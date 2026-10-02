#!/usr/bin/env python3
"""Read docs/practices/invariants/*.md (2026-10-01).

Shared by tools/adversarial_nightly.py (scope + brief) and the pytest sensor
tests/test_invariants_coverage.py, so "which invariants file covers this
path" has exactly one answer.

Stdlib only. The front matter is a deliberately tiny YAML subset:

    ---
    tier: data-risk
    paths:
      - VideoScan/VideoScan/Archive/**
      - VideoScan/VideoScanCore/Sources/VideoScanCore/ArchiveFixity.swift
    ---

Globs are repo-relative: `*` and `?` stay inside one path component, `**`
crosses components (`a/**` matches everything under a/, `a/**/b.swift` matches
a/b.swift and a/x/y/b.swift).
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from functools import lru_cache
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
INVARIANTS_DIR = REPO / "docs" / "practices" / "invariants"
TIERS = ("data-risk", "truth")
INVARIANT_RE = re.compile(r"^\s*\d+\.\s+\*\*(?P<id>[A-Z]+-\d+)\*\*\s*(?P<text>.+)$")


@dataclass
class InvariantsFile:
    name: str                 # "Archive" (file stem)
    path: Path
    tier: str
    paths: list[str]
    invariants: list[tuple[str, str]] = field(default_factory=list)   # (ID, text)
    known_accepted: list[str] = field(default_factory=list)

    def covers(self, rel_path: str) -> bool:
        return any(glob_match(pattern, rel_path) for pattern in self.paths)


@lru_cache(maxsize=512)
def _glob_regex(pattern: str) -> re.Pattern:
    out, i = [], 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out.append("(?:.*/)?")
            i += 3
        elif pattern.startswith("**", i):
            out.append(".*")
            i += 2
        elif pattern[i] == "*":
            out.append("[^/]*")
            i += 1
        elif pattern[i] == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(pattern[i]))
            i += 1
    return re.compile("^" + "".join(out) + "$")


def glob_match(pattern: str, rel_path: str) -> bool:
    return bool(_glob_regex(pattern.strip()).match(rel_path))


def parse_front_matter(text: str) -> tuple[dict, str]:
    """Return ({'tier': str, 'paths': [..]}, body). Raises ValueError on a
    malformed header — a typo must fail loudly, not silently cover nothing."""
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        raise ValueError("missing front matter (first line must be ---)")
    meta: dict = {}
    key = None
    for index in range(1, len(lines)):
        line = lines[index]
        if line.strip() == "---":
            return meta, "\n".join(lines[index + 1:])
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        item = re.match(r"^\s+-\s+(.+?)\s*$", line)
        if item:
            if key is None or not isinstance(meta.get(key), list):
                raise ValueError(f"list item outside a list key: {line!r}")
            meta[key].append(item.group(1).strip("'\""))
            continue
        pair = re.match(r"^([A-Za-z_][\w-]*):\s*(.*?)\s*$", line)
        if not pair:
            raise ValueError(f"unreadable front matter line: {line!r}")
        key, value = pair.group(1), pair.group(2)
        if value.startswith("[") and value.endswith("]"):
            meta[key] = [v.strip().strip("'\"") for v in value[1:-1].split(",") if v.strip()]
        elif value == "":
            meta[key] = []
        else:
            meta[key] = value.strip("'\"")
    raise ValueError("front matter is not closed with ---")


def parse_file(path: Path) -> InvariantsFile:
    meta, body = parse_front_matter(path.read_text(encoding="utf-8"))
    tier = meta.get("tier")
    if tier not in TIERS:
        raise ValueError(f"{path.name}: tier must be one of {TIERS}, got {tier!r}")
    paths = meta.get("paths")
    if not isinstance(paths, list) or not paths:
        raise ValueError(f"{path.name}: paths must be a non-empty list")
    result = InvariantsFile(name=path.stem, path=path, tier=tier, paths=paths)
    section = None
    for line in body.splitlines():
        heading = re.match(r"^##\s+(.*)$", line)
        if heading:
            title = heading.group(1).lower()
            section = "known" if title.startswith("known and accepted") else (
                "inv" if title.startswith("invariants") else None)
            continue
        if section == "inv":
            match = INVARIANT_RE.match(line)
            if match:
                result.invariants.append((match.group("id"), match.group("text").strip()))
        elif section == "known" and line.lstrip().startswith("- "):
            result.known_accepted.append(line.lstrip()[2:].strip())
    return result


def load_all(directory: Path | None = None) -> list[InvariantsFile]:
    directory = directory or INVARIANTS_DIR
    files = []
    for path in sorted(directory.glob("*.md")):
        if path.name.lower() == "readme.md":
            continue
        files.append(parse_file(path))
    return files


def covering(rel_path: str, files: list[InvariantsFile]) -> list[InvariantsFile]:
    return [f for f in files if f.covers(rel_path)]


def bucket_for(rel_path: str, files: list[InvariantsFile]) -> str | None:
    """'data-risk' beats 'truth'; None = out of scope."""
    tiers = {f.tier for f in covering(rel_path, files)}
    if "data-risk" in tiers:
        return "data-risk"
    if "truth" in tiers:
        return "truth"
    return None
