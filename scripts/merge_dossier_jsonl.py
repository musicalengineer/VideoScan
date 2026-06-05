#!/usr/bin/env python3
"""Dossier JSONL merger.

Reads per-record JSONL delta files emitted by `dossier_batch.py
--output-jsonl <path>` workers running on the fleet (M4 + M1 + M5), and
applies them to the authoritative catalog.json on M4.

Runs as a daemon: scans the delta directory at a configurable interval,
tracks read offsets per file (so it doesn't re-apply lines), atomically
writes catalog.json. Single writer to catalog.json — workers never touch
it directly when in delta mode.

Usage:
  merge_dossier_jsonl.py --delta-dir /Volumes/Crucial2TB/dossier-deltas
                        [--interval 60]      # seconds between scans
                        [--once]             # one pass, then exit
                        [--catalog ~/Library/Application\\ Support/VideoScan/catalog.json]

State:
  /tmp/dossier-merger-offsets.json  — last-applied byte offset per JSONL file.

Safety:
  - Atomic write of catalog.json (tmp + rename, .prev backup rotated).
  - Idempotent: re-applying the same JSONL line is a no-op (same fields → same record state).
  - JSON parse errors on a single line are logged and skipped — never abort the merger.
"""

import argparse
import datetime as dt
import json
import os
import shutil
import sys
import time
from pathlib import Path

DEFAULT_CATALOG = Path("~/Library/Application Support/VideoScan/catalog.json").expanduser()
DEFAULT_OFFSETS = Path("/tmp/dossier-merger-offsets.json")
LOG_DIR = Path("~/Library/Logs/VideoScan/dossier-merger").expanduser()


def now_iso():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def load_offsets(path: Path) -> dict[str, int]:
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text())
    except Exception:
        return {}


def save_offsets(path: Path, offsets: dict[str, int]):
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(offsets, indent=2))
    os.replace(tmp, path)


def atomic_write_catalog(catalog: dict, path: Path):
    if path.exists():
        shutil.copy2(path, path.with_suffix(".json.prev"))
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(catalog, indent=2, ensure_ascii=False))
    os.replace(tmp, path)


def read_new_deltas(delta_dir: Path, offsets: dict[str, int], log):
    """Return list of (file, parsed delta dict) for unread lines, plus updated offsets."""
    new_deltas = []
    for jsonl_file in sorted(delta_dir.glob("*.jsonl")):
        key = jsonl_file.name
        last_offset = offsets.get(key, 0)
        size = jsonl_file.stat().st_size
        if size <= last_offset:
            continue
        # Read from last offset
        with jsonl_file.open("r") as f:
            f.seek(last_offset)
            raw = f.read()
            new_end = last_offset + len(raw.encode("utf-8"))
        line_count = 0
        for line in raw.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                delta = json.loads(line)
                new_deltas.append((key, delta))
                line_count += 1
            except json.JSONDecodeError as e:
                log(f"  skip malformed line in {key}: {e}")
        if line_count:
            log(f"  {key}: read {line_count} new line(s) "
                f"(offset {last_offset} → {new_end})")
        offsets[key] = new_end
    return new_deltas, offsets


def apply_deltas(catalog: dict, deltas: list, log):
    """Apply parsed delta dicts to catalog records. Returns count applied."""
    by_path = {r["fullPath"]: r for r in catalog["records"]}
    applied = 0
    skipped_no_record = 0
    for _, delta in deltas:
        path = delta.get("fullPath")
        fields = delta.get("fields", {})
        if not path or not fields:
            continue
        rec = by_path.get(path)
        if not rec:
            skipped_no_record += 1
            continue
        for k, v in fields.items():
            rec[k] = v
        applied += 1
    if skipped_no_record:
        log(f"  skipped {skipped_no_record} delta(s) with no matching catalog record")
    return applied


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--delta-dir", required=True,
                    help="Directory containing per-worker *.jsonl files.")
    ap.add_argument("--catalog", type=Path, default=DEFAULT_CATALOG)
    ap.add_argument("--offsets", type=Path, default=DEFAULT_OFFSETS,
                    help="Where to track per-file read offsets between runs.")
    ap.add_argument("--interval", type=int, default=60,
                    help="Seconds between scans in daemon mode (default: 60).")
    ap.add_argument("--once", action="store_true",
                    help="One pass then exit (for cron-style scheduling).")
    args = ap.parse_args()

    LOG_DIR.mkdir(parents=True, exist_ok=True)
    logpath = LOG_DIR / f"merger_{dt.datetime.now().strftime('%Y%m%d_%H%M%S')}.log"
    logf = open(logpath, "w")

    def log(msg):
        line = f"[{now_iso()}] {msg}"
        print(line)
        logf.write(line + "\n")
        logf.flush()

    delta_dir = Path(args.delta_dir)
    log(f"=== merger start ===")
    log(f"delta_dir: {delta_dir}")
    log(f"catalog:   {args.catalog}")
    log(f"offsets:   {args.offsets}")
    log(f"interval:  {args.interval}s ({'once' if args.once else 'daemon'})")

    if not delta_dir.exists():
        delta_dir.mkdir(parents=True, exist_ok=True)
        log(f"created delta dir")

    while True:
        offsets = load_offsets(args.offsets)
        deltas, offsets = read_new_deltas(delta_dir, offsets, log)
        if deltas:
            try:
                catalog = json.loads(args.catalog.read_text())
            except Exception as e:
                log(f"ERROR reading catalog: {e} — will retry next cycle")
                if args.once:
                    break
                time.sleep(args.interval)
                continue
            applied = apply_deltas(catalog, deltas, log)
            if applied:
                atomic_write_catalog(catalog, args.catalog)
                save_offsets(args.offsets, offsets)
                log(f"  applied {applied} delta(s) → catalog.json")
            else:
                log(f"  no applicable deltas (read {len(deltas)})")
                save_offsets(args.offsets, offsets)
        else:
            log(f"  no new deltas")
        if args.once:
            break
        time.sleep(args.interval)

    log(f"=== merger stop ===")
    logf.close()


if __name__ == "__main__":
    sys.exit(main() or 0)
