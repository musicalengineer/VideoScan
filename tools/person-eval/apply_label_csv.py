#!/usr/bin/env python3
"""Apply a human-edited CSV review sheet back to its JSON label queue."""

from __future__ import annotations

import argparse
import csv
import json
import pathlib
from typing import Any


def _boolean(value: str, field: str, row: str) -> bool | None:
    normalized = value.strip().casefold()
    if not normalized:
        return None
    if normalized in {"yes", "y", "true", "1"}:
        return True
    if normalized in {"no", "n", "false", "0"}:
        return False
    raise ValueError(f"row {row}: {field} must be yes, no, or blank")


def apply_rows(queue: dict[str, Any], rows: list[dict[str, str]]) -> int:
    candidates = {item["id"]: item for item in queue.get("candidates", [])}
    seen: set[str] = set()
    updated = 0
    for row in rows:
        identifier = row.get("id", "").strip()
        if not identifier:
            raise ValueError("CSV row is missing id")
        if identifier in seen:
            raise ValueError(f"duplicate CSV id: {identifier}")
        seen.add(identifier)
        if identifier not in candidates:
            raise ValueError(f"CSV id is not in queue: {identifier}")
        target = _boolean(row.get("targetPerson", ""), "targetPerson", identifier)
        face = _boolean(row.get("anyFace", ""), "anyFace", identifier)
        selected_set = row.get("set", "").strip().casefold() or None
        if selected_set not in {None, "development", "holdout"}:
            raise ValueError(f"row {identifier}: set must be development, holdout, or blank")
        reviewer = row.get("reviewedBy", "").strip() or None
        if (target is not None or face is not None or selected_set is not None) and not reviewer:
            raise ValueError(f"row {identifier}: reviewedBy is required for labeled rows")
        if target is True and face is False:
            raise ValueError(f"row {identifier}: targetPerson=yes requires anyFace=yes")

        review = candidates[identifier]["review"]
        before = dict(review)
        review.update({
            "targetPerson": target, "anyFace": face, "set": selected_set,
            "reviewedBy": reviewer, "notes": row.get("notes", "").strip() or None,
            "status": "human-reviewed" if target is not None and face is not None
                      else "needs-review",
        })
        if review != before:
            updated += 1
    return updated


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--queue", type=pathlib.Path, required=True)
    parser.add_argument("--csv", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    queue = json.loads(args.queue.read_text())
    with args.csv.open(newline="") as handle:
        rows = list(csv.DictReader(handle))
    try:
        updated = apply_rows(queue, rows)
    except ValueError as exc:
        parser.error(str(exc))
    args.output.write_text(json.dumps(queue, indent=2, sort_keys=True) + "\n")
    print(f"Applied {updated} reviewed row(s) -> {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
