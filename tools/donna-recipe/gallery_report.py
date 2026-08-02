#!/usr/bin/env python3
"""Donna Recipe G1 — reference-gallery report card.

Audits an era-banded reference gallery (decade subfolders of one person)
with the SAME model family the recipe mandates: insightface buffalo_l =
SCRFD-10G detection + ArcFace-w600k 512-d embeddings + genderage, via
ONNX Runtime (CoreML EP when available). This is simultaneously the
Apple-Silicon platform spike (docs/donna-recipe-v1.md, "Risks") and the
G1 grading gate's report card.

Per photo: face count, presumed-subject face (two-pass centroid
resolution for group shots), detector confidence, face pixel size vs the
two-tier gates (record ≥25px / vote ≥60px — PhotoPrism production
values), gender/age estimate (attribute-gate preview), and embedding
cohesion vs the rest of the gallery.

Per era: intra-era mean pairwise cosine, cross-era centroid matrix,
outliers (candidate mislabels / other people), unusable files.

SENSITIVE-DATA RULE (POI cycle-2): raw embeddings are biometrics — they
live only in process memory here; the report contains statistics and
filenames only. Nothing embedding-shaped is written to disk.

Usage:
    python3.12 tools/donna-recipe/gallery_report.py \
        --gallery tests/fixtures/photos/Donna \
        --out docs/donna-gallery-report.md
"""

from __future__ import annotations

import argparse
import pathlib
import sys
import time

import numpy as np

IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png", ".tif", ".tiff", ".heic", ""}
RECORD_PX = 25   # PhotoPrism SizeThreshold — loose tier
VOTE_PX = 60     # PhotoPrism ClusterSizeThreshold — strict/voting tier
OUTLIER_COS = 0.25  # mean-cos to era peers below this → flag for human look


def load_image(path: pathlib.Path):
    """EXIF-aware load → BGR ndarray (cv2.imread ignores orientation)."""
    import cv2
    from PIL import Image, ImageOps
    try:
        with Image.open(path) as im:
            im = ImageOps.exif_transpose(im).convert("RGB")
            return cv2.cvtColor(np.asarray(im), cv2.COLOR_RGB2BGR)
    except Exception:
        return cv2.imread(str(path))  # last resort


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--gallery", required=True, type=pathlib.Path)
    ap.add_argument("--out", required=True, type=pathlib.Path)
    ap.add_argument("--model-root", type=pathlib.Path,
                    default=pathlib.Path(".cache/insightface"))
    args = ap.parse_args()

    from insightface.app import FaceAnalysis
    t0 = time.time()
    app = FaceAnalysis(
        name="buffalo_l", root=str(args.model_root),
        providers=["CoreMLExecutionProvider", "CPUExecutionProvider"])
    app.prepare(ctx_id=0, det_size=(640, 640))
    prep_s = time.time() - t0

    eras = sorted(d for d in args.gallery.iterdir() if d.is_dir())
    if not eras:
        print("no era subfolders found", file=sys.stderr)
        return 1

    # ---- pass 1: detect + embed every photo --------------------------------
    rows = []          # dicts: era, file, faces(list of insightface Face)
    detect_s = 0.0
    for era in eras:
        for f in sorted(era.iterdir()):
            if f.name.startswith("."):
                continue
            if f.suffix.lower() not in IMAGE_SUFFIXES:
                continue
            img = load_image(f)
            if img is None:
                rows.append({"era": era.name, "file": f.name, "faces": None})
                continue
            t = time.time()
            faces = app.get(img)
            detect_s += time.time() - t
            rows.append({"era": era.name, "file": f.name, "faces": faces,
                         "shape": img.shape[:2]})

    # Provisional centroid from single-face photos ≥ VOTE_PX.
    def face_px(face) -> int:
        x1, y1, x2, y2 = face.bbox
        return int(min(x2 - x1, y2 - y1))

    singles = [r["faces"][0] for r in rows
               if r["faces"] and len(r["faces"]) == 1
               and face_px(r["faces"][0]) >= VOTE_PX]
    if not singles:
        print("no usable single-face photos — cannot bootstrap centroid",
              file=sys.stderr)
        return 1
    centroid = np.mean([f.normed_embedding for f in singles], axis=0)
    centroid /= np.linalg.norm(centroid)

    # ---- pass 2: resolve the presumed-subject face per photo ---------------
    chosen = []   # era, file, face, cos_to_centroid, ambiguous, n_faces
    problems = []
    for r in rows:
        if r["faces"] is None:
            problems.append((r["era"], r["file"], "unreadable image"))
            continue
        if not r["faces"]:
            problems.append((r["era"], r["file"], "no face detected"))
            continue
        scored = sorted(
            ((float(np.dot(f.normed_embedding, centroid)), f) for f in r["faces"]),
            key=lambda p: -p[0])
        best_cos, best = scored[0]
        runner = scored[1][0] if len(scored) > 1 else None
        ambiguous = runner is not None and (best_cos - runner) < 0.10
        chosen.append({
            "era": r["era"], "file": r["file"], "face": best,
            "cos": best_cos, "n": len(r["faces"]), "ambiguous": ambiguous,
            "px": face_px(best), "det": float(best.det_score),
            "sex": "F" if best.gender == 0 else "M",
            "age": int(best.age),
        })

    # ---- per-era + cross-era statistics ------------------------------------
    era_names = [e.name for e in eras]
    by_era = {e: [c for c in chosen if c["era"] == e] for e in era_names}
    era_centroids = {}
    for e, cs in by_era.items():
        votable = [c for c in cs if c["px"] >= VOTE_PX]
        if votable:
            m = np.mean([c["face"].normed_embedding for c in votable], axis=0)
            era_centroids[e] = m / np.linalg.norm(m)

    def intra_mean(cs):
        embs = [c["face"].normed_embedding for c in cs if c["px"] >= VOTE_PX]
        if len(embs) < 2:
            return None
        sims = [float(np.dot(a, b)) for i, a in enumerate(embs)
                for b in embs[i + 1:]]
        return sum(sims) / len(sims)

    # Outliers: mean cosine to same-era votable peers.
    outliers = []
    for e, cs in by_era.items():
        votable = [c for c in cs if c["px"] >= VOTE_PX]
        for c in votable:
            peers = [p for p in votable if p is not c]
            if not peers:
                continue
            mc = float(np.mean([np.dot(c["face"].normed_embedding,
                                       p["face"].normed_embedding)
                                for p in peers]))
            c["peer_cos"] = mc
            if mc < OUTLIER_COS:
                outliers.append(c)

    # ---- report -------------------------------------------------------------
    lines = ["# Donna reference-gallery report card (G1)", ""]
    lines.append(f"Gallery: `{args.gallery}` — {len(rows)} files, "
                 f"{len(chosen)} with a resolved subject face.")
    lines.append(f"Models: buffalo_l (SCRFD-10G + ArcFace-w600k + genderage), "
                 f"providers requested CoreML→CPU; prepare {prep_s:.1f}s, "
                 f"total detect+embed {detect_s:.1f}s "
                 f"({detect_s / max(len(rows), 1):.2f}s/photo).")
    lines.append("")

    lines.append("## Per era")
    lines.append("")
    lines.append("| era | photos | subject faces | votable (≥60px) | record-only (25–59px) | intra-era mean cos | sex maj | age range |")
    lines.append("|---|---|---|---|---|---|---|---|")
    for e in era_names:
        cs = by_era[e]
        votable = [c for c in cs if c["px"] >= VOTE_PX]
        small = [c for c in cs if RECORD_PX <= c["px"] < VOTE_PX]
        im = intra_mean(cs)
        sexes = [c["sex"] for c in votable]
        ages = [c["age"] for c in votable]
        lines.append(
            f"| {e} | {sum(1 for r in rows if r['era'] == e)} | {len(cs)} "
            f"| {len(votable)} | {len(small)} "
            f"| {im:.3f} |" .replace("None", "—") if im is not None else
            f"| {e} | {sum(1 for r in rows if r['era'] == e)} | {len(cs)} "
            f"| {len(votable)} | {len(small)} | — |")
        # append sex/age to the last row
        maj = (max(set(sexes), key=sexes.count) + f" {sexes.count('F')}/{len(sexes)}F") if sexes else "—"
        rng = f"{min(ages)}–{max(ages)}" if ages else "—"
        lines[-1] += f" {maj} | {rng} |"
    lines.append("")

    lines.append("## Cross-era centroid cosine matrix")
    lines.append("")
    have = [e for e in era_names if e in era_centroids]
    lines.append("| | " + " | ".join(have) + " |")
    lines.append("|---|" + "---|" * len(have))
    for a in have:
        cells = [f"{float(np.dot(era_centroids[a], era_centroids[b])):.3f}"
                 for b in have]
        lines.append(f"| {a} | " + " | ".join(cells) + " |")
    lines.append("")

    if problems:
        lines.append("## Unusable files")
        lines.append("")
        for era, name, why in problems:
            lines.append(f"- `{era}/{name}` — {why}")
        lines.append("")

    flagged = [c for c in chosen if c.get("peer_cos", 1) < OUTLIER_COS
               or c["ambiguous"] or c["sex"] == "M" or c["px"] < VOTE_PX]
    if flagged:
        lines.append("## Flagged for a human look")
        lines.append("")
        lines.append("| file | why | faces | px | det | sex/age | peer cos |")
        lines.append("|---|---|---|---|---|---|---|")
        for c in sorted(flagged, key=lambda c: (c["era"], c["file"])):
            whys = []
            if c.get("peer_cos", 1) < OUTLIER_COS:
                whys.append("embedding outlier (mislabeled? not the subject?)")
            if c["ambiguous"]:
                whys.append(f"group shot, subject pick uncertain ({c['n']} faces)")
            if c["sex"] == "M":
                whys.append("attribute model says male — check crop choice")
            if c["px"] < VOTE_PX:
                whys.append(f"face below voting tier ({c['px']}px)")
            lines.append(
                f"| `{c['era']}/{c['file']}` | {'; '.join(whys)} | {c['n']} "
                f"| {c['px']} | {c['det']:.2f} | {c['sex']}/{c['age']} "
                f"| {c.get('peer_cos', float('nan')):.3f} |")
        lines.append("")

    ok = [c for c in chosen if c not in flagged]
    lines.append(f"## Verdict inputs\n")
    lines.append(f"- Clean votable references: **{len(ok)}** across "
                 f"{len({c['era'] for c in ok})} eras.")
    lines.append(f"- Flagged: {len(flagged)}; unusable: {len(problems)}.")
    lines.append("- No embeddings were persisted (cycle-2 sensitive-data rule).")

    args.out.write_text("\n".join(lines) + "\n")
    print(f"report → {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
