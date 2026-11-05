#!/usr/bin/env python3
"""Transcribe the audio track of a video / audio file with MLX Whisper.

Phase-1 sibling to scripts/vlm_caption.py — same isolation pattern
(must run from the dedicated venv-mlx environment so we don't have
to share a numpy ABI with the dlib / facenet venv used by face
recognition). The Swift app launches this script via Process() and
reads the transcript from the file path passed to --out.

Why a file output (rather than parsing stdout): mlx-whisper prints
progress + diagnostics to stdout, and Whisper transcripts can be
long enough to span many chunks. Writing the final text to a file
lets the parent process pick it up atomically without parsing
mixed-content streams.

Setup on a new machine (one-time):

    python3.12 -m venv venv-mlx
    venv-mlx/bin/pip install -r scripts/requirements-mlx.txt
    venv-mlx/bin/pip install mlx-whisper

The weights must already be on this Mac (scripts/check_models.py says
which are); the script refuses, exit 6, rather than download them.

Then call from the Swift app, or by hand:

    venv-mlx/bin/python scripts/whisper_transcribe.py <audio-or-video> \
        --model mlx-community/whisper-medium-mlx-q4 --out /tmp/t.txt
"""
from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

# Weights resolve from the local cache only, never a download (exit 6 with
# "model … is not on this Mac" instead). 2026-11-05: the M5 Ultra ran a week
# without this model and nothing said so.
from check_models import resolve_model  # scripts/ is sys.path[0] when run as a script

# Exit codes the Swift side surfaces in the log (AudioTranscriberError
# .subprocessFailed carries exit code + stderr tail): 2 input missing,
# 3 mlx_whisper missing, 4 transcription failed, 5 output unwritable,
# 6 model weights not on this Mac.
EXIT_MODEL_MISSING = 6


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("input", type=Path, help="Audio or video file to transcribe")
    ap.add_argument(
        "--model",
        default="mlx-community/whisper-medium-mlx-q4",
        help="HuggingFace model id passed to mlx_whisper.transcribe",
    )
    ap.add_argument(
        "--out",
        type=Path,
        required=True,
        help="Write the final transcript text to this file (UTF-8).",
    )
    ap.add_argument(
        "--language",
        default=None,
        help="Force a language code (e.g. 'en'); default = auto-detect.",
    )
    args = ap.parse_args()

    if not args.input.is_file():
        print(f"error: {args.input} not found", file=sys.stderr)
        return 2

    model_path, model_words = resolve_model(args.model)
    if model_path is None:
        print(f"error: {model_words}", file=sys.stderr)
        return EXIT_MODEL_MISSING

    # Late import — if the user runs this from the wrong venv, the
    # error message says so before we try to do anything else.
    try:
        import mlx_whisper
    except ImportError as e:
        print(f"error: mlx_whisper not installed in this Python environment: {e}", file=sys.stderr)
        print("hint: pip install mlx-whisper (in venv-mlx)", file=sys.stderr)
        return 3

    print(f"[whisper] loading {model_words} ...", flush=True)
    t0 = time.time()
    # The local snapshot folder, never the repo id: mlx_whisper only calls
    # snapshot_download (network) when the path does not exist.
    kwargs = {"path_or_hf_repo": model_path}
    if args.language:
        kwargs["language"] = args.language
    try:
        result = mlx_whisper.transcribe(str(args.input), **kwargs)
    except Exception as e:
        print(f"error: transcription failed: {e}", file=sys.stderr)
        return 4
    elapsed = time.time() - t0

    text = (result.get("text") if isinstance(result, dict) else None) or ""
    text = text.strip()
    language = (result.get("language") if isinstance(result, dict) else None) or "unknown"
    print(f"[whisper] transcribed in {elapsed:.1f}s — {len(text)} chars", flush=True)
    print(f"[whisper] language={language}", flush=True)

    try:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(text, encoding="utf-8")
    except OSError as e:
        print(f"error: writing transcript to {args.out}: {e}", file=sys.stderr)
        return 5

    return 0


if __name__ == "__main__":
    sys.exit(main())
