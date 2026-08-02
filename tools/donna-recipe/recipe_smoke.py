#!/usr/bin/env python3
"""Donna Recipe — end-to-end smoke test (pre-G2 signal, not a grade).

Runs the recipe skeleton over the labeled DonnaTestVideos corpus:
    ffmpeg frame sampling (deinterlace + fps) → SCRFD-10G detect →
    voting-tier size gate (≥60px) → sex gate (genderage, F) →
    ArcFace embed → max cosine vs ERA-BANDED gallery centroids →
    per-video top-K mean aggregation (C1 pattern).

Reports per-clip scores for Donna/ vs NotDonna/ and the separation
(worst Donna vs best NotDonna). No embeddings persisted (cycle-2 rule);
frames land in a scratch dir and are deleted per clip.

Usage:
    python3.12 tools/donna-recipe/recipe_smoke.py \
        --gallery tests/fixtures/photos/Donna \
        --corpus tests/fixtures/videos/DonnaTestVideos \
        --scratch /private/tmp/donna-smoke --fps 2 --top-k 5
"""

from __future__ import annotations

import argparse
import pathlib
import shutil
import subprocess
import sys
import time

import numpy as np

VOTE_PX = 60
RECORD_PX = 25
SMALL_FACE_MIN_COS = 0.55   # small faces must match STRONGLY to count
VIDEO_SUFFIXES = {".mov", ".mp4", ".m4v", ".avi", ".mts", ".m2ts", ".mxf", ".mkv"}


def load_image(path):
    import cv2
    from PIL import Image, ImageOps
    try:
        with Image.open(path) as im:
            im = ImageOps.exif_transpose(im).convert("RGB")
            return cv2.cvtColor(np.asarray(im), cv2.COLOR_RGB2BGR)
    except Exception:
        return cv2.imread(str(path))


def face_px(face) -> int:
    x1, y1, x2, y2 = face.bbox
    return int(min(x2 - x1, y2 - y1))


def build_era_centroids(app, gallery: pathlib.Path):
    """Per-era L2-normalized centroids from single-face votable photos.
    (Group shots skipped — the report card resolves those; centroids
    only need the unambiguous references.)"""
    centroids = {}
    for era in sorted(d for d in gallery.iterdir() if d.is_dir()):
        embs = []
        for f in sorted(era.iterdir()):
            if f.name.startswith("."):
                continue
            img = load_image(f)
            if img is None:
                continue
            faces = app.get(img)
            if len(faces) == 1 and face_px(faces[0]) >= VOTE_PX:
                embs.append(faces[0].normed_embedding)
        if embs:
            m = np.mean(embs, axis=0)
            centroids[era.name] = m / np.linalg.norm(m)
    return centroids


def clip_score(app, clip: pathlib.Path, centroids, scratch: pathlib.Path,
               fps: float, top_k: int):
    """Sample frames, gate faces, return (score, n_frames, n_gated_faces,
    per-face cosine list). Score = mean of top-K gated-face cosines."""
    frames_dir = scratch / clip.stem
    frames_dir.mkdir(parents=True, exist_ok=True)
    try:
        run = subprocess.run(
            ["ffmpeg", "-nostdin", "-v", "error", "-i", str(clip),
             "-vf", f"yadif,fps={fps}", "-q:v", "3",
             str(frames_dir / "f%05d.jpg")],
            capture_output=True, text=True, timeout=300)
        if run.returncode != 0:
            return None, 0, 0, [], f"ffmpeg: {run.stderr.strip()[:80]}"
        cosines = []
        frames = sorted(frames_dir.glob("f*.jpg"))
        import cv2
        for fpath in frames:
            img = cv2.imread(str(fpath))
            if img is None:
                continue
            for face in app.get(img):
                px = face_px(face)
                if px < RECORD_PX:
                    continue
                if face.gender != 0:      # sex gate: keep female
                    continue
                cos = max(float(np.dot(face.normed_embedding, c))
                          for c in centroids.values())
                # Two-tier MATCHING rule (PhotoPrism semantics, applied
                # correctly after the Donna-14 diagnosis): big faces may
                # contribute any score; small (record-tier) faces only
                # count when they match STRONGLY — they may confirm a
                # known person, never smear weak evidence into the vote.
                if px < VOTE_PX and cos < SMALL_FACE_MIN_COS:
                    continue
                cosines.append(cos)
        if not cosines:
            return 0.0, len(frames), 0, [], None
        top = sorted(cosines, reverse=True)[:top_k]
        return sum(top) / len(top), len(frames), len(cosines), cosines, None
    finally:
        shutil.rmtree(frames_dir, ignore_errors=True)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--gallery", required=True, type=pathlib.Path)
    ap.add_argument("--corpus", required=True, type=pathlib.Path)
    ap.add_argument("--scratch", required=True, type=pathlib.Path)
    ap.add_argument("--fps", type=float, default=2.0)
    ap.add_argument("--top-k", type=int, default=5)
    ap.add_argument("--model-root", type=pathlib.Path,
                    default=pathlib.Path(".cache/insightface"))
    args = ap.parse_args()

    from insightface.app import FaceAnalysis
    app = FaceAnalysis(
        name="buffalo_l", root=str(args.model_root),
        providers=["CoreMLExecutionProvider", "CPUExecutionProvider"])
    app.prepare(ctx_id=0, det_size=(640, 640))

    centroids = build_era_centroids(app, args.gallery)
    print(f"era centroids: {sorted(centroids)}")

    results = []
    t0 = time.time()
    for label_dir in sorted(d for d in args.corpus.iterdir() if d.is_dir()):
        for clip in sorted(label_dir.iterdir()):
            if clip.suffix.lower() not in VIDEO_SUFFIXES:
                continue
            score, n_frames, n_faces, cosines, err = clip_score(
                app, clip, centroids, args.scratch, args.fps, args.top_k)
            results.append((label_dir.name, clip.name, score, n_frames,
                            n_faces, err))
            status = f"{score:.3f}" if score is not None else f"ERR {err}"
            print(f"  {label_dir.name}/{clip.name}: {status} "
                  f"({n_frames} frames, {n_faces} gated faces)")
    elapsed = time.time() - t0

    donna = [r[2] for r in results if r[0].lower() == "donna" and r[2] is not None]
    other = [r[2] for r in results if r[0].lower() != "donna" and r[2] is not None]
    print(f"\n=== {len(results)} clips in {elapsed:.0f}s "
          f"({elapsed / max(len(results),1):.1f}s/clip at {args.fps}fps sampling)")
    if donna and other:
        donna_sorted = sorted(donna)
        other_sorted = sorted(other, reverse=True)
        # Simple AUC via pairwise comparison.
        wins = sum(1 for d in donna for o in other if d > o)
        ties = sum(1 for d in donna for o in other if d == o)
        auc = (wins + ties * 0.5) / (len(donna) * len(other))
        print(f"Donna scores:    min {min(donna):.3f}  median "
              f"{donna_sorted[len(donna)//2]:.3f}  max {max(donna):.3f}")
        print(f"NotDonna scores: min {min(other):.3f}  median "
              f"{sorted(other)[len(other)//2]:.3f}  max {max(other):.3f}")
        print(f"separation: worst-Donna {min(donna):.3f} vs best-NotDonna "
              f"{max(other):.3f}  |  AUC {auc:.3f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
