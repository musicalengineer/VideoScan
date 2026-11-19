"""The scheduled nightly keeps its own logs bounded (worker A, 2026-11-18; DECISIONS 2026-11-18: a run's
scratch goes once it is summarized). RED before: ~/Library/Logs/VideoScan/nightly_test_<stamp>.log
(~48 MB each on the M4) was never removed — 13 files, 620 MB since 11/10, one more every day.

The function is the text between its markers in scripts/nightly_local_tests.sh, run here with bash in
a temporary log folder: the newest N stay, older ones go; only that name, regular files, directly in the
folder; a link is left as it is; a log folder that is a link is not touched."""
import os
import pathlib
import subprocess
import tempfile
import time
import unittest

REPO = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = REPO / 'scripts' / 'nightly_local_tests.sh'


def function_text():
    text = SCRIPT.read_text()
    start, end = text.index('# >>> prune_nightly_logs'), text.index('# <<< prune_nightly_logs')
    return text[start:end]


def run(logdir, keep):
    return subprocess.run(['/bin/bash', '-c', function_text() + f'\nLOGDIR="$1"; prune_nightly_logs {keep}', 'x', str(logdir)],
                          capture_output=True, text=True, timeout=30)


class NightlyLogRetentionTests(unittest.TestCase):

    def test_the_newest_logs_stay_and_older_ones_go(self):
        with tempfile.TemporaryDirectory() as tmp:
            logs = pathlib.Path(tmp, 'Logs')
            logs.mkdir()
            now = time.time()
            names = [f'nightly_test_202611{d:02d}_140007.log' for d in range(1, 21)]
            for i, name in enumerate(names):
                (logs / name).write_text('x')
                os.utime(logs / name, (now - (20 - i) * 86400, now - (20 - i) * 86400))
            for other in ('nightly-pending.jsonl', 'coverage.log', 'nightly_test_notes.txt'):
                (logs / other).write_text('keep')
            outside = pathlib.Path(tmp, 'outside.log')
            outside.write_text('keep')
            os.symlink(outside, logs / 'nightly_test_20251231_000000.log')
            done = run(logs, 14)
            self.assertEqual(done.returncode, 0, done.stderr)
            left = sorted(p.name for p in logs.iterdir() if p.name.startswith('nightly_test_2026'))
            self.assertEqual(left, names[-14:])
            for other in ('nightly-pending.jsonl', 'coverage.log', 'nightly_test_notes.txt'):
                self.assertTrue((logs / other).exists(), other)
            self.assertTrue((logs / 'nightly_test_20251231_000000.log').is_symlink() and outside.exists())

    def test_a_log_folder_that_is_a_link_is_not_touched(self):
        with tempfile.TemporaryDirectory() as tmp:
            real = pathlib.Path(tmp, 'real')
            real.mkdir()
            for d in range(1, 5):
                (real / f'nightly_test_2026110{d}_140007.log').write_text('x')
            os.symlink(real, pathlib.Path(tmp, 'Logs'))
            run(pathlib.Path(tmp, 'Logs'), 1)
            self.assertEqual(len(list(real.iterdir())), 4)

    def test_only_a_scheduled_run_prunes(self):
        text = SCRIPT.read_text()
        self.assertIn('[ "$NIGHTLY_ON_DEMAND" = 1 ] || prune_nightly_logs "$NIGHTLY_LOGS_KEPT"', text)


if __name__ == '__main__':
    unittest.main()
