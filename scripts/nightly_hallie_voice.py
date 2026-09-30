#!/usr/bin/env python3
"""Nightly Hallie VOICE lane (Rick 2026-09-29: "it needs to be part of the
nightly … all tests when possible should be automated").

Two checks, because the 9/28 regression had two halves:

1. THE VOICE. Render the reference sentence with the installed Kokoro engine
   (the environment the app now hands it: Metal debug switches removed) and
   compare its signature with tests/fixtures/voice/hallie_bella_reference.json.
   Catches an OS / Metal / MLX / model / engine change that alters or breaks
   her voice.
2. THE APP. Scan videoscan.log for "[hallie-voice] neural voice unavailable"
   lines written since the last nightly (byte offset kept in a state file).
   Catches the app itself falling back to Apple speech in real use — which
   is what actually happened (the engine was fine; the app killed it).

Writes one JSON object (only `hallie_voice_*` keys — it never touches the
row's status or test counts) and, when anything is wrong, posts a 🔴
team-channel message to claude + rick so it is the first line of the next
status.

    venv/bin/python scripts/nightly_hallie_voice.py --out /tmp/nightly-hallie-voice.json

Exit 0 always (a lane, not the verdict); the JSON carries the result.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "scripts"))
import hallie_voice_signature as hv  # noqa: E402

ENGINE = Path.home() / "Library" / "Application Support" / "VideoScan" / "HallieKokoro"
REFERENCE = REPO / "tests" / "fixtures" / "voice" / "hallie_bella_reference.json"
APP_LOG = Path.home() / "Library" / "Logs" / "VideoScan" / "videoscan.log"
STATE = Path.home() / "Library" / "Logs" / "VideoScan" / "nightly-hallie-voice.state.json"
FALLBACK_MARK = "[hallie-voice] neural voice unavailable"
WORKER_ENV_KEYS = {"HOME", "TMPDIR", "PATH", "USER", "LOGNAME", "LANG", "LC_ALL", "LC_CTYPE", "__CF_USER_TEXT_ENCODING"}


def worker_env(parent: dict[str, str]) -> dict[str, str]:
    """Mirror of HallieNeuralSpeech.workerEnvironment (Swift): an allowlist."""
    import tempfile
    env = {k: v for k, v in parent.items() if k in WORKER_ENV_KEYS}
    env.setdefault("TMPDIR", tempfile.gettempdir() + "/")
    return env


def check_voice(engine: Path, reference: dict) -> dict:
    exe = engine / "kokoro-tts"
    if not exe.exists():
        return {"hallie_voice_status": "not-run", "hallie_voice_reason": f"engine not installed at {engine}"}
    with tempfile.TemporaryDirectory() as d:
        r = subprocess.run(
            [str(exe), "--model", str(engine / "kokoro-v1_0.safetensors"), "--voices", str(engine / "voices.npz"),
             "--output", d, "--voice", reference["voice"], "--speed", str(reference["speed"]),
             "--text", reference["text"]],
            cwd=engine, env=worker_env(dict(os.environ)), capture_output=True, text=True, timeout=300)
        wav = Path(d) / f"hallie-{reference['voice']}.wav"
        if r.returncode != 0 or not wav.exists():
            tail = (r.stderr.strip().splitlines() or ["(no stderr)"])[-1][:240]
            return {"hallie_voice_status": "regressed",
                    "hallie_voice_reason": f"engine failed (exit {r.returncode}): {tail}"}
        got = hv.signature(wav)
    ok, notes = hv.compare(reference["signature"], got)
    a, b = reference["signature"]["timbre"], got["timbre"]
    import numpy as np
    cos = float(np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12))
    return {"hallie_voice_status": "ok" if ok else "regressed",
            "hallie_voice_reason": "; ".join(notes),
            "hallie_voice_similarity": round(cos, 4),
            "hallie_voice_duration_s": got["duration_s"],
            "hallie_voice_pitch_hz": got["median_pitch_hz"]}


def scan_fallbacks(log: Path, state: Path) -> dict:
    """Fallback lines appended to the app log since the last run."""
    if not log.exists():
        return {"hallie_voice_fallbacks": 0}
    size = log.stat().st_size
    try:
        saved = json.loads(state.read_text())
    except (OSError, ValueError):
        saved = {}
    start = int(saved.get("offset", 0))
    if start > size:            # the log was rotated / truncated: read it all
        start = 0
    with log.open("rb") as f:
        f.seek(start)
        new = f.read().decode("utf-8", errors="replace")
    hits = [line for line in new.splitlines() if FALLBACK_MARK in line]
    state.parent.mkdir(parents=True, exist_ok=True)
    state.write_text(json.dumps({"offset": size}))
    out = {"hallie_voice_fallbacks": len(hits)}
    if hits:
        out["hallie_voice_fallback_last"] = hits[-1][:300]
    return out


def verdict(voice: dict, fallbacks: dict) -> dict:
    row = dict(voice)
    row.update(fallbacks)
    if row.get("hallie_voice_status") == "ok" and fallbacks.get("hallie_voice_fallbacks", 0) > 0:
        row["hallie_voice_status"] = "fallback-seen"
    return row


def alert(row: dict) -> None:
    status = row.get("hallie_voice_status")
    if status in ("ok", "not-run"):
        return
    body = (f"Nightly Hallie voice lane: {status}.\n"
            f"Voice check: {row.get('hallie_voice_reason', '-')}\n"
            f"App fell back to Apple speech {row.get('hallie_voice_fallbacks', 0)} time(s) since the last nightly"
            + (f"; last: {row['hallie_voice_fallback_last']}" if row.get("hallie_voice_fallback_last") else "")
            + "\nReference: tests/fixtures/voice/hallie_bella_reference.wav · tool: scripts/hallie_voice_signature.py")
    subprocess.run([sys.executable if Path(sys.executable).exists() else "python3", str(REPO / "tools" / "team-channel.py"),
                    "post", "--from", "reviewer", "--to", "claude,rick",
                    "--subject", f"🔴 Hallie's voice: {status}", "--body", body],
                   capture_output=True, text=True, timeout=60)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--no-alert", action="store_true")
    args = ap.parse_args(argv)
    try:
        reference = json.loads(REFERENCE.read_text())
        row = verdict(check_voice(ENGINE, reference), scan_fallbacks(APP_LOG, STATE))
    except Exception as e:      # a lane never takes the nightly down
        row = {"hallie_voice_status": "incomplete", "hallie_voice_reason": f"{type(e).__name__}: {e}"[:300]}
    Path(args.out).write_text(json.dumps(row))
    print(json.dumps(row))
    if not args.no_alert:
        alert(row)
    return 0


if __name__ == "__main__":
    sys.exit(main())
