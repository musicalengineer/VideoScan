"""The nightly's own shell self-tests run in an automated lane.

RED 2026-11-10: scripts/test_nightly_failure_modes.sh (92 checks of the nightly
script: verdict precedence, publish queue, rota, installers) was run by nothing.
When the M4 moved to 14:00 on 11/05, three of its checks went red and stayed red
for five days with nobody told. Each self-test is now one pytest test, so the
gauntlet's Python stage runs them every day on the M4.

macOS only: the self-tests call plutil, scutil and launchctl stand-ins that
assume a Mac (CI's Python job is Linux and skips them).
"""
import re
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "scripts"
needs_mac = pytest.mark.skipif(sys.platform != "darwin", reason="the nightly self-tests need macOS tools")


def run_selftest(name: str, timeout: int = 900) -> subprocess.CompletedProcess:
    return subprocess.run(["bash", str(SCRIPTS / name)], capture_output=True, text=True, timeout=timeout,
                          stdin=subprocess.DEVNULL)


def failures(output: str) -> str:
    """The self-test's own failure lines, for the assertion message."""
    lines = [line for line in output.splitlines() if re.search(r"\bFAIL\b|^\s*not ok\b", line)]
    return "\n".join(lines[-20:]) or output[-1500:]


@needs_mac
def test_nightly_failure_modes_selftest_passes():
    proc = run_selftest("test_nightly_failure_modes.sh")
    assert proc.returncode == 0, failures(proc.stdout + proc.stderr)
    m = re.search(r"Tests passed: (\d+)\s+Tests failed: (\d+)", proc.stdout)
    assert m, proc.stdout[-500:]
    # A self-test that ran nothing is red, not green (CLAUDE.md rule 9).
    assert int(m.group(1)) >= 90 and int(m.group(2)) == 0, m.group(0)


@needs_mac
def test_nightly_analysis_lane_selftest_passes():
    proc = run_selftest("test_nightly_analysis_lane.sh")
    assert proc.returncode == 0, failures(proc.stdout + proc.stderr)
    m = re.search(r"Tests passed: (\d+)\s+Tests failed: (\d+)", proc.stdout)
    assert m and int(m.group(1)) >= 30 and int(m.group(2)) == 0, proc.stdout[-500:]


@needs_mac
def test_nightly_hallie_replay_selftest_passes():
    proc = run_selftest("test_nightly_hallie_replay.sh")
    assert proc.returncode == 0, failures(proc.stdout + proc.stderr)
    m = re.search(r"passed (\d+), failed (\d+)", proc.stdout)
    assert m and int(m.group(1)) >= 15 and int(m.group(2)) == 0, proc.stdout[-500:]


def test_every_nightly_shell_selftest_has_a_seat_here():
    """A new scripts/test_nightly_*.sh must be added above, or it runs nowhere again."""
    here = Path(__file__).read_text()
    for script in sorted(SCRIPTS.glob("test_nightly_*.sh")):
        assert f'run_selftest("{script.name}")' in here, script.name
