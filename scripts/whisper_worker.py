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
    response (stdout): {"id": "<uuid>", "ok": true,  "text": "...", "language": "en"}
                    or {"id": "<uuid>", "ok": false, "error": "..."}

The weights must already be on this Mac: a missing model answers every
request ok:false, "model <repo> is not on this Mac (…)", and never
downloads (scripts/check_models.py lists what is required).

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

# Weights resolve from the local cache only, never a download: a missing
# model answers ok:false "model … is not on this Mac". Resolved per request
# (a stat of a few files), so weights copied in mid-batch are picked up.
from check_models import resolve_model  # scripts/ is sys.path[0] when run as a script


WORKER_CACHE_LIMIT_BYTES = 1024 * 1024 * 1024  # MLX buffer-cache ceiling


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

    model_path, model_words = resolve_model(model)
    if model_path is None:
        log(f"error: {model_words}")
        return {"id": req_id, "ok": False, "error": model_words}

    import mlx_whisper  # cached module; import cost paid at startup

    # The local folder, never the repo id (no network). ModelHolder keys
    # its cache on this string, so the model still loads once per worker.
    kwargs = {"path_or_hf_repo": model_path}
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
    language = result.get("language") if isinstance(result, dict) else None
    log(f"transcribed {Path(path).name} in {time.time() - t0:.1f}s — {len(text)} chars, language {language}")
    # "language" is additive: the Swift WorkerResponse decoder ignores it.
    return {"id": req_id, "ok": True, "text": text, "language": language}


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

    # Bound MLX's buffer cache (Rick 2026-10-04: this worker sat at 20 GB
    # alongside a 49 GB TTS worker and beachballed the M4). MLX keeps freed
    # GPU buffers for reuse and by default lets the cache grow to the whole
    # working set; a long-lived worker fed files of every length never
    # gives it back. The model weights (~0.5 GB) are live arrays, not
    # cache, so they stay loaded.
    import mlx.core as mx
    mx.set_cache_limit(WORKER_CACHE_LIMIT_BYTES)

    # Say at spawn, once, in the app log (stderr is relayed there), when the
    # weights are not on this Mac; each request then answers the same words.
    model_path, model_words = resolve_model(args.model)
    if model_path is None:
        log(f"error: {model_words}")
    else:
        log(f"ready — model {model_words} (loads on first request, then cached)")

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
        mx.clear_cache()

    log("stdin EOF — exiting cleanly")
    return 0


if __name__ == "__main__":
    sys.exit(main())
