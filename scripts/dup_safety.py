#!/usr/bin/env python3
"""Safety analysis of duplicate groups: would collapsing a group strand
the surviving copy on an offline / non-redundant volume?

Read-only. Classifies each High-confidence group by where its members live.
"""
import json
import os
from collections import defaultdict

CATALOG = os.path.expanduser("~/Library/Application Support/VideoScan/catalog.json")

# Volumes considered redundant (RAID5) vs merely online vs offline.
REDUNDANT = {"FamilyArchive", "Projects"}


def vol_of(r):
    p = r.get("fullPath") or r.get("directory") or ""
    parts = p.split("/")
    if p.startswith("/Volumes/") and len(parts) > 2:
        return parts[2]
    return "(internal)"


def gb(n):
    return n / 1e9


def main():
    recs = json.load(open(CATALOG))["records"]
    groups = defaultdict(list)
    for r in recs:
        g = r.get("duplicateGroupID") or ""
        if g:
            groups[g].append(r)

    online_cache = {}

    def is_online(v):
        if v not in online_cache:
            online_cache[v] = v == "(internal)" or os.path.ismount(f"/Volumes/{v}")
        return online_cache[v]

    stats = defaultdict(lambda: [0, 0])  # class -> [groups, reclaimable bytes]
    strand_examples = []

    for g, members in groups.items():
        if len(members) < 2:
            continue
        if not all((m.get("duplicateConfidence") or "") == "High" for m in members):
            continue

        keeps = [m for m in members if (m.get("duplicateDisposition") or "") == "Keep"]
        extras = [m for m in members if (m.get("duplicateDisposition") or "") == "Extra copy"]
        vols = {vol_of(m) for m in members}
        sizes = sorted((m.get("sizeBytes", 0) or 0) for m in members)
        reclaimable = sum(sizes[:-1])

        any_online = any(is_online(v) for v in vols)
        keep_online = any(is_online(vol_of(m)) for m in keeps) if keeps else False
        any_redundant = any(v in REDUNDANT for v in vols)

        if not any_online:
            cls = "ALL members offline"
        elif keeps and not keep_online:
            cls = "STRANDS: keeper is offline, extras online"
            if len(strand_examples) < 5:
                strand_examples.append(
                    (keeps[0].get("filename", "?"),
                     vol_of(keeps[0]),
                     [vol_of(e) for e in extras])
                )
        elif any_redundant:
            cls = "safe: a copy is on RAID"
        elif all(is_online(v) for v in vols):
            cls = "all online, none redundant"
        else:
            cls = "mixed online/offline, keeper online"

        stats[cls][0] += 1
        stats[cls][1] += reclaimable

    print("=== High-confidence duplicate groups, by collapse safety ===\n")
    for cls, (n, b) in sorted(stats.items(), key=lambda kv: -kv[1][1]):
        print(f"  {n:>6,} groups  {gb(b):>9,.1f} GB   {cls}")

    if strand_examples:
        print("\n=== examples where the 'Keep' sits on an OFFLINE volume ===")
        for fn, kv, evs in strand_examples:
            print(f"  {fn[:52]:<52} keep={kv:<18} extras on {sorted(set(evs))}")


if __name__ == "__main__":
    main()
