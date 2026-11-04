"""metrics/sanitizer.jsonl: the M4's weekly sanitizer runs, published as counts.

RED 2026-11-04: the page's "Sanitizers & static checks" card read only the
GitHub nightly's static_analysis.jsonl, whose tsan/asan/ubsan fields have been
null since that job stopped building (10/14). The real runs (weekly on the M4,
scripts/weekly_sanitizer.py) found a GRDB data race on 11/01 and an mlx-swift
UBSan report on 10/31; neither reached the page. tools/publish_metrics.py now
publishes one row per run from the M4's runs.jsonl: counts and enum words only.
"""
from __future__ import annotations

import importlib.util
import json
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("publish_metrics_sanitizer", ROOT / "tools" / "publish_metrics.py")
pm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pm)

DD = "/Users/rickb/Library/Caches/VideoScan/sanitizer-dd"
# The shapes of the two real rows (M4, 10/31 and 11/01), paths and symbols included.
ADDRESS_1031 = {
    "kind": "address", "started": "2026-10-31T07:00:00-04:00", "source": "weekly", "branch": "main",
    "sha": "30e415296", "dirty": False, "configuration": "Debug", "targets": ["app"], "subset": "full",
    "log": "/Users/rickb/Library/Logs/VideoScan/sanitizer/2026-10-31-address.log", "host_restarts": 2, "reports": 2,
    "unique_findings": [f"UndefinedBehaviorSanitizer: undefined-behavior {DD}/address/SourcePackages/checkouts/"
                        "mlx-swift/Source/Cmlx/mlx/mlx/backend/metal/device.cpp:717:21"],
    "tests": 4292, "suites": 656, "tests_outcome": "passed", "failed_tests": ["hundredThousandEntries"],
    "build_failed": False, "test_succeeded": True, "status": "findings", "exit_code": 65,
}
THREAD_1101 = {
    "kind": "thread", "started": "2026-11-01T05:00:05-05:00", "source": "weekly", "branch": "main",
    "sha": "4fc66b944", "dirty": False, "configuration": "Debug", "targets": ["app"], "subset": "full",
    "log": "/Users/rickb/Library/Logs/VideoScan/sanitizer/2026-11-01-thread.log", "host_restarts": 8, "reports": 8,
    "unique_findings": [f"ThreadSanitizer: data race ({DD}/thread/Build/Products/Debug/PackageFrameworks/"
                        "GRDB_5DC4DB053_PackageProduct.framework/GRDB:arm64+0xa32c0) in GRDB.DatabasePool.close()"],
    "tests": 10333, "suites": 1590, "tests_outcome": "passed", "failed_tests": [],
    "build_failed": False, "test_succeeded": True, "status": "findings", "exit_code": 65,
}
SECRETS = ["/Users/rickb", "mlx-swift", "device.cpp", "GRDB", "DatabasePool", "hundredThousandEntries",
           "sanitizer-dd", ".log", "main"]


def write_runs(tmp_path: Path, runs) -> Path:
    d = tmp_path / "sanitizer"
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


def test_the_two_real_runs_become_counts_per_sanitizer(tmp_path):
    rows = pm.sanitizer_rows(write_runs(tmp_path, [ADDRESS_1031, THREAD_1101]) / "runs.jsonl")
    assert rows == [
        {"schemaVersion": 1, "date": "2026-10-31", "kind": "address", "source": "weekly", "configuration": "Debug",
         "subset": "full", "status": "findings", "sha": "30e415296", "tests": 4292, "host_restarts": 2, "reports": 2,
         "asan_issues": 0, "ubsan_issues": 1, "tsan_issues": None},
        {"schemaVersion": 1, "date": "2026-11-01", "kind": "thread", "source": "weekly", "configuration": "Debug",
         "subset": "full", "status": "findings", "sha": "4fc66b944", "tests": 10333, "host_restarts": 8, "reports": 8,
         "asan_issues": None, "ubsan_issues": None, "tsan_issues": 1},
    ]
    for row in rows:
        pm.validate("sanitizer.jsonl", row)


def test_no_finding_text_path_or_test_name_leaves_the_mac(tmp_path):
    rows = pm.sanitizer_rows(write_runs(tmp_path, [ADDRESS_1031, THREAD_1101]) / "runs.jsonl")
    blob = list(strings(rows))
    for secret in SECRETS:
        assert not [s for s in blob if secret in s], secret


@pytest.mark.parametrize("status", ["skipped-busy", "build-failed", "no-tests-ran"])
def test_a_run_where_nothing_ran_is_null_never_zero(tmp_path, status):
    run = {"kind": "address", "started": "2026-11-07T07:00:00-05:00", "source": "weekly", "status": status,
           "tests": 0, "reports": 0, "unique_findings": []}
    (row,) = pm.sanitizer_rows(write_runs(tmp_path, [run]) / "runs.jsonl")
    assert (row["asan_issues"], row["ubsan_issues"], row["tsan_issues"]) == (None, None, None)
    assert row["status"] == status and row["tests"] == 0
    pm.validate("sanitizer.jsonl", row)


def test_a_clean_run_is_zero_for_what_it_measured_and_null_for_the_rest(tmp_path):
    run = {"kind": "thread", "started": "2026-11-08T05:00:00-05:00", "status": "ok", "tests": 12000,
           "reports": 0, "unique_findings": []}
    (row,) = pm.sanitizer_rows(write_runs(tmp_path, [run]) / "runs.jsonl")
    assert (row["asan_issues"], row["ubsan_issues"], row["tsan_issues"]) == (None, None, 0)
    assert row["source"] == "unknown" and row["configuration"] == "unknown" and row["sha"] is None


def test_reports_without_a_parsed_summary_still_count(tmp_path):
    run = dict(THREAD_1101, unique_findings=[], reports=3)
    (row,) = pm.sanitizer_rows(write_runs(tmp_path, [run]) / "runs.jsonl")
    assert row["tsan_issues"] == 3, "a run with reports never reads 0"


def test_one_row_per_day_kind_and_source_the_later_run_wins(tmp_path):
    first = dict(ADDRESS_1031, status="tests-failed", unique_findings=[], reports=0)
    lane = dict(ADDRESS_1031, source="analysis-lane", configuration="Release", subset="catalog")
    thread_same_day = dict(THREAD_1101, started="2026-10-31T09:00:00-04:00")
    rows = pm.sanitizer_rows(write_runs(tmp_path, [first, ADDRESS_1031, lane, thread_same_day]) / "runs.jsonl")
    assert [(r["date"], r["kind"], r["source"], r["status"]) for r in rows] == [
        ("2026-10-31", "address", "analysis-lane", "findings"),
        ("2026-10-31", "address", "weekly", "findings"),
        ("2026-10-31", "thread", "weekly", "findings"),
    ]


def test_rows_without_a_kind_or_date_are_dropped_and_no_file_is_none(tmp_path):
    rows = pm.sanitizer_rows(write_runs(tmp_path, [{"kind": "memory", "started": "2026-10-31T07:00:00"},
                                                   {"kind": "thread", "started": "yesterday"}]) / "runs.jsonl")
    assert rows == []
    assert pm.sanitizer_rows(tmp_path / "nope" / "runs.jsonl") is None
    assert pm.build_streams(tmp_path / "a", tmp_path / "b", tmp_path / "c")["sanitizer.jsonl"] is None


@pytest.mark.parametrize("mutate", [
    lambda r: r.update(tsan_issues="1"),
    lambda r: r.update(unique_findings=["ThreadSanitizer: data race in GRDB"]),
    lambda r: r.update(kind="memory"),
    lambda r: r.update(status="crashed in /Users/rickb"),
    lambda r: r.update(sha="/Users/rickb"),
    lambda r: r.pop("host_restarts"),
])
def test_the_gate_refuses_anything_off_the_allowlist(tmp_path, mutate):
    (row,) = pm.sanitizer_rows(write_runs(tmp_path, [THREAD_1101]) / "runs.jsonl")
    mutate(row)
    with pytest.raises(pm.PrivacyError):
        pm.validate("sanitizer.jsonl", row)


def test_merge_keeps_both_kinds_of_one_day_and_branch_only_rows(tmp_path):
    rows = pm.sanitizer_rows(write_runs(tmp_path, [ADDRESS_1031, THREAD_1101]) / "runs.jsonl")
    existing = tmp_path / "branch"
    existing.mkdir()
    old = dict(rows[0], date="2026-10-24", status="tests-failed", ubsan_issues=0)
    stale_same_key = dict(rows[1], tsan_issues=0, status="ok")
    (existing / "sanitizer.jsonl").write_text(pm.render([old, stale_same_key]))
    out = pm.sanitized_files({"sanitizer.jsonl": rows}, existing, None)["sanitizer.jsonl"]
    merged = [json.loads(line) for line in out.splitlines()]
    assert [(r["date"], r["kind"], r["tsan_issues"]) for r in merged] == [
        ("2026-10-24", "address", None), ("2026-10-31", "address", None), ("2026-11-01", "thread", 1)]


def test_cli_out_dir_writes_the_stream_from_the_sanitizer_folder(tmp_path, capsys):
    san = write_runs(tmp_path, [ADDRESS_1031, THREAD_1101])
    out = tmp_path / "out"
    rc = pm.main(["--out-dir", str(out), "--no-summary", "--no-events", "--sanitizer-dir", str(san),
                  "--coverage-dir", str(tmp_path / "x"), "--adversarial-dir", str(tmp_path / "x"),
                  "--codex-dir", str(tmp_path / "x")])
    assert rc == 0 and "sanitizer.jsonl" in capsys.readouterr().out
    lines = (out / "sanitizer.jsonl").read_text().splitlines()
    assert len(lines) == 2 and json.loads(lines[1])["tsan_issues"] == 1


def test_scale_a_decade_of_weekly_runs_publishes_in_budget(tmp_path):
    import datetime as dt
    import time
    start = dt.date(2026, 1, 3)
    runs = []
    for week in range(520):                     # ten years, both kinds
        d = start + dt.timedelta(weeks=week)
        runs.append(dict(ADDRESS_1031, started=f"{d.isoformat()}T07:00:00-05:00"))
        runs.append(dict(THREAD_1101, started=f"{(d + dt.timedelta(days=1)).isoformat()}T05:00:00-05:00"))
    path = write_runs(tmp_path, runs) / "runs.jsonl"
    t0 = time.monotonic()
    rows = pm.sanitizer_rows(path)
    text = pm.sanitized_files({"sanitizer.jsonl": rows}, None, None)["sanitizer.jsonl"]
    assert len(rows) == 1040 and text.count("\n") == 1040
    assert time.monotonic() - t0 < 5.0
