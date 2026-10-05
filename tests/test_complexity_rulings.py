"""Rick's rulings, 2026-10-05 (complexity debt):
1. Only Rick can sweep debt under the rug: every gate override, and every
   NEW / WORSE offender, is a 🔴 item in the morning digest (override: with
   function, CCN, lines, reason, commit, author).
2. The 2 AM nightly commits the shrunk baseline itself: removals only,
   verified before the commit; anything else is refused and reported 🔴.
Synthetic data and a fake git; nothing here scans the repo or runs git."""
from __future__ import annotations

import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

import complexity_baseline_nightly as nightly  # noqa: E402
import complexity_metrics as cm  # noqa: E402

NOW = datetime(2026, 10, 6, 6, 0, tzinfo=timezone.utc)


# ---------------------------------------------------------------- ruling 1

def test_override_is_red_with_function_size_reason_commit_and_author():
    records = [{"ts": "2026-10-06T01:00:00Z", "reason": "ship the demo, split Tuesday", "author": "Rick Breen",
                "commit": "abc1234", "functions": {"VideoScan/VideoScan/Catalog/Big.swift::Big.run": {"ccn": 35, "nloc": 120}},
                "disables": {"VideoScan/VideoScan/Catalog/Big.swift|cyclomatic_complexity": 1}}]
    recent = cm.recent_overrides(records, NOW)
    lines = cm.alert_lines({"new": [], "worse": [], "fixed": [], "overrides_recent": recent})
    text = "\n".join(lines)
    assert lines[0].startswith("🔴") and "OVERRIDDEN" in lines[0]
    for want in ["Rick Breen", "abc1234", "ship the demo, split Tuesday", "Big.run", "CCN  35", "NLOC  120",
                 "swiftlint:disable cyclomatic_complexity"]:
        assert want in text, want


def test_old_overrides_drop_out_of_the_digest():
    records = [{"ts": "2026-10-01T01:00:00Z", "reason": "old", "functions": {}}]
    assert cm.recent_overrides(records, NOW) == []


def test_every_new_or_worse_offender_is_red_for_ricks_decision():
    debt = {"ts": "2026-10-06T05:00:00Z", "fixed": [],
            "new": [{"file": "a.swift", "function": "A.f", "ccn": 16, "nloc": 10}],
            "worse": []}
    lines = cm.alert_lines(debt)
    assert lines[0].startswith("🔴") and "Rick's decision" in lines[0]
    assert all(not l.startswith("🟡") for l in lines)


def test_gate_records_the_author(tmp_path):
    import pytest
    pytest.importorskip("lizard")
    import complexity_gate as gate
    body = "\n".join(f"        if x == {i} {{ r += {i} }}" for i in range(34))
    src = f"struct S {{\n    func big(x: Int) -> Int {{\n        var r = 0\n{body}\n        return r\n    }}\n}}\n"
    base = tmp_path / "b.json"
    cm.write_baseline(str(base), {}, {})
    ov = tmp_path / "ov.jsonl"
    lines = []
    assert gate.run_gate({"VideoScan/VideoScan/X/S.swift": src}, str(base), str(ov), override_reason="why",
                         out=lines.append, author="Rick Breen") == 0
    rec = json.loads(ov.read_text())
    assert rec["author"] == "Rick Breen" and "@" not in json.dumps(rec)
    assert any("Rick" in l and "🔴" in l for l in lines)


# ---------------------------------------------------------------- ruling 2: pure logic

def test_verify_removals_only_refuses_adds_and_raises():
    old = {"a::f": {"ccn": 20, "nloc": 50}, "a::g": {"ccn": 18, "nloc": 90}}
    assert cm.verify_removals_only(old, {"a::f": {"ccn": 19, "nloc": 50}}, {"x|file_length": 1}, {}) == []
    problems = cm.verify_removals_only(old, {"a::f": {"ccn": 21, "nloc": 50}, "a::h": {"ccn": 40, "nloc": 1}},
                                       {"x|file_length": 1}, {"x|file_length": 2, "y|file_length": 1})
    assert any("adds a::h" in p for p in problems)
    assert any("raises ccn of a::f" in p for p in problems)
    assert any("adds disable y|file_length" in p for p in problems)
    assert any("raises disable x|file_length" in p for p in problems)


def test_strict_shrink_never_adds_a_moved_key():
    baseline = {"old.swift::T.big": {"ccn": 30, "nloc": 100}, "a.swift::gone": {"ccn": 20, "nloc": 10}}
    moved = cm.Func(file="new.swift", name="big", long_name="big", ccn=28, nloc=90, start_line=1, lang="swift",
                    key="new.swift::U.big")
    result = cm.ratchet([moved], baseline)
    shrunk = cm.strict_shrink(baseline, result)
    assert shrunk == {"old.swift::T.big": {"ccn": 28, "nloc": 90}}
    assert cm.verify_removals_only(baseline, shrunk, {}, {}) == []


def test_disable_allowance_follows_the_rule_not_the_file():
    base = {"a.swift|cyclomatic_complexity": 1}
    # Moved to b.swift: same total, nothing shrinks.
    assert cm.shrink_disables(base, {"b.swift|cyclomatic_complexity": 1}) == base
    # Really removed: the allowance goes.
    assert cm.shrink_disables(base, {}) == {}
    base = {"a.swift|file_length": 2, "b.swift|file_length": 1}
    assert cm.shrink_disables(base, {"a.swift|file_length": 1, "b.swift|file_length": 1}) == \
        {"a.swift|file_length": 1, "b.swift|file_length": 1}


# ---------------------------------------------------------------- ruling 2: the nightly committer

class FakeGit:
    """Records calls; answers from a small script. `old` is origin/main's baseline."""

    def __init__(self, old: dict, dirty: str = "", push_ok=(True,), commit_ok=True):
        self.old, self.dirty, self.push_ok, self.commit_ok = old, dirty, list(push_ok), commit_ok
        self.calls = []

    def __call__(self, *args, check=True):
        self.calls.append(args)
        cmd = args[2] if args[0] == "-C" else args[0]
        out, rc = "", 0
        if cmd == "status":
            out = self.dirty
        elif cmd == "show":
            out = json.dumps(self.old)
        elif cmd == "push":
            rc = 0 if (self.push_ok.pop(0) if self.push_ok else False) else 1
        elif cmd == "rev-parse":
            out = "def5678\n"
        elif "commit" in args and not self.commit_ok:
            rc = 1
        return subprocess.CompletedProcess(args, rc, out, "")

    def ran(self, word):
        return [c for c in self.calls if word in c]


def worktree(tmp_path, entries, disables=None):
    wt = tmp_path / "wt"
    (wt / "ci" / "baselines").mkdir(parents=True)
    (wt / ".git").write_text("gitdir: elsewhere\n")
    cm.write_baseline(str(wt / nightly.BASELINE_REL), entries, disables or {})
    data = json.loads((wt / nightly.BASELINE_REL).read_text())
    return str(wt), data


OLD = {"a::f": {"ccn": 20, "nloc": 50}, "a::gone": {"ccn": 18, "nloc": 90}}


def plan_of(entries, problems=(), changed=True, disables=None):
    return lambda wt, path: {"changed": changed, "problems": list(problems), "entries": entries,
                             "disables": disables or {}, "fixed": ["a::gone"] if changed else [],
                             "before": 2, "after": len(entries)}


def test_nightly_commits_a_pure_shrink_and_pushes_without_force(tmp_path):
    wt, old = worktree(tmp_path, OLD)
    git = FakeGit(old)
    status = nightly.run(str(tmp_path / "repo"), wt, git, plan_of({"a::f": {"ccn": 19, "nloc": 50}}), NOW, gate_check=lambda wt: 0)
    assert status["outcome"] == "committed" and status["commit"] == "def5678"
    push = git.ran("push")[0]
    assert "HEAD:refs/heads/main" in push and "--force" not in push and "-f" not in push
    assert json.loads((Path(wt) / nightly.BASELINE_REL).read_text())["entries"] == {"a::f": {"ccn": 19, "nloc": 50}}
    assert nightly.alert_lines(status)[0].startswith("✅")


def test_nightly_refuses_when_the_plan_is_not_removals_only(tmp_path):
    wt, old = worktree(tmp_path, OLD)
    git = FakeGit(old)
    status = nightly.run("repo", wt, git, plan_of({}, problems=["adds a::new"]), NOW, gate_check=lambda wt: 0)
    assert status["outcome"] == "refused" and "adds a::new" in status["detail"]
    assert not git.ran("commit") and not git.ran("push")
    assert nightly.alert_lines(status)[0].startswith("🔴")


def test_nightly_double_checks_the_written_file_against_origin_main(tmp_path):
    # A plan that claims to be clean but raises a value is caught on disk.
    wt, old = worktree(tmp_path, OLD)
    git = FakeGit(old)
    status = nightly.run("repo", wt, git, plan_of({"a::f": {"ccn": 25, "nloc": 50}}), NOW, gate_check=lambda wt: 0)
    assert status["outcome"] == "refused" and "raises ccn of a::f" in status["detail"]
    assert not git.ran("commit") and not git.ran("push")


def test_nightly_never_touches_a_dirty_worktree(tmp_path):
    wt, old = worktree(tmp_path, OLD)
    git = FakeGit(old, dirty=" M ci/baselines/complexity_debt.json\n")
    status = nightly.run("repo", wt, git, plan_of({"a::f": {"ccn": 19, "nloc": 50}}), NOW, gate_check=lambda wt: 0)
    assert status["outcome"] == "failed" and "dirty" in status["detail"]
    assert not git.ran("reset") and not git.ran("checkout") and not git.ran("commit")


def test_nightly_unchanged_is_silent(tmp_path):
    wt, old = worktree(tmp_path, OLD)
    git = FakeGit(old)
    status = nightly.run("repo", wt, git, plan_of(OLD, changed=False), NOW, gate_check=lambda wt: 0)
    assert status["outcome"] == "unchanged" and nightly.alert_lines(status) == []
    assert not git.ran("commit")


def test_nightly_refuses_a_shrink_that_would_turn_ci_gate_red(tmp_path):
    # QA round 2: removals-only is not enough; the whole-tree gate must pass
    # against the NEW baseline before anything is committed.
    wt, old = worktree(tmp_path, OLD)
    git = FakeGit(old)
    seen = []

    def red_gate(w):
        seen.append(json.loads((Path(w) / nightly.BASELINE_REL).read_text())["entries"])
        return 1

    status = nightly.run("repo", wt, git, plan_of({"a::f": {"ccn": 19, "nloc": 50}}), NOW, gate_check=red_gate)
    assert seen == [{"a::f": {"ccn": 19, "nloc": 50}}]                  # it checked the NEW file
    assert status["outcome"] == "refused" and "gate red" in status["detail"]
    assert not git.ran("commit") and not git.ran("push")
    assert any(BASE in c for c in git.ran("checkout") for BASE in [nightly.BASELINE_REL])  # file restored
    assert nightly.alert_lines(status)[0].startswith("🔴")


def test_nightly_retries_once_after_a_rejected_push_then_reports_red(tmp_path):
    wt, old = worktree(tmp_path, OLD)
    git = FakeGit(old, push_ok=(False, False))
    status = nightly.run("repo", wt, git, plan_of({"a::f": {"ccn": 19, "nloc": 50}}), NOW, gate_check=lambda wt: 0)
    assert status["outcome"] == "failed" and "rejected" in status["detail"]
    assert len(git.ran("push")) == 2
    assert nightly.alert_lines(status)[0].startswith("🔴")
