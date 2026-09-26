import importlib.util
from pathlib import Path
import re
import subprocess
import unittest

REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "ci_test_verdict", REPO / "scripts/ci_test_verdict.py")
verdict = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verdict)

# A complete run as the real log prints it: the canary records its issue,
# then fails, and the one run summary carries exactly that issue.
CLEAN = """✔ Test mustPass() passed after 0.001 seconds.
✘ Test mustFail() recorded an issue at CICanaryTests.swift:23:9: Expectation failed: 1 == 2
✘ Test mustFail() failed after 0.001 seconds with 1 issue.
✘ Test run with 300 tests in 30 suites failed after 4.0 seconds with 1 issue.
"""

# Verbatim shape of CI run 36223041786 (442fdc73): launch 1 ran the canary,
# then a test hit its time limit while the host was frozen (42.98 GB), the
# host was restarted, and launch 2's summary covers only the rest.
RUN_36223041786 = """TEST_HOST_STARTED epoch=1790404209.797 pid=44657
◇ Test run started.
✔ Test mustPass() passed after 0.001 seconds.
✘ Test mustFail() recorded an issue at CICanaryTests.swift:23:9: Expectation failed: 1 == 2
✘ Test mustFail() failed after 0.001 seconds with 1 issue.
✘ Suite CICanaryTests failed after 0.001 seconds with 1 issue.
✘ Test followUpsRunWithoutTranslationAndReturnMediaActions() recorded a known issue at HallieAppTurnCoordinatorFollowUpTests.swift:139:13: Expectation failed
✘ Test followUpsRunWithoutTranslationAndReturnMediaActions() passed after 0.149 seconds with 1 known issue.
◇ Test isolation_garbageCSVAndGarbageLabelsDegradeIndependently() started.
✘ Test isolation_garbageCSVAndGarbageLabelsDegradeIndependently() recorded an issue at UnifiedReviewSessionTests.swift:299:6: Time limit was exceeded: 60.000 seconds

*** If you believe this error represents a bug, please attach the result bundle at /Users/runner/work/VideoScan/VideoScan/TestResults.xcresult

TEST_HOST_STARTED epoch=1790406693.768 pid=58365

Restarting after unexpected exit, crash, or test timeout; summary will include totals from previous launches.

◇ Test run started.
✔ Test exactStemMatch_uniqueParent() passed after 0.001 seconds.
✔ Test run with 544 tests in 85 suites passed after 140.996 seconds.
** TEST EXECUTE FAILED **
"""


class CIVerdictTests(unittest.TestCase):
    def test_only_canary_is_accepted(self):
        self.assertEqual(verdict.problems(CLEAN, 65), [])

    def test_real_failures_cannot_disappear_in_count_pipeline(self):
        for count in (1, 5, 20):
            with self.subTest(count=count):
                extra = "✘ Test realBug() failed after 1 seconds with 1 issue.\n" * count
                self.assertTrue(verdict.problems(extra + CLEAN, 65))

    def test_xctest_failures_are_not_exempt(self):
        self.assertTrue(verdict.problems("Test Case '-[Tests bug]' failed (0.1 seconds).\n" + CLEAN, 65))

    def test_missing_completion_is_incomplete(self):
        self.assertTrue(verdict.problems("\n".join(CLEAN.splitlines()[:-1]), 65))

    def test_unexpected_exit_codes_fail_even_after_summary(self):
        for code in (0, 1, 124, 137, 143):
            self.assertTrue(verdict.problems(CLEAN, code))

    def test_missing_canaries_fail(self):
        for line in (CLEAN.splitlines()[0], CLEAN.splitlines()[2]):
            self.assertTrue(verdict.problems(CLEAN.replace(line, ""), 65))

    def test_summary_extra_issue_is_not_hidden(self):
        self.assertTrue(verdict.problems(CLEAN.replace("with 1 issue.", "with 2 issues."), 65))

    def test_zero_width_prefix_does_not_hide_failure(self):
        self.assertTrue(verdict.problems("​✘ Test bug() failed after 1 seconds with 1 issue.\n" + CLEAN, 65))

    def test_empty_log_fails(self):
        self.assertTrue(verdict.problems("", 65))

    def test_infrastructure_failure_after_completed_swift_run(self):
        for message in ("Testing failed: Test runner crashed.", "Lost connection to test host", "Test runner hung"):
            self.assertTrue(verdict.problems(CLEAN + message, 65))

    def test_test_names_are_not_crash_evidence(self):
        self.assertEqual(verdict.problems(CLEAN + "✔ Test testRunnerCrashIsHandled() passed after 0.1 seconds.\n", 65), [])

    # ── fix/ci-red-5 (run 36223041786) ──────────────────────────────────

    def test_the_canarys_own_issue_record_is_expected(self):
        # The canary prints "recorded an issue" before "failed after";
        # that line must not count as a second failure.
        self.assertIn("✘ Test mustFail() recorded an issue", CLEAN)
        self.assertEqual(verdict.problems(CLEAN, 65), [])

    def test_known_issues_are_not_failures(self):
        known = ("✘ Test k() recorded a known issue at K.swift:1:1: Expectation failed\n"
                 "✘ Test k() passed after 0.1 seconds with 1 known issue.\n")
        self.assertEqual(verdict.problems(known + CLEAN, 65), [])

    def test_an_issue_without_a_failed_after_line_is_a_real_failure(self):
        # A time limit on a frozen host records the issue; the "failed
        # after" line never comes. The old counters missed exactly this.
        timeout = ("✘ Test isolation() recorded an issue at U.swift:299:6: "
                   "Time limit was exceeded: 60.000 seconds\n")
        errors = verdict.problems(timeout + CLEAN, 65)
        self.assertTrue(any("issue record" in e and "Time limit" in e for e in errors), errors)

    def test_a_host_restart_is_named_as_such(self):
        errors = verdict.problems(CLEAN + verdict.RESTART + "; summary will include totals from previous launches.\n", 65)
        self.assertTrue(any(e.startswith("Test host restarted 1 time(s)") for e in errors), errors)

    def test_run_36223041786_is_rejected_for_the_true_reasons(self):
        errors = verdict.problems(RUN_36223041786, 65)
        joined = "\n".join(errors)
        self.assertIn("Test host restarted 1 time(s)", joined)
        self.assertIn("isolation_garbageCSVAndGarbageLabelsDegradeIndependently() recorded an issue", joined)
        self.assertIn("summaries seen: ✔ Test run with 544 tests in 85 suites passed", joined)
        # The canary did run and fail exactly once — that is NOT the problem.
        self.assertNotIn("Expected exactly one failing canary", joined)
        self.assertNotIn("Passing canary missing", joined)
        # xcodebuild really exits 65 here; only the masked 0 was wrong.
        self.assertFalse(any(e.startswith("Unexpected xcodebuild exit") for e in errors), errors)

    def test_two_summaries_are_rejected_even_if_one_looks_right(self):
        second = "✔ Test run with 10 tests in 2 suites passed after 1.0 seconds.\n"
        errors = verdict.problems(CLEAN + second, 65)
        self.assertTrue(any("2 Swift Testing run summaries" in e for e in errors), errors)


class CIWorkflowExitCodeTests(unittest.TestCase):
    """The unit-test step must hand the verdict XCODEBUILD's exit status."""

    WORKFLOW = (REPO / ".github/workflows/ci.yml").read_text(encoding="utf-8")

    def test_pipeline_status_comes_from_pipestatus_not_tee(self):
        self.assertNotRegex(self.WORKFLOW, r"\|\s*tee test-output\.log\s*\|\|\s*TEST_EXIT=\$\?",
                            "`… | tee … || TEST_EXIT=$?` records tee's status (always 0) under bash -e")
        self.assertRegex(self.WORKFLOW, r"\| tee test-output\.log\n\s*TEST_EXIT=\$\{PIPESTATUS\[0\]\}")
        self.assertIn('ci_test_verdict.py test-output.log --exit-code "$TEST_EXIT"', self.WORKFLOW)

    def _run(self, script):
        # The step's real shell: "shell: /bin/bash -e {0}" (run 36223041786).
        return subprocess.run(["/bin/bash", "-e", "-c", script],
                              capture_output=True, text=True, check=False).stdout.strip()

    def test_old_capture_pattern_really_records_zero(self):
        # Documents the bug: a failing producer piped to tee reads as 0.
        self.assertEqual(self._run('(exit 65) | tee /dev/null || X=$?; echo "${X:-0}"'), "0")

    def test_new_capture_pattern_records_the_producers_status(self):
        for code in (0, 65, 1):
            with self.subTest(code=code):
                out = self._run(f'set +e\n(exit {code}) | tee /dev/null\nX=${{PIPESTATUS[0]}}\nset -e\necho "$X"')
                self.assertEqual(out, str(code))

    def test_new_capture_pattern_survives_pipefail(self):
        out = self._run('set -o pipefail\nset +e\n(exit 65) | tee /dev/null\nX=${PIPESTATUS[0]}\nset -e\necho "$X"')
        self.assertEqual(out, "65")


if __name__ == "__main__":
    unittest.main()
