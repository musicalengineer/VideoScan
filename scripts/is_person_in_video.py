#!/usr/bin/env python3.12
"""
is_person_in_video.py — answer "is X in this video?" for one or more POIs.

Surgical CLI for the question that the full Find Person scanner over-answers.
Takes one video + one or more POI reference folders, returns yes/no per POI
with confidence and presence estimate. No clip extraction, no compilation,
no catalog mutation. Just the answer, scriptable for batch use.

Usage:
    scripts/is_person_in_video.py \\
        --video /path/to/clip.mov \\
        --poi  "$HOME/Library/Application Support/VideoScan/POI/donna" \\
        [--poi  "...another"] \\
        [--threshold 0.40]      # cosine similarity floor (FaceNet vggface2)
        [--frame-step 5]        # seconds between sampled frames
        [--max-frames 120]      # cap; default keeps runtime predictable
        [--quiet]               # machine-readable single line

Exit codes:
    0  — at least one POI detected above threshold
    1  — no POI detected
    2  — error (missing file, no faces, model load failure)
"""
from __future__ import annotations
import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Optional

import numpy as np
from PIL import Image, ImageOps

# Ensure ffmpeg/ffprobe on PATH when invoked from a GUI subprocess (matches
# cluster_faces.py — same Homebrew gotcha).
os.environ["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + os.environ.get("PATH", "")

IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".heic", ".heif", ".bmp", ".webp"}

_torch = None
_mtcnn = None
_resnet = None
_device = None


def init_models() -> None:
    """Lazy-load torch + facenet (slow first import, ~3-5s)."""
    global _torch, _mtcnn, _resnet, _device
    if _torch is not None:
        return
    import torch
    from facenet_pytorch import MTCNN, InceptionResnetV1
    _torch = torch
    _device = (torch.device("mps") if torch.backends.mps.is_available()
               else torch.device("cpu"))
    # MTCNN on CPU per cluster_faces.py — adaptive_avg_pool2d MPS bug.
    _mtcnn = MTCNN(keep_all=True, device=torch.device("cpu"), post_process=False)
    _resnet = InceptionResnetV1(pretrained="vggface2").eval().to(_device)


def detect_and_embed(img: Image.Image) -> list[tuple[np.ndarray, float]]:
    """Run MTCNN + FaceNet on one frame. Returns [(embedding_512d, prob), ...]."""
    boxes, probs = _mtcnn.detect(img)
    if boxes is None:
        return []
    out: list[tuple[np.ndarray, float]] = []
    for box, prob in zip(boxes, probs):
        x1, y1, x2, y2 = box
        w, h = x2 - x1, y2 - y1
        if w < 24 or h < 24:
            continue
        cx, cy = x1 + w / 2, y1 + h / 2
        side = max(w, h) * 1.2
        fx1 = max(0, cx - side / 2)
        fy1 = max(0, cy - side / 2)
        fx2 = min(img.width, cx + side / 2)
        fy2 = min(img.height, cy + side / 2)
        face = img.crop((fx1, fy1, fx2, fy2)).resize((160, 160), Image.BILINEAR)
        arr = np.asarray(face, dtype=np.float32)
        arr = (arr - 127.5) / 128.0
        tensor = _torch.from_numpy(arr).permute(2, 0, 1).unsqueeze(0).to(_device)
        with _torch.no_grad():
            e = _resnet(tensor).cpu().numpy()[0]
        e = e / (np.linalg.norm(e) + 1e-9)
        out.append((e, float(prob) if prob is not None else 0.0))
    return out


def load_poi_embeddings(poi_dir: Path) -> tuple[str, np.ndarray]:
    """Return (poi_name, [embeddings_NxD]) for all reference photos in a folder.
    Photos with multiple faces use the largest one. Photos with no detectable
    face are skipped. Returns empty array if the folder yields zero usable refs."""
    name = poi_dir.name
    photos = sorted(p for p in poi_dir.iterdir() if p.suffix.lower() in IMAGE_EXTS)
    embeddings: list[np.ndarray] = []
    for p in photos:
        try:
            img = ImageOps.exif_transpose(Image.open(p)).convert("RGB")
        except Exception:
            continue
        faces = detect_and_embed(img)
        if not faces:
            continue
        # Keep the highest-confidence detection from this reference photo.
        faces.sort(key=lambda x: x[1], reverse=True)
        embeddings.append(faces[0][0])
    if not embeddings:
        return name, np.empty((0, 512), dtype=np.float32)
    return name, np.stack(embeddings, axis=0)


def ffprobe_duration(path: Path) -> Optional[float]:
    try:
        out = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration",
             "-of", "default=noprint_wrappers=1:nokey=1", str(path)],
            capture_output=True, text=True, timeout=30)
        if out.returncode != 0:
            return None
        s = out.stdout.strip()
        return float(s) if s else None
    except Exception:
        return None


def extract_frames(video: Path, duration: float, interval_s: float,
                   max_frames: int, tmpdir: Path) -> list[tuple[float, Path]]:
    """Sample evenly-spaced frames. Same shape as cluster_faces.extract_frames."""
    usable = max(1.0, duration - 4.0)
    n = min(max_frames, max(4, int(usable / interval_s)))
    starts = [2.0 + (i + 0.5) * usable / n for i in range(n)]
    frames: list[tuple[float, Path]] = []
    for i, ts in enumerate(starts):
        out = tmpdir / f"f_{i:05d}.jpg"
        cmd = ["ffmpeg", "-y", "-v", "error", "-hwaccel", "videotoolbox", "-ss", f"{ts:.2f}",
               "-i", str(video), "-frames:v", "1",
               "-vf", "scale='min(640,iw)':'-2'",
               "-q:v", "4", "-an", str(out)]
        try:
            subprocess.run(cmd, timeout=15, capture_output=True)
        except Exception:
            continue
        if out.exists() and out.stat().st_size > 0:
            frames.append((ts, out))
    return frames


def cosine_max(face_emb: np.ndarray, ref_embs: np.ndarray) -> float:
    """Best cosine similarity of one face embedding against a stack of refs.
    Both inputs are L2-normalized, so dot-product == cosine similarity."""
    if ref_embs.size == 0:
        return 0.0
    sims = ref_embs @ face_emb
    return float(sims.max())


def format_secs(s: float) -> str:
    s = max(0, int(s))
    return f"{s // 60}m {s % 60}s" if s >= 60 else f"{s}s"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--video", type=Path, required=True)
    ap.add_argument("--poi", type=Path, required=True, action="append",
                    help="POI reference folder (repeatable)")
    ap.add_argument("--threshold", type=float, default=0.40,
                    help="cosine similarity floor (FaceNet vggface2; default 0.40)")
    ap.add_argument("--frame-step", type=float, default=5.0,
                    help="seconds between sampled frames (default 5)")
    ap.add_argument("--max-frames", type=int, default=120,
                    help="max sampled frames per video (default 120)")
    ap.add_argument("--quiet", action="store_true",
                    help="single-line machine-readable output")
    args = ap.parse_args()

    if not args.video.exists():
        print(f"error: video not found: {args.video}", file=sys.stderr)
        return 2

    duration = ffprobe_duration(args.video)
    if duration is None:
        print(f"error: ffprobe could not read {args.video}", file=sys.stderr)
        return 2

    init_models()

    pois: list[tuple[str, np.ndarray]] = []
    for d in args.poi:
        if not d.is_dir():
            print(f"error: POI folder not found: {d}", file=sys.stderr)
            return 2
        name, embs = load_poi_embeddings(d)
        if embs.shape[0] == 0:
            print(f"error: no usable reference faces in {d}", file=sys.stderr)
            return 2
        pois.append((name, embs))
        if not args.quiet:
            print(f"[ref] {name}: {embs.shape[0]} reference embeddings", file=sys.stderr)

    with tempfile.TemporaryDirectory() as td:
        tmpdir = Path(td)
        frames = extract_frames(args.video, duration, args.frame_step,
                                args.max_frames, tmpdir)
        if not frames:
            print(f"error: extracted 0 frames from {args.video}", file=sys.stderr)
            return 2

        per_poi_best: dict[str, tuple[float, float]] = {n: (0.0, -1.0) for n, _ in pois}
        per_poi_hits: dict[str, int] = {n: 0 for n, _ in pois}
        total_face_frames = 0

        for ts, frame_path in frames:
            try:
                img = ImageOps.exif_transpose(Image.open(frame_path)).convert("RGB")
            except Exception:
                continue
            faces = detect_and_embed(img)
            if not faces:
                continue
            total_face_frames += 1
            for emb, _prob in faces:
                for name, refs in pois:
                    sim = cosine_max(emb, refs)
                    best_sim, _ = per_poi_best[name]
                    if sim > best_sim:
                        per_poi_best[name] = (sim, ts)
                    if sim >= args.threshold:
                        per_poi_hits[name] += 1
                        break  # one face suffices; don't double-count this frame

        any_found = False
        for name, _refs in pois:
            best, best_ts = per_poi_best[name]
            hits = per_poi_hits[name]
            sampled = len(frames)
            presence = (hits / sampled) * duration if sampled else 0.0
            found = best >= args.threshold

            if args.quiet:
                # video=path person=Donna found=true conf=0.987 presence=92s sampled=120
                print(f"video={args.video} person={name} found={'true' if found else 'false'} "
                      f"conf={best:.3f} presence={int(presence)}s sampled={sampled}")
            else:
                mark = "✓" if found else "✗"
                if found:
                    pct = (presence / duration * 100) if duration > 0 else 0.0
                    print(f"{mark} {name} detected in {args.video.name}")
                    print(f"  Best confidence: {best:.3f} (cosine, threshold {args.threshold:.2f})")
                    print(f"  Presence: ~{format_secs(presence)} of {format_secs(duration)} "
                          f"({pct:.1f}%)")
                    print(f"  Strongest match at: ~{format_secs(best_ts)} "
                          f"(frame {hits}/{sampled} sampled)")
                else:
                    print(f"{mark} {name} not detected in {args.video.name}")
                    print(f"  Best similarity: {best:.3f} (below threshold {args.threshold:.2f})")
                    print(f"  Frames with faces: {total_face_frames}/{sampled} sampled")
            any_found = any_found or found

        return 0 if any_found else 1


if __name__ == "__main__":
    sys.exit(main())
