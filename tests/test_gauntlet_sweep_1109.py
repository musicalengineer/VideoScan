"""Codex sweep 2026-11-09 (cycle #266, "gauntlet deletion and verdict truth").

F1 P0  retention removed ANY directory whose name started with a parseable
       timestamp ("2026-11-01T00-00-00Z-family-backup/precious.mov") — no
       proof the runner made it.
F2 P1  retention removed an old run whose summary row was never written to
       history.jsonl (a crash after result.json, before the row) — the only
       record of that run. Rick 11/08: "delete them all, once we have the
       summary data": no summary row, no whole-run delete (the regenerable
       build products still go).
F3 P1  history rows were appended with seek-to-end + write: two writers
       could overwrite each other's row. O_APPEND makes the kernel place
       every write at the end.
F5 P1  `fixed` counted a previously failing test as fixed when it was only
       beyond the 200-name cap (`_truncated`), or when the package build
       failed and supplied no names.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_gauntlet_run_tidy import NOW, make_run, result, runner_binary, stage, write_history  # noqa: E402


@unittest.skipUnless(sys.platform == "darwin", "macOS-only: builds with /usr/bin/swiftc")
class GauntletSweep1109Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workspace = tempfile.TemporaryDirectory(prefix='gauntlet-sweep-', dir='/private/tmp')
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
        return done.stdout

    # -- F1: only the runner's own run dirs ----------------------------------

    def test_f1_retention_never_removes_a_directory_the_runner_did_not_make(self):
        root = self.case_dir() / 'gauntlet'
        root.mkdir()
        backup = root / '2026-11-01T00-00-00Z-family-backup'
        backup.mkdir()
        (backup / 'precious.mov').write_bytes(b'family')
        lookalike = root / '2026-11-01T00-00-00Z-ABCD1234'       # the run-name shape, but no runner marker
        lookalike.mkdir()
        (lookalike / 'keep.txt').write_text('mine')
        (lookalike / 'result.json').write_text('{}')
        write_history(root, lookalike.name)
        self.assertEqual(json.loads(self.seam('--retention-plan', root, NOW)), [])
        self.seam('--retain', root, NOW)
        self.assertTrue((backup / 'precious.mov').exists())
        self.assertTrue((lookalike / 'keep.txt').exists())

    def test_f1_an_owned_old_run_with_its_summary_row_is_still_removed(self):
        root = self.case_dir() / 'gauntlet'
        root.mkdir()
        run = make_run(root, '2026-10-20T14-00-00Z-0LD00001')
        (run / '.gauntlet-run').write_text(run.name)
        write_history(root, run.name)
        out = self.seam('--retain', root, NOW)
        self.assertFalse(run.exists(), out)
        self.assertIn(f'GAUNTLET RETENTION removed {run}', out)

    # -- F2: no summary row, no whole-run delete -----------------------------

    def test_f2_an_old_run_with_no_summary_row_keeps_its_record_and_loses_only_build_products(self):
        root = self.case_dir() / 'gauntlet'
        root.mkdir()
        crashed = make_run(root, '2026-10-20T14-00-00Z-CRASH001')          # result.json, no history row
        (crashed / '.gauntlet-run').write_text(crashed.name)
        (root / 'history.jsonl').write_text('')
        out = self.seam('--retain', root, NOW)
        self.assertTrue((crashed / 'logs' / 'build.log').exists(), out)
        self.assertTrue((crashed / 'result.json').exists(), out)
        for gone in ('DerivedData', 'PackageBuild', 'swift-cache'):
            self.assertFalse((crashed / gone).exists(), gone)
        self.assertIn('no summary row in history.jsonl', out)

    # -- F3: concurrent appends never overwrite each other -------------------

    def test_f3_two_concurrent_history_writers_lose_no_line(self):
        case = self.case_dir()
        history = case / 'history.jsonl'
        history.write_text('')
        n = 1500
        procs = [subprocess.Popen([str(self.binary), '--append-lines', str(history), tag, str(n)],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE) for tag in ('A', 'B', 'C')]
        for p in procs:
            self.assertEqual(p.wait(timeout=120), 0, p.stderr.read())
        lines = history.read_text().splitlines()
        rows = []
        for line in lines:
            try:
                rows.append(json.loads(line))
            except ValueError:
                pass
        self.assertEqual(len(rows), 3 * n, f'{len(lines)} lines, {len(rows)} intact rows of {3 * n}')

    # -- F5: no evidence, no "fixed" -----------------------------------------

    def history_row(self, current, *previous):
        case = self.case_dir()
        history = case / 'history.jsonl'
        history.write_text(''.join(json.dumps(r) + '\n' for r in previous))
        path = case / 'result.json'
        path.write_text(json.dumps(current))
        return json.loads(self.seam('--history-row', path, history))

    def test_f5_a_failure_beyond_the_name_cap_is_not_fixed(self):
        previous = result('2026-11-07T14-00-00Z-R0000002', '2026-11-07T14:00:00Z', [
            stage('unit', 'failed', failed=1, failed_tests=['Z/test()'])])
        shown = [f'A/t{i:03}()' for i in range(200)]
        current = result('2026-11-08T14-00-00Z-R0000004', '2026-11-08T14:00:00Z', [
            stage('unit', 'failed', passed=5, failed=201, failed_tests=shown, failed_tests_truncated=1)])
        self.assertEqual(self.history_row(current, previous)['fixed'], [])

    def test_f5_a_failed_package_build_fixes_nothing(self):
        previous = result('2026-11-07T14-00-00Z-R0000002', '2026-11-07T14:00:00Z', [
            stage('unit', 'failed', failed=1, failed_tests=['VideoScanCoreTests.P/pkg()'])])
        current = result('2026-11-08T14-00-00Z-R0000004', '2026-11-08T14:00:00Z', [
            stage('unit', 'failed', passed=10, failed=0)])
        current['package_build_exit_code'] = 1
        self.assertEqual(self.history_row(current, previous)['fixed'], [])


if __name__ == '__main__':
    unittest.main()
