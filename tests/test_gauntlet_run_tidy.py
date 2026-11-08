"""Gauntlet runs clean up after themselves (Rick 2026-11-08).

Each run dir under ~/Library/Logs/VideoScan/gauntlet/<ts>-<id>/ kept its
DerivedData (~5 GB), PackageBuild (~1.3 GB) and swift-cache forever; the M4
testbed reached 102 GB of them and 86% full. Two rules, both in Runner.swift:

1. TIDY: once result.json and the history row are written, the run removes its
   own build scratch (DerivedData, PackageBuild, swift-cache) and keeps the
   evidence (logs, *.xcresult, result.json, caches). Never before result.json
   exists; never with --keep-build.
2. RETENTION: at the start of a run, finished run dirs (have result.json) whose
   NAME date is older than 14 days are removed (Rick 2026-11-08: "we don't need
   them"; history.jsonl keeps every run's summary row). Never history.jsonl,
   pending-metrics*, a symlink, or an unfinished run; mtime is ignored.

Seams (Runner.swift main()):
  --retention-plan <results-root> <now-iso8601>   prints the JSON list to move
  --retain <results-root> <now-iso8601>           removes them
  --tidy-build <run> [--keep-build]               the end-of-run tidy
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
NOW = '2026-11-08T20:00:00Z'


def runner_binary(workspace):
    binary = workspace / 'runner'
    subprocess.run(['/usr/bin/swiftc', '-module-cache-path', str(workspace / 'swift-cache'),
                    str(REPO / 'scripts/gauntlet/Runner.swift'), '-o', str(binary)], check=True, capture_output=True)
    return binary


def make_run(root, name, finished=True, build=True):
    run = root / name
    (run / 'logs').mkdir(parents=True)
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

    def test_tidy_removes_only_build_scratch_of_a_finished_run(self):
        run = make_run(self.case_dir(), '2026-11-08T19-19-00Z-AAAA0001')
        out = self.seam('--tidy-build', run)
        for gone in ('DerivedData', 'PackageBuild', 'swift-cache'):
            self.assertFalse((run / gone).exists(), gone)
        for kept in ('logs/build.log', 'unit.xcresult', 'caches', 'result.json'):
            self.assertTrue((run / kept).exists(), kept)
        self.assertRegex(out, r'GAUNTLET TIDY removed build products \(\d+\.\d+ GB\) from ' + str(run))

    def test_tidy_refuses_before_result_json_exists(self):
        run = make_run(self.case_dir(), '2026-11-08T19-19-00Z-AAAA0002', finished=False)
        out = self.seam('--tidy-build', run)
        for kept in ('DerivedData', 'PackageBuild', 'swift-cache'):
            self.assertTrue((run / kept).exists(), kept)
        self.assertIn('kept build products', out)

    def test_keep_build_flag_keeps_everything(self):
        run = make_run(self.case_dir(), '2026-11-08T19-19-00Z-AAAA0003')
        out = self.seam('--tidy-build', run, '--keep-build')
        for kept in ('DerivedData', 'PackageBuild', 'swift-cache'):
            self.assertTrue((run / kept).exists(), kept)
        self.assertIn('--keep-build', out)

    def test_tidy_of_a_run_without_build_products_is_quiet_and_safe(self):
        run = make_run(self.case_dir(), '2026-11-08T19-19-00Z-AAAA0004', build=False)
        out = self.seam('--tidy-build', run)
        self.assertIn('(0.00 GB)', out)
        self.assertTrue((run / 'result.json').exists())

    def test_tidy_does_not_follow_a_symlinked_scratch_dir(self):
        case = self.case_dir()
        outside = case / 'outside'
        outside.mkdir()
        (outside / 'precious.mov').write_bytes(b'media')
        run = make_run(case, '2026-11-08T19-19-00Z-AAAA0005', build=False)
        os.symlink(outside, run / 'DerivedData')
        self.seam('--tidy-build', run)
        self.assertTrue((outside / 'precious.mov').exists())

    def test_runner_accepts_keep_build_in_its_option_parser(self):
        done = subprocess.run([str(self.binary), '--help'], text=True, capture_output=True, timeout=60)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn('--keep-build', done.stdout)

    # -- retention ----------------------------------------------------------

    def results_root(self):
        root = self.case_dir() / 'gauntlet'
        root.mkdir()
        make_run(root, '2026-10-20T14-00-00Z-OLD00001')                   # 19 days: removed
        make_run(root, '2026-10-25T19-59-59Z-OLD00002')                   # just over 14 days: removed
        make_run(root, '2026-10-25T20-00-01Z-NEW00001')                   # just under: stays
        make_run(root, '2026-11-08T14-00-00Z-NEW00002')                   # today: stays
        make_run(root, '2026-09-01T14-00-00Z-UNFIN001', finished=False)   # no result.json: stays
        (root / 'history.jsonl').write_text('{}\n')
        (root / 'pending-metrics.jsonl').write_text('{}\n')
        (root / 'pending-metrics.lock').write_text('')
        (root / 'not-a-run').mkdir()
        (root / 'not-a-run' / 'result.json').write_text('{}')
        # Fresh mtime on an old name, old mtime on a new name: the name decides.
        os.utime(root / '2026-10-20T14-00-00Z-OLD00001', (0, 2_000_000_000))
        os.utime(root / '2026-11-08T14-00-00Z-NEW00002', (0, 0))
        return root

    def test_retention_plan_picks_finished_runs_older_than_14_days_by_name(self):
        root = self.results_root()
        plan = json.loads(self.seam('--retention-plan', root, NOW))
        self.assertEqual(plan, ['2026-10-20T14-00-00Z-OLD00001', '2026-10-25T19-59-59Z-OLD00002'])

    def test_retain_removes_old_finished_runs_and_nothing_else(self):
        root = self.results_root()
        before = sorted(p.name for p in root.iterdir())
        out = self.seam('--retain', root, NOW)
        removed = ['2026-10-20T14-00-00Z-OLD00001', '2026-10-25T19-59-59Z-OLD00002']
        self.assertEqual(sorted(p.name for p in root.iterdir()), sorted(set(before) - set(removed)))
        for name in removed:
            self.assertIn(f'GAUNTLET RETENTION removed {root / name}', out)
        self.assertEqual(len(out.strip().splitlines()), 2, out)
        self.assertEqual((root / 'history.jsonl').read_text(), '{}\n')
        self.assertEqual((root / 'pending-metrics.jsonl').read_text(), '{}\n')
        self.assertTrue((root / '2026-09-01T14-00-00Z-UNFIN001' / 'logs' / 'build.log').exists())

    def test_retain_with_nothing_old_prints_nothing_and_removes_nothing(self):
        root = self.case_dir() / 'gauntlet'
        root.mkdir()
        make_run(root, '2026-11-08T14-00-00Z-NEW00002')
        (root / 'history.jsonl').write_text('{}\n')
        self.assertEqual(self.seam('--retain', root, NOW), '')
        self.assertEqual(sorted(p.name for p in root.iterdir()), ['2026-11-08T14-00-00Z-NEW00002', 'history.jsonl'])

    def test_retain_never_follows_a_symlinked_run_dir(self):
        case = self.case_dir()
        root = case / 'gauntlet'
        root.mkdir()
        elsewhere = make_run(case, '2026-10-01T14-00-00Z-ELSE0001')
        os.symlink(elsewhere, root / '2026-10-01T14-00-00Z-LINK0001')
        self.assertEqual(json.loads(self.seam('--retention-plan', root, NOW)), [])
        self.seam('--retain', root, NOW)
        self.assertTrue((elsewhere / 'result.json').exists())
        self.assertTrue((root / '2026-10-01T14-00-00Z-LINK0001').is_symlink())


if __name__ == '__main__':
    unittest.main()
