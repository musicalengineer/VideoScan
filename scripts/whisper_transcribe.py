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

Then call from the Swift app, or by hand:

    venv-mlx/bin/python scripts/whisper_transcribe.py <audio-or-video> \
        --model mlx-community/whisper-medium-mlx-q4 --out /tmp/t.txt
"""
from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path


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

    # Late import — if the user runs this from the wrong venv, the
    # error message says so before we try to do anything else.
    try:
        import mlx_whisper
    except ImportError as e:
        print(f"error: mlx_whisper not installed in this Python environment: {e}", file=sys.stderr)
        print("hint: pip install mlx-whisper (in venv-mlx)", file=sys.stderr)
        return 3

    print(f"[whisper] loading {args.model} ...", flush=True)
    t0 = time.time()
    # mlx_whisper.transcribe loads the model on demand and caches it
    # to ~/.cache/huggingface. First call pays the download cost
    # (~244 MB for medium-q4), subsequent calls are warm-start.
    kwargs = {"path_or_hf_repo": args.model}
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
    print(f"[whisper] transcribed in {elapsed:.1f}s — {len(text)} chars", flush=True)

    try:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(text, encoding="utf-8")
    except OSError as e:
        print(f"error: writing transcript to {args.out}: {e}", file=sys.stderr)
        return 5

    return 0


if __name__ == "__main__":
    sys.exit(main())
