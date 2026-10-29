"""scripts/m4_run.sh + scripts/m4_run_summary.py — the on-demand test-host runner.

Rick (2026-10-29) wants "run the gauntlet UI tests on the M4" from his phone to
be one command. These tests pin what can be pinned without a host: argument
parsing, what --dry-run says it will do for each host, the host-side lock
(busy refusal, stale reclaim, `latest` untouched by a refused run), and the
one-line plan summary (a zero-test or timed-out plan is RED). Nothing here
runs ssh, git push, launchctl or xcodebuild.
"""
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = REPO / 'scripts/m4_run.sh'
SUMMARY = REPO / 'scripts/m4_run_summary.py'
sys.path.insert(0, str(SUMMARY.parent))
import m4_run_summary as ms  # noqa: E402

LOG_MIXED = """
Test Case '-[VideoScanUITests.Gauntlet06TabClicksUITests testFamilyTreeTabOpens]' started.
Test Case '-[VideoScanUITests.Gauntlet06TabClicksUITests testFamilyTreeTabOpens]' passed (12.250 seconds).
Test Case '-[VideoScanUITests.Gauntlet02CatalogSearchUITests testSearch]' failed (31.000 seconds).
Test Case '-[VideoScanUITests.Gauntlet07FamilyMapUITests testWalkTreeOpensTheFamilyMap]' passed (40.125 seconds).
Test Case '-[VideoScanUITests.Gauntlet01PersonSearchUITests testFind]' skipped (0.010 seconds).
** TEST EXECUTE FAILED **
"""


def run(*args, env=None):
    return subprocess.run(['/bin/bash', str(SCRIPT), *args], capture_output=True, text=True,
                          env=env, timeout=60)


class SummaryTests(unittest.TestCase):

    def test_counts_names_and_seconds(self):
        rows = ms.parse(LOG_MIXED)
        self.assertEqual([r[1] for r in rows if r[0] == 'failed'], ['Gauntlet02CatalogSearchUITests.testSearch'])
        self.assertIn(('passed', 'Gauntlet07FamilyMapUITests.testWalkTreeOpensTheFamilyMap', 40.125), rows)
        green, line = ms.summarize('VideoScan-Gauntlet', rows, 65, 90, False)
        self.assertFalse(green)
        self.assertEqual(line, 'VideoScan-Gauntlet: RED 2 passed, 1 failed, 1 skipped, rc=65, 90s; '
                               'failing: Gauntlet02CatalogSearchUITests.testSearch')

    def test_green_needs_rc_zero_no_failures_and_a_pass(self):
        rows = [('passed', 'A.testOne', 1.0)]
        self.assertTrue(ms.summarize('P', rows, 0, 5, False)[0])
        self.assertFalse(ms.summarize('P', rows, 65, 5, False)[0], 'non-zero xcodebuild exit is red')

    def test_zero_tests_is_red(self):
        green, line = ms.summarize('VideoScan-UI', [], 0, 3, False)
        self.assertFalse(green)
        self.assertIn('no test ran', line)

    def test_timeout_is_red_and_says_so(self):
        green, line = ms.summarize('VideoScan-UI', [('passed', 'A.t', 1.0)], 124, 1200, True)
        self.assertFalse(green)
        self.assertTrue(line.startswith('VideoScan-UI: RED TIMEOUT after 1200s'))

    def test_cli_writes_the_table_and_exits_by_verdict(self):
        with tempfile.TemporaryDirectory() as d:
            log = pathlib.Path(d, 'plan.log')
            log.write_text(LOG_MIXED)
            tsv = pathlib.Path(d, 'plan.tsv')
            p = subprocess.run([sys.executable, str(SUMMARY), 'VideoScan-Gauntlet', str(log), '65', '90',
                                '--tsv', str(tsv)], capture_output=True, text=True)
            self.assertEqual(p.returncode, 1)
            self.assertIn('RED 2 passed, 1 failed', p.stdout)
            self.assertEqual(len(tsv.read_text().splitlines()), 4)
            missing = subprocess.run([sys.executable, str(SUMMARY), 'P', str(pathlib.Path(d, 'none.log')),
                                      '0', '1'], capture_output=True, text=True)
            self.assertEqual(missing.returncode, 1, 'a missing log is a zero-test run: red')


class ArgumentTests(unittest.TestCase):

    def test_usage_errors_exit_2(self):
        for args in ([], ['bogus'], ['ui', '--host', 'm9'], ['deep', '--only', 'X'],
                     ['ui', '--plan-timeout', 'soon'], ['ui', '--only', 'X;rm'], ['ui', 'extra'],
                     ['ui', '--ref', 'no-such-ref-xyz', '--dry-run']):
            with self.subTest(args=args):
                self.assertEqual(run(*args).returncode, 2, args)


class DryRunTests(unittest.TestCase):

    def test_ui_on_m4_ships_the_commit_and_bootstraps_a_gui_agent(self):
        sha = subprocess.run(['git', '-C', str(REPO), 'rev-parse', 'HEAD'], capture_output=True,
                             text=True).stdout.strip()
        p = run('ui', '--host', 'm4', '--ref', 'HEAD', '--only', 'Gauntlet07FamilyMapUITests', '--dry-run')
        self.assertEqual(p.returncode, 0, p.stderr)
        out = p.stdout
        self.assertIn(f'push -q ricksm4.local:dev/VideoScan {sha}:refs/m4run/{sha}', out)
        self.assertIn('+ ssh ricksm4.local', out)
        self.assertIn(f"checkout -q --detach '{sha}'", out)
        self.assertIn('launchctl bootstrap gui/', out)
        self.assertIn('<key>LimitLoadToSessionType</key><string>Aqua</string>', out)
        for arg in ('__host', 'ui', sha, '--host', 'm4', '--only', 'Gauntlet07FamilyMapUITests'):
            self.assertIn(f'<string>{arg}</string>', out)
        self.assertIn('/m4run/work', out)

    def test_deep_on_the_ultra_stays_local_and_says_it_runs_as_m5(self):
        p = run('deep', '--host', 'ultra', '--ref', 'HEAD', '--dry-run')
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertNotIn('ssh ', p.stdout)
        self.assertNotIn('push', p.stdout)
        self.assertIn('VideoScan-wt/ultra-testbed', p.stdout)
        self.assertIn('--machine m5 --queue-only', p.stdout)
        self.assertIn('com.videoscan.ultrarun', p.stdout)

    def test_status_dry_run_prints_the_probe(self):
        p = run('status', '--dry-run')
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn('/m4run/lock', p.stdout)


class HostLockTests(unittest.TestCase):
    """The host side in a fake HOME with no testbed: it must take the lock,
    report RED (testbed not at the commit) and release the lock."""

    def setUp(self):
        self.home = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.home.name, 'm4run')
        self.root.mkdir()
        self.env = dict(os.environ, HOME=self.home.name)

    def tearDown(self):
        self.home.cleanup()

    def host(self, stamp):
        return run('__host', 'ui', 'a' * 40, stamp, '--host', 'm4', env=self.env)

    def test_free_lock_is_taken_and_released(self):
        p = self.host('s1')
        self.assertEqual(p.returncode, 1)
        log = (self.root / 'out/s1-ui/run.log').read_text()
        self.assertIn('START', log)
        self.assertIn('OUTCOME RED testbed', log)
        self.assertFalse((self.root / 'lock').exists(), 'lock left behind')
        self.assertEqual(os.readlink(self.root / 'latest'), str(self.root / 'out/s1-ui'))

    def test_live_holder_refuses_and_latest_is_untouched(self):
        lock = self.root / 'lock'
        lock.mkdir()
        (lock / 'pid').write_text(str(os.getpid()))
        (lock / 'info').write_text('deep sha=123 since now')
        os.symlink(self.root / 'out/live', self.root / 'latest')
        p = self.host('s2')
        self.assertEqual(p.returncode, 3)
        self.assertIn('OUTCOME REFUSED busy: deep sha=123', (self.root / 'out/s2-ui/run.log').read_text())
        self.assertTrue((lock / 'pid').exists(), "a refused run must not drop the holder's lock")
        self.assertEqual(os.readlink(self.root / 'latest'), str(self.root / 'out/live'))

    def test_dead_holder_lock_is_reclaimed(self):
        dead = subprocess.Popen(['/usr/bin/true'])
        dead.wait()
        lock = self.root / 'lock'
        lock.mkdir()
        (lock / 'pid').write_text(str(dead.pid))
        p = self.host('s3')
        self.assertEqual(p.returncode, 1)
        log = (self.root / 'out/s3-ui/run.log').read_text()
        self.assertIn('reclaiming a stale lock', log)
        self.assertFalse(lock.exists())


if __name__ == '__main__':
    unittest.main()
