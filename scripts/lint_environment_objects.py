#!/usr/bin/env python3
"""
Detect SwiftUI views that declare @EnvironmentObject vars they never
actually READ as `.property` in the file body.

Bug shape this catches (PersonFinderView dashboard cascade, 2026-06-02):

    struct SomeView: View {
        @EnvironmentObject var dashboard: DashboardState   # ← subscribed
        @EnvironmentObject var model: SomeModel

        var body: some View {
            VStack {
                Text(model.title)                           # model.* — fine
            }
            .onAppear {
                model.dashboard = dashboard                 # only USE of dashboard
            }
        }
    }

The view subscribes to every @Published change on DashboardState (51
properties in VideoScan's case), retriggering body re-eval on each one,
even though body never READS dashboard.anything. The subscription is
pure overhead. Fix: don't @EnvironmentObject. Instead access the
reference indirectly (here: via `model.dashboard` set by the parent
that owns both refs), or use a custom EnvironmentKey via @Environment.

Heuristic the linter uses:

  For each @EnvironmentObject var X: T declaration in a file, check
  whether the regex `\\bX\\.` appears anywhere AFTER the declaration.
  If yes, the var is being read as a property → OK. If no, the var is
  either unused OR only being forwarded as a reference (the bug
  pattern) → flag it.

Annotation to opt out for genuine reference-forwarding cases:

    // swiftlint:disable-next-line vs-env-object-unused
    @EnvironmentObject var foo: Bar

Exit code: 0 if no findings, 1 if findings (so pre-commit / CI fail).

Run modes:

  Lint all included VideoScan sources:
    scripts/lint_environment_objects.py

  Lint specific files (used by pre-commit hook to limit to staged):
    scripts/lint_environment_objects.py path/a.swift path/b.swift

  Self-test (verifies the linter catches a known-bad synthetic case):
    scripts/lint_environment_objects.py --selftest
"""

from __future__ import annotations
import re
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Default paths to lint when no args are passed. Mirrors .swiftlint.yml's
# `included:` so the linter has the same scope as the rest of the rules.
DEFAULT_ROOTS = [
    "VideoScan/VideoScan",
    "swift_cli",
]

# Skip test files — @EnvironmentObject in test fixtures is fine.
EXCLUDE_PATTERNS = [
    "Tests/",
    "/build/",
    "/DerivedData/",
    "/.build/",
]

# Pattern that matches @EnvironmentObject declarations. Captures:
#   1. var name
#   2. type
# Handles both `@EnvironmentObject var X: T` and `@EnvironmentObject
# private var X: T` and `@EnvironmentObject internal var X: T`.
# Note: type pattern uses [^\n] not \s, so we don't accidentally span across
# the end of the declaration into the next code on a separate line.
ENV_OBJ_RE = re.compile(
    r"@EnvironmentObject\s+(?:private\s+|fileprivate\s+|internal\s+|public\s+)?var\s+(\w+)\s*:\s*([\w<>\?]+)",
    re.MULTILINE,
)

# Per-declaration opt-out annotation. Place on the line BEFORE the
# @EnvironmentObject declaration. Uses a `vs-lint:` prefix instead of
# SwiftLint's `swiftlint:disable-next-line` syntax so SwiftLint doesn't
# generate "Invalid SwiftLint Command" warnings for our custom rule
# (the rule lives in this Python script, not in .swiftlint.yml).
OPT_OUT_LINE = "// vs-lint:disable-next vs-env-object-unused"


# ---------------------------------------------------------------------------
# Linter core
# ---------------------------------------------------------------------------


def _strip_comments(swift: str) -> str:
    """
    Replace line/block comments with whitespace so byte offsets are
    preserved (line numbers stay correct after stripping).

    Does NOT strip string literals — Swift's `\\(...)` interpolation
    syntax means strings often contain real code (e.g.
    `"FPS: \\(dashboard.visionFPS)"`), and treating those as comments
    would create false negatives for property reads.
    """
    # Block comments first, then line comments. Replace with newlines for
    # block comments to preserve line counts.
    def block_sub(m: re.Match[str]) -> str:
        return "\n" * m.group(0).count("\n")
    swift = re.sub(r"/\*[\s\S]*?\*/", block_sub, swift)
    # Line comments: replace from `//` to end of line with empty (don't
    # remove the newline itself — it terminates the line).
    swift = re.sub(r"//[^\n]*", "", swift)
    return swift


def lint_file(path: Path) -> list[tuple[int, str, str]]:
    """
    Scan one Swift file. Returns a list of (line_number, var_name, type_name)
    tuples for each @EnvironmentObject var that is declared but never read
    as `<var>.` in the file body.
    """
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        return []

    # Strip comments BEFORE looking for @EnvironmentObject declarations so
    # a doc comment showing the antipattern (the PersonFinderView fix note)
    # doesn't get matched as if it were a real declaration. Line numbers
    # are preserved by replacing comment bodies with empty-or-newline.
    stripped = _strip_comments(text)
    lines = text.split("\n")  # keep original for opt-out annotation lookup
    findings: list[tuple[int, str, str]] = []

    for m in ENV_OBJ_RE.finditer(stripped):
        var_name = m.group(1)
        type_name = m.group(2).strip()
        line_no = stripped.count("\n", 0, m.start()) + 1

        # Opt-out: line immediately preceding the declaration carries the
        # disable annotation. Use the original `lines` here so users can
        # write the annotation as an actual comment.
        if line_no >= 2 and OPT_OUT_LINE in lines[line_no - 2]:
            continue

        # Look for `X.` anywhere AFTER the declaration. String literals
        # are NOT stripped because Swift's `\(expr)` interpolation syntax
        # embeds real code inside strings (would be a false-negative).
        after = stripped[m.end() :]
        usage_pat = re.compile(rf"\b{re.escape(var_name)}\.")
        if not usage_pat.search(after):
            findings.append((line_no, var_name, type_name))

    return findings


def is_excluded(path: Path) -> bool:
    s = str(path)
    return any(p in s for p in EXCLUDE_PATTERNS)


def collect_files(args: list[str]) -> list[Path]:
    if not args:
        files: list[Path] = []
        for root in DEFAULT_ROOTS:
            for p in Path(root).rglob("*.swift"):
                if not is_excluded(p):
                    files.append(p)
        return files
    return [Path(a) for a in args if a.endswith(".swift") and not is_excluded(Path(a))]


# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------


SELFTEST_BAD = """import SwiftUI

struct BadView: View {
    @EnvironmentObject var dashboard: DashboardState
    @EnvironmentObject var model: SomeModel

    var body: some View {
        Text(model.title)
            .onAppear {
                model.dashboard = dashboard
            }
    }
}
"""

SELFTEST_GOOD = """import SwiftUI

struct GoodView: View {
    @EnvironmentObject var dashboard: DashboardState

    var body: some View {
        VStack {
            Text("FPS: \\(dashboard.visionFPS)")
            Text("Workers: \\(dashboard.visionWorkers)")
        }
    }
}
"""

SELFTEST_OPTOUT = """import SwiftUI

struct OptOutView: View {
    // vs-lint:disable-next vs-env-object-unused
    @EnvironmentObject var dashboard: DashboardState

    var body: some View {
        Text("hi")
            .environmentObject(dashboard)
    }
}
"""


def run_selftest() -> int:
    """Verify the linter catches the BAD case, ignores the GOOD case,
    and respects the opt-out annotation."""
    import tempfile

    failures = 0
    with tempfile.TemporaryDirectory() as tmpd:
        bad = Path(tmpd) / "Bad.swift"
        good = Path(tmpd) / "Good.swift"
        optout = Path(tmpd) / "OptOut.swift"
        bad.write_text(SELFTEST_BAD)
        good.write_text(SELFTEST_GOOD)
        optout.write_text(SELFTEST_OPTOUT)

        bad_findings = lint_file(bad)
        good_findings = lint_file(good)
        optout_findings = lint_file(optout)

        # BAD: should flag `dashboard` (no dashboard.* read). `model` IS
        # read as `model.title` and `model.dashboard = ...`, so it
        # should NOT be flagged.
        bad_vars = {f[1] for f in bad_findings}
        if bad_vars != {"dashboard"}:
            print(f"SELFTEST FAIL: BAD case — expected only 'dashboard' flagged, got {bad_vars}")
            failures += 1
        else:
            print("SELFTEST PASS: BAD case correctly flags dashboard (forwarded but not read)")

        if good_findings:
            print(f"SELFTEST FAIL: GOOD case — expected no findings, got {good_findings}")
            failures += 1
        else:
            print("SELFTEST PASS: GOOD case (dashboard.visionFPS reads) generates no findings")

        if optout_findings:
            print(f"SELFTEST FAIL: OPTOUT case — annotation ignored, got {optout_findings}")
            failures += 1
        else:
            print("SELFTEST PASS: OPTOUT case respects the disable annotation")

    return 0 if failures == 0 else 1


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main(argv: list[str]) -> int:
    if "--selftest" in argv:
        return run_selftest()

    files = collect_files([a for a in argv if not a.startswith("--")])
    if not files:
        return 0

    total_findings = 0
    for path in files:
        findings = lint_file(path)
        for line_no, var_name, type_name in findings:
            print(
                f"{path}:{line_no}: warning: @EnvironmentObject var "
                f"{var_name}: {type_name} is declared but never read as "
                f"`{var_name}.<property>` in this file. The subscription "
                f"retriggers the view's body on every @Published change "
                f"to the {type_name} for no purpose. Drop the declaration, "
                f"or annotate the line above with `{OPT_OUT_LINE}` if "
                f"forwarding is intentional. (vs-env-object-unused)"
            )
            total_findings += 1

    if total_findings:
        print(
            f"\n{total_findings} @EnvironmentObject usage warning(s) found. "
            f"See project_bug_prevention_strategy memory."
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
