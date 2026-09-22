"""Headless CI wiring and fail-closed shell sensors; no Xcode is launched."""
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/ci.yml"
PASS = "✔ Test mustPass() passed after 0.001 seconds.\n"
FAIL = "✘ Test mustFail() failed after 0.001 seconds with 1 issue.\n"
COMPLETE = "✘ Test run with 300 tests in 30 suites failed after 4.0 seconds with 1 issue.\n"
SUITES = "".join(f"◇ Suite Suite{index} started.\n" for index in range(30))
CLEAN = SUITES + PASS + FAIL + COMPLETE


def run_scripts(source):
    """Read this workflow's literal run blocks, without parsing arbitrary YAML."""
    scripts = []
    for step in re.split(r"(?m)^      - ", source)[1:]:
        marker = re.search(r"(?m)^        run: \|[ \t]*$", step)
        if marker is None:
            continue
        lines = []
        for line in step[marker.end():].splitlines():
            if line.strip() and not line.startswith("          "):
                break
            lines.append(line[10:] if line.strip() else "")
        scripts.append("\n".join(lines))
    if not scripts:
        raise AssertionError("No literal run blocks found; check workflow layout")
    return scripts


class CIWorkflowContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = WORKFLOW.read_text()
        cls.scripts = run_scripts(cls.source)

    def script_for(self, command):
        matches = [script for script in self.scripts
                   if re.search(rf"(?m)^\s*{re.escape(command)}(?:\s|$)", script)]
        self.assertEqual(len(matches), 1, f"Expected one {command} run block")
        return matches[0]

    def xcode_arguments(self, action):
        script = self.script_for(f"xcodebuild {action}")
        logical = script.replace("\\\n", " ")
        command = re.search(rf"(?m)^.*\bxcodebuild {action}[^\n]*", logical)
        self.assertIsNotNone(command)
        return shlex.split(command.group())

    def option(self, arguments, name):
        self.assertEqual(arguments.count(name), 1, f"Expected exactly one {name}")
        index = arguments.index(name)
        self.assertLess(index + 1, len(arguments), f"Missing value for {name}")
        return arguments[index + 1]

    def test_build_and_test_share_release_products_and_coverage(self):
        build = self.xcode_arguments("build-for-testing")
        test = self.xcode_arguments("test-without-building")
        for option in ("-project", "-scheme", "-destination", "-derivedDataPath"):
            with self.subTest(option=option):
                self.assertEqual(self.option(build, option), self.option(test, option))
        for arguments in (build, test):
            self.assertEqual(self.option(arguments, "-configuration"), "Release")
            self.assertEqual(self.option(arguments, "-enableCodeCoverage"), "YES")
        self.assertEqual(self.option(test, "-resultBundlePath"), "TestResults.xcresult")

    def test_test_plan_keeps_real_test_target_and_canaries_enabled(self):
        arguments = self.xcode_arguments("test-without-building")
        self.assertEqual(self.option(arguments, "-testPlan"), "VideoScan-CI")
        self.assertNotIn("-parallel-testing-enabled", arguments)
        self.assertFalse(any(arg.startswith(("-only-testing", "-skip-testing")) for arg in arguments))
        plan = json.loads((ROOT / "VideoScan/VideoScan-CI.xctestplan").read_text())
        targets = [target for target in plan["testTargets"]
                   if target["target"]["name"] == "VideoScanTests"]
        self.assertEqual(len(targets), 1)
        self.assertIs(targets[0].get("parallelizable"), False)
        self.assertFalse(targets[0].get("enabled") is False)
        self.assertFalse(targets[0].get("skippedTests"), "CI must run the full unit suite, including canaries")
        self.assertTrue((ROOT / "VideoScan/VideoScanTests/CICanaryTests.swift").is_file())

    def test_referenced_local_scripts_and_preflight_suites_exist(self):
        referenced = set(re.findall(r"\b(?:scripts|tests)/[\w./-]+\.(?:py|sh)\b", self.source))
        required = {
            "scripts/ci_test_verdict.py", "scripts/ci_select_xcode.sh",
            "scripts/ci_test_summary.sh", "scripts/collect_metrics.sh",
            "tests/test_ci_workflow_contract.py", "tests/test_ci_test_verdict.py",
            "tests/test_nightly_workflow_contract.py", "tests/test_nightly_lint_report.py",
            "tests/test_collect_metrics.py",
        }
        self.assertFalse(required - referenced, f"Missing CI dependencies: {sorted(required - referenced)}")
        for relative in referenced:
            with self.subTest(path=relative):
                self.assertTrue((ROOT / relative).is_file(), f"CI references nonexistent file {relative}")
        preflight = self.source.split("  preflight:\n", 1)[1].split("  test:\n", 1)[0]
        for relative in required:
            if relative.startswith("tests/"):
                self.assertIn(relative, preflight, f"{relative} must run before the macOS build")

    def run_test_step(self, log, exit_code=65):
        script = self.script_for("xcodebuild test-without-building")
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            binary = work / "bin"
            binary.mkdir()
            fake = binary / "xcodebuild"
            fake.write_text('#!/bin/bash\n'
                            '[ "${TEST_RUNNER_GITHUB_ACTIONS:-}" = true ] || exit 99\n'
                            'cat "$FAKE_TEST_LOG"\nexit "$FAKE_TEST_EXIT"\n')
            fake.chmod(0o755)
            (work / "scripts").symlink_to(ROOT / "scripts", target_is_directory=True)
            fixture = work / "fixture.log"
            fixture.write_text(log)
            env = {**os.environ, "PATH": f"{binary}{os.pathsep}{os.environ['PATH']}",
                   "GITHUB_STEP_SUMMARY": str(work / "summary.md"),
                   "FAKE_TEST_LOG": str(fixture), "FAKE_TEST_EXIT": str(exit_code)}
            return subprocess.run(["bash", "-e", "-o", "pipefail", "-c", script],
                                  cwd=work, env=env, text=True, capture_output=True, timeout=10)

    def assert_rejected(self, log, exit_code=65):
        result = self.run_test_step(log, exit_code)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_complete_canary_only_run_is_accepted(self):
        result = self.run_test_step(CLEAN)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("only the expected canary failed", result.stdout)

    def test_missing_either_canary_is_rejected(self):
        for canary in (PASS, FAIL):
            with self.subTest(canary=canary):
                self.assert_rejected(CLEAN.replace(canary, ""))

    def test_ghost_run_with_too_few_suites_is_rejected(self):
        self.assert_rejected(CLEAN.replace(SUITES, "◇ Suite OnlySuite started.\n"))

    def test_real_failures_are_rejected(self):
        for failure in ("✘ Test realBug() failed after 1 seconds with 1 issue.\n",
                        "Test Case '-[Tests realBug]' failed (0.1 seconds).\n",
                        "\u200b✘ Test hiddenBug() failed after 1 seconds with 1 issue.\n"):
            with self.subTest(failure=failure):
                self.assert_rejected(failure + CLEAN)

    def test_canaries_without_completion_are_rejected(self):
        self.assert_rejected(CLEAN.replace(COMPLETE, ""))

    def test_infrastructure_exit_after_canaries_is_rejected(self):
        for exit_code in (0, 1, 124, 137, 143):
            with self.subTest(exit_code=exit_code):
                self.assert_rejected(CLEAN, exit_code)

    def test_runner_crash_after_summary_is_rejected(self):
        self.assert_rejected(CLEAN + "Testing failed: Test runner crashed.\n")


if __name__ == "__main__":
    unittest.main()
