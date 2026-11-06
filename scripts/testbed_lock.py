#!/usr/bin/env python3
"""testbed_lock.py — the testbed lock behind scripts/m4_run.sh and scripts/nightly_gauntlet.sh.

A kernel advisory lock (fcntl.flock LOCK_EX|LOCK_NB on <lockdir>/flock), held by this
process for the life of the run and released by the kernel the instant the holder
dies — so there is no stale lock, no reclamation and no race in reclaiming
(Codex 2026-11-05 re-review, P1: every hand-rolled mkdir/rename protocol had a
check-then-act window; two owners could win). <lockdir>/info carries "pid info"
for the "busy: …" message only; it is never the truth.

  hold <lockdir> <info>   acquire; print one line — "HELD" or "BUSY <info of the
                          holder>" — then (if HELD) keep holding until the parent
                          shell is gone (ppid changes) or SIGTERM arrives.
  probe <lockdir>         print "FREE" or "BUSY <info>"; never holds.

Shell contract (take_lock in both scripts): run `hold` in the background with its
stdout on a FIFO, read the one answer line; on HELD the holder child is the lease,
killed by drop_lock, or gone by itself when the shell exits (any way it exits).

Test hooks (tests/test_nightly_gauntlet.py, tests/test_m4_run.py): while the file
named by VIDEOSCAN_TESTBED_LOCK_PAUSE exists, `hold` waits BEFORE claiming (and
writes <path>.paused); VIDEOSCAN_TESTBED_LOCK_PAUSE_HELD likewise AFTER claiming,
before answering. Deterministic interleavings, nothing timing-based.

C++ analogy: an RAII lock guard whose destructor is process exit.
"""
from __future__ import annotations

import fcntl
import os
import sys
import time


def _pause(env: str) -> None:
    path = os.environ.get(env)
    if not path:
        return
    with open(path + ".paused", "w"):
        pass
    while os.path.exists(path):
        time.sleep(0.02)


def _info(lockdir: str) -> str:
    """The holder's words (the info file is "pid info"; the pid stays out of the message)."""
    try:
        with open(os.path.join(lockdir, "info"), encoding="utf-8", errors="replace") as f:
            return f.read().strip().split(" ", 1)[-1]
    except OSError:
        return "(no info written yet)"


def _open(lockdir: str) -> int:
    os.makedirs(lockdir, exist_ok=True)
    return os.open(os.path.join(lockdir, "flock"), os.O_RDWR | os.O_CREAT, 0o644)


def _try_lock(fd: int) -> bool:
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return True
    except OSError:
        return False


def probe(lockdir: str) -> int:
    fd = _open(lockdir)
    if _try_lock(fd):
        fcntl.flock(fd, fcntl.LOCK_UN)
        print("FREE")
    else:
        print("BUSY " + _info(lockdir))
    return 0


def hold(lockdir: str, info: str) -> int:
    parent = os.getppid()
    _pause("VIDEOSCAN_TESTBED_LOCK_PAUSE")
    fd = _open(lockdir)
    if not _try_lock(fd):
        print("BUSY " + _info(lockdir), flush=True)
        return 1
    with open(os.path.join(lockdir, "info"), "w", encoding="utf-8") as f:
        f.write(f"{parent} {info}\n")
    _pause("VIDEOSCAN_TESTBED_LOCK_PAUSE_HELD")
    print("HELD", flush=True)
    try:
        sys.stdout.close()
    except OSError:
        pass
    # The lease: live exactly as long as the shell that asked. A shell that
    # exits (or is killed) reparents us; the kernel drops the lock with us.
    while os.getppid() == parent:
        time.sleep(0.2)
    return 0


def main(argv: list[str]) -> int:
    if len(argv) == 3 and argv[0] == "hold":
        return hold(argv[1], argv[2])
    if len(argv) == 2 and argv[0] == "probe":
        return probe(argv[1])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
