"""Gauntlet runs keep only their summary row (Rick 2026-11-08).

"Delete them all, once we have the summary data, 13,000 passed, 12 failed, 2
unknown <list of fails> date/time/machine, nothing else is needed." Each run
dir under ~/Library/Logs/VideoScan/gauntlet/<ts>-<id>/ held DerivedData
(~5 GB), PackageBuild (~1.3 GB) and logs/xcresults forever; the M4 testbed
reached 102 GB and 86% full. Rules, all in Runner.swift:

1. SUMMARY: the history.jsonl row names, per stage, the failed, unexpectedly
   skipped and incomplete (no verdict) tests, each list capped at 200 with a
   `_truncated` count, plus top-level totals, and against the previous row for
   the same machine: `new_failures`, `fixed`, and `first_failed` per still
   failing test. It carries no paths into the run dir (roots, artifacts) and
   counts blocked suites instead of listing them.
2. TIDY: once the row is in history.jsonl (checked there, by run_id) and the
   publish is "published", the WHOLE run dir goes. Queued or failed publish:
   the run keeps result.json/logs and loses only its build scratch. --keep-run
   keeps everything.
3. RETENTION: at the start of a run, run dirs whose NAME date is older than 3
   days are removed (finished or crashed). Never history.jsonl,
   pending-metrics*, a symlink; mtime is ignored.

Seams (Runner.swift main()):
  --retention-plan <results-root> <now-iso8601>   prints the JSON list to remove
  --retain <results-root> <now-iso8601>           removes them
  --tidy-run <run> <publish> [--keep-run]         the end-of-run tidy
  --package-names <stream> <console> <list> [filter…] / --xcode-names <summary> [<tests>]
  --history-row <result.json> <history.jsonl>     the row publishResults appends
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

REPO = Path(__file__).resolve().parents[1]
NOW = '2026-11-08T20:00:00Z'


def runner_binary(workspace):
    binary = workspace / 'runner'
    subprocess.run(['/usr/bin/swiftc', '-module-cache-path', str(workspace / 'swift-cache'),
                    str(REPO / 'scripts/gauntlet/Runner.swift'), '-o', str(binary)], check=True, capture_output=True)
    return binary


def write_history(root, *run_ids, machine='m4'):
    with open(root / 'history.jsonl', 'a') as f:
        for rid in run_ids:
            f.write(json.dumps(dict(run_id=rid, machine=machine, status='passed')) + '\n')


def make_run(root, name, finished=True, build=True):
    """A run dir as the runner leaves it (result.json once finished)."""
    run = root / name
    (run / 'logs').mkdir(parents=True)
    (run / '.gauntlet-run').write_text(name)          # prepareRoots' ownership marker (Codex sweep 11/09 F1)
    (run / 'logs' / 'build.log').write_text('log')
    (run / 'unit.xcresult').mkdir()
    (run / 'caches').mkdir()
    if finished:
        (run / 'result.json').write_text('{"status": "passed"}')
    if build:
        for scratch in ('DerivedData/Build/Products', 'PackageBuild/release', 'swift-cache'):
            (run / scratch).mkdir(parents=True)
        (run / 'DerivedData/Build/Products/app.bin').write_bytes(b'x' * 1_000_000)
        (run / 'PackageBuild/release/pkg.bin').write_bytes(b'y' * 1000)
    return run


@unittest.skipUnless(sys.platform == "darwin", "macOS-only: builds with /usr/bin/swiftc")
class GauntletRunTidyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workspace = tempfile.TemporaryDirectory(prefix='gauntlet-tidy-', dir='/private/tmp')
        cls.binary = runner_binary(Path(cls.workspace.name))

    @classmethod
    def tearDownClass(cls):
        cls.workspace.cleanup()

    def case_dir(self):
        case = tempfile.TemporaryDirectory(dir=self.workspace.name)
        self.addCleanup(case.cleanup)
        return Path(case.name)

    def seam(self, *args):
        done = subprocess.run([str(self.binary), *map(str, args)], text=True, capture_output=True, timeout=60)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        return done.stdout

    # -- tidy ---------------------------------------------------------------

    def test_tidy_of_a_kept_run_removes_every_regenerable_folder_and_keeps_its_logs(self):
        # RED 2026-11-24 (Rick hand-cleaned ~150 GB off the M4): a kept run (queued publish) lost only
        # DerivedData/PackageBuild/swift-cache; its xcresult bundles and the sealed roots (caches, tmp,
        # home, fixtures, ...) stayed, ~1.2 GB a run. Now every folder but the test host's `logs` goes.
        run = make_run(self.case_dir(), '2026-11-08T19-19-00Z-AAAA0001')
        for root in ('tmp/TemporaryDirectory.x', 'home/Library', 'fixtures', 'app-support'):
            (run / root).mkdir(parents=True)
        (run / 'tmp/TemporaryDirectory.x/blob').write_bytes(b'z' * 10_000)
        (run / 'unit.log').write_text('log')
        (run / 'unit-summary.json').write_text('{}')
        out = self.seam('--tidy-run', run, 'queued')
        for gone in ('DerivedData', 'PackageBuild', 'swift-cache', 'unit.xcresult', 'caches', 'tmp', 'home',
                     'fixtures', 'app-support'):
            self.assertFalse((run / gone).exists(), gone)
        for kept in ('logs/build.log', 'result.json', 'unit.log', 'unit-summary.json', '.gauntlet-run'):
            self.assertTrue((run / kept).exists(), kept)
        self.assertRegex(out, r'GAUNTLET TIDY removed build products \(\d+\.\d+ GB\) from ' + str(run))
        self.assertIn('kept run (publish queued', out)

    def test_a_read_only_folder_left_by_a_test_does_not_keep_the_run(self):
        # RED 2026-11-24: FileManager.removeItem stops at a folder without write permission (a test
        # that chmods its fixture 0500 and dies before restoring it); the whole-run removal failed with
        # a warning and left the run - DerivedData and all - for good (retention failed the same way).
        for publish in ('published', 'queued'):
            root = self.case_dir()
            run = make_run(root, '2026-11-08T19-19-00Z-AAAA0011')
            locked = run / 'DerivedData' / 'locked'
            locked.mkdir()
            (locked / 'inside.bin').write_bytes(b'q' * 1000)
            locked.chmod(0o500)
            self.addCleanup(lambda p=locked: p.exists() and p.chmod(0o700))
            write_history(root, run.name)
            out = self.seam('--tidy-run', run, publish)
            self.assertFalse((run / 'DerivedData').exists(), publish + ': ' + out)
            self.assertNotIn('warning', out, publish)
            if publish == 'published':
                self.assertFalse(run.exists(), out)

    def test_review_a_kept_run_keeps_its_build_through_the_next_runs_retention(self):
        # Review 2026-11-24 (reviewer agent). RED: scripts/gauntlet/Runner.swift:776-782 tidies every
        # finished run that is not a retention candidate, and a --keep-run run leaves no mark, so the next
        # run (tonight's nightly) removes the DerivedData --keep-run was asked to keep. Before: kept 3 days.
        root = self.case_dir() / 'gauntlet'
        root.mkdir()
        kept = make_run(root, '2026-11-08T14-00-00Z-KEEP0001')
        write_history(root, kept.name)
        self.seam('--tidy-run', kept, 'published', '--keep-run')
        self.assertTrue((kept / 'DerivedData').exists(), 'precondition: --keep-run kept the build')
        out = self.seam('--retain', root, NOW)
        self.assertTrue((kept / 'DerivedData').exists(), '--keep-run lasted until the next run: ' + out)

    def test_review_tidy_never_empties_a_volume_a_test_left_mounted_in_the_run(self):
        # Review 2026-11-24 (reviewer agent). RED (expected; not run by the reviewer): Runner.swift:686-700
        # makeOwnerWritable recurses and removeTree removes with no device check, and regenerableFolders
        # (:655-662) now includes the sealed tmp, where CatalogDiskFullTests attaches a disk image under
        # its own folder. A test that dies attached leaves a mount in <run>/tmp; the tidy empties it.
        case = self.case_dir()
        run = make_run(case, '2026-11-08T19-19-00Z-AAAA0021')
        image = case / 'vol.dmg'
        made = subprocess.run(['/usr/bin/hdiutil', 'create', '-size', '4m', '-fs', 'HFS+', '-volname', 'ReviewT',
                               str(image)], capture_output=True, text=True)
        mnt = run / 'tmp' / 'mnt'
        mnt.mkdir(parents=True)
        att = subprocess.run(['/usr/bin/hdiutil', 'attach', '-nobrowse', '-noautoopen', '-mountpoint', str(mnt), str(image)],
                             capture_output=True, text=True) if made.returncode == 0 else made
        if att.returncode:
            self.skipTest('hdiutil not permitted here: ' + att.stderr)
        self.addCleanup(subprocess.run, ['/usr/bin/hdiutil', 'detach', '-force', str(mnt)], capture_output=True)
        (mnt / 'on-the-volume.bin').write_bytes(b'v' * 1000)
        subprocess.run([str(self.binary), '--tidy-run', str(run), 'queued'], text=True, capture_output=True, timeout=60)
        self.assertTrue((mnt / 'on-the-volume.bin').exists(), 'the tidy crossed into a mounted volume and emptied it')

    def test_rereview_a_folder_a_test_left_0000_or_0100_does_not_keep_the_run(self):
        # Re-review 2026-11-24 of 8856be49a. RED: scripts/gauntlet/Runner.swift:715 removeEntry opens a
        # folder O_RDONLY BEFORE it fchmods it (:722), and open(2) needs read permission: a folder a test left
        # 0000 (or 0100, search only) fails EACCES, so the run is never removed - the leak this branch fixes.
        # The old path-based makeOwnerWritable chmod-ed first and handled it; the doc comment (:703) still
        # promises 0000. The no-follow way to chmod first: fchmodat(parent, name, mode, AT_SYMLINK_NOFOLLOW).
        for mode in (0o000, 0o100):
            root = self.case_dir()
            run = make_run(root, '2026-11-08T19-19-00Z-AAAA0031')
            locked = run / 'DerivedData' / 'locked'
            locked.mkdir()
            (locked / 'inside.bin').write_bytes(b'q' * 1000)
            locked.chmod(mode)
            self.addCleanup(lambda p=locked: p.exists() and p.chmod(0o700))
            write_history(root, run.name)
            out = self.seam('--tidy-run', run, 'published')
            self.assertNotIn('warning', out, oct(mode))
            self.assertFalse(run.exists(), oct(mode) + ': ' + out)

    def test_rereview_a_tree_deeper_than_the_open_file_limit_is_removed(self):
        # Re-review 2026-11-24 of 8856be49a. RED: scripts/gauntlet/Runner.swift:725-727 removeEntry recurses
        # holding one open folder per level, so a tree deeper than RLIMIT_NOFILE (macOS default soft limit
        # 256) fails EMFILE at :715 and the run stays (fails safe, but the leak returns). FileManager.removeItem
        # (removefile/fts) had no depth limit. 300 levels of "d/" is a ~700-byte path: any test can make it.
        import resource
        root = self.case_dir()
        run = make_run(root, '2026-11-08T19-19-00Z-AAAA0032')
        deep = run / 'DerivedData'
        for _ in range(300):
            deep = deep / 'd'
        deep.mkdir(parents=True)
        write_history(root, run.name)

        def macos_default_limit():
            hard = resource.getrlimit(resource.RLIMIT_NOFILE)[1]
            resource.setrlimit(resource.RLIMIT_NOFILE, (256 if hard == resource.RLIM_INFINITY else min(256, hard), hard))
        done = subprocess.run([str(self.binary), '--tidy-run', str(run), 'published'], text=True,
                              capture_output=True, timeout=60, preexec_fn=macos_default_limit)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertNotIn('warning', done.stdout, done.stdout)
        self.assertFalse(run.exists(), done.stdout)

    def test_tidy_refuses_before_result_json_exists(self):
        run = make_run(self.case_dir(), '2026-11-08T19-19-00Z-AAAA0002', finished=False)
        write_history(run.parent, run.name)
        out = self.seam('--tidy-run', run, 'published')
        for kept in ('DerivedData', 'PackageBuild', 'swift-cache'):
            self.assertTrue((run / kept).exists(), kept)
        self.assertIn('kept', out)

    def test_keep_run_flag_keeps_everything(self):
        run = make_run(self.case_dir(), '2026-11-08T19-19-00Z-AAAA0003')
        write_history(run.parent, run.name)
        out = self.seam('--tidy-run', run, 'published', '--keep-run')
        for kept in ('DerivedData', 'PackageBuild', 'swift-cache', 'result.json'):
            self.assertTrue((run / kept).exists(), kept)
        self.assertIn('--keep-run', out)

    def test_tidy_of_a_run_without_build_products_is_quiet_and_safe(self):
        run = make_run(self.case_dir(), '2026-11-08T19-19-00Z-AAAA0004', build=False)
        out = self.seam('--tidy-run', run, 'queued')
        self.assertIn('(0.00 GB)', out)
        self.assertTrue((run / 'result.json').exists())

    def test_tidy_does_not_follow_a_symlinked_scratch_dir(self):
        case = self.case_dir()
        outside = case / 'outside'
        outside.mkdir()
        (outside / 'precious.mov').write_bytes(b'media')
        run = make_run(case, '2026-11-08T19-19-00Z-AAAA0005', build=False)
        os.symlink(outside, run / 'DerivedData')
        self.seam('--tidy-run', run, 'queued')
        self.assertTrue((outside / 'precious.mov').exists())
        write_history(case, run.name)
        self.seam('--tidy-run', run, 'published')                       # whole-run removal: same rule
        self.assertTrue((outside / 'precious.mov').exists())
        self.assertFalse(run.exists())

    def test_runner_accepts_keep_run_in_its_option_parser(self):
        for flag in ('--keep-run', '--keep-build'):                     # --keep-build: the old name, same meaning
            done = subprocess.run([str(self.binary), flag, '--help'], text=True, capture_output=True, timeout=60)
            self.assertEqual(done.returncode, 0, done.stderr)
            self.assertIn('--keep-run', done.stdout)

    def test_tidy_removes_the_whole_run_after_a_published_summary_row(self):
        root = self.case_dir()
        run = make_run(root, '2026-11-08T19-19-00Z-AAAA0006')
        write_history(root, run.name)
        (root / 'pending-metrics.jsonl').write_text('{}\n')
        history = (root / 'history.jsonl').read_text()
        out = self.seam('--tidy-run', run, 'published')
        self.assertFalse(run.exists())
        self.assertRegex(out, r'GAUNTLET TIDY removed run ' + str(run) + r' \(\d+\.\d+ GB\); summary in history.jsonl')
        self.assertEqual((root / 'history.jsonl').read_text(), history)
        self.assertEqual((root / 'pending-metrics.jsonl').read_text(), '{}\n')

    def test_tidy_keeps_a_queued_or_failed_publish_and_says_why(self):
        for publish in ('queued', 'queue_failed'):
            root = self.case_dir()
            run = make_run(root, '2026-11-08T19-19-00Z-AAAA0007')
            write_history(root, run.name)
            out = self.seam('--tidy-run', run, publish)
            self.assertTrue((run / 'result.json').exists(), publish)
            self.assertFalse((run / 'DerivedData').exists(), publish)
            self.assertIn(f'kept run (publish {publish}', out)

    def test_tidy_keeps_a_published_run_whose_summary_row_is_not_in_history(self):
        root = self.case_dir()
        run = make_run(root, '2026-11-08T19-19-00Z-AAAA0008')
        write_history(root, '2026-11-08T19-19-00Z-SOMEONE0')            # another run's row only
        out = self.seam('--tidy-run', run, 'published')
        self.assertTrue((run / 'result.json').exists())
        self.assertIn('no summary row in history.jsonl', out)

    # -- retention ----------------------------------------------------------

    def results_root(self):
        root = self.case_dir() / 'gauntlet'
        root.mkdir()
        make_run(root, '2026-10-20T14-00-00Z-OLD00001')                   # 19 days: removed
        make_run(root, '2026-11-05T19-59-59Z-OLD00002')                   # just over 3 days: removed
        make_run(root, '2026-11-05T20-00-01Z-NEW00001')                   # just under: stays
        make_run(root, '2026-11-08T14-00-00Z-NEW00002')                   # today: stays
        make_run(root, '2026-09-01T14-00-00Z-UNFIN001', finished=False)   # crashed long ago: removed
        make_run(root, '2026-11-08T19-00-00Z-LIVE0001', finished=False)   # a live run: stays
        (root / 'history.jsonl').write_text('{}\n')
        write_history(root, '2026-10-20T14-00-00Z-OLD00001', '2026-11-05T19-59-59Z-OLD00002')   # their summary rows
        (root / 'pending-metrics.jsonl').write_text('{}\n')
        (root / 'pending-metrics.lock').write_text('')
        (root / 'not-a-run').mkdir()
        (root / 'not-a-run' / 'result.json').write_text('{}')
        # Fresh mtime on an old name, old mtime on a new name: the name decides.
        os.utime(root / '2026-10-20T14-00-00Z-OLD00001', (0, 2_000_000_000))
        os.utime(root / '2026-11-08T14-00-00Z-NEW00002', (0, 0))
        return root

    OLD = ['2026-09-01T14-00-00Z-UNFIN001', '2026-10-20T14-00-00Z-OLD00001', '2026-11-05T19-59-59Z-OLD00002']

    def test_retention_plan_picks_runs_older_than_3_days_by_name(self):
        root = self.results_root()
        plan = json.loads(self.seam('--retention-plan', root, NOW))
        self.assertEqual(plan, self.OLD)

    def test_retain_removes_old_finished_runs_and_nothing_else(self):
        root = self.results_root()
        before = sorted(p.name for p in root.iterdir())
        history = (root / 'history.jsonl').read_text()
        out = self.seam('--retain', root, NOW)
        # Codex sweep 11/09 F2: the crashed run has no summary row — kept (its
        # logs are its only record), its build products removed.
        removed = [n for n in self.OLD if n != '2026-09-01T14-00-00Z-UNFIN001']
        self.assertEqual(sorted(p.name for p in root.iterdir()), sorted(set(before) - set(removed)))
        for name in removed:
            self.assertIn(f'GAUNTLET RETENTION removed {root / name}', out)
        crashed = root / '2026-09-01T14-00-00Z-UNFIN001'
        self.assertIn(f'GAUNTLET RETENTION kept {crashed} (no summary row in history.jsonl', out)
        self.assertTrue((crashed / 'logs' / 'build.log').exists())
        self.assertFalse((crashed / 'DerivedData').exists())
        # The two finished runs that stay give up their regenerable folders too (2026-11-24); the live one is untouched.
        for name in ('2026-11-05T20-00-01Z-NEW00001', '2026-11-08T14-00-00Z-NEW00002'):
            self.assertIn(f'GAUNTLET RETENTION tidied {root / name}', out)
            self.assertFalse((root / name / 'DerivedData').exists(), name)
            self.assertTrue((root / name / 'result.json').exists(), name)
        self.assertEqual(len(out.strip().splitlines()), 5, out)
        self.assertEqual((root / 'history.jsonl').read_text(), history)
        self.assertEqual((root / 'pending-metrics.jsonl').read_text(), '{}\n')
        self.assertTrue((root / '2026-11-08T19-00-00Z-LIVE0001' / 'logs' / 'build.log').exists())
        self.assertTrue((root / '2026-11-08T19-00-00Z-LIVE0001' / 'DerivedData').exists(), 'a live run keeps its build')

    def test_retain_keeps_at_most_the_newest_three_runs(self):
        # RED 2026-11-24: retention went by age only, so a busy week kept every run of the last 3 days.
        root = self.case_dir() / 'gauntlet'
        root.mkdir()
        names = [f'2026-11-08T1{h}-00-00Z-KEEP000{h}' for h in range(5)]       # all within the last 3 days
        for name in names:
            make_run(root, name)
        write_history(root, *names)
        out = self.seam('--retain', root, NOW)
        self.assertEqual(sorted(p.name for p in root.iterdir() if p.is_dir()), names[-3:], out)
        for name in names[:2]:
            self.assertIn(f'GAUNTLET RETENTION removed {root / name}', out)

    def test_retain_tidies_a_crashed_run_once_it_cannot_be_live(self):
        # RED 2026-11-24: a run killed before its tidy (SIGKILL past the watchdog) kept its DerivedData
        # until it was 3 days old. Past the longest a run can last (6 h) its regenerable folders go.
        root = self.case_dir() / 'gauntlet'
        root.mkdir()
        dead = make_run(root, '2026-11-08T13-00-00Z-DEAD0001', finished=False)     # 7 h before NOW
        live = make_run(root, '2026-11-08T19-30-00Z-LIVE0002', finished=False)     # 30 min before NOW
        out = self.seam('--retain', root, NOW)
        self.assertFalse((dead / 'DerivedData').exists(), out)
        self.assertTrue((dead / 'logs' / 'build.log').exists())
        self.assertTrue((live / 'DerivedData').exists(), 'a run that may still be live keeps its build')

    def test_retain_never_tidies_a_run_that_may_still_be_live_even_beyond_the_newest_three(self):
        # Review 2026-11-24 (nit): a retention candidate with no summary row got its build removed with no
        # liveness check; a run started an hour ago, pushed past the newest three by later names, may be live.
        root = self.case_dir() / 'gauntlet'
        root.mkdir()
        live = make_run(root, '2026-11-08T19-00-00Z-LIVE0003', finished=False)     # 1 h before NOW, no row
        later = [f'2026-11-08T19-{m}-00Z-DONE00{m}' for m in ('10', '20', '30')]
        for name in later:
            make_run(root, name)
        write_history(root, *later)
        out = self.seam('--retain', root, NOW)
        self.assertTrue((live / 'DerivedData').exists(), out)

    def test_retain_with_nothing_old_prints_nothing_and_removes_nothing(self):
        root = self.case_dir() / 'gauntlet'
        root.mkdir()
        make_run(root, '2026-11-08T14-00-00Z-NEW00002', build=False)
        for folder in ('unit.xcresult', 'caches'):
            (root / '2026-11-08T14-00-00Z-NEW00002' / folder).rmdir()
        (root / 'history.jsonl').write_text('{}\n')
        self.assertEqual(self.seam('--retain', root, NOW), '')
        self.assertEqual(sorted(p.name for p in root.iterdir()), ['2026-11-08T14-00-00Z-NEW00002', 'history.jsonl'])

    def test_retain_never_follows_a_symlinked_run_dir(self):
        case = self.case_dir()
        root = case / 'gauntlet'
        root.mkdir()
        elsewhere = make_run(case, '2026-10-01T14-00-00Z-ELSE0001')   # old by name, but not ours
        os.symlink(elsewhere, root / '2026-10-01T14-00-00Z-LINK0001')
        self.assertEqual(json.loads(self.seam('--retention-plan', root, NOW)), [])
        self.seam('--retain', root, NOW)
        self.assertTrue((elsewhere / 'result.json').exists())
        self.assertTrue((root / '2026-10-01T14-00-00Z-LINK0001').is_symlink())


def declared(tid, kind='function'):
    return dict(kind='test', version='6.4.0', payload=dict(id=tid, kind=kind, name=tid))


def event(kind, tid=None, **extra):
    payload = dict(kind=kind, messages=[], **extra)
    if tid:
        payload['testID'] = tid
    return dict(kind='event', version='6.4.0', payload=payload)


FAIL = dict(isKnown=False, isFailure=True)


def stage(name, status='passed', passed=10, failed=0, skipped=0, known=0, **names):
    row = dict(name=name, status=status, passed=passed, failed=failed, skipped=skipped, known_issues=known,
               expected=10, incomplete=0 if status == 'passed' else 1, reason=None,
               artifacts=[f'{name}.xcresult', f'{name}.log'], blocked_details=[dict(name='a.swift', reason='r')] * 3)
    for key in ('failed_tests', 'skipped_tests', 'incomplete_tests'):
        row[key] = names.get(key, [])
        row[key + '_truncated'] = names.get(key + '_truncated', 0)
    return row


def result(run_id, ts, stages, machine='m4'):
    return dict(schema=1, run_id=run_id, ts=ts, machine=machine, commit='a' * 40, status='failed',
                publish='published', roots=dict(home='/x/home'), stages=stages)


@unittest.skipUnless(sys.platform == "darwin", "macOS-only: builds with /usr/bin/swiftc")
class GauntletSummaryRowTests(unittest.TestCase):
    """The summary row is the only record left once the run dir is gone."""

    @classmethod
    def setUpClass(cls):
        cls.workspace = tempfile.TemporaryDirectory(prefix='gauntlet-summary-', dir='/private/tmp')
        cls.binary = runner_binary(Path(cls.workspace.name))

    @classmethod
    def tearDownClass(cls):
        cls.workspace.cleanup()

    def case_dir(self):
        case = tempfile.TemporaryDirectory(dir=self.workspace.name)
        self.addCleanup(case.cleanup)
        return Path(case.name)

    def seam(self, *args):
        done = subprocess.run([str(self.binary), *map(str, args)], text=True, capture_output=True, timeout=120)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        return json.loads(done.stdout)

    # -- names, from the sources the counts come from -------------------------

    def test_package_names_failed_skipped_and_incomplete_even_when_the_run_was_killed(self):
        case = self.case_dir()
        ids = [f'M.S/{n}()/T.swift:{i}:4' for i, n in enumerate(['ok', 'bad', 'off', 'hung', 'never'])]
        records = [declared('M.S', 'suite')] + [declared(i) for i in ids] + [
            event('runStarted'), event('testStarted', ids[0]), event('testEnded', ids[0]),
            event('testStarted', ids[1]), event('issueRecorded', ids[1], issue=FAIL), event('testEnded', ids[1]),
            event('testSkipped', ids[2]), event('testStarted', ids[3])]       # killed: no runEnded, 'never' not started
        stream = case / 'events.jsonl'
        stream.write_text(''.join(json.dumps(r) + '\n' for r in records) + '{"kind": "ev')  # torn last line
        console = case / 'console.log'
        console.write_text("Test Suite 'Selected tests' started at 2026-11-08 14:00:00.000.\n"
                           "Test Case '-[M.X testA]' started.\nTest Case '-[M.X testA]' failed (0.1 seconds).\n"
                           "Test Case '-[M.X testB]' started.\n")                # killed mid-test
        listing = case / 'list.txt'
        listing.write_text('M.X/testA\nM.X/testB\nM.X/testC\nM.S/ok()\n')
        names = self.seam('--package-names', stream, console, listing)
        self.assertEqual(names['failed_tests'], ['M.S/bad()', 'M.X/testA'])
        self.assertEqual(names['skipped_tests'], ['M.S/off()'])
        self.assertEqual(names['incomplete_tests'], ['M.S/hung()', 'M.S/never()', 'M.X/testB', 'M.X/testC'])
        self.assertEqual(names['failed_tests_truncated'], 0)

    def test_xcode_names_from_the_xcresult_summary_and_tests_tree(self):
        case = self.case_dir()
        summary = case / 'unit-summary.json'
        summary.write_text(json.dumps(dict(result='Failed', passedTests=5, failedTests=2, skippedTests=1, totalTestCount=8,
            testFailures=[dict(testName='testA()', testIdentifierString='VideoScanTests.Foo/testA()', failureText='x'),
                          dict(testName='testA()', testIdentifierString='VideoScanTests.Foo/testA()', failureText='y'),
                          dict(testName='testB()', targetName='VideoScanTests')])))
        tree = case / 'unit-tests.json'
        tree.write_text(json.dumps(dict(testNodes=[dict(name='VideoScanTests', nodeType='Unit test bundle', result='Failed', children=[
            dict(name='Foo', nodeType='Test Suite', result='Failed', children=[
                dict(name='testA()', nodeIdentifier='Foo/testA()', nodeType='Test Case', result='Failed'),
                dict(name='testS()', nodeIdentifier='Foo/testS()', nodeType='Test Case', result='Skipped'),
                dict(name='testP()', nodeIdentifier='Foo/testP()', nodeType='Test Case', result='Passed')])])])))
        names = self.seam('--xcode-names', summary, tree)
        self.assertEqual(names['failed_tests'], ['VideoScanTests.Foo/testA()', 'VideoScanTests/testB()'])
        self.assertEqual(names['skipped_tests'], ['Foo/testS()'])
        self.assertEqual(names['incomplete_tests'], [])

    def test_name_lists_are_capped_at_200_with_a_truncated_count(self):
        case = self.case_dir()
        summary = case / 's.json'
        summary.write_text(json.dumps(dict(result='Failed', passedTests=0, failedTests=250, skippedTests=0, totalTestCount=250,
            testFailures=[dict(testName=f't{i:03}()', testIdentifierString=f'C/t{i:03}()') for i in range(250)])))
        names = self.seam('--xcode-names', summary)
        self.assertEqual(len(names['failed_tests']), 200)
        self.assertEqual(names['failed_tests'][0], 'C/t000()')
        self.assertEqual(names['failed_tests_truncated'], 50)

    # -- the history row ----------------------------------------------------

    def history_row(self, current, *previous):
        case = self.case_dir()
        history = case / 'history.jsonl'
        history.write_text(''.join(json.dumps(r) + '\n' for r in previous))
        path = case / 'result.json'
        path.write_text(json.dumps(current))
        return self.seam('--history-row', path, history)

    def test_row_has_totals_and_names_and_no_links_into_the_run_dir(self):
        row = self.history_row(result('2026-11-08T14-00-00Z-R0000001', '2026-11-08T14:00:00Z', [
            stage('unit', 'failed', passed=100, failed=2, failed_tests=['A/t1()', 'A/t2()']),
            stage('regression', 'failed', passed=50, skipped=1, known=3, skipped_tests=['B/s()'], incomplete_tests=['B/h()']),
            dict(name='ui', status='not_run', reason='phase 2', passed=None, failed=None, skipped=None, incomplete=1)]))
        self.assertEqual(row['totals'], dict(passed=150, failed=2, skipped=1, known_issues=3, unknown=1))
        self.assertEqual(row['stages'][0]['failed_tests'], ['A/t1()', 'A/t2()'])
        self.assertEqual(row['stages'][1]['skipped_tests'], ['B/s()'])
        for gone in ('roots',):
            self.assertNotIn(gone, row)
        for s in row['stages']:
            self.assertNotIn('artifacts', s)
            self.assertNotIn('blocked_details', s)
        self.assertEqual(row['stages'][0]['blocked_suites'], 3)
        for kept in ('ts', 'machine', 'commit', 'status', 'publish', 'run_id'):
            self.assertIn(kept, row)
        self.assertLess(len(json.dumps(row)), 5000)

    def test_new_failures_fixed_and_first_failed_against_the_previous_row_for_this_machine(self):
        older = result('2026-11-06T14-00-00Z-R0000001', '2026-11-06T14:00:00Z', [
            stage('unit', 'failed', failed=2, failed_tests=['A/old()', 'A/flaky()'])])
        older['first_failed'] = {'A/old()': '2026-11-01T14:00:00Z'}
        previous = result('2026-11-07T14-00-00Z-R0000002', '2026-11-07T14:00:00Z', [
            stage('unit', 'failed', failed=3, failed_tests=['A/old()', 'A/flaky()', 'A/fixedNow()']),
            stage('stress', 'failed', failed=1, failed_tests=['S/notRunNow()'])])
        previous['first_failed'] = {'A/old()': '2026-11-01T14:00:00Z', 'A/flaky()': '2026-11-06T14:00:00Z',
                                    'A/fixedNow()': '2026-11-07T14:00:00Z', 'S/notRunNow()': '2026-11-07T14:00:00Z'}
        other_machine = result('2026-11-08T02-00-00Z-R0000003', '2026-11-08T02:00:00Z', [
            stage('unit', 'failed', failed=1, failed_tests=['A/elsewhere()'])], machine='m5')
        current = result('2026-11-08T14-00-00Z-R0000004', '2026-11-08T14:00:00Z', [
            stage('unit', 'failed', failed=3, failed_tests=['A/old()', 'A/flaky()', 'A/brandNew()']),
            dict(name='stress', status='blocked', reason='interrupted', passed=None, failed=None, skipped=None, incomplete=1)])
        row = self.history_row(current, older, previous, other_machine)
        self.assertEqual(row['compared_to'], '2026-11-07T14-00-00Z-R0000002')
        self.assertEqual(row['new_failures'], ['A/brandNew()'])
        self.assertEqual(row['fixed'], ['A/fixedNow()'])                  # S/notRunNow(): its stage did not run, not fixed
        self.assertEqual(row['first_failed'], {'A/old()': '2026-11-01T14:00:00Z', 'A/flaky()': '2026-11-06T14:00:00Z',
                                               'A/brandNew()': '2026-11-08T14:00:00Z'})

    def test_a_test_skipped_or_incomplete_now_is_not_fixed(self):
        previous = result('2026-11-07T14-00-00Z-R0000002', '2026-11-07T14:00:00Z', [
            stage('unit', 'failed', failed=2, failed_tests=['A/s()', 'A/h()'])])
        current = result('2026-11-08T14-00-00Z-R0000004', '2026-11-08T14:00:00Z', [
            stage('unit', 'failed', skipped=1, skipped_tests=['A/s()'], incomplete_tests=['A/h()'])])
        self.assertEqual(self.history_row(current, previous)['fixed'], [])

    def test_first_row_for_a_machine_compares_to_nothing(self):
        current = result('2026-11-08T14-00-00Z-R0000004', '2026-11-08T14:00:00Z', [
            stage('unit', 'failed', failed=1, failed_tests=['A/x()'])])
        other_machine = result('2026-11-07T14-00-00Z-R0000002', '2026-11-07T14:00:00Z', [], machine='m1')
        row = self.history_row(current, other_machine)
        self.assertIsNone(row['compared_to'])
        self.assertEqual(row['new_failures'], ['A/x()'])
        self.assertEqual(row['fixed'], [])
        self.assertEqual(row['first_failed'], {'A/x()': '2026-11-08T14:00:00Z'})

    def test_scale_a_long_history_is_streamed_within_budget(self):
        case = self.case_dir()
        history = case / 'history.jsonl'
        old = result('2026-11-01T14-00-00Z-R0000001', '2026-11-01T14:00:00Z',
                     [stage('unit', 'failed', failed=200, failed_tests=[f'A/t{i}()' for i in range(200)])])
        line = json.dumps(old) + '\n'
        history.write_text(line * 2000)                                   # ~2000 runs, ~10 MB
        path = case / 'result.json'
        path.write_text(json.dumps(result('2026-11-08T14-00-00Z-R0000004', '2026-11-08T14:00:00Z',
                                          [stage('unit', 'failed', failed=1, failed_tests=['A/t1()'])])))
        start = time.monotonic()
        row = self.seam('--history-row', path, history)
        self.assertLess(time.monotonic() - start, 10)
        self.assertEqual(row['new_failures'], [])
        self.assertEqual(len(row['fixed']), 199)


class SummaryReadsHistoryWhenRunIsGoneTests(unittest.TestCase):
    """nightly_gauntlet.sh reads the verdict after the runner exits: by then a
    published run dir is gone, so m4_run_summary.py reads its history row."""

    def test_verdict_comes_from_the_history_row_when_result_json_is_gone(self):
        sys.path.insert(0, str(REPO / 'scripts'))
        import m4_run_summary
        with tempfile.TemporaryDirectory(dir='/private/tmp') as tmp:
            root = Path(tmp)
            run_id = '2026-11-08T14-00-00Z-R0000004'
            row = result(run_id, '2026-11-08T14:00:00Z', [stage('unit', 'failed', failed=1, failed_tests=['A/x()'])])
            (root / 'history.jsonl').write_text(json.dumps(result('other', 'x', [])) + '\n' + json.dumps(row) + '\n')
            done = subprocess.run([sys.executable, str(REPO / 'scripts/m4_run_summary.py'), '--gauntlet',
                                   str(root / run_id / 'result.json'), '1', '60'], text=True, capture_output=True, timeout=60)
            self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
            self.assertIn('deep: RED unit failed', done.stdout)
            self.assertIn('sha=aaaaaaaaa', done.stdout)
            self.assertIsNone(m4_run_summary.load_result(str(root / 'missing-run' / 'result.json')))


if __name__ == '__main__':
    unittest.main()
