#!/usr/bin/env python3.12
"""
cluster_faces.py — find and cluster every face in a folder of videos.

The "Identify Family" pipeline, prototype edition. Walks a folder of
videos, detects every face, embeds it with FaceNet, then clusters all
embeddings together with HDBSCAN. Outputs per-cluster thumbnail folders
plus a 4x4 grid per cluster for quick eyeballing.

The point: instead of running 20 reference-based searches ("find
Donna", "find Tim", etc.), one pass produces named-able clusters.
A 1,000-frame cluster is one person to label, not 1,000 frames.

Pipeline:
  1. Walk videos under <root>
  2. Per video: ffprobe duration, ffmpeg sample N frames, MTCNN detect
     each frame, FaceNet embed each face (uses MPS on Apple Silicon)
  3. Save every face crop + its 512-D embedding + metadata
  4. After collection: HDBSCAN on the full embedding pool
  5. Group thumbnails by cluster, write 4x4 montage per cluster

Output (in output/cluster_faces/<run_name>/):
  faces.npz                         — embeddings + metadata for every face
  face_thumbs/face_NNNNN.jpg        — every face crop (160x160 RGB)
  clusters/cluster_NNN/             — symlinks to face crops in this cluster
  clusters/cluster_NNN/grid.jpg     — 4x4 representative montage
  cluster_summary.csv               — cluster_id, face_count, video_count
  noise/                            — face crops HDBSCAN couldn't cluster
  scan.log                          — per-video progress

Resumable: re-running on the same root with --run-name <existing> picks
up where it left off (skips videos already scanned). Re-clustering with
different params is fast — embeddings are persisted.

Usage:
  cluster_faces.py /Volumes/MyBook3Terabytes/Christmas_2010
  cluster_faces.py <root> --run-name christmas2010 --min-cluster-size 15
  cluster_faces.py <root> --cluster-only --run-name christmas2010
"""

from __future__ import annotations
import argparse
import csv
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from dataclasses import dataclass, field, asdict
from typing import Optional

import numpy as np
from PIL import Image, ImageOps

REPO = Path(__file__).resolve().parent.parent
DEFAULT_OUT = REPO / "output/cluster_faces"

VIDEO_EXTS = {
    ".mp4", ".mov", ".m4v", ".avi", ".mkv", ".wmv", ".flv",
    ".mts", ".m2ts", ".mpg", ".mpeg", ".3gp", ".webm", ".ogv",
    ".dv", ".divx", ".vob", ".ts"
}
SKIP_DIR_PATTERNS = {
    ".Spotlight-V100", ".Trashes", ".DocumentRevisions-V100",
    ".fseventsd", "System Volume Information", "$RECYCLE.BIN",
    ".TemporaryItems", "node_modules", ".git", "venv", ".venv",
}


# --- Lazy heavy imports ----------------------------------------------------

_torch = None
_mtcnn = None
_resnet = None
_device = None


def _init_models():
    """Load torch / facenet only when needed (slow on first import)."""
    global _torch, _mtcnn, _resnet, _device
    if _torch is not None:
        return
    import torch
    from facenet_pytorch import MTCNN, InceptionResnetV1
    _torch = torch
    _device = (torch.device("mps") if torch.backends.mps.is_available()
               else torch.device("cpu"))
    _mtcnn = MTCNN(keep_all=True, device=_device, post_process=False)
    _resnet = InceptionResnetV1(pretrained="vggface2").eval().to(_device)
    print(f"[init] models loaded on {_device}")


# --- Video walking + frame extraction --------------------------------------

def iter_videos(root: Path):
    root = root.resolve()
    for dirpath, dirnames, filenames in os.walk(root, topdown=True,
                                                  followlinks=False):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIR_PATTERNS
                       and not d.startswith(".")]
        for fn in sorted(filenames):
            if fn.startswith("."):
                continue
            ext = os.path.splitext(fn)[1].lower()
            if ext in VIDEO_EXTS:
                yield Path(dirpath) / fn


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
                   max_frames: int, tmpdir: Path) -> list[tuple[float, Path]]:
    """Return [(timestamp, jpg_path), ...] for sampled frames."""
    usable = max(1.0, duration - 4.0)
    n = min(max_frames, max(4, int(usable / interval_s)))
    starts = [2.0 + (i + 0.5) * usable / n for i in range(n)]

    frames: list[tuple[float, Path]] = []
    for i, ts in enumerate(starts):
        out = tmpdir / f"f_{i:05d}.jpg"
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
        except Exception:
            continue
        if out.exists() and out.stat().st_size > 0:
            frames.append((ts, out))
    return frames


# --- Face detect + embed ---------------------------------------------------

@dataclass
class FaceRecord:
    face_id: int
    video_path: str
    frame_time_s: float
    bbox: tuple[float, float, float, float]   # x1, y1, x2, y2 in source coords
    detect_score: float


def detect_and_embed(img_path: Path) -> list[tuple[FaceRecord, np.ndarray, Image.Image]]:
    """Run MTCNN+FaceNet on one frame.

    Returns [(face_record_partial, embedding, face_crop_image), ...].
    face_id and frame_time_s on the FaceRecord get filled in by caller.
    """
    try:
        img = Image.open(img_path)
        img = ImageOps.exif_transpose(img).convert("RGB")
    except Exception:
        return []
    boxes, probs = _mtcnn.detect(img)
    if boxes is None:
        return []

    out = []
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

        rec = FaceRecord(
            face_id=-1,
            video_path="",
            frame_time_s=-1.0,
            bbox=(float(x1), float(y1), float(x2), float(y2)),
            detect_score=float(prob) if prob is not None else 0.0
        )
        out.append((rec, e, face))
    return out


# --- Collection phase ------------------------------------------------------

def collect_faces(root: Path, run_dir: Path, args) -> int:
    """Walk videos under root, save face crops + embeddings.

    Returns total face count.
    """
    _init_models()

    thumbs_dir = run_dir / "face_thumbs"
    thumbs_dir.mkdir(parents=True, exist_ok=True)
    log_path = run_dir / "scan.log"
    progress_path = run_dir / "progress.json"
    embeddings_path = run_dir / "faces.npz"

    # Resume support: load existing progress
    seen_videos: set[str] = set()
    face_records: list[FaceRecord] = []
    embeddings: list[np.ndarray] = []
    if progress_path.exists():
        with progress_path.open() as f:
            state = json.load(f)
        seen_videos = set(state.get("seen_videos", []))
        face_records = [FaceRecord(**r) for r in state.get("face_records", [])]
        if embeddings_path.exists():
            data = np.load(embeddings_path)
            embeddings = list(data["embeddings"])
        print(f"[resume] {len(seen_videos)} videos already scanned, "
              f"{len(face_records)} faces collected")

    next_face_id = max((r.face_id for r in face_records), default=-1) + 1

    log = log_path.open("a")
    log.write(f"\n=== run {time.strftime('%Y-%m-%d %H:%M:%S')} ===\n")

    videos = list(iter_videos(root))
    print(f"[scan] {len(videos)} videos under {root}")

    for vi, vpath in enumerate(videos):
        if str(vpath) in seen_videos:
            continue

        dur = ffprobe_duration(vpath)
        if dur is None or dur < 5 or dur > 14400:
            log.write(f"SKIP\t{vpath}\tduration={dur}\n")
            seen_videos.add(str(vpath))
            continue

        target_interval = max(args.frame_interval, dur / args.max_frames)

        n_added = 0
        with tempfile.TemporaryDirectory(prefix="cluster_") as td:
            tmpdir = Path(td)
            frames = extract_frames(vpath, dur, target_interval,
                                     args.max_frames, tmpdir)
            for ts, fp in frames:
                results = detect_and_embed(fp)
                for rec, emb, crop in results:
                    rec.face_id = next_face_id
                    rec.video_path = str(vpath)
                    rec.frame_time_s = ts
                    crop.save(thumbs_dir / f"face_{next_face_id:06d}.jpg",
                              "JPEG", quality=85)
                    face_records.append(rec)
                    embeddings.append(emb)
                    next_face_id += 1
                    n_added += 1

        seen_videos.add(str(vpath))
        log.write(f"OK\t{vpath}\tduration={dur:.1f}\tfaces={n_added}\n")
        log.flush()
        print(f"[{vi+1}/{len(videos)}] {vpath.name}: {n_added} faces "
              f"(total {len(face_records)})")

        # Persist progress every video
        with progress_path.open("w") as f:
            json.dump({
                "seen_videos": sorted(seen_videos),
                "face_records": [asdict(r) for r in face_records]
            }, f)
        if embeddings:
            np.savez_compressed(embeddings_path,
                                 embeddings=np.stack(embeddings))

    log.close()
    print(f"[scan-done] {len(face_records)} faces from {len(seen_videos)} videos")
    return len(face_records)


# --- Cluster phase ---------------------------------------------------------

def cluster_phase(run_dir: Path, args) -> None:
    import hdbscan

    embeddings_path = run_dir / "faces.npz"
    progress_path = run_dir / "progress.json"
    if not embeddings_path.exists() or not progress_path.exists():
        sys.exit(f"No collected faces under {run_dir}. Run collection first.")

    data = np.load(embeddings_path)
    embeddings = data["embeddings"]
    with progress_path.open() as f:
        state = json.load(f)
    face_records = [FaceRecord(**r) for r in state["face_records"]]

    if len(embeddings) == 0:
        sys.exit("No embeddings to cluster.")

    print(f"[cluster] {len(embeddings)} embeddings, "
          f"min_cluster_size={args.min_cluster_size}, "
          f"min_samples={args.min_samples}")

    # FaceNet embeddings are L2-normed → cosine distance == 0.5 * euclidean^2.
    # HDBSCAN supports euclidean directly; on unit-norm vectors it's monotonic
    # with cosine, so cluster topology is identical.
    clusterer = hdbscan.HDBSCAN(
        min_cluster_size=args.min_cluster_size,
        min_samples=args.min_samples,
        metric="euclidean",
        cluster_selection_method="eom",
    )
    labels = clusterer.fit_predict(embeddings.astype(np.float64))

    # Organize thumbs into per-cluster directories
    clusters_dir = run_dir / "clusters"
    noise_dir = run_dir / "noise"
    # Wipe existing cluster output (we may re-cluster with different params)
    if clusters_dir.exists():
        for p in clusters_dir.glob("**/*"):
            if p.is_file() or p.is_symlink():
                p.unlink()
        for p in sorted(clusters_dir.glob("*"), reverse=True):
            if p.is_dir():
                p.rmdir()
    if noise_dir.exists():
        for p in noise_dir.iterdir():
            if p.is_file() or p.is_symlink():
                p.unlink()
    clusters_dir.mkdir(parents=True, exist_ok=True)
    noise_dir.mkdir(parents=True, exist_ok=True)

    thumbs_dir = run_dir / "face_thumbs"

    # Build cluster_id -> list of face indices
    by_cluster: dict[int, list[int]] = {}
    for idx, lab in enumerate(labels):
        by_cluster.setdefault(int(lab), []).append(idx)

    # Sort clusters by size (largest first), noise (-1) last
    sorted_clusters = sorted(
        ((cid, idxs) for cid, idxs in by_cluster.items() if cid != -1),
        key=lambda t: -len(t[1])
    )
    if -1 in by_cluster:
        sorted_clusters.append((-1, by_cluster[-1]))

    summary_path = run_dir / "cluster_summary.csv"
    with summary_path.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["cluster_id", "rank", "face_count", "video_count",
                    "videos_sample", "thumb_dir"])

        for rank, (cid, idxs) in enumerate(sorted_clusters):
            videos = sorted({face_records[i].video_path for i in idxs})
            if cid == -1:
                target_dir = noise_dir
                rank_label = "noise"
            else:
                target_dir = clusters_dir / f"cluster_{rank+1:03d}"
                target_dir.mkdir(parents=True, exist_ok=True)
                rank_label = str(rank + 1)

            # Symlink thumbs into the cluster dir so we don't duplicate disk
            for i in idxs:
                fid = face_records[i].face_id
                src = thumbs_dir / f"face_{fid:06d}.jpg"
                dst = target_dir / f"face_{fid:06d}.jpg"
                if src.exists() and not dst.exists():
                    try:
                        os.symlink(src.resolve(), dst)
                    except OSError:
                        # Fallback to copy if symlink fails (e.g., exFAT)
                        import shutil
                        shutil.copy2(src, dst)

            # 4x4 montage of the first 16 thumbs
            if cid != -1:
                make_montage(target_dir, idxs[:16], face_records, thumbs_dir)

            videos_preview = ", ".join(Path(v).name for v in videos[:3])
            if len(videos) > 3:
                videos_preview += f" (+{len(videos)-3} more)"

            w.writerow([cid, rank_label, len(idxs), len(videos),
                        videos_preview, str(target_dir.relative_to(run_dir))])
            print(f"[cluster {rank_label}] {len(idxs)} faces in "
                  f"{len(videos)} videos: {videos_preview}")

    print(f"\n[done] cluster_summary.csv at {summary_path}")
    print(f"[done] open {clusters_dir} in Finder to eyeball clusters")


def make_montage(cluster_dir: Path, idxs: list[int],
                 face_records: list, thumbs_dir: Path) -> None:
    """Write a 4x4 grid of thumbs as grid.jpg for at-a-glance review."""
    n = min(16, len(idxs))
    if n == 0:
        return
    grid_w = 4
    grid_h = (n + grid_w - 1) // grid_w
    cell = 160
    montage = Image.new("RGB", (grid_w * cell, grid_h * cell), (32, 32, 32))
    for i, face_idx in enumerate(idxs[:16]):
        fid = face_records[face_idx].face_id
        src = thumbs_dir / f"face_{fid:06d}.jpg"
        if not src.exists():
            continue
        try:
            im = Image.open(src).resize((cell, cell), Image.BILINEAR)
            montage.paste(im, ((i % grid_w) * cell, (i // grid_w) * cell))
        except Exception:
            continue
    montage.save(cluster_dir / "grid.jpg", "JPEG", quality=88)


# --- Driver ----------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description=__doc__)
    ap.add_argument("root", type=Path, nargs="?",
                    help="Folder of videos to scan (omit with --cluster-only)")
    ap.add_argument("--run-name", default=None,
                    help="Subdir under output/cluster_faces (default: derived from root)")
    ap.add_argument("--max-frames", type=int, default=60,
                    help="Per-video frame cap (default 60)")
    ap.add_argument("--frame-interval", type=float, default=5.0,
                    help="Seconds between samples (default 5)")
    ap.add_argument("--min-cluster-size", type=int, default=20,
                    help="HDBSCAN: min faces per person (default 20)")
    ap.add_argument("--min-samples", type=int, default=5,
                    help="HDBSCAN: density param (default 5)")
    ap.add_argument("--cluster-only", action="store_true",
                    help="Skip collection, just re-cluster existing embeddings")
    ap.add_argument("--collect-only", action="store_true",
                    help="Skip clustering, just collect faces")
    ap.add_argument("--out-dir", type=Path, default=DEFAULT_OUT,
                    help=f"Output root (default {DEFAULT_OUT})")
    args = ap.parse_args()

    if not args.cluster_only and args.root is None:
        ap.error("root is required unless --cluster-only")

    if args.run_name:
        run_dir = args.out_dir / args.run_name
    elif args.root:
        run_dir = args.out_dir / args.root.name
    else:
        ap.error("Specify --run-name when using --cluster-only")
    run_dir.mkdir(parents=True, exist_ok=True)
    print(f"[run-dir] {run_dir}")

    if not args.cluster_only:
        collect_faces(args.root, run_dir, args)

    if not args.collect_only:
        cluster_phase(run_dir, args)


if __name__ == "__main__":
    main()
