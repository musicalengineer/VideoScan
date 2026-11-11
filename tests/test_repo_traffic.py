"""scripts/repo_traffic.py — the daily record of clones, views, forks, stars and
referrers of the public repo (Rick 2026-11-10: "I would like to know if anyone
clones this repo"). No network: the GitHub API is a dict of canned answers."""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import repo_traffic as rt  # noqa: E402

REPO = "o/r"


def fake_api(clones=(), views=(), runs=(), forks=(), stars=(), referrers=(), fail=None):
    """An api(path) over canned data. clones/views: (day, count, uniques); runs: a day
    (a run of one job) or (day, jobs). A run's id is its position, from 1. Every path
    asked for is kept in api.calls."""
    runs = [(r, 1) if isinstance(r, str) else r for r in runs]

    def api(path, **_):
        api.calls.append(path)
        if fail and fail in path:
            raise RuntimeError(f"gh api {path}: HTTP 403")
        if "/actions/runs/" in path:
            assert path.endswith("/jobs?per_page=1"), path
            return {"total_count": runs[int(path.split("/actions/runs/")[1].split("/")[0]) - 1][1], "jobs": []}
        if path.endswith("/traffic/clones"):
            return {"clones": [dict(timestamp=d + "T00:00:00Z", count=c, uniques=u) for d, c, u in clones]}
        if path.endswith("/traffic/views"):
            return {"views": [dict(timestamp=d + "T00:00:00Z", count=c, uniques=u) for d, c, u in views]}
        if "/actions/runs" in path:
            page = int(path.split("&page=")[1].split("&")[0])
            first = (page - 1) * 100
            return {"workflow_runs": [dict(id=first + i + 1, created_at=d + "T05:00:00Z")
                                      for i, (d, _) in enumerate(runs[first: page * 100])]}
        if "/forks" in path:
            return [dict(owner=dict(login=n)) for n in forks]
        if "/stargazers" in path:
            return [dict(login=n) for n in stars]
        if path.endswith("/popular/referrers"):
            return [dict(referrer=n, count=1, uniques=1) for n in referrers]
        raise AssertionError(path)
    api.calls = []
    return api


def job_calls(api):
    return [p for p in api.calls if p.endswith("/jobs?per_page=1")]


def latest(state):
    return json.loads((state / "latest.json").read_text())


def test_yesterdays_numbers_and_our_own_ci_runs_are_in_the_line(tmp_path):
    api = fake_api(clones=[("2026-11-08", 207, 70), ("2026-11-09", 261, 83), ("2026-11-10", 12, 5)],
                   views=[("2026-11-09", 9, 4)], runs=["2026-11-09"] * 19 + ["2026-11-08"] * 49)
    line = rt.run_once(REPO, tmp_path, "2026-11-10", api)
    assert line == ("2026-11-09: 261 clones (83 unique), 9 page views (4 unique); our own CI made 19 checkouts that day")
    assert latest(tmp_path) == {"date": "2026-11-10", "headline": line, "events": [], "alert": False}
    rows = [json.loads(x) for x in (tmp_path / "days.jsonl").read_text().splitlines()]
    assert [r["day"] for r in rows] == ["2026-11-08", "2026-11-09", "2026-11-10"]
    assert rows[0] == {"day": "2026-11-08", "clones": 207, "cloners": 70, "our_ci_runs": 49, "our_ci_jobs": 49}


def test_a_day_outlives_githubs_14_days_and_a_rising_day_takes_the_larger_reading(tmp_path):
    rt.run_once(REPO, tmp_path, "2026-11-02", fake_api(clones=[("2026-11-01", 100, 30), ("2026-11-02", 5, 2)]))
    # Later: 11/01 has left GitHub's window, 11/02 finished higher, and one reading came back lower.
    rt.run_once(REPO, tmp_path, "2026-11-20", fake_api(clones=[("2026-11-02", 40, 1), ("2026-11-19", 7, 3)]))
    days = rt.load_days(tmp_path / "days.jsonl")
    assert days["2026-11-01"]["clones"] == 100                       # kept though GitHub forgot it
    assert (days["2026-11-02"]["clones"], days["2026-11-02"]["cloners"]) == (40, 2)
    assert sorted(days) == ["2026-11-01", "2026-11-02", "2026-11-19"]


def test_a_new_fork_star_or_referrer_is_named_once_and_raises_the_alert(tmp_path):
    base = dict(clones=[("2026-11-09", 1, 1)])
    rt.run_once(REPO, tmp_path, "2026-11-10", fake_api(forks=["early"], referrers=["a.example"], **base))
    first = latest(tmp_path)
    assert first["events"] == ["already there: fork by early", "already there: link from a.example"]
    assert first["alert"] is False                                   # the first run's inventory is not news

    rt.run_once(REPO, tmp_path, "2026-11-11", fake_api(forks=["early", "stranger"], stars=["fan"],
                                                       referrers=["a.example", "b.example"], **base))
    second = latest(tmp_path)
    assert second["events"] == ["NEW fork by stranger", "NEW star from fan", "NEW link from b.example"]
    assert second["alert"] is True and "NEW fork by stranger" in second["headline"]

    # The same state again is silent; a fork that vanished and came back is not news twice.
    rt.run_once(REPO, tmp_path, "2026-11-12", fake_api(forks=["early"], stars=["fan"], referrers=["a.example"], **base))
    rt.run_once(REPO, tmp_path, "2026-11-13", fake_api(forks=["early", "stranger"], stars=["fan"],
                                                       referrers=["a.example", "b.example"], **base))
    assert latest(tmp_path)["events"] == [] and latest(tmp_path)["alert"] is False


def test_a_failed_fetch_changes_nothing_on_disk_and_the_cli_still_exits_zero(tmp_path, capsys, monkeypatch):
    rt.run_once(REPO, tmp_path, "2026-11-10", fake_api(clones=[("2026-11-09", 1, 1)], forks=["early"]))
    before = {p.name: p.read_bytes() for p in tmp_path.iterdir()}
    with pytest.raises(RuntimeError):
        rt.run_once(REPO, tmp_path, "2026-11-11", fake_api(clones=[("2026-11-10", 9, 9)], forks=["x"], fail="/forks"))
    assert {p.name: p.read_bytes() for p in tmp_path.iterdir()} == before

    monkeypatch.setattr(rt, "fetch", lambda repo, api=None: (_ for _ in ()).throw(RuntimeError("gh is not installed")))
    assert rt.main(["--dir", str(tmp_path)]) == 0
    assert capsys.readouterr().out.strip() == "OUTCOME failed: RuntimeError: gh is not installed"
    assert {p.name: p.read_bytes() for p in tmp_path.iterdir()} == before


def test_gh_api_says_why_it_failed_and_never_hangs_on_stdin():
    calls = []

    def run(argv, **kw):
        calls.append((argv, kw))
        return subprocess.CompletedProcess(argv, 1, "", "gh: Must have push access\n(HTTP 403)\n")
    with pytest.raises(RuntimeError, match="Must have push access"):
        rt.gh_api("repos/o/r/traffic/clones", gh="/x/gh", run=run)
    assert calls[0][0] == ["/x/gh", "api", "repos/o/r/traffic/clones"] and calls[0][1]["stdin"] == subprocess.DEVNULL
    ok = lambda argv, **kw: subprocess.CompletedProcess(argv, 0, "not json", "")   # noqa: E731
    with pytest.raises(RuntimeError, match="not JSON"):
        rt.gh_api("x", gh="/x/gh", run=ok)


def test_no_finished_day_and_many_ci_runs_pages(tmp_path):
    assert rt.run_once(REPO, tmp_path, "2026-11-10", fake_api(clones=[("2026-11-10", 3, 1)])).startswith("no finished day")
    api = fake_api(clones=[("2026-11-09", 1, 1)], runs=["2026-11-09"] * 250)
    assert "our own CI made 250 checkouts" in rt.run_once(REPO, tmp_path / "b", "2026-11-10", api)


# --- each CI job is its own checkout, so jobs (not runs) are our share of the clones ---

def test_a_days_jobs_are_summed_across_its_runs_and_the_larger_reading_wins(tmp_path):
    # Measured 2026-10-28: one run, eleven jobs. A run is not one clone.
    api = fake_api(clones=[("2026-11-08", 97, 31), ("2026-11-09", 638, 179)],
                   runs=[("2026-11-09", 11), ("2026-11-08", 4), ("2026-11-09", 3), ("2026-11-09", 1)])
    rt.run_once(REPO, tmp_path, "2026-11-10", api)
    days = rt.load_days(tmp_path / "days.jsonl")
    assert (days["2026-11-09"]["our_ci_runs"], days["2026-11-09"]["our_ci_jobs"]) == (3, 15)
    assert (days["2026-11-08"]["our_ci_runs"], days["2026-11-08"]["our_ci_jobs"]) == (1, 4)
    assert sorted(job_calls(api)) == [f"repos/{REPO}/actions/runs/{i}/jobs?per_page=1" for i in (1, 2, 3, 4)]

    # A later, lower reading of the same day (a run deleted) does not shrink what was saved.
    rt.run_once(REPO, tmp_path, "2026-11-10", fake_api(clones=[("2026-11-09", 638, 179)], runs=[("2026-11-09", 2)]))
    assert rt.load_days(tmp_path / "days.jsonl")["2026-11-09"]["our_ci_jobs"] == 15


def test_a_settled_day_that_already_has_its_jobs_is_not_asked_for_again(tmp_path):
    rows = [{"day": "2026-11-03", "clones": 638, "cloners": 179, "our_ci_runs": 2, "our_ci_jobs": 102},   # settled
            {"day": "2026-11-04", "clones": 50, "cloners": 9, "our_ci_runs": 1},                          # never counted
            {"day": "2026-11-08", "clones": 20, "cloners": 5, "our_ci_runs": 1, "our_ci_jobs": 2}]        # 2 days ago
    (tmp_path / "days.jsonl").write_text("".join(json.dumps(r) + "\n" for r in rows))
    api = fake_api(clones=[("2026-11-03", 638, 179), ("2026-11-04", 50, 9), ("2026-11-08", 20, 5), ("2026-11-10", 1, 1)],
                   runs=[("2026-11-03", 7), ("2026-11-03", 7), ("2026-11-04", 6), ("2026-11-08", 9), ("2026-11-10", 5)])
    rt.run_once(REPO, tmp_path, "2026-11-10", api)
    # Runs 1 and 2 are 11/03's: not asked. 11/04 had no count; 11/08 and today may still be finishing.
    assert sorted(job_calls(api)) == [f"repos/{REPO}/actions/runs/{i}/jobs?per_page=1" for i in (3, 4, 5)]
    days = rt.load_days(tmp_path / "days.jsonl")
    assert [days[d]["our_ci_jobs"] for d in sorted(days)] == [102, 6, 9, 5]


def test_the_line_counts_checkouts_not_runs(tmp_path):
    api = fake_api(clones=[("2026-11-09", 638, 179)], runs=[("2026-11-09", 60), ("2026-11-09", 42)])
    line = rt.run_once(REPO, tmp_path, "2026-11-10", api)
    assert line == "2026-11-09: 638 clones (179 unique), 0 page views (0 unique); our own CI made 102 checkouts that day"
    one = {"2026-11-09": {"day": "2026-11-09", "our_ci_runs": 1, "our_ci_jobs": 1}}
    assert rt.headline(one, [], "2026-11-10").endswith("our own CI made 1 checkout that day")
    none = {"2026-11-09": {"day": "2026-11-09", "our_ci_runs": 0, "our_ci_jobs": 0}}        # a counted zero is a fact
    assert rt.headline(none, [], "2026-11-10").endswith("our own CI made 0 checkouts that day")


def test_a_day_whose_jobs_were_never_counted_does_not_say_zero(tmp_path):
    # Saved before jobs were counted, and no longer in GitHub's window: the jobs are unknown, not 0.
    (tmp_path / "days.jsonl").write_text(json.dumps({"day": "2026-10-20", "clones": 97, "cloners": 31, "our_ci_runs": 40}) + "\n")
    api = fake_api(clones=[("2026-11-10", 1, 1)])
    line = rt.run_once(REPO, tmp_path, "2026-11-10", api)
    assert line == "2026-10-20: 97 clones (31 unique), 0 page views (0 unique); our own CI ran 40 times that day"
    assert "checkout" not in line and "our_ci_jobs" not in rt.load_days(tmp_path / "days.jsonl")["2026-10-20"]
    assert job_calls(api) == []                                      # no runs today: nothing to ask
