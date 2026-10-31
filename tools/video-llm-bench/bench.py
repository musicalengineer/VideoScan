#!/usr/bin/env python3
"""Video-LLM benchmark harness — Phase 0 of docs/design/video_llm_lab_2026_10_30.md.

Three subcommands, one file, no package:

* ``validate-corpus``  builds the frozen ERA and OCR corpora from a READ-ONLY
  ``.backup`` copy of the catalog and writes one manifest JSON (digests, paths,
  strata, truth values).  The manifest lives in ``.scratch/`` — it names family
  footage and never enters the repo (DECISIONS 2026-10-26).
* ``run``              drives approach ``a0-py`` (Qwen2.5-VL-3B-Instruct-4bit
  through mlx-vlm, the three prompts the app's ``MLXVLMCaptionRunner.dossier``
  sends, 448×448 letterboxed stills from the middle 90 % of each clip) over a
  manifest and streams one JSONL file per clip into ``<out>/clips/``.  Resume
  safe: a clip whose file ends with a ``clip_done`` record is skipped.
* ``summarize``        reads a run directory and writes AGGREGATES ONLY
  (no path, no digest, no raw model text) to a Markdown file and stdout.

Discipline follows ``tools/qwen-bench``: the run record pins model tag,
weights digest, prompt hashes, sampler id, git SHA, corpus hash, host, seed,
library versions and timings.

Memory (worst case, ``run``): model weights ≈ 2.4 GB resident + mlx cache
limit 512 MB + one 448×448 PNG on disk per ripped frame (≤ ``--frames`` per
clip, deleted after the clip) + the KV cache of one generation (≤ 180 tokens).
Results stream to disk one record at a time; nothing per-clip is kept in RAM.
``summarize`` keeps one small dict per clip (≈ 300 clips → a few hundred KB).

C++ reading: ``Approach`` is an abstract base with ``load()`` / ``answer()``;
``run_corpus`` takes it (and the frame ripper) as injected collaborators so the
loop is testable without a model or media — std::function parameters.
"""
from __future__ import annotations

import argparse
import collections
import dataclasses
import datetime as dt
import hashlib
import json
import os
import platform
import random
import re
import shutil
import socket
import sqlite3
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, List, Optional, Sequence, Tuple

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parents[1]

APPROACH_ID = "a0-py"
MODEL_ID = "mlx-community/Qwen2.5-VL-3B-Instruct-4bit"
SAMPLER_ID_TEMPLATE = "stills-{n}-middle90"
MANIFEST_SCHEMA = 1
RUN_SCHEMA = 1
DEFAULT_SEED = 20261030
ERA_CAMERA_TARGET = 200
OCR_TARGET = 100
STRATUM_FLOOR = 8          # every non-empty camera stratum gets at least this many (or all it has)

# ---------------------------------------------------------------------------
# Prompts — copied VERBATIM from VideoScan/VideoScan/Media/CaptionRunner.swift
# (`DossierPromptKind.promptText` and the system message in `dossier(...)`).
# Wording PROVEN 2026-06-04 on Clip 03_converted.mov; do not drift.
# ---------------------------------------------------------------------------
SYSTEM_PROMPT = (
    "You are an image understanding model capable of describing the salient "
    "features of any image."
)
PROMPTS: Dict[str, str] = {
    "date": (
        "What date or time is shown anywhere in this image, including any timestamp "
        "burned into the video? If you see a date or time, give exactly what you see "
        "(e.g. 'MAR 14 1991 03:42PM'). If no date/time visible, answer just 'NONE'."
    ),
    "scene": (
        "Briefly describe what you see in this image: people (with apparent ages and "
        "roles), location, what they're doing, and any era cues (decor, technology, "
        "fashion). 2-3 sentences."
    ),
    "text": (
        "List all text visible in this image — burned-in subtitles, signs, screen "
        "content, anything readable. If no text, answer 'NONE'."
    ),
}
PROMPT_ORDER = ("date", "scene", "text")
# Per-prompt generation parameters, same as the app's dossier pass.
GEN_PARAMS: Dict[str, Dict[str, Any]] = {
    "date": {"max_tokens": 32, "temperature": 0.0, "top_p": 0.9},
    "scene": {"max_tokens": 180, "temperature": 0.2, "top_p": 0.9},
    "text": {"max_tokens": 96, "temperature": 0.0, "top_p": 0.9},
}
MLX_SEED = 0xCAFE_F00D   # MLXRandom.seed(0xCAFE_F00D) in the app, once per dossier call
FRAME_SIDE = 448
MLX_CACHE_LIMIT_BYTES = 512 * 1024 * 1024

# Codecs a camera writes natively: `format:creation_time` is the footage date.
# ProRes / FFV1 / DNxHD / qtrle / rawvideo creation_time is a transfer or export
# stamp (DateTriangulator: "export stamp … set aside as ingest"), so those files
# are NOT camera-dated truth and are excluded from the camera strata.
CAMERA_NATIVE_CODECS = {"hevc", "h264", "mjpeg", "dvvideo", "DV 25", "mpeg4", "svq3", "h263"}


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def sha256_json(value: Any) -> str:
    return sha256_text(json.dumps(value, sort_keys=True, separators=(",", ":")))


def git_sha(repository: Path = REPO_ROOT) -> Optional[str]:
    try:
        result = subprocess.run(
            ["git", "-C", str(repository), "rev-parse", "HEAD"],
            capture_output=True, text=True, timeout=5, check=False)
    except (OSError, subprocess.SubprocessError):
        return None
    revision = result.stdout.strip()
    return revision if result.returncode == 0 and revision else None


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")


# ---------------------------------------------------------------------------
# Date and year parsing (pure).  Mirrors `pfParseOcrDate` in
# Catalog/DateTriangulation.swift for the month-name form, plus the numeric
# forms a burn-in or a VLM may emit.  Every regex guards both ends with
# (?<!\d) / (?!\d) so "19910" is never a year.
# ---------------------------------------------------------------------------
MONTHS: Dict[str, int] = {
    "JAN": 1, "JANUARY": 1, "FEB": 2, "FEBRUARY": 2, "MAR": 3, "MARCH": 3,
    "APR": 4, "APRIL": 4, "MAY": 5, "JUN": 6, "JUNE": 6, "JUL": 7, "JULY": 7,
    "AUG": 8, "AUGUST": 8, "SEP": 9, "SEPT": 9, "SEPTEMBER": 9, "OCT": 10,
    "OCTOBER": 10, "NOV": 11, "NOVEMBER": 11, "DEC": 12, "DECEMBER": 12,
}
_YEAR4 = r"(?:19|20)\d{2}"
_YEAR2 = r"['’`]\s?(\d{2})"
# MONTH-NAME [. ] DAY [. ,] YEAR | 'YY          ("JUN.21 1991", "JUN 21 '97", "JUN\n21\n'97")
_RE_MDY_NAME = re.compile(
    r"(?<![A-Z])([A-Z]{3,9})[.\s]+(\d{1,2})(?!\d)[.\s,]+(?:(" + _YEAR4 + r")|" + _YEAR2 + r")(?!\d)")
# DAY MONTH-NAME YEAR                           ("4 March 1952", "21 JUN 1991")
_RE_DMY_NAME = re.compile(
    r"(?<!\d)(\d{1,2})(?!\d)[.\s,]+([A-Z]{3,9})[.\s,]+(?:(" + _YEAR4 + r")|" + _YEAR2 + r")(?!\d)")
# ISO                                          ("1991-06-21", "1991/06/21")
_RE_ISO = re.compile(r"(?<!\d)(" + _YEAR4 + r")[-/.](\d{1,2})[-/.](\d{1,2})(?!\d)")
# US numeric                                   ("6/21/91", "06-21-1991")
_RE_US = re.compile(r"(?<!\d)(\d{1,2})[/\-.](\d{1,2})[/\-.](?:(" + _YEAR4 + r")|(\d{2}))(?!\d)")
# A bare year; "1990s" / "1990's" is a decade mention, not the year 1990.
_RE_YEAR = re.compile(r"(?<![\d'’`])(" + _YEAR4 + r")(?!\d|['’]?[sS]\b)")
# Decade mentions: "1990s", "1990's", "the 90s", "early 1990s", "late '80s", "mid-1970s"
_RE_DECADE = re.compile(
    r"(?i)\b(early|mid|late)?[-\s]*(?:(19\d0|20[0-2]0)|['’`]?(\d0))\s?['’]?s\b")

YEAR_MIN, YEAR_MAX = 1900, 2029


def expand_two_digit_year(yy: int) -> int:
    """Same pivot as pfExpandTwoDigitYear: 00–29 → 2000s, 30–99 → 1900s."""
    return 2000 + yy if yy < 30 else 1900 + yy


def _valid(year: int, month: int, day: int) -> Optional[str]:
    if not (YEAR_MIN <= year <= YEAR_MAX):
        return None
    try:
        return dt.date(year, month, day).isoformat()
    except ValueError:
        return None


def parse_dates(text: str) -> List[str]:
    """Every calendar date in ``text`` as ISO strings, in text order, deduplicated.

    "NONE" and empty → [].  "19910" → [].  "6/21/91" → ["1991-06-21"].
    "JUN 21 1991" → ["1991-06-21"].  "4 March 1952" → ["1952-03-04"].
    A bare 4-digit year is NOT a date (see ``parse_years``).
    """
    if not text:
        return []
    upper = text.strip().upper()
    if not upper or upper == "NONE":
        return []
    found: List[Tuple[int, str]] = []
    for match in _RE_MDY_NAME.finditer(upper):
        month = MONTHS.get(match.group(1))
        if month is None:
            continue
        year = int(match.group(3)) if match.group(3) else expand_two_digit_year(int(match.group(4)))
        iso = _valid(year, month, int(match.group(2)))
        if iso:
            found.append((match.start(), iso))
    for match in _RE_DMY_NAME.finditer(upper):
        month = MONTHS.get(match.group(2))
        if month is None:
            continue
        year = int(match.group(3)) if match.group(3) else expand_two_digit_year(int(match.group(4)))
        iso = _valid(year, month, int(match.group(1)))
        if iso:
            found.append((match.start(), iso))
    for match in _RE_ISO.finditer(upper):
        iso = _valid(int(match.group(1)), int(match.group(2)), int(match.group(3)))
        if iso:
            found.append((match.start(), iso))
    for match in _RE_US.finditer(upper):
        year = int(match.group(3)) if match.group(3) else expand_two_digit_year(int(match.group(4)))
        iso = _valid(year, int(match.group(1)), int(match.group(2)))
        if iso:
            found.append((match.start(), iso))
    ordered: List[str] = []
    for _, iso in sorted(found):
        if iso not in ordered:
            ordered.append(iso)
    return ordered


def parse_years(text: str) -> List[int]:
    """Explicit 4-digit years 1900–2029 in ``text`` (not part of a longer number)."""
    if not text:
        return []
    years = [int(m.group(1)) for m in _RE_YEAR.finditer(text)]
    return [y for y in years if YEAR_MIN <= y <= YEAR_MAX]


def parse_decades(text: str) -> List[int]:
    """Decade mentions as a representative year: "1990s" → 1995, "early 1990s" → 1992,
    "late 80s" → 1987, "mid-1970s" → 1975.  Two-digit decades pivot like years."""
    if not text:
        return []
    out: List[int] = []
    for match in _RE_DECADE.finditer(text):
        qualifier = (match.group(1) or "").lower()
        if match.group(2):
            decade = int(match.group(2))
        else:
            decade = expand_two_digit_year(int(match.group(3)))
        if not (YEAR_MIN <= decade <= YEAR_MAX):
            continue
        offset = {"early": 2, "mid": 5, "late": 7}.get(qualifier, 5)
        out.append(decade + offset)
    return out


def is_degenerate(text: str) -> bool:
    """The 3B model's known failure mode: a run of one repeated punctuation glyph
    ("!!!!!!!!…").  Ten or more of the same non-alphanumeric character in a row."""
    return bool(re.search(r"([^\w\s])\1{9,}", text or ""))


# ---------------------------------------------------------------------------
# Best-single-year rule for ERA (documented in README and the Markdown):
#   weight 3 — the year of every parsed calendar date from the date/text prompts
#   weight 1 — every explicit 4-digit year in any prompt's text
#   weight 1 — every decade mention ("1990s" → 1995; early/mid/late → +2/+5/+7)
# Best year = the candidate with the highest total weight; on a tie, the median
# of the tied candidates (lower middle).  No candidate at all → "no answer".
# Degenerate outputs ("!!!!…") contribute nothing.
# ---------------------------------------------------------------------------
def best_year(records: Iterable[Dict[str, Any]]) -> Optional[int]:
    weights: Dict[int, int] = collections.Counter()
    for record in records:
        text = record.get("raw_text") or ""
        if is_degenerate(text):
            continue
        kind = record.get("prompt_kind")
        if kind in ("date", "text"):
            for iso in parse_dates(text):
                weights[int(iso[:4])] += 3
        for year in parse_years(text):
            weights[year] += 1
        for year in parse_decades(text):
            weights[year] += 1
    if not weights:
        return None
    top = max(weights.values())
    tied = sorted(year for year, weight in weights.items() if weight == top)
    return tied[(len(tied) - 1) // 2]


# ---------------------------------------------------------------------------
# Corpus building (validate-corpus)
# ---------------------------------------------------------------------------
@dataclasses.dataclass(frozen=True)
class ClipEntry:
    digest: str
    path: str
    size_bytes: int
    duration_s: float
    corpus: str            # "era" | "ocr"
    stratum: str           # e.g. "rick-dated/1990s", "camera/2020s/hevc"
    truth: Dict[str, Any]  # era: {"year", "source", "confidence"}; ocr: {"date", "source", "verdict_year"}
    codec: str
    container: str

    def to_dict(self) -> Dict[str, Any]:
        return dataclasses.asdict(self)


def decade_label(year: int) -> str:
    return "{}s".format(year // 10 * 10)


def codec_class(video_codec: str) -> str:
    return {"DV 25": "dvvideo"}.get(video_codec, video_codec or "unknown")


def open_readonly(path: Path) -> sqlite3.Connection:
    """URI mode=ro: the connection cannot write, even by accident."""
    return sqlite3.connect("file:{}?mode=ro".format(Path(path).resolve()), uri=True)


def _first_reachable(paths: Sequence[str], exists: Callable[[str], bool]) -> Optional[str]:
    for path in sorted(paths):
        if exists(path):
            return path
    return None


def _live_files(conn: sqlite3.Connection) -> Dict[str, List[Dict[str, Any]]]:
    """content digest → the live (not removed) video rows that carry it."""
    rows = conn.execute(
        "SELECT content_digest, full_path, size_bytes, duration_s, video_codec, container, "
        "embedded_created_at, stream_type FROM files WHERE removal_state IS NULL "
        "AND stream_type IN ('Video+Audio','Video only')").fetchall()
    by: Dict[str, List[Dict[str, Any]]] = collections.defaultdict(list)
    for digest, path, size, dur, codec, container, embedded, _ in rows:
        by[digest].append({
            "path": path, "size_bytes": size, "duration_s": dur or 0.0,
            "codec": codec or "", "container": container or "", "embedded": embedded,
        })
    return by


def allocate_stratified(sizes: Dict[str, int], target: int, floor: int) -> Dict[str, int]:
    """Deterministic allocation of ``target`` draws across strata: every non-empty
    stratum gets min(size, floor); the remainder is spread proportionally to size
    (largest remainder), never exceeding a stratum's size."""
    alloc = {name: min(size, floor) for name, size in sizes.items() if size > 0}
    remaining = target - sum(alloc.values())
    if remaining <= 0:
        return alloc
    room = {name: sizes[name] - alloc[name] for name in alloc}
    total_room = sum(room.values())
    if total_room <= 0:
        return alloc
    shares = {name: remaining * room[name] / total_room for name in alloc}
    whole = {name: min(room[name], int(shares[name])) for name in alloc}
    left = remaining - sum(whole.values())
    for name in sorted(alloc, key=lambda n: (-(shares[n] - int(shares[n])), n)):
        if left <= 0:
            break
        if whole[name] < room[name]:
            whole[name] += 1
            left -= 1
    return {name: alloc[name] + whole[name] for name in alloc}


def build_era_corpus(conn: sqlite3.Connection, seed: int, camera_target: int,
                     exists: Callable[[str], bool] = os.path.exists) -> Tuple[List[ClipEntry], Dict[str, Any]]:
    files = _live_files(conn)
    entries: List[ClipEntry] = []
    report: Dict[str, Any] = {"user_dates_rows": 0, "user_dates_with_value": 0,
                              "user_dates_reachable": 0, "camera_pool": {}, "camera_drawn": {}}
    # --- Rick-dated: every user_dates row with a reachable live video file ---
    rows = conn.execute("SELECT digest, value, confidence FROM user_dates").fetchall()
    report["user_dates_rows"] = len(rows)
    rick_digests = set()
    for digest, value, confidence in sorted(rows):
        if value is None:
            continue
        report["user_dates_with_value"] += 1
        candidates = files.get(digest, [])
        path = _first_reachable([c["path"] for c in candidates], exists)
        if path is None:
            continue
        row = next(c for c in candidates if c["path"] == path)
        year = int(value[:4])
        rick_digests.add(digest)
        report["user_dates_reachable"] += 1
        entries.append(ClipEntry(
            digest=digest, path=path, size_bytes=row["size_bytes"], duration_s=row["duration_s"],
            corpus="era", stratum="rick-dated/{}".format(decade_label(year)),
            truth={"year": year, "source": "user_dates", "confidence": confidence, "value": value},
            codec=codec_class(row["codec"]), container=row["container"]))
    # --- camera-dated: stratified by decade × native codec ---
    pool: Dict[str, List[Tuple[str, Dict[str, Any], int]]] = collections.defaultdict(list)
    for digest in sorted(files):
        if digest in rick_digests:
            continue
        rows_with_stamp = [c for c in files[digest] if c["embedded"] is not None]
        if not rows_with_stamp:
            continue
        row = rows_with_stamp[0]
        if row["codec"] not in CAMERA_NATIVE_CODECS:
            continue
        year = dt.datetime.fromtimestamp(row["embedded"], dt.timezone.utc).year
        if not (YEAR_MIN <= year <= YEAR_MAX):
            continue
        stratum = "camera/{}/{}".format(decade_label(year), codec_class(row["codec"]))
        pool[stratum].append((digest, row, year))
    sizes = {name: len(items) for name, items in pool.items()}
    report["camera_pool"] = dict(sorted(sizes.items()))
    alloc = allocate_stratified(sizes, camera_target, STRATUM_FLOOR)
    rng = random.Random(seed)
    for stratum in sorted(alloc):
        items = sorted(pool[stratum], key=lambda item: item[0])
        rng.shuffle(items)
        drawn = 0
        for digest, row, year in items:
            if drawn >= alloc[stratum]:
                break
            path = _first_reachable([c["path"] for c in files[digest] if c["embedded"] is not None], exists)
            if path is None:
                continue
            drawn += 1
            entries.append(ClipEntry(
                digest=digest, path=path, size_bytes=row["size_bytes"], duration_s=row["duration_s"],
                corpus="era", stratum=stratum,
                truth={"year": year, "source": "files.embedded_created_at", "confidence": "camera"},
                codec=codec_class(row["codec"]), container=row["container"]))
        report["camera_drawn"][stratum] = drawn
    return entries, report


_RE_ONSCREEN = re.compile(r"on-screen date (\d{4}-\d{2}-\d{2})")


def ocr_truth_for(reason: Optional[str], caption_texts: Sequence[str]) -> Optional[Tuple[str, str]]:
    """The catalog's OCR verdict for one digest: the triangulator's 'on-screen date'
    when its reason names one, else the majority parsed date of the existing ocrDate
    captions (the catalog's own OCR channel).  None → no OCR verdict → not in corpus."""
    if reason:
        match = _RE_ONSCREEN.search(reason)
        if match:
            return match.group(1), "inferred_dates.reason:on-screen"
    votes: collections.Counter = collections.Counter()
    for text in caption_texts:
        for iso in parse_dates(text):
            votes[iso] += 1
    if votes:
        top = max(votes.values())
        return sorted(d for d, n in votes.items() if n == top)[0], "captions.ocrDate:majority"
    return None


def build_ocr_corpus(conn: sqlite3.Connection, seed: int, target: int,
                     exists: Callable[[str], bool] = os.path.exists) -> Tuple[List[ClipEntry], Dict[str, Any]]:
    files = _live_files(conn)
    rows = conn.execute(
        "SELECT i.digest, i.date_at, i.reason FROM inferred_dates i "
        "WHERE i.date_at IS NOT NULL AND EXISTS "
        "(SELECT 1 FROM captions c WHERE c.digest = i.digest AND c.kind = 'ocrDate')").fetchall()
    report: Dict[str, Any] = {"ocr_with_verdict_rows": len(rows), "with_ocr_truth": 0,
                              "truth_sources": {}, "drawn": 0}
    candidates: List[ClipEntry] = []
    for digest, date_at, reason in sorted(rows):
        texts = [t for (t,) in conn.execute(
            "SELECT text FROM captions WHERE digest = ? AND kind = 'ocrDate' ORDER BY seq", (digest,))]
        truth = ocr_truth_for(reason, texts)
        if truth is None:
            continue
        path = _first_reachable([c["path"] for c in files.get(digest, [])], exists)
        if path is None:
            continue
        row = next(c for c in files[digest] if c["path"] == path)
        report["with_ocr_truth"] += 1
        iso, source = truth
        verdict_year = dt.datetime.fromtimestamp(date_at, dt.timezone.utc).year
        candidates.append(ClipEntry(
            digest=digest, path=path, size_bytes=row["size_bytes"], duration_s=row["duration_s"],
            corpus="ocr", stratum="ocr/{}".format(codec_class(row["codec"])),
            truth={"date": iso, "source": source, "verdict_year": verdict_year},
            codec=codec_class(row["codec"]), container=row["container"]))
    # Prefer the triangulator's own on-screen verdicts; fill from the majority set.
    strong = [c for c in candidates if c.truth["source"].endswith("on-screen")]
    weak = [c for c in candidates if not c.truth["source"].endswith("on-screen")]
    rng = random.Random(seed)
    rng.shuffle(strong)
    rng.shuffle(weak)
    chosen = (strong + weak)[:target]
    report["drawn"] = len(chosen)
    report["truth_sources"] = dict(collections.Counter(c.truth["source"] for c in chosen))
    return chosen, report


def corpus_hash(entries: Sequence[ClipEntry]) -> str:
    """Path-independent identity of a corpus: sorted (digest, corpus, stratum, truth)."""
    rows = sorted((e.digest, e.corpus, e.stratum, json.dumps(e.truth, sort_keys=True)) for e in entries)
    return sha256_json(rows)


def build_manifest(catalog_copy: Path, seed: int = DEFAULT_SEED,
                   camera_target: int = ERA_CAMERA_TARGET, ocr_target: int = OCR_TARGET,
                   exists: Callable[[str], bool] = os.path.exists) -> Dict[str, Any]:
    conn = open_readonly(catalog_copy)
    try:
        era, era_report = build_era_corpus(conn, seed, camera_target, exists)
        ocr, ocr_report = build_ocr_corpus(conn, seed, ocr_target, exists)
    finally:
        conn.close()
    entries = era + ocr
    strata = collections.Counter(e.stratum for e in entries)
    return {
        "record_type": "manifest",
        "schema_version": MANIFEST_SCHEMA,
        "created_at": utc_now(),
        "seed": seed,
        "catalog_copy": str(Path(catalog_copy).resolve()),
        "catalog_copy_sha256": sha256_file(catalog_copy),
        "bench_source_sha256": sha256_file(Path(__file__).resolve()),
        "git_sha": git_sha(),
        "host": socket.gethostname(),
        "corpus_hash": corpus_hash(entries),
        "era_corpus_hash": corpus_hash(era),
        "ocr_corpus_hash": corpus_hash(ocr),
        "counts": {"era": len(era), "ocr": len(ocr), "strata": dict(sorted(strata.items()))},
        "era_report": era_report,
        "ocr_report": ocr_report,
        "clips": [e.to_dict() for e in entries],
    }


def load_manifest(path: Path) -> Dict[str, Any]:
    manifest = json.loads(Path(path).read_text(encoding="utf-8"))
    if manifest.get("record_type") != "manifest" or manifest.get("schema_version") != MANIFEST_SCHEMA:
        raise ValueError("not a video-llm-bench manifest (schema {}): {}".format(MANIFEST_SCHEMA, path))
    return manifest


def format_manifest_report(manifest: Dict[str, Any]) -> str:
    lines = ["ERA corpus: {} clips   OCR corpus: {} clips".format(
        manifest["counts"]["era"], manifest["counts"]["ocr"])]
    era = manifest["era_report"]
    lines.append("  user_dates rows {} · with value {} · reachable video {}".format(
        era["user_dates_rows"], era["user_dates_with_value"], era["user_dates_reachable"]))
    lines.append("  stratum                          drawn / pool")
    for stratum, count in sorted(manifest["counts"]["strata"].items()):
        pool = era["camera_pool"].get(stratum)
        lines.append("  {:<32} {:>5} / {}".format(stratum, count, pool if pool is not None else "-"))
    ocr = manifest["ocr_report"]
    lines.append("  OCR: {} digests with ocrDate caption + verdict · {} with an OCR truth · drawn {} · sources {}".format(
        ocr["ocr_with_verdict_rows"], ocr["with_ocr_truth"], ocr["drawn"], ocr["truth_sources"]))
    lines.append("  corpus hash {}".format(manifest["corpus_hash"]))
    return "\n".join(lines)


def validate_corpus_command(args: argparse.Namespace) -> int:
    catalog = Path(args.catalog)
    if not catalog.is_file():
        raise SystemExit("catalog copy not found: {}".format(catalog))
    live = Path.home() / "Library" / "Application Support" / "VideoScan" / "catalog.sqlite"
    if catalog.resolve() == live.resolve():
        raise SystemExit("refusing to open the live catalog; pass a .backup copy")
    manifest = build_manifest(catalog, seed=args.seed, camera_target=args.camera_target,
                              ocr_target=args.ocr_target)
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(manifest, indent=1, sort_keys=True), encoding="utf-8")
    print(format_manifest_report(manifest))
    print("manifest: {}".format(out))
    return 0


# ---------------------------------------------------------------------------
# Sampler and frame ripping
# ---------------------------------------------------------------------------
def frames_evenly_spaced(frames_per_file: int, duration_s: float) -> List[float]:
    """Same as `framesEvenlySpaced` in CaptionOrchestrator.swift: N timestamps across
    the middle 90 % (skip the first and last 5 %)."""
    if frames_per_file <= 0 or duration_s <= 0:
        return []
    safe = max(0.1, duration_s)
    lo, hi = safe * 0.05, safe * 0.95
    if frames_per_file == 1:
        return [(lo + hi) / 2.0]
    stride = (hi - lo) / (frames_per_file - 1)
    return [lo + i * stride for i in range(frames_per_file)]


def probe_duration(path: str) -> float:
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "default=nokey=1:noprint_wrappers=1", path],
        capture_output=True, text=True, timeout=60, check=False)
    try:
        return float(out.stdout.strip())
    except ValueError:
        return 0.0


def rip_frame(path: str, at_s: float, dest: Path, duration_s: float) -> bool:
    """One still, letterboxed into 448×448 (aspect kept, black bars) — the shape the
    app hands the model (`processing.resize = 448×448`).  Input-seek (-ss before -i),
    one frame, PNG.  Returns False when ffmpeg cannot decode that instant."""
    clamped = max(0.0, min(at_s, max(0.0, duration_s - 0.05)))
    vf = ("scale={s}:{s}:force_original_aspect_ratio=decrease,"
          "pad={s}:{s}:(ow-iw)/2:(oh-ih)/2:color=black").format(s=FRAME_SIDE)
    result = subprocess.run(
        ["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-ss", "{:.3f}".format(clamped),
         "-i", path, "-frames:v", "1", "-vf", vf, str(dest)],
        capture_output=True, text=True, timeout=300, check=False)
    return result.returncode == 0 and dest.is_file() and dest.stat().st_size > 0


def ffmpeg_version() -> Optional[str]:
    try:
        out = subprocess.run(["ffmpeg", "-version"], capture_output=True, text=True, timeout=10, check=False)
    except (OSError, subprocess.SubprocessError):
        return None
    first = out.stdout.splitlines()[0] if out.stdout else ""
    return first.strip() or None


# ---------------------------------------------------------------------------
# Approach A0 in Python: Qwen2.5-VL-3B-Instruct-4bit through mlx-vlm
# ---------------------------------------------------------------------------
class Approach:
    """Abstract: one model + host + prompt family.  `load()` once, `answer()` per
    (frame, prompt).  Subclasses must set `id`."""
    id = "abstract"

    def load(self) -> Dict[str, Any]:
        raise NotImplementedError

    def answer(self, image_path: Path, prompt_kind: str) -> Tuple[str, Dict[str, Any]]:
        raise NotImplementedError

    def seed(self, value: int) -> None:
        pass

    def after_clip(self) -> None:
        pass


def weights_digest(model_dir: Path) -> Tuple[str, int]:
    """sha256 over the sorted (name, sha256) of every *.safetensors file — one
    digest for the weights as loaded.  Reads ≈ 2.4 GB once per run."""
    rows = []
    total = 0
    for file in sorted(Path(model_dir).glob("*.safetensors")):
        rows.append((file.name, sha256_file(file)))
        total += file.stat().st_size
    if not rows:
        raise RuntimeError("no safetensors under {}".format(model_dir))
    return sha256_json(rows), total


class A0Python(Approach):
    id = APPROACH_ID

    def __init__(self, model_id: str = MODEL_ID, model_dir: Optional[Path] = None):
        self.model_id = model_id
        self.model_dir_override = Path(model_dir) if model_dir else None   # offline: a local snapshot of MODEL_ID
        self.model = None
        self.processor = None
        self.config = None

    def load(self) -> Dict[str, Any]:
        import mlx.core as mx
        import mlx_vlm
        import transformers
        from huggingface_hub import snapshot_download
        from mlx_vlm import load

        started = time.perf_counter()
        if self.model_dir_override is not None:
            model_dir = self.model_dir_override
            if not (model_dir / "config.json").is_file():
                raise RuntimeError("--model-dir has no config.json: {}".format(model_dir))
        else:
            model_dir = Path(snapshot_download(self.model_id))
        digest, size = weights_digest(model_dir)
        mx.set_cache_limit(MLX_CACHE_LIMIT_BYTES)
        self.model, self.processor = load(str(model_dir))
        self.config = getattr(self.model, "config", None)
        return {
            "model": self.model_id,
            "model_dir": str(model_dir),
            "weights_sha256": digest,
            "weights_bytes": size,
            "load_s": round(time.perf_counter() - started, 3),
            "mlx_vlm_version": getattr(mlx_vlm, "__version__", None),
            "mlx_version": _dist_version("mlx"),
            "transformers_version": transformers.__version__,
        }

    def seed(self, value: int) -> None:
        import mlx.core as mx
        mx.random.seed(value)

    def after_clip(self) -> None:
        import mlx.core as mx
        mx.clear_cache()

    def answer(self, image_path: Path, prompt_kind: str) -> Tuple[str, Dict[str, Any]]:
        from mlx_vlm import generate
        from mlx_vlm.prompt_utils import apply_chat_template

        messages = [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": PROMPTS[prompt_kind]},
        ]
        templated = apply_chat_template(self.processor, self.config, messages, num_images=1)
        params = GEN_PARAMS[prompt_kind]
        result = generate(self.model, self.processor, templated, image=[str(image_path)],
                          max_tokens=params["max_tokens"], temperature=params["temperature"],
                          top_p=params["top_p"], verbose=False)
        text = result if isinstance(result, str) else getattr(result, "text", str(result))
        counters = {}
        for name in ("prompt_tokens", "generation_tokens", "generation_tps", "peak_memory"):
            value = getattr(result, name, None)
            if value is not None:
                counters[name] = value
        return text.strip(), counters


def _dist_version(name: str) -> Optional[str]:
    try:
        from importlib.metadata import version
        return version(name)
    except Exception:  # noqa: BLE001 — version is informational
        return None


def peak_rss_bytes() -> int:
    import resource
    return int(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)  # bytes on macOS


# ---------------------------------------------------------------------------
# The run loop (testable: approach and ripper are injected)
# ---------------------------------------------------------------------------
def clip_file(out_dir: Path, digest: str) -> Path:
    return Path(out_dir) / "clips" / "{}.jsonl".format(digest)


def clip_is_done(path: Path) -> bool:
    """A clip counts as done only when its JSONL ends with a clip_done record —
    a crash mid-clip leaves a partial file that is redone, never trusted."""
    if not path.is_file():
        return False
    try:
        with path.open("rb") as stream:
            stream.seek(0, os.SEEK_END)
            size = stream.tell()
            stream.seek(max(0, size - 4096))
            tail = stream.read().decode("utf-8", errors="replace").strip().splitlines()
    except OSError:
        return False
    if not tail:
        return False
    try:
        return json.loads(tail[-1]).get("record_type") == "clip_done"
    except json.JSONDecodeError:
        return False


def write_json(path: Path, value: Dict[str, Any]) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(value, indent=1, sort_keys=True), encoding="utf-8")
    os.replace(tmp, path)


def default_ripper(path: str, at_s: float, dest: Path, duration_s: float) -> bool:
    return rip_frame(path, at_s, dest, duration_s)


def run_corpus(entries: Sequence[Dict[str, Any]], out_dir: Path, approach: Approach,
               frames: int, run_record: Dict[str, Any],
               ripper: Callable[[str, float, Path, float], bool] = default_ripper,
               duration_of: Callable[[str, float], float] = lambda p, d: d if d > 0 else probe_duration(p),
               log: Callable[[str], None] = lambda s: print(s, flush=True)) -> Dict[str, Any]:
    out_dir = Path(out_dir)
    (out_dir / "clips").mkdir(parents=True, exist_ok=True)
    progress_path = out_dir / "progress.json"
    done = skipped = failed = frames_done = 0
    gen_seconds = 0.0
    started = time.perf_counter()
    progress: Dict[str, Any] = {
        "run_id": run_record.get("run_id"), "total_clips": len(entries), "done": 0,
        "skipped_resume": 0, "failed": 0, "frames_done": 0, "s_per_frame": None,
        "started_at": utc_now(), "updated_at": utc_now(), "state": "running",
    }
    write_json(progress_path, progress)
    tmp_root = Path(tempfile.mkdtemp(prefix="video-llm-bench-frames-"))
    try:
        for index, entry in enumerate(entries, 1):
            digest = entry["digest"]
            target = clip_file(out_dir, digest)
            if clip_is_done(target):
                skipped += 1
                progress.update(skipped_resume=skipped, updated_at=utc_now())
                write_json(progress_path, progress)
                continue
            clip_tmp = tmp_root / digest[:16]
            clip_tmp.mkdir(parents=True, exist_ok=True)
            clip_started = time.perf_counter()
            approach.seed(MLX_SEED)
            duration = duration_of(entry["path"], float(entry.get("duration_s") or 0.0))
            timestamps = frames_evenly_spaced(frames, duration)
            rip_failures = 0
            records_written = 0
            with target.open("w", encoding="utf-8") as stream:
                header = {
                    "record_type": "clip", "digest": digest, "corpus": entry["corpus"],
                    "stratum": entry["stratum"], "truth": entry["truth"], "duration_s": duration,
                    "frames_requested": len(timestamps), "run_id": run_record.get("run_id"),
                }
                stream.write(json.dumps(header, sort_keys=True) + "\n")
                for frame_index, at_s in enumerate(timestamps):
                    png = clip_tmp / "frame_{:03d}.png".format(frame_index)
                    rip_started = time.perf_counter()
                    ok = ripper(entry["path"], at_s, png, duration)
                    rip_s = time.perf_counter() - rip_started
                    if not ok:
                        rip_failures += 1
                        stream.write(json.dumps({
                            "record_type": "frame_failed", "digest": digest, "frame_index": frame_index,
                            "at_s": round(at_s, 3), "rip_s": round(rip_s, 3)}, sort_keys=True) + "\n")
                        continue
                    for kind in PROMPT_ORDER:
                        gen_started = time.perf_counter()
                        error = None
                        try:
                            text, counters = approach.answer(png, kind)
                        except Exception as exc:  # noqa: BLE001 — one bad frame never ends the run
                            text, counters, error = "", {}, "{}: {}".format(type(exc).__name__, exc)
                        elapsed = time.perf_counter() - gen_started
                        gen_seconds += elapsed
                        record = {
                            "record_type": "result", "digest": digest, "frame_index": frame_index,
                            "at_s": round(at_s, 3), "prompt_kind": kind,
                            "prompt_sha256": sha256_text(PROMPTS[kind]), "raw_text": text,
                            "elapsed_s": round(elapsed, 3), "rip_s": round(rip_s, 3),
                            "error": error, "counters": counters,
                            "parsed": {
                                "dates": parse_dates(text), "years": parse_years(text),
                                "decades": parse_decades(text), "degenerate": is_degenerate(text),
                            },
                        }
                        stream.write(json.dumps(record, sort_keys=True) + "\n")
                        stream.flush()
                        records_written += 1
                    png.unlink(missing_ok=True)
                    frames_done += 1
                clip_elapsed = time.perf_counter() - clip_started
                stream.write(json.dumps({
                    "record_type": "clip_done", "digest": digest, "frames_ok": len(timestamps) - rip_failures,
                    "frames_failed": rip_failures, "results": records_written,
                    "clip_s": round(clip_elapsed, 3), "peak_rss_bytes": peak_rss_bytes(),
                    "best_year": None, "finished_at": utc_now()}, sort_keys=True) + "\n")
            shutil.rmtree(clip_tmp, ignore_errors=True)
            approach.after_clip()
            if records_written == 0:
                failed += 1
            done += 1
            progress.update(
                done=done, failed=failed, frames_done=frames_done, updated_at=utc_now(),
                s_per_frame=round(gen_seconds / frames_done, 3) if frames_done else None,
                elapsed_s=round(time.perf_counter() - started, 1), last_stratum=entry["stratum"],
                peak_rss_bytes=peak_rss_bytes())
            write_json(progress_path, progress)
            log("[{}/{}] {} frames={} {:.1f}s stratum={}".format(
                index, len(entries), digest[:12], len(timestamps) - rip_failures, clip_elapsed, entry["stratum"]))
    finally:
        shutil.rmtree(tmp_root, ignore_errors=True)
    progress.update(state="finished", updated_at=utc_now(), finished_at=utc_now())
    write_json(progress_path, progress)
    return progress


def build_run_record(manifest: Dict[str, Any], manifest_path: Path, approach: Approach,
                     load_info: Dict[str, Any], frames: int, limit: Optional[int],
                     corpus_filter: Optional[str], run_id: str) -> Dict[str, Any]:
    return {
        "record_type": "run",
        "schema_version": RUN_SCHEMA,
        "run_id": run_id,
        "started_at": utc_now(),
        "approach_id": approach.id,
        "sampler_id": SAMPLER_ID_TEMPLATE.format(n=frames),
        "frames_per_clip": frames,
        "frame_side_px": FRAME_SIDE,
        "frame_letterbox": "scale to fit, pad black",
        "prompts_sha256": {kind: sha256_text(PROMPTS[kind]) for kind in PROMPT_ORDER},
        "system_prompt_sha256": sha256_text(SYSTEM_PROMPT),
        "gen_params": GEN_PARAMS,
        "mlx_seed": MLX_SEED,
        "manifest_path": str(Path(manifest_path).resolve()),
        "manifest_seed": manifest.get("seed"),
        "corpus_hash": manifest.get("corpus_hash"),
        "era_corpus_hash": manifest.get("era_corpus_hash"),
        "ocr_corpus_hash": manifest.get("ocr_corpus_hash"),
        "corpus_filter": corpus_filter,
        "limit": limit,
        "host": socket.gethostname(),
        "platform": platform.platform(),
        "python": platform.python_version(),
        "ffmpeg": ffmpeg_version(),
        "git_sha": git_sha(),
        "bench_source_sha256": sha256_file(Path(__file__).resolve()),
        **load_info,
    }


def run_command(args: argparse.Namespace) -> int:
    manifest_path = Path(args.manifest)
    manifest = load_manifest(manifest_path)
    entries = list(manifest["clips"])
    if args.corpus:
        entries = [e for e in entries if e["corpus"] == args.corpus]
    if args.limit is not None:
        entries = entries[:args.limit]
    if not entries:
        raise SystemExit("no clips selected")
    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    if args.approach != APPROACH_ID:
        raise SystemExit("unknown approach {}".format(args.approach))
    run_path = out_dir / "run.json"
    if run_path.is_file():
        previous = json.loads(run_path.read_text(encoding="utf-8"))
        if previous.get("corpus_hash") != manifest.get("corpus_hash"):
            raise SystemExit("run dir belongs to another corpus ({} ≠ {})".format(
                previous.get("corpus_hash"), manifest.get("corpus_hash")))
        if previous.get("frames_per_clip") != args.frames:
            raise SystemExit("run dir was started with --frames {}".format(previous.get("frames_per_clip")))
        run_id = previous["run_id"]
    else:
        run_id = "{}-{}".format(dt.datetime.now().strftime("%Y%m%dT%H%M%S"), APPROACH_ID)
    approach = A0Python(model_dir=args.model_dir)
    print("loading {} …".format(MODEL_ID), flush=True)
    load_info = approach.load()
    print("loaded in {:.1f}s; weights sha256 {}".format(load_info["load_s"], load_info["weights_sha256"][:12]), flush=True)
    record = build_run_record(manifest, manifest_path, approach, load_info, args.frames,
                              args.limit, args.corpus, run_id)
    if run_path.is_file():
        # Resume: keep the first run record, append this session's load timing.
        previous = json.loads(run_path.read_text(encoding="utf-8"))
        previous.setdefault("resumed", []).append({"at": utc_now(), "load_s": load_info["load_s"]})
        write_json(run_path, previous)
    else:
        write_json(run_path, record)
    progress = run_corpus(entries, out_dir, approach, args.frames, record)
    print("done {} skipped {} failed {} s/frame {}".format(
        progress["done"], progress["skipped_resume"], progress["failed"], progress["s_per_frame"]))
    return 0


# ---------------------------------------------------------------------------
# Summarize (aggregates only)
# ---------------------------------------------------------------------------
def read_clip_results(path: Path) -> Tuple[Optional[Dict[str, Any]], List[Dict[str, Any]], Optional[Dict[str, Any]]]:
    header = footer = None
    results: List[Dict[str, Any]] = []
    with Path(path).open(encoding="utf-8") as stream:
        for line in stream:
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue  # a corrupt line never crashes a summary
            kind = record.get("record_type")
            if kind == "clip":
                header = record
            elif kind == "result":
                results.append(record)
            elif kind == "clip_done":
                footer = record
    return header, results, footer


def _rate(num: int, den: int) -> Optional[float]:
    return (num / den) if den else None


def score_era_clip(truth_year: int, results: Sequence[Dict[str, Any]]) -> Dict[str, Any]:
    year = best_year(results)
    return {"truth": truth_year, "guess": year,
            "abs_err": abs(year - truth_year) if year is not None else None}


def score_ocr_clip(truth_date: str, results: Sequence[Dict[str, Any]]) -> Dict[str, Any]:
    date_results = [r for r in results if r.get("prompt_kind") == "date"]
    dates_per_frame = [parse_dates(r.get("raw_text") or "") for r in date_results]
    frames_with_date = sum(1 for d in dates_per_frame if d)
    degenerate = sum(1 for r in date_results if is_degenerate(r.get("raw_text") or ""))
    all_dates = collections.Counter(d for ds in dates_per_frame for d in ds)
    majority = None
    if all_dates:
        top = max(all_dates.values())
        majority = sorted(d for d, n in all_dates.items() if n == top)[0]
    return {
        "truth": truth_date,
        "date_frames": len(date_results),
        "frames_with_date": frames_with_date,
        "degenerate_frames": degenerate,
        "any_exact": truth_date in all_dates,
        "majority": majority,
        "majority_exact": majority == truth_date,
        "year_match": majority is not None and majority[:4] == truth_date[:4],
        "schema_valid": frames_with_date > 0,
    }


def aggregate_era(rows: Sequence[Dict[str, Any]]) -> Dict[str, Any]:
    answered = [r for r in rows if r["abs_err"] is not None]
    within = sum(1 for r in answered if r["abs_err"] <= 5)
    return {
        "n": len(rows),
        "answered": len(answered),
        "no_answer_rate": _rate(len(rows) - len(answered), len(rows)),
        "mae_years": (statistics.fmean(r["abs_err"] for r in answered) if answered else None),
        "median_err_years": (statistics.median(r["abs_err"] for r in answered) if answered else None),
        "within_5_of_answered": _rate(within, len(answered)),
        "within_5_of_all": _rate(within, len(rows)),
    }


def aggregate_ocr(rows: Sequence[Dict[str, Any]]) -> Dict[str, Any]:
    frames = sum(r["date_frames"] for r in rows)
    return {
        "n": len(rows),
        "any_frame_exact": _rate(sum(1 for r in rows if r["any_exact"]), len(rows)),
        "majority_exact": _rate(sum(1 for r in rows if r["majority_exact"]), len(rows)),
        "year_match": _rate(sum(1 for r in rows if r["year_match"]), len(rows)),
        "schema_valid": _rate(sum(1 for r in rows if r["schema_valid"]), len(rows)),
        "date_frames": frames,
        "frames_with_date_rate": _rate(sum(r["frames_with_date"] for r in rows), frames),
        "degenerate_frame_rate": _rate(sum(r["degenerate_frames"] for r in rows), frames),
    }


def summarize_run(run_dir: Path, manifest: Dict[str, Any]) -> Dict[str, Any]:
    run_dir = Path(run_dir)
    run_record = json.loads((run_dir / "run.json").read_text(encoding="utf-8")) if (run_dir / "run.json").is_file() else {}
    progress = json.loads((run_dir / "progress.json").read_text(encoding="utf-8")) if (run_dir / "progress.json").is_file() else {}
    # A digest may sit in both corpora (an OCR clip Rick also dated); the clip file is
    # keyed by digest and is scored once per manifest entry that names it.
    by_digest: Dict[str, List[Dict[str, Any]]] = collections.defaultdict(list)
    for clip in manifest["clips"]:
        by_digest[clip["digest"]].append(clip)
    era_rows: List[Tuple[str, Dict[str, Any]]] = []
    ocr_rows: List[Tuple[str, Dict[str, Any]]] = []
    frame_count = 0
    gen_seconds = 0.0
    rip_seconds = 0.0
    result_count = 0
    errors = 0
    peak_rss = 0
    clips_done = clips_partial = clips_unreadable = 0
    for path in sorted((run_dir / "clips").glob("*.jsonl")) if (run_dir / "clips").is_dir() else []:
        header, results, footer = read_clip_results(path)
        if header is None:
            continue
        entries_for = by_digest.get(header["digest"])
        if not entries_for:
            continue
        if footer is None:
            clips_partial += 1
        else:
            clips_done += 1
            peak_rss = max(peak_rss, int(footer.get("peak_rss_bytes") or 0))
        if not results:
            # No frame could be decoded (e.g. an iMovie reference movie whose media
            # lives on an unmounted volume): nothing any approach could see, so it is
            # counted here and excluded from the tables — not scored as "no answer".
            clips_unreadable += 1
            continue
        frames_seen = {r["frame_index"] for r in results}
        frame_count += len(frames_seen)
        for r in results:
            gen_seconds += float(r.get("elapsed_s") or 0.0)
            result_count += 1
            errors += 1 if r.get("error") else 0
        rip_seconds += sum(float(r.get("rip_s") or 0.0) for r in results if r.get("prompt_kind") == "date")
        for entry in entries_for:
            if entry["corpus"] == "era":
                era_rows.append((entry["stratum"], score_era_clip(int(entry["truth"]["year"]), results)))
            elif entry["corpus"] == "ocr":
                ocr_rows.append((entry["stratum"], score_ocr_clip(entry["truth"]["date"], results)))

    def grouped(rows: Sequence[Tuple[str, Dict[str, Any]]], key: Callable[[str], str],
                agg: Callable[[Sequence[Dict[str, Any]]], Dict[str, Any]]) -> Dict[str, Dict[str, Any]]:
        groups: Dict[str, List[Dict[str, Any]]] = collections.defaultdict(list)
        for stratum, row in rows:
            groups[key(stratum)].append(row)
        return {name: agg(items) for name, items in sorted(groups.items())}

    def decade_of(stratum: str) -> str:
        parts = stratum.split("/")
        return parts[1] if len(parts) > 1 else stratum

    def family_of(stratum: str) -> str:
        return stratum.split("/")[0]

    era_all = [row for _, row in era_rows]
    ocr_all = [row for _, row in ocr_rows]
    return {
        "record_type": "summary",
        "schema_version": RUN_SCHEMA,
        "generated_at": utc_now(),
        "approach_id": run_record.get("approach_id", APPROACH_ID),
        "run_id": run_record.get("run_id"),
        "model": run_record.get("model"),
        "weights_sha256": run_record.get("weights_sha256"),
        "sampler_id": run_record.get("sampler_id"),
        "frames_per_clip": run_record.get("frames_per_clip"),
        "host": run_record.get("host"),
        "platform": run_record.get("platform"),
        "mlx_vlm_version": run_record.get("mlx_vlm_version"),
        "mlx_version": run_record.get("mlx_version"),
        "git_sha": run_record.get("git_sha"),
        "corpus_hash": run_record.get("corpus_hash") or manifest.get("corpus_hash"),
        "prompts_sha256": run_record.get("prompts_sha256"),
        "load_s": run_record.get("load_s"),
        "run_state": progress.get("state", "unknown"),
        "clips": {"done": clips_done, "partial": clips_partial, "unreadable": clips_unreadable,
                  "era_scored": len(era_rows), "ocr_scored": len(ocr_rows),
                  "era_in_manifest": manifest["counts"]["era"], "ocr_in_manifest": manifest["counts"]["ocr"]},
        "cost": {
            "frames": frame_count, "results": result_count, "errors": errors,
            "s_per_frame_all_prompts": _rate(gen_seconds, frame_count) if frame_count else None,
            "s_per_generation": _rate(gen_seconds, result_count) if result_count else None,
            "rip_s_per_frame": _rate(rip_seconds, frame_count) if frame_count else None,
            "peak_rss_gb": round(peak_rss / 1e9, 2) if peak_rss else None,
        },
        "era": {
            "all": aggregate_era(era_all),
            "by_family": grouped(era_rows, family_of, aggregate_era),
            "by_decade": grouped(era_rows, decade_of, aggregate_era),
            "by_stratum": grouped(era_rows, lambda s: s, aggregate_era),
        },
        "ocr": {
            "all": aggregate_ocr(ocr_all),
            "by_stratum": grouped(ocr_rows, lambda s: s, aggregate_ocr),
        },
    }


def _pct(value: Optional[float]) -> str:
    return "—" if value is None else "{:.0%}".format(value)


def _num(value: Optional[float], fmt: str = "{:.1f}") -> str:
    return "—" if value is None else fmt.format(value)


def _short(digest: Optional[str]) -> str:
    return (digest or "")[:12] or "—"


def format_summary_markdown(summary: Dict[str, Any]) -> str:
    """Aggregates only.  Never a path, never a content digest, never model text.
    Hashes that identify the run (weights, corpus) are shown as 12 hex chars."""
    lines: List[str] = []
    lines.append("# Video LLM benchmarks")
    lines.append("")
    lines.append("*Written by `tools/video-llm-bench/bench.py summarize`; overwritten on every run, never appended "
                 "(CLAUDE.md). Aggregates only — per-clip results stay in `.scratch/` (DECISIONS 2026-10-26). "
                 "Design: `docs/design/video_llm_lab_2026_10_30.md` §4.*")
    lines.append("")
    lines.append("## Approach `{}` — baseline (today's 3B captioner, stills, the three app prompts)".format(summary["approach_id"]))
    lines.append("")
    clips = summary["clips"]
    cost = summary["cost"]
    lines.append("| Run | Value |")
    lines.append("|---|---|")
    lines.append("| generated | {} |".format(summary["generated_at"]))
    lines.append("| run id | {} |".format(summary.get("run_id") or "—"))
    lines.append("| model | `{}` |".format(summary.get("model") or "—"))
    lines.append("| weights sha256 (first 12) | `{}` |".format(_short(summary.get("weights_sha256"))))
    lines.append("| sampler | `{}` ({} frames/clip, 448×448 letterboxed, middle 90 %) |".format(
        summary.get("sampler_id") or "—", summary.get("frames_per_clip") or "—"))
    lines.append("| prompts | date/scene/text as in `CaptionRunner.swift`; sha256 first 12: {} |".format(
        ", ".join("{} `{}`".format(k, _short(v)) for k, v in (summary.get("prompts_sha256") or {}).items()) or "—"))
    lines.append("| host | {} · {} |".format(summary.get("host") or "—", summary.get("platform") or "—"))
    lines.append("| mlx-vlm / mlx | {} / {} |".format(summary.get("mlx_vlm_version") or "—", summary.get("mlx_version") or "—"))
    lines.append("| git | `{}` |".format(_short(summary.get("git_sha"))))
    lines.append("| corpus hash (first 12) | `{}` |".format(_short(summary.get("corpus_hash"))))
    lines.append("| run state | {} |".format(summary.get("run_state", "unknown")))
    lines.append("| clips | {} done · {} partial · {} unreadable · ERA scored {}/{} · OCR scored {}/{} |".format(
        clips["done"], clips["partial"], clips["unreadable"], clips["era_scored"], clips["era_in_manifest"],
        clips["ocr_scored"], clips["ocr_in_manifest"]))
    if clips["unreadable"]:
        lines.append("")
        lines.append("*unreadable* = no frame could be decoded by ffmpeg (QuickTime reference movies whose media is on an "
                     "unmounted volume, zero-length files); nothing any approach could see, so they are excluded from "
                     "the tables rather than scored as \"no answer\".")
    if clips["era_scored"] + clips["ocr_scored"] + clips["unreadable"] < clips["era_in_manifest"] + clips["ocr_in_manifest"]:
        lines.append("")
        lines.append("**Partial run:** the tables below cover only the clips scored so far; rerun `run` with the same "
                     "`--out` to continue (resume-safe), then `summarize` again.")
    lines.append("")
    lines.append("### Cost")
    lines.append("")
    lines.append("| Metric | Value |")
    lines.append("|---|---|")
    lines.append("| model load | {} s |".format(_num(summary.get("load_s"))))
    lines.append("| s / frame (3 prompts) | {} |".format(_num(cost["s_per_frame_all_prompts"], "{:.2f}")))
    lines.append("| s / generation | {} |".format(_num(cost["s_per_generation"], "{:.2f}")))
    lines.append("| ffmpeg rip s / frame | {} |".format(_num(cost["rip_s_per_frame"], "{:.2f}")))
    lines.append("| peak RSS | {} GB |".format(_num(cost["peak_rss_gb"], "{:.2f}")))
    lines.append("| frames · generations · errors | {} · {} · {} |".format(cost["frames"], cost["results"], cost["errors"]))
    lines.append("")
    lines.append("### ERA — best single year vs truth")
    lines.append("")
    lines.append("Rule: the year of every parsed calendar date in the date/text answers counts 3; every explicit "
                 "4-digit year in any answer counts 1; a decade mention (\"1990s\" → 1995, early/mid/late → +2/+5/+7) "
                 "counts 1; the heaviest year wins (tie → median). A clip whose answers yield no year is **no answer** "
                 "and is excluded from MAE; its rate is reported, not invented. Truth: `user_dates` (Rick) or "
                 "`files.embedded_created_at` for camera-native codecs only (ProRes/FFV1/DNxHD stamps are transfers).")
    lines.append("")
    lines.append("| Group | n | answered | no answer | MAE y | median y | ±5 y (answered) | ±5 y (all) |")
    lines.append("|---|---|---|---|---|---|---|---|")

    def era_row(name: str, agg: Dict[str, Any]) -> str:
        return "| {} | {} | {} | {} | {} | {} | {} | {} |".format(
            name, agg["n"], agg["answered"], _pct(agg["no_answer_rate"]), _num(agg["mae_years"]),
            _num(agg["median_err_years"]), _pct(agg["within_5_of_answered"]), _pct(agg["within_5_of_all"]))

    era = summary["era"]
    lines.append(era_row("**all**", era["all"]))
    for name, agg in era["by_family"].items():
        lines.append(era_row("family: {}".format(name), agg))
    for name, agg in era["by_decade"].items():
        lines.append(era_row("decade: {}".format(name), agg))
    for name, agg in era["by_stratum"].items():
        lines.append(era_row("stratum: {}".format(name), agg))
    lines.append("")
    lines.append("### OCR — burned-in date vs the catalog's verdict")
    lines.append("")
    lines.append("Truth: the `DateTriangulator` on-screen date in `inferred_dates.reason` when present, else the "
                 "majority parsed date of the catalog's existing `ocrDate` captions. *any-frame exact*: some frame's "
                 "date answer parses to the truth date. *majority exact*: the most frequent parsed date equals it. "
                 "*schema-valid*: at least one date answer contained a parseable date. *degenerate*: the "
                 "\"!!!!…\" failure mode.")
    lines.append("")
    lines.append("| Group | n | any-frame exact | majority exact | year match | schema-valid | date frames | frames with a date | degenerate frames |")
    lines.append("|---|---|---|---|---|---|---|---|---|")

    def ocr_row(name: str, agg: Dict[str, Any]) -> str:
        return "| {} | {} | {} | {} | {} | {} | {} | {} | {} |".format(
            name, agg["n"], _pct(agg["any_frame_exact"]), _pct(agg["majority_exact"]), _pct(agg["year_match"]),
            _pct(agg["schema_valid"]), agg["date_frames"], _pct(agg["frames_with_date_rate"]),
            _pct(agg["degenerate_frame_rate"]))

    ocr = summary["ocr"]
    lines.append(ocr_row("**all**", ocr["all"]))
    for name, agg in ocr["by_stratum"].items():
        lines.append(ocr_row("stratum: {}".format(name), agg))
    lines.append("")
    return "\n".join(lines) + "\n"


def summarize_command(args: argparse.Namespace) -> int:
    manifest = load_manifest(Path(args.manifest))
    summary = summarize_run(Path(args.run), manifest)
    markdown = format_summary_markdown(summary)
    if args.out:
        out = Path(args.out)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(markdown, encoding="utf-8")
    if args.json_out:
        Path(args.json_out).write_text(json.dumps(summary, indent=1, sort_keys=True), encoding="utf-8")
    print(markdown)
    return 0


# ---------------------------------------------------------------------------
def make_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)

    validate = commands.add_parser("validate-corpus", help="build the frozen ERA/OCR manifest from a catalog .backup copy")
    validate.add_argument("--catalog", required=True, help="READ-ONLY .backup copy of catalog.sqlite (never the live file)")
    validate.add_argument("--out", required=True, help="manifest JSON (keep it under .scratch/)")
    validate.add_argument("--seed", type=int, default=DEFAULT_SEED)
    validate.add_argument("--camera-target", type=int, default=ERA_CAMERA_TARGET)
    validate.add_argument("--ocr-target", type=int, default=OCR_TARGET)
    validate.set_defaults(func=validate_corpus_command)

    run = commands.add_parser("run", help="run an approach over a manifest; resume-safe")
    run.add_argument("--manifest", required=True)
    run.add_argument("--approach", default=APPROACH_ID, choices=[APPROACH_ID])
    run.add_argument("--frames", type=int, default=5)
    run.add_argument("--limit", type=int, default=None, help="first N clips (after --corpus filter)")
    run.add_argument("--corpus", choices=["era", "ocr"], default=None, help="only this corpus")
    run.add_argument("--out", required=True, help="run directory (keep it under .scratch/)")
    run.add_argument("--model-dir", default=None,
                     help="local snapshot directory of the model (offline); default: HF cache via snapshot_download")
    run.set_defaults(func=run_command)

    summarize = commands.add_parser("summarize", help="aggregates only → Markdown (+ stdout)")
    summarize.add_argument("--run", required=True)
    summarize.add_argument("--manifest", required=True)
    summarize.add_argument("--out", help="Markdown file, e.g. docs/reviews/video_llm_benchmarks.md")
    summarize.add_argument("--json-out", help="optional JSON aggregate (keep under .scratch/)")
    summarize.set_defaults(func=summarize_command)
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = make_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
