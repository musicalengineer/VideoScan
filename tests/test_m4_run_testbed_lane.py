"""scripts/m4_run.sh testbed — everything on the M4 at one commit, one verdict.

The lane is the suite lane, then corpus `check`, then corpus `proof`, under one
hold of the testbed lock, with ONE summary block (m4_run_summary.py --testbed).
These tests pin, without a host:

  * the host side for real in a fake HOME: the real m4_run.sh, the real nightly
    runner and the real summary (stand-ins for xcodebuild / swift, as in
    tests/test_m4_run_suite_lane.py) and a stand-in for corpus_run.py that
    plays a corpus lane's exit code and facts file;
  * the verdict: RED over NORUN over AMBER over GREEN, each lane judged on its
    own, a later lane still run after an earlier RED, exit 0 only when nothing
    is RED or NORUN;
  * the block: first in the summary, one row per lane with counts and wall
    time, a corpus lane's diff under its row;
  * isolation: one lane's stale summary is never read as another's; a facts
    file that is missing, poisoned or says a word nobody knows is never a pass;
  * the caller: M4 only, no lane options, the dry-run plan, `--host m4local`
    refused off the M4, and --wait's exit codes through the local mode;
  * `status` reading the last testbed run back after a later run of another lane.

No ssh, no real xcodebuild, no corpus, no network.
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
from test_m4_run_suite_lane import Testbed, app_log, probe  # noqa: E402

RUNNER_FILES = ('m4_run.sh', 'm4_run_summary.py', 'testbed_lock.py', 'testbed_host.py', 'nightly_local_tests.sh',
                'lib/process_group_watchdog.sh')

# Stand-in for corpus_run.py on the host: plays the lane from $SUITE_FAKE/corpus-<lane>.json
# ({"exit": n, "facts": {...} | null, "summary": text | null}) and records its call.
STUB_CORPUS = r'''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
lane, out = args[1], args[args.index("--out") + 1]
fake = os.environ["SUITE_FAKE"]
with open(os.path.join(fake, "calls"), "a") as f:
    f.write("corpus_run.py " + " ".join(args) + (" LOCKFD" if os.path.exists("/dev/fd/9") else " NOLOCK") + "\n")
plan = json.load(open(os.path.join(fake, "corpus-%s.json" % lane)))
if plan.get("summary") is not None:
    open(os.path.join(out, "corpus-summary.txt"), "w").write(plan["summary"])
if plan.get("facts") is not None:
    open(os.path.join(out, "corpus-verdict.json"), "w").write(
        plan["facts"] if isinstance(plan["facts"], str) else json.dumps(plan["facts"]))
sys.exit(plan["exit"])
'''
FAKE_HOSTNAME = '#!/bin/sh\necho ricksm4\n'


def facts(lane, verdict='GREEN', files=3, against=None, **more):
    engines = {'check': {'probe': {'probed': files}, 'check': {'OK': files - 1, 'Warning': 1}, 'audio': {'healthy': files}},
               'proof': {'balance': {'balanced': files}, 'proof': {'same_content': files}}}[lane]
    order = {'check': ['probe', 'check', 'audio'], 'proof': ['balance', 'proof']}[lane]
    return dict(lane=lane, verdict=verdict, sha='abcdef012', files=files, bytes=1000, wall_s=12.0, engines=engines,
                engine_order=order, failures={}, against=against, **more)


class TestbedScene(Testbed):
    """The fake M4: runner files installed in a bin folder as on the host, the corpus stand-in beside them."""

    def setUp(self):
        super().setUp()
        self.work = self.root / 'work'
        self.work.mkdir()
        self.sha = self.make_repo(self.work)
        self.install = self.home / 'installed'
        (self.install / 'lib').mkdir(parents=True)
        for name in RUNNER_FILES:
            shutil.copy(SCRIPTS / name, self.install / name)
        (self.install / 'corpus_run.py').write_text(STUB_CORPUS)
        self.corpus('check')
        self.corpus('proof')
        # The host side of the corpus lanes runs only on the M4 (Codex #311 F5): a stand-in `hostname` says this is it.
        (self.bin / 'hostname').write_text(FAKE_HOSTNAME)
        (self.bin / 'hostname').chmod(0o755)
        self.env['PATH'] = f"{self.bin}:{os.environ['PATH']}"

    def corpus(self, lane, exit_code=0, verdict='GREEN', summary='', lane_facts='default', **more):
        if lane_facts == 'default':
            lane_facts = facts(lane, verdict, **more)
        if summary == '':
            summary = f'corpus {lane}: {verdict} counts only\n'
        (self.fake / f'corpus-{lane}.json').write_text(json.dumps(dict(exit=exit_code, facts=lane_facts, summary=summary)))

    def host(self, stamp, lane='testbed', *extra):
        p = subprocess.run(['/bin/bash', str(self.install / 'm4_run.sh'), '__host', lane, self.sha, stamp, '--host', 'm4', *extra],
                           capture_output=True, text=True, env=self.env, timeout=180)
        out = self.root / 'out' / f'{stamp}-{lane}'
        summary = out / 'summary.txt'
        return p, (out / 'run.log').read_text(), summary.read_text() if summary.exists() else '', out


class HostTestbedLaneTests(TestbedScene):

    def test_three_green_lanes_are_one_green_verdict_with_one_block(self):
        p, log, summary, out = self.host('t1')
        self.assertEqual(p.returncode, 0, log)
        self.assertRegex(log, r'(?m)^START \S+ \S+ host=M4 lane=testbed sha=' + self.sha + '$')
        self.assertRegex(log, r'(?m)^OUTCOME GREEN \S+ \S+ lane=testbed sha=' + self.sha[:9] + '$')
        self.assertEqual(len([line for line in log.splitlines() if line.startswith(('START', 'OUTCOME'))]), 2)
        lines = summary.splitlines()
        self.assertRegex(lines[0], r'^testbed: GREEN at ' + self.sha[:9] + r' — 3 lanes, wall \d+s$')
        self.assertRegex(lines[1], r'^  suite         GREEN +\d+s  app 5 passed, 0 failed, 1 skipped; core 4 passed, 0 failed, 0 skipped$')
        check = next(i for i, line in enumerate(lines) if line.startswith('  corpus check '))
        proof = next(i for i, line in enumerate(lines) if line.startswith('  corpus proof '))
        self.assertLess(check, proof)
        self.assertRegex(lines[check], r'GREEN +\d+s  3 files — probe: probed 3 · check: OK 2, Warning 1 · audio: healthy 3$')
        self.assertIn("nothing to compare against: this is the lane's first run", lines[check + 1])
        self.assertRegex(lines[proof], r'GREEN +\d+s  3 files — balance: balanced 3 · proof: same_content 3$')
        # The lanes' own lines follow the block, each once.
        rest = '\n'.join(lines[lines.index("— the lanes' own lines —"):])
        for own in ('suite: GREEN app 5 passed', 'corpus check: GREEN counts only', 'corpus proof: GREEN counts only'):
            self.assertEqual(rest.count(own), 1, own)
        self.assertEqual((out / 'testbed-block.txt').read_text().splitlines(), lines[:lines.index("— the lanes' own lines —")])
        self.assert_nothing_published()

    def test_the_lanes_run_in_order_under_one_hold_of_the_lock_at_one_commit(self):
        p, log, _, out = self.host('t2')
        self.assertEqual(p.returncode, 0, log)
        calls = self.calls()
        suite_test = next(i for i, c in enumerate(calls) if ' test-without-building ' in c)
        corpus = [(i, c) for i, c in enumerate(calls) if c.startswith('corpus_run.py ')]
        self.assertEqual([c.split()[1:3] for _, c in corpus], [['host', 'check'], ['host', 'proof']])
        self.assertLess(suite_test, corpus[0][0], 'the suite runs first')
        for (_, call), lane in zip(corpus, ('check', 'proof')):
            args = call.split()
            for flag, value in (('--sha', self.sha), ('--stamp', 't2'), ('--out', str(out / f'corpus-{lane}')),
                                ('--worktree', str(self.work)), ('--bin', str(self.install))):
                self.assertEqual(args[args.index(flag) + 1], value, flag)
            self.assertTrue(call.endswith(' LOCKFD'), 'a corpus lane must inherit the testbed lock (fd 9)')
            self.assertNotIn('--limit', call)
            self.assertNotIn('--deadline', call)
        self.assertEqual(probe(self.root / 'lock'), 'FREE', 'lock left behind')
        self.assertEqual(os.readlink(self.root / 'latest-testbed'), str(out))
        self.assertEqual(os.readlink(self.root / 'latest'), str(out))
        self.assertFalse((self.root / 'latest-suite').exists(), "latest-suite is the suite lane's own")
        rows = [line.split('\t') for line in (out / 'lanes.tsv').read_text().splitlines()]
        self.assertEqual([(r[0], r[1]) for r in rows], [('suite', 'GREEN'), ('corpus check', 'GREEN'), ('corpus proof', 'GREEN')])

    def test_an_amber_corpus_lane_makes_the_run_amber_and_shows_its_diff(self):
        against = dict(what='the previous run', run='20261117_194337_87818', sha='e24b3a200', compared=3, changed=2,
                       only_new=0, only_old=1, transitions={'check: OK -> Problem': 2})
        self.corpus('check', exit_code=3, verdict='AMBER', against=against)
        p, log, summary, _ = self.host('a1')
        self.assertEqual(p.returncode, 0, log)
        self.assertRegex(log, r'(?m)^OUTCOME AMBER .* lane=testbed sha=\w+ — suite GREEN · corpus check AMBER · corpus proof GREEN$')
        self.assertTrue(summary.startswith('testbed: AMBER at '), summary)
        self.assertIn('against the previous run 20261117_194337_87818 at e24b3a200: 2 of 3 files changed (new 0, absent 1)', summary)
        self.assertIn('  check: OK -> Problem x2', summary)

    def test_a_red_suite_is_a_red_run_and_the_corpus_lanes_still_run(self):
        self.plant(app=app_log(failed=('theLedgerKeepsEveryRow()',)), test_rc=65)
        p, log, summary, _ = self.host('r1')
        self.assertEqual(p.returncode, 1, log)
        self.assertRegex(log, r'(?m)^OUTCOME RED .* — suite RED · corpus check GREEN · corpus proof GREEN$')
        self.assertTrue(summary.startswith('testbed: RED at '), summary)
        self.assertRegex(summary, r'(?m)^  suite         RED +\d+s  failed-tests:1 — app 5 passed, 1 failed')
        self.assertIn('  failed (app): theLedgerKeepsEveryRow() — VideoScan/VideoScanTests/LedgerTests.swift:3', summary)
        self.assertEqual(len([c for c in self.calls() if c.startswith('corpus_run.py ')]), 2)

    def test_a_lane_that_could_not_run_is_norun_and_never_exit_zero(self):
        self.corpus('proof', exit_code=4, verdict='NORUN', files=0)
        p, log, summary, _ = self.host('n1')
        self.assertEqual(p.returncode, 1, log)
        self.assertRegex(log, r'(?m)^OUTCOME NORUN .* — suite GREEN · corpus check GREEN · corpus proof NORUN$')
        self.assertTrue(summary.startswith('testbed: NORUN at '), summary)
        self.assertRegex(summary, r'(?m)^  corpus proof  NORUN +\d+s  not run: this ref has no engine for the lane$')

    def test_the_machine_preflight_is_norun_and_red_outranks_it(self):
        self.plant(automation='REQUIRES')
        p, log, summary, _ = self.host('n2')
        self.assertEqual(p.returncode, 1, log)
        self.assertRegex(log, r'(?m)^OUTCOME NORUN .* — suite NORUN · corpus check GREEN · corpus proof GREEN$')
        self.assertRegex(summary, r'(?m)^  suite         NORUN +\d+s  machine-setup:automation-mode — ')
        self.corpus('check', exit_code=1, verdict='RED')
        p, log, summary, _ = self.host('n3')
        self.assertEqual(p.returncode, 1, log)
        self.assertRegex(log, r'(?m)^OUTCOME RED .* — suite NORUN · corpus check RED · corpus proof GREEN$')
        self.assertTrue(summary.startswith('testbed: RED at '), summary)

    def test_a_corpus_lane_that_dies_without_a_summary_is_red_and_borrows_nothing(self):
        # Poisoned state: `check` wrote its summary and facts; `proof` dies having written neither.
        # Its row must be RED with no counts — never check's files read as proof's.
        self.corpus('proof', exit_code=99, summary=None, lane_facts=None)
        p, log, summary, out = self.host('d1')
        self.assertEqual(p.returncode, 1, log)
        self.assertRegex(log, r'(?m)^OUTCOME RED .* — suite GREEN · corpus check GREEN · corpus proof RED$')
        self.assertIn('corpus proof: RED the harness stopped (rc=99; see corpus.log on the M4)', summary)
        self.assertRegex(summary, r"(?m)^  corpus proof  RED +\d+s  no facts file")
        self.assertEqual(summary.count('corpus check: GREEN counts only'), 1)
        self.assertFalse((out / 'corpus-summary.txt').exists(), "each corpus lane's files are in its own folder")
        self.assertTrue((out / 'corpus-check' / 'corpus-summary.txt').exists())

    def test_a_poisoned_facts_file_does_not_stop_the_block_or_pass(self):
        self.corpus('check', lane_facts='{not json')
        self.corpus('proof', exit_code=3, verdict='AMBER', lane_facts=dict(verdict='AMBER', files='many', engines='x', against=7))
        p, log, summary, _ = self.host('p1')
        self.assertEqual(p.returncode, 0, log)
        self.assertTrue(summary.startswith('testbed: AMBER at '), summary)
        self.assertRegex(summary, r"(?m)^  corpus check  GREEN +\d+s  no facts file")
        self.assertRegex(summary, r"(?m)^  corpus proof  AMBER +\d+s  no count of files — $")

    def test_a_held_lock_refuses_before_touching_anything(self):
        lock = self.root / 'lock'
        lock.mkdir()
        fd = os.open(str(lock / 'flock'), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
        try:
            subprocess.run([sys.executable, str(SCRIPTS / 'testbed_lock.py'), 'hold', str(fd), str(lock), 'corpus sha=abc since 21:00'],
                           capture_output=True, text=True, pass_fds=(fd,), timeout=20)
            p, log, _, _ = self.host('b1')
            self.assertEqual(p.returncode, 3)
            self.assertIn('OUTCOME REFUSED busy: corpus sha=abc since 21:00', log)
            self.assertFalse((self.root / 'latest-testbed').exists())
            self.assertEqual(self.calls(), [], 'a refused run ran something')
        finally:
            os.close(fd)

    def test_status_shows_the_last_testbed_run_also_after_another_lane(self):
        _, _, _, out = self.host('s1')
        (self.work / 'VideoScan/VideoScanCore/Package.swift').write_text('// edited\n')
        later, _, _, _ = self.host('s2', 'ui')
        self.assertEqual(later.returncode, 4)
        status = subprocess.run(['/bin/bash', str(SCRIPTS / 'm4_run.sh'), 'status', '--host', 'm4', '--dry-run'],
                                capture_output=True, text=True, env=self.env, timeout=60).stdout
        snippet = status.split("+ ssh ricksm4.local <<'SH'", 1)[1].split('\n  SH', 1)[0]
        snippet = '\n'.join(line[4:] if line.startswith('    ') else line for line in snippet.splitlines())
        text = subprocess.run(['/bin/bash', '-s'], input=snippet, capture_output=True, text=True, env=self.env, timeout=30).stdout
        self.assertIn(f'last run: {self.root}/out/s2-ui', text)
        self.assertIn(f'last testbed run: {out}', text)
        self.assertIn('  OUTCOME GREEN', text)
        self.assertRegex(text, r'(?m)^  testbed: GREEN at \w+ — 3 lanes')
        self.assertRegex(text, r'(?m)^    corpus proof  GREEN')
        self.assertNotIn("the lanes' own lines", text, 'status shows the block, not every lane line')


class BlockTests(unittest.TestCase):
    """m4_run_summary.testbed_block: the verdict precedence and what a row may say."""

    def block(self, *rows):
        with tempfile.TemporaryDirectory() as tmp:
            out = []
            for i, (name, verdict, value) in enumerate(rows):
                path = pathlib.Path(tmp, f'{i}.json')
                if value is not None:
                    path.write_text(json.dumps(value))
                out.append((name, verdict, '5', str(path)))
            return ms.testbed_block(out, 'a' * 40, 60)

    def test_red_over_norun_over_amber_over_green(self):
        row = dict(passed=1, failed=0, skipped=0, core_passed=1, core_failed=0)
        for verdicts, want in ((('GREEN', 'GREEN', 'GREEN'), 'GREEN'), (('GREEN', 'AMBER', 'GREEN'), 'AMBER'),
                               (('AMBER', 'NORUN', 'GREEN'), 'NORUN'), (('NORUN', 'AMBER', 'RED'), 'RED'),
                               (('RED', 'GREEN', 'GREEN'), 'RED')):
            got, lines = self.block(('suite', verdicts[0], row), ('corpus check', verdicts[1], facts('check', verdicts[1])),
                                    ('corpus proof', verdicts[2], facts('proof', verdicts[2])))
            self.assertEqual(got, want, verdicts)
            self.assertTrue(lines[0].startswith(f'testbed: {want} at aaaaaaaaa — 3 lanes, wall 60s'), lines[0])

    def test_no_lane_or_an_unknown_verdict_word_is_red(self):
        got, lines = self.block()
        self.assertEqual(got, 'RED')
        self.assertIn('no lane ran', lines[0])
        got, lines = self.block(('corpus check', 'PASSED?', facts('check')))
        self.assertEqual(got, 'RED')
        self.assertIn('corpus check  RED', lines[1])

    def test_a_row_carries_counts_and_at_most_a_bounded_list(self):
        against = dict(what='its baseline', run='r1', sha='b' * 40, compared=500, changed=100, only_new=0, only_old=0,
                       transitions={f'check: OK -> W{i}': 1 for i in range(100)},
                       listed=[f'{i:012x} check: OK -> W{i}' for i in range(100)])
        _, lines = self.block(('corpus check', 'AMBER', facts('check', 'AMBER', files=500, against=against)))
        self.assertIn('against its baseline r1 at bbbbbbbbb: 100 of 500 files changed', lines[2])
        self.assertLessEqual(len(lines), 3 + 2 * ms.NAMES_PROVEN, 'the block is a table, not a file list')

    def test_cli_exit_codes(self):
        with tempfile.TemporaryDirectory() as tmp:
            lanes = pathlib.Path(tmp, 'lanes.tsv')
            for verdict, want in (('GREEN', 0), ('AMBER', 3), ('NORUN', 4), ('RED', 1)):
                lanes.write_text(f'corpus check\t{verdict}\t7\t{tmp}/none.json\n')
                done = subprocess.run([sys.executable, str(SCRIPTS / 'm4_run_summary.py'), '--testbed', str(lanes), 'c' * 40, '9'],
                                      capture_output=True, text=True, timeout=60)
                self.assertEqual(done.returncode, want, done.stdout)
                self.assertTrue(done.stdout.startswith(f'testbed: {verdict} at ccccccccc — 1 lane, wall 9s'), done.stdout)
            missing = subprocess.run([sys.executable, str(SCRIPTS / 'm4_run_summary.py'), '--testbed', f'{tmp}/no.tsv', 'c' * 40, '9'],
                                     capture_output=True, text=True, timeout=60)
            self.assertEqual(missing.returncode, 1, 'no lanes file is red')
            lanes.write_text('a line that is not four fields\n')
            self.assertEqual(subprocess.run([sys.executable, str(SCRIPTS / 'm4_run_summary.py'), '--testbed', str(lanes), 'c' * 40, '9'],
                                            capture_output=True, text=True, timeout=60).returncode, 1)


class ArgumentAndDryRunTests(unittest.TestCase):

    def run_sh(self, *args, env=None):
        return subprocess.run(['/bin/bash', str(SCRIPTS / 'm4_run.sh'), *args], capture_output=True, text=True, env=env, timeout=120)

    def test_usage_errors_exit_2(self):
        for args in (['testbed', 'extra'], ['testbed', '--host', 'ultra', '--dry-run'], ['testbed', '--limit', '3', '--dry-run'],
                     ['testbed', '--deadline', '9', '--dry-run'], ['testbed', '--only', 'X', '--dry-run'],
                     ['testbed', '--corpus-lane', 'check', '--dry-run'], ['__host', 'testbed', 'a' * 40, 's', '--host', 'ultra'],
                     ['__host', 'testbed', 'a' * 40]):
            with self.subTest(args=args):
                self.assertEqual(self.run_sh(*args).returncode, 2, args)
        self.assertIn('run only on the M4', self.run_sh('testbed', '--host', 'ultra').stderr)

    def test_m4local_is_refused_on_any_mac_that_is_not_the_m4(self):
        with tempfile.TemporaryDirectory() as tmp:
            fake = pathlib.Path(tmp, 'hostname')
            for name in ('RicksUltra', 'ricksm5', 'ricksm4x', ''):
                fake.write_text(f'#!/bin/sh\necho "{name}"\n')
                fake.chmod(0o755)
                env = dict(os.environ, PATH=f"{tmp}:{os.environ['PATH']}", HOME=tmp)
                for lane in ('testbed', 'suite', 'status'):
                    p = self.run_sh(lane, '--host', 'm4local', '--dry-run', env=env)
                    self.assertEqual(p.returncode, 2, (name, lane, p.stdout))
                    self.assertIn('this Mac is not the M4', p.stderr)
            self.assertEqual(sorted(os.listdir(tmp)), ['hostname'])

    def test_dry_run_prints_the_plan_and_touches_nothing(self):
        sha = subprocess.run(['git', '-C', str(REPO), 'rev-parse', 'HEAD'], capture_output=True, text=True).stdout.strip()
        with tempfile.TemporaryDirectory() as home:
            p = self.run_sh('testbed', '--ref', 'HEAD', '--wait', '--dry-run', env=dict(os.environ, HOME=home))
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertEqual(os.listdir(home), [], 'a dry run wrote something')
        out = p.stdout
        self.assertIn(f'm4_run: testbed on M4 at {sha[:9]}', out)
        self.assertIn(f'push -q ricksm4.local:dev/VideoScan {sha}:refs/m4run/{sha}', out)
        for name in ('nightly_local_tests.sh', 'corpus_run.py', 'catalog_db.py', 'CorpusSeal.swift', 'CorpusDriverSupport.swift',
                     'CorpusCheckDriver.swift', 'CorpusProofDriver.swift', 'CorpusVerbsDriver.swift', 'testbed_lock.py', 'm4_run_summary.py'):
            self.assertRegex(out, rf'install .*{name} -> ricksm4\.local:.*/m4run/bin/\d{{8}}_\d{{6}}_\d+/{name}')
        self.assertIn('under one hold of the lock: the suite lane, then corpus_run.py host check, then corpus_run.py host proof', out)
        for arg in ('__host', 'testbed', sha, '--host', 'm4'):
            self.assertIn(f'<string>{arg}</string>', out)
        self.assertNotIn('--corpus-lane', out)
        self.assertNotIn('ultrarun', out)

    def test_the_lane_reuses_the_lanes_and_has_no_second_implementation(self):
        text = (SCRIPTS / 'm4_run.sh').read_text()
        start = text.index('host_testbed() {')
        body = text[start:text.index('\n}\n', start)]
        self.assertIn('testbed_lane "suite" "$OUT/suite-row.json" host_suite', body)
        self.assertIn('host_corpus "$sha" "$stamp"', body)
        for word in ('xcodebuild', 'swift test', 'nightly_local_tests', 'corpus_run.py', 'run_bounded'):
            self.assertNotIn(word, body, f'host_testbed runs {word} itself')


class CallerOnTheM4Tests(TestbedScene):
    """The caller end to end through `--host m4local` (a stand-in `hostname` says this Mac is the
    M4; a fake launchctl starts the agent as launchd would): --wait's exit codes."""

    def setUp(self):
        super().setUp()
        self.repo = self.home / 'dev' / 'VideoScan'
        (self.repo / 'scripts/lib').mkdir(parents=True)
        (self.repo / 'scripts/corpus').mkdir(parents=True)
        for name in RUNNER_FILES:
            shutil.copy(SCRIPTS / name, self.repo / 'scripts' / name)
        for name in ('corpus_run.py', 'corpus_ui_lane.py', 'catalog_db.py', 'corpus/CorpusSeal.swift', 'corpus/CorpusDriverSupport.swift', 'corpus/CorpusCheckDriver.swift',
                     'corpus/CorpusProofDriver.swift', 'corpus/CorpusVerbsDriver.swift'):
            (self.repo / 'scripts' / name).write_text(STUB_CORPUS)
        shutil.rmtree(self.work)                            # the host adds its testbed worktree from the repo
        self.sha = self.make_repo(self.repo)
        (self.bin / 'hostname').write_text(FAKE_HOSTNAME)
        (self.bin / 'hostname').chmod(0o755)
        (self.bin / 'date').write_text('#!/bin/sh\n[ "$1" = "+%H%M" ] && { echo 1730; exit 0; }\nexec /bin/date "$@"\n')
        (self.bin / 'date').chmod(0o755)
        self.env['PATH'] = f"{self.bin}:{os.environ['PATH']}"

    def caller(self, *extra):
        return subprocess.run(['/bin/bash', str(self.repo / 'scripts/m4_run.sh'), 'testbed', '--host', 'm4local',
                               '--ref', self.sha, *extra], capture_output=True, text=True, env=self.env, timeout=240)

    def test_wait_exits_0_on_green_without_ssh_or_a_push(self):
        p = self.caller('--wait')
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn('OUTCOME GREEN', p.stdout)
        self.assertRegex(p.stdout, r'(?m)^  testbed: GREEN at \w+ — 3 lanes')
        for call in self.calls():
            self.assertNotIn(' push ', call + ' ')
        self.assertEqual(probe(self.root / 'lock'), 'FREE')

    def test_wait_exits_1_on_red_and_2_when_a_lane_could_not_run(self):
        self.corpus('check', exit_code=1, verdict='RED')
        p = self.caller('--wait')
        self.assertEqual(p.returncode, 1, p.stdout + p.stderr)
        self.assertIn('OUTCOME RED', p.stdout)
        self.corpus('check')
        self.corpus('proof', exit_code=4, verdict='NORUN')
        p = self.caller('--wait')
        self.assertEqual(p.returncode, 2, p.stdout + p.stderr)
        self.assertIn('OUTCOME NORUN', p.stdout)


if __name__ == '__main__':
    unittest.main()
