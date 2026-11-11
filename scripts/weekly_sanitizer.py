#!/usr/bin/env python3
"""Sanitizer run of the unit battery (Rick 2026-10-04: "automated tools
overnight so someone wouldn't break something and if they did we'd know first
thing in the morning").

Two launchd jobs (scripts/install_sanitizer_weekly.sh) call this:
  --sanitizer address   Saturday 07:00  (Address Sanitizer: use-after-free,
                                         overruns, double free — the class
                                         behind the 10/4 SIGSEGVs, GH #273 —
                                         plus the Undefined Behavior Sanitizer,
                                         which shares its build)
  --sanitizer thread    Sunday   05:00  (Thread Sanitizer: data races; cannot
                                         share a build with ASan)

The Swift 6 nightly analysis lane (scripts/nightly_analysis_lane.sh, stage 2
of docs/archive/design/swift6_migration_2026_10_25.md §7) calls the same runner with
`--configuration Release --target all` (Release where the nightly is Release;
Core + app) and reads the row it writes; `--subset catalog` is the time-boxed
subset (all of VideoScanCore — the catalog store lives there — plus the app
suites whose file names say Catalog / MediaFileOperations / Archive / Promote /
Trash / Prune / Relocate / Commit / Store, taken from the gauntlet manifest).

What it does, in order:
  1. Waits (up to --wait-minutes) while another xcodebuild is running or memory
     is tight — the RAM budget is one broad test run at a time on the M4.
     Gives up with status "skipped-busy" rather than piling on. --no-wait skips
     the wait (the analysis lane has already waited for the test nightly).
  2. For each target (app: `xcodebuild test`, Core: `swift test --sanitize`),
     builds and tests with the sanitizer on, in its own derived-data / scratch
     folder (~/Library/Caches/VideoScan/sanitizer-dd/<kind>[-<cfg>]; never the
     XcodeRAM disk), UI tests skipped, in its own process group behind a hard
     deadline shared by the targets.
  3. Parses each log: sanitizer reports (deduplicated by their SUMMARY line),
     the Swift Testing run line and the XCTest "Executed N tests" line, build
     failure, timeout, a relaunched test host.
  3a. Known findings (2026-11-08, Rick: "make red mean a new finding"): each
     sanitizer's suppression file under scripts/sanitizer/ (tsan.supp,
     ubsan.supp) goes to the runtime through TSAN_OPTIONS / UBSAN_OPTIONS (and
     their TEST_RUNNER_ forms, which xcodebuild forwards to the test host). A
     suppressed report is never printed, so it neither counts as a finding nor
     halts the host. Every entry must carry a `# known:` header (code, issue,
     reason) or the run stops with status "config-error"; the row lists each
     entry with its hit count (TSan prints them with print_suppressions=1;
     UBSan does not, so its hits are null = not observable, never 0).
  4. Writes <log-dir>/latest-<kind>.json (read by the morning digest,
     scripts/sanitizer_alert.py, and by analysis_lane.py) and appends
     runs.jsonl. The full logs stay beside them for the reports' stack traces.

Every exit path writes a status row — a run that silently did nothing is the
failure mode the nightly learned the hard way.

Memory: each log is read whole once for parsing (a full TSan app log is
~200k lines / ~40 MB); nothing else is held.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import Dict, List, Optional

REPO = Path(__file__).resolve().parent.parent
PROJECT = REPO / "VideoScan" / "VideoScan.xcodeproj"
CORE_PKG = REPO / "VideoScan" / "VideoScanCore"
MANIFEST = REPO / "scripts" / "gauntlet" / "manifest.json"
LOGDIR = Path.home() / "Library" / "Logs" / "VideoScan" / "sanitizer"
DD_ROOT = Path.home() / "Library" / "Caches" / "VideoScan" / "sanitizer-dd"
SUPP_DIR = REPO / "scripts" / "sanitizer"

# xcodebuild flags per kind. ASan and UBSan share a build; TSan cannot share
# with either (the runtimes conflict), hence two kinds, two builds.
FLAGS: Dict[str, List[str]] = {
    "address": ["-enableAddressSanitizer", "YES", "-enableUndefinedBehaviorSanitizer", "YES"],
    "thread": ["-enableThreadSanitizer", "YES"],
}
# swift test equivalents (SwiftPM: one --sanitize per sanitizer).
SWIFTPM_FLAGS: Dict[str, List[str]] = {
    "address": ["--sanitize", "address", "--sanitize", "undefined"],
    "thread": ["--sanitize", "thread"],
}
# File-name shape of the catalog / MFO / Archive suites (the data-risk paths).
CATALOG_SUBSET_RE = re.compile(r"Catalog|MediaFileOperations|MediaOps|Archive|Promote|Trash|Prune|Relocate|Commit|Store")

# A sanitizer report starts with one of these and ends with a SUMMARY line.
REPORT_START = re.compile(r"(==\d+==ERROR: AddressSanitizer|WARNING: ThreadSanitizer|: runtime error: )")
SUMMARY = re.compile(r"SUMMARY: (AddressSanitizer|ThreadSanitizer|UndefinedBehaviorSanitizer): (.+)")
# TSan at process exit with print_suppressions=1: a header, then "<hits> <type>:<pattern>" lines.
MATCHED_HEADER = re.compile(r"^ThreadSanitizer: Matched \d+ suppressions? \(pid=\d+\):\s*$")
MATCHED_LINE = re.compile(r"^\s*(\d+) ([a-z_]+:\S+)\s*$")
RUN_LINE = re.compile(r"Test run with (\d+) tests? in (\d+) suites? (passed|failed)")
XCTEST_EXECUTED = re.compile(r"^\s*Executed (\d+) tests?, with (\d+) failures?", re.M)
FAILED_TEST = re.compile(r"✘ Test (\S+?)\(\) (?:failed|recorded an issue)|^Test Case '-\[\S+ (\w+)\]' failed", re.M)


# Which suppression file each kind's runtimes read, and the environment variable
# that carries it (the ASan+UBSan build reads UBSAN_OPTIONS for its UBSan half).
SUPPRESSION_FILES: Dict[str, List[tuple]] = {
    "thread": [("TSAN_OPTIONS", "tsan.supp", "print_suppressions=1")],
    "address": [("UBSAN_OPTIONS", "ubsan.supp", "print_stacktrace=1")],
}
KNOWN_HEADER = re.compile(r"^#\s*known:\s*(.*)$")
REASON_LINE = re.compile(r"^#\s*reason:\s*(.*)$")


class SuppressionError(ValueError):
    """A suppression file that would hide a finding nobody explained."""


def load_suppressions(path: Path) -> List[dict]:
    """Pure-ish (reads one small file): each entry is `# known: k=v ...` (code
    and issue required), `# reason:` lines, then ONE pattern line. A pattern
    without a header, a header without a pattern, or a header missing code /
    issue / reason raises SuppressionError. A missing file is no entries."""
    if not path.is_file():
        return []
    entries: List[dict] = []
    pending: Optional[dict] = None
    for n, raw in enumerate(path.read_text().splitlines(), 1):
        line = raw.strip()
        if m := KNOWN_HEADER.match(line):
            if pending is not None:
                raise SuppressionError(f"{path.name}:{n}: a new `# known:` before the previous one's pattern")
            fields = dict(kv.split("=", 1) for kv in m.group(1).split() if "=" in kv)
            if not fields.get("code") or not fields.get("issue", "").isdigit():
                raise SuppressionError(f"{path.name}:{n}: `# known:` needs code=<code> and issue=<number>")
            pending = {"code": fields["code"], "issue": int(fields["issue"]), "date": fields.get("date"),
                       "repro": fields.get("repro"), "reason": []}
        elif m := REASON_LINE.match(line):
            if pending is not None:
                pending["reason"].append(m.group(1))
        elif not line or line.startswith("#"):
            continue
        else:
            if pending is None:
                raise SuppressionError(f"{path.name}:{n}: `{line}` has no `# known:` header (code, issue, reason)")
            if not pending["reason"]:
                raise SuppressionError(f"{path.name}:{n}: `{line}` has no `# reason:` line")
            check, _, pattern = line.partition(":")
            if not pattern:
                raise SuppressionError(f"{path.name}:{n}: `{line}` is not <check>:<pattern>")
            entries.append({**pending, "reason": " ".join(pending["reason"]), "check": check, "pattern": pattern})
            pending = None
    if pending is not None:
        raise SuppressionError(f"{path.name}: `# known: code={pending['code']}` has no pattern under it")
    return entries


def sanitizer_env(kind: str, base: Dict[str, str], supp_dir: Path = SUPP_DIR) -> tuple[Dict[str, str], List[dict]]:
    """The environment that hands `kind`'s suppression files to its runtimes
    (each variable also as TEST_RUNNER_<name>, which xcodebuild strips and
    forwards to the hosted test process; swift test reads the plain name), and
    the entries in force. Existing options in `base` are kept, ours appended."""
    env = dict(base)
    entries: List[dict] = []
    for var, name, extra in SUPPRESSION_FILES[kind]:
        path = supp_dir / name
        loaded = load_suppressions(path)
        entries += loaded
        # The reporting option (hit counts for TSan, a stack for UBSan so its
        # frames can be classified) applies with or without a suppression file.
        ours = ":".join(x for x in (f"suppressions={path}" if loaded else "", extra) if x)
        if not ours:
            continue
        for key in (var, f"TEST_RUNNER_{var}"):
            env[key] = f"{base[key]}:{ours}" if base.get(key) else ours
    return env, entries


def matched_suppressions(text: str) -> Dict[str, int]:
    """'<check>:<pattern>' -> hits, summed over every process that printed TSan's
    matched-suppressions block (each relaunched or child process prints its own)."""
    hits: Dict[str, int] = {}
    in_block = False
    for line in text.splitlines():
        if MATCHED_HEADER.match(line):
            in_block = True
            continue
        m = MATCHED_LINE.match(line) if in_block else None
        if m:
            hits[m.group(2)] = hits.get(m.group(2), 0) + int(m.group(1))
        else:
            in_block = False
    return hits


def suppression_rows(entries: List[dict], hits: Dict[str, int], kind: str) -> List[dict]:
    """The row's `suppressed` list: each entry in force with its hits. TSan
    reports hits; UBSan has no such report, so its hits are None (not observable)."""
    return [{"code": e["code"], "issue": e["issue"], "check": e["check"], "pattern": e["pattern"],
             "reason": e["reason"],
             "hits": hits.get(f"{e['check']}:{e['pattern']}", 0) if kind == "thread" else None}
            for e in entries]


# ── Whose code a report is in (Rick 2026-11-08) ──────────────────────────────
# A finding whose frames IN OUR CODE are all test code (VideoScanTests/, a
# package's Tests/, test helpers) is grey: "fix when convenient". One that
# touches product code (the app, VideoScan Background, VideoScanCore Sources)
# is red. Third-party and runtime frames are not ours. A report with no frame
# of ours (a UBSan line in a dependency, an unsymbolised stack) is product:
# the classifier may only ever make something grey on positive evidence.
FRAME_LINE = re.compile(r"^\s*#\d+\s+(.*)$")
SOURCE_PATH = re.compile(r"(/[^\s():]+\.(?:swift|mm?|c|cc|cpp|h|hpp))(?::\d+)")
TEST_PATH_PARTS = ("/VideoScanTests/", "/VideoScanUITests/", "/Tests/")
PRODUCT_PATH_PARTS = ("/VideoScan/VideoScan/", "/VideoScanCore/Sources/", "/VideoScanBackground/")
SWIFT_MODULE = re.compile(r"\b(VideoScanCoreTests|VideoScanTests|VideoScanUITests|VideoScanCore|VideoScan)\.")
TEST_MODULES = {"VideoScanCoreTests", "VideoScanTests", "VideoScanUITests"}
BINARY_MODULE = re.compile(r"\(([^()]+?)(?::arm64e?)?\+0x[0-9a-fA-F]+\)\s*$")


def frame_side(frame: str) -> Optional[str]:
    """Pure: "test", "product", or None (not our code / not a frame).
    Evidence in order of precision: the source path; the module of the Swift
    function that owns the frame (after the last " in ", so a closure inside a
    test reads as the test); the binary. VideoScanCoreTests as a BINARY says
    nothing (swift test links Core into it), so it never decides alone."""
    m = FRAME_LINE.match(frame)
    body = m.group(1) if m else (frame if ": runtime error: " in frame else None)
    if body is None:
        return None
    path = SOURCE_PATH.search(body)
    if path and path.group(1).startswith("/"):
        p = path.group(1)
        if any(part in p for part in TEST_PATH_PARTS):
            return "test"
        if any(part in p for part in PRODUCT_PATH_PARTS):
            return "product"
    symbol = BINARY_MODULE.sub("", body)
    owner = symbol.rsplit(" in ", 1)[-1]
    sm = SWIFT_MODULE.search(owner) or SWIFT_MODULE.search(symbol)
    if sm:
        return "test" if sm.group(1) in TEST_MODULES else "product"
    bm = BINARY_MODULE.search(body)
    if bm:
        module = bm.group(1)
        if module in ("VideoScanTests", "VideoScanUITests"):
            return "test"
        if module in ("VideoScan", "VideoScan.debug.dylib", "VideoScan Background") or module.startswith("VideoScanCore_"):
            return "product"
    return None


def classify_report(block: str) -> str:
    """Pure: "test" when the report has at least one frame of ours and every
    frame of ours is test code; otherwise "product"."""
    sides = {frame_side(line) for line in block.splitlines()} - {None}
    return "test" if sides == {"test"} else "product"


def report_blocks(text: str) -> List[tuple]:
    """(block, summary line or None) per sanitizer report: from the report's
    first line to its SUMMARY (or to the next report)."""
    starts = sorted({text.rfind("\n", 0, m.start()) + 1 for m in REPORT_START.finditer(text)})
    out = []
    for i, start in enumerate(starts):
        end = starts[i + 1] if i + 1 < len(starts) else len(text)
        chunk = text[start:end]
        sm = SUMMARY.search(chunk)
        if sm:
            chunk = chunk[:sm.end()]
        out.append((chunk, f"{sm.group(1)}: {sm.group(2).strip()}" if sm else None))
    return out


def parse_log(text: str) -> dict:
    """Pure: everything the row needs, from an xcodebuild or swift test log."""
    summaries: list[str] = []
    test_only: list[str] = []
    test_only_reports = 0
    for block, line in report_blocks(text):
        if classify_report(block) == "test":
            test_only_reports += 1
            if line and line not in test_only:
                test_only.append(line)
        elif line and line not in summaries:
            summaries.append(line)
    # A SUMMARY whose report start was not recognised is product (never hidden).
    for m in SUMMARY.finditer(text):
        line = f"{m.group(1)}: {m.group(2).strip()}"
        if line not in summaries and line not in test_only:
            summaries.append(line)
    # One line seen both in tests and product is product.
    test_only = [t for t in test_only if t not in summaries]
    run = RUN_LINE.findall(text)
    tests, suites, outcome = (int(run[-1][0]), int(run[-1][1]), run[-1][2]) if run else (0, 0, None)
    # XCTest prints "Executed N tests, with F failures" per suite and once for
    # 'All tests'; the last line is the whole XCTest half of a mixed run.
    xct = XCTEST_EXECUTED.findall(text)
    if xct:
        tests += int(xct[-1][0])
        if int(xct[-1][1]) > 0 and outcome != "failed":
            outcome = "failed"
    failed_tests = sorted({a or b for a, b in FAILED_TEST.findall(text)})
    # xcodebuild silently relaunches a test host that died mid-run; the only
    # trace is a second "Test Suite 'VideoScanTests.xctest' started" line
    # (2026-10-05: a TSan-runtime SIGSEGV lost ~800 cases unnoticed).
    host_starts = text.count("Test Suite 'VideoScanTests.xctest' started")
    return {
        "host_restarts": max(0, host_starts - 1),
        "reports": len(REPORT_START.findall(text)),
        "suppressed_hits": matched_suppressions(text),
        "unique_findings": summaries,
        "test_only_findings": test_only,
        "test_only_reports": test_only_reports,
        "tests": tests,
        "suites": suites,
        "tests_outcome": outcome,
        "failed_tests": failed_tests[:20],
        "build_failed": any(s in text for s in ("** BUILD FAILED **", "** TEST BUILD FAILED **",
                                                 "Testing cancelled because the build failed",
                                                 "linker command failed",
                                                 "error: emit-module command failed",
                                                 "error: fatalError")),
        "test_succeeded": "** TEST SUCCEEDED **" in text or bool(run and run[-1][2] == "passed" and not xct)
                          or bool(xct and int(xct[-1][1]) == 0 and (not run or run[-1][2] == "passed")),
    }


def merge(parsed: List[dict]) -> dict:
    """Fold per-target results into one row-shaped dict (union of findings,
    sums of counts, worst outcome)."""
    out = {"host_restarts": 0, "reports": 0, "unique_findings": [], "tests": 0, "suites": 0,
           "tests_outcome": None, "failed_tests": [], "build_failed": False, "test_succeeded": bool(parsed),
           "suppressed_hits": {}, "test_only_findings": [], "test_only_reports": 0}
    for p in parsed:
        out["test_only_reports"] += p.get("test_only_reports", 0)
        out["test_only_findings"] += [f for f in p.get("test_only_findings", []) if f not in out["test_only_findings"]]
        for key, n in p.get("suppressed_hits", {}).items():
            out["suppressed_hits"][key] = out["suppressed_hits"].get(key, 0) + n
        out["host_restarts"] += p["host_restarts"]
        out["reports"] += p["reports"]
        out["unique_findings"] += [f for f in p["unique_findings"] if f not in out["unique_findings"]]
        out["tests"] += p["tests"]
        out["suites"] += p["suites"]
        if p["tests_outcome"] == "failed" or out["tests_outcome"] == "failed":
            out["tests_outcome"] = "failed"
        elif p["tests_outcome"]:
            out["tests_outcome"] = p["tests_outcome"]
        out["failed_tests"] = sorted(set(out["failed_tests"]) | set(p["failed_tests"]))[:20]
        out["build_failed"] = out["build_failed"] or p["build_failed"]
        out["test_succeeded"] = out["test_succeeded"] and p["test_succeeded"]
    # A finding product code shows in one target is product everywhere.
    out["test_only_findings"] = [f for f in out["test_only_findings"] if f not in out["unique_findings"]]
    return out


def status_for(parsed: dict, timed_out: bool) -> str:
    """One word for the morning: product findings beat everything else; a
    finding only in test code (grey, "test-findings") is the last word before
    ok, and each test-only report may explain one relaunched host (the
    sanitizer halts the host on a report)."""
    test_only_reports = parsed.get("test_only_reports", 0)
    if parsed["unique_findings"] or parsed["reports"] > test_only_reports:
        return "findings"
    if parsed.get("host_restarts", 0) > test_only_reports:
        return "host-crashed"
    if timed_out:
        return "timeout"
    if parsed["build_failed"]:
        return "build-failed"
    if parsed["tests_outcome"] == "failed" or parsed["failed_tests"]:
        return "tests-failed"
    if parsed["tests"] == 0:
        return "no-tests-ran"
    if parsed.get("test_only_findings") or test_only_reports:
        return "test-findings"
    return "ok"


def subset_selectors(manifest_path: Path, pattern: re.Pattern = CATALOG_SUBSET_RE) -> List[str]:
    """`-only-testing:` identifiers for the app suites whose FILE name matches
    `pattern`, from the gauntlet manifest (the reviewed inventory of suites).
    Empty when the manifest cannot be read — the caller must treat that as
    "no subset", never as "run nothing"."""
    try:
        manifest = json.loads(manifest_path.read_text())
    except (OSError, ValueError):
        return []
    out: List[str] = []
    for a in manifest.get("assignments", []):
        path = a.get("path", "")
        if a.get("kind") != "xcode" or "VideoScanCore" in path or not pattern.search(Path(path).stem):
            continue
        out += [f"VideoScanTests/{s}" for s in a.get("suites", [])]
    return sorted(set(out))


def app_command(kind: str, configuration: str, dd: Path, selectors: List[str]) -> List[str]:
    cmd = ["xcodebuild", "test", "-project", str(PROJECT), "-scheme", "VideoScan",
           "-configuration", configuration, "-destination", "platform=macOS,arch=arm64",
           "-derivedDataPath", str(dd), "-skip-testing:VideoScanUITests"] + FLAGS[kind]
    if configuration == "Release":
        # The nightly's Release shape: testability on so @testable imports resolve.
        cmd += ["ENABLE_TESTABILITY=YES", "CODE_SIGN_IDENTITY=-", "CODE_SIGNING_REQUIRED=NO", "CODE_SIGN_ENTITLEMENTS="]
    cmd += [f"-only-testing:{s}" for s in selectors]
    return cmd


def core_command(kind: str, configuration: str, scratch: Path) -> List[str]:
    return ["swift", "test", "--package-path", str(CORE_PKG), "-c", configuration.lower(),
            "--scratch-path", str(scratch), "--no-parallel"] + SWIFTPM_FLAGS[kind]


def busy() -> str | None:
    """Why we should not start now, or None."""
    if subprocess.run(["pgrep", "-x", "xcodebuild"], capture_output=True).returncode == 0:
        return "another xcodebuild is running"
    out = subprocess.run(["memory_pressure"], capture_output=True, text=True).stdout
    m = re.search(r"free percentage: (\d+)%", out)
    if m and int(m.group(1)) < 30:
        return f"memory free {m.group(1)}%"
    return None


def git(*args: str) -> str:
    return subprocess.run(["git", "-C", str(REPO), *args], capture_output=True, text=True).stdout.strip()


def write_row(kind: str, row: dict, logdir: Path = LOGDIR) -> None:
    logdir.mkdir(parents=True, exist_ok=True)
    (logdir / f"latest-{kind}.json").write_text(json.dumps(row, indent=2) + "\n")
    with (logdir / "runs.jsonl").open("a") as f:
        f.write(json.dumps(row) + "\n")


def run_target(cmd: List[str], log_path: Path, env: dict, deadline: float) -> tuple[int | None, bool]:
    """Run one target's command in a private process group until `deadline`
    (monotonic). Returns (returncode, timed_out)."""
    timed_out = False
    with open(log_path, "w") as log:
        log.write("$ " + " ".join(cmd) + "\n")
        log.flush()
        proc = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT, start_new_session=True, env=env)
        try:
            proc.wait(timeout=max(1.0, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            timed_out = True
            os.killpg(proc.pid, signal.SIGTERM)
            try:
                proc.wait(timeout=60)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
    return proc.returncode, timed_out


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--sanitizer", choices=sorted(FLAGS), required=True)
    ap.add_argument("--timeout-hours", type=float, default=3.0)
    ap.add_argument("--wait-minutes", type=float, default=90)
    ap.add_argument("--no-wait", action="store_true", help="do not wait for a quiet machine (the analysis lane already did)")
    ap.add_argument("--configuration", choices=["Debug", "Release"], default="Debug",
                    help="Debug (the weekly jobs) or Release (the nightly analysis lane)")
    ap.add_argument("--target", choices=["app", "core", "all"], default="app",
                    help="app = VideoScanTests via xcodebuild; core = VideoScanCore via swift test --sanitize")
    ap.add_argument("--subset", choices=["full", "catalog"], default="full",
                    help="catalog = all of Core + the app's catalog/MFO/Archive suites (gauntlet manifest)")
    ap.add_argument("--manifest", type=Path, default=MANIFEST)
    ap.add_argument("--log-dir", type=Path, default=LOGDIR)
    ap.add_argument("--dd-root", type=Path, default=DD_ROOT)
    ap.add_argument("--suppressions-dir", type=Path, default=SUPP_DIR,
                    help="folder holding tsan.supp / ubsan.supp (known findings, each with an issue)")
    ap.add_argument("--source", default="weekly", help="who ran it (weekly | analysis-lane); recorded in the row")
    args = ap.parse_args(argv)
    kind = args.sanitizer
    targets = ["app", "core"] if args.target == "all" else [args.target]
    started = dt.datetime.now().astimezone()
    stamp = started.strftime("%Y-%m-%d")
    suffix = "" if args.configuration == "Debug" else f"-{args.configuration.lower()}"
    logdir: Path = args.log_dir
    row: dict = {
        "kind": kind, "started": started.isoformat(timespec="seconds"), "source": args.source,
        "branch": git("rev-parse", "--abbrev-ref", "HEAD"), "sha": git("rev-parse", "--short", "HEAD"),
        "dirty": bool(git("status", "--porcelain")), "configuration": args.configuration,
        "targets": targets, "subset": args.subset,
        "log": str(logdir / f"{stamp}-{kind}{suffix}.log"),
    }

    if not args.no_wait:
        deadline_wait = time.monotonic() + args.wait_minutes * 60
        while (why := busy()) is not None:
            if time.monotonic() > deadline_wait:
                row.update(status="skipped-busy", reason=why,
                           finished=dt.datetime.now().astimezone().isoformat(timespec="seconds"))
                write_row(kind, row, logdir)
                print(f"sanitizer {kind}: skipped — {why}")
                return 0
            time.sleep(60)

    logdir.mkdir(parents=True, exist_ok=True)
    selectors: List[str] = []
    if args.subset == "catalog":
        selectors = subset_selectors(args.manifest)
        row["selected_suites"] = len(selectors)
        if not selectors and "app" in targets:
            # No manifest = no subset; say so and run the whole app battery rather than nothing.
            row["subset_note"] = f"manifest unreadable at {args.manifest}; app ran in full"
    # Tell the tests which sanitizer is on: TimingBudget widens wall-clock
    # budgets by the instrumentation's known slowdown (xcodebuild strips the
    # TEST_RUNNER_ prefix when it forwards the variable; swift test reads the
    # plain name).
    try:
        env, known = sanitizer_env(kind, dict(os.environ, TEST_RUNNER_VIDEOSCAN_SANITIZER=kind,
                                                VIDEOSCAN_SANITIZER=kind), args.suppressions_dir)
    except SuppressionError as why:
        row.update(status="config-error", reason=str(why), tests=0, reports=0, host_restarts=0,
                   unique_findings=[], finished=dt.datetime.now().astimezone().isoformat(timespec="seconds"))
        write_row(kind, row, logdir)
        print(f"sanitizer {kind}: config-error — {why}")
        return 0
    deadline = time.monotonic() + args.timeout_hours * 3600
    per_target: Dict[str, dict] = {}
    parsed_all: List[dict] = []
    timed_out = False
    exit_codes: Dict[str, int | None] = {}
    for target in targets:
        if target == "app":
            cmd = app_command(kind, args.configuration, args.dd_root / f"{kind}{suffix}", selectors)
            log_path = Path(row["log"])
        else:
            cmd = core_command(kind, args.configuration, args.dd_root / f"{kind}{suffix}-core")
            log_path = Path(row["log"]).with_name(Path(row["log"]).stem + "-core.log")
        if timed_out:
            per_target[target] = {"status": "not-run", "reason": "deadline spent by an earlier target", "log": str(log_path)}
            continue
        rc, t_out = run_target(cmd, log_path, env, deadline)
        timed_out = timed_out or t_out
        exit_codes[target] = rc
        p = parse_log(log_path.read_text(errors="replace"))
        per_target[target] = {**p, "exit_code": rc, "timed_out": t_out, "log": str(log_path),
                              "status": status_for(p, t_out)}
        parsed_all.append(p)
    merged = merge(parsed_all)
    row.update(merged)
    row["suppressed"] = suppression_rows(known, merged["suppressed_hits"], kind)
    row.update(per_target=per_target, status=status_for(merged, timed_out),
               exit_code=exit_codes.get("app", exit_codes.get("core")), exit_codes=exit_codes,
               timed_out=timed_out, finished=dt.datetime.now().astimezone().isoformat(timespec="seconds"))
    if any(t.get("status") == "not-run" for t in per_target.values()) and row["status"] == "ok":
        row["status"] = "timeout"
    write_row(kind, row, logdir)
    print(f"sanitizer {kind}: {row['status']} — {merged['tests']} tests ({'+'.join(targets)}, {args.configuration}, "
          f"{args.subset}), {len(merged['unique_findings'])} unique finding(s), "
          f"{len(row['suppressed'])} known suppressed; log {row['log']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
