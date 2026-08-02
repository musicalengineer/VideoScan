#!/usr/bin/env python3
"""Donna Recipe — batch clip scorer for the app's Find & Tag job.

One process per JOB (model prep + gallery embedding paid once), scoring
many clips: reads clip paths from --clips-file (one absolute path per
line), emits one JSON object per line on stdout:

    {"event":"ready","clips":N}                        once, after prep
    {"event":"beat","path":P,"frame":K}                heartbeat ~every 50 frames
    {"event":"result","path":P,"score":S,"frames":F,"faces":G}
    {"event":"result","path":P,"error":"..."}          per-clip failure

The Swift FindPersonJob streams these lines: beats kick the stall
watchdog, results drive progress + tagging. Exit 0 even with per-clip
errors (they are data); nonzero only for setup failures.

Scoring = the smoke-test recipe (recipe_smoke.py): SCRFD-10G detect →
two-tier size gates (small faces confirm at a raised bar, never define)
→ sex gate → ArcFace vs era-banded gallery centroids → top-K mean.
No embeddings are persisted (POI cycle-2 sensitive-data rule).
"""

from __future__ import annotations

import argparse
import json
import pathlib
import shutil
import subprocess
import sys

import numpy as np

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from recipe_smoke import (RECORD_PX, SMALL_FACE_MIN_COS, VOTE_PX,
                          build_era_centroids, face_px)

BEAT_EVERY = 50


def emit(obj) -> None:
    print(json.dumps(obj), flush=True)


def resolve_ffmpeg(explicit: str | None) -> str:
    """The app launches us with a GUI PATH that lacks /opt/homebrew/bin —
    'ffmpeg' bare is a FileNotFoundError there (Rick 2026-08-02: every
    clip errored in ms and the scan looked done in 33 s). Prefer the
    app-provided path, then PATH, then the Homebrew default."""
    import shutil as _shutil
    for candidate in [explicit, _shutil.which("ffmpeg"),
                      "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]:
        if candidate and pathlib.Path(candidate).exists():
            return candidate
    raise FileNotFoundError("ffmpeg not found (pass --ffmpeg)")


def score_clip(app, clip: pathlib.Path, centroids, scratch: pathlib.Path,
               fps: float, top_k: int, ffmpeg: str = "ffmpeg"):
    frames_dir = scratch / f"fp-{clip.stem}-{abs(hash(str(clip))) % 99999}"
    frames_dir.mkdir(parents=True, exist_ok=True)
    try:
        run = subprocess.run(
            [ffmpeg, "-nostdin", "-v", "error", "-i", str(clip),
             "-vf", f"yadif,fps={fps}", "-q:v", "3",
             str(frames_dir / "f%05d.jpg")],
            capture_output=True, text=True, timeout=1800)
        if run.returncode != 0:
            return {"error": f"ffmpeg: {run.stderr.strip()[:120]}"}
        import cv2
        cosines = []
        frames = sorted(frames_dir.glob("f*.jpg"))
        for i, fpath in enumerate(frames):
            if i % BEAT_EVERY == 0:
                emit({"event": "beat", "path": str(clip), "frame": i})
            img = cv2.imread(str(fpath))
            if img is None:
                continue
            for face in app.get(img):
                px = face_px(face)
                if px < RECORD_PX:
                    continue
                if face.gender != 0:
                    continue
                cos = max(float(np.dot(face.normed_embedding, c))
                          for c in centroids.values())
                if px < VOTE_PX and cos < SMALL_FACE_MIN_COS:
                    continue
                cosines.append(cos)
        if not cosines:
            return {"score": 0.0, "frames": len(frames), "faces": 0}
        top = sorted(cosines, reverse=True)[:top_k]
        return {"score": sum(top) / len(top), "frames": len(frames),
                "faces": len(cosines)}
    finally:
        shutil.rmtree(frames_dir, ignore_errors=True)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--gallery", required=True, type=pathlib.Path)
    ap.add_argument("--clips-file", required=True, type=pathlib.Path)
    ap.add_argument("--scratch", type=pathlib.Path,
                    default=pathlib.Path("/private/tmp/videoscan-findperson"))
    ap.add_argument("--fps", type=float, default=2.0)
    ap.add_argument("--top-k", type=int, default=5)
    ap.add_argument("--model-root", type=pathlib.Path,
                    default=pathlib.Path(__file__).parents[2] / ".cache/insightface")
    ap.add_argument("--ffmpeg", default=None,
                    help="explicit ffmpeg path (the app passes ToolLocator's)")
    args = ap.parse_args()
    ffmpeg = resolve_ffmpeg(args.ffmpeg)

    clips = [pathlib.Path(line.strip())
             for line in args.clips_file.read_text().splitlines()
             if line.strip()]
    if not clips:
        print("no clips given", file=sys.stderr)
        return 2

    from insightface.app import FaceAnalysis
    app = FaceAnalysis(
        name="buffalo_l", root=str(args.model_root),
        providers=["CoreMLExecutionProvider", "CPUExecutionProvider"])
    app.prepare(ctx_id=0, det_size=(640, 640))
    centroids = build_era_centroids(app, args.gallery)
    if not centroids:
        print("gallery produced no centroids", file=sys.stderr)
        return 2
    emit({"event": "ready", "clips": len(clips)})

    args.scratch.mkdir(parents=True, exist_ok=True)
    for clip in clips:
        if not clip.exists():
            emit({"event": "result", "path": str(clip), "error": "missing file"})
            continue
        try:
            r = score_clip(app, clip, centroids, args.scratch,
                           args.fps, args.top_k, ffmpeg=ffmpeg)
        except Exception as e:  # per-clip failures are data, not crashes
            r = {"error": f"{type(e).__name__}: {e}"[:160]}
        r["event"] = "result"
        r["path"] = str(clip)
        emit(r)
    return 0


if __name__ == "__main__":
    sys.exit(main())
