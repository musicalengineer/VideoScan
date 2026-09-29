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


def test_worker_env_mirrors_the_app_filter():
    env = lane.worker_env({"MTL_DEBUG_LAYER": "1", "MTL_SHADER_VALIDATION": "1", "METAL_DEVICE_WRAPPER_TYPE": "1",
                           "METAL_DEBUG_ERROR_MODE": "0", "MTL_HUD_ENABLED": "1", "HOME": "/h"})
    assert env == {"MTL_HUD_ENABLED": "1", "HOME": "/h"}


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
