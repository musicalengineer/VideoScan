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
    assert m.phase(marker, "post-test")
    assert m.stale(marker, start_of=lambda pid: None) == ("2026-11-09T19:00:04Z", "post-test", "25bcbab2e")
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
    assert not m.phase(marker, "Bad Phase!")
    assert json.loads(marker.read_text())["phase"] == "start"
    assert not m.phase(tmp_path / "absent.json", "test")


def test_cli_round_trip_with_a_real_dead_process(tmp_path):
    """The real `ps`: a child that has exited is a run that is gone."""
    marker = tmp_path / "nightly-running.json"
    child = subprocess.Popen([sys.executable, "-c", "pass"])
    child.wait()
    run = lambda *a: subprocess.run([sys.executable, str(SCRIPT), *a], capture_output=True, text=True)
    assert run("stale", str(marker)).returncode == 1
    assert run("begin", str(marker), str(child.pid), "25bcbab2e").returncode == 0
    assert run("phase", str(marker), "build").returncode == 0
    out = run("stale", str(marker))
    assert out.returncode == 0
    started, phase, commit = out.stdout.strip().split("\t")
    assert m.TS_RE.match(started) and phase == "build" and commit == "25bcbab2e"
    assert run("end", str(marker)).returncode == 0 and not marker.exists()
    assert run("bogus", str(marker)).returncode == 2


def test_cli_a_live_process_is_not_stale(tmp_path):
    marker = tmp_path / "nightly-running.json"
    run = lambda *a: subprocess.run([sys.executable, str(SCRIPT), *a], capture_output=True, text=True)
    assert run("begin", str(marker), str(os.getpid()), "25bcbab2e").returncode == 0
    assert run("stale", str(marker)).returncode == 1


def test_sensor_the_nightly_records_reports_and_clears_the_marker():
    text = NIGHTLY.read_text()
    # One marker path; the publisher clears it the moment a row is published or queued.
    assert 'RUN_MARKER="$LOGDIR/nightly-running.json"' in text
    publish = text[text.index("\npublish_row() {"):text.index("\nqueue_pending() {")]
    assert 'rm -f "${RUN_MARKER:-/nonexistent}"' in publish
    main = text[text.index("# ── A run that never finished"):]
    # The stale run is published BEFORE this run's marker is written, dated when it started.
    assert main.index('stale "$RUN_MARKER"') < main.index("interrupted:") < main.index('begin "$RUN_MARKER"')
    assert 'NIGHTLY_ROW_TS="$STALE_STARTED"' in main
    for phase in ("core", "model", "build", "test", "post-test"):
        assert f"mark_phase {phase}\n" in main, phase
    # The page's summary is rebuilt after the run's row, on every Mac, from the EXIT trap.
    assert "trap rebuild_page_summary EXIT" in main and "--summary-only" in main
    # make_status_row honours the interrupted run's own start time.
    status_row = text[text.index("\nmake_status_row() {"):text.index("\n# ── Branch + dirty-tree handling")]
    assert 'ts="${NIGHTLY_ROW_TS:-$(date -u +\'%Y-%m-%dT%H:%M:%SZ\')}"' in status_row


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
