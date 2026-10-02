"""The local-review and Hallie's-voice lines in .claude/scripts/session_morning_hook.sh
(2026-10-02: they replaced team-channel posts). Every latest.json state maps to
exactly one honest line; a stale or missing file is never green."""

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


def snippet(marker: str) -> str:
    block = HOOK.read_text().split(marker, 1)[1]
    match = re.search(r"<<'PY'[^\n]*\n(.*?)\nPY\n", block, re.S)
    assert match, f"{marker!r} block not found in the morning hook"
    return match.group(1)


def line_for(tmp_path, marker: str, state: dict | None) -> str:
    path = tmp_path / "latest.json"
    if state is not None:
        path.write_text(json.dumps(state))
    out = subprocess.run([sys.executable, "-c", snippet(marker), str(path), TODAY],
                         capture_output=True, text=True)
    assert out.returncode == 0, out.stderr
    return out.stdout.strip()


LOCAL = "── Nightly local-model review"
VOICE = "── Hallie's voice"
S = "/logs/model-review/2026-10-02/summary.md"


@pytest.mark.parametrize("state,expect", [
    (None, "🔴 local review did not run last night (last: never)"),
    ({"date": "2026-10-01", "status": "reviewed"}, "🔴 local review did not run last night (last: 2026-10-01)"),
    ({"date": TODAY, "status": "reviewed", "flagged": 0, "unreviewed": 0, "abandoned": 0, "summary": S},
     f"🟢 local review: 0 flagged, 0 unreviewed → {S}"),
    ({"date": TODAY, "status": "reviewed", "flagged": 3, "unreviewed": 0, "abandoned": 0, "summary": S},
     f"🟡 local review: 3 flagged, 0 unreviewed → {S}"),
    ({"date": TODAY, "status": "reviewed", "flagged": 1, "unreviewed": 4, "abandoned": 2, "summary": S},
     f"🔴 local review: 1 flagged, 4 unreviewed, 2 abandoned → {S}"),
    ({"date": TODAY, "status": "skipped", "reason": "host asleep", "unreviewed": 7, "summary": S},
     f"🔴 local review SKIPPED: host asleep; 7 commit(s) pending → {S}"),
    ({"date": TODAY, "status": "quiet", "quietNights": 1, "summary": S},
     f"⚪ local review: nothing new (1 quiet night(s)) → {S}"),
    ({"date": TODAY, "status": "quiet", "quietNights": 3, "summary": S},
     f"🟡 local review: nothing new (3 quiet night(s)) → {S}"),
    ({"date": TODAY, "status": "weird", "summary": S}, "🔴 local review: unknown state 'weird'"),
])
def test_local_review_line(tmp_path, state, expect):
    assert line_for(tmp_path, LOCAL, state).startswith(expect)


def test_local_review_line_matches_what_nightly_review_writes():
    """The keys the hook reads are the keys nightly_review.sh publishes."""
    script = (ROOT / "tools" / "model-fitness" / "nightly_review.sh").read_text()
    for key in ("reviewed=", "flagged=", "unreviewed=", "abandoned=", "quietNights=", "reason="):
        assert key in script, key
    assert "latest.json" in script and "summary.md" in script


@pytest.mark.parametrize("state,expect", [
    (None, ""),
    ({"date": TODAY, "alert": False, "headline": "Hallie's voice: ok"}, ""),
    ({"date": "2026-10-01", "alert": True, "headline": "Hallie's voice: regressed"}, ""),
    ({"date": TODAY, "alert": True, "headline": "Hallie's voice: regressed", "detail": "similarity 0.41"},
     "🔴 Hallie's voice: regressed — similarity 0.41 → "),
])
def test_hallie_voice_line_only_when_last_night_alerted(tmp_path, state, expect):
    line = line_for(tmp_path, VOICE, state)
    assert line.startswith(expect) if expect else line == ""
