"""The adversarial-review line in .claude/scripts/session_morning_hook.sh:
every latest.json state maps to exactly one honest line (2026-10-01)."""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
HOOK = ROOT / ".claude" / "scripts" / "session_morning_hook.sh"
TODAY = "2026-10-02"


def snippet() -> str:
    text = HOOK.read_text()
    block = text.split("── Adversarial review", 1)[1]
    match = re.search(r"<<'PY'[^\n]*\n(.*?)\nPY\n", block, re.S)
    assert match, "adversarial block not found in the morning hook"
    return match.group(1)


def line_for(tmp_path, state: dict | None) -> str:
    path = tmp_path / "latest.json"
    if state is not None:
        path.write_text(json.dumps(state))
    out = subprocess.run([sys.executable, "-c", snippet(), str(path), TODAY], capture_output=True, text=True)
    assert out.returncode == 0, out.stderr
    return out.stdout.strip()


BASE = {"date": TODAY, "doc": "/x/2026-10-02.md", "filesReviewed": 11, "costUsd": 4.2, "notReviewed": 0}


@pytest.mark.parametrize("state,expect", [
    (None, "🔴 adversarial review did not run last night (last: never)"),
    ({**BASE, "date": "2026-10-01", "status": "clean"}, "🔴 adversarial review did not run"),
    ({**BASE, "status": "failed", "failure": "brief 1: timeout after 2400s"}, "🔴 adversarial review FAILED: brief 1: timeout"),
    ({**BASE, "status": "disabled"}, "🔴 adversarial review DISABLED"),
    ({**BASE, "status": "findings", "newFindings": {"P1": 2, "P2": 1}, "confirmedRed": 1},
     "🔴 adversarial review: 2 P1, 1 P2 (1 confirmed-red) → /x/2026-10-02.md"),
    ({**BASE, "status": "findings", "newFindings": {"P1": 1}, "confirmedRed": None},
     "(red tests: pending)"),
    ({**BASE, "status": "findings", "newFindings": {"P3": 2}}, "🟢 adversarial review clean, 11 files"),
    ({**BASE, "status": "clean"}, "🟢 adversarial review clean, 11 files"),
    ({**BASE, "status": "nothing"}, "⚪ adversarial review: nothing in scope"),
    ({**BASE, "status": "findings", "newFindings": {"P0": 1}, "notReviewed": 4}, "4 NOT REVIEWED"),
])
def test_morning_line(tmp_path, state, expect):
    assert expect in line_for(tmp_path, state)
