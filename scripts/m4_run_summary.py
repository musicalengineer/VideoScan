#!/usr/bin/env python3
"""m4_run_summary.py — one line per test plan for scripts/m4_run.sh.

Reads an `xcodebuild test-without-building` log and prints ONE line:

    VideoScan-Gauntlet: GREEN 9 passed, 0 failed, 0 skipped, rc=0, 412s
    VideoScan-Gauntlet: RED 5 passed, 4 failed, 0 skipped, rc=65, 412s; failing: Gauntlet01PersonSearchUITests.testX, ...
    VideoScan-UI: RED TIMEOUT after 900s (0 passed, 0 failed so far)

and writes the per-test table (status, Class.test, seconds) to `--tsv`.

A plan is GREEN only when xcodebuild exited 0, no test failed, at least one
test passed, and the watchdog did not fire. A zero-test run is RED (CLAUDE.md
rule 9: a lane that ran nothing proves nothing).

Usage:
    m4_run_summary.py PLAN LOG RC SECONDS [--timeout] [--tsv PATH]
Exit status: 0 GREEN, 1 RED, 2 usage error.
"""
import argparse
import re
import sys

# XCTest's per-test line, the same for unit and UI bundles:
#   Test Case '-[VideoScanUITests.Gauntlet07FamilyMapUITests testWalk]' passed (34.512 seconds).
XCTEST_LINE = re.compile(
    r"Test Case '-\[(?:[\w]+\.)?(?P<cls>\w+) (?P<test>\w+)\]' "
    r"(?P<status>passed|failed|skipped) \((?P<secs>[\d.]+) seconds\)")


def parse(log_text):
    """[(status, 'Class.test', seconds)] in log order; last verdict per test wins."""
    seen = {}
    for m in XCTEST_LINE.finditer(log_text):
        seen[f"{m['cls']}.{m['test']}"] = (m['status'], float(m['secs']))
    return [(status, name, secs) for name, (status, secs) in seen.items()]


def summarize(plan, rows, rc, seconds, timed_out):
    passed = sum(1 for s, _, _ in rows if s == 'passed')
    failed = [n for s, n, _ in rows if s == 'failed']
    skipped = sum(1 for s, _, _ in rows if s == 'skipped')
    if timed_out:
        line = (f"{plan}: RED TIMEOUT after {seconds}s "
                f"({passed} passed, {len(failed)} failed so far)")
        if failed:
            line += "; failing: " + ", ".join(failed)
        return False, line
    green = rc == 0 and not failed and passed > 0
    line = (f"{plan}: {'GREEN' if green else 'RED'} {passed} passed, {len(failed)} failed, "
            f"{skipped} skipped, rc={rc}, {seconds}s")
    if failed:
        line += "; failing: " + ", ".join(failed)
    elif not green and passed == 0:
        line += "; no test ran"
    return green, line


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('plan')
    ap.add_argument('log')
    ap.add_argument('rc', type=int)
    ap.add_argument('seconds', type=int)
    ap.add_argument('--timeout', action='store_true', help='the watchdog fired')
    ap.add_argument('--tsv', help='write status<TAB>Class.test<TAB>seconds here')
    try:
        a = ap.parse_args(argv)
    except SystemExit:
        return 2
    try:
        with open(a.log, encoding='utf-8', errors='replace') as f:
            text = f.read()
    except OSError:
        text = ''
    rows = parse(text)
    if a.tsv:
        with open(a.tsv, 'w', encoding='utf-8') as f:
            for status, name, secs in rows:
                f.write(f"{status}\t{name}\t{secs:.1f}\n")
    green, line = summarize(a.plan, rows, a.rc, a.seconds, a.timeout)
    print(line)
    return 0 if green else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
