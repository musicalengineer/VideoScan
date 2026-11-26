"""scripts/m4_watch.py + scripts/m4_watch_install.sh — the push trigger on the M4.

DECISIONS 2026-11-17: the M4 runs the suite on every push to `main`. The watcher is a
tick every ~300 s that decides and then calls the pinned `m4_run.sh suite --host
m4local`. These tests pin, with a real local git remote, a stand-in runner and a
stand-in clock (no network, no host, no launchd):

  * it runs only on the M4 (the Ultra refused by name), and creates nothing elsewhere;
  * one slot, the newest commit; never the same commit twice; a run started by hand
    counts; a docs-only range is skipped and an unknown range never is;
  * a run that ended without an OUTCOME is retried once, then recorded;
  * busy and the quiet window wait; a runner that will not start is given up on;
  * the one-line verdict file, the tick line, bounded history, poisoned state;
  * the whole path for real in a fake HOME: the pinned m4_run.sh starts a suite run
    through `--host m4local` from a folder that is not a checkout, a later tick reads
    its OUTCOME, and `status` shows the verdict line;
  * the installer: the plan, the plist, install / uninstall / reinstall on a fake M4,
    and a refusal on any other Mac.
"""
import json
import os
import pathlib
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[1]
SCRIPTS = REPO / 'scripts'
sys.path.insert(0, str(SCRIPTS))
sys.path.insert(0, str(REPO / 'tests'))
import m4_watch as mw  # noqa: E402
import testbed_host as th  # noqa: E402
from test_m4_run_suite_lane import Testbed, probe  # noqa: E402

GIT = '/usr/bin/git'
PINNED = ('m4_watch.py', 'm4_run.sh', 'm4_run_summary.py', 'testbed_lock.py', 'testbed_host.py', 'nightly_local_tests.sh',
          'lib/process_group_watchdog.sh')

# Stand-in for the pinned m4_run.sh: records its arguments, then does what $WATCH_FAKE/plan says:
# "exit N" (default 0), and on exit 0 makes the run folder and prints the line the watcher reads.
FAKE_RUNNER = r'''#!/bin/bash
echo "$*" >> "$WATCH_FAKE/runner-calls"
n=$(wc -l < "$WATCH_FAKE/runner-calls" | tr -d ' ')
code=$(cat "$WATCH_FAKE/exit" 2>/dev/null || echo 0)
[ "$code" = 0 ] || exit "$code"
out="$WATCH_FAKE/root/out/run$n-suite"
mkdir -p "$out"
sha="${@: -1}"
echo "START 2026-11-18 01:00:00 host=M4 lane=suite sha=$sha" > "$out/run.log"
echo "m4_run: started — output $out (run.log, summary.txt)"
'''
FAKE_LAUNCHCTL_LOG = '#!/bin/sh\necho "$*" >> "$WATCH_FAKE/launchctl-calls"\n[ "$1" = print ] && [ ! -e "$WATCH_FAKE/loaded" ] && exit 113\n' \
                     '[ "$1" = bootstrap ] && touch "$WATCH_FAKE/loaded"\n[ "$1" = bootout ] && { [ -e "$WATCH_FAKE/loaded" ] || exit 3; rm -f "$WATCH_FAKE/loaded"; }\nexit 0\n'


class Scene:
    """A fake M4: an "origin" (bare), the M4's checkout (a clone), <root>, and the stand-in runner."""

    def __init__(self, tmp, hostname='RicksM4.local'):
        self.tmp = pathlib.Path(tmp)
        self.fake = self.tmp / 'fake'
        self.root = self.fake / 'root'
        self.root.mkdir(parents=True)
        self.env = dict(os.environ, GIT_AUTHOR_NAME='t', GIT_AUTHOR_EMAIL='t@t', GIT_COMMITTER_NAME='t', GIT_COMMITTER_EMAIL='t@t',
                        WATCH_FAKE=str(self.fake))
        os.environ['WATCH_FAKE'] = str(self.fake)
        self.origin, self.author, self.repo = self.tmp / 'origin.git', self.tmp / 'author', self.tmp / 'm4-checkout'
        self.git('init', '-q', '--bare', '-b', 'main', str(self.origin), cwd=self.tmp)
        self.git('clone', '-q', str(self.origin), str(self.author), cwd=self.tmp)
        self.commit({'VideoScan/App.swift': 'let a = 1\n', 'docs/STATUS.md': 'status\n'})
        self.git('clone', '-q', str(self.origin), str(self.repo), cwd=self.tmp)
        self.runner = self.fake / 'm4_run.sh'
        self.runner.write_text(FAKE_RUNNER)
        self.clock = 1_800_000_000.0
        self.watch = mw.Watch(str(self.root), str(self.repo), str(self.runner), hostname, git=GIT, now=lambda: self.clock)

    def git(self, *args, cwd=None):
        return subprocess.run([GIT, *args], cwd=str(cwd or self.author), env=self.env, check=True, capture_output=True, text=True).stdout.strip()

    def commit(self, files, message='change'):
        """A commit on origin/main; returns its sha."""
        for rel, text in files.items():
            path = self.author / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        self.git('add', '-A')
        self.git('commit', '-q', '-m', message)
        self.git('push', '-q', 'origin', 'HEAD:main')
        return self.git('rev-parse', 'HEAD')

    def head(self):
        return self.git('rev-parse', 'HEAD')

    def tick(self, later=300):
        self.clock += later
        return self.watch.tick()

    def calls(self):
        path = self.fake / 'runner-calls'
        return path.read_text().splitlines() if path.exists() else []

    def finish(self, n, verdict='GREEN', summary='suite: GREEN app 9 passed, 0 failed, 0 skipped; core 4 passed, 0 failed, 0 skipped'):
        out = self.root / 'out' / f'run{n}-suite'
        with open(out / 'run.log', 'a') as f:
            f.write(f'OUTCOME {verdict} 2026-11-18 02:00:00 lane=suite sha=abc\n')
        (out / 'summary.txt').write_text(summary + '\n')

    def text(self, name):
        path = self.root / 'watch' / name
        return path.read_text() if path.exists() else ''

    def hold_lock(self, info):
        lock = self.root / 'lock'
        lock.mkdir(exist_ok=True)
        fd = os.open(str(lock / 'flock'), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
        subprocess.run([sys.executable, str(SCRIPTS / 'testbed_lock.py'), 'hold', str(fd), str(lock), info],
                       capture_output=True, text=True, pass_fds=(fd,), timeout=20)
        return fd


class WatchTests(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.scene = Scene(self.tmp.name)

    def tearDown(self):
        os.environ.pop('WATCH_FAKE', None)
        self.tmp.cleanup()

    def test_it_runs_only_on_the_m4_and_creates_nothing_elsewhere(self):
        for host in ('RicksUltra', 'ricksultra.local', 'ricksm5', 'ricksm4x', 'localhost', ''):
            with self.subTest(host=host):
                other = mw.Watch(str(self.scene.root), str(self.scene.repo), str(self.scene.runner), host, git=GIT)
                self.assertTrue(other.tick().startswith('refused: '), host)
        self.assertIn('the M5 Ultra', mw.Watch(str(self.scene.root), str(self.scene.repo), str(self.scene.runner), 'RicksUltra').tick())
        self.assertFalse((self.scene.root / 'watch').exists(), 'a refused tick wrote state')
        self.assertEqual(self.scene.calls(), [])
        self.assertEqual(mw.main(['tick'], watch=mw.Watch(str(self.scene.root), str(self.scene.repo), str(self.scene.runner), 'RicksUltra')), 1)
        self.assertEqual((mw.ALLOWED_HOSTS, mw.LANE), (frozenset({'ricksm4'}), 'suite'))

    def test_the_first_tick_starts_the_suite_for_the_head_of_main_through_m4local(self):
        head = self.scene.head()
        line = self.scene.tick()
        self.assertRegex(line, r'^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d saw ' + head[:9] + r' — started the suite lane \(run 1 of at most 2\)$')
        self.assertEqual(self.scene.calls(), [f'suite --host m4local --ref {head} --unless-ran'])
        self.assertEqual(self.scene.text('tick.txt').strip(), line)
        self.assertEqual(self.scene.text('verdict.txt'), '', 'no verdict until the run has one')
        # The watcher fetched into its own ref and moved nothing else in the M4's checkout.
        refs = self.scene.git('for-each-ref', '--format=%(refname)', cwd=self.scene.repo).splitlines()
        self.assertIn('refs/m4watch/main', refs)
        self.assertEqual(self.scene.git('status', '--porcelain', cwd=self.scene.repo), '')

    def test_a_running_commit_is_never_started_again_and_its_outcome_becomes_the_one_verdict_line(self):
        head = self.scene.head()
        self.scene.tick()
        fd = self.scene.hold_lock(f'suite sha=x since now out={self.scene.root}/out/run1-suite')
        try:
            for _ in range(5):
                self.assertIn(f'the run of {head[:9]} is still going', self.scene.tick())
        finally:
            os.close(fd)
        self.scene.finish(1)
        line = self.scene.tick()
        self.assertIn(f'the run of {head[:9]} ended GREEN — nothing to do (settled GREEN)', line)
        verdict = self.scene.text('verdict.txt')
        self.assertRegex(verdict, r'^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d ' + head[:9] + r' suite GREEN — suite: GREEN app 9 passed, 0 failed, '
                                  r'0 skipped; core 4 passed, 0 failed, 0 skipped\n$')
        self.assertEqual(len(verdict.splitlines()), 1)
        for _ in range(3):
            self.assertIn('nothing to do (settled GREEN)', self.scene.tick())
        self.assertEqual(len(self.scene.calls()), 1, 'the same commit was started twice')

    def test_one_slot_the_newest_commit_and_a_red_verdict(self):
        first = self.scene.head()
        self.scene.tick()
        self.scene.commit({'VideoScan/App.swift': 'let a = 2\n'})
        middle = self.scene.head()
        newest = self.scene.commit({'VideoScan/App.swift': 'let a = 3\n'})
        self.scene.finish(1, 'RED', 'suite: RED failed-tests:1 — app 8 passed, 1 failed, 0 skipped; core 4 passed, 0 failed, 0 skipped')
        line = self.scene.tick()
        self.assertIn(f'saw {newest[:9]} — the run of {first[:9]} ended RED — started the suite lane', line)
        self.assertEqual(self.scene.calls(), [f'suite --host m4local --ref {first} --unless-ran', f'suite --host m4local --ref {newest} --unless-ran'])
        self.assertNotIn(middle, ' '.join(self.scene.calls()), 'commits are never queued one by one')
        self.assertIn(f'{first[:9]} suite RED — suite: RED failed-tests:1', self.scene.text('verdict.txt'))

    def test_a_docs_only_range_is_skipped_and_a_range_with_code_is_not(self):
        self.scene.tick()
        self.scene.finish(1)
        self.scene.tick()
        base = self.scene.head()
        docs = self.scene.commit({'docs/STATUS.md': 'status 2\n', 'README.md': 'read me\n', 'docs/' + 'guides/x.txt': 'x\n'})
        line = self.scene.tick()
        self.assertIn(f'saw {docs[:9]} — docs-only since {base[:9]}: skipped', line)
        self.assertIn(f'{docs[:9]} suite SKIPPED — docs-only since {base[:9]}', self.scene.text('verdict.txt'))
        self.assertEqual(len(self.scene.calls()), 1)
        # Docs again, then code: the range since the last settled commit holds code — it runs.
        self.scene.commit({'docs/STATUS.md': 'status 3\n'})
        self.scene.tick()
        code = self.scene.commit({'scripts/tool.py': 'x = 1\n'})
        self.assertIn('started the suite lane', self.scene.tick())
        self.assertEqual(self.scene.calls()[-1], f'suite --host m4local --ref {code} --unless-ran')
        # Docs AND code since the last settled commit, seen in one tick: it runs.
        self.scene.finish(2)
        self.scene.tick()
        self.scene.commit({'scripts/tool.py': 'x = 2\n'})
        self.scene.commit({'docs/STATUS.md': 'status 4\n'})
        self.assertIn('started the suite lane', self.scene.tick())
        self.scene.finish(3)
        self.scene.tick()
        # A file that only looks like a doc is code.
        self.scene.commit({'VideoScan/' + 'docs' + '/notes.swift': '// swift\n'})   # (spelled apart: tests/test_docs_links.py reads this file too)
        self.assertIn('started the suite lane', self.scene.tick())

    def test_an_unknown_range_is_never_docs_only(self):
        watch = self.scene.watch
        watch.load()
        head = self.scene.head()
        self.scene.tick()
        for base in (None, '', head, 'f' * 40, 'not-a-sha'):
            self.assertFalse(watch.docs_only(base, head), base)
        # History rewritten: the settled commit is no longer behind main, though it differs from it only in docs.
        self.scene.git('checkout', '-q', '-b', 'side')
        (self.scene.author / 'docs' / 'STATUS.md').write_text('rewritten\n')
        self.scene.git('commit', '-q', '-am', 'a commit main no longer holds')
        side = self.scene.git('rev-parse', 'HEAD')
        self.scene.git('push', '-q', 'origin', 'side')
        self.scene.git('fetch', '-q', 'origin', 'side', cwd=self.scene.repo)
        self.scene.git('checkout', '-q', 'main')
        self.assertEqual(self.scene.git('diff', '--name-only', side, head, cwd=self.scene.repo), 'docs/STATUS.md')
        self.assertFalse(watch.docs_only(side, head), 'a commit that is not behind main proves nothing about the range')

    def test_a_run_that_ended_without_an_outcome_is_retried_once_then_recorded(self):
        head = self.scene.head()
        self.scene.tick()
        line = self.scene.tick()                        # 300 s later: no OUTCOME, and nothing holds the lock
        self.assertIn(f'the run of {head[:9]} ended without an OUTCOME: one retry — started the suite lane (run 2 of at most 2)', line)
        line = self.scene.tick()
        self.assertIn(f'the run of {head[:9]} ended without an OUTCOME again: recorded', line)
        self.assertIn(f'{head[:9]} suite NO-OUTCOME — ended without an OUTCOME twice', self.scene.text('verdict.txt'))
        for _ in range(3):
            self.assertIn('nothing to do (settled NO-OUTCOME)', self.scene.tick())
        self.assertEqual(len(self.scene.calls()), 2, 'retried more than once')

    def test_an_unreadable_outcome_word_is_not_a_host_refusal_and_is_retried_once(self):
        """#489: a torn or unknown OUTCOME word ("OUTCOME GRE") was never settled as a verdict
        (honest), but read "the start was refused on the host (GRE)" and counted a start failure."""
        head = self.scene.head()
        self.scene.tick()
        self.scene.finish(1, verdict='GRE')
        line = self.scene.tick()
        self.assertNotIn('refused on the host', line)
        self.assertIn(f'the run of {head[:9]} ended with an unreadable OUTCOME (GRE): one retry — '
                      'started the suite lane (run 2 of at most 2)', line)
        self.scene.finish(2, verdict='GRE')
        line = self.scene.tick()
        self.assertIn(f'the run of {head[:9]} ended with an unreadable OUTCOME (GRE) again: recorded', line)
        self.assertIn(f'{head[:9]} suite NO-OUTCOME — ended with an unreadable OUTCOME (GRE) twice', self.scene.text('verdict.txt'))
        self.assertNotIn('START-FAILED', self.scene.text('history.log'))
        self.assertEqual(len(self.scene.calls()), 2, 'retried more than once')

    def test_a_run_just_started_is_given_time_to_take_the_lock(self):
        self.scene.tick()
        self.assertIn('is still going', self.scene.tick(later=60))
        self.assertEqual(len(self.scene.calls()), 1)

    def test_no_retry_for_an_older_commit_when_main_has_moved(self):
        first = self.scene.head()
        self.scene.tick()
        newer = self.scene.commit({'VideoScan/App.swift': 'let a = 9\n'})
        line = self.scene.tick()
        self.assertIn('started the suite lane (run 1 of at most 2)', line)
        self.assertEqual(self.scene.calls(), [f'suite --host m4local --ref {first} --unless-ran', f'suite --host m4local --ref {newer} --unless-ran'])
        self.assertIn(f'{first[:9]} suite NO-OUTCOME', self.scene.text('history.log'))

    def test_busy_and_the_quiet_window_wait_without_counting_against_the_commit(self):
        for code, words in ((3, 'the testbed is busy: waiting for the next tick'),
                            (5, 'inside the nightly or quiet window: waiting for the next tick')):
            (self.scene.fake / 'exit').write_text(str(code))
            for _ in range(6):
                self.assertIn(words, self.scene.tick())
        self.assertEqual(self.scene.text('verdict.txt'), '')
        (self.scene.fake / 'exit').write_text('0')
        self.assertIn('started the suite lane (run 1 of at most 2)', self.scene.tick())
        self.assertEqual(len(self.scene.calls()), 13)

    def test_a_runner_that_will_not_start_is_given_up_on(self):
        head = self.scene.head()
        (self.scene.fake / 'exit').write_text('4')
        self.assertIn('the runner would not start (exit 4); failure 1 of 3', self.scene.tick())
        self.assertIn('failure 2 of 3', self.scene.tick())
        self.assertIn('recorded START-FAILED', self.scene.tick())
        self.assertIn(f'{head[:9]} suite START-FAILED', self.scene.text('verdict.txt'))
        for _ in range(3):
            self.assertIn('nothing to do (settled START-FAILED)', self.scene.tick())
        self.assertEqual(len(self.scene.calls()), 3)

    def test_a_start_the_host_refused_is_not_a_run_and_is_bounded(self):
        head = self.scene.head()
        for n in (1, 2, 3):
            self.scene.tick()
            with open(self.scene.root / 'out' / f'run{n}-suite' / 'run.log', 'w') as f:
                f.write('OUTCOME REFUSED testbed worktree has local changes:\n')
        line = self.scene.tick()
        self.assertIn(f'the start of {head[:9]} was refused on the host (REFUSED:testbed) — nothing to do (settled START-FAILED)', line)
        self.assertEqual(len(self.scene.calls()), 3)

    def test_a_commit_already_run_by_hand_is_recorded_and_not_run_again(self):
        head = self.scene.head()
        by_hand = self.scene.root / 'out' / '20261117_230000_1-testbed'
        by_hand.mkdir(parents=True)
        (by_hand / 'run.log').write_text(f'START 2026-11-17 23:00:00 host=M4 lane=testbed sha={head}\nOUTCOME AMBER 2026-11-18 00:30:00 lane=testbed sha=x\n')
        line = self.scene.tick()
        self.assertIn('already run by hand (AMBER): recorded, not run again', line)
        self.assertEqual(self.scene.calls(), [])
        self.assertIn(f'{head[:9]} suite AMBER — run by hand under root/out; not run again', self.scene.text('verdict.txt'))

    def test_a_hand_run_that_never_ran_or_of_another_lane_does_not_count(self):
        head = self.scene.head()
        out = self.scene.root / 'out'
        for name, log in (('a-suite', f'START x host=M4 lane=suite sha={head}\nOUTCOME NORUN x\n'),
                          ('b-suite', f'START x host=M4 lane=suite sha={head}\n'),
                          ('c-suite', f'OUTCOME REFUSED busy\n'),
                          ('d-ui', f'START x host=M4 lane=ui sha={head}\nOUTCOME GREEN x\n'),
                          ('e-suite', f'START x host=M4 lane=suite sha={"e" * 40}\nOUTCOME GREEN x\n')):
            (out / name).mkdir(parents=True)
            (out / name / 'run.log').write_text(log)
        self.assertIn('started the suite lane', self.scene.tick())

    def test_a_fetch_that_fails_does_nothing_and_keeps_the_state(self):
        self.scene.tick()
        before = self.scene.text('state.json')
        shutil.move(str(self.scene.origin), str(self.scene.origin) + '.away')
        line = self.scene.tick()
        self.assertRegex(line, r'could not fetch origin/main \(git exit \d+\) — nothing done$')
        self.assertEqual(json.loads(self.scene.text('state.json'))['current'], json.loads(before)['current'])
        self.assertEqual(len(self.scene.calls()), 1)

    def test_poisoned_state_is_empty_state_not_a_traceback(self):
        watch_dir = self.scene.root / 'watch'
        watch_dir.mkdir()
        for poison in ('{not json', '[]', '"text"', json.dumps(dict(settled='x', current=[1], runs=7, start_failures=None, base=5)),
                       json.dumps(dict(settled=[['only-one'], 3, ['a', 'b']], current=dict(sha=1, out=2, started='soon')))):
            with self.subTest(poison=poison[:20]):
                (watch_dir / 'state.json').write_text(poison)
                (watch_dir / 'history.log').write_bytes(b'\xff\xfe old line\n')
                line = self.scene.tick()
                self.assertRegex(line, r'saw [0-9a-f]{9} — ')
                json.loads(self.scene.text('state.json'))

    def test_only_one_tick_at_a_time(self):
        import fcntl
        (self.scene.root / 'watch').mkdir()
        fd = os.open(str(self.scene.root / 'watch' / 'lock'), os.O_RDWR | os.O_CREAT, 0o644)
        fcntl.flock(fd, fcntl.LOCK_EX)
        try:
            self.assertEqual(self.scene.tick(), 'another tick is still running')
            self.assertEqual(self.scene.calls(), [])
        finally:
            os.close(fd)

    def test_history_and_state_are_bounded(self):
        watch = self.scene.watch
        os.makedirs(watch.dir)
        watch.load()
        for n in range(mw.HISTORY_KEPT + 60):
            watch.settle(f'{n:040x}', 'GREEN', 'x')
        watch.state['runs'] = {f'{n:040x}': 1 for n in range(40)}
        watch.save()
        state = json.loads(self.scene.text('state.json'))
        self.assertEqual(len(state['settled']), mw.SETTLED_KEPT)
        self.assertEqual(len(self.scene.text('history.log').splitlines()), mw.HISTORY_KEPT)
        self.assertEqual(len(self.scene.text('verdict.txt').splitlines()), 1)
        self.assertEqual(len(state['runs']), 40, 'a counter is kept until its commit is settled')
        self.assertEqual(watch.status().splitlines()[0][:15], 'watch verdict: ')

    def test_the_watcher_never_signals_pushes_or_writes_a_branch(self):
        source = (SCRIPTS / 'm4_watch.py').read_text()
        code = source.split('"""', 2)[2]
        for never in ('os.kill', 'killpg', '.terminate(', 'send_signal', 'pkill', '"push"', '"commit"', '"checkout"', '"reset"',
                      'refs/heads/main:refs/heads', 'refs/remotes', 'metrics', 'catalog.sqlite', 'ssh'):
            self.assertNotIn(never, code, never)
        self.assertIn('"+refs/heads/main:" + REF', code)
        self.assertIn('[self.bash, self.runner, LANE, "--host", "m4local", "--ref", sha, "--unless-ran"]', code)
        self.assertNotIn("'", source, 'the watcher may be shipped inside a heredoc')


class EndToEndTests(Testbed):
    """The real m4_run.sh, pinned in <fake HOME>/m4run/bin/watch (not a checkout), started by a real tick."""
    HOST = 'm4'
    ROOT = 'm4run'

    def setUp(self):
        super().setUp()
        self.repo = self.home / 'dev' / 'VideoScan'
        self.repo.mkdir(parents=True)
        self.sha = self.make_repo(self.repo)
        subprocess.run([GIT, '-C', str(self.repo), 'branch', '-M', 'main'], check=True, env=self.git_env)
        origin = self.home / 'origin.git'
        subprocess.run([GIT, 'clone', '-q', '--bare', str(self.repo), str(origin)], check=True, env=self.git_env)
        subprocess.run([GIT, '-C', str(self.repo), 'remote', 'add', 'origin', str(origin)], check=True, env=self.git_env)
        self.pinned = self.root / 'bin' / 'watch'
        (self.pinned / 'lib').mkdir(parents=True)
        for name in PINNED:
            shutil.copy(SCRIPTS / name, self.pinned / name)
        for name, body in (('hostname', '#!/bin/sh\necho RicksM4\n'),
                           ('date', '#!/bin/sh\n[ "$1" = "+%H%M" ] && { echo 1030; exit 0; }\nexec /bin/date "$@"\n')):
            (self.bin / name).write_text(body)
            (self.bin / name).chmod(0o755)
        self.env['PATH'] = f"{self.bin}:{os.environ['PATH']}"

    def test_a_tick_starts_the_real_suite_lane_and_a_later_tick_writes_its_verdict(self):
        saved = dict(os.environ)
        os.environ.update(self.env)
        try:
            watch = mw.Watch(str(self.root), str(self.repo), str(self.pinned / 'm4_run.sh'), 'RicksM4', git=GIT)
            first = watch.tick()
            self.assertIn(f'saw {self.sha[:9]} — started the suite lane (run 1 of at most 2)', first)
            out = pathlib.Path(json.loads((self.root / 'watch' / 'state.json').read_text())['current']['out'])
            self.assertEqual(out.parent, self.root / 'out')
            import time
            deadline = time.time() + 120
            while time.time() < deadline and 'OUTCOME' not in ((out / 'run.log').read_text() if (out / 'run.log').exists() else ''):
                time.sleep(0.5)
            self.assertIn('OUTCOME GREEN', (out / 'run.log').read_text())
            second = watch.tick()
        finally:
            os.environ.clear()
            os.environ.update(saved)
        self.assertIn(f'the run of {self.sha[:9]} ended GREEN', second)
        self.assertRegex((self.root / 'watch' / 'verdict.txt').read_text(),
                         self.sha[:9] + r' suite GREEN — suite: GREEN app 5 passed, 0 failed, 1 skipped; core 4 passed')
        self.assertEqual(probe(self.root / 'lock'), 'FREE')
        self.assert_nothing_published()
        # The run folder's prune left the pinned scripts alone, and `status` shows the verdict line.
        self.assertTrue((self.pinned / 'm4_watch.py').exists())
        os.utime(self.pinned, (1000, 1000))
        th.prune(str(self.root), keep=1)
        self.assertTrue((self.pinned / 'm4_run.sh').exists(), 'the prune removed the pinned watcher')
        status = subprocess.run(['/bin/bash', str(self.pinned / 'm4_run.sh'), 'status', '--host', 'm4local'],
                                capture_output=True, text=True, env=self.env, timeout=60).stdout
        self.assertRegex(status, r'(?m)^push watcher: \S+ \S+ ' + self.sha[:9] + ' suite GREEN')
        self.assertRegex(status, r'(?m)^push watcher, last tick: ')
        value = json.loads(subprocess.run(['/bin/bash', str(self.pinned / 'm4_run.sh'), 'status', '--host', 'm4local', '--json'],
                                          capture_output=True, text=True, env=self.env, timeout=60).stdout)
        self.assertIn('suite GREEN', value['watch'])

    def test_a_run_by_hand_that_finishes_after_the_tick_looked_is_caught_under_the_lock(self):
        # Codex #315-5: the tick asks "already run?" (no: the run by hand has no OUTCOME yet); that run
        # then finishes and frees the lock before the watcher's run takes it. The host side asks again
        # UNDER the lock and refuses; the next tick records the hand run's verdict. No second START.
        by_hand = self.root / 'out' / '20261118_010000_1-suite'
        by_hand.mkdir(parents=True)
        (by_hand / 'run.log').write_text(f'START 2026-11-18 01:00:00 host=M4 lane=suite sha={self.sha}\n')
        saved = dict(os.environ)
        os.environ.update(self.env)
        try:
            watch = mw.Watch(str(self.root), str(self.repo), str(self.pinned / 'm4_run.sh'), 'RicksM4', git=GIT)
            looked = watch.already_run

            def finishes_right_after(sha):
                answer = looked(sha)
                with open(by_hand / 'run.log', 'a') as f:
                    f.write('OUTCOME AMBER 2026-11-18 01:59:00 lane=suite sha=x\n')
                return answer
            watch.already_run = finishes_right_after
            first = watch.tick()
            self.assertIn('started the suite lane', first)
            out = pathlib.Path(json.loads((self.root / 'watch' / 'state.json').read_text())['current']['out'])
            import time
            deadline = time.time() + 60
            while time.time() < deadline and 'OUTCOME' not in ((out / 'run.log').read_text() if (out / 'run.log').exists() else ''):
                time.sleep(0.2)
            log = (out / 'run.log').read_text()
            self.assertIn(f'OUTCOME REFUSED already-run AMBER — sha={self.sha[:9]}', log)
            self.assertNotIn('START', log, 'the commit was run a second time')
            watch.already_run = looked
            second = watch.tick()
        finally:
            os.environ.clear()
            os.environ.update(saved)
        self.assertIn(f'{self.sha[:9]} was already run (AMBER), found under the lock: recorded, not run again', second)
        self.assertRegex((self.root / 'watch' / 'verdict.txt').read_text(), self.sha[:9] + ' suite AMBER — run by hand')
        self.assertFalse(any(' test-without-building ' in c or c.startswith('swift') for c in self.calls()), 'the suite ran')

    def test_the_host_side_refuses_an_already_run_commit_only_when_asked(self):
        out = self.root / 'out' / 'x1-testbed'
        out.mkdir(parents=True)
        (out / 'run.log').write_text(f'START now host=M4 lane=testbed sha={self.sha}\nOUTCOME RED then lane=testbed sha=x\n')
        work = self.root / 'work'
        subprocess.run([GIT, '-C', str(self.repo), 'worktree', 'add', '-q', '--detach', str(work), self.sha], check=True, env=self.git_env)
        p = subprocess.run(['/bin/bash', str(self.pinned / 'm4_run.sh'), '__host', 'suite', self.sha, 'u1', '--host', 'm4', '--unless-ran'],
                           capture_output=True, text=True, env=self.env, timeout=120)
        self.assertEqual(p.returncode, 6)
        self.assertIn('OUTCOME REFUSED already-run RED', (self.root / 'out' / 'u1-suite' / 'run.log').read_text())
        self.assertEqual(self.calls(), [])
        p = subprocess.run(['/bin/bash', str(self.pinned / 'm4_run.sh'), '__host', 'suite', self.sha, 'u2', '--host', 'm4'],
                           capture_output=True, text=True, env=self.env, timeout=180)
        self.assertEqual(p.returncode, 0, (self.root / 'out' / 'u2-suite' / 'run.log').read_text())

    def assert_nothing_published(self):
        self.assertFalse((self.fake / 'tripped').exists())
        for call in self.calls():
            if call.startswith('git '):
                for word in (' push', ' pull', ' commit', 'metrics'):
                    self.assertNotIn(word, call)


class InstallerTests(unittest.TestCase):

    def run_sh(self, *args, env=None):
        return subprocess.run(['/bin/bash', str(SCRIPTS / 'm4_watch_install.sh'), *args], capture_output=True, text=True, env=env, timeout=120)

    def test_usage_errors_exit_2(self):
        for args in ([], ['bogus'], ['install', 'extra'], ['install', '--dry-run', 'extra'], ['status', '--force']):
            self.assertEqual(self.run_sh(*args).returncode, 2, args)

    def test_the_plist_is_a_gui_session_agent_ticking_a_pinned_copy_every_300_seconds(self):
        text = (SCRIPTS / 'launchd' / 'com.videoscan.m4watch.plist').read_text()
        plist = plistlib.loads(text.encode())
        self.assertEqual(plist['Label'], 'com.videoscan.m4watch')
        self.assertEqual(plist['ProgramArguments'], ['/usr/bin/python3', '__HOME__/m4run/bin/watch/m4_watch.py', 'tick'])
        self.assertEqual((plist['StartInterval'], plist['LimitLoadToSessionType'], plist['RunAtLoad']), (300, 'Aqua', True))
        self.assertNotIn('KeepAlive', plist)
        self.assertTrue(plist['StandardOutPath'].startswith('__HOME__/m4run/watch/'))
        self.assertNotIn('dev/VideoScan', text, 'the agent never runs from a checkout')

    def test_the_dry_run_plan_from_another_mac_goes_to_the_m4_and_writes_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            fake = pathlib.Path(tmp, 'hostname')
            fake.write_text('#!/bin/sh\necho RicksUltra\n')
            fake.chmod(0o755)
            env = dict(os.environ, HOME=tmp, PATH=f"{tmp}:{os.environ['PATH']}")
            p = self.run_sh('install', '--dry-run', env=env)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertEqual(os.listdir(tmp), ['hostname'])
            out = p.stdout
            self.assertIn("+ ssh ricksm4.local <<'SH'", out)
            self.assertNotIn("+ bash <<'SH'", out)
            for name in PINNED:
                self.assertIn(f'install {SCRIPTS}/{name} -> ricksm4.local:~/m4run/bin/watch.new/{name}', out)
            self.assertIn('this Mac is not the M4', out, 'every host snippet carries the guard')
            self.assertIn('launchctl bootstrap "gui/$uid" "$HOME/Library/LaunchAgents/com.videoscan.m4watch.plist"', out)
            self.assertLess(out.index('launchctl bootout'), out.index('mv "$new" "$pinned"'), 'the agent stops before the copy is swapped')
            for verb in ('uninstall', 'status'):
                p = self.run_sh(verb, '--dry-run', env=env)
                self.assertEqual(p.returncode, 0, p.stderr)
                self.assertIn('com.videoscan.m4watch', p.stdout)
            self.assertNotIn(' rm ', self.run_sh('uninstall', '--dry-run', env=env).stdout, 'uninstall moves, never deletes')

    def test_the_pinned_set_is_everything_the_suite_lane_installs(self):
        text = (SCRIPTS / 'm4_watch_install.sh').read_text()
        for name in PINNED:
            self.assertIn(name, text.split('PINNED=(', 1)[1].split(')', 1)[0], name)
        for needed in ('m4_run_summary.py', 'testbed_lock.py', 'testbed_host.py', 'nightly_local_tests.sh', 'lib/process_group_watchdog.sh'):
            self.assertIn(f'"$SCRIPT_DIR/{needed}"', (SCRIPTS / 'm4_run.sh').read_text(), needed)

    def test_install_uninstall_and_reinstall_on_a_fake_m4_and_a_refusal_anywhere_else(self):
        with tempfile.TemporaryDirectory() as tmp:
            home, tools, fake = pathlib.Path(tmp, 'home'), pathlib.Path(tmp, 'tools'), pathlib.Path(tmp, 'fake')
            for d in (home, tools, fake):
                d.mkdir()
            (tools / 'hostname').write_text('#!/bin/sh\ncat "$WATCH_FAKE/hostname"\n')
            (tools / 'launchctl').write_text(FAKE_LAUNCHCTL_LOG)
            for tool in tools.iterdir():
                tool.chmod(0o755)
            env = dict(os.environ, HOME=str(home), WATCH_FAKE=str(fake), PATH=f"{tools}:{os.environ['PATH']}")
            agents = home / 'Library' / 'LaunchAgents' / 'com.videoscan.m4watch.plist'
            pinned = home / 'm4run' / 'bin' / 'watch'

            (fake / 'hostname').write_text('RicksM4\n')
            p = self.run_sh('status', env=env)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertIn('com.videoscan.m4watch: not loaded', p.stdout)
            self.assertIn('plist: not installed', p.stdout)

            p = self.run_sh('install', env=env)
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
            self.assertRegex(p.stdout, r'installed: com\.videoscan\.m4watch in gui/\d+ — plist \S+/Library/LaunchAgents/com\.videoscan\.m4watch\.plist, '
                                       r'every 300 s, pinned scripts \S+/m4run/bin/watch at [0-9a-f]{40}')
            for name in PINNED:
                self.assertEqual((pinned / name).read_bytes(), (SCRIPTS / name).read_bytes(), name)
            self.assertRegex((pinned / 'VERSION').read_text(), r'^[0-9a-f]{40}\n$')
            plist = plistlib.loads(agents.read_bytes())
            self.assertEqual(plist['ProgramArguments'][1], f'{home}/m4run/bin/watch/m4_watch.py')
            self.assertNotIn('__HOME__', agents.read_text())
            calls = (fake / 'launchctl-calls').read_text().splitlines()
            self.assertRegex(calls[-1], r'^bootstrap gui/\d+ ' + str(agents) + '$')
            self.assertIn('com.videoscan.m4watch: loaded', self.run_sh('status', env=env).stdout)

            p = self.run_sh('uninstall', env=env)
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
            self.assertIn('booted out com.videoscan.m4watch', p.stdout)
            self.assertFalse(agents.exists())
            moved = list((home / 'm4run' / 'watch' / 'uninstalled').iterdir())
            self.assertEqual(len(moved), 1, 'the plist is moved, not deleted')
            self.assertTrue((pinned / 'm4_watch.py').exists(), 'the pinned scripts stay')
            self.assertIn('com.videoscan.m4watch: not loaded', self.run_sh('status', env=env).stdout)
            self.assertIn('was not loaded', self.run_sh('uninstall', env=env).stdout, 'a second uninstall is harmless')

            (pinned / 'm4_watch.py').write_text('# an older copy\n')
            p = self.run_sh('install', env=env)                       # reinstall: the rollback's way back
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
            self.assertEqual((pinned / 'm4_watch.py').read_bytes(), (SCRIPTS / 'm4_watch.py').read_bytes())
            self.assertEqual(len(list((home / 'm4run' / 'watch' / 'replaced').iterdir())), 1, 'the replaced copy is kept')
            self.assertTrue(agents.exists())

            # Any other Mac: the dry run shows ssh; and the host snippet itself refuses where it lands.
            (fake / 'hostname').write_text('RicksUltra\n')
            guard = (SCRIPTS / 'm4_watch_install.sh').read_text().split("GUARD='", 1)[1].split("'\n", 1)[0]
            landed = subprocess.run(['/bin/bash', '-c', guard + '\necho WROTE'], capture_output=True, text=True, env=env, timeout=30)
            self.assertEqual(landed.returncode, 1)
            self.assertIn('refused — this Mac is not the M4', landed.stdout)
            self.assertNotIn('WROTE', landed.stdout)


if __name__ == '__main__':
    unittest.main()
