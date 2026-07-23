#!/usr/bin/env python3
"""Validate and publish the public POI-cycle metric stream.

The canonical rows live in docs/poi-cycles/metrics.jsonl. Cycle completion
must add or update its row there, then run this tool with --output pointing at
the metrics worktree's metrics/poi_cycles.jsonl before committing that branch.
"""

from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path
import tempfile


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SOURCE = ROOT / "docs" / "poi-cycles" / "metrics.jsonl"
VALID_TIERS = {"grade", "development"}
VALID_VERDICTS = {"pass", "fail", "development"}


def load_and_validate(path: Path) -> list[dict]:
    rows: list[dict] = []
    for line_number, raw in enumerate(path.read_text().splitlines(), 1):
        if not raw.strip():
            continue
        try:
            row = json.loads(raw)
        except json.JSONDecodeError as error:
            raise ValueError(f"line {line_number}: invalid JSON: {error}") from error
        validate_row(row, line_number)
        rows.append(row)

    cycles = [row["cycle"] for row in rows]
    if not rows:
        raise ValueError("cycle stream must contain at least one cycle")
    if len(cycles) != len(set(cycles)):
        raise ValueError("cycle numbers must be unique")
    if cycles != list(range(1, max(cycles, default=0) + 1)):
        raise ValueError(f"cycles must be contiguous and ordered from 1; got {cycles}")
    production = [row for row in rows if row.get("productionBaseline") is True]
    if rows and len(production) != 1:
        raise ValueError("exactly one cycle must be marked productionBaseline")
    if production and (production[0]["evidenceTier"], production[0]["verdict"]) != ("grade", "pass"):
        raise ValueError("productionBaseline must be a passing grade, never development evidence")
    return rows


def validate_row(row: dict, line_number: int) -> None:
    required = {
        "schemaVersion", "cycle", "cycleLabel", "ts", "candidate", "commit",
        "evidenceTier", "verdict", "rounds", "uniqueClips", "tp", "fn", "fp", "tn",
        "precision", "recall", "f1", "balancedAccuracy", "evidence",
    }
    missing = sorted(required - row.keys())
    if missing:
        raise ValueError(f"line {line_number}: missing {', '.join(missing)}")
    if row["schemaVersion"] != 1 or row["cycleLabel"] != f"C{row['cycle']}":
        raise ValueError(f"line {line_number}: invalid schema version or cycle label")
    if row["evidenceTier"] not in VALID_TIERS or row["verdict"] not in VALID_VERDICTS:
        raise ValueError(f"line {line_number}: invalid evidence tier or verdict")
    if row["evidenceTier"] == "development" and row["verdict"] != "development":
        raise ValueError(f"line {line_number}: development evidence cannot claim a grade verdict")
    if row["evidenceTier"] == "grade" and row["verdict"] == "development":
        raise ValueError(f"line {line_number}: grade evidence requires pass or fail")

    tp, fn, fp, tn = (row[key] for key in ("tp", "fn", "fp", "tn"))
    if any(not isinstance(value, int) or value < 0 for value in (tp, fn, fp, tn)):
        raise ValueError(f"line {line_number}: confusion counts must be non-negative integers")
    expected = {
        "precision": ratio(tp, tp + fp),
        "recall": ratio(tp, tp + fn),
        "f1": ratio(2 * tp, 2 * tp + fp + fn),
        "balancedAccuracy": mean(ratio(tp, tp + fn), ratio(tn, tn + fp)),
    }
    for key, value in expected.items():
        if value is None or not math.isclose(float(row[key]), value, rel_tol=0, abs_tol=1e-9):
            raise ValueError(f"line {line_number}: {key} does not match confusion counts")


def ratio(numerator: int, denominator: int) -> float | None:
    return numerator / denominator if denominator else None


def mean(first: float | None, second: float | None) -> float | None:
    return (first + second) / 2 if first is not None and second is not None else None


def serialize(rows: list[dict]) -> str:
    return "".join(json.dumps(row, separators=(",", ":"), sort_keys=True) + "\n" for row in rows)


def nightly_summary(rows: list[dict]) -> dict:
    """Return safe daily status without promoting the latest dev score."""
    latest = rows[-1]
    production = next(row for row in rows if row.get("productionBaseline") is True)
    return {
        "poi_cycle_stream_status": "ok",
        "poi_cycle_count": len(rows),
        "poi_cycle_latest_label": latest["cycleLabel"],
        "poi_cycle_latest_evidence_tier": latest["evidenceTier"],
        "poi_cycle_latest_verdict": latest["verdict"],
        "poi_cycle_production_label": production["cycleLabel"],
        "poi_cycle_production_commit": production["commit"],
        "poi_cycle_production_balanced_accuracy": production["balancedAccuracy"],
        "poi_cycle_production_precision": production["precision"],
        "poi_cycle_production_recall": production["recall"],
        "poi_cycle_production_f1": production["f1"],
    }


def publish(text: str, output: Path) -> bool:
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists() and output.read_text() == text:
        return False
    descriptor, temporary = tempfile.mkstemp(prefix=f".{output.name}.", dir=output.parent, text=True)
    try:
        with os.fdopen(descriptor, "w") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, output)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    rows = load_and_validate(args.source)
    text = serialize(rows)
    if args.output and not args.check:
        changed = publish(text, args.output)
        print(f"{'updated' if changed else 'unchanged'} {args.output} ({len(rows)} cycles)")
    else:
        print(f"validated {len(rows)} cycles: C1-C{rows[-1]['cycle'] if rows else 0}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
