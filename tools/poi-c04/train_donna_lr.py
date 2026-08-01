#!/usr/bin/env python3
"""POI cycle 04 — train the Donna logistic-regression head.

Consumes the per-face embedding dumps produced by extract_embeddings.py
(production ArcFace path) and:

1. Runs leave-one-clip-out (LOCO) cross-validation — the fold unit is the
   WHOLE CLIP, never frame-level splits (frames within a clip are
   near-duplicates and would leak).
2. Chooses the presence threshold p* from the cross-validated per-clip
   max-probabilities (widest optimal interval, midpoint).
3. Fits the final model on ALL rows and writes the committable artifact
   (weights vector + bias + p* — no embeddings, no absolute paths).

The CV numbers are DEVELOPMENT EVIDENCE, NOT A GRADE: p* is chosen from
these same held-out predictions, and the training pool is the whole current
corpus. The official grade runs later on Rick's sealed holdout.

Deterministic: lbfgs from a zero init with fixed hyperparameters; the final
fit is performed twice and byte-compared.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import pathlib
import sys

import numpy as np
import sklearn
from sklearn.linear_model import LogisticRegression

FEATURE_DIM = 512
# L2 regularization is sklearn's default (the explicit `penalty` kwarg is
# deprecated in 1.8); C=1.0 is the untuned default — deliberately not
# optimized against the 26-clip pool.
HYPERPARAMS = dict(
    C=1.0, class_weight="balanced", solver="lbfgs",
    max_iter=5000, tol=1e-8, random_state=0,
)


def load_rows(embeddings_dir: pathlib.Path):
    """Returns (X float64[n,512], y int[n], clip_of_row[n], clips list)."""
    manifest = json.loads((embeddings_dir / "manifest.json").read_text())
    vectors, labels, clip_ids, clips = [], [], [], []
    for entry in manifest["clips"]:
        label, clip = entry["label"], entry["clip"]
        jsonl = embeddings_dir / label / f"{pathlib.Path(clip).stem}.jsonl"
        clip_key = f"{label}/{clip}"
        clips.append({"key": clip_key, "label": label, "clip": clip})
        with jsonl.open() as fh:
            for line in fh:
                row = json.loads(line)
                emb = np.asarray(row["embedding"], dtype=np.float64)
                if emb.shape != (FEATURE_DIM,):
                    raise SystemExit(f"{clip_key}: bad embedding shape {emb.shape}")
                vectors.append(emb)
                labels.append(1 if label == "Donna" else 0)
                clip_ids.append(clip_key)
    X = np.vstack(vectors)
    y = np.asarray(labels)
    norms = np.linalg.norm(X, axis=1)
    # Production embeddings are L2-normalized in Swift; verify rather than
    # transform, so training and inference consume identical vectors
    # ("preprocessing": "arcface-unit-l2" — meaning: already unit, applied
    # upstream by the production extractor, nothing applied here).
    if not np.allclose(norms, 1.0, atol=1e-3):
        raise SystemExit(f"embeddings not unit-norm: {norms.min()}..{norms.max()}")
    return X, y, np.asarray(clip_ids), manifest, clips


def fit_lr(X: np.ndarray, y: np.ndarray) -> LogisticRegression:
    model = LogisticRegression(**HYPERPARAMS)
    model.fit(X, y)
    return model


def loco_max_probabilities(X, y, clip_ids, clips):
    """Leave-one-clip-out: per held-out clip, the max P(Donna) over its
    faces under a model trained on the other 25 clips."""
    folds = []
    for clip in clips:
        held = clip_ids == clip["key"]
        model = fit_lr(X[~held], y[~held])
        probs = model.predict_proba(X[held])[:, 1]
        folds.append({
            "clip": clip["key"],
            "positive": clip["label"] == "Donna",
            "faces": int(held.sum()),
            "maxP": float(probs.max()) if len(probs) else None,
        })
    return folds


def balanced_accuracy(folds, threshold: float):
    tp = sum(1 for f in folds if f["positive"] and f["maxP"] is not None and f["maxP"] >= threshold)
    fn = sum(1 for f in folds if f["positive"]) - tp
    fp = sum(1 for f in folds if not f["positive"] and f["maxP"] is not None and f["maxP"] >= threshold)
    tn = sum(1 for f in folds if not f["positive"]) - fp
    tpr = tp / (tp + fn) if tp + fn else 0.0
    tnr = tn / (tn + fp) if tn + fp else 0.0
    return (tpr + tnr) / 2.0, (tp, fn, fp, tn)


def choose_threshold(folds):
    """The decision surface only changes at observed maxP values, so scan
    the midpoints between consecutive distinct scores (plus outer guards),
    take every BA-maximizing candidate, and return the midpoint of the
    WIDEST maximizing score gap — maximum drift margin, no knife edge."""
    scores = sorted({f["maxP"] for f in folds if f["maxP"] is not None})
    edges = [0.0] + scores + [1.0]
    candidates = [(edges[i] + edges[i + 1]) / 2.0 for i in range(len(edges) - 1)]
    best_ba = max(balanced_accuracy(folds, c)[0] for c in candidates)
    best = [
        (edges[i + 1] - edges[i], (edges[i] + edges[i + 1]) / 2.0)
        for i in range(len(edges) - 1)
        if balanced_accuracy(folds, (edges[i] + edges[i + 1]) / 2.0)[0] == best_ba
    ]
    width, p_star = max(best)
    return p_star, best_ba, width


def legacy_baseline(embeddings_dir: pathlib.Path, clips):
    """Legacy any-hit decisions from the SAME extraction runs' CLI outputs
    (presence ⇔ hits > 0) — the untrained comparator on this corpus."""
    folds = []
    for clip in clips:
        result = embeddings_dir / clip["label"] / (
            f"{pathlib.Path(clip['clip']).stem}.result.json")
        payload = json.loads(result.read_text())
        folds.append({
            "clip": clip["key"], "positive": clip["label"] == "Donna",
            "maxP": 1.0 if payload.get("hits", 0) > 0 else 0.0, "faces": None,
        })
    return balanced_accuracy(folds, 0.5)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--embeddings", type=pathlib.Path, required=True,
                        help="Output dir of extract_embeddings.py (scratch)")
    parser.add_argument("--out", type=pathlib.Path, required=True,
                        help="Committable model artifact path (JSON)")
    parser.add_argument("--report", type=pathlib.Path, required=True,
                        help="CV report JSON (kept in scratch; numbers are "
                             "transcribed into the cycle doc)")
    args = parser.parse_args()

    X, y, clip_ids, manifest, clips = load_rows(args.embeddings)
    n_pos, n_neg = int((y == 1).sum()), int((y == 0).sum())
    print(f"rows: {len(y)} ({n_pos} Donna / {n_neg} NotDonna) from {len(clips)} clips")

    folds = loco_max_probabilities(X, y, clip_ids, clips)
    p_star, cv_ba, margin_width = choose_threshold(folds)
    _, (tp, fn, fp, tn) = balanced_accuracy(folds, p_star)
    print(f"\nLOCO CV (26 folds): BA {cv_ba:.6f}  TP {tp} FN {fn} FP {fp} TN {tn}")
    print(f"chosen p* = {p_star:.6f} (widest optimal gap {margin_width:.6f})")
    for f in sorted(folds, key=lambda f: f["clip"]):
        decided = f["maxP"] is not None and f["maxP"] >= p_star
        ok = "ok " if decided == f["positive"] else "MISS"
        print(f"  {ok} {f['clip']:32s} faces={f['faces']:4d} "
              f"maxP={f['maxP'] if f['maxP'] is not None else float('nan'):.6f}")

    legacy_ba, legacy_counts = legacy_baseline(args.embeddings, clips)
    print(f"\nlegacy any-hit on same extraction runs: BA {legacy_ba:.6f} "
          f"TP/FN/FP/TN {legacy_counts}")

    # Final model on ALL rows; determinism check via a second identical fit.
    model_a = fit_lr(X, y)
    model_b = fit_lr(X, y)
    if not (np.array_equal(model_a.coef_, model_b.coef_)
            and np.array_equal(model_a.intercept_, model_b.intercept_)):
        raise SystemExit("training is not deterministic — refusing to publish")

    weights = [float(w) for w in model_a.coef_[0]]
    bias = float(model_a.intercept_[0])
    artifact = {
        "formatVersion": 1,
        "kind": "logistic-regression",
        "person": "Donna",
        "featureDim": FEATURE_DIM,
        "preprocessing": "arcface-unit-l2",
        "weights": weights,
        "bias": bias,
        "probThreshold": float(p_star),
        "training": {
            "cycle": "poi-c04",
            "trainedAt": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
            "trainer": "tools/poi-c04/train_donna_lr.py",
            "hyperparameters": {k: str(v) for k, v in HYPERPARAMS.items()},
            "sklearnVersion": sklearn.__version__,
            "numpyVersion": np.__version__,
            "pythonVersion": sys.version.split()[0],
            "corpusFingerprint": manifest["corpusFingerprint"],
            "corpusFingerprintRecipe": manifest["corpusFingerprintRecipe"],
            "frameStep": manifest["frameStep"],
            "rows": {"donna": n_pos, "notDonna": n_neg},
            "clips": {"donna": sum(1 for c in clips if c["label"] == "Donna"),
                      "notDonna": sum(1 for c in clips if c["label"] != "Donna")},
            "cvProtocol": "leave-one-clip-out; clip-level decision = any face "
                          "P >= probThreshold; p* chosen from CV predictions "
                          "(development evidence, NOT a grade)",
            "cvBalancedAccuracy": cv_ba,
        },
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(artifact, indent=1) + "\n")
    sha = hashlib.sha256(args.out.read_bytes()).hexdigest()
    print(f"\nartifact: {args.out}\nsha256: {sha}")

    report = {
        "pStar": p_star, "cvBalancedAccuracy": cv_ba,
        "cvCounts": {"tp": tp, "fn": fn, "fp": fp, "tn": tn},
        "widestOptimalGap": margin_width,
        "legacyBalancedAccuracy": legacy_ba,
        "legacyCounts": dict(zip(("tp", "fn", "fp", "tn"), legacy_counts)),
        "folds": folds,
        "artifactSHA256": sha,
        "rows": {"donna": n_pos, "notDonna": n_neg},
    }
    args.report.write_text(json.dumps(report, indent=1) + "\n")
    print(f"report: {args.report}")


if __name__ == "__main__":
    main()
