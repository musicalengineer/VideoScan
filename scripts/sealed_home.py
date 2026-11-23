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
import re
import shutil
import sqlite3
import subprocess
import sys
from pathlib import Path
from typing import Dict, List, NamedTuple, Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))
import catalog_db  # noqa: E402  (the one read-only door to the catalog)

SUBDIRS = ("Library/Application Support", "Library/Logs", "Library/Preferences", "Library/Caches", "tmp")
APP = Path("Library") / "Application Support" / "VideoScan"
DB_SUFFIXES = (".sqlite", ".sqlite3", ".db")
# The marker a test process requires before it trusts VIDEOSCAN_TEST_TMP as the root it may remove scratch from
# (VideoScanCore TestHostScratch.rootMarkerName; Codex 2026-11-23 #352 P1-1).
TMP_MARKER = ".videoscan-test-tmp"
MODEL_CACHES = (Path(".cache") / "huggingface",)     # read by the app from the home; public weights


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
            # Rollback-journal mode: the copy keeps the source's WAL flag, and a WAL file with no -shm
            # cannot be opened READ-ONLY (the production-shape tests' `sqlite3 file:…?mode=ro .backup`:
            # "unable to open database file", 13 tests RED 2026-11-22). Data and schema are unchanged;
            # a writer that wants WAL switches it back on open, as the app does.
            d.execute("PRAGMA journal_mode=DELETE")
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
    (home / "tmp" / TMP_MARKER).write_text("the runner's sealed test temp root (scripts/sealed_home.py)\n")
    # public model caches the app reads from the home (SigLIP's weights: ~/.cache/huggingface) — cloned
    for rel in MODEL_CACHES:
        m_src, m_dst = real / rel, home / rel
        if m_src.is_dir() and not m_dst.exists():
            m_dst.parent.mkdir(parents=True, exist_ok=True)
            if subprocess.run(["/bin/cp", "-cR", str(m_src), str(m_dst)], capture_output=True).returncode != 0:
                shutil.rmtree(m_dst, ignore_errors=True)
                shutil.copytree(m_src, m_dst, symlinks=True)
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


class Leftover(NamedTuple):
    prefix: str        # the folder name with its UUID / pid / random tail replaced by <id>
    count: int
    bytes: int


def _prefix(name: str) -> str:
    name = re.sub(r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}.*$", "<id>", name)
    name = re.sub(r"(?<=[-_.])\d{2,}([-_.][A-Za-z0-9]+)?$", "<id>", name)
    return re.sub(r"(?<=[-_.])[A-Za-z0-9]{6,10}$", "<id>", name) if "<id>" not in name else name


def leftovers(tmp: Path) -> List[Leftover]:
    """What the tests left in the sealed tmp, by prefix, biggest count first. Each line is a test that took
    disk and did not give it back (DECISIONS 2026-11-23: a leak is a bug) — reported, then freed with the home."""
    tmp = Path(tmp)
    if not tmp.is_dir():
        return []
    acc: Dict[str, List[int]] = {}
    for e in tmp.iterdir():
        if e.name == TMP_MARKER:
            continue
        size = 0
        try:
            size = sum(f.stat().st_size for f in ([e] if e.is_file() else e.rglob("*")) if f.is_file() and not f.is_symlink())
        except OSError:
            pass
        a = acc.setdefault(_prefix(e.name), [0, 0])
        a[0] += 1
        a[1] += size
    return sorted((Leftover(k, c, b) for k, (c, b) in acc.items()), key=lambda r: (-r.count, -r.bytes, r.prefix))


def leftovers_line(tmp: Path, top: int = 6) -> Optional[str]:
    rows = leftovers(tmp)
    if not rows:
        return None
    total = sum(r.count for r in rows)
    mb = sum(r.bytes for r in rows) / 1e6
    return (f"left behind by tests: {total} folder(s), {mb:.1f} MB — " +
            ", ".join(f"{r.prefix} ×{r.count}" for r in rows[:top]) + (" …" if len(rows) > top else "") +
            " (freed with the sealed home; each is a test that does not clean up)")


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
