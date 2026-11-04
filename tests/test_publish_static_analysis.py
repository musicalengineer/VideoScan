"""metrics/static_analysis.jsonl: the M4 analysis lane's numbers, published beside GitHub's rows.

2026-11-04: GitHub's strict-concurrency, lint-strict and lint-warn jobs are off
(the hosted runner has no Swift 6.4), so swiftlint_strict, periphery_aggressive
and the warning counts stopped. scripts/nightly_analysis_lane.sh on the M4 now
measures them; tools/publish_metrics.py publishes one row per lane night from
its runs.jsonl, numbers and enum words only, source "m4-analysis-lane". The
GitHub aggregate job still appends its own rows (complexity, ratchets); those are
kept verbatim and never re-validated, as complexity.jsonl's are.
"""
from __future__ import annotations

import importlib.util
import json
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("publish_metrics_static", ROOT / "tools" / "publish_metrics.py")
pm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pm)

METRICS = {"strict_warning_total": 455, "concurrency_warnings": 7, "memory_safety_warnings": 466,
           "swiftlint_strict": 359, "periphery_aggressive": 21, "escape_hatches": 1386}
# The shape scripts/analysis_lane.py `report` appends to runs.jsonl, free text included.
LANE_RUN = {
    "date": "2026-11-04", "ts": "2026-11-04T15:10:00-05:00", "status": "ok", "commit": "a99c9c13a",
    "host": "RicksM4", "elapsed_s": 5400, "metrics": METRICS,
    "headline": "🟢 Swift 6 analysis lane OK (a99c9c13a, RicksM4): ratchet 455 SECRET-HEADLINE",
    "reasons": ["SECRET-REASON /Users/rickb/dev/VideoScan/VideoScan/People/Secret.swift"],
    "stages": {"swiftlint": {"line": "swiftlint --strict: 359 … /Users/rickb/dev/VideoScan/Secret.swift",
                             "detail": ["VideoScan/VideoScan/People/Secret.swift (14)"], "number": 359}},
    "report": "/Users/rickb/Library/Logs/VideoScan/swift6-analysis/2026-11-04-report.md",
}
GITHUB_ROW = {"ts": "2026-11-04T13:17:15Z", "sha": "6f2934a8", "run_kind": "nightly", "concurrency_warnings": None,
              "swiftlint_strict": None, "complexity_offenders": 512, "some_future_github_field": [1, 2]}
SECRETS = ["/Users/rickb", "Secret", "SECRET", "RicksM4", ".md", "Swift 6 analysis lane"]


def write_runs(tmp_path: Path, runs) -> Path:
    d = tmp_path / "swift6-analysis"
    d.mkdir(parents=True, exist_ok=True)
    (d / "runs.jsonl").write_text("".join(json.dumps(r) + "\n" for r in runs) + "not json\n")
    return d


def strings(obj):
    if isinstance(obj, str):
        yield obj
    elif isinstance(obj, dict):
        for k, v in obj.items():
            yield k
            yield from strings(v)
    elif isinstance(obj, list):
        for v in obj:
            yield from strings(v)


def test_a_lane_night_becomes_one_row_under_the_existing_field_names(tmp_path):
    (row,) = pm.static_analysis_rows(write_runs(tmp_path, [LANE_RUN]) / "runs.jsonl")
    assert row == dict({"schemaVersion": 1, "ts": "2026-11-04T20:10:00Z", "date": "2026-11-04", "sha": "a99c9c13a",
                        "run_kind": "nightly", "source": "m4-analysis-lane", "host": "M4", "status": "ok",
                        "elapsed_s": 5400, "codeql_findings": None}, **METRICS)
    pm.validate("static_analysis.jsonl", row)


def test_no_line_path_reason_or_host_name_leaves_the_mac(tmp_path):
    rows = pm.static_analysis_rows(write_runs(tmp_path, [LANE_RUN]) / "runs.jsonl")
    blob = list(strings(rows))
    for secret in SECRETS:
        assert not [s for s in blob if secret in s], secret


def test_a_null_count_stays_null_and_a_red_night_says_red(tmp_path):
    run = dict(LANE_RUN, status="red", metrics=dict(METRICS, swiftlint_strict=None, memory_safety_warnings=None))
    (row,) = pm.static_analysis_rows(write_runs(tmp_path, [run]) / "runs.jsonl")
    assert row["swiftlint_strict"] is None and row["memory_safety_warnings"] is None and row["status"] == "red"
    pm.validate("static_analysis.jsonl", row)


def test_a_run_without_metrics_or_a_readable_time_is_dropped(tmp_path):
    older = {k: v for k, v in LANE_RUN.items() if k != "metrics"}          # a run from before 11/04
    rows = pm.static_analysis_rows(write_runs(tmp_path, [older, dict(LANE_RUN, ts="last night")]) / "runs.jsonl")
    assert rows == []
    assert pm.static_analysis_rows(tmp_path / "absent" / "runs.jsonl") is None


def test_one_row_per_night_the_later_run_wins(tmp_path):
    first = dict(LANE_RUN, ts="2026-11-04T05:10:00-05:00", status="red", metrics=dict(METRICS, swiftlint_strict=None))
    rows = pm.static_analysis_rows(write_runs(tmp_path, [first, LANE_RUN]) / "runs.jsonl")
    assert [(r["date"], r["status"], r["swiftlint_strict"]) for r in rows] == [("2026-11-04", "ok", 359)]


@pytest.mark.parametrize("mutate", [
    lambda r: r.update(swiftlint_strict="359"),
    lambda r: r.update(swiftlint_strict=-1),
    lambda r: r.update(source="weekly"),
    lambda r: r.update(host="RicksM4"),
    lambda r: r.update(status="red: /Users/rickb"),
    lambda r: r.update(headline="🟢 lane"),
    lambda r: r.pop("periphery_aggressive"),
])
def test_the_gate_refuses_anything_off_the_allowlist(tmp_path, mutate):
    (row,) = pm.static_analysis_rows(write_runs(tmp_path, [LANE_RUN]) / "runs.jsonl")
    mutate(row)
    with pytest.raises(pm.PrivacyError):
        pm.validate("static_analysis.jsonl", row)


def test_merge_keeps_githubs_rows_verbatim_and_replaces_our_row_for_the_night(tmp_path):
    (fresh,) = pm.static_analysis_rows(write_runs(tmp_path, [LANE_RUN]) / "runs.jsonl")
    ours_yesterday = dict(fresh, ts="2026-11-03T20:00:00Z", date="2026-11-03", swiftlint_strict=357)
    ours_stale_tonight = dict(fresh, ts="2026-11-04T10:00:00Z", status="red", swiftlint_strict=None)
    branch = tmp_path / "branch"
    branch.mkdir()
    # GitHub writes its rows unsorted-keys and compact; they must come back byte-identical.
    gh_text = json.dumps(GITHUB_ROW, separators=(",", ":"))
    (branch / "static_analysis.jsonl").write_text(
        gh_text + "\n" + pm.render([ours_yesterday, ours_stale_tonight]))
    out = pm.sanitized_files({"static_analysis.jsonl": [fresh]}, branch, None)["static_analysis.jsonl"]
    lines = out.splitlines()
    assert gh_text in lines, "a GitHub row is kept exactly as GitHub wrote it"
    merged = [json.loads(line) for line in lines]
    assert [(r.get("source"), r["ts"], r.get("swiftlint_strict")) for r in merged] == [
        ("m4-analysis-lane", "2026-11-03T20:00:00Z", 357),
        (None, "2026-11-04T13:17:15Z", None),
        ("m4-analysis-lane", "2026-11-04T20:10:00Z", 359),
    ], "time order; tonight's earlier red row replaced by the later run"


def test_a_poisoned_lane_row_already_on_the_branch_stops_the_publish(tmp_path):
    (fresh,) = pm.static_analysis_rows(write_runs(tmp_path, [LANE_RUN]) / "runs.jsonl")
    branch = tmp_path / "branch"
    branch.mkdir()
    bad = dict(fresh, date="2026-11-01", ts="2026-11-01T20:00:00Z", headline="/Users/rickb/Secret.swift")
    (branch / "static_analysis.jsonl").write_text(pm.render([bad]))
    with pytest.raises(pm.PrivacyError):
        pm.sanitized_files({"static_analysis.jsonl": [fresh]}, branch, None)


def test_without_a_lane_folder_the_stream_is_left_as_published(tmp_path):
    streams = pm.build_streams(tmp_path / "a", tmp_path / "b", tmp_path / "c", None, tmp_path / "no-lane")
    assert streams["static_analysis.jsonl"] is None


def test_cli_out_dir_writes_the_stream_from_the_lane_folder(tmp_path, capsys):
    lane = write_runs(tmp_path, [LANE_RUN])
    out = tmp_path / "out"
    rc = pm.main(["--out-dir", str(out), "--no-summary", "--no-events", "--analysis-dir", str(lane),
                  "--sanitizer-dir", str(tmp_path / "x"), "--coverage-dir", str(tmp_path / "x"),
                  "--adversarial-dir", str(tmp_path / "x"), "--codex-dir", str(tmp_path / "x")])
    assert rc == 0 and "static_analysis.jsonl" in capsys.readouterr().out
    (line,) = (out / "static_analysis.jsonl").read_text().splitlines()
    assert json.loads(line)["swiftlint_strict"] == 359


def test_scale_ten_years_of_nights_beside_github_rows_in_budget(tmp_path):
    import datetime as dt
    start = dt.date(2026, 11, 4)
    runs = [dict(LANE_RUN, date=(start + dt.timedelta(days=i)).isoformat(),
                 ts=f"{(start + dt.timedelta(days=i)).isoformat()}T05:30:00-05:00") for i in range(3650)]
    branch = tmp_path / "branch"
    branch.mkdir()
    (branch / "static_analysis.jsonl").write_text("".join(
        json.dumps(dict(GITHUB_ROW, ts=f"{(start + dt.timedelta(days=i)).isoformat()}T13:00:00Z"),
                   separators=(",", ":")) + "\n" for i in range(3650)))
    t0 = time.monotonic()
    rows = pm.static_analysis_rows(write_runs(tmp_path, runs) / "runs.jsonl")
    text = pm.sanitized_files({"static_analysis.jsonl": rows}, branch, None)["static_analysis.jsonl"]
    assert len(rows) == 3650 and text.count("\n") == 7300
    assert time.monotonic() - t0 < 5.0
