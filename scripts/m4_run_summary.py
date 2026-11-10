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
    m4_run_summary.py --gauntlet RESULT_JSON RC SECONDS [--timeout]
Exit status: 0 GREEN, 1 RED, 2 usage error, 3 AMBER (--gauntlet only).

--gauntlet reads the deep lane's result.json (scripts/gauntlet/Runner.swift),
or that run's history.jsonl row when a published run dir is already gone, and prints ONE line (Rick 2026-11-05, DECISIONS):

    deep: GREEN — every stage passed
    deep: AMBER 7 known issues (regression 7); 6 stages blocked (912 unadapted suites); ui not run (phase 2)
    deep: RED regression failed: 1 test failure

RED = a test failed, a floor was missed, inventory errored, a build failed,
the watchdog fired, or there is no result. AMBER = only tracked known issues,
unadapted ("blocked") suites and stages not run. GREEN = everything passed.
A result.json from before AMBER (status "incomplete") reads as AMBER: it had
no failure.
"""
import json
import argparse
import os
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


GREEN, AMBER, RED = 'GREEN', 'AMBER', 'RED'


def _amber_reasons(result):
    """The runner's own words when it wrote them; else counted here (old runs)."""
    if result.get('amber_reasons'):
        return list(result['amber_reasons'])
    stages = result.get('stages') or []
    reasons = []
    known = [(s.get('name', '?'), int(s.get('known_issues') or 0)) for s in stages if int(s.get('known_issues') or 0) > 0]
    if known:
        total = sum(n for _, n in known)
        reasons.append(f"{total} known issue{'s' if total != 1 else ''} ("
                       + ", ".join(f"{name} {n}" for name, n in known) + ")")
    held = [s for s in stages if s.get('status') in ('blocked', 'amber', 'incomplete') and s.get('blocked_details')]
    if held:
        reasons.append(f"{len(held)} stage{'s' if len(held) != 1 else ''} blocked "
                       f"({sum(len(s['blocked_details']) for s in held)} unadapted suites)")
    for s in stages:
        if s.get('status') == 'not_run':
            reasons.append(f"{s.get('name', '?')} not run ({s.get('reason') or '?'})")
    return reasons


NAMES_SHOWN = 5


def stage_names(stage):
    """" [skipped: A, B; failed: C +2 more]" — the tests behind a stage's verdict, from the
    names the runner recorded (failed_tests / skipped_tests / incomplete_tests and their
    `_truncated` counts). Empty when the stage carries none. 2026-11-10: the done line said
    "unit failed: unexpected skipped tests" for four days and never said which tests."""
    parts = []
    for word, key in (('failed', 'failed_tests'), ('skipped', 'skipped_tests'), ('did not finish', 'incomplete_tests')):
        names = [n for n in (stage.get(key) or []) if isinstance(n, str)]
        more = len(names) - NAMES_SHOWN + int(stage.get(key + '_truncated') or 0)
        if names:
            parts.append(f"{word}: {', '.join(names[:NAMES_SHOWN])}" + (f" +{more} more" if more > 0 else ''))
    return f" [{'; '.join(parts)}]" if parts else ''


def gauntlet_verdict(result, rc, timed_out=False):
    """(GREEN|AMBER|RED, words) for one deep run's result.json (dict or None)."""
    if timed_out:
        return RED, 'watchdog timeout'
    if not isinstance(result, dict):
        return RED, 'no result.json'
    # Defence in depth (Codex 2026-11-05): a build that did not exit 0 is RED
    # whatever the stage statuses say (a contaminated package build once read AMBER).
    for key, name in (('build_exit_code', 'build'), ('package_build_exit_code', 'package build')):
        code = result.get(key)
        if code not in (None, 0):
            return RED, f'{name} exit {code}'
    stages = result.get('stages') or []
    failed = [s for s in stages if s.get('status') == 'failed']
    status = result.get('status')
    if status == 'failed' or failed or result.get('inventory_errors') or rc not in (0,):
        words = [f"{s.get('name', '?')} failed: {s.get('reason') or '?'}{stage_names(s)}" for s in failed]
        if result.get('inventory_errors'):
            words.append(f"inventory: {len(result['inventory_errors'])} error(s)")
        if result.get('reason') and not failed:
            words.append(str(result['reason']))
        if not words:
            words.append(f"rc={rc}")
        return RED, '; '.join(words)
    if status == 'passed' and all(s.get('status') == 'passed' for s in stages):
        return GREEN, 'every stage passed'
    if status in ('amber', 'incomplete', 'passed'):
        return AMBER, '; '.join(_amber_reasons(result)) or 'not every stage passed'
    return RED, f"unknown status {status!r}"


def load_result(path):
    """The run's result.json, or — once the runner has deleted a published run
    dir (Rick 2026-11-08: only the summary row is kept) — that run's row in
    <results-root>/history.jsonl, matched by run_id (the run dir's name). None
    when neither exists."""
    try:
        with open(path, encoding='utf-8') as f:
            return json.load(f)
    except (OSError, ValueError):
        pass
    run = os.path.dirname(os.path.abspath(path))
    found = None
    try:
        with open(os.path.join(os.path.dirname(run), 'history.jsonl'), encoding='utf-8') as f:
            for line in f:                                  # streamed: one row in memory at a time
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if isinstance(row, dict) and row.get('run_id') == os.path.basename(run):
                    found = row
    except OSError:
        return None
    return found


def gauntlet_main(argv):
    ap = argparse.ArgumentParser(prog='m4_run_summary.py --gauntlet')
    ap.add_argument('result')
    ap.add_argument('rc', type=int)
    ap.add_argument('seconds', type=int)
    ap.add_argument('--timeout', action='store_true')
    try:
        a = ap.parse_args(argv)
    except SystemExit:
        return 2
    result = load_result(a.result)
    verdict, words = gauntlet_verdict(result, a.rc, a.timeout)
    sha = str((result or {}).get('commit') or '')[:9]
    print(f"deep: {verdict} {words} (sha={sha or '?'}, {a.seconds}s, results={a.result})")
    return {GREEN: 0, AMBER: 3, RED: 1}[verdict]


def main(argv):
    if argv[:1] == ['--gauntlet']:
        return gauntlet_main(argv[1:])
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
