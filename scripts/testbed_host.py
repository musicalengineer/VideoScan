#!/usr/bin/env python3
"""testbed_host.py — housekeeping on a test host for scripts/m4_run.sh: what is kept, and status for machines.

    testbed_host.py prune <root> [--current <run dir>] [--keep N]
    testbed_host.py status-json <root> <host name>
    testbed_host.py window <root> <lane> <HHMM>

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

No apostrophes anywhere in this file: m4_run.sh ships it to the host inside a heredoc.
Memory: one run.log (KBs) at a time. Python 3.9 is the floor. Tests: tests/test_testbed_host.py.
"""
from __future__ import annotations

import fcntl
import json
import os
import re
import shutil
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
    if len(argv) == 3 and argv[0] == "status-json":
        print(status_json(argv[1], argv[2]))
        return 0
    if len(argv) == 4 and argv[0] == "window":
        print(window(argv[1], argv[2], argv[3]))
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
