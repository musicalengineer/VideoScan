"""tools/adversarial_nightly.py — scope, brief, Tier A run, ledger, stop rules.

No network, no real claude: VIDEOSCAN_CLAUDE_BIN points at a fake that
answers according to FAKE_CLAUDE_MODE. Every state path is redirected into
tmp_path, and the repository under review is a throwaway git repo.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import textwrap
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

import adversarial_nightly as adv  # noqa: E402
import codex_review  # noqa: E402

FAKE_CLAUDE = r'''#!/usr/bin/env python3
import json, os, sys, time
brief = sys.stdin.read()
log = os.environ.get("FAKE_CLAUDE_LOG")
if log:
    with open(log, "a") as h:
        h.write(json.dumps({"argv": sys.argv[1:], "cwd": os.getcwd(), "brief_len": len(brief)}) + "\n")
mode = os.environ.get("FAKE_CLAUDE_MODE", "findings")
if mode == "hang":
    time.sleep(60)
if mode == "exit1":
    print("boom", file=sys.stderr); sys.exit(1)
if mode == "malformed":
    text = "I looked around and everything seems fine."
elif mode == "clean":
    text = "Credits spent: unavailable | Finding count: 0\nVerdict: merge — nothing found\n\nread, no findings: VideoScan/VideoScan/Archive/Writer.swift\n"
else:
    text = """Credits spent: unavailable | Finding count: 2
Verdict: fix — the writer can clobber

### F1 — P1 — Writer overwrites an existing archive file
- File: VideoScan/VideoScan/Archive/Writer.swift:3
- Invariant: ARCH-2
- Key: VideoScan/VideoScan/Archive/Writer.swift#save#ARCH-2
- Claim: save() writes over a file that is already there.

```swift
// target: app
// test: AdvWriterTests/saveNeverClobbers
import Testing
@testable import VideoScan
@Suite struct AdvWriterTests {
    @Test func saveNeverClobbers() { #expect(Bool(false)) }
}
```

### F2 — P3 — No START line
- File: VideoScan/VideoScan/Archive/Writer.swift:1
- Invariant: ARCH-9
- Key: VideoScan/VideoScan/Archive/Writer.swift#save#ARCH-9
- Claim: no log line.

read, no findings: VideoScan/VideoScan/Archive/Other.swift
"""
print(json.dumps({"type": "result", "subtype": "success", "is_error": False, "result": text,
                  "total_cost_usd": 1.25, "usage": {"input_tokens": 1000, "output_tokens": 200,
                  "cache_creation_input_tokens": 0, "cache_read_input_tokens": 300}}))
'''

INVARIANTS = {
    "Archive.md": """---
tier: data-risk
paths:
  - VideoScan/VideoScan/Archive/**
---
# Archive
## Invariants
1. **ARCH-2** Nothing is overwritten.
2. **ARCH-9** Outcomes tell the truth.
## Known and accepted (do not report)
- per-process lock only.
""",
    "Hallie.md": """---
tier: truth
paths:
  - VideoScan/VideoScan/Hallie/*Answer*.swift
---
# Hallie
## Invariants
1. **HAL-1** Grounded.
## Known and accepted (do not report)
- phrasing varies.
""",
}


def sh(repo: Path, *args: str) -> str:
    env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
           "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com"}
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True,
                          text=True, env=env).stdout


def write(repo: Path, rel: str, text: str) -> None:
    path = repo / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


@pytest.fixture
def env(tmp_path, monkeypatch):
    repo = tmp_path / "repo"
    repo.mkdir()
    sh(repo, "init", "-q", "-b", "main")
    for name, text in INVARIANTS.items():
        write(repo, f"docs/practices/invariants/{name}", text)
    write(repo, "VideoScan/VideoScan/Archive/Old.swift", "struct Old { func keep() {} }\n" * 20)
    write(repo, "VideoScan/VideoScan/Archive/Writer.swift", "struct Writer {\n}\n")
    write(repo, "VideoScan/VideoScan/Catalog/Caller.swift", "func use() { Writer().save() }\n")
    sh(repo, "add", "-A")
    sh(repo, "commit", "-q", "-m", "base")
    base = sh(repo, "rev-parse", "HEAD").strip()
    fake = tmp_path / "fake-claude"
    fake.write_text(FAKE_CLAUDE)
    fake.chmod(0o755)
    state = tmp_path / "state"
    for key, value in {
        "VIDEOSCAN_ADV_REPO": repo, "VIDEOSCAN_ADV_STATE": state,
        "VIDEOSCAN_ADV_LOG": tmp_path / "adv.log", "VIDEOSCAN_ADV_CACHE": tmp_path / "cache",
        "VIDEOSCAN_CLAUDE_BIN": fake, "VIDEOSCAN_REVIEW_CYCLES": tmp_path / "cycles.json",
        "FAKE_CLAUDE_LOG": tmp_path / "claude-calls.jsonl",
    }.items():
        monkeypatch.setenv(key, str(value))
    monkeypatch.setenv("VIDEOSCAN_ADV_NO_GH", "1")
    monkeypatch.setenv("FAKE_CLAUDE_MODE", "findings")
    return {"repo": repo, "state": state, "base": base, "tmp": tmp_path}


def change_day(repo: Path) -> str:
    """One day of merges: a real change, a pure rename, a test, a doc, a non-Swift file."""
    write(repo, "VideoScan/VideoScan/Archive/Writer.swift",
          "struct Writer {\n    func save() { /* writes */ }\n}\n")
    sh(repo, "mv", "VideoScan/VideoScan/Archive/Old.swift", "VideoScan/VideoScan/Archive/Moved.swift")
    write(repo, "VideoScan/VideoScanTests/WriterTests.swift", "// test\n")
    write(repo, "docs/note.md", "note\n")
    write(repo, "VideoScan/VideoScan/Archive/data.json", "{}\n")
    write(repo, "VideoScan/VideoScan/Hallie/HallieFooAnswer.swift", "func answer() {}\n")
    write(repo, "VideoScan/VideoScan/Catalog/Table.swift", "func table() {}\n")
    sh(repo, "add", "-A")
    sh(repo, "commit", "-q", "-m", "Merge writer fix: app 12/3 green (Debug)")
    return sh(repo, "rev-parse", "HEAD").strip()


def latest(env) -> dict:
    return json.loads((env["state"] / "latest.json").read_text())


def ledger(env) -> list[dict]:
    return [json.loads(l) for l in (env["state"] / "ledger.jsonl").read_text().splitlines() if l.strip()]


def baseline(env) -> str | None:
    p = env["state"] / "last_sha"
    return p.read_text().strip() if p.exists() else None


def set_baseline(env, sha: str) -> None:
    env["state"].mkdir(parents=True, exist_ok=True)
    (env["state"] / "last_sha").write_text(sha + "\n")


# ---------------------------------------------------------------- scope

def test_name_status_filter_drops_renames_tests_docs_nonswift():
    entries = adv.parse_name_status(
        "R100\ta/Old.swift\ta/New.swift\nR095\ta/X.swift\ta/Y.swift\nM\tVideoScan/VideoScanTests/T.swift\n"
        "M\tdocs/a.md\nA\ta/b.json\nD\ta/gone.swift\nM\ta/keep.swift\n")
    kept, dropped = adv.filter_entries(entries)
    assert [e["path"] for e in kept] == ["a/Y.swift", "a/keep.swift"]
    assert kept[0]["old"] == "a/X.swift"
    assert dropped == {"rename": 1, "deleted": 1, "tests": 1, "docs": 1, "non-swift": 1}


def test_scope_on_a_real_range(env):
    head = change_day(env["repo"])
    scope = adv.compute_scope(f"{env['base']}..{head}")
    paths = {f["path"]: f["bucket"] for f in scope["files"]}
    assert paths == {"VideoScan/VideoScan/Archive/Writer.swift": "data-risk",
                     "VideoScan/VideoScan/Hallie/HallieFooAnswer.swift": "truth"}
    assert scope["dropped"]["rename"] == 1          # the pure move never reaches the reviewer
    assert scope["dropped"]["tests"] == 1 and scope["dropped"]["docs"] >= 1
    assert "VideoScan/VideoScan/Catalog/Table.swift" in scope["outOfScope"]


def test_split_caps_files_and_lists_overflow():
    files = [{"path": f"A/{i:02}.swift", "bucket": "data-risk", "group": "Archive"} for i in range(30)]
    files += [{"path": f"H/{i:02}.swift", "bucket": "truth", "group": "Hallie"} for i in range(10)]
    briefs, overflow = adv.split_briefs(files)
    assert len(briefs) == 3 and all(len(b) <= 12 for b in briefs)
    assert all(b[0]["bucket"] == "data-risk" for b in briefs)     # data-risk first
    assert [len(b) for b in briefs] == [12, 12, 6]
    assert len(overflow) == 10 and all(f["bucket"] == "truth" for f in overflow)   # visible, not dropped
    assert {f["path"] for f in overflow} | {f["path"] for b in briefs for f in b} == {f["path"] for f in files}


def test_split_never_mixes_buckets_in_one_brief():
    files = [{"path": "A/1.swift", "bucket": "data-risk", "group": "Archive"},
             {"path": "H/1.swift", "bucket": "truth", "group": "Hallie"}]
    briefs, overflow = adv.split_briefs(files)
    assert [[f["bucket"] for f in b] for b in briefs] == [["data-risk"], ["truth"]] and not overflow


# ---------------------------------------------------------------- brief

def test_brief_shape_and_contract(env, tmp_path):
    head = change_day(env["repo"])
    scope = adv.compute_scope(f"{env['base']}..{head}")
    briefs = adv.prepare_briefs(scope, head, "2026-10-02", tmp_path / "out", ".adv-review")
    assert [b["bucket"] for b in briefs] == ["data-risk", "truth"]
    assert [b["effort"] for b in briefs] == ["xhigh", "high"]
    text = briefs[0]["text"]
    assert codex_review.validate_brief(text) is None
    for section in ("(a) Range", "(b) Files in scope", "(c) Callers", "(d) Invariants",
                    "(e) Already reported", "(f) Tests already run", "(g) Coverage", "(h) Privacy",
                    "(i) Output contract"):
        assert section in text, section
    assert "do not explore outside these files" in text
    assert "changed: save" in text
    assert "VideoScan/VideoScan/Catalog/Caller.swift:1" in text      # caller via git grep -w
    assert "**ARCH-2**" in text and "per-process lock only." in text
    assert "12/3 green" in text                                      # green clause of the merge subject
    assert (tmp_path / "out" / "1" / "1.diff").read_text().startswith("diff --git")
    assert "HallieFooAnswer" not in text                             # truth file is in brief 2


# ---------------------------------------------------------------- parse

def test_parse_claude_json_and_findings():
    out = {"type": "result", "subtype": "success", "is_error": False,
           "result": "Credits spent: unavailable | Finding count: 1\nVerdict: fix — x\n\n"
                     "### F1 — P2 — Title here\n- File: a/B.swift:9\n- Invariant: FT-3\n"
                     "- Key: a/B.swift#save#FT-3\n- Claim: c\n\n```swift\n// target: core\n"
                     "// test: S/t\n@Test func t() {}\n```\n\nread, no findings: a/C.swift\n",
           "total_cost_usd": 2.5, "usage": {"input_tokens": 10, "output_tokens": 5}}
    parsed = adv.parse_claude_json(json.dumps(out))
    assert parsed["cost"] == 2.5 and parsed["tokens"] == 15
    contract = codex_review.parse_output(parsed["text"], "")
    assert contract["findings"] == 1 and contract["verdict"] == "fix"
    [f] = adv.parse_findings(parsed["text"])
    assert (f["severity"], f["path"], f["symbol"], f["invariant"]) == ("P2", "a/B.swift", "save", "FT-3")
    assert f["target"] == "core" and f["test"] == "S/t" and "@Test" in f["redTest"]
    assert f["fp"] == adv.fingerprint("a/B.swift", "save", "FT-3")
    assert adv.clean_files(parsed["text"]) == ["a/C.swift"]


def test_fingerprint_ignores_line_numbers():
    a = adv.parse_findings("### F1 — P1 — t\n- File: a/B.swift:9\n- Invariant: X-1\n- Key: a/B.swift#f#X-1\n")
    b = adv.parse_findings("### F1 — P1 — t2\n- File: a/B.swift:200\n- Invariant: X-1\n- Key: a/B.swift#f#X-1\n")
    assert a[0]["fp"] == b[0]["fp"]


# ---------------------------------------------------------------- run

def test_run_happy_path_writes_ledger_latest_doc_and_advances(env):
    head = change_day(env["repo"])
    set_baseline(env, env["base"])
    assert adv.run(None, "2026-10-02") == 0
    row = ledger(env)[-1]
    assert row["status"] == "findings" and row["range"] == f"{env['base']}..{head}"
    assert row["findings"] == {"P0": 0, "P1": 2, "P2": 0, "P3": 2}   # 2 briefs × fake's answer
    assert row["costUsd"] == 2.5 and row["tokens"] == 3000 and row["shadow"] is True
    assert row["effort"] == ["high", "xhigh"]
    assert baseline(env) == head
    lat = latest(env)
    assert lat["status"] == "findings" and lat["repoDoc"] == "docs/reviews/adversarial/2026-10-02.md"
    doc = Path(lat["doc"])
    assert doc.exists() and "Adversarial review — 2026-10-02" in doc.read_text()
    assert not str(doc).startswith(str(env["repo"]))                 # never written into the checkout
    # Second brief re-reports the same fingerprint → marked a same-run dup.
    findings = json.loads((env["state"] / "runs" / "2026-10-02" / "findings.json").read_text())
    assert [f["dup"] for f in findings] == [None, None, "same run", "same run"]
    # Review cycles recorded through codex_review.
    cycles = codex_review.load_cycles()
    assert [c["title"] for c in cycles] == ["adv 2026-10-02 1/2", "adv 2026-10-02 2/2"]
    assert all(c["phase"] == "fixing" for c in cycles)
    # Scratch worktree removed; reviewer ran in it with the restricted flags.
    calls = [json.loads(l) for l in (env["tmp"] / "claude-calls.jsonl").read_text().splitlines()]
    assert all("/cache/" in c["cwd"] for c in calls)
    assert not any((env["tmp"] / "cache").iterdir())
    argv = calls[0]["argv"]
    for flag in ("-p", "--restricted", "--strict-mcp-config", "--no-session-persistence", "--safe-mode"):
        assert flag in argv
    assert argv[argv.index("--tools") + 1] == "Read,Grep,Glob"
    assert argv[argv.index("--permission-mode") + 1] == "dontAsk"
    assert argv[argv.index("--max-budget-usd") + 1] == "10"
    assert argv[argv.index("--model") + 1] == "claude-opus-5-5"
    log = (env["tmp"] / "adv.log").read_text()
    assert " START run 2026-10-02" in log and " OUTCOME run 2026-10-02 status=findings" in log


@pytest.mark.parametrize("mode,reason", [("malformed", "no 'Finding count"), ("exit1", "claude exit 1")])
def test_bad_answer_is_a_failed_night_and_the_baseline_stays(env, monkeypatch, mode, reason):
    change_day(env["repo"])
    set_baseline(env, env["base"])
    monkeypatch.setenv("FAKE_CLAUDE_MODE", mode)
    assert adv.run(None, "2026-10-02") == 1
    assert baseline(env) == env["base"]                              # carried forward
    lat = latest(env)
    assert lat["status"] == "failed" and reason in lat["failure"]
    assert codex_review.load_cycles()[0]["phase"] == "failed"
    assert "status=failed" in (env["tmp"] / "adv.log").read_text()
    assert not any((env["tmp"] / "cache").iterdir())


def test_timeout_kills_the_reviewer_and_fails(env, monkeypatch):
    change_day(env["repo"])
    set_baseline(env, env["base"])
    monkeypatch.setenv("FAKE_CLAUDE_MODE", "hang")
    monkeypatch.setenv("VIDEOSCAN_ADV_TIMEOUT", "1")
    assert adv.run(None, "2026-10-02") == 1
    assert "timeout" in latest(env)["failure"]
    assert baseline(env) == env["base"]


def test_nothing_in_scope_is_one_line_and_advances(env):
    write(env["repo"], "VideoScan/VideoScan/Catalog/Table.swift", "func t() {}\n")
    sh(env["repo"], "add", "-A")
    sh(env["repo"], "commit", "-q", "-m", "ui only")
    head = sh(env["repo"], "rev-parse", "HEAD").strip()
    set_baseline(env, env["base"])
    assert adv.run(None, "2026-10-02") == 0
    assert latest(env)["status"] == "nothing" and baseline(env) == head
    assert not (env["tmp"] / "claude-calls.jsonl").exists()


def test_dedupe_across_nights(env, monkeypatch):
    head = change_day(env["repo"])
    set_baseline(env, env["base"])
    assert adv.run(None, "2026-10-02") == 0
    set_baseline(env, env["base"])                                   # same range again next night
    assert adv.run(None, "2026-10-03") == 0
    findings = json.loads((env["state"] / "runs" / "2026-10-03" / "findings.json").read_text())
    assert all(f["dup"] for f in findings)
    assert latest(env)["status"] == "clean"                          # nothing NEW
    assert head == baseline(env)


def test_three_failed_nights_self_disable(env, monkeypatch):
    change_day(env["repo"])
    set_baseline(env, env["base"])
    monkeypatch.setenv("FAKE_CLAUDE_MODE", "malformed")
    for day in ("2026-10-02", "2026-10-03", "2026-10-04"):
        assert adv.run(None, day) == 1
    assert (env["state"] / "DISABLED").exists()
    monkeypatch.setenv("FAKE_CLAUDE_MODE", "findings")
    calls_before = len((env["tmp"] / "claude-calls.jsonl").read_text().splitlines())
    assert adv.run(None, "2026-10-05") == 0
    assert latest(env)["status"] == "disabled"
    assert len((env["tmp"] / "claude-calls.jsonl").read_text().splitlines()) == calls_before
    assert adv.enable() == 0 and not (env["state"] / "DISABLED").exists()
    assert adv.run(None, "2026-10-06") == 0 and latest(env)["status"] == "findings"


def test_a_success_resets_the_failure_count(env, monkeypatch):
    change_day(env["repo"])
    set_baseline(env, env["base"])
    monkeypatch.setenv("FAKE_CLAUDE_MODE", "malformed")
    adv.run(None, "2026-10-02")
    adv.run(None, "2026-10-03")
    monkeypatch.setenv("FAKE_CLAUDE_MODE", "clean")
    adv.run(None, "2026-10-04")
    assert adv.consecutive_failures() == 0


def test_explicit_older_range_does_not_move_the_baseline(env):
    first = change_day(env["repo"])
    write(env["repo"], "VideoScan/VideoScan/Catalog/Table.swift", "func t2() {}\n")
    sh(env["repo"], "add", "-A")
    sh(env["repo"], "commit", "-q", "-m", "later")
    set_baseline(env, env["base"])
    assert adv.run(f"{env['base']}..{first}", "2026-10-02") == 0
    assert baseline(env) == env["base"]


# ---------------------------------------------------------------- triage

def test_close_and_decline(env):
    change_day(env["repo"])
    set_baseline(env, env["base"])
    adv.run(None, "2026-10-02")
    known = adv.load_findings()
    fps = sorted(known)
    p1 = next(fp for fp in fps if known[fp]["severity"] == "P1")
    p3 = next(fp for fp in fps if known[fp]["severity"] == "P3")
    assert adv.close_finding(p1[:8], "AdvWriterTests/saveNeverClobbers", "abc1234") == 0
    assert adv.decline_finding(p3[:10], "logging is fine here") == 0
    known = adv.load_findings()
    assert known[p1]["status"] == "closed" and known[p3]["status"] == "declined"
    declined = [json.loads(l) for l in adv.declined_path().read_text().splitlines()]
    assert declined[0]["fp"] == p3 and declined[0]["reason"] == "logging is fine here"
    events = [r["event"] for r in ledger(env)]
    assert events[-2:] == ["close", "decline"]
    assert all(c["phase"] == "closed" for c in codex_review.load_cycles())
    with pytest.raises(SystemExit):
        adv.close_finding("abc", "S/t", "x")                         # too short a prefix


def test_status_reports_shadow_and_precision(env, capsys):
    change_day(env["repo"])
    set_baseline(env, env["base"])
    adv.run(None, "2026-10-02")
    capsys.readouterr()
    assert adv.status(as_json=True) == 0
    info = json.loads(capsys.readouterr().out)
    assert info["shadow"] is True and info["runs"] == 1 and info["open"] == 2


def test_shadow_mode_is_on():
    """install.sh refuses unless this holds; filing/Tier B are not built."""
    assert adv.SHADOW_MODE is True
    source = (ROOT / "tools" / "adversarial_nightly.py").read_text()
    for forbidden in ("gh issue create", "\"issue\", \"create\"", "codex_review.run_review",
                      "git(\"commit\"", "\"git\", \"commit\"", "\"push\"", "codex exec"):
        assert forbidden not in source, forbidden
