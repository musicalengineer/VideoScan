"""scripts/nightly_gauntlet.sh — the M4's 14:00 full testbed (Rick, 2026-11-05).

Rick: "It is important at 1400 when it completes, whenever that is, to have it
show up on the m4 and/or the metrics page ... 'm4 full testbed done, see
results here ...'". These tests pin that contract:

- the suite runs, then the gauntlet runs PUBLISHED (never --queue-only, or the
  page would never see it), with the rota's machine label;
- one done line lands in testbed_latest.txt and goes to Rick's Mac as a
  notification, carrying both verdicts, the counts and the page URL;
- RED is never hidden: a RED gauntlet or a red suite makes the exit non-zero;
- the testbed lock is shared with scripts/m4_run.sh: a live on-demand run
  makes the gauntlet skip (said in the line), and the lock is released after;
- a failed notification never changes the outcome;
- nightly_rota.py `gauntlet` says yes only for listed, on-rota Macs.

Everything runs for real in a fake HOME with a fake suite, a fake
run_gauntlet.sh and a fake ssh on PATH; the real m4_run_summary.py and
nightly_rota.py decide. No xcodebuild, no network, no notification.
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
SCRIPT = REPO / "scripts/nightly_gauntlet.sh"
sys.path.insert(0, str(REPO / "scripts"))
import nightly_rota  # noqa: E402

FAKE_SUITE = r'''#!/bin/sh
# Stand-in for nightly_local_tests.sh: writes the log line the real one writes.
d="$HOME/Library/Logs/VideoScan"; mkdir -p "$d"
echo "[x] Results: $(cat "$FAKE/suite_passed")p / $(cat "$FAKE/suite_failed")f / 1s ($(cat "$FAKE/suite_total") total; 0 passed with known issues)" > "$d/nightly_test_20991231_140000.log"
exit "$(cat "$FAKE/suite_rc")"
'''

FAKE_GAUNTLET = r'''#!/bin/sh
# Stand-in for run_gauntlet.sh: records its arguments, prints the runner's line.
echo "$@" > "$FAKE/gauntlet_args"
status=$(cat "$FAKE/g_status")
printf 'GAUNTLET %s sha=abc12345 total=9s results=%s publish=published\n' "$status" "$FAKE/result.json"
exit "$(cat "$FAKE/g_rc")"
'''

FAKE_SSH = r'''#!/bin/sh
# Stand-in for ssh: records the call; fails when told to.
printf '%s\n' "$@" > "$FAKE/ssh_args"
exit "$(cat "$FAKE/ssh_rc" 2>/dev/null || echo 0)"
'''


def result_json(status, regression="passed", known=0):
    stages = [
        {"name": "unit", "status": "passed", "known_issues": 0, "blocked_details": []},
        {"name": "regression", "status": regression, "known_issues": known, "blocked_details": [],
         "reason": "test failures" if regression == "failed" else None},
        {"name": "ui", "status": "not_run", "reason": "phase 2", "blocked_details": []},
    ]
    return {"status": status, "commit": "abc12345", "stages": stages, "inventory_errors": []}


class NightlyGauntletTests(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        t = pathlib.Path(self.tmp.name)
        self.home = t / "home"
        self.repo = t / "repo"
        self.fake = t / "fake"
        self.bin = t / "bin"
        for d in (self.home, self.repo / "scripts", self.fake, self.bin):
            d.mkdir(parents=True)
        for name in ("nightly_gauntlet.sh", "nightly_rota.py", "nightly_rota.json", "m4_run_summary.py"):
            shutil.copy(REPO / "scripts" / name, self.repo / "scripts" / name)
        for path, body in ((self.repo / "scripts/nightly_local_tests.sh", FAKE_SUITE),
                           (self.repo / "scripts/run_gauntlet.sh", FAKE_GAUNTLET),
                           (self.bin / "ssh", FAKE_SSH)):
            path.write_text(body)
            path.chmod(0o755)
        git_env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t",
                       GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t")
        subprocess.run(["git", "-C", str(self.repo), "init", "-q"], check=True, env=git_env)
        subprocess.run(["git", "-C", str(self.repo), "add", "-A"], check=True, env=git_env)
        subprocess.run(["git", "-C", str(self.repo), "commit", "-q", "-m", "x"], check=True, env=git_env)
        self.sha = subprocess.run(["git", "-C", str(self.repo), "rev-parse", "--short", "HEAD"],
                                  check=True, capture_output=True, text=True).stdout.strip()
        self.lock = self.home / "m4run" / "lock"
        self.env = dict(os.environ, HOME=str(self.home), FAKE=str(self.fake),
                        PATH=f"{self.bin}:{os.environ['PATH']}", VIDEOSCAN_HOST="RicksM4",
                        VIDEOSCAN_NOTIFY_HOST="rickmac.test")
        self.plant()

    def tearDown(self):
        self.tmp.cleanup()

    def plant(self, suite_rc=0, passed=12, failed=0, total=12, g_status="AMBER", g_rc=0,
              result=None, ssh_rc=0):
        for name, value in (("suite_rc", suite_rc), ("suite_passed", passed), ("suite_failed", failed),
                            ("suite_total", total), ("g_status", g_status), ("g_rc", g_rc),
                            ("ssh_rc", ssh_rc)):
            (self.fake / name).write_text(str(value))
        result = result or result_json("amber", known=7)
        (self.fake / "result.json").write_text(json.dumps(result))

    def run_it(self):
        r = subprocess.run(["bash", str(self.repo / "scripts/nightly_gauntlet.sh")], env=self.env,
                           capture_output=True, text=True, timeout=60)
        latest = self.home / "Library/Logs/VideoScan/testbed_latest.txt"
        line = latest.read_text().strip() if latest.exists() else ""
        return r.returncode, line

    def test_green_suite_amber_gauntlet_writes_the_done_line_and_notifies(self):
        rc, line = self.run_it()
        self.assertEqual(rc, 0)
        self.assertTrue(line.startswith("M4 full testbed done "), line)
        self.assertIn(f"(main {self.sha})", line)
        self.assertIn("nightly suite GREEN 12/12 passed, 0 failed", line)
        self.assertIn("gauntlet AMBER", line)
        self.assertIn("7 known issues", line)
        self.assertIn("results https://musicalengineer.github.io/VideoScan/", line)
        history = (self.home / "Library/Logs/VideoScan/testbed_history.log").read_text()
        self.assertIn(line, history)
        ssh = (self.fake / "ssh_args").read_text()
        self.assertIn("rickmac.test", ssh)
        self.assertIn("display notification", ssh)
        self.assertIn("M4 full testbed done", ssh)

    def test_gauntlet_is_published_never_queue_only_with_the_rota_machine(self):
        self.run_it()
        args = (self.fake / "gauntlet_args").read_text().split()
        self.assertIn("--away", args)
        self.assertNotIn("--queue-only", args)
        self.assertEqual(args[args.index("--machine") + 1], "m4")

    def test_red_gauntlet_is_red_in_the_line_and_the_exit(self):
        self.plant(g_status="FAILED", g_rc=1,
                   result=result_json("failed", regression="failed"))
        rc, line = self.run_it()
        self.assertEqual(rc, 1)
        self.assertIn("gauntlet RED", line)

    def test_red_suite_still_runs_the_gauntlet_and_exits_red(self):
        self.plant(suite_rc=1, passed=10, failed=2, total=12)
        rc, line = self.run_it()
        self.assertEqual(rc, 1)
        self.assertIn("nightly suite RED 10/12 passed, 2 failed", line)
        self.assertIn("gauntlet AMBER", line)
        self.assertTrue((self.fake / "gauntlet_args").exists())

    def test_gauntlet_that_prints_nothing_is_red(self):
        (self.repo / "scripts/run_gauntlet.sh").write_text("#!/bin/sh\nexit 1\n")
        rc, line = self.run_it()
        self.assertEqual(rc, 1)
        self.assertIn("gauntlet RED", line)

    def test_a_crashed_summary_is_red(self):
        (self.repo / "scripts/m4_run_summary.py").write_text("raise SystemExit(2)\n")
        rc, line = self.run_it()
        self.assertEqual(rc, 1)
        self.assertIn("gauntlet RED", line)

    def test_a_live_on_demand_run_skips_the_gauntlet_and_keeps_its_lock(self):
        holder = subprocess.Popen(["sleep", "30"])
        try:
            self.lock.mkdir(parents=True)
            (self.lock / "pid").write_text(str(holder.pid))
            (self.lock / "info").write_text("deep 2673211ef (m4_run)")
            rc, line = self.run_it()
        finally:
            holder.kill()
            holder.wait()
        self.assertEqual(rc, 0)
        self.assertIn("gauntlet skipped (testbed busy: deep 2673211ef (m4_run))", line)
        self.assertFalse((self.fake / "gauntlet_args").exists())
        self.assertEqual((self.lock / "pid").read_text(), str(holder.pid))

    def test_the_lock_is_taken_during_the_run_and_released_after(self):
        (self.repo / "scripts/run_gauntlet.sh").write_text(
            FAKE_GAUNTLET.replace('echo "$@"', 'cat "$HOME/m4run/lock/info" > "$FAKE/lock_seen"; echo "$@"'))
        self.run_it()
        self.assertIn("nightly testbed", (self.fake / "lock_seen").read_text())
        self.assertFalse(self.lock.exists())

    def test_a_stale_lock_is_reclaimed(self):
        self.lock.mkdir(parents=True)
        (self.lock / "pid").write_text("999999")
        rc, line = self.run_it()
        self.assertEqual(rc, 0)
        self.assertIn("gauntlet AMBER", line)
        self.assertFalse(self.lock.exists())

    def test_a_failed_notification_changes_nothing(self):
        self.plant(ssh_rc=255)
        rc, line = self.run_it()
        self.assertEqual(rc, 0)
        self.assertIn("gauntlet AMBER", line)
        log = (self.home / "Library/Logs/VideoScan/nightly_gauntlet.log").read_text()
        self.assertIn("notify: could not reach rickmac.test", log)

    def test_quotes_never_reach_the_applescript(self):
        self.plant(result=result_json("amber", known=7))
        (self.repo / "scripts/m4_run_summary.py").write_text(
            "print('deep: AMBER a \"quoted\" $reason `x` \\\\ it\\'s (sha=abc, 5s, results=r)')\nraise SystemExit(3)\n")
        self.run_it()
        ssh = (self.fake / "ssh_args").read_text()
        message = ssh.split("display notification", 1)[1].split("with title", 1)[0]
        self.assertEqual(message.count('"'), 2, message)  # only the AppleScript string's own quotes
        for ch in ("$", "`", "\\", "'"):
            self.assertNotIn(ch, message.strip()[1:-1])


class RotaGauntletTests(unittest.TestCase):

    def rota(self, body):
        d = tempfile.TemporaryDirectory()
        self.addCleanup(d.cleanup)
        p = pathlib.Path(d.name, "nightly_rota.json")
        p.write_text(body)
        return p

    def test_the_real_rota_runs_the_m4_testbed_at_14_and_the_ultra_nightly_at_02(self):
        self.assertEqual(nightly_rota.gauntlet("RicksM4"), "yes")
        self.assertEqual(nightly_rota.gauntlet("RicksUltra"), "no")
        self.assertEqual(nightly_rota.slot("RicksM4"), "on 14 0")
        self.assertEqual(nightly_rota.slot("RicksUltra"), "on 2 0")

    def test_off_unknown_and_broken_say_no(self):
        p = self.rota(json.dumps({"on": {"M4": "14:00"}, "gauntlet": ["M4", "M1"], "off": {"M1": "laptop"}}))
        self.assertEqual(nightly_rota.gauntlet("RicksM4", p), "yes")
        self.assertEqual(nightly_rota.gauntlet("RicksM1", p), "no")
        self.assertEqual(nightly_rota.gauntlet("Elsewhere", p), "no")
        self.assertEqual(nightly_rota.gauntlet("RicksM4", self.rota("{broken")), "no")
        self.assertEqual(nightly_rota.gauntlet("RicksM4", self.rota('{"gauntlet": "M4"}')), "no")

    def test_cli(self):
        out = subprocess.run([sys.executable, str(REPO / "scripts/nightly_rota.py"), "gauntlet", "RicksM4"],
                             capture_output=True, text=True, check=True).stdout.strip()
        self.assertEqual(out, "yes")


class GuardPicksTheTestbedTests(unittest.TestCase):
    """nightly_guarded.sh execs the full testbed only for a Mac on the gauntlet list."""

    def test_guard_branches_on_the_rota(self):
        text = (REPO / "scripts/nightly_guarded.sh").read_text()
        branch = text.index('nightly_rota.py" gauntlet "$HOST"')
        testbed = text.index('exec caffeinate -i bash "$REPO_ROOT/scripts/nightly_gauntlet.sh"')
        plain = text.index('exec caffeinate -i bash "$REPO_ROOT/scripts/nightly_local_tests.sh"')
        self.assertLess(branch, testbed)
        self.assertLess(testbed, plain)


if __name__ == "__main__":
    unittest.main()
