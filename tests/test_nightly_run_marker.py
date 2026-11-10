"""A nightly run that never finished leaves a record; one run per Mac.

RED 2026-11-09: the M4's 14:00 testbed was cut off by a macOS update 41 minutes
in. No row, no log line; the page kept showing the day before.

scripts/nightly_local_tests.sh holds a kernel lock for the whole run and keeps a
marker under it (scripts/nightly_run_marker.py). The next launch that gets the
lock and finds a marker publishes "did not run · interrupted:<phase>" — unless
that run's row is already on the branch or in the queue.

Logic (the marker's verbs, `accounted`), isolation (a torn marker, a second
launch while one is live, a commit that fails before the push) and the wiring
(sensor + the script's own block and publish_row run in real bash against a
stand-in git). No host, no network.
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
LOCK = ROOT / "scripts" / "testbed_lock.py"
NIGHTLY = ROOT / "scripts" / "nightly_local_tests.sh"
WHEN = datetime(2026, 11, 9, 19, 0, 4, tzinfo=timezone.utc)


def test_the_marker_keeps_when_the_run_started_how_far_it_got_and_its_commit(tmp_path):
    marker = tmp_path / "logs" / "nightly-running.json"
    assert m.read(marker) is None
    m.begin(marker, "25bcbab2e", now=WHEN)
    assert m.read(marker) == ("2026-11-09T19:00:04Z", "start", "25bcbab2e")
    assert m.phase(marker, "post-test")
    assert m.read(marker) == ("2026-11-09T19:00:04Z", "post-test", "25bcbab2e")
    assert marker.exists(), "reading it does not consume it: a durable row does"


def test_a_torn_marker_is_never_a_run_and_is_removed(tmp_path):
    marker = tmp_path / "nightly-running.json"
    for torn in ("", "{", "[]", json.dumps({"started": "soon", "phase": "test"}),
                 json.dumps({"started": "2026-11-09T19:00:04Z", "phase": "rm -rf /"}),
                 json.dumps({"started": "2026-11-09T19:00:04Z"})):
        marker.write_text(torn)
        assert m.read(marker) is None, torn
        assert not marker.exists(), torn


def test_a_phase_or_commit_that_is_not_code_shaped_is_never_recorded(tmp_path):
    marker = tmp_path / "nightly-running.json"
    m.begin(marker, "not a sha; echo", now=WHEN)
    assert m.read(marker)[2] == "unknown"
    assert not m.phase(marker, "Bad Phase!")
    assert m.read(marker)[1] == "start"
    assert not m.phase(tmp_path / "absent.json", "test")
    assert not (tmp_path / "absent.json").exists(), "a phase write never creates a marker"


def test_cli_round_trip(tmp_path):
    marker = tmp_path / "nightly-running.json"
    run = lambda *a: subprocess.run([sys.executable, str(SCRIPT), *a], capture_output=True, text=True)
    assert run("read", str(marker)).returncode == 1
    assert run("begin", str(marker), "25bcbab2e").returncode == 0
    assert run("phase", str(marker), "build").returncode == 0
    out = run("read", str(marker))
    started, phase, commit = out.stdout.strip().split("\t")
    assert out.returncode == 0 and m.TS_RE.match(started) and phase == "build" and commit == "25bcbab2e"
    assert run("end", str(marker)).returncode == 0 and not marker.exists()
    assert run("end", str(marker)).returncode == 0, "ending twice is harmless"
    assert run("bogus", str(marker)).returncode == 2 and run("begin", str(marker)).returncode == 2


def test_a_run_whose_result_is_published_or_queued_is_accounted_never_interrupted(tmp_path):
    """Codex #275 F2/F3: a leftover marker beside a real result must not publish
    "interrupted" (it would replace a green day with did-not-run)."""
    started = "2026-11-09T19:00:04Z"
    row = lambda **kw: json.dumps({"source": "nightly-local", "host": "RicksM4", "ts": "2026-11-09T20:18:44Z", **kw})
    assert m.accounted(started, "RicksM4", [[row()]])
    assert m.accounted(started, "RicksM4", [["garbage", "", row(ts="2026-11-10T01:00:00Z")]])
    assert m.accounted(started, "RicksM4", [[row(ts=started)]]), "the same second counts (Codex #276 F3)"
    # Not this host, not a nightly row, dated before the start, an interrupted row, or unreadable.
    assert not m.accounted(started, "RicksM4", [[row(host="RicksUltra")]])
    assert not m.accounted(started, "RicksM4", [[row(source="gauntlet")]])
    assert not m.accounted(started, "RicksM4", [[row(ts="2026-11-08T20:18:44Z")]])
    assert not m.accounted(started, "RicksM4", [[row(ts=started, reason="interrupted:test")]])
    assert not m.accounted(started, "RicksM4", [[row(ts="tomorrow"), "{", "[1]"]])
    assert not m.accounted("not a time", "RicksM4", [[row()]])
    queue = tmp_path / "nightly-pending.jsonl"
    queue.write_text(row() + "\n")
    run = lambda stdin, *a: subprocess.run([sys.executable, str(SCRIPT), "accounted", started, "RicksM4", *a],
                                           input=stdin, capture_output=True, text=True)
    assert run("", "-", str(queue)).returncode == 0
    assert run(row() + "\n", "-", str(tmp_path / "absent.jsonl")).returncode == 0
    assert run("", "-", str(tmp_path / "absent.jsonl")).returncode == 1


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


def test_sensor_the_lock_comes_first_and_the_marker_goes_only_when_a_row_is_durable():
    text = NIGHTLY.read_text()
    assert 'RUN_MARKER="$LOGDIR/nightly-running.json"' in text
    # The run lock is taken before the pull, the build or any publish (Codex #277 F2).
    lock = text.index('python3 "$LOCK_TOOL" hold 8 "$RUN_LOCK"')
    assert text.index('cd "$REPO" ||') < lock < text.index("git fetch origin main --quiet")
    assert lock < text.index('BRANCH=$(git rev-parse --abbrev-ref HEAD')
    block = text[text.index("# ── One nightly run per Mac: the run lock"):text.index("# ── Host detection")]
    assert "exit 3" in block and "another nightly run is live" in block
    # No pid bookkeeping is left anywhere.
    assert "RUN_MARKER_PID" not in text and '"$RUN_MARKER" $$' not in text and 'MARKER_TOOL" stale' not in text
    # The marker goes only when a row is DURABLE: after the read-back, or after the queue append.
    publish = text[text.index("\npublish_row() {"):text.index("\n# The run marker goes ONLY when")]
    assert publish.index("not every row is on origin/metrics") < publish.index('log "Published successfully') < publish.index("end_run_marker")
    assert publish.count("end_run_marker") == 2, "one guarded call: `declare -F end_run_marker` then the call"
    # A failed commit is never pushed; the read-back makes no network call of its own.
    assert publish.index("could not commit the row(s)") < publish.index("# ── Push with retry-on-conflict")
    readback = publish[publish.index('"push returned 0" is not'):publish.index("# Backlog landed")]
    assert "fetch" not in readback and '"$PENDING_QUEUE"' in readback
    queue = text[text.index("\nqueue_pending() {"):text.index("\n# Build a status/skipped/failed row")]
    assert queue.index('>> "$PENDING_QUEUE"') < queue.index("end_run_marker")
    main = text[text.index("# ── A run that never finished"):]
    assert '[ "$RUN_LOCK_HELD" = 1 ] || MARKER_TOOL=""' in main, "no lock, no marker"
    # Recovery asks whether the run is already accounted for BEFORE reporting it — from
    # the local ref and the queue, no network — and this run's marker is written after.
    recover = main[:main.index('begin "$RUN_MARKER" "$COMMIT"')]
    assert (recover.index('read "$RUN_MARKER"') < recover.index('accounted "$STALE_STARTED" "$HOST" - "$PENDING_QUEUE"')
            < recover.index("interrupted:"))
    assert "git fetch" not in recover and 'NIGHTLY_ROW_TS="$STALE_STARTED"' in recover
    for phase in ("core", "model", "build", "test", "post-test"):
        assert f"mark_phase {phase}\n" in main, phase
    assert "trap rebuild_page_summary EXIT" in main and "--summary-only" in main
    status_row = text[text.index("\nmake_status_row() {"):text.index("\n# ── Branch + dirty-tree handling")]
    assert 'ts="${NIGHTLY_ROW_TS:-$(date -u +\'%Y-%m-%dT%H:%M:%SZ\')}"' in status_row


def _run_script_parts(tmp_path, publish_body, hold_lock_elsewhere=False):
    """The script's own lock block and marker block, run in real bash with stubs."""
    text = NIGHTLY.read_text()
    lock_block = text[text.index("# ── One nightly run per Mac: the run lock"):text.index("# ── Host detection")]
    block = text[text.index("# ── A run that never finished, and the page summary"):text.index("# Establish the pre-build readiness state.")]
    status_row = text[text.index("\nmake_status_row() {"):text.index("\n# ── Branch + dirty-tree handling")]
    helper = text[text.index("\nend_run_marker() {"):text.index("\n# Append a row to the local pending-rows queue")]
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
{lock_block}
echo "LOCKED $RUN_LOCK_HELD"
{helper}
publish_row() {{ {publish_body} }}
{status_row}
{block}
echo "MARKER $(cat "$RUN_MARKER" 2>/dev/null)"
exit 7
"""
    holder = None
    if hold_lock_elsewhere:
        lockdir = tmp_path / "nightly-run.lock"
        lockdir.mkdir(exist_ok=True)
        ready = tmp_path / "holder-ready"
        holder = subprocess.Popen(["bash", "-c", f'exec 8>>"{lockdir}/flock"; python3 "{LOCK}" hold 8 "{lockdir}" "nightly run since earlier" >/dev/null; touch "{ready}"; sleep 30'], start_new_session=True)
        for _ in range(200):
            if ready.exists():
                break
            subprocess.run(["sleep", "0.05"])
        assert ready.exists()
    try:
        return subprocess.run(["bash", "-c", script], capture_output=True, text=True, timeout=60)
    finally:
        if holder is not None:
            # The whole group: the lock lives as long as ANY process of the "run" does.
            import signal
            os.killpg(holder.pid, signal.SIGKILL)
            holder.wait()


def test_the_script_blocks_end_to_end_with_real_bash(tmp_path):
    marker = tmp_path / "nightly-running.json"
    queue = tmp_path / "nightly-pending.jsonl"

    def dead_run(phase):
        m.begin(marker, "25bcbab2e", now=WHEN)
        assert m.phase(marker, phase)

    # 1. A dead run with no result anywhere: reported, dated at its start; then this run's marker.
    dead_run("post-test")
    out = _run_script_parts(tmp_path, 'echo "PUBLISH $1"; end_run_marker;')
    assert out.returncode == 7 and "LOCKED 1" in out.stdout, (out.stdout, out.stderr)
    published = [json.loads(l[len("PUBLISH "):]) for l in out.stdout.splitlines() if l.startswith("PUBLISH ")]
    assert len(published) == 1 and published[0]["reason"] == "interrupted:post-test"
    assert published[0]["ts"] == "2026-11-09T19:00:04Z" and published[0]["commit"] == "25bcbab2e"
    now_marker = json.loads(next(l for l in out.stdout.splitlines() if l.startswith("MARKER "))[len("MARKER "):])
    assert now_marker["commit"] == "abcdef123" and now_marker["phase"] == "start"

    # 2. The same dead run, but its result is in the pending queue: nothing is reported.
    dead_run("post-test")
    queue.write_text(json.dumps({"source": "nightly-local", "host": "RicksM4", "ts": "2026-11-09T20:18:44Z"}) + "\n")
    out = _run_script_parts(tmp_path, 'echo "PUBLISH $1"; end_run_marker;')
    assert "PUBLISH" not in out.stdout and "already published or queued" in out.stdout, out.stdout
    queue.unlink()

    # 3. ONE run per Mac (Codex #276 F3, #277 F2): another run holds the kernel lock —
    #    this launch exits 3 before touching anything; the live run's marker is untouched.
    dead_run("test")
    owned = marker.read_text()
    out = _run_script_parts(tmp_path, 'echo "PUBLISH $1"; end_run_marker;', hold_lock_elsewhere=True)
    assert out.returncode == 3, (out.returncode, out.stdout, out.stderr)
    assert "another nightly run is live" in out.stdout and "nightly run since earlier" in out.stdout
    assert "PUBLISH" not in out.stdout and "LOCKED" not in out.stdout and marker.read_text() == owned

    # 4. The lock is the kernel's: once that holder is gone, the next launch gets it (no stale lock).
    out = _run_script_parts(tmp_path, 'echo "PUBLISH $1"; end_run_marker;')
    assert out.returncode == 7 and "LOCKED 1" in out.stdout and "interrupted:test" in out.stdout


def test_two_launches_at_once_only_one_runs(tmp_path):
    """Codex #277 F2 (RED first): two launches that both saw "no marker" both began.
    With the kernel lock exactly one holds it, however they interleave."""
    lockdir = tmp_path / "nightly-run.lock"
    lockdir.mkdir()
    script = f'exec 8>>"{lockdir}/flock"; python3 "{LOCK}" hold 8 "{lockdir}" "launch $1"; sleep 2'
    launches = [subprocess.Popen(["bash", "-c", script, "bash", str(i)], stdout=subprocess.PIPE, text=True) for i in range(6)]
    answers = [p.communicate()[0].strip() for p in launches]
    assert sum(a == "HELD" for a in answers) == 1, answers
    assert sum(a.startswith("BUSY") for a in answers) == 5, answers


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
python3 "$MARKER_TOOL" begin "$RUN_MARKER" 25bcbab2e
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
    assert "could not commit the row(s)" in out and "Published successfully" not in out
    # Queued is durable too, so the marker has gone — by the queue, not by a false success.
    assert not marker_exists


def test_a_real_publish_is_read_back_then_the_queue_is_cleared_and_the_marker_removed(tmp_path):
    rc, out, remote, queue, marker_exists, row = _publish(tmp_path, commit_rc=0)
    assert rc == 0, out
    assert remote.splitlines() == ['{"old":1}', row]
    assert queue == "" and not marker_exists
    assert "Published successfully" in out


def test_a_queued_row_that_did_not_land_keeps_the_whole_queue(tmp_path):
    """Codex #277 F1 (RED first): the read-back checked only the newest row and then
    cleared the WHOLE queue: a queued row that had not landed was discarded."""
    text = NIGHTLY.read_text()
    functions = text[text.index("\npublish_row() {"):text.index("\n# Build a status/skipped/failed row")]
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    # A git whose push "succeeds" but lands only the NEW row, never the queued one.
    (bin_dir / "git").write_text(FAKE_GIT.replace(
        'push) [ -f "$FAKE_COMMITTED" ] && cp "$FAKE_COMMITTED" "$FAKE_REMOTE"; exit 0 ;;',
        'push) tail -1 "$FAKE_COMMITTED" >> "$FAKE_REMOTE"; exit 0 ;;'))
    (bin_dir / "git").chmod(0o755)
    wt = tmp_path / "wt"
    (wt / ".git").mkdir(parents=True)
    remote, queue = tmp_path / "remote.jsonl", tmp_path / "nightly-pending.jsonl"
    remote.write_text('{"old":1}\n')
    queued = '{"ts":"2026-11-09T07:00:00Z","source":"nightly-local","host":"RicksUltra","status":"ok","q":1}'
    queue.write_text(queued + "\n")
    row = '{"ts":"2026-11-10T07:07:07Z","source":"nightly-local","host":"RicksUltra","status":"ok"}'
    script = f"""set -u
export PATH="{bin_dir}:$PATH" METRICS_WT="{wt}" FAKE_REMOTE="{remote}" FAKE_COMMITTED="{tmp_path / 'committed'}" FAKE_COMMIT_RC=0
PENDING_QUEUE="{queue}"
RUN_MARKER="{tmp_path / 'nightly-running.json'}"
MARKER_TOOL="{SCRIPT}"
log() {{ echo "LOG $*"; }}
sleep() {{ :; }}
{functions}
publish_row '{row}'
echo "RC $?"
"""
    out = subprocess.run(["bash", "-c", script], capture_output=True, text=True, timeout=120)
    assert "RC 1" in out.stdout, out.stdout + out.stderr
    assert "not every row is on origin/metrics" in out.stdout and "Published successfully" not in out.stdout
    kept = queue.read_text().splitlines()
    assert queued in kept and row in kept, kept
