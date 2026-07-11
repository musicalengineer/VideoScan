#!/usr/bin/env python3
"""Score VideoScan person-recognition runs against a labeled manifest."""

from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import json
import os
import pathlib
import subprocess
import sys
import time
from typing import Any


SCHEMA_VERSION = 1


class EvaluationError(RuntimeError):
    pass


@dataclasses.dataclass(frozen=True)
class Counts:
    tp: int = 0
    fp: int = 0
    tn: int = 0
    fn: int = 0

    @property
    def precision(self) -> float | None:
        return _ratio(self.tp, self.tp + self.fp)

    @property
    def recall(self) -> float | None:
        return _ratio(self.tp, self.tp + self.fn)

    @property
    def accuracy(self) -> float | None:
        return _ratio(self.tp + self.tn, self.tp + self.fp + self.tn + self.fn)

    @property
    def false_positive_rate(self) -> float | None:
        return _ratio(self.fp, self.fp + self.tn)

    @property
    def f1(self) -> float | None:
        p, r = self.precision, self.recall
        if p is None or r is None or p + r == 0:
            return 0.0 if (self.tp + self.fp + self.fn) > 0 else None
        return 2 * p * r / (p + r)

    def as_dict(self) -> dict[str, Any]:
        return {
            "tp": self.tp, "fp": self.fp, "tn": self.tn, "fn": self.fn,
            "precision": self.precision, "recall": self.recall,
            "f1": self.f1, "accuracy": self.accuracy,
            "false_positive_rate": self.false_positive_rate,
        }


def _ratio(numerator: float, denominator: float) -> float | None:
    return numerator / denominator if denominator else None


def _classification(expected: bool, predicted: bool) -> Counts:
    if expected and predicted:
        return Counts(tp=1)
    if expected:
        return Counts(fn=1)
    if predicted:
        return Counts(fp=1)
    return Counts(tn=1)


def _sum_counts(items: list[Counts]) -> Counts:
    return Counts(
        tp=sum(x.tp for x in items), fp=sum(x.fp for x in items),
        tn=sum(x.tn for x in items), fn=sum(x.fn for x in items),
    )


def _interval_union_length(intervals: list[tuple[float, float]]) -> float:
    ordered = sorted((max(0.0, a), max(0.0, b)) for a, b in intervals if b > a)
    if not ordered:
        return 0.0
    total = 0.0
    start, end = ordered[0]
    for next_start, next_end in ordered[1:]:
        if next_start <= end:
            end = max(end, next_end)
        else:
            total += end - start
            start, end = next_start, next_end
    return total + end - start


def _intersection_length(
    left: list[tuple[float, float]], right: list[tuple[float, float]]
) -> float:
    events: list[tuple[float, int, int]] = []
    for start, end in left:
        if end > start:
            events.extend(((start, 1, 0), (end, -1, 0)))
    for start, end in right:
        if end > start:
            events.extend(((start, 0, 1), (end, 0, -1)))
    events.sort(key=lambda x: (x[0], x[1] + x[2]))
    active_left = active_right = 0
    previous: float | None = None
    total = 0.0
    for position, delta_left, delta_right in events:
        if previous is not None and active_left > 0 and active_right > 0:
            total += position - previous
        active_left += delta_left
        active_right += delta_right
        previous = position
    return total


def _segments(raw: list[dict[str, Any]]) -> list[tuple[float, float]]:
    return [(float(x["start"]), float(x["end"])) for x in raw]


def _resolve(base: pathlib.Path, value: str) -> pathlib.Path:
    path = pathlib.Path(os.path.expanduser(value))
    return path if path.is_absolute() else (base / path).resolve()


def _run_case(
    case: dict[str, Any], engine: dict[str, Any], base: pathlib.Path,
    app_path: pathlib.Path | None,
) -> tuple[dict[str, Any], float]:
    if "result" in case:
        result_path = _resolve(base, case["result"])
        return json.loads(result_path.read_text()), 0.0

    command = engine.get("command")
    if not command:
        raise EvaluationError(f"case {case['id']}: no result fixture and engine has no command")
    video = _resolve(base, case["video"])
    references = _resolve(base, engine.get("referencePath", ""))
    if not video.exists():
        raise EvaluationError(f"case {case['id']}: video does not exist: {video}")
    values = {
        "video": str(video), "references": str(references),
        "person": str(engine.get("person", "")),
        "engine": str(engine.get("name", "")),
        "app": str(app_path or engine.get("appPath", "")),
    }
    # Replace only the evaluator's explicit tokens. Do not use str.format:
    # commands may legitimately contain braces (Python snippets, JSON, regex).
    args = []
    for part in command:
        expanded = part
        for key, value in values.items():
            expanded = expanded.replace("{" + key + "}", value)
        args.append(expanded)
    if not args[0]:
        raise EvaluationError(f"case {case['id']}: command requires --app or engine.appPath")
    started = time.monotonic()
    try:
        completed = subprocess.run(
            args, cwd=base, capture_output=True, text=True,
            timeout=float(engine.get("timeoutSeconds", 3600)), check=False,
        )
    except subprocess.TimeoutExpired as exc:
        raise EvaluationError(
            f"case {case['id']}: engine timed out after {exc.timeout:g}s"
        ) from exc
    elapsed = time.monotonic() - started
    if completed.returncode != 0:
        raise EvaluationError(
            f"case {case['id']}: command exited {completed.returncode}: "
            f"{completed.stderr[-1000:]}"
        )
    try:
        return json.loads(completed.stdout), elapsed
    except json.JSONDecodeError as exc:
        raise EvaluationError(f"case {case['id']}: invalid engine JSON: {exc}") from exc


def evaluate(
    manifest_path: pathlib.Path, app_path: pathlib.Path | None = None
) -> dict[str, Any]:
    manifest = json.loads(manifest_path.read_text())
    if manifest.get("schemaVersion") != SCHEMA_VERSION:
        raise EvaluationError(f"unsupported schemaVersion: {manifest.get('schemaVersion')}")
    base = manifest_path.parent
    engine = manifest["engine"]
    cases = manifest.get("cases", [])
    if not cases:
        raise EvaluationError("manifest has no cases")
    results: list[dict[str, Any]] = []

    for case in cases:
        observed, elapsed = _run_case(case, engine, base, app_path)
        expected_face = bool(case["expected"]["anyFace"])
        expected_identity = bool(case["expected"]["targetPerson"])
        predicted_face = int(observed.get("facesDetected", observed.get("faces_detected", 0))) > 0
        predicted_segments = _segments(observed.get("segments", []))
        predicted_identity = bool(predicted_segments) or int(observed.get("hits", 0)) > 0
        expected_segments = _segments(case["expected"].get("segments", []))
        expected_duration = _interval_union_length(expected_segments)
        predicted_duration = _interval_union_length(predicted_segments)
        overlap = _intersection_length(expected_segments, predicted_segments)
        segment_recall = _ratio(overlap, expected_duration)
        segment_precision = _ratio(overlap, predicted_duration)
        results.append({
            "id": case["id"], "video": case.get("video", ""),
            "tags": sorted(set(case.get("tags", []))),
            "expected": {"anyFace": expected_face, "targetPerson": expected_identity},
            "predicted": {"anyFace": predicted_face, "targetPerson": predicted_identity},
            "faceClass": _classification(expected_face, predicted_face).as_dict(),
            "identityClass": _classification(expected_identity, predicted_identity).as_dict(),
            "expectedPresenceSeconds": expected_duration,
            "predictedPresenceSeconds": predicted_duration,
            "overlapSeconds": overlap,
            "segmentRecall": segment_recall,
            "segmentPrecision": segment_precision,
            "elapsedSeconds": float(observed.get("elapsedSeconds", elapsed)),
            "peakRSSMB": observed.get("peakRSSMB"),
            "facesDetected": int(observed.get("facesDetected", observed.get("faces_detected", 0))),
            "hits": int(observed.get("hits", 0)),
            "bestDistance": observed.get("bestDistance", observed.get("best_dist")),
            "error": observed.get("error"),
        })

    face_counts = _sum_counts([Counts(**{k: r["faceClass"][k] for k in ("tp", "fp", "tn", "fn")}) for r in results])
    identity_counts = _sum_counts([Counts(**{k: r["identityClass"][k] for k in ("tp", "fp", "tn", "fn")}) for r in results])
    segment_expected = sum(r["expectedPresenceSeconds"] for r in results)
    segment_predicted = sum(r["predictedPresenceSeconds"] for r in results)
    segment_overlap = sum(r["overlapSeconds"] for r in results)

    tags: dict[str, Any] = {}
    for tag in sorted({tag for result in results for tag in result["tags"]}):
        tagged = [r for r in results if tag in r["tags"]]
        counts = _sum_counts([Counts(**{k: r["identityClass"][k] for k in ("tp", "fp", "tn", "fn")}) for r in tagged])
        tags[tag] = {"cases": len(tagged), **counts.as_dict()}

    peak_values = [float(r["peakRSSMB"]) for r in results if r["peakRSSMB"] is not None]
    has_fixture_results = any("result" in case for case in cases)
    has_identity_positive = any(bool(case["expected"]["targetPerson"]) for case in cases)
    has_identity_negative = any(not bool(case["expected"]["targetPerson"]) for case in cases)
    ineligibility_reasons: list[str] = []
    publication = manifest.get("publication", {})
    publication_tier = publication.get("tier", "development")
    dataset_version = publication.get("datasetVersion")
    is_holdout = publication.get("holdout") is True
    if publication_tier != "quality":
        ineligibility_reasons.append("suite is not marked as quality-tier")
    if not dataset_version:
        ineligibility_reasons.append("suite has no stable datasetVersion")
    if not is_holdout:
        ineligibility_reasons.append("suite is not marked as a holdout")
    if has_fixture_results:
        ineligibility_reasons.append("contains prerecorded result fixtures")
    if not has_identity_positive:
        ineligibility_reasons.append("has no identity-positive cases")
    if not has_identity_negative:
        ineligibility_reasons.append("has no identity-negative cases")
    if any(result["error"] for result in results):
        ineligibility_reasons.append("one or more engine results reported errors")

    report = {
        "schemaVersion": SCHEMA_VERSION,
        "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "suite": manifest.get("suite", manifest_path.stem),
        "person": engine.get("person", ""), "engine": engine.get("name", ""),
        "caseCount": len(results),
        "publicationTier": publication_tier,
        "datasetVersion": dataset_version,
        "holdout": is_holdout,
        "resultSource": "fixture" if has_fixture_results else "live-engine",
        "publishEligible": not ineligibility_reasons,
        "ineligibilityReasons": ineligibility_reasons,
        "facePresence": face_counts.as_dict(),
        "identityPresence": identity_counts.as_dict(),
        "segment": {
            "expectedSeconds": segment_expected, "predictedSeconds": segment_predicted,
            "overlapSeconds": segment_overlap,
            "recall": _ratio(segment_overlap, segment_expected),
            "precision": _ratio(segment_overlap, segment_predicted),
        },
        "performance": {
            "elapsedSeconds": sum(r["elapsedSeconds"] for r in results),
            "peakRSSMB": max(peak_values) if peak_values else None,
        },
        "byTag": tags, "cases": results,
    }
    headline = identity_counts.f1
    report["score"] = None if headline is None else round(100 * headline, 1)
    return report


def _pct(value: float | None) -> str:
    return "n/a" if value is None else f"{100 * value:.1f}%"


def markdown(report: dict[str, Any]) -> str:
    identity, face, segment = report["identityPresence"], report["facePresence"], report["segment"]
    lines = [
        f"# Person Recognition Evaluation — {report['person']}", "",
        f"**Score:** {report['score'] if report['score'] is not None else 'n/a'}/100 (identity F1)", "",
        f"Engine: **{report['engine']}** · Cases: **{report['caseCount']}** · Generated: {report['generatedAt']}", "",
        f"Dataset: **{report['datasetVersion'] or 'unversioned'}** · Tier: **{report['publicationTier']}** · Holdout: **{'yes' if report['holdout'] else 'no'}**", "",
        f"Metrics publication: **{'eligible' if report['publishEligible'] else 'NOT ELIGIBLE'}**", "",
        "| Signal | Precision | Recall | F1 | Accuracy | FP | FN |", "|---|---:|---:|---:|---:|---:|---:|",
        f"| Any face | {_pct(face['precision'])} | {_pct(face['recall'])} | {_pct(face['f1'])} | {_pct(face['accuracy'])} | {face['fp']} | {face['fn']} |",
        f"| {report['person']} present | {_pct(identity['precision'])} | {_pct(identity['recall'])} | {_pct(identity['f1'])} | {_pct(identity['accuracy'])} | {identity['fp']} | {identity['fn']} |",
        f"| Screen-time segments | {_pct(segment['precision'])} | {_pct(segment['recall'])} | — | — | — | — |", "",
    ]
    if report["ineligibilityReasons"]:
        lines.extend(["Reasons: " + "; ".join(report["ineligibilityReasons"]), ""])
    lines.extend(["## Cases", "", "| Case | Expected | Predicted | Result | Tags |", "|---|---|---|---|---|"])
    for case in report["cases"]:
        expected = "present" if case["expected"]["targetPerson"] else "absent"
        predicted = "present" if case["predicted"]["targetPerson"] else "absent"
        verdict = "PASS" if expected == predicted else ("FALSE POSITIVE" if predicted == "present" else "FALSE NEGATIVE")
        lines.append(f"| {case['id']} | {expected} | {predicted} | {verdict} | {', '.join(case['tags'])} |")
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest", type=pathlib.Path)
    parser.add_argument("--json", type=pathlib.Path)
    parser.add_argument("--markdown", type=pathlib.Path)
    parser.add_argument("--app", type=pathlib.Path,
                        help="VideoScan executable used by {app} in engine.command")
    parser.add_argument("--require-publishable", action="store_true",
                        help="exit 4 unless the suite is safe for metrics publication")
    args = parser.parse_args(argv)
    try:
        report = evaluate(args.manifest.resolve(), args.app.resolve() if args.app else None)
    except (OSError, KeyError, ValueError, EvaluationError, json.JSONDecodeError) as exc:
        print(f"person-eval: {exc}", file=sys.stderr)
        return 2
    output = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(output)
    if args.markdown:
        args.markdown.parent.mkdir(parents=True, exist_ok=True)
        args.markdown.write_text(markdown(report))
    print(f"{report['person']} / {report['engine']}: {report['score']}/100 identity F1 ({report['caseCount']} cases)")
    if args.require_publishable and not report["publishEligible"]:
        print("person-eval: report is not publication-eligible: "
              + "; ".join(report["ineligibilityReasons"]), file=sys.stderr)
        return 4
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
