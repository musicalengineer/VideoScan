"""The nightly Hallie VOICE lane (scripts/nightly_hallie_voice.py)."""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import nightly_hallie_voice as lane  # noqa: E402

MARK = lane.FALLBACK_MARK


def test_fallbacks_are_counted_only_since_the_last_run(tmp_path):
    log, state = tmp_path / "videoscan.log", tmp_path / "state.json"
    log.write_text(f"[11:53:14] {MARK}; using Apple speech — status 6\n[11:54:00] other\n")
    first = lane.scan_fallbacks(log, state)
    assert first["hallie_voice_fallbacks"] == 1
    assert "status 6" in first["hallie_voice_fallback_last"]
    assert lane.scan_fallbacks(log, state)["hallie_voice_fallbacks"] == 0, "already counted last night"
    with log.open("a") as f:
        f.write(f"[02:10:00] {MARK}; again\n[02:11:00] {MARK}; and again\n")
    assert lane.scan_fallbacks(log, state)["hallie_voice_fallbacks"] == 2


def test_a_rotated_log_is_read_from_the_start(tmp_path):
    log, state = tmp_path / "videoscan.log", tmp_path / "state.json"
    state.write_text(json.dumps({"offset": 10_000_000}))
    log.write_text(f"[09:00:00] {MARK}; after rotation\n")
    assert lane.scan_fallbacks(log, state)["hallie_voice_fallbacks"] == 1


def test_no_log_and_no_state_is_zero_not_an_error(tmp_path):
    assert lane.scan_fallbacks(tmp_path / "missing.log", tmp_path / "s.json") == {"hallie_voice_fallbacks": 0}


def test_verdict_a_good_voice_with_app_fallbacks_is_not_ok():
    row = lane.verdict({"hallie_voice_status": "ok"}, {"hallie_voice_fallbacks": 3})
    assert row["hallie_voice_status"] == "fallback-seen"
    assert lane.verdict({"hallie_voice_status": "ok"}, {"hallie_voice_fallbacks": 0})["hallie_voice_status"] == "ok"
    assert lane.verdict({"hallie_voice_status": "regressed"}, {"hallie_voice_fallbacks": 3})["hallie_voice_status"] == "regressed"


def test_worker_env_mirrors_the_app_allowlist():
    env = lane.worker_env({"MTL_DEBUG_LAYER": "1", "DYLD_INSERT_LIBRARIES": "/x", "CA_DEBUG_TRANSACTIONS": "1",
                           "HOME": "/h", "TMPDIR": "/t/", "LANG": "en_US.UTF-8"})
    assert env == {"HOME": "/h", "TMPDIR": "/t/", "LANG": "en_US.UTF-8"}


def test_the_python_allowlist_is_the_swift_allowlist():
    import re
    swift = next((ROOT / "VideoScan/VideoScan").rglob("HallieNeuralSpeech.swift")).read_text()
    block = swift[swift.index("workerEnvironmentKeys"):swift.index("]", swift.index("workerEnvironmentKeys"))]
    assert set(re.findall(r'"([A-Za-z_]+)"', block)) == lane.WORKER_ENV_KEYS


def test_missing_engine_is_not_run_never_green(tmp_path):
    ref = json.loads((ROOT / "tests/fixtures/voice/hallie_bella_reference.json").read_text())
    assert lane.check_voice(tmp_path / "nope", ref)["hallie_voice_status"] == "not-run"


def test_the_lane_never_raises_and_only_writes_voice_keys(tmp_path, monkeypatch):
    monkeypatch.setattr(lane, "REFERENCE", tmp_path / "missing.json")
    out = tmp_path / "out.json"
    assert lane.main(["--out", str(out), "--no-alert"]) == 0
    row = json.loads(out.read_text())
    assert row["hallie_voice_status"] == "incomplete"
    assert all(k.startswith("hallie_voice_") for k in row)


def test_alert_writes_the_morning_record_not_a_channel_post(tmp_path):
    """Team channel retired 2026-10-02: the lane's alert is a file the session
    morning hook reads. Written every night; `alert` true only when wrong."""
    path = tmp_path / "hallie-voice" / "latest.json"
    lane.alert({"hallie_voice_status": "regressed", "hallie_voice_reason": "similarity 0.41",
                "hallie_voice_fallbacks": 2}, path)
    record = json.loads(path.read_text())
    assert record["alert"] is True and record["status"] == "regressed"
    assert record["headline"] == "Hallie's voice: regressed" and "similarity 0.41" in record["detail"]
    assert len(record["date"]) == 10
    lane.alert({"hallie_voice_status": "ok", "hallie_voice_fallbacks": 0}, path)
    assert json.loads(path.read_text())["alert"] is False
    assert [p.name for p in path.parent.iterdir()] == ["latest.json"], "temp file left behind"
    assert "team-channel" not in (ROOT / "scripts" / "nightly_hallie_voice.py").read_text()
