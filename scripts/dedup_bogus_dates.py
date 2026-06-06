#!/usr/bin/env python3
"""Catalog cleanup — dedup records carrying the 2040-02-06 sentinel.

Background (Rick + Claude, 2026-06-06): every MTS file in some old
"Thanksgiving 2009" folder had TWO records — one with a real date,
and one with `dateCreatedRaw == "2040-02-06T06:28:16Z"` from a prior
scan done on a MacPro with a dead PRAM battery (which defaulted the
system clock to that future date). The dossier-side date triangulation
already ignored the bogus value (mtime fallback wins) — but the catalog
table displayed "2040" in the dateCreated column for the duplicates.

This script:

  1. Identifies records carrying the exact 2040 sentinel.
  2. For each, checks if there's a sibling record with the same
     fullPath that has a DIFFERENT (plausible) dateCreatedRaw.
  3. If yes — drops the bogus record. The sibling carries everything
     of value (the real timestamp + any dossier work already merged
     onto it by the JSONL merger).
  4. If no sibling — clears the bogus dateCreatedRaw / dateCreated
     fields to nil/empty but keeps the record (don't lose the file
     from the catalog over a single bad timestamp).

Operates atomically on `~/Library/Application Support/VideoScan/catalog.json`
via the same tmp-then-rename pattern the merger uses, and rotates the
prior catalog to `catalog.json.prev` before writing.

Usage:
  dedup_bogus_dates.py                  # apply the cleanup
  dedup_bogus_dates.py --dry-run        # report only, don't mutate

Output is human-readable summary lines.
"""

import argparse
import json
import os
import shutil
import sys
from collections import defaultdict
from pathlib import Path

DEFAULT_CATALOG = Path("~/Library/Application Support/VideoScan/catalog.json").expanduser()

# The exact bogus stamp, byte-for-byte. See DateValidation.swift for
# the Swift-side mirror that prevents new occurrences at scan time.
BOGUS_2040 = "2040-02-06T06:28:16Z"


def is_bogus(date_str):
    """Match the 2040 sentinel exactly. We don't want to drop a
    legitimate 2040 date when 2040 actually arrives."""
    return date_str == BOGUS_2040


def classify_records(records):
    """Return three categories:
      - drop_indices: bogus-sibling-exists, drop the bogus
      - clear_indices: bogus alone (no sibling), keep but clear date
      - keep_indices: everything else
    """
    by_path = defaultdict(list)
    for i, r in enumerate(records):
        by_path[r.get("fullPath", "")].append(i)

    drop, clear = [], []
    for _path, indices in by_path.items():
        bogus = [i for i in indices if is_bogus(records[i].get("dateCreatedRaw"))]
        if not bogus:
            continue
        non_bogus = [i for i in indices if i not in bogus]
        if non_bogus:
            # Sibling exists with a real date — drop the bogus row(s).
            drop.extend(bogus)
        else:
            # No sibling — keep the bogus record but null out the date.
            clear.extend(bogus)
    return drop, clear


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--catalog", type=Path, default=DEFAULT_CATALOG)
    ap.add_argument("--dry-run", action="store_true",
                    help="Report what would change, don't write.")
    args = ap.parse_args()

    if not args.catalog.exists():
        print(f"catalog not found: {args.catalog}", file=sys.stderr)
        return 1

    catalog = json.loads(args.catalog.read_text())
    records = catalog.get("records", [])
    total = len(records)
    print(f"loaded {total} records from {args.catalog}")

    drop, clear = classify_records(records)
    drop_set = set(drop)

    print(f"  records carrying the {BOGUS_2040} sentinel: {len(drop) + len(clear)}")
    print(f"  will DROP   (bogus with a real sibling): {len(drop)}")
    print(f"  will CLEAR  (bogus alone, null the date): {len(clear)}")

    if args.dry_run:
        print("DRY RUN — no changes written.")
        return 0

    if not drop and not clear:
        print("nothing to do.")
        return 0

    for i in clear:
        records[i].pop("dateCreatedRaw", None)
        records[i]["dateCreated"] = ""

    new_records = [r for i, r in enumerate(records) if i not in drop_set]
    catalog["records"] = new_records

    if args.catalog.exists():
        shutil.copy2(args.catalog, args.catalog.with_suffix(".json.prev"))
    tmp = args.catalog.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(catalog, indent=2, ensure_ascii=False))
    os.replace(tmp, args.catalog)

    print(f"wrote {len(new_records)} records ({total - len(new_records)} dropped) → {args.catalog}")
    print(f"backup saved at {args.catalog.with_suffix('.json.prev')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
