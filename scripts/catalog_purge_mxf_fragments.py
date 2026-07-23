#!/usr/bin/env python3
"""One-shot catalog purge: sub-5s Avid MXF essence fragments (Rick, 2026-07-23).

Rationale: 20-year-old Avid render fragments (audio-dissolve/crossfade media)
and false-start capture fragments — 1-5 seconds, unreassemblable, drag search
down. Rick's directive: purge from the CATALOG (files stay on disk; the purge
report below is the finding aid if anything is ever missed).

Purge rule (all must hold):
  - ext == mxf
  - duration KNOWN and 0 < d <= 5.0s   (unknown/zero stays — ffprobe can't
    read Avid RGBA video essence, so "no duration" does NOT mean short)
  - single-essence: audio-only or video-only (never A/V)
  - mediaDisposition != "Important"

Pair hygiene (lesson of e593dc8): surviving records whose pairedWithID points
at a purged record get pairedWithID/pairGroupID/pairConfidence cleared.

Safety: refuses while VideoScan.app runs; snapshot first; atomic replace;
retires catalog.search-index.v1.plist so the app rebuilds it on next launch
(established recovery path); writes a full purge report (all paths + sizes)
next to the catalog; --dry-run and --catalog for rehearsal.
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


def app_is_running():
    r = subprocess.run(["pgrep", "-f", "VideoScan.app/Contents/MacOS/VideoScan"],
                       capture_output=True)
    return r.returncode == 0


def is_fragment(rec):
    if (rec.get("ext") or "").lower() != "mxf":
        return False
    d = rec.get("durationSeconds") or 0
    if not (0 < d <= 5.0):
        return False
    audio_only = bool(rec.get("audioCodec")) and not rec.get("resolution")
    video_only = bool(rec.get("resolution")) and not rec.get("audioCodec")
    if not (audio_only or video_only):
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

    purged = [r for r in recs if is_fragment(r)]
    keep = [r for r in recs if not is_fragment(r)]
    purged_ids = {r["id"] for r in purged}

    severed = 0
    for r in keep:
        if r.get("pairedWithID") in purged_ids:
            r["pairedWithID"] = None
            r["pairGroupID"] = None
            r["pairConfidence"] = None
            severed += 1

    ao = sum(1 for r in purged if r.get("audioCodec"))
    total_bytes = sum(r.get("sizeBytes") or 0 for r in purged)
    print(f"records: {len(recs)} -> {len(keep)}  (purging {len(purged)}: "
          f"{ao} audio-only, {len(purged) - ao} video-only)")
    print(f"pair back-references severed on survivors: {severed}")
    print(f"disk bytes represented (files stay on disk): {total_bytes/1e6:.1f} MB")
    print("top directories:")
    for d, c in collections.Counter(r["directory"] for r in purged).most_common(6):
        print(f"  {c:5d}  {d}")

    assert len(keep) + len(purged) == len(recs)
    assert not any(is_fragment(r) for r in keep)

    if args.dry_run:
        print("DRY RUN — no changes written.")
        return

    stamp = datetime.datetime.now(datetime.timezone.utc).strftime(
        "%Y-%m-%dT%H-%M-%SZ")
    cat_dir = os.path.dirname(args.catalog)

    report = os.path.join(cat_dir, f"fragment-purge-report.{stamp}.txt")
    with open(report, "w") as f:
        f.write(f"# MXF fragment purge {stamp} — {len(purged)} records "
                f"removed from catalog (files untouched on disk)\n")
        f.write("# duration_s\tsize_bytes\tfullPath\n")
        for r in sorted(purged, key=lambda r: r["fullPath"]):
            f.write(f"{r.get('durationSeconds')}\t{r.get('sizeBytes')}\t"
                    f"{r['fullPath']}\n")

    snapshot = os.path.join(cat_dir, f"catalog.pre-fragment-purge.{stamp}.json")
    os.rename(args.catalog, snapshot)
    tmp = args.catalog + ".tmp"
    with open(tmp, "w") as f:
        json.dump(set_recs(keep), f)
    os.replace(tmp, args.catalog)

    index = os.path.join(cat_dir, "catalog.search-index.v1.plist")
    if os.path.exists(index):
        os.rename(index, index + f".pre-fragment-purge-{stamp}")
        print("search index retired — app rebuilds it on next launch")

    print(f"snapshot: {snapshot}")
    print(f"report:   {report}")
    print(f"written:  {args.catalog}  ({len(keep)} records)")


if __name__ == "__main__":
    main()
