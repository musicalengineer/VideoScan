#!/usr/bin/env python3
"""Persistent MLX Whisper transcription worker (NDJSON over stdio).

Perf sibling to scripts/whisper_transcribe.py. That script is
spawn-per-file: every invocation is a fresh Python process, so
mlx-whisper reloads the whisper-medium-mlx-q4 weights (~244 MB) every
time — a nightly batch of 888 files paid ~5 s of pure model load per
file (~1.18 h wasted, 2026-07-14 perf diagnosis). This worker stays
alive for the whole batch: mlx_whisper caches the loaded model
per-process (transcribe()'s internal ModelHolder keyed by repo id), so
the load cost is paid exactly once, on the first request.

Protocol — one JSON object per line, both directions:

    request  (stdin):  {"id": "<uuid>", "path": "/abs/file", "language": null}
    response (stdout): {"id": "<uuid>", "ok": true,  "text": "..."}
                    or {"id": "<uuid>", "ok": false, "error": "..."}

Rules the Swift side (WhisperWorkerTranscriber) relies on:
  * stdout is protocol-pure — EXACTLY one JSON line per request,
    flushed immediately, nothing else ever printed there.
  * ALL progress / diagnostics go to stderr.
  * Transcripts are KB-scale; json.dumps escapes embedded newlines so a
    response is always a single line.
  * Clean exit 0 on stdin EOF (parent closed the pipe = batch settled).
  * A malformed request line produces an {"id": null, ok: false}
    response; the parent treats the unknown id as a protocol error and
    recycles the worker.

Setup is identical to whisper_transcribe.py (venv-mlx). By hand:

    venv-mlx/bin/python scripts/whisper_worker.py \
        --model mlx-community/whisper-medium-mlx-q4
    {"id": "1", "path": "/tmp/clip.mov", "language": null}
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path


def respond(payload: dict) -> None:
    """Write one protocol line to stdout and flush — the parent blocks
    on this line, so buffering would deadlock the pipeline."""
    print(json.dumps(payload, ensure_ascii=False), flush=True)


def log(msg: str) -> None:
    """Diagnostics channel. stdout is protocol-pure; everything human
    goes here."""
    print(f"[whisper-worker] {msg}", file=sys.stderr, flush=True)


def handle_request(req: dict, model: str) -> dict:
    """Transcribe one file; always returns a response dict (never raises)."""
    req_id = req.get("id")
    path = req.get("path")
    if not isinstance(req_id, str) or not isinstance(path, str) or not path:
        return {"id": req_id if isinstance(req_id, str) else None,
                "ok": False,
                "error": "malformed request: need string 'id' and 'path'"}

    if not Path(path).is_file():
        return {"id": req_id, "ok": False, "error": f"file not found: {path}"}

    import mlx_whisper  # cached module; import cost paid at startup

    kwargs = {"path_or_hf_repo": model}
    language = req.get("language")
    if language:
        kwargs["language"] = language

    t0 = time.time()
    try:
        # First call loads + caches the model in-process (ModelHolder);
        # every later call is warm-start — that cache is this worker's
        # entire reason to exist.
        result = mlx_whisper.transcribe(path, **kwargs)
    except Exception as e:  # decode errors, bad media, OOM — report, keep serving
        log(f"transcription failed for {path}: {e}")
        return {"id": req_id, "ok": False, "error": f"transcription failed: {e}"}

    text = (result.get("text") if isinstance(result, dict) else None) or ""
    text = text.strip()
    log(f"transcribed {Path(path).name} in {time.time() - t0:.1f}s — {len(text)} chars")
    return {"id": req_id, "ok": True, "text": text}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--model",
        default="mlx-community/whisper-medium-mlx-q4",
        help="HuggingFace model id passed to mlx_whisper.transcribe",
    )
    args = ap.parse_args()

    # Late import with a helpful message — same shape as
    # whisper_transcribe.py. Exiting before the loop means the parent
    # sees immediate EOF and surfaces our stderr in the app log.
    try:
        import mlx_whisper  # noqa: F401
    except ImportError as e:
        log(f"error: mlx_whisper not installed in this Python environment: {e}")
        log("hint: pip install mlx-whisper (in venv-mlx)")
        return 3

    log(f"ready — model {args.model} (loads on first request, then cached)")

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError as e:
            log(f"bad request line ({e}): {line[:200]}")
            respond({"id": None, "ok": False, "error": f"bad request JSON: {e}"})
            continue
        respond(handle_request(req, args.model))

    log("stdin EOF — exiting cleanly")
    return 0


if __name__ == "__main__":
    sys.exit(main())
