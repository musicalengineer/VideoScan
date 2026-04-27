#!/usr/bin/env python3.12
"""
fd_diagnostic.py — Family Face-Recognition Confusion Diagnostic (Tier 1)

Measures how confusable family members are to generic face embedders, using
Rick's POI reference photos as ground truth. Runs two embedders side-by-side
so the "generic FD is confused on family" claim isn't an artifact of a single
algorithm:

  1. dlib (face_recognition, 128-D)  — matches the existing Swift dlib engine
  2. FaceNet (VGGFace2 InceptionResnetV1, 512-D via facenet-pytorch)

For each photo it: detects the largest face, computes both embeddings, and
stores them. Then it builds a person × person confusion matrix (mean pairwise
distance across photos) and flags confusable pairs where cross-person
distance is smaller than within-person distance.

Outputs to output/fd_diagnostic/:
  - embeddings.npz                    (reusable for Tier 2 classifier training)
  - confusion_matrix_dlib.{png,csv}
  - confusion_matrix_facenet.{png,csv}
  - within_vs_between_dlib.png        (distribution overlap plot)
  - within_vs_between_facenet.png
  - summary.md                        (findings + Tier 2 viability call)

No app surgery. Run via:
  /Users/rickb/dev/VideoScan/venv/bin/python3.12 scripts/fd_diagnostic.py
"""

from __future__ import annotations

import os
import sys
import json
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

import numpy as np
import torch
from PIL import Image, ImageOps
import face_recognition  # dlib
from facenet_pytorch import MTCNN, InceptionResnetV1

# --- Paths -----------------------------------------------------------------

REPO = Path(__file__).resolve().parent.parent
POI_ROOT = Path.home() / "Library/Application Support/VideoScan/POI"
OUT_DIR = REPO / "output/fd_diagnostic"
OUT_DIR.mkdir(parents=True, exist_ok=True)

IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".heic", ".heif", ".tiff", ".tif", ".bmp"}

# --- Device ----------------------------------------------------------------

DEVICE = (
    torch.device("mps") if torch.backends.mps.is_available()
    else torch.device("cpu")
)
print(f"[init] device = {DEVICE}")

# --- Data containers -------------------------------------------------------

@dataclass
class PhotoEmbedding:
    person: str
    path: Path
    dlib_vec: Optional[np.ndarray] = None      # 128-D or None if no face
    facenet_vec: Optional[np.ndarray] = None   # 512-D or None if no face
    bbox: Optional[tuple] = None               # (x1,y1,x2,y2) of chosen face
    note: str = ""


# --- Face detection --------------------------------------------------------

def load_pil(path: Path) -> Optional[Image.Image]:
    """Load image, apply EXIF orientation, convert to RGB."""
    try:
        img = Image.open(path)
        img = ImageOps.exif_transpose(img)
        return img.convert("RGB")
    except Exception as exc:
        print(f"  [warn] could not load {path.name}: {exc}")
        return None


def largest_face_bbox(mtcnn: MTCNN, img: Image.Image) -> Optional[tuple]:
    """Return (x1,y1,x2,y2) of the largest face, or None."""
    boxes, probs = mtcnn.detect(img)
    if boxes is None or len(boxes) == 0:
        return None
    # Pick largest by area
    areas = [(b[2] - b[0]) * (b[3] - b[1]) for b in boxes]
    idx = int(np.argmax(areas))
    return tuple(boxes[idx].tolist())


def facenet_embedding(resnet: InceptionResnetV1, img: Image.Image,
                      bbox: tuple) -> np.ndarray:
    """Crop to bbox, resize to 160x160, run through InceptionResnetV1."""
    x1, y1, x2, y2 = bbox
    # Expand by 20% like MTCNN default
    w, h = x2 - x1, y2 - y1
    cx, cy = x1 + w/2, y1 + h/2
    side = max(w, h) * 1.2
    x1 = max(0, cx - side/2)
    y1 = max(0, cy - side/2)
    x2 = min(img.width, cx + side/2)
    y2 = min(img.height, cy + side/2)
    face = img.crop((x1, y1, x2, y2)).resize((160, 160), Image.BILINEAR)
    arr = np.asarray(face, dtype=np.float32)
    arr = (arr - 127.5) / 128.0            # facenet normalization
    tensor = torch.from_numpy(arr).permute(2, 0, 1).unsqueeze(0).to(DEVICE)
    with torch.no_grad():
        emb = resnet(tensor).cpu().numpy()[0]
    # L2 normalize so distances are interpretable on unit sphere
    emb = emb / (np.linalg.norm(emb) + 1e-9)
    return emb


def dlib_embedding(img: Image.Image, bbox_xyxy: tuple) -> Optional[np.ndarray]:
    """dlib ResNet 128-D face_encoding, given a bbox from MTCNN."""
    arr = np.asarray(img)
    x1, y1, x2, y2 = [int(v) for v in bbox_xyxy]
    # face_recognition wants (top, right, bottom, left)
    trbl = (y1, x2, y2, x1)
    encs = face_recognition.face_encodings(arr, known_face_locations=[trbl])
    if not encs:
        return None
    return encs[0]


# --- Main extraction loop --------------------------------------------------

def discover_photos() -> list[tuple[str, Path]]:
    rows: list[tuple[str, Path]] = []
    for person_dir in sorted(POI_ROOT.iterdir()):
        if not person_dir.is_dir():
            continue
        for p in sorted(person_dir.iterdir()):
            if p.suffix.lower() in IMAGE_EXTS:
                rows.append((person_dir.name, p))
    return rows


def extract_all(photos: list[tuple[str, Path]]) -> list[PhotoEmbedding]:
    print(f"[init] loading MTCNN (cpu) + InceptionResnetV1 (VGGFace2, {DEVICE})…")
    # MTCNN has an adaptive-pool bug on MPS (size-divisibility); CPU is fine
    # and it's a small net. Keep the bulk-compute resnet on MPS.
    mtcnn = MTCNN(keep_all=False, device=torch.device("cpu"),
                   post_process=False)
    resnet = InceptionResnetV1(pretrained="vggface2").eval().to(DEVICE)

    out: list[PhotoEmbedding] = []
    t0 = time.time()
    for i, (person, path) in enumerate(photos, 1):
        img = load_pil(path)
        pe = PhotoEmbedding(person=person, path=path)
        if img is None:
            pe.note = "load_failed"
            out.append(pe)
            continue
        bbox = largest_face_bbox(mtcnn, img)
        if bbox is None:
            pe.note = "no_face_detected"
            out.append(pe)
            continue
        pe.bbox = bbox
        try:
            pe.facenet_vec = facenet_embedding(resnet, img, bbox)
        except Exception as exc:
            pe.note += f"facenet_err:{exc} "
        try:
            pe.dlib_vec = dlib_embedding(img, bbox)
        except Exception as exc:
            pe.note += f"dlib_err:{exc} "
        out.append(pe)
        print(f"  [{i:3d}/{len(photos)}] {person:10s} {path.name:40s} "
              f"{'✓face' if bbox else 'no-face':8s} "
              f"dlib={'✓' if pe.dlib_vec is not None else '✗'} "
              f"facenet={'✓' if pe.facenet_vec is not None else '✗'}")
    print(f"[extract] done in {time.time()-t0:.1f}s")
    return out


# --- Analysis --------------------------------------------------------------

def build_person_matrix(embeds: list[PhotoEmbedding],
                        get_vec, metric: str) -> tuple[list[str], np.ndarray,
                                                        dict[str, list[np.ndarray]]]:
    """
    Returns:
      persons: sorted list of person names (only those with ≥2 valid embeddings)
      matrix[i,j]: mean pairwise distance between person i and person j photos
                   (diagonal = within-person mean)
      per_person: dict person -> list of embedding vectors (for later)
    """
    per_person: dict[str, list[np.ndarray]] = {}
    for pe in embeds:
        v = get_vec(pe)
        if v is None:
            continue
        per_person.setdefault(pe.person, []).append(v)

    persons = sorted([p for p, vs in per_person.items() if len(vs) >= 2])
    n = len(persons)
    mat = np.full((n, n), np.nan)

    def pairdist(a: np.ndarray, b: np.ndarray) -> float:
        if metric == "euclidean":
            return float(np.linalg.norm(a - b))
        if metric == "cosine":  # on L2-normed vectors
            return float(1.0 - np.dot(a, b))
        raise ValueError(metric)

    for i, pi in enumerate(persons):
        for j, pj in enumerate(persons):
            vs_i = per_person[pi]
            vs_j = per_person[pj]
            if i == j:
                # within-person: all unordered pairs
                ds = [pairdist(vs_i[a], vs_i[b])
                      for a in range(len(vs_i))
                      for b in range(a+1, len(vs_i))]
            else:
                ds = [pairdist(a, b) for a in vs_i for b in vs_j]
            if ds:
                mat[i, j] = float(np.mean(ds))
    return persons, mat, per_person


def save_heatmap(persons: list[str], mat: np.ndarray,
                 title: str, path: Path) -> None:
    import matplotlib.pyplot as plt
    import seaborn as sns
    fig, ax = plt.subplots(figsize=(1.1*len(persons)+2, 1.0*len(persons)+1.5))
    sns.heatmap(mat, annot=True, fmt=".3f",
                xticklabels=persons, yticklabels=persons,
                cmap="viridis_r", ax=ax,
                cbar_kws={"label": "mean distance (lower = more similar)"})
    ax.set_title(title)
    plt.xticks(rotation=45, ha="right")
    plt.yticks(rotation=0)
    plt.tight_layout()
    plt.savefig(path, dpi=110)
    plt.close(fig)


def save_csv(persons: list[str], mat: np.ndarray, path: Path) -> None:
    with path.open("w") as f:
        f.write("," + ",".join(persons) + "\n")
        for i, p in enumerate(persons):
            cells = [f"{mat[i,j]:.4f}" if not np.isnan(mat[i,j]) else ""
                     for j in range(len(persons))]
            f.write(p + "," + ",".join(cells) + "\n")


def save_within_vs_between(persons: list[str], mat: np.ndarray,
                            per_person: dict[str, list[np.ndarray]],
                            metric: str, title: str, path: Path) -> None:
    """Histogram: within-person pairwise vs between-person pairwise."""
    import matplotlib.pyplot as plt
    within = []
    between = []

    def pairdist(a, b):
        if metric == "euclidean":
            return float(np.linalg.norm(a - b))
        return float(1.0 - np.dot(a, b))

    for pi in persons:
        vs = per_person[pi]
        for a in range(len(vs)):
            for b in range(a+1, len(vs)):
                within.append(pairdist(vs[a], vs[b]))
    for i, pi in enumerate(persons):
        for j, pj in enumerate(persons):
            if j <= i:
                continue
            for a in per_person[pi]:
                for b in per_person[pj]:
                    between.append(pairdist(a, b))

    fig, ax = plt.subplots(figsize=(8, 4))
    bins = 40
    ax.hist(within, bins=bins, alpha=0.55, label=f"within-person (n={len(within)})",
            color="#2ecc71", density=True)
    ax.hist(between, bins=bins, alpha=0.55, label=f"between-person (n={len(between)})",
            color="#e74c3c", density=True)
    ax.set_xlabel(f"{metric} distance")
    ax.set_ylabel("density")
    ax.set_title(title)
    ax.legend()
    plt.tight_layout()
    plt.savefig(path, dpi=110)
    plt.close(fig)


def find_confusable_pairs(persons: list[str], mat: np.ndarray) -> list[dict]:
    """A pair (A,B) is confusable when d(A,B) < max(d(A,A), d(B,B))."""
    pairs = []
    n = len(persons)
    for i in range(n):
        for j in range(i+1, n):
            within_i = mat[i, i]
            within_j = mat[j, j]
            between = mat[i, j]
            if any(np.isnan(x) for x in (within_i, within_j, between)):
                continue
            gap = between - max(within_i, within_j)
            pairs.append({
                "a": persons[i], "b": persons[j],
                "within_a": float(within_i),
                "within_b": float(within_j),
                "between": float(between),
                "gap": float(gap),
                "confusable": gap < 0,
            })
    pairs.sort(key=lambda r: r["gap"])
    return pairs


# --- Summary ---------------------------------------------------------------

def write_summary(embeds: list[PhotoEmbedding],
                  dlib_persons, dlib_mat, dlib_pairs,
                  fnet_persons, fnet_mat, fnet_pairs) -> None:
    lines: list[str] = []
    lines.append("# Family FD Confusion Diagnostic — Summary\n")
    lines.append(f"Run: {time.strftime('%Y-%m-%d %H:%M:%S')}  "
                 f"Device: {DEVICE}\n")

    # Per-person photo counts + detection success
    by_person: dict[str, dict] = {}
    for pe in embeds:
        d = by_person.setdefault(pe.person,
            {"total": 0, "face_ok": 0, "dlib_ok": 0, "facenet_ok": 0})
        d["total"] += 1
        if pe.bbox: d["face_ok"] += 1
        if pe.dlib_vec is not None: d["dlib_ok"] += 1
        if pe.facenet_vec is not None: d["facenet_ok"] += 1

    lines.append("## Photo inventory\n")
    lines.append("| person | total | face detected | dlib embed | facenet embed |")
    lines.append("|--------|-------|---------------|------------|---------------|")
    for p in sorted(by_person):
        d = by_person[p]
        lines.append(f"| {p} | {d['total']} | {d['face_ok']} | "
                     f"{d['dlib_ok']} | {d['facenet_ok']} |")
    lines.append("")

    def bloc(name, persons, mat, pairs, metric):
        out = [f"## {name} ({metric})\n"]
        if len(persons) < 2:
            out.append("*Not enough persons with ≥2 usable photos.*\n")
            return out
        diag = [mat[i, i] for i in range(len(persons))
                if not np.isnan(mat[i, i])]
        off = [mat[i, j] for i in range(len(persons))
               for j in range(len(persons)) if i != j
               and not np.isnan(mat[i, j])]
        out.append(f"- Within-person mean distance: "
                   f"{np.mean(diag):.3f} (min {np.min(diag):.3f}, "
                   f"max {np.max(diag):.3f})")
        out.append(f"- Between-person mean distance: "
                   f"{np.mean(off):.3f} (min {np.min(off):.3f}, "
                   f"max {np.max(off):.3f})")
        gap = np.min(off) - np.max(diag)
        verdict = ("✓ separable — min between > max within"
                   if gap > 0
                   else "⚠ overlap — some within-person > some between-person")
        out.append(f"- **Gap (min_between − max_within) = {gap:+.3f}** "
                   f"→ {verdict}")
        out.append("")
        out.append("### Pair confusability (sorted worst → best)\n")
        out.append("| A | B | within_A | within_B | between | gap | confusable |")
        out.append("|---|---|----------|----------|---------|-----|------------|")
        for r in pairs:
            flag = "**YES**" if r["confusable"] else "no"
            out.append(f"| {r['a']} | {r['b']} | "
                       f"{r['within_a']:.3f} | {r['within_b']:.3f} | "
                       f"{r['between']:.3f} | {r['gap']:+.3f} | {flag} |")
        out.append("")
        return out

    lines += bloc("dlib (128-D ResNet)", dlib_persons, dlib_mat,
                  dlib_pairs, "euclidean")
    lines += bloc("FaceNet (512-D InceptionResnetV1 / VGGFace2)",
                  fnet_persons, fnet_mat, fnet_pairs, "cosine")

    # Tier 2 viability call
    lines.append("## Tier 2 viability call\n")
    def viable(pairs):
        confusable = [p for p in pairs if p["confusable"]]
        return (len(confusable) == 0, confusable)
    dlib_ok, dlib_confused = viable(dlib_pairs)
    fnet_ok, fnet_confused = viable(fnet_pairs)
    if dlib_ok and fnet_ok:
        lines.append("Both embedders **separate all person pairs** on "
                     "current reference photos. A Tier 2 classifier "
                     "(SVM/MLP on frozen embeddings) should work well; "
                     "fine-tuning (Tier 3) is likely unnecessary.")
    elif not dlib_ok and not fnet_ok:
        lines.append(f"Both embedders have confusable pairs "
                     f"(dlib: {len(dlib_confused)}, facenet: "
                     f"{len(fnet_confused)}). Age-bucketed classifier "
                     f"(Tier 2 with sub-classes) is the right next step. "
                     f"If it plateaus, Tier 3 fine-tuning required.")
    else:
        winner = "facenet" if dlib_ok is False and fnet_ok else "dlib"
        lines.append(f"Mixed signal — {winner} separates cleanly, the "
                     f"other does not. Proceed with {winner} as the "
                     f"Tier 2 base embedder.")
    lines.append("")
    lines.append("## Caveats\n")
    lines.append("- Per-person photo counts are uneven; people with <8 photos "
                 "have noisy within-person distance estimates.")
    lines.append("- No age-bucketing yet. If all of a person's photos are "
                 "from the same era, the diagnostic is optimistic about "
                 "across-decade performance.")
    lines.append("- Embeddings are saved to `embeddings.npz` for Tier 2 "
                 "classifier training without re-running this script.\n")

    (OUT_DIR / "summary.md").write_text("\n".join(lines))


# --- Driver ----------------------------------------------------------------

def main():
    photos = discover_photos()
    print(f"[init] {len(photos)} photos across "
          f"{len({p for p,_ in photos})} persons")
    if not photos:
        print("No photos found — aborting.")
        sys.exit(1)

    embeds = extract_all(photos)

    # Save embeddings for Tier 2 reuse
    npz_path = OUT_DIR / "embeddings.npz"
    persons_arr = np.array([e.person for e in embeds])
    paths_arr = np.array([str(e.path) for e in embeds])
    dlib_mask = np.array([e.dlib_vec is not None for e in embeds])
    fnet_mask = np.array([e.facenet_vec is not None for e in embeds])
    dlib_stack = np.stack([e.dlib_vec for e in embeds
                           if e.dlib_vec is not None]) if dlib_mask.any() else np.empty((0, 128))
    fnet_stack = np.stack([e.facenet_vec for e in embeds
                           if e.facenet_vec is not None]) if fnet_mask.any() else np.empty((0, 512))
    np.savez(npz_path,
             persons=persons_arr, paths=paths_arr,
             dlib_mask=dlib_mask, facenet_mask=fnet_mask,
             dlib=dlib_stack, facenet=fnet_stack)
    print(f"[save] embeddings → {npz_path}")

    # dlib matrix
    dpers, dmat, dper = build_person_matrix(
        embeds, lambda e: e.dlib_vec, "euclidean")
    save_heatmap(dpers, dmat, "dlib 128-D — mean Euclidean distance",
                 OUT_DIR / "confusion_matrix_dlib.png")
    save_csv(dpers, dmat, OUT_DIR / "confusion_matrix_dlib.csv")
    save_within_vs_between(dpers, dmat, dper, "euclidean",
                            "dlib — within vs between distribution",
                            OUT_DIR / "within_vs_between_dlib.png")
    dpairs = find_confusable_pairs(dpers, dmat)
    print(f"[dlib] confusable pairs: "
          f"{sum(1 for p in dpairs if p['confusable'])}/{len(dpairs)}")

    # facenet matrix
    fpers, fmat, fper = build_person_matrix(
        embeds, lambda e: e.facenet_vec, "cosine")
    save_heatmap(fpers, fmat, "FaceNet (VGGFace2) — mean cosine distance",
                 OUT_DIR / "confusion_matrix_facenet.png")
    save_csv(fpers, fmat, OUT_DIR / "confusion_matrix_facenet.csv")
    save_within_vs_between(fpers, fmat, fper, "cosine",
                            "FaceNet — within vs between distribution",
                            OUT_DIR / "within_vs_between_facenet.png")
    fpairs = find_confusable_pairs(fpers, fmat)
    print(f"[facenet] confusable pairs: "
          f"{sum(1 for p in fpairs if p['confusable'])}/{len(fpairs)}")

    write_summary(embeds,
                  dpers, dmat, dpairs,
                  fpers, fmat, fpairs)
    print(f"[done] → {OUT_DIR}")


if __name__ == "__main__":
    main()
