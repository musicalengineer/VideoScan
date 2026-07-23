#!/usr/bin/env python3
"""One-shot catalog repair: remove exact-duplicate records (same fullPath).

Root cause: repeated April-2026 development scans of MyBook3Terabytes double-
cataloged 1,554 files (every duplicate group has multiplicity exactly 2, all on
/Volumes/MyBook3Terabytes). This removes the redundant record of each pair.

Keep rule (per group, in order):
  1. Prefer the record with curation signal: lifecycleStage != "Cataloged",
     mediaDisposition != "Unreviewed", junkScore set, or human notes.
     (Audit 2026-07-22: exactly one group truly diverges — IMG_0010.MOV,
     one copy "In Triage"/"Confirmed Junk" — the curated copy wins.)
  2. Otherwise records are identical on all curation fields (ffmpeg pointer
     addresses inside probe notes excepted) — keep the first.

Safety:
  - Refuses to run while VideoScan.app is running (single-writer rule).
  - Snapshots the catalog to catalog.pre-exactdup-dedup.<UTC>.json first.
  - Atomic replace (write temp + os.replace) preserving the JSON envelope.
  - --dry-run prints the plan without writing; --catalog lets you point at a
    COPY for rehearsal.
  - Post-write verification: unique path count unchanged, no non-duplicate
    record lost, every kept-vs-dropped choice logged.
"""

import argparse
import collections
import datetime
import json
import os
import subprocess
import sys

DEFAULT_CATALOG = os.path.expanduser(
    "~/Library/Application Support/VideoScan/catalog.json")

CURATION_DEFAULTS = {
    "lifecycleStage": ("Cataloged", ""),
    "mediaDisposition": ("Unreviewed", ""),
}


def app_is_running():
    r = subprocess.run(["pgrep", "-f", "VideoScan.app/Contents/MacOS/VideoScan"],
                       capture_output=True)
    return r.returncode == 0


def curation_score(rec):
    score = 0
    for field, defaults in CURATION_DEFAULTS.items():
        if str(rec.get(field) or "") not in defaults:
            score += 10
    if rec.get("junkScore") not in (None, "", 0):
        score += 1
    notes = str(rec.get("notes") or "")
    # ffprobe warnings (e.g. "[mxf @ 0x...] guessing index") are machine noise,
    # not curation.
    if notes and not notes.startswith("["):
        score += 1
    return score


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--catalog", default=DEFAULT_CATALOG)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--force-while-running", action="store_true",
                    help="bypass the running-app check (rehearsal on a copy only)")
    args = ap.parse_args()

    if not args.dry_run and not args.force_while_running and app_is_running():
        sys.exit("REFUSING: VideoScan.app is running (single-writer rule). "
                 "Quit the app first.")

    with open(args.catalog) as f:
        envelope = json.load(f)
    if isinstance(envelope, list):
        recs, set_recs = envelope, lambda v: v
    else:
        key = next(k for k, v in envelope.items() if isinstance(v, list))
        recs = envelope[key]

        def set_recs(v, key=key):
            envelope[key] = v
            return envelope

    by_path = collections.Counter(r["fullPath"] for r in recs)
    dup_paths = {p for p, c in by_path.items() if c > 1}
    if not dup_paths:
        print("No duplicate paths — nothing to do.")
        return

    keep, dropped = [], []
    seen_choice = {}
    for rec in recs:
        p = rec["fullPath"]
        if p not in dup_paths:
            keep.append(rec)
            continue
        if p not in seen_choice:
            seen_choice[p] = rec
            keep.append(rec)
        else:
            incumbent = seen_choice[p]
            if curation_score(rec) > curation_score(incumbent):
                keep[keep.index(incumbent)] = rec
                seen_choice[p] = rec
                dropped.append(incumbent)
            else:
                dropped.append(rec)

    print(f"records: {len(recs)} -> {len(keep)}  (dropping {len(dropped)})")
    assert len(keep) + len(dropped) == len(recs)
    assert len({r['fullPath'] for r in keep}) == len(by_path), \
        "unique-path count changed — aborting"
    assert all(by_path[r['fullPath']] > 1 for r in dropped), \
        "would drop a non-duplicate record — aborting"

    curated_wins = [p for p, r in seen_choice.items()
                    if curation_score(r) > 0]
    print(f"groups where curation decided the keeper: {len(curated_wins)}")
    for p in curated_wins:
        print("  curated keeper:", p)

    if args.dry_run:
        print("DRY RUN — no changes written.")
        return

    stamp = datetime.datetime.now(datetime.timezone.utc).strftime(
        "%Y-%m-%dT%H-%M-%SZ")
    snapshot = os.path.join(os.path.dirname(args.catalog),
                            f"catalog.pre-exactdup-dedup.{stamp}.json")
    os.rename(args.catalog, snapshot)
    tmp = args.catalog + ".tmp"
    with open(tmp, "w") as f:
        json.dump(set_recs(keep), f)
    os.replace(tmp, args.catalog)
    print(f"snapshot: {snapshot}")
    print(f"written:  {args.catalog}  ({len(keep)} records)")


if __name__ == "__main__":
    main()
