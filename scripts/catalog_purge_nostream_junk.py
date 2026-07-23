#!/usr/bin/env python3
"""One-shot catalog purge: no-stream sub-1MB junk records (Rick, 2026-07-23).

Class "C-safe": records where ffprobe found NO audio stream and NO video
stream, under 1 MB. That is build/system debris swept in by the April dev
scans (Makefile, LICENSE, PkgInfo, Photos-library cache blobs) — not media.
The 1 MB floor deliberately protects larger no-stream records, which are
probe FAILURES on real footage (e.g. MiscKidsWholeWithFX.mov, 5 GB) kept for
a future re-probe lane.

Files stay on disk; a finding-aid report of every purged path is written
next to the catalog. Same safety rails as the sibling scripts: refuses while
VideoScan.app runs, snapshot first, atomic replace, search index retired for
rebuild, pair back-references severed, --dry-run/--catalog for rehearsal.
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

SIZE_FLOOR = 1_000_000  # bytes


def app_is_running():
    r = subprocess.run(["pgrep", "-f", "VideoScan.app/Contents/MacOS/VideoScan"],
                       capture_output=True)
    return r.returncode == 0


def is_nostream_junk(rec):
    if rec.get("audioCodec") or rec.get("resolution"):
        return False
    if (rec.get("sizeBytes") or 0) >= SIZE_FLOOR:
        return False
    if rec.get("mediaDisposition") == "Important":
        return False
    return True


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

    purged = [r for r in recs if is_nostream_junk(r)]
    keep = [r for r in recs if not is_nostream_junk(r)]
    purged_ids = {r["id"] for r in purged}

    severed = 0
    for r in keep:
        if r.get("pairedWithID") in purged_ids:
            r["pairedWithID"] = None
            r["pairGroupID"] = None
            r["pairConfidence"] = None
            severed += 1

    total_bytes = sum(r.get("sizeBytes") or 0 for r in purged)
    print(f"records: {len(recs)} -> {len(keep)}  (purging {len(purged)} "
          f"no-stream sub-1MB records, {total_bytes/1e6:.1f} MB on disk)")
    print(f"pair back-references severed on survivors: {severed}")
    print("top filenames:")
    for n, c in collections.Counter(r["filename"] for r in purged).most_common(8):
        print(f"  {c:5d}  {n}")
    kept_nostream = sum(1 for r in keep
                        if not r.get("audioCodec") and not r.get("resolution"))
    print(f"no-stream records KEPT (>=1MB probe-failure candidates): {kept_nostream}")

    assert len(keep) + len(purged) == len(recs)
    kept_ids = {r["id"] for r in keep}
    assert not any(r.get("pairedWithID") and r["pairedWithID"] not in kept_ids
                   for r in keep), "dangling pair refs would remain — aborting"

    if args.dry_run:
        print("DRY RUN — no changes written.")
        return

    stamp = datetime.datetime.now(datetime.timezone.utc).strftime(
        "%Y-%m-%dT%H-%M-%SZ")
    cat_dir = os.path.dirname(args.catalog)

    report = os.path.join(cat_dir, f"nostream-purge-report.{stamp}.txt")
    with open(report, "w") as f:
        f.write(f"# No-stream sub-1MB purge {stamp} — {len(purged)} records "
                f"removed from catalog (files untouched on disk)\n")
        f.write("# size_bytes\tfullPath\n")
        for r in sorted(purged, key=lambda r: r["fullPath"]):
            f.write(f"{r.get('sizeBytes')}\t{r['fullPath']}\n")

    snapshot = os.path.join(cat_dir, f"catalog.pre-nostream-purge.{stamp}.json")
    os.rename(args.catalog, snapshot)
    tmp = args.catalog + ".tmp"
    with open(tmp, "w") as f:
        json.dump(set_recs(keep), f)
    os.replace(tmp, args.catalog)

    index = os.path.join(cat_dir, "catalog.search-index.v1.plist")
    if os.path.exists(index):
        os.rename(index, index + f".pre-nostream-purge-{stamp}")
        print("search index retired — app rebuilds it on next launch")

    print(f"snapshot: {snapshot}")
    print(f"report:   {report}")
    print(f"written:  {args.catalog}  ({len(keep)} records)")


if __name__ == "__main__":
    main()
