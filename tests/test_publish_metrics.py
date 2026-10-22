"""tools/publish_metrics.py: the privacy gate, the per-stream builders, and the git
path (through a fake git seam: no network, no real repo, no real metrics branch)."""
from __future__ import annotations

import importlib.util
import json
import os
import shutil
import subprocess
from pathlib import Path
from types import SimpleNamespace

import pytest

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("publish_metrics", ROOT / "tools" / "publish_metrics.py")
pm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pm)

FOLDERS = {"Core", "(app root)", "Hallie", "People", "Archive"}

# Planted in every free-text field of every input. None may reach the output.
SECRETS = ["Donna", "Matthew Rice", "People/DonnaSecret.swift", "VideoScan/VideoScan/People",
           "SECRET-TITLE", "secretTestName", "RicksM4", "/Users/rickb", "abc1234def"]


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


# ---------------------------------------------------------------- fixtures

def write_coverage(cov_dir: Path, date: str, folders: dict, app_status="ok") -> None:
    cov_dir.mkdir(parents=True, exist_ok=True)
    (cov_dir / f"coverage-{date}.json").write_text(json.dumps({
        "meta": {"date": date, "commit": "abc1234def", "host": "RicksM4",
                 "app_status": app_status, "core_status": "exit 1"},
        "folders": folders}))


def folder(cov, exe, lcov, lexe, files=3, zero=()):
    return {"covered": cov, "executable": exe, "logic_covered": lcov, "logic_executable": lexe,
            "files": files, "zero_files": list(zero), "pct": 0, "logic_pct": 0}


def write_ledger(adv_dir: Path) -> None:
    adv_dir.mkdir(parents=True, exist_ok=True)
    secret = " ".join(SECRETS)
    events = [
        {"event": "run", "date": "2026-10-01", "status": "failed", "failure": secret, "costUsd": None,
         "filesInScope": 48, "filesReviewed": 26, "findings": {"P0": 0, "P1": 0, "P2": 0, "P3": 0},
         "range": secret, "doc": "/Users/rickb/People/x.md", "notReviewed": [secret], "head": "abc1234def"},
        {"event": "run", "date": "2026-10-01", "status": "findings", "failure": None, "costUsd": 8.012,
         "filesInScope": 25, "filesReviewed": 25, "findings": {"P0": 0, "P1": 2, "P2": 1, "P3": 1},
         "range": secret, "doc": secret, "notReviewed": [], "model": secret},
        {"event": "confirm", "date": "2026-10-01", "confirmedRed": 0, "considered": 3, "skipped": secret},
        {"event": "confirm", "date": "2026-10-01", "confirmedRed": 2, "considered": 3, "skipped": None},
        {"event": "close", "fp": "fpA", "key": secret, "severity": "P1", "test": "secretTestName",
         "sha": "abc1234def", "at": "2026-10-01T22:00:00", "kept": True},
        {"event": "run", "date": "2026-10-02", "status": "findings", "failure": None, "costUsd": 2.7,
         "filesInScope": 4, "filesReviewed": 4, "findings": {"P0": 0, "P1": 0, "P2": 2, "P3": 0},
         "range": secret},
        # fpB was first seen on 10-01 but is closed after the 10-02 run: it must
        # still count for 10-01 (findings.json says so).
        {"event": "decline", "fp": "fpB", "key": secret, "severity": "P2", "reason": secret,
         "at": "2026-10-02T09:00:00"},
        {"event": "close", "fp": "fpC", "key": secret, "severity": "P2", "test": "secretTestName",
         "sha": "abc", "at": "2026-10-02T09:00:00", "kept": True},
    ]
    (adv_dir / "ledger.jsonl").write_text("".join(json.dumps(e) + "\n" for e in events))
    (adv_dir / "findings.json").write_text(json.dumps({
        "fpA": {"runs": ["2026-10-01"], "title": secret, "path": "People/DonnaSecret.swift"},
        "fpB": {"runs": ["2026-10-01", "2026-10-02"], "title": secret},
        "fpC": {"runs": ["2026-10-02"], "title": secret},
    }))


CONTRACT_DOC = """# Codex review — Donna's People folder
- Credits spent: unavailable
- Finding count: 3

## Codex answer

Credits spent: unavailable | Finding count: 3
Verdict: fix — SECRET-TITLE

## Closed

Closed by `abc` at 2026-09-27T18:11:43Z.

Credits spent: unavailable | Finding count: 2
Verdict: fix

## Closed
## Closure
"""

BRIEF_ECHO_ONLY = """# Old review (before the contract)
OUTPUT: first line exactly `Credits spent: <n or unavailable> | Finding count: <n>`
F1 — P1: Donna SECRET-TITLE
"""


@pytest.fixture
def sources(tmp_path):
    cov = tmp_path / "coverage"
    write_coverage(cov, "2026-10-01", {"Hallie": folder(50, 100, 40, 50, zero=["People/DonnaSecret.swift"]),
                                       "Core": folder(9, 10, 9, 10)})
    write_coverage(cov, "2026-10-02", {"Hallie": folder(60, 100, 45, 50), "People": folder(0, 0, 0, 0)})
    (cov / "coverage-latest-not-a-date.json").write_text("{}")
    adv = tmp_path / "adv"
    write_ledger(adv)
    codex = tmp_path / "codex"
    codex.mkdir()
    (codex / "codex-review-x-2026-09-27.md").write_text(CONTRACT_DOC)
    (codex / "codex_review_2026_09_15.md").write_text(BRIEF_ECHO_ONLY)
    (codex / "no-date-here.md").write_text(CONTRACT_DOC)
    return SimpleNamespace(cov=cov, adv=adv, codex=codex)


# ---------------------------------------------------------------- builders

def test_coverage_rows_keep_numbers_and_folder_names_only(sources):
    rows = pm.coverage_rows(sources.cov)
    assert [r["date"] for r in rows] == ["2026-10-01", "2026-10-02"]
    first = rows[0]
    assert first["app_status"] == "ok" and first["core_status"] == "failed"   # free text -> category
    hallie = next(f for f in first["folders"] if f["folder"] == "Hallie")
    assert hallie == {"folder": "Hallie", "lines": 100, "covered": 50, "pct": 50.0,
                      "logic_lines": 50, "logic_covered": 40, "logic_pct": 80.0, "files": 3}
    assert first["total"]["lines"] == 110 and first["total"]["pct"] == 53.6
    # A folder with nothing executable is "no data", not 0 %.
    people = next(f for f in rows[1]["folders"] if f["folder"] == "People")
    assert people["pct"] is None and people["logic_pct"] is None
    for row in rows:
        pm.validate("coverage.jsonl", row, FOLDERS)


def test_missing_sources_are_none_not_empty(tmp_path):
    streams = pm.build_streams(tmp_path / "nope", tmp_path / "nope", tmp_path / "nope")
    assert streams == {"coverage.jsonl": None, "adversarial.jsonl": None, "codex_reviews.jsonl": None}


def test_adversarial_rows_are_per_night_counts(sources):
    rows = pm.adversarial_rows(sources.adv / "ledger.jsonl", sources.adv / "findings.json")
    by = {r["date"]: r for r in rows}
    n1 = by["2026-10-01"]
    assert n1["runs"] == 2 and n1["failed_runs"] == 1 and n1["status"] == "findings"
    assert n1["files_reviewed"] == 25 and n1["files_in_scope"] == 25            # the run that worked
    assert n1["findings"] == {"P0": 0, "P1": 2, "P2": 1, "P3": 1}
    assert n1["confirmed_red"] == 2 and n1["confirm_considered"] == 3          # skipped confirm ignored
    assert (n1["kept"], n1["declined"], n1["precision"]) == (1, 1, 0.5)        # fpB credited to 10-01
    assert n1["cost_usd"] == 8.01                                              # null cost is not 0
    n2 = by["2026-10-02"]
    assert (n2["kept"], n2["declined"], n2["precision"]) == (1, 0, 1.0)
    assert n2["confirmed_red"] is None                                         # no confirm yet: no data
    for row in rows:
        pm.validate("adversarial.jsonl", row)


def test_codex_rows_count_contract_lines_and_flag_pre_contract_docs(sources):
    rows = pm.codex_rows(sources.codex)
    by = {r["date"]: r for r in rows}
    assert by["2026-09-27"] == {"schemaVersion": 1, "date": "2026-09-27", "docs": 1, "unparsed_docs": 0,
                                "passes": 2, "findings": 5, "closed_passes": 2}   # 3 Closed headings capped at 2
    # The brief's own `<n>` template is not a pass, and the doc is not "0 findings".
    assert by["2026-09-15"]["unparsed_docs"] == 1 and by["2026-09-15"]["passes"] == 0
    assert len(rows) == 2                                                      # undated doc skipped


# ---------------------------------------------------------------- privacy gate

def test_no_free_text_leaks_from_any_source(sources):
    """THE privacy proof: secrets planted in every free-text field of the ledger,
    findings.json, coverage meta/zero_files and codex docs never reach the
    published text, and every string that does is a date, an enum value, a
    folder name, a severity key or an allowlisted key."""
    fresh = pm.build_streams(sources.cov, sources.adv, sources.codex)
    files = pm.sanitized_files(fresh, None, FOLDERS)
    assert set(files) == {"coverage.jsonl", "adversarial.jsonl", "codex_reviews.jsonl"}
    blob = "".join(files.values())
    for secret in SECRETS:
        assert secret not in blob, f"{secret!r} leaked"
    allowed_keys = set()
    for schema in pm.SCHEMAS.values():
        allowed_keys |= set(schema)
    allowed_keys |= set(pm._COV_NUMS) | {"folder"} | set(pm.SEVERITIES)
    enums = set(pm.TEST_STATUS) | set(pm.RUN_STATUS)
    for text in files.values():
        for line in text.splitlines():
            for s in every_string(json.loads(line)):
                assert (s in allowed_keys or s in enums or s in FOLDERS
                        or pm.DATE_RE.match(s)), f"unexpected published string {s!r}"


@pytest.mark.parametrize("mutate, why", [
    (lambda r: r.update(note="Donna at the beach"), "extra key"),
    (lambda r: r.pop("kept"), "missing key"),
    (lambda r: r.update(status="Donna"), "free text in an enum"),
    (lambda r: r.update(date="2026-10-02 Donna"), "free text in a date"),
    (lambda r: r.update(kept=True), "bool is not a count"),
    (lambda r: r.update(kept=-1), "negative count"),
    (lambda r: r.update(cost_usd=float("nan")), "NaN"),
    (lambda r: r.update(findings={"P1": 1}), "partial severity map"),
    (lambda r: r.update(findings={"P0": 0, "P1": 0, "P2": 0, "P3": 0, "title": 1}), "extra severity key"),
])
def test_validator_rejects_anything_off_the_allowlist(mutate, why):
    row = {"schemaVersion": 1, "date": "2026-10-02", "status": "findings", "runs": 1, "failed_runs": 0,
           "files_in_scope": 1, "files_reviewed": 1, "findings": {"P0": 0, "P1": 0, "P2": 0, "P3": 0},
           "confirmed_red": None, "confirm_considered": None, "kept": 0, "declined": 0,
           "precision": None, "cost_usd": None}
    pm.validate("adversarial.jsonl", row)
    mutate(row)
    with pytest.raises(pm.PrivacyError):
        pm.validate("adversarial.jsonl", row)


@pytest.mark.parametrize("name", ["People/Donna", "Donna Breen", "../People", "Matthew", "hallie lower", ""])
def test_folder_names_must_be_plain_source_folders(name):
    row = pm.coverage_row({"meta": {"date": "2026-10-02"}, "folders": {name: folder(1, 2, 1, 2)}})
    with pytest.raises(pm.PrivacyError):
        pm.validate("coverage.jsonl", row, FOLDERS)


def test_a_folder_deleted_since_it_was_published_does_not_wedge_the_publish(tmp_path):
    """FamilyMusic was removed 10/19; its old coverage rows on the branch refused
    every later publish and froze the dashboard at 10/18. Names already on the
    branch stay allowed; a NEW row still may only name a folder that exists."""
    old = pm.coverage_row({"meta": {"date": "2026-10-18"}, "folders": {"FamilyMusic": folder(1, 2, 1, 2)}})
    (tmp_path / "coverage.jsonl").write_text(pm.render([old]))
    new = pm.coverage_row({"meta": {"date": "2026-10-22"}, "folders": {"Hallie": folder(1, 2, 1, 2)}})
    text = pm.sanitized_files({"coverage.jsonl": [new]}, tmp_path, FOLDERS)["coverage.jsonl"]
    assert "FamilyMusic" in text and "2026-10-22" in text
    stray = pm.coverage_row({"meta": {"date": "2026-10-22"}, "folders": {"Donna": folder(1, 2, 1, 2)}})
    with pytest.raises(pm.PrivacyError):
        pm.sanitized_files({"coverage.jsonl": [stray]}, tmp_path, FOLDERS)


def test_real_source_folders_are_the_allowlist():
    names = pm.source_folders()
    assert {"Core", "(app root)", "Hallie", "Catalog"} <= names
    assert all(pm.FOLDER_RE.match(n) for n in names)


def test_unknown_stream_is_refused():
    with pytest.raises(pm.PrivacyError):
        pm.validate("people.jsonl", {})


# ---------------------------------------------------------------- merge

def test_merge_keeps_branch_only_days_and_fresh_wins():
    old = [{"date": "2026-09-30", "v": 1}, {"date": "2026-10-01", "v": 1}]
    new = [{"date": "2026-10-01", "v": 2}, {"date": "2026-10-02", "v": 2}]
    assert pm.merge_rows(old, new) == [{"date": "2026-09-30", "v": 1}, {"date": "2026-10-01", "v": 2},
                                       {"date": "2026-10-02", "v": 2}]


# ---------------------------------------------------------------- git seam

class FakeGit:
    """Simulates `origin/metrics` as a dict of file name -> text and a linked
    worktree on disk. Records every (path, args) call."""

    def __init__(self, repo: Path, remote: dict | None = None, reject_pushes: int = 0,
                 main_checkout: bool = False):
        self.repo = repo.resolve()
        self.remote = dict(remote or {})
        self.reject_pushes = reject_pushes
        self.main_checkout = main_checkout
        self.calls: list[tuple[Path, tuple]] = []
        self.pushes = 0

    def __call__(self, path, *args, check=True):
        path = Path(path).resolve()
        self.calls.append((path, args))
        rc, out = 0, ""
        if args[:2] == ("worktree", "add"):
            wt = Path(args[-1])
            wt.mkdir(parents=True, exist_ok=True)
            (wt / ".git").write_text("gitdir: fake")
        elif args[:2] == ("rev-parse", "--show-toplevel"):
            out = str(path)
        elif args[:2] == ("rev-parse", "--absolute-git-dir"):
            out = str(self.repo / ".git" / ("" if self.main_checkout else "worktrees/wt"))
        elif "--git-common-dir" in args:
            out = str(self.repo / ".git")
        elif args[0] == "reset":
            shutil.rmtree(path / "metrics", ignore_errors=True)
            (path / "metrics").mkdir(parents=True)
            for name, text in self.remote.items():
                (path / "metrics" / name).write_text(text)
        elif args[0] == "push":
            if self.reject_pushes:
                self.reject_pushes -= 1
                rc = 1
                self.remote["other.jsonl"] = "someone else published\n"
            else:
                self.pushes += 1
                for f in (path / "metrics").iterdir():
                    self.remote[f.name] = f.read_text()
        if check and rc:
            raise pm.PublishError("fake failure")
        return SimpleNamespace(returncode=rc, stdout=out + "\n", stderr="")

    def args_for(self, path):
        return [a for p, a in self.calls if p == Path(path).resolve()]


@pytest.fixture
def repo(tmp_path):
    r = tmp_path / "repo"
    r.mkdir()
    return r


def fresh_streams(sources):
    return pm.build_streams(sources.cov, sources.adv, sources.codex)


def test_publish_touches_the_main_checkout_only_to_create_its_worktree(sources, repo, tmp_path):
    wt = tmp_path / "wt"
    git = FakeGit(repo, remote={"history.jsonl": "{}\n"})
    assert pm.publish(fresh_streams(sources), repo=repo, wt=wt, git=git, folders=FOLDERS, say=lambda m: None) == "pushed"
    assert git.args_for(repo) == [("worktree", "prune"), ("worktree", "add", "--detach", "--no-checkout", str(wt.resolve()))]
    assert all(p in (repo.resolve(), wt.resolve()) for p, _ in git.calls)
    pushes = [a for a in git.args_for(wt) if a[0] == "push"]
    assert pushes == [("push", "--quiet", "origin", "HEAD:refs/heads/metrics")]
    flat = " ".join(" ".join(a) for _, a in git.calls)
    assert "--force" not in flat and " -f " not in f" {flat} " and "+HEAD" not in flat
    assert set(git.remote) == {"history.jsonl", "coverage.jsonl", "adversarial.jsonl", "codex_reviews.jsonl"}
    assert git.remote["history.jsonl"] == "{}\n"                        # other streams untouched


def test_second_publish_with_nothing_new_commits_nothing(sources, repo, tmp_path):
    wt = tmp_path / "wt"
    git = FakeGit(repo)
    pm.publish(fresh_streams(sources), repo=repo, wt=wt, git=git, folders=FOLDERS, say=lambda m: None)
    git.calls.clear()
    assert pm.publish(fresh_streams(sources), repo=repo, wt=wt, git=git, folders=FOLDERS, say=lambda m: None) == "unchanged"
    verbs = [a[0] if a[0] != "-c" else a[4] for a in git.args_for(wt)]
    assert "commit" not in verbs and "push" not in verbs
    assert not git.args_for(repo)                                       # worktree reused


def test_rejected_push_refetches_resets_and_keeps_the_other_publishers_rows(sources, repo, tmp_path):
    wt = tmp_path / "wt"
    git = FakeGit(repo, reject_pushes=2)
    assert pm.publish(fresh_streams(sources), repo=repo, wt=wt, git=git, folders=FOLDERS, say=lambda m: None) == "pushed"
    verbs = [a[0] for a in git.args_for(wt)]
    assert verbs.count("push") == 3 and verbs.count("fetch") == 3 and verbs.count("reset") == 3
    assert "other.jsonl" in git.remote and "coverage.jsonl" in git.remote


def test_push_rejected_every_time_raises(sources, repo, tmp_path):
    git = FakeGit(repo, reject_pushes=99)
    with pytest.raises(pm.PublishError):
        pm.publish(fresh_streams(sources), repo=repo, wt=tmp_path / "wt", git=git, folders=FOLDERS, say=lambda m: None)
    assert git.pushes == 0


def test_privacy_failure_stops_before_any_write_or_commit(sources, repo, tmp_path):
    wt = tmp_path / "wt"
    git = FakeGit(repo)
    fresh = fresh_streams(sources)
    fresh["adversarial.jsonl"][0]["status"] = "Donna's birthday"
    with pytest.raises(pm.PrivacyError):
        pm.publish(fresh, repo=repo, wt=wt, git=git, folders=FOLDERS, say=lambda m: None)
    verbs = [a[0] for a in git.args_for(wt)]
    assert "add" not in verbs and "push" not in verbs and "-c" not in verbs
    assert not (wt / "metrics" / "coverage.jsonl").exists()
    assert not git.remote


def test_existing_published_rows_are_revalidated(sources, repo, tmp_path):
    git = FakeGit(repo, remote={"adversarial.jsonl": json.dumps({"date": "2026-09-01", "title": "Donna"}) + "\n"})
    with pytest.raises(pm.PrivacyError):
        pm.publish(fresh_streams(sources), repo=repo, wt=tmp_path / "wt", git=git, folders=FOLDERS, say=lambda m: None)


def test_refuses_the_main_checkout_as_its_worktree(sources, repo):
    git = FakeGit(repo)
    with pytest.raises(pm.PublishError):
        pm.publish(fresh_streams(sources), repo=repo, wt=repo, git=git, folders=FOLDERS, say=lambda m: None)
    with pytest.raises(pm.PublishError):
        pm.publish(fresh_streams(sources), repo=repo, wt=repo.parent, git=git, folders=FOLDERS, say=lambda m: None)
    assert not git.calls


def test_refuses_a_directory_that_is_a_main_checkout(sources, repo, tmp_path):
    wt = tmp_path / "other-clone"
    wt.mkdir()
    (wt / ".git").mkdir()
    git = FakeGit(repo, main_checkout=True)
    with pytest.raises(pm.PublishError, match="main checkout"):
        pm.publish(fresh_streams(sources), repo=repo, wt=wt, git=git, folders=FOLDERS, say=lambda m: None)
    assert not [a for _, a in git.calls if a[0] in ("reset", "add", "push", "fetch")]


def test_refuses_a_non_empty_non_worktree_directory(sources, repo, tmp_path):
    wt = tmp_path / "busy"
    wt.mkdir()
    (wt / "keep.txt").write_text("x")
    git = FakeGit(repo)
    with pytest.raises(pm.PublishError, match="not empty"):
        pm.publish(fresh_streams(sources), repo=repo, wt=wt, git=git, folders=FOLDERS, say=lambda m: None)
    assert (wt / "keep.txt").exists() and not git.calls


# ---------------------------------------------------------------- real git, local only

def sh(*args, cwd):
    return subprocess.run(["git", "-C", str(cwd), *args], capture_output=True, text=True, check=True,
                          stdin=subprocess.DEVNULL).stdout


@pytest.mark.skipif(shutil.which("git") is None, reason="needs git")
def test_real_git_round_trip_against_a_local_bare_origin(sources, tmp_path):
    """The real command lines, against a file-system 'origin': worktree creation,
    the fetch refspec, detached reset, non-force push, and coexistence with a
    second worktree that has branch `metrics` checked out (as the 2 AM nightly's
    /tmp/nightly-metrics-wt does). The main checkout's HEAD and status are unchanged."""
    origin = tmp_path / "origin.git"
    # `-b main`: the bare origin's HEAD must name a branch we push. Without it
    # HEAD follows the machine's init.defaultBranch ("master" on the Linux
    # runner), the clone below has an unborn HEAD ("remote HEAD refers to
    # nonexistent ref") and `rev-parse HEAD` exits 128 (CI 2026-10-02).
    subprocess.run(["git", "init", "--bare", "-q", "-b", "main", str(origin)], check=True)
    seed = tmp_path / "seed"
    subprocess.run(["git", "init", "-q", "-b", "main", str(seed)], check=True)
    ident = ["-c", "user.name=t", "-c", "user.email=t@t"]
    (seed / "README.md").write_text("main\n")
    sh("add", "README.md", cwd=seed)
    sh(*ident, "commit", "-q", "-m", "main", cwd=seed)
    sh("checkout", "-q", "--orphan", "metrics", cwd=seed)
    sh("rm", "-q", "-rf", ".", cwd=seed)
    (seed / "metrics").mkdir()
    (seed / "metrics" / "history.jsonl").write_text('{"ts":"2026-10-01T00:00:00Z"}\n')
    sh("add", "metrics", cwd=seed)
    sh(*ident, "commit", "-q", "-m", "metrics", cwd=seed)
    sh("remote", "add", "origin", str(origin), cwd=seed)
    sh("push", "-q", "origin", "main", "metrics", cwd=seed)

    repo = tmp_path / "repo"
    subprocess.run(["git", "clone", "-q", str(origin), str(repo)], check=True)
    sh("fetch", "-q", "origin", "metrics:metrics", cwd=repo)
    sh("worktree", "add", "-q", str(tmp_path / "nightly-wt"), "metrics", cwd=repo)   # branch is busy
    head_before = sh("rev-parse", "HEAD", cwd=repo)

    wt = tmp_path / "cache" / "metrics-publish-wt"
    fresh = fresh_streams(sources)
    assert pm.publish(fresh, repo=repo, wt=wt, folders=FOLDERS, say=lambda m: None) == "pushed"
    assert pm.publish(fresh, repo=repo, wt=wt, folders=FOLDERS, say=lambda m: None) == "unchanged"

    published = sh("ls-tree", "-r", "--name-only", "metrics", cwd=origin).split()
    assert published == ["metrics/adversarial.jsonl", "metrics/codex_reviews.jsonl",
                         "metrics/coverage.jsonl", "metrics/history.jsonl"]
    assert sh("show", "metrics:metrics/history.jsonl", cwd=origin) == '{"ts":"2026-10-01T00:00:00Z"}\n'
    assert sh("rev-parse", "HEAD", cwd=repo) == head_before
    assert sh("status", "--porcelain", cwd=repo) == ""
    assert sh("rev-parse", "--abbrev-ref", "HEAD", cwd=wt).strip() == "HEAD"        # detached


# ---------------------------------------------------------------- CLI

def run_cli(*args, env=None):
    import os
    e = dict(os.environ, **(env or {}))
    # Never run the real events prototype (it reads this Mac's catalog) unless a test names a script.
    events = [] if "--events-script" in args else ["--no-events"]
    return subprocess.run(["python3", str(ROOT / "tools" / "publish_metrics.py"), *events, *args],
                          capture_output=True, text=True, env=e, timeout=60, stdin=subprocess.DEVNULL)


def test_cli_kill_switch_is_a_no_op():
    r = run_cli("--worktree", "/nonexistent/should-not-be-created", env={"VIDEOSCAN_PUBLISH_METRICS": "0"})
    assert r.returncode == 0 and r.stdout.strip().splitlines()[-1].startswith("OUTCOME skipped")
    assert not Path("/nonexistent/should-not-be-created").exists()


def test_cli_out_dir_writes_sanitized_files_without_git(sources, tmp_path):
    out = tmp_path / "out"
    r = run_cli("--out-dir", str(out), "--coverage-dir", str(sources.cov),
                "--adversarial-dir", str(sources.adv), "--codex-dir", str(sources.codex))
    assert r.returncode == 0, r.stdout
    assert r.stdout.strip().splitlines()[-1].startswith("OUTCOME ok: dry run")
    assert sorted(p.name for p in out.iterdir()) == ["adversarial.jsonl", "codex_reviews.jsonl", "coverage.jsonl"]
    blob = "".join(p.read_text() for p in out.iterdir())
    assert not any(s in blob for s in SECRETS)


# ---------------------------------------------------------------- events_latest.json (event recognition v0)

EVENTS_OK = {
    "ts": "2026-10-12T15:00:00Z", "active_records": 9810, "with_captions": 6120, "with_transcripts": 3310,
    "clips_with_evidence": 1274, "candidate_events": 308, "strong_events": 109,
    "by_category": {"Birthday": 120, "Christmas": 88, "Beach / vacation": 30, "Graduation": 0},
    "marks_yes": 38, "marks_no": 9,
    "precision_by_category": {"Birthday": {"yes": 30, "no": 5}, "Christmas": {"yes": 8, "no": 4}},
}


class FakeRun:
    """The subprocess.run seam of events_stats: writes `body` to the --stats-json path (or nothing)."""

    def __init__(self, body=None, returncode=0, raise_timeout=False):
        self.body, self.returncode, self.raise_timeout, self.calls = body, returncode, raise_timeout, []

    def __call__(self, argv, **kw):
        self.calls.append((argv, kw))
        if self.raise_timeout:
            raise subprocess.TimeoutExpired(argv, kw.get("timeout", 0))
        if self.body is not None:
            Path(argv[argv.index("--stats-json") + 1]).write_text(self.body)
        return SimpleNamespace(returncode=self.returncode, stdout="", stderr="")


def test_events_stream_is_the_prototypes_counts_and_absent_on_any_failure(tmp_path):
    secret = dict(EVENTS_OK, worst_clip="/Users/rickb/Donna.mov", names=["Donna"])      # not in the allowlist
    run = FakeRun(json.dumps(secret))
    obj = pm.events_stats(run=run, script=Path("/x/events_prototype.py"), python="py3", timeout=7)
    assert obj == dict({"schemaVersion": 1}, **EVENTS_OK)                                  # extras dropped
    argv, kw = run.calls[0]
    assert argv[:3] == ["py3", "/x/events_prototype.py", "--no-open"] and argv[3] == "--stats-json"
    assert kw["timeout"] == 7 and kw["stdin"] == subprocess.DEVNULL
    files = pm.sanitized_files({"events_latest.json": obj}, None, FOLDERS)
    assert set(files) == {"events_latest.json"} and json.loads(files["events_latest.json"]) == obj
    assert not any(s in files["events_latest.json"] for s in SECRETS)
    # Marks not exported yet: nulls pass the gate.
    pm.validate("events_latest.json", pm.events_object(dict(EVENTS_OK, marks_yes=None, marks_no=None,
                                                                 precision_by_category=None)))
    # Any failure of the script means no stream (None), never an exception and never a half object.
    assert pm.events_stats(run=FakeRun(json.dumps(EVENTS_OK), returncode=1)) is None
    assert pm.events_stats(run=FakeRun(None)) is None                                       # wrote nothing
    assert pm.events_stats(run=FakeRun("{not json")) is None
    assert pm.events_stats(run=FakeRun("[1, 2]")) is None                                   # not an object
    assert pm.events_stats(run=FakeRun(json.dumps(EVENTS_OK), raise_timeout=True)) is None
    assert pm.events_stats(script=tmp_path / "missing.py") is None                          # real run, no script
    # The publisher's CLI: a fake script's counts land in the out dir beside the other streams; --no-events skips it.
    fake = tmp_path / "fake_events.py"
    fake.write_text("import json, sys\n"
                    "json.dump(" + json.dumps(secret) + ", open(sys.argv[sys.argv.index('--stats-json') + 1], 'w'))\n")
    out = tmp_path / "out"
    r = run_cli("--out-dir", str(out), "--events-script", str(fake), "--coverage-dir", str(tmp_path / "none"),
                "--adversarial-dir", str(tmp_path / "none"), "--codex-dir", str(tmp_path / "none"))
    assert r.returncode == 0, r.stdout
    assert sorted(p.name for p in out.iterdir()) == ["events_latest.json"]
    assert json.loads((out / "events_latest.json").read_text()) == dict({"schemaVersion": 1}, **EVENTS_OK)
    r2 = run_cli("--out-dir", str(tmp_path / "out2"), "--coverage-dir", str(tmp_path / "none"),
                 "--adversarial-dir", str(tmp_path / "none"), "--codex-dir", str(tmp_path / "none"))
    assert r2.returncode == 0 and list((tmp_path / "out2").iterdir()) == []


@pytest.mark.parametrize("mutate, why", [
    (lambda o: o["by_category"].__setitem__("Donna's party", 3), "a category that is not a constant"),
    (lambda o: o["by_category"].__setitem__("Birthday", "120"), "a count as a string"),
    (lambda o: o.__setitem__("marks_yes", "38"), "marks as a string"),
    (lambda o: o["precision_by_category"].__setitem__("Birthday", {"yes": 30, "no": "five"}), "string in the pair"),
    (lambda o: o["precision_by_category"].__setitem__("Birthday", {"yes": 30}), "half a pair"),
    (lambda o: o["precision_by_category"].__setitem__("Matthew Rice", {"yes": 1, "no": 0}), "a name as a category"),
    (lambda o: o.__setitem__("ts", "2026-10-12"), "a date is not a timestamp"),
    (lambda o: o.__setitem__("candidate_events", None), "a null count"),
    (lambda o: o.__setitem__("clips", 1274), "an extra key"),
    (lambda o: o.pop("strong_events"), "a missing key"),
    (lambda o: o.__setitem__("by_category", None), "no category map at all"),
])
def test_events_gate_refuses_strings_names_and_bad_shapes(mutate, why):
    import copy
    obj = pm.events_object(copy.deepcopy(EVENTS_OK))        # the maps are mutated below; keep the fixture pristine
    pm.validate("events_latest.json", obj)
    mutate(obj)
    with pytest.raises(pm.PrivacyError):
        pm.validate("events_latest.json", obj)


def test_events_prototype_stats_json_is_counts_only(tmp_path, monkeypatch):
    """scripts/events_prototype.py --stats-json: counts from a fake catalog.sqlite and a fake marks export;
    no path, caption, transcript or name reaches the file, and the publisher's gate accepts it."""
    ep_spec = importlib.util.spec_from_file_location("events_prototype", ROOT / "scripts" / "events_prototype.py")
    ep = importlib.util.module_from_spec(ep_spec)
    ep_spec.loader.exec_module(ep)
    import sys
    sys.path.insert(0, str(ROOT / "tests"))
    from catalog_sqlite_fixture import Catalog
    sha = "a" * 64
    # The catalog is catalog.sqlite since the 10/18 cutover (read through scripts/catalog_db.py).
    db = Catalog(tmp_path)
    tape = dict(digest=sha, user_date="1995-06-05", transcript="happy birthday Donna, make a wish",
                captions=[(95, "a child blowing out the candles on a cake")])
    db.add("/Volumes/LaCie/1995/Donna/tape1.mov", **tape)
    db.add("/Volumes/RAID/copies/tape1.mov", **tape)                                     # a copy: one witness
    db.add("/Volumes/LaCie/1996/xmas.mov", digest="b" * 64, user_date="1996-12-25",
           captions=[(3, "santa hands out wrapped presents")])
    db.add("/Volumes/LaCie/misc/lawn.mov", captions=[(0, "a lawn")], transcript="   ")  # evidence-free, blank transcript
    db.add("/Volumes/LaCie/gone.mov", removal=("removedFromCatalog", "purged"),
           captions=[(0, "birthday")])                                                   # purged: not active
    catalog_path = db.close()
    downloads = tmp_path / "Downloads"
    downloads.mkdir()
    (downloads / "events-v0-marks (1).json").write_text(json.dumps({f"Birthday|{sha}": "yes", "Birthday|zzz": "no",
                                                                    "Christmas|bbb": "yes", "Donna|x": "yes",
                                                                    f"Easter|{sha}": "maybe"}))
    (downloads / "events-v0-marks.json").write_text("{}")                                 # older: ignored
    os.utime(downloads / "events-v0-marks.json", (1_600_000_000, 1_600_000_000))
    monkeypatch.setattr(ep, "CATALOG", catalog_path)
    monkeypatch.setattr(ep, "OUT_DIR", tmp_path / "events-prototype")
    monkeypatch.setattr(ep, "PREVIEWS", tmp_path / "previews")
    monkeypatch.setattr(ep, "DOWNLOADS", downloads)
    stats_path = tmp_path / "stats.json"
    assert ep.main(["--no-open", "--stats-json", str(stats_path)]) == 0
    text = stats_path.read_text()
    stats = json.loads(text)
    assert stats["active_records"] == 4 and stats["with_captions"] == 4 and stats["with_transcripts"] == 2   # both copies
    assert stats["clips_with_evidence"] == 2 and stats["candidate_events"] == 2 and stats["strong_events"] == 1
    assert stats["by_category"]["Birthday"] == 1 and stats["by_category"]["Christmas"] == 1 and stats["by_category"]["Easter"] == 0
    assert set(stats["by_category"]) == set(ep.CATEGORIES)
    assert stats["marks_yes"] == 2 and stats["marks_no"] == 1                             # "Donna|x" and "maybe" ignored
    assert stats["precision_by_category"]["Birthday"] == {"yes": 1, "no": 1}
    assert stats["precision_by_category"]["Christmas"] == {"yes": 1, "no": 0}
    for s in ["Donna", "/Volumes", "tape1", "candles", "santa", "make a wish", sha, "zzz"]:
        assert s not in text, s
    pm.validate("events_latest.json", pm.events_object(stats))
    # No marks export at all: nulls, never zeros.
    monkeypatch.setattr(ep, "DOWNLOADS", tmp_path / "empty")
    assert ep.main(["--no-open", "--stats-json", str(stats_path)]) == 0
    stats = json.loads(stats_path.read_text())
    assert stats["marks_yes"] is None and stats["marks_no"] is None and stats["precision_by_category"] is None
    pm.validate("events_latest.json", pm.events_object(stats))


def test_cli_privacy_refusal_exits_3_and_writes_nothing(sources, tmp_path):
    write_coverage(sources.cov, "2026-10-03", {"DonnaBreen": folder(1, 2, 1, 2)})   # not a source folder
    out = tmp_path / "out"
    r = run_cli("--out-dir", str(out), "--coverage-dir", str(sources.cov),
                "--adversarial-dir", str(sources.adv), "--codex-dir", str(sources.codex))
    assert r.returncode == 3 and "privacy gate refused" in r.stdout
    assert "DonnaBreen" not in r.stdout          # the refusal names the field, not the value
    assert not out.exists()
