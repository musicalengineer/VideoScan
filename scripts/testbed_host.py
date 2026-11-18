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
RUN_WORK = re.compile(r"^[0-9A-Za-z_]+-(" + "|".join(CORPUS_LANES) + r")$")       # ~/corpus/work/<stamp>-<lane>
CORPUS_OUT = re.compile(r"^corpus-(" + "|".join(CORPUS_LANES) + r")$")             # <run>/corpus-<lane> in a testbed run
KEEP_FILES = frozenset({"run.log", "summary.txt", "testbed-block.txt", "lanes.tsv", "suite-row.json", "corpus-summary.txt",
                        "corpus-verdict.json", "disk-start.txt", "disk-low.txt", "tidy.txt"})
KEEP_SUFFIXES = (".tests.tsv",)
CORPUS_MARKER = "THIS_IS_TEST_DATA.txt"
# Never a target, whatever a path resolved through: the corpus sources, its documents, its stored
# reports and accepted baselines, its sealed state, the read-only share mount.
CORPUS_PROTECTED = ("media", "live", "state", "reports", "corpus-sha-v1.txt", "corpus-manifest-v1.json",
                    "catalog-source-backup.sqlite", CORPUS_MARKER, "share.credentials", "_experiment", ".trash")
UF_IMMUTABLE = 0x2


class Refused(Exception):
    """The cleanup said no. The message carries no path below the home folder."""


def _measure(path: str, dev: int):
    """(bytes on disk under `path`, whether a folder in it is on another device: a mount). Links
    are counted as themselves and never followed."""
    total, foreign = 0, False
    try:
        top = os.lstat(path)
    except OSError:
        return 0, False
    if not stat.S_ISDIR(top.st_mode):
        return top.st_blocks * 512, top.st_dev != dev
    for folder, dirs, names in os.walk(path):
        try:
            if os.lstat(folder).st_dev != dev:
                foreign = True
        except OSError:
            continue
        for name in names + dirs:
            try:
                info = os.lstat(os.path.join(folder, name))
            except OSError:
                continue
            if not stat.S_ISDIR(info.st_mode):
                total += info.st_blocks * 512
    return total, foreign


def _unlock(path: str) -> None:
    """Clear the user immutable flag (what Promote sets) on files with ONE name only: a second name
    would share the inode with a file outside the root, and clearing it here clears it there."""
    if os.path.isdir(path) and not os.path.islink(path):
        targets = (os.path.join(folder, name) for folder, _, names in os.walk(path) for name in names)
    else:
        targets = iter([path])
    for target in targets:
        try:
            info = os.lstat(target)
            if stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_flags & UF_IMMUTABLE:
                os.lchflags(target, info.st_flags & ~UF_IMMUTABLE)
        except (OSError, AttributeError):
            continue


def _joined(path: str) -> str:
    """Where `path` really is, without following `path` itself: its folder resolved, its own name."""
    path = os.path.abspath(path)
    return os.path.join(os.path.realpath(os.path.dirname(path)), os.path.basename(path))


class Confine:
    """The roots cleanup may delete under, each proven to be itself (no link in its way), by real path:
    <root> (~/m4run), ~/corpus/work (the M4 only, a marked corpus), and the two build caches of this
    root (~/Library/Caches/videoscan-<root name>-dd and -dd-suite). Nothing else, ever."""

    def __init__(self, root: str):
        root = os.path.abspath(root)
        if os.path.islink(root) or not os.path.isdir(root):
            raise Refused("the run root is a symlink or not a folder")
        self.home = os.path.realpath(os.path.dirname(root))
        self.name = os.path.basename(root)
        self.root = os.path.join(self.home, self.name)
        if os.path.realpath(root) != self.root:
            raise Refused("the run root resolves somewhere else")
        out = os.path.join(self.root, "out")
        if os.path.islink(out) or (os.path.lexists(out) and os.path.realpath(out) != out):
            raise Refused("the out folder is a symlink or resolves somewhere else")
        self.out = out
        corpus = os.path.join(self.home, "corpus")
        self.protected = [os.path.join(corpus, name) for name in CORPUS_PROTECTED] + ["/Volumes"]
        self.work = ""
        work = os.path.join(corpus, "work")
        if (self.name == "m4run" and not os.path.islink(corpus) and os.path.realpath(corpus) == corpus
                and os.path.isfile(os.path.join(corpus, CORPUS_MARKER)) and not os.path.islink(work)
                and os.path.isdir(work) and os.path.realpath(work) == work):
            self.work = work
        self.caches = []
        caches = os.path.join(self.home, "Library", "Caches")
        for suffix in ("-dd-suite", "-dd"):
            cache = os.path.join(caches, "videoscan-" + self.name + suffix)
            if os.path.isdir(cache) and not os.path.islink(cache) and os.path.realpath(cache) == cache:
                self.caches.append(cache)

    def allows(self, path: str) -> bool:
        """True when `path` may be deleted: not a link itself, and its real place is strictly inside
        <root> or ~/corpus/work, or is (or is inside) one of the caches, and nowhere protected."""
        try:
            if stat.S_ISLNK(os.lstat(path).st_mode):
                return False
        except OSError:
            return False
        real = _joined(path)
        if any(real == p or real.startswith(p + "/") for p in self.protected):
            return False
        inside = [self.root] + ([self.work] if self.work else [])
        if any(real.startswith(r + "/") for r in inside):
            return True
        return any(real == c or real.startswith(c + "/") for c in self.caches)

    def remove(self, path: str):
        """Delete `path` (a file or a whole tree) when `allows` says so; the bytes it held, or None
        when refused or not gone. Inside a tree a link is removed as itself (rmtree never follows
        one); a hard link loses only its own name; a tree with a mount in it is refused."""
        if not self.allows(path):
            return None
        info = os.lstat(path)
        size, foreign = _measure(path, info.st_dev)
        if foreign:
            return None
        _unlock(path)
        if stat.S_ISDIR(info.st_mode):
            if not shutil.rmtree.avoids_symlink_attacks:        # Python on a platform without the fd-based walk
                return None
            shutil.rmtree(path, ignore_errors=True)
        else:
            try:
                os.unlink(path)
            except OSError:
                pass
        return None if os.path.lexists(path) else size


def _plain(path: str):
    """An fd on `path` read-only when it is a regular file with ONE name (never through a link), else None."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError:
        return None
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        os.close(fd)
        return None
    return fd


def _write_own(path: str, text: str, create: bool = False) -> bool:
    """Write a file of this cleanup: never through a link, never a file with a second name."""
    flags = os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW | (os.O_EXCL if create else 0)
    try:
        fd = os.open(path, flags, 0o644)
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


def _shorten(path: str) -> bool:
    """Cut a log to its last TAIL_LINES lines, under its own name (a new file renamed over it). A log
    that is a link or has a second name is never read: its name is removed by the caller instead."""
    fd = _plain(path)
    if fd is None:
        return False
    try:
        size = os.fstat(fd).st_size
        lines = 0
        while True:                                          # count lines without holding the file in memory
            chunk = os.read(fd, 1 << 20)
            if not chunk:
                break
            lines += chunk.count(b"\n")
        if lines <= TAIL_LINES:
            return True                                      # short already: kept as it is
        os.lseek(fd, max(0, size - TAIL_BYTES), os.SEEK_SET)
        tail = os.read(fd, TAIL_BYTES).decode("utf-8", errors="replace").splitlines()[-TAIL_LINES:]
    finally:
        os.close(fd)
    temporary = path + ".tidy-new"
    text = "[tidied: the last %d of %d lines are kept]\n%s\n" % (TAIL_LINES, lines, "\n".join(tail))
    if not _write_own(temporary, text, create=True):
        return False
    os.replace(temporary, path)                              # replaces the name; a link at `path` was refused above
    return True


def _run_folders(conf: Confine):
    """(mtime, path, finished) of every run folder under <root>/out: named <stamp>-<lane>, a real folder."""
    found = []
    try:
        names = os.listdir(conf.out)
    except OSError:
        return found
    for name in names:
        path = os.path.join(conf.out, name)
        if not RUN_NAME.match(name) or os.path.islink(path) or not os.path.isdir(path):
            continue
        try:
            found.append((os.lstat(path).st_mtime, path, _outcome(path) != ""))
        except OSError:
            continue
    found.sort()
    return found


def tidy(conf: Confine, run: str):
    """A summarized run gives up its scratch: everything but KEEP_FILES, *.tests.tsv and its logs,
    each log cut to its tail. Returns (bytes freed, items removed, items refused), or None when the
    folder is not a run folder of this root or was tidied already (tidy.txt)."""
    run = os.path.abspath(run)
    if (not RUN_NAME.match(os.path.basename(run)) or os.path.islink(run) or not os.path.isdir(run)
            or _joined(run) != os.path.join(conf.out, os.path.basename(run))
            or os.path.lexists(os.path.join(run, "tidy.txt"))):
        return None
    freed = removed = refused = shortened = 0
    folders = [run]
    while folders:
        folder = folders.pop(0)
        for name in sorted(os.listdir(folder)):
            path = os.path.join(folder, name)
            if folder == run and CORPUS_OUT.match(name) and not os.path.islink(path) and os.path.isdir(path):
                folders.append(path)                         # a testbed run: each corpus lane has its own folder
                continue
            if name in KEEP_FILES or name.endswith(KEEP_SUFFIXES):
                continue
            if name.endswith(".log") and _shorten(path):
                shortened += 1
                continue
            if os.path.islink(path):
                refused += 1                                 # a link is left as it is: never followed, never ours
                continue
            gone = conf.remove(path)
            if gone is None:
                refused += 1
            else:
                freed += gone
                removed += 1
    _write_own(os.path.join(run, "tidy.txt"),
               "tidied %s: removed %d items (%.2f GB), %d logs cut to their last %d lines, %d left (a link, a mount or a lock)\n"
               % (time.strftime("%Y-%m-%d %H:%M:%S"), removed, freed / 1e9, shortened, TAIL_LINES, refused), create=True)
    return freed, removed, refused


def disk_space(path: str):
    """(free bytes, total bytes) of the volume holding `path`: what df calls Available and Size.
    Test hook: VIDEOSCAN_TESTBED_FAKE_DISK=<total>:<other> makes free = total - other - the bytes
    under the folder above <root> (a fake HOME), so deleting there frees space as on a disk."""
    fake = re.fullmatch(r"(\d+):(\d+)", os.environ.get("VIDEOSCAN_TESTBED_FAKE_DISK", ""))
    if fake:
        home = os.path.dirname(os.path.abspath(path))
        total = int(fake.group(1))
        used = int(fake.group(2)) + _measure(home, os.lstat(home).st_dev)[0]
        return max(total - used, 0), total
    st = os.statvfs(path)
    return st.f_bavail * st.f_frsize, st.f_blocks * st.f_frsize


def _holds_lock(root: str, current: str) -> bool:
    """True when the testbed lock is held (the kernel says so) and its holder named `current` as its run folder."""
    busy, holder = lock_state(root)
    return bool(busy and holder and current and holder.endswith("out=" + current))


def _pct(free: int, total: int) -> str:
    return "%d%%" % round(100.0 * free / total) if total else "?%"


def _read_pair(path: str):
    """Two numbers from a file of this cleanup (disk-start.txt, disk-low.txt), or None."""
    fd = _plain(path)
    if fd is None:
        return None
    try:
        parts = os.read(fd, 200).decode("ascii", errors="replace").split()
    finally:
        os.close(fd)
    return (int(parts[0]), int(parts[1])) if len(parts) == 2 and parts[0].isdigit() and parts[1].isdigit() else None


def clean(root: str, current: str, phase: str, disk=disk_space) -> str:
    """Under the lock, at a run start (phase "start") or once it is summarized ("end"). In order:
      1. end only: this run is tidied;
      2. every OTHER finished run (its run.log has an OUTCOME) not yet tidied is tidied;
      3. every ~/corpus/work/<stamp>-<lane> folder goes (no corpus lane runs outside the lock);
      4. below the floor (FLOOR of the volume free): unfinished runs other than this one, oldest
         first, are tidied until the floor is met;
      5. still below it: the two build caches of this root go, but only when that reaches the floor
         (a cold build costs 10-25 minutes; dropping them for nothing is all cost).
    Returns the one disk line. Refused (exception) unless the lock is held by `current`."""
    if phase not in ("start", "end"):
        raise Refused("phase is start or end")
    conf = Confine(root)
    current = os.path.abspath(current)
    if _joined(current) != os.path.join(conf.out, os.path.basename(current)) or not RUN_NAME.match(os.path.basename(current)):
        raise Refused("the current run is not a run folder of this root")
    if not _holds_lock(root, current):
        raise Refused("the testbed lock is not held by this run")
    mine = _joined(current)
    free, total = disk(conf.root)
    lowest = free                                            # at the end: before this run gives anything back
    parts, refused, removed = [], 0, 0
    if phase == "end":
        done = tidy(conf, current)
        if done:
            parts.append("this run %.2f GB" % (done[0] / 1e9))
            removed += done[0]
            refused += done[2]
    old_bytes = old_runs = 0
    unfinished = []
    for _, path, finished in _run_folders(conf):
        if path == mine:
            continue                                         # the run holding the lock: only ever its own end tidies it
        if not finished:
            unfinished.append(path)
            continue
        done = tidy(conf, path)
        if done:
            old_bytes += done[0]
            old_runs += 1
            refused += done[2]
    work_bytes = work_folders = 0
    if conf.work:
        for name in sorted(os.listdir(conf.work)):
            path = os.path.join(conf.work, name)
            if not RUN_WORK.match(name) or os.path.islink(path) or not os.path.isdir(path):
                continue
            gone = conf.remove(path)
            if gone is None:
                refused += 1
            else:
                work_bytes += gone
                work_folders += 1
    free, total = disk(conf.root)
    target = int(total * FLOOR)
    for path in unfinished:                                  # oldest first
        if free >= target:
            break
        done = tidy(conf, path)
        if done:
            old_bytes += done[0]
            old_runs += 1
            refused += done[2]
        free, total = disk(conf.root)
    if old_runs:
        parts.append("older runs %.2f GB (%d)" % (old_bytes / 1e9, old_runs))
    if work_folders:
        parts.append("corpus work %.2f GB (%d)" % (work_bytes / 1e9, work_folders))
    removed += old_bytes + work_bytes
    caches_note = ""
    if free < target and conf.caches:
        sizes = [_measure(c, os.lstat(c).st_dev)[0] for c in conf.caches]
        if free + sum(sizes) >= target:
            cache_bytes = 0
            for cache in conf.caches:
                gone = conf.remove(cache)
                if gone is None:
                    refused += 1
                else:
                    cache_bytes += gone
                free, total = disk(conf.root)
                if free >= target:
                    break
            parts.append("build caches %.2f GB" % (cache_bytes / 1e9))
            removed += cache_bytes
        else:
            caches_note = "; build caches kept (%.1f GB would not reach the floor)" % (sum(sizes) / 1e9)
    removed /= 1e9
    under = "" if free >= target else ", UNDER by %.1f GB" % ((target - free) / 1e9)
    if phase == "start":
        _write_own(os.path.join(current, "disk-start.txt"), "%d %d\n" % (free, total))
        head = "disk: free %s at the start (floor %d%%%s)" % (_pct(free, total), FLOOR * 100, under)
    else:
        start = _read_pair(os.path.join(current, "disk-start.txt"))
        low = _read_pair(os.path.join(current, "disk-low.txt"))
        lowest = min([lowest] + [pair[0] for pair in (start, low) if pair])
        head = "disk: free %s after cleanup (lowest %s during the run, %s at the start; floor %d%%%s)" % (
            _pct(free, total), _pct(lowest, total), _pct(start[0], start[1]) if start else "?%", FLOOR * 100, under)
    tail = (" — removed %.2f GB: %s" % (removed, ", ".join(parts))) if parts else " — nothing to remove"
    if refused:
        tail += "; could not be removed %d (a link, a mount or a lock flag)" % refused
    return head + tail + caches_note


def sample(root: str, out: str, disk=disk_space, interval: float = SAMPLE_SECONDS) -> None:
    """While a run works: the lowest free figure seen, kept in <out>/disk-low.txt as "<free> <total>".
    Stops when <out>/disk-sample.stop appears or the shell that started it is gone, after one last look.
    It never holds the testbed lock (m4_run.sh starts it with fd 9 closed)."""
    conf = Confine(root)
    out = os.path.abspath(out)
    if _joined(out) != os.path.join(conf.out, os.path.basename(out)) or not RUN_NAME.match(os.path.basename(out)):
        raise Refused("not a run folder of this root")
    stop, parent, low = os.path.join(out, "disk-sample.stop"), os.getppid(), None
    while True:
        free, total = disk(conf.root)
        if low is None or free < low:
            low = free
            _write_own(os.path.join(out, "disk-low.txt"), "%d %d\n" % (low, total))
        if os.path.lexists(stop) or os.getppid() != parent:
            return
        waited = 0.0
        while waited < interval and not os.path.lexists(stop) and os.getppid() == parent:
            time.sleep(min(1.0, interval))
            waited += min(1.0, interval)


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
        try:
            print(clean(argv[1], argv[3], argv[5]))
            return 0
        except Refused as error:
            print("disk: cleanup refused (%s)" % error)
            return 2
        except Exception as error:                         # noqa: BLE001 — the run must reach its OUTCOME
            print("disk: cleanup failed (%s)" % type(error).__name__)
            return 1
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
