"""The stall watchdog samples the hung process even when it left the group.

2026-10-28 nightly on the M5 Ultra: the Core lane stalled 900 s and the
sample file held only `swift-package` (idle in its run loop). SwiftPM starts
the test runner in a process group of its own, so `pgrep -g <leader>` never
saw the stuck `xctest` and the hang left no stack. The watchdog must sample
the leader's whole descendant tree.
"""
import os
import signal
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
LIB = REPO / "scripts" / "lib" / "process_group_watchdog.sh"

# The command under the watchdog: start a grandchild in its own session
# (like SwiftPM's xctest), record its pid, then hang without output.
COMMAND = r"""
import os, subprocess, sys, time
p = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(120)"],
                     start_new_session=True)
open(sys.argv[1], "w").write(str(p.pid))
time.sleep(120)
"""


class WatchdogSamplesTreeTests(unittest.TestCase):
    def test_a_grandchild_in_its_own_group_is_sampled(self):
        with tempfile.TemporaryDirectory() as tmp:
            pid_file = Path(tmp) / "grandchild.pid"
            sample_file = Path(tmp) / "sample.txt"
            log_file = Path(tmp) / "out.log"
            env = dict(os.environ,
                       VIDEOSCAN_WATCHDOG_STALL_SECONDS="2",
                       VIDEOSCAN_WATCHDOG_SAMPLE_FILE=str(sample_file))
            script = 'source "$1"; shift; run_with_process_group_watchdog 60 1 "$@"'
            grandchild = None
            try:
                started = time.monotonic()
                rc = subprocess.run(
                    ["bash", "-c", script, "watchdog", str(LIB), str(log_file),
                     "python3", "-c", COMMAND, str(pid_file)],
                    env=env, timeout=90).returncode
                self.assertEqual(rc, 124, "a stalled command is stopped with 124")
                self.assertLess(time.monotonic() - started, 60, "stopped by the stall, not the deadline")
                grandchild = int(pid_file.read_text())
                text = sample_file.read_text()
                self.assertIn("===== sample of pid %d =====" % grandchild, text,
                              "the hung grandchild outside the group was not sampled:\n" + text[:400])
            finally:
                if grandchild is None and pid_file.exists():
                    grandchild = int(pid_file.read_text())
                if grandchild:
                    try:
                        os.kill(grandchild, signal.SIGKILL)
                    except ProcessLookupError:
                        pass


if __name__ == "__main__":
    unittest.main()
