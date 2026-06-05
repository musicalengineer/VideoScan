#!/usr/bin/env python3
"""Batch dossier — runs the proven Qwen + Whisper pipeline over a list
of video paths, writes results into catalog.json under the new
dossier schema fields:

  ocrDateCandidates  : [{timestamp, text}]
  ocrText            : [{timestamp, text}]
  sceneCaptions      : [{timestamp, text}]    (the scene-description prompt)
  audioTranscript    : "..."
  inferredRecordDate : "ISO date"
  inferredDateConfidence : float
  dossierProcessedAt : "ISO date"
  dossierProcessedBy : "qwen2.5-vl-3b-4bit+whisper-medium-mlx-q4"

Idempotent: records with `dossierProcessedAt` set are skipped unless
--force is passed.

Atomic catalog write: catalog.json is loaded, mutated in-memory,
written to a tmp file, then renamed over the original. The previous
catalog is rotated to catalog.json.prev so we can rewind if anything
goes sideways.

Usage:
  python dossier_batch.py                         # all 121 Matt-tagged records
  python dossier_batch.py --paths-file <file>     # explicit list, one path per line
  python dossier_batch.py --filter people=Matt    # filter expression
  python dossier_batch.py --limit 5               # safety cap (smoke test)
  python dossier_batch.py --force                 # re-dossier already-processed records
  python dossier_batch.py --frames 15             # frames per file (default 15)
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import traceback
from datetime import datetime, timezone
from pathlib import Path

CATALOG = Path("~/Library/Application Support/VideoScan/catalog.json").expanduser()
LOG_DIR = Path("~/Library/Logs/VideoScan/dossier-batch").expanduser()

VLM_MODEL = "mlx-community/Qwen2.5-VL-3B-Instruct-4bit"
WHISPER_MODEL = "mlx-community/whisper-medium-mlx-q4"
MODEL_STACK = "qwen2.5-vl-3b-4bit+whisper-medium-mlx-q4"

PROMPTS = {
    "date":  "What date or time is shown anywhere in this image, including any timestamp burned into the video? If you see a date or time, give exactly what you see (e.g. 'MAR 14 1991 03:42PM'). If no date/time visible, answer just 'NONE'.",
    "scene": "Briefly describe what you see in this image: people (with apparent ages and roles), location, what they're doing, and any era cues (decor, technology, fashion). 2-3 sentences.",
    "text":  "List all text visible in this image — burned-in subtitles, signs, screen content, anything readable. If no text, answer 'NONE'.",
}

# ---------------------------------------------------------------------------
# Date parsing — Swift parity. Same regex shape as DateTriangulation.swift's
# pfParseOcrDate so the Python batch and the Swift runtime produce identical
# inferred dates.

MONTH_MAP = {
    "JAN": 1, "JANUARY": 1, "FEB": 2, "FEBRUARY": 2, "MAR": 3, "MARCH": 3,
    "APR": 4, "APRIL": 4, "MAY": 5, "JUN": 6, "JUNE": 6, "JUL": 7, "JULY": 7,
    "AUG": 8, "AUGUST": 8, "SEP": 9, "SEPT": 9, "SEPTEMBER": 9,
    "OCT": 10, "OCTOBER": 10, "NOV": 11, "NOVEMBER": 11, "DEC": 12, "DECEMBER": 12,
}

OCR_DATE_RE = re.compile(r"([A-Z]{3,9})[.\s]+(\d{1,2})[.\s,]+((?:19|20)\d{2})")

def parse_ocr_date(raw: str):
    """Return datetime or None. Matches Swift pfParseOcrDate semantics."""
    if not raw:
        return None
    s = raw.strip().upper()
    if not s or s == "NONE":
        return None
    m = OCR_DATE_RE.search(s)
    if not m:
        return None
    mon = MONTH_MAP.get(m.group(1))
    day = int(m.group(2))
    year = int(m.group(3))
    if not mon or not (1 <= day <= 31):
        return None
    try:
        return datetime(year, mon, day, 12, 0, 0, tzinfo=timezone.utc)
    except ValueError:
        return None


def infer_record_date(ocr_candidates, file_mtime: float):
    """Mirror of Swift pfInferRecordDate. Returns (datetime, confidence)."""
    parsed = [d for d in (parse_ocr_date(t) for t in ocr_candidates) if d]
    if parsed:
        # Bucket by day, find consensus.
        buckets = {}
        for d in parsed:
            key = d.replace(hour=12, minute=0, second=0, microsecond=0)
            buckets.setdefault(key, []).append(d)
        best, hits = max(buckets.items(), key=lambda kv: len(kv[1]))
        if len(hits) >= 3:
            conf = 0.95
        elif len(hits) == 2:
            conf = 0.85
        else:
            conf = 0.75
        return best, conf
    if file_mtime:
        return datetime.fromtimestamp(file_mtime, tz=timezone.utc), 0.30
    return None, 0.0


# ---------------------------------------------------------------------------
# Single-file dossier (mirrors video_dossier.py but returns structured data)

def dossier_one(video_path: Path, vlm_model, vlm_processor, vlm_config, num_frames: int, log):
    """Return dict of dossier results for one video, or raise on fatal."""
    log(f"\n=== {video_path.name} ===")
    if not video_path.exists():
        log(f"  SKIP (missing on disk)")
        return None

    # ffprobe duration
    try:
        probe = subprocess.run(
            ["ffprobe", "-v", "error", "-show_format", "-of", "json", str(video_path)],
            capture_output=True, text=True, timeout=30
        )
        duration = float(json.loads(probe.stdout)["format"]["duration"])
    except Exception as e:
        log(f"  SKIP (ffprobe failed: {e})")
        return None
    if duration <= 0:
        log(f"  SKIP (zero duration)")
        return None

    # Extract frames evenly spaced
    tmpdir = Path(tempfile.mkdtemp(prefix="dossier_batch_"))
    frame_times = [duration * (i + 0.5) / num_frames for i in range(num_frames)]
    frame_paths = []
    try:
        for i, t in enumerate(frame_times):
            out = tmpdir / f"frame_{i:02d}.jpg"
            r = subprocess.run(
                ["ffmpeg", "-y", "-ss", f"{t:.3f}", "-i", str(video_path),
                 "-frames:v", "1", "-q:v", "2", str(out)],
                capture_output=True, timeout=30
            )
            if r.returncode == 0 and out.exists() and out.stat().st_size > 100:
                frame_paths.append((t, out))
        if not frame_paths:
            log(f"  SKIP (no frames extracted)")
            return None

        # VLM per frame
        from mlx_vlm import generate
        from mlx_vlm.prompt_utils import apply_chat_template
        ocr_dates = []
        ocr_texts = []
        scene_caps = []

        vlm_start = time.time()
        for ts, fp in frame_paths:
            for key, prompt in PROMPTS.items():
                formatted = apply_chat_template(vlm_processor, vlm_config, prompt, num_images=1)
                try:
                    out = generate(vlm_model, vlm_processor, formatted, image=str(fp),
                                   max_tokens=180, verbose=False)
                    text = (out.text if hasattr(out, "text") else str(out)).strip()
                except Exception as e:
                    log(f"  VLM error at t={ts:.1f}s/{key}: {e}")
                    continue
                if key == "date" and text.upper() != "NONE":
                    ocr_dates.append({"timestamp": ts, "text": text})
                elif key == "text" and text.upper() != "NONE":
                    ocr_texts.append({"timestamp": ts, "text": text})
                elif key == "scene":
                    scene_caps.append({"timestamp": ts, "text": text})
        vlm_secs = time.time() - vlm_start
        log(f"  VLM: {vlm_secs:.1f}s ({len(ocr_dates)} dates, {len(ocr_texts)} text, {len(scene_caps)} scenes)")

        # Whisper transcript
        import mlx_whisper
        try:
            w_start = time.time()
            result = mlx_whisper.transcribe(str(video_path), path_or_hf_repo=WHISPER_MODEL, verbose=False)
            transcript = result.get("text", "").strip()
            w_secs = time.time() - w_start
            log(f"  Whisper: {w_secs:.1f}s")
        except Exception as e:
            log(f"  Whisper error: {e}")
            transcript = ""

        # Triangulate
        ocr_strings = [d["text"] for d in ocr_dates]
        mtime = video_path.stat().st_mtime
        inferred_date, conf = infer_record_date(ocr_strings, mtime)

        log(f"  → inferred: {inferred_date.isoformat() if inferred_date else 'unknown'} (conf {conf:.2f})")

        return {
            "ocrDateCandidates": ocr_dates,
            "ocrText": ocr_texts,
            "sceneCaptions": scene_caps,
            "sceneCaptionModel": VLM_MODEL.rsplit("/", 1)[-1],
            "sceneCaptionDate": datetime.now(timezone.utc).isoformat(),
            "audioTranscript": transcript or None,
            "audioTranscriptModel": WHISPER_MODEL.rsplit("/", 1)[-1] if transcript else None,
            "audioTranscriptDate": datetime.now(timezone.utc).isoformat() if transcript else None,
            "inferredRecordDate": inferred_date.isoformat() if inferred_date else None,
            "inferredDateConfidence": float(conf) if inferred_date else None,
            "dossierProcessedAt": datetime.now(timezone.utc).isoformat(),
            "dossierProcessedBy": MODEL_STACK,
        }
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


# ---------------------------------------------------------------------------
# Catalog I/O — atomic write, idempotent skip

def select_records(catalog, *, paths_file=None, filter_expr=None):
    """Return list of (index, record) pairs from catalog['records'] to process."""
    records = catalog["records"]
    if paths_file:
        wanted = {p.strip() for p in Path(paths_file).read_text().splitlines() if p.strip()}
        return [(i, r) for i, r in enumerate(records) if r.get("fullPath") in wanted]
    if filter_expr:
        # Simple "people=Matt" — extend later if needed.
        if "=" in filter_expr:
            key, val = filter_expr.split("=", 1)
            if key == "people":
                return [(i, r) for i, r in enumerate(records)
                        if val in (r.get("detectedPeople") or []) or val in (r.get("suspectedPeople") or [])]
        raise ValueError(f"Unsupported filter: {filter_expr}")
    return list(enumerate(records))


def atomic_write_catalog(catalog, path):
    """Write catalog.json atomically: tmp + rename. Rotate previous to .prev."""
    if path.exists():
        shutil.copy2(path, path.with_suffix(".json.prev"))
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(catalog, indent=2, ensure_ascii=False))
    os.replace(tmp, path)


# ---------------------------------------------------------------------------
# main

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--paths-file", type=str, help="One path per line.")
    ap.add_argument("--filter", type=str, help="e.g. 'people=Matt'")
    ap.add_argument("--limit", type=int, default=0, help="Cap records (0 = no cap)")
    ap.add_argument("--frames", type=int, default=15)
    ap.add_argument("--force", action="store_true", help="Re-dossier records that already have dossierProcessedAt")
    ap.add_argument("--save-every", type=int, default=5,
                    help="Write catalog.json after every N processed records (safety against crash)")
    args = ap.parse_args()

    if not args.paths_file and not args.filter:
        # Default: Matt-tagged
        args.filter = "people=Matt"

    LOG_DIR.mkdir(parents=True, exist_ok=True)
    logpath = LOG_DIR / f"batch_{datetime.now().strftime('%Y%m%d_%H%M%S')}.log"
    logf = open(logpath, "w")

    def log(msg):
        print(msg)
        logf.write(msg + "\n")
        logf.flush()

    log(f"=== dossier_batch start ===")
    log(f"catalog: {CATALOG}")
    log(f"log:     {logpath}")
    log(f"filter:  paths_file={args.paths_file} expr={args.filter} limit={args.limit}")
    log(f"frames:  {args.frames}")
    log(f"force:   {args.force}")

    catalog = json.loads(CATALOG.read_text())
    log(f"records in catalog: {len(catalog['records'])}")

    targets = select_records(catalog, paths_file=args.paths_file, filter_expr=args.filter)
    log(f"targets after filter: {len(targets)}")

    if not args.force:
        before = len(targets)
        targets = [(i, r) for i, r in targets if not r.get("dossierProcessedAt")]
        log(f"  skip already-processed: {before - len(targets)} → {len(targets)} to do")

    if args.limit and args.limit > 0:
        targets = targets[:args.limit]
        log(f"  --limit applied → {len(targets)} to do")

    if not targets:
        log("nothing to do.")
        return

    # Load VLM model once.
    log(f"\n=== loading {VLM_MODEL} ===")
    from mlx_vlm import load
    from mlx_vlm.utils import load_config
    t0 = time.time()
    vlm_model, vlm_processor = load(VLM_MODEL)
    vlm_config = load_config(VLM_MODEL)
    log(f"loaded in {time.time() - t0:.1f}s")

    started = time.time()
    ok = 0
    failed = 0
    for n, (idx, rec) in enumerate(targets, 1):
        path = Path(rec["fullPath"])
        log(f"\n[{n}/{len(targets)}] index={idx}")
        try:
            d = dossier_one(path, vlm_model, vlm_processor, vlm_config, args.frames, log)
            if d:
                # Merge into record. Only set fields we computed.
                for k, v in d.items():
                    rec[k] = v
                ok += 1
            else:
                failed += 1
        except KeyboardInterrupt:
            log("interrupted — saving partial progress")
            break
        except Exception as e:
            log(f"  EXC: {e}")
            log(traceback.format_exc())
            failed += 1

        # Periodic save — survives crashes
        if n % args.save_every == 0:
            atomic_write_catalog(catalog, CATALOG)
            log(f"  [checkpoint saved at {n}/{len(targets)}]")

    # Final save
    atomic_write_catalog(catalog, CATALOG)
    elapsed = time.time() - started
    log(f"\n=== done in {elapsed:.0f}s — {ok} ok, {failed} failed of {len(targets)} ===")
    logf.close()


if __name__ == "__main__":
    main()
