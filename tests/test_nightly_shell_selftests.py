"""The nightly's own shell self-tests run in an automated lane.

RED 2026-11-10: scripts/test_nightly_failure_modes.sh (92 checks of the nightly
script: verdict precedence, publish queue, rota, installers) was run by nothing.
When the M4 moved to 14:00 on 11/05, three of its checks went red and stayed red
for five days with nobody told. Each self-test is now one pytest test, so the
gauntlet's Python stage runs them every day on the M4.

macOS only: the self-tests call plutil, scutil and launchctl stand-ins that
assume a Mac (CI's Python job is Linux and skips them).

2026-11-20: the failure-modes self-test runs as concurrent groups, one module
each (tests/test_nightly_failure_modes_<group>.py, defined in
tests/nightly_failure_modes_groups.py); the pin below keeps every section seated.
"""
import os
import re
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "scripts"
sys.path.insert(0, str(Path(__file__).resolve().parent))

from nightly_failure_modes_groups import GROUPS, list_sections  # noqa: E402

needs_mac = pytest.mark.skipif(sys.platform != "darwin", reason="the nightly self-tests need macOS tools")


def run_selftest(name: str, timeout: int = 900) -> subprocess.CompletedProcess:
    return subprocess.run(["bash", str(SCRIPTS / name)], capture_output=True, text=True, timeout=timeout,
                          stdin=subprocess.DEVNULL)


def failures(output: str) -> str:
    """The self-test's own failure lines, for the assertion message."""
    lines = [line for line in output.splitlines() if re.search(r"\bFAIL\b|^\s*not ok\b", line)]
    return "\n".join(lines[-20:]) or output[-1500:]


def test_failure_modes_groups_seat_every_section_once():
    """test_nightly_failure_modes.sh runs as groups: a section in no group would run nowhere.

    Every section the script lists is in exactly one group; a group holds each section's
    prerequisites (the script would refuse it otherwise); every group has its own module calling
    run_group; and the groups' check floors still add up to the 90+ checks of the serial run."""
    sections = list_sections()
    seated = [s for g in GROUPS.values() for s in g.sections.split()]
    assert sorted(seated) == sorted(sections), "sections vs groups differ"
    assert len(seated) == len(set(seated)), "a section is in two groups"
    for name, group in GROUPS.items():
        words = group.sections.split()
        assert words == [s for s in sections if s in words], f"group {name} is not in script order"
        for s in words:
            missing = [n for n in sections[s] if n not in words]
            assert not missing, f"group {name}: section {s} needs {missing}"
        module = ROOT / "tests" / f"test_nightly_failure_modes_{name}.py"
        assert module.is_file() and f'run_group("{name}")' in module.read_text(), module.name
        assert group.floor >= 1, name
    total = sum(g.floor for g in GROUPS.values())
    assert total >= 90, f"group floors sum to {total} checks, the serial run had 90+"


def test_failure_modes_selection_refuses_unknown_or_half_set_up_sections():
    """A typo or a missing prerequisite is refused (exit 2), never a quiet partial run."""
    script = str(SCRIPTS / "test_nightly_failure_modes.sh")
    for selection, why in (("1 99", "unknown section '99'"), ("2", "section 2 needs section 1"),
                           ("5 6 3", "section 3 needs section 2")):
        proc = subprocess.run(["bash", script], capture_output=True, text=True, timeout=60,
                              stdin=subprocess.DEVNULL, env=dict(os.environ, SELFTEST_SECTIONS=selection))
        assert proc.returncode == 2 and why in proc.stderr, (selection, proc.returncode, proc.stderr)
        assert "Tests passed" not in proc.stdout, selection


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


# Run as groups by tests/test_nightly_failure_modes_<group>.py, pinned above.
GROUPED = {"test_nightly_failure_modes.sh"}


def test_every_nightly_shell_selftest_has_a_seat_here():
    """A new scripts/test_nightly_*.sh must be added above, or it runs nowhere again."""
    here = Path(__file__).read_text()
    for script in sorted(SCRIPTS.glob("test_nightly_*.sh")):
        assert script.name in GROUPED or f'run_selftest("{script.name}")' in here, script.name
