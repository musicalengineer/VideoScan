#!/usr/bin/env python3
"""Collect a metrics row without confusing missing observations with zero.

The existing total_swift_lines field deliberately remains physical lines (including
comments/blanks) for historical comparability. test_count is source declarations,
not executed tests or parameterized cases. Coverage uses xccov's structured report.
Only Python's standard library is required.
"""

import datetime
import json
import os
from pathlib import Path
import re
import subprocess
import sys

SOURCE_ROOTS = ("VideoScan/VideoScan", "VideoScan/VideoScanTests", "swift_cli")
VIEW_SUFFIX = re.compile(r"(?:View|Window|Sheet|Dashboard|App|Bar|Row|SplitView)\.swift$")


def run(command, cwd):
    try:
        result = subprocess.run(command, cwd=cwd, capture_output=True, text=True, timeout=60)
        return result.stdout.strip() if result.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired):
        return None


def masked_swift(source):
    """Mask comments and string literals, preserving offsets and newlines.

    Handles nested block comments and raw/multiline strings. This is a source
    census, not a compiler: conditional compilation and macro expansion are not
    evaluated, and interpolated string contents are deliberately ignored.
    """
    pieces = []
    index = 0
    length = len(source)
    while index < length:
        start = index
        if source.startswith("//", index):
            end = source.find("\n", index)
            index = length if end < 0 else end
        elif source.startswith("/*", index):
            index += 2
            depth = 1
            while index < length and depth:
                if source.startswith("/*", index):
                    depth += 1
                    index += 2
                elif source.startswith("*/", index):
                    depth -= 1
                    index += 2
                else:
                    index += 1
        else:
            match = re.match(r'(\#*)("""|")', source[index:index + 32])
            if not match:
                pieces.append(source[index])
                index += 1
                continue
            hashes, quote = match.groups()
            index += len(match[0])
            closing = quote + hashes
            escape = "\\" + hashes
            while index < length:
                if source.startswith(escape, index):
                    index += len(escape) + 1
                elif source.startswith(closing, index):
                    index += len(closing)
                    break
                else:
                    index += 1
        pieces.append(re.sub(r"[^\n]", " ", source[start:index]))
    return "".join(pieces)


def declared_tests(source):
    code = masked_swift(source)
    functions = list(re.finditer(r"\bfunc\s+(`[^`]+`|\w+)\s*\(", code))
    counted = {m.start() for m in functions if m[1].strip("`").startswith("test")}
    # Associate each @Test with its following function, skipping its balanced
    # argument list so traits may contain closures, arrays, or nested calls.
    for attribute in re.finditer(r"@(?:Testing\.)?Test\b", code):
        pos = attribute.end()
        while pos < len(code) and code[pos].isspace():
            pos += 1
        if pos < len(code) and code[pos] == "(":
            depth = 1
            pos += 1
            while pos < len(code) and depth:
                depth += (code[pos] == "(") - (code[pos] == ")")
                pos += 1
        function = re.match(r"[^{};]*?\bfunc\s+(`[^`]+`|\w+)\s*\(", code[pos:])
        if function:
            func_token = re.search(r"\bfunc\s+", function[0])
            counted.add(pos + func_token.start())
    return len(counted)


def coverage(report):
    result = dict.fromkeys(("coverage_overall_pct", "coverage_logic_pct", "logic_lines", "logic_covered"))
    if not isinstance(report, dict) or not isinstance(report.get("targets"), list):
        return result
    matches = [t for t in report["targets"] if isinstance(t, dict) and t.get("name") == "VideoScan.app"]
    if len(matches) != 1:
        return result
    target = matches[0]

    def counts(item):
        covered, total = item.get("coveredLines"), item.get("executableLines")
        if type(covered) is int and type(total) is int and 0 <= covered <= total:
            return covered, total
        return None

    overall = counts(target)
    if overall and overall[1]:
        result["coverage_overall_pct"] = round(100 * overall[0] / overall[1], 2)
    files = target.get("files")
    if not isinstance(files, list) or not files:
        return result
    covered = total = 0
    for entry in files:
        if not isinstance(entry, dict):
            return result
        path = entry.get("path") or entry.get("name")
        if not isinstance(path, str):
            return result
        if VIEW_SUFFIX.search(Path(path).name):
            continue
        pair = counts(entry)
        if pair is None:
            return result
        covered += pair[0]
        total += pair[1]
    if total:
        result.update(coverage_logic_pct=round(100 * covered / total, 2), logic_lines=total, logic_covered=covered)
    return result


def diagnostic_count(env, name, pattern):
    # A path can be stale or contain a partial/error log. Callers must explicitly
    # attest that this invocation finished successfully (without swallowing its
    # exit status). Current CI supplies neither logs nor outcomes: report null.
    outcome_name = name.removesuffix("_OUTPUT") + "_OUTCOME"
    path = env.get(name)
    if env.get(outcome_name) != "success" or not path or not Path(path).is_file():
        return None
    return sum(bool(re.search(pattern, line)) for line in
               Path(path).read_text(encoding="utf-8", errors="replace").splitlines())


def collect(root, env):
    sha = env.get("GITHUB_SHA") or run(["git", "rev-parse", "HEAD"], root) or "unknown"
    branch = env.get("GITHUB_REF_NAME") or run(["git", "rev-parse", "--abbrev-ref", "HEAD"], root) or "unknown"
    row = {"ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "sha": sha[:8], "branch": branch}
    report = None
    if (root / "TestResults.xcresult").is_dir():
        raw = run(["xcrun", "xccov", "view", "--report", "--json", "TestResults.xcresult"], root)
        try:
            report = json.loads(raw) if raw else None
        except (ValueError, TypeError):
            pass
        if report is None:
            print("metrics: xccov coverage unavailable; emitting null coverage", file=sys.stderr)
    row.update(coverage(report))
    row.update(swiftlint_warnings=diagnostic_count(env, "SWIFTLINT_OUTPUT", r": warning:"),
               swiftlint_errors=diagnostic_count(env, "SWIFTLINT_OUTPUT", r": error:"),
               periphery_findings=diagnostic_count(env, "PERIPHERY_OUTPUT", r"^/"))
    total = fat = worst_lines = tests = regressions = 0
    worst = "none"
    for source_root in SOURCE_ROOTS:
        directory = root / source_root
        if not directory.is_dir():
            raise ValueError(f"missing source directory: {directory}")
        for file in sorted(directory.rglob("*.swift")):
            if {"build", ".build"}.intersection(file.relative_to(directory).parts):
                continue
            source = file.read_text()
            # Match the historical wc -l definition (newline count).
            lines = source.count("\n")
            total += lines
            fat += lines > 1000
            if lines > worst_lines:
                worst_lines, worst = lines, f"{file.name}:{lines}"
            if source_root == "VideoScan/VideoScanTests":
                tests += declared_tests(source)
                regressions += len(re.findall(r"^\s*// regression:", source, re.MULTILINE))
    # GraphQL totalCount avoids the old 1,000-issue truncation.
    raw = run(["gh", "api", "graphql", "-F", "owner={owner}", "-F", "name={repo}", "-f",
               "query=query($owner:String!,$name:String!){repository(owner:$owner,name:$name){issues(states:OPEN){totalCount}}}"], root)
    issues = None
    try:
        value = json.loads(raw)["data"]["repository"]["issues"]["totalCount"]
        if type(value) is int and value >= 0:
            issues = value
    except (ValueError, TypeError, KeyError):
        pass
    row.update(total_swift_lines=total, files_over_1000=fat, worst_file=worst,
               test_count=tests, regression_count=regressions, open_issues=issues)
    return row


if __name__ == "__main__":
    try:
        print(json.dumps(collect(Path(__file__).resolve().parents[1], os.environ), separators=(",", ":"), allow_nan=False))
    except (OSError, ValueError) as error:
        print(f"metrics: {error}", file=sys.stderr)
        sys.exit(1)
