#!/usr/bin/env python3.12
"""
fd_scan_volume.py — find videos containing a given person on a volume.

Tier 1B of the Media Analyzer plan: prove the Donna-gallery + generic
embedder approach works end-to-end on real home video. Produces a ranked
CSV + top-N list the user can verify by eye.

Pipeline per video:
  1. ffprobe for duration (skip <30s, >4hr, unreadable)
  2. ffmpeg samples N frames evenly spaced
  3. MTCNN finds faces in each frame (multiple OK)
  4. FaceNet (VGGFace2) embeds each face
  5. For each face, compute min cosine distance to the target gallery
  6. Classify each frame-face as strong/weak/miss
  7. Classify the video as hit/weak/miss by hit count + thresholds

Streams results to CSV as it goes — safe to kill mid-run and still
get partial data.

Usage:
    python3.12 fd_scan_volume.py <root_dir> [--person donna]
                                            [--frame-interval 5]
                                            [--max-frames 120]
                                            [--strong-thresh 0.60]
                                            [--weak-thresh 0.75]
                                            [--margin 0.08]
"""

from __future__ import annotations
import argparse
import csv
import json
import os
import subprocess
import sys
import time
import tempfile
from pathlib import Path
from dataclasses import dataclass
from typing import Optional

import numpy as np
import torch
from PIL import Image, ImageOps
from facenet_pytorch import MTCNN, InceptionResnetV1

REPO = Path(__file__).resolve().parent.parent
EMB_PATH = REPO / "output/fd_diagnostic/embeddings.npz"
OUT_DIR = REPO / "output/fd_scan_volume"
OUT_DIR.mkdir(parents=True, exist_ok=True)

VIDEO_EXTS = {
    ".mp4", ".mov", ".m4v", ".avi", ".mkv", ".wmv", ".flv",
    ".mts", ".m2ts", ".mpg", ".mpeg", ".3gp", ".webm", ".ogv",
    ".dv", ".divx", ".vob", ".ts"
}
# Skip tree patterns that are rarely user media
SKIP_DIR_PATTERNS = {
    ".Spotlight-V100", ".Trashes", ".DocumentRevisions-V100",
    ".fseventsd", "System Volume Information", "$RECYCLE.BIN",
    ".TemporaryItems", "node_modules", ".git", "venv", ".venv",
}

DEVICE = (torch.device("mps") if torch.backends.mps.is_available()
          else torch.device("cpu"))


# --- Gallery load ----------------------------------------------------------

def load_gallery(person: str) -> np.ndarray:
    if not EMB_PATH.exists():
        sys.exit(f"No embeddings at {EMB_PATH}. Run fd_diagnostic.py first.")
    data = np.load(EMB_PATH, allow_pickle=True)
    persons = data["persons"]
    fnet_mask = data["facenet_mask"]
    fnet = data["facenet"]
    # persons array is indexed by all photos; facenet array only has mask==True entries
    indices_by_person = []
    fnet_idx = 0
    for i, p in enumerate(persons):
        if fnet_mask[i]:
            if p == person:
                indices_by_person.append(fnet_idx)
            fnet_idx += 1
    if not indices_by_person:
        sys.exit(f"No facenet embeddings for person '{person}' in {EMB_PATH}")
    gal = fnet[indices_by_person]
    print(f"[gallery] loaded {len(gal)} facenet vectors for '{person}'")
    return gal  # shape (G, 512), already L2-normed


# --- Video utilities -------------------------------------------------------

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


def extract_frames(path: Path, duration: float, interval_s: float,
                    max_frames: int, tmpdir: Path) -> list[Path]:
    """Extract evenly-spaced frames via per-timestamp ffmpeg -ss seek.

    Much faster than the fps filter on long videos because each -ss does a
    fast keyframe seek instead of decoding the whole file. Timeout is per
    call (not per video) so a 2-hour video never hangs the scan.
    """
    # How many frames to pull? evenly spaced, avoiding the first/last 2s
    usable = max(1.0, duration - 4.0)
    n = min(max_frames, max(4, int(usable / interval_s)))
    # Timestamps: n points evenly in [2, duration-2]
    starts = [2.0 + (i + 0.5) * usable / n for i in range(n)]

    frames: list[Path] = []
    for i, ts in enumerate(starts):
        out = tmpdir / f"f_{i:05d}.jpg"
        # -ss before -i = fast (keyframe-accurate) seek
        cmd = [
            "ffmpeg", "-y", "-v", "error",
            "-ss", f"{ts:.2f}",
            "-i", str(path),
            "-frames:v", "1",
            "-vf", "scale='min(640,iw)':'-2'",
            "-q:v", "4",
            "-an",
            str(out)
        ]
        try:
            subprocess.run(cmd, timeout=15, capture_output=True)
        except subprocess.TimeoutExpired:
            continue
        except Exception:
            continue
        if out.exists() and out.stat().st_size > 0:
            frames.append(out)
    return frames


# --- Face detection + embed ------------------------------------------------

def embed_faces_in_frame(mtcnn: MTCNN, resnet: InceptionResnetV1,
                         img_path: Path) -> list[np.ndarray]:
    """Return list of L2-normed 512-D facenet embeddings for faces in frame."""
    try:
        img = Image.open(img_path)
        img = ImageOps.exif_transpose(img).convert("RGB")
    except Exception:
        return []
    boxes, probs = mtcnn.detect(img)
    if boxes is None:
        return []
    embs = []
    for b in boxes:
        x1, y1, x2, y2 = b
        w, h = x2 - x1, y2 - y1
        if w < 24 or h < 24:   # skip tiny faces
            continue
        cx, cy = x1 + w/2, y1 + h/2
        side = max(w, h) * 1.2
        fx1 = max(0, cx - side/2)
        fy1 = max(0, cy - side/2)
        fx2 = min(img.width, cx + side/2)
        fy2 = min(img.height, cy + side/2)
        face = img.crop((fx1, fy1, fx2, fy2)).resize((160, 160), Image.BILINEAR)
        arr = np.asarray(face, dtype=np.float32)
        arr = (arr - 127.5) / 128.0
        tensor = torch.from_numpy(arr).permute(2, 0, 1).unsqueeze(0).to(DEVICE)
        with torch.no_grad():
            e = resnet(tensor).cpu().numpy()[0]
        e = e / (np.linalg.norm(e) + 1e-9)
        embs.append(e)
    return embs


def min_distance_to_gallery(face_emb: np.ndarray,
                            gallery: np.ndarray) -> float:
    """Cosine distance (1 - cos_sim) min over gallery."""
    sims = gallery @ face_emb
    return float(1.0 - np.max(sims))


# --- Video walker ----------------------------------------------------------

def iter_videos(root: Path):
    root = root.resolve()
    for dirpath, dirnames, filenames in os.walk(root, topdown=True,
                                                  followlinks=False):
        # prune unwanted dirs
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIR_PATTERNS
                        and not d.startswith(".")]
        for fn in filenames:
            if fn.startswith("."):
                continue
            ext = os.path.splitext(fn)[1].lower()
            if ext in VIDEO_EXTS:
                yield Path(dirpath) / fn


# --- Per-video scan --------------------------------------------------------

@dataclass
class VideoResult:
    path: Path
    duration: Optional[float]
    frames_scanned: int
    frames_with_faces: int
    strong_hits: int
    weak_hits: int
    best_min_dist: float = 1.0     # lower is better
    avg_min_dist: float = 1.0
    err: str = ""

    def verdict(self, strong_thresh: float) -> str:
        if self.strong_hits >= 3:
            return "STRONG"
        if self.strong_hits >= 1 or self.weak_hits >= 5:
            return "WEAK"
        return "NO"


def scan_video(path: Path, mtcnn, resnet, gallery: np.ndarray,
                args) -> VideoResult:
    dur = ffprobe_duration(path)
    if dur is None:
        return VideoResult(path, None, 0, 0, 0, 0, err="probe_failed")
    if dur < 30 or dur > 14400:
        return VideoResult(path, dur, 0, 0, 0, 0, err="out_of_range")

    # Sample interval scales with duration: target ~max_frames sampled
    target_interval = max(args.frame_interval,
                           dur / args.max_frames)

    with tempfile.TemporaryDirectory(prefix="fdvol_") as td:
        tmpdir = Path(td)
        frames = extract_frames(path, dur, target_interval,
                                 args.max_frames, tmpdir)
        if not frames:
            return VideoResult(path, dur, 0, 0, 0, 0, err="no_frames")

        min_dists: list[float] = []
        frames_with_faces = 0
        strong = 0
        weak = 0
        for fp in frames:
            face_embs = embed_faces_in_frame(mtcnn, resnet, fp)
            if not face_embs:
                continue
            frames_with_faces += 1
            # Best match for this frame = the face closest to the gallery
            frame_min = min(min_distance_to_gallery(e, gallery)
                             for e in face_embs)
            min_dists.append(frame_min)
            if frame_min < args.strong_thresh:
                strong += 1
            elif frame_min < args.weak_thresh:
                weak += 1

        r = VideoResult(path, dur, len(frames), frames_with_faces,
                         strong, weak)
        if min_dists:
            r.best_min_dist = float(min(min_dists))
            r.avg_min_dist = float(np.mean(min_dists))
        return r


# --- Driver ----------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("root", type=Path)
    ap.add_argument("--person", default="donna")
    ap.add_argument("--frame-interval", type=float, default=5.0,
                     help="seconds between sampled frames (default 5)")
    ap.add_argument("--max-frames", type=int, default=120,
                     help="max frames sampled per video (default 120)")
    ap.add_argument("--strong-thresh", type=float, default=0.60,
                     help="cosine distance threshold for strong hit")
    ap.add_argument("--weak-thresh", type=float, default=0.75,
                     help="cosine distance threshold for weak hit")
    ap.add_argument("--limit", type=int, default=0,
                     help="only scan first N videos (0 = no limit)")
    args = ap.parse_args()

    if not args.root.exists():
        sys.exit(f"Root not found: {args.root}")

    gallery = load_gallery(args.person)

    print(f"[init] loading models (MTCNN cpu, FaceNet {DEVICE})…")
    mtcnn = MTCNN(keep_all=True, device=torch.device("cpu"),
                   post_process=False, min_face_size=40)
    resnet = InceptionResnetV1(pretrained="vggface2").eval().to(DEVICE)

    run_tag = time.strftime("%Y%m%d_%H%M%S")
    csv_path = OUT_DIR / f"scan_{args.person}_{run_tag}.csv"
    topN_path = OUT_DIR / f"top_{args.person}_{run_tag}.md"
    print(f"[out] streaming CSV → {csv_path}")

    cols = ["path", "duration_s", "frames_scanned", "frames_with_faces",
            "strong_hits", "weak_hits", "best_min_dist", "avg_min_dist",
            "verdict", "error"]

    t_start = time.time()
    all_results: list[VideoResult] = []
    videos_iter = iter_videos(args.root)
    with csv_path.open("w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(cols)
        fh.flush()
        for i, vpath in enumerate(videos_iter, 1):
            if args.limit and i > args.limit:
                break
            try:
                r = scan_video(vpath, mtcnn, resnet, gallery, args)
            except KeyboardInterrupt:
                raise
            except Exception as exc:
                r = VideoResult(vpath, None, 0, 0, 0, 0,
                                 err=f"scan_err:{exc}")
            verdict = r.verdict(args.strong_thresh)
            w.writerow([
                str(r.path),
                f"{r.duration:.1f}" if r.duration else "",
                r.frames_scanned, r.frames_with_faces,
                r.strong_hits, r.weak_hits,
                f"{r.best_min_dist:.3f}",
                f"{r.avg_min_dist:.3f}",
                verdict, r.err
            ])
            fh.flush()
            all_results.append(r)
            elapsed = time.time() - t_start
            rate = i / elapsed if elapsed > 0 else 0
            print(f"[{i:5d}] {elapsed/60:6.1f}min  "
                  f"{verdict:6s}  s={r.strong_hits:3d} w={r.weak_hits:3d}  "
                  f"best={r.best_min_dist:.3f}  "
                  f"{r.path.name[:60]}")

    # Write ranked top-N markdown
    ranked = [r for r in all_results if r.strong_hits >= 1 or r.weak_hits >= 1]
    ranked.sort(key=lambda r: (-r.strong_hits, -r.weak_hits, r.best_min_dist))
    with topN_path.open("w") as f:
        f.write(f"# Videos likely containing '{args.person}'\n\n")
        f.write(f"Scanned: {args.root}\n")
        f.write(f"Run: {run_tag}\n")
        f.write(f"Total videos scanned: {len(all_results)}\n")
        f.write(f"Any-hit videos: {len(ranked)}\n")
        strong_videos = [r for r in ranked if r.strong_hits >= 3]
        f.write(f"STRONG-verdict videos: {len(strong_videos)}\n\n")
        f.write("| rank | verdict | strong | weak | best_dist | duration | path |\n")
        f.write("|------|---------|--------|------|-----------|----------|------|\n")
        for rank, r in enumerate(ranked[:200], 1):
            v = r.verdict(args.strong_thresh)
            dur = f"{r.duration/60:.1f}m" if r.duration else "?"
            f.write(f"| {rank} | {v} | {r.strong_hits} | {r.weak_hits} | "
                    f"{r.best_min_dist:.3f} | {dur} | "
                    f"`{r.path}` |\n")
    print(f"\n[done] {len(all_results)} videos, "
          f"{len(ranked)} with any hit, "
          f"{sum(1 for r in ranked if r.strong_hits >= 3)} STRONG.")
    print(f"[top-N] → {topN_path}")


if __name__ == "__main__":
    main()
