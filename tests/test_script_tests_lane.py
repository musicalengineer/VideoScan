"""scripts/script_tests_lane.py — the testbed's own tests, one line in the done line.

RED 2026-11-10: nothing ran scripts/run_python_tests.sh on a Mac. Logic (every
verdict), truth (a run that proves nothing is RED), isolation (a runner that
hangs is stopped at its budget) and the wiring in scripts/nightly_gauntlet.sh.
"""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import script_tests_lane as lane  # noqa: E402

SCRIPT = ROOT / "scripts" / "script_tests_lane.py"
GAUNTLET = ROOT / "scripts" / "nightly_gauntlet.sh"


def test_green_needs_exit_zero_and_at_least_one_passed_test():
    text = "collected tests: 1803 (floor 1700)\n....\n1803 passed, 4 skipped in 61.20s\n"
    assert lane.verdict(text, 0, False, 1500) == (True, "script tests GREEN (1803 passed)")


def test_failures_are_named_and_counted():
    text = ("FAILED tests/test_a.py::test_one - AssertionError: x\n"
            "FAILED tests/test_a.py::test_one - AssertionError: x\n"
            "FAILED tests/test_b.py::T::test_two\nERROR tests/test_c.py::test_three\nFAILED tests/test_d.py::test_four\n"
            "3 failed, 1790 passed, 1 error in 70.1s\n")
    green, line = lane.verdict(text, 1, False, 1500)
    assert not green
    assert line == "script tests RED (4 failed: test_a.py::test_one, test_b.py::T::test_two, test_c.py::test_three +1 more)"


def test_a_run_that_proves_nothing_is_red_never_green():
    # Exit 0 with no test counted, zero passed, and a preflight stop: all RED.
    assert lane.verdict("", 0, False, 1500) == (False, "script tests RED (exit 0, 0 passed)")
    assert lane.verdict("0 passed in 0.01s\n", 0, False, 1500)[0] is False
    stop = "python: x\n::error::node is not on PATH. The dashboard contract tests require it.\n"
    assert lane.verdict(stop, 1, False, 1500) == (
        False, "script tests RED (exit 1, 0 passed: node is not on PATH. The dashboard contract tests require it.)")
    # Passing counts with a non-zero exit (a later step failed) is RED too.
    assert lane.verdict("1803 passed in 60s\n", 1, False, 1500)[0] is False


def test_a_timeout_is_red_whatever_the_log_says():
    assert lane.verdict("1803 passed in 60s\n", 0, True, 1500) == (False, "script tests RED (timed out after 1500s)")


def test_cli_runs_a_real_runner_and_writes_its_log(tmp_path):
    runner = tmp_path / "runner.sh"
    runner.write_text("echo '12 passed in 0.5s'\n")
    log = tmp_path / "out.log"
    proc = subprocess.run([sys.executable, str(SCRIPT), str(runner), str(log), "30", str(tmp_path)],
                          capture_output=True, text=True, timeout=60)
    assert proc.returncode == 0 and proc.stdout.strip() == "script tests GREEN (12 passed)"
    assert "12 passed" in log.read_text()
    runner.write_text("echo 'FAILED tests/test_x.py::test_y'; echo '1 failed, 11 passed in 0.5s'; exit 1\n")
    proc = subprocess.run([sys.executable, str(SCRIPT), str(runner), str(log), "30", str(tmp_path)],
                          capture_output=True, text=True, timeout=60)
    assert proc.returncode == 1 and proc.stdout.strip() == "script tests RED (1 failed: test_x.py::test_y)"


def test_cli_a_hung_runner_is_stopped_at_its_budget_with_its_children(tmp_path):
    runner = tmp_path / "runner.sh"
    marker = tmp_path / "child-survived"
    runner.write_text(f"(sleep 4; touch '{marker}') &\nsleep 60\n")
    proc = subprocess.run([sys.executable, str(SCRIPT), str(runner), str(tmp_path / "out.log"), "1", str(tmp_path)],
                          capture_output=True, text=True, timeout=60)
    assert proc.returncode == 1 and proc.stdout.strip() == "script tests RED (timed out after 1s)"
    subprocess.run(["sleep", "5"], check=True)
    assert not marker.exists(), "the runner's child outlived the watchdog"


def test_cli_bad_arguments_and_a_missing_runner_are_red_in_one_line(tmp_path):
    proc = subprocess.run([sys.executable, str(SCRIPT), "only-one"], capture_output=True, text=True, timeout=30)
    assert proc.returncode == 1 and proc.stdout.startswith("script tests RED (usage")
    proc = subprocess.run([sys.executable, str(SCRIPT), str(tmp_path / "absent.sh"), str(tmp_path / "o.log"), "5", str(tmp_path)],
                          capture_output=True, text=True, timeout=30)
    assert proc.returncode == 1 and proc.stdout.count("\n") == 1 and "RED" in proc.stdout


def test_sensor_the_testbed_runs_the_lane_and_its_red_fails_the_run():
    text = GAUNTLET.read_text()
    assert 'python3 "$REPO_ROOT/scripts/script_tests_lane.py" "$SCRIPT_TESTS" "$S_OUT" "$SCRIPT_TESTS_BUDGET" "$REPO_ROOT"' in text
    # The line reaches the done line, and RED is the run's exit code when nothing else failed.
    assert "${S_TEXT:+ · $S_TEXT}" in text
    assert text.rstrip().endswith('[ "$G_RC" = 0 ] || exit "$G_RC"\nexit "$S_RC"')
    # It runs before the page summary is rebuilt and before the done line.
    assert text.index("script_tests_lane.py\" \"$SCRIPT_TESTS\"") < text.index("# ── 2b. rebuild the page's summary") < text.index("# ── 3. the done line")
