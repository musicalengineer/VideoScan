#!/usr/bin/env python3
"""Weekly sanitizer run of the unit battery (Rick 2026-10-04: "automated tools
overnight so someone wouldn't break something and if they did we'd know first
thing in the morning").

Two launchd jobs (scripts/install_sanitizer_weekly.sh) call this:
  --sanitizer address   Saturday 07:00  (Address Sanitizer: use-after-free,
                                         overruns, double free — the class
                                         behind the 10/4 SIGSEGVs, GH #273)
  --sanitizer thread    Sunday   05:00  (Thread Sanitizer: data races)

What it does, in order:
  1. Waits (up to --wait-minutes) while another xcodebuild is running or memory
     is tight — the RAM budget is one broad test run at a time on the M4.
     Gives up with status "skipped-busy" rather than piling on.
  2. Builds and tests VideoScanTests in DEBUG with the sanitizer on, in its own
     derived-data folder (~/Library/Caches/VideoScan/sanitizer-dd/<kind>; never
     the XcodeRAM disk), UI tests skipped, in its own process group behind a hard
     deadline.
  3. Parses the log: sanitizer reports (deduplicated by their SUMMARY line),
     the Swift Testing run line, build failure, timeout.
  4. Writes ~/Library/Logs/VideoScan/sanitizer/latest-<kind>.json (read by the
     morning digest, scripts/sanitizer_alert.py) and appends runs.jsonl. The
     full log stays beside them for the reports' stack traces.

Every exit path writes a status row — a run that silently did nothing is the
failure mode the nightly learned the hard way.
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

REPO = Path(__file__).resolve().parent.parent
PROJECT = REPO / "VideoScan" / "VideoScan.xcodeproj"
LOGDIR = Path.home() / "Library" / "Logs" / "VideoScan" / "sanitizer"
DD_ROOT = Path.home() / "Library" / "Caches" / "VideoScan" / "sanitizer-dd"

FLAGS = {
    "address": "-enableAddressSanitizer",
    "thread": "-enableThreadSanitizer",
}

# A sanitizer report starts with one of these and ends with a SUMMARY line.
REPORT_START = re.compile(r"(==\d+==ERROR: AddressSanitizer|WARNING: ThreadSanitizer)")
SUMMARY = re.compile(r"SUMMARY: (AddressSanitizer|ThreadSanitizer): (.+)")
RUN_LINE = re.compile(r"Test run with (\d+) tests? in (\d+) suites? (passed|failed)")
FAILED_TEST = re.compile(r"✘ Test (\S+?)\(\) (?:failed|recorded an issue)")


def parse_log(text: str) -> dict:
    """Pure: everything the row needs, from an xcodebuild log."""
    summaries: list[str] = []
    for m in SUMMARY.finditer(text):
        line = f"{m.group(1)}: {m.group(2).strip()}"
        if line not in summaries:
            summaries.append(line)
    run = RUN_LINE.findall(text)
    tests, suites, outcome = (int(run[-1][0]), int(run[-1][1]), run[-1][2]) if run else (0, 0, None)
    failed_tests = sorted(set(FAILED_TEST.findall(text)))
    return {
        "reports": len(REPORT_START.findall(text)),
        "unique_findings": summaries,
        "tests": tests,
        "suites": suites,
        "tests_outcome": outcome,
        "failed_tests": failed_tests[:20],
        "build_failed": any(s in text for s in ("** BUILD FAILED **", "** TEST BUILD FAILED **",
                                                 "Testing cancelled because the build failed",
                                                 "linker command failed")),
        "test_succeeded": "** TEST SUCCEEDED **" in text,
    }


def status_for(parsed: dict, timed_out: bool) -> str:
    """One word for the morning: findings beat everything else."""
    if parsed["unique_findings"] or parsed["reports"]:
        return "findings"
    if timed_out:
        return "timeout"
    if parsed["build_failed"]:
        return "build-failed"
    if parsed["tests_outcome"] == "failed" or parsed["failed_tests"]:
        return "tests-failed"
    if parsed["tests"] == 0:
        return "no-tests-ran"
    return "ok"


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


def write_row(kind: str, row: dict) -> None:
    LOGDIR.mkdir(parents=True, exist_ok=True)
    (LOGDIR / f"latest-{kind}.json").write_text(json.dumps(row, indent=2) + "\n")
    with (LOGDIR / "runs.jsonl").open("a") as f:
        f.write(json.dumps(row) + "\n")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--sanitizer", choices=sorted(FLAGS), required=True)
    ap.add_argument("--timeout-hours", type=float, default=3.0)
    ap.add_argument("--wait-minutes", type=float, default=90)
    args = ap.parse_args(argv)
    kind = args.sanitizer
    started = dt.datetime.now().astimezone()
    stamp = started.strftime("%Y-%m-%d")
    row = {
        "kind": kind, "started": started.isoformat(timespec="seconds"),
        "branch": git("rev-parse", "--abbrev-ref", "HEAD"), "sha": git("rev-parse", "--short", "HEAD"),
        "dirty": bool(git("status", "--porcelain")), "configuration": "Debug",
        "log": str(LOGDIR / f"{stamp}-{kind}.log"),
    }

    deadline_wait = time.monotonic() + args.wait_minutes * 60
    while (why := busy()) is not None:
        if time.monotonic() > deadline_wait:
            row.update(status="skipped-busy", reason=why,
                       finished=dt.datetime.now().astimezone().isoformat(timespec="seconds"))
            write_row(kind, row)
            print(f"sanitizer {kind}: skipped — {why}")
            return 0
        time.sleep(60)

    LOGDIR.mkdir(parents=True, exist_ok=True)
    dd = DD_ROOT / kind
    cmd = ["xcodebuild", "test", "-project", str(PROJECT), "-scheme", "VideoScan",
           "-configuration", "Debug", "-destination", "platform=macOS",
           "-derivedDataPath", str(dd), "-skip-testing:VideoScanUITests", FLAGS[kind], "YES"]
    timed_out = False
    with open(row["log"], "w") as log:
        log.write("$ " + " ".join(cmd) + "\n")
        log.flush()
        proc = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            proc.wait(timeout=args.timeout_hours * 3600)
        except subprocess.TimeoutExpired:
            timed_out = True
            os.killpg(proc.pid, signal.SIGTERM)
            try:
                proc.wait(timeout=60)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
    parsed = parse_log(Path(row["log"]).read_text(errors="replace"))
    row.update(parsed)
    row.update(status=status_for(parsed, timed_out), exit_code=proc.returncode, timed_out=timed_out,
               finished=dt.datetime.now().astimezone().isoformat(timespec="seconds"))
    write_row(kind, row)
    print(f"sanitizer {kind}: {row['status']} — {parsed['tests']} tests, "
          f"{len(parsed['unique_findings'])} unique finding(s); log {row['log']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
