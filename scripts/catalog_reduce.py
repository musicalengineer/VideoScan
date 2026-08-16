#!/usr/bin/env python3
"""Reduce the VideoScan catalog in two passes.

  PASS A  untrack records living on OFFLINE volumes (retired shelf drives)
  PASS B  re-elect duplicate Keep/Extra dispositions among survivors,
          weighting volume role instead of whatever elected shelf drives

Run with --apply to write. Without it, reports only and changes nothing.

Election priority (highest wins):
    3  redundant  -- FamilyArchive, Projects (RAID5)
    2  master     -- LaCieWorkspace, MediaExpansion
    1  scratch    -- CrucialX9, CrucialX10, SanDiskWorkspace
    0  other online / internal
   -1  offline
Ties break on larger sizeBytes, then on record id for determinism.
"""
import json
import subprocess
import os
import shutil
import sys
from collections import defaultdict

# --catalog PATH overrides the target (testing / offline forensics).
if "--catalog" in sys.argv:
    CATALOG = sys.argv[sys.argv.index("--catalog") + 1]
else:
    CATALOG = os.path.expanduser("~/Library/Application Support/VideoScan/catalog.json")

REDUNDANT = {"FamilyArchive", "Projects"}
MASTER = {"LaCieWorkspace", "MediaExpansion"}
SCRATCH = {"CrucialX9", "CrucialX10", "SanDiskWorkspace"}

APPLY = "--apply" in sys.argv


def vol_of(r):
    p = r.get("fullPath") or r.get("directory") or ""
    parts = p.split("/")
    if p.startswith("/Volumes/") and len(parts) > 2:
        return parts[2]
    return "(internal)"


_mounted = {}


def online(v):
    if v not in _mounted:
        _mounted[v] = (v == "(internal)") or os.path.ismount(f"/Volumes/{v}")
    return _mounted[v]


def rank(r):
    v = vol_of(r)
    if not online(v):
        return -1
    if v in REDUNDANT:
        return 3
    if v in MASTER:
        return 2
    if v in SCRATCH:
        return 1
    return 0


def gb(n):
    return n / 1e9


def app_running():
    """True if the VideoScan GUI app — the catalog's writer — is up.

    Matching by process NAME alone is too coarse: the same binary also
    runs headless as `--find-tag` (findtagd) and `--hallie`, and neither
    writes catalog.json by design (FindTagCLI.swift:10; the app ingests
    the daemon's journals). Blocking on those would refuse maintenance
    whenever a daemon happens to be scanning.
    """
    try:
        r = subprocess.run(["pgrep", "-x", "-l", "-f", "VideoScan"],
                           capture_output=True, text=True, timeout=10)
        for line in r.stdout.splitlines():
            if "VideoScan.app/Contents/MacOS/VideoScan" not in line:
                continue
            if "--find-tag" in line or "--hallie" in line:
                continue           # headless non-writers
            return True            # the GUI app: the actual writer
        return False
    except (subprocess.SubprocessError, OSError):
        return True   # fail closed: if we cannot tell, do not write


def header_generation(path, head_bytes=8192):
    """Cheap OCC probe mirroring CatalogSnapshot.headerProbe: the app writes
    savedAt then generation at the head of the object, so the number lands in
    the first few KB. Returns None if the key isn't in the head (pre-generation
    catalog) -- callers treat None as 'cannot tell', not as 0."""
    import re
    try:
        with open(path, "rb") as f:
            head = f.read(head_bytes).decode("utf-8", "ignore")
    except OSError:
        return None
    m = re.search(r'"generation"\s*:\s*(\d+)', head)
    return int(m.group(1)) if m else None


def main():
    if app_running():
        print("VideoScan is running -- quit it before reducing the catalog.\n"
              "It holds the catalog in memory and writes it back wholesale.")
        if APPLY:
            sys.exit(1)

    mtime_at_read = os.path.getmtime(CATALOG)
    doc = json.load(open(CATALOG))
    recs = doc["records"]
    before = len(recs)
    before_bytes = sum(r.get("sizeBytes", 0) or 0 for r in recs)

    # ---------- PASS A: untrack offline ----------
    offline_vols = defaultdict(lambda: [0, 0])
    keep, dropped = [], []
    for r in recs:
        v = vol_of(r)
        if online(v):
            keep.append(r)
        else:
            dropped.append(r)
            offline_vols[v][0] += 1
            offline_vols[v][1] += r.get("sizeBytes", 0) or 0

    print("=== PASS A: untrack offline volumes ===")
    for v, (c, b) in sorted(offline_vols.items(), key=lambda kv: -kv[1][1]):
        print(f"  {v:<24} {c:>7,} recs  {gb(b):>9,.1f} GB")
    print(f"  {'TOTAL DROPPED':<24} {len(dropped):>7,} recs  "
          f"{gb(sum(r.get('sizeBytes',0) or 0 for r in dropped)):>9,.1f} GB")

    # ---------- PASS B: re-elect duplicates among survivors ----------
    groups = defaultdict(list)
    for r in keep:
        g = r.get("duplicateGroupID") or ""
        if g:
            groups[g].append(r)

    changed_keep = 0
    changed_extra = 0
    orphaned_singletons = 0

    for g, members in groups.items():
        if len(members) == 1:
            # Group lost its siblings to Pass A -- it is no longer a duplicate.
            #
            # DELETE the keys rather than writing "" (the clobber-3/4 bug):
            # duplicateGroupID decodes as a Swift UUID, and "" is not a valid
            # UUID string -- ONE such field in ONE record failed the entire
            # 41 MB decode, and load() silently fell back to .prev, reverting
            # the whole reduction. Key-absence is what the Swift encoder
            # itself emits for these, and decodeIfPresent handles it.
            m = members[0]
            if (m.get("duplicateDisposition") or m.get("duplicateGroupID")):
                m.pop("duplicateDisposition", None)
                m.pop("duplicateGroupID", None)
                m.pop("duplicateBestMatchFilename", None)
                m.pop("duplicateConfidence", None)
                m.pop("duplicateReasons", None)
                m["duplicateGroupCount"] = 0
                orphaned_singletons += 1
            continue

        winner = max(members,
                     key=lambda r: (rank(r), r.get("sizeBytes", 0) or 0, r.get("id", "")))
        for m in members:
            want = "Keep" if m is winner else "Extra copy"
            if (m.get("duplicateDisposition") or "") != want:
                if want == "Keep":
                    changed_keep += 1
                else:
                    changed_extra += 1
                m["duplicateDisposition"] = want
            m["duplicateGroupCount"] = len(members)

    print("\n=== PASS B: re-elect duplicates among survivors ===")
    print(f"  surviving duplicate groups        {len([g for g,m in groups.items() if len(m)>1]):>7,}")
    print(f"  records promoted to 'Keep'        {changed_keep:>7,}")
    print(f"  records demoted to 'Extra copy'   {changed_extra:>7,}")
    print(f"  singletons cleared (siblings gone){orphaned_singletons:>7,}")

    # Verify every surviving group has exactly one keeper.
    bad = [g for g, m in groups.items()
           if len(m) > 1 and sum(1 for x in m if x.get("duplicateDisposition") == "Keep") != 1]
    print(f"  groups WITHOUT exactly one Keep   {len(bad):>7,}  {'<-- PROBLEM' if bad else '(good)'}")

    after_bytes = sum(r.get("sizeBytes", 0) or 0 for r in keep)
    print("\n=== RESULT ===")
    print(f"  records {before:>7,} -> {len(keep):>7,}   ({len(dropped):,} removed, "
          f"{100*len(dropped)/before:.0f}%)")
    print(f"  bytes   {gb(before_bytes):>7,.0f} -> {gb(after_bytes):>7,.0f} GB")

    if not APPLY:
        print("\nDRY RUN -- nothing written. Re-run with --apply to commit.")
        return
    if bad:
        print("\nABORTED: some groups lack exactly one keeper. Nothing written.")
        return

    # The catalog is single-writer. VideoScan holds the whole thing in
    # memory and writes it back wholesale, so if the app is running -- even
    # if it launched AFTER we started reading -- our write gets clobbered
    # by its next save. Check immediately before writing, not just at start.
    if app_running():
        print("\nABORTED: VideoScan is running. It would overwrite this write "
              "with its in-memory copy. Quit the app and re-run.")
        return

    # --- external-writer contract (docs/catalog_write_safety_design.md §5) ---
    # This script is the REFERENCE IMPLEMENTATION for scripts that write
    # catalog.json:
    #   1. take the advisory flock on catalog.lock (refuse, don't wait --
    #      maintenance is human-run; "quit the app first" is fine)
    #   2. bump `generation` so the app's OCC check sees our write and
    #      reconciles instead of clobbering us with its stale copy
    #   3. atomic replace, then release
    import fcntl
    lock_path = os.path.join(os.path.dirname(CATALOG), "catalog.lock")
    lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o644)
    try:
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            owner = ""
            try:
                owner = open(lock_path).read().strip()
            except OSError:
                pass
            print(f"\nABORTED: catalog.lock is held{' by ' + owner if owner else ''}. "
                  "Quit VideoScan (or wait for the other writer) and re-run.")
            return

        # Re-validate UNDER the lock (codex #385 TOCTOU: the old check ran
        # before flock, leaving a window in which the app could write and
        # we would then replace its newer file with our stale derivation).
        # Two independent signals: mtime, and the on-disk generation header.
        if os.path.getmtime(CATALOG) != mtime_at_read:
            print("\nABORTED: catalog.json changed on disk while we were working. "
                  "Nothing written.")
            return
        gen_read = int(doc.get("generation", 0))
        gen_disk = header_generation(CATALOG)
        if gen_disk is not None and gen_disk != gen_read:
            print(f"\nABORTED: catalog.json generation on disk is {gen_disk}, "
                  f"we derived from {gen_read}. Someone wrote in between. Nothing written.")
            return

        doc["generation"] = gen_read + 1
        shutil.copy2(CATALOG, CATALOG + ".prev")
        doc["records"] = keep
        tmp = CATALOG + ".tmp"
        with open(tmp, "w") as f:
            json.dump(doc, f)
        os.replace(tmp, CATALOG)
        print(f"\nWRITTEN generation {doc['generation']}. {len(keep):,} records remain. "
              "Previous saved to catalog.json.prev")
    finally:
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        os.close(lock_fd)


if __name__ == "__main__":
    main()
