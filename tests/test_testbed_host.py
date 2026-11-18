"""scripts/testbed_host.py — housekeeping on a test host, and its hooks in scripts/m4_run.sh.

  prune         at the start of every lane, under the lock: the newest N runs of each
                lane, every RED run and whatever `latest*` names stay; the rest go with
                their bin folder and agent plist. Nothing that is not a run folder, no
                symlink and nothing outside the root is touched.
  the window    an on-demand lane refuses to START inside the quiet window before a
                scheduled run (the M4's 14:00 testbed does not wait for the lock);
                configurable in <root>/testbed.conf; --force overrides.
  status --json one JSON object: the lock and the last / last suite / last testbed run.

Everything runs in a temporary folder; no ssh, no host.
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
sys.path.insert(0, str(SCRIPTS))
sys.path.insert(0, str(REPO / 'tests'))
import testbed_host as th  # noqa: E402
from test_m4_run_suite_lane import Testbed  # noqa: E402


class Root:
    """A fake <root>: run folders with a run.log, bin folders and plists, each with a set age."""

    def __init__(self, tmp, name='m4run'):
        self.root = pathlib.Path(tmp, name)
        (self.root / 'out').mkdir(parents=True)
        (self.root / 'bin').mkdir()
        self.clock = time.time() - 10 * 86400

    def run(self, stamp, lane, outcome='GREEN', size=1000, bin_dir=True):
        self.clock += 60
        path = self.root / 'out' / f'{stamp}-{lane}'
        path.mkdir()
        log = f'START 2026-11-17 10:00:00 host=M4 lane={lane} sha={"a" * 40}\n'
        if outcome:
            log += f'OUTCOME {outcome} 2026-11-17 11:00:00 lane={lane} sha=aaaaaaaaa\n'
        (path / 'run.log').write_text(log)
        (path / 'payload.xcresult').write_bytes(b'x' * size)
        if bin_dir:
            (self.root / 'bin' / stamp).mkdir(exist_ok=True)
            (self.root / 'bin' / stamp / 'm4_run.sh').write_text('#\n')
            (self.root / f'com.videoscan.m4run.{stamp}.plist').write_text('<plist/>')
        for p in (path, self.root / 'bin' / stamp, self.root / f'com.videoscan.m4run.{stamp}.plist'):
            if p.exists():
                os.utime(p, (self.clock, self.clock))
        return path

    def names(self):
        return sorted(p.name for p in (self.root / 'out').iterdir())


class PruneTests(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.scene = Root(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_the_newest_n_of_each_lane_and_every_red_run_stay(self):
        for i in range(6):
            self.scene.run(f's{i}', 'suite', 'RED' if i == 1 else 'GREEN')
        for i in range(3):
            self.scene.run(f'c{i}', 'corpus', 'AMBER')
        line = th.prune(str(self.scene.root), keep=2)
        self.assertEqual(self.scene.names(), ['c1-corpus', 'c2-corpus', 's1-suite', 's4-suite', 's5-suite'])
        self.assertRegex(line, r'^prune: removed 4 run folders \(0\.0 GB\), kept 5 \(newest 2 per lane, 1 RED, 0 pinned\)$')
        # A removed run takes its bin folder and plist with it; a kept one keeps both.
        self.assertEqual(sorted(p.name for p in (self.scene.root / 'bin').iterdir()), ['c1', 'c2', 's1', 's4', 's5'])
        self.assertEqual(sorted(p.name for p in self.scene.root.glob('*.plist')),
                         [f'com.videoscan.m4run.{s}.plist' for s in ('c1', 'c2', 's1', 's4', 's5')])
        self.assertEqual(th.prune(str(self.scene.root), keep=2).split(',')[0], 'prune: removed 0 run folders (0.0 GB)')

    def test_whatever_latest_names_and_the_current_run_are_never_removed(self):
        old_suite = self.scene.run('s0', 'suite')
        old_testbed = self.scene.run('t0', 'testbed')
        for i in range(1, 5):
            self.scene.run(f's{i}', 'suite')
            self.scene.run(f't{i}', 'testbed')
        current = self.scene.run('s9', 'suite', outcome=None)
        os.symlink(old_suite, self.scene.root / 'latest-suite')
        os.symlink(old_testbed, self.scene.root / 'latest-testbed')
        os.symlink(current, self.scene.root / 'latest')
        line = th.prune(str(self.scene.root), current=str(current), keep=1)
        self.assertEqual(self.scene.names(), ['s0-suite', 's9-suite', 't0-testbed', 't4-testbed'])
        self.assertIn('2 pinned', line)

    def test_only_run_folders_are_ever_touched(self):
        for i in range(4):
            self.scene.run(f's{i}', 'suite')
        out = self.scene.root / 'out'
        precious = pathlib.Path(self.tmp.name, 'elsewhere')
        precious.mkdir()
        (precious / 'keep.txt').write_text('keep')
        (out / 'notes.txt').write_text('a file')
        (out / 'something-else').mkdir()
        (out / 'x-unknownlane').mkdir()
        os.symlink(precious, out / 'a0-suite')                       # a symlink named like the oldest run
        os.symlink(precious, self.scene.root / 'bin' / 'zz')
        th.prune(str(self.scene.root), keep=1)
        self.assertEqual(self.scene.names(), ['a0-suite', 'notes.txt', 's3-suite', 'something-else', 'x-unknownlane'])
        self.assertEqual((precious / 'keep.txt').read_text(), 'keep', 'a symlink was followed')
        self.assertTrue((self.scene.root / 'bin' / 'zz').is_symlink())

    def test_a_bin_folder_with_no_run_yet_is_left_alone_until_it_is_a_day_old(self):
        self.scene.run('s0', 'suite')
        fresh = self.scene.root / 'bin' / 'queued'
        fresh.mkdir()                                                # a caller installed it a moment ago
        (self.scene.root / 'com.videoscan.m4run.queued.plist').write_text('<plist/>')
        stale = self.scene.root / 'bin' / 'abandoned'
        stale.mkdir()
        (self.scene.root / 'com.videoscan.m4run.abandoned.plist').write_text('<plist/>')
        (self.scene.root / 'testbed.conf').write_text('KEEP=3\n')
        for p in (stale, self.scene.root / 'com.videoscan.m4run.abandoned.plist'):
            os.utime(p, (time.time() - 2 * 86400,) * 2)
        th.prune(str(self.scene.root))
        self.assertEqual(sorted(p.name for p in (self.scene.root / 'bin').iterdir()), ['queued', 's0'])
        self.assertEqual(sorted(p.name for p in self.scene.root.glob('*.plist')),
                         ['com.videoscan.m4run.queued.plist', 'com.videoscan.m4run.s0.plist'])
        self.assertTrue((self.scene.root / 'testbed.conf').exists())

    def test_keep_comes_from_the_conf_and_a_poisoned_conf_is_the_default(self):
        for i in range(14):
            self.scene.run(f's{i:02d}', 'suite')
        conf = self.scene.root / 'testbed.conf'
        for text in ('KEEP=0\n', 'KEEP=$(rm -rf /)\n', 'KEEP=-3\n', 'garbage\n', 'KEEP=99999\n'):
            conf.write_text(text)
            self.assertIn(f'newest {th.KEEP_DEFAULT} per lane', th.prune(str(self.scene.root)), text)
        self.assertEqual(len(self.scene.names()), th.KEEP_DEFAULT)
        conf.write_text('# keep fewer\nKEEP = 3   # three\n')
        self.assertIn('newest 3 per lane', th.prune(str(self.scene.root)))
        self.assertEqual(self.scene.names(), ['s11-suite', 's12-suite', 's13-suite'])

    def test_no_out_folder_and_a_thousand_runs(self):
        empty = pathlib.Path(self.tmp.name, 'empty')
        empty.mkdir()
        self.assertEqual(th.prune(str(empty)), 'prune: nothing to do (no run folder yet)')
        for i in range(1000):
            self.scene.run(f'n{i:04d}', 'ui', size=10, bin_dir=False)
        t0 = time.monotonic()
        line = th.prune(str(self.scene.root))
        self.assertLess(time.monotonic() - t0, 20.0)
        self.assertIn('removed 990 run folders', line)

    def test_the_command_line(self):
        self.scene.run('s0', 'suite')
        done = subprocess.run([sys.executable, str(SCRIPTS / 'testbed_host.py'), 'prune', str(self.scene.root), '--keep', '5'],
                              capture_output=True, text=True, timeout=60)
        self.assertEqual((done.returncode, done.stdout.split(':')[0]), (0, 'prune'))
        for bad in (['prune'], ['prune', str(self.scene.root), '--keep', 'x'], ['status-json'], ['window', 'a'], []):
            self.assertEqual(subprocess.run([sys.executable, str(SCRIPTS / 'testbed_host.py'), *bad],
                                            capture_output=True, text=True, timeout=60).returncode, 2, bad)

    def test_the_helper_can_be_shipped_inside_a_heredoc(self):
        self.assertNotIn("'", (SCRIPTS / 'testbed_host.py').read_text(), 'm4_run.sh ships this file inside a quoted heredoc')


class WindowTests(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.m4 = pathlib.Path(self.tmp.name, 'm4run')
        self.ultra = pathlib.Path(self.tmp.name, 'ultrarun')
        self.m4.mkdir()
        self.ultra.mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def test_each_lane_is_refused_for_its_own_length_before_the_m4s_14_00_run(self):
        for lane, hhmm, quiet in (('suite', '1244', False), ('suite', '1245', True), ('suite', '1359', True),
                                  ('suite', '1400', False), ('suite', '1430', False), ('testbed', '1200', True),
                                  ('testbed', '1159', False), ('ui', '1329', False), ('ui', '1330', True),
                                  ('corpus', '1315', True), ('corpus', '1314', False), ('deep', '1300', True)):
            with self.subTest(lane=lane, hhmm=hhmm):
                answer = th.window(str(self.m4), lane, hhmm)
                self.assertEqual(answer.startswith('QUIET'), quiet, answer)
        self.assertEqual(th.window(str(self.m4), 'suite', '1300'),
                         'QUIET the scheduled 14:00 run starts in 60 min and a suite lane wants 75 clear')
        self.assertEqual(th.window(str(self.ultra), 'suite', '1359'), 'OK', 'no scheduled afternoon run on the Ultra')

    def test_the_conf_sets_the_schedule_and_the_window_and_midnight_wraps(self):
        (self.ultra / 'testbed.conf').write_text('SCHEDULED=0010, 14:00\nQUIET_MINUTES=30\n')
        for hhmm, quiet in (('2345', True), ('2339', False), ('0009', True), ('0010', False), ('1331', True), ('1329', False)):
            with self.subTest(hhmm=hhmm):
                self.assertEqual(th.window(str(self.ultra), 'testbed', hhmm).startswith('QUIET'), quiet)
        (self.m4 / 'testbed.conf').write_text('SCHEDULED=\n')
        self.assertTrue(th.window(str(self.m4), 'suite', '1359').startswith('QUIET'), 'an empty SCHEDULED is not a setting')
        (self.m4 / 'testbed.conf').write_text('QUIET_MINUTES=0\n')
        self.assertEqual(th.window(str(self.m4), 'suite', '1359'), 'OK', 'QUIET_MINUTES=0 turns the window off')

    def test_a_poisoned_clock_or_conf_never_raises(self):
        (self.m4 / 'testbed.conf').write_text('SCHEDULED=2599,ab,1400\nQUIET_MINUTES=many\n\x00\xff')
        self.assertTrue(th.window(str(self.m4), 'suite', '1350').startswith('QUIET'))
        for clock in ('', 'soon', '2500', '12:61', '9'):
            self.assertEqual(th.window(str(self.m4), 'suite', clock), 'OK', clock)


class StatusJSONTests(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.scene = Root(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def status(self):
        return json.loads(th.status_json(str(self.scene.root), 'M4'))

    def test_an_idle_host_with_nothing_recorded(self):
        value = self.status()
        self.assertEqual((value['host'], value['state'], value['lock'], value['last'], value['suite'], value['testbed'], value['watch']),
                         ('M4', 'idle', None, None, None, None, None))

    def test_the_last_run_the_last_suite_and_the_last_testbed(self):
        suite = self.scene.run('s1', 'suite')
        (suite / 'summary.txt').write_text('suite: GREEN app 9 passed, 0 failed, 0 skipped; core 4 passed\n')
        testbed = self.scene.run('t1', 'testbed', outcome=None)
        (testbed / 'run.log').write_text(f'START 2026-11-18 01:00:00 host=M4 lane=testbed sha={"b" * 40}\n'
                                         'OUTCOME AMBER 2026-11-18 02:30:00 lane=testbed sha=bbbbbbbbb — suite GREEN · corpus check AMBER\n')
        (testbed / 'lanes.tsv').write_text('suite\tGREEN\t3300\t/x\ncorpus check\tAMBER\t600\t/y\n')
        corpus = self.scene.run('c1', 'corpus', outcome=None)
        (corpus / 'run.log').write_text(f'START 2026-11-18 03:00:00 host=M4 lane=corpus corpus-lane=verbs sha={"c" * 40}\n'
                                        'OUTCOME REFUSED testbed worktree has local changes:\n')
        os.symlink(suite, self.scene.root / 'latest-suite')
        os.symlink(testbed, self.scene.root / 'latest-testbed')
        os.symlink(corpus, self.scene.root / 'latest')
        (self.scene.root / 'watch').mkdir()
        (self.scene.root / 'watch' / 'verdict.txt').write_text('2026-11-18 02:31 bbbbbbbbb testbed AMBER\n')
        value = self.status()
        self.assertEqual((value['suite']['verdict'], value['suite']['lane'], value['suite']['sha']), ('GREEN', 'suite', 'a' * 40))
        self.assertEqual(value['suite']['summary'], ['suite: GREEN app 9 passed, 0 failed, 0 skipped; core 4 passed'])
        self.assertEqual((value['testbed']['verdict'], value['testbed']['started'], value['testbed']['ended']),
                         ('AMBER', '2026-11-18 01:00:00', '2026-11-18 02:30:00'))
        self.assertEqual(value['testbed']['why'], 'suite GREEN · corpus check AMBER')
        self.assertEqual(value['testbed']['lanes'], [dict(name='suite', verdict='GREEN', seconds=3300),
                                                     dict(name='corpus check', verdict='AMBER', seconds=600)])
        self.assertEqual((value['last']['verdict'], value['last']['corpus_lane'], value['last']['why']),
                         ('REFUSED', 'verbs', 'testbed worktree has local changes:'))
        self.assertEqual(value['watch'], '2026-11-18 02:31 bbbbbbbbb testbed AMBER')

    def test_a_run_with_no_outcome_is_running_only_while_the_lock_names_it(self):
        run = self.scene.run('s1', 'suite', outcome=None)
        os.symlink(run, self.scene.root / 'latest')
        os.symlink(run, self.scene.root / 'latest-suite')
        value = self.status()
        self.assertEqual((value['state'], value['last']['running'], value['last']['ended_without_outcome']), ('idle', False, True))
        lock = self.scene.root / 'lock'
        lock.mkdir(exist_ok=True)
        fd = os.open(str(lock / 'flock'), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
        try:
            subprocess.run([sys.executable, str(SCRIPTS / 'testbed_lock.py'), 'hold', str(fd), str(lock), f'suite sha=abc since now out={run}'],
                           capture_output=True, text=True, pass_fds=(fd,), timeout=20)
            value = self.status()
            self.assertEqual((value['state'], value['lock']), ('running', f'suite sha=abc since now out={run}'))
            for key in ('last', 'suite'):
                self.assertEqual((value[key]['running'], value[key]['ended_without_outcome']), (True, False), key)
        finally:
            os.close(fd)

    def test_poisoned_files_give_nulls_not_a_traceback(self):
        run = self.scene.run('s1', 'suite', outcome=None)
        (run / 'run.log').write_bytes(b'\xff\xfe START nonsense\nOUTCOME\nOUTCOME \n')
        (run / 'lanes.tsv').write_text('one field\n\t\t\t\n')
        os.symlink(run, self.scene.root / 'latest')
        os.symlink(pathlib.Path(self.tmp.name, 'gone'), self.scene.root / 'latest-suite')
        (self.scene.root / 'latest-testbed').write_text('a file, not a link')
        value = self.status()
        self.assertEqual((value['last']['verdict'], value['last']['sha'], value['suite'], value['testbed']), (None, None, None, None))


class RunnerHookTests(Testbed):
    """scripts/m4_run.sh for real in a fake HOME: the prune at lane start, the quiet window, status --json."""
    HOST = 'ultra'
    ROOT = 'ultrarun'

    def setUp(self):
        super().setUp()
        self.repo = self.home / 'dev' / 'VideoScan'
        (self.repo / 'scripts/lib').mkdir(parents=True)
        for name in ('m4_run.sh', 'm4_run_summary.py', 'testbed_lock.py', 'testbed_host.py', 'nightly_local_tests.sh',
                     'lib/process_group_watchdog.sh'):
            shutil.copy(SCRIPTS / name, self.repo / 'scripts' / name)
        self.sha = self.make_repo(self.repo)
        self.env['PATH'] = f"{self.bin}:{os.environ['PATH']}"

    def clock(self, hhmm):
        (self.bin / 'date').write_text(f'#!/bin/sh\n[ "$1" = "+%H%M" ] && {{ echo {hhmm}; exit 0; }}\nexec /bin/date "$@"\n')
        (self.bin / 'date').chmod(0o755)

    def caller(self, *extra):
        return subprocess.run(['/bin/bash', str(self.repo / 'scripts/m4_run.sh'), 'suite', '--host', 'ultra', '--ref', self.sha, *extra],
                              capture_output=True, text=True, env=self.env, timeout=180)

    def test_a_run_that_reaches_its_lock_after_the_window_opened_is_refused_there(self):
        # Codex #315-6: the caller checks at 01:29 and passes; the run reaches the host side at 01:31.
        (self.fake / 'hhmm').write_text('0129')
        (self.fake / 'epoch').write_text('1700000000')
        (self.bin / 'date').write_text('#!/bin/sh\n[ "$1" = "+%H%M" ] && { cat "$SUITE_FAKE/hhmm"; exit 0; }\n'
                                       '[ "$1" = "+%s" ] && { cat "$SUITE_FAKE/epoch"; exit 0; }\nexec /bin/date "$@"\n')
        (self.bin / 'date').chmod(0o755)
        gate = pathlib.Path(self.tmp_gate()) / 'gate'
        gate.write_text('')
        env = dict(self.env, VIDEOSCAN_M4RUN_PAUSE_AFTER_PROBE=str(gate))
        caller = subprocess.Popen(['/bin/bash', str(self.repo / 'scripts/m4_run.sh'), 'suite', '--host', 'ultra', '--ref', self.sha, '--wait'],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
        deadline = time.time() + 60
        while not pathlib.Path(str(gate) + '.paused').exists() and time.time() < deadline:
            time.sleep(0.05)
        self.assertTrue(pathlib.Path(str(gate) + '.paused').exists(), 'the caller never reached its pause')
        (self.fake / 'hhmm').write_text('0131')
        (self.fake / 'epoch').write_text('1700000120')                    # two minutes later
        gate.unlink()
        stdout, stderr = caller.communicate(timeout=180)
        self.assertEqual(caller.returncode, 2, stdout + stderr)
        run = next((self.root / 'out').glob('*-suite'))
        log = (run / 'run.log').read_text()
        self.assertIn('OUTCOME REFUSED window: the run reached its lock after the next window opened', log)
        self.assertNotIn('START', log)
        self.assertEqual([c for c in self.calls() if not c.startswith('git ')], [], 'the suite ran inside the window')

    def test_force_carries_no_deadline_and_a_direct_host_call_has_none(self):
        self.clock('0129')
        p = self.caller('--dry-run')
        self.assertIn('--start-by <the epoch the next window opens>', p.stdout)
        self.assertEqual(th.minutes_left(str(self.root), 'suite', '0129'), 1)
        self.assertEqual(th.minutes_left(str(self.root), 'suite', '0600'), 1170)     # 06:00 to the next 01:30
        self.assertEqual(th.start_by(str(self.root), 'suite', '0129', '1700000070'), str(1700000040 + 60))   # 30 s into a minute: by the next minute's start
        (self.root / 'testbed.conf').write_text('SCHEDULED=1400\nQUIET_MINUTES=75\n')
        self.assertEqual(th.minutes_left(str(self.root), 'suite', '1200'), 45)

    def tmp_gate(self):
        folder = self.home / 'gate'
        folder.mkdir(exist_ok=True)
        return folder

    def test_a_lane_is_refused_inside_the_quiet_window_and_force_overrides(self):
        (self.root / 'testbed.conf').write_text('SCHEDULED=1400\n')
        self.clock('1330')
        p = self.caller('--wait')
        self.assertEqual(p.returncode, 5, p.stdout + p.stderr)
        self.assertIn('it is 1330 on M5 Ultra — the scheduled 14:00 run starts in 30 min and a suite lane wants 75 clear; '
                      'pass --force to run anyway', p.stderr)
        self.assertFalse((self.root / 'out').exists(), 'a refused run started')
        self.assertFalse((self.root / 'bin').exists(), 'a refused run installed a runner')
        self.clock('1230')
        p = self.caller('--wait')
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.clock('1330')
        p = self.caller('--wait', '--force')
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn('OUTCOME GREEN', p.stdout)

    def test_a_lane_prunes_at_its_start_under_the_lock_and_keeps_itself(self):
        (self.root / 'testbed.conf').write_text('KEEP=1\n')
        out = self.root / 'out'
        out.mkdir()
        for stamp, verdict in (('old1', 'GREEN'), ('old2', 'RED'), ('old3', 'GREEN')):
            (out / f'{stamp}-suite').mkdir()
            (out / f'{stamp}-suite' / 'run.log').write_text(f'START x\nOUTCOME {verdict} then\n')
            os.utime(out / f'{stamp}-suite', (1000, 1000))
        self.clock('1000')
        p = self.caller('--wait')
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        runs = sorted(q.name for q in out.iterdir())
        self.assertEqual(len(runs), 2, runs)
        self.assertIn('old2-suite', runs, 'the RED run is evidence')
        new = next(q for q in out.iterdir() if q.name != 'old2-suite')
        log = (new / 'run.log').read_text()
        self.assertRegex(log, r'(?m)^prune: removed 2 run folders \(0\.0 GB\), kept 2 \(newest 1 per lane, 1 RED, 0 pinned\)$')
        self.assertLess(log.index('prune:'), log.index('START '))
        self.assertTrue((self.root / 'bin' / new.name[:-len('-suite')] / 'testbed_host.py').exists())

    def test_status_json_is_one_object_and_only_for_status(self):
        self.clock('1000')
        self.caller('--wait')
        p = subprocess.run(['/bin/bash', str(self.repo / 'scripts/m4_run.sh'), 'status', '--host', 'ultra', '--json'],
                           capture_output=True, text=True, env=self.env, timeout=60)
        self.assertEqual(p.returncode, 0, p.stderr)
        value = json.loads(p.stdout)
        self.assertEqual((value['host'], value['state'], value['last']['verdict'], value['suite']['lane']), ('M5 Ultra', 'idle', 'GREEN', 'suite'))
        self.assertIn('suite: GREEN app 5 passed', value['suite']['summary'][0])
        self.assertEqual(value['testbed'], None)
        bad = subprocess.run(['/bin/bash', str(self.repo / 'scripts/m4_run.sh'), 'suite', '--host', 'ultra', '--json', '--dry-run'],
                             capture_output=True, text=True, env=self.env, timeout=60)
        self.assertEqual(bad.returncode, 2)
        dry = subprocess.run(['/bin/bash', str(SCRIPTS / 'm4_run.sh'), 'status', '--host', 'm4', '--json', '--dry-run'],
                             capture_output=True, text=True, env=self.env, timeout=60)
        self.assertIn("+ ssh ricksm4.local <<'SH'", dry.stdout)
        self.assertIn("python3 - 'status-json'", dry.stdout)


if __name__ == '__main__':
    unittest.main()
