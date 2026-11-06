"""scripts/m4_run.sh host_deep — the bash glue behind GREEN / AMBER / RED.

Fresh-eyes coverage review (main 9c86c7369..2c8fa9777, 2026-11-05): the
verdict rules are pinned in Python (m4_run_summary.gauntlet_verdict,
tests/test_m4_run.py) and the runner in Swift, but the shell between them —
host_deep pulling `results=` off the GAUNTLET line, mapping the summary's
exit 3 to AMBER, carrying the reasons into the OUTCOME line, and host_main
exiting 0 for AMBER and 1 for RED (m4_run.sh:381-440) — had no test. A
broken `${line##* results=}` or a dropped `vrc` case would publish RED (or
worse, GREEN) silently.

The host side runs for real in a fake HOME: a real git repo as the testbed
(so the sha check passes), a fake scripts/run_gauntlet.sh that prints the
runner's one line for a planted result.json, and the real
m4_run_summary.py in <root>/bin. No ssh, no xcodebuild, no network.
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
SCRIPT = REPO / 'scripts/m4_run.sh'
SUMMARY = REPO / 'scripts/m4_run_summary.py'

FAKE_GAUNTLET = r'''#!/bin/sh
# A stand-in for scripts/run_gauntlet.sh: the line the real runner prints
# (Runner.swift publishResults) for the result the test planted in fake/.
status=$(cat fake/status); rc=$(cat fake/rc)
if [ "$status" != "NONE" ]; then
    amber=''
    [ "$status" = AMBER ] && amber=' amber="7 known issues (regression 7); ui not run (phase 2)"'
    printf 'GAUNTLET %s sha=%s total=9s unit=PASSED regression=%s ui=NOT_RUN UI not run (phase 2)%s results=%s/fake/result.json publish=queued\n' \
        "$status" "$(cat fake/sha)" "$status" "$amber" "$(pwd)"
fi
exit "$rc"
'''


def result_json(status, sha, regression='passed', known=0, ui='not_run'):
    stages = [
        {'name': 'unit', 'status': 'passed', 'known_issues': 0, 'blocked_details': []},
        {'name': 'regression', 'status': regression, 'known_issues': known, 'blocked_details': [],
         'reason': 'test failures' if regression == 'failed' else None},
        {'name': 'ui', 'status': ui, 'reason': 'phase 2', 'blocked_details': []},
    ]
    return {'status': status, 'commit': sha, 'stages': stages, 'inventory_errors': []}


class HostDeepLaneTests(unittest.TestCase):

    def setUp(self):
        self.home = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.home.name, 'm4run')
        self.work = self.root / 'work'
        (self.work / 'scripts').mkdir(parents=True)
        (self.work / 'fake').mkdir()
        (self.root / 'bin').mkdir()
        shutil.copy(SUMMARY, self.root / 'bin' / 'm4_run_summary.py')
        gauntlet = self.work / 'scripts' / 'run_gauntlet.sh'
        gauntlet.write_text(FAKE_GAUNTLET)
        gauntlet.chmod(0o755)
        git = ['git', '-C', str(self.work)]
        env = dict(os.environ, HOME=self.home.name, GIT_AUTHOR_NAME='t', GIT_AUTHOR_EMAIL='t@t',
                   GIT_COMMITTER_NAME='t', GIT_COMMITTER_EMAIL='t@t')
        subprocess.run(git + ['init', '-q'], check=True, env=env)
        subprocess.run(git + ['add', '-A'], check=True, env=env)
        subprocess.run(git + ['commit', '-q', '-m', 'testbed'], check=True, env=env)
        self.sha = subprocess.run(git + ['rev-parse', 'HEAD'], check=True, env=env,
                                  capture_output=True, text=True).stdout.strip()
        self.env = dict(os.environ, HOME=self.home.name)

    def tearDown(self):
        self.home.cleanup()

    def plant(self, status_word, rc, result):
        fake = self.work / 'fake'
        (fake / 'status').write_text(status_word)
        (fake / 'rc').write_text(str(rc))
        (fake / 'sha').write_text(self.sha[:8])
        if result is not None:
            (fake / 'result.json').write_text(json.dumps(result))

    def host(self, stamp):
        p = subprocess.run(['/bin/bash', str(SCRIPT), '__host', 'deep', self.sha, stamp, '--host', 'm4'],
                           capture_output=True, text=True, env=self.env, timeout=60)
        out = self.root / 'out' / f'{stamp}-deep'
        return p, (out / 'run.log').read_text(), (out / 'summary.txt').read_text()

    def test_amber_run_is_outcome_amber_with_the_reasons_and_exit_0(self):
        self.plant('AMBER', 0, result_json('amber', self.sha, regression='amber', known=7))
        p, log, summary = self.host('d1')
        self.assertEqual(p.returncode, 0, log)
        self.assertIn('OUTCOME AMBER', log)
        self.assertIn('— 7 known issues (regression 7); ui not run (phase 2)', log)
        self.assertIn('deep: AMBER 7 known issues (regression 7); ui not run (phase 2) (sha=', summary)
        self.assertNotIn('OUTCOME GREEN', log)
        self.assertNotIn('OUTCOME RED', log)
        probe = subprocess.run([sys.executable, str(REPO / 'scripts/testbed_lock.py'), 'probe', str(self.root / 'lock')],
                               capture_output=True, text=True, timeout=20).stdout.strip()
        self.assertEqual(probe, 'FREE', 'lock left behind')

    def test_green_run_is_outcome_green_and_exit_0(self):
        self.plant('PASSED', 0, result_json('passed', self.sha, ui='passed'))
        p, log, summary = self.host('d2')
        self.assertEqual(p.returncode, 0, log)
        self.assertIn('OUTCOME GREEN', log)
        self.assertNotIn(' — ', log.splitlines()[-1] if log.strip() else '')
        self.assertIn('deep: GREEN every stage passed', summary)

    def test_red_run_is_outcome_red_and_exit_1(self):
        self.plant('FAILED', 1, result_json('failed', self.sha, regression='failed'))
        p, log, summary = self.host('d3')
        self.assertEqual(p.returncode, 1, log)
        self.assertIn('OUTCOME RED', log)
        self.assertIn('deep: RED regression failed: test failures', summary)

    def test_no_gauntlet_line_is_red_never_green(self):
        # The runner died before its one line (or printed something else): no result.json to read.
        self.plant('NONE', 0, None)
        p, log, summary = self.host('d4')
        self.assertEqual(p.returncode, 1, log)
        self.assertIn('OUTCOME RED', log)
        self.assertIn('deep: RED no result.json', summary)
        self.assertIn('(no GAUNTLET line; see gauntlet.log)', summary)

    def test_amber_result_with_a_non_zero_runner_exit_is_red(self):
        # The runner says AMBER but exited 1 (a publish failure, a signal): not AMBER.
        self.plant('AMBER', 1, result_json('amber', self.sha, regression='amber', known=7))
        p, log, _ = self.host('d5')
        self.assertEqual(p.returncode, 1, log)
        self.assertIn('OUTCOME RED', log)


if __name__ == '__main__':
    unittest.main()
