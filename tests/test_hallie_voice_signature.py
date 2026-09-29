"""Hallie's voice regression sensor (Rick 2026-09-29).

After the macOS 27 / Xcode 27 upgrade Hallie quietly lost her neural voice
(Kokoro "Bella") and fell back to Apple speech. These tests keep a reference
recording and its signature (tests/fixtures/voice/) and fail when the voice
she renders now no longer matches it.

  * The calibration tests run anywhere with numpy.
  * The LIVE test renders the reference sentence with the installed engine
    (~/Library/Application Support/VideoScan/HallieKokoro) and skips where
    it is not installed (CI, fresh machines). Run it after an OS / Xcode /
    engine upgrade:  venv/bin/python -m pytest -q tests/test_hallie_voice_signature.py
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import hallie_voice_signature as hv  # noqa: E402

FIXTURES = ROOT / "tests" / "fixtures" / "voice"
REF = json.loads((FIXTURES / "hallie_bella_reference.json").read_text())
ENGINE = Path.home() / "Library" / "Application Support" / "VideoScan" / "HallieKokoro"


def _render(voice: str, out_dir: Path, env: dict | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(
        [str(ENGINE / "kokoro-tts"), "--model", str(ENGINE / "kokoro-v1_0.safetensors"),
         "--voices", str(ENGINE / "voices.npz"), "--output", str(out_dir), "--voice", voice,
         "--speed", str(REF["speed"]), "--text", REF["text"]],
        cwd=ENGINE, env=env, capture_output=True, text=True, timeout=180)


def _clean_env() -> dict:
    # What the app now hands the engine (HallieNeuralSpeech.workerEnvironment).
    return {k: v for k, v in os.environ.items()
            if not k.startswith(("MTL_DEBUG", "MTL_SHADER_VALIDATION", "METAL_DEVICE_WRAPPER", "METAL_DEBUG"))}


def test_signature_of_the_stored_reference_is_stable():
    """The tool itself: the stored WAV still yields the stored signature."""
    ok, notes = hv.compare(REF["signature"], hv.signature(FIXTURES / "hallie_bella_reference.wav"))
    assert ok, notes


def test_a_slower_render_is_caught(tmp_path):
    """Pacing: the same audio stretched 20 % longer fails the duration check."""
    import wave
    src = FIXTURES / "hallie_bella_reference.wav"
    with wave.open(str(src), "rb") as w:
        params, frames = w.getparams(), w.readframes(w.getnframes())
    out = tmp_path / "slow.wav"
    with wave.open(str(out), "wb") as w:
        w.setparams(params)
        w.setframerate(int(params.framerate / 1.2))     # plays 20 % slower and lower
        w.writeframes(frames)
    ok, notes = hv.compare(REF["signature"], hv.signature(out))
    assert not ok, notes


@pytest.mark.skipif(shutil.which("say") is None, reason="macOS 'say' not available")
def test_apple_speech_is_not_hallie(tmp_path):
    """The failure we actually had: Apple speech in place of Bella."""
    aiff, wav = tmp_path / "apple.aiff", tmp_path / "apple.wav"
    subprocess.run(["say", "-o", str(aiff), REF["text"]], check=True)
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(aiff), "-ar", "24000", "-ac", "1", str(wav)],
                   check=True)
    ok, notes = hv.compare(REF["signature"], hv.signature(wav))
    assert not ok, notes


@pytest.mark.skipif(not (ENGINE / "kokoro-tts").exists(), reason="Hallie's neural engine is not installed here")
def test_live_hallie_still_sounds_like_the_reference():
    with tempfile.TemporaryDirectory() as d:
        r = _render(REF["voice"], Path(d), env=_clean_env())
        assert r.returncode == 0, f"engine failed: {r.stderr[-400:]}"
        ok, notes = hv.compare(REF["signature"], hv.signature(Path(d) / f"hallie-{REF['voice']}.wav"))
    assert ok, "Hallie's voice changed:\n  " + "\n  ".join(notes)


@pytest.mark.skipif(not (ENGINE / "kokoro-tts").exists(), reason="Hallie's neural engine is not installed here")
def test_another_kokoro_voice_is_caught():
    with tempfile.TemporaryDirectory() as d:
        r = _render("af_heart", Path(d), env=_clean_env())
        assert r.returncode == 0, r.stderr[-400:]
        ok, notes = hv.compare(REF["signature"], hv.signature(Path(d) / "hallie-af_heart.wav"))
    assert not ok, notes


@pytest.mark.skipif(not (ENGINE / "kokoro-tts").exists(), reason="Hallie's neural engine is not installed here")
def test_the_engine_dies_under_metal_debug_so_the_app_must_strip_it():
    """Documents WHY the app filters the environment: with Xcode's Metal API
    validation inherited, the engine aborts (exit -6). If Apple or MLX ever
    fixes this the test says so, and the filter becomes belt-and-braces."""
    with tempfile.TemporaryDirectory() as d:
        r = _render(REF["voice"], Path(d), env=dict(_clean_env(), MTL_DEBUG_LAYER="1"))
    if r.returncode == 0:
        pytest.skip("engine now survives MTL_DEBUG_LAYER=1 — the app's filter is no longer load-bearing")
    assert "bytes argument cannot be nil" in r.stderr or r.returncode < 0
