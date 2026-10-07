#!/usr/bin/env python3
"""Resolve merge conflicts in scripts/gauntlet/manifest.json that are ONLY in
`expected_floor` lines, by recomputing every stage's floor from its assignments.

Two branches that each add tests both raise a stage's floor, so a merge conflicts
on that one number. Picking either side is wrong (the merged tree has both sets of
tests); the right floor is recomputed from the merged assignments, exactly as
`inventory.swift --validate` checks it (the declarations of runnable xcode
assignments in that stage).

Refuses (exit 1, file untouched) if any conflict hunk contains anything other than
`expected_floor` lines. Usage:  python3 scripts/gauntlet/resolve_floor_conflicts.py [manifest]
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

HUNK = re.compile(r"<<<<<<< [^\n]*\n(.*?)=======\n(.*?)>>>>>>> [^\n]*\n", re.S)
FLOOR_LINE = re.compile(r'^\s*"expected_floor": \d+,?\n$')


def floor_only(side: str) -> bool:
    lines = side.splitlines(keepends=True)
    return bool(lines) and all(FLOOR_LINE.match(l) for l in lines)


def resolve(text: str) -> str:
    hunks = HUNK.findall(text)
    if not hunks:
        raise ValueError("no conflict hunks found")
    for ours, theirs in hunks:
        if not (floor_only(ours) and floor_only(theirs)):
            raise ValueError("a conflict hunk contains more than expected_floor lines; resolve by hand")
    # Keep "ours" text as a placeholder; the numbers are recomputed below.
    text = HUNK.sub(lambda m: m.group(1), text)
    indent = len(re.match(r"\{\n( +)", text).group(1))
    manifest = json.loads(text)
    for stage in manifest["stages"]:
        runnable = [a for a in manifest["assignments"]
                    if a.get("stage") == stage["name"] and not a.get("blocked_reason") and a.get("kind") == "xcode"]
        stage["expected_floor"] = max(1, sum(len(a.get("tests", [])) for a in runnable))
    return json.dumps(manifest, indent=indent, ensure_ascii=False) + "\n"


def main(argv: list[str]) -> int:
    path = Path(argv[1]) if len(argv) > 1 else Path(__file__).with_name("manifest.json")
    try:
        path.write_text(resolve(path.read_text()))
    except ValueError as e:
        print(f"resolve_floor_conflicts: {e}", file=sys.stderr)
        return 1
    print(f"resolve_floor_conflicts: floors recomputed in {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
