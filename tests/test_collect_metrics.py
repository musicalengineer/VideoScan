"""Offline regression sensors for metrics correctness and optional tool failures."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("collect_metrics", ROOT / "scripts/collect_metrics.py")
metrics = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(metrics)


def report(files, covered=10, total=20):
    return {"targets": [{"name": "VideoScan.app", "coveredLines": covered,
                         "executableLines": total, "files": files}]}


def file_counts(path, covered, total):
    return {"path": path, "coveredLines": covered, "executableLines": total}


class CoverageTests(unittest.TestCase):
    def test_missing_or_malformed_report_is_null_not_zero(self):
        for value in (None, {}, [], {"targets": []}, {"targets": [None]}, report([])):
            with self.subTest(value=value):
                result = metrics.coverage(value)
                self.assertIsNone(result["coverage_logic_pct"])
                self.assertIsNone(result["logic_lines"])

    def test_structured_coverage_handles_spaces_and_excludes_views(self):
        value = report([file_counts('/source with spaces/Engine.swift', 1, 4),
                        file_counts('/source with spaces/MainView.swift', 9, 16)])
        self.assertEqual(metrics.coverage(value), {"coverage_overall_pct": 50.0,
                         "coverage_logic_pct": 25.0, "logic_covered": 1, "logic_lines": 4})

    def test_actual_zero_coverage_remains_zero(self):
        result = metrics.coverage(report([file_counts("Engine.swift", 0, 10)], 0, 10))
        self.assertEqual(result["coverage_overall_pct"], 0)
        self.assertEqual(result["coverage_logic_pct"], 0)
        self.assertEqual(result["logic_lines"], 10)

    def test_partial_or_invalid_logic_counts_do_not_make_a_percentage(self):
        for broken in ({"path": "Broken.swift"}, file_counts("Broken.swift", 11, 10),
                       file_counts("Broken.swift", True, 10), None):
            result = metrics.coverage(report([file_counts("Good.swift", 10, 10), broken]))
            self.assertEqual(result["coverage_overall_pct"], 50)
            self.assertIsNone(result["coverage_logic_pct"])
            self.assertIsNone(result["logic_covered"])

    def test_no_executable_logic_has_no_percentage(self):
        self.assertIsNone(metrics.coverage(report([file_counts("Empty.swift", 0, 0)]))["coverage_logic_pct"])
        self.assertIsNone(metrics.coverage(report([file_counts("MainView.swift", 1, 2)]))["coverage_logic_pct"])


class SourceTests(unittest.TestCase):
    def test_bare_attributes_xctest_modifiers_and_no_double_count(self):
        source = '''
        @Test
        func standalone() {}
        @Test("named") @MainActor func testDoubleCount() {}
        @Test(arguments: [1, 2])
        func parameterized(value: Int) {}
        @Test(.enabled(if: { true }())) func traitClosure() {}
        @Testing.Test func qualified() {}
        @MainActor public func testlowercase() {}
        func test_XCTest() {}
        func helper() {}
        '''
        self.assertEqual(metrics.declared_tests(source), 7)

    def test_comments_and_swift_string_fixtures_are_not_tests(self):
        source = '''
        // @Test func comment() {}
        /* outer /* nested */ @Test func comment() {} */
        let raw = #"@Test func rawString() {}"#
        let multiline = """
        @Test
        func embedded() {}
        func testEmbedded() {}
        """
        let escaped = "ignore \\" @Test func escaped() {}"
        @Test func real() {}
        '''
        self.assertEqual(metrics.declared_tests(source), 1)

    def test_production_scale_declaration_sensor(self):
        # > the app's current 8k declared tests; a bounded source census, no app.
        source = '\n'.join(f'@Test\nfunc test_{i}() {{}} // @Test func fake() {{}}' for i in range(10000))
        started = time.monotonic()
        self.assertEqual(metrics.declared_tests(source), 10000)
        self.assertLess(time.monotonic() - started, 10)


class CollectorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="test_metrics_", dir=ROOT)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for source in metrics.SOURCE_ROOTS:
            (self.root / source).mkdir(parents=True)
        (self.root / "VideoScan/VideoScan/Engine.swift").write_text('// comment\n\nstruct Engine {}\n')
        (self.root / "VideoScan/VideoScanTests/Tests.swift").write_text('@Test\nfunc one() {}\n// regression: #1\n')
        self.env = {"GITHUB_SHA": "abcd1234", "GITHUB_REF_NAME": 'quote"back\\slash\nbranch'}

    def test_poisoned_optional_tools_do_not_report_zero(self):
        (self.root / "TestResults.xcresult").mkdir()
        with patch.object(metrics, "run", return_value="not json"):
            row = metrics.collect(self.root, self.env)
        self.assertIsNone(row["coverage_logic_pct"])
        self.assertIsNone(row["open_issues"])
        self.assertIsNone(row["swiftlint_warnings"])
        self.assertEqual(row["test_count"], 1)
        self.assertEqual(row["total_swift_lines"], 6)
        self.assertEqual(row["regression_count"], 1)
        self.assertEqual(json.loads(json.dumps(row))["branch"], self.env["GITHUB_REF_NAME"])

    def test_issue_total_is_not_capped_at_a_thousand(self):
        with patch.object(metrics, "run", return_value=json.dumps({"data": {"repository": {"issues": {"totalCount": 1234}}}})):
            self.assertEqual(metrics.collect(self.root, self.env)["open_issues"], 1234)

    def test_missing_source_tree_is_failure_not_plausible_empty_row(self):
        (self.root / "swift_cli").rmdir()
        with self.assertRaisesRegex(ValueError, "missing source"):
            metrics.collect(self.root, self.env)

    def test_lint_absent_is_null_but_empty_successful_output_is_zero(self):
        output = self.root / "lint.txt"
        output.write_text("")
        env = {"SWIFTLINT_OUTPUT": str(output), "SWIFTLINT_OUTCOME": "success"}
        self.assertIsNone(metrics.diagnostic_count({}, "SWIFTLINT_OUTPUT", r": warning:"))
        self.assertEqual(metrics.diagnostic_count(env, "SWIFTLINT_OUTPUT", r": warning:"), 0)
        output.write_text('/file.swift:1: warning: issue\n/file.swift:2: error: issue\n')
        self.assertEqual(metrics.diagnostic_count(env, "SWIFTLINT_OUTPUT", r": warning:"), 1)

    def test_failed_partial_skipped_and_unattested_logs_are_unknown(self):
        output = self.root / "lint.txt"
        for tool in ("SWIFTLINT", "PERIPHERY"):
            for content in ("", "Error: Unknown option '--targets'\n",
                            "/file.swift:1:2: warning: partial\nerror: index failed\n",
                            "Done linting! Found 0 violations, 0 serious in 1 file.\n"):
                output.write_text(content)
                for outcome in (None, "", "failure", "skipped", "cancelled"):
                    with self.subTest(tool=tool, content=content, outcome=outcome):
                        env = {f"{tool}_OUTPUT": str(output)}
                        if outcome is not None:
                            env[f"{tool}_OUTCOME"] = outcome
                        self.assertIsNone(metrics.diagnostic_count(env, f"{tool}_OUTPUT", r": warning:"))

    def test_supplied_failed_logs_propagate_null_into_metrics_row(self):
        output = self.root / "lint.txt"
        output.write_text("Error: Unknown option '--targets'\n")
        env = {**self.env, "SWIFTLINT_OUTPUT": str(output), "SWIFTLINT_OUTCOME": "failure",
               "PERIPHERY_OUTPUT": str(output), "PERIPHERY_OUTCOME": "skipped"}
        with patch.object(metrics, "run", return_value=None):
            row = metrics.collect(self.root, env)
        for key in ("swiftlint_warnings", "swiftlint_errors", "periphery_findings"):
            self.assertIsNone(row[key])

    def test_shell_entrypoint_from_unrelated_cwd_and_escaped_json(self):
        scripts = self.root / "scripts"
        scripts.mkdir()
        for name in ("collect_metrics.sh", "collect_metrics.py"):
            shutil.copyfile(ROOT / "scripts" / name, scripts / name)
        fake_bin = self.root / "bin"
        fake_bin.mkdir()
        for name in ("gh", "xcrun"):
            tool = fake_bin / name
            tool.write_text('#!/bin/sh\necho poisoned-output\nexit 1\n')
            tool.chmod(0o755)
        (self.root / "TestResults.xcresult").mkdir()
        env = {**os.environ, **self.env, "PATH": f'{fake_bin}:{os.environ["PATH"]}'}
        env.pop("SWIFTLINT_OUTPUT", None)
        env.pop("PERIPHERY_OUTPUT", None)
        process = subprocess.run(["bash", str(scripts / "collect_metrics.sh")], cwd=fake_bin,
                                 env=env, text=True, capture_output=True, timeout=10)
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(len(process.stdout.splitlines()), 1)
        row = json.loads(process.stdout)
        self.assertEqual(row["branch"], self.env["GITHUB_REF_NAME"])
        self.assertEqual(row["test_count"], 1)
        self.assertIsNone(row["coverage_logic_pct"])


if __name__ == "__main__":
    unittest.main()
