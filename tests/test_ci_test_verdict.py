import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    "ci_test_verdict", Path(__file__).resolve().parents[1] / "scripts/ci_test_verdict.py")
verdict = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verdict)
CLEAN = """✔ Test mustPass() passed after 0.001 seconds.
✘ Test mustFail() failed after 0.001 seconds with 1 issue.
✘ Test run with 300 tests in 30 suites failed after 4.0 seconds with 1 issue.
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
        for line in CLEAN.splitlines()[:2]:
            self.assertTrue(verdict.problems(CLEAN.replace(line, ""), 65))

    def test_summary_extra_issue_is_not_hidden(self):
        self.assertTrue(verdict.problems(CLEAN.replace("with 1 issue.", "with 2 issues."), 65))

    def test_zero_width_prefix_does_not_hide_failure(self):
        self.assertTrue(verdict.problems("\u200b✘ Test bug() failed after 1 seconds with 1 issue.\n" + CLEAN, 65))

    def test_empty_log_fails(self):
        self.assertTrue(verdict.problems("", 65))

    def test_infrastructure_failure_after_completed_swift_run(self):
        for message in ("Testing failed: Test runner crashed.", "Lost connection to test host", "Test runner hung"):
            self.assertTrue(verdict.problems(CLEAN + message, 65))

    def test_test_names_are_not_crash_evidence(self):
        self.assertEqual(verdict.problems(CLEAN + "✔ Test testRunnerCrashIsHandled() passed after 0.1 seconds.\n", 65), [])
