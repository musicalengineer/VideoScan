#!/usr/bin/env python3.12
"""
overnight_people_scan.py — survey "who is in which video?" across local volumes.

Walks a list of root directories, runs face recognition once per video with
the model state loaded a single time (saves ~5s/video of model-load overhead),
and produces:

  - per_video.tsv   one row per (video, person) — append-as-you-go, crash-safe
  - summary.md      final aggregated counts per POI
  - progress.log    timestamped running log

Default behavior: imports the embedding helpers from is_person_in_video.py
and reuses them. POI list is auto-discovered from
~/Library/Application Support/VideoScan/POI/.

Usage:
    scripts/overnight_people_scan.py                            # default roots
    scripts/overnight_people_scan.py --root /Volumes/X          # explicit roots
    scripts/overnight_people_scan.py --max-frames 30            # quicker survey
"""
from __future__ import annotations
import argparse
import os
import sys
import time
import tempfile
from datetime import datetime
from pathlib import Path

import numpy as np
from PIL import Image, ImageOps

# Reuse functions from the surgical CLI.
sys.path.insert(0, str(Path(__file__).parent))
import is_person_in_video as ipv

VIDEO_EXTS = {".mov", ".mp4", ".m4v", ".mkv", ".avi", ".mts", ".dv",
              ".vob", ".webm", ".wmv", ".flv", ".3gp"}

# Volumes that hold generated app output — skip to avoid recursing into
# files we made ourselves (which would inflate counts circularly).
SKIP_DIR_NAMES = {
    "output_may3", "output", "Render Files", "Analysis Files",
    "Backups.backupdb", "Time Machine Backups",
    ".Spotlight-V100", ".fseventsd", ".Trashes", ".DocumentRevisions-V100",
}

DEFAULT_ROOTS = [
    Path.home() / "Movies",
    Path("/Volumes/Crucial2TB"),
    Path("/Volumes/LACIE500"),
    Path("/Volumes/Seagate2TB"),
    Path("/Volumes/MyBook3Terabytes"),
]

DEFAULT_OUT = Path.home() / "dev/VideoScan/output"


def iter_videos(roots: list[Path]):
    """Walk roots yielding (path, size_bytes) for video files."""
    for root in roots:
        if not root.exists():
            yield from ()
            continue
        for dirpath, dirnames, filenames in os.walk(str(root), topdown=True,
                                                     followlinks=False):
            dirnames[:] = [d for d in dirnames
                           if d not in SKIP_DIR_NAMES and not d.startswith(".")]
            for fn in sorted(filenames):
                if fn.startswith("."):
                    continue
                ext = os.path.splitext(fn)[1].lower()
                if ext in VIDEO_EXTS:
                    p = Path(dirpath) / fn
                    try:
                        sz = p.stat().st_size
                    except OSError:
                        continue
                    if sz < 100_000:   # skip <100KB (junk)
                        continue
                    yield p, sz


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", type=Path, action="append",
                    help="root directory to walk (repeatable). Default: "
                         "~/Movies + /Volumes/{Crucial2TB,LACIE500,Seagate2TB,MyBook3Terabytes}")
    ap.add_argument("--poi-root", type=Path,
                    default=Path.home() / "Library/Application Support/VideoScan/POI")
    ap.add_argument("--out-dir", type=Path, default=DEFAULT_OUT,
                    help="output root (default ~/dev/VideoScan/output)")
    ap.add_argument("--threshold", type=float, default=0.40)
    ap.add_argument("--frame-step", type=float, default=5.0)
    ap.add_argument("--max-frames", type=int, default=30,
                    help="frames per video — survey defaults to 30 for speed")
    ap.add_argument("--resume", action="store_true",
                    help="skip videos already in per_video.tsv from a prior run")
    ap.add_argument("--resume-from", type=Path,
                    help="path to per_video.tsv from a prior run to resume")
    args = ap.parse_args()

    roots = args.root or DEFAULT_ROOTS
    roots = [r for r in roots if r.exists()]
    if not roots:
        print("error: no roots exist", file=sys.stderr)
        return 2

    # Resolve output dir for this run.
    if args.resume_from:
        run_dir = args.resume_from.parent
        ts_label = run_dir.name.replace("overnight_scan_", "")
    else:
        ts_label = datetime.now().strftime("%Y%m%d_%H%M%S")
        run_dir = args.out_dir / f"overnight_scan_{ts_label}"
    run_dir.mkdir(parents=True, exist_ok=True)

    tsv_path = run_dir / "per_video.tsv"
    log_path = run_dir / "progress.log"
    summary_path = run_dir / "summary.md"

    # Resume support.
    already_done: set[str] = set()
    if args.resume or args.resume_from:
        src = args.resume_from or tsv_path
        if src.exists():
            with src.open() as f:
                next(f, None)  # header
                for line in f:
                    parts = line.rstrip("\n").split("\t")
                    if parts:
                        already_done.add(parts[0])
            print(f"[resume] {len(already_done)} videos already processed", flush=True)

    # Open TSV in append mode if resuming, write fresh otherwise.
    new_tsv = not tsv_path.exists()
    tsv = tsv_path.open("a", buffering=1)  # line-buffered
    log = log_path.open("a", buffering=1)
    if new_tsv:
        tsv.write("video_path\tvideo_duration_sec\tperson\tfound\tbest_cosine\t"
                  "presence_sec\tsampled_frames\trun_seconds\n")

    def logline(msg: str) -> None:
        ts = datetime.now().strftime("%H:%M:%S")
        line = f"[{ts}] {msg}"
        print(line, flush=True)
        log.write(line + "\n")

    logline(f"Run started. Roots: {[str(r) for r in roots]}")
    logline(f"Threshold {args.threshold}, frame_step {args.frame_step}s, "
            f"max_frames {args.max_frames}")
    logline(f"Output: {run_dir}")

    # Load POIs once.
    logline("Loading reference embeddings…")
    ipv.init_models()
    pois: list[tuple[str, np.ndarray]] = []
    for d in sorted(args.poi_root.iterdir()):
        if not d.is_dir():
            continue
        name, embs = ipv.load_poi_embeddings(d)
        if embs.shape[0] == 0:
            logline(f"  {name}: 0 usable references (skipped)")
            continue
        pois.append((name, embs))
        logline(f"  {name}: {embs.shape[0]} reference embeddings")

    if not pois:
        logline("error: no POIs with usable references")
        return 2

    # Walk videos.
    logline("Enumerating videos…")
    all_videos = list(iter_videos(roots))
    logline(f"  Found {len(all_videos)} video files (>=100KB)")

    pending = [(p, sz) for p, sz in all_videos if str(p) not in already_done]
    logline(f"  Processing {len(pending)} (skipping {len(all_videos) - len(pending)} "
            f"from resume state)")

    started = time.time()
    n_done = 0
    n_with_face = 0

    for i, (video, _sz) in enumerate(pending, 1):
        t0 = time.time()
        try:
            duration = ipv.ffprobe_duration(video)
        except Exception:
            duration = None
        if duration is None or duration < 1.0:
            for name, _ in pois:
                tsv.write(f"{video}\t{duration or 0:.2f}\t{name}\tfalse\t0.000\t0\t0\t0.00\n")
            n_done += 1
            if i % 25 == 0 or i == len(pending):
                logline(f"  [{i}/{len(pending)}] (skipped: ffprobe failed) {video.name}")
            continue

        with tempfile.TemporaryDirectory() as td:
            tmpdir = Path(td)
            try:
                frames = ipv.extract_frames(video, duration, args.frame_step,
                                            args.max_frames, tmpdir)
            except Exception as e:
                logline(f"  ⚠ extract_frames failed for {video}: {e}")
                frames = []
            if not frames:
                for name, _ in pois:
                    tsv.write(f"{video}\t{duration:.2f}\t{name}\tfalse\t0.000\t0\t0\t"
                              f"{time.time() - t0:.2f}\n")
                n_done += 1
                continue

            per_poi_best = {n: 0.0 for n, _ in pois}
            per_poi_hits = {n: 0 for n, _ in pois}
            face_frames = 0

            for ts, frame_path in frames:
                try:
                    img = ImageOps.exif_transpose(Image.open(frame_path)).convert("RGB")
                except Exception:
                    continue
                faces = ipv.detect_and_embed(img)
                if not faces:
                    continue
                face_frames += 1
                for emb, _prob in faces:
                    for name, refs in pois:
                        sim = ipv.cosine_max(emb, refs)
                        if sim > per_poi_best[name]:
                            per_poi_best[name] = sim
                        if sim >= args.threshold:
                            per_poi_hits[name] += 1
                            break

            if face_frames > 0:
                n_with_face += 1
            sampled = len(frames)
            for name, _ in pois:
                hits = per_poi_hits[name]
                best = per_poi_best[name]
                presence = (hits / sampled) * duration if sampled else 0.0
                found = "true" if best >= args.threshold else "false"
                tsv.write(f"{video}\t{duration:.2f}\t{name}\t{found}\t"
                          f"{best:.3f}\t{int(presence)}\t{sampled}\t"
                          f"{time.time() - t0:.2f}\n")

        n_done += 1
        if i % 10 == 0 or i == len(pending):
            elapsed = time.time() - started
            rate = n_done / elapsed if elapsed > 0 else 0
            eta_s = (len(pending) - n_done) / rate if rate > 0 else 0
            eta_h = eta_s / 3600
            logline(f"  [{i}/{len(pending)}] done. Rate {rate:.2f} vid/sec, "
                    f"ETA ~{eta_h:.1f}h. With faces: {n_with_face}.")

    tsv.close()
    log.close()

    # Aggregate summary.
    counts: dict[str, int] = {n: 0 for n, _ in pois}
    presence_total: dict[str, float] = {n: 0.0 for n, _ in pois}
    videos_seen = set()
    with tsv_path.open() as f:
        next(f)  # header
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 8:
                continue
            v_path, _dur, person, found, _conf, presence, _sampled, _t = parts
            videos_seen.add(v_path)
            if found == "true":
                counts[person] = counts.get(person, 0) + 1
                presence_total[person] = presence_total.get(person, 0.0) + float(presence)

    total_videos = len(videos_seen)
    elapsed_total = time.time() - started

    with summary_path.open("w") as f:
        f.write(f"# Overnight people scan — {ts_label}\n\n")
        f.write(f"**Run:** {datetime.now().strftime('%Y-%m-%d %H:%M:%S')} "
                f"(elapsed {elapsed_total/3600:.1f} h)\n\n")
        f.write(f"**Roots scanned:** {len(roots)}\n\n")
        for r in roots:
            f.write(f"- `{r}`\n")
        f.write(f"\n**Total videos scanned:** {total_videos}\n\n")
        f.write(f"**Settings:** threshold={args.threshold}, frame_step={args.frame_step}s, "
                f"max_frames={args.max_frames}\n\n")
        f.write("## Counts per person\n\n")
        f.write("| Person | Videos with detections | % of total | Total presence |\n")
        f.write("|---|---:|---:|---:|\n")
        for name, _ in sorted(pois, key=lambda x: counts.get(x[0], 0), reverse=True):
            n = counts.get(name, 0)
            pct = (n / total_videos * 100) if total_videos else 0
            secs = presence_total.get(name, 0)
            mins = secs / 60
            f.write(f"| {name} | {n} | {pct:.1f}% | {mins:.1f} min |\n")
        f.write(f"\n## Detail\n\nPer-video, per-person breakdown: `per_video.tsv`\n")
        f.write(f"\nProgress log: `progress.log`\n")

    logline(f"Done. {total_videos} videos scanned across {len(roots)} roots in "
            f"{elapsed_total/3600:.2f}h. Summary: {summary_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
