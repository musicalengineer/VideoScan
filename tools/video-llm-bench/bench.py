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


# scripts/catalog_db.py is the one door that names catalog.sqlite; we only need its path constant.
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import catalog_db  # noqa: E402
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
    # The live catalog is named in one place only (scripts/catalog_db.py; sensor test_no_script_writes_catalog).
    if catalog.resolve() == catalog_db.DEFAULT_DATABASE.resolve():
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


# ===========================================================================
# Approach A1 in Python (design §5 row A1): the same model and weights as A0,
# but (1) chronological WINDOWS of N frames shown to the model together in one
# prompt instead of single stills, and (2) a STRICT JSON contract per field
# family (§3.3 `era`, `roomFeatures`), decoded fail-closed by a Python mirror of
# the Swift `ContractDecoder` (VideoScanCore/ModelLab/ApproachOutputContracts.swift).
# The OCR corpus still gets A0's `date` prompt verbatim, one frame per call, on
# the window frames, so OCR parity is measured on the same sampler.
#
# Memory (worst case, A1 run): model ≈ 2.4 GB + mlx cache limit 512 MB + the
# KV cache of one multi-image generation (MAX_WINDOWS_FRAMES images × 256
# visual tokens + ≤ 400 output tokens ≈ 2.7k tokens) + ≤ 3 × N letterboxed
# 448×448 PNGs on disk per clip (N ≤ 8 → 24 × ≈ 0.4 MB), deleted after the clip.
# ===========================================================================
A1_APPROACH_ID = "a1-py"
A1_SAMPLER_TEMPLATE = "windows-{w}x{n}-max{s}s-middle90"
A1_MAX_WINDOWS = 3
A1_WINDOW_MAX_S = 60.0       # a window is at most a minute (design §3.2 WindowSampler 60 s)
A1_MIN_WINDOW_S = 10.0       # a middle-90 % span shorter than 3 × this gets ONE window
A1_MIN_FRAME_GAP_S = 0.25    # never ask for frames closer than this (a 1 s clip gets ≤ 4)
A1_DEFAULT_FRAMES = 6

A1_SYSTEM_PROMPT = (
    "You are a careful video analyst. You answer with exactly one JSON object that matches the "
    "schema you are given, and nothing else: no prose, no markdown, no code fences."
)
# Prompt revision r2 (2026-10-30): r1 phrased the window as "from the window X s
# to Y s"; on the 3-clip smoke the model echoed that phrase into "window" as a
# string and put the setting word into "family" (roomFeatures 3/9 valid). r2 states
# the two fixed values as literals to copy and asks for distinct features.  No
# decoding rule changed — the decoder is the contract; only the question moved.
# r3: r2 era answers echoed the placeholder FRAME_TIME as a bare word into "atS"
# (not JSON → schemaInvalid, 3/9) and one hit the 320-token cap; r3 writes the
# first frame time as the example atS and raises era max_tokens to 400.
A1_PROMPT_REVISION = 3
A1_ERA_PROMPT = (
    "These {n} images are frames from ONE home video, in chronological order. "
    "Frame times in seconds: {times}.\n"
    "Estimate the range of years in which this footage was recorded, from visual evidence only: "
    "picture quality, camcorder on-screen display, burned-in dates, technology, clothing, hairstyles, "
    "cars, decor.\n"
    "Answer with ONLY this JSON object, with exactly these keys:\n"
    '{{"family": "era", "window": [{start}, {end}], "yearRange": [FROM_YEAR, TO_YEAR], '
    '"rationale": "ONE SENTENCE", "cues": [{{"kind": "KIND", "text": "WHAT YOU SAW", "atS": {first}}}], '
    '"selfConfidence": NUMBER}}\n'
    'Rules: copy "family" and "window" exactly as shown: "family" is the string "era" and "window" is the '
    "array [{start}, {end}]. FROM_YEAR and TO_YEAR are integers from 1900 to 2100 and FROM_YEAR is not after "
    "TO_YEAR. KIND is one of technical, cultural, environmental, onScreenText, spoken. Each atS is the number "
    "of the frame time (from the list above) where you saw the cue. At most 5 cues. NUMBER is from 0.0 to 1.0. Do not add any other key."
)
A1_ROOM_PROMPT = (
    "These {n} images are frames from ONE home video, in chronological order. "
    "Frame times in seconds: {times}.\n"
    "Describe the PLACE where this was filmed (not the people).\n"
    "Answer with ONLY this JSON object, with exactly these keys:\n"
    '{{"family": "roomFeatures", "window": [{start}, {end}], "setting": "SETTING", '
    '"locationType": "SHORT PHRASE", "features": ["FEATURE", "FEATURE"], "selfConfidence": NUMBER}}\n'
    'Rules: copy "family" and "window" exactly as shown: "family" is the string "roomFeatures" and "window" '
    "is the array [{start}, {end}]. SETTING is one of indoor, outdoor, mixed, unknown. SHORT PHRASE is a "
    "generic kind of place, for example residential living room or backyard. Each FEATURE is a different "
    "short generic lowercase phrase for something fixed in the place (flooring, walls, furniture, fixtures, "
    "landscape), for example green shag carpet or brick fireplace; at most 8 features, no repeats; never a "
    "name of a person, a business or a town. NUMBER is from 0.0 to 1.0. Do not add any other key."
)
A1_PROMPTS: Dict[str, str] = {"era": A1_ERA_PROMPT, "roomFeatures": A1_ROOM_PROMPT}
A1_FAMILY_ORDER = ("era", "roomFeatures")
A1_GEN_PARAMS: Dict[str, Dict[str, Any]] = {
    "era": {"max_tokens": 400, "temperature": 0.0, "top_p": 1.0},
    "roomFeatures": {"max_tokens": 200, "temperature": 0.0, "top_p": 1.0},
}

# --- Window planning (pure) -------------------------------------------------


def plan_windows(frames_per_window: int, duration_s: float,
                 max_windows: int = A1_MAX_WINDOWS, window_max_s: float = A1_WINDOW_MAX_S,
                 min_window_s: float = A1_MIN_WINDOW_S) -> List[Dict[str, Any]]:
    """Up to ``max_windows`` chronological windows inside the middle 90 % of the
    file — one at its START, one centred on its MIDDLE, one at its END — each at
    most ``window_max_s`` long and never overlapping (each is ≤ span / 3).  A span
    shorter than ``max_windows × min_window_s`` gets ONE window covering it.  Each
    window holds N frames at the centres of N equal sub-intervals (never on a
    boundary), fewer when they would be closer than ``A1_MIN_FRAME_GAP_S``.

    Zero / negative / non-finite duration or N ≤ 0 → [] (nothing to look at).

    C++ reading: a pure function returning a std::vector<Window>; no I/O.
    """
    if frames_per_window <= 0 or not (duration_s == duration_s) or duration_s <= 0 or duration_s == float("inf"):
        return []
    lo, hi = duration_s * 0.05, duration_s * 0.95
    span = hi - lo
    if span < max_windows * min_window_s:
        bounds = [(lo, hi)]
    else:
        width = min(window_max_s, span / max_windows)
        mid = (lo + hi) / 2.0
        bounds = [(lo, lo + width), (mid - width / 2.0, mid + width / 2.0), (hi - width, hi)]
    windows: List[Dict[str, Any]] = []
    for index, (start, end) in enumerate(bounds):
        length = end - start
        n = max(1, min(frames_per_window, int(length / A1_MIN_FRAME_GAP_S)))
        step = length / n
        times = [round(start + step * (i + 0.5), 3) for i in range(n)]
        windows.append({"index": index, "start_s": round(start, 3), "end_s": round(end, 3), "frame_times_s": times})
    return windows


def format_a1_prompt(family: str, window: Dict[str, Any]) -> str:
    times = window["frame_times_s"]
    return A1_PROMPTS[family].format(
        n=len(times), start="{:.1f}".format(window["start_s"]), end="{:.1f}".format(window["end_s"]),
        first="{:.1f}".format(times[0]) if times else "0.0",
        times=", ".join("{:.1f}".format(t) for t in times))


# --- Fail-closed contract decoding (mirror of Swift ContractDecoder) ---------
CONTRACT_MAX_JSON_BYTES = 64 * 1024
CONTRACT_MAX_LIST_ITEMS = 64
CONTRACT_YEAR_MIN, CONTRACT_YEAR_MAX = 1900, 2100
FIELD_FAMILIES = ("era", "scene", "ocrDate", "ocrText", "occasionKind", "roomFeatures",
                  "carrierClues", "spokenNamePresence")
CUE_KINDS = ("technical", "cultural", "environmental", "onScreenText", "spoken")
ROOM_SETTINGS = ("indoor", "outdoor", "mixed", "unknown")
_ERA_KEYS = ("family", "window", "yearRange", "rationale", "cues", "selfConfidence")
_ROOM_KEYS = ("family", "window", "setting", "locationType", "features", "selfConfidence")
_CUE_KEYS = ("kind", "text", "atS")


class ContractViolation(Exception):
    """A rule of the contract broken; the message is the log reason."""


def _reject_constant(name: str) -> Any:
    # json.loads accepts NaN / Infinity / -Infinity; Foundation's JSONDecoder does not.
    raise ContractViolation("not valid JSON: {} is not a JSON number".format(name))


def _no_duplicate_keys(pairs: List[Tuple[str, Any]]) -> Dict[str, Any]:
    # Stricter than Foundation (which keeps one silently): a duplicated key is ambiguous.
    out: Dict[str, Any] = {}
    for key, value in pairs:
        if key in out:
            raise ContractViolation("duplicate key '{}'".format(key))
        out[key] = value
    return out


def _is_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _as_double(value: Any, where: str) -> float:
    """Swift `Double` from JSON: any number, never a string, bool or null."""
    if value is None:
        raise ContractViolation("null at '{}' where Double was expected".format(where))
    if not _is_number(value):
        raise ContractViolation("wrong type at '{}' (expected Double)".format(where))
    return float(value)


def _as_int(value: Any, where: str) -> int:
    """Swift `Int` from JSON: an integer number (1991 or 1991.0); 1991.5, "1991", true → wrong type."""
    if value is None:
        raise ContractViolation("null at '{}' where Int was expected".format(where))
    if not _is_number(value):
        raise ContractViolation("wrong type at '{}' (expected Int)".format(where))
    if isinstance(value, float):
        if not value.is_integer():
            raise ContractViolation("not valid JSON at '{}': Number {} is not representable as Int".format(where, value))
        return int(value)
    return value


def _as_string(value: Any, where: str) -> str:
    if value is None:
        raise ContractViolation("null at '{}' where String was expected".format(where))
    if not isinstance(value, str):
        raise ContractViolation("wrong type at '{}' (expected String)".format(where))
    return value


def _as_list(value: Any, where: str) -> list:
    if value is None:
        raise ContractViolation("null at '{}' where Array was expected".format(where))
    if not isinstance(value, list):
        raise ContractViolation("wrong type at '{}' (expected Array)".format(where))
    return value


def _require(obj: Dict[str, Any], key: str, parent: str = "") -> Any:
    if key not in obj:
        raise ContractViolation("missing key '{}'".format(parent + "." + key if parent else key))
    return obj[key]


def _reject_unknown_keys(obj: Dict[str, Any], allowed: Sequence[str]) -> None:
    unknown = sorted(k for k in obj if k not in allowed)
    if unknown:
        raise ContractViolation("unknown key(s) {} — the contract names every field".format(
            ", ".join("'{}'".format(k) for k in unknown)))


def _non_empty_text(obj: Dict[str, Any], key: str, parent: str = "") -> str:
    text = _as_string(_require(obj, key, parent), key)
    if not text.strip():
        raise ContractViolation("'{}' is empty".format(key))
    return text


def _frame_time(obj: Dict[str, Any], key: str, parent: str = "") -> float:
    t = _as_double(_require(obj, key, parent), key)
    if t != t or t in (float("inf"), float("-inf")) or t < 0:
        raise ContractViolation("'{}' {} is not a frame time at or after 0".format(key, t))
    return t


def _bounded(items: list, name: str) -> list:
    if len(items) > CONTRACT_MAX_LIST_ITEMS:
        raise ContractViolation("'{}' has {} items, more than the {} cap".format(name, len(items), CONTRACT_MAX_LIST_ITEMS))
    return items


def _word(obj: Dict[str, Any], key: str, words: Sequence[str], parent: str = "") -> str:
    raw = _as_string(_require(obj, key, parent), key)
    if raw not in words:
        raise ContractViolation("'{}' word '{}' is not one of {}".format(key, raw, ", ".join(words)))
    return raw


def _family(obj: Dict[str, Any], expected: str) -> None:
    word = _as_string(_require(obj, "family"), "family")
    if word not in FIELD_FAMILIES:
        raise ContractViolation("unknown family '{}'".format(word))
    if word != expected:
        raise ContractViolation("family '{}' where '{}' was asked for".format(word, expected))


def _window(obj: Dict[str, Any]) -> List[float]:
    pair = [_as_double(v, "window") for v in _as_list(_require(obj, "window"), "window")]
    if len(pair) != 2:
        raise ContractViolation("window must be two numbers [start, end], got {}".format(len(pair)))
    finite = all(v == v and v not in (float("inf"), float("-inf")) for v in pair)
    if not finite or pair[0] < 0:
        raise ContractViolation("window must be finite and start at or after 0: {}".format(pair))
    if pair[1] < pair[0]:
        raise ContractViolation("window end {} is before its start {}".format(pair[1], pair[0]))
    return pair


def _year_range(obj: Dict[str, Any]) -> List[int]:
    pair = [_as_int(v, "yearRange") for v in _as_list(_require(obj, "yearRange"), "yearRange")]
    if len(pair) != 2:
        raise ContractViolation("yearRange must be two years [from, to], got {}".format(len(pair)))
    for year in pair:
        if not (CONTRACT_YEAR_MIN <= year <= CONTRACT_YEAR_MAX):
            raise ContractViolation("year {} is outside {}…{}".format(year, CONTRACT_YEAR_MIN, CONTRACT_YEAR_MAX))
    if pair[0] > pair[1]:
        raise ContractViolation("yearRange {} is reversed".format(pair))
    return pair


def _self_confidence(obj: Dict[str, Any]) -> float:
    v = _as_double(_require(obj, "selfConfidence"), "selfConfidence")
    if not (0.0 <= v <= 1.0):
        raise ContractViolation("selfConfidence {} is outside 0…1".format(v))
    return v


def _cue(value: Any, index: int) -> Dict[str, Any]:
    where = "cues.{}".format(index)
    if not isinstance(value, dict):
        raise ContractViolation("wrong type at '{}' (expected Object)".format(where))
    _reject_unknown_keys(value, _CUE_KEYS)
    return {"kind": _word(value, "kind", CUE_KINDS, where), "text": _non_empty_text(value, "text", where),
            "atS": _frame_time(value, "atS", where)}


def _decode_era(obj: Dict[str, Any]) -> Dict[str, Any]:
    _family(obj, "era")
    _reject_unknown_keys(obj, _ERA_KEYS)
    window = _window(obj)
    year_range = _year_range(obj)
    rationale = _non_empty_text(obj, "rationale")
    cues = _bounded([_cue(c, i) for i, c in enumerate(_as_list(_require(obj, "cues"), "cues"))], "cues")
    return {"family": "era", "window": window, "yearRange": year_range, "rationale": rationale, "cues": cues,
            "selfConfidence": _self_confidence(obj)}


def _decode_room(obj: Dict[str, Any]) -> Dict[str, Any]:
    _family(obj, "roomFeatures")
    _reject_unknown_keys(obj, _ROOM_KEYS)
    window = _window(obj)
    setting = _word(obj, "setting", ROOM_SETTINGS)
    location = _non_empty_text(obj, "locationType")
    features = _bounded([_as_string(f, "features.{}".format(i))
                         for i, f in enumerate(_as_list(_require(obj, "features"), "features"))], "features")
    if any(not f.strip() for f in features):
        raise ContractViolation("'features' holds an empty item")
    return {"family": "roomFeatures", "window": window, "setting": setting, "locationType": location,
            "features": features, "selfConfidence": _self_confidence(obj)}


_DECODERS: Dict[str, Callable[[Dict[str, Any]], Dict[str, Any]]] = {"era": _decode_era, "roomFeatures": _decode_room}


def decode_contract(family: str, text: Any) -> Tuple[Optional[Dict[str, Any]], Optional[str]]:
    """Fail-closed: (value, None) when ``text`` is EXACTLY one JSON object meeting the
    family's contract; (None, reason) otherwise — the caller records `schemaInvalid`.

    The raw model text is parsed as-is: no fence stripping, no "find the first {",
    no regex rescue, no defaulting.  Mirrors Swift `ContractDecoder.decode`: size cap
    64 KB, unknown keys / wrong types / null / missing keys rejected, `family` must
    match, years 1900…2100, ranges not reversed, lists ≤ 64, selfConfidence 0…1.
    Stricter than Foundation in two corners, both fail-closed: NaN/Infinity literals
    and duplicate keys are rejected.

    C++ reading: a parser returning std::variant<Value, Reason>; it throws
    internally and the one catch turns every throw into the Reason arm.
    """
    if family not in _DECODERS:
        return None, "no output contract for family '{}' in this harness".format(family)
    if not isinstance(text, str):
        return None, "response is not text"
    raw = text.encode("utf-8")
    if len(raw) > CONTRACT_MAX_JSON_BYTES:
        return None, "response is {} bytes, larger than the {}-byte cap".format(len(raw), CONTRACT_MAX_JSON_BYTES)
    if not raw:
        return None, "empty response"
    try:
        obj = json.loads(text, parse_constant=_reject_constant, object_pairs_hook=_no_duplicate_keys)
        if not isinstance(obj, dict):
            raise ContractViolation("wrong type at 'top level' (expected Object)")
        return _DECODERS[family](obj), None
    except ContractViolation as violation:
        return None, str(violation)
    except (json.JSONDecodeError, RecursionError, ValueError) as error:
        return None, "not valid JSON: {}".format(error)


class A1Python(A0Python):
    """A0's model and loader; adds one multi-image generation per (window, family).
    C++ reading: a derived class reusing the base's load()/seed() and adding a method."""
    id = A1_APPROACH_ID

    def answer_window(self, image_paths: Sequence[Path], family: str,
                      window: Dict[str, Any]) -> Tuple[str, Dict[str, Any]]:
        from mlx_vlm import generate
        from mlx_vlm.prompt_utils import apply_chat_template

        messages = [
            {"role": "system", "content": A1_SYSTEM_PROMPT},
            {"role": "user", "content": format_a1_prompt(family, window)},
        ]
        templated = apply_chat_template(self.processor, self.config, messages, num_images=len(image_paths))
        params = A1_GEN_PARAMS[family]
        result = generate(self.model, self.processor, templated, image=[str(p) for p in image_paths],
                          max_tokens=params["max_tokens"], temperature=params["temperature"],
                          top_p=params["top_p"], verbose=False)
        text = result if isinstance(result, str) else getattr(result, "text", str(result))
        counters = {}
        for name in ("prompt_tokens", "generation_tokens", "generation_tps", "peak_memory"):
            value = getattr(result, name, None)
            if value is not None:
                counters[name] = value
        return text.strip(), counters


# ===========================================================================
# Approach A2 in Python (design §5 row A2): a BIGGER model — Qwen3-VL-8B-Instruct
# 4-bit — through exactly A1's code paths (windows 3×N, the r3 era/roomFeatures
# contracts, the fail-closed decoder), with one change dictated by the A1 result
# ("one engine, two samplers"): the OCR corpus goes back to A0's sampler, N spread
# stills from the middle 90 % with A0's unchanged `date` prompt, one frame per call.
# The ERA corpus keeps the windows.  The loop is `run_corpus_a1`; only the
# sampling plan differs (`plan_clip_sampling`).
#
# Memory (worst case, A2 run): weights ≈ 5.8 GB resident + mlx cache limit 512 MB +
# one multi-image generation's activations / KV (one window at a time, ≤ N frames,
# N ≤ 12 → ≤ 12 × ~256 visual tokens + ≤ 400 output tokens ≈ 3.5k tokens; measured
# peak 7.1 GB at N = 4) + ≤ N + 5 letterboxed 448×448 PNGs on disk per clip,
# deleted after the clip.  Nothing is cached across clips (`mx.clear_cache()`).
# ===========================================================================
A2_APPROACH_ID = "a2-py"
A2_MODEL_ID = "mlx-community/Qwen3-VL-8B-Instruct-4bit"
A2_OCR_STILLS = 5                      # A0's sampler: `stills-5-middle90`
OCR_SAMPLER_WINDOW_FRAMES = "window-frames"   # A1: date prompt on every window frame
OCR_SAMPLER_STILLS = "stills"                 # A0 / A2: date prompt on N spread stills


class A2Python(A1Python):
    """A1's prompts, generation and decoding on the 8B model.
    C++ reading: a derived class that only changes the constructor default."""
    id = A2_APPROACH_ID

    def __init__(self, model_id: str = A2_MODEL_ID, model_dir: Optional[Path] = None):
        super().__init__(model_id=model_id, model_dir=model_dir)


# id → (class, model id, default frames, OCR sampler).  The one registry `run`
# and `summarize` consult; A0 is stills-only (its loop is `run_corpus`).
APPROACHES: Dict[str, Dict[str, Any]] = {
    APPROACH_ID: {"cls": A0Python, "model": MODEL_ID, "default_frames": 5, "ocr_sampler": OCR_SAMPLER_STILLS,
                  "windows": False},
    A1_APPROACH_ID: {"cls": A1Python, "model": MODEL_ID, "default_frames": A1_DEFAULT_FRAMES,
                     "ocr_sampler": OCR_SAMPLER_WINDOW_FRAMES, "windows": True},
    A2_APPROACH_ID: {"cls": A2Python, "model": A2_MODEL_ID, "default_frames": A1_DEFAULT_FRAMES,
                     "ocr_sampler": OCR_SAMPLER_STILLS, "windows": True},
}


# ===========================================================================
# Watchdog (#406).  On 2026-10-30 one mlx-vlm generation wedged (100 % GPU, no
# output) and held the Ultra's GPU for twelve hours, through the nightly.  A
# wedged Metal kernel cannot be interrupted from a Python thread, so the only
# cure is a process boundary: the model lives in a WORKER PROCESS (this same
# script, `worker` subcommand, JSON lines over its stdin/stdout); the parent
# waits at most `timeout_s` for each generation and, on silence, SIGKILLs the
# worker — the GPU is freed with the process — records the generation as a
# `GenerationTimeout` failure, and respawns (model reload) on the next call.
# C++ reading: a supervisor that owns a child and a pipe; the child is the
# only thing that ever touches the GPU.
#
# A run-level `--deadline HH:MM` stops BETWEEN clips (resume-safe: the run
# directory picks up where it stopped) so an unattended run cannot cross the
# nightly's start even when every generation is healthy.
# ===========================================================================
DEFAULT_GENERATION_TIMEOUT_S = 120.0
DEFAULT_LOAD_TIMEOUT_S = 900.0
WORKER_EXIT_METHOD = "__exit__"


class GenerationTimeout(Exception):
    """A generation exceeded the watchdog; the worker was killed and the GPU freed."""


def factory_ref_for_approach(approach_id: str, model_dir: Optional[str]) -> str:
    return "approach:{}:{}".format(approach_id, model_dir or "")


def build_from_factory_ref(ref: str) -> Any:
    """``approach:<id>:<model_dir or empty>`` → the registered approach;
    ``import:<sys_path dir>:<module>:<attribute>`` → ``attribute()`` (tests)."""
    kind, _, rest = ref.partition(":")
    if kind == "approach":
        approach_id, _, model_dir = rest.partition(":")
        return resolve_approach(approach_id, model_dir or None)
    if kind == "import":
        directory, module_name, attribute = rest.rsplit(":", 2)
        if directory and directory not in sys.path:
            sys.path.insert(0, directory)
        import importlib
        return getattr(importlib.import_module(module_name), attribute)()
    raise ValueError("unknown factory ref {!r}".format(ref))


def worker_command(args: argparse.Namespace) -> int:
    """The child: one JSON request per stdin line → one JSON reply per stdout line.
    Everything the model stack prints goes to stderr; the real stdout carries
    only the protocol."""
    protocol = os.fdopen(os.dup(1), "w", encoding="utf-8")
    sys.stdout = sys.stderr
    approach = build_from_factory_ref(args.factory)
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        request = json.loads(line)
        method = request["method"]
        if method == WORKER_EXIT_METHOD:
            break
        try:
            result = getattr(approach, method)(*request.get("args", []))
            reply = {"ok": _jsonable(result)}
        except Exception as exc:  # noqa: BLE001 — reported to the parent, never swallowed
            reply = {"error": str(exc), "type": type(exc).__name__}
        protocol.write(json.dumps(reply) + "\n")
        protocol.flush()
    return 0


def _jsonable(value: Any) -> Any:
    if isinstance(value, tuple):
        return [_jsonable(v) for v in value]
    if isinstance(value, dict):
        return {str(k): _jsonable(v) for k, v in value.items()}
    if isinstance(value, (list, str, int, float, bool)) or value is None:
        return value
    return str(value)


class SubprocessApproach:
    """The parent half of the watchdog: an `Approach` whose every method runs in
    the worker process under a wall-clock cap."""

    def __init__(self, factory_ref: str, timeout_s: float = DEFAULT_GENERATION_TIMEOUT_S,
                 load_timeout_s: float = DEFAULT_LOAD_TIMEOUT_S, approach_id: str = "",
                 python: Optional[str] = None, script: Optional[Path] = None,
                 log: Callable[[str], None] = lambda s: print(s, file=sys.stderr, flush=True)):
        self.factory_ref = factory_ref
        self.timeout_s = float(timeout_s)
        self.load_timeout_s = float(load_timeout_s)
        self.id = approach_id
        self.python = python or sys.executable
        self.script = Path(script or __file__).resolve()
        self.log = log
        self.timeouts = 0
        self.respawns = 0
        self.load_info: Dict[str, Any] = {}
        self._proc: Optional[subprocess.Popen] = None
        self._lines: Optional[Any] = None   # queue.Queue of stdout lines
        self.worker_pid: Optional[int] = None

    # -- process ------------------------------------------------------------
    def _spawn(self) -> None:
        import queue
        import threading
        self._proc = subprocess.Popen(
            [self.python, "-I", str(self.script), "worker", "--factory", self.factory_ref],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=None, text=True, bufsize=1)
        self.worker_pid = self._proc.pid
        lines: "queue.Queue[Optional[str]]" = queue.Queue()
        stdout = self._proc.stdout

        def pump() -> None:
            try:
                for line in stdout:   # type: ignore[union-attr]
                    lines.put(line)
            finally:
                lines.put(None)       # EOF: the worker is gone

        threading.Thread(target=pump, name="bench-worker-stdout", daemon=True).start()
        self._lines = lines

    def _kill(self, why: str) -> None:
        proc = self._proc
        self._proc = None
        self._lines = None
        if proc is None:
            return
        try:
            proc.kill()
            proc.wait(timeout=30)
        except Exception:  # noqa: BLE001
            pass
        self.log("watchdog: worker pid {} killed ({})".format(proc.pid, why))

    def _ensure(self) -> None:
        if self._proc is not None and self._proc.poll() is None:
            return
        if self._proc is not None:
            self._kill("worker exited on its own")
        first = self.worker_pid is None
        self._spawn()
        if not first:
            self.respawns += 1
            self.log("watchdog: worker respawned (pid {}), reloading the model".format(self.worker_pid))
        self.load_info = self._call("load", timeout=self.load_timeout_s, spawn=False)

    def _call(self, method: str, *args: Any, timeout: Optional[float] = None, spawn: bool = True) -> Any:
        if spawn:
            self._ensure()
        assert self._proc is not None and self._proc.stdin is not None and self._lines is not None
        try:
            self._proc.stdin.write(json.dumps({"method": method, "args": list(args)}) + "\n")
            self._proc.stdin.flush()
        except (BrokenPipeError, OSError) as exc:
            self._kill("stdin broken: {}".format(exc))
            raise RuntimeError("worker unreachable ({})".format(exc))
        import queue
        cap = self.timeout_s if timeout is None else timeout
        try:
            line = self._lines.get(timeout=cap)
        except queue.Empty:
            self.timeouts += 1
            self._kill("{} exceeded {:.0f} s".format(method, cap))
            raise GenerationTimeout("{} exceeded {:.0f} s; worker killed, GPU freed".format(method, cap))
        if line is None:
            self._kill("worker died during {}".format(method))
            raise RuntimeError("worker died during {}".format(method))
        reply = json.loads(line)
        if "error" in reply:
            raise RuntimeError("{}: {}".format(reply.get("type", "Error"), reply["error"]))
        return reply["ok"]

    def close(self) -> None:
        proc = self._proc
        if proc is None:
            return
        try:
            if proc.stdin is not None:
                proc.stdin.write(json.dumps({"method": WORKER_EXIT_METHOD}) + "\n")
                proc.stdin.flush()
            proc.wait(timeout=30)
            self._proc = None
            self._lines = None
        except Exception:  # noqa: BLE001
            self._kill("did not exit when asked")

    # -- Approach surface ----------------------------------------------------
    def load(self) -> Dict[str, Any]:
        self._ensure()
        info = dict(self.load_info)
        info["watchdog"] = {"generation_timeout_s": self.timeout_s, "load_timeout_s": self.load_timeout_s,
                            "worker_pid": self.worker_pid}
        return info

    def seed(self, value: int) -> None:
        self._call("seed", value)

    def after_clip(self) -> None:
        self._call("after_clip")

    def answer(self, image_path: Path, prompt_kind: str) -> Tuple[str, Dict[str, Any]]:
        text, counters = self._call("answer", str(image_path), prompt_kind)
        return text, counters

    def answer_window(self, image_paths: Sequence[Path], family: str,
                      window: Dict[str, Any]) -> Tuple[str, Dict[str, Any]]:
        text, counters = self._call("answer_window", [str(p) for p in image_paths], family, window)
        return text, counters

    def stats(self) -> Dict[str, Any]:
        return {"timeouts": self.timeouts, "respawns": self.respawns, "worker_pid": self.worker_pid}


def parse_deadline(text: str, now: Optional[dt.datetime] = None) -> float:
    """``HH:MM`` local → epoch seconds of the next such wall-clock time (today if
    still ahead, else tomorrow)."""
    now = now or dt.datetime.now()
    try:
        hour, minute = (int(part) for part in text.split(":", 1))
    except ValueError:
        raise SystemExit("--deadline wants HH:MM, got {!r}".format(text))
    if not (0 <= hour < 24 and 0 <= minute < 60):
        raise SystemExit("--deadline wants HH:MM, got {!r}".format(text))
    candidate = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
    if candidate <= now:
        candidate += dt.timedelta(days=1)
    return candidate.timestamp()


def _generation_error(exc: BaseException) -> Tuple[str, bool]:
    """(error text for the record, is_timeout)."""
    return "{}: {}".format(type(exc).__name__, exc), isinstance(exc, GenerationTimeout)


def plan_clip_sampling(corpora: Iterable[str], duration_s: float, frames_per_window: int,
                       ocr_sampler: str = OCR_SAMPLER_WINDOW_FRAMES,
                       ocr_stills: int = A2_OCR_STILLS) -> Dict[str, Any]:
    """Which frames a windowed approach rips for one clip, and which prompt each gets.

    * ``window-frames`` (A1): windows are always planned; an OCR clip's `date`
      prompt runs on every window frame; no separate stills.
    * ``stills`` (A2): windows only when the clip is in the ERA corpus; an OCR clip
      gets ``ocr_stills`` A0 stills (`frames_evenly_spaced`) for the `date` prompt.

    Returns {"windows": [...], "date_on_window_frames": bool, "ocr_still_times_s": [...]}.
    Pure. C++ reading: a function returning a small struct; no I/O.
    """
    corpora = set(corpora)
    if ocr_sampler == OCR_SAMPLER_WINDOW_FRAMES:
        return {"windows": plan_windows(frames_per_window, duration_s),
                "date_on_window_frames": "ocr" in corpora, "ocr_still_times_s": []}
    if ocr_sampler != OCR_SAMPLER_STILLS:
        raise ValueError("unknown OCR sampler {}".format(ocr_sampler))
    finite = duration_s == duration_s and duration_s not in (float("inf"), float("-inf"))
    stills = frames_evenly_spaced(ocr_stills, duration_s) if ("ocr" in corpora and finite) else []
    return {"windows": plan_windows(frames_per_window, duration_s) if "era" in corpora else [],
            "date_on_window_frames": False,
            "ocr_still_times_s": [round(t, 3) for t in stills]}


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
               log: Callable[[str], None] = lambda s: print(s, flush=True),
               deadline: Optional[float] = None,
               clock: Callable[[], float] = time.time) -> Dict[str, Any]:
    out_dir = Path(out_dir)
    (out_dir / "clips").mkdir(parents=True, exist_ok=True)
    progress_path = out_dir / "progress.json"
    done = skipped = failed = frames_done = timeouts = 0
    gen_seconds = 0.0
    started = time.perf_counter()
    stopped_by_deadline = False
    progress: Dict[str, Any] = {
        "run_id": run_record.get("run_id"), "total_clips": len(entries), "done": 0,
        "skipped_resume": 0, "failed": 0, "frames_done": 0, "s_per_frame": None, "timeouts": 0,
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
            if deadline is not None and clock() >= deadline:
                stopped_by_deadline = True
                log("deadline reached before clip {}/{}; stopping (resume-safe)".format(index, len(entries)))
                break
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
                            error, is_timeout = _generation_error(exc)
                            text, counters = "", {}
                            timeouts += int(is_timeout)
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
                done=done, failed=failed, frames_done=frames_done, timeouts=timeouts, updated_at=utc_now(),
                s_per_frame=round(gen_seconds / frames_done, 3) if frames_done else None,
                elapsed_s=round(time.perf_counter() - started, 1), last_stratum=entry["stratum"],
                peak_rss_bytes=peak_rss_bytes())
            write_json(progress_path, progress)
            log("[{}/{}] {} frames={} {:.1f}s stratum={}".format(
                index, len(entries), digest[:12], len(timestamps) - rip_failures, clip_elapsed, entry["stratum"]))
    finally:
        shutil.rmtree(tmp_root, ignore_errors=True)
    progress.update(state="deadline" if stopped_by_deadline else "finished", updated_at=utc_now(),
                    finished_at=utc_now())
    write_json(progress_path, progress)
    return progress


def run_corpus_a1(entries: Sequence[Dict[str, Any]], out_dir: Path, approach: Any,
                  frames_per_window: int, run_record: Dict[str, Any],
                  ripper: Callable[[str, float, Path, float], bool] = default_ripper,
                  duration_of: Callable[[str, float], float] = lambda p, d: d if d > 0 else probe_duration(p),
                  log: Callable[[str], None] = lambda s: print(s, flush=True),
                  families: Sequence[str] = A1_FAMILY_ORDER,
                  ocr_sampler: str = OCR_SAMPLER_WINDOW_FRAMES,
                  ocr_stills: int = A2_OCR_STILLS,
                  deadline: Optional[float] = None,
                  clock: Callable[[], float] = time.time) -> Dict[str, Any]:
    """A1 loop.  Per clip: plan ≤ 3 windows, rip every window frame once, then
    * ERA-corpus clip → one multi-image generation per (window, family) — a
      ``window_result`` record carrying raw text, `schema_valid`, the decoded value
      or the `schemaInvalid` reason;
    * OCR-corpus clip → A0's ``date`` prompt per frame — a ``result`` record shaped
      exactly like A0's, so `score_ocr_clip` scores both approaches the same way.
    A digest in both corpora gets both.  Same resume / clip_done / progress rules
    as `run_corpus`; frames are deleted after the clip.

    ``ocr_sampler="stills"`` (A2) moves the OCR `date` prompt off the window frames
    onto ``ocr_stills`` A0 stills (records carry ``sampler: "stills"`` and
    ``window_index: None``) and plans windows only for ERA clips — see
    `plan_clip_sampling`.  The default reproduces A1 exactly."""
    out_dir = Path(out_dir)
    (out_dir / "clips").mkdir(parents=True, exist_ok=True)
    progress_path = out_dir / "progress.json"
    corpora_of: Dict[str, set] = collections.defaultdict(set)
    for entry in entries:
        corpora_of[entry["digest"]].add(entry["corpus"])
    seen: set = set()
    unique = []
    for entry in entries:
        if entry["digest"] not in seen:
            seen.add(entry["digest"])
            unique.append(entry)
    done = skipped = failed = frames_done = windows_done = timeouts = 0
    gen_seconds = 0.0
    started = time.perf_counter()
    stopped_by_deadline = False
    progress: Dict[str, Any] = {
        "run_id": run_record.get("run_id"), "total_clips": len(unique), "done": 0,
        "skipped_resume": 0, "failed": 0, "frames_done": 0, "windows_done": 0, "s_per_frame": None,
        "s_per_window": None, "timeouts": 0, "started_at": utc_now(), "updated_at": utc_now(), "state": "running",
    }
    write_json(progress_path, progress)
    tmp_root = Path(tempfile.mkdtemp(prefix="video-llm-bench-a1-frames-"))
    try:
        for index, entry in enumerate(unique, 1):
            digest = entry["digest"]
            target = clip_file(out_dir, digest)
            if clip_is_done(target):
                skipped += 1
                progress.update(skipped_resume=skipped, updated_at=utc_now())
                write_json(progress_path, progress)
                continue
            if deadline is not None and clock() >= deadline:
                stopped_by_deadline = True
                log("deadline reached before clip {}/{}; stopping (resume-safe)".format(index, len(unique)))
                break
            corpora = corpora_of[digest]
            clip_tmp = tmp_root / digest[:16]
            clip_tmp.mkdir(parents=True, exist_ok=True)
            clip_started = time.perf_counter()
            approach.seed(MLX_SEED)
            duration = duration_of(entry["path"], float(entry.get("duration_s") or 0.0))
            plan = plan_clip_sampling(corpora, duration, frames_per_window, ocr_sampler, ocr_stills)
            windows = plan["windows"]
            rip_failures = frames_ok = records_written = window_records = 0

            def ask_date(png: Path, frame_index: int, window_index: Optional[int], at_s: float, rip_s: float,
                         stream: Any, sampler: Optional[str]) -> None:
                # A0's `date` prompt on one frame; the record is shaped like A0's so
                # `score_ocr_clip` scores every approach the same way.
                nonlocal gen_seconds, records_written, timeouts
                gen_started = time.perf_counter()
                error = None
                try:
                    text, counters = approach.answer(png, "date")
                except Exception as exc:  # noqa: BLE001 — one bad frame never ends the run
                    error, is_timeout = _generation_error(exc)
                    text, counters = "", {}
                    timeouts += int(is_timeout)
                elapsed = time.perf_counter() - gen_started
                gen_seconds += elapsed
                record = {
                    "record_type": "result", "digest": digest, "frame_index": frame_index,
                    "window_index": window_index, "at_s": at_s, "prompt_kind": "date",
                    "prompt_sha256": sha256_text(PROMPTS["date"]), "raw_text": text,
                    "elapsed_s": round(elapsed, 3), "rip_s": round(rip_s, 3), "error": error,
                    "counters": counters,
                    "parsed": {"dates": parse_dates(text), "years": parse_years(text),
                               "decades": parse_decades(text), "degenerate": is_degenerate(text)},
                }
                if sampler is not None:
                    record["sampler"] = sampler
                stream.write(json.dumps(record, sort_keys=True) + "\n")
                stream.flush()
                records_written += 1

            with target.open("w", encoding="utf-8") as stream:
                header = {
                    "record_type": "clip", "digest": digest, "corpus": entry["corpus"],
                    "corpora": sorted(corpora), "stratum": entry["stratum"], "truth": entry["truth"],
                    "duration_s": duration, "windows": windows,
                    "frames_requested": sum(len(w["frame_times_s"]) for w in windows) + len(plan["ocr_still_times_s"]),
                    "run_id": run_record.get("run_id")}
                if ocr_sampler != OCR_SAMPLER_WINDOW_FRAMES:
                    header.update(ocr_sampler=ocr_sampler, ocr_still_times_s=plan["ocr_still_times_s"])
                stream.write(json.dumps(header, sort_keys=True) + "\n")
                frame_index = 0
                for window in windows:
                    pngs: List[Path] = []
                    rip_s_window = 0.0
                    for at_s in window["frame_times_s"]:
                        png = clip_tmp / "w{}_f{:03d}.png".format(window["index"], frame_index)
                        rip_started = time.perf_counter()
                        ok = ripper(entry["path"], at_s, png, duration)
                        rip_s = time.perf_counter() - rip_started
                        rip_s_window += rip_s
                        if not ok:
                            rip_failures += 1
                            stream.write(json.dumps({
                                "record_type": "frame_failed", "digest": digest, "frame_index": frame_index,
                                "window_index": window["index"], "at_s": at_s, "rip_s": round(rip_s, 3)},
                                sort_keys=True) + "\n")
                        else:
                            frames_ok += 1
                            pngs.append(png)
                            if plan["date_on_window_frames"]:
                                ask_date(png, frame_index, window["index"], at_s, rip_s, stream, None)
                        frame_index += 1
                    if pngs and "era" in corpora:
                        for family in families:
                            gen_started = time.perf_counter()
                            error = None
                            is_timeout = False
                            try:
                                text, counters = approach.answer_window(pngs, family, window)
                            except Exception as exc:  # noqa: BLE001
                                error, is_timeout = _generation_error(exc)
                                text, counters = "", {}
                                timeouts += int(is_timeout)
                            elapsed = time.perf_counter() - gen_started
                            gen_seconds += elapsed
                            if error is None:
                                value, reason = decode_contract(family, text)
                            else:
                                value, reason = None, ("timeout" if is_timeout else "generation error")
                            stream.write(json.dumps({
                                "record_type": "window_result", "digest": digest, "window_index": window["index"],
                                "window": [window["start_s"], window["end_s"]],
                                "frame_times_s": window["frame_times_s"], "frames_shown": len(pngs),
                                "family": family, "prompt_sha256": sha256_text(A1_PROMPTS[family]),
                                "raw_text": text, "elapsed_s": round(elapsed, 3), "rip_s": round(rip_s_window, 3),
                                "error": error, "counters": counters, "schema_valid": value is not None,
                                "schema_invalid_reason": reason, "decoded": value,
                            }, sort_keys=True) + "\n")
                            stream.flush()
                            records_written += 1
                            window_records += 1
                        windows_done += 1
                    for png in pngs:
                        png.unlink(missing_ok=True)
                for at_s in plan["ocr_still_times_s"]:
                    png = clip_tmp / "s_f{:03d}.png".format(frame_index)
                    rip_started = time.perf_counter()
                    ok = ripper(entry["path"], at_s, png, duration)
                    rip_s = time.perf_counter() - rip_started
                    if not ok:
                        rip_failures += 1
                        stream.write(json.dumps({
                            "record_type": "frame_failed", "digest": digest, "frame_index": frame_index,
                            "window_index": None, "sampler": OCR_SAMPLER_STILLS, "at_s": at_s,
                            "rip_s": round(rip_s, 3)}, sort_keys=True) + "\n")
                    else:
                        frames_ok += 1
                        ask_date(png, frame_index, None, at_s, rip_s, stream, OCR_SAMPLER_STILLS)
                        png.unlink(missing_ok=True)
                    frame_index += 1
                frames_done += frames_ok
                clip_elapsed = time.perf_counter() - clip_started
                stream.write(json.dumps({
                    "record_type": "clip_done", "digest": digest, "frames_ok": frames_ok,
                    "frames_failed": rip_failures, "results": records_written, "window_results": window_records,
                    "clip_s": round(clip_elapsed, 3), "peak_rss_bytes": peak_rss_bytes(),
                    "finished_at": utc_now()}, sort_keys=True) + "\n")
            shutil.rmtree(clip_tmp, ignore_errors=True)
            approach.after_clip()
            if records_written == 0:
                failed += 1
            done += 1
            progress.update(
                done=done, failed=failed, frames_done=frames_done, windows_done=windows_done, timeouts=timeouts,
                updated_at=utc_now(),
                s_per_frame=round(gen_seconds / frames_done, 3) if frames_done else None,
                s_per_window=round(gen_seconds / windows_done, 3) if windows_done else None,
                elapsed_s=round(time.perf_counter() - started, 1), last_stratum=entry["stratum"],
                peak_rss_bytes=peak_rss_bytes())
            write_json(progress_path, progress)
            log("[{}/{}] {} windows={} frames={} {:.1f}s{} stratum={}".format(
                index, len(unique), digest[:12], len(windows), frames_ok, clip_elapsed,
                " timeouts={}".format(timeouts) if timeouts else "", entry["stratum"]))
    finally:
        shutil.rmtree(tmp_root, ignore_errors=True)
    progress.update(state="deadline" if stopped_by_deadline else "finished", updated_at=utc_now(),
                    finished_at=utc_now())
    write_json(progress_path, progress)
    return progress


def build_run_record(manifest: Dict[str, Any], manifest_path: Path, approach: Approach,
                     load_info: Dict[str, Any], frames: int, limit: Optional[int],
                     corpus_filter: Optional[str], run_id: str,
                     selection: Optional[str] = None) -> Dict[str, Any]:
    record = {
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
        "selection": selection,
        "host": socket.gethostname(),
        "platform": platform.platform(),
        "python": platform.python_version(),
        "ffmpeg": ffmpeg_version(),
        "git_sha": git_sha(),
        "bench_source_sha256": sha256_file(Path(__file__).resolve()),
        **load_info,
    }
    if APPROACHES.get(approach.id, {}).get("windows"):
        record.update({
            "sampler_id": A1_SAMPLER_TEMPLATE.format(w=A1_MAX_WINDOWS, n=frames, s=int(A1_WINDOW_MAX_S)),
            "frames_per_clip": None,
            "frames_per_window": frames,
            "max_windows": A1_MAX_WINDOWS,
            "window_max_s": A1_WINDOW_MAX_S,
            "min_window_s": A1_MIN_WINDOW_S,
            "prompts_sha256": {"era": sha256_text(A1_ERA_PROMPT), "roomFeatures": sha256_text(A1_ROOM_PROMPT),
                               "date": sha256_text(PROMPTS["date"])},
            "system_prompt_sha256": {"era+roomFeatures": sha256_text(A1_SYSTEM_PROMPT),
                                     "date": sha256_text(SYSTEM_PROMPT)},
            "gen_params": {**A1_GEN_PARAMS, "date": GEN_PARAMS["date"]},
            "decoder": "fail-closed mirror of VideoScanCore ContractDecoder; no repair",
            "prompt_revision": A1_PROMPT_REVISION,
        })
    if approach.id == A2_APPROACH_ID:
        # Two samplers, one engine: windows for ERA, A0's stills for OCR.
        record.update({
            "ocr_sampler": OCR_SAMPLER_STILLS,
            "ocr_stills": A2_OCR_STILLS,
            "sampler_id_by_corpus": {
                "era": record["sampler_id"],
                "ocr": SAMPLER_ID_TEMPLATE.format(n=A2_OCR_STILLS),
            },
        })
    return record


def resolve_approach(approach_id: str, model_dir: Optional[str]) -> Approach:
    """The registered approach object for ``approach_id`` (SystemExit when unknown)."""
    spec = APPROACHES.get(approach_id)
    if spec is None:
        raise SystemExit("unknown approach {}".format(approach_id))
    return spec["cls"](model_id=spec["model"], model_dir=model_dir)


def stratified_smoke(entries: Sequence[Dict[str, Any]], k: int) -> List[Dict[str, Any]]:
    """The first ERA clip (manifest order) of each of ``k`` distinct decades, preferring a
    clip of at least 60 s so all three windows exist — the N-frames calibration set."""
    picked: List[Dict[str, Any]] = []
    decades: set = set()
    era = [e for e in entries if e["corpus"] == "era" and float(e.get("duration_s") or 0) >= 60.0]
    for e in era:
        decade = e["stratum"].split("/")[1] if "/" in e["stratum"] else e["stratum"]
        if decade in decades:
            continue
        decades.add(decade)
        picked.append(e)
        if len(picked) >= k:
            break
    return picked


def run_command(args: argparse.Namespace) -> int:
    manifest_path = Path(args.manifest)
    manifest = load_manifest(manifest_path)
    entries = list(manifest["clips"])
    selection = None
    if args.corpus:
        entries = [e for e in entries if e["corpus"] == args.corpus]
    if getattr(args, "smoke", None):
        entries = stratified_smoke(entries, args.smoke)
        selection = "stratified-smoke-{}".format(args.smoke)
    if args.limit is not None:
        entries = entries[:args.limit]
    if not entries:
        raise SystemExit("no clips selected")
    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    spec = APPROACHES.get(args.approach)
    if spec is None:
        raise SystemExit("unknown approach {}".format(args.approach))
    frames = args.frames if args.frames is not None else spec["default_frames"]
    frames_key = "frames_per_window" if spec["windows"] else "frames_per_clip"
    run_path = out_dir / "run.json"
    if run_path.is_file():
        previous = json.loads(run_path.read_text(encoding="utf-8"))
        if previous.get("corpus_hash") != manifest.get("corpus_hash"):
            raise SystemExit("run dir belongs to another corpus ({} ≠ {})".format(
                previous.get("corpus_hash"), manifest.get("corpus_hash")))
        if previous.get("approach_id", APPROACH_ID) != args.approach:
            raise SystemExit("run dir was started with --approach {}".format(previous.get("approach_id")))
        if previous.get(frames_key) != frames:
            raise SystemExit("run dir was started with --frames {}".format(previous.get(frames_key)))
        run_id = previous["run_id"]
    else:
        run_id = "{}-{}".format(dt.datetime.now().strftime("%Y%m%dT%H%M%S"), args.approach)
    generation_timeout = float(getattr(args, "generation_timeout", DEFAULT_GENERATION_TIMEOUT_S) or 0.0)
    deadline = parse_deadline(args.deadline) if getattr(args, "deadline", None) else None
    if generation_timeout > 0:
        approach: Any = SubprocessApproach(factory_ref_for_approach(args.approach, args.model_dir),
                                           timeout_s=generation_timeout,
                                           load_timeout_s=float(getattr(args, "load_timeout", DEFAULT_LOAD_TIMEOUT_S)),
                                           approach_id=args.approach)
        print("watchdog: {:.0f} s per generation (worker process; a wedged generation is killed and the model reloaded)"
              .format(generation_timeout), flush=True)
    else:
        approach = resolve_approach(args.approach, args.model_dir)
        print("watchdog: OFF (--generation-timeout 0) — a wedged generation holds the GPU until killed by hand", flush=True)
    if deadline is not None:
        print("deadline: stops between clips at {}".format(dt.datetime.fromtimestamp(deadline).strftime("%Y-%m-%d %H:%M")),
              flush=True)
    print("loading {} …".format(spec["model"]), flush=True)
    load_info = approach.load()
    print("loaded in {:.1f}s; weights sha256 {}".format(load_info["load_s"], load_info["weights_sha256"][:12]), flush=True)
    record = build_run_record(manifest, manifest_path, approach, load_info, frames,
                              args.limit, args.corpus, run_id, selection)
    if run_path.is_file():
        # Resume: keep the first run record, append this session's load timing.
        previous = json.loads(run_path.read_text(encoding="utf-8"))
        previous.setdefault("resumed", []).append({"at": utc_now(), "load_s": load_info["load_s"]})
        write_json(run_path, previous)
    else:
        write_json(run_path, record)
    try:
        if spec["windows"]:
            progress = run_corpus_a1(entries, out_dir, approach, frames, record, ocr_sampler=spec["ocr_sampler"],
                                     deadline=deadline)
            print("done {} skipped {} failed {} timeouts {} s/frame {} s/window {} state {}".format(
                progress["done"], progress["skipped_resume"], progress["failed"], progress.get("timeouts", 0),
                progress["s_per_frame"], progress["s_per_window"], progress["state"]))
        else:
            progress = run_corpus(entries, out_dir, approach, frames, record, deadline=deadline)
            print("done {} skipped {} failed {} timeouts {} s/frame {} state {}".format(
                progress["done"], progress["skipped_resume"], progress["failed"], progress.get("timeouts", 0),
                progress["s_per_frame"], progress["state"]))
    finally:
        if isinstance(approach, SubprocessApproach):
            stats = approach.stats()
            approach.close()
            if stats["timeouts"] or stats["respawns"]:
                print("watchdog: {} timeouts, {} respawns".format(stats["timeouts"], stats["respawns"]), flush=True)
    return 3 if progress["state"] == "deadline" else 0


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
            "s_per_clip": _rate(gen_seconds + rip_seconds, clips_done - clips_unreadable)
            if clips_done - clips_unreadable > 0 else None,
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


# ---------------------------------------------------------------------------
# Summarize A1 (aggregates only)
# ---------------------------------------------------------------------------
def read_clip_records(path: Path) -> Dict[str, Any]:
    """header, A0-shaped `result` records, A1 `window_result` records, footer."""
    out: Dict[str, Any] = {"header": None, "results": [], "window_results": [], "footer": None}
    with Path(path).open(encoding="utf-8") as stream:
        for line in stream:
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            kind = record.get("record_type")
            if kind == "clip":
                out["header"] = record
            elif kind == "result":
                out["results"].append(record)
            elif kind == "window_result":
                out["window_results"].append(record)
            elif kind == "clip_done":
                out["footer"] = record
    return out


def clip_year_range(window_results: Sequence[Dict[str, Any]]) -> Optional[Tuple[float, float]]:
    """One range per clip from its schema-valid `era` windows: [median of the
    windows' FROM years, median of their TO years] (median(lo) ≤ median(hi) because
    every lo ≤ its hi).  No valid window → None (no answer).  Validity is re-checked
    by decoding the raw text again — the stored flag is never trusted on its own."""
    los: List[int] = []
    his: List[int] = []
    for record in window_results:
        if record.get("family") != "era" or record.get("error"):
            continue
        value, _ = decode_contract("era", record.get("raw_text") or "")
        if value is None:
            continue
        los.append(value["yearRange"][0])
        his.append(value["yearRange"][1])
    if not los:
        return None
    return float(statistics.median(los)), float(statistics.median(his))


def score_a1_era_clip(truth_year: int, window_results: Sequence[Dict[str, Any]]) -> Dict[str, Any]:
    span = clip_year_range(window_results)
    if span is None:
        return {"truth": truth_year, "guess": None, "abs_err": None, "inside": None, "width": None}
    lo, hi = span
    mid = (lo + hi) / 2.0
    return {"truth": truth_year, "guess": mid, "abs_err": abs(mid - truth_year),
            "inside": lo <= truth_year <= hi, "width": hi - lo, "range": [lo, hi]}


def aggregate_a1_era(rows: Sequence[Dict[str, Any]]) -> Dict[str, Any]:
    base = aggregate_era(rows)
    answered = [r for r in rows if r["abs_err"] is not None]
    inside = sum(1 for r in answered if r["inside"])
    base.update({
        "answered_rate": _rate(len(answered), len(rows)),
        "inside_of_answered": _rate(inside, len(answered)),
        "inside_of_all": _rate(inside, len(rows)),
        "median_width_years": statistics.median(r["width"] for r in answered) if answered else None,
    })
    return base


def _reason_class(reason: Optional[str]) -> str:
    """A fixed label per schemaInvalid reason, so the Markdown never quotes model text."""
    text = reason or ""
    for prefix, label in (("generation error", "generation error"), ("empty response", "empty"),
                          ("not valid JSON", "not JSON (prose, fence, truncated, trailing text)"),
                          ("wrong type at 'top level'", "not an object"), ("unknown key", "unknown key"),
                          ("missing key", "missing key"), ("duplicate key", "duplicate key"),
                          ("null at", "null value"), ("wrong type", "wrong type"),
                          ("unknown family", "wrong family"), ("family '", "wrong family"),
                          ("year ", "year outside 1900…2100"), ("yearRange", "yearRange shape / reversed"),
                          ("window", "window shape"), ("selfConfidence", "selfConfidence outside 0…1"),
                          ("'kind' word", "cue kind not in vocabulary"), ("'setting' word", "setting not in vocabulary"),
                          ("response is", "oversize")):
        if text.startswith(prefix):
            return label
    if "is empty" in text or "empty item" in text:
        return "empty text"
    if "frame time" in text:
        return "bad atS"
    if "cap" in text:
        return "list over cap"
    return "other"


_SAFE_FEATURE = re.compile(r"^[a-z][a-z \-]{0,38}[a-z]$")


def safe_feature(text: str) -> Optional[str]:
    """A feature string fit for the repo: lowercase letters, spaces and hyphens only
    (≤ 40 chars).  Anything with a capital (a possible proper noun), a digit, an
    apostrophe or punctuation is dropped from the printed list, never rewritten."""
    candidate = (text or "").strip()
    return candidate if _SAFE_FEATURE.match(candidate) else None


def summarize_a1_run(run_dir: Path, manifest: Dict[str, Any]) -> Dict[str, Any]:
    run_dir = Path(run_dir)
    run_record = json.loads((run_dir / "run.json").read_text(encoding="utf-8")) if (run_dir / "run.json").is_file() else {}
    progress = json.loads((run_dir / "progress.json").read_text(encoding="utf-8")) if (run_dir / "progress.json").is_file() else {}
    by_digest: Dict[str, List[Dict[str, Any]]] = collections.defaultdict(list)
    for clip in manifest["clips"]:
        by_digest[clip["digest"]].append(clip)
    era_rows: List[Tuple[str, Dict[str, Any]]] = []
    ocr_rows: List[Tuple[str, Dict[str, Any]]] = []
    family_counts: Dict[str, collections.Counter] = {f: collections.Counter() for f in A1_FAMILY_ORDER}
    invalid_classes: Dict[str, collections.Counter] = {f: collections.Counter() for f in A1_FAMILY_ORDER}
    features: collections.Counter = collections.Counter()
    printable_features: collections.Counter = collections.Counter()
    settings: collections.Counter = collections.Counter()
    feature_items = dropped_features = 0
    frames = windows = window_gens = date_gens = errors = 0
    gen_s = window_gen_s = rip_s = 0.0
    peak_rss = 0
    clips_done = clips_partial = clips_unreadable = 0
    clip_dir = run_dir / "clips"
    for path in sorted(clip_dir.glob("*.jsonl")) if clip_dir.is_dir() else []:
        rec = read_clip_records(path)
        header, footer = rec["header"], rec["footer"]
        if header is None or not by_digest.get(header["digest"]):
            continue
        if footer is None:
            clips_partial += 1
        else:
            clips_done += 1
            peak_rss = max(peak_rss, int(footer.get("peak_rss_bytes") or 0))
        if not rec["results"] and not rec["window_results"]:
            clips_unreadable += 1
            continue
        frames += int(footer.get("frames_ok") or 0) if footer else 0
        # rip seconds: per window record pair once (window rip_s), else per date frame
        ripped_windows = set()
        for r in rec["window_results"]:
            gen_s += float(r.get("elapsed_s") or 0.0)
            window_gen_s += float(r.get("elapsed_s") or 0.0)
            window_gens += 1
            errors += 1 if r.get("error") else 0
            if r["window_index"] not in ripped_windows:
                ripped_windows.add(r["window_index"])
                rip_s += float(r.get("rip_s") or 0.0)
            family = r.get("family")
            if family not in family_counts:
                continue
            value, reason = (None, "generation error") if r.get("error") else decode_contract(family, r.get("raw_text") or "")
            family_counts[family]["windows"] += 1
            if value is None:
                invalid_classes[family][_reason_class(reason)] += 1
                continue
            family_counts[family]["valid"] += 1
            if family == "roomFeatures":
                settings[value["setting"]] += 1
                for item in value["features"]:
                    feature_items += 1
                    features[item.strip().lower()] += 1          # vocabulary size: a number only
                    printable = safe_feature(item)               # judged on the RAW string, before lowercasing
                    if printable is None:
                        dropped_features += 1
                    else:
                        printable_features[printable] += 1
        windows += len(ripped_windows)
        for r in rec["results"]:
            gen_s += float(r.get("elapsed_s") or 0.0)
            date_gens += 1
            errors += 1 if r.get("error") else 0
            if r.get("window_index") not in ripped_windows:
                rip_s += float(r.get("rip_s") or 0.0)
        for entry in by_digest[header["digest"]]:
            if entry["corpus"] == "era":
                era_rows.append((entry["stratum"], score_a1_era_clip(int(entry["truth"]["year"]), rec["window_results"])))
            elif entry["corpus"] == "ocr":
                ocr_rows.append((entry["stratum"], score_ocr_clip(entry["truth"]["date"], rec["results"])))

    def grouped(rows, key, agg):
        groups: Dict[str, List[Dict[str, Any]]] = collections.defaultdict(list)
        for stratum, row in rows:
            groups[key(stratum)].append(row)
        return {name: agg(items) for name, items in sorted(groups.items())}

    def decade_of(stratum: str) -> str:
        parts = stratum.split("/")
        return parts[1] if len(parts) > 1 else stratum

    scored_clips = clips_done - clips_unreadable
    # Ties broken alphabetically so the list is stable run to run.
    safe_top = sorted(printable_features.items(), key=lambda kv: (-kv[1], kv[0]))[:20]
    return {
        "record_type": "summary_a1",
        "generated_at": utc_now(),
        "approach_id": run_record.get("approach_id", A1_APPROACH_ID),
        "run_id": run_record.get("run_id"),
        "model": run_record.get("model"),
        "weights_sha256": run_record.get("weights_sha256"),
        "sampler_id": run_record.get("sampler_id"),
        "frames_per_window": run_record.get("frames_per_window"),
        "host": run_record.get("host"),
        "platform": run_record.get("platform"),
        "mlx_vlm_version": run_record.get("mlx_vlm_version"),
        "mlx_version": run_record.get("mlx_version"),
        "git_sha": run_record.get("git_sha"),
        "corpus_hash": run_record.get("corpus_hash") or manifest.get("corpus_hash"),
        "prompts_sha256": run_record.get("prompts_sha256"),
        "selection": run_record.get("selection"),
        "load_s": run_record.get("load_s"),
        "run_state": progress.get("state", "unknown"),
        "clips": {"done": clips_done, "partial": clips_partial, "unreadable": clips_unreadable,
                  "era_scored": len(era_rows), "ocr_scored": len(ocr_rows),
                  "era_in_manifest": manifest["counts"]["era"], "ocr_in_manifest": manifest["counts"]["ocr"]},
        "cost": {
            "frames": frames, "windows": windows, "window_generations": window_gens, "date_generations": date_gens,
            "errors": errors,
            "s_per_clip": _rate(gen_s + rip_s, scored_clips) if scored_clips > 0 else None,
            "s_per_frame": _rate(gen_s, frames) if frames else None,
            "s_per_window_generation": _rate(window_gen_s, window_gens) if window_gens else None,
            "s_per_date_generation": _rate(gen_s - window_gen_s, date_gens) if date_gens else None,
            "rip_s_per_frame": _rate(rip_s, frames) if frames else None,
            "peak_rss_gb": round(peak_rss / 1e9, 2) if peak_rss else None,
        },
        "schema": {f: {"windows": c["windows"], "valid": c["valid"], "valid_rate": _rate(c["valid"], c["windows"]),
                       "invalid_by_class": dict(invalid_classes[f].most_common())}
                   for f, c in family_counts.items()},
        "era": {
            "all": aggregate_a1_era([row for _, row in era_rows]),
            "by_family": grouped(era_rows, lambda s: s.split("/")[0], aggregate_a1_era),
            "by_decade": grouped(era_rows, decade_of, aggregate_a1_era),
            "by_stratum": grouped(era_rows, lambda s: s, aggregate_a1_era),
            # family × decade ("camera/2020s"): used by the A2 reading, not printed as a table
            "by_family_decade": grouped(era_rows, lambda s: "/".join(s.split("/")[:2]), aggregate_a1_era),
        },
        "ocr": {
            "all": aggregate_ocr([row for _, row in ocr_rows]),
            "by_stratum": grouped(ocr_rows, lambda s: s, aggregate_ocr),
        },
        "ocr_sampler": run_record.get("ocr_sampler", OCR_SAMPLER_WINDOW_FRAMES),
        "room": {
            "valid": family_counts["roomFeatures"]["valid"],
            "feature_items": feature_items,
            "vocabulary": len(features),
            "dropped_unsafe_items": dropped_features,
            "settings": dict(settings.most_common()),
            "top20": safe_top,
        },
    }


def a1_vs_a0_reading(a1: Dict[str, Any], a0: Optional[Dict[str, Any]]) -> List[str]:
    """Three generated sentences — numbers only, no judgement words added by hand."""
    e1 = a1["era"]["all"]
    o1 = a1["ocr"]["all"]
    c1 = a1["cost"]
    if a0 is None:
        return ["*(no A0 run passed to `summarize`; the A1-vs-A0 reading needs both runs)*"]
    e0 = a0["era"]["all"]
    o0 = a0["ocr"]["all"]
    c0 = a0["cost"]
    answered0 = _rate(e0["answered"], e0["n"])
    lines = [
        "1. **Answered rate:** A0 {} → A1 {} of {} readable ERA clips; MAE {} → {} y where answered; "
        "±5 y of all clips {} → {}; truth inside A1's range {} of answered (median width {} y).".format(
            _pct(answered0), _pct(e1.get("answered_rate")), e1["n"], _num(e0["mae_years"]), _num(e1["mae_years"]),
            _pct(e0["within_5_of_all"]), _pct(e1["within_5_of_all"]), _pct(e1.get("inside_of_answered")),
            _num(e1.get("median_width_years"))),
        "2. **OCR (same `date` prompt):** any-frame exact {} → {}, majority exact {} → {}, year match {} → {} "
        "(A1 reads {} frames per OCR clip vs A0's 5, which favours any-frame; majority is the fairer comparison).".format(
            _pct(o0["any_frame_exact"]), _pct(o1["any_frame_exact"]), _pct(o0["majority_exact"]),
            _pct(o1["majority_exact"]), _pct(o0["year_match"]), _pct(o1["year_match"]),
            _num(_rate(o1["date_frames"], o1["n"]) if o1["n"] else None, "{:.0f}")),
        "3. **Cost:** {} s/clip (A0) → {} s/clip (A1, era + roomFeatures windows plus OCR date frames); "
        "{} s per multi-image window generation; peak RSS {} → {} GB.".format(
            _num(c0.get("s_per_clip")), _num(c1.get("s_per_clip")), _num(c1.get("s_per_window_generation"), "{:.2f}"),
            _num(c0.get("peak_rss_gb"), "{:.2f}"), _num(c1.get("peak_rss_gb"), "{:.2f}")),
    ]
    return lines


A1_HEADING = "chronological windows + strict JSON contract (same model and weights)"
A1_OCR_HEADING = "OCR — A0's `date` prompt on the A1 window frames"
A1_OCR_NOTE = "Same truth and columns as A0. A1 reads every window frame (up to 3 × N per clip) instead of 5 stills."


def format_a1_markdown(summary: Dict[str, Any], a0: Optional[Dict[str, Any]] = None, *,
                       heading: str = A1_HEADING, reading_title: str = "A1 vs A0",
                       reading: Optional[List[str]] = None, sampler_note: str = "",
                       ocr_heading: str = A1_OCR_HEADING, ocr_note: str = A1_OCR_NOTE) -> str:
    """A windowed approach's section (A1, and A2 with its own labels; aggregates
    only; same privacy rules as A0's).  Defaults reproduce the A1 section."""
    lines: List[str] = []
    lines.append("## Approach `{}` — {}".format(summary["approach_id"], heading))
    lines.append("")
    lines.append("**{}**".format(reading_title))
    lines.append("")
    lines.extend(reading if reading is not None else a1_vs_a0_reading(summary, a0))
    lines.append("")
    clips = summary["clips"]
    cost = summary["cost"]
    lines.append("| Run | Value |")
    lines.append("|---|---|")
    lines.append("| generated | {} |".format(summary["generated_at"]))
    lines.append("| run id | {} |".format(summary.get("run_id") or "—"))
    lines.append("| model | `{}` |".format(summary.get("model") or "—"))
    lines.append("| weights sha256 (first 12) | `{}` |".format(_short(summary.get("weights_sha256"))))
    lines.append("| sampler | `{}` (≤ {} windows — start / middle / end of the middle 90 %, each ≤ {:.0f} s, "
                 "{} frames each shown together in one prompt; a middle-90 % span under {:.0f} s gets one window){} |".format(
                     summary.get("sampler_id") or "—", A1_MAX_WINDOWS, A1_WINDOW_MAX_S,
                     summary.get("frames_per_window") or "—", A1_MAX_WINDOWS * A1_MIN_WINDOW_S, sampler_note))
    lines.append("| prompts | era / roomFeatures strict JSON (§3.3), OCR `date` verbatim from A0; sha256 first 12: {} |".format(
        ", ".join("{} `{}`".format(k, _short(v)) for k, v in sorted((summary.get("prompts_sha256") or {}).items())) or "—"))
    lines.append("| decoding | fail-closed mirror of `ContractDecoder`: raw text must be exactly one JSON object; "
                 "unknown key, wrong type, null, missing key, wrong family, year outside 1900…2100, reversed range → "
                 "`schemaInvalid`; never repaired |")
    lines.append("| host | {} · {} |".format(summary.get("host") or "—", summary.get("platform") or "—"))
    lines.append("| mlx-vlm / mlx | {} / {} |".format(summary.get("mlx_vlm_version") or "—", summary.get("mlx_version") or "—"))
    lines.append("| git | `{}` |".format(_short(summary.get("git_sha"))))
    lines.append("| corpus hash (first 12) | `{}` |".format(_short(summary.get("corpus_hash"))))
    lines.append("| run state | {}{} |".format(summary.get("run_state", "unknown"),
                                             " · selection {}".format(summary["selection"]) if summary.get("selection") else ""))
    lines.append("| clips | {} done · {} partial · {} unreadable · ERA scored {}/{} · OCR scored {}/{} |".format(
        clips["done"], clips["partial"], clips["unreadable"], clips["era_scored"], clips["era_in_manifest"],
        clips["ocr_scored"], clips["ocr_in_manifest"]))
    if clips["era_scored"] + clips["ocr_scored"] + clips["unreadable"] < clips["era_in_manifest"] + clips["ocr_in_manifest"]:
        lines.append("")
        lines.append("**Partial run:** the tables below cover only the clips scored so far.")
    lines.append("")
    lines.append("### Cost")
    lines.append("")
    lines.append("| Metric | Value |")
    lines.append("|---|---|")
    lines.append("| model load | {} s |".format(_num(summary.get("load_s"))))
    lines.append("| s / clip (all generations + ffmpeg) | {} |".format(_num(cost["s_per_clip"], "{:.1f}")))
    lines.append("| s / frame (all generations ÷ frames ripped) | {} |".format(_num(cost["s_per_frame"], "{:.2f}")))
    lines.append("| s / window generation (multi-image, era or roomFeatures) | {} |".format(
        _num(cost["s_per_window_generation"], "{:.2f}")))
    lines.append("| s / OCR date generation (one frame) | {} |".format(_num(cost["s_per_date_generation"], "{:.2f}")))
    lines.append("| ffmpeg rip s / frame | {} |".format(_num(cost["rip_s_per_frame"], "{:.2f}")))
    lines.append("| peak RSS | {} GB |".format(_num(cost["peak_rss_gb"], "{:.2f}")))
    lines.append("| frames · windows · window gens · date gens · errors | {} · {} · {} · {} · {} |".format(
        cost["frames"], cost["windows"], cost["window_generations"], cost["date_generations"], cost["errors"]))
    lines.append("")
    lines.append("### Schema-valid rate per family (per window)")
    lines.append("")
    lines.append("| Family | windows | schema-valid | rate | invalid, by reason |")
    lines.append("|---|---|---|---|---|")
    for family, agg in summary["schema"].items():
        reasons = ", ".join("{} {}".format(name, n) for name, n in agg["invalid_by_class"].items()) or "—"
        lines.append("| {} | {} | {} | {} | {} |".format(family, agg["windows"], agg["valid"], _pct(agg["valid_rate"]), reasons))
    lines.append("")
    lines.append("### ERA — yearRange vs truth")
    lines.append("")
    lines.append("Rule: a schema-valid `era` window is an answer. Per clip, range = [median FROM, median TO] over its "
                 "valid windows; point estimate = the range midpoint (MAE, ±5 y). *inside* = truth year within the "
                 "range, inclusive. A clip with no valid window is **no answer** (excluded from MAE, counted in the "
                 "rate). Truth as for A0.")
    lines.append("")
    lines.append("| Group | n | answered | no answer | MAE y | median y | ±5 y (answered) | ±5 y (all) | inside range (answered) | inside range (all) | median width y |")
    lines.append("|---|---|---|---|---|---|---|---|---|---|---|")

    def era_row(name: str, agg: Dict[str, Any]) -> str:
        return "| {} | {} | {} | {} | {} | {} | {} | {} | {} | {} | {} |".format(
            name, agg["n"], agg["answered"], _pct(agg["no_answer_rate"]), _num(agg["mae_years"]),
            _num(agg["median_err_years"]), _pct(agg["within_5_of_answered"]), _pct(agg["within_5_of_all"]),
            _pct(agg["inside_of_answered"]), _pct(agg["inside_of_all"]), _num(agg["median_width_years"]))

    era = summary["era"]
    lines.append(era_row("**all**", era["all"]))
    for name, agg in era["by_family"].items():
        lines.append(era_row("family: {}".format(name), agg))
    for name, agg in era["by_decade"].items():
        lines.append(era_row("decade: {}".format(name), agg))
    for name, agg in era["by_stratum"].items():
        lines.append(era_row("stratum: {}".format(name), agg))
    lines.append("")
    lines.append("### " + ocr_heading)
    lines.append("")
    lines.append(ocr_note)
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
    room = summary["room"]
    lines.append("### roomFeatures")
    lines.append("")
    lines.append("No ground truth yet (design §4: needs Rick's place labels); reported for shape only. Vocabulary = "
                 "distinct lower-cased feature strings over schema-valid windows. The top-20 list prints only strings "
                 "of lowercase letters, spaces and hyphens; any string with a capital, digit or punctuation is "
                 "counted but never printed.")
    lines.append("")
    lines.append("| Metric | Value |")
    lines.append("|---|---|")
    lines.append("| schema-valid windows | {} of {} ({}) |".format(
        room["valid"], summary["schema"]["roomFeatures"]["windows"], _pct(summary["schema"]["roomFeatures"]["valid_rate"])))
    lines.append("| feature items · distinct vocabulary | {} · {} |".format(room["feature_items"], room["vocabulary"]))
    lines.append("| items not printable (capital / digit / punctuation) | {} |".format(room["dropped_unsafe_items"]))
    lines.append("| setting | {} |".format(", ".join("{} {}".format(k, v) for k, v in room["settings"].items()) or "—"))
    lines.append("")
    lines.append("| # | feature | occurrences (a window may repeat an item) |")
    lines.append("|---|---|---|")
    for rank, (name, count) in enumerate(room["top20"], 1):
        lines.append("| {} | {} | {} |".format(rank, name, count))
    lines.append("")
    return "\n".join(lines) + "\n"


def _era_mae(summary: Optional[Dict[str, Any]], group: str, name: str) -> Optional[float]:
    if summary is None:
        return None
    agg = (summary.get("era") or {}).get(group, {}).get(name)
    return agg.get("mae_years") if agg else None


def a2_reading(a2: Dict[str, Any], a0: Optional[Dict[str, Any]], a1: Optional[Dict[str, Any]]) -> List[str]:
    """Three generated sentences for A2 against A0 and A1 — numbers only.
    Missing baselines print as "—" rather than being invented."""
    e2, o2, c2 = a2["era"]["all"], a2["ocr"]["all"], a2["cost"]
    o0 = a0["ocr"]["all"] if a0 else {}
    c1 = a1["cost"] if a1 else {}
    e1 = a1["era"]["all"] if a1 else {}
    return [
        "1. **Era (bigger model):** MAE on Rick-dated clips A0 {} / A1 {} / A2 {} y; on camera-dated 2020s "
        "A1 {} → A2 {} y; all readable ERA clips A1 {} → A2 {} y, truth inside the range {} → {} of answered "
        "(median width {} → {} y), answered {} → {}.".format(
            _num(_era_mae(a0, "by_family", "rick-dated")), _num(_era_mae(a1, "by_family", "rick-dated")),
            _num(_era_mae(a2, "by_family", "rick-dated")), _num(_era_mae(a1, "by_family_decade", "camera/2020s")),
            _num(_era_mae(a2, "by_family_decade", "camera/2020s")), _num(e1.get("mae_years")),
            _num(e2.get("mae_years")), _pct(e1.get("inside_of_answered")), _pct(e2.get("inside_of_answered")),
            _num(e1.get("median_width_years")), _num(e2.get("median_width_years")),
            _pct(e1.get("answered_rate")), _pct(e2.get("answered_rate"))),
        "2. **OCR (A0's 5 stills and `date` prompt, 8B model):** any-frame exact A0 {} → A2 {}, majority exact "
        "{} → {}, year match {} → {} (same sampler and prompt as A0; only the model differs).".format(
            _pct(o0.get("any_frame_exact")), _pct(o2.get("any_frame_exact")), _pct(o0.get("majority_exact")),
            _pct(o2.get("majority_exact")), _pct(o0.get("year_match")), _pct(o2.get("year_match"))),
        "3. **Cost vs A1:** {} → {} s/clip; {} → {} s per multi-image window generation; {} → {} s per OCR date "
        "generation; peak RSS {} → {} GB; model load {} s.".format(
            _num(c1.get("s_per_clip")), _num(c2.get("s_per_clip")),
            _num(c1.get("s_per_window_generation"), "{:.2f}"), _num(c2.get("s_per_window_generation"), "{:.2f}"),
            _num(c1.get("s_per_date_generation"), "{:.2f}"), _num(c2.get("s_per_date_generation"), "{:.2f}"),
            _num(c1.get("peak_rss_gb"), "{:.2f}"), _num(c2.get("peak_rss_gb"), "{:.2f}"), _num(a2.get("load_s"))),
    ]


A2_HEADING = "Qwen3-VL-8B through A1's windows and contracts; OCR on A0's stills"
A2_OCR_HEADING = "OCR — A0's sampler (5 stills, middle 90 %) and `date` prompt on the 8B model"
A2_OCR_NOTE = ("Same truth and columns as A0. A2 routes the OCR corpus to A0's sampler (5 spread stills, one frame "
               "per call) — the \"one engine, two samplers\" finding from A1 — so only the model differs from A0.")


def format_a2_markdown(summary: Dict[str, Any], a0: Optional[Dict[str, Any]] = None,
                       a1: Optional[Dict[str, Any]] = None) -> str:
    return format_a1_markdown(
        summary, a0, heading=A2_HEADING, reading_title="A2 vs A0 and A1", reading=a2_reading(summary, a0, a1),
        sampler_note="; OCR corpus: `{}`".format(SAMPLER_ID_TEMPLATE.format(n=A2_OCR_STILLS)),
        ocr_heading=A2_OCR_HEADING, ocr_note=A2_OCR_NOTE)


def summarize_command(args: argparse.Namespace) -> int:
    manifest = load_manifest(Path(args.manifest))
    a0_summary = a1_summary = a2_summary = None
    for run in args.run:
        run_json = Path(run) / "run.json"
        approach = json.loads(run_json.read_text(encoding="utf-8")).get("approach_id") if run_json.is_file() else APPROACH_ID
        if approach == A2_APPROACH_ID:
            a2_summary = summarize_a1_run(Path(run), manifest)
        elif approach == A1_APPROACH_ID:
            a1_summary = summarize_a1_run(Path(run), manifest)
        else:
            a0_summary = summarize_run(Path(run), manifest)
    parts: List[str] = []
    if a0_summary is not None:
        parts.append(format_summary_markdown(a0_summary))
    else:
        parts.append("# Video LLM benchmarks\n\n*Written by `tools/video-llm-bench/bench.py summarize`; aggregates only.*\n\n")
    if a1_summary is not None:
        parts.append(format_a1_markdown(a1_summary, a0_summary))
    if a2_summary is not None:
        parts.append(format_a2_markdown(a2_summary, a0_summary, a1_summary))
    markdown = "".join(parts)
    if args.out:
        out = Path(args.out)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(markdown, encoding="utf-8")
    if args.json_out:
        Path(args.json_out).write_text(json.dumps({"a0": a0_summary, "a1": a1_summary, "a2": a2_summary}, indent=1, sort_keys=True),
                                       encoding="utf-8")
    print(markdown)
    return 0


# ---------------------------------------------------------------------------
def make_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)

    validate = commands.add_parser("validate-corpus", help="build the frozen ERA/OCR manifest from a catalog .backup copy")
    validate.add_argument("--catalog", required=True, help="READ-ONLY .backup copy of the catalog database (never the live file)")
    validate.add_argument("--out", required=True, help="manifest JSON (keep it under .scratch/)")
    validate.add_argument("--seed", type=int, default=DEFAULT_SEED)
    validate.add_argument("--camera-target", type=int, default=ERA_CAMERA_TARGET)
    validate.add_argument("--ocr-target", type=int, default=OCR_TARGET)
    validate.set_defaults(func=validate_corpus_command)

    run = commands.add_parser("run", help="run an approach over a manifest; resume-safe")
    run.add_argument("--manifest", required=True)
    run.add_argument("--approach", default=APPROACH_ID, choices=list(APPROACHES))
    run.add_argument("--frames", type=int, default=None,
                     help="a0-py: stills per clip (default 5); a1-py / a2-py: frames per window (default 6)")
    run.add_argument("--smoke", type=int, default=None,
                     help="only the first ERA clip (>= 60 s) of each of K distinct decades — the N calibration set")
    run.add_argument("--limit", type=int, default=None, help="first N clips (after --corpus filter)")
    run.add_argument("--corpus", choices=["era", "ocr"], default=None, help="only this corpus")
    run.add_argument("--out", required=True, help="run directory (keep it under .scratch/)")
    run.add_argument("--model-dir", default=None,
                     help="local snapshot directory of the model (offline); default: HF cache via snapshot_download")
    run.add_argument("--generation-timeout", type=float, default=DEFAULT_GENERATION_TIMEOUT_S,
                     help="seconds a single generation may take before the worker is killed and the model reloaded "
                          "(#406; default {:.0f}; 0 = no worker process, no cap)".format(DEFAULT_GENERATION_TIMEOUT_S))
    run.add_argument("--load-timeout", type=float, default=DEFAULT_LOAD_TIMEOUT_S,
                     help="seconds the model load may take in the worker (default {:.0f})".format(DEFAULT_LOAD_TIMEOUT_S))
    run.add_argument("--deadline", default=None,
                     help="HH:MM local; the run stops BETWEEN clips at that time (resume-safe, exit code 3)")
    run.set_defaults(func=run_command)

    worker = commands.add_parser("worker", help="(internal) the watchdog's model process; JSON lines on stdin/stdout")
    worker.add_argument("--factory", required=True, help="approach:<id>:<model_dir> or import:<dir>:<module>:<attr>")
    worker.set_defaults(func=worker_command)

    summarize = commands.add_parser("summarize", help="aggregates only → Markdown (+ stdout)")
    summarize.add_argument("--run", required=True, action="append",
                           help="run directory; repeat to put A0 and A1 side by side (approach read from run.json)")
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
