#!/usr/bin/env python3
"""Repair catalog records whose `mediaDisposition` holds a Swift enum
case NAME instead of the case's RAW VALUE.

Rick 2026-06-10: scripts/tag_imovie_stock_as_junk.py shipped with
"confirmedJunk" (Swift case name) where it should have written
"Confirmed Junk" (the enum's String raw value). The Swift decoder
silently falls back to `.unreviewed` on raw-value mismatch, so 132
records were tagged in a way the app couldn't see — dial undercounts,
the audit tests blow up, and a clean catalog round-trip is impossible.

This script repairs in three phases:
  1. /Volumes/Crucial2TB/dossier-deltas/junk-tagging.jsonl — rewrite
     bad case-name values to the Swift raw value so any replay produces
     correct data.
  2. ~/Library/Application Support/VideoScan/catalog.json — apply the
     (now-corrected) JSONL deltas to the catalog records. Many records
     that were tagged with the buggy script then "healed" themselves to
     .unreviewed via the Swift decoder fallback — those records need
     the tag re-applied from the truth source (the JSONL).
  3. ~/Library/Application Support/VideoScan/dossier-merger-offsets.json
     — bump the offset for junk-tagging.jsonl to the new file size, so
     the live merger doesn't re-apply already-applied deltas after the
     repair lands.

Defensive checks:
  - Refuses to run if the VideoScan app process is detected — would race
    with the app's debounced auto-save and lose work.
  - Atomic write via tmp + rename (same pattern as the app + merger).
  - `.prev` rotation is preserved by the atomic-rename behavior — the
    caller can `cp catalog.json.prev catalog.json` to roll back.
  - --dry-run reports the count without writing.

Mapping table is intentionally a full case→raw enumeration of
MediaDisposition. If the Swift enum gains a case or renames one, the
test pair (Python + Swift contract test) will fire before this script
is needed again.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

DEFAULT_CATALOG = Path("~/Library/Application Support/VideoScan/catalog.json").expanduser()
DEFAULT_JSONL = Path("/Volumes/Crucial2TB/dossier-deltas/junk-tagging.jsonl")
DEFAULT_OFFSETS = Path("~/Library/Application Support/VideoScan/dossier-merger-offsets.json").expanduser()

# Swift `MediaDisposition` case name -> raw value. Kept in lock-step with
# VideoScan/VideoScan/Models.swift::MediaDisposition. The Swift contract
# test MediaDispositionRawValueContractTests.allRawValuesAreStableContract
# pins the other side.
CASE_NAME_TO_RAW = {
    "unreviewed":    "Unreviewed",
    "important":     "Important",
    "recoverable":   "Recoverable",
    "suspectedJunk": "Suspected Junk",
    "confirmedJunk": "Confirmed Junk",
}


def app_is_running() -> bool:
    """True if the VideoScan app (or its in-flight test runner) is alive.
    A live app means our catalog write will race against the app's
    debounced auto-save. Caller should refuse to proceed."""
    try:
        out = subprocess.check_output(
            ["pgrep", "-fl", "VideoScan.app/Contents/MacOS/VideoScan"],
            text=True,
        ).strip()
        return bool(out)
    except subprocess.CalledProcessError:
        return False  # pgrep returns 1 when no match


def atomic_write_json(obj, dest: Path) -> None:
    """Write `obj` to `dest` via tmp + os.replace, matching the app's
    write contract. The existing dest -> dest.prev rotation lives in
    the app/merger, not here; this preserves whatever .prev currently
    points at, so a misfire is one cp away from full rollback."""
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp_fd, tmp_path = tempfile.mkstemp(prefix=dest.name + ".tmp.",
                                        dir=str(dest.parent))
    try:
        with os.fdopen(tmp_fd, "w") as f:
            json.dump(obj, f, ensure_ascii=False, separators=(",", ":"))
        os.replace(tmp_path, dest)
    except Exception:
        try:
            os.unlink(tmp_path)
        except FileNotFoundError:
            pass
        raise


def repair_catalog_records(records: list[dict]) -> tuple[int, dict[str, int]]:
    """Mutate `records` in place: replace any mediaDisposition value
    that's a Swift case name with the corresponding raw value.
    Returns (count_fixed, per_disposition_breakdown).
    """
    fixed = 0
    breakdown: dict[str, int] = {}
    for rec in records:
        v = rec.get("mediaDisposition")
        if not isinstance(v, str):
            continue
        # Already a raw value -> leave alone.
        if v in CASE_NAME_TO_RAW.values():
            continue
        # A known case-name? -> repair.
        raw = CASE_NAME_TO_RAW.get(v)
        if raw is None:
            # Unknown value (neither case name nor raw value) — leave it.
            # The Swift decoder will reject it loudly, which is what we
            # want for a real schema breach.
            continue
        rec["mediaDisposition"] = raw
        fixed += 1
        breakdown[raw] = breakdown.get(raw, 0) + 1
    return fixed, breakdown


def apply_jsonl_to_catalog(jsonl_path: Path, records: list[dict]) -> tuple[int, int]:
    """For each delta in `jsonl_path`, find the matching catalog record
    by fullPath and apply its `fields`. Idempotent: writing the same
    value twice is a no-op. Returns (applied_count, skipped_missing).

    Reads from disk (NOT from the in-memory repair_jsonl_file output)
    so the on-disk JSONL truth is what gets applied — important when
    the JSONL was just rewritten by the previous phase.
    """
    if not jsonl_path.exists():
        return 0, 0
    by_path = {r["fullPath"]: r for r in records if "fullPath" in r}
    applied = 0
    skipped = 0
    with jsonl_path.open("r") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            full = obj.get("fullPath")
            fields = obj.get("fields") or {}
            if not full or not fields:
                continue
            rec = by_path.get(full)
            if rec is None:
                skipped += 1
                continue
            for k, v in fields.items():
                rec[k] = v
            applied += 1
    return applied, skipped


def repair_jsonl_file(path: Path, dry_run: bool) -> tuple[int, dict[str, int]]:
    """Repair the JSONL delta file in place. Each line is `{"...,
    "fields": {"mediaDisposition": "..."}}`. Returns (count_fixed,
    breakdown). Same atomic-rename pattern as the catalog repair."""
    if not path.exists():
        return 0, {}
    fixed = 0
    breakdown: dict[str, int] = {}
    out_lines: list[str] = []
    with path.open("r") as f:
        for line in f:
            raw_line = line.rstrip("\n")
            if not raw_line.strip():
                out_lines.append(raw_line)
                continue
            try:
                obj = json.loads(raw_line)
            except json.JSONDecodeError:
                out_lines.append(raw_line)  # leave malformed lines alone
                continue
            fields = obj.get("fields") or {}
            v = fields.get("mediaDisposition")
            if isinstance(v, str) and v in CASE_NAME_TO_RAW:
                raw = CASE_NAME_TO_RAW[v]
                fields["mediaDisposition"] = raw
                obj["fields"] = fields
                fixed += 1
                breakdown[raw] = breakdown.get(raw, 0) + 1
            out_lines.append(json.dumps(obj, ensure_ascii=False))

    if dry_run or fixed == 0:
        return fixed, breakdown

    tmp_fd, tmp_path = tempfile.mkstemp(prefix=path.name + ".tmp.",
                                       dir=str(path.parent))
    with os.fdopen(tmp_fd, "w") as f:
        f.write("\n".join(out_lines) + "\n")
    os.replace(tmp_path, path)
    return fixed, breakdown


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--catalog", type=Path, default=DEFAULT_CATALOG)
    ap.add_argument("--jsonl", type=Path, default=DEFAULT_JSONL,
                    help="JSONL delta file to repair in lock-step (junk-tagging.jsonl)")
    ap.add_argument("--offsets", type=Path, default=DEFAULT_OFFSETS,
                    help="merger offsets file to bump after repair (so it doesn't re-apply)")
    ap.add_argument("--dry-run", action="store_true",
                    help="report what would be fixed; write nothing")
    ap.add_argument("--allow-app-running", action="store_true",
                    help="bypass the live-app safety check (NOT recommended)")
    args = ap.parse_args()

    if not args.dry_run and not args.allow_app_running and app_is_running():
        print("ERROR: VideoScan.app is running. Quit it first or pass --allow-app-running.",
              file=sys.stderr)
        print("  (the app's debounced auto-save would overwrite this repair within ~60s)",
              file=sys.stderr)
        return 2

    # --- catalog load ---
    try:
        catalog = json.loads(args.catalog.read_text())
    except Exception as e:
        print(f"ERROR reading {args.catalog}: {e}", file=sys.stderr)
        return 1
    records = catalog.get("records", [])
    print(f"catalog: {len(records):,} records")

    # --- phase 0: in-catalog case-name repair (defense in depth — usually 0
    #     because the Swift decoder's fallback silently un-tagged them) ---
    cat_fixed, cat_breakdown = repair_catalog_records(records)
    print(f"  phase 0 (in-catalog case-name → raw value): {cat_fixed}")
    for raw, n in sorted(cat_breakdown.items(), key=lambda kv: -kv[1]):
        print(f"    → {raw}: {n}")

    # --- phase 1: JSONL case-name repair (the upstream source) ---
    j_fixed, j_breakdown = repair_jsonl_file(args.jsonl, dry_run=True)
    print(f"\nphase 1 ({args.jsonl.name} case-name → raw value): {j_fixed}")
    for raw, n in sorted(j_breakdown.items(), key=lambda kv: -kv[1]):
        print(f"    → {raw}: {n}")

    if args.dry_run:
        # For the dry-run preview of phase 2, use a temp copy of the catalog
        # so we don't mutate the in-memory records dict.
        import copy
        preview_records = copy.deepcopy(records)
        applied, skipped = apply_jsonl_to_catalog(args.jsonl, preview_records)
        print(f"\nphase 2 (apply JSONL deltas to catalog): {applied} applied, {skipped} skipped (path missing)")
        print("\n(dry run — no writes)")
        return 0

    # --- write phase 1 (JSONL) FIRST so phase 2 reads the corrected values ---
    j_fixed, _ = repair_jsonl_file(args.jsonl, dry_run=False)
    if j_fixed:
        print(f"\nrepaired JSONL:   wrote {args.jsonl} ({j_fixed} delta(s) fixed)")
    else:
        print("\nJSONL unchanged")

    # --- phase 2: apply (now-correct) JSONL deltas to catalog records ---
    applied, skipped = apply_jsonl_to_catalog(args.jsonl, records)
    print(f"phase 2: applied {applied} delta(s) to catalog ({skipped} skipped — path not in catalog)")

    # --- write catalog (combines phase 0 + phase 2 mutations) ---
    if cat_fixed or applied:
        atomic_write_json(catalog, args.catalog)
        print(f"repaired catalog: wrote {args.catalog}")
    else:
        print("catalog unchanged")

    # --- phase 3: bump merger offset so it doesn't reapply ---
    if args.offsets.exists():
        try:
            offsets = json.loads(args.offsets.read_text())
        except Exception as e:
            print(f"WARN: couldn't read offsets {args.offsets}: {e}", file=sys.stderr)
        else:
            new_size = args.jsonl.stat().st_size if args.jsonl.exists() else 0
            prev = offsets.get(args.jsonl.name, 0)
            offsets[args.jsonl.name] = new_size
            atomic_write_json(offsets, args.offsets)
            print(f"phase 3: bumped merger offset for {args.jsonl.name}: {prev} → {new_size}")

    print("\nrollback (if needed): cp catalog.json.prev catalog.json")
    return 0


if __name__ == "__main__":
    sys.exit(main() or 0)
