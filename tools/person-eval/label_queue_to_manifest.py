#!/usr/bin/env python3
"""Export reviewed label-queue entries into a person-eval manifest."""

from __future__ import annotations

import argparse
import json
import pathlib
from typing import Any


def _tags(candidate: dict[str, Any]) -> list[str]:
    tags = {candidate.get("suggestedClass", "reviewed")}
    tags.update(candidate.get("otherFamilyCandidates", []))
    date = str(candidate.get("context", {}).get("date") or "")
    if len(date) >= 4 and date[:4].isdigit():
        tags.add(f"{date[:3]}0s")
    if candidate.get("derivedMediaReason"):
        tags.add("derived-media")
    if candidate.get("leakageWarnings"):
        tags.add("leakage-warning")
    return sorted(tag for tag in tags if tag)


def make_manifest(
    queue: dict[str, Any], engine: str, references: str, dataset_version: str,
    selected_set: str | None, quality: bool, max_cases: int | None = None,
) -> dict[str, Any]:
    reviewed = []
    for candidate in queue.get("candidates", []):
        review = candidate.get("review", {})
        if review.get("targetPerson") is None or review.get("anyFace") is None:
            continue
        if selected_set and review.get("set") != selected_set:
            continue
        reviewed.append(candidate)
    if max_cases is not None:
        reviewed = reviewed[:max(0, max_cases)]
    if not reviewed:
        raise ValueError("queue has no reviewed candidates matching the requested set")

    positives = sum(bool(x["review"]["targetPerson"]) for x in reviewed)
    negatives = len(reviewed) - positives
    if quality:
        if selected_set != "holdout":
            raise ValueError("quality export requires --set holdout")
        if positives == 0 or negatives == 0:
            raise ValueError("quality export requires reviewed positive and negative cases")
        if any(x.get("leakageWarnings") for x in reviewed):
            raise ValueError("quality export contains unresolved leakage warnings")
        if any(not x.get("goldenHoldoutEligible") for x in reviewed):
            raise ValueError("quality export contains holdout-ineligible media")

    cases = []
    for candidate in reviewed:
        review = candidate["review"]
        cases.append({
            "id": candidate["id"],
            "video": candidate["video"],
            "tags": _tags(candidate),
            "sourceGroup": candidate["sourceGroup"],
            "context": candidate.get("context", {}),
            "groundTruth": {
                "status": review.get("status"),
                "reviewedBy": review.get("reviewedBy"),
                "notes": review.get("notes"),
            },
            "expected": {
                "anyFace": bool(review["anyFace"]),
                "targetPerson": bool(review["targetPerson"]),
                "segments": review.get("segments", []),
            },
        })

    target = queue["targetPerson"]
    return {
        "schemaVersion": 1,
        "suite": f"{target} {selected_set or 'reviewed'} set",
        "publication": {
            "tier": "quality" if quality else "development",
            "datasetVersion": dataset_version,
            "holdout": quality,
        },
        "engine": {
            "name": engine,
            "person": target,
            "referencePath": references,
            "timeoutSeconds": 3600,
            "command": [
                "{app}", "--person-eval", "--engine", engine.casefold(),
                "--person", "{person}", "--references", "{references}",
                "--video", "{video}", "--frame-step", "5",
            ],
        },
        "datasetSummary": {
            "cases": len(cases), "positives": positives, "negatives": negatives,
            "sourceQueueGeneratedAt": queue.get("generatedAt"),
        },
        "cases": cases,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--queue", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--engine", choices=("Vision", "ArcFace", "dlib", "Hybrid"), required=True)
    parser.add_argument("--references", required=True)
    parser.add_argument("--dataset-version", required=True)
    parser.add_argument("--set", choices=("development", "holdout"))
    parser.add_argument("--quality", action="store_true")
    parser.add_argument("--max-cases", type=int)
    args = parser.parse_args()

    queue = json.loads(args.queue.read_text())
    try:
        manifest = make_manifest(
            queue, args.engine, args.references, args.dataset_version,
            args.set, args.quality, args.max_cases,
        )
    except ValueError as exc:
        parser.error(str(exc))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    summary = manifest["datasetSummary"]
    print(
        f"{manifest['suite']}: {summary['positives']} positive + "
        f"{summary['negatives']} negative -> {args.output}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
