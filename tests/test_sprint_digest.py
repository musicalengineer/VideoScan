"""scripts/sprint_digest.py — sprint progress and top bugs, never breaks the digest."""
import importlib.util
import pathlib

_SPEC = importlib.util.spec_from_file_location(
    "sprint_digest", pathlib.Path(__file__).resolve().parents[1] / "scripts" / "sprint_digest.py")
sd = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(sd)


def _fake_gh(milestones, milestone_issues, bugs):
    def gh(*args):
        if args[0] == "api":
            return milestones
        if "--milestone" in args:
            return milestone_issues
        return bugs
    return gh


def test_picks_the_earliest_due_week_and_counts_progress(monkeypatch):
    ms = [{"title": "Week of Oct 19", "due_on": "2026-10-25T23:59:59Z", "closed_issues": 0, "open_issues": 5},
          {"title": "Week of Oct 12", "due_on": "2026-10-18T23:59:59Z", "closed_issues": 3, "open_issues": 5},
          {"title": "5.2", "due_on": None, "closed_issues": 0, "open_issues": 1}]
    monkeypatch.setattr(sd, "gh", _fake_gh(ms, [{"number": 143, "title": "One delete engine"}], []))
    lines = sd.sprint_lines()
    assert lines[0].startswith('Sprint "Week of Oct 12": 3 of 8 done')
    assert lines[1] == "   • #143 One delete engine"


def test_no_week_milestone_asks_for_picks(monkeypatch):
    monkeypatch.setattr(sd, "gh", _fake_gh([], [], []))
    assert "draft next week's picks" in sd.sprint_lines()[0]


def test_top_three_bugs_by_recent_activity(monkeypatch):
    bugs = [{"number": n, "title": f"bug {n}", "updatedAt": f"2026-10-{n:02d}T00:00:00Z"} for n in (1, 5, 3, 9)]
    monkeypatch.setattr(sd, "gh", _fake_gh([], [], bugs))
    assert [l.split()[1] for l in sd.bug_lines()[1:]] == ["#9", "#5", "#3"]


def test_failure_prints_one_line_and_exits_zero(monkeypatch, capsys):
    def boom(*_):
        raise RuntimeError("gh: not logged in")
    monkeypatch.setattr(sd, "gh", boom)
    assert sd.main() == 0
    assert "sprint digest unavailable" in capsys.readouterr().out
