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
_COUNT_LINE = re.compile(r"\b\d+ (?:passed|failed|errors?)\b")
_FAILED = re.compile(r"^(?:FAILED|ERROR) (\S+)", re.M)


def verdict(text: str, rc: int, timed_out: bool, budget: int) -> Tuple[bool, str]:
    """(green, line) from the runner's whole output, its exit code and the watchdog."""
    if timed_out:
        return False, f"script tests RED (timed out after {budget}s)"
    lines = [line for line in text.splitlines() if _COUNT_LINE.search(line)]
    last = lines[-1] if lines else ""

    def count(word: str) -> int:
        m = re.search(r"(\d+) " + word, last)
        return int(m.group(1)) if m else 0

    passed, failed, errors = count("passed"), count("failed"), count("errors?")
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
            try:
                os.killpg(p.pid, signal.SIGTERM)
                p.wait(timeout=20)
            except subprocess.TimeoutExpired:
                os.killpg(p.pid, signal.SIGKILL)
                p.wait()
            except ProcessLookupError:
                pass
            return 124, True


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
