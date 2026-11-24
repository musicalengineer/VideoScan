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
    sealed_home.py run [--empty] [--plain] -- <command> [args…]

`run` (2026-11-23, every lane sealed): allocate a fresh home in the temp dir, run <command> with the
test process's HOME / CFFIXED_USER_HOME / TMPDIR / VIDEOSCAN_TEST_TMP pointing into it, report what the
tests left in its tmp, free it (also on TERM/HUP/Ctrl-C), exit with the command's code. By default the
variables are TEST_RUNNER_-prefixed: `xcodebuild test` keeps the real home for its own caches and hands
them, prefix stripped, to the test host (`man xcodebuild`, TEST_RUNNER_<VAR>). --plain sets them unprefixed,
for a command that IS the test process (`swift test --skip-build`). --empty: no copy of App Support (a
source-scan lane needs no data; nothing to copy, nothing to free but folders). Worst case on disk: one
App Support copy (clones + ~1 GB of database backups) for the length of the command.
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
# Proof a folder is a sealed home THIS script made (its pid on the first line). A sweep that frees dead lanes' homes
# deletes only a folder carrying it — a matching folder NAME is not proof (Codex 2026-11-23, runner deletion review).
OWNER_FILE = ".videoscan-sealed-home"


def _create_exclusive(path: Path, text: str) -> None:
    """Create `path` as a NEW regular file — never through a symlink, never truncating an existing file."""
    fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644)
    with os.fdopen(fd, "w") as f:
        f.write(text)


def _ensure_regular_file(path: Path, text: str) -> None:
    """The file exists as a regular file (left from an earlier prepare of the same home), or is created. A symlink
    or anything else at that name is REFUSED (Codex 2026-11-23: write_text through a symlink truncated its target)."""
    if os.path.lexists(path):
        if path.is_symlink() or not path.is_file():
            raise Refused(f"{path} exists and is not a regular file (a symlink?) — not writing through it")
        return
    _create_exclusive(path, text)
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


def prepare(home: Path, real_home: Optional[Path] = None, copy: bool = True) -> Path:
    """Make `home` a sealed home holding a copy of the real App Support (if there is one; copy=False: an
    empty home, nothing copied). Returns it."""
    real = real_home or _real_home()
    home = Path(home)
    # what the seal protects: the real App Support, Logs and Preferences (a run folder under ~/Library/Caches is fine)
    guarded = [real / "Library" / sub for sub in ("Application Support", "Logs", "Preferences")]
    if home.resolve() == real.resolve() or any(_inside(home, g) for g in guarded):
        raise Refused(f"a sealed home at {home} would be inside the real home's App Support, Logs or Preferences")
    if home.is_symlink():                    # the home itself, not only what is beneath it (Codex 2026-11-23 r2)
        raise Refused(f"{home} is a symlink — a sealed home is never prepared (or later freed) through a link")
    home.mkdir(parents=True, exist_ok=True)
    for sub in SUBDIRS:                      # no part of the sealed home may be a symlink out of it
        if any((home / Path(*Path(sub).parts[:i + 1])).is_symlink() for i in range(len(Path(sub).parts))):
            raise Refused(f"{home / sub} is (or passes through) a symlink — not preparing a sealed home through it")
        (home / sub).mkdir(parents=True, exist_ok=True)
    _ensure_regular_file(home / OWNER_FILE, f"{os.getpid()} sealed home made by scripts/sealed_home.py\n")
    _ensure_regular_file(home / "tmp" / TMP_MARKER, "the runner's sealed test temp root (scripts/sealed_home.py)\n")
    if not copy:
        return home
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
        if e.name in (TMP_MARKER, OWNER_FILE):
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


def test_env(home: Path, runner: bool = True) -> Dict[str, str]:
    """What points a test process at `home`. runner=True: TEST_RUNNER_-prefixed, for xcodebuild to hand on."""
    tmp = str(Path(home) / "tmp") + "/"      # Foundation ignores TMPDIR: the tests' scratch helpers read VIDEOSCAN_TEST_TMP
    env = {"HOME": str(home), "CFFIXED_USER_HOME": str(home), "TMPDIR": tmp, "VIDEOSCAN_TEST_TMP": tmp}
    return {f"TEST_RUNNER_{k}": v for k, v in env.items()} if runner else env


def run(cmd: List[str], copy: bool = True, plain: bool = False) -> int:
    """Allocate a sealed home, run `cmd` pointed at it, free it (whoever allocates frees). The command's exit
    code; 128+N when a signal N ended it or this runner. ≈ C++: an RAII guard around one child process."""
    import signal
    import tempfile
    home = Path(tempfile.mkdtemp(prefix="videoscan-sealed-home-"))

    def stop(signum, frame):                 # TERM/HUP become an exception, so `finally` frees the home
        raise SystemExit(128 + signum)
    for sig in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, stop)
    child = None
    try:
        src = os.environ.get("VIDEOSCAN_SEAL_SOURCE_HOME")       # tests: a fake source; never changes the destination
        prepare(home, Path(src) if src else None, copy=copy)
        print(f"sealed-home: the test process runs with HOME = {home} ({'a copy of App Support' if copy else 'empty'}; "
              f"freed after)", file=sys.stderr, flush=True)
        try:
            child = subprocess.Popen(cmd, env=dict(os.environ, **test_env(home, runner=not plain)))
        except OSError as e:
            print(f"sealed-home: cannot run {cmd[0]}: {e}", file=sys.stderr)
            return 127
        rc = child.wait()
        return 128 - rc if rc < 0 else rc
    finally:
        if child is not None and child.poll() is None:            # we were stopped: the child goes too
            child.terminate()
            try:
                child.wait(30)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
        line = leftovers_line(home / "tmp")
        if line:
            print(f"sealed-home: {line}", file=sys.stderr, flush=True)
        shutil.rmtree(home, ignore_errors=True)    # never follows a symlink out of the home


def main(argv=None) -> int:
    a = list(sys.argv[1:] if argv is None else argv)
    if a[:1] == ["run"] and "--" in a:
        opts, cmd = a[1:a.index("--")], a[a.index("--") + 1:]
        if cmd and set(opts) <= {"--empty", "--plain"}:
            return run(cmd, copy="--empty" not in opts, plain="--plain" in opts)
    if len(a) != 2 or a[0] != "prepare":
        print("usage: sealed_home.py prepare <home> | run [--empty] [--plain] -- <command> [args…]", file=sys.stderr)
        return 2
    try:
        src = os.environ.get("VIDEOSCAN_SEAL_SOURCE_HOME")
        print(prepare(Path(a[1]), Path(src) if src else None))
    except Refused as e:
        print(f"REFUSED: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
