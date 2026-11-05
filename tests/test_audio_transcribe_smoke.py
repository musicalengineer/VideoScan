#!/usr/bin/env python3
"""Real-model audio smoke: a known sentence in, the same words out.

Why (Rick, 2026-11-05): the M5 Ultra ran for a week without the Whisper
weights (`mlx-community/whisper-medium-mlx-q4`) and no test noticed, because
every transcription test used a fake. "A real media file with real audio
with a known audio track as a standard test ... red/green so we detect
breaks like this in future."

What runs is the app's REAL path, with the app's arguments (pinned against
the Swift source below): venv-mlx Python, `-u`, the script, `--model
mlx-community/whisper-medium-mlx-q4`, PYTHONUNBUFFERED=1, Homebrew on PATH —
  * "worker"   scripts/whisper_worker.py over NDJSON (WhisperWorkerTranscriber,
               the app's default since 2026-07-14);
  * "per-file" scripts/whisper_transcribe.py --out (PythonSubprocessAudioTranscriber,
               the fallback when the worker script is absent).
The fixture is generated (tests/known_speech_fixture.py: `say` + ffmpeg),
never family media.

  test_known_speech_is_transcribed  needs the model. With the model missing
      it FAILS, never skips: a skip is how the week-long miss hid. It
      inherits the environment, so scripts/audio_smoke.sh can hide the model
      (empty HF cache, offline) and show it go red.
  test_missing_model_says_so        forces that empty, offline cache and
      expects the scripts to refuse in words, exit non-zero (per-file) or
      answer ok:false (worker), and download nothing.
  test_media_matrix_is_heard        the same sentence in mov/h264, mp4/h264,
      mov/prores, mkv/ffv1, mxf/mpeg2 and avi/dv, through one warm worker.
  test_the_smoke_uses_the_apps_arguments  the arguments here are the Swift
      launch's (source pin), so the smoke cannot drift from the app.

Runs under any pytest Python (venv/, like the rest of the suite); only the
subprocess needs venv-mlx. Skipped only off macOS (GitHub's Linux Python
job), where neither `say` nor MLX exists. NOT in the sensor lane (it loads a
real model); it runs in the nightly on every rota Mac.

Memory: the fixtures (< 50 MB together, tmp) and one child's model
(~0.5 GB resident) at a time. Time: ~15 s with the model warm.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "tests"))
sys.path.insert(0, str(REPO / "scripts"))
from known_speech_fixture import KEY_PHRASES, SHAPES, make_known_speech, make_known_speech_mov  # noqa: E402
from check_models import WHISPER_REPO  # noqa: E402

pytestmark = pytest.mark.skipif(sys.platform != "darwin",
                                reason="macOS only: needs `say`, Homebrew ffmpeg and MLX")

MODEL = WHISPER_REPO
ENGINES = ("worker", "per-file")
SWIFT_MEDIA = REPO / "VideoScan" / "VideoScan" / "Media"
TIMEOUT_S = 300


def mlx_python() -> Path:
    """The interpreter the app would pick (ToolLocator.mlxPythonPath order)."""
    candidates = [os.environ.get("VS_MLX_PYTHON_PATH", ""),
                  str(REPO / "venv-mlx" / "bin" / "python3"),
                  str(Path.home() / "dev" / "VideoScan" / "venv-mlx" / "bin" / "python3")]
    for c in candidates:
        if c and Path(c).is_file():
            return Path(c)
    pytest.fail("venv-mlx is not on this Mac (looked in " + ", ".join(c for c in candidates if c)
                + "); the app cannot transcribe without it")


def app_env(extra: dict | None = None) -> dict:
    """The app's child environment: inherited + PYTHONUNBUFFERED + Homebrew first on PATH."""
    env = dict(os.environ)
    env["PYTHONUNBUFFERED"] = "1"
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + env.get("PATH", "")
    env.update(extra or {})
    return env


def words(text: str) -> str:
    """Lower-case, punctuation to spaces, one space: Whisper's commas and full stops vary."""
    return " ".join(re.sub(r"[^a-z0-9]+", " ", text.lower()).split())


def transcribe(engine: str, video: Path, env: dict, tmp: Path) -> dict:
    """Run one engine the way the app does; {'ok', 'text', 'language', 'error', 'rc'}."""
    py = str(mlx_python())
    if engine == "worker":
        # WhisperWorkerTranscriber.ensureWorker: ["-u", scriptPath, "--model", hfModel]
        request = json.dumps({"id": "smoke-1", "path": str(video), "language": None}) + "\n"
        r = subprocess.run([py, "-u", str(REPO / "scripts" / "whisper_worker.py"), "--model", MODEL],
                           input=request, env=env, capture_output=True, text=True, timeout=TIMEOUT_S)
        lines = [ln for ln in r.stdout.splitlines() if ln.strip()]
        assert len(lines) == 1, f"worker must answer exactly one line, got {lines!r}; stderr: {r.stderr[-800:]}"
        resp = json.loads(lines[0])
        assert resp.get("id") == "smoke-1", resp
        return {"ok": bool(resp.get("ok")), "text": resp.get("text") or "", "language": resp.get("language"),
                "error": resp.get("error") or r.stderr[-800:], "rc": r.returncode}
    # PythonSubprocessAudioTranscriber: ["-u", scriptPath, videoPath, "--model", hfModel, "--out", outFile.path]
    out = tmp / "transcript.txt"
    r = subprocess.run([py, "-u", str(REPO / "scripts" / "whisper_transcribe.py"), str(video),
                        "--model", MODEL, "--out", str(out)],
                       env=env, capture_output=True, text=True, timeout=TIMEOUT_S)
    m = re.search(r"^\[whisper\] language=(\S+)$", r.stdout, re.M)
    return {"ok": r.returncode == 0, "text": out.read_text(encoding="utf-8") if out.is_file() else "",
            "language": m.group(1) if m else None, "error": r.stderr[-800:], "rc": r.returncode}


@pytest.fixture(scope="module")
def known_speech(tmp_path_factory) -> Path:
    mov = tmp_path_factory.mktemp("known-speech") / "known_speech.mov"
    make_known_speech_mov(mov)
    return mov


@pytest.mark.parametrize("engine", ENGINES)
def test_known_speech_is_transcribed(engine, known_speech, tmp_path):
    got = transcribe(engine, known_speech, app_env(), tmp_path)
    assert got["ok"], (f"RED — no audio: the {engine} Whisper path failed on a file whose audio says "
                       f"{KEY_PHRASES!r}: {got['error'].strip()}")
    heard = words(got["text"])
    missing = [p for p in KEY_PHRASES if p not in heard]
    assert not missing, f"RED — wrong audio: transcript {got['text']!r} lacks {missing}"
    assert got["language"] == "en", f"RED — language {got['language']!r}, expected 'en'"
    print(f"GREEN — good audio ({engine}): {got['text']!r} [language {got['language']}]")


@pytest.mark.parametrize("engine", ENGINES)
def test_missing_model_says_so(engine, known_speech, tmp_path):
    empty = tmp_path / "empty-hf-cache"
    empty.mkdir()
    hidden = app_env({"HF_HUB_OFFLINE": "1", "HF_HOME": str(empty), "HF_HUB_CACHE": str(empty)})
    got = transcribe(engine, known_speech, hidden, tmp_path)
    assert not got["ok"], f"a Mac without the model produced a transcript: {got['text']!r}"
    if engine == "per-file":
        assert got["rc"] == 6, f"expected exit 6 (model missing), got {got['rc']}: {got['error']}"
    assert "whisper-medium-mlx-q4 is not on this Mac" in got["error"], got["error"]
    assert list(empty.iterdir()) == [], "the script tried to fetch the model into the cache"


def test_media_matrix_is_heard(tmp_path):
    """The rule-8 media matrix through ONE warm worker (the app's batch shape):
    mov/h264+aac, mp4/h264+aac, mov/prores+pcm, mkv/ffv1+pcm, mxf/mpeg2+pcm,
    avi/dv+pcm. Each container is its own way for ffmpeg to hand Whisper
    silence; every one must come back with the sentence."""
    clips = {}
    for shape, (ext, _, _) in SHAPES.items():
        clips[shape] = tmp_path / f"known_speech_{shape}.{ext}"
        make_known_speech(clips[shape], shape)
    requests = "".join(json.dumps({"id": shape, "path": str(p), "language": None}) + "\n"
                       for shape, p in clips.items())
    r = subprocess.run([str(mlx_python()), "-u", str(REPO / "scripts" / "whisper_worker.py"), "--model", MODEL],
                       input=requests, env=app_env(), capture_output=True, text=True, timeout=TIMEOUT_S)
    answers = {a["id"]: a for a in (json.loads(ln) for ln in r.stdout.splitlines() if ln.strip())}
    assert set(answers) == set(clips), f"worker answered {sorted(answers)}; stderr: {r.stderr[-800:]}"
    bad = {}
    for shape, a in answers.items():
        heard = words(a.get("text") or "")
        lost = [p for p in KEY_PHRASES if p not in heard]
        if not a.get("ok") or lost or a.get("language") != "en":
            bad[shape] = a.get("error") or f"{a.get('text')!r} (lacks {lost}, language {a.get('language')})"
    assert not bad, "RED — no audio in: " + "; ".join(f"{k}: {v}" for k, v in bad.items())


def test_the_smoke_uses_the_apps_arguments():
    """The arguments above are the app's; if the Swift launch changes, this goes red first."""
    worker = (SWIFT_MEDIA / "WhisperWorkerTranscriber.swift").read_text(encoding="utf-8")
    per_file = (SWIFT_MEDIA / "AudioTranscriber.swift").read_text(encoding="utf-8")
    assert 'proc.arguments = ["-u", scriptPath, "--model", hfModel]' in worker
    assert re.search(r'"-u",[^\]]*scriptPath,[^\]]*videoPath,[^\]]*"--model", hfModel,[^\]]*"--out", outFile\.path',
                     per_file, re.S)
    for src in (worker, per_file):
        assert f'hfModel: String = "{MODEL}"' in src
        assert 'env["PYTHONUNBUFFERED"] = "1"' in src
