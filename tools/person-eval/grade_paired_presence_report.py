#!/usr/bin/env python3
"""Fail-closed grader for a frozen two-binary POI paired report.

This module deliberately does not run either binary.  It grades a private
schema-v2 report assembled by the execution harness.  Presence is positive
only for the exact spelling ``confirmed``; raw hits/segments are ignored.
"""

from __future__ import annotations

import argparse
import json
import re
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Any

HEX64 = re.compile(r"^[0-9a-f]{64}$")
VALID_PRESENCE = {"confirmed", "none"}


class GradeError(ValueError):
    pass


@dataclass(frozen=True)
class Metrics:
    tp: int
    fn: int
    fp: int
    tn: int
    precision: float
    recall: float
    f1: float
    balancedAccuracy: float


def _mapping(value: Any, name: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise GradeError(f"{name} must be an object")
    return value


def _hash(value: Any, name: str) -> str:
    if not isinstance(value, str) or not HEX64.fullmatch(value):
        raise GradeError(f"{name} must be a lowercase SHA-256")
    return value


def _identities(value: Any) -> dict[str, dict[str, str]]:
    obj = _mapping(value, "identities")
    if set(obj) != {"control", "candidate"}:
        raise GradeError("identities must contain exactly control and candidate")
    result: dict[str, dict[str, str]] = {}
    for arm in ("control", "candidate"):
        identity = _mapping(obj[arm], f"identities.{arm}")
        required = {"commit", "binarySHA256", "configSHA256"}
        if not required.issubset(identity) or not set(identity).issubset(required | {"modelSHA256"}):
            raise GradeError(f"identities.{arm} is incomplete")
        commit = identity["commit"]
        if not isinstance(commit, str) or not re.fullmatch(r"[0-9a-f]{7,40}", commit):
            raise GradeError(f"identities.{arm}.commit is invalid")
        normalized = {
            "commit": commit,
            "binarySHA256": _hash(identity["binarySHA256"], f"identities.{arm}.binarySHA256"),
            "configSHA256": _hash(identity["configSHA256"], f"identities.{arm}.configSHA256"),
        }
        if "modelSHA256" in identity:
            normalized["modelSHA256"] = _hash(identity["modelSHA256"], f"identities.{arm}.modelSHA256")
        result[arm] = normalized
    if result["control"]["binarySHA256"] == result["candidate"]["binarySHA256"]:
        raise GradeError("control and candidate binary hashes must differ")
    if result["control"]["configSHA256"] == result["candidate"]["configSHA256"]:
        raise GradeError("control and candidate config hashes must differ")
    return result


def _fingerprints(value: Any) -> dict[str, str]:
    obj = _mapping(value, "fingerprints")
    if set(obj) != {"corpusSHA256", "referencesSHA256"}:
        raise GradeError("fingerprints must contain exactly corpusSHA256 and referencesSHA256")
    return {key: _hash(obj[key], f"fingerprints.{key}") for key in sorted(obj)}


def _metrics(expected: dict[str, bool], predicted: dict[str, bool]) -> Metrics:
    tp = sum(expected[key] and predicted[key] for key in expected)
    fn = sum(expected[key] and not predicted[key] for key in expected)
    fp = sum(not expected[key] and predicted[key] for key in expected)
    tn = sum(not expected[key] and not predicted[key] for key in expected)
    positives, negatives = tp + fn, tn + fp
    if positives == 0 or negatives == 0:
        raise GradeError("each round must contain positive and negative cases")
    precision = tp / (tp + fp) if tp + fp else 0.0
    recall = tp / positives
    f1 = 2 * precision * recall / (precision + recall) if precision + recall else 0.0
    return Metrics(tp, fn, fp, tn, precision, recall, f1, (recall + tn / negatives) / 2)


def grade_report(report: Any) -> dict[str, Any]:
    root = _mapping(report, "report")
    if set(root) != {"schemaVersion", "identities", "fingerprints", "rounds"}:
        raise GradeError("report contains missing or unknown fields")
    if type(root.get("schemaVersion")) is not int or root["schemaVersion"] != 2:
        raise GradeError("schemaVersion must be exactly 2")
    identities = _identities(root.get("identities"))
    fingerprints = _fingerprints(root.get("fingerprints"))
    rounds = root.get("rounds")
    if not isinstance(rounds, list) or len(rounds) != 2:
        raise GradeError("exactly two rounds are required")

    required_orders = [["control", "candidate"], ["candidate", "control"]]
    expected_by_round: list[dict[str, bool]] = []
    predictions: dict[str, list[dict[str, bool]]] = {"control": [], "candidate": []}
    metrics: list[dict[str, Metrics]] = []

    for index, raw_round in enumerate(rounds):
        round_obj = _mapping(raw_round, f"rounds[{index}]")
        if set(round_obj) != {"order", "identities", "fingerprints", "cases"}:
            raise GradeError(f"round {index + 1} contains missing or unknown fields")
        if round_obj.get("order") != required_orders[index]:
            raise GradeError(f"round {index + 1} order must be {required_orders[index]}")
        if _identities(round_obj.get("identities")) != identities:
            raise GradeError(f"round {index + 1} identity drift")
        if _fingerprints(round_obj.get("fingerprints")) != fingerprints:
            raise GradeError(f"round {index + 1} fingerprint drift")
        cases = round_obj.get("cases")
        if not isinstance(cases, list) or not cases:
            raise GradeError(f"round {index + 1} cases must be a nonempty array")
        expected: dict[str, bool] = {}
        arm_predictions = {"control": {}, "candidate": {}}
        for case_index, raw_case in enumerate(cases):
            case = _mapping(raw_case, f"rounds[{index}].cases[{case_index}]")
            if set(case) != {"caseId", "expected", "results"}:
                raise GradeError(f"round {index + 1} case contains missing or unknown fields")
            case_id, truth = case.get("caseId"), case.get("expected")
            if not isinstance(case_id, str) or not case_id or case_id in expected:
                raise GradeError(f"round {index + 1} has invalid or duplicate caseId")
            if type(truth) is not bool:
                raise GradeError(f"round {index + 1} case {case_id} expected must be boolean")
            expected[case_id] = truth
            results = _mapping(case.get("results"), f"case {case_id}.results")
            if set(results) != {"control", "candidate"}:
                raise GradeError(f"case {case_id} must contain both arm results")
            for arm in ("control", "candidate"):
                result = _mapping(results[arm], f"case {case_id}.{arm}")
                if set(result) != {"exitCode", "schemaVersion", "presence"}:
                    raise GradeError(f"case {case_id} {arm} contains missing or unknown fields")
                if (type(result.get("exitCode")) is not int or result["exitCode"] != 0
                        or type(result.get("schemaVersion")) is not int or result["schemaVersion"] != 2):
                    raise GradeError(f"case {case_id} {arm} did not complete with schema v2")
                presence = result.get("presence")
                if not isinstance(presence, str) or presence not in VALID_PRESENCE:
                    raise GradeError(f"case {case_id} {arm} has invalid presence")
                arm_predictions[arm][case_id] = presence == "confirmed"
        if index and set(expected) != set(expected_by_round[0]):
            raise GradeError("case membership changed between rounds")
        if index and expected != expected_by_round[0]:
            raise GradeError("expected labels changed between rounds")
        expected_by_round.append(expected)
        for arm in predictions:
            predictions[arm].append(arm_predictions[arm])
        metrics.append({arm: _metrics(expected, arm_predictions[arm]) for arm in predictions})

    prediction_flips = {
        arm: sorted(case_id for case_id in expected_by_round[0]
                    if predictions[arm][0][case_id] != predictions[arm][1][case_id])
        for arm in predictions
    }
    fn_changes = []
    for index in range(2):
        expected = expected_by_round[index]
        control_fn = {key for key, truth in expected.items() if truth and not predictions["control"][index][key]}
        candidate_fn = {key for key, truth in expected.items() if truth and not predictions["candidate"][index][key]}
        fn_changes.append({
            "round": index + 1,
            "controlFalseNegatives": sorted(control_fn),
            "candidateFalseNegatives": sorted(candidate_fn),
            "newFalseNegatives": sorted(candidate_fn - control_fn),
            "correctedFalseNegatives": sorted(control_fn - candidate_fn),
        })
    accuracy = all(metrics[i]["candidate"].balancedAccuracy > metrics[i]["control"].balancedAccuracy for i in range(2))
    safety = all(metrics[i]["candidate"].recall >= metrics[i]["control"].recall for i in range(2))
    stability = not prediction_flips["control"] and not prediction_flips["candidate"]
    passed = accuracy and safety and stability
    return {
        "schemaVersion": 1,
        "verdict": "pass" if passed else "fail",
        "gates": {"accuracy": accuracy, "safety": safety, "stability": stability},
        "identities": identities,
        "fingerprints": fingerprints,
        "rounds": [{arm: asdict(value) for arm, value in round_metrics.items()} for round_metrics in metrics],
        "predictionFlips": prediction_flips,
        "falseNegativeChanges": fn_changes,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("report", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        result = grade_report(json.loads(args.report.read_text()))
    except (OSError, UnicodeError, json.JSONDecodeError, GradeError) as error:
        parser.error(str(error))
    text = json.dumps(result, indent=2, sort_keys=True) + "\n"
    try:
        if args.output:
            args.output.write_text(text)
        else:
            print(text, end="")
    except OSError as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
