#!/usr/bin/env python3
"""Cosine-threshold sweep for the Donna corpus (POI cycle 2) — WORKING
EVIDENCE ONLY. The official A/B grade is owned by codex; numbers from this
script inform the choice of operating point and are quoted as such.

Lives in tools/poi-c02/ — tools/person-eval/ (the frozen grading harness) is
deliberately untouched, same discipline as cycle 1.

Enumerates the dynamic corpus (Donna/ and NotDonna/ directories), runs the
VideoScan person-eval CLI ONCE per clip per arm at the loosest threshold of
the sweep range with `--emit-hit-distances`, then computes the balanced-
accuracy curve offline: a clip is predicted PRESENT at cosine threshold t iff
it has at least one hit with distance ≤ 1 − t. This is exact for the captured
run, not an approximation — a hit at threshold t is by definition a face
whose best reference cosine is ≥ t, and the capture run records every hit's
distance at the loosest t of the range (stricter sweeps are subsets).
Caveat: ArcFace inference is not bit-stable run to run, so a direct rerun at
a stricter t can differ near decision boundaries; boundary cases are reported
so they can be checked individually rather than averaged away.

Per-clip captures are cached in --out and reused ONLY when their recorded
provenance (app binary sha256, references dir fingerprint, arm flags, corpus
fingerprint, frame step, base threshold) matches the current invocation;
anything else forces a fresh run. `sweep.json` carries the same provenance.

Arms are defined by the references dir and optional extra CLI flags. The C2
candidate is the in-memory audited calibration — SAME reference directory as
legacy, selected by flags (one canonical candidate definition; materialized
refset folders from make_refset.py are cross-check utilities, not the
candidate):
  legacy arm:     --references "<production refs>"
  candidate arm:  --references "<production refs>" \
                  --arm-flags "--reference-calibration audited"
For audited arms the capture threshold is passed via --calibration-threshold
(the flag that owns the operating point in audited mode); legacy arms use
--threshold. Either way the capture happens at --t-min.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import shlex
import subprocess
import sys

VIDEO_EXTS = {".mov", ".mp4", ".m4v", ".avi", ".mts", ".m2ts", ".mkv", ".mxf"}


def corpus_clips(root: pathlib.Path) -> list[tuple[str, pathlib.Path, bool]]:
    clips = []
    for sub, positive in (("Donna", True), ("NotDonna", False)):
        for path in sorted((root / sub).iterdir()):
            if path.suffix.lower() in VIDEO_EXTS and not path.name.startswith("."):
                clips.append((f"{sub}/{path.name}", path, positive))
    if not clips:
        raise SystemExit(f"no clips found under {root}")
    return clips


def corpus_fingerprint(clips: list[tuple[str, pathlib.Path, bool]]) -> str:
    digest = hashlib.sha256()
    for rel, path, _ in sorted(clips):
        digest.update(f"{rel}\n".encode())
        digest.update(bytes.fromhex(sha256_file(path)))
    return digest.hexdigest()


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def refs_fingerprint(refs: pathlib.Path) -> str:
    """sha256 over sorted relative names and content hashes."""
    digest = hashlib.sha256()
    if refs.is_dir():
        for path in sorted(refs.rglob("*")):
            if path.is_file():
                digest.update(f"{path.relative_to(refs)}\n".encode())
                digest.update(bytes.fromhex(sha256_file(path)))
    elif refs.exists():
        digest.update(f"{refs.name}\n".encode())
        digest.update(bytes.fromhex(sha256_file(refs)))
    return digest.hexdigest()


def build_command(app: pathlib.Path, video: pathlib.Path, references: str,
                  base_threshold: float, frame_step: int,
                  arm_flags: list[str]) -> list[str]:
    cmd = [str(app), "--person-eval", "--engine", "arcface",
           "--person", "Donna", "--references", references,
           "--video", str(video), "--frame-step", str(frame_step),
           "--emit-hit-distances"]
    mode = None
    if "--reference-calibration" in arm_flags:
        pos = arm_flags.index("--reference-calibration")
        if pos + 1 >= len(arm_flags):
            raise SystemExit("--reference-calibration requires legacy|audited")
        mode = arm_flags[pos + 1]
    if mode == "audited":
        # Audited mode owns its operating point via --calibration-threshold.
        if "--calibration-threshold" not in arm_flags:
            cmd += arm_flags + ["--calibration-threshold", f"{base_threshold:g}"]
        else:
            raise SystemExit(
                "arm flags must not pin --calibration-threshold: the capture "
                "threshold is --t-min by construction")
    else:
        if "--calibration-link" in arm_flags or "--calibration-threshold" in arm_flags:
            raise SystemExit("explicit/default legacy arm cannot receive audited calibration flags")
        if "--threshold" in arm_flags:
            raise SystemExit(
                "arm flags must not pin --threshold: the capture threshold "
                "is --t-min by construction")
        cmd += ["--threshold", f"{base_threshold:g}"] + arm_flags
    return cmd


def run_clip(cmd: list[str], provenance: dict, out_path: pathlib.Path,
             rerun: bool) -> dict:
    if out_path.exists() and not rerun:
        cached = json.loads(out_path.read_text())
        if cached.get("provenance") == provenance:
            return cached["result"]
        print(f"  cache provenance mismatch, rerunning: {out_path.name}",
              file=sys.stderr)
    completed = subprocess.run(cmd, capture_output=True, text=True, timeout=1800)
    if completed.returncode != 0:
        raise SystemExit(f"{cmd[-3]}: CLI exited {completed.returncode}: "
                         f"{completed.stderr[-800:]}")
    result = json.loads(completed.stdout)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps({"provenance": provenance, "result": result},
                                   indent=1, sort_keys=True) + "\n")
    return result


def sweep(results: dict[str, dict], labels: dict[str, bool],
          thresholds: list[float]) -> list[dict]:
    curve = []
    for t in thresholds:
        tp = fp = tn = fn = 0
        for rel, result in results.items():
            distances = result.get("hitDistances") or []
            present = any(d <= 1.0 - t + 1e-9 for d in distances)
            if labels[rel]:
                tp += present
                fn += not present
            else:
                fp += present
                tn += not present
        tpr = tp / max(1, tp + fn)
        tnr = tn / max(1, tn + fp)
        curve.append({"threshold": round(t, 4), "tp": tp, "fp": fp,
                      "tn": tn, "fn": fn,
                      "tpr": round(tpr, 4), "tnr": round(tnr, 4),
                      "balancedAccuracy": round((tpr + tnr) / 2, 4)})
    return curve


def boundary_cases(results: dict[str, dict], labels: dict[str, bool],
                   thresholds: list[float], margin: float = 0.02) -> list[dict]:
    """Clips whose decisive distance sits within `margin` of a sweep
    threshold — the ones ArcFace run-to-run drift could flip."""
    flagged = []
    for rel, result in sorted(results.items()):
        distances = result.get("hitDistances") or []
        if not distances:
            continue
        best_cos = 1.0 - min(distances)
        near = [t for t in thresholds if abs(best_cos - t) <= margin]
        if near:
            flagged.append({"clip": rel, "positive": labels[rel],
                            "bestCosine": round(best_cos, 4),
                            "nearThresholds": [round(t, 2) for t in near]})
    return flagged


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=pathlib.Path, required=True,
                        help="VideoScan executable (Release build)")
    parser.add_argument("--corpus", type=pathlib.Path, required=True,
                        help="dir containing Donna/ and NotDonna/")
    parser.add_argument("--references", required=True,
                        help="reference dir passed to the CLI")
    parser.add_argument("--arm-flags", default="",
                        help="extra CLI flags defining this arm (shell-quoted)")
    parser.add_argument("--arm-name", default="arm")
    parser.add_argument("--out", type=pathlib.Path, required=True,
                        help="cache/output dir for this arm")
    parser.add_argument("--t-min", type=float, default=0.40)
    parser.add_argument("--t-max", type=float, default=0.65)
    parser.add_argument("--t-step", type=float, default=0.01)
    parser.add_argument("--frame-step", type=int, default=10)
    parser.add_argument("--rerun", action="store_true")
    args = parser.parse_args(argv)

    arm_flags = shlex.split(args.arm_flags)
    clips = corpus_clips(args.corpus)
    fingerprint = corpus_fingerprint(clips)
    labels = {rel: positive for rel, _, positive in clips}
    provenance = {
        "appSha256": sha256_file(args.app),
        "references": args.references,
        "referencesFingerprint": refs_fingerprint(pathlib.Path(args.references)),
        "armFlags": arm_flags,
        "corpusFingerprint": fingerprint,
        "frameStep": args.frame_step,
        "baseThreshold": args.t_min,
    }
    results: dict[str, dict] = {}
    for rel, path, _ in clips:
        cmd = build_command(args.app, path, args.references, args.t_min,
                            args.frame_step, arm_flags)
        out_path = args.out / (rel.replace("/", "_") + ".json")
        results[rel] = run_clip(cmd, provenance, out_path, args.rerun)
        hits = len(results[rel].get("hitDistances") or [])
        print(f"  {rel}: {hits} hits @ t={args.t_min:g}", file=sys.stderr)

    count = round((args.t_max - args.t_min) / args.t_step)
    thresholds = [args.t_min + i * args.t_step for i in range(count + 1)]
    curve = sweep(results, labels, thresholds)
    summary = {
        "arm": args.arm_name,
        "provenance": provenance,
        "corpus": str(args.corpus),
        "cases": {"positive": sum(labels.values()),
                  "negative": sum(not v for v in labels.values())},
        "curve": curve,
        "boundaryCases": boundary_cases(results, labels, thresholds),
    }
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / "sweep.json").write_text(json.dumps(summary, indent=1, sort_keys=True) + "\n")
    print(f"corpus fingerprint: {fingerprint}")
    print(f"{'t':>6s} {'TP':>3s} {'FP':>3s} {'TN':>3s} {'FN':>3s} {'TPR':>6s} {'TNR':>6s} {'BA':>6s}")
    for point in curve:
        print(f"{point['threshold']:6.2f} {point['tp']:3d} {point['fp']:3d} "
              f"{point['tn']:3d} {point['fn']:3d} {point['tpr']:6.3f} "
              f"{point['tnr']:6.3f} {point['balancedAccuracy']:6.3f}")
    if summary["boundaryCases"]:
        print("boundary cases (|best cosine − t| ≤ 0.02 — drift-sensitive):")
        for case in summary["boundaryCases"]:
            print(f"  {case['clip']}: best cosine {case['bestCosine']} "
                  f"near {case['nearThresholds']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
