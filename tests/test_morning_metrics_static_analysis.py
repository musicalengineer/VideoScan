"""scripts/morning_metrics.sh: the static-analysis day-over-day flag (#426).

Since 2026-11-04 metrics/static_analysis.jsonl interleaves GitHub's nightly rows
(concurrency_warnings / swiftlint_strict null: those build jobs are off) with
the M4 analysis lane's (source "m4-analysis-lane"). The digest compared the
last two rows, usually one of each, so "rose by >= 5" never fired."""
from __future__ import annotations

import datetime
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def morning(sa_rows: list) -> str:
    script = (ROOT / "scripts" / "morning_metrics.sh").read_text()
    code = re.search(r"python3 - <<'PY'\n(.*?)\nPY\s*$", script, re.DOTALL).group(1)
    now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
    row = {"ts": now.isoformat().replace("+00:00", "Z"), "source": "nightly-local", "host": "M4",
           "branch": "main", "dirty": False, "status": "ok", "passed": 100, "failed": 0, "skipped": 0,
           "total": 100}
    env = dict(os.environ, TD_ROWS=json.dumps(row), TD_SA="\n".join(json.dumps(r) for r in sa_rows))
    return subprocess.run([sys.executable, "-c", code], env=env, check=True, capture_output=True,
                          text=True, timeout=60).stdout


def lane(ts: str, warnings: int, strict: int) -> dict:
    return {"ts": ts, "source": "m4-analysis-lane", "branch": "chore/m4-analysis-lane",
            "concurrency_warnings": warnings, "swiftlint_strict": strict}


def github(ts: str) -> dict:
    return {"ts": ts, "source": "github-nightly", "concurrency_warnings": None,
            "swiftlint_strict": None, "codeql_findings": None}


def test_a_rise_between_two_lane_rows_is_flagged_through_interleaved_github_rows():
    rows = [lane("2026-11-23T06:00:00Z", 10, 40), github("2026-11-23T08:00:00Z"),
            lane("2026-11-24T06:00:00Z", 17, 46), github("2026-11-24T08:00:00Z")]
    out = morning(rows)
    assert "concurrency warnings rose +7 (10 → 17)." in out, out
    assert "swiftlint-strict rose +6 (40 → 46)." in out, out


def test_rows_from_other_sources_are_never_compared():
    """GitHub rows with numbers (an older shape) are not the lane's ruler."""
    rows = [{"ts": "2026-11-23T08:00:00Z", "source": "github-nightly", "concurrency_warnings": 0,
             "swiftlint_strict": 0, "codeql_findings": 0},
            lane("2026-11-24T06:00:00Z", 30, 50)]
    out = morning(rows)
    assert "rose" not in out, out
    # one lane row only: nothing to compare, nothing flagged
    assert "rose" not in morning([lane("2026-11-24T06:00:00Z", 30, 50)])


def test_codeql_is_not_read_from_the_lane():
    rows = [dict(lane("2026-11-23T06:00:00Z", 1, 1), codeql_findings=0),
            dict(lane("2026-11-24T06:00:00Z", 1, 1), codeql_findings=9)]
    assert "CodeQL" not in morning(rows)
