"""scripts/testbed_host.py clean / sample — the M4 kept at least 50% free (DECISIONS 2026-11-18).

Rick: "after a testrun has been summarized, delete the temp data and cleanup, so we can keep
that 50% free, but when you are running the testbed, feel free to chew up disk space".

  tidy        once a run is summarized, its scratch goes (xcresult bundles, overlays, patched
              test-run files, unused publish paths); its summary, verdict files, run.log and a
              200-line tail of each other log stay, under their own names.
  the floor   before a run starts and after it ends, under the lock: finished runs are tidied
              and dead corpus work folders removed whatever the disk says; below 50% free,
              unfinished runs are tidied oldest first until the floor is met, and the lane
              build caches go only when that reaches the floor.
  confinement deletion is confined by resolved real path to ~/m4run, ~/corpus/work and the
              two m4run caches; never the corpus protected set, never through a link, never a
              tree with a mount in it, never under a run that holds the lock.
  the line    "disk: free N% ..." in the summary: the start, the lowest during the run, the end.

Everything runs in a temporary HOME with a fake disk (VIDEOSCAN_TESTBED_FAKE_DISK or a callable);
no host, no real disk figures.
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
SCRIPTS = REPO / 'scripts'
sys.path.insert(0, str(SCRIPTS))
sys.path.insert(0, str(REPO / 'tests'))
import testbed_host as th  # noqa: E402
from test_m4_run_suite_lane import probe  # noqa: E402
from test_m4_run_testbed_lane import TestbedScene  # noqa: E402

GB = 10 ** 9
PROTECTED = ('corpus-sha-v1.txt', 'corpus-manifest-v1.json', 'catalog-source-backup.sqlite', 'THIS_IS_TEST_DATA.txt',
             'share.credentials', 'media/clip.mov', 'media/sub/tape.dv', 'reports/check/baseline.json',
             'reports/check/abc/s1/outcomes.json', 'state/catalog.sqlite', 'live/LaCieWorkspace/share.mov')


class FakeDisk:
    """free = total - other - (bytes under the fake HOME): deleting there frees space, as on a real disk."""

    def __init__(self, home, total, other):
        self.home, self.total, self.other = str(home), total, other
        self.calls = 0

    def __call__(self, path):
        self.calls += 1
        used = self.other + th._measure(self.home, os.lstat(self.home).st_dev)[0]
        return max(self.total - used, 0), self.total


def full(home):
    """A full disk: nothing free, the floor 50 GB away."""
    return FakeDisk(home, 100 * GB, 100 * GB)


class Scene:
    """A fake M4 HOME: ~/m4run with run folders, ~/corpus with its protected set and work, the lane caches."""

    def __init__(self, tmp):
        self.home = pathlib.Path(tmp, 'home')
        self.root = self.home / 'm4run'
        self.out = self.root / 'out'
        self.out.mkdir(parents=True)
        self.corpus = self.home / 'corpus'
        for rel in PROTECTED:
            path = self.corpus / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'precious ' + rel.encode())
        (self.corpus / 'work').mkdir()
        self.caches = [self.home / 'Library/Caches/videoscan-m4run-dd', self.home / 'Library/Caches/videoscan-m4run-dd-suite']
        self.clock = time.time() - 30 * 86400

    def run(self, stamp, lane='suite', outcome='GREEN', size=4096, log_lines=500):
        self.clock += 60
        path = self.out / f'{stamp}-{lane}'
        path.mkdir()
        text = f'START 2026-11-18 10:00:00 host=M4 lane={lane} sha={"a" * 40}\n'
        if outcome:
            text += f'OUTCOME {outcome} 2026-11-18 11:00:00 lane={lane} sha=aaaaaaaaa\n'
        (path / 'run.log').write_text(text)
        (path / 'summary.txt').write_text(f'{lane}: {outcome or "?"} counts\n')
        (path / 'suite-row.json').write_text('{}\n')
        (path / 'lanes.tsv').write_text('suite\tGREEN\t1\t/x\n')
        (path / 'testbed-block.txt').write_text('testbed: GREEN\n')
        (path / 'testbed-block.raw').write_text('testbed: GREEN\n')
        (path / 'VideoScan-UI.tests.tsv').write_text('t\tpassed\n')
        (path / 'suite.log').write_text(''.join(f'line {i}\n' for i in range(log_lines)))
        bundle = path / 'suite-app.xcresult' / 'Data'
        bundle.mkdir(parents=True)
        (bundle / 'blob').write_bytes(b'x' * size)
        for lane_dir in ('corpus-check', 'corpus-proof'):
            d = path / lane_dir
            d.mkdir()
            (d / 'corpus-summary.txt').write_text('corpus: GREEN\n')
            (d / 'corpus-verdict.json').write_text('{}\n')
            (d / 'corpus-build.log').write_text(''.join(f'build {i}\n' for i in range(log_lines)))
            (d / 'corpus-x-1.xctestrun').write_text('<plist/>')
            (d / 'overlay-1').mkdir()
            (d / 'overlay-1' / 'Driver.swift').write_text('// driver')
        os.utime(path, (self.clock, self.clock))
        return path

    def work(self, name, size=1000):
        path = self.corpus / 'work' / name
        (path / 'vol').mkdir(parents=True)
        (path / 'vol' / 'clone.mov').write_bytes(b'c' * size)
        return path

    def cache(self, index, size):
        self.caches[index].mkdir(parents=True, exist_ok=True)
        (self.caches[index] / 'Build').mkdir(exist_ok=True)
        (self.caches[index] / 'Build' / 'blob').write_bytes(b'd' * size)

    def protected_snapshot(self):
        return {rel: (self.corpus / rel).read_bytes() for rel in PROTECTED}


def hold(root, info):
    """Hold the testbed lock as a run does (scripts/testbed_lock.py), until the returned fd is closed."""
    lock = pathlib.Path(root, 'lock')
    lock.mkdir(exist_ok=True)
    fd = os.open(str(lock / 'flock'), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    done = subprocess.run([sys.executable, str(SCRIPTS / 'testbed_lock.py'), 'hold', str(fd), str(lock), info],
                          capture_output=True, text=True, pass_fds=(fd,), timeout=20)
    assert done.stdout.strip() == 'HELD', done.stdout + done.stderr
    return fd


class CleanCase(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.s = Scene(self.tmp.name)
        self.fds = []

    def tearDown(self):
        for fd in self.fds:
            os.close(fd)
        for parent, dirs, files in os.walk(self.tmp.name):
            for name in dirs + files:
                try:
                    os.lchflags(os.path.join(parent, name), 0)
                except OSError:
                    pass
        self.tmp.cleanup()

    def current(self, stamp='now', lane='suite', outcome=None):
        run = self.s.run(stamp, lane, outcome=outcome)
        self.fds.append(hold(self.s.root, f'{lane} sha=abc since now out={run}'))
        return run

    def clean(self, current, phase, disk):
        return th.clean(str(self.s.root), str(current), phase, disk=disk)


class TidyTests(CleanCase):

    def test_a_summarized_run_keeps_its_summary_verdict_and_log_tails_and_nothing_else(self):
        run = self.current('t1', 'testbed', outcome='GREEN')
        disk = FakeDisk(self.s.home, 100 * GB, 0)
        line = self.clean(run, 'end', disk)
        self.assertEqual(sorted(p.name for p in run.iterdir()),
                         ['VideoScan-UI.tests.tsv', 'corpus-check', 'corpus-proof', 'lanes.tsv', 'run.log', 'suite-row.json',
                          'suite.log', 'summary.txt', 'testbed-block.txt', 'tidy.txt'])
        for lane_dir in ('corpus-check', 'corpus-proof'):
            self.assertEqual(sorted(p.name for p in (run / lane_dir).iterdir()),
                             ['corpus-build.log', 'corpus-summary.txt', 'corpus-verdict.json'])
        tail = (run / 'suite.log').read_text().splitlines()
        self.assertEqual(tail[0], f'[tidied: the last {th.TAIL_LINES} of 500 lines are kept]')
        self.assertEqual(tail[1:], [f'line {i}' for i in range(300, 500)])
        self.assertEqual((run / 'run.log').read_text().count('\n'), 2, 'run.log is kept whole')
        self.assertRegex(line, r'^disk: free \d+% after cleanup')
        self.assertIn('this run', line)

    def test_tidy_is_once_and_a_short_log_is_left_as_it_is(self):
        run = self.current('t1', outcome='GREEN')
        (run / 'suite.log').write_text('one\ntwo\n')
        disk = FakeDisk(self.s.home, 100 * GB, 0)
        self.clean(run, 'end', disk)
        self.assertEqual((run / 'suite.log').read_text(), 'one\ntwo\n')
        record = (run / 'tidy.txt').read_text()
        (run / 'later.xcresult').mkdir()                      # anything that appears after the tidy is not its business
        self.assertIsNone(th.tidy(th.Confine(str(self.s.root)), str(run)))
        self.assertTrue((run / 'later.xcresult').exists())
        self.assertEqual((run / 'tidy.txt').read_text(), record)


class FloorTests(CleanCase):

    def test_finished_runs_and_dead_corpus_work_go_whatever_the_disk_says(self):
        old = [self.s.run(f'o{i}', outcome=word) for i, word in enumerate(('GREEN', 'RED', 'AMBER'))]
        dead = self.s.work('20261117_1_1-verbs')
        self.s.cache(0, 5000)
        run = self.current()
        disk = FakeDisk(self.s.home, 100 * GB, 0)           # 100% free: the floor is far away
        line = self.clean(run, 'start', disk)
        for path in old:
            self.assertFalse((path / 'suite-app.xcresult').exists(), path.name)
            self.assertTrue((path / 'summary.txt').exists(), path.name)
            self.assertTrue((path / 'tidy.txt').exists(), path.name)
        self.assertFalse(dead.exists())
        self.assertTrue((self.s.caches[0] / 'Build' / 'blob').exists(), 'a cache is kept above the floor')
        self.assertTrue((run / 'suite-app.xcresult').exists(), 'the run in progress is never tidied at its start')
        self.assertRegex(line, r'^disk: free 100% at the start \(floor 50%\) — removed [\d.]+ GB: older runs [\d.]+ GB \(3\), corpus work [\d.]+ GB \(1\)$')

    def test_below_the_floor_unfinished_runs_go_oldest_first_and_only_until_it_is_met(self):
        unfinished = [self.s.run(f'u{i}', outcome=None, size=1_000_000) for i in range(4)]   # the bundle dominates a run
        run = self.current()
        used = th._measure(str(self.s.home), os.lstat(str(self.s.home)).st_dev)[0]
        per_run = th._measure(str(unfinished[0] / 'suite-app.xcresult'), os.lstat(str(self.s.home)).st_dev)[0]
        # The floor is reached once exactly two runs have given up their scratch.
        total = 2 * (used - int(1.5 * per_run))
        disk = FakeDisk(self.s.home, total, 0)
        self.assertLess(disk(str(self.s.root))[0], total // 2)
        self.clean(run, 'start', disk)
        gone = [not (u / 'suite-app.xcresult').exists() for u in unfinished]
        self.assertEqual(gone, [True, True, False, False], 'oldest first, and no further than the floor needs')
        self.assertGreaterEqual(disk(str(self.s.root))[0], total // 2)
        for u in unfinished:
            self.assertTrue((u / 'run.log').exists())

    def test_the_build_caches_go_only_when_that_reaches_the_floor(self):
        self.s.cache(0, 200_000)
        self.s.cache(1, 200_000)
        run = self.current()
        used = th._measure(str(self.s.home), os.lstat(str(self.s.home)).st_dev)[0]
        # Out of reach: other data fills the disk; removing the caches would not reach 50%.
        disk = FakeDisk(self.s.home, 10 * used, 9 * used)
        line = self.clean(run, 'start', disk)
        self.assertTrue(all(c.exists() for c in self.s.caches), 'caches dropped for nothing')
        self.assertRegex(line, r'UNDER by [\d.]+ GB')
        self.assertIn('build caches kept', line)
        # Within reach: the caches go, and the line says so.
        disk = FakeDisk(self.s.home, 2 * used - 250_000, 0)
        line = self.clean(run, 'start', disk)
        self.assertFalse(self.s.caches[1].exists(), 'the suite cache goes first')
        self.assertTrue(self.s.caches[0].exists(), 'and no further than the floor needs')
        self.assertIn('build caches', line)
        self.assertNotIn('UNDER', line)

    def test_the_end_line_says_how_low_the_run_took_the_disk(self):
        run = self.current()
        disk = FakeDisk(self.s.home, 100 * GB, 40 * GB)
        self.clean(run, 'start', disk)
        (run / 'disk-low.txt').write_text(f'{30 * GB} {100 * GB}\n')      # what the sampler saw mid-run
        (run / 'run.log').write_text((run / 'run.log').read_text() + 'OUTCOME GREEN x\n')
        line = self.clean(run, 'end', disk)
        self.assertRegex(line, r'^disk: free 60% after cleanup \(lowest 30% during the run, 60% at the start; floor 50%\) — removed')
        disk = FakeDisk(self.s.home, 100 * GB, 70 * GB)
        line = self.clean(run, 'end', disk)
        self.assertIn('floor 50%, UNDER by 20.0 GB', line)


class ConfinementTests(CleanCase):

    def test_the_corpus_protected_set_is_never_touched(self):
        before = self.s.protected_snapshot()
        self.s.run('o1', outcome='GREEN')
        self.s.work('20261117_1_1-proof')
        (self.s.corpus / 'work' / 'not-a-run').mkdir()
        self.s.cache(0, 1000)
        self.s.cache(1, 1000)
        run = self.current()
        self.clean(run, 'start', full(self.s.home))       # far under the floor: everything allowed goes
        self.assertEqual(self.s.protected_snapshot(), before)
        self.assertTrue((self.s.corpus / 'work' / 'not-a-run').exists(), 'only <stamp>-<lane> work folders are run scratch')
        conf = th.Confine(str(self.s.root))
        for rel in PROTECTED:
            self.assertFalse(conf.allows(str(self.s.corpus / rel)), rel)
        for rel in ('media', 'live', 'reports', 'state', ''):
            self.assertFalse(conf.allows(str(self.s.corpus / rel)), rel or 'corpus')
        self.assertFalse(conf.allows('/Volumes'))
        self.assertFalse(conf.allows(str(self.s.home)))
        self.assertFalse(conf.allows(str(self.s.home / 'Library/Caches/videoscan-nightly-dd')), "the scheduled run's cache")

    def test_a_symlink_out_of_the_root_is_never_followed(self):
        outside = pathlib.Path(self.tmp.name, 'outside')
        (outside / 'deep').mkdir(parents=True)
        (outside / 'deep' / 'keep.txt').write_text('keep')
        old = self.s.run('o1', outcome='GREEN')
        os.symlink(outside, old / 'suite-app.xcresult' / 'Data' / 'linked')       # inside a tree that goes
        os.symlink(outside, old / 'evil.xcresult')                               # an entry of the run folder
        os.symlink(outside / 'deep' / 'keep.txt', old / 'corpus-check' / 'corpus.log')   # a log that is a link
        os.symlink(outside, self.s.out / 'a0-suite')                             # a "run folder" that is a link
        os.symlink(outside, self.s.corpus / 'work' / '20261117_2_2-verbs')        # a "work folder" that is a link
        run = self.current()
        self.clean(run, 'start', full(self.s.home))
        self.assertEqual((outside / 'deep' / 'keep.txt').read_text(), 'keep', 'a symlink was followed')
        self.assertFalse((old / 'suite-app.xcresult').exists())
        for link in (old / 'evil.xcresult', self.s.out / 'a0-suite', self.s.corpus / 'work' / '20261117_2_2-verbs'):
            self.assertTrue(link.is_symlink(), link)

    def test_a_link_in_the_way_of_a_root_refuses_that_root(self):
        elsewhere = pathlib.Path(self.tmp.name, 'elsewhere')
        elsewhere.mkdir()
        (elsewhere / '20261117_3_3-check').mkdir()
        (elsewhere / '20261117_3_3-check' / 'x').write_text('x')
        shutil.rmtree(self.s.corpus / 'work')
        os.symlink(elsewhere, self.s.corpus / 'work')                            # ~/corpus/work is an alias
        run = self.current()
        self.clean(run, 'start', full(self.s.home))
        self.assertTrue((elsewhere / '20261117_3_3-check' / 'x').exists())
        # ~/m4run/out an alias: nothing at all.
        other = pathlib.Path(self.tmp.name, 'other-out')
        shutil.move(str(self.s.out), str(other))
        os.symlink(other, self.s.out)
        with self.assertRaises(th.Refused):
            th.clean(str(self.s.root), str(self.s.out / run.name), 'start', disk=full(self.s.home))
        # ~/m4run itself an alias: refused before anything.
        alias = pathlib.Path(self.tmp.name, 'alias')
        os.symlink(self.s.root, alias)
        with self.assertRaises(th.Refused):
            th.Confine(str(alias))

    def test_a_hard_link_to_a_protected_file_loses_only_its_own_name(self):
        media = self.s.corpus / 'media' / 'clip.mov'
        old = self.s.run('o1', outcome='GREEN')
        os.link(media, old / 'corpus-check' / 'clip.log')            # a ".log" that is a protected file
        os.link(media, old / 'stray.mov')
        work = self.s.work('20261117_4_4-verbs')
        os.link(media, work / 'vol' / 'hard.mov')
        run = self.current()
        before = media.read_bytes()
        self.clean(run, 'start', full(self.s.home))
        self.assertEqual(media.read_bytes(), before)
        self.assertEqual(os.lstat(media).st_nlink, 1, 'each second name went; the protected file stays')
        self.assertFalse((old / 'corpus-check' / 'clip.log').exists())
        for path in old.rglob('*'):
            if path.is_file():
                self.assertNotIn(b'precious', path.read_bytes(), f'{path.name} carries bytes of a protected file')

    def test_the_lock_flag_is_never_cleared_on_a_file_with_a_second_name(self):
        media = self.s.corpus / 'media' / 'clip.mov'
        work = self.s.work('20261117_5_5-verbs')
        os.link(media, work / 'vol' / 'hard.mov')
        os.chflags(media, 0x2)                                      # UF_IMMUTABLE, as Promote sets it, on the shared inode
        run = self.current()
        line = self.clean(run, 'start', FakeDisk(self.s.home, 100 * GB, 0))
        self.assertTrue(os.lstat(media).st_flags & 0x2, 'the flag on a file with a second name was cleared')
        self.assertEqual(media.read_bytes(), b'precious media/clip.mov')
        self.assertTrue(work.exists(), 'a work folder that cannot go whole is left and said')
        self.assertIn('could not be removed 1', line)

    def test_a_tree_with_a_mount_in_it_is_refused(self):
        old = self.s.run('o1', outcome='GREEN')
        real = th._measure

        def foreign(path, dev):
            size, _ = real(path, dev)
            return size, path.endswith('.xcresult')
        th._measure = foreign
        try:
            run = self.current()
            self.clean(run, 'start', full(self.s.home))
        finally:
            th._measure = real
        self.assertTrue((old / 'suite-app.xcresult' / 'Data' / 'blob').exists())


class LockTests(CleanCase):

    def test_a_run_holding_the_lock_is_never_pruned_and_nobody_else_may_clean(self):
        live = self.s.run('live', outcome=None)
        self.fds.append(hold(self.s.root, f'suite sha=abc since now out={live}'))
        other = self.s.run('other', outcome=None)
        for current in (other, self.s.out / 'nope-suite'):
            with self.assertRaises(th.Refused):
                self.clean(current, 'start', full(self.s.home))
        self.assertTrue((live / 'suite-app.xcresult').exists())
        self.assertTrue((other / 'suite-app.xcresult').exists())
        # The holder itself cleans; its own folder is never tidied at its start, even far under the floor.
        self.clean(live, 'start', full(self.s.home))
        self.assertTrue((live / 'suite-app.xcresult').exists())
        self.assertFalse((other / 'suite-app.xcresult').exists(), 'a dead unfinished run is scratch under the floor')

    def test_no_lock_held_is_refused(self):
        run = self.s.run('x', outcome=None)
        with self.assertRaises(th.Refused):
            self.clean(run, 'start', full(self.s.home))
        self.assertTrue((run / 'suite-app.xcresult').exists())

    def test_the_command_line_refuses_with_exit_2_and_one_line(self):
        run = self.s.run('x', outcome=None)
        done = subprocess.run([sys.executable, str(SCRIPTS / 'testbed_host.py'), 'clean', str(self.s.root), '--current', str(run),
                               '--phase', 'start'], capture_output=True, text=True, timeout=60)
        self.assertEqual(done.returncode, 2)
        self.assertRegex(done.stdout, r'^disk: cleanup refused \(.+\)\n$')
        for bad in (['clean', str(self.s.root)], ['clean', str(self.s.root), '--current', str(run), '--phase', 'later'], ['sample']):
            self.assertEqual(subprocess.run([sys.executable, str(SCRIPTS / 'testbed_host.py'), *bad],
                                            capture_output=True, text=True, timeout=60).returncode, 2, bad)


class SampleAndScaleTests(CleanCase):

    def test_the_sampler_keeps_the_lowest_free_figure_and_stops_on_its_stop_file(self):
        run = self.current()
        figures = iter([70 * GB, 40 * GB, 55 * GB] + [60 * GB] * 50)
        stop = run / 'disk-sample.stop'

        def disk(path):
            value = next(figures)
            if value == 55 * GB:
                stop.write_text('')
            return value, 100 * GB
        th.sample(str(self.s.root), str(run), disk=disk, interval=0.01)
        self.assertEqual((run / 'disk-low.txt').read_text(), f'{40 * GB} {100 * GB}\n')

    def test_a_thousand_finished_runs_are_tidied_inside_the_budget(self):
        for i in range(1000):
            path = self.s.out / f'n{i:04d}-ui'
            path.mkdir()
            (path / 'run.log').write_text('START x\nOUTCOME GREEN y\n')
            (path / 'VideoScan-UI.xcresult').mkdir()
            (path / 'VideoScan-UI.xcresult' / 'blob').write_bytes(b'x' * 100)
        run = self.current()
        t0 = time.monotonic()
        line = self.clean(run, 'start', FakeDisk(self.s.home, 100 * GB, 0))
        self.assertLess(time.monotonic() - t0, 30.0)
        self.assertIn('older runs', line)
        self.assertIn('(1000)', line)
        self.assertFalse(any((self.s.out / f'n{i:04d}-ui' / 'VideoScan-UI.xcresult').exists() for i in range(0, 1000, 97)))


class RunnerCleanupTests(TestbedScene):
    """scripts/m4_run.sh __host testbed for real in a fake HOME: the start clean, the sampler and the end clean."""

    def setUp(self):
        super().setUp()
        self.env['VIDEOSCAN_TESTBED_FAKE_DISK'] = f'{1000 * GB}:{100 * GB}'

    def test_a_testbed_run_leaves_its_summary_and_a_disk_line_and_no_scratch(self):
        old = self.root / 'out' / 'old1-suite'
        (old / 'suite-app.xcresult').mkdir(parents=True)
        (old / 'suite-app.xcresult' / 'blob').write_bytes(b'x' * 1000)
        (old / 'run.log').write_text('START x\nOUTCOME GREEN y\n')
        p, log, summary, out = self.host('c1')
        self.assertEqual(p.returncode, 0, log)
        self.assertRegex(log, r'(?m)^disk: free 90% at the start \(floor 50%\) — removed [\d.]+ GB: older runs [\d.]+ GB \(1\)$')
        self.assertLess(log.index('disk: free 90% at the start'), log.index('START '))
        block = (out / 'testbed-block.txt').read_text().splitlines()
        last = block[-1]
        self.assertRegex(last, r'^disk: free 90% after cleanup \(lowest 90% during the run, 90% at the start; floor 50%\) — removed')
        lines = summary.splitlines()
        self.assertEqual(lines[:len(block)], block, 'the summary opens with the block, its disk line last')
        self.assertEqual(lines[len(block)], "— the lanes' own lines —")
        self.assertEqual(summary.count('disk: free'), 1)
        self.assertLess(log.index('OUTCOME'), log.index(last), 'the summary, with its disk line, follows the OUTCOME')
        self.assertFalse((old / 'suite-app.xcresult').exists())
        self.assertTrue((out / 'tidy.txt').exists())
        self.assertFalse((out / 'testbed-block.raw').exists())
        self.assertFalse((out / 'disk-sample.stop').exists())
        for name in ('run.log', 'summary.txt', 'lanes.tsv', 'suite-row.json', 'testbed-block.txt',
                     'corpus-check/corpus-summary.txt', 'corpus-proof/corpus-verdict.json'):
            self.assertTrue((out / name).exists(), name)
        self.assertEqual(probe(self.root / 'lock'), 'FREE', 'the sampler (or the cleanup) kept the lock')

    def test_a_cleanup_that_fails_never_costs_the_run_its_outcome(self):
        tool = self.install / 'testbed_host.py'
        tool.write_text(tool.read_text().replace('if __name__ == "__main__":',
                                                 'def clean(*args, **kwargs):\n    raise ZeroDivisionError\n\n\nif __name__ == "__main__":'))
        p, log, summary, out = self.host('c2')
        self.assertEqual(p.returncode, 0, log)
        self.assertRegex(log, r'(?m)^OUTCOME GREEN ')
        self.assertIn('disk: cleanup failed (ZeroDivisionError)', log)
        self.assertEqual((out / 'testbed-block.txt').read_text().splitlines()[-1], 'disk: cleanup failed (ZeroDivisionError)')
        self.assertEqual(summary.count('disk: cleanup failed (ZeroDivisionError)'), 1)
        self.assertTrue((out / 'suite-app.xcresult').exists() or not (out / 'tidy.txt').exists(), 'nothing was tidied')
        self.assertEqual(probe(self.root / 'lock'), 'FREE')


if __name__ == '__main__':
    unittest.main()
