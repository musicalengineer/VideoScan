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
  two contenders can never both own it (Codex 2026-11-05 P1: an acquisition
  race, reproduced with a deterministic pause between staging and publishing);
- a failed notification never changes the outcome;
- nightly_rota.py `gauntlet` says yes only for listed, on-rota Macs;
- --gauntlet-only (the guard's same-day retry) runs the gauntlet without the
  suite and still writes the done line;
- the guard (nightly_guarded.sh): on a gauntlet Mac a green suite row alone is
  NOT "done today" — a published passed/amber gauntlet row is needed too, else
  the retry runs the gauntlet only (Codex 2026-11-05 P1).

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
import time
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

# A gauntlet that announces itself and then holds the testbed until released:
# the live owner in the lock-race test.
FAKE_GAUNTLET_HOLD = r'''#!/bin/sh
echo "$$" >> "$FAKE/gauntlet_starts"
while [ -e "$FAKE/hold" ]; do sleep 0.05; done
status=$(cat "$FAKE/g_status")
printf 'GAUNTLET %s sha=abc12345 total=9s results=%s publish=published\n' "$status" "$FAKE/result.json"
exit "$(cat "$FAKE/g_rc")"
'''


def wait_for(predicate, timeout=20.0, what='condition'):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.05)
    raise AssertionError(f'timed out waiting for {what}')


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
        for name in ("nightly_gauntlet.sh", "nightly_rota.py", "nightly_rota.json", "m4_run_summary.py",
                     "testbed_lock.py"):
            shutil.copy(REPO / "scripts" / name, self.repo / "scripts" / name)
        self.holders = []
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
        for fd in self.holders:
            try:
                os.close(fd)
            except OSError:
                pass
        self.tmp.cleanup()

    # The lock's kernel truth, through the same helper the scripts use.
    def hold(self, info):
        """A live owner of the testbed lock: this process opens the flock file and the
        helper flocks that fd (scripts/testbed_lock.py hold <fd>); the lock lives on the
        returned fd until it is closed — exactly the shell's `exec 9>>` protocol."""
        self.lock.mkdir(parents=True, exist_ok=True)
        fd = os.open(str(self.lock / "flock"), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
        self.holders.append(fd)
        out = subprocess.run([sys.executable, str(REPO / "scripts/testbed_lock.py"), "hold", str(fd), str(self.lock), info],
                             capture_output=True, text=True, pass_fds=(fd,), timeout=20).stdout.strip()
        self.assertEqual(out, "HELD")
        return fd

    def probe(self):
        return subprocess.run([sys.executable, str(REPO / "scripts/testbed_lock.py"), "probe", str(self.lock)],
                              capture_output=True, text=True, timeout=20).stdout.strip()

    def plant(self, suite_rc=0, passed=12, failed=0, total=12, g_status="AMBER", g_rc=0,
              result=None, ssh_rc=0):
        for name, value in (("suite_rc", suite_rc), ("suite_passed", passed), ("suite_failed", failed),
                            ("suite_total", total), ("g_status", g_status), ("g_rc", g_rc),
                            ("ssh_rc", ssh_rc)):
            (self.fake / name).write_text(str(value))
        result = result or result_json("amber", known=7)
        (self.fake / "result.json").write_text(json.dumps(result))

    def run_it(self, *args):
        r = subprocess.run(["bash", str(self.repo / "scripts/nightly_gauntlet.sh"), *args], env=self.env,
                           capture_output=True, text=True, timeout=60)
        latest = self.home / "Library/Logs/VideoScan/testbed_latest.txt"
        line = latest.read_text().strip() if latest.exists() else ""
        return r.returncode, line

    def test_gauntlet_only_mode_runs_no_suite_and_still_writes_the_done_line(self):
        rc, line = self.run_it("--gauntlet-only")
        self.assertEqual(rc, 0)
        self.assertFalse(list((self.home / "Library/Logs/VideoScan").glob("nightly_test_*.log")),
                         "the suite must not run in --gauntlet-only mode")
        self.assertIn("nightly suite GREEN (earlier today, not re-run)", line)
        self.assertIn("gauntlet AMBER", line)
        self.assertIn("7 known issues", line)
        self.assertIn("M4 full testbed done", (self.fake / "ssh_args").read_text())
        self.assertEqual(self.probe(), "FREE")
        self.plant(g_status="FAILED", g_rc=1, result=result_json("failed", regression="failed"))
        rc, line = self.run_it("--gauntlet-only")
        self.assertEqual(rc, 1)
        self.assertIn("gauntlet RED", line)

    def race(self, pause_env, stale=False):
        """Owner A is paused at `pause_env`; contender B runs to a live hold (its
        gauntlet blocks); A resumes. Returns (a, b, gauntlet start count, history lines)."""
        gauntlet = self.repo / "scripts/run_gauntlet.sh"
        gauntlet.write_text(FAKE_GAUNTLET_HOLD)
        gauntlet.chmod(0o755)
        pause, hold, starts = self.fake / "pause", self.fake / "hold", self.fake / "gauntlet_starts"
        pause.touch(); hold.touch()
        if stale:
            # Leftovers of a dead holder and of the retired mkdir/rename protocol: never the truth.
            self.lock.mkdir(parents=True, exist_ok=True)
            (self.lock / "pid").write_text("999999")
            (self.lock / "info").write_text("999999 deep (dead long ago)")
        a = subprocess.Popen(["bash", str(self.repo / "scripts/nightly_gauntlet.sh")],
                             env=dict(self.env, **{pause_env: str(pause)}),
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        b = None
        try:
            wait_for(lambda: (self.fake / "pause.paused").exists(), what="A at the race point")
            b = subprocess.Popen(["bash", str(self.repo / "scripts/nightly_gauntlet.sh")], env=self.env,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            # B either becomes the live owner (its gauntlet starts) or is refused and finishes.
            started = lambda: len(starts.read_text().split()) if starts.exists() else 0  # noqa: E731
            wait_for(lambda: started() >= 1 or b.poll() is not None, what="B to decide")
            before = started()
            pause.unlink()                                       # A resumes
            # A either leaves (refused) or starts its gauntlet (one more start).
            wait_for(lambda: a.poll() is not None or started() > before, what="A to decide")
        finally:
            hold.unlink(missing_ok=True)
            for p in (a, b):
                if p is not None:
                    try:
                        p.wait(timeout=30)
                    except subprocess.TimeoutExpired:
                        p.kill(); p.wait()
        count = len(starts.read_text().split()) if starts.exists() else 0
        history = (self.home / "Library/Logs/VideoScan/testbed_history.log").read_text().splitlines()
        return a, b, count, history

    def assert_one_owner(self, a, b, count, history):
        self.assertEqual(count, 1, "two live owners started two gauntlets")
        self.assertEqual(len(history), 2)
        self.assertEqual(sum("gauntlet skipped (testbed busy: nightly testbed" in h for h in history), 1, history)
        self.assertEqual(sum("gauntlet AMBER" in h for h in history), 1, history)
        self.assertEqual((a.returncode, b.returncode), (0, 0))
        self.assertEqual(self.probe(), "FREE", "the lock must be released by its owner")
        self.assertFalse(list(self.lock.parent.glob("lock.answer.*")), "no answer FIFOs left behind")

    def test_two_contenders_never_both_own_the_testbed(self):
        # Codex 2026-11-05 (P1): owner A paused between deciding and claiming;
        # contender B becomes a live owner (its gauntlet holds); A resumes and
        # must be refused. Exactly one gauntlet may start.
        self.assert_one_owner(*self.race("VIDEOSCAN_TESTBED_LOCK_PAUSE"))

    def test_a_contender_paused_before_claiming_never_reclaims_a_live_owner_over_a_stale_lock(self):
        # Codex 2026-11-05 re-review (P1): A inspects a stale lock (dead pid),
        # pauses; B reclaims and holds; A resumes and renamed B's live lock
        # aside. With a kernel lock there is nothing to reclaim: A is refused.
        self.assert_one_owner(*self.race("VIDEOSCAN_TESTBED_LOCK_PAUSE", stale=True))

    def test_an_owner_paused_after_claiming_refuses_the_contender(self):
        # The other interleaving: A holds but has not yet answered its shell;
        # B must already see busy, and A then runs its gauntlet alone.
        a, b, count, history = self.race("VIDEOSCAN_TESTBED_LOCK_PAUSE_HELD")
        self.assertEqual(count, 1, history)
        self.assertEqual((a.returncode, b.returncode), (0, 0))
        self.assertEqual(sum("gauntlet skipped (testbed busy: nightly testbed" in h for h in history), 1, history)
        self.assertEqual(sum("gauntlet AMBER" in h for h in history), 1, history)
        self.assertEqual(self.probe(), "FREE")

    def test_a_killed_shells_live_work_keeps_the_lock_and_frees_it_when_done(self):
        # Codex 2026-11-05 re-review 2 (P1): the shell dies (SIGKILL: no trap
        # runs) while its gauntlet — in its own session — is still running. The
        # lock lives on the open file description the work inherited, so B is
        # busy until that work ends; then the kernel frees it with no cleanup
        # and C acquires without reclaiming anything.
        gauntlet = self.repo / "scripts/run_gauntlet.sh"
        gauntlet.write_text(FAKE_GAUNTLET_HOLD)
        gauntlet.chmod(0o755)
        hold, starts = self.fake / "hold", self.fake / "gauntlet_starts"
        hold.touch()
        a = subprocess.Popen(["bash", str(self.repo / "scripts/nightly_gauntlet.sh")], env=self.env,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            wait_for(lambda: starts.exists(), what="A's gauntlet to start")
            self.assertTrue(self.probe().startswith("BUSY nightly testbed"), self.probe())
            a.kill(); a.wait()
            time.sleep(0.5)                                       # the old lease would have let go by now
            self.assertTrue(self.probe().startswith("BUSY nightly testbed"),
                            f"the lock must outlive the shell while its work runs: {self.probe()}")
            rc, line = self.run_it()                              # B, while A's gauntlet is still alive
            self.assertEqual(rc, 0)
            self.assertIn("gauntlet skipped (testbed busy: nightly testbed", line)
            self.assertEqual(len(starts.read_text().split()), 1, "B must not start a second gauntlet")
        finally:
            hold.unlink(missing_ok=True)
        wait_for(lambda: self.probe() == "FREE", what="the kernel to drop the lock when the work ends")
        gauntlet.write_text(FAKE_GAUNTLET)
        rc, line = self.run_it()                                  # C
        self.assertEqual(rc, 0)
        self.assertIn("gauntlet AMBER", line)
        self.assertNotIn("reclaim", (self.home / "Library/Logs/VideoScan/nightly_gauntlet.log").read_text())

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

    def test_a_published_run_whose_dir_is_gone_reads_its_history_row_after_the_tidy_lines(self):
        # The real runner (Rick 2026-11-08) prints its verdict line, then
        # SUMMARY and TIDY lines that also start "GAUNTLET ", and deletes the
        # published run dir: only <results-root>/history.jsonl holds the row.
        run = self.fake / "gauntlet" / "2026-11-08T14-00-00Z-R0000001"
        (self.fake / "gauntlet").mkdir()
        row = dict(result_json("amber", known=7), run_id=run.name)
        (self.fake / "gauntlet" / "history.jsonl").write_text(json.dumps(row) + "\n")
        (self.repo / "scripts/run_gauntlet.sh").write_text(
            "#!/bin/sh\n"
            f"printf 'GAUNTLET RETENTION removed %s (run older than 3 days)\\n' '{self.fake}/gauntlet/old'\n"
            f"printf 'GAUNTLET SUMMARY passed=9 failed=0 skipped=0 unknown=0 new_failures= fixed=0 history=x\\n'\n"
            f"printf 'GAUNTLET AMBER sha=abc12345 total=9s results=%s publish=published\\n' '{run}/result.json'\n"
            f"printf 'GAUNTLET TIDY removed run %s (5.10 GB); summary in history.jsonl\\n' '{run}'\n")
        rc, line = self.run_it()
        self.assertEqual(rc, 0, line)
        self.assertIn("gauntlet AMBER", line)
        self.assertIn("7 known issues", line)

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
        self.hold("deep 2673211ef (m4_run)")
        rc, line = self.run_it()
        self.assertEqual(rc, 0)
        self.assertIn("gauntlet skipped (testbed busy: deep 2673211ef (m4_run))", line)
        self.assertFalse((self.fake / "gauntlet_args").exists())
        self.assertEqual(self.probe(), "BUSY deep 2673211ef (m4_run)", "the holder is untouched")

    def test_the_lock_is_taken_during_the_run_and_released_after(self):
        (self.repo / "scripts/run_gauntlet.sh").write_text(
            FAKE_GAUNTLET.replace('echo "$@"', 'cat "$HOME/m4run/lock/info" > "$FAKE/lock_seen"; echo "$@"'))
        self.run_it()
        self.assertIn("nightly testbed", (self.fake / "lock_seen").read_text())
        self.assertEqual(self.probe(), "FREE")

    def test_a_dead_holders_lock_needs_no_reclaim(self):
        # A holder that died (SIGKILL) left its info behind; the kernel freed the
        # lock with it. Leftovers of the retired protocol (a pid file, an empty
        # directory) are ignored the same way.
        dead = self.hold("deep (about to die)")
        os.close(dead)                                            # the holder is gone: its fd closed with it
        (self.lock / "pid").write_text("999999")
        rc, line = self.run_it()
        self.assertEqual(rc, 0)
        self.assertIn("gauntlet AMBER", line)
        self.assertEqual(self.probe(), "FREE")
        self.assertNotIn("reclaim", (self.home / "Library/Logs/VideoScan/nightly_gauntlet.log").read_text())

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

    # Regression 2026-11-06 ("the metrics page says stale"): the page's "Last night's tests"
    # reads summary_latest.json, which tools/publish_metrics.py rebuilt only at 04:00 and
    # 05:30 (the coverage and adversarial-confirm jobs) — right after the old 02:00 nightly.
    # Since the M4 moved to 14:00 (11/05) its result sat on testdriver.jsonl for ~14 h while
    # the page showed the night without it, and the done line pointed Rick at that page.
    def plant_publisher(self, rc=0):
        tools = self.repo / "tools"
        tools.mkdir(exist_ok=True)
        (tools / "publish_metrics.py").write_text(
            "import os, pathlib, sys\n"
            "fake = pathlib.Path(os.environ['FAKE'])\n"
            "seen = [n for n in ('gauntlet_args',) if (fake / n).exists()]\n"
            "logs = list((pathlib.Path(os.environ['HOME']) / 'Library/Logs/VideoScan').glob('testbed_latest.txt'))\n"
            "(fake / 'publish_calls').open('a').write(' '.join(sys.argv[1:] + seen + (['done-line-already'] if logs else [])) + '\\n')\n"
            f"print('OUTCOME ok: pushed metrics/summary_latest.json')\nraise SystemExit({rc})\n")

    def test_the_page_summary_is_rebuilt_after_the_testbed_and_before_the_done_line(self):
        self.plant_publisher()
        rc, line = self.run_it()
        self.assertEqual(rc, 0)
        calls = (self.fake / "publish_calls").read_text().splitlines()
        self.assertEqual(len(calls), 1, calls)
        self.assertIn("gauntlet_args", calls[0], "the publisher must run after the gauntlet published")
        self.assertNotIn("done-line-already", calls[0], "the page is rebuilt before Rick is told to look")
        self.assertIn("--no-events", calls[0])
        log = (self.home / "Library/Logs/VideoScan/nightly_gauntlet.log").read_text()
        self.assertIn("publish: OUTCOME ok: pushed metrics/summary_latest.json", log)
        self.plant_publisher()
        self.run_it("--gauntlet-only")
        self.assertEqual(len((self.fake / "publish_calls").read_text().splitlines()), 2)

    def test_a_failed_or_missing_publisher_changes_nothing(self):
        self.plant_publisher(rc=1)
        rc, line = self.run_it()
        self.assertEqual(rc, 0)
        self.assertIn("gauntlet AMBER", line)
        log = (self.home / "Library/Logs/VideoScan/nightly_gauntlet.log").read_text()
        self.assertIn("publish: exit 1", log)
        (self.repo / "tools" / "publish_metrics.py").unlink()
        rc, line = self.run_it()
        self.assertEqual(rc, 0)
        self.assertIn("gauntlet AMBER", line)


class WatchdogLockHandoffTests(unittest.TestCase):
    """Codex 2026-11-05 re-review 3 (P1): the nightly suite's real supervisor
    (scripts/lib/process_group_watchdog.sh) launched its worker with Popen and
    no pass_fds, so fd 9 — the testbed lock — was dropped before the actual
    work: with the supervisors gone and the worker alive, a second owner was
    admitted. The real handoff, with a real kernel lock: shell takes the lock
    on fd 9, the watchdog starts a worker, shell + watchdog are SIGKILLed, the
    worker lives on → BUSY until the worker exits → FREE."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.t = pathlib.Path(self.tmp.name)
        self.lock = self.t / "lock"

    def tearDown(self):
        (self.t / "hold").unlink(missing_ok=True)
        self.tmp.cleanup()

    def probe(self):
        return subprocess.run([sys.executable, str(REPO / "scripts/testbed_lock.py"), "probe", str(self.lock)],
                              capture_output=True, text=True, timeout=20).stdout.strip()

    def test_the_watchdogs_worker_keeps_the_lock_after_its_supervisors_die(self):
        hold, pidfile, log = self.t / "hold", self.t / "worker.pid", self.t / "out.log"
        hold.touch()
        script = (
            'mkdir -p "$LOCK" && exec 9>>"$LOCK/flock" && '
            'answer="$(python3 "$HELPER" hold 9 "$LOCK" "nightly suite (watchdog)")" && [ "$answer" = HELD ] || exit 9; '
            'source "$LIB"; '
            'run_with_process_group_watchdog 120 1 "$LOG" sh -c \'echo $$ > "$PIDFILE"; while [ -e "$HOLD" ]; do sleep 0.05; done\''
        )
        env = dict(os.environ, LOCK=str(self.lock), HELPER=str(REPO / "scripts/testbed_lock.py"),
                   LIB=str(REPO / "scripts/lib/process_group_watchdog.sh"), LOG=str(log),
                   PIDFILE=str(pidfile), HOLD=str(hold))
        shell = subprocess.Popen(["/bin/bash", "-c", script], env=env, start_new_session=True,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            wait_for(lambda: pidfile.exists() and pidfile.read_text().strip(), what="the worker to start")
            worker = int(pidfile.read_text().strip())
            self.assertTrue(self.probe().startswith("BUSY nightly suite (watchdog)"), self.probe())
            # Kill the supervisors: the shell and its python watchdog, not the worker.
            supervisors = subprocess.run(["pgrep", "-P", str(shell.pid)], capture_output=True, text=True).stdout.split()
            for pid in supervisors:
                os.kill(int(pid), 9)
            shell.kill(); shell.wait()
            time.sleep(0.5)
            self.assertEqual(subprocess.run(["kill", "-0", str(worker)]).returncode, 0, "fixture: the worker must still be alive")
            self.assertTrue(self.probe().startswith("BUSY nightly suite (watchdog)"),
                            f"the lock must live on with the worker: {self.probe()}")
        finally:
            hold.unlink(missing_ok=True)
        wait_for(lambda: self.probe() == "FREE", what="the kernel to drop the lock when the worker exits")


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

    def test_machine_is_the_runners_label_and_empty_when_unknown(self):
        self.assertEqual(nightly_rota.machine("RicksM4"), "m4")
        self.assertEqual(nightly_rota.machine("RicksUltra"), "m5")
        self.assertEqual(nightly_rota.machine("RicksM1"), "m1")
        self.assertEqual(nightly_rota.machine("Elsewhere"), "")
        out = subprocess.run([sys.executable, str(REPO / "scripts/nightly_rota.py"), "machine", "RicksM4"],
                             capture_output=True, text=True, check=True).stdout.strip()
        self.assertEqual(out, "m4")


FAKE_GIT = r'''#!/bin/sh
# Stand-in for git: `fetch` is a no-op, `show origin/metrics:…` prints the planted rows.
case "$1" in
    fetch) exit 0 ;;
    show) cat "$FAKE/rows.jsonl"; exit 0 ;;
esac
exit 1
'''
FAKE_SCUTIL = r'''#!/bin/sh
cat "$FAKE/host"
'''
FAKE_CAFFEINATE = r'''#!/bin/sh
# Stand-in for caffeinate: records what the guard would have run, runs nothing.
printf '%s\n' "$@" > "$FAKE/caffeinate_args"
exit 0
'''


class GuardRetryTests(unittest.TestCase):
    """scripts/nightly_guarded.sh, run for real with a fake git / scutil / caffeinate.

    Codex 2026-11-05 (P1): on the M4 (a "gauntlet" Mac) the suite publishes GREEN,
    then the gauntlet fails, is skipped (testbed busy) or never publishes; a
    same-day retry saw the suite row and exited 0. "Done today" on a gauntlet Mac
    needs BOTH rows; suite green without the gauntlet row → gauntlet only.
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        t = pathlib.Path(self.tmp.name)
        self.home, self.repo, self.fake, self.bin = t / "home", t / "repo", t / "fake", t / "bin"
        for d in (self.home, self.repo / "scripts", self.fake, self.bin):
            d.mkdir(parents=True)
        for name in ("nightly_guarded.sh", "nightly_rota.py", "nightly_rota.json"):
            shutil.copy(REPO / "scripts" / name, self.repo / "scripts" / name)
        for name, body in (("git", FAKE_GIT), ("scutil", FAKE_SCUTIL), ("caffeinate", FAKE_CAFFEINATE)):
            (self.bin / name).write_text(body)
            (self.bin / name).chmod(0o755)
        self.env = dict(os.environ, HOME=str(self.home), FAKE=str(self.fake),
                        PATH=f"{self.bin}:{os.environ['PATH']}", TOOLCHAIN_UPDATE_LOCK=str(t / "no-lock"))
        self.today = time.strftime("%Y-%m-%d", time.gmtime())
        self.host("RicksM4")

    def tearDown(self):
        self.tmp.cleanup()

    def host(self, name):
        (self.fake / "host").write_text(name)

    def suite_row(self, host="RicksM4", status="ok", day=None, total=13000):
        return {"ts": f"{day or self.today}T18:10:00Z", "source": "nightly-local", "host": host,
                "status": status, "total": total, "passed": total, "failed": 0}

    def gauntlet_row(self, status="passed", machine="m4", day=None, schema=1):
        return {"ts": f"{day or self.today}T18:40:00Z", "source": "gauntlet", "schemaVersion": schema,
                "machine": machine, "status": status, "run_id": "x"}

    def run_guard(self, *rows):
        (self.fake / "rows.jsonl").write_text("".join(json.dumps(r) + "\n" for r in rows))
        r = subprocess.run(["bash", str(self.repo / "scripts/nightly_guarded.sh")], env=self.env,
                           capture_output=True, text=True, timeout=60)
        args = self.fake / "caffeinate_args"
        ran = args.read_text().split("\n") if args.exists() else None
        log = (self.home / "Library/Logs/VideoScan/nightly_guard.log").read_text()
        return r.returncode, ran, log

    def test_green_suite_and_red_gauntlet_retries_the_gauntlet_only(self):
        rc, ran, log = self.run_guard(self.suite_row(), self.gauntlet_row("failed"))
        self.assertEqual(rc, 0)
        self.assertIsNotNone(ran, log)
        self.assertTrue(ran[2].endswith("scripts/nightly_gauntlet.sh"), ran)
        self.assertEqual(ran[3], "--gauntlet-only", ran)
        self.assertIn("running the gauntlet only", log)

    def test_green_suite_and_no_gauntlet_row_retries_the_gauntlet_only(self):
        lookalikes = [self.gauntlet_row("passed", machine="m5"),                 # the Ultra's
                      self.gauntlet_row("passed", day="2026-01-01"),               # another day
                      self.gauntlet_row("passed", schema=2),                        # not the schema the page reads
                      self.gauntlet_row("incomplete")]                             # never finished
        for rows in ([self.suite_row()], [self.suite_row()] + lookalikes):
            with self.subTest(rows=len(rows)):
                (self.fake / "caffeinate_args").unlink(missing_ok=True)
                rc, ran, log = self.run_guard(*rows)
                self.assertEqual(rc, 0)
                self.assertIsNotNone(ran, log)
                self.assertEqual(ran[2:4], [str(self.repo / "scripts/nightly_gauntlet.sh"), "--gauntlet-only"])

    def test_the_latest_row_per_kind_decides_not_any_row(self):
        # Codex 2026-11-05 re-review (P1): an earlier passed gauntlet row kept
        # "gauntlet done" after a later failed one. Ordered history, per kind.
        passed_then_failed = [self.suite_row(), self.gauntlet_row("passed"),
                              dict(self.gauntlet_row("failed"), ts=f"{self.today}T19:30:00Z")]
        rc, ran, log = self.run_guard(*passed_then_failed)
        self.assertEqual(ran[2:4], [str(self.repo / "scripts/nightly_gauntlet.sh"), "--gauntlet-only"], log)
        (self.fake / "caffeinate_args").unlink()
        failed_then_passed = [self.suite_row(), self.gauntlet_row("failed"),
                              dict(self.gauntlet_row("passed"), ts=f"{self.today}T19:30:00Z")]
        rc, ran, log = self.run_guard(*failed_then_passed)
        self.assertIsNone(ran, log)
        # The same rule for the suite: a green row followed by a later red one is not "done".
        green_then_red = [self.suite_row(), dict(self.suite_row(status="failed"), ts=f"{self.today}T20:00:00Z"),
                          self.gauntlet_row("passed")]
        rc, ran, log = self.run_guard(*green_then_red)
        self.assertEqual(ran[2:], [str(self.repo / "scripts/nightly_gauntlet.sh"), ""], log)

    def test_green_suite_and_published_gauntlet_is_a_no_op(self):
        for status in ("passed", "amber"):
            with self.subTest(status=status):
                rc, ran, log = self.run_guard(self.suite_row(), self.gauntlet_row(status))
                self.assertEqual(rc, 0)
                self.assertIsNone(ran, "nothing may run")
                self.assertIn("skipping (no-op)", log)

    def test_red_or_missing_suite_runs_the_full_testbed(self):
        for rows in ([], [self.suite_row(status="failed"), self.gauntlet_row("passed")],
                     [self.suite_row(host="RicksUltra")]):                        # another host's green
            with self.subTest(rows=rows):
                (self.fake / "caffeinate_args").unlink(missing_ok=True)
                rc, ran, log = self.run_guard(*rows)
                self.assertEqual(rc, 0)
                self.assertEqual(ran[2:], [str(self.repo / "scripts/nightly_gauntlet.sh"), ""], ran)
                self.assertIn("running the full testbed", log)

    def test_a_plain_nightly_mac_needs_only_its_green_suite(self):
        self.host("RicksUltra")
        rc, ran, log = self.run_guard(self.suite_row(host="RicksUltra"))
        self.assertEqual(rc, 0)
        self.assertIsNone(ran, log)
        (self.fake / "caffeinate_args").unlink(missing_ok=True)
        rc, ran, log = self.run_guard(self.suite_row(host="RicksUltra", status="failed"))
        self.assertEqual(ran[2:], [str(self.repo / "scripts/nightly_local_tests.sh"), ""], ran)


if __name__ == "__main__":
    unittest.main()
