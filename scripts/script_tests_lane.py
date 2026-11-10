#!/usr/bin/env python3
"""script_tests_lane.py — run the testbed's own Python tests and say the result in one line.

Why (2026-11-10): scripts/run_python_tests.sh (the tests of the nightly scripts,
the publishers and the metrics page) ran only in GitHub's Linux job, which skips
every macOS-only test. Nothing ran them on a Mac: the nightly's shell self-test
sat red for five days unseen. scripts/nightly_gauntlet.sh now calls this once per
run on the M4 and puts the line in its done line.

    script_tests_lane.py <runner.sh> <log file> <budget seconds> <cwd>

Prints exactly one line and exits 0 GREEN / 1 RED:

    script tests GREEN (1803 passed)
    script tests RED (2 failed: test_x.py::test_a, test_y.py::test_b)
    script tests RED (timed out after 1500s)
    script tests RED (exit 1, 0 passed: <the runner's own error>)

A run that proves nothing (zero tests, a preflight stop) is RED, never GREEN.
The runner gets its own process group; past the budget the group is stopped.
Memory: the runner's log is read once at the end (a few hundred KB).
Tests: tests/test_script_tests_lane.py.
"""
from __future__ import annotations

import os
import re
import signal
import subprocess
import sys
from typing import List, Tuple

NAMES_SHOWN = 3
# pytest's FINAL summary line, whole: "1987 passed, 4 skipped, 1 warning in 781.25s (0:13:01)",
# with or without the "=====" rule around it. Only this line is counted (Codex #275 F6: any
# line saying "1 passed" — a preflight note — used to make a zero-test run GREEN).
_SUMMARY = re.compile(r"^=*\s*((?:\d+ [a-z]+(?: [a-z]+)?, )*\d+ [a-z]+(?: [a-z]+)?) in \d+(?:\.\d+)?s(?: \([\d:]+\))?\s*=*$")
# The only outcome words pytest's summary uses. A term with any other word, or a word
# said twice ("1 passed, 0 failed, 2 failed"), is not a summary this lane will trust
# (Codex #276 F6).
_KINDS = {"passed", "failed", "error", "errors", "skipped", "warning", "warnings", "xfailed", "xpassed",
          "deselected", "rerun", "subtests passed", "subtests failed", "subtests skipped"}


def summary_counts(line: str):
    """{kind: n} for a well-formed summary body ("3 passed, 1 skipped"), else None."""
    counts = {}
    for term in line.split(", "):
        m = re.fullmatch(r"(\d+) ([a-z]+(?: [a-z]+)?)", term)
        if not m or m.group(2) not in _KINDS or m.group(2) in counts:
            return None
        counts[m.group(2)] = int(m.group(1))
    return counts
_NO_TESTS = re.compile(r"^=*\s*no tests ran\b")
_FAILED = re.compile(r"^(?:FAILED|ERROR) (\S+)", re.M)


def verdict(text: str, rc: int, timed_out: bool, budget: int) -> Tuple[bool, str]:
    """(green, line) from the runner's whole output, its exit code and the watchdog."""
    if timed_out:
        return False, f"script tests RED (timed out after {budget}s)"
    # The LAST summary-shaped line decides; a later "no tests ran" cancels an earlier count.
    counts = {}
    for line in text.splitlines():
        m = _SUMMARY.match(line.strip())
        if m:
            counts = summary_counts(m.group(1)) or {}      # malformed: no result
        elif _NO_TESTS.match(line.strip()):
            counts = {}
    passed = counts.get("passed", 0)
    failed = counts.get("failed", 0) + counts.get("subtests failed", 0)
    errors = counts.get("error", 0) + counts.get("errors", 0)
    if rc == 0 and passed > 0 and not failed and not errors:
        return True, f"script tests GREEN ({passed} passed)"
    if failed or errors:
        names: List[str] = []
        for name in _FAILED.findall(text):
            name = name.replace("tests/", "", 1)
            if name not in names:
                names.append(name)
        shown = ", ".join(names[:NAMES_SHOWN]) + (f" +{len(names) - NAMES_SHOWN} more" if len(names) > NAMES_SHOWN else "")
        return False, f"script tests RED ({failed + errors} failed{': ' + shown if shown else ''})"
    why = next((line for line in reversed(text.splitlines()) if "::error::" in line), "")
    why = re.sub(r"^.*::error::", "", why).strip()[:120]
    return False, f"script tests RED (exit {rc}, {passed} passed{': ' + why if why else ''})"


def run(runner: str, log: str, budget: int, cwd: str) -> Tuple[int, bool]:
    """Run `bash runner` with output in `log`; (exit code, timed out)."""
    with open(log, "wb") as f:
        p = subprocess.Popen(["bash", runner], cwd=cwd, stdin=subprocess.DEVNULL, stdout=f,
                             stderr=subprocess.STDOUT, start_new_session=True)
        try:
            return p.wait(timeout=budget), False
        except subprocess.TimeoutExpired:
            stop_group(p)
            return 124, True


def descendants(root: int) -> List[int]:
    """Every live process below `root` in the process tree (children, their children…),
    from one `ps` listing. A process that has already been re-parented to launchd is
    not found — nothing short of a job object could find it."""
    try:
        listing = subprocess.run(["ps", "-axo", "pid=,ppid="], capture_output=True, text=True, timeout=20).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    children: dict = {}
    for row in listing.splitlines():
        parts = row.split()
        if len(parts) == 2 and parts[0].isdigit() and parts[1].isdigit():
            children.setdefault(int(parts[1]), []).append(int(parts[0]))
    found, queue = [], [root]
    while queue:
        for child in children.get(queue.pop(), []):
            if child not in found:
                found.append(child)
                queue.append(child)
    return found


def stop_group(p: subprocess.Popen, grace: float = 20.0) -> None:
    """Stop the runner and everything it started. The tree below it is listed FIRST
    (while the parent links still exist), then: TERM the process group, give it
    `grace` seconds, KILL the group — always, even when the leader has already exited
    (bash dies on TERM at once; a child ignoring TERM stayed, Codex #275 F4) — and
    KILL every listed descendant, which reaches a child that moved to its own
    session or group (Codex #276 F4)."""
    tree = descendants(p.pid)
    try:
        os.killpg(p.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        p.wait(timeout=grace)
    except subprocess.TimeoutExpired:
        pass
    tree += [pid for pid in descendants(p.pid) if pid not in tree]
    try:
        os.killpg(p.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass                                # nobody left in the group
    for pid in tree:
        try:
            os.kill(pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
    try:
        p.wait(timeout=10)
    except subprocess.TimeoutExpired:
        pass


def main(argv: List[str]) -> int:
    if len(argv) != 4 or not argv[2].isdigit():
        print("script tests RED (usage: script_tests_lane.py <runner.sh> <log> <budget seconds> <cwd>)")
        return 1
    runner, log, budget, cwd = argv[0], argv[1], int(argv[2]), argv[3]
    try:
        rc, timed_out = run(runner, log, budget, cwd)
        with open(log, errors="replace") as f:
            text = f.read()
    except OSError as exc:
        print(f"script tests RED (could not run: {type(exc).__name__})")
        return 1
    green, line = verdict(text, rc, timed_out, budget)
    print(line)
    return 0 if green else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
