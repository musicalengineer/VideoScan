#!/usr/bin/env python3
"""testbed_lock.py — the testbed lock behind scripts/m4_run.sh and scripts/nightly_gauntlet.sh.

A kernel advisory lock (fcntl.flock LOCK_EX|LOCK_NB) on <lockdir>/flock, taken on an
OPEN FILE DESCRIPTION the shell created and every piece of its work inherits:

    exec 9>>"<lockdir>/flock"                        # the shell opens fd 9 (append, create)
    python3 testbed_lock.py hold 9 <lockdir> <info>  # flocks fd 9 and exits

flock belongs to the open file description, not to a process, so the kernel holds it
until the LAST process holding fd 9 closes it: the shell, the suite, the gauntlet in
its own session, a detached child — all of them, for exactly as long as any of them
lives; a crash anywhere releases it by itself. No stale lock, no reclaim, no lease
process (Codex 2026-11-05 re-reviews: every hand-rolled protocol had a check-then-act
window, and a lease tied to the shell ended before surviving work did). <lockdir>/info
carries "pid info" for the "busy: …" message only; it is never the truth.

  hold <fd> <lockdir> <info>   flock the inherited <fd>; print one line — "HELD" or
                               "BUSY <info of the holder>" — and exit (the lock stays with fd).
  probe <lockdir>              print "FREE" or "BUSY <info>" from a fresh open; never holds.

Test hooks (tests/test_nightly_gauntlet.py, tests/test_m4_run.py): while the file named
by VIDEOSCAN_TESTBED_LOCK_PAUSE exists, `hold` waits BEFORE claiming (and writes
<path>.paused); VIDEOSCAN_TESTBED_LOCK_PAUSE_HELD likewise AFTER claiming, before
answering. Deterministic interleavings, nothing timing-based.

C++ analogy: the lock is owned by a shared_ptr every child copies; it frees at refcount 0.
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
    """The words of the holder (the info file is "pid info"; the pid stays out of the message).
    No apostrophes anywhere in this file: m4_run.sh ships it to the host inside a heredoc."""
    try:
        with open(os.path.join(lockdir, "info"), encoding="utf-8", errors="replace") as f:
            return f.read().strip().split(" ", 1)[-1]
    except OSError:
        return "(no info written yet)"


def _try_lock(fd: int) -> bool:
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return True
    except OSError:
        return False


def probe(lockdir: str) -> int:
    os.makedirs(lockdir, exist_ok=True)
    fd = os.open(os.path.join(lockdir, "flock"), os.O_RDWR | os.O_CREAT, 0o644)
    if _try_lock(fd):
        fcntl.flock(fd, fcntl.LOCK_UN)
        print("FREE")
    else:
        print("BUSY " + _info(lockdir))
    os.close(fd)
    return 0


def hold(fd: int, lockdir: str, info: str) -> int:
    try:
        os.fstat(fd)
    except OSError:
        print("ERROR fd %d is not open (the shell must `exec %d>>\"%s/flock\"` first)" % (fd, fd, lockdir))
        return 2
    _pause("VIDEOSCAN_TESTBED_LOCK_PAUSE")
    if not _try_lock(fd):
        print("BUSY " + _info(lockdir))
        return 1
    with open(os.path.join(lockdir, "info"), "w", encoding="utf-8") as f:
        f.write(f"{os.getppid()} {info}\n")
    _pause("VIDEOSCAN_TESTBED_LOCK_PAUSE_HELD")
    print("HELD")
    return 0          # our copy of fd closes; the copies in the shell and its children keep the lock


def main(argv: list[str]) -> int:
    if len(argv) == 4 and argv[0] == "hold" and argv[1].isdigit():
        return hold(int(argv[1]), argv[2], argv[3])
    if len(argv) == 2 and argv[0] == "probe":
        return probe(argv[1])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
