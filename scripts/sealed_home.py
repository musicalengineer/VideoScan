#!/usr/bin/env python3
"""sealed_home.py — the home folder every test host and Core test process runs with: a COPY of the real
~/Library/Application Support/VideoScan, never the real one.

Why (DECISIONS 2026-11-22, Rick: "Tests always use a synthetic or a copy, they can never open the real
catalog"): the test lanes set HOME = CFFIXED_USER_HOME = <run>/home (scripts/xctest_shards.py,
scripts/core_lane.py), so FileManager's Application Support, Logs and Preferences resolve inside the run.
An EMPTY home made 35 real-data tests skip (production-shape migrations on a .backup of the live catalog,
the real GEDCOM, search on real data, installed models — measured on the Ultra 2026-11-22: 107 skipped
sealed vs 72 unsealed, 0 failed). So the sealed home holds today's data, copied:

  * every SQLite database that has a -wal or -shm beside it (the ones a running app has open), and the
    catalog, is copied with SQLite's ONLINE BACKUP API from a read-only connection — the only safe copy
    of a live database (CLAUDE.md: copy the catalog only with sqlite .backup); its -wal/-shm are not copied;
  * everything else is an APFS clone (`cp -c`): instant, no extra space on the same volume, and a write
    to the clone never reaches the original (copy-on-write).

Nothing here writes under the real home: the source is only read; the destination must be outside the
real ~/Library (refused otherwise). ≈ C++: handing the test a deep copy of the production state instead of
a pointer to it.

    sealed_home.py prepare <home>      # print the prepared home's path
"""
from __future__ import annotations

import os
import shutil
import sqlite3
import subprocess
import sys
from pathlib import Path
from typing import Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))
import catalog_db  # noqa: E402  (the one read-only door to the catalog)

SUBDIRS = ("Library/Application Support", "Library/Logs", "Library/Preferences", "Library/Caches")
APP = Path("Library") / "Application Support" / "VideoScan"
DB_SUFFIXES = (".sqlite", ".sqlite3", ".db")


class Refused(Exception):
    pass


def _real_home() -> Path:
    import pwd
    return Path(pwd.getpwuid(os.getuid()).pw_dir)      # not $HOME: an overridden HOME cannot move the source


def _inside(child: Path, parent: Path) -> bool:
    try:
        child.resolve().relative_to(parent.resolve())
        return True
    except ValueError:
        return False


def _is_catalog(p: Path) -> bool:
    return p.name == catalog_db.DATABASE_FILE_NAME


def _is_live_db(p: Path) -> bool:
    """A database a running app may hold open: one with a -wal/-shm beside it, or THE catalog (its cutover
    latch beside it). A static backup copy (no latch, no -wal) is safe to clone as it is."""
    if p.suffix not in DB_SUFFIXES:
        return False
    if p.with_name(p.name + "-wal").exists() or p.with_name(p.name + "-shm").exists():
        return True
    return _is_catalog(p) and (p.parent / catalog_db.LATCH_FILE_NAME).exists()


def _open_source(src: Path) -> sqlite3.Connection:
    """Read-only. The catalog only through its one door, scripts/catalog_db.connect (mode=ro + query_only;
    tests/test_no_script_writes_catalog.py); catalog_db.CatalogUnavailable when the door refuses it."""
    if _is_catalog(src):
        return catalog_db.connect(src)
    return sqlite3.connect(f"file:{src}?mode=ro", uri=True, timeout=30)


def _backup(src: Path, dst: Path) -> None:
    """SQLite's online backup from a read-only connection: a consistent copy including committed WAL frames."""
    s = _open_source(src)                  # first: a refused source leaves the clone in place
    dst.parent.mkdir(parents=True, exist_ok=True)
    for extra in ("", "-wal", "-shm", "-journal"):
        with_extra = Path(str(dst) + extra)
        if with_extra.exists() or with_extra.is_symlink():
            with_extra.unlink()
    try:
        d = sqlite3.connect(str(dst))
        try:
            s.backup(d)
        finally:
            d.close()
    finally:
        s.close()


def prepare(home: Path, real_home: Optional[Path] = None) -> Path:
    """Make `home` a sealed home holding a copy of the real App Support (if there is one). Returns it."""
    real = real_home or _real_home()
    home = Path(home)
    # what the seal protects: the real App Support, Logs and Preferences (a run folder under ~/Library/Caches is fine)
    guarded = [real / "Library" / sub for sub in ("Application Support", "Logs", "Preferences")]
    if home.resolve() == real.resolve() or any(_inside(home, g) for g in guarded):
        raise Refused(f"a sealed home at {home} would be inside the real home's App Support, Logs or Preferences")
    for sub in SUBDIRS:
        (home / sub).mkdir(parents=True, exist_ok=True)
    src = real / APP
    if not src.is_dir():
        return home
    dst = home / APP
    if dst.exists():
        shutil.rmtree(dst)
    # clone the tree (APFS copy-on-write; a plain copy where cloning is not possible)
    rc = subprocess.run(["/bin/cp", "-cR", str(src), str(dst)], capture_output=True, text=True).returncode
    if rc != 0:
        if dst.exists():
            shutil.rmtree(dst)
        shutil.copytree(src, dst, symlinks=True)
    # the live databases: replace each clone with an online backup
    for p in sorted(src.rglob("*")):
        if p.is_file() and not p.is_symlink() and _is_live_db(p):
            try:
                _backup(p, dst / p.relative_to(src))
            except catalog_db.CatalogUnavailable as e:
                # e.g. the viewer's synced copy has no cutover latch: it keeps its clone (-wal included)
                print(f"sealed_home: {p.relative_to(src)} kept as a clone (no {catalog_db.LATCH_FILE_NAME} beside it)",
                      file=sys.stderr)
                del e
    return home


def main(argv=None) -> int:
    a = list(sys.argv[1:] if argv is None else argv)
    if len(a) != 2 or a[0] != "prepare":
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    try:
        print(prepare(Path(a[1])))
    except Refused as e:
        print(f"REFUSED: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
