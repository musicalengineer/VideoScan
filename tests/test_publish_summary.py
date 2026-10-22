"""tools/publish_metrics.py — the GH #310 summary stream (metrics/summary_latest.json):
the did-not-run rule for a night, the 90-night table per Mac, the tolerant `gh`
numbers (null on failure, never a crash), the privacy gate over all of it, and
the publish path through the fake git seam."""
from __future__ import annotations

import importlib.util
import json
import os
import subprocess
from datetime import datetime, timezone
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("publish_metrics", ROOT / "tools" / "publish_metrics.py")
pm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pm)
_real_load_rota = pm.load_rota


@pytest.fixture(autouse=True)
def fixed_rota(tmp_path_factory, monkeypatch):
    """These tests are about the summary rules, not about who is on the rota
    today, so they read a fixed two-Mac rota (M4 + M5 on, M1 off). Only
    test_the_real_rota_* reads scripts/nightly_rota.json."""
    path = tmp_path_factory.mktemp("rota") / "nightly_rota.json"
    path.write_text(json.dumps({"on": {"M4": "02:00", "M5": "03:15"}, "off": {"M1": "laptop"}}))
    monkeypatch.setattr(pm, "load_rota", lambda p=None: _real_load_rota(p or path))

NOW = datetime(2026, 10, 12, 9, 0, 0, tzinfo=timezone.utc)
SECRETS = ["RicksM4", "RicksM5", "RicksM1", "/Users/rickb", "SECRET", "Donna", "VideoScan.xcscheme"]


def night(host, date, hour="07", **f):
    row = {"ts": f"{date}T{hour}:00:00Z", "source": "nightly-local", "host": host, "branch": "main",
           "passed": 0, "failed": 0, "skipped": 0, "total": 0, "status": "failed", "reason": "",
           "failed_names": ["SECRET-TEST"], "hallie_replay_reason": "SECRET /Users/rickb"}
    row.update(f)
    return row


# ---------------------------------------------------------------- the rule

@pytest.mark.parametrize("row, state", [
    # No test ran: build timeout (the M1's 90-minute cap), build error, zero tests, dirty tree.
    (night("RicksM1", "2026-10-12", status="failed", reason="build-timeout:5400s"), "did_not_run"),
    (night("RicksM4", "2026-10-12", status="failed", reason="build-rc:65"), "did_not_run"),
    (night("RicksM4", "2026-10-12", status="failed", reason="zero-tests-ran:test-rc=65"), "did_not_run"),
    (night("RicksM4", "2026-10-12", status="skipped", reason="dirty-tree:VideoScan.xcscheme"), "did_not_run"),
    # A few failed (fewer than WATCH_MAX_FAILED), the suite ran to the end: watch (Rick 2026-10-15).
    (night("RicksM4", "2026-10-12", status="failed", reason="failed-tests:2", passed=11211, failed=2, total=11275), "watch"),
    (night("RicksM5", "2026-10-12", status="ok", passed=2089, failed=1, total=2092), "watch"),
    (night("RicksM4", "2026-10-15", status="failed", reason="failed-tests:9", passed=11425, failed=9, total=11496, crashed_names=[]), "watch"),
    # crashed_names is the nightly's log heuristic (a named Swift Testing test that merely failed lands there): never the colour.
    (night("RicksM4", "2026-10-15", status="failed", reason="failed-tests:4", passed=11430, failed=4, total=11496, crashed_names=["SECRET-CRASH"]), "watch"),
    # Broken: that many failed, or a run killed part-way (exit code is evidence).
    (night("RicksM4", "2026-10-15", status="failed", reason="failed-tests:10", passed=11424, failed=10, total=11496), "red"),
    (night("RicksM5", "2026-10-12", status="failed", reason="test-timeout:7200s", passed=2089, failed=0, total=2092), "red"),
    (night("RicksM5", "2026-10-12", status="failed", reason="test-timeout:7200s", passed=2089, failed=3, total=2092), "red"),
    # Tests ran, nothing failed.
    (night("RicksM4", "2026-10-12", status="ok", passed=2631, failed=0, total=2678), "green"),
    (night("RicksM4", "2026-10-12", status="ok", reason="ui-runner-hung", passed=2631, failed=0, total=2678), "green"),
    (night("RicksM4", "2026-05-20", status=None, reason=None, passed=806, failed=0, total=806), "green"),
])
def test_did_not_run_rule(row, state):
    assert pm.classify_nightly_row(row) == state


def test_host_labels_and_reason_codes_are_sanitized():
    assert pm.host_label("RicksM4") == "M4" and pm.host_label("ricksUltra") == "Ultra"
    assert pm.host_label("Donna's MacBook") is None and pm.host_label(None) is None
    assert pm.reason_code("build-timeout:5400s") == "build-timeout:5400s"
    assert pm.reason_code("zero-tests-ran:test-rc=65") == "zero-tests-ran:test-rc=65"
    assert pm.reason_code("dirty-tree:VideoScan/VideoScan.xcodeproj/x.xcscheme,Tests/T.swift") == "dirty-tree"
    assert pm.reason_code("") is None and pm.reason_code(None) is None
    assert pm.reason_code("Donna was here") is None


# ---------------------------------------------------------------- the 90-night table

def test_nightly_summary_is_90_nights_ending_today_last_row_per_host_wins():
    rows = [
        night("RicksM4", "2026-07-15", status="ok", passed=2631, total=2678),           # first night in the window
        night("RicksM4", "2026-07-14", status="ok", passed=1, total=1),                 # the night before: out
        night("RicksM4", "2026-10-11", hour="06", status="failed", reason="failed-tests:3", passed=10, failed=3, total=13),
        night("RicksM4", "2026-10-11", hour="15", status="ok", passed=13, failed=0, total=13),   # rerun: newer evidence
        night("RicksM1", "2026-10-12", status="failed", reason="build-timeout:5400s"),
        night("RicksM5", "2026-10-12", status="failed", reason="failed-tests:1", passed=11207, failed=1, total=11275),
        night("Somebody's Mac", "2026-10-12", status="ok", passed=5, total=5),          # label not allowed: dropped
        night("RicksM4", "2026-10-13", status="ok", passed=5, total=5),                 # tomorrow: out
        {"ts": "2026-10-12T07:00:00Z", "source": "gauntlet", "host": "RicksM4", "total": 9, "status": "ok"},
    ]
    n = pm.nightly_summary(rows, "2026-10-12")
    assert n["days"] == 90 and len(n["nights"]) == 90
    assert n["nights"][0]["date"] == "2026-07-15" and n["nights"][-1]["date"] == "2026-10-12"
    # GH #360: the M1 is OFF the rota (scripts/nightly_rota.json) — its rows leave
    # the table entirely, and the summary says so instead of showing a gap.
    assert n["hosts"] == ["M4", "M5"]
    assert n["off_rota"] == ["M1"]
    assert n["nights"][0]["hosts"] == {"M4": {"state": "green", "passed": 2631, "failed": 0, "total": 2678, "reason": None}}
    assert n["nights"][-2]["hosts"]["M4"]["state"] == "green"
    last = n["nights"][-1]["hosts"]
    assert set(last) == {"M5"}
    assert last["M5"]["state"] == "watch" and last["M5"]["failed"] == 1
    # Nights with no row are present and empty, never invented.
    assert n["nights"][1]["hosts"] == {}
    # Back on the rota, the same rows give the M1 its column and its amber cell again.
    back = pm.nightly_summary(rows, "2026-10-12", rota={"on": ["M4", "M5", "M1"], "off": []})
    assert back["hosts"] == ["M4", "M5", "M1"] and back["off_rota"] == []
    assert back["nights"][-1]["hosts"]["M1"] == {"state": "did_not_run", "passed": 0, "failed": 0, "total": 0,
                                                 "reason": "build-timeout:5400s"}


def test_the_real_rota_runs_the_nightly_on_mac_studios_only():
    """GH #360 item 4 (10/21) took the M1 out; Rick 10/22: laptops are not
    nightly hosts (a closed lid slept the M5 37 times in one night), so the M5
    MacBook Pro is out too. One file says so; the publisher reads it."""
    rota = _real_load_rota(pm.NIGHTLY_ROTA)
    assert rota["on"] == ["M4"] and sorted(rota["off"]) == ["M1", "M5"]


def test_an_unreadable_rota_drops_nobody(tmp_path):
    bad = tmp_path / "rota.json"
    bad.write_text("{not json")
    assert pm.load_rota(bad) == {"on": list(pm.HOST_ORDER), "off": []}
    assert pm.load_rota(tmp_path / "missing.json")["off"] == []


def test_an_off_rota_mac_that_still_publishes_never_colours_a_night():
    """The M1's launchd job may fire once more before Rick unloads it (or its
    checkout pulls the new guard): its build-timeout row must not show up."""
    rows = [night("RicksM4", "2026-10-22", status="ok", passed=12300, total=12300),
            night("RicksM5", "2026-10-22", hour="08", status="ok", passed=12300, total=12300),
            night("RicksM1", "2026-10-22", hour="10", status="failed", reason="build-timeout:5400s")]
    n = pm.nightly_summary(rows, "2026-10-22")
    assert set(n["nights"][-1]["hosts"]) == {"M4", "M5"}
    assert all(c["state"] == "green" for c in n["nights"][-1]["hosts"].values())


def test_person_summary_is_codes_and_numbers_only():
    rows = [night("RicksM4", "2026-10-11", person_eval_status="not-configured", person_eval_readiness_pct=0,
                  person_eval_quality_score=None, person_eval_reason="SECRET path /Users/rickb")]
    assert pm.person_summary(rows) == {"status": "not-configured", "readiness_pct": 0, "quality_score": None}
    assert pm.person_summary([night("RicksM4", "2026-10-11")]) is None
    assert pm.person_summary([night("RicksM4", "2026-10-11", person_eval_status="Donna's eval")])["status"] == "other"


# ---------------------------------------------------------------- gh: tolerant

class FakeGh:
    def __init__(self, answers=None, fail=False):
        self.answers, self.fail, self.calls = answers or {}, fail, []

    def __call__(self, *args):
        self.calls.append(args)
        if self.fail:
            return None
        for key, body in self.answers.items():
            if key in " ".join(args):
                return body if isinstance(body, str) else json.dumps(body)
        return None


GH_OK = {
    "--state open --limit 1000": [{"number": i} for i in range(82)],
    "--label bug": [
        {"state": "OPEN", "createdAt": "2026-10-12T01:00:00Z", "closedAt": None},
        {"state": "OPEN", "createdAt": "2026-09-01T01:00:00Z", "closedAt": None},
        {"state": "CLOSED", "createdAt": "2026-10-08T01:00:00Z", "closedAt": "2026-10-11T01:00:00Z"},
        {"state": "CLOSED", "createdAt": "2026-08-08T01:00:00Z", "closedAt": "2026-09-11T01:00:00Z"},
    ],
    "--label High Priority": [{"number": 7}, {"number": 19}, {"number": 311}],
    "commits/main": {"sha": "b07f9da43d14abcdef0123456789abcdef012345",
                     "commit": {"committer": {"date": "2026-10-12T14:00:00Z"}, "message": "SECRET Donna"}},
    "milestones": [{"title": "Week of Oct 12", "open_issues": 8, "closed_issues": 1, "due_on": "2026-10-18T00:00:00Z"},
                   {"title": "Later", "open_issues": 2, "closed_issues": 0, "due_on": None}],
}


def test_github_numbers_from_gh():
    g = pm.github_summary(FakeGh(GH_OK), NOW)
    assert g == {"open_issues": 82, "open_bugs": 2, "bugs_opened_7d": 2, "bugs_closed_7d": 1, "high_priority_open": 3,
                 "main_sha": "b07f9da43d14", "main_date": "2026-10-12"}
    assert pm.sprint_summary(FakeGh(GH_OK)) == {"title": "Week of Oct 12", "open": 8, "closed": 1, "due": "2026-10-18"}


def test_gh_failure_means_nulls_not_an_exception():
    g = pm.github_summary(FakeGh(fail=True), NOW)
    assert g == {"open_issues": None, "open_bugs": None, "bugs_opened_7d": None, "bugs_closed_7d": None,
                 "high_priority_open": None, "main_sha": None, "main_date": None}
    assert pm.sprint_summary(FakeGh(fail=True)) is None
    # Garbage from gh is a failure too.
    assert pm.github_summary(FakeGh({"--label bug": "not json", "--state open": "[1,"}), NOW)["open_bugs"] is None
    # A real gh binary that does not exist: same answer, no crash.
    assert pm.Gh(binary="/nonexistent/gh")("issue", "list") is None


def test_github_daily_row_adds_the_one_day_counts_and_leaves_the_summary_keys_alone():
    nums = pm.github_numbers(FakeGh(GH_OK), NOW)
    # Opened 10-12T01 is within a day of NOW (10-12T09); the 10-11T01 close is 32 h old.
    assert nums["bugs_opened_1d"] == 1 and nums["bugs_closed_1d"] == 0
    row = pm.github_daily_row(nums, NOW)
    assert row == {"ts": "2026-10-12T09:00:00Z", "open_issues": 82, "open_bugs": 2, "bugs_opened_7d": 2,
                   "bugs_closed_7d": 1, "bugs_opened_1d": 1, "bugs_closed_1d": 0, "high_priority_open": 3}
    pm.validate("github_daily.jsonl", row)
    assert set(pm.github_summary(FakeGh(GH_OK), NOW)) == {"open_issues", "open_bugs", "bugs_opened_7d",
                                                            "bugs_closed_7d", "high_priority_open", "main_sha", "main_date"}


def test_github_daily_row_is_absent_not_null_when_gh_fails(tmp_path):
    assert pm.github_daily_row(pm.github_numbers(FakeGh(fail=True), NOW), NOW) is None
    # The bug list failing drops the day; the tip of main failing does not (the row carries no SHA).
    no_bugs = FakeGh({k: v for k, v in GH_OK.items() if k != "--label bug"})
    assert pm.github_daily_row(pm.github_numbers(no_bugs, NOW), NOW) is None
    no_tip = FakeGh({k: v for k, v in GH_OK.items() if k != "commits/main"})
    assert pm.github_daily_row(pm.github_numbers(no_tip, NOW), NOW)["open_bugs"] == 2
    b = pm.summary_builder(gh=FakeGh(fail=True), git=TagGit([]), now=NOW, pbxproj=tmp_path / "missing")
    assert b.daily_rows() is None
    ok = pm.summary_builder(gh=FakeGh(GH_OK), git=TagGit([]), now=NOW, pbxproj=tmp_path / "missing")
    assert ok.daily_rows() == [pm.github_daily_row(pm.github_numbers(FakeGh(GH_OK), NOW), NOW)]


@pytest.mark.parametrize("mutate", [
    lambda r: r.__setitem__("open_bugs", None),                   # a null never enters a trend
    lambda r: r.__setitem__("bugs_closed_1d", -1),
    lambda r: r.__setitem__("ts", "2026-10-12"),                  # a date is not a timestamp
    lambda r: r.__setitem__("main_sha", "b07f9da43d14"),          # no extra keys
    lambda r: r.pop("bugs_opened_1d"),
    lambda r: r.__setitem__("high_priority_open", None),
    lambda r: r.__setitem__("high_priority_open", "3"),
])
def test_github_daily_gate_refuses_nulls_extras_and_bad_shapes(mutate):
    row = pm.github_daily_row(pm.github_numbers(FakeGh(GH_OK), NOW), NOW)
    mutate(row)
    with pytest.raises(pm.PrivacyError):
        pm.validate("github_daily.jsonl", row)


def test_high_priority_open_is_counted_by_exact_label_null_on_failure_and_rides_the_daily_row(tmp_path):
    # One extra gh call, open issues only, the exact label name "High Priority" (not a slug or a glob).
    gh = FakeGh(GH_OK)
    nums = pm.github_numbers(gh, NOW)
    assert nums["high_priority_open"] == 3
    high_calls = [c for c in gh.calls if "--label" in c and c[c.index("--label") + 1] == pm.HIGH_PRIORITY_LABEL]
    assert len(high_calls) == 1 and pm.HIGH_PRIORITY_LABEL == "High Priority"
    assert ("--state", "open") == tuple(high_calls[0][high_calls[0].index("--state"):][:2])
    # The summary object carries it (int or null), validates either way, and keeps every existing key.
    assert pm.github_summary(gh, NOW)["high_priority_open"] == 3
    assert pm.validate("summary_latest.json", pm.summary_builder(gh=FakeGh(GH_OK), git=TagGit([]), now=NOW,
                                                                 pbxproj=tmp_path / "missing")(tmp_path)) is None
    # Only that call failing: the summary says null, every other number survives, and the day is skipped
    # in the trend (never a null row) exactly like the other counts.
    no_high = FakeGh({k: v for k, v in GH_OK.items() if k != "--label High Priority"})
    g = pm.github_summary(no_high, NOW)
    assert g["high_priority_open"] is None and g["open_bugs"] == 2 and g["open_issues"] == 82
    assert pm.github_daily_row(pm.github_numbers(no_high, NOW), NOW) is None
    assert pm.summary_builder(gh=no_high, git=TagGit([]), now=NOW, pbxproj=tmp_path / "missing").daily_rows() is None
    # Garbage is a failure too, not a count.
    assert pm.github_summary(FakeGh({"--label High Priority": "{not json"}), NOW)["high_priority_open"] is None
    # The daily row carries it as an int and the gate accepts it.
    row = pm.github_daily_row(nums, NOW)
    assert row["high_priority_open"] == 3
    pm.validate("github_daily.jsonl", row)
    # Rows published before 2026-10-12 have no such key; the gate re-validates them on
    # every publish, so absence stays legal (present-and-null does not: see the gate test).
    old = {k: v for k, v in row.items() if k != "high_priority_open"}
    pm.validate("github_daily.jsonl", old)
    with pytest.raises(pm.PrivacyError):
        pm.validate("github_daily.jsonl", {k: v for k, v in row.items() if k != "open_bugs"})


def test_sprint_with_an_unprintable_title_is_skipped_not_published():
    gh = FakeGh({"milestones": [{"title": "Donna's\nsecret", "open_issues": 1, "closed_issues": 0, "due_on": None},
                                {"title": "Week of Oct 19", "open_issues": 3, "closed_issues": 2, "due_on": None}]})
    assert pm.sprint_summary(gh) == {"title": "Week of Oct 19", "open": 3, "closed": 2, "due": None}


# ---------------------------------------------------------------- version + tags

PBXPROJ = """
		AAA /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CURRENT_PROJECT_VERSION = 1;
				MARKETING_VERSION = 2.0;
				PRODUCT_BUNDLE_IDENTIFIER = "Rick-Breen.VideoScanTests";
			};
			name = Release;
		};
		BBB /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CURRENT_PROJECT_VERSION = 7;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
				);
				MARKETING_VERSION = 5.1;
				PRODUCT_BUNDLE_IDENTIFIER = "Rick-Breen.VideoScan";
			};
			name = Debug;
		};
"""


def test_app_version_reads_the_app_target(tmp_path):
    p = tmp_path / "project.pbxproj"
    p.write_text(PBXPROJ)
    assert pm.app_version(p) == {"marketing": "5.1", "build": "7"}
    assert pm.app_version(tmp_path / "missing.pbxproj") is None
    assert pm.app_version(ROOT / "VideoScan" / "VideoScan.xcodeproj" / "project.pbxproj") is not None


class TagGit:
    def __init__(self, lines):
        self.lines = lines

    def __call__(self, path, *args, check=True):
        from types import SimpleNamespace
        return SimpleNamespace(returncode=0, stdout="\n".join(self.lines) + "\n", stderr="")


def test_demo_tags_keep_only_demo_names_with_dates(tmp_path):
    tags = pm.demo_tags(TagGit(["2026-10-09|demo-2026-10-10", "2026-09-03|demo-2026-09-04",
                                "2026-10-01|archive/fix/Donna", "garbage", "2026-10-08|demo-stable-2026-10-08"]), tmp_path)
    assert tags == [{"date": "2026-09-03", "name": "demo-2026-09-04"},
                    {"date": "2026-10-08", "name": "demo-stable-2026-10-08"},
                    {"date": "2026-10-09", "name": "demo-2026-10-10"}]


# ---------------------------------------------------------------- the whole object

@pytest.fixture
def metrics_dir(tmp_path):
    d = tmp_path / "metrics"
    d.mkdir()
    rows = [night("RicksM4", "2026-10-11", status="ok", passed=11000, total=11060,
                  person_eval_status="not-configured", person_eval_readiness_pct=0, person_eval_quality_score=None),
            night("RicksM5", "2026-10-12", status="failed", reason="build-timeout:5400s"),
            night("RicksM1", "2026-10-12", status="failed", reason="build-timeout:5400s"),   # off the rota
            night("RicksM4", "2026-10-12", status="failed", reason="failed-tests:2", passed=11211, failed=2, total=11275)]
    (d / "testdriver.jsonl").write_text("".join(json.dumps(r) + "\n" for r in rows) + "not json\n")
    (d / "history.jsonl").write_text("{}\n")
    return d


def every_string(obj):
    if isinstance(obj, str):
        yield obj
    elif isinstance(obj, dict):
        for k, v in obj.items():
            yield k
            yield from every_string(v)
    elif isinstance(obj, list):
        for v in obj:
            yield from every_string(v)


def test_summary_object_validates_and_leaks_nothing(metrics_dir, tmp_path):
    p = tmp_path / "project.pbxproj"
    p.write_text(PBXPROJ)
    gh = FakeGh(GH_OK)
    build = pm.summary_builder(gh=gh, git=TagGit(["2026-10-09|demo-2026-10-10"]), now=NOW, pbxproj=p)
    s = build(metrics_dir)
    pm.validate("summary_latest.json", s)
    assert s["generated"] == "2026-10-12T09:00:00Z"
    assert s["version"] == {"marketing": "5.1", "build": "7"}
    assert s["github"]["open_bugs"] == 2 and s["sprint"]["title"] == "Week of Oct 12"
    assert s["tags"] == [{"date": "2026-10-09", "name": "demo-2026-10-10"}]
    assert s["person"]["status"] == "not-configured"
    assert s["nightly"]["hosts"] == ["M4", "M5"] and s["nightly"]["off_rota"] == ["M1"]
    assert s["nightly"]["nights"][-1]["hosts"]["M5"]["state"] == "did_not_run"
    assert "M1" not in s["nightly"]["nights"][-1]["hosts"]
    assert s["nightly"]["nights"][-1]["hosts"]["M4"]["state"] == "watch"   # 2 failed of 11,275: a few
    assert s["nightly"]["nights"][-2]["hosts"]["M4"]["state"] == "green"
    blob = " ".join(every_string(s))
    for secret in SECRETS:
        assert secret not in blob, secret
    # GitHub is asked once per builder, however many times the nights are rebuilt:
    # open issues, bugs, High Priority, tip of main, milestones.
    build(metrics_dir)
    assert len(gh.calls) == 5


def test_summary_with_everything_failing_is_still_valid(tmp_path):
    empty = tmp_path / "metrics"
    empty.mkdir()
    build = pm.summary_builder(gh=FakeGh(fail=True), git=TagGit([]), now=NOW, pbxproj=tmp_path / "missing")
    s = build(empty)
    pm.validate("summary_latest.json", s)
    assert s["version"] is None and s["sprint"] is None and s["person"] is None and s["tags"] == []
    assert all(v is None for v in s["github"].values())
    assert s["nightly"]["hosts"] == [] and len(s["nightly"]["nights"]) == 90
    assert all(n["hosts"] == {} for n in s["nightly"]["nights"])


@pytest.mark.parametrize("mutate", [
    lambda s: s["nightly"]["nights"][0]["hosts"].__setitem__("RicksM4", {"state": "green", "passed": 1, "failed": 0, "total": 1, "reason": None}),
    lambda s: s["nightly"]["nights"][0]["hosts"].__setitem__("M4", {"state": "green", "passed": 1, "failed": 0, "total": 1, "reason": "dirty-tree:/Users/rickb/x"}),
    lambda s: s["nightly"]["nights"][0]["hosts"].__setitem__("M4", {"state": "amber", "passed": 1, "failed": 0, "total": 1, "reason": None}),
    lambda s: s["tags"].append({"date": "2026-10-01", "name": "archive/fix/Donna"}),
    lambda s: s.__setitem__("sprint", {"title": "Donna\nsecret", "open": 1, "closed": 0, "due": None}),
    lambda s: s["github"].__setitem__("main_sha", "SECRET"),
    lambda s: s.__setitem__("extra", 1),
])
def test_summary_gate_refuses_anything_off_the_allowlist(mutate, tmp_path):
    empty = tmp_path / "metrics"
    empty.mkdir()
    s = pm.summary_builder(gh=FakeGh(fail=True), git=TagGit([]), now=NOW, pbxproj=tmp_path / "missing")(empty)
    mutate(s)
    with pytest.raises(pm.PrivacyError):
        pm.validate("summary_latest.json", s)


# ---------------------------------------------------------------- publish path

def test_publish_writes_summary_latest_beside_the_other_streams(tmp_path):
    from test_publish_metrics import FakeGit, FOLDERS
    repo = tmp_path / "repo"
    repo.mkdir()
    wt = tmp_path / "wt"
    td = json.dumps(night("RicksM5", "2026-10-12", status="failed", reason="build-timeout:5400s")) + "\n"
    git = FakeGit(repo, remote={"history.jsonl": "{}\n", "testdriver.jsonl": td})
    build = pm.summary_builder(gh=FakeGh(GH_OK), git=TagGit([]), now=NOW, pbxproj=tmp_path / "missing")
    assert pm.publish({"coverage.jsonl": []}, repo=repo, wt=wt, git=git, folders=FOLDERS,
                      say=lambda m: None, summary=build) == "pushed"
    assert set(git.remote) == {"history.jsonl", "testdriver.jsonl", "coverage.jsonl", "summary_latest.json"}
    s = json.loads(git.remote["summary_latest.json"])
    assert s["nightly"]["nights"][-1]["hosts"] == {"M5": {"state": "did_not_run", "passed": 0, "failed": 0, "total": 0,
                                                          "reason": "build-timeout:5400s"}}
    assert s["github"]["open_bugs"] == 2
    assert "RicksM5" not in git.remote["summary_latest.json"]
    # Same inputs again: the summary is byte-identical (fixed `now`), so nothing is committed.
    assert pm.publish({"coverage.jsonl": []}, repo=repo, wt=wt, git=git, folders=FOLDERS,
                      say=lambda m: None, summary=build) == "unchanged"


def daily_row(ts, open_bugs, **f):
    row = {"ts": ts, "open_issues": 80, "open_bugs": open_bugs, "bugs_opened_7d": 1, "bugs_closed_7d": 1,
           "bugs_opened_1d": 0, "bugs_closed_1d": 0}
    row.update(f)
    return row


def test_publish_writes_one_daily_row_per_day_and_rewrites_the_same_day(tmp_path):
    from test_publish_metrics import FakeGit, FOLDERS
    repo = tmp_path / "repo"
    repo.mkdir()
    wt = tmp_path / "wt"
    published = [daily_row("2026-10-10T09:00:00Z", 5), daily_row("2026-10-11T09:00:00Z", 4),
                 daily_row("2026-10-12T04:00:00Z", 3, bugs_opened_1d=2)]           # today's 4 AM row
    git = FakeGit(repo, remote={"history.jsonl": "{}\n", "testdriver.jsonl": "",
                                "github_daily.jsonl": pm.render(published)})
    build = pm.summary_builder(gh=FakeGh(GH_OK), git=TagGit([]), now=NOW, pbxproj=tmp_path / "missing")
    assert pm.publish({}, repo=repo, wt=wt, git=git, folders=FOLDERS, say=lambda m: None,
                      summary=build, daily=build.daily_rows) == "pushed"
    rows = [json.loads(line) for line in git.remote["github_daily.jsonl"].splitlines()]
    assert [r["ts"] for r in rows] == ["2026-10-10T09:00:00Z", "2026-10-11T09:00:00Z", "2026-10-12T09:00:00Z"]
    assert rows[:2] == published[:2]                            # earlier days kept verbatim (no high_priority_open)
    assert rows[2] == {"ts": "2026-10-12T09:00:00Z", "open_issues": 82, "open_bugs": 2, "bugs_opened_7d": 2,
                       "bugs_closed_7d": 1, "bugs_opened_1d": 1, "bugs_closed_1d": 0,
                       "high_priority_open": 3}                                      # today rewritten, not appended
    assert "summary_latest.json" in git.remote and git.remote["history.jsonl"] == "{}\n"
    # gh failed: the stream is left exactly as published — no row, no nulls, nothing committed for it.
    before = git.remote["github_daily.jsonl"]
    failing = pm.summary_builder(gh=FakeGh(fail=True), git=TagGit([]),
                                 now=NOW.replace(day=13), pbxproj=tmp_path / "missing")
    pm.publish({}, repo=repo, wt=wt, git=git, folders=FOLDERS, say=lambda m: None,
               summary=failing, daily=failing.daily_rows)
    assert git.remote["github_daily.jsonl"] == before
    assert json.loads(git.remote["summary_latest.json"])["github"]["open_bugs"] is None


def test_daily_gate_refuses_a_published_null_before_anything_is_written(tmp_path):
    from test_publish_metrics import FakeGit, FOLDERS
    repo = tmp_path / "repo"
    repo.mkdir()
    poisoned = pm.render([daily_row("2026-10-10T09:00:00Z", None)])
    git = FakeGit(repo, remote={"history.jsonl": "{}\n", "testdriver.jsonl": "", "github_daily.jsonl": poisoned})
    build = pm.summary_builder(gh=FakeGh(GH_OK), git=TagGit([]), now=NOW, pbxproj=tmp_path / "missing")
    with pytest.raises(pm.PrivacyError):
        pm.publish({}, repo=repo, wt=tmp_path / "wt", git=git, folders=FOLDERS, say=lambda m: None,
                   summary=build, daily=build.daily_rows)
    assert git.pushes == 0


def run_cli(*args, env=None):
    e = dict(os.environ, **(env or {}))
    return subprocess.run(["python3", str(ROOT / "tools" / "publish_metrics.py"), *args],
                          capture_output=True, text=True, env=e, timeout=60, stdin=subprocess.DEVNULL)


def test_cli_out_dir_with_metrics_dir_writes_summary_with_nulls_when_gh_is_missing(metrics_dir, tmp_path):
    out = tmp_path / "out"
    r = run_cli("--out-dir", str(out), "--metrics-dir", str(metrics_dir), "--coverage-dir", "/nonexistent",
                "--adversarial-dir", "/nonexistent", "--codex-dir", "/nonexistent",
                env={"VIDEOSCAN_GH_BIN": "/nonexistent/gh"})
    assert r.returncode == 0, r.stdout + r.stderr
    assert "summary_latest.json" in r.stdout
    s = json.loads((out / "summary_latest.json").read_text())
    assert s["github"]["open_bugs"] is None and s["sprint"] is None
    # The CLI uses the real clock; the fixture's rows are dated 2026-10-12, so
    # find that night by date (the last cell is "today", empty after 10/12).
    night_1012 = next(x for x in s["nightly"]["nights"] if x["date"] == "2026-10-12")
    # The CLI reads the REAL rota (Mac Studios only since 10/22): the fixture's
    # M5 and M1 rows are off-rota, so they colour nothing and are named instead.
    assert "M5" not in night_1012["hosts"] and "M1" not in night_1012["hosts"]
    assert sorted(s["nightly"]["off_rota"]) == ["M1", "M5"]
    assert s["version"] is not None                          # the repo's own pbxproj
    assert not (out / "github_daily.jsonl").exists()         # gh failed: no daily row, never a null row
    assert "github_daily" not in r.stdout
    for secret in SECRETS:
        assert secret not in (out / "summary_latest.json").read_text(), secret


def test_cli_no_summary_and_no_metrics_dir_produce_no_summary(metrics_dir, tmp_path):
    out = tmp_path / "out"
    r = run_cli("--out-dir", str(out), "--no-summary", "--metrics-dir", str(metrics_dir),
                "--coverage-dir", "/nonexistent", "--adversarial-dir", "/nonexistent", "--codex-dir", "/nonexistent")
    assert r.returncode == 0 and not out.exists() or not (out / "summary_latest.json").exists()
    out2 = tmp_path / "out2"
    r = run_cli("--out-dir", str(out2), "--coverage-dir", "/nonexistent",
                "--adversarial-dir", "/nonexistent", "--codex-dir", "/nonexistent")
    assert r.returncode == 0 and not (out2 / "summary_latest.json").exists()
