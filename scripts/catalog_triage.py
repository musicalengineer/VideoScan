#!/usr/bin/env python3
"""Read-only triage analysis of the VideoScan catalog.

Reports junk/duplicate candidates and where the bytes actually live.
Makes NO modifications to the catalog or to any media.
"""
import json
import os
from collections import Counter, defaultdict

CATALOG = os.path.expanduser("~/Library/Application Support/VideoScan/catalog.json")


def gb(n):
    return n / 1e9


def main():
    d = json.load(open(CATALOG))
    recs = d["records"]
    total = sum(r.get("sizeBytes", 0) or 0 for r in recs)

    print(f"catalog v{d['version']}  saved {d['savedAt']}  host {d.get('savedFromHost')}")
    print(f"{len(recs):,} records   {gb(total):,.1f} GB total\n")

    # ---- where the bytes live -------------------------------------------
    byvol = defaultdict(lambda: [0, 0])  # volume -> [count, bytes]
    for r in recs:
        p = r.get("fullPath") or r.get("directory") or ""
        parts = p.split("/")
        vol = parts[2] if p.startswith("/Volumes/") and len(parts) > 2 else "(internal or unknown)"
        byvol[vol][0] += 1
        byvol[vol][1] += r.get("sizeBytes", 0) or 0
    print("=== bytes by volume ===")
    for vol, (c, b) in sorted(byvol.items(), key=lambda kv: -kv[1][1])[:15]:
        online = "ONLINE " if os.path.ismount(f"/Volumes/{vol}") or vol.startswith("(") else "OFFLINE"
        print(f"  {online} {vol:<28} {c:>7,} recs  {gb(b):>9,.1f} GB")

    # ---- junk score ------------------------------------------------------
    print("\n=== junkScore distribution ===")
    js = Counter(r.get("junkScore", 0) or 0 for r in recs)
    for score in sorted(js):
        b = sum(r.get("sizeBytes", 0) or 0 for r in recs if (r.get("junkScore", 0) or 0) == score)
        print(f"  score {score:<4} {js[score]:>7,} recs  {gb(b):>9,.1f} GB")

    # ---- duplicates ------------------------------------------------------
    print("\n=== duplicates ===")
    groups = defaultdict(list)
    for r in recs:
        g = r.get("duplicateGroupID") or ""
        if g:
            groups[g].append(r)
    dispo = Counter(r.get("duplicateDisposition") or "(none)" for r in recs)
    conf = Counter(r.get("duplicateConfidence") or "(none)" for r in recs)
    print(f"  {len(groups):,} duplicate groups covering "
          f"{sum(len(v) for v in groups.values()):,} records")
    print("  disposition:", dict(dispo))
    print("  confidence :", dict(conf))

    # Reclaimable = every member of a group beyond the largest single keeper.
    reclaim = 0
    for g, members in groups.items():
        if len(members) < 2:
            continue
        sizes = sorted((m.get("sizeBytes", 0) or 0) for m in members)
        reclaim += sum(sizes[:-1])
    print(f"  reclaimable if each group collapses to one copy: {gb(reclaim):,.1f} GB")

    # High-confidence only -- the safe subset.
    hi_reclaim = 0
    hi_groups = 0
    for g, members in groups.items():
        if len(members) < 2:
            continue
        if all((m.get("duplicateConfidence") or "") == "High" for m in members):
            hi_groups += 1
            sizes = sorted((m.get("sizeBytes", 0) or 0) for m in members)
            hi_reclaim += sum(sizes[:-1])
    print(f"  of which HIGH confidence only: {hi_groups:,} groups, {gb(hi_reclaim):,.1f} GB")

    # ---- lifecycle / disposition ----------------------------------------
    print("\n=== lifecycleStage ===")
    for k, v in Counter(r.get("lifecycleStage") or "(none)" for r in recs).most_common(8):
        print(f"  {k:<28} {v:>7,}")
    print("\n=== mediaDisposition ===")
    for k, v in Counter(r.get("mediaDisposition") or "(none)" for r in recs).most_common(8):
        print(f"  {k:<28} {v:>7,}")

    # ---- structural junk candidates --------------------------------------
    print("\n=== structural candidates ===")
    zero = [r for r in recs if (r.get("sizeBytes", 0) or 0) == 0]
    tiny = [r for r in recs if 0 < (r.get("sizeBytes", 0) or 0) < 1_000_000]
    unplayable = [r for r in recs if (r.get("isPlayable") or "") not in ("Yes", "")]
    print(f"  zero-byte            {len(zero):>7,} recs")
    print(f"  under 1 MB           {len(tiny):>7,} recs  {gb(sum(r.get('sizeBytes',0) or 0 for r in tiny)):>8,.1f} GB")
    print(f"  not playable         {len(unplayable):>7,} recs  {gb(sum(r.get('sizeBytes',0) or 0 for r in unplayable)):>8,.1f} GB")

    # Path-pattern junk.
    PATTERNS = ["/.Trash", "/Trash", "ImmichBenchmark", "/Caches/", "DerivedData",
                "/tmp/", "_test", "test_", "sample", "/Downloads/"]
    print("\n=== path-pattern candidates ===")
    for pat in PATTERNS:
        hits = [r for r in recs if pat.lower() in (r.get("fullPath") or "").lower()]
        if hits:
            b = sum(r.get("sizeBytes", 0) or 0 for r in hits)
            print(f"  {pat:<22} {len(hits):>7,} recs  {gb(b):>9,.1f} GB")

    # ---- extension mix ----------------------------------------------------
    print("\n=== top extensions by bytes ===")
    ext = defaultdict(lambda: [0, 0])
    for r in recs:
        e = (r.get("ext") or "?").upper()
        ext[e][0] += 1
        ext[e][1] += r.get("sizeBytes", 0) or 0
    for e, (c, b) in sorted(ext.items(), key=lambda kv: -kv[1][1])[:10]:
        print(f"  {e:<10} {c:>7,} recs  {gb(b):>9,.1f} GB")


if __name__ == "__main__":
    main()
