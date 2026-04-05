#!/usr/bin/env python3
"""
face_recognize.py — production face recognition engine for VideoScan.

Called per-video by the Swift app. Outputs structured JSON to stdout,
human-readable progress to stderr. Swift handles parallelism by running
multiple instances concurrently.

Usage:
    /path/to/venv/bin/python face_recognize.py \\
        --ref-path  <dir_of_reference_photos> \\
        --video     <video_file> \\
        --threshold 0.52 \\
        --frame-step 5 \\
        --min-conf 0.55 \\
        --pad 2.0 \\
        --min-duration 1.0

Stdout (always valid JSON, even on error):
    {
      "video": "filename.mov",
      "video_path": "/full/path/filename.mov",
      "duration": 123.4,
      "fps": 29.97,
      "error": null,                   // or error string
      "faces_detected": 279,
      "hits": 42,
      "best_dist": 0.3122,
      "segments": [
        { "start": 4.2, "end": 9.8, "best_dist": 0.31, "avg_dist": 0.34, "hit_count": 17 },
        ...
      ]
    }

Stderr:
    Human-readable progress lines (shown in the app's console view).
"""

import sys
import os
import json
import argparse
import math
import gc
import resource
import platform
from pathlib import Path

# ─────────────────────────────────────────────────────────────────────────────
# Memory ceiling — kill this process rather than let it swap the system.
# Default 4 GB; override with env FACE_RECOG_MAX_RSS_MB.
# ─────────────────────────────────────────────────────────────────────────────
_MAX_RSS_MB = int(os.environ.get("FACE_RECOG_MAX_RSS_MB", "4096"))
if platform.system() == "Darwin":
    # macOS setrlimit uses bytes
    resource.setrlimit(resource.RLIMIT_RSS,
                       (_MAX_RSS_MB * 1024 * 1024, resource.RLIM_INFINITY))
else:
    # Linux RLIMIT_AS (virtual) — RSS limit isn't enforced on most kernels
    resource.setrlimit(resource.RLIMIT_AS,
                       (_MAX_RSS_MB * 1024 * 1024, resource.RLIM_INFINITY))

# ─────────────────────────────────────────────────────────────────────────────
# Imports — fail gracefully so Swift gets a proper JSON error
# ─────────────────────────────────────────────────────────────────────────────

def _fatal(video_path: str, msg: str):
    """Emit a JSON error to stdout and exit non-zero."""
    name = Path(video_path).name if video_path else ""
    result = {
        "video": name, "video_path": video_path or "",
        "duration": 0, "fps": 0, "error": msg,
        "faces_detected": 0, "hits": 0, "best_dist": None, "segments": []
    }
    print(json.dumps(result))
    sys.exit(1)

try:
    import cv2
    import face_recognition
    import numpy as np
except ImportError as e:
    _fatal("", f"Missing dependency: {e}. Run: pip install face_recognition opencv-python")

# ─────────────────────────────────────────────────────────────────────────────
# Args
# ─────────────────────────────────────────────────────────────────────────────

def parse_args():
    p = argparse.ArgumentParser(add_help=True)
    p.add_argument("--ref-path",     required=True, help="Reference photos directory")
    p.add_argument("--video",        required=True, help="Video file to analyze")
    p.add_argument("--threshold",    type=float, default=0.52)
    p.add_argument("--frame-step",   type=int,   default=5)
    p.add_argument("--min-conf",     type=float, default=0.55,
                   help="Minimum face detection confidence (0–1, HOG-based approximation)")
    p.add_argument("--pad",          type=float, default=2.0,
                   help="Seconds to pad each segment start/end")
    p.add_argument("--min-duration", type=float, default=1.0,
                   help="Minimum segment duration in seconds")
    p.add_argument("--gap-tolerance",type=float, default=0.0,
                   help="Override gap tolerance for segment clustering (0 = auto: 3×frame_interval)")
    return p.parse_args()

# ─────────────────────────────────────────────────────────────────────────────
# Reference loading
# ─────────────────────────────────────────────────────────────────────────────

IMAGE_EXTS = {'.jpg', '.jpeg', '.png', '.heic', '.heif', '.tiff', '.tif', '.bmp'}

_REF_MAX_DIM = 800  # Downsize reference photos — dlib needs ~150px faces, not 4K images

def _downsize(img: "np.ndarray", max_dim: int) -> "np.ndarray":
    """Downsize image so its longest edge is at most max_dim pixels."""
    h, w = img.shape[:2]
    if max(h, w) <= max_dim:
        return img
    scale = max_dim / max(h, w)
    new_w, new_h = int(w * scale), int(h * scale)
    return cv2.resize(img, (new_w, new_h), interpolation=cv2.INTER_AREA)


def load_references(ref_path: str) -> list:
    """
    Returns list of (filename, encoding) tuples.
    Uses HOG-only detector (CNN loads ~700 MB resident and never releases it).
    Images are downsized before detection to reduce peak memory.
    Each image is explicitly freed after encoding extraction.
    """
    p = Path(ref_path)
    paths = sorted(p.rglob("*") if p.is_dir() else [p])
    paths = [f for f in paths if f.suffix.lower() in IMAGE_EXTS]

    if not paths:
        return []

    print(f"Loading {len(paths)} reference photo(s)…", file=sys.stderr)
    refs = []
    for img_path in paths:
        try:
            img = face_recognition.load_image_file(str(img_path))
        except Exception as e:
            print(f"  [ref] Cannot read {img_path.name}: {e}", file=sys.stderr)
            continue

        # Downsize to cap memory — dlib needs ~150px faces, not megapixel images
        img = _downsize(img, _REF_MAX_DIM)

        # HOG only — CNN loads a ~700 MB model that stays resident forever.
        # HOG is accurate enough for clear reference portraits.
        locs = face_recognition.face_locations(img, model="hog")
        if not locs:
            print(f"  [ref] No face in {img_path.name} — skipped", file=sys.stderr)
            del img
            continue

        # Use the largest detected face
        largest = max(locs, key=lambda r: (r[2] - r[0]) * (r[1] - r[3]))
        encs = face_recognition.face_encodings(img, [largest])
        if encs:
            refs.append((img_path.name, encs[0]))
        else:
            print(f"  [ref] Encoding failed for {img_path.name} — skipped", file=sys.stderr)

        # Explicitly free the pixel array — don't let 30 images accumulate
        del img, locs, encs
        gc.collect()

    print(f"  {len(refs)} reference face(s) loaded", file=sys.stderr)
    return refs

# ─────────────────────────────────────────────────────────────────────────────
# Video analysis
# ─────────────────────────────────────────────────────────────────────────────

_FRAME_MAX_DIM = 640  # Downsize video frames — saves ~75% RAM vs 1080p

def _get_rss_mb() -> float:
    """Current process RSS in MB (macOS/Linux)."""
    usage = resource.getrusage(resource.RUSAGE_SELF)
    if platform.system() == "Darwin":
        return usage.ru_maxrss / (1024 * 1024)  # bytes on macOS
    return usage.ru_maxrss / 1024  # KB on Linux


def analyze_video(video_path: str, refs: list, args) -> dict:
    """
    Sample every frame-step frames. For each frame with detected faces,
    compute dlib 128-dim distance to every reference encoding.
    Frames are downsized to reduce peak memory.
    Returns a result dict ready for JSON serialization.
    """
    filename = Path(video_path).name
    ref_encs = np.array([enc for _, enc in refs])

    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        return {"error": f"Cannot open video: {video_path}"}

    fps       = cap.get(cv2.CAP_PROP_FPS) or 25.0
    total_fr  = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    duration  = total_fr / fps if fps > 0 else 0

    print(f"{filename}  {duration:.1f}s  {fps:.1f}fps  step={args.frame_step}  "
          f"frame_max={_FRAME_MAX_DIM}px  rss={_get_rss_mb():.0f}MB",
          file=sys.stderr)

    gap_tol    = (args.gap_tolerance if args.gap_tolerance > 0
                  else (args.frame_step / fps) * 3.0) if fps > 0 else 0.0
    raw_segments = []
    current_segment = None   # [start, end, best_dist, dist_sum, hit_count]
    n_detected = 0
    best_dist_ever = math.inf
    frame_no   = 0
    milestones = {25, 50, 75}
    logged_ms  = set()

    while True:
        ret, bgr = cap.read()
        if not ret:
            break
        frame_no += 1
        if frame_no % args.frame_step != 0:
            del bgr
            continue

        t = frame_no / fps
        # Downsize before color conversion — process at 640px max, not 1080/4K
        bgr = _downsize(bgr, _FRAME_MAX_DIM)
        rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
        del bgr  # free immediately — we only need rgb from here

        locs = face_recognition.face_locations(rgb, model="hog")
        if not locs:
            del rgb
            continue

        encs = face_recognition.face_encodings(rgb, locs)
        del rgb  # free pixel data before distance computation
        n_detected += len(encs)

        for enc in encs:
            dists = face_recognition.face_distance(ref_encs, enc)
            best  = float(np.min(dists))
            if best < best_dist_ever:
                best_dist_ever = best
            if best <= args.threshold:
                if current_segment is None:
                    current_segment = [t, t, best, best, 1]
                elif t - current_segment[1] <= gap_tol:
                    current_segment[1] = t
                    current_segment[2] = min(current_segment[2], best)
                    current_segment[3] += best
                    current_segment[4] += 1
                else:
                    raw_segments.append(tuple(current_segment))
                    current_segment = [t, t, best, best, 1]

        # Progress milestones to stderr (now includes RSS)
        pct = int(t / duration * 100) if duration > 0 else 0
        for m in list(milestones - logged_ms):
            if pct >= m:
                logged_ms.add(m)
                dist_str = f"{best_dist_ever:.4f}" if best_dist_ever < math.inf else "—"
                print(f"  {m}%  t={t:.0f}s/{duration:.0f}s  "
                      f"faces={n_detected}  hits={sum(seg[4] for seg in raw_segments) + (current_segment[4] if current_segment else 0)}  "
                      f"best={dist_str}  rss={_get_rss_mb():.0f}MB",
                      file=sys.stderr)
        del encs, locs
        # GC every 10 sampled frames (was every 20 — tighter now)
        if frame_no % (args.frame_step * 10) == 0:
            gc.collect()

    cap.release()
    gc.collect()  # one final collection after video processing
    if current_segment is not None:
        raw_segments.append(tuple(current_segment))

    # Progress footer
    dist_str = f"{best_dist_ever:.4f}" if best_dist_ever < math.inf else "—"
    total_hits = sum(seg[4] for seg in raw_segments)
    print(f"  done  faces={n_detected}  hits={total_hits}  best={dist_str}",
          file=sys.stderr)

    return {
        "fps": fps,
        "duration": duration,
        "faces_detected": n_detected,
        "raw_segments": raw_segments,
        "hits": total_hits,
        "best_dist_ever": best_dist_ever if best_dist_ever < math.inf else None,
    }

# ─────────────────────────────────────────────────────────────────────────────
# Segment clustering  (mirrors pfProcessVideo logic in PersonFinderModel.swift)
# ─────────────────────────────────────────────────────────────────────────────

def cluster_segments(raw_segments: list, args) -> list:
    """
    Cluster raw (time, dist) hits into padded segments.
    Returns list of dicts: start, end, best_dist, avg_dist, hit_count.
    """
    if not raw_segments:
        return []

    # Pad and merge overlapping segments
    padded = [(max(0, s - args.pad), e + args.pad, best, dist_sum, hit_count)
              for s, e, best, dist_sum, hit_count in raw_segments]
    padded.sort(key=lambda x: x[0])
    merged = []
    for seg in padded:
        if merged and seg[0] <= merged[-1][1]:
            prev = merged[-1]
            merged[-1] = (
                prev[0],
                max(prev[1], seg[1]),
                min(prev[2], seg[2]),
                prev[3] + seg[3],
                prev[4] + seg[4],
            )
        else:
            merged.append(seg)

    # Filter by min duration and build output dicts
    segments = []
    for s, e, best_dist, dist_sum, hit_count in merged:
        dur = e - s
        if dur < args.min_duration:
            continue
        segments.append({
            "start":      round(max(0, s), 4),
            "end":        round(e, 4),
            "best_dist":  round(float(best_dist), 4),
            "avg_dist":   round(float(dist_sum / hit_count), 4),
            "hit_count":  hit_count,
        })
    return segments

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

def main():
    args = parse_args()

    if not Path(args.video).exists():
        _fatal(args.video, f"Video file not found: {args.video}")

    # Load references
    refs = load_references(args.ref_path)
    if not refs:
        _fatal(args.video, f"No reference faces loaded from {args.ref_path}")

    # Analyze video
    result = analyze_video(args.video, refs, args)
    if "error" in result:
        _fatal(args.video, result["error"])

    # Cluster into segments
    segments = cluster_segments(result["raw_segments"], args)

    # Emit JSON to stdout
    output = {
        "video":          Path(args.video).name,
        "video_path":     args.video,
        "duration":       round(result["duration"], 4),
        "fps":            round(result["fps"], 4),
        "error":          None,
        "faces_detected": result["faces_detected"],
        "hits":           result["hits"],
        "best_dist":      round(result["best_dist_ever"], 4) if result["best_dist_ever"] is not None else None,
        "segments":       segments,
    }
    print(json.dumps(output))

if __name__ == "__main__":
    main()
