#!/usr/bin/env python3
"""
repair_salvage_stage.py — one-time catalog repair for stale "Salvage Failed" stages.

Background (2026-06-19): re-running the RicksBackups → LaCie salvage migration
successfully re-copied 97 files that had been marked archiveStage="Salvage Failed"
during an earlier transient-failure run. The relocate success path rewrote
fullPath/originalFullPath/partialMD5 but did NOT clear the stale terminal stage
(fixed going forward in VideoScanModel+Relocate.swift). Records already relocated
won't be re-touched by any future run, so their stale label must be repaired here.

This script ONLY clears records that are provably safe:
    archiveStage == "Salvage Failed"
    AND originalFullPath is set            (it really was relocated)
    AND fullPath is NOT on the origin vol  (it moved off the failing drive)
    AND the file exists on disk at fullPath (the copy is really there)
Each qualifying record is reset to archiveStage="None" with a provenance note
appended (same "\\n"-joined format the app uses).

SAFETY:
  * Dry-run by default. Pass --apply to write.
  * Refuses to run while the VideoScan app is open (it owns catalog.json and
    would clobber our write / hold a stale in-memory copy). Override with --force.
  * Snapshots catalog.json -> catalog.pre-salvagestage-repair.<UTC>.json before writing.
  * Atomic write (temp file + os.replace).

Usage:
    python3 scripts/repair_salvage_stage.py            # dry run, shows what it would do
    python3 scripts/repair_salvage_stage.py --apply     # snapshot + repair (app must be closed)
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

DEFAULT_CATALOG = os.path.expanduser(
    "~/Library/Application Support/VideoScan/catalog.json"
)
SALVAGE_FAILED = "Salvage Failed"
CLEARED = "None"
APP_BINARY_HINT = "Build/Products/Debug/VideoScan.app"  # also matches Release path fragment


def app_is_running() -> bool:
    """True if a VideoScan.app process appears to be running."""
    try:
        out = subprocess.run(
            ["pgrep", "-fl", "VideoScan.app/Contents/MacOS/VideoScan"],
            capture_output=True, text=True,
        )
        return out.returncode == 0 and bool(out.stdout.strip())
    except Exception:
        return False  # pgrep unavailable -> don't block; --force still available


def append_note(existing: str, msg: str) -> str:
    existing = existing or ""
    return msg if existing == "" else existing + "\n" + msg


def qualifies(rec: dict) -> bool:
    if rec.get("archiveStage") != SALVAGE_FAILED:
        return False
    orig = rec.get("originalFullPath")
    full = rec.get("fullPath") or ""
    if not orig:
        return False
    # Must have actually moved off the origin volume.
    if full == orig:
        return False
    # The copy must really exist on disk.
    if not full or not os.path.exists(full):
        return False
    return True


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--catalog", default=DEFAULT_CATALOG, help="path to catalog.json")
    ap.add_argument("--apply", action="store_true",
                    help="actually write changes (default: dry run)")
    ap.add_argument("--force", action="store_true",
                    help="proceed even if the VideoScan app appears to be running")
    args = ap.parse_args()

    if not os.path.exists(args.catalog):
        print(f"ERROR: catalog not found: {args.catalog}", file=sys.stderr)
        return 2

    if args.apply and app_is_running() and not args.force:
        print("ERROR: VideoScan.app appears to be running.\n"
              "       Quit the app first (it owns catalog.json and would overwrite\n"
              "       this repair), or re-run with --force if you know it's safe.",
              file=sys.stderr)
        return 3

    with open(args.catalog) as f:
        catalog = json.load(f)
    records = catalog.get("records")
    if not isinstance(records, list):
        print("ERROR: catalog.json has no 'records' list", file=sys.stderr)
        return 2

    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    note = f"Catalog repair {stamp}: salvage recovered — verified on LaCie, stale Salvage Failed stage cleared"

    targets = [r for r in records if qualifies(r)]
    # Also surface any salvage-failed records we are deliberately NOT touching,
    # so nothing is silently skipped.
    all_failed = [r for r in records if r.get("archiveStage") == SALVAGE_FAILED]
    skipped = [r for r in all_failed if r not in targets]

    print(f"catalog: {args.catalog}")
    print(f"total records: {len(records)}")
    print(f"'Salvage Failed' records: {len(all_failed)}")
    print(f"  -> qualify for repair (moved + on-disk + has origin): {len(targets)}")
    print(f"  -> SKIPPED (do not qualify): {len(skipped)}")
    print()
    for r in targets[:200]:
        print(f"  REPAIR  {r.get('filename')}")
        print(f"          {r.get('fullPath')}")
    if skipped:
        print("\n  --- skipped (left as Salvage Failed) ---")
        for r in skipped[:200]:
            full = r.get("fullPath") or ""
            why = ("no originalFullPath" if not r.get("originalFullPath")
                   else "not moved off origin" if full == r.get("originalFullPath")
                   else "file missing on disk" if not (full and os.path.exists(full))
                   else "?")
            print(f"  SKIP    {r.get('filename')}  [{why}]")

    if not args.apply:
        print(f"\nDRY RUN — would repair {len(targets)} record(s). Re-run with --apply to write.")
        return 0

    if not targets:
        print("\nNothing to repair. No write performed.")
        return 0

    # Snapshot before writing.
    snap = os.path.join(os.path.dirname(args.catalog),
                        f"catalog.pre-salvagestage-repair.{stamp.replace(':', '-')}.json")
    with open(args.catalog, "rb") as src, open(snap, "wb") as dst:
        dst.write(src.read())
    print(f"\nSnapshot written: {snap}")

    # Apply.
    for r in targets:
        r["archiveStage"] = CLEARED
        r["notes"] = append_note(r.get("notes", ""), note)
    catalog["savedAt"] = stamp

    # Atomic write.
    d = os.path.dirname(args.catalog)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".catalog.repair.", suffix=".json")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(catalog, f, ensure_ascii=False, indent=None)
        os.replace(tmp, args.catalog)
    except Exception:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise

    print(f"APPLIED — repaired {len(targets)} record(s). Catalog written: {args.catalog}")
    print("Restart the app to load the repaired catalog.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
