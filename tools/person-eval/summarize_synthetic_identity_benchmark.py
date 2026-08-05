#!/usr/bin/env python3
"""Summarize output from the 25 ControlFace RecipeCalibrationCLI runs."""

from __future__ import annotations

import argparse
import json
import re
import statistics
from collections import defaultdict
from pathlib import Path


ROW = re.compile(
    r"\s+(Donna|NotDonna)/(query\.(mp4|mkv)): "
    r"(?:(ERR .+)|([-0-9.]+) \((\d+) frames, (\d+) gated faces\))"
)


def parse_log(text: str) -> tuple[list[dict], list[dict]]:
    identity = None
    rows: list[dict] = []
    errors: list[dict] = []
    for line in text.splitlines():
        if line.startswith("### "):
            identity = line[4:]
            continue
        match = ROW.match(line)
        if not match:
            continue
        if identity is None:
            raise ValueError("score row appeared before identity marker")
        label, filename, transport, error, score, frames, faces = match.groups()
        base = {"identity": identity, "label": label, "transport": transport, "filename": filename}
        if error:
            errors.append({**base, "error": error})
        else:
            rows.append(
                {
                    **base,
                    "score": float(score),
                    "frames": int(frames),
                    "gatedFaces": int(faces),
                }
            )
    return rows, errors


def _tier(score: float, detected: float, suspected: float) -> str:
    if score >= detected:
        return "detected"
    if score >= suspected:
        return "suspected"
    return "none"


def _distribution(rows: list[dict], detected: float, suspected: float) -> dict:
    scores = [row["score"] for row in rows]
    return {
        "count": len(scores),
        "min": min(scores),
        "median": statistics.median(scores),
        "max": max(scores),
        "detectedCount": sum(score >= detected for score in scores),
        "surfacedCount": sum(score >= suspected for score in scores),
    }


def summarize(rows: list[dict], errors: list[dict], detected: float = 0.46, suspected: float = 0.30) -> dict:
    positive = [row for row in rows if row["label"] == "Donna"]
    negative = [row for row in rows if row["label"] == "NotDonna"]
    wins = 0.0
    for pos in positive:
        for neg in negative:
            wins += 1.0 if pos["score"] > neg["score"] else 0.5 if pos["score"] == neg["score"] else 0.0
    auc = wins / (len(positive) * len(negative)) if positive and negative else None

    groups: dict[tuple[str, str], dict[str, float]] = defaultdict(dict)
    for row in rows:
        groups[(row["identity"], row["label"])][row["transport"]] = row["score"]
    route_pairs = []
    for (identity, label), scores in sorted(groups.items()):
        if set(scores) != {"mp4", "mkv"}:
            continue
        mp4_tier = _tier(scores["mp4"], detected, suspected)
        mkv_tier = _tier(scores["mkv"], detected, suspected)
        route_pairs.append(
            {
                "identity": identity,
                "label": label,
                "mp4Score": scores["mp4"],
                "mkvScore": scores["mkv"],
                "absoluteDelta": abs(scores["mp4"] - scores["mkv"]),
                "mp4Tier": mp4_tier,
                "mkvTier": mkv_tier,
                "tierFlip": mp4_tier != mkv_tier,
            }
        )
    deltas = [row["absoluteDelta"] for row in route_pairs]
    return {
        "schemaVersion": 1,
        "thresholds": {"detected": detected, "suspected": suspected},
        "scoredCases": len(rows),
        "errors": errors,
        "sameIdentity": _distribution(positive, detected, suspected),
        "differentIdentity": _distribution(negative, detected, suspected),
        "pairwiseAUC": auc,
        "routeComparison": {
            "pairCount": len(route_pairs),
            "medianAbsoluteDelta": statistics.median(deltas) if deltas else None,
            "maxAbsoluteDelta": max(deltas) if deltas else None,
            "tierFlipCount": sum(row["tierFlip"] for row in route_pairs),
            "tierFlips": [row for row in route_pairs if row["tierFlip"]],
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--detected", type=float, default=0.46)
    parser.add_argument("--suspected", type=float, default=0.30)
    parser.add_argument("--binary-sha256")
    parser.add_argument("--source-commit")
    args = parser.parse_args()
    rows, errors = parse_log(args.log.read_text())
    report = summarize(rows, errors, args.detected, args.suspected)
    report["binarySHA256"] = args.binary_sha256
    report["sourceCommitAtCapture"] = args.source_commit
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    return 0 if not errors else 1


if __name__ == "__main__":
    raise SystemExit(main())
