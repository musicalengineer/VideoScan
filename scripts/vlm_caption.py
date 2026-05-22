#!/usr/bin/env python3
"""Sample N frames from a video and caption each one with an MLX VLM.

Experimental — first pass at evaluating whether vision-language captions
are useful as catalog metadata for VideoScan.

Run from the isolated MLX venv (not the shared dlib/facenet venv, which
pins numpy<2 and is incompatible with current transformers):

    venv-mlx/bin/python scripts/vlm_caption.py <video> [--frames 8]
                                                       [--model mlx-community/...]
                                                       [--prompt "..."]
                                                       [--out captions.json]
                                                       [--max-tokens 120]
"""
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, asdict
from pathlib import Path

DEFAULT_MODEL = "mlx-community/Qwen2.5-VL-3B-Instruct-4bit"
DEFAULT_PROMPT = (
    "Describe this video frame in one or two sentences. "
    "Mention the setting, the people (count, approximate ages, what they are doing), "
    "and any visible text, dates, or signs. Be concrete, not flowery."
)


@dataclass
class FrameCaption:
    index: int
    timestamp: float
    caption: str
    elapsed_s: float


def probe_duration(video: Path) -> float:
    out = subprocess.check_output(
        [
            "ffprobe", "-v", "error",
            "-show_entries", "format=duration",
            "-of", "default=nokey=1:noprint_wrappers=1",
            str(video),
        ],
        text=True,
    ).strip()
    return float(out)


def sample_timestamps(duration: float, n: int) -> list[float]:
    if n <= 0:
        return []
    if n == 1:
        return [duration / 2.0]
    # Avoid the first/last 5% — usually black/credits.
    pad = max(0.1, duration * 0.05)
    start = pad
    end = max(start + 0.01, duration - pad)
    step = (end - start) / (n - 1)
    return [start + i * step for i in range(n)]


def extract_frame(video: Path, ts: float, dest: Path) -> None:
    subprocess.check_call(
        [
            "ffmpeg", "-nostdin", "-loglevel", "error", "-y",
            "-ss", f"{ts:.3f}",
            "-i", str(video),
            "-frames:v", "1",
            "-q:v", "2",
            str(dest),
        ]
    )


def caption_frames(model_id: str, prompt: str, frames: list[Path], max_tokens: int) -> list[str]:
    """Load VLM once, caption each frame. Returns list of captions aligned with frames."""
    from mlx_vlm import load, generate
    from mlx_vlm.prompt_utils import apply_chat_template

    print(f"[vlm] loading {model_id} ...", flush=True)
    t0 = time.time()
    model, processor = load(model_id)
    # mlx-vlm exposes config on model.config in recent versions.
    config = getattr(model, "config", None)
    print(f"[vlm] loaded in {time.time() - t0:.1f}s", flush=True)

    captions: list[str] = []
    for i, frame in enumerate(frames):
        templated = apply_chat_template(processor, config, prompt, num_images=1)
        result = generate(
            model, processor, templated,
            image=[str(frame)],
            max_tokens=max_tokens,
            verbose=False,
        )
        # mlx-vlm returns either a string or a GenerateResult object depending on version.
        text = result if isinstance(result, str) else getattr(result, "text", str(result))
        captions.append(text.strip())
    return captions


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("video", type=Path)
    ap.add_argument("--frames", type=int, default=8)
    ap.add_argument("--model", default=DEFAULT_MODEL)
    ap.add_argument("--prompt", default=DEFAULT_PROMPT)
    ap.add_argument("--out", type=Path, help="Write JSON results to this path")
    ap.add_argument("--max-tokens", type=int, default=120)
    args = ap.parse_args()

    if not args.video.is_file():
        print(f"error: {args.video} not found", file=sys.stderr)
        return 2
    if not shutil.which("ffmpeg") or not shutil.which("ffprobe"):
        print("error: ffmpeg/ffprobe not on PATH", file=sys.stderr)
        return 2

    duration = probe_duration(args.video)
    ts_list = sample_timestamps(duration, args.frames)
    print(f"[vlm] {args.video.name}: {duration:.2f}s, sampling {len(ts_list)} frames", flush=True)

    with tempfile.TemporaryDirectory(prefix="vlm-frames-") as tmp:
        tmp_dir = Path(tmp)
        frame_paths: list[Path] = []
        for i, ts in enumerate(ts_list):
            dest = tmp_dir / f"frame_{i:03d}.png"
            extract_frame(args.video, ts, dest)
            frame_paths.append(dest)

        t0 = time.time()
        captions = caption_frames(args.model, args.prompt, frame_paths, args.max_tokens)
        total = time.time() - t0
        per_frame = total / max(len(captions), 1)

    results = [
        FrameCaption(index=i, timestamp=ts, caption=cap, elapsed_s=per_frame)
        for i, (ts, cap) in enumerate(zip(ts_list, captions))
    ]

    print()
    print(f"=== {args.video.name} — {len(results)} frames, {total:.1f}s total ({per_frame:.2f}s/frame) ===")
    for r in results:
        print(f"  [{r.timestamp:6.2f}s]  {r.caption}")

    if args.out:
        payload = {
            "video": str(args.video),
            "duration_s": duration,
            "model": args.model,
            "prompt": args.prompt,
            "total_caption_s": total,
            "frames": [asdict(r) for r in results],
        }
        args.out.write_text(json.dumps(payload, indent=2))
        print(f"\n[vlm] wrote {args.out}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
