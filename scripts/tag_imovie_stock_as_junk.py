#!/usr/bin/env python3
"""Tag unambiguous iMovie HD stock assets as confirmedJunk.

Rick 2026-06-10: many records on retired drives are iMovie HD's stock
title/transition generators (Animated Gradient, Bounce, Cartwheel,
Cross Through Center, Rolling Centered Credits, Typewriter, Scrolling
Block, Zoom, Push, etc). They're not family content — they're Apple's
shipped effect library that was copied along with iMovie projects.
They have no dossier'd siblings anywhere because they're junk on
every drive they appear on.

This script tags them with mediaDisposition = "confirmedJunk" so:
  - dossier_batch.py skips them (no wasted Qwen/Whisper compute)
  - CatalogCoverage skips them (dial stops looking stuck)
  - they show up in the catalog's existing "Delete Confirmed Junk…"
    UI when Rick decides to actually purge them

We're DELIBERATELY narrow: only filename prefixes that are 100% iMovie
HD generator templates. "Clip N.dv" is intentionally NOT in the list
because that's the same naming convention iMovie uses for real
captured footage from miniDV tapes — auto-tagging those would
destroy real family content.

Output: JSONL deltas at /Volumes/Crucial2TB/dossier-deltas/
junk-tagging.jsonl. The existing merger applies them.

Per-field provenance: dossierProcessedBy is NOT touched (this isn't
dossier work). Instead the record's `notes` field gets a marker:
"[auto-tagged confirmedJunk: iMovie stock asset]".
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import sys
from collections import defaultdict
from pathlib import Path

DEFAULT_CATALOG = Path("~/Library/Application Support/VideoScan/catalog.json").expanduser()
DEFAULT_OUTPUT = Path("/Volumes/Crucial2TB/dossier-deltas/junk-tagging.jsonl")

# Filename prefix patterns that are unambiguously iMovie HD stock
# title/transition assets. Each entry matches a filename starting with
# the given string (followed by a space, digit, or extension).
#
# Verified by inspecting Rick's catalog 2026-06-10 — these names
# appear ONLY in iMovie Projects' Media folders and never as real
# captured footage. If you're tempted to add "Clip" here, DON'T —
# Clip N.dv is also the name iMovie gives miniDV tape captures.
IMOVIE_STOCK_PREFIXES = [
    "Animated Gradient",
    "Bounce Across Multiple",
    "Bounce In To Center",
    "Cartwheel Multiple",
    "Centered Title",
    "Cross Dissolve",
    "Cross Through Center",
    "Disintegrate",
    "Drifting",
    "Fade In",
    "Fade Out",
    "Flying Letters",
    "Lens Flare",
    "Music Video",
    "Page Curl",
    "Push",
    "Radial",
    "Ripple",
    "Rolling Centered Credits",
    "Scrolling Block",
    "Subtitle",
    "Tumble",
    "Twirl",
    "Typewriter",
    "Unscramble",
    "Zoom",
]


def is_imovie_stock(filename: str) -> bool:
    """Return True iff `filename` starts with any unambiguous iMovie
    stock-asset prefix followed by a space, digit, or extension dot.
    The trailing requirement prevents false positives like "Pusher.mov".
    """
    if not filename:
        return False
    for prefix in IMOVIE_STOCK_PREFIXES:
        if not filename.startswith(prefix):
            continue
        # The next char after the prefix must be a delimiter, not a
        # letter. "Push" matches "Push 01.dv" but NOT "Pusher.mov".
        nxt = filename[len(prefix):len(prefix) + 1]
        if nxt in ("", " ", ".") or nxt.isdigit():
            return True
    return False


def compute_tag_deltas(records: list[dict]) -> list[dict]:
    """Pure function — given catalog records, return JSONL delta dicts
    that tag each matching record as confirmedJunk. Skips records that
    are already confirmedJunk (idempotent).

    Rick 2026-06-10: the narrow prefix list IS the safety check. We
    don't try to use the existence of dossier output as evidence —
    in the real catalog, every copy of "Centered Title 03.dv" had
    Whisper burned on it before this script existed, so any
    sibling-based veto either fires on partialMD5 collisions across
    different filenames, or mutually fires across duplicate copies
    of the same junk template. Tagging here is reversible (it
    just routes to the existing "Delete Confirmed Junk…" UI where
    Rick eyeballs before any actual delete) and the per-record
    notes marker makes a tag easy to spot and undo.
    """
    now = dt.datetime.now(dt.timezone.utc).isoformat()
    deltas: list[dict] = []
    for rec in records:
        filename = rec.get("filename") or ""
        if not is_imovie_stock(filename):
            continue
        if rec.get("mediaDisposition") == "confirmedJunk":
            continue  # already tagged
        full = rec.get("fullPath")
        if not full:
            continue
        existing_notes = rec.get("notes") or ""
        marker = "[auto-tagged confirmedJunk: iMovie stock asset]"
        new_notes = (existing_notes + "\n" + marker).strip() if existing_notes else marker
        deltas.append({
            "fullPath": full,
            "host": "junk-tagger",
            "ts": now,
            "fields": {
                "mediaDisposition": "confirmedJunk",
                "notes": new_notes,
            },
        })
    return deltas


def write_deltas_jsonl(deltas, path: Path) -> int:
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
    ap.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    try:
        catalog = json.loads(args.catalog.read_text())
    except Exception as e:
        print(f"ERROR reading {args.catalog}: {e}", file=sys.stderr)
        return 1
    records = catalog.get("records", [])
    print(f"records in catalog: {len(records)}")

    deltas = compute_tag_deltas(records)
    print(f"records to tag as confirmedJunk: {len(deltas)}")

    if deltas:
        # Per-prefix breakdown so it's clear what's being tagged.
        by_prefix: dict[str, int] = defaultdict(int)
        for d in deltas:
            fp = d.get("fullPath", "")
            fn = fp.rsplit("/", 1)[-1]
            for prefix in IMOVIE_STOCK_PREFIXES:
                if fn.startswith(prefix):
                    by_prefix[prefix] += 1
                    break
        print("  breakdown by stock-asset family:")
        for p, c in sorted(by_prefix.items(), key=lambda kv: -kv[1]):
            print(f"    {p}: {c}")

    if args.dry_run:
        print("\n(dry run — no JSONL written)")
        return 0

    n = write_deltas_jsonl(deltas, args.output)
    print(f"\nwrote {n} delta(s) to {args.output}")
    print("merger will pick them up on its next poll cycle (~60s).")
    return 0


if __name__ == "__main__":
    sys.exit(main() or 0)
