#!/usr/bin/env python3
"""Regression sensors for failed nightly scans masquerading as zero findings."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from nightly_lint_report import finding_count


class NightlyLintReportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.log = self.directory / "scan.txt"

    def test_successful_empty_scan_is_zero(self):
        self.log.write_text("Scan complete\n")
        self.assertEqual(finding_count(self.log, "success"), 0)

    def test_today_unknown_option_is_unknown_not_zero(self):
        self.log.write_text("Error: Unknown option '--targets'\nUsage: periphery scan\n")
        self.assertIsNone(finding_count(self.log, "failure"))

    def test_failed_scan_cannot_publish_partial_findings(self):
        self.log.write_text("/repo/Code.swift:7:2: warning: unused\nerror: index failed\n")
        for outcome in ("failure", "skipped", "cancelled", ""):
            with self.subTest(outcome=outcome):
                self.assertIsNone(finding_count(self.log, outcome))

    def test_missing_report_is_unknown_even_after_success(self):
        self.assertIsNone(finding_count(self.log, "success"))

    def test_counts_only_xcode_diagnostics_in_absolute_or_relative_paths(self):
        self.log.write_text("/a/path with spaces/File.swift:1:2: warning: unused\n"
                            "Source/Other.swift:15:1: error: too complex\n"
                            "/Applications/Xcode\nDone linting! Found 2 violations\n")
        self.assertEqual(finding_count(self.log, "success"), 2)

    def test_completed_strict_findings_keep_their_count_despite_exit_two(self):
        self.log.write_text("File.swift:2:18: error: Trailing Semicolon Violation\n"
                            "Done linting! Found 1 violation, 1 serious in 1 file.\n\n")
        self.assertEqual(finding_count(self.log, "failure", swiftlint=True, exit_code="2"), 1)

    def test_completed_clean_strict_scan_is_zero(self):
        self.log.write_text("Done linting! Found 0 violations, 0 serious in 12 files.\n")
        self.assertEqual(finding_count(self.log, "success", swiftlint=True, exit_code="0"), 0)

    def test_strict_footer_does_not_hide_cache_save_failure(self):
        # SwiftLint 0.65.1 reproducer: cache write fails AFTER its completion footer.
        self.log.write_text("Done linting! Found 0 violations, 0 serious in 1 file.\n"
                            "Error: You don’t have permission to save the file\n")
        self.assertIsNone(finding_count(self.log, "failure", swiftlint=True, exit_code="1"))

    def test_strict_rejects_partial_mismatched_and_appended_scans(self):
        diagnostic = "File.swift:2:18: error: violation\n"
        footer = "Done linting! Found 1 violation, 1 serious in 1 file.\n"
        for content in (diagnostic, footer, diagnostic + footer + "Error: failed\n",
                        diagnostic + footer + diagnostic + footer,
                        diagnostic + "Done linting! Found 2 violations, 2 serious in 1 file.\n",
                        diagnostic + "Done linting! Found 1 violation, 0 serious in 1 file.\n"):
            with self.subTest(content=content):
                self.log.write_text(content)
                self.assertIsNone(finding_count(self.log, "failure", swiftlint=True, exit_code="2"))

    def test_poisoned_complete_strict_log_requires_current_exit_and_outcome(self):
        self.log.write_text("Old.swift:2:18: error: old\n"
                            "Done linting! Found 1 violation, 1 serious in 1 file.\n")
        for outcome, status in (("skipped", "2"), ("cancelled", "2"), ("", "2"),
                                ("failure", ""), ("failure", "1"), ("failure", "137"),
                                ("success", "2"), ("failure", "0")):
            with self.subTest(outcome=outcome, status=status):
                self.assertIsNone(finding_count(self.log, outcome, swiftlint=True, exit_code=status))

    def test_cli_preserves_completed_strict_findings(self):
        (self.directory / "swiftlint-strict.txt").write_text(
            "File.swift:2:18: error: violation\n"
            "Done linting! Found 1 violation, 1 serious in 1 file.\n")
        (self.directory / "periphery-strict.txt").write_text("")
        output = self.directory / "output"
        result = subprocess.run([sys.executable, str(ROOT / "scripts/nightly_lint_report.py")],
                                cwd=self.directory, env={**os.environ,
                                    "GITHUB_OUTPUT": str(output),
                                    "GITHUB_STEP_SUMMARY": str(self.directory / "summary"),
                                    "SWIFTLINT_OUTCOME": "failure", "SWIFTLINT_EXIT_CODE": "2",
                                    "PERIPHERY_OUTCOME": "success"}, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output.read_text(), "swiftlint=1\nperiphery=0\n")

    def test_cli_emits_null_and_failure_with_poisoned_previous_log(self):
        (self.directory / "swiftlint-strict.txt").write_text("Old.swift:1:2: warning: old\n")
        (self.directory / "periphery-strict.txt").write_text("Error: Unknown option '--targets'\n")
        output = self.directory / "output"
        summary = self.directory / "summary"
        result = subprocess.run([sys.executable, str(ROOT / "scripts/nightly_lint_report.py")],
                                cwd=self.directory, env={**os.environ,
                                    "GITHUB_OUTPUT": str(output), "GITHUB_STEP_SUMMARY": str(summary),
                                    "SWIFTLINT_OUTCOME": "skipped", "PERIPHERY_OUTCOME": "failure"},
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(output.read_text(), "swiftlint=null\nperiphery=null\n")
        self.assertIn("unavailable", summary.read_text())

    def test_workflow_uses_supported_scan_and_does_not_swallow_errors(self):
        workflow = (ROOT / ".github/workflows/nightly-analysis.yml").read_text()
        self.assertNotIn("--targets VideoScan", workflow)
        self.assertIn("--index-store-path periphery-dd/Index.noindex/DataStore", workflow)
        self.assertNotIn("> periphery-strict.txt 2>&1 || true", workflow)
        self.assertIn("PERIPHERY_OUTCOME: ${{ steps.periphery.outcome }}", workflow)
        self.assertIn("SWIFTLINT_EXIT_CODE: ${{ steps.swiftlint.outputs.exit_code }}", workflow)

    def test_workflow_captures_original_exit_and_truncates_stale_log(self):
        workflow = (ROOT / ".github/workflows/nightly-analysis.yml").read_text()
        step = workflow.split("      - name: SwiftLint --strict\n", 1)[1].split("      - name:", 1)[0]
        script = "\n".join(line[10:] for line in step.split("        run: |\n", 1)[1].splitlines())
        fake_bin = self.directory / "bin"
        fake_bin.mkdir()
        executable = fake_bin / "swiftlint"
        executable.write_text('#!/bin/sh\necho "new scan"\nexit "$TEST_EXIT"\n')
        executable.chmod(0o755)
        for status in (0, 1, 2, 137):
            with self.subTest(status=status):
                log = self.directory / "swiftlint-strict.txt"
                log.write_text("poisoned old completion footer\n")
                output = self.directory / f"output-{status}"
                result = subprocess.run(["bash", "-e", "-c", script], cwd=self.directory,
                                        env={**os.environ, "PATH": f'{fake_bin}:{os.environ["PATH"]}',
                                             "TEST_EXIT": str(status), "GITHUB_OUTPUT": str(output)},
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, status, result.stderr)
                self.assertEqual(output.read_text(), f"exit_code={status}\n")
                self.assertEqual(log.read_text(), "new scan\n")


if __name__ == "__main__":
    unittest.main()
