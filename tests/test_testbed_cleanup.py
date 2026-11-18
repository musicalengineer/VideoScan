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
from test_m4_run_testbed_lane import STUB_CORPUS, TestbedScene  # noqa: E402

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
        return max(self.total - self.other - measure(self.home), 0), self.total


def measure(path):
    """Bytes on disk under `path`, each file once: a second name frees nothing (Codex #322 F7)."""
    seen, used = set(), 0
    for folder, dirs, names in os.walk(path):
        for name in dirs + names:
            info = os.lstat(os.path.join(folder, name))
            if (info.st_dev, info.st_ino) not in seen:
                seen.add((info.st_dev, info.st_ino))
                used += info.st_blocks * 512
    return used


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
        self.saved_home = os.environ.get('HOME')
        os.environ['HOME'] = str(self.s.home)                 # the authority: <root> must be $HOME/m4run (Codex F3)

    def tearDown(self):
        os.environ['HOME'] = self.saved_home
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
        conf = th.Confine(str(self.s.root))
        try:
            self.assertIsNone(th.tidy(conf, run.name))
        finally:
            conf.close()
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
        used = measure(self.s.home)
        per_run = measure(unfinished[0] / 'suite-app.xcresult')
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
        used = measure(self.s.home)
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
        self.s.cache(0, 1_000_000)
        self.s.cache(1, 1_000_000)
        nightly = self.s.home / 'Library/Caches/videoscan-nightly-dd'
        nightly.mkdir()
        (nightly / 'blob').write_bytes(b'n' * 1000)
        run = self.current()
        # Under the floor by 0.75 MB: the run and work scratch cannot reach it, the first cache does.
        self.clean(run, 'start', FakeDisk(self.s.home, 2 * measure(self.s.home) - 1_500_000, 0))
        self.assertEqual(self.s.protected_snapshot(), before)
        self.assertTrue((self.s.corpus / 'work' / 'not-a-run').exists(), 'only <stamp>-<lane> work folders are run scratch')
        self.assertFalse(self.s.caches[1].exists(), 'the floor reached the caches')
        self.assertTrue((nightly / 'blob').exists(), "the scheduled run's cache is not this cleanup's")
        conf = th.Confine(str(self.s.root))
        try:
            self.assertEqual(conf.caches, ['videoscan-m4run-dd'], 'the only caches it may name are its own two')
            for rel in PROTECTED + ('media', 'live', 'reports', 'state'):
                self.assertTrue(conf.guarded(os.path.join(conf.home, 'corpus', rel)), rel)
            self.assertTrue(conf.guarded('/Volumes/x'))
            self.assertFalse(conf.guarded(os.path.join(conf.work, '20261117_1_1-proof')))
        finally:
            conf.close()

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

def mount_image(tmp, at):
    """A real 1 MB disk image attached at `at` (Codex F1: a mount must be found, not told). None when hdiutil cannot."""
    image = os.path.join(tmp, 'm.dmg')
    made = subprocess.run(['hdiutil', 'create', '-size', '2m', '-fs', 'HFS+', '-volname', 'cleanuptest', '-quiet', image],
                          capture_output=True, text=True, timeout=120)
    if made.returncode != 0:
        return None
    attached = subprocess.run(['hdiutil', 'attach', '-nobrowse', '-quiet', '-mountpoint', str(at), image],
                              capture_output=True, text=True, timeout=120)
    return str(at) if attached.returncode == 0 else None


class CodexFindingsTests(CleanCase):
    """Codex #322 (M4 post-run cleanup), each finding as its reproduction."""

    def test_f1_a_mount_at_a_deletion_target_is_found_and_never_entered(self):
        old = self.s.run('o1', outcome='GREEN')
        target = old / 'suite-app.xcresult'
        shutil.rmtree(target)
        target.mkdir()
        mounted = mount_image(self.tmp.name, target)
        if not mounted:
            self.skipTest('hdiutil could not attach a disk image here')
        try:
            (target / 'keep.mov').write_bytes(b'on another volume')
            run = self.current()
            line = self.clean(run, 'start', full(self.s.home))
            self.assertEqual((target / 'keep.mov').read_bytes(), b'on another volume', 'a mounted volume was emptied')
            self.assertIn('could not be removed', line)
        finally:
            subprocess.run(['hdiutil', 'detach', '-force', '-quiet', mounted], capture_output=True, timeout=120)

    def swap_on(self, hook_name, trigger, run, aside, into):
        """Wrap os.<hook_name>: the first call whose first argument ends with `trigger` first renames
        the run folder aside and puts a symlink to `into` in its place — an ancestor swapped between check and act."""
        real = getattr(os, hook_name)
        state = {'done': False}

        def hooked(*args, **kwargs):
            if not state['done'] and str(args[0]).endswith(trigger):
                state['done'] = True
                os.rename(run, aside)
                os.symlink(into, run)
            return real(*args, **kwargs)
        setattr(os, hook_name, hooked)
        self.addCleanup(setattr, os, hook_name, real)

    def test_f2_an_ancestor_swapped_after_the_check_never_redirects_an_unlink(self):
        media = self.s.corpus / 'media'
        (media / 'victim.mov').write_bytes(b'family')
        old = self.s.run('o1', outcome='GREEN')
        (old / 'victim.mov').write_bytes(b'scratch')
        run = self.current()
        self.swap_on('unlink', 'victim.mov', old, self.s.out / 'aside', media)
        raised = self.clean_catching(run)
        self.assertTrue((media / 'victim.mov').exists(), 'a protected file was unlinked through a swapped ancestor')
        self.assertEqual((media / 'victim.mov').read_bytes(), b'family')
        self.assertIsNone(raised)

    def test_f2_an_ancestor_swapped_mid_tail_never_writes_into_the_protected_folder(self):
        media = self.s.corpus / 'media'
        (media / 'suite.log').write_bytes(b'precious log')
        old = self.s.run('o1', outcome='GREEN')
        run = self.current()
        self.swap_on('open', '.tidy-new', old, self.s.out / 'aside', media)
        raised = self.clean_catching(run)
        self.assertEqual((media / 'suite.log').read_bytes(), b'precious log', 'a log tail was renamed over a protected file')
        self.assertEqual(sorted(q.name for q in media.iterdir()), ['clip.mov', 'sub', 'suite.log'])
        self.assertIsNone(raised)

    def clean_catching(self, run):
        try:
            self.clean(run, 'start', FakeDisk(self.s.home, 100 * GB, 0))
        except Exception as error:                            # noqa: BLE001 — the protected file is checked first
            return error
        return None

    def test_f3_a_root_other_than_home_m4run_has_no_authority(self):
        fake = self.s.corpus / 'media'
        (fake / 'out' / 'now-suite').mkdir(parents=True)
        (fake / 'out' / 'now-suite' / 'precious.mov').write_bytes(b'family')
        (fake / 'out' / 'now-suite' / 'run.log').write_text('START x\nOUTCOME GREEN y\n')
        self.fds.append(hold(fake, f'suite sha=abc since now out={fake}/out/now-suite'))
        with self.assertRaises(th.Refused):
            th.clean(str(fake), str(fake / 'out' / 'now-suite'), 'end', disk=full(self.s.home))
        self.assertTrue((fake / 'out' / 'now-suite' / 'precious.mov').exists())
        alias = pathlib.Path(self.tmp.name, 'alias')
        os.symlink(self.s.home, alias)
        with self.assertRaises(th.Refused):
            th.Confine(str(alias / 'm4run'))
        with self.assertRaises(th.Refused):
            th.Confine(str(REPO))
        (self.s.home / 'ultrarun' / 'out').mkdir(parents=True)
        with self.assertRaises(th.Refused):
            th.Confine(str(self.s.home / 'ultrarun'))                    # the M4 only: the Ultra is Rick's machine

    def test_f6_a_cleanup_past_its_budget_stops_and_still_says_one_line(self):
        real_clean, real_budget = th.clean, th.CLEAN_BUDGET
        th.clean = lambda *args, **kwargs: time.sleep(30)
        th.CLEAN_BUDGET = 1
        try:
            t0 = time.monotonic()
            import io
            import contextlib
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                rc = th.main(['clean', str(self.s.root), '--current', str(self.s.out / 'x-suite'), '--phase', 'end'])
            self.assertLess(time.monotonic() - t0, 10)
            self.assertEqual((rc, out.getvalue()), (1, 'disk: cleanup stopped at its 1 s budget\n'))
        finally:
            th.clean, th.CLEAN_BUDGET = real_clean, real_budget

    def test_f4_a_protected_name_that_resolves_into_work_protects_its_destination(self):
        old = self.s.work('20261117_9_9-verbs')
        (old / 'family.mov').write_bytes(b'family')
        shutil.rmtree(self.s.corpus / 'media')
        os.symlink(old, self.s.corpus / 'media')
        run = self.current()
        with self.assertRaises(th.Refused):                     # an aliased protected name stops the cleanup whole (#324 S1)
            self.clean(run, 'start', full(self.s.home))
        self.assertEqual((old / 'family.mov').read_bytes(), b'family')

    def test_f5_a_current_run_that_is_a_symlink_is_refused_before_any_write(self):
        state = self.s.corpus / 'state'
        (state / 'disk-low.txt').write_text('precious')
        (state / 'disk-sample.stop').write_text('')
        (state / 'run.log').write_text('START x\n')
        current = self.s.out / 'now-suite'
        os.symlink(state, current)
        self.fds.append(hold(self.s.root, f'suite sha=abc since now out={current}'))
        with self.assertRaises(th.Refused):
            th.sample(str(self.s.root), str(current), disk=full(self.s.home), interval=0.01)
        with self.assertRaises(th.Refused):
            self.clean(current, 'start', full(self.s.home))
        self.assertEqual((state / 'disk-low.txt').read_text(), 'precious')
        self.assertFalse((state / 'disk-start.txt').exists())

    def command(self, *args):
        env = dict(os.environ, HOME=str(self.s.home), VIDEOSCAN_TESTBED_FAKE_DISK=f'{100 * GB}:0')
        return subprocess.run([sys.executable, str(SCRIPTS / 'testbed_host.py'), *args], capture_output=True, text=True,
                              env=env, timeout=30)

    def test_f6_a_fifo_never_stalls_the_cleanup_or_the_sampler(self):
        old = self.s.run('o1', outcome='GREEN')
        os.mkfifo(old / 'stall.log')
        run = self.current()
        try:
            done = self.command('clean', str(self.s.root), '--current', str(run), '--phase', 'start')
        except subprocess.TimeoutExpired:
            self.fail('the cleanup blocked on a FIFO')
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        os.mkfifo(run / 'disk-low.txt')
        (run / 'disk-sample.stop').write_text('')
        try:
            done = self.command('sample', str(self.s.root), str(run))
        except subprocess.TimeoutExpired:
            self.fail('the sampler blocked on a FIFO')
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)

    def test_f7_bytes_with_a_second_name_are_not_counted_as_reclaimable(self):
        media = self.s.corpus / 'media' / 'big.mov'
        media.write_bytes(b'm' * 4_000_000)
        for cache in self.s.caches:
            (cache / 'Build').mkdir(parents=True)
            os.link(media, cache / 'Build' / 'linked.mov')
        run = self.current()
        free, total = FakeDisk(self.s.home, 0, 0)(str(self.s.root))
        used = -free
        # Counted per name the caches hold 8 MB and would reach the floor; reclaimable, they hold nothing.
        disk = FakeDisk(self.s.home, 2 * used + 6_000_000, 0)
        line = self.clean(run, 'start', disk)
        self.assertTrue(all(c.exists() for c in self.s.caches), 'caches dropped for bytes another name keeps')
        self.assertIn('build caches kept', line)
        self.assertEqual(media.read_bytes()[:1], b'm')


class CodexReReviewTests(CleanCase):
    """Codex #323 (the re-review of the descriptor rewrite), each finding as its reproduction."""

    def test_r2_a_cache_holding_a_protected_destination_is_never_removed(self):
        build = self.s.caches[1] / 'Build'
        build.mkdir(parents=True)
        (build / 'family.mov').write_bytes(b'f' * 4_000_000)
        shutil.rmtree(self.s.corpus / 'media')
        os.symlink(build, self.s.corpus / 'media')
        run = self.current()
        with self.assertRaises(th.Refused):
            self.clean(run, 'start', FakeDisk(self.s.home, 2 * measure(self.s.home) - 2_000_000, 0))
        self.assertTrue((build / 'family.mov').exists(), 'a cache that holds the corpus media was removed')

    def test_r2_a_current_run_that_is_a_protected_destination_is_never_written(self):
        run = self.current()
        (run / 'disk-start.txt').write_text('precious')
        shutil.rmtree(self.s.corpus / 'state')
        os.symlink(run, self.s.corpus / 'state')
        try:
            self.clean(run, 'start', FakeDisk(self.s.home, 100 * GB, 0))
        except th.Refused:
            pass
        self.assertEqual((run / 'disk-start.txt').read_text(), 'precious')

    def test_r3_a_folder_moved_out_of_the_roots_before_its_entries_go_is_left_alone(self):
        old = self.s.run('o1', outcome='GREEN')
        (old / 'victim.mov').write_bytes(b'scratch')
        adopted = self.s.corpus / 'media' / 'adopted'
        real = os.listdir
        state = {'done': False}

        def hooked(arg=None):
            names = real(arg) if arg is not None else real()
            if not state['done'] and isinstance(arg, int) and 'victim.mov' in names:
                state['done'] = True
                os.rename(old, adopted)                      # the folder now lives under the corpus media
            return names
        os.listdir = hooked
        self.addCleanup(setattr, os, 'listdir', real)
        run = self.current()
        self.clean(run, 'start', FakeDisk(self.s.home, 100 * GB, 0))
        self.assertTrue((adopted / 'victim.mov').exists(), 'a file was unlinked in a folder that had moved into the corpus media')
        self.assertTrue((adopted / 'suite-app.xcresult' / 'Data' / 'blob').exists())

    def test_r4_a_tree_with_a_mount_inside_is_refused_whole(self):
        old = self.s.run('o1', outcome='GREEN')
        inner = old / 'suite-app.xcresult' / 'mounted'
        inner.mkdir()
        mounted = mount_image(self.tmp.name, inner)
        if not mounted:
            self.skipTest('hdiutil could not attach a disk image here')
        try:
            (inner / 'keep.mov').write_bytes(b'on another volume')
            run = self.current()
            self.clean(run, 'start', FakeDisk(self.s.home, 100 * GB, 0))
            self.assertEqual((inner / 'keep.mov').read_bytes(), b'on another volume')
            self.assertTrue((old / 'suite-app.xcresult' / 'Data' / 'blob').exists(), 'a tree with a mount in it was partly deleted')
        finally:
            subprocess.run(['hdiutil', 'detach', '-force', '-quiet', mounted], capture_output=True, timeout=120)

    def test_r5_locked_bytes_are_not_counted_as_reclaimable(self):
        self.s.cache(1, 4_000_000)
        os.chflags(self.s.caches[1] / 'Build' / 'blob', 0x2)       # UF_IMMUTABLE: it stays whatever we do
        self.s.cache(0, 2_000_000)
        run = self.current()
        line = self.clean(run, 'start', FakeDisk(self.s.home, 2 * measure(self.s.home) - 6_000_000, 0))
        self.assertTrue((self.s.caches[0] / 'Build' / 'blob').exists(), 'a cache was dropped on a forecast counting locked bytes')
        self.assertIn('build caches kept', line)


class RunnerShellWriteTests(TestbedScene):
    """Codex #323 R1: the runner writes its stop marker and the disk line only through the helper's door."""

    def setUp(self):
        super().setUp()
        self.env['VIDEOSCAN_TESTBED_FAKE_DISK'] = f'{1000 * GB}:{100 * GB}'
        self.media = self.home / 'corpus' / 'media' / 'clip.mov'
        self.media.parent.mkdir(parents=True)
        self.media.write_bytes(b'family')

    def plant_during_the_lane(self, code):
        stub = STUB_CORPUS.replace('sys.exit(plan["exit"])', code + '\nsys.exit(plan["exit"])')
        (self.install / 'corpus_run.py').write_text(stub)

    def test_r1_a_planted_link_at_the_stop_marker_is_never_written_through(self):
        self.plant_during_the_lane(
            'run = os.path.dirname(out)\n'
            'stop = os.path.join(run, "disk-sample.stop")\n'
            'os.path.lexists(stop) or os.symlink(os.path.join(os.environ["HOME"], "corpus/media/clip.mov"), stop)')
        p, log, summary, _ = self.host('l1')
        self.assertEqual(self.media.read_bytes(), b'family', 'the stop marker was written through a planted link')
        self.assertRegex(log, r'(?m)^OUTCOME ')

    def test_r1_a_planted_fifo_at_the_stop_marker_never_holds_the_outcome(self):
        self.plant_during_the_lane(
            'run = os.path.dirname(out)\n'
            'stop = os.path.join(run, "disk-sample.stop")\n'
            'os.path.lexists(stop) or os.mkfifo(stop)')
        stamp = 'l2'
        try:
            p = subprocess.run(['/bin/bash', str(self.install / 'm4_run.sh'), '__host', 'testbed', self.sha, stamp, '--host', 'm4'],
                               capture_output=True, text=True, env=self.env, timeout=90)
        except subprocess.TimeoutExpired:
            self.fail('a FIFO at the stop marker held the run before its OUTCOME')
        log = (self.root / 'out' / f'{stamp}-testbed' / 'run.log').read_text()
        self.assertRegex(log, r'(?m)^OUTCOME ')


class CodexSecondReReviewTests(CleanCase):
    """Codex #324 (second re-review), each finding as its reproduction."""

    def test_s1_a_protected_name_aliased_by_another_spelling_stops_the_cleanup(self):
        old = self.s.run('o1', outcome='GREEN')
        (old / 'family.mov').write_bytes(b'family')
        shutil.rmtree(self.s.corpus / 'media')
        os.symlink(self.s.out / 'O1-SUITE', self.s.corpus / 'media')            # the same folder, other case
        run = self.current()
        try:
            self.clean(run, 'start', FakeDisk(self.s.home, 100 * GB, 0))
        except th.Refused:
            pass
        self.assertEqual((old / 'family.mov').read_bytes(), b'family')

    def test_s2_the_summary_replacement_checks_where_the_folder_is_before_each_act(self):
        run = self.current()
        (run / 'testbed-block.txt').unlink()                    # a suite run: the summary path
        (run / 'summary.txt').write_text('suite: GREEN\n')
        (run / 'summary.txt.disk-new').write_text('planted')
        adopted = self.s.corpus / 'media' / 'adopted'
        real = th._read_at
        state = {'done': False}

        def hooked(dir_fd, name, limit):
            data = real(dir_fd, name, limit)
            if not state['done'] and name == 'summary.txt':
                state['done'] = True
                os.rename(run, adopted)
            return data
        th._read_at = hooked
        self.addCleanup(setattr, th, '_read_at', real)
        try:
            th.record(str(self.s.root), str(run), 'disk: free 50% after cleanup')
        except th.Refused:
            pass
        self.assertEqual((adopted / 'summary.txt.disk-new').read_text(), 'planted')
        self.assertEqual((adopted / 'summary.txt').read_text(), 'suite: GREEN\n')

    def test_s3_a_tree_that_cannot_be_scanned_whole_is_not_touched(self):
        old = self.s.run('o1', outcome='GREEN')
        sealed = old / 'suite-app.xcresult' / 'sealed'
        sealed.mkdir()
        (sealed / 'inner').write_text('x')
        os.chmod(sealed, 0)
        try:
            run = self.current()
            self.clean(run, 'start', FakeDisk(self.s.home, 100 * GB, 0))
        finally:
            if sealed.exists():
                os.chmod(sealed, 0o755)
        self.assertTrue((old / 'suite-app.xcresult' / 'Data' / 'blob').exists(), 'a tree it could not see whole was partly deleted')

    def test_s4_an_end_cleanup_without_the_lock_writes_nothing(self):
        run = self.s.run('x', outcome='GREEN')
        (run / 'summary.txt').write_text('suite: GREEN\n')
        (run / 'summary.txt.disk-new').write_text('planted')
        env = dict(os.environ, HOME=str(self.s.home), VIDEOSCAN_TESTBED_FAKE_DISK=f'{100 * GB}:0')
        done = subprocess.run([sys.executable, str(SCRIPTS / 'testbed_host.py'), 'clean', str(self.s.root), '--current', str(run),
                               '--phase', 'end'], capture_output=True, text=True, env=env, timeout=60)
        self.assertEqual(done.returncode, 2)
        self.assertEqual((run / 'summary.txt.disk-new').read_text(), 'planted')
        self.assertEqual((run / 'summary.txt').read_text(), 'suite: GREEN\n')
        self.assertTrue((run / 'suite-app.xcresult').exists())

    def test_s5_nothing_runs_past_the_deadline_and_stop_has_its_own(self):
        import contextlib
        import io
        calls = []
        saved = th.clean, th.record, th.stop_marker, th.CLEAN_BUDGET
        th.clean = lambda *args, **kwargs: time.sleep(30)
        th.record = lambda *args, **kwargs: calls.append('record') or True
        th.stop_marker = lambda *args, **kwargs: time.sleep(30)
        th.CLEAN_BUDGET = 1
        try:
            out = io.StringIO()
            t0 = time.monotonic()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
                th.main(['clean', str(self.s.root), '--current', str(self.s.out / 'x-suite'), '--phase', 'end'])
            self.assertEqual(calls, [], 'the summary was written after the deadline had passed')
            th.STOP_BUDGET = 1
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                th.main(['stop', str(self.s.root), str(self.s.out / 'x-suite')])
            self.assertLess(time.monotonic() - t0, 10)
        finally:
            th.clean, th.record, th.stop_marker, th.CLEAN_BUDGET = saved
            signal_reset()

    def test_s6_a_cache_with_a_mount_in_it_counts_nothing_toward_the_floor(self):
        self.s.cache(1, 4_000_000)
        inner = self.s.caches[1] / 'mounted'
        inner.mkdir()
        mounted = mount_image(self.tmp.name, inner)
        if not mounted:
            self.skipTest('hdiutil could not attach a disk image here')
        try:
            self.s.cache(0, 2_000_000)
            run = self.current()
            line = self.clean(run, 'start', FakeDisk(self.s.home, 2 * measure(self.s.home) - 6_000_000, 0))
            self.assertTrue((self.s.caches[0] / 'Build' / 'blob').exists(), 'a cache dropped on a forecast that counted a refused cache')
            self.assertIn('build caches kept', line)
        finally:
            subprocess.run(['hdiutil', 'detach', '-force', '-quiet', mounted], capture_output=True, timeout=120)


def signal_reset():
    import signal
    signal.alarm(0)
    signal.signal(signal.SIGALRM, signal.SIG_DFL)


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
