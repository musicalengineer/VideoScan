"""scripts/nightly_local_tests.sh — the page summary follows every run, and a failed
commit is never pushed.

RED 2026-11-09: only M4 jobs rebuilt summary_latest.json; two failed publishes left
the page a day old. And (Codex #276 F2, a bug older than this change): `git commit`
fails, the push then "succeeds" as a no-op, publish_row logged "Published
successfully" and cleared the pending queue — the row was gone.

publish_row and queue_pending are run as they are in the script, in real bash,
against a stand-in git whose "remote" is one file. No host, no network.
"""
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
NIGHTLY = ROOT / "scripts" / "nightly_local_tests.sh"

FAKE_GIT = r"""#!/bin/bash
# A stand-in for git: `git [-C dir] [-c k=v]… <verb> …`. The "remote" is one file.
while [ $# -gt 0 ]; do
  case "$1" in -C) shift 2 ;; -c) shift 2 ;; *) break ;; esac
done
verb="$1"; shift
case "$verb" in
  rev-parse) echo metrics ;;
  commit) [ "${FAKE_COMMIT_RC:-0}" = 0 ] && cp "$METRICS_WT/metrics/testdriver.jsonl" "$FAKE_COMMITTED"; exit "${FAKE_COMMIT_RC:-0}" ;;
  push) [ -f "$FAKE_COMMITTED" ] && cp "$FAKE_COMMITTED" "$FAKE_REMOTE"; exit 0 ;;
  reset) mkdir -p "$METRICS_WT/metrics"; cp "$FAKE_REMOTE" "$METRICS_WT/metrics/testdriver.jsonl" 2>/dev/null; rm -f "$FAKE_COMMITTED" ;;
esac
exit 0
"""

ROW = '{"ts":"2026-11-10T07:07:07Z","source":"nightly-local","host":"RicksUltra","status":"ok"}'
QUEUED = '{"ts":"2026-11-09T07:00:00Z","source":"nightly-local","host":"RicksUltra","status":"ok","q":1}'


def publish(tmp_path, commit_rc, queued=""):
    text = NIGHTLY.read_text()
    functions = text[text.index("\npublish_row() {"):text.index("\n# Build a status/skipped/failed row")]
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    (bin_dir / "git").write_text(FAKE_GIT)
    (bin_dir / "git").chmod(0o755)
    wt = tmp_path / "wt"
    (wt / ".git").mkdir(parents=True)
    remote, queue = tmp_path / "remote.jsonl", tmp_path / "nightly-pending.jsonl"
    remote.write_text('{"old":1}\n')
    queue.write_text(queued)
    script = f"""set -u
export PATH="{bin_dir}:$PATH" METRICS_WT="{wt}" FAKE_REMOTE="{remote}" FAKE_COMMITTED="{tmp_path / 'committed'}" FAKE_COMMIT_RC={commit_rc}
PENDING_QUEUE="{queue}"
log() {{ echo "LOG $*"; }}
sleep() {{ :; }}
{functions}
publish_row '{ROW}'
echo "RC $?"
"""
    out = subprocess.run(["bash", "-c", script], capture_output=True, text=True, timeout=120)
    rc = int(next(l for l in out.stdout.splitlines() if l.startswith("RC ")).split()[1])
    return rc, out.stdout + out.stderr, remote.read_text().splitlines(), queue.read_text().splitlines()


def test_a_commit_that_fails_is_not_pushed_and_nothing_is_lost(tmp_path):
    """RED first (on the script before this change the function returned 0, logged
    "Published successfully" and emptied the queue; the row was on no branch)."""
    rc, out, remote, queue = publish(tmp_path, commit_rc=128, queued=QUEUED + "\n")
    assert rc == 1, out
    assert "could not commit the row(s)" in out and "Published successfully" not in out
    assert remote == ['{"old":1}'], "nothing reached the branch"
    assert queue == [QUEUED, ROW], "the row waits in the queue; the row queued before it is still there"


def test_a_good_publish_lands_the_queued_rows_first_and_clears_the_queue(tmp_path):
    rc, out, remote, queue = publish(tmp_path, commit_rc=0, queued=QUEUED + "\n")
    assert rc == 0, out
    assert remote == ['{"old":1}', QUEUED, ROW]
    assert queue == [] and "Published successfully (2 row(s))" in out


def test_sensor_the_summary_is_rebuilt_from_an_exit_trap_after_every_run():
    text = NIGHTLY.read_text()
    main = text[text.index("# ── The page summary follows every run"):]
    assert "trap rebuild_page_summary EXIT" in main
    assert 'python3 "$tool" --summary-only' in main
    # Before the first place the run can publish and exit, so every exit path rebuilds it.
    assert main.index("trap rebuild_page_summary EXIT") < main.index("check_machine_setup\n")
    # Best effort: the function never exits and can be switched off.
    body = main[main.index("rebuild_page_summary() {"):main.index("trap rebuild_page_summary EXIT")]
    assert "exit" not in body.replace("exit code", "") and "VIDEOSCAN_NIGHTLY_SUMMARY" in body


def test_the_exit_trap_keeps_the_runs_own_exit_code(tmp_path):
    text = NIGHTLY.read_text()
    block = text[text.index("# ── The page summary follows every run"):text.index("trap rebuild_page_summary EXIT") + len("trap rebuild_page_summary EXIT")]
    tool = tmp_path / "tools" / "publish_metrics.py"
    tool.parent.mkdir()
    tool.write_text("import sys\nprint('OUTCOME failed: boom')\nsys.exit(1)\n")
    for code in (0, 1, 7):
        script = f"set -u\nREPO={tmp_path}\nlog() {{ echo \"LOG $*\"; }}\n{block}\nexit {code}\n"
        out = subprocess.run(["bash", "-c", script], capture_output=True, text=True, timeout=60)
        assert out.returncode == code, (code, out.returncode, out.stderr)
        assert "LOG Page summary: OUTCOME failed: boom" in out.stdout
