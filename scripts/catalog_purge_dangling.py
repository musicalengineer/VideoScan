#!/usr/bin/env python3
"""Purge catalog records whose files were DELIBERATELY deleted (2026-08-18
redistribution cleanup). Catalog-only: no media is touched -- the files are
already gone. Modeled on catalog_reduce.py (flock + OCC generation bump +
.prev + timestamped snapshot).

Selection (ALL must hold):
  * fullPath is under one of ROOTS (Rick's deliberate cleanups)
  * the volume IS mounted right now (offline volume != deleted file)
  * the file does not exist on disk
Run with --apply to write. Without it, reports only and changes nothing.
"""
import fcntl, json, os, shutil, subprocess, sys, time
from collections import Counter

CATALOG = os.path.expanduser("~/Library/Application Support/VideoScan/catalog.json")
if "--catalog" in sys.argv:
    CATALOG = sys.argv[sys.argv.index("--catalog") + 1]
APPLY = "--apply" in sys.argv

ROOTS = [
    "/Volumes/CrucialX9/may5/",                                # Donna-compilation experiment outputs
    "/Volumes/CrucialX9/output_may3/",                          # same
    "/Volumes/LaCieWorkspace/CheesegraterArchive/InternalRaid/",
    "/Volumes/LaCieWorkspace/CheesegraterArchive/osx10.8_backup/",
    "/Volumes/LaCieWorkspace/CheesegraterArchive/highsierra_rickb/",
]

def vol_of(p):
    parts = p.split("/")
    return "/".join(parts[:3]) if p.startswith("/Volumes/") else "/"

def app_running():
    try:
        r = subprocess.run(["pgrep", "-x", "-l", "-f", "VideoScan"], capture_output=True, text=True, timeout=10)
        for line in r.stdout.splitlines():
            if "VideoScan.app/Contents/MacOS/VideoScan" not in line: continue
            if "--find-tag" in line or "--hallie" in line: continue
            return True
        return False
    except (subprocess.SubprocessError, OSError):
        return True

def header_generation(path, head_bytes=8192):
    import re
    try:
        with open(path, "rb") as f: head = f.read(head_bytes).decode("utf-8", "ignore")
    except OSError: return None
    m = re.search(r'"generation"\s*:\s*(\d+)', head)
    return int(m.group(1)) if m else None

def main():
    if app_running():
        print("VideoScan GUI is running -- quit it first (it writes the catalog wholesale).")
        if APPLY: sys.exit(1)
    mtime_at_read = os.path.getmtime(CATALOG)
    doc = json.load(open(CATALOG)); recs = doc["records"]
    keep, drop = [], []
    for r in recs:
        p = r.get("fullPath", "")
        if any(p.startswith(root) for root in ROOTS) and os.path.isdir(vol_of(p)) and not os.path.exists(p):
            drop.append(r)
        else:
            keep.append(r)
    print(f"records: {len(recs):,}   purge: {len(drop):,}   keep: {len(keep):,}")
    print("\nby root:")
    for root in ROOTS:
        n = sum(1 for r in drop if r["fullPath"].startswith(root)); gb = sum((r.get("sizeBytes") or 0) for r in drop if r["fullPath"].startswith(root))/1e9
        print(f"  {n:5d} {gb:7.1f} GB  {root}")
    print("\nlifecycle:", dict(Counter(r.get("lifecycleStage") for r in drop)))
    print("disposition:", dict(Counter(r.get("mediaDisposition") for r in drop)))
    print("dup disposition:", dict(Counter(r.get("duplicateDisposition") for r in drop)))
    valued = [r for r in drop if (r.get("starRating") or 0) >= 2 or r.get("confirmedByUserPeople") or (r.get("userNotes") or "").strip()]
    print(f"\nrecords with human metadata (star>=2 / confirmed people / notes): {len(valued)}")
    for r in valued[:40]:
        print(f"   *{r.get('starRating') or 0} people={r.get('confirmedByUserPeople')} notes={(r.get('userNotes') or '')[:40]!r}  {r['fullPath']}")
    if not APPLY:
        print("\n(dry run -- pass --apply to write)"); return
    lock_fd = os.open(os.path.join(os.path.dirname(CATALOG), "catalog.lock"), os.O_RDWR | os.O_CREAT, 0o644)
    try:
        try: fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            print("ABORTED: catalog.lock is held by another writer."); sys.exit(1)
        if os.path.getmtime(CATALOG) != mtime_at_read:
            print("ABORTED: catalog.json changed since read."); sys.exit(1)
        gen_read = int(doc.get("generation", 0)); gen_disk = header_generation(CATALOG)
        if gen_disk is not None and gen_disk != gen_read:
            print(f"ABORTED: on-disk generation {gen_disk} != read {gen_read}."); sys.exit(1)
        doc["generation"] = gen_read + 1
        doc["records"] = keep
        stamp = time.strftime("%Y-%m-%dT%H-%M-%SZ", time.gmtime())
        snap = CATALOG.replace("catalog.json", f"catalog.pre-danglingpurge.{stamp}.json")
        shutil.copy2(CATALOG, snap); shutil.copy2(CATALOG, CATALOG + ".prev")
        tmp = CATALOG + ".tmp"
        with open(tmp, "w") as f: json.dump(doc, f, ensure_ascii=False)
        os.replace(tmp, CATALOG)
        # decode sensor: the file we just wrote must load
        json.load(open(CATALOG))
        print(f"\nWRITTEN generation {doc['generation']}: {len(keep):,} records remain. Snapshot: {os.path.basename(snap)}")
    finally:
        fcntl.flock(lock_fd, fcntl.LOCK_UN); os.close(lock_fd)

if __name__ == "__main__": main()
