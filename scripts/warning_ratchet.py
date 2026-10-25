#!/usr/bin/env python3
"""warning_ratchet.py — compiler warnings may go DOWN, never UP (Swift 6 stage 0).

Why: on 2026-10-25 a clean Debug build of main carried 454 distinct compiler
warnings in the repo's own files, 299 of them strict-concurrency findings that
Swift 6 language mode turns into errors (docs/design/swift6_migration_2026_10_25.md).
At that volume a new warning is invisible, so the pile grows. This ratchet is
the floor under the migration: every build is compared, per file AND per
category, with a committed baseline; a (file, category) whose count rose is
RED. The same numbers give Rick his morning progress figure.

  python3 scripts/warning_ratchet.py check  <build log>...          # red if any (file, category) went up
  python3 scripts/warning_ratchet.py update <build log>... --clean  # rewrite the baseline from CLEAN builds
  python3 scripts/warning_ratchet.py progress [--markdown]           # "Swift 6 progress: N% …"
  python3 scripts/warning_ratchet.py categories <build log>...      # the breakdown, for picking a slice

Logs: any mix of `xcodebuild … build|build-for-testing|test` and `swift build
--build-tests` / `swift test` output. A diagnostic is one `path:line:col:
warning: text` line (ANSI stripped, duplicates folded — xcodebuild prints a
compile warning once in the step and again in its summary). Only files inside
this repository count; package checkouts (`.build/`, `DerivedData/`,
`SourcePackages/`) do not, wherever they sit.

Per (file, category), not per build: an incremental build recompiles only
changed files, so its total is meaningless, but a file that emits a warning
WAS compiled, and its counts are exact. Per category, so fixing a deprecation
can never pay for a new concurrency finding in the same file. `check`
therefore works on the sensor lane's incremental build and on a clean nightly
alike.

`update` is the one step that needs clean builds (an incremental log would
record 0 for every untouched file). It does not take that on trust: a file
that had warnings, still exists, and emits none now must appear in the logs'
COMPILE EVIDENCE — xcodebuild's `SwiftCompile … Compiling\\ X.swift …` lines
(absolute paths; they cover the app, its tests and VideoScanCore's sources,
which the app builds as a package), or `Compile X.swift` lines from
`swift build -vv` (bare file names; the only source for VideoScanCore's test
target). Otherwise the update is refused (pass --force for Rick's override).
It also refuses to raise a count.

Baseline: scripts/warnings_baseline.tsv — `count<TAB>category<TAB>path`,
sorted by path then category, with `#` header lines. `# start_total N` is the
denominator of the progress figure and is written once, at the first update;
it never moves. 100 % = app target in Swift 6 language mode and a total of 0.
The baseline is taken from the same configuration the sensor lane builds
(Debug, `build-for-testing`, the lane's flags) so Debug-only warnings are in it.

The sensor lane (scripts/sensor_lane.py) calls `check` on its two logs, so
the ratchet runs before every merge without a separate step.
"""
from __future__ import annotations

import argparse
import datetime as dt
import re
import sys
from collections import Counter
from pathlib import Path
from typing import Dict, Iterable, List, Set, Tuple

REPO = Path(__file__).resolve().parent.parent
BASELINE = REPO / "scripts" / "warnings_baseline.tsv"
CORE_MANIFEST = REPO / "VideoScan" / "VideoScanCore" / "Package.swift"
APP_PBXPROJ = REPO / "VideoScan" / "VideoScan.xcodeproj" / "project.pbxproj"

ANSI_RE = re.compile(r"\x1b\[[0-9;]*m|\x1b\]8;;[^\x1b]*\x1b\\")
# Not anchored at line start: a verbose SwiftPM build interleaves its command
# echo with the compiler's stderr, and a warning can land glued to a truncated
# `cd /Users/…` (seen 2026-10-25). `_ours` recovers the path from the blob.
WARNING_RE = re.compile(r"(/[^:\s]+?\.swift):(\d+):(\d+): warning: (.*)$", re.M)
# Compile evidence: every absolute .swift path on an xcodebuild SwiftCompile
# line, every `-primary-file <path>` of a failed-frontend line, and the bare
# `Compile X.swift` lines of `swift build -vv`.
XCODE_COMPILE_RE = re.compile(r"^SwiftCompile .*Compiling.*$", re.M)
PRIMARY_FILE_RE = re.compile(r"-primary-file ((?:\\ |\S)+?\.swift)(?=\s)")
SWIFTPM_COMPILE_RE = re.compile(r"^\s*(?:Compile|builtin-SwiftPerFileCompile) (\S+\.swift)\s*$", re.M)
ABS_SWIFT_RE = re.compile(r"(/(?:\\ |[^\s])+?\.swift)(?=\s|$)")
NOT_OURS = {".build", "DerivedData", "SourcePackages", "checkouts", ".worktrees"}
KNOWN_META = ("start_total", "recorded")

# How a warning is classified (first match wins). The Swift 6 blockers first.
CATEGORIES: List[Tuple[str, re.Pattern]] = [
    ("global-static", re.compile(r"not concurrency-safe")),
    # "cannot be accessed" (a property) as well as "referenced" (a method/let);
    # "can not" is how older diagnostics spell it.
    ("main-actor", re.compile(r"main actor-isolated .* (can ?not) be (referenced|accessed)|main actor-isolated default value")),
    ("sendable-conformance", re.compile(r"does not conform to the 'Sendable' protocol")),
    # Case-insensitive: "mutated after capture by sendable closure" is lowercase;
    # "region-based isolation" is how the "Please file a bug" diagnostics name it.
    ("sendable-capture", re.compile(r"sendable|sending '|risks causing data races|concurrently-execut|RegionIsolation|region[- ]based isolation", re.I)),
    ("capture-ownership", re.compile(r"ownership of capture")),
    ("deprecated", re.compile(r"deprecated")),
    ("other", re.compile(r".")),
]
SWIFT6_BLOCKERS = {"global-static", "main-actor", "sendable-capture", "sendable-conformance"}

Diag = Tuple[str, int, int, str]       # repo-relative path, line, col, text
Key = Tuple[str, str]                  # (repo-relative path, category)


def category(text: str) -> str:
    for name, rx in CATEGORIES:
        if rx.search(text):
            return name
    return "other"


def _ours(path_text: str):
    """Repo-relative POSIX path, or None for anything outside the repo or in a
    package checkout / build directory inside it."""
    text = path_text.replace("\\ ", " ")
    marker = str(REPO) + "/"
    glued = text.find(marker)
    if glued > 0:                      # junk from another stream glued in front of the path
        text = text[glued:]
    try:
        p = Path(text).resolve()
        rel = p.relative_to(REPO)
    except (ValueError, OSError):
        return None
    if NOT_OURS.intersection(rel.parts):
        return None
    return rel.as_posix()


def _read(paths: Iterable[Path]) -> List[str]:
    return [ANSI_RE.sub("", p.read_text(errors="replace")) for p in paths if p.exists()]


def parse_logs(paths: Iterable[Path]) -> Set[Diag]:
    """Distinct warnings in the repo's own Swift files across all logs."""
    out: Set[Diag] = set()
    for text in _read(paths):
        for m in WARNING_RE.finditer(text):
            rel = _ours(m.group(1))
            if rel:
                out.add((rel, int(m.group(2)), int(m.group(3)), m.group(4).strip()))
    return out


def compiled_files(paths: Iterable[Path]) -> Tuple[Set[str], Set[str]]:
    """(repo-relative paths, bare file names) the logs show were compiled."""
    rels: Set[str] = set()
    names: Set[str] = set()
    for text in _read(paths):
        for line in XCODE_COMPILE_RE.findall(text):
            for p in ABS_SWIFT_RE.findall(line):
                rel = _ours(p)
                if rel:
                    rels.add(rel)
        for p in PRIMARY_FILE_RE.findall(text):
            rel = _ours(p)
            if rel:
                rels.add(rel)
        names.update(SWIFTPM_COMPILE_RE.findall(text))
    return rels, names


def counts_of(diags: Set[Diag]) -> Dict[Key, int]:
    return dict(Counter((d[0], category(d[3])) for d in diags))


def per_file(diags: Set[Diag]) -> Dict[str, int]:
    return dict(Counter(d[0] for d in diags))


def read_baseline(path: Path = BASELINE) -> Tuple[Dict[Key, int], Dict[str, str]]:
    counts: Dict[Key, int] = {}
    meta: Dict[str, str] = {}
    if not path.exists():
        return counts, meta
    for line in path.read_text().splitlines():
        if not line.strip():
            continue
        if line.startswith("#"):
            parts = line[1:].split(None, 1)
            if len(parts) == 2 and parts[0] in KNOWN_META:
                meta[parts[0]] = parts[1].strip()
            continue
        n, cat, rel = line.split("\t", 2)
        counts[(rel, cat)] = int(n)
    return counts, meta


def write_baseline(counts: Dict[Key, int], meta: Dict[str, str], path: Path = BASELINE) -> None:
    lines = [f"# {k} {meta[k]}" for k in KNOWN_META if k in meta]
    lines.append(f"# total {sum(counts.values())}")
    lines.append("# count<TAB>category<TAB>path — scripts/warning_ratchet.py; edit by `update --clean`, never by hand")
    lines += [f"{n}\t{cat}\t{rel}" for (rel, cat), n in sorted(counts.items()) if n > 0]
    path.write_text("\n".join(lines) + "\n")


def check(logs: List[Path], baseline: Path = BASELINE) -> Tuple[List[str], int, int]:
    """(red lines, warnings seen, files seen). Red = a (file, category) above
    its baseline, or no baseline at all (one line, not one per file)."""
    if not baseline.exists():
        return [f"baseline {baseline} is missing — commit one from clean builds: "
                "warning_ratchet.py update <xcodebuild log> <swift build -vv log> --clean"], 0, 0
    diags = parse_logs(logs)
    seen = counts_of(diags)
    base, _ = read_baseline(baseline)
    red: List[str] = []
    for (rel, cat), n in sorted(seen.items()):
        b = base.get((rel, cat), 0)
        if n > b:
            red.append(f"{rel} [{cat}]: {n} warning(s), baseline {b} (+{n - b})")
    return red, len(diags), len(per_file(diags))


def update(logs: List[Path], baseline: Path, force: bool, recorded: str | None) -> Tuple[int, List[str]]:
    """Rewrite the baseline from clean-build logs. Returns (rc, messages)."""
    new = counts_of(parse_logs(logs))
    old, meta = read_baseline(baseline)
    msgs: List[str] = []
    if baseline.exists() and not force:
        rises = [f"{rel} [{cat}]: {old.get((rel, cat), 0)} → {n}" for (rel, cat), n in sorted(new.items())
                 if n > old.get((rel, cat), 0)]
        if rises:
            return 1, ["update REFUSED — these went up (pass --force to accept):"] + [f"  ✘ {r}" for r in rises]
        compiled, compiled_names = compiled_files(logs)
        new_files = {rel for rel, _ in new}
        unproven = sorted({rel for (rel, _), n in old.items()
                           if n > 0 and rel not in new_files and (REPO / rel).exists()
                           and rel not in compiled and Path(rel).name not in compiled_names})
        if unproven:
            return 1, ["update REFUSED — these files had warnings, still exist, emit none now, and the logs do not "
                       "show them compiled (not a clean build, or `swift build` without -vv); pass --force to accept:"] \
                      + [f"  ✘ {rel}" for rel in unproven]
    meta.setdefault("start_total", str(sum(new.values())))
    meta["recorded"] = recorded or dt.date.today().isoformat()
    write_baseline(new, meta, baseline)
    msgs.append(f"baseline written: {sum(new.values())} warning(s) in {len({r for r, _ in new})} file(s) (was {sum(old.values())})")
    msgs.append(progress(baseline))
    return 0, msgs


def language_modes() -> Tuple[str, str]:
    core = "Swift 6" if re.search(r"swiftLanguageModes:\s*\[\s*\.v6\s*\]", CORE_MANIFEST.read_text()) else "Swift 5"
    versions = set(re.findall(r"SWIFT_VERSION = ([\d.]+);", APP_PBXPROJ.read_text()))
    app = "Swift 6" if versions and all(v.startswith("6") for v in versions) else "Swift 5"
    return core, app


def progress(baseline: Path = BASELINE, markdown: bool = False) -> str:
    counts, meta = read_baseline(baseline)
    total = sum(counts.values())
    start = int(meta.get("start_total", total) or 0)
    core, app = language_modes()
    cleared = max(start - total, 0)
    pct = 100 if (total == 0 and app == "Swift 6") else (int(cleared * 100 / start) if start else 0)
    if pct == 100 and app != "Swift 6":
        pct = 99
    line = (f"Swift 6 progress: {pct}% — {total} of {start} warnings remain "
            f"(baseline {meta.get('recorded', '?')}) · Core: {core} · App: {app}"
            + ("" if app == "Swift 6" else " (flips at 0)"))
    if not markdown:
        return line
    by_cat = Counter()
    by_file = Counter()
    for (rel, cat), n in counts.items():
        by_cat[cat] += n
        by_file[rel] += n
    blockers = sum(n for c, n in by_cat.items() if c in SWIFT6_BLOCKERS)
    body = [f"## {line}", "",
            "Measured by `scripts/warning_ratchet.py progress` from `scripts/warnings_baseline.tsv`;",
            "the baseline is rewritten only from clean builds (`update --clean`).", "",
            f"- Swift 6 blockers remaining: {blockers}",
            "- By category: " + ", ".join(f"{c} {n}" for c, n in by_cat.most_common()),
            f"- Files with warnings: {len(by_file)}",
            "- Heaviest files: " + ", ".join(f"`{p}` ({n})" for p, n in by_file.most_common(8)),
            "- Plan and stages: `docs/design/swift6_migration_2026_10_25.md`"]
    return "\n".join(body)


def categorize(logs: List[Path]) -> str:
    diags = parse_logs(logs)
    by = Counter(category(text) for _, _, _, text in diags)
    blockers = sum(n for c, n in by.items() if c in SWIFT6_BLOCKERS)
    lines = [f"{len(diags)} distinct warnings in {len(per_file(diags))} file(s), {blockers} become errors in Swift 6 mode:"]
    lines += [f"  {n:4d}  {c}" for c, n in by.most_common()]
    return "\n".join(lines)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--baseline", type=Path, default=BASELINE)
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("check"); c.add_argument("logs", nargs="+", type=Path)
    u = sub.add_parser("update"); u.add_argument("logs", nargs="+", type=Path)
    u.add_argument("--clean", action="store_true", help="assert the logs are from CLEAN builds (required)")
    u.add_argument("--force", action="store_true", help="accept a rise or an unproven fall (Rick's call)")
    u.add_argument("--recorded", default=None, help="label for the baseline, default: today")
    p = sub.add_parser("progress"); p.add_argument("--markdown", action="store_true")
    k = sub.add_parser("categories"); k.add_argument("logs", nargs="+", type=Path)
    a = ap.parse_args(argv)

    if a.cmd == "check":
        red, n, files = check(a.logs, a.baseline)
        print(f"warning ratchet: {n} warning(s) in {files} compiled file(s) with warnings; baseline {a.baseline.name}")
        if red:
            print("WARNING RATCHET RED — more warnings than the baseline allows:", file=sys.stderr)
            for r in red:
                print(f"  ✘ {r}", file=sys.stderr)
            return 1
        print("warning ratchet GREEN (nothing above its baseline)")
        return 0

    if a.cmd == "update":
        if not a.clean:
            print("update needs --clean: the logs must come from CLEAN builds (an incremental log reads as 0 for every untouched file)", file=sys.stderr)
            return 2
        rc, msgs = update(a.logs, a.baseline, a.force, a.recorded)
        for m in msgs:
            print(m, file=sys.stderr if rc else sys.stdout)
        return rc

    if a.cmd == "progress":
        print(progress(a.baseline, markdown=a.markdown))
        return 0

    if a.cmd == "categories":
        print(categorize(a.logs))
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
