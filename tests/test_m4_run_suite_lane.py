"""scripts/m4_run.sh suite — the on-demand full app + Core suite on a test host.

Rick 2026-11-17 (DECISIONS): the idle M4 runs the full suite on demand for a
branch, not only at 14:00. The lane reuses the nightly's own runner
(scripts/nightly_local_tests.sh --on-demand: one engine) and must never write
a metrics row. These tests pin, without a host:

  * arguments, and that --dry-run prints the plan and touches nothing;
  * the caller's refusals (lock held: exit 3; nightly window: exit 5);
  * the host side for real in a fake HOME — the real m4_run.sh, the real
    nightly runner and the real summary, with stand-ins for xcodebuild, swift,
    xcrun and automationmodetool: GREEN, a failed test (named and proven
    against the worktree), zero tests, a build failure, a Core lane with no
    number, the machine preflight (NORUN), a held lock;
  * that nothing is published: git never fetches, pushes or adds a worktree,
    and the publisher / metrics / complexity / traffic scripts never run;
  * `status` reading the last suite run back, also after a later run of
    another lane; and `--wait` exiting 0 GREEN / 1 RED / 2 could-not-run.

No ssh, no real xcodebuild, no network.
"""
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

REPO = pathlib.Path(__file__).resolve().parents[1]
SCRIPTS = REPO / 'scripts'
SCRIPT = SCRIPTS / 'm4_run.sh'
SUMMARY = SCRIPTS / 'm4_run_summary.py'
LOCK_HELPER = SCRIPTS / 'testbed_lock.py'
sys.path.insert(0, str(SCRIPTS))
import m4_run_summary as ms  # noqa: E402

# Stand-ins, first on the host's PATH (VIDEOSCAN_M4RUN_TEST_PATH). Each reads
# what to do from $SUITE_FAKE and records its call in $SUITE_FAKE/calls.
FAKE_XCODEBUILD = r'''#!/bin/sh
echo "xcodebuild $*" >> "$SUITE_FAKE/calls"
case " $* " in
  *" -checkFirstLaunchStatus "*)
    [ -e "$SUITE_FAKE/die" ] && kill -9 $PPID
    if [ -e "$SUITE_FAKE/logout" ]; then
      # What launchd does at a logout of the GUI session: SIGTERM the agent's own shell (m4_run.sh
      # __host: this stand-in <- the runner <- caffeinate <- run_bounded's python <- that shell).
      # The runner is in its own session and lives on.
      pid=$PPID
      for hop in 1 2 3 4 5 6; do
        case "$(ps -o command= -p "$pid")" in *"m4_run.sh __host"*) break ;; esac
        pid=$(ps -o ppid= -p "$pid" | tr -d ' ')
      done
      echo "logout: TERM $pid $(ps -o command= -p "$pid")" >> "$SUITE_FAKE/calls"
      kill -TERM "$pid"
      sleep 1
    fi
    exit 0 ;;
  *" build-for-testing "*) echo "fake build"; exit "$(cat "$SUITE_FAKE/build_rc")" ;;
  *" test-without-building "*) cat "$SUITE_FAKE/app.log"; exit "$(cat "$SUITE_FAKE/test_rc")" ;;
esac
exit 0
'''
FAKE_SWIFT = r'''#!/bin/sh
echo "swift $*" >> "$SUITE_FAKE/calls"
cat "$SUITE_FAKE/core.log"
exit "$(cat "$SUITE_FAKE/core_rc")"
'''
FAKE_XCRUN = r'''#!/bin/sh
echo "xcrun $*" >> "$SUITE_FAKE/calls"
exit 0
'''
FAKE_AUTOMATION = r'''#!/bin/sh
cat "$SUITE_FAKE/automation"
'''
# git: record, then the real one — EXCEPT anything that syncs, commits or names the metrics
# branch or worktree, which is recorded and refused, never run. A regression of the on-demand
# gate must fail these tests, not publish from them: on 2026-11-17 a mutation check of that gate
# ran the nightly's real publish_row from here, which reset the developer Mac's real
# /tmp/nightly-metrics-wt, committed a fabricated row into it and tried six times to push it
# (the push failed only because the fake HOME had no credentials).
FAKE_GIT = r'''#!/bin/sh
echo "git $*" >> "$SUITE_FAKE/calls"
case " $* " in
  *" push "*|*" fetch "*|*" pull "*|*" commit "*|*" reset "*|*" rebase "*|*metrics*) exit 1 ;;
esac
exec /usr/bin/git "$@"
'''
# Anything that publishes or writes outside the run: running it leaves a mark.
TRIPWIRE = r'''#!/bin/sh
echo "$0 $*" >> "$SUITE_FAKE/tripped"
'''
TRIPWIRES = ('tools/publish_metrics.py', 'tools/person-eval/nightly_metrics.py', 'scripts/check_models.py',
             'scripts/complexity_baseline_nightly.py', 'scripts/repo_traffic.py', 'scripts/nightly_hallie_replay.sh',
             'scripts/nightly_hallie_voice.py', 'scripts/run_gauntlet.sh')
FAKE_LAUNCHCTL = r'''#!/usr/bin/env python3
# `bootstrap gui/<uid> <plist>` starts the plist's ProgramArguments detached, as launchd would.
import plistlib, subprocess, sys
args = sys.argv[1:]
if args[:1] == ["bootstrap"]:
    with open(args[2], "rb") as f:
        plist = plistlib.load(f)
    subprocess.Popen(plist["ProgramArguments"], start_new_session=True,
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
sys.exit(0)
'''

SWIFT_SOURCE = '''import Testing
@Suite struct LedgerTests {
    @Test func theLedgerKeepsEveryRow() {}
    @Test("A display name with spaces") func named() {}
}
final class OldStyleTests: XCTestCase {
    func testOldStyle() {}
}
'''


def app_log(passed=3, failed=(), skipped=1, xctest_passed=2):
    lines = [f"✔ Test pass{i}() passed after 0.01 seconds." for i in range(passed)]
    lines += [f"Test Case '-[VideoScanTests.OldStyleTests testOld{i}]' passed (0.010 seconds)." for i in range(xctest_passed)]
    lines += [f"➜ Test skip{i}() skipped: \"not here\"" for i in range(skipped)]
    for name in failed:
        lines.append(f"✘ Test {name} recorded an issue at X.swift:1:1: Expectation failed: false")
        lines.append(f"✘ Test {name} failed after 0.01 seconds with 1 issue.")
    total = passed + xctest_passed + len(failed)
    lines.append(f"{'✘' if failed else '✔'} Test run with {total} tests {'failed' if failed else 'passed'} after 1.0 seconds.")
    return "\n".join(lines) + "\n"


def run(*args, env=None, timeout=120):
    return subprocess.run(['/bin/bash', str(SCRIPT), *args], capture_output=True, text=True, env=env, timeout=timeout)


def probe(lock):
    return subprocess.run([sys.executable, str(LOCK_HELPER), 'probe', str(lock)],
                          capture_output=True, text=True, timeout=20).stdout.strip()


class Testbed(unittest.TestCase):
    """A fake HOME with a real git repo as the testbed worktree and the stand-ins on the host PATH."""
    HOST = 'm4'
    ROOT = 'm4run'

    def setUp(self):
        self.home_dir = tempfile.TemporaryDirectory()
        self.home = pathlib.Path(self.home_dir.name)
        self.root = self.home / self.ROOT
        self.fake = self.home / 'fake'
        self.bin = self.home / 'fakebin'
        for d in (self.root, self.fake, self.bin):
            d.mkdir()
        for name, body in (('xcodebuild', FAKE_XCODEBUILD), ('swift', FAKE_SWIFT), ('xcrun', FAKE_XCRUN),
                           ('automationmodetool', FAKE_AUTOMATION), ('git', FAKE_GIT), ('launchctl', FAKE_LAUNCHCTL)):
            (self.bin / name).write_text(body)
            (self.bin / name).chmod(0o755)
        self.plant()
        self.git_env = dict(os.environ, HOME=str(self.home), GIT_AUTHOR_NAME='t', GIT_AUTHOR_EMAIL='t@t',
                            GIT_COMMITTER_NAME='t', GIT_COMMITTER_EMAIL='t@t')
        self.env = dict(os.environ, HOME=str(self.home), SUITE_FAKE=str(self.fake),
                        VIDEOSCAN_M4RUN_TEST_PATH=str(self.bin), VIDEOSCAN_M4RUN_WAIT_POLL='1')

    def tearDown(self):
        self.home_dir.cleanup()

    def plant(self, app=None, core=None, build_rc=0, test_rc=0, core_rc=0, automation='DOES NOT REQUIRE'):
        (self.fake / 'app.log').write_text(app_log() if app is None else app)
        (self.fake / 'core.log').write_text(app_log(passed=4, skipped=0, xctest_passed=0) if core is None else core)
        (self.fake / 'build_rc').write_text(str(build_rc))
        (self.fake / 'test_rc').write_text(str(test_rc))
        (self.fake / 'core_rc').write_text(str(core_rc))
        (self.fake / 'automation').write_text(
            f"This device {automation} user authentication to enable Automation Mode.\n")

    def make_repo(self, where):
        """A git repo shaped like the checkout: a Core package dir, a test source, and tripwires."""
        (where / 'VideoScan/VideoScanCore').mkdir(parents=True)
        (where / 'VideoScan/VideoScanTests').mkdir(parents=True)
        (where / 'VideoScan/VideoScanTests/LedgerTests.swift').write_text(SWIFT_SOURCE)
        (where / 'VideoScan/VideoScanCore/Package.swift').write_text('// stand-in\n')
        for rel in TRIPWIRES:
            path = where / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(TRIPWIRE)
            path.chmod(0o755)
        git = ['/usr/bin/git', '-C', str(where)]
        subprocess.run(git + ['init', '-q'], check=True, env=self.git_env)
        subprocess.run(git + ['add', '-A'], check=True, env=self.git_env)
        subprocess.run(git + ['commit', '-q', '-m', 'testbed'], check=True, env=self.git_env)
        return subprocess.run(git + ['rev-parse', 'HEAD'], check=True, env=self.git_env,
                              capture_output=True, text=True).stdout.strip()

    def calls(self):
        path = self.fake / 'calls'
        return path.read_text().splitlines() if path.exists() else []

    def assert_nothing_published(self):
        self.assertFalse((self.fake / 'tripped').exists(),
                         (self.fake / 'tripped').read_text() if (self.fake / 'tripped').exists() else '')
        for call in self.calls():
            if call.startswith('git '):
                for word in (' push', ' fetch', ' pull', ' worktree add', ' commit', 'metrics'):
                    self.assertNotIn(word, call, 'an on-demand run must not publish or sync')
        self.assertFalse((self.home / 'Library/Logs/VideoScan/nightly-pending.jsonl').exists(),
                         'the pending-rows queue belongs to the scheduled run')


class HostSuiteLaneTests(Testbed):

    def setUp(self):
        super().setUp()
        self.work = self.root / 'work'
        self.work.mkdir()
        self.sha = self.make_repo(self.work)

    def host(self, stamp):
        p = run('__host', 'suite', self.sha, stamp, '--host', 'm4', env=self.env)
        out = self.root / 'out' / f'{stamp}-suite'
        summary = out / 'summary.txt'
        return p, (out / 'run.log').read_text(), summary.read_text() if summary.exists() else '', out

    def test_green_run_counts_both_lanes_and_publishes_nothing(self):
        p, log, summary, out = self.host('g1')
        self.assertEqual(p.returncode, 0, log)
        self.assertRegex(log, r'(?m)^START \d{4}-\d\d-\d\d \d\d:\d\d:\d\d host=M4 lane=suite sha=' + self.sha + '$')
        self.assertRegex(log, r'(?m)^OUTCOME GREEN \d{4}-\d\d-\d\d \d\d:\d\d:\d\d lane=suite sha=' + self.sha[:9] + '$')
        self.assertEqual(len([line for line in log.splitlines() if line.startswith(('START', 'OUTCOME'))]), 2)
        self.assertRegex(summary, r'suite: GREEN app 5 passed, 0 failed, 1 skipped; core 4 passed, 0 failed, 0 skipped '
                                  r'\(sha=' + self.sha[:7] + r'\w*, \d+s, log=' + str(out / 'suite.log') + r'\)')
        self.assertIn('testbed worktree clean after the run', summary)
        row = json.loads((out / 'suite-row.json').read_text())
        self.assertEqual((row['status'], row['passed'], row['core_passed'], row['core_status']), ('ok', 5, 4, 'ok'))
        self.assertEqual(row['model_smoke_status'], 'not-run')
        self.assert_nothing_published()
        # Defence in depth: the scheduled run's metrics worktree and queue are not even nameable from this run.
        self.assertFalse(list(out.glob('unused-*')), 'the unused publish paths were used')
        log_text = (out / 'suite.log').read_text()
        self.assertIn('On-demand row (not published)', log_text)
        self.assertNotIn('Publishing row', log_text)
        self.assertEqual(probe(self.root / 'lock'), 'FREE', 'lock left behind')
        self.assertEqual(os.readlink(self.root / 'latest-suite'), str(out))
        self.assertEqual(os.readlink(self.root / 'latest'), str(out))

    def test_the_runner_is_the_nightlys_with_its_own_caches_and_the_nightlys_flags(self):
        self.host('g2')
        calls = self.calls()
        build = next(c for c in calls if ' build-for-testing ' in c)
        test = next(c for c in calls if ' test-without-building ' in c)
        core = next(c for c in calls if c.startswith('swift test'))
        dd = str(self.home / 'Library/Caches/videoscan-m4run-dd-suite')
        for call in (build, test):
            self.assertIn('-configuration Release', call)
            self.assertIn(f'-derivedDataPath {dd}/app', call)
            self.assertIn('ENABLE_TESTABILITY=YES', call)
        self.assertIn('-skip-testing:VideoScanUITests', test)
        self.assertIn(f'-resultBundlePath {self.root}/out/g2-suite/suite-app.xcresult', test)
        self.assertIn(f'--package-path {self.work}/VideoScan/VideoScanCore -c release --scratch-path {dd}/core --no-parallel', core)
        for call in calls:
            self.assertNotIn('videoscan-nightly-', call, "the scheduled run's caches are not this run's")
            self.assertNotIn('/tmp/nightly-', call)

    def test_a_worktree_that_has_the_two_phase_core_lane_runs_its_own_copy_of_it(self):
        # 2026-11-20: the Core lane is scripts/core_lane.py OF THE COMMIT UNDER TEST (its quiet-machine
        # marks decide the split), not swift test --no-parallel over everything. The testbed repo above
        # has none (an older commit): that is the fallback the test before this one pins.
        lane = self.work / 'scripts/core_lane.py'
        lane.write_text('import os, sys\n'
                        'fake = os.environ["SUITE_FAKE"]\n'
                        'open(fake + "/calls", "a").write("core_lane.py " + " ".join(sys.argv[1:]) + "\\n")\n'
                        'sys.stdout.write(open(fake + "/core.log").read())\n'
                        'sys.exit(int(open(fake + "/core_rc").read()))\n')
        git = ['/usr/bin/git', '-C', str(self.work)]
        subprocess.run(git + ['add', '-A'], check=True, env=self.git_env)
        subprocess.run(git + ['commit', '-q', '-m', 'two-phase core lane'], check=True, env=self.git_env)
        self.sha = subprocess.run(git + ['rev-parse', 'HEAD'], check=True, env=self.git_env,
                                  capture_output=True, text=True).stdout.strip()
        p, log, summary, out = self.host('g3')
        self.assertEqual(p.returncode, 0, log)
        calls = self.calls()
        dd = str(self.home / 'Library/Caches/videoscan-m4run-dd-suite')
        self.assertIn(f'core_lane.py run --package-path {self.work}/VideoScan/VideoScanCore -c release --scratch-path {dd}/core', calls)
        self.assertFalse([c for c in calls if c.startswith('swift test')], 'the whole lane was serialized again')
        row = json.loads((out / 'suite-row.json').read_text())
        self.assertEqual((row['core_passed'], row['core_status']), (4, 'ok'))

    # A stand-in for scripts/xctest_shards.py OF THE COMMIT UNDER TEST (the real one: tests/test_xctest_shards.py).
    # It carries the line the nightly looks for, lays the app log down as two shards' logs and writes the summary
    # the nightly reads ($SUITE_FAKE/shards.json: the fields to change).
    FAKE_SHARDER = r'''NIGHTLY_SUMMARY_VERSION = 1
import json, os, sys
a = sys.argv[1:]
fake = os.environ["SUITE_FAKE"]
open(fake + "/calls", "a").write("xctest_shards.py " + " ".join(a) + "\n")
run_dir = a[a.index("--run-dir") + 1]
lines = open(fake + "/app.log").read().splitlines(True)
sys.stdout.write("".join(lines))        # --stream: the hosts' lines, live
half = len(lines) // 2
shards = []
for i, part in enumerate((lines[:half], lines[half:])):
    os.makedirs("%s/%04d" % (run_dir, i))
    open("%s/%04d/strand.log" % (run_dir, i), "w").write("".join(part))
    shards.append({"name": "shard-%02d" % (i + 1), "green": True, "codes": [], "problems": [], "timed_out": False,
                   "bundle_read": True, "rc": 0, "log": "%s/%04d/strand.log" % (run_dir, i)})
d = {"version": 1, "verdict": "GREEN", "jobs": int(a[a.index("--jobs") + 1]), "passed": 5, "failed": 0, "skipped": 1,
     "counts_from": "bundles", "undealable_files": 0, "failures": [], "shards": shards}
change = json.load(open(fake + "/shards.json")) if os.path.exists(fake + "/shards.json") else {}
for i, s in enumerate(change.pop("shards", [])):
    d["shards"][i].update(s)
d.update(change)
json.dump(d, open(a[a.index("--summary") + 1], "w"))
print("xctest-shards: %s: 5 passed, 0 failed, 1 skipped (ran 6 of 6)" % d["verdict"])
sys.exit(0 if d["verdict"] == "GREEN" else 1)
'''

    def commit_sharder(self):
        (self.work / 'scripts').mkdir(exist_ok=True)
        (self.work / 'scripts/xctest_shards.py').write_text(self.FAKE_SHARDER)
        git = ['/usr/bin/git', '-C', str(self.work)]
        subprocess.run(git + ['add', '-A'], check=True, env=self.git_env)
        subprocess.run(git + ['commit', '-q', '-m', 'app test shards'], check=True, env=self.git_env)
        self.sha = subprocess.run(git + ['rev-parse', 'HEAD'], check=True, env=self.git_env,
                                  capture_output=True, text=True).stdout.strip()

    def test_a_worktree_that_has_the_sharder_runs_the_app_phase_as_k_test_hosts(self):
        # 2026-11-21: the app phase is scripts/xctest_shards.py OF THE COMMIT UNDER TEST, K hosts at once.
        # The testbed repo of the tests above has none (an older commit): they pin the single-host fallback.
        self.commit_sharder()
        self.env['NIGHTLY_APP_JOBS'] = '4'
        p, log, summary, out = self.host('k1')
        self.assertEqual(p.returncode, 0, log)
        calls = self.calls()
        dd = str(self.home / 'Library/Caches/videoscan-m4run-dd-suite')
        self.assertIn(f'xctest_shards.py --products {dd}/app/Build/Products --all --stages all --jobs 4 '
                      f'--run-dir {out}/suite-app-shards/run --stream --timeout 1800 --timings {dd}-xctest-timings.json '
                      f'--summary {out}/suite-app-shards/summary.json', calls)
        self.assertFalse([c for c in calls if ' test-without-building ' in c], 'the single host ran as well')
        self.assertRegex(summary, r'suite: GREEN app 5 passed, 0 failed, 1 skipped; core 4 passed, 0 failed, 0 skipped ')
        row = json.loads((out / 'suite-row.json').read_text())
        self.assertEqual((row['status'], row['passed'], row['skipped'], row['total'], row['app_test_hosts']), ('ok', 5, 1, 6, 2))   # the two hosts that ran, of the 4 asked for
        # The file a reader tails while the phase runs (run_tests --full, `status`) is the sharder's live stream.
        # (The shards' folder is the run's scratch: the testbed's tidy removes it with the result bundles once
        # the run is summarized.) Nothing published, nothing of the scheduled run's touched (its shard folder is
        # /tmp/nightly-app-shards, its timings in ~/Library/Caches).
        self.assertEqual((out / 'suite-app-test.log').read_text(),
                         (self.fake / 'app.log').read_text() + 'xctest-shards: GREEN: 5 passed, 0 failed, 1 skipped (ran 6 of 6)\n')
        self.assertIn('4 test hosts at once', (out / 'suite.log').read_text())
        for call in calls:
            self.assertNotIn('/tmp/nightly-', call)
            self.assertNotIn('videoscan-nightly-', call)
        self.assert_nothing_published()

    def test_nightly_app_jobs_1_is_the_single_host_also_when_the_worktree_has_the_sharder(self):
        self.commit_sharder()
        self.env['NIGHTLY_APP_JOBS'] = '1'
        p, log, summary, out = self.host('k2')
        self.assertEqual(p.returncode, 0, log)
        calls = self.calls()
        self.assertFalse([c for c in calls if c.startswith('xctest_shards.py')], 'NIGHTLY_APP_JOBS=1 still sharded')
        test = [c for c in calls if ' test-without-building ' in c]
        dd = str(self.home / 'Library/Caches/videoscan-m4run-dd-suite')
        self.assertEqual(test, [
            'xcodebuild test-without-building -project VideoScan/VideoScan.xcodeproj -scheme VideoScan '
            f'-configuration Release -destination platform=macOS,arch=arm64 -derivedDataPath {dd}/app '
            f'-enableCodeCoverage YES -resultBundlePath {out}/suite-app.xcresult -skip-testing:VideoScanUITests '
            'ENABLE_TESTABILITY=YES CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGN_ENTITLEMENTS='])
        row = json.loads((out / 'suite-row.json').read_text())
        self.assertEqual((row['status'], row['passed']), ('ok', 5))
        self.assertNotIn('app_test_hosts', row)
        self.assertIn('one test host (NIGHTLY_APP_JOBS=1)', (out / 'suite.log').read_text())

    def test_a_shard_that_came_up_short_is_red_by_name_though_every_test_passed(self):
        self.commit_sharder()
        self.env['NIGHTLY_APP_JOBS'] = '4'
        (self.fake / 'shards.json').write_text(json.dumps({
            'verdict': 'RED', 'shards': [{}, {'green': False, 'codes': ['short'], 'problems': ['ran 2 of 9 tests']}]}))
        p, log, summary, out = self.host('k3')
        self.assertEqual(p.returncode, 1, log)
        self.assertIn('OUTCOME RED', log)
        self.assertIn('suite: RED shard-short:1 — app 5 passed, 0 failed, 1 skipped', summary)
        self.assertIn('App shards: RED shard-02: ran 2 of 9 tests', (out / 'suite.log').read_text())

    def test_a_failed_test_is_red_and_named_with_where_the_repo_declares_it(self):
        self.plant(app=app_log(failed=('theLedgerKeepsEveryRow()', '"A display name with spaces"', 'ghost()')), test_rc=65)
        p, log, summary, out = self.host('r1')
        self.assertEqual(p.returncode, 1, log)
        # What each failure said is repeated at the end of the runner's log, which is what the testbed keeps.
        self.assertIn('failure detail: ✘ Test theLedgerKeepsEveryRow() recorded an issue at X.swift:1:1: Expectation failed: false',
                      (out / 'suite.log').read_text())
        self.assertIn('OUTCOME RED', log)
        self.assertIn('suite: RED failed-tests:3 — app 5 passed, 3 failed, 1 skipped; core 4 passed', summary)
        self.assertIn('  failed (app): theLedgerKeepsEveryRow() — VideoScan/VideoScanTests/LedgerTests.swift:3', summary)
        self.assertIn('  failed (app): "A display name with spaces" — VideoScan/VideoScanTests/LedgerTests.swift:4', summary)
        self.assertIn('  failed (app): ghost() — NOT FOUND in the repo at this commit', summary)
        self.assert_nothing_published()

    def test_a_core_failure_turns_a_green_app_red(self):
        self.plant(core=app_log(passed=4, skipped=0, xctest_passed=0, failed=('theLedgerKeepsEveryRow()',)), core_rc=1)
        p, log, summary, _ = self.host('r2')
        self.assertEqual(p.returncode, 1, log)
        self.assertIn('suite: RED core-failed-tests:1 — app 5 passed, 0 failed, 1 skipped; core 4 passed, 1 failed', summary)
        self.assertIn('  failed (core): theLedgerKeepsEveryRow() — VideoScan/VideoScanTests/LedgerTests.swift:3', summary)

    def test_zero_app_tests_is_red(self):
        self.plant(app='** nothing ran **\n')
        p, log, summary, _ = self.host('r3')
        self.assertEqual(p.returncode, 1, log)
        self.assertIn('OUTCOME RED', log)
        self.assertIn('suite: RED zero-tests-ran:test-rc=0 — app 0 passed, 0 failed, 0 skipped', summary)

    def test_a_core_lane_with_no_number_is_red(self):
        self.plant(core='')
        p, log, summary, _ = self.host('r4')
        self.assertEqual(p.returncode, 1, log)
        self.assertIn('suite: RED core-zero-tests-ran:test-rc=0 — app 5 passed, 0 failed, 1 skipped; core 0 passed', summary)

    def test_a_build_failure_is_red_after_the_nightlys_one_clean_retry(self):
        self.plant(build_rc=65)
        p, log, summary, _ = self.host('r5')
        self.assertEqual(p.returncode, 1, log)
        self.assertIn('OUTCOME RED', log)
        self.assertIn('suite: RED build-rc:65 — app 0 passed, 0 failed, 0 skipped; core 4 passed', summary)
        self.assertEqual(len([c for c in self.calls() if ' build-for-testing ' in c]), 2)
        self.assertFalse(any(' test-without-building ' in c for c in self.calls()))
        self.assert_nothing_published()

    def test_the_machine_preflight_is_norun_not_a_test_result(self):
        self.plant(automation='REQUIRES')
        p, log, summary, _ = self.host('n1')
        self.assertEqual(p.returncode, 1, log)
        self.assertRegex(log, r'(?m)^OUTCOME NORUN .* lane=suite sha=\w+ — machine-setup:automation-mode$')
        self.assertIn('suite: NORUN machine-setup:automation-mode — nothing ran', summary)
        self.assertFalse(any(c.startswith('swift') or 'build-for-testing' in c for c in self.calls()))
        self.assert_nothing_published()

    def test_a_runner_that_leaves_no_row_is_red(self):
        (self.fake / 'die').touch()                     # the runner is killed in its preflight (the fake xcodebuild does it)
        p, log, summary, _ = self.host('r6')
        self.assertEqual(p.returncode, 1, log)
        self.assertIn('OUTCOME RED', log)
        self.assertIn('suite: RED no result row (runner exit ', summary)

    def test_a_held_lock_refuses_before_touching_anything(self):
        lock = self.root / 'lock'
        lock.mkdir()
        fd = os.open(str(lock / 'flock'), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
        try:
            held = subprocess.run([sys.executable, str(LOCK_HELPER), 'hold', str(fd), str(lock), 'nightly testbed since 14:00'],
                                  capture_output=True, text=True, pass_fds=(fd,), timeout=20).stdout.strip()
            self.assertEqual(held, 'HELD')
            p, log, _, _ = self.host('b1')
            self.assertEqual(p.returncode, 3)
            self.assertIn('OUTCOME REFUSED busy: nightly testbed since 14:00', log)
            self.assertNotIn('START', log)
            self.assertFalse((self.root / 'latest-suite').exists())
            self.assertEqual(self.calls(), [], 'a refused run ran something')
        finally:
            os.close(fd)

    def test_status_shows_the_last_suite_run_also_after_another_lane(self):
        _, _, _, out = self.host('s1')
        status = run('status', '--host', 'm4', '--dry-run', env=self.env).stdout
        snippet = status.split("+ ssh ricksm4.local <<'SH'", 1)[1].split('\n  SH', 1)[0]
        snippet = '\n'.join(line[4:] if line.startswith('    ') else line for line in snippet.splitlines())

        def read_back():
            return subprocess.run(['/bin/bash', '-s'], input=snippet, capture_output=True, text=True,
                                  env=self.env, timeout=30).stdout
        text = read_back()
        self.assertIn(f'last run: {out}', text)
        self.assertIn('OUTCOME GREEN', text)
        self.assertIn('suite: GREEN app 5 passed, 0 failed, 1 skipped; core 4 passed, 0 failed, 0 skipped', text)
        self.assertNotIn('last suite run:', text, 'said twice when the last run IS the suite run')
        # A later run of another lane (refused here for a dirty tree, which is enough to repoint `latest`).
        (self.work / 'VideoScan/VideoScanCore/Package.swift').write_text('// edited\n')
        later = run('__host', 'ui', self.sha, 's2', '--host', 'm4', env=self.env)
        self.assertEqual(later.returncode, 4)
        text = read_back()
        self.assertIn(f'last run: {self.root}/out/s2-ui', text)
        self.assertIn(f'last suite run: {out}', text)
        self.assertIn('  START', text)
        self.assertIn('suite: GREEN app 5 passed', text)
        self.assertNotIn('step:', text, 'progress lines belong to a live run only')

    def test_status_of_a_live_suite_run_shows_the_step_and_the_tests_finished(self):
        out = self.root / 'out' / 'live-suite'
        out.mkdir(parents=True)
        (out / 'run.log').write_text(f'START 2026-11-17 17:33:58 host=M4 lane=suite sha={self.sha}\n')
        (out / 'suite.log').write_text('[17:33:58] Core results: 4p / 0f / 0s\n[17:40:00] Core lane machine: load 3\n'
                                       '[17:41:00] Running ALL tests (Release) with coverage...\n')
        (out / 'suite-core-test.log').write_text(app_log(passed=4, skipped=0, xctest_passed=0))
        (out / 'suite-app-test.log').write_text(app_log(passed=3, failed=('x()',)))
        os.symlink(out, self.root / 'latest')
        status = run('status', '--host', 'm4', '--dry-run', env=self.env).stdout
        snippet = status.split("+ ssh ricksm4.local <<'SH'", 1)[1].split('\n  SH', 1)[0]
        snippet = '\n'.join(line[4:] if line.startswith('    ') else line for line in snippet.splitlines())
        text = subprocess.run(['/bin/bash', '-s'], input=snippet, capture_output=True, text=True, env=self.env, timeout=30).stdout
        self.assertIn('  step: [17:41:00] Running ALL tests (Release) with coverage...', text)
        self.assertIn('  core tests finished so far: 4', text)
        self.assertIn('  app tests finished so far: 6', text)


class SuiteVerdictTests(unittest.TestCase):
    """m4_run_summary.suite_verdict: the row's verdict, and a lane without a number is RED."""

    ROW = dict(status='ok', reason='', commit='abc1234', passed=10, failed=0, skipped=2, total=12,
               core_status='ok', core_reason='', core_passed=5, core_failed=0, core_skipped=0, core_total=5)

    def row(self, **changes):
        row = dict(self.ROW)
        for key, value in changes.items():
            if value is None:
                row.pop(key, None)
            else:
                row[key] = value
        return row

    def test_green_needs_both_lanes_counted_and_exit_zero(self):
        self.assertEqual(ms.suite_verdict(self.row(), 0), ('GREEN', ''))
        self.assertEqual(ms.suite_verdict(self.row(), 1), ('RED', 'runner exit 1'))

    def test_zero_tests_or_no_number_is_red_whatever_the_status_says(self):
        self.assertEqual(ms.suite_verdict(self.row(passed=0, total=0), 0), ('RED', 'app lane ran zero tests'))
        self.assertEqual(ms.suite_verdict(self.row(core_passed=0, core_total=0), 0), ('RED', 'core lane ran zero tests'))
        self.assertEqual(ms.suite_verdict(self.row(core_passed=None), 0), ('RED', 'core lane has no count'))
        self.assertEqual(ms.suite_verdict(self.row(passed='many'), 0), ('RED', 'app lane has no count'))
        self.assertEqual(ms.suite_verdict(self.row(core_status='not-run', core_reason='lane-not-reached'), 0),
                         ('RED', 'core-lane-not-reached'))

    def test_failures_build_timeout_and_no_row_are_red(self):
        self.assertEqual(ms.suite_verdict(self.row(status='failed', reason='failed-tests:2', failed=2), 1),
                         ('RED', 'failed-tests:2'))
        self.assertEqual(ms.suite_verdict(self.row(failed=1), 0), ('RED', 'app failed-tests:1'))
        self.assertEqual(ms.suite_verdict(self.row(status='failed', reason='build-rc:65', passed=0, total=0), 1),
                         ('RED', 'build-rc:65'))
        self.assertEqual(ms.suite_verdict(self.row(), 124, timed_out=True), ('RED', 'watchdog timeout'))
        self.assertEqual(ms.suite_verdict(None, 137), ('RED', 'no result row (runner exit 137)'))

    def test_machine_setup_is_norun(self):
        row = self.row(status='failed', reason='machine-setup:xcode-first-launch', passed=0, total=0)
        self.assertEqual(ms.suite_verdict(row, 1), ('NORUN', 'machine-setup:xcode-first-launch'))

    def test_names_reduce_to_what_the_sources_declare(self):
        for name, want in (('bar()', ('func', 'bar')), ('Suite.bar()', ('func', 'bar')), ('Suite/bar(x:y:)', ('func', 'bar')),
                           ('-[VideoScanTests.Old testBar]', ('func', 'testBar')), ('"A name (with) dots."', ('text', 'A name (with) dots.'))):
            self.assertEqual(ms.name_token(name), want, name)

    def test_cli_exits_0_green_1_red_4_norun_and_caps_the_names(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / 'row.json'
            for row, rc, want, word in ((self.row(), 0, 0, 'GREEN'),
                                        (self.row(status='failed', reason='failed-tests:40', failed=40,
                                                  failed_names=[f't{i}()' for i in range(40)]), 1, 1, 'RED'),
                                        (self.row(status='failed', reason='machine-setup:metal-toolchain'), 1, 4, 'NORUN')):
                path.write_text(json.dumps(row))
                done = subprocess.run([sys.executable, str(SUMMARY), '--suite', str(path), str(rc), '7', '--log', '/x/suite.log'],
                                      capture_output=True, text=True, timeout=60)
                self.assertEqual(done.returncode, want, done.stdout)
                self.assertTrue(done.stdout.startswith(f'suite: {word}'), done.stdout)
                self.assertIn('(sha=abc1234, 7s, log=/x/suite.log)', done.stdout.splitlines()[0])
                if word == 'RED':
                    self.assertEqual(len(done.stdout.splitlines()), 1 + ms.NAMES_PROVEN + 1)
                    self.assertIn('… +15 more (see the log)', done.stdout)
            missing = subprocess.run([sys.executable, str(SUMMARY), '--suite', str(pathlib.Path(tmp) / 'none.json'), '0', '1'],
                                     capture_output=True, text=True, timeout=60)
            self.assertEqual(missing.returncode, 1, 'no row is red')
            self.assertIn('suite: RED no result row', missing.stdout)


class ArgumentAndDryRunTests(unittest.TestCase):

    def test_usage_errors_exit_2(self):
        for args in (['suite', 'extra'], ['suite', '--only', 'X'], ['suite', '--host', 'm9'],
                     ['suite', '--ref', 'no-such-ref-xyz', '--dry-run'], ['suite', '--publish'], ['__host', 'suite', 'a' * 40]):
            with self.subTest(args=args):
                self.assertEqual(run(*args).returncode, 2, args)

    def test_dry_run_prints_the_plan_and_touches_nothing(self):
        sha = subprocess.run(['git', '-C', str(REPO), 'rev-parse', 'HEAD'], capture_output=True, text=True).stdout.strip()
        with tempfile.TemporaryDirectory() as home:
            p = run('suite', '--host', 'm4', '--ref', 'HEAD', '--wait', '--dry-run', env=dict(os.environ, HOME=home))
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertEqual(os.listdir(home), [], 'a dry run wrote something')
        out = p.stdout
        self.assertIn(f'm4_run: suite on M4 at {sha[:9]}', out)
        self.assertIn(f'push -q ricksm4.local:dev/VideoScan {sha}:refs/m4run/{sha}', out)
        self.assertIn('refuse early with exit 3 if a live run holds it', out)
        self.assertIn('refuse with exit 5 between 01:30 and 06:00 host time unless --force', out)
        self.assertRegex(out, r'install .*/scripts/nightly_local_tests\.sh -> ricksm4\.local:.*/m4run/bin/\d{8}_\d{6}_\d+/nightly_local_tests\.sh')
        self.assertRegex(out, r'install .*/scripts/lib/process_group_watchdog\.sh -> ricksm4\.local:.*/bin/\d{8}_\d{6}_\d+/lib/process_group_watchdog\.sh')
        self.assertRegex(out, r'nightly_local_tests\.sh --on-demand \S+/m4run/out/\S+-suite --repo \S+/m4run/work '
                              r'--dd \S+/Library/Caches/videoscan-m4run-dd-suite: nothing published')
        for arg in ('__host', 'suite', sha, '--host', 'm4'):
            self.assertIn(f'<string>{arg}</string>', out)
        self.assertNotIn('--machine', out, 'the suite lane is not the gauntlet')

    def test_the_lane_never_passes_a_publish_or_metrics_flag(self):
        # The only way the lane starts the nightly's runner is --on-demand; in that mode every
        # publishing step is gated (HostSuiteLaneTests proves it by running). Pin the call text too.
        text = SCRIPT.read_text()
        start = text.index('host_suite() {')
        body = text[start:text.index('\n}\n', start)]
        self.assertIn('nightly_local_tests.sh" --on-demand "$OUT" --repo "$H_WT" --dd "$H_SUITE_DD"', body)
        for word in ('publish', 'metrics', 'run_gauntlet', '--away', 'nightly_gauntlet', 'nightly_guarded'):
            self.assertNotIn(word, body)
        p = run('suite', '--host', 'ultra', '--ref', 'HEAD', '--dry-run')
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertNotIn('ssh ', p.stdout)
        self.assertNotIn('push', p.stdout)
        self.assertNotIn('runs as --machine m5', p.stdout)
        self.assertIn('videoscan-ultrarun-dd-suite', p.stdout)

    def test_the_nightly_runner_refuses_half_an_on_demand_command(self):
        nightly = SCRIPTS / 'nightly_local_tests.sh'
        with tempfile.TemporaryDirectory() as home:
            env = dict(os.environ, HOME=home)
            for args in (['--on-demand', home], ['--repo', home], ['--on-demand', home + '/none', '--repo', home, '--dd', home],
                         ['--publish'], ['--on-demand']):
                with self.subTest(args=args):
                    p = subprocess.run(['/bin/bash', str(nightly), *args], capture_output=True, text=True, env=env, timeout=30)
                    self.assertEqual(p.returncode, 2, p.stderr)
            self.assertEqual(os.listdir(home), [], 'a refused command wrote something (a log, a cache)')


class CallerTests(Testbed):
    """The caller end to end on the "ultra" host (local, no ssh): a fake launchctl starts the
    agent as launchd would; a real git repo plays ~/dev/VideoScan."""
    HOST = 'ultra'
    ROOT = 'ultrarun'

    def setUp(self):
        super().setUp()
        self.repo = self.home / 'dev' / 'VideoScan'
        self.repo.mkdir(parents=True)
        (self.repo / 'scripts/lib').mkdir(parents=True)
        for name in ('m4_run.sh', 'm4_run_summary.py', 'testbed_lock.py', 'testbed_host.py', 'nightly_local_tests.sh',
                     'lib/process_group_watchdog.sh'):
            shutil.copy(SCRIPTS / name, self.repo / 'scripts' / name)
        self.sha = self.make_repo(self.repo)
        self.env['PATH'] = f"{self.bin}:{os.environ['PATH']}"       # the caller's launchctl and date

    def caller(self, *extra):
        return subprocess.run(['/bin/bash', str(self.repo / 'scripts/m4_run.sh'), 'suite', '--host', 'ultra',
                               '--ref', self.sha, *extra], capture_output=True, text=True, env=self.env, timeout=180)

    def set_host_clock(self, hhmm):
        (self.bin / 'date').write_text(f'#!/bin/sh\n[ "$1" = "+%H%M" ] && {{ echo {hhmm}; exit 0; }}\nexec /bin/date "$@"\n')
        (self.bin / 'date').chmod(0o755)

    def runs(self):
        return sorted((self.root / 'out').glob('*-suite')) if (self.root / 'out').exists() else []

    def test_wait_exits_0_on_green_and_shows_the_verdict(self):
        self.set_host_clock('1730')
        p = self.caller('--wait')
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn('OUTCOME GREEN', p.stdout)
        self.assertIn('suite: GREEN app 5 passed, 0 failed, 1 skipped; core 4 passed, 0 failed, 0 skipped', p.stdout)
        out = self.runs()[0]
        stamp = out.name[:-len('-suite')]
        # The host ran the runner the CALLER installed, not one from the commit under test.
        self.assertTrue((self.root / 'bin' / stamp / 'nightly_local_tests.sh').exists())
        self.assertTrue((self.root / 'bin' / stamp / 'lib/process_group_watchdog.sh').exists())
        testbed = pathlib.Path(os.path.realpath(self.home)) / 'dev/VideoScan-wt/ultra-testbed'
        self.assertTrue(any(c.startswith('swift test --package-path ') and c.split()[3] in
                            (f'{testbed}/VideoScan/VideoScanCore', f'{self.home}/dev/VideoScan-wt/ultra-testbed/VideoScan/VideoScanCore')
                            for c in self.calls()), self.calls())
        self.assert_nothing_published_by_the_run()
        self.assertEqual(probe(self.root / 'lock'), 'FREE')

    def assert_nothing_published_by_the_run(self):
        self.assertFalse((self.fake / 'tripped').exists())
        for call in self.calls():
            if call.startswith('git '):
                for word in (' push', ' fetch', ' pull', ' commit', 'metrics'):
                    self.assertNotIn(word, call)

    def test_wait_exits_1_on_red(self):
        self.set_host_clock('1730')
        self.plant(app=app_log(failed=('theLedgerKeepsEveryRow()',)), test_rc=65)
        p = self.caller('--wait')
        self.assertEqual(p.returncode, 1, p.stdout + p.stderr)
        self.assertIn('OUTCOME RED', p.stdout)
        self.assertIn('failed (app): theLedgerKeepsEveryRow() — VideoScan/VideoScanTests/LedgerTests.swift:3', p.stdout)

    def test_wait_exits_2_when_the_run_could_not_run(self):
        self.set_host_clock('1730')
        self.plant(automation='REQUIRES')
        p = self.caller('--wait')
        self.assertEqual(p.returncode, 2, p.stdout + p.stderr)
        self.assertIn('OUTCOME NORUN', p.stdout)

    def test_a_run_whose_shell_is_stopped_ends_the_wait_with_exit_2_not_a_six_hour_poll(self):
        # RED 2026-11-17, the first real run: the M4's console session logged out 55 minutes in; launchd
        # SIGTERMed the agent's shell, so no OUTCOME was ever written and --wait polled on for its budget.
        self.set_host_clock('1730')
        (self.fake / 'logout').touch()
        p = self.caller('--wait')
        self.assertEqual(p.returncode, 2, p.stdout + p.stderr)
        self.assertIn('ended without an OUTCOME', p.stderr)
        self.assertIn('ENDED WITHOUT AN OUTCOME', p.stdout)
        log = (self.runs()[0] / 'run.log').read_text()
        self.assertIn('START', log)
        self.assertNotIn('OUTCOME', log)
        self.assertEqual(probe(self.root / 'lock'), 'FREE')

    def test_the_nightly_window_refuses_with_exit_5_and_starts_nothing(self):
        self.set_host_clock('0200')
        p = self.caller('--wait')
        self.assertEqual(p.returncode, 5, p.stdout + p.stderr)
        self.assertIn('pass --force to run anyway', p.stderr)
        self.assertEqual(self.runs(), [])
        self.assertFalse((self.root / 'bin').exists(), 'a refused run installed a runner')
        self.assertEqual([c for c in self.calls() if not c.startswith('git ')], [])

    def test_a_held_lock_refuses_with_exit_3_and_starts_nothing(self):
        self.set_host_clock('1730')
        lock = self.root / 'lock'
        lock.mkdir()
        fd = os.open(str(lock / 'flock'), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
        try:
            subprocess.run([sys.executable, str(LOCK_HELPER), 'hold', str(fd), str(lock), 'nightly testbed (suite + gauntlet) since 14:00'],
                           capture_output=True, text=True, pass_fds=(fd,), timeout=20)
            p = self.caller('--wait')
            self.assertEqual(p.returncode, 3, p.stdout + p.stderr)
            self.assertIn('is busy: nightly testbed (suite + gauntlet) since 14:00', p.stderr)
            self.assertEqual(self.runs(), [])
            self.assertFalse((self.root / 'bin').exists())
        finally:
            os.close(fd)


if __name__ == '__main__':
    unittest.main()
