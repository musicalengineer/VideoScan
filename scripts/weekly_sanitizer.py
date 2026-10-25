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
of docs/design/swift6_migration_2026_10_25.md §7) calls the same runner with
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
RUN_LINE = re.compile(r"Test run with (\d+) tests? in (\d+) suites? (passed|failed)")
XCTEST_EXECUTED = re.compile(r"^\s*Executed (\d+) tests?, with (\d+) failures?", re.M)
FAILED_TEST = re.compile(r"✘ Test (\S+?)\(\) (?:failed|recorded an issue)|^Test Case '-\[\S+ (\w+)\]' failed", re.M)


def parse_log(text: str) -> dict:
    """Pure: everything the row needs, from an xcodebuild or swift test log."""
    summaries: list[str] = []
    for m in SUMMARY.finditer(text):
        line = f"{m.group(1)}: {m.group(2).strip()}"
        if line not in summaries:
            summaries.append(line)
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
        "unique_findings": summaries,
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
           "tests_outcome": None, "failed_tests": [], "build_failed": False, "test_succeeded": bool(parsed)}
    for p in parsed:
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
    return out


def status_for(parsed: dict, timed_out: bool) -> str:
    """One word for the morning: findings beat everything else."""
    if parsed["unique_findings"] or parsed["reports"]:
        return "findings"
    if parsed.get("host_restarts"):
        return "host-crashed"
    if timed_out:
        return "timeout"
    if parsed["build_failed"]:
        return "build-failed"
    if parsed["tests_outcome"] == "failed" or parsed["failed_tests"]:
        return "tests-failed"
    if parsed["tests"] == 0:
        return "no-tests-ran"
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
    env = dict(os.environ, TEST_RUNNER_VIDEOSCAN_SANITIZER=kind, VIDEOSCAN_SANITIZER=kind)
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
    row.update(per_target=per_target, status=status_for(merged, timed_out),
               exit_code=exit_codes.get("app", exit_codes.get("core")), exit_codes=exit_codes,
               timed_out=timed_out, finished=dt.datetime.now().astimezone().isoformat(timespec="seconds"))
    if any(t.get("status") == "not-run" for t in per_target.values()) and row["status"] == "ok":
        row["status"] = "timeout"
    write_row(kind, row, logdir)
    print(f"sanitizer {kind}: {row['status']} — {merged['tests']} tests ({'+'.join(targets)}, {args.configuration}, "
          f"{args.subset}), {len(merged['unique_findings'])} unique finding(s); log {row['log']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
