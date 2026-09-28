"""tools/codex_review.py — one-command codex review cycle.

Every test runs against a FAKE codex executable and a temp channel DB + state
file (VIDEOSCAN_TEAM_CHANNEL_DB / VIDEOSCAN_REVIEW_CYCLES), so nothing touches
the real mailbox or spends codex credits.
"""

from __future__ import annotations

import importlib.util
import json
import os
import sqlite3
import subprocess
import sys
import textwrap
import time
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "tools" / "codex_review.py"
SPEC = importlib.util.spec_from_file_location("codex_review", SCRIPT)
assert SPEC and SPEC.loader
codex_review = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(codex_review)

BRIEF = textwrap.dedent("""\
    Review range X..Y. Files in scope: a.swift. Do not explore outside these files.
    Answer with this first line:
    Credits spent: <amount> | Finding count: <N>
    and end with a line: Verdict: merge | fix | block
    """)

FAKE_CODEX = textwrap.dedent("""\
    #!{python}
    import json, os, sys, time
    mode = os.environ.get("FAKE_CODEX_MODE", "merge0")
    with open(os.environ["FAKE_CODEX_ARGS"], "w") as f:
        json.dump(sys.argv[1:], f)
    if mode == "stdin":
        sys.stdin.read()          # blocks forever unless stdin is /dev/null
        mode = "merge0"
    if mode == "sleep":
        time.sleep(60)
    if mode == "merge0":
        print("Credits spent: $0.40 | Finding count: 0")
        print("Nothing found.")
        print("**Verdict: MERGE** — clean.")
        print("OpenAI Codex\\ntokens used\\n12,345", file=sys.stderr)
    elif mode == "findings":
        print("Credits spent: $1.10 | Finding count: 2")
        print("F1 — P1: something. F2 — P2: other.")
        print("Verdict: fix before merge")
        print("tokens used\\n98765", file=sys.stderr)
    elif mode == "garbage":
        print("I looked around and it seems fine.")
    elif mode == "crash":
        sys.exit(3)
    """)


@pytest.fixture()
def env(tmp_path, monkeypatch):
    fake = tmp_path / "codex"
    fake.write_text(FAKE_CODEX.format(python=sys.executable))
    fake.chmod(0o755)
    brief = tmp_path / "brief.md"
    brief.write_text(BRIEF)
    monkeypatch.setenv("VIDEOSCAN_CODEX_BIN", str(fake))
    monkeypatch.setenv("VIDEOSCAN_TEAM_CHANNEL_DB", str(tmp_path / "channel.sqlite3"))
    monkeypatch.setenv("VIDEOSCAN_REVIEW_CYCLES", str(tmp_path / "state" / "review-cycles.json"))
    monkeypatch.setenv("VIDEOSCAN_REVIEW_ANNOUNCE", "1")   # channel posts are opt-in; the posting tests opt in
    monkeypatch.setenv("FAKE_CODEX_ARGS", str(tmp_path / "args.json"))
    monkeypatch.setenv("FAKE_CODEX_MODE", "merge0")   # registered so teardown restores it
    return tmp_path


def run(env: Path, mode: str, timeout: float = 20, title: str = "⌘O") -> tuple[int, dict]:
    os.environ["FAKE_CODEX_MODE"] = mode
    code = codex_review.main(["--title", title, "--range", "de54a7ca..48708aba",
                              "--brief", str(env / "brief.md"), "--doc", str(env / "review.md"),
                              "--timeout", str(timeout)])
    cycles = codex_review.load_cycles()
    return code, cycles[-1]


def channel_rows(env: Path) -> list[tuple]:
    with sqlite3.connect(env / "channel.sqlite3") as db:
        return db.execute("SELECT id, author, subject, reply_to FROM messages ORDER BY id").fetchall()


def test_happy_path_merge_zero_closes(env):
    code, cycle = run(env, "merge0")
    assert code == 0
    assert cycle["phase"] == "closed"
    assert (cycle["findings"], cycle["verdict"], cycle["tokens"]) == (0, "merge", 12345)
    assert cycle["closedBy"] == "48708aba"
    doc = (env / "review.md").read_text()
    assert "- Tokens: 12345" in doc and "- Finding count: 0" in doc and "Credits spent: $0.40" in doc
    assert "## Brief" in doc and "Do not explore outside" in doc
    rows = channel_rows(env)
    assert [r[1] for r in rows] == ["claude", "claude"]
    assert rows[0][2] == "Review ⌘O (de54a7ca..48708aba) — started"
    assert rows[1][3] == rows[0][0]                       # verdict is a reply to the start
    assert rows[1][2].startswith("Review ⌘O — merge, 0 findings → ")
    assert cycle["messageIDs"] == [rows[0][0], rows[1][0]]
    args = json.loads((env / "args.json").read_text())
    assert args[:3] == ["exec", "--sandbox", "read-only"] and "--skip-git-repo-check" in args
    assert args[-1] == BRIEF


def test_findings_leave_cycle_fixing_then_close(env):
    code, cycle = run(env, "findings")
    assert code == 0
    assert cycle["phase"] == "fixing"
    assert (cycle["findings"], cycle["verdict"], cycle["tokens"]) == (2, "fix", 98765)
    assert codex_review.main(["close", "--title", "⌘O", "--closed-by", "7d2a9674", "--note", "pinned"]) == 0
    closed = codex_review.load_cycles()[-1]
    assert closed["phase"] == "closed" and closed["closedBy"] == "7d2a9674"
    assert "Closed by `7d2a9674`" in (env / "review.md").read_text()
    assert channel_rows(env)[-1][3] == closed["messageIDs"][0]


def test_second_run_appends_to_doc(env):
    run(env, "findings")
    run(env, "merge0")
    doc = (env / "review.md").read_text()
    assert doc.count("# Codex review — ⌘O") == 2


def test_timeout_kills_codex_and_fails(env):
    started = time.monotonic()
    code, cycle = run(env, "sleep", timeout=1)
    assert code == 1
    assert time.monotonic() - started < 15
    assert cycle["phase"] == "failed" and cycle["failure"] == "timeout"
    with pytest.raises(ProcessLookupError):
        os.kill(cycle["pid"], 0)


def test_stdin_is_dev_null_even_when_caller_holds_a_pipe_open(env):
    # The wrapper itself is started with an open, never-closed stdin pipe.
    # A leaked stdin would block the fake codex → wrapper timeout → failed.
    # NB: not communicate() — that closes stdin and would make this test vacuous.
    environment = dict(os.environ, FAKE_CODEX_MODE="stdin")
    log = open(env / "wrapper.log", "w")
    proc = subprocess.Popen([sys.executable, str(SCRIPT), "--title", "stdin", "--range", "a..b",
                             "--brief", str(env / "brief.md"), "--doc", str(env / "review.md"),
                             "--timeout", "5"],
                            stdin=subprocess.PIPE, stdout=log, stderr=log, env=environment)
    try:
        proc.wait(timeout=25)
    finally:
        proc.kill()
        proc.stdin.close()
        log.close()
    assert proc.returncode == 0, (env / "wrapper.log").read_text()
    assert codex_review.load_cycles()[-1]["phase"] == "closed"


def test_malformed_output_fails_with_reason(env):
    code, cycle = run(env, "garbage")
    assert code == 1
    assert cycle["phase"] == "failed"
    assert cycle["failure"] == "malformed output: no 'Finding count: N'"
    assert not (env / "review.md").exists()
    rows = channel_rows(env)
    assert "failed: malformed output" in rows[-1][2] and rows[-1][3] == rows[0][0]


def test_codex_nonzero_exit_fails(env):
    code, cycle = run(env, "crash")
    assert code == 1 and cycle["failure"] == "codex exit 3"


def test_brief_without_contract_is_refused_before_anything_is_posted(env):
    (env / "brief.md").write_text("Please review a.swift.\n")
    assert codex_review.main(["--title", "x", "--range", "a..b", "--brief", str(env / "brief.md")]) == 2
    assert codex_review.load_cycles() == []
    assert not (env / "channel.sqlite3").exists()


def test_state_file_is_atomic_and_capped_at_twenty(env):
    path = codex_review.state_path()
    for i in range(25):
        codex_review.new_cycle(f"t{i}", "a..b", "d.md")
    cycles = json.loads(path.read_text())
    assert len(cycles) == 20
    assert [c["title"] for c in cycles][0] == "t5" and cycles[-1]["id"] == 25
    leftovers = [p.name for p in path.parent.iterdir() if p.name.endswith(".tmp")]
    assert leftovers == []


def test_save_replaces_via_rename_not_in_place_write(env, monkeypatch):
    path = codex_review.state_path()
    codex_review.new_cycle("first", "a..b", "d.md")
    before = path.stat().st_ino
    codex_review.new_cycle("second", "a..b", "d.md")
    assert path.stat().st_ino != before            # a new inode = temp + rename


def test_corrupt_state_file_reads_as_empty(env):
    path = codex_review.state_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("{not json")
    assert codex_review.load_cycles() == []
    codex_review.new_cycle("fresh", "a..b", "d.md")
    assert [c["title"] for c in codex_review.load_cycles()] == ["fresh"]


def test_parse_output_last_match_wins_over_echoed_contract():
    stdout = "Credits spent: <amount> | Finding count: <N>\nVerdict: merge | fix | block\n" \
             "Credits spent: $2 | Finding count: 3\nVerdict: block — data loss"
    parsed = codex_review.parse_output(stdout, "")
    assert (parsed["findings"], parsed["verdict"], parsed["tokens"]) == (3, "block", None)


def test_status_prints_last_five(env, capsys):
    for i in range(7):
        codex_review.new_cycle(f"t{i}", "a..b", "d.md")
    assert codex_review.main(["status"]) == 0
    lines = capsys.readouterr().out.strip().splitlines()
    assert len(lines) == 5 and lines[0].startswith("#7 t6 (a..b) — briefed")


def test_hyphenated_verdict_is_kept_whole():
    import importlib.util, pathlib
    spec = importlib.util.spec_from_file_location("codex_review", pathlib.Path(__file__).resolve().parents[1] / "tools" / "codex_review.py")
    mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
    fn = next(getattr(mod, n) for n in dir(mod) if n.startswith("parse") and callable(getattr(mod, n)))
    out = fn("Credits spent: unavailable | Finding count: 5\nVerdict: merge-after-fixes\n", "tokens used\n97,983\n")
    assert out["verdict"] == "merge-after-fixes"
    assert out["findings"] == 5


def test_channel_posts_are_off_by_default(env, monkeypatch):
    """Rick 2026-09-27: 19 red 'unanswered from codex' rows — the wrapper must not post by default."""
    monkeypatch.delenv("VIDEOSCAN_REVIEW_ANNOUNCE")
    code, cycle = run(env, "merge0")
    assert code == 0 and cycle["phase"] == "closed"
    db = env / "channel.sqlite3"
    assert not db.exists() or channel_rows(env) == []
