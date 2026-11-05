"""The gauntlet's package counter reads Swift Testing's event stream (2026-11-05).

The console is for humans: a concurrent test's stdout can split a result line
(M4 deep run at 2c8fa9777 counted 774 of 775) or forge one. The runner counts
Swift Testing from `swift test --event-stream-output-path` (one JSON record a
line, written by the testing library to its own file) and XCTest from its
serial "Test Case '…' passed" lines, matched anywhere in a line.

Runner.swift's `--count-package-output <stream> <console>` seam prints the
counts as JSON (exit 0) or `null` (exit 1: counts unavailable, a RED stage).
The real-toolchain class builds a tiny package and runs the real `swift test`.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

REPO = Path(__file__).resolve().parents[1]


def runner_binary(workspace):
    binary = workspace / 'runner'
    subprocess.run(['/usr/bin/swiftc', '-module-cache-path', str(workspace / 'swift-cache'),
                    str(REPO / 'scripts/gauntlet/Runner.swift'), '-o', str(binary)], check=True, capture_output=True)
    return binary


def declared(tid, kind='function'):
    return dict(kind='test', version='6.4.0', payload=dict(id=tid, kind=kind, name=tid))


def event(kind, tid=None, **extra):
    payload = dict(kind=kind, messages=[], **extra)
    if tid:
        payload['testID'] = tid
    return dict(kind='event', version='6.4.0', payload=payload)


@unittest.skipUnless(sys.platform == "darwin", "macOS-only: builds with /usr/bin/swiftc")
class EventStreamCountTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workspace = tempfile.TemporaryDirectory(prefix='gauntlet-events-', dir='/private/tmp')
        cls.binary = runner_binary(Path(cls.workspace.name))

    @classmethod
    def tearDownClass(cls):
        cls.workspace.cleanup()

    def count(self, records, console='', raw=None):
        case = tempfile.TemporaryDirectory(dir=self.workspace.name)
        self.addCleanup(case.cleanup)
        stream = Path(case.name) / 'events.jsonl'
        stream.write_text(raw if raw is not None else ''.join(json.dumps(r) + '\n' for r in records))
        log = Path(case.name) / 'console.log'
        log.write_text(console)
        done = subprocess.run([str(self.binary), '--count-package-output', str(stream), str(log)],
                              text=True, capture_output=True, timeout=60)
        counts = json.loads(done.stdout)
        self.assertEqual(done.returncode, 0 if counts is not None else 1, done.stderr)
        return counts

    def run_of(self, *outcomes):
        """One function per (name, issue-or-None); suite records ride along."""
        records = [declared('M.S', 'suite')] + [declared(f'M.S/{n}()') for n, _ in outcomes]
        records += [event('runStarted'), event('testStarted', 'M.S')]
        for name, issue in outcomes:
            tid = f'M.S/{name}()'
            records.append(event('testStarted', tid))
            if issue == 'skip':
                records[-1] = event('testSkipped', tid)
                continue
            if issue is not None:
                records.append(event('issueRecorded', tid, issue=issue))
            records.append(event('testEnded', tid))
        return records + [event('testEnded', 'M.S'), event('runEnded')]

    def test_logic_pass_fail_known_skip_and_suites_not_counted(self):
        records = self.run_of(('a', None), ('b', dict(isKnown=False, isFailure=True)),
                              ('c', dict(isKnown=True, isFailure=False)), ('d', 'skip'))
        self.assertEqual(self.count(records), dict(passed=1, failed=1, known_issues=1, skipped=1))

    def test_a_known_issue_beside_a_real_failure_is_a_failure(self):
        tid = 'M.S/a()'
        records = self.run_of(('a', dict(isKnown=True, isFailure=False)))
        records.insert(-2, event('issueRecorded', tid, issue=dict(isKnown=False, isFailure=True)))
        self.assertEqual(self.count(records)['failed'], 1)

    def test_version_zero_issue_without_isFailure_is_a_failure_and_a_warning_is_not(self):
        records = self.run_of(('a', dict(isKnown=False)), ('b', dict(isKnown=False, isFailure=False)))
        self.assertEqual(self.count(records), dict(passed=1, failed=1, known_issues=0, skipped=0))

    def test_parameterized_cases_count_once_per_function(self):
        records = self.run_of(('p', None))
        at = records.index(event('testEnded', 'M.S/p()'))
        records[at:at] = [event('testCaseStarted', 'M.S/p()'), event('testCaseEnded', 'M.S/p()')] * 3
        self.assertEqual(self.count(records)['passed'], 1)

    def test_a_duplicate_ended_event_never_double_counts(self):
        records = self.run_of(('a', None))
        records.insert(-2, event('testEnded', 'M.S/a()'))
        self.assertEqual(self.count(records)['passed'], 1)

    def test_cancelled_and_unattributed_failures_are_failures(self):
        records = self.run_of(('a', None), ('b', None))
        records.insert(-2, event('testCancelled', 'M.S/b()'))
        records.insert(-1, event('issueRecorded', issue=dict(isKnown=False, isFailure=True)))
        self.assertEqual(self.count(records), dict(passed=1, failed=2, known_issues=0, skipped=0))

    def test_isolation_poisoned_streams_are_unavailable_never_a_count(self):
        good = self.run_of(('a', None))
        self.assertIsNone(self.count(good[:-1]))                        # no runEnded: the run never finished
        raw = ''.join(json.dumps(r) + '\n' for r in good)
        self.assertIsNone(self.count(None, raw=raw.replace('"runStarted"', '"runStarted', 1)))  # torn line
        self.assertIsNone(self.count(good + [event('testEnded', 'M.S/undeclared()')]))         # unknown id
        self.assertIsNone(self.count(None, raw=''))                      # empty / never written

    def test_xctest_lines_count_anywhere_in_a_line_and_add_to_swift_testing(self):
        console = ("Test Case '-[M.X testA]' started.\n"
                   "Test Case '-[M.X testA]' passed (0.001 seconds).\n"
                   "noise without newline Test Case '-[M.X testB]' failed (0.002 seconds).\n"
                   "Test Case '-[M.X testC]' skipped (0.000 seconds).\n"
                   "✔ Test ghost() passed after 0.001 seconds.\n")      # Swift Testing comes from the stream only
        self.assertEqual(self.count(self.run_of(('a', None)), console),
                         dict(passed=2, failed=1, known_issues=0, skipped=1))

    def test_scale_20k_functions_counted_within_budget(self):
        records = self.run_of(*[(f't{n}', None) for n in range(20_000)])
        start = time.monotonic()
        self.assertEqual(self.count(records)['passed'], 20_000)
        self.assertLess(time.monotonic() - start, 10.0)


FIXTURE_PACKAGE = '''// swift-tools-version:6.0
import PackageDescription
let package = Package(name: "Fix", platforms: [.macOS(.v15)],
  targets: [.target(name: "Fix"), .testTarget(name: "FixTests", dependencies: ["Fix"])])
'''
FIXTURE_TESTS = '''import Foundation
import Testing
import XCTest
@testable import Fix
struct S {
  @Test func passes() { #expect(one() == 1) }
  @Test func knows() { withKnownIssue { #expect(one() == 2) } }
  @Test(arguments: [1, 2, 3]) func param(_ x: Int) { #expect(x > 0) }
  @Test func noisy() { print("✔ Test refused[family-tree] noise", terminator: ""); #expect(true) }
  @Test(.disabled("fixture")) func skipped() {}
  @Test func failsOnRequest() { #expect(ProcessInfo.processInfo.environment["FIX_FAIL"] == nil) }
}
final class X: XCTestCase { func testA() { XCTAssertEqual(one(), 1) } }
'''


@unittest.skipUnless(sys.platform == "darwin" and shutil.which('swift'), "needs the real swift toolchain")
class RealSwiftTestCountTests(unittest.TestCase):
    """A real `swift test` run of a tiny package is counted exactly."""

    @classmethod
    def setUpClass(cls):
        cls.workspace = tempfile.TemporaryDirectory(prefix='gauntlet-real-', dir='/private/tmp')
        root = Path(cls.workspace.name)
        cls.binary = runner_binary(root)
        cls.package = root / 'fixture'
        (cls.package / 'Sources/Fix').mkdir(parents=True)
        (cls.package / 'Tests/FixTests').mkdir(parents=True)
        (cls.package / 'Package.swift').write_text(FIXTURE_PACKAGE)
        (cls.package / 'Sources/Fix/Fix.swift').write_text('public func one() -> Int { 1 }\n')
        (cls.package / 'Tests/FixTests/T.swift').write_text(FIXTURE_TESTS)

    @classmethod
    def tearDownClass(cls):
        cls.workspace.cleanup()

    def swift_test(self, name, fail=False):
        stream = Path(self.workspace.name) / f'{name}.jsonl'
        log = Path(self.workspace.name) / f'{name}.log'
        env = {k: v for k, v in os.environ.items() if k != 'FIX_FAIL'}
        if fail:
            env['FIX_FAIL'] = '1'
        with log.open('w') as out:
            done = subprocess.run(['swift', 'test', '--package-path', str(self.package),
                                   '--event-stream-output-path', str(stream)],
                                  stdout=out, stderr=subprocess.STDOUT, env=env, timeout=600)
        counted = subprocess.run([str(self.binary), '--count-package-output', str(stream), str(log)],
                                 text=True, capture_output=True, timeout=60)
        return done.returncode, json.loads(counted.stdout)

    def test_real_run_counts_functions_known_issues_and_xctest_exactly(self):
        code, counts = self.swift_test('clean')
        self.assertEqual(code, 0)
        # passes, param (3 cases = 1), noisy, failsOnRequest + XCTest testA; knows is known; skipped skips.
        self.assertEqual(counts, dict(passed=5, failed=0, known_issues=1, skipped=1))

    def test_real_failure_is_counted_as_failed(self):
        code, counts = self.swift_test('failing', fail=True)
        self.assertNotEqual(code, 0)
        self.assertEqual(counts, dict(passed=4, failed=1, known_issues=1, skipped=1))


if __name__ == '__main__':
    unittest.main()
