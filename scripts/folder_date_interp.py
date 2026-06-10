#!/usr/bin/env python3
"""Folder-coherence date interpolation for the catalog.

Problem: many catalog records lack an inferredRecordDate (the
dossier pipeline only sets it when OCR + Whisper + scene signals
triangulate above the confidence floor). But files SIT IN FOLDERS,
and a folder's other clips often have well-dated siblings. If 5 of
12 clips in "Cape Cod 1997" are dated 1997 by dossier, the other 7
are almost certainly 1997 too — even if their VLM signal was weak.

This script fills in those gaps. For every directory with at least
2 dossier-dated siblings, it proposes a date for the directory's
undated records: the median year of the signals, mid-year date,
confidence reduced (default 0.55, well below dossier's typical
0.85+).

Output: JSONL deltas at /Volumes/Crucial2TB/dossier-deltas/
folder-interp.jsonl. The existing merger
(scripts/merge_dossier_jsonl.py) picks these up and applies them
to catalog.json with the same schema validation, atomic rename,
and manifest re-stamping as the worker JSONLs.

Critical design choices (Rick 2026-06-08 audit):

- **We do NOT set dossierProcessedAt.** Folder interpolation is
  not dossier work — no VLM ran. Setting it would inflate the
  "29% dossier'd" dial dishonestly. Only inferredRecordDate
  and inferredDateConfidence are written.
- **Require >=2 signals per folder.** Single signal is too easy
  to spoof (a misdated VLM hit shouldn't propagate to every
  sibling).
- **Median, not mean.** Robust to outlier years (e.g. one file
  whose VLM saw a date burn-in from a different era).
- **Propose mid-year date (June 15).** We only know year-level
  granularity from the median; pretending to know month/day
  would be a lie.
- **Don't touch records that already have inferredRecordDate.**
  Dossier's evidence outranks folder coherence — if a record's
  own VLM found a strong date, leave it alone.

Run:
  scripts/folder_date_interp.py
  # or with custom catalog/output paths:
  scripts/folder_date_interp.py --catalog ~/path/to/catalog.json \\
      --output /Volumes/Crucial2TB/dossier-deltas/folder-interp.jsonl \\
      [--min-signals 2] [--confidence 0.55] [--dry-run]
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import statistics
import sys
from collections import defaultdict
from pathlib import Path
from typing import Iterable

DEFAULT_CATALOG = Path("~/Library/Application Support/VideoScan/catalog.json").expanduser()
DEFAULT_OUTPUT = Path("/Volumes/Crucial2TB/dossier-deltas/folder-interp.jsonl")


def parse_iso_year(s: str | None) -> int | None:
    """Best-effort year extraction from an ISO 8601 date string.
    Tolerant of TZ suffix variants. Returns None on parse failure."""
    if not s:
        return None
    try:
        # Strip Z or TZ offset, take first 4 chars after possible quote stripping.
        # Most workers emit ISO like "1991-06-21T12:00:00+00:00" or "...Z".
        clean = s.replace("Z", "+00:00")
        # Fast path: first 4 chars are year if it's well-formed ISO.
        if len(clean) >= 4 and clean[:4].isdigit():
            y = int(clean[:4])
            if 1900 <= y <= 2099:
                return y
    except Exception:
        return None
    return None


def folder_signal_years(records: list[dict]) -> list[int]:
    """Extract usable year signals from records in a folder.
    A record contributes its inferredRecordDate year if present.
    Out-of-range years (<1900 or >2099) are silently dropped — those
    are almost always parse errors, not real history."""
    years: list[int] = []
    for r in records:
        y = parse_iso_year(r.get("inferredRecordDate"))
        if y is not None:
            years.append(y)
    return years


def propose_date_for_year(year: int) -> str:
    """Mid-year ISO date for a given year. June 15 12:00 UTC — placeholder
    consistent with how the rest of the pipeline emits dates for
    year-only inferences."""
    return f"{year:04d}-06-15T12:00:00+00:00"


def compute_interpolations(
    records: list[dict],
    *,
    min_signals: int = 2,
    confidence: float = 0.55,
) -> list[dict]:
    """Return a list of JSONL delta dicts (one per record that gets a
    new inferred date). Pure function — no IO. Easy to test.

    Each delta has the shape the merger expects:
        {"fullPath": "...", "host": "folder-interp",
         "ts": "<iso now>", "fields": {...}}

    `fields` includes ONLY the date+confidence keys; we deliberately
    don't write dossierProcessedAt (see module docstring)."""
    by_dir: dict[str, list[dict]] = defaultdict(list)
    for rec in records:
        d = rec.get("directory") or ""
        by_dir[d].append(rec)

    deltas: list[dict] = []
    now = dt.datetime.now(dt.timezone.utc).isoformat()
    for directory, recs in by_dir.items():
        if not directory:
            continue  # records without a directory aren't a coherent folder
        signal_years = folder_signal_years(recs)
        if len(signal_years) < min_signals:
            continue
        # Robust central tendency: integer median (rounded down for ties).
        median_year = int(statistics.median(signal_years))
        proposed_iso = propose_date_for_year(median_year)
        # Candidates: same directory, no inferredRecordDate yet.
        for cand in recs:
            if cand.get("inferredRecordDate"):
                continue
            full = cand.get("fullPath")
            if not full:
                continue
            deltas.append({
                "fullPath": full,
                "host": "folder-interp",
                "ts": now,
                "fields": {
                    "inferredRecordDate": proposed_iso,
                    "inferredDateConfidence": confidence,
                },
            })
    return deltas


def write_deltas_jsonl(deltas: Iterable[dict], path: Path) -> int:
    """Append deltas as JSONL. Returns count written."""
    path.parent.mkdir(parents=True, exist_ok=True)
    count = 0
    with path.open("a") as f:
        for d in deltas:
            f.write(json.dumps(d, ensure_ascii=False) + "\n")
            count += 1
    return count


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--catalog", type=Path, default=DEFAULT_CATALOG)
    ap.add_argument("--output", type=Path, default=DEFAULT_OUTPUT,
                    help="JSONL delta file the merger consumes.")
    ap.add_argument("--min-signals", type=int, default=2,
                    help="Minimum dated siblings required to interpolate (default 2).")
    ap.add_argument("--confidence", type=float, default=0.55,
                    help="Confidence value for interpolated dates (default 0.55).")
    ap.add_argument("--dry-run", action="store_true",
                    help="Print summary stats without writing anything.")
    args = ap.parse_args()

    try:
        catalog = json.loads(args.catalog.read_text())
    except Exception as e:
        print(f"ERROR reading {args.catalog}: {e}", file=sys.stderr)
        return 1

    records = catalog.get("records", [])
    print(f"records in catalog: {len(records)}")

    deltas = compute_interpolations(
        records,
        min_signals=args.min_signals,
        confidence=args.confidence,
    )
    print(f"folder-interpolated deltas: {len(deltas)}")
    # Per-year histogram of proposed years for sanity checking.
    year_hist: dict[int, int] = defaultdict(int)
    for d in deltas:
        iso = d["fields"]["inferredRecordDate"]
        y = parse_iso_year(iso) or 0
        year_hist[y] += 1
    if year_hist:
        print("year histogram of proposed dates:")
        for y in sorted(year_hist):
            print(f"  {y}: {year_hist[y]}")

    if args.dry_run:
        print("(dry run — no JSONL written)")
        return 0

    n = write_deltas_jsonl(deltas, args.output)
    print(f"wrote {n} delta(s) to {args.output}")
    print("merger will pick them up on its next poll cycle (~60s).")
    return 0


if __name__ == "__main__":
    sys.exit(main() or 0)
