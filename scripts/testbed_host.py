#!/usr/bin/env python3
"""testbed_host.py — housekeeping on a test host for scripts/m4_run.sh: what is kept, and status for machines.

    testbed_host.py prune <root> [--current <run dir>] [--keep N]
    testbed_host.py status-json <root> <host name>
    testbed_host.py window <root> <lane> <HHMM>
    testbed_host.py start-by <root> <lane> <HHMM> <epoch>
    testbed_host.py ran <root> <40-hex sha> [<run dir to ignore>]
    testbed_host.py show <file> [--under <dir>] [--match <regex>] [--tail N]
    testbed_host.py clean <root> --current <run dir> --phase start|end
    testbed_host.py sample <root> <run dir>
    testbed_host.py stop <root> <run dir>

clean and sample (DECISIONS 2026-11-18, the M4 kept at least 50% free): see the section
"clean" below. clean runs at a run start and once its summary is written, under the lock it
must hold itself; it prints the one "disk: free N% ..." line the summary carries. sample keeps
the lowest free figure seen while the run works.

prune (run by m4_run.sh at the start of every lane, under the testbed lock). <root>/out
holds one folder per run, 140-420 MB each for a suite run; nothing removed them before.
KEPT: the newest N runs of each lane (N = --keep, else KEEP in <root>/testbed.conf, else 10),
every run whose run.log says OUTCOME RED, whatever <root>/latest* points at, and --current.
Everything else under <root>/out that is named <stamp>-<lane> is removed, with its
<root>/bin/<stamp> and its agent plist. A bin folder or plist with no run folder is removed
only when it is older than a day (a caller installs them moments before its run starts).
<root>/bin/watch (the push watcher, pinned there) is never removed.
Symlinks are never followed and nothing outside <root> is touched. One line is printed:

    prune: removed 14 run folders (3.9 GB), kept 31 (newest 10 per lane, 4 RED, 2 pinned)

status-json prints one JSON object: the lock (idle or running, and who holds it), and for
the last run, the last suite run and the last testbed run: lane, commit, START and OUTCOME
times, the verdict word, the summary lines, and for a testbed run its lanes. It is what
`m4_run.sh status --json` returns. It reads the same files `status` reads; a file that is
missing or cut short gives null, never a traceback.

window answers whether an on-demand lane may START now, given the host clock <HHMM>:
prints "OK", or "QUIET <words>" inside the quiet window before a scheduled run. The
schedule and the window come from <root>/testbed.conf when it has them:

    KEEP=10               runs kept per lane
    SCHEDULED=1400        scheduled runs on this host, HHMM, comma separated
    QUIET_MINUTES=90      refuse to start a lane this long before one (default: by lane)

The default window is the expected length of the lane, so a lane started outside it is
done before the scheduled run begins: testbed 120, all 90, suite 75, deep 60, corpus 45,
ui 30 minutes. (The scheduled run does NOT wait for the lock: scripts/nightly_gauntlet.sh
runs its suite anyway and skips only its gauntlet, so an overlap is two suites at once.)

start-by answers, at the moment the caller checks the windows, the latest moment (epoch
seconds) the lane may still START: the next 01:30 or the next quiet-window start, whichever
comes first. The caller passes it to the host side, which refuses a run that reaches its lock
after it (Codex #315-6: a check that passed at 01:29 must not let a run start at 01:31).

show prints a file a caller will read back (a summary, a run log, a testbed block) only through
a door that proves it: opened without following a link, a regular file with ONE name, inside
--under when given, at most 256 KB — and each line that could carry a name is withheld (a media
file extension, a run of 41+ hex or of 24+ hex that is not a commit id after "sha=", a path
below /Volumes, ~/corpus/media or ~/corpus/live, a home path that is not the run root). A file that fails the door prints one line saying so (Codex
#315-3: `status` never prints unvalidated text).

No apostrophes anywhere in this file: m4_run.sh ships it to the host inside a heredoc.
Memory: one run.log (KBs) at a time. Python 3.9 is the floor. Tests: tests/test_testbed_host.py.
"""
from __future__ import annotations

import fcntl
import json
import os
import re
import shutil
import signal
import stat
import sys
import time

LANES = ("ui", "deep", "all", "suite", "corpus", "testbed")
RUN_NAME = re.compile(r"^([0-9A-Za-z_]+)-(" + "|".join(LANES) + r")$")
KEEP_DEFAULT = 10
POINTERS = ("latest", "latest-suite", "latest-testbed")
PINNED_BINS = ("watch",)                         # <root>/bin/watch: the push watcher (scripts/m4_watch_install.sh) — never pruned
DAY = 86400
QUIET_DEFAULT = {"testbed": 120, "all": 90, "suite": 75, "deep": 60, "corpus": 45, "ui": 30}
SCHEDULED_DEFAULT = {"m4run": ["1400"]}          # by root folder name; the Ultra has the 01:30-06:00 window already
SUMMARY_LINES = 60


def conf(root: str) -> dict:
    """<root>/testbed.conf as {KEY: value}: KEY=value lines, nothing executed."""
    values = {}
    try:
        with open(os.path.join(root, "testbed.conf"), encoding="utf-8", errors="replace") as f:
            for line in f:
                m = re.fullmatch(r"\s*([A-Z_]+)\s*=\s*([0-9,: ]+?)\s*", line.split("#", 1)[0])
                if m:
                    values[m.group(1)] = m.group(2)
    except OSError:
        pass
    return values


def _number(text, default: int, low: int, high: int) -> int:
    try:
        value = int(str(text).strip())
    except (TypeError, ValueError):
        return default
    return value if low <= value <= high else default


# ── prune ─────────────────────────────────────────────────────────────────

def _tree_bytes(path: str) -> int:
    total = 0
    for folder, _, names in os.walk(path):
        for name in names:
            try:
                total += os.lstat(os.path.join(folder, name)).st_size
            except OSError:
                pass
    return total


def _outcome(run: str) -> str:
    """The verdict word of a run folder (GREEN, RED, ...), or "" when its log has no OUTCOME."""
    try:
        with open(os.path.join(run, "run.log"), encoding="utf-8", errors="replace") as f:
            for line in f:
                if line.startswith("OUTCOME "):
                    return line.split()[1]
    except (OSError, IndexError):
        pass
    return ""


def prune(root: str, current: str = "", keep: int = 0) -> str:
    out = os.path.join(root, "out")
    keep = keep or _number(conf(root).get("KEEP"), KEEP_DEFAULT, 1, 1000)
    pinned = {os.path.realpath(current)} if current else set()
    for pointer in POINTERS:
        path = os.path.join(root, pointer)
        if os.path.islink(path):
            pinned.add(os.path.realpath(path))
    by_lane = {}
    try:
        names = sorted(os.listdir(out))
    except OSError:
        return "prune: nothing to do (no run folder yet)"
    for name in names:
        path = os.path.join(out, name)
        m = RUN_NAME.match(name)
        if not m or os.path.islink(path) or not os.path.isdir(path):
            continue                                        # not a run folder: never touched
        try:
            when = os.lstat(path).st_mtime
        except OSError:
            continue
        by_lane.setdefault(m.group(2), []).append((when, name, path, m.group(1)))
    removed = freed = kept = red = held = 0
    gone_stamps, live_stamps = set(), set()
    for runs in by_lane.values():
        runs.sort()
        newest = {path for _, _, path, _ in runs[-keep:]}
        for _, _, path, stamp in runs:
            is_red = _outcome(path) == "RED"
            is_pinned = os.path.realpath(path) in pinned
            if path in newest or is_red or is_pinned:
                kept += 1
                red += int(is_red and path not in newest)
                held += int(is_pinned and path not in newest and not is_red)
                live_stamps.add(stamp)
                continue
            size = _tree_bytes(path)
            shutil.rmtree(path, ignore_errors=True)
            if os.path.exists(path):
                kept += 1                                   # could not be removed: still there, still counted
                live_stamps.add(stamp)
                continue
            removed += 1
            freed += size
            gone_stamps.add(stamp)
    gone_stamps -= live_stamps                              # `all` and another lane can share a stamp
    now = time.time()
    try:
        bins = os.listdir(os.path.join(root, "bin"))
    except OSError:
        bins = []
    for stamp in bins:
        path = os.path.join(root, "bin", stamp)
        if os.path.islink(path) or not os.path.isdir(path) or stamp in live_stamps or stamp in PINNED_BINS:
            continue
        try:
            old = now - os.lstat(path).st_mtime > DAY
        except OSError:
            continue
        if stamp in gone_stamps or old:
            shutil.rmtree(path, ignore_errors=True)
    try:
        entries = os.listdir(root)
    except OSError:
        entries = []
    for name in entries:
        m = re.fullmatch(r"com\.videoscan\.[a-z0-9]+\.([0-9A-Za-z_]+)\.plist", name)
        path = os.path.join(root, name)
        if not m or m.group(1) in live_stamps or os.path.islink(path) or not os.path.isfile(path):
            continue
        try:
            old = now - os.lstat(path).st_mtime > DAY
        except OSError:
            continue
        if m.group(1) in gone_stamps or old:
            try:
                os.remove(path)
            except OSError:
                pass
    return ("prune: removed %d run folder%s (%.1f GB), kept %d (newest %d per lane, %d RED, %d pinned)"
            % (removed, "" if removed == 1 else "s", freed / 1e9, kept, keep, red, held))


# ── clean: the M4 kept at least 50% free (DECISIONS 2026-11-18) ────────────
#
# Measured on the M4, 2026-11-18 (971 GB data volume, 40% free before this existed):
#   a suite or testbed run folder   410-430 MB (suite-app.xcresult ~310 MB, suite.log and
#                                   suite-app-test.log ~48 MB each); a corpus run 0.2-1.2 MB;
#                                   ui/gauntlet runs ~185 MB (the xcresult)
#   <root>/bin/<stamp>              ~0.2 MB each        corpus work/<stamp>-<lane>: removed by
#   videoscan-m4run-dd              5.5 GB (ui + corpus lanes, Debug)       the lane itself;
#   videoscan-m4run-dd-suite        7.3 GB (suite lane: Release app + Core) verbs clones are
#                                                                           APFS clones (0 B)
# A run may use as much disk as it needs. Once it is summarized its scratch goes; kept: run.log,
# summary.txt, the verdict files and a 200-line tail of each other log, under its own name, so a
# summary that names a log still names a file (KB per run). No run folder is kept whole: a whole
# suite folder is 0.4 GB, and the summary already names every failed test.
#
# Worst case on disk: the largest run (testbed: ~0.45 GB) plus the two caches (~13 GB) plus what
# the lanes write while they run. Memory: one 64 KB log tail at a time and one directory walk.

FLOOR = 0.50
TAIL_LINES = 200
TAIL_BYTES = 64 * 1024
SAMPLE_SECONDS = 15
CORPUS_LANES = ("check", "proof", "verbs")
# ~/corpus/work/<stamp>-<lane>, and <stamp>-coverage (the raw profiles of scripts/corpus_coverage.py)
RUN_WORK = re.compile(r"^[0-9A-Za-z_]+-(" + "|".join(CORPUS_LANES + ("coverage",)) + r")$")
CORPUS_OUT = re.compile(r"^corpus-(" + "|".join(CORPUS_LANES) + r")$")             # <run>/corpus-<lane> in a testbed run
KEEP_FILES = frozenset({"run.log", "summary.txt", "testbed-block.txt", "lanes.tsv", "suite-row.json", "corpus-summary.txt",
                        "corpus-verdict.json", "disk-start.txt", "disk-low.txt", "tidy.txt"})
KEEP_SUFFIXES = (".tests.tsv",)
CORPUS_MARKER = "THIS_IS_TEST_DATA.txt"
# Never a target, whatever a path resolved through: the corpus sources, its documents, its stored
# reports and accepted baselines, its sealed state, the read-only share mount.
CORPUS_PROTECTED = ("media", "live", "state", "reports", "corpus-sha-v1.txt", "corpus-manifest-v1.json",
                    "catalog-source-backup.sqlite", CORPUS_MARKER, "share.credentials", "_experiment", ".trash")
CLEAN_BUDGET = 900                # seconds: a cleanup past it stops and says so; the run still reaches OUTCOME
STOP_BUDGET = 30                  # seconds for the stop marker (Codex #324 S5: every helper call is bounded)
O_DIR = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
O_READ = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK      # NONBLOCK: a FIFO never stalls an open (Codex #322 F6)
LOCKED = 0x2 | 0x4 | 0x20000 | 0x40000                    # UF/SF IMMUTABLE and APPEND: such a file stays, whatever we do


class Refused(Exception):
    """The cleanup said no. The message carries no path below the home folder."""


class OverBudget(Exception):
    """The cleanup ran past CLEAN_BUDGET."""


# Every operation below is relative to a folder DESCRIPTOR, and every folder is opened from the
# home folder down one name at a time with O_NOFOLLOW and on the home volume only (Codex #322 F1,
# F2, F5): a name swapped for a link after a check cannot redirect an unlink, a rename or a write,
# and a mounted volume is never entered. (C++: openat/unlinkat/renameat on a dirfd, never a path.)

def _open_dir(name: str, dir_fd: int, dev: int) -> int:
    """A folder of `dir_fd`, never through a link, on the device `dev`; else Refused."""
    try:
        fd = os.open(name, O_DIR, dir_fd=dir_fd)
    except OSError:
        raise Refused("a folder is missing, a link, or not a folder")
    if os.fstat(fd).st_dev != dev:
        os.close(fd)
        raise Refused("a folder is on another volume (a mount)")
    return fd


def _lstat_at(dir_fd: int, name: str):
    """The entry as itself, or None when it is not there. Any other error refuses: a name that cannot
    be inspected is never taken for an absent one (Codex #325 T1)."""
    try:
        return os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
    except FileNotFoundError:
        return None
    except OSError:
        raise Refused("a name could not be inspected")


def _write_at(dir_fd: int, name: str, text: str, create: bool = False) -> bool:
    """Write a file of this cleanup in an open folder: never through a link, never a FIFO, never a
    file with a second name."""
    flags = os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK | (os.O_EXCL if create else 0)
    try:
        fd = os.open(name, flags, 0o644, dir_fd=dir_fd)
    except OSError:
        return False
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            return False
        os.ftruncate(fd, 0)
        os.write(fd, text.encode("utf-8"))
        return True
    finally:
        os.close(fd)


def _read_at(dir_fd: int, name: str, limit: int) -> bytes:
    """Up to `limit` bytes of a regular one-name file of an open folder, or b"" (a link, a FIFO, a second name)."""
    try:
        fd = os.open(name, O_READ, dir_fd=dir_fd)
    except OSError:
        return b""
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            return b""
        return os.read(fd, limit)
    finally:
        os.close(fd)


class Confine:
    """The folders cleanup may delete in, each opened from the home folder down (see above):
    ~/m4run/out (the run folders), ~/corpus/work (a marked corpus whose protected names are all
    themselves), and ~/Library/Caches/videoscan-m4run-dd and -dd-suite. <root> must be exactly
    $HOME/m4run: the same home every path of m4_run.sh comes from, and the M4 only (Codex #322 F3)."""

    def __init__(self, root: str, home: str = ""):
        home = home or os.environ.get("HOME", "")
        if not home or not os.path.isabs(home):
            raise Refused("no home folder")
        self.home = os.path.realpath(home)
        if os.path.abspath(root) not in (os.path.join(home, "m4run"), os.path.join(self.home, "m4run")):
            raise Refused("the run root is not HOME/m4run")
        self.fds = []
        try:
            self.home_fd = os.open(self.home, O_DIR)
        except OSError:
            raise Refused("the home folder cannot be opened")
        self.fds.append(self.home_fd)
        self.dev = os.fstat(self.home_fd).st_dev
        try:
            self.root_fd = self._keep(_open_dir("m4run", self.home_fd, self.dev))
            self.out_fd = self._keep(_open_dir("out", self.root_fd, self.dev))
        except Refused:
            self.close()
            raise
        self.out = os.path.join(self.home, "m4run", "out")
        corpus = os.path.join(self.home, "corpus")
        self.protected = ["/Volumes"] + [os.path.join(corpus, name) for name in CORPUS_PROTECTED]
        # The corpus as it is, never as a name resolves (Codex #324 S1): ~/corpus that is not a folder of
        # its own, or a protected name in it that is a link, stops the WHOLE cleanup - there is then no
        # alias to compare spellings against. The protected folders are also known by (device, inode), and
        # a scan that meets one refuses its tree. Only lstat through descriptors: nothing is resolved, so a
        # stalled share mount under ~/corpus/live is never waited on (S5).
        self.protected_ids = set()
        self.work_fd = None
        corpus_info = _lstat_at(self.home_fd, "corpus")
        if corpus_info is not None:
            if not stat.S_ISDIR(corpus_info.st_mode):
                self.close()
                raise Refused("~/corpus is not a folder of its own")
            corpus_fd = self._keep(_open_dir("corpus", self.home_fd, self.dev))
            for name in CORPUS_PROTECTED:
                info = _lstat_at(corpus_fd, name)
                if info is None:
                    continue
                if stat.S_ISLNK(info.st_mode):
                    self.close()
                    raise Refused("a protected corpus name is a link")
                self.protected_ids.add((info.st_dev, info.st_ino))
            marker = _lstat_at(corpus_fd, CORPUS_MARKER)
            if marker is not None and stat.S_ISREG(marker.st_mode):
                try:
                    self.work_fd = self._keep(_open_dir("work", corpus_fd, self.dev))
                except Refused:
                    self.work_fd = None
        self.work = os.path.join(corpus, "work")
        self.caches_dir = os.path.join(self.home, "Library", "Caches")
        self.caches_fd, self.caches = None, []
        try:
            library = self._keep(_open_dir("Library", self.home_fd, self.dev))
            self.caches_fd = self._keep(_open_dir("Caches", library, self.dev))
            for suffix in ("-dd-suite", "-dd"):
                name = "videoscan-m4run" + suffix
                info = _lstat_at(self.caches_fd, name)
                if info is not None and stat.S_ISDIR(info.st_mode) and not self.guarded(os.path.join(self.caches_dir, name)):
                    self.caches.append(name)                 # a cache that holds a protected destination is not one (Codex #323 R2)
        except Refused:
            self.caches_fd, self.caches = None, []
        # The roots as the kernel names them (F_GETPATH), so a later where-is-it answer compares like with like;
        # each must still be where it was authorized: a fresh open from home finds the same folder, and the
        # kernel name is that path (Codex #325 T3: a root moved while it was being opened is refused).
        try:
            self.out_where = self._verified(self.out_fd, ("m4run", "out"))
            self.work_where = self._verified(self.work_fd, ("corpus", "work")) if self.work_fd is not None else ""
            self.caches_where = self._verified(self.caches_fd, ("Library", "Caches")) if self.caches_fd is not None else ""
        except Refused:
            self.close()
            raise

    def _verified(self, fd: int, parts) -> str:
        fresh, opened = self.home_fd, []
        try:
            for part in parts:
                fresh = _open_dir(part, fresh, self.dev)
                opened.append(fresh)
            held, again = os.fstat(fd), os.fstat(fresh)
            if (held.st_dev, held.st_ino) != (again.st_dev, again.st_ino):
                raise Refused("a root moved while it was opened")
        finally:
            for one in opened:
                os.close(one)
        where = _where(fd)
        if where.lower() != os.path.join(self.home, *parts).lower():
            raise Refused("a root is not where it was authorized")
        return where

    def open_dir(self, name: str, dir_fd: int) -> int:
        """`_open_dir`, and never a protected folder, whatever it is called now (Codex #325 T2)."""
        fd = _open_dir(name, dir_fd, self.dev)
        info = os.fstat(fd)
        if (info.st_dev, info.st_ino) in self.protected_ids:
            os.close(fd)
            raise Refused("a protected corpus folder")
        return fd

    def _keep(self, fd: int) -> int:
        self.fds.append(fd)
        return fd

    def close(self) -> None:
        for fd in self.fds:
            try:
                os.close(fd)
            except OSError:
                pass
        self.fds = []

    def guarded(self, path: str) -> bool:
        """True when a target (by the path it was reached at) overlaps a protected destination."""
        return any(path == p or path.startswith(p + "/") or p.startswith(path + "/") for p in self.protected)

    def inside(self, dir_fd: int) -> bool:
        """Where an open folder IS now (the kernel answer, F_GETPATH), not where it was opened: strictly
        inside ~/m4run/out or ~/corpus/work, or inside one of the two caches, and overlapping nothing
        protected. Asked before every unlink, rmdir, rename and write (Codex #323 R3: a folder moved
        out of the roots after it was opened is left alone). A move that lands between this answer and
        the very next call is the one race left; it needs a second process renaming folders under
        ~/m4run while this run holds the lock and no lane runs."""
        where = _where(dir_fd)
        if not where:
            return False
        roots = [self.out_where] + ([self.work_where] if self.work_where else [])
        caches = [os.path.join(self.caches_where, name) for name in self.caches] if self.caches_where else []
        # The three parents themselves are allowed: in them this code acts only on names it chose
        # (<stamp>-<lane> run and work folders, its own two caches).
        parents = roots + ([self.caches_where] if self.caches and self.caches_where else [])
        ok = (where in parents or any(where.startswith(r + "/") for r in roots)
              or any(where == c or where.startswith(c + "/") for c in caches))
        return ok and not self.guarded(where)

    def remove(self, dir_fd: int, name: str):
        """Remove the entry `name` of an open folder, the whole of it or none of it: a tree with a
        mount anywhere in it is refused before anything goes (Codex #323 R4), and so is one that could
        not be seen whole or holds a protected folder (#324 S3). Returns (reclaimed bytes, removed whole)."""
        if self.scan_at(dir_fd, name)[1]:
            return 0, False
        return self.remove_at(dir_fd, name)

    def remove_at(self, dir_fd: int, name: str):
        """Remove the entry `name` of an open folder, a whole tree when it is one. Returns
        (reclaimed bytes, removed whole). A link is unlinked as itself; a hard link loses only its
        own name (its bytes are not counted: another name keeps them, F7); a folder on another
        volume is not entered; no flag is changed (a locked file stays, and says so)."""
        if not self.inside(dir_fd):
            return 0, False
        info = _lstat_at(dir_fd, name)
        if info is None:
            return 0, True
        if not stat.S_ISDIR(info.st_mode):
            try:
                os.unlink(name, dir_fd=dir_fd)
            except OSError:
                return 0, False
            return _reclaim(info), True
        try:
            fd = self.open_dir(name, dir_fd)
        except Refused:
            return 0, False
        freed, whole = 0, True
        try:
            if os.fstat(fd).st_ino != info.st_ino:
                return 0, False                              # swapped between the look and the open
            for entry in os.listdir(fd):
                got, ok = self.remove_at(fd, entry)
                freed += got
                whole = whole and ok
        finally:
            os.close(fd)
        if whole and self.inside(dir_fd):
            try:
                os.rmdir(name, dir_fd=dir_fd)
            except OSError:
                whole = False
        else:
            whole = False
        return freed, whole

    def scan_at(self, dir_fd: int, name: str):
        """(what removing the entry would give back, BLOCKED). Blocked: a mount, a folder that could not
        be opened or listed (the scan is not whole: #324 S3), or a protected folder by (device, inode).
        Given back: regular files with one name and no lock flag, in folders with no lock flag (F7, #323
        R5); a blocked tree gives back nothing (#324 S6)."""
        try:
            info = _lstat_at(dir_fd, name)
        except Refused:
            return 0, True
        if info is None:
            return 0, False
        if (info.st_dev, info.st_ino) in self.protected_ids:
            return 0, True
        if not stat.S_ISDIR(info.st_mode):
            return _reclaim(info), False
        try:
            fd = os.open(name, O_DIR, dir_fd=dir_fd)
        except OSError:
            return 0, True
        try:
            opened = os.fstat(fd)
            if opened.st_dev != self.dev or (opened.st_dev, opened.st_ino) in self.protected_ids:
                return 0, True
            try:
                entries = os.listdir(fd)
            except OSError:
                return 0, True
            total, blocked = 0, False
            for entry in entries:
                got, stop = self.scan_at(fd, entry)
                total += got
                if stop:
                    return 0, True
            return (0 if getattr(info, "st_flags", 0) & LOCKED else total), blocked
        finally:
            os.close(fd)


def _where(fd: int) -> str:
    """Where an open folder is now, as the kernel names it (F_GETPATH), or ""."""
    try:
        return fcntl.fcntl(fd, fcntl.F_GETPATH, bytes(1024)).split(b"\0", 1)[0].decode("utf-8", "surrogateescape")
    except (OSError, AttributeError, ValueError, TypeError):
        return ""


def _reclaim(info) -> int:
    """Bytes a removed name gives back: a regular file with one name and no lock flag, else nothing."""
    if stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and not getattr(info, "st_flags", 0) & LOCKED:
        return info.st_blocks * 512
    return 0


def _shorten_at(dir_fd: int, name: str, inside=lambda fd: True) -> bool:
    """Cut a log to its last TAIL_LINES lines under its own name, in its open folder (a new file
    renamed over it, both relative to the folder descriptor). False for a link, a FIFO or a file
    with a second name: never read, its name is removed by the caller instead."""
    try:
        fd = os.open(name, O_READ, dir_fd=dir_fd)
    except OSError:
        return False
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            return False
        lines = 0
        while True:                                          # count lines without holding the file in memory
            chunk = os.read(fd, 1 << 20)
            if not chunk:
                break
            lines += chunk.count(b"\n")
        if lines <= TAIL_LINES:
            return True                                      # short already: kept as it is
        os.lseek(fd, max(0, info.st_size - TAIL_BYTES), os.SEEK_SET)
        tail = os.read(fd, TAIL_BYTES).decode("utf-8", errors="replace").splitlines()[-TAIL_LINES:]
    finally:
        os.close(fd)
    temporary = name + ".tidy-new"
    if not inside(dir_fd):
        return False
    try:
        os.unlink(temporary, dir_fd=dir_fd)                  # a leftover of a stopped cleanup
    except OSError:
        pass
    text = "[tidied: the last %d of %d lines are kept]\n%s\n" % (TAIL_LINES, lines, "\n".join(tail))
    if not inside(dir_fd) or not _write_at(dir_fd, temporary, text, create=True) or not inside(dir_fd):
        return False
    try:
        os.rename(temporary, name, src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
    except OSError:
        return False
    return True


def _finished_at(out_fd: int, name: str, dev: int) -> bool:
    """True when the run folder has a run.log with an OUTCOME line (read through descriptors only)."""
    try:
        fd = _open_dir(name, out_fd, dev)
    except Refused:
        return False
    try:
        text = _read_at(fd, "run.log", 4 << 20)
    finally:
        os.close(fd)
    return any(line.startswith(b"OUTCOME ") for line in text.splitlines())


def _run_folders(conf: Confine):
    """(mtime, name, finished) of every run folder of ~/m4run/out, oldest first: <stamp>-<lane>, a real folder."""
    found = []
    for name in os.listdir(conf.out_fd):
        info = _lstat_at(conf.out_fd, name)
        if RUN_NAME.match(name) and info is not None and stat.S_ISDIR(info.st_mode):
            found.append((info.st_mtime, name, _finished_at(conf.out_fd, name, conf.dev), (info.st_dev, info.st_ino)))
    found.sort()
    return found


def tidy(conf: Confine, run_name: str):
    """A summarized run gives up its scratch: everything but KEEP_FILES, *.tests.tsv and its logs,
    each log cut to its tail; links are left as they are. Returns (bytes reclaimed, items removed,
    items left), or None when it is not a run folder or was tidied already (tidy.txt)."""
    if not RUN_NAME.match(run_name) or conf.guarded(os.path.join(conf.out, run_name)):
        return None
    try:
        run_fd = conf.open_dir(run_name, conf.out_fd)
    except Refused:
        return None
    freed = removed = refused = shortened = 0
    opened = [run_fd]
    try:
        if _lstat_at(run_fd, "tidy.txt") is not None or not conf.inside(run_fd):
            return None
        folders = [run_fd]
        while folders:
            folder = folders.pop(0)
            for name in sorted(os.listdir(folder)):
                if not conf.inside(folder):
                    refused += 1                             # the folder moved out of the roots: nothing more in it
                    break
                info = _lstat_at(folder, name)
                if info is None:
                    continue
                if folder == run_fd and CORPUS_OUT.match(name) and stat.S_ISDIR(info.st_mode):
                    try:
                        sub = conf.open_dir(name, run_fd)        # a testbed run: each corpus lane has its own folder
                    except Refused:
                        refused += 1
                        continue
                    opened.append(sub)
                    folders.append(sub)
                    continue
                if name in KEEP_FILES or name.endswith(KEEP_SUFFIXES):
                    continue
                if stat.S_ISLNK(info.st_mode):
                    refused += 1                             # a link is left as it is: never followed, never ours
                    continue
                if name.endswith(".log") and _shorten_at(folder, name, conf.inside):
                    shortened += 1
                    continue
                got, whole = conf.remove(folder, name)
                freed += got
                if whole:
                    removed += 1
                else:
                    refused += 1
        if conf.inside(run_fd):
            _write_at(run_fd, "tidy.txt",
                      "tidied %s: removed %d items (%.2f GB), %d logs cut to their last %d lines, %d left (a link, a mount or a locked file)\n"
                      % (time.strftime("%Y-%m-%d %H:%M:%S"), removed, freed / 1e9, shortened, TAIL_LINES, refused), create=True)
        return freed, removed, refused
    finally:
        for fd in opened:
            os.close(fd)


def disk_space(path: str):
    """(free bytes, total bytes) of the volume holding `path`: what df calls Available and Size.
    Test hook: VIDEOSCAN_TESTBED_FAKE_DISK=<total>:<other> makes free = total - other - the bytes
    under the folder above <root> (a fake HOME; each file once), so deleting there frees space."""
    fake = re.fullmatch(r"(\d+):(\d+)", os.environ.get("VIDEOSCAN_TESTBED_FAKE_DISK", ""))
    if fake:
        home = os.path.dirname(os.path.abspath(path))
        seen, used = set(), int(fake.group(2))
        for folder, dirs, names in os.walk(home):
            for name in dirs + names:
                try:
                    info = os.lstat(os.path.join(folder, name))
                except OSError:
                    continue
                if (info.st_dev, info.st_ino) not in seen:
                    seen.add((info.st_dev, info.st_ino))
                    used += info.st_blocks * 512
        return max(int(fake.group(1)) - used, 0), int(fake.group(1))
    st = os.statvfs(path)
    return st.f_bavail * st.f_frsize, st.f_blocks * st.f_frsize


def _holds_lock(root: str, current: str) -> bool:
    """True when the testbed lock is held (the kernel says so) and its holder named `current` as its run folder."""
    busy, holder = lock_state(root)
    return bool(busy and holder and current and holder.endswith("out=" + current))


def _pct(free: int, total: int) -> str:
    return "%d%%" % round(100.0 * free / total) if total else "?%"


def _pair_at(dir_fd: int, name: str):
    """Two numbers from a file of this cleanup (disk-start.txt, disk-low.txt), or None."""
    parts = _read_at(dir_fd, name, 200).decode("ascii", errors="replace").split()
    return (int(parts[0]), int(parts[1])) if len(parts) == 2 and parts[0].isdigit() and parts[1].isdigit() else None


def _current_fd(conf: Confine, current: str) -> int:
    """The run folder of the run holding the lock, opened as itself (never a link, F5)."""
    current = os.path.abspath(current)
    name = os.path.basename(current)
    if (not RUN_NAME.match(name)
            or os.path.dirname(current) not in (conf.out, os.path.join(os.environ.get("HOME", ""), "m4run", "out"))):
        raise Refused("the current run is not a run folder of this root")
    if conf.guarded(os.path.join(conf.out, name)):
        raise Refused("the current run overlaps a protected corpus folder")   # Codex #323 R2
    fd = conf.open_dir(name, conf.out_fd)
    if not conf.inside(fd):
        os.close(fd)
        raise Refused("the current run is not inside the run root")
    return fd


def clean(root: str, current: str, phase: str, disk=disk_space) -> str:
    """Under the lock, at a run start (phase "start") or once it is summarized ("end"). In order:
      1. end only: this run is tidied;
      2. every OTHER finished run (its run.log has an OUTCOME) not yet tidied is tidied;
      3. every ~/corpus/work/<stamp>-<lane> folder goes (no corpus lane runs outside the lock);
      4. below the floor (FLOOR of the volume free): unfinished runs other than this one, oldest
         first, are tidied until the floor is met;
      5. still below it: the two build caches go, but only when what they would give back reaches
         the floor (a cold build costs 10-25 minutes; dropping them for nothing is all cost).
    Returns the one disk line. Refused (exception) unless the lock is held by `current`."""
    if phase not in ("start", "end"):
        raise Refused("phase is start or end")
    conf = Confine(root)
    try:
        cur_fd = _current_fd(conf, current)
    except Refused:
        conf.close()
        raise
    conf.fds.append(cur_fd)
    try:
        if not _holds_lock(root, os.path.abspath(current)):
            raise Refused("the testbed lock is not held by this run")
        return _clean(conf, cur_fd, os.path.basename(os.path.abspath(current)), phase, disk)
    finally:
        conf.close()


def _clean(conf: Confine, cur_fd: int, mine: str, phase: str, disk) -> str:
    root = os.path.join(conf.home, "m4run")
    free, total = disk(root)
    lowest = free                                            # at the end: before this run gives anything back
    parts, refused, removed = [], 0, 0
    if phase == "end":
        done = tidy(conf, mine)
        if done:
            parts.append("this run %.2f GB" % (done[0] / 1e9))
            removed += done[0]
            refused += done[2]
    old_bytes = old_runs = 0
    unfinished = []
    held = os.fstat(cur_fd)
    for _, name, finished, identity in _run_folders(conf):
        if name == mine or identity == (held.st_dev, held.st_ino):
            continue                                         # the run holding the lock, by identity too (#325 T4: a case-only rename)
        if not finished:
            unfinished.append(name)
            continue
        done = tidy(conf, name)
        if done:
            old_bytes += done[0]
            old_runs += 1
            refused += done[2]
    work_bytes = work_folders = 0
    if conf.work_fd is not None:
        for name in sorted(os.listdir(conf.work_fd)):
            info = _lstat_at(conf.work_fd, name)
            if (not RUN_WORK.match(name) or info is None or not stat.S_ISDIR(info.st_mode)
                    or conf.guarded(os.path.join(conf.work, name))):
                continue
            got, whole = conf.remove(conf.work_fd, name)
            work_bytes += got
            if whole:
                work_folders += 1
            else:
                refused += 1
    free, total = disk(root)
    target = int(total * FLOOR)
    for name in unfinished:                                  # oldest first
        if free >= target:
            break
        done = tidy(conf, name)
        if done:
            old_bytes += done[0]
            old_runs += 1
            refused += done[2]
        free, total = disk(root)
    if old_runs:
        parts.append("older runs %.2f GB (%d)" % (old_bytes / 1e9, old_runs))
    if work_folders:
        parts.append("corpus work %.2f GB (%d)" % (work_bytes / 1e9, work_folders))
    removed += old_bytes + work_bytes
    caches_note = ""
    if free < target and conf.caches:
        sizes = [0 if blocked else size for size, blocked in (conf.scan_at(conf.caches_fd, name) for name in conf.caches)]
        if free + sum(sizes) >= target:
            cache_bytes = 0
            for name in conf.caches:
                got, whole = conf.remove(conf.caches_fd, name)
                cache_bytes += got
                if not whole:
                    refused += 1
                free, total = disk(root)
                if free >= target:
                    break
            parts.append("build caches %.2f GB" % (cache_bytes / 1e9))
            removed += cache_bytes
        else:
            caches_note = "; build caches kept (%.1f GB would not reach the floor)" % (sum(sizes) / 1e9)
    under = "" if free >= target else ", UNDER by %.1f GB" % ((target - free) / 1e9)
    if phase == "start":
        if conf.inside(cur_fd):
            _write_at(cur_fd, "disk-start.txt", "%d %d\n" % (free, total))
        head = "disk: free %s at the start (floor %d%%%s)" % (_pct(free, total), FLOOR * 100, under)
    else:
        start = _pair_at(cur_fd, "disk-start.txt")
        low = _pair_at(cur_fd, "disk-low.txt")
        lowest = min([lowest] + [pair[0] for pair in (start, low) if pair])
        head = "disk: free %s after cleanup (lowest %s during the run, %s at the start; floor %d%%%s)" % (
            _pct(free, total), _pct(lowest, total), _pct(start[0], start[1]) if start else "?%", FLOOR * 100, under)
    tail = (" — removed %.2f GB: %s" % (removed / 1e9, ", ".join(parts))) if parts else " — nothing to remove"
    if refused:
        tail += "; could not be removed %d (a link, a mount or a locked file)" % refused
    return head + tail + caches_note


def _replace_at(conf: Confine, dir_fd: int, name: str, data: bytes) -> bool:
    """Replace a file of the run folder whole: a new file renamed over the name, both through the
    folder descriptor, only while the folder is inside the run root."""
    temporary = name + ".disk-new"
    if not conf.inside(dir_fd):                              # before each act (Codex #324 S2)
        return False
    try:
        os.unlink(temporary, dir_fd=dir_fd)
    except OSError:
        pass
    if not conf.inside(dir_fd) or not _write_at(dir_fd, temporary, data.decode("utf-8", "replace"), create=True):
        return False
    if not conf.inside(dir_fd):
        return False
    try:
        os.rename(temporary, name, src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
    except OSError:
        return False
    return True


def _plain_or_absent(dir_fd: int, name: str) -> bool:
    info = _lstat_at(dir_fd, name)
    return info is None or (stat.S_ISREG(info.st_mode) and info.st_nlink == 1)


def record(root: str, current: str, line: str) -> bool:
    """Put the disk line into the summary of the run holding the lock, through its folder descriptor
    (Codex #323 R1: never a planted link, a FIFO or a second name). A testbed run: the line closes its
    block (what status shows) and the summary is the block again, then the lanes own lines."""
    conf = Confine(root)
    try:
        cur_fd = _current_fd(conf, current)
    except Refused:
        conf.close()
        return False
    conf.fds.append(cur_fd)
    try:
        if not _holds_lock(root, os.path.abspath(current)):
            return False                                     # only the run holding the lock writes its summary (#324 S4)
        if not _plain_or_absent(cur_fd, "summary.txt") or not _plain_or_absent(cur_fd, "testbed-block.txt"):
            return False
        summary = _read_at(cur_fd, "summary.txt", MAX_SHOW * 16)
        add = (line + "\n").encode("utf-8")
        if _lstat_at(cur_fd, "testbed-block.txt") is None:
            return _replace_at(conf, cur_fd, "summary.txt", summary + add)
        block = _read_at(cur_fd, "testbed-block.txt", MAX_SHOW) + add
        marker = "\u2014 the lanes".encode("utf-8")
        lines = summary.splitlines(keepends=True)
        at = next((i for i, text in enumerate(lines) if text.startswith(marker)), None)
        rest = b"".join(lines[at:]) if at is not None else summary
        return _replace_at(conf, cur_fd, "testbed-block.txt", block) and _replace_at(conf, cur_fd, "summary.txt", block + rest)
    finally:
        conf.close()


def stop_marker(root: str, out: str) -> None:
    """Tell the sampler to stop: a new empty marker in the run folder, through its descriptor. Anything
    already at that name (a planted link, a FIFO) is left as it is; the sampler stops on its presence."""
    conf = Confine(root)
    try:
        cur_fd = _current_fd(conf, out)
        conf.fds.append(cur_fd)
        _write_at(cur_fd, "disk-sample.stop", "", create=True)
    finally:
        conf.close()


def sample(root: str, out: str, disk=disk_space, interval: float = SAMPLE_SECONDS) -> None:
    """While a run works: the lowest free figure seen, kept in <out>/disk-low.txt as "<free> <total>"
    (written through the run folder descriptor, never a link or a FIFO). Stops when
    <out>/disk-sample.stop appears or the shell that started it is gone, after one last look.
    It never holds the testbed lock (m4_run.sh starts it with fd 9 closed)."""
    conf = Confine(root)
    try:
        cur_fd = _current_fd(conf, out)
    except Refused:
        conf.close()
        raise
    conf.fds.append(cur_fd)
    try:
        parent, low = os.getppid(), None
        def stopped() -> bool:
            try:
                return _lstat_at(cur_fd, "disk-sample.stop") is not None or os.getppid() != parent
            except Refused:
                return True
        while True:
            free, total = disk(os.path.join(conf.home, "m4run"))
            if low is None or free < low:
                low = free
                if conf.inside(cur_fd):
                    _write_at(cur_fd, "disk-low.txt", "%d %d\n" % (low, total))
            if stopped():
                return
            waited = 0.0
            while waited < interval and not stopped():
                time.sleep(min(1.0, interval))
                waited += min(1.0, interval)
    finally:
        conf.close()


# ── status for machines ───────────────────────────────────────────────────

START = re.compile(r"^START (\S+ \S+) host=(.+?) lane=(\S+)(?: corpus-lane=(\S+))? sha=([0-9a-f]+)")
OUTCOME = re.compile(r"^OUTCOME (\S+) (\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)? ?(?:lane=(\S+) sha=([0-9a-f]+))?(?: — (.*))?")


def _lines(path: str, limit: int = 4000) -> list:
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return [line.rstrip("\n") for _, line in zip(range(limit), f)]
    except OSError:
        return []


def run_facts(root: str, pointer: str, holder):
    """One run, as `status` reads it, or None when the pointer names nothing. `holder` is the
    words of whoever holds the lock (None: nobody): a run with no OUTCOME is running when the
    holder names its folder, and ended without one otherwise."""
    path = os.path.join(root, pointer)
    if not os.path.islink(path):
        return None
    target = os.readlink(path)
    log = _lines(os.path.join(path, "run.log"))
    if not log:
        return None
    facts = {"dir": target, "lane": None, "corpus_lane": None, "sha": None, "started": None, "verdict": None,
             "ended": None, "why": None, "ended_without_outcome": False, "summary": [], "lanes": []}
    m = RUN_NAME.match(os.path.basename(target))
    if m:
        facts["lane"] = m.group(2)
    for line in log:
        started, ended = START.match(line), OUTCOME.match(line)
        if started:
            facts.update(started=started.group(1), lane=started.group(3), corpus_lane=started.group(4), sha=started.group(5))
        elif ended and line.startswith("OUTCOME "):
            facts.update(verdict=ended.group(1), ended=ended.group(2), why=ended.group(5))
            if line.startswith("OUTCOME REFUSED"):
                facts["why"] = line[len("OUTCOME REFUSED "):]
    facts["summary"] = _lines(os.path.join(path, "summary.txt"), SUMMARY_LINES)
    for line in _lines(os.path.join(path, "lanes.tsv"), 20):
        parts = line.split("\t")
        if len(parts) == 4:
            facts["lanes"].append({"name": parts[0], "verdict": parts[1],
                                   "seconds": int(parts[2]) if parts[2].isdigit() else None})
    live = holder is not None and ("out=" + target) in holder
    facts["ended_without_outcome"] = facts["verdict"] is None and not live
    facts["running"] = facts["verdict"] is None and live
    return facts


def lock_state(root: str):
    """(busy, the holder words) from a fresh open of the testbed lock: the kernel truth."""
    lockdir = os.path.join(root, "lock")
    try:
        os.makedirs(lockdir, exist_ok=True)
        fd = os.open(os.path.join(lockdir, "flock"), os.O_RDWR | os.O_CREAT, 0o644)
    except OSError:
        return False, None
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            words = " ".join(_lines(os.path.join(lockdir, "info"), 1)).strip().split(" ", 1)
            return True, words[-1] if words and words[-1] else "(no info written yet)"
        fcntl.flock(fd, fcntl.LOCK_UN)
        return False, None
    finally:
        os.close(fd)


def status_json(root: str, name: str) -> str:
    busy, holder = lock_state(root)
    watch = _lines(os.path.join(root, "watch", "verdict.txt"), 1)
    value = {"host": name, "state": "running" if busy else "idle", "lock": holder,
             "last": run_facts(root, "latest", holder), "suite": run_facts(root, "latest-suite", holder),
             "testbed": run_facts(root, "latest-testbed", holder), "watch": watch[0] if watch else None,
             "at": time.strftime("%Y-%m-%d %H:%M:%S")}
    return json.dumps(value, indent=1, sort_keys=True)


# ── the quiet window before a scheduled run ───────────────────────────────

def _minutes(hhmm: str):
    m = re.fullmatch(r"(\d\d):?(\d\d)", hhmm.strip())
    if not m or int(m.group(1)) > 23 or int(m.group(2)) > 59:
        return None
    return int(m.group(1)) * 60 + int(m.group(2))


def window(root: str, lane: str, hhmm: str) -> str:
    values = conf(root)
    now = _minutes(hhmm)
    if now is None:
        return "OK"                                         # no clock, no window: the lock still decides
    scheduled = values.get("SCHEDULED")
    times = scheduled.split(",") if scheduled is not None else SCHEDULED_DEFAULT.get(os.path.basename(root.rstrip("/")), [])
    quiet = _number(values.get("QUIET_MINUTES"), QUIET_DEFAULT.get(lane, 60), 0, 720)
    for text in times:
        at = _minutes(text)
        if at is None:
            continue
        ahead = (at - now) % 1440                           # minutes until the next such run
        if 0 < ahead <= quiet:
            return ("QUIET the scheduled %02d:%02d run starts in %d min and a %s lane wants %d clear"
                    % (at // 60, at % 60, ahead, lane, quiet))
    return "OK"


NIGHTLY_START = "0130"            # the 01:30-06:00 window m4_run.sh refuses (its own check, by the clock)


def minutes_left(root: str, lane: str, hhmm: str):
    """Minutes from <HHMM> until the next moment the lane may no longer start, or None."""
    now = _minutes(hhmm)
    if now is None:
        return None
    values = conf(root)
    scheduled = values.get("SCHEDULED")
    times = scheduled.split(",") if scheduled is not None else SCHEDULED_DEFAULT.get(os.path.basename(root.rstrip("/")), [])
    quiet = _number(values.get("QUIET_MINUTES"), QUIET_DEFAULT.get(lane, 60), 0, 720)
    starts = [_minutes(NIGHTLY_START)]
    if quiet > 0:
        starts += [(at - quiet) % 1440 for at in (_minutes(t) for t in times) if at is not None]
    return min((start - now) % 1440 for start in starts)


def start_by(root: str, lane: str, hhmm: str, epoch: str) -> str:
    left = minutes_left(root, lane, hhmm)
    if left is None or not epoch.isdigit():
        return ""
    whole = int(epoch) - int(epoch) % 60                # the start of the current minute
    return str(whole + left * 60)


MAX_SHOW = 256 * 1024
_WITHHELD = re.compile(
    r"\.(mov|mp4|m4v|mxf|dv|avi|mkv|mts|m2ts|mpg|mpeg|vob|wav|aif|aiff|m4a|mp3|3gp|webm|jpg|jpeg|png|heic)\b"
    r"|[0-9a-fA-F]{41,}|(?<!sha=)(?<![0-9a-fA-F])[0-9a-fA-F]{24,40}(?![0-9a-fA-F])"
    r"|/Volumes/|corpus/media/|corpus/live/|/Users/[^/ ]+/(?!m4run/)|[\x00-\x08\x0b-\x1f\x7f]",
    re.IGNORECASE)


def show(path: str, under: str = "", match: str = "", tail: int = 0) -> list:
    """The lines of a file a caller may read back (see the module text), or one line saying why not."""
    try:
        if os.path.islink(path) or (under and os.path.realpath(os.path.dirname(os.path.abspath(path))) != os.path.realpath(under)):
            return ["(withheld: not a file of this run)"]
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError:
        return []
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            return ["(withheld: not a plain file of this run)"]
        data = os.read(fd, MAX_SHOW + 1)
    finally:
        os.close(fd)
    lines = data[:MAX_SHOW].decode("utf-8", errors="replace").splitlines()
    if match:
        lines = [line for line in lines if re.search(match, line)]
    if tail:
        lines = lines[-tail:]
    return [("(a line was withheld: it did not read as counts and words)" if _WITHHELD.search(line) else line) for line in lines]


RAN = ("GREEN", "AMBER", "RED")


def ran(root: str, sha: str, ignore: str = "") -> str:
    """The verdict of a suite or testbed run of `sha` under <root>/out that reached GREEN, AMBER
    or RED (the newest such), or "". What the push watcher asks UNDER the testbed lock, before
    it starts a run (Codex #315-5). Run logs are read without following a link."""
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        return ""
    out = os.path.join(root, "out")
    try:
        names = sorted(os.listdir(out), reverse=True)
    except OSError:
        return ""
    skip = os.path.realpath(ignore) if ignore else ""
    for name in names:
        m = RUN_NAME.match(name)
        path = os.path.join(out, name)
        if not m or m.group(2) not in ("suite", "testbed") or os.path.islink(path) or os.path.realpath(path) == skip:
            continue
        verdict, started = "", False
        for line in show(os.path.join(path, "run.log")):
            if line.startswith("START ") and (" sha=" + sha) in line:
                started = True
            elif line.startswith("OUTCOME ") and len(line.split()) > 1:
                verdict = line.split()[1]
        if started and verdict in RAN:
            return verdict
    return ""


def main(argv: list) -> int:
    if len(argv) >= 2 and argv[0] == "prune":
        current, keep, rest = "", 0, argv[2:]
        while rest:
            if rest[0] == "--current" and len(rest) > 1:
                current, rest = rest[1], rest[2:]
            elif rest[0] == "--keep" and len(rest) > 1 and rest[1].isdigit():
                keep, rest = int(rest[1]), rest[2:]
            else:
                return 2
        print(prune(argv[1], current, keep))
        return 0
    if len(argv) == 6 and argv[0] == "clean" and argv[2] == "--current" and argv[4] == "--phase" and argv[5] in ("start", "end"):
        # One line on stdout, always: m4_run.sh puts it in the summary. A cleanup that is refused or
        # fails says so and never stops the run (its verdict is already decided).
        def stop(signum, frame):
            raise OverBudget()
        signal.signal(signal.SIGALRM, stop)
        signal.alarm(CLEAN_BUDGET)                          # a stuck syscall is interrupted, the line still comes (F6)
        late = False
        try:
            line, rc = clean(argv[1], argv[3], argv[5]), 0
        except OverBudget:
            line, rc, late = "disk: cleanup stopped at its %d s budget" % CLEAN_BUDGET, 1, True
        except Refused as error:
            line, rc = "disk: cleanup refused (%s)" % error, 2
        except Exception as error:                         # noqa: BLE001 — the run must reach its OUTCOME
            line, rc = "disk: cleanup failed (%s)" % type(error).__name__, 1
        if argv[5] == "end":
            recorded = False
            if not late:                                    # past the deadline nothing more touches the disk (#324 S5)
                try:
                    recorded = record(argv[1], argv[3], line)   # still under the same alarm
                except BaseException:                       # noqa: BLE001 — OverBudget included; said on stderr instead
                    recorded = False
            if not recorded:
                print(line + " (not written into the summary)", file=sys.stderr)
        signal.alarm(0)
        print(line)
        return rc
    if len(argv) == 3 and argv[0] == "stop":
        def late(signum, frame):
            raise OverBudget()
        signal.signal(signal.SIGALRM, late)
        signal.alarm(STOP_BUDGET)
        try:
            stop_marker(argv[1], argv[2])
            return 0
        except Refused as error:
            print("stop refused: %s" % error, file=sys.stderr)
            return 2
        except OverBudget:
            print("stop: past its %d s budget" % STOP_BUDGET, file=sys.stderr)
            return 1
        finally:
            signal.alarm(0)
    if len(argv) == 3 and argv[0] == "sample":
        try:
            sample(argv[1], argv[2])
            return 0
        except Refused as error:
            print("sample refused: %s" % error, file=sys.stderr)
            return 2
    if len(argv) == 3 and argv[0] == "status-json":
        print(status_json(argv[1], argv[2]))
        return 0
    if len(argv) == 4 and argv[0] == "window":
        print(window(argv[1], argv[2], argv[3]))
        return 0
    if len(argv) in (3, 4) and argv[0] == "ran":
        print(ran(argv[1], argv[2], argv[3] if len(argv) == 4 else ""))
        return 0
    if len(argv) == 5 and argv[0] == "start-by":
        print(start_by(argv[1], argv[2], argv[3], argv[4]))
        return 0
    if len(argv) >= 2 and argv[0] == "show":
        under, match, tail, rest = "", "", 0, argv[2:]
        while rest:
            if rest[0] == "--under" and len(rest) > 1:
                under, rest = rest[1], rest[2:]
            elif rest[0] == "--match" and len(rest) > 1:
                match, rest = rest[1], rest[2:]
            elif rest[0] == "--tail" and len(rest) > 1 and rest[1].isdigit():
                tail, rest = int(rest[1]), rest[2:]
            else:
                return 2
        for line in show(argv[1], under, match, tail):
            print(line)
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
