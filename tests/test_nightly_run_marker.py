"""scripts/nightly_run_marker.py — a nightly run that never finished leaves a record.

RED 2026-11-09: the M4's 14:00 testbed was cut off by a macOS update 41 minutes
in. No row, no log line; the page kept showing the day before. The marker is
what the next launch reads to publish "did not run · interrupted:<phase>".

Logic (begin / phase / stale / end), isolation (a torn marker, a reused pid, a
live run) and the wiring in scripts/nightly_local_tests.sh (sensor). No host,
no git, no network: every process question is a function the test supplies.
"""
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import nightly_run_marker as m  # noqa: E402

SCRIPT = ROOT / "scripts" / "nightly_run_marker.py"
NIGHTLY = ROOT / "scripts" / "nightly_local_tests.sh"
WHEN = datetime(2026, 11, 9, 19, 0, 4, tzinfo=timezone.utc)


def test_a_marker_whose_process_is_gone_is_stale_with_its_start_phase_and_commit(tmp_path):
    marker = tmp_path / "logs" / "nightly-running.json"
    m.begin(marker, 4242, "25bcbab2e", now=WHEN, start_of=lambda pid: "Mon Nov  9 14:00:04 2026")
    assert m.phase(marker, "post-test", 4242)
    assert m.stale(marker, start_of=lambda pid: None) == ("2026-11-09T19:00:04Z", "post-test", "25bcbab2e", "4242")
    assert marker.exists(), "reading it does not consume it: the publish does"


def test_a_run_that_is_still_going_is_not_stale(tmp_path):
    marker = tmp_path / "nightly-running.json"
    m.begin(marker, 4242, "25bcbab2e", now=WHEN, start_of=lambda pid: "Mon Nov  9 14:00:04 2026")
    assert m.stale(marker, start_of=lambda pid: "Mon Nov  9 14:00:04 2026") is None


def test_a_pid_reused_after_a_reboot_is_not_the_same_run(tmp_path):
    marker = tmp_path / "nightly-running.json"
    m.begin(marker, 4242, "25bcbab2e", now=WHEN, start_of=lambda pid: "Mon Nov  9 14:00:04 2026")
    assert m.stale(marker, start_of=lambda pid: "Mon Nov  9 17:44:51 2026") is not None


def test_no_marker_and_a_torn_marker_are_never_stale_and_the_torn_one_is_removed(tmp_path):
    marker = tmp_path / "nightly-running.json"
    assert m.stale(marker, start_of=lambda pid: None) is None
    for torn in ("", "{", "[]", json.dumps({"pid": "x", "started": "soon", "phase": "test"}),
                 json.dumps({"pid": 1, "started": "2026-11-09T19:00:04Z", "phase": "rm -rf /"}),
                 json.dumps({"pid": True, "started": "2026-11-09T19:00:04Z", "phase": "test"})):
        marker.write_text(torn)
        assert m.stale(marker, start_of=lambda pid: None) is None, torn
        assert not marker.exists(), torn


def test_a_phase_or_commit_that_is_not_code_shaped_is_never_recorded(tmp_path):
    marker = tmp_path / "nightly-running.json"
    m.begin(marker, 7, "not a sha; echo", now=WHEN, start_of=lambda pid: "x")
    assert json.loads(marker.read_text())["commit"] == "unknown"
    assert not m.phase(marker, "Bad Phase!", 7)
    assert json.loads(marker.read_text())["phase"] == "start"
    assert not m.phase(tmp_path / "absent.json", "test", 7)


def test_cli_round_trip_with_a_real_dead_process(tmp_path):
    """The real `ps`: a child that has exited is a run that is gone."""
    marker = tmp_path / "nightly-running.json"
    child = subprocess.Popen([sys.executable, "-c", "pass"])
    child.wait()
    run = lambda *a: subprocess.run([sys.executable, str(SCRIPT), *a], capture_output=True, text=True)
    assert run("stale", str(marker)).returncode == 1
    assert run("begin", str(marker), str(child.pid), "25bcbab2e").returncode == 0
    assert run("phase", str(marker), "build", str(child.pid)).returncode == 0
    out = run("stale", str(marker))
    assert out.returncode == 0
    started, phase, commit, pid = out.stdout.strip().split("\t")
    assert m.TS_RE.match(started) and phase == "build" and commit == "25bcbab2e" and pid == str(child.pid)
    assert run("end", str(marker), "1").returncode == 1 and marker.exists(), "another pid cannot remove it"
    assert run("end", str(marker), str(child.pid)).returncode == 0 and not marker.exists()
    assert run("bogus", str(marker)).returncode == 2


def test_cli_a_live_process_is_not_stale(tmp_path):
    marker = tmp_path / "nightly-running.json"
    run = lambda *a: subprocess.run([sys.executable, str(SCRIPT), *a], capture_output=True, text=True)
    assert run("begin", str(marker), str(os.getpid()), "25bcbab2e").returncode == 0
    assert run("stale", str(marker)).returncode == 1


def test_only_the_owner_changes_or_removes_the_marker_and_a_live_run_is_never_replaced(tmp_path):
    """Codex #275 F3 (RED first): run B overwrote live run A's marker; A's phase update
    then rewrote B's marker after B had published and cleared it; A died; B was
    "recovered" as interrupted and its green day became did-not-run."""
    marker = tmp_path / "nightly-running.json"
    alive = {100: "Mon Nov  9 14:00:04 2026", 200: "Mon Nov  9 14:05:00 2026"}
    start_of = alive.get
    assert m.begin(marker, 100, "aaaaaaa1", now=WHEN, start_of=start_of)
    # B starts while A is live: refused, A's marker untouched.
    assert not m.begin(marker, 200, "bbbbbbb2", now=WHEN, start_of=start_of)
    assert json.loads(marker.read_text())["pid"] == 100
    # B cannot move A's phase or remove A's marker.
    assert not m.phase(marker, "test", 200) and json.loads(marker.read_text())["phase"] == "start"
    assert not m.end(marker, 200) and marker.exists()
    # A is gone: B may take the marker; A's late phase write and end are then no-ops.
    del alive[100]
    assert m.begin(marker, 200, "bbbbbbb2", now=WHEN, start_of=start_of)
    assert not m.phase(marker, "post-test", 100) and not m.end(marker, 100)
    assert json.loads(marker.read_text())["pid"] == 200 and json.loads(marker.read_text())["phase"] == "start"
    assert m.end(marker, 200) and not marker.exists()
    assert not m.phase(marker, "test", 100), "a removed marker is never recreated by a phase write"
    assert not marker.exists()


def test_cli_begin_refuses_a_live_owner_with_exit_3(tmp_path):
    marker = tmp_path / "nightly-running.json"
    run = lambda *a: subprocess.run([sys.executable, str(SCRIPT), *a], capture_output=True, text=True)
    assert run("begin", str(marker), str(os.getpid()), "25bcbab2e").returncode == 0
    before = marker.read_text()
    assert run("begin", str(marker), "1", "ffffff0").returncode == 3
    assert marker.read_text() == before


def test_a_run_whose_result_is_published_or_queued_is_accounted_never_interrupted(tmp_path):
    """Codex #275 F2/F3: a leftover marker beside a real result must not publish
    "interrupted" (it would replace a green day with did-not-run)."""
    started = "2026-11-09T19:00:04Z"
    row = lambda **kw: json.dumps({"source": "nightly-local", "host": "RicksM4", "ts": "2026-11-09T20:18:44Z", **kw})
    assert m.accounted(started, "RicksM4", [[row()]])
    assert m.accounted(started, "RicksM4", [["garbage", "", row(ts="2026-11-10T01:00:00Z")]])
    # Not this host, not a nightly row, dated before (or at) the start, or unreadable: not accounted.
    assert not m.accounted(started, "RicksM4", [[row(host="RicksUltra")]])
    assert not m.accounted(started, "RicksM4", [[row(source="gauntlet")]])
    assert not m.accounted(started, "RicksM4", [[row(ts="2026-11-09T19:00:04Z"), row(ts="2026-11-08T20:18:44Z")]])
    assert not m.accounted(started, "RicksM4", [[row(ts="tomorrow"), "{", "[1]"]])
    assert not m.accounted("not a time", "RicksM4", [[row()]])
    # CLI: the branch's rows on stdin, the pending queue as a file (missing files are no rows).
    queue = tmp_path / "nightly-pending.jsonl"
    queue.write_text(row() + "\n")
    run = lambda stdin, *a: subprocess.run([sys.executable, str(SCRIPT), "accounted", started, "RicksM4", *a],
                                           input=stdin, capture_output=True, text=True)
    assert run("", "-", str(queue)).returncode == 0
    assert run(row() + "\n", "-", str(tmp_path / "absent.jsonl")).returncode == 0
    assert run("", "-", str(tmp_path / "absent.jsonl")).returncode == 1


def test_an_interrupted_row_never_replaces_a_later_result_of_the_same_night():
    """Defence in depth on the publisher: the interrupted row is published LATER but
    dated when its run started; the night's newest run by time wins, not the last line."""
    sys.path.insert(0, str(ROOT / "tools"))
    import publish_metrics as pm
    real = {"source": "nightly-local", "host": "RicksM4", "ts": "2026-11-09T20:18:44Z", "status": "ok",
            "reason": "", "passed": 100, "failed": 0, "total": 100}
    late = {"source": "nightly-local", "host": "RicksM4", "ts": "2026-11-09T19:00:04Z", "status": "failed",
            "reason": "interrupted:test", "passed": 0, "failed": 0, "total": 0}
    kw = dict(days=1, rota={"on": ["M4"], "off": []}, test_names=pm.TestNames(roots=()))
    for rows in ([real, late], [late, real]):
        cell = pm.nightly_summary(rows, "2026-11-09", **kw)["nights"][0]["hosts"]["M4"]
        assert cell["state"] == "green" and cell["passed"] == 100 and cell["finished"] == real["ts"], rows
    # The same instant (Codex #276 F3): a result beats "interrupted", in either order.
    tie = dict(late, ts=real["ts"])
    for rows in ([real, tie], [tie, real]):
        cell = pm.nightly_summary(rows, "2026-11-09", **kw)["nights"][0]["hosts"]["M4"]
        assert cell["state"] == "green" and cell["passed"] == 100, rows
    # A genuine rerun (later time) still replaces the earlier result.
    rerun = dict(real, ts="2026-11-09T23:00:00Z", passed=99, failed=1, status="failed", reason="failed-tests:1")
    cell = pm.nightly_summary([real, rerun], "2026-11-09", **kw)["nights"][0]["hosts"]["M4"]
    assert cell["passed"] == 99 and cell["state"] == "watch"


def test_sensor_the_nightly_records_reports_and_clears_the_marker():
    text = NIGHTLY.read_text()
    assert 'RUN_MARKER="$LOGDIR/nightly-running.json"' in text
    # Codex #275 F2: the marker goes only when a row is DURABLE — after the push, or
    # after the queue append — never at the start of publish_row.
    publish = text[text.index("\npublish_row() {"):text.index("\n# The run marker goes ONLY when")]
    assert "rm -f" not in publish.split("git fetch origin metrics")[0]
    assert publish.index('log "Published successfully') < publish.index("end_run_marker")
    assert publish.count("end_run_marker") == 2, "one guarded call: `declare -F end_run_marker` then the call"
    queue = text[text.index("\nqueue_pending() {"):text.index("\n# Build a status/skipped/failed row")]
    assert queue.index('>> "$PENDING_QUEUE"') < queue.index("end_run_marker")
    helper = text[text.index("\nend_run_marker() {"):text.index("\n# Append a row to the local pending-rows queue")]
    assert 'end "${RUN_MARKER:-/nonexistent}" "${RUN_MARKER_PID:-$$}"' in helper
    main = text[text.index("# ── A run that never finished"):]
    # Recovery asks whether the run is already accounted for BEFORE reporting it, and
    # this run's marker is written after that, never over a live run's.
    assert (main.index('stale "$RUN_MARKER"') < main.index('accounted "$STALE_STARTED" "$HOST" - "$PENDING_QUEUE"')
            < main.index("interrupted:") < main.index('begin "$RUN_MARKER" $$'))
    assert 'RUN_MARKER_PID="$STALE_PID"' in main and "unset RUN_MARKER_PID" in main
    assert 'NIGHTLY_ROW_TS="$STALE_STARTED"' in main
    assert 'phase "$RUN_MARKER" "$1" $$' in main
    for phase in ("core", "model", "build", "test", "post-test"):
        assert f"mark_phase {phase}\n" in main, phase
    # The page's summary is rebuilt after the run's row, on every Mac, from the EXIT trap.
    assert "trap rebuild_page_summary EXIT" in main and "--summary-only" in main
    # make_status_row honours the interrupted run's own start time.
    status_row = text[text.index("\nmake_status_row() {"):text.index("\n# ── Branch + dirty-tree handling")]
    assert 'ts="${NIGHTLY_ROW_TS:-$(date -u +\'%Y-%m-%dT%H:%M:%SZ\')}"' in status_row


def test_the_nightly_block_end_to_end_with_real_bash(tmp_path):
    """The main-flow block run for real (stub log / publish), three situations:
    a dead run with no result is reported; a dead run whose result is queued is not;
    a marker that is not removed until the row is durable survives a kill mid-publish."""
    text = NIGHTLY.read_text()
    block = text[text.index("# ── A run that never finished, and the page summary"):text.index("# Establish the pre-build readiness state.")]
    status_row = text[text.index("\nmake_status_row() {"):text.index("\n# ── Branch + dirty-tree handling")]
    helper = text[text.index("\nend_run_marker() {"):text.index("\n# Append a row to the local pending-rows queue")]
    marker = tmp_path / "nightly-running.json"
    queue = tmp_path / "nightly-pending.jsonl"

    def dead_marker(phase):
        child = subprocess.Popen([sys.executable, "-c", "pass"])
        child.wait()
        assert subprocess.run([sys.executable, str(SCRIPT), "begin", str(marker), str(child.pid), "25bcbab2e"]).returncode == 0
        assert subprocess.run([sys.executable, str(SCRIPT), "phase", str(marker), phase, str(child.pid)]).returncode == 0
        return json.loads(marker.read_text())["started"]

    def run_block(publish_body):
        script = f"""set -u
REPO={ROOT}
LOGDIR={tmp_path}
RUN_MARKER="$LOGDIR/nightly-running.json"
PENDING_QUEUE="$LOGDIR/nightly-pending.jsonl"
HOST=RicksM4; BRANCH=main; COMMIT=abcdef123; NIGHTLY_SCRIPT_VERSION=x; NIGHTLY_CONFIGURATION=Release
export VIDEOSCAN_NIGHTLY_SUMMARY=0
git() {{ return 1; }}
log() {{ echo "LOG $*"; }}
with_person_metrics() {{ printf '%s' "$1"; }}
{helper}
publish_row() {{ {publish_body} }}
{status_row}
{block}
echo "OWNER $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$RUN_MARKER") $$"
exit 7
"""
        return subprocess.run(["bash", "-c", script], capture_output=True, text=True, timeout=60)

    # 1. A dead run with no result anywhere: reported, dated at its start; then this run owns the marker.
    started = dead_marker("post-test")
    out = run_block('echo "PUBLISH $1"; end_run_marker;')
    assert out.returncode == 7, out.stderr
    published = [json.loads(l[len("PUBLISH "):]) for l in out.stdout.splitlines() if l.startswith("PUBLISH ")]
    assert len(published) == 1 and published[0]["reason"] == "interrupted:post-test" and published[0]["ts"] == started
    owner, shell = next(l for l in out.stdout.splitlines() if l.startswith("OWNER ")).split()[1:]
    assert owner == shell

    # 2. The same dead run, but its result is in the pending queue: nothing is reported.
    marker.unlink()
    started = dead_marker("post-test")
    later = started[:11] + "23:59:59Z"
    queue.write_text(json.dumps({"source": "nightly-local", "host": "RicksM4", "ts": later}) + "\n")
    out = run_block('echo "PUBLISH $1"; end_run_marker;')
    assert "PUBLISH" not in out.stdout and "already published or queued" in out.stdout, out.stdout
    queue.unlink()

    # 2b. ONE run per Mac (Codex #276 F3): a live run owns the marker — this launch
    #     refuses to start (exit 3), reports nothing and leaves the marker as it was.
    marker.unlink(missing_ok=True)
    assert subprocess.run([sys.executable, str(SCRIPT), "begin", str(marker), str(os.getpid()), "25bcbab2e"]).returncode == 0
    owned = marker.read_text()
    out = run_block('echo "PUBLISH $1"; end_run_marker;')
    assert out.returncode == 3, (out.returncode, out.stdout, out.stderr)
    assert "another nightly run is live" in out.stdout and "PUBLISH" not in out.stdout and "OWNER" not in out.stdout
    assert marker.read_text() == owned

    # 3. Killed mid-publish (publish_row returns without making the row durable): the
    #    stale marker is NOT consumed by the attempt — but this run then takes the marker,
    #    and the log line above is the record. The run's own marker stays until durable.
    marker.unlink()
    dead_marker("build")
    out = run_block('echo "PUBLISH $1"; return 2;')
    assert "interrupted:build" in out.stdout
    assert marker.exists(), "this run's marker is still there: nothing durable was written for it"


def test_an_interrupted_row_is_a_did_not_run_night_with_a_publishable_reason():
    sys.path.insert(0, str(ROOT / "tools"))
    import publish_metrics as pm
    for phase in ("start", "core", "model", "build", "test", "post-test"):
        reason = f"interrupted:{phase}"
        assert pm.reason_code(reason) == reason
        row = {"source": "nightly-local", "host": "RicksM4", "ts": "2026-11-09T19:00:04Z", "status": "failed",
               "reason": reason, "passed": 0, "failed": 0, "total": 0}
        assert pm.classify_nightly_row(row) == "did_not_run"
    night = pm.nightly_summary([row], "2026-11-09", days=1, rota={"on": ["M4"], "off": []},
                               test_names=pm.TestNames(roots=()))["nights"][0]
    assert night["hosts"]["M4"]["state"] == "did_not_run" and night["hosts"]["M4"]["reason"] == "interrupted:post-test"


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
  show) cat "$FAKE_REMOTE" 2>/dev/null ;;
  reset) mkdir -p "$METRICS_WT/metrics"; cp "$FAKE_REMOTE" "$METRICS_WT/metrics/testdriver.jsonl" 2>/dev/null; rm -f "$FAKE_COMMITTED" ;;
esac
exit 0
"""


def _publish(tmp_path, commit_rc):
    """publish_row / queue_pending / end_run_marker as they are in the script, run for
    real against the fake git. Returns (rc, stdout, remote text, queue text, marker exists)."""
    text = NIGHTLY.read_text()
    functions = text[text.index("\npublish_row() {"):text.index("\n# Build a status/skipped/failed row")]
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir(exist_ok=True)
    (bin_dir / "git").write_text(FAKE_GIT)
    (bin_dir / "git").chmod(0o755)
    wt = tmp_path / "wt"
    (wt / ".git").mkdir(parents=True, exist_ok=True)
    remote, queue, marker = tmp_path / "remote.jsonl", tmp_path / "nightly-pending.jsonl", tmp_path / "nightly-running.json"
    remote.write_text('{"old":1}\n')
    queue.write_text("")
    row = '{"ts":"2026-11-10T07:07:07Z","source":"nightly-local","host":"RicksUltra","status":"ok"}'
    script = f"""set -u
export PATH="{bin_dir}:$PATH" METRICS_WT="{wt}" FAKE_REMOTE="{remote}" FAKE_COMMITTED="{tmp_path / 'committed'}" FAKE_COMMIT_RC={commit_rc}
PENDING_QUEUE="{queue}"
RUN_MARKER="{marker}"
MARKER_TOOL="{SCRIPT}"
log() {{ echo "LOG $*"; }}
sleep() {{ :; }}
python3 "$MARKER_TOOL" begin "$RUN_MARKER" $$ 25bcbab2e
{functions}
publish_row '{row}'
echo "RC $?"
"""
    out = subprocess.run(["bash", "-c", script], capture_output=True, text=True, timeout=120)
    rc = int(next(l for l in out.stdout.splitlines() if l.startswith("RC ")).split()[1])
    return rc, out.stdout, remote.read_text(), queue.read_text(), marker.exists(), row


def test_a_push_that_returns_zero_without_the_row_is_not_a_publish(tmp_path):
    """Codex #276 F2 (RED first, a bug older than the marker): `git commit` fails, the
    push then "succeeds" as a no-op; publish_row logged "Published successfully",
    cleared the pending queue and (new) removed the run marker. The row was gone."""
    rc, out, remote, queue, marker_exists, row = _publish(tmp_path, commit_rc=128)
    assert rc == 1, out                                  # not published; durably queued
    assert row not in remote
    assert queue.strip() == row, "the row waits in the pending queue for the next run"
    assert "NOT on origin/metrics" in out and "Published successfully" not in out
    # Queued is durable too, so the marker has gone — by the queue, not by the false success.
    assert not marker_exists


def test_a_real_publish_is_read_back_then_the_queue_is_cleared_and_the_marker_removed(tmp_path):
    rc, out, remote, queue, marker_exists, row = _publish(tmp_path, commit_rc=0)
    assert rc == 0, out
    assert remote.splitlines() == ['{"old":1}', row]
    assert queue == "" and not marker_exists
    assert "Published successfully" in out
