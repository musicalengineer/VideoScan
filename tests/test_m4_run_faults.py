"""Harness fault injection (Rick, 2026-11-18: "harden this testbed" so that "it passed on the M4"
counts for something). Each failure must end in an honest RED, a refusal or a clean resume —
never a silent GREEN or a hung lock. What each fault does, and where it is pinned:

  the testbed process dies mid-lane   kernel flock: the lock frees itself; status says ENDED WITHOUT
                                      AN OUTCOME; --wait exits 2 — test_m4_run_suite_lane
                                      test_a_run_whose_shell_is_stopped_…, test_m4_run
                                      test_a_killed_shells_live_work_keeps_the_lock_…; the watcher
                                      retries once — test_m4_watch test_a_run_that_ended_without_…
  ssh drops during a --wait           HERE: a bounded wait that says "lost contact", never exit 0
  a stale lock                        there is none: flock dies with its holders — test_m4_run
                                      test_a_dead_holders_lock_needs_no_reclaim
  a partly written results file       HERE: a corpus lane that exits 0 with no summary is RED; a
                                      testbed lanes file missing a lane is RED; a torn suite row is RED
  the disk forecast crosses 90%       HERE: refused before START, nothing built or run
  the TB5 share disappears mid-read   no lane reads ~/corpus/live; the cleanup only lstats its name,
                                      under a 900 s alarm — test_testbed_cleanup test_f6_…
  watcher ticks during a run / two    test_m4_watch test_a_running_commit_is_never_started_again_…,
  pushes in quick succession          test_one_slot_the_newest_commit_and_a_red_verdict
  a --ref that does not build         suite: test_m4_run_suite_lane test_a_build_failure_is_red_…;
                                      corpus: corpus_run.py writes "RED the driver did not build"
                                      (exit 1) — and HERE for the testbed lane

Fake HOME, stand-ins for xcodebuild / swift / ssh / launchctl; no host, no network.
"""
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[1]
SCRIPTS = REPO / 'scripts'
sys.path.insert(0, str(SCRIPTS))
sys.path.insert(0, str(REPO / 'tests'))
import m4_run_summary as ms  # noqa: E402
import testbed_host as th  # noqa: E402
from test_m4_run_suite_lane import Testbed, probe  # noqa: E402
from test_m4_run_testbed_lane import TestbedScene, facts  # noqa: E402

GB = 10 ** 9

# ssh as the caller uses it: `ssh -o … -o … <host> bash -s` (a script on stdin) or `ssh … <host> "<command>"`,
# run locally (same account, same HOME). $SUITE_FAKE/ssh_down: "forever" fails every call (exit 255, as ssh
# does when the host is gone); a number fails that many calls, then the link is back.
FAKE_SSH = r'''#!/bin/bash
echo "ssh $*" >> "$SUITE_FAKE/ssh-calls"
if [ -e "$SUITE_FAKE/ssh_down" ]; then
  left="$(cat "$SUITE_FAKE/ssh_down")"
  if [ "$left" = forever ]; then echo "ssh: connect to host ricksm4.local port 22: Host is down" >&2; exit 255; fi
  if [ "$left" -gt 0 ] 2>/dev/null; then echo $((left - 1)) > "$SUITE_FAKE/ssh_down"; echo "ssh: Host is down" >&2; exit 255; fi
fi
while [ "${1:-}" = -o ]; do shift 2; done
shift
if [ "${1:-}" = bash ] && [ "${2:-}" = -s ]; then exec /bin/bash -s; fi
exec /bin/bash -c "$*"
'''
# launchctl: `bootstrap` starts the agent as launchd would; then, when $SUITE_FAKE/drop_after_start says so,
# the link to the host goes down (the run itself goes on, on the host).
FAKE_LAUNCHCTL = r'''#!/usr/bin/env python3
import os, plistlib, shutil, subprocess, sys
args = sys.argv[1:]
fake = os.environ["SUITE_FAKE"]
if args[:1] == ["bootstrap"]:
    with open(args[2], "rb") as f:
        plist = plistlib.load(f)
    subprocess.Popen(plist["ProgramArguments"], start_new_session=True,
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    drop = os.path.join(fake, "drop_after_start")
    if os.path.exists(drop):
        shutil.copy(drop, os.path.join(fake, "ssh_down"))
sys.exit(0)
'''
# git on the caller: a push to the M4 is accepted and does nothing (the "M4" is this fake HOME).
FAKE_GIT_PUSH_OK = r'''#!/bin/sh
echo "git $*" >> "$SUITE_FAKE/calls"
case " $* " in *" push "*) exit 0 ;; esac
exec /usr/bin/git "$@"
'''


class SshDropTests(Testbed):
    """The caller on the Ultra, the run on the "M4" over a fake ssh that drops."""
    HOST = 'm4'
    ROOT = 'm4run'

    def setUp(self):
        super().setUp()
        self.repo = self.home / 'dev' / 'VideoScan'
        (self.repo / 'scripts/lib').mkdir(parents=True)
        for name in ('m4_run.sh', 'm4_run_summary.py', 'testbed_lock.py', 'testbed_host.py', 'nightly_local_tests.sh',
                     'lib/process_group_watchdog.sh'):
            shutil.copy(SCRIPTS / name, self.repo / 'scripts' / name)
        self.sha = self.make_repo(self.repo)
        for name, body in (('ssh', FAKE_SSH), ('launchctl', FAKE_LAUNCHCTL), ('git', FAKE_GIT_PUSH_OK)):
            (self.bin / name).write_text(body)
            (self.bin / name).chmod(0o755)
        (self.bin / 'date').write_text('#!/bin/sh\n[ "$1" = "+%H%M" ] && { echo 1730; exit 0; }\nexec /bin/date "$@"\n')
        (self.bin / 'date').chmod(0o755)
        self.env['PATH'] = f"{self.bin}:{os.environ['PATH']}"
        self.env['VIDEOSCAN_M4RUN_UNREACHABLE_SECONDS'] = '4'

    def caller(self, timeout=120):
        return subprocess.run(['/bin/bash', str(self.repo / 'scripts/m4_run.sh'), 'suite', '--host', 'm4', '--ref', self.sha,
                               '--wait'], capture_output=True, text=True, env=self.env, timeout=timeout)

    def test_a_link_that_stays_down_ends_the_wait_with_could_not_run_never_green(self):
        (self.fake / 'drop_after_start').write_text('forever')
        try:
            p = self.caller(timeout=90)
        except subprocess.TimeoutExpired:
            self.fail('--wait kept polling a host it could not reach (it would have run out its 6.5 h budget)')
        self.assertEqual(p.returncode, 2, p.stdout + p.stderr)
        self.assertIn('lost contact with M4', p.stderr)
        self.assertIn('the run may still be going', p.stderr)
        self.assertNotIn('OUTCOME GREEN', p.stdout)

    def test_a_link_that_comes_back_still_reports_the_runs_verdict(self):
        (self.fake / 'drop_after_start').write_text('2')
        p = self.caller()
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn('OUTCOME GREEN', p.stdout)
        self.assertEqual(probe(self.root / 'lock'), 'FREE')


class PartialResultsTests(TestbedScene):

    def test_a_corpus_lane_that_exits_0_without_a_summary_is_red(self):
        # RED before: host_corpus wrote "RED no summary was written" into the summary and left the
        # verdict GREEN, so the run.log said OUTCOME GREEN over a lane that reported nothing.
        self.corpus('check', exit_code=0, summary=None)
        p, log, summary, _ = self.host('c1', 'corpus', '--corpus-lane', 'check')
        self.assertIn('corpus check: RED no summary was written', summary)
        self.assertRegex(log, r'(?m)^OUTCOME RED ')
        self.assertEqual(p.returncode, 1, log)

    def test_an_amber_corpus_lane_without_a_summary_is_red_too(self):
        self.corpus('proof', exit_code=3, verdict='AMBER', summary=None)
        p, log, summary, _ = self.host('c2')
        self.assertRegex(log, r'(?m)^OUTCOME RED .* corpus proof RED$')
        self.assertTrue(summary.startswith('testbed: RED at '), summary)

    def test_a_lanes_file_missing_a_lane_is_red(self):
        with tempfile.TemporaryDirectory() as tmp:
            row = pathlib.Path(tmp, 'row.json')
            row.write_text(json.dumps(dict(passed=1, failed=0, skipped=0, core_passed=1, core_failed=0)))
            check = pathlib.Path(tmp, 'check.json')
            check.write_text(json.dumps(facts('check')))
            lanes = pathlib.Path(tmp, 'lanes.tsv')
            # The shell died after the second row: proof never wrote its row.
            lanes.write_text(f'suite\tGREEN\t9\t{row}\ncorpus check\tGREEN\t9\t{check}\n')
            done = subprocess.run([sys.executable, str(SCRIPTS / 'm4_run_summary.py'), '--testbed', str(lanes), 'c' * 40, '9',
                                   '--expect', 'suite,corpus check,corpus proof'], capture_output=True, text=True, timeout=60)
            self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
            self.assertRegex(done.stdout, r'(?m)^  corpus proof  RED +\?s  no row: the lane never reported')
            lanes.write_text(lanes.read_text() + 'corpus proof\tGRE')        # a row torn mid-write
            done = subprocess.run([sys.executable, str(SCRIPTS / 'm4_run_summary.py'), '--testbed', str(lanes), 'c' * 40, '9',
                                   '--expect', 'suite,corpus check,corpus proof'], capture_output=True, text=True, timeout=60)
            self.assertEqual(done.returncode, 1, done.stdout)

    def test_the_testbed_lane_asks_for_its_three_lanes(self):
        text = (SCRIPTS / 'm4_run.sh').read_text()
        self.assertIn("--testbed \"$OUT/lanes.tsv\" \"$sha\" \"$(( $(date +%s) - t0 ))\" --expect 'suite,corpus check,corpus proof'", text)

    def test_a_torn_suite_row_is_red_at_every_cut(self):
        row = json.dumps(dict(status='ok', passed=10, failed=0, skipped=0, total=10, core_status='ok', core_passed=4,
                              core_failed=0, core_skipped=0, core_total=4, commit='a' * 40))
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp, 'suite-row.json')
            for cut in range(0, len(row), 7):
                path.write_text(row[:cut])
                done = subprocess.run([sys.executable, str(SUMMARY), '--suite', str(path), '0', '5'],
                                      capture_output=True, text=True, timeout=60)
                self.assertEqual(done.returncode, 1, f'cut at {cut}: {done.stdout}')
            path.write_text(row)
            self.assertEqual(subprocess.run([sys.executable, str(SUMMARY), '--suite', str(path), '0', '5'],
                                            capture_output=True, text=True, timeout=60).returncode, 0)

    def test_a_ref_whose_corpus_driver_does_not_build_is_a_red_testbed(self):
        self.corpus('check', exit_code=1, verdict='RED', lane_facts=None,
                    summary='corpus check: RED the driver did not build against abcdef012 (corpus-build.log on the host); no file was run\n')
        p, log, summary, _ = self.host('b1')
        self.assertEqual(p.returncode, 1, log)
        self.assertRegex(log, r'(?m)^OUTCOME RED .* corpus check RED')


SUMMARY = SCRIPTS / 'm4_run_summary.py'


class DiskForecastTests(TestbedScene):
    """DECISIONS 2026-11-18: a run may take the M4 to ~90% used. One that would cross it is refused
    before it starts: nothing checked out, built or run, the lock released, the run says why."""

    def test_a_run_that_would_cross_90_percent_is_refused_before_start(self):
        self.env['VIDEOSCAN_TESTBED_FAKE_DISK'] = f'{100 * GB}:{85 * GB}'      # 85% used; a testbed run needs more than 5 GB
        p, log, summary, out = self.host('f1')
        self.assertEqual(p.returncode, 4, log)
        self.assertRegex(log, r'(?m)^OUTCOME REFUSED disk: \d+% used now; a testbed run needs up to \d+ GB')
        self.assertNotIn('START ', log)
        self.assertEqual([c for c in self.calls() if not c.startswith('git ')], [], 'a refused run built or ran something')
        self.assertEqual(probe(self.root / 'lock'), 'FREE')

    def test_a_run_inside_the_ceiling_starts(self):
        self.env['VIDEOSCAN_TESTBED_FAKE_DISK'] = f'{1000 * GB}:{600 * GB}'    # 60% used, as the M4 is tonight
        p, log, _, _ = self.host('f2')
        self.assertEqual(p.returncode, 0, log)
        self.assertRegex(log, r'(?m)^OUTCOME GREEN ')

    def test_the_forecast_by_lane(self):
        self.assertTrue(th.forecast('suite', '', (300 * GB, 1000 * GB)).startswith('OK '))
        self.assertTrue(th.forecast('suite', '', (100 * GB, 1000 * GB)).startswith('REFUSE '))
        self.assertTrue(th.forecast('corpus', 'coverage', (110 * GB, 1000 * GB)).startswith('REFUSE '))
        self.assertTrue(th.forecast('corpus', 'check', (120 * GB, 1000 * GB)).startswith('OK '))
        self.assertTrue(th.forecast('nonsense', '', (900 * GB, 1000 * GB)).startswith('OK '), 'an unknown lane takes the largest peak')
        self.assertTrue(th.forecast('nonsense', '', (101 * GB, 1000 * GB)).startswith('REFUSE '))
        self.assertTrue(th.forecast('suite', '', (0, 0)).startswith('REFUSE '), 'a disk it cannot measure is refused')


if __name__ == '__main__':
    unittest.main()
