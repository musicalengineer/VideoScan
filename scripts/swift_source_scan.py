#!/usr/bin/env python3
"""Shared Swift-source scanning helpers for the nightly ratchet checkers.

Deliberately *not* a Swift parser. These checkers pin a small number of very
specific source shapes, and a regex/brace-depth pass over the text is both
sufficient and dependency-free (the nightly runner has stock python3 only).

Three things live here because both ratchets need them:

  * `iter_swift_files`      — walk the repo, skip build output
  * `classify_source_role`  — production vs test vs tool
  * `split_functions`       — cut a file into `func`-shaped regions so a
                              "check here, write there" rule can require both
                              halves inside ONE function

Memory: everything is per-file. The largest Swift file in the tree is well
under 1 MB, so the worst-case footprint is one file's text plus its line list
(~2 MB transient). Nothing accumulates across files except findings.
"""

from __future__ import annotations

import os
import re
from dataclasses import dataclass, field
from typing import Iterator, List, Optional

# Directories whose contents are never interesting to these checkers.
SKIP_DIR_NAMES = {
    ".git", ".build", "DerivedData", "build", ".swiftpm", "Pods",
    "Carthage", "node_modules", ".claude", "venv", ".venv",
    "ModuleCache.noindex", "Index.noindex", ".trash",
}

# Path fragments that mark a file as test/fixture code. Tests legitimately
# spawn `/bin/sh -c` to synthesise failure modes, so the injection ratchet
# must not fire on them.
TEST_PATH_MARKERS = (
    "/VideoScanTests/",
    "/VideoScanUITests/",
    "/VideoScanCoreTests/",
    "/Tests/",
    "/tests/",
    "/TestDriver/",
    "/fixtures/",
)

# Production source roots — what the ratchets actually police.
PRODUCTION_PATH_MARKERS = (
    "VideoScan/VideoScan/",
    "VideoScan/VideoScanCore/Sources/",
    "swift_cli/",
    "tools/",
)

ROLE_PRODUCTION = "production"
ROLE_TEST = "test"
ROLE_OTHER = "other"


def classify_source_role(rel_path: str) -> str:
    """Return ROLE_TEST / ROLE_PRODUCTION / ROLE_OTHER for a repo-relative path."""
    normalised = "/" + rel_path.replace(os.sep, "/").lstrip("/")
    for marker in TEST_PATH_MARKERS:
        if marker in normalised:
            return ROLE_TEST
    stripped = normalised.lstrip("/")
    for marker in PRODUCTION_PATH_MARKERS:
        if stripped.startswith(marker):
            return ROLE_PRODUCTION
    return ROLE_OTHER


def iter_swift_files(root: str) -> Iterator[str]:
    """Yield repo-relative paths of every .swift file under `root`, sorted."""
    collected: List[str] = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIR_NAMES)
        for name in sorted(filenames):
            if name.endswith(".swift"):
                full = os.path.join(dirpath, name)
                collected.append(os.path.relpath(full, root).replace(os.sep, "/"))
    collected.sort()
    return iter(collected)


# --------------------------------------------------------------------------
# Comment / string stripping
#
# Swift's `//`, `/* */` (nestable) and string literals all have to go before a
# regex hunts for code shapes, otherwise a comment that says "never use
# /bin/sh -c" becomes a finding. We keep the line COUNT identical so reported
# line numbers still point at the real source line.
# --------------------------------------------------------------------------

def strip_comments(text: str) -> str:
    """Blank out // and /* */ comments, preserving line structure."""
    out: List[str] = []
    i = 0
    n = len(text)
    block_depth = 0
    in_string = False
    in_multiline_string = False
    while i < n:
        ch = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if block_depth > 0:
            if ch == "/" and nxt == "*":
                block_depth += 1
                out.append("  ")
                i += 2
                continue
            if ch == "*" and nxt == "/":
                block_depth -= 1
                out.append("  ")
                i += 2
                continue
            out.append("\n" if ch == "\n" else " ")
            i += 1
            continue
        if in_multiline_string:
            out.append(ch)
            if text.startswith('"""', i):
                in_multiline_string = False
                out.append(text[i + 1:i + 3])
                i += 3
                continue
            i += 1
            continue
        if in_string:
            out.append(ch)
            if ch == "\\" and nxt:
                out.append(nxt)
                i += 2
                continue
            if ch == '"':
                in_string = False
            i += 1
            continue
        # not in a comment or string
        if text.startswith('"""', i):
            in_multiline_string = True
            out.append('"""')
            i += 3
            continue
        if ch == '"':
            in_string = True
            out.append(ch)
            i += 1
            continue
        if ch == "/" and nxt == "/":
            while i < n and text[i] != "\n":
                out.append(" ")
                i += 1
            continue
        if ch == "/" and nxt == "*":
            block_depth = 1
            out.append("  ")
            i += 2
            continue
        out.append(ch)
        i += 1
    return "".join(out)


@dataclass
class FunctionRegion:
    """One `func`/`init`/closure-bearing declaration, by line range (1-based)."""
    name: str
    start_line: int
    end_line: int
    lines: List[str] = field(default_factory=list)

    def contains(self, line_no: int) -> bool:
        return self.start_line <= line_no <= self.end_line


_FUNC_DECL = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*"
    r"(?:public\s+|private\s+|fileprivate\s+|internal\s+|open\s+|static\s+|class\s+|final\s+|override\s+|mutating\s+|nonisolated\s+|nonmutating\s+)*"
    r"(?:func\s+(?P<fname>[A-Za-z_][A-Za-z0-9_]*)|(?P<init>init)\s*[?!]?\s*\()"
)


def split_functions(text: str) -> List[FunctionRegion]:
    """Cut a Swift file into function-shaped regions by brace depth.

    `text` should already have comments stripped. Nested functions are folded
    into their parent — good enough, and intentionally *inclusive*: a rule that
    requires "same function" stays conservative if the region is a little wide.
    """
    lines = text.split("\n")
    regions: List[FunctionRegion] = []
    i = 0
    total = len(lines)
    while i < total:
        match = _FUNC_DECL.match(lines[i])
        if not match:
            i += 1
            continue
        name = match.group("fname") or "init"
        # Find the opening brace (it may be on a later line for a multi-line
        # signature). Bail out if we never find one within a sane window.
        depth = 0
        opened = False
        start = i
        j = i
        while j < total:
            for ch in lines[j]:
                if ch == "{":
                    depth += 1
                    opened = True
                elif ch == "}":
                    depth -= 1
            if opened and depth <= 0:
                break
            if not opened and j - i > 40:
                break
            j += 1
        if not opened:
            i += 1
            continue
        end = min(j, total - 1)
        regions.append(
            FunctionRegion(
                name=name,
                start_line=start + 1,
                end_line=end + 1,
                lines=lines[start:end + 1],
            )
        )
        i = end + 1
    return regions


def function_for_line(regions: List[FunctionRegion], line_no: int) -> Optional[FunctionRegion]:
    for region in regions:
        if region.contains(line_no):
            return region
    return None
