"""The nightly failure-modes self-test, cut into groups that run at once.

scripts/test_nightly_failure_modes.sh was one 365 s serial run and set the Python lane's wall time
(Rick 2026-11-20: "we do not want to serialize when we can parallelize"). Its "== Test N ==" blocks
are now selectable sections (SELFTEST_SECTIONS="1 2 3"), each run in its own mktemp sandbox, and the
groups below are one pytest module each (tests/test_nightly_failure_modes_<group>.py), because
scripts/pytest_shards.py deals whole modules to its concurrent shards: three tests in one module
would run one after another in one shard.

Groups follow the script's dependencies (SECTION_NEEDS in the script: 2 needs 1, 3 needs 2, 6 needs 5;
everything else builds its fixtures on first use) and the measured seconds per section (M5 Ultra,
2026-11-20, each section alone): 14 is 14.5 s, every other section 1.6 s or less.

`floor` is the group's check count when it was cut: a group that reports fewer PASS lines has lost a
check (or ran nothing), which is red (CLAUDE.md rule 9). tests/test_nightly_shell_selftests.py pins
that the groups cover every section exactly once and that the floors still sum to >= 90.
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Dict, List, NamedTuple

import pytest

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "test_nightly_failure_modes.sh"


class Group(NamedTuple):
    sections: str   # SELFTEST_SECTIONS for this group, in script order
    floor: int      # PASS lines this group must reach
    why: str


GROUPS: Dict[str, Group] = {
    # ~6.5 s: the publish chain (fake origin + metrics worktree + pending queue) and the fake rota
    # Mac (guard, installers, toolchain update).
    "publish": Group("1 2 3 4 5 6 16 17 18", 19, "metrics publish/queue chain, rota, guard, toolchain"),
    # ~15 s: the Core package lane (its stall case alone is ~7 s) and the model lane.
    "lanes": Group("14 14b", 20, "Core package lane and model lane"),
    # ~2.5 s: pure row builders, parsers, classifiers, watchdog and machine-setup checks.
    "rows": Group("7 7b 8 9 9b 10 11 12 12b 13 15", 55, "row builders, parsers, watchdog, verdict ladder"),
}

SUMMARY = re.compile(r"Tests passed: (\d+)\s+Tests failed: (\d+)")


def list_sections() -> Dict[str, List[str]]:
    """{section: [prerequisites]} in script order, from the script itself (--list-sections)."""
    out = subprocess.run(["bash", str(SCRIPT), "--list-sections"], capture_output=True, text=True,
                         timeout=60, stdin=subprocess.DEVNULL, check=True).stdout
    return {line.split()[0]: line.split()[1:] for line in out.splitlines() if line.strip()}


def failures(output: str) -> str:
    lines = [line for line in output.splitlines() if re.search(r"\bFAIL\b", line)]
    return "\n".join(lines[-20:]) or output[-1500:]


def run_group(name: str, timeout: int = 600) -> None:
    """Run one group in its own sandbox and assert it is green and ran at least its floor."""
    group = GROUPS[name]
    env = dict(os.environ, SELFTEST_SECTIONS=group.sections)
    proc = subprocess.run(["bash", str(SCRIPT)], capture_output=True, text=True, timeout=timeout,
                          stdin=subprocess.DEVNULL, env=env)
    out = proc.stdout + proc.stderr
    assert proc.returncode == 0, failures(out)
    m = SUMMARY.search(proc.stdout)
    assert m, proc.stdout[-500:]
    # A group that ran nothing (or lost checks) is red, not green (CLAUDE.md rule 9).
    passed, failed = int(m.group(1)), int(m.group(2))
    assert failed == 0 and passed >= group.floor >= 1, f"group {name}: {m.group(0)} (floor {group.floor})"


needs_mac = pytest.mark.skipif(sys.platform != "darwin", reason="the nightly self-tests need macOS tools")
