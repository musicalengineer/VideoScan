#!/usr/bin/env python3
"""Compare two person-eval JSON reports by metric and by case."""

from __future__ import annotations

import argparse
import json
import pathlib
from typing import Any


def compare(baseline: dict[str, Any], candidate: dict[str, Any]) -> dict[str, Any]:
    if baseline.get("datasetVersion") != candidate.get("datasetVersion"):
        raise ValueError("reports use different datasetVersion values")
    left = {case["id"]: case for case in baseline.get("cases", [])}
    right = {case["id"]: case for case in candidate.get("cases", [])}
    if set(left) != set(right):
        raise ValueError("reports do not contain the same case IDs")

    transitions = []
    for identifier in sorted(left):
        before = bool(left[identifier]["predicted"]["targetPerson"])
        after = bool(right[identifier]["predicted"]["targetPerson"])
        expected = bool(left[identifier]["expected"]["targetPerson"])
        before_ok = before == expected
        after_ok = after == expected
        transition = "unchanged-pass" if before_ok and after_ok else "unchanged-fail"
        if not before_ok and after_ok:
            transition = "recovered"
        elif before_ok and not after_ok:
            transition = "regressed"
        transitions.append({
            "id": identifier, "video": left[identifier].get("video", ""),
            "expected": expected, "baselinePredicted": before,
            "candidatePredicted": after, "transition": transition,
            "baselineBestDistance": left[identifier].get("bestDistance"),
            "candidateBestDistance": right[identifier].get("bestDistance"),
        })

    def metric(report: dict[str, Any], section: str, key: str) -> float | None:
        value = report.get(section, {}).get(key)
        return float(value) if value is not None else None

    def delta(before: float | None, after: float | None) -> float | None:
        return after - before if before is not None and after is not None else None

    metrics = {}
    for name, section, key in (
        ("identityF1", "identityPresence", "f1"),
        ("identityPrecision", "identityPresence", "precision"),
        ("identityRecall", "identityPresence", "recall"),
        ("faceRecall", "facePresence", "recall"),
        ("elapsedSeconds", "performance", "elapsedSeconds"),
        ("peakRSSMB", "performance", "peakRSSMB"),
    ):
        before = metric(baseline, section, key)
        after = metric(candidate, section, key)
        metrics[name] = {"baseline": before, "candidate": after, "delta": delta(before, after)}

    return {
        "schemaVersion": 1,
        "datasetVersion": baseline.get("datasetVersion"),
        "baseline": {"engine": baseline.get("engine"), "score": baseline.get("score")},
        "candidate": {"engine": candidate.get("engine"), "score": candidate.get("score")},
        "metrics": metrics,
        "transitionCounts": {
            key: sum(item["transition"] == key for item in transitions)
            for key in ("recovered", "regressed", "unchanged-pass", "unchanged-fail")
        },
        "cases": transitions,
    }


def _value(value: float | None, percent: bool = False) -> str:
    if value is None:
        return "n/a"
    return f"{value * 100:.1f}%" if percent else f"{value:.2f}"


def markdown(result: dict[str, Any]) -> str:
    lines = [
        "# Person Recognition Comparison", "",
        f"Dataset: **{result['datasetVersion']}**", "",
        f"Baseline: **{result['baseline']['engine']}** ({result['baseline']['score']}/100)  ",
        f"Candidate: **{result['candidate']['engine']}** ({result['candidate']['score']}/100)", "",
        "| Metric | Baseline | Candidate | Delta |", "|---|---:|---:|---:|",
    ]
    for key, label, percent in (
        ("identityF1", "Identity F1", True),
        ("identityPrecision", "Identity precision", True),
        ("identityRecall", "Identity recall", True),
        ("faceRecall", "Face recall", True),
        ("elapsedSeconds", "Elapsed seconds", False),
        ("peakRSSMB", "Peak RSS MB", False),
    ):
        row = result["metrics"][key]
        lines.append(
            f"| {label} | {_value(row['baseline'], percent)} | "
            f"{_value(row['candidate'], percent)} | {_value(row['delta'], percent)} |"
        )
    lines.extend(["", "## Case transitions", "", "| Case | Transition | Baseline best | Candidate best |", "|---|---|---:|---:|"])
    for case in result["cases"]:
        lines.append(
            f"| {case['id']} | {case['transition']} | "
            f"{_value(case['baselineBestDistance'])} | {_value(case['candidateBestDistance'])} |"
        )
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("baseline", type=pathlib.Path)
    parser.add_argument("candidate", type=pathlib.Path)
    parser.add_argument("--json", type=pathlib.Path)
    parser.add_argument("--markdown", type=pathlib.Path)
    args = parser.parse_args()
    try:
        result = compare(json.loads(args.baseline.read_text()), json.loads(args.candidate.read_text()))
    except (OSError, json.JSONDecodeError, ValueError) as exc:
        parser.error(str(exc))
    if args.json:
        args.json.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    if args.markdown:
        args.markdown.write_text(markdown(result))
    counts = result["transitionCounts"]
    print(
        f"{result['baseline']['engine']} {result['baseline']['score']} -> "
        f"{result['candidate']['engine']} {result['candidate']['score']}; "
        f"recovered={counts['recovered']} regressed={counts['regressed']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
