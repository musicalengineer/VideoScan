#!/usr/bin/env python3
"""Build a human-review queue from VideoScan catalog identity evidence."""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import hashlib
import json
import pathlib
import re
from typing import Any


DERIVED_WORDS = {
    "compilation", "converted", "by_decade", "demo", "preview", "extract",
    "part1", "part2", "part3", "clip_", "_clip", "unit-test", "unit_test",
}


def _names(record: dict[str, Any], key: str) -> list[str]:
    names = []
    for value in record.get(key, []) or []:
        name = value.get("name") if isinstance(value, dict) else value
        if isinstance(name, str) and name.strip():
            names.append(name.strip())
    return sorted(set(names), key=str.casefold)


def _stable_id(path: str) -> str:
    return hashlib.sha256(path.encode("utf-8")).hexdigest()[:16]


def _source_group(record: dict[str, Any]) -> str:
    """Best available near-duplicate group for train/holdout leakage review."""
    digest = record.get("partialMD5") or record.get("perceptualHash")
    if digest:
        return f"hash:{digest}"
    path = pathlib.Path(record.get("fullPath", ""))
    stem = path.stem.casefold()
    stem = re.sub(r"_?\d{2}h\d{2}m\d{2}s_?\d*", "", stem)
    for token in DERIVED_WORDS:
        stem = stem.replace(token, "")
    normalized = "".join(ch for ch in stem if ch.isalnum())[:80]
    return f"name:{normalized or _stable_id(str(path))}"


def _derived_reason(path: str) -> str | None:
    lower = pathlib.Path(path).name.casefold()
    if re.search(r"\d{2}h\d{2}m\d{2}s", lower):
        return "filename contains an extracted-clip timestamp"
    hit = next((word for word in sorted(DERIVED_WORDS) if word in lower), None)
    return f"filename contains '{hit}'" if hit else None


def _context(record: dict[str, Any]) -> dict[str, Any]:
    captions = record.get("sceneCaptions", []) or []
    snippets = []
    for caption in captions[:3]:
        text = caption.get("text", "") if isinstance(caption, dict) else ""
        if text:
            snippets.append(text[:240])
    return {
        "date": record.get("inferredRecordDate") or record.get("creationDate"),
        "dateConfidence": record.get("inferredDateConfidence"),
        "notes": record.get("notes"),
        "sceneCaptionSnippets": snippets,
    }


def make_queue(
    records: list[dict[str, Any]], target: str, family_names: set[str],
    max_positive: int, max_negative: int, max_duration: float,
    path_exists: callable = pathlib.Path.exists,
) -> dict[str, Any]:
    target_folded = target.casefold()
    candidates: list[dict[str, Any]] = []

    for record in records:
        path = str(record.get("fullPath", ""))
        if not path:
            continue
        duration = float(record.get("durationSeconds") or 0)
        confirmed = _names(record, "confirmedByUserPeople")
        detected = _names(record, "detectedPeople")
        suspected = _names(record, "suspectedPeople")
        confirmed_folded = {name.casefold() for name in confirmed}
        detected_folded = {name.casefold() for name in detected}
        suspected_folded = {name.casefold() for name in suspected}
        target_confirmed = target_folded in confirmed_folded
        other_family = sorted(
            name for name in family_names
            if name.casefold() != target_folded
            and (name.casefold() in confirmed_folded
                 or name.casefold() in detected_folded
                 or name.casefold() in suspected_folded)
        )
        if not target_confirmed and not other_family:
            continue

        derived = _derived_reason(path)
        eligible_duration = duration <= max_duration if max_duration > 0 else True
        reachable = bool(path_exists(pathlib.Path(path)))
        if target_confirmed:
            suggestion = "positive"
            evidence = "human-confirmed target tag"
            priority = 0 if reachable and eligible_duration and not derived else 1
        else:
            suggestion = "hard-negative"
            evidence = "other-family identity evidence; target absence is NOT confirmed"
            priority = 2 if reachable and eligible_duration and not derived else 3

        candidates.append({
            "id": _stable_id(path),
            "video": path,
            "filename": pathlib.Path(path).name,
            "durationSeconds": duration,
            "reachable": reachable,
            "suggestedClass": suggestion,
            "suggestionEvidence": evidence,
            "confirmedPeople": confirmed,
            "detectedPeople": detected,
            "suspectedPeople": suspected,
            "otherFamilyCandidates": other_family,
            "derivedMediaReason": derived,
            "goldenHoldoutEligible": reachable and eligible_duration and derived is None,
            "sourceGroup": _source_group(record),
            "context": _context(record),
            "review": {
                "status": "imported-catalog-confirmation" if target_confirmed else "needs-review",
                "anyFace": True if target_confirmed else None,
                "targetPerson": True if target_confirmed else None,
                "segments": [],
                "reviewedBy": "VideoScan confirmedByUserPeople" if target_confirmed else None,
                "notes": None,
                "set": None,
            },
            "_priority": priority,
        })

    positives = sorted(
        (x for x in candidates if x["suggestedClass"] == "positive"),
        key=lambda x: (x["_priority"], x["durationSeconds"], x["video"]),
    )[:max_positive]
    negatives = sorted(
        (x for x in candidates if x["suggestedClass"] == "hard-negative"),
        key=lambda x: (x["_priority"], x["durationSeconds"], x["video"]),
    )[:max_negative]
    selected = positives + negatives
    group_classes: dict[str, set[str]] = {}
    for item in selected:
        group_classes.setdefault(item["sourceGroup"], set()).add(item["suggestedClass"])
    for item in selected:
        item.pop("_priority", None)
        warnings = []
        if len(group_classes[item["sourceGroup"]]) > 1:
            warnings.append("same sourceGroup appears in both positive and hard-negative suggestions")
            item["goldenHoldoutEligible"] = False
        item["leakageWarnings"] = warnings

    return {
        "schemaVersion": 1,
        "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "targetPerson": target,
        "groundTruthWarning": (
            "suggestedClass is candidate-selection evidence only. A human must fill review; "
            "algorithm detections must never become ground truth automatically."
        ),
        "selection": {
            "maxPositive": max_positive, "maxNegative": max_negative,
            "maxDurationSeconds": max_duration,
            "familyNames": sorted(family_names, key=str.casefold),
        },
        "counts": {
            "positiveCandidates": len(positives),
            "hardNegativeCandidates": len(negatives),
            "holdoutEligible": sum(x["goldenHoldoutEligible"] for x in selected),
            "crossLabelConflicts": sum(bool(x["leakageWarnings"]) for x in selected),
        },
        "candidates": selected,
    }


def _family_names(poi_root: pathlib.Path) -> set[str]:
    names: set[str] = set()
    if not poi_root.exists():
        return names
    for profile in poi_root.glob("*/profile.json"):
        try:
            value = json.loads(profile.read_text()).get("name")
        except (OSError, json.JSONDecodeError):
            continue
        if isinstance(value, str) and value.strip():
            names.add(value.strip())
    return names


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--catalog", type=pathlib.Path, required=True)
    parser.add_argument("--poi-root", type=pathlib.Path, required=True)
    parser.add_argument("--target", default="Donna")
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--csv", type=pathlib.Path,
                        help="optional human-editable review sheet")
    parser.add_argument("--max-positive", type=int, default=20)
    parser.add_argument("--max-negative", type=int, default=20)
    parser.add_argument("--max-duration", type=float, default=300.0)
    args = parser.parse_args()

    catalog = json.loads(args.catalog.expanduser().read_text())
    queue = make_queue(
        catalog.get("records", []), args.target,
        _family_names(args.poi_root.expanduser()),
        max(0, args.max_positive), max(0, args.max_negative), args.max_duration,
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(queue, indent=2, sort_keys=True) + "\n")
    if args.csv:
        args.csv.parent.mkdir(parents=True, exist_ok=True)
        with args.csv.open("w", newline="") as handle:
            fields = [
                "id", "filename", "durationSeconds", "date", "suggestedClass",
                "holdoutEligible", "otherFamily", "targetPerson", "anyFace",
                "set", "reviewedBy", "notes", "video",
            ]
            writer = csv.DictWriter(handle, fieldnames=fields)
            writer.writeheader()
            for item in queue["candidates"]:
                review = item["review"]
                writer.writerow({
                    "id": item["id"], "filename": item["filename"],
                    "durationSeconds": item["durationSeconds"],
                    "date": str(item["context"].get("date") or "")[:10],
                    "suggestedClass": item["suggestedClass"],
                    "holdoutEligible": "yes" if item["goldenHoldoutEligible"] else "no",
                    "otherFamily": ", ".join(item["otherFamilyCandidates"]),
                    "targetPerson": "yes" if review["targetPerson"] is True else ("no" if review["targetPerson"] is False else ""),
                    "anyFace": "yes" if review["anyFace"] is True else ("no" if review["anyFace"] is False else ""),
                    "set": review["set"] or "", "reviewedBy": review["reviewedBy"] or "",
                    "notes": review["notes"] or "", "video": item["video"],
                })
    counts = queue["counts"]
    print(
        f"{args.target}: {counts['positiveCandidates']} positive + "
        f"{counts['hardNegativeCandidates']} hard-negative candidates; "
        f"{counts['holdoutEligible']} holdout-eligible -> {args.output}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
