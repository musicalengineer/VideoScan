#!/usr/bin/env python3
"""Count completed lint scans; tool failures and skipped scans are unknown."""
from __future__ import annotations

import os
import re
from pathlib import Path

DIAGNOSTIC = re.compile(r"^.+:\d+:\d+: (?:warning|error):", re.MULTILINE)
SWIFTLINT_COMPLETION = re.compile(
    r"^Done linting! Found (\d+) violations?, (\d+) serious in (\d+) files?\.$",
    re.MULTILINE,
)


def finding_count(path: Path, outcome: str, *, swiftlint: bool = False,
                  exit_code: str = "") -> int | None:
    if outcome not in ("success", "failure") or not path.is_file():
        return None
    content = path.read_text(encoding="utf-8", errors="replace").rstrip()
    count = len(DIAGNOSTIC.findall(content))
    if not swiftlint:
        return count if outcome == "success" else None
    # SwiftLint prints completion before saving its cache, which can still fail.
    # A completed strict scan exits 2 for findings, 0 for a clean result:
    # realm/SwiftLint a510662, Source/SwiftLintFramework/LintOrAnalyzeCommand.swift.
    # The workflow truncates the log and captures this invocation's exit status.
    if (outcome, exit_code) not in (("success", "0"), ("failure", "2")):
        return None
    completions = list(SWIFTLINT_COMPLETION.finditer(content))
    if len(completions) != 1 or completions[0].end() != len(content):
        return None
    total, serious, _ = map(int, completions[0].groups())
    if total != count or not 0 <= serious <= total:
        return None
    if (exit_code == "2") != (serious > 0):
        return None
    return count


def main() -> int:
    tools = (
        ("swiftlint", "SwiftLint --strict", Path("swiftlint-strict.txt"), "SWIFTLINT_OUTCOME"),
        ("periphery", "Periphery aggressive", Path("periphery-strict.txt"), "PERIPHERY_OUTCOME"),
    )
    summary = ["## Nightly lint analysis", "", "| Tool | Findings |", "|---|---:|"]
    failed = False
    for key, label, path, variable in tools:
        count = finding_count(path, os.environ.get(variable, ""),
                              swiftlint=key == "swiftlint",
                              exit_code=os.environ.get("SWIFTLINT_EXIT_CODE", ""))
        failed |= count is None
        value = "null" if count is None else str(count)
        if output := os.environ.get("GITHUB_OUTPUT"):
            with open(output, "a", encoding="utf-8") as handle:
                handle.write(f"{key}={value}\n")
        summary.append(f"| {label} | {'unavailable (scan failed or skipped)' if count is None else count} |")
        if path.is_file() and (count is None or count > 0):
            summary.extend(["", f"<details><summary>{label} log (first 100 lines)</summary>", "", "```"])
            with path.open(encoding="utf-8", errors="replace") as handle:
                for index, line in enumerate(handle):
                    if index == 100:
                        break
                    summary.append(line.rstrip())
            summary.extend(["```", "", "</details>"])
    report = "\n".join(summary) + "\n"
    print(report)
    if destination := os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(destination, "a", encoding="utf-8") as handle:
            handle.write(report)
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
