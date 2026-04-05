#!/usr/bin/env python3
"""
face_diagnose.py — prototype face recognition using dlib/face_recognition library.

Uses the same reference photo set and test video as FaceDiagnose.swift but with
a model actually trained for face identity (dlib's ResNet face descriptor).

Usage:
    python face_diagnose.py <ref_photos_dir> <video_file> [options]

Options:
    --threshold F       Match distance threshold (default: 0.55, dlib scale)
    --frame-step N      Sample every Nth frame (default: 5)
    --verbose           Print distance to every reference per face
"""

import sys
import os
import argparse
import cv2
import face_recognition
import numpy as np
from pathlib import Path
from dataclasses import dataclass, field
from typing import Optional

# ─────────────────────────────────────────────────────────────────────────────
# Args
# ─────────────────────────────────────────────────────────────────────────────

def parse_args():
    p = argparse.ArgumentParser(description="Face recognition diagnostic using dlib")
    p.add_argument("ref_path",   help="Folder of reference photos")
    p.add_argument("video_path", help="Video file or folder of videos")
    p.add_argument("--threshold",   type=float, default=0.55,
                   help="Match distance threshold (default 0.55; dlib: lower=stricter)")
    p.add_argument("--frame-step",  type=int,   default=5,
                   help="Sample every Nth frame (default 5)")
    p.add_argument("--verbose",     action="store_true",
                   help="Print distance to each reference photo per face")
    return p.parse_args()

# ─────────────────────────────────────────────────────────────────────────────
# Reference loading
# ─────────────────────────────────────────────────────────────────────────────

IMAGE_EXTS = {'.jpg', '.jpeg', '.png', '.heic', '.heif', '.tiff', '.tif', '.bmp'}

@dataclass
class RefFace:
    filename: str
    encoding: np.ndarray   # 128-dim dlib face descriptor

def load_references(path: str) -> list[RefFace]:
    p = Path(path)
    if p.is_file():
        paths = [p]
    else:
        paths = sorted(f for f in p.rglob("*") if f.suffix.lower() in IMAGE_EXTS)

    refs = []
    for img_path in paths:
        img = face_recognition.load_image_file(str(img_path))
        # Use CNN model for better accuracy (slower but much more accurate than HOG)
        locs = face_recognition.face_locations(img, model="cnn")
        if not locs:
            # Fall back to HOG if CNN finds nothing
            locs = face_recognition.face_locations(img, model="hog")
        if not locs:
            print(f"  [ref] No face detected in {img_path.name} — skipping")
            continue
        # Use largest face
        largest = max(locs, key=lambda r: (r[2]-r[0]) * (r[1]-r[3]))
        encs = face_recognition.face_encodings(img, [largest])
        if encs:
            refs.append(RefFace(filename=img_path.name, encoding=encs[0]))
            print(f"  [ref] Loaded {img_path.name}")
        else:
            print(f"  [ref] Encoding failed for {img_path.name} — skipping")
    return refs

# ─────────────────────────────────────────────────────────────────────────────
# Video discovery
# ─────────────────────────────────────────────────────────────────────────────

VIDEO_EXTS = {'.mov', '.mp4', '.m4v', '.avi', '.mkv', '.mxf', '.mts',
              '.m2ts', '.mpg', '.mpeg', '.dv', '.3gp', '.wmv', '.mod', '.tod'}

def find_videos(path: str) -> list[str]:
    p = Path(path)
    if p.is_file():
        return [str(p)] if p.suffix.lower() in VIDEO_EXTS else []
    return sorted(str(f) for f in p.rglob("*") if f.suffix.lower() in VIDEO_EXTS)

# ─────────────────────────────────────────────────────────────────────────────
# Frame analysis
# ─────────────────────────────────────────────────────────────────────────────

@dataclass
class FrameFace:
    video_file: str
    time_secs: float
    frame_idx: int
    face_idx: int
    area_pct: float
    best_dist: float
    best_ref: str
    all_dists: list[float] = field(default_factory=list)
    is_hit: bool = False

def analyze_video(video_path: str, refs: list[RefFace], args) -> list[FrameFace]:
    filename = Path(video_path).name
    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        print(f"  Could not open {filename}", file=sys.stderr)
        return []

    fps      = cap.get(cv2.CAP_PROP_FPS) or 25.0
    total_fr = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    duration = total_fr / fps
    print(f"\n  {filename}  {duration:.1f}s  {fps:.1f}fps  step={args.frame_step}")

    ref_encs = [r.encoding for r in refs]
    results  = []
    frame_no = 0

    while True:
        ret, bgr = cap.read()
        if not ret:
            break
        frame_no += 1
        if frame_no % args.frame_step != 0:
            continue

        t = frame_no / fps
        # face_recognition expects RGB
        rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
        h, w = rgb.shape[:2]

        # CNN model: more accurate, slightly slower
        locs = face_recognition.face_locations(rgb, model="cnn")
        if not locs:
            continue

        encs = face_recognition.face_encodings(rgb, locs)

        # Sort by face area descending (largest = most prominent)
        faces_sorted = sorted(zip(locs, encs),
                              key=lambda x: (x[0][2]-x[0][0]) * (x[0][1]-x[0][3]),
                              reverse=True)

        for face_idx, (loc, enc) in enumerate(faces_sorted):
            top, right, bottom, left = loc
            area_pct = ((bottom - top) * (right - left)) / (h * w) * 100

            dists = face_recognition.face_distance(ref_encs, enc)
            best_i    = int(np.argmin(dists))
            best_dist = float(dists[best_i])
            best_ref  = refs[best_i].filename

            ff = FrameFace(
                video_file=filename,
                time_secs=t,
                frame_idx=frame_no,
                face_idx=face_idx,
                area_pct=area_pct,
                best_dist=best_dist,
                best_ref=best_ref,
                all_dists=[float(d) for d in dists],
                is_hit=(best_dist <= args.threshold)
            )
            results.append(ff)

    cap.release()
    return results

# ─────────────────────────────────────────────────────────────────────────────
# Reporting
# ─────────────────────────────────────────────────────────────────────────────

W = 72  # box width

def box(lines: list[str], title: str = ""):
    top = "╔" + "═" * (W-2) + "╗"
    mid = "╠" + "═" * (W-2) + "╣"
    bot = "╚" + "═" * (W-2) + "╝"
    print(top)
    if title:
        print(f"║  {title:<{W-4}}║")
        print(mid)
    for l in lines:
        print(f"║  {l:<{W-4}}║")
    print(bot)

def print_frame_log(faces: list[FrameFace], refs: list[RefFace], args):
    lines = ["time     face  area%   best-dist  best-ref                   hit"]
    lines.append("─" * (W-4))
    for f in sorted(faces, key=lambda x: (x.time_secs, x.face_idx)):
        hit = "HIT" if f.is_hit else "   "
        ref = f.best_ref[:26]
        lines.append(f"{f.time_secs:6.2f}s  #{f.face_idx+1}  {f.area_pct:5.2f}%   {f.best_dist:.4f}    {ref:<26}  {hit}")
        if args.verbose:
            for ri, d in enumerate(f.all_dists):
                mark = " <- MATCH" if d <= args.threshold else ""
                lines.append(f"   ref {ri+1:02d}  {refs[ri].filename[:34]:<34}  {d:.4f}{mark}")
            lines.append("")
    box(lines, "PER-FRAME FACE LOG")

def print_summary(faces: list[FrameFace], refs: list[RefFace], args):
    if not faces:
        print("\nNo faces detected at all.")
        return

    hits   = [f for f in faces if f.is_hit]
    misses = [f for f in faces if not f.is_hit]
    dists  = sorted(f.best_dist for f in faces)

    # Histogram  0.0–1.0 in 0.05 buckets
    n_buckets = 20
    bw = 1.0 / n_buckets
    counts = [0] * n_buckets
    for d in dists:
        counts[min(n_buckets-1, int(d / bw))] += 1
    max_c = max(1, max(counts))
    hist_lines = []
    for b in range(n_buckets):
        lo, hi = b*bw, (b+1)*bw
        bar  = "█" * (counts[b] * 44 // max_c)
        mark = " <- threshold" if lo <= args.threshold < hi else ""
        hist_lines.append(f"{lo:.2f}–{hi:.2f}  {bar:<44}  {counts[b]:3d}{mark}")
    box(hist_lines, "DISTANCE HISTOGRAM (dlib 128-dim descriptor, best dist per face)")

    # Reference contribution
    ref_any  = {}
    ref_hits = {}
    for f in faces: ref_any[f.best_ref]  = ref_any.get(f.best_ref, 0) + 1
    for f in hits:  ref_hits[f.best_ref] = ref_hits.get(f.best_ref, 0) + 1
    ref_lines = []
    for name in sorted(ref_any):
        a = ref_any[name]
        h = ref_hits.get(name, 0)
        flag = "  <- possible noisy ref" if a > 0 and h/a > 0.8 else ""
        ref_lines.append(f"{name[:38]:<38}  closest:{a:4d}  hits:{h:4d}{flag}")
    box(ref_lines, "REFERENCE CONTRIBUTION")

    # Stats
    p5  = dists[max(0, int(len(dists)*0.05))]
    p50 = dists[int(len(dists)*0.50)]
    p95 = dists[min(len(dists)-1, int(len(dists)*0.95))]
    hit_rate = len(hits)/len(faces)*100
    confident = sum(1 for f in hits if f.best_dist < 0.40)
    borderline = len(hits) - confident
    near_miss  = sum(1 for f in misses if f.best_dist < args.threshold + 0.05)

    summary = [
        f"Model:              dlib ResNet face descriptor (128-dim)",
        f"Threshold:          {args.threshold}  (dlib default 0.6; stricter ~0.50)",
        f"",
        f"Faces detected:     {len(faces)}",
        f"Hits (<= {args.threshold:.2f}):      {len(hits)}   ({hit_rate:.1f}%)",
        f"Misses:             {len(misses)}",
        f"Best dist (min):    {dists[0]:.4f}",
        f"Dist p5/p50/p95:    {p5:.3f} / {p50:.3f} / {p95:.3f}",
        f"",
        f"Confident hits (< 0.40):      {confident}",
        f"Borderline hits (0.40–{args.threshold:.2f}):  {borderline}",
        f"Near-misses (thresh+0.05):    {near_miss}",
    ]
    if not hits:
        summary.append("⚠  No hits — target may not appear, or threshold too tight")
    elif hit_rate > 50:
        summary.append("⚠  >50% matched — threshold probably too loose")
    elif borderline > confident:
        summary.append("⚠  Most hits borderline — consider tightening threshold")
    else:
        summary.append("✓  Hit distribution looks reasonable")
    box(summary, "SUMMARY")

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

def main():
    args = parse_args()

    print("face_diagnose.py  (dlib ResNet face recognition)")
    print(f"  References: {args.ref_path}")
    print(f"  Video:      {args.video_path}")
    print(f"  threshold={args.threshold}  frame-step={args.frame_step}\n")

    print("Loading reference photos (CNN detection — may take a moment)...")
    refs = load_references(args.ref_path)
    if not refs:
        print("ERROR: No reference faces loaded.", file=sys.stderr)
        sys.exit(1)
    print(f"\nLoaded {len(refs)} reference face(s)\n")

    videos = find_videos(args.video_path)
    if not videos:
        print(f"ERROR: No video files found at {args.video_path}", file=sys.stderr)
        sys.exit(1)
    print(f"Found {len(videos)} video(s)")

    all_faces = []
    for v in videos:
        faces = analyze_video(v, refs, args)
        all_faces.extend(faces)

    print()
    print_frame_log(all_faces, refs, args)
    print_summary(all_faces, refs, args)

if __name__ == "__main__":
    main()
