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
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

REPO = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = REPO / 'scripts/m4_run.sh'
SUMMARY = REPO / 'scripts/m4_run_summary.py'
LOCK_HELPER = REPO / 'scripts/testbed_lock.py'
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

    # Rick 2026-11-05: GREEN everything passed · AMBER only known issues /
    # blocked suites / not run · RED a failure, floor miss, inventory or build.
    @staticmethod
    def _result(status, **stage_overrides):
        stages = [dict(name=n, status='passed', known_issues=0, blocked_details=[])
                  for n in ('unit', 'regression', 'integration', 'ui')]
        for s in stages:
            s.update(stage_overrides.get(s['name'], {}))
        return dict(status=status, commit='b' * 40, stages=stages, inventory_errors=[])

    def test_gauntlet_all_passed_is_green(self):
        self.assertEqual(ms.gauntlet_verdict(self._result('passed'), 0)[0], 'GREEN')

    def test_gauntlet_known_issues_only_is_amber_with_counts(self):
        r = self._result('amber', regression=dict(status='amber', known_issues=7), ui=dict(status='not_run', reason='phase 2'))
        verdict, words = ms.gauntlet_verdict(r, 0)
        self.assertEqual(verdict, 'AMBER')
        self.assertEqual(words, '7 known issues (regression 7); ui not run (phase 2)')

    def test_gauntlet_blocked_only_is_amber_and_the_runners_words_win(self):
        r = self._result('amber', integration=dict(status='blocked', blocked_details=[{}, {}]))
        self.assertEqual(ms.gauntlet_verdict(r, 0), ('AMBER', '1 stage blocked (2 unadapted suites)'))
        r['amber_reasons'] = ['6 stages blocked (912 unadapted suites)']
        self.assertEqual(ms.gauntlet_verdict(r, 0), ('AMBER', '6 stages blocked (912 unadapted suites)'))

    def test_gauntlet_failure_beside_known_issues_is_red(self):
        r = self._result('failed', unit=dict(status='failed', reason='test failures'),
                         regression=dict(status='amber', known_issues=7))
        self.assertEqual(ms.gauntlet_verdict(r, 1), ('RED', 'unit failed: test failures'))

    def test_gauntlet_floor_miss_inventory_build_timeout_and_no_result_are_red(self):
        r = self._result('failed', regression=dict(status='failed', reason='executed count below expected floor 426'))
        self.assertEqual(ms.gauntlet_verdict(r, 1)[0], 'RED')
        r = self._result('amber'); r['inventory_errors'] = ['x']
        self.assertEqual(ms.gauntlet_verdict(r, 0)[0], 'RED')
        r = self._result('failed'); r['reason'] = 'build exit 65'
        self.assertEqual(ms.gauntlet_verdict(r, 1), ('RED', 'build exit 65'))
        self.assertEqual(ms.gauntlet_verdict(self._result('amber'), 0, timed_out=True)[0], 'RED')
        self.assertEqual(ms.gauntlet_verdict(None, 0), ('RED', 'no result.json'))
        self.assertEqual(ms.gauntlet_verdict(self._result('amber'), 1)[0], 'RED', 'a non-zero runner exit is red')

    def test_gauntlet_failed_package_build_is_red_whatever_the_stages_say(self):
        # Codex 2026-11-05 (P1): a package build that left a surviving child
        # exits 125 with contamination; Runner.swift then blocked every stage
        # and wrote AMBER. The shape Codex fed gauntlet_verdict: RED regardless.
        r = self._result('amber', unit=dict(status='blocked', reason='unreaped process contamination'),
                         regression=dict(status='blocked', reason='unreaped process contamination'))
        r['package_build_exit_code'] = 125
        r['amber_reasons'] = ['2 stages without an adapter (unit, regression)']
        self.assertEqual(ms.gauntlet_verdict(r, 0), ('RED', 'package build exit 125'))
        r = self._result('amber')
        r['build_exit_code'] = 65
        self.assertEqual(ms.gauntlet_verdict(r, 0), ('RED', 'build exit 65'))
        r = self._result('passed')
        r['package_build_exit_code'] = 0
        r['build_exit_code'] = 0
        self.assertEqual(ms.gauntlet_verdict(r, 0)[0], 'GREEN', 'exit 0 builds stay green')

    def test_gauntlet_pre_amber_result_reads_as_amber(self):
        r = self._result('incomplete', hallie=dict(status='blocked'))
        r['stages'].append(dict(name='hallie', status='blocked', blocked_details=[{}]))
        self.assertEqual(ms.gauntlet_verdict(r, 1 - 1)[0], 'AMBER')

    def test_gauntlet_cli_exits_0_green_3_amber_1_red(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / 'result.json'
            for status, extra, want in [('passed', {}, 0),
                                        ('amber', dict(regression=dict(status='amber', known_issues=7)), 3),
                                        ('failed', dict(unit=dict(status='failed', reason='x')), 1)]:
                import json as _json
                path.write_text(_json.dumps(self._result(status, **extra)))
                rc = 0 if want != 1 else 1
                done = subprocess.run([sys.executable, str(SUMMARY), '--gauntlet', str(path), str(rc), '9'],
                                      capture_output=True, text=True, timeout=30)
                self.assertEqual(done.returncode, want, done.stdout)
                self.assertTrue(done.stdout.startswith('deep: ' + {0: 'GREEN', 3: 'AMBER', 1: 'RED'}[want]))

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
        # The caller never checks the testbed out: the host does, under the lock.
        self.assertNotIn('checkout -q --detach', out)
        self.assertIn(f'the host checks out {sha} into', out)
        self.assertNotIn(f"bootout gui/$uid/com.videoscan.m4run\n", out)
        self.assertIn('launchctl bootstrap gui/', out)
        self.assertIn('<key>LimitLoadToSessionType</key><string>Aqua</string>', out)
        self.assertRegex(out, r'<key>Label</key><string>com\.videoscan\.m4run\.\d{8}_\d{6}_\d+</string>')
        self.assertRegex(out, r'install .*m4_run\.sh -> ricksm4\.local:.*/m4run/bin/\d{8}_\d{6}_\d+/m4_run\.sh')
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
        self.holders = []

    def tearDown(self):
        for fd in self.holders:
            try:
                os.close(fd)
            except OSError:
                pass
        self.home.cleanup()

    def host(self, stamp):
        return run('__host', 'ui', 'a' * 40, stamp, '--host', 'm4', env=self.env)

    def hold(self, info):
        """A live owner through the same helper the scripts use: this process opens the
        flock file, the helper flocks that fd (`hold <fd>`); the lock lives on the fd."""
        lock = self.root / 'lock'
        lock.mkdir(exist_ok=True)
        fd = os.open(str(lock / 'flock'), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
        self.holders.append(fd)
        out = subprocess.run([sys.executable, str(LOCK_HELPER), 'hold', str(fd), str(lock), info],
                             capture_output=True, text=True, pass_fds=(fd,), timeout=20).stdout.strip()
        self.assertEqual(out, 'HELD')
        return fd

    def probe(self):
        return subprocess.run([sys.executable, str(LOCK_HELPER), 'probe', str(self.root / 'lock')],
                              capture_output=True, text=True, timeout=20).stdout.strip()

    def test_free_lock_is_taken_and_released(self):
        # No testbed repo under this HOME: the host refuses under the lock
        # (it never touched a tree) and releases.
        p = self.host('s1')
        self.assertEqual(p.returncode, 4)
        log = (self.root / 'out/s1-ui/run.log').read_text()
        self.assertIn('OUTCOME REFUSED cannot add worktree', log)
        self.assertNotIn('START', log)
        self.assertEqual(self.probe(), 'FREE', 'lock left behind')
        self.assertEqual(os.readlink(self.root / 'latest'), str(self.root / 'out/s1-ui'))

    def test_live_holder_refuses_and_latest_is_untouched(self):
        self.hold('deep sha=123 since now')
        os.symlink(self.root / 'out/live', self.root / 'latest')
        p = self.host('s2')
        self.assertEqual(p.returncode, 3)
        self.assertIn('OUTCOME REFUSED busy: deep sha=123', (self.root / 'out/s2-ui/run.log').read_text())
        self.assertEqual(self.probe(), 'BUSY deep sha=123 since now', "a refused run must not touch the holder")
        self.assertEqual(os.readlink(self.root / 'latest'), str(self.root / 'out/live'))

    def test_a_dead_holders_lock_needs_no_reclaim(self):
        # The kernel freed it with the holder; leftovers of the retired
        # mkdir/rename protocol (a pid file) never block and are never "reclaimed".
        dead = self.hold('deep sha=dead')
        os.close(dead)                                            # the holder is gone: its fd closed with it
        (self.root / 'lock' / 'pid').write_text('999999')
        p = self.host('s3')
        self.assertEqual(p.returncode, 4)                        # past the lock; refused only for the missing testbed
        log = (self.root / 'out/s3-ui/run.log').read_text()
        self.assertIn('OUTCOME REFUSED cannot add worktree', log)
        self.assertNotIn('busy', log)
        self.assertNotIn('reclaim', log)
        self.assertEqual(self.probe(), 'FREE')

    def test_the_remote_probe_and_status_read_the_same_kernel_lock(self):
        # m4_run's caller-side BUSY probe runs the helper's own source over
        # ssh (lock_probe_snippet); here the snippet is executed locally.
        holder = self.hold('deep sha=abc since 10:00')
        p = run('status', '--dry-run', env=self.env)          # H_ROOT under the fake HOME
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn('/m4run/lock', p.stdout)
        snippet = p.stdout.split("+ ssh ricksm4.local <<'SH'", 1)[1].split('\n  SH', 1)[0]
        snippet = '\n'.join(line[4:] if line.startswith('    ') else line for line in snippet.splitlines())
        out = subprocess.run(['/bin/bash', '-s'], input=snippet, capture_output=True, text=True,
                             env=self.env, timeout=30).stdout
        self.assertIn('M4: RUNNING deep sha=abc since 10:00', out)
        os.close(holder)
        out = subprocess.run(['/bin/bash', '-s'], input=snippet, capture_output=True, text=True,
                             env=self.env, timeout=30).stdout
        self.assertIn('M4: idle', out)

    def test_the_lock_protocol_text_is_the_same_in_both_scripts(self):
        # One protocol (Codex 2026-11-05 P1): m4_run.sh and nightly_gauntlet.sh
        # share the testbed lock, so they carry the same take_lock/drop_lock
        # text. Drift here is a second protocol on one lock.
        def shared(path):
            text = path.read_text()
            start = text.index('take_lock() {')
            end = text.index('# ── end of the shared lock text ──')
            return text[start:end]
        self.assertEqual(shared(SCRIPT), shared(REPO / 'scripts/nightly_gauntlet.sh'))
        self.assertIn('testbed_lock.py', (REPO / 'scripts/nightly_gauntlet.sh').read_text())


FAKE_GAUNTLET_HOLD = r'''#!/bin/sh
# A deep run that announces itself, then holds the testbed until released.
echo "$$" >> "$(pwd)/fake/gauntlet_starts"
while [ -e "$(pwd)/fake/hold" ]; do sleep 0.05; done
printf 'GAUNTLET PASSED sha=%s total=9s unit=PASSED results=%s/fake/result.json publish=queued\n' \
    "$(cat fake/sha)" "$(pwd)"
exit 0
'''


class LockRaceTests(unittest.TestCase):
    """Codex 2026-11-05 (P1): owner A paused between deciding and claiming;
    contender B took the lock and started work; A resumed and also claimed it
    (first the mkdir-then-pid protocol, then the rename protocol's stale
    reclaim) — two live owners of one testbed. The lock is now a kernel flock
    (scripts/testbed_lock.py); the pause hooks hold A before claiming
    (VIDEOSCAN_TESTBED_LOCK_PAUSE) or after claiming, before answering
    (…_HELD); B's deep run holds the testbed; A resumes. Every interleaving:
    exactly one START, one deep run; a killed holder frees the lock by itself."""

    def setUp(self):
        self.home = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.home.name, 'm4run')
        self.work = self.root / 'work'
        (self.work / 'scripts').mkdir(parents=True)
        (self.work / 'fake').mkdir()
        (self.root / 'bin').mkdir()
        shutil.copy(SUMMARY, self.root / 'bin' / 'm4_run_summary.py')
        gauntlet = self.work / 'scripts' / 'run_gauntlet.sh'
        gauntlet.write_text(FAKE_GAUNTLET_HOLD)
        gauntlet.chmod(0o755)
        git = ['git', '-C', str(self.work)]
        env = dict(os.environ, HOME=self.home.name, GIT_AUTHOR_NAME='t', GIT_AUTHOR_EMAIL='t@t',
                   GIT_COMMITTER_NAME='t', GIT_COMMITTER_EMAIL='t@t')
        subprocess.run(git + ['init', '-q'], check=True, env=env)
        subprocess.run(git + ['add', '-A'], check=True, env=env)
        subprocess.run(git + ['commit', '-q', '-m', 'testbed'], check=True, env=env)
        self.sha = subprocess.run(git + ['rev-parse', 'HEAD'], check=True, env=env,
                                  capture_output=True, text=True).stdout.strip()
        (self.work / 'fake' / 'sha').write_text(self.sha[:8])
        (self.work / 'fake' / 'result.json').write_text(
            '{"status": "passed", "commit": "%s", "stages": [], "inventory_errors": []}' % self.sha)
        self.env = dict(os.environ, HOME=self.home.name)

    def tearDown(self):
        self.home.cleanup()

    def wait_for(self, predicate, what, timeout=20.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(0.05)
        raise AssertionError(f'timed out waiting for {what}')

    def host(self, stamp, **extra):
        return subprocess.Popen(['/bin/bash', str(SCRIPT), '__host', 'deep', self.sha, stamp, '--host', 'm4'],
                                env=dict(self.env, **extra), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def probe(self):
        return subprocess.run([sys.executable, str(LOCK_HELPER), 'probe', str(self.root / 'lock')],
                              capture_output=True, text=True, timeout=20).stdout.strip()

    def race(self, pause_env, stale=False):
        fake = self.work / 'fake'
        pause, hold, starts = fake / 'pause', fake / 'hold', fake / 'gauntlet_starts'
        pause.touch(); hold.touch()
        if stale:
            (self.root / 'lock').mkdir(exist_ok=True)
            (self.root / 'lock' / 'pid').write_text('999999')
            (self.root / 'lock' / 'info').write_text('999999 deep sha=dead')
        a = self.host('ra', **{pause_env: str(pause)})
        b = None
        try:
            self.wait_for(lambda: (fake / 'pause.paused').exists(), 'A at the race point')
            b = self.host('rb')
            started = lambda: len(starts.read_text().split()) if starts.exists() else 0  # noqa: E731
            self.wait_for(lambda: started() >= 1 or b.poll() is not None, 'B to decide')
            before = started()
            pause.unlink()                                           # A resumes
            # A either leaves (refused) or starts its deep run (one more start).
            self.wait_for(lambda: a.poll() is not None or started() > before, 'A to decide')
        finally:
            hold.unlink(missing_ok=True)
            for p in (a, b):
                if p is not None:
                    try:
                        p.wait(timeout=30)
                    except subprocess.TimeoutExpired:
                        p.kill(); p.wait()
        count = len(starts.read_text().split()) if starts.exists() else 0
        return a, b, count, (self.root / 'out/ra-deep/run.log').read_text(), (self.root / 'out/rb-deep/run.log').read_text()

    def test_two_contenders_never_both_own_the_lock(self):
        a, b, count, log_a, log_b = self.race('VIDEOSCAN_TESTBED_LOCK_PAUSE')
        self.assertEqual(count, 1, 'two live owners started two deep runs')
        self.assertIn('OUTCOME REFUSED busy: deep sha=', log_a)
        self.assertNotIn('START', log_a)
        self.assertIn('START', log_b)
        self.assertIn('OUTCOME GREEN', log_b)
        self.assertEqual((a.returncode, b.returncode), (3, 0))
        self.assertEqual(self.probe(), 'FREE', 'the lock must be released by its owner')
        self.assertFalse(list(self.root.glob('lock.*')), 'no answer FIFOs left behind')

    def test_a_contender_paused_over_a_stale_lock_never_reclaims_a_live_owner(self):
        # Codex 2026-11-05 re-review (P1): A found a dead pid, paused; B
        # reclaimed and started; A resumed and renamed B's live lock aside.
        a, b, count, log_a, log_b = self.race('VIDEOSCAN_TESTBED_LOCK_PAUSE', stale=True)
        self.assertEqual(count, 1, 'two live owners started two deep runs')
        self.assertIn('OUTCOME REFUSED busy: deep sha=', log_a)
        self.assertIn('OUTCOME GREEN', log_b)
        self.assertEqual((a.returncode, b.returncode), (3, 0))
        self.assertEqual(self.probe(), 'FREE')

    def test_an_owner_paused_after_claiming_refuses_the_contender(self):
        a, b, count, log_a, log_b = self.race('VIDEOSCAN_TESTBED_LOCK_PAUSE_HELD')
        self.assertEqual(count, 1)
        self.assertIn('OUTCOME GREEN', log_a)
        self.assertIn('OUTCOME REFUSED busy: deep sha=', log_b)
        self.assertEqual((a.returncode, b.returncode), (0, 3))
        self.assertEqual(self.probe(), 'FREE')

    def test_a_killed_shells_live_work_keeps_the_lock_and_frees_it_when_done(self):
        # Codex 2026-11-05 re-review 2 (P1): the host shell dies while its deep
        # run (run_bounded: own session) still works. The lock lives on the fd
        # the work inherited (run_bounded passes fd 9 on), so B is refused until
        # the work ends; then the kernel frees it and C runs, no reclaim.
        fake = self.work / 'fake'
        hold, starts = fake / 'hold', fake / 'gauntlet_starts'
        hold.touch()
        a = self.host('ka')
        try:
            self.wait_for(lambda: starts.exists(), "A's deep run")
            self.assertTrue(self.probe().startswith('BUSY deep sha='), self.probe())
            a.kill(); a.wait()
            time.sleep(0.5)                                      # the old lease would have let go by now
            self.assertTrue(self.probe().startswith('BUSY deep sha='),
                            f'the lock must outlive the shell while its work runs: {self.probe()}')
            b = self.host('kb')                                  # B, while A's work is still alive
            b.wait(timeout=60)
            self.assertEqual(b.returncode, 3)
            self.assertIn('OUTCOME REFUSED busy: deep sha=', (self.root / 'out/kb-deep/run.log').read_text())
            self.assertEqual(len(starts.read_text().split()), 1)
        finally:
            hold.unlink(missing_ok=True)
        self.wait_for(lambda: self.probe() == 'FREE', 'the kernel to drop the lock when the work ends')
        c = self.host('kc')
        c.wait(timeout=60)
        log_c = (self.root / 'out/kc-deep/run.log').read_text()
        self.assertIn('START', log_c)
        self.assertIn('OUTCOME GREEN', log_c)
        self.assertNotIn('reclaim', log_c)
        self.assertEqual(c.returncode, 0)


FAKE_LAUNCHCTL = r'''#!/usr/bin/env python3
# Stand-in for launchctl: `bootstrap gui/<uid> <plist>` starts the plist's
# ProgramArguments detached (what launchd would do) and records it; every
# call is appended to $M4RUN_TEST_LAUNCHCTL_LOG.
import os, plistlib, subprocess, sys
args = sys.argv[1:]
with open(os.environ["M4RUN_TEST_LAUNCHCTL_LOG"], "a") as f:
    f.write(" ".join(args) + "\n")
if args[:1] == ["bootstrap"]:
    with open(args[2], "rb") as f:
        plist = plistlib.load(f)
    subprocess.Popen(plist["ProgramArguments"], start_new_session=True,
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
sys.exit(0)
'''

# The deep run inside the testbed worktree: announces itself, holds until released.
FAKE_GAUNTLET_ENV_HOLD = r'''#!/bin/sh
echo "$$" >> "$M4RUN_TEST_STARTS"
while [ -e "$M4RUN_TEST_HOLD" ]; do sleep 0.05; done
printf 'GAUNTLET PASSED sha=%s total=9s unit=PASSED results=%s publish=queued\n' \
    "$(git rev-parse --short=8 HEAD)" "$M4RUN_TEST_RESULT"
exit 0
'''


class CallerMutationTests(unittest.TestCase):
    """Codex 2026-11-05 re-review 3 (P1): the caller probed FREE, then checked
    the SHA out and booted the LaunchAgent out BEFORE the host took the lock —
    a second caller could clobber a live run's worktree and agent. Now every
    mutation of the shared testbed happens on the host under the lock, and the
    caller's steps are additive (per-run bin dir, per-run agent label).

    End to end on the "ultra" host (local, no ssh): a fake launchctl starts
    the agent's command detached, as launchd would; a real git repo plays
    ~/dev/VideoScan with two commits (the fake deep run blocks until released)."""

    def setUp(self):
        self.home = tempfile.TemporaryDirectory()
        home = pathlib.Path(self.home.name)
        self.repo = home / 'dev' / 'VideoScan'
        (self.repo / 'scripts').mkdir(parents=True)
        (self.repo / 'fake').mkdir()
        for name in ('m4_run.sh', 'm4_run_summary.py', 'testbed_lock.py'):
            shutil.copy(REPO / 'scripts' / name, self.repo / 'scripts' / name)
        gauntlet = self.repo / 'scripts' / 'run_gauntlet.sh'
        gauntlet.write_text(FAKE_GAUNTLET_ENV_HOLD)
        gauntlet.chmod(0o755)
        git = ['git', '-C', str(self.repo)]
        env = dict(os.environ, HOME=self.home.name, GIT_AUTHOR_NAME='t', GIT_AUTHOR_EMAIL='t@t',
                   GIT_COMMITTER_NAME='t', GIT_COMMITTER_EMAIL='t@t')
        subprocess.run(git + ['init', '-q'], check=True, env=env)
        subprocess.run(git + ['add', '-A'], check=True, env=env)
        subprocess.run(git + ['commit', '-q', '-m', 'a'], check=True, env=env)
        self.sha_a = subprocess.run(git + ['rev-parse', 'HEAD'], check=True, env=env, capture_output=True, text=True).stdout.strip()
        (self.repo / 'fake' / 'second').write_text('b\n')
        subprocess.run(git + ['add', '-A'], check=True, env=env)
        subprocess.run(git + ['commit', '-q', '-m', 'b'], check=True, env=env)
        self.sha_b = subprocess.run(git + ['rev-parse', 'HEAD'], check=True, env=env, capture_output=True, text=True).stdout.strip()
        self.bin = home / 'bin'
        self.bin.mkdir()
        (self.bin / 'launchctl').write_text(FAKE_LAUNCHCTL)
        (self.bin / 'launchctl').chmod(0o755)
        self.test = home / 'test'
        self.test.mkdir()
        self.root = home / 'ultrarun'
        self.wt = home / 'dev' / 'VideoScan-wt' / 'ultra-testbed'
        self.launchctl_log = self.test / 'launchctl.log'
        self.launchctl_log.touch()
        (self.test / 'result.json').write_text(
            '{"status": "passed", "commit": "%s", "stages": [], "inventory_errors": []}' % self.sha_b)
        self.env = dict(os.environ, HOME=self.home.name, PATH=f"{self.bin}:{os.environ['PATH']}",
                        M4RUN_TEST_LAUNCHCTL_LOG=str(self.launchctl_log), M4RUN_TEST_HOLD=str(self.test / 'hold'),
                        M4RUN_TEST_STARTS=str(self.test / 'starts'), M4RUN_TEST_RESULT=str(self.test / 'result.json'))

    def tearDown(self):
        (self.test / 'hold').unlink(missing_ok=True)
        time.sleep(0.3)
        self.home.cleanup()

    def wait_for(self, predicate, what, timeout=30.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(0.05)
        raise AssertionError(f'timed out waiting for {what}')

    def caller(self, sha, **extra):
        return subprocess.Popen(['/bin/bash', str(self.repo / 'scripts/m4_run.sh'), 'deep', '--host', 'ultra',
                                 '--ref', sha, '--force'], env=dict(self.env, **extra),
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

    def head(self):
        return subprocess.run(['git', '-C', str(self.wt), 'rev-parse', 'HEAD'], capture_output=True, text=True).stdout.strip()

    def run_logs(self):
        return {p.parent.name: p.read_text() for p in (self.root / 'out').glob('*-deep/run.log')} if (self.root / 'out').exists() else {}

    def test_a_second_caller_never_touches_a_live_runs_tree_runner_or_agent(self):
        starts, hold, pause = self.test / 'starts', self.test / 'hold', self.test / 'pause'
        hold.touch(); pause.touch()
        a = self.caller(self.sha_a, VIDEOSCAN_M4RUN_PAUSE_AFTER_PROBE=str(pause))
        try:
            self.wait_for(lambda: (self.test / 'pause.paused').exists(), 'A past its probe')
            b = self.caller(self.sha_b)
            self.assertEqual(b.wait(timeout=60), 0, b.stdout.read())
            self.wait_for(lambda: starts.exists(), "B's deep run to start (its agent holds the lock)")
            self.assertEqual(self.head(), self.sha_b)
            runner_b = next((self.root / 'bin').glob('*/m4_run.sh'))
            runner_b_bytes, runner_b_mtime = runner_b.read_bytes(), runner_b.stat().st_mtime_ns
            log_before = self.launchctl_log.read_text()
            self.assertEqual(log_before.count('bootstrap'), 1)
            pause.unlink()                                             # A resumes with another SHA
            self.assertEqual(a.wait(timeout=60), 0, "the caller only ships; the host refuses")
            self.wait_for(lambda: any('OUTCOME REFUSED' in l for l in self.run_logs().values()), "A's agent to be refused")
            self.assertEqual(self.head(), self.sha_b, "A clobbered B's checked-out tree")
            self.assertEqual((runner_b.read_bytes(), runner_b.stat().st_mtime_ns), (runner_b_bytes, runner_b_mtime),
                             "A overwrote B's installed runner")
            log_after = self.launchctl_log.read_text()
            self.assertNotIn('bootout', log_after, "A booted out an agent while B's was live")
            self.assertEqual(log_after.count('bootstrap'), 2)
            self.assertEqual(len(starts.read_text().split()), 1, 'two deep runs on one testbed')
            refused = [l for l in self.run_logs().values() if 'OUTCOME REFUSED' in l]
            self.assertEqual(len(refused), 1)
            self.assertIn('busy: deep sha=' + self.sha_b[:9], refused[0])
        finally:
            hold.unlink(missing_ok=True)
        self.wait_for(lambda: any('OUTCOME GREEN' in l for l in self.run_logs().values()), "B's run to finish")
        self.assertEqual(self.head(), self.sha_b)
        self.assertEqual([l for l in self.run_logs().values() if 'START' in l and 'OUTCOME GREEN' in l].__len__(), 1)


if __name__ == '__main__':
    unittest.main()
