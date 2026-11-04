"""scripts/run_python_tests.sh runs every TRACKED test module except what was
moved to .trash/.

RED 2026-11-04 (GitHub run 41856296565): the 10/23 context reset moved two
test modules into .trash/retired-2026-10-reset/tests/, still tracked. The
runner's `git ls-files '*test_*.py'` picked them up and they failed (24 of the
27 failures) because the scripts they exercise were retired with them. A file
in .trash/ is kept, never run.
"""
from __future__ import annotations

import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RUNNER = ROOT / "scripts" / "run_python_tests.sh"


def listed_modules() -> list[str]:
    out = subprocess.run(["bash", str(RUNNER), "--list-modules"], capture_output=True, text=True,
                         timeout=60, check=True).stdout
    return [line for line in out.splitlines() if line.strip()]


def test_nothing_under_trash_is_collected():
    modules = listed_modules()
    assert modules, "the runner listed no modules"
    assert [m for m in modules if m.startswith(".trash/")] == []


def test_the_list_is_every_tracked_test_module_outside_trash():
    tracked = subprocess.run(["git", "-C", str(ROOT), "ls-files", "*test_*.py", "*_test.py"],
                             capture_output=True, text=True, check=True).stdout.split()
    expected = {m for m in tracked if not m.startswith(".trash/")}
    listed = listed_modules()
    assert len(listed) == len(set(listed)) and set(listed) == expected     # `sort -u` order is the locale's
    assert "tests/test_run_python_tests.py" in expected
