#!/usr/bin/env python3
"""Out-of-process pin for test-host detection (codex #1713, 2026-09-23).

FamilyGraphCompiledStore's test-host detector keyed on four environment
variables that XCTest sets but SwiftPM's Swift Testing runner
(`swift test` -> swiftpm-testing-helper) does not, so under `swift test` the
production compiled-store factory resolved to the REAL family tree in
Application Support. Asking the getter from inside an app-host test cannot
establish the fix, because the app host always has the XCTest markers. So
these tests launch the real runners as subprocesses and read what the probe
suite, running inside each runner, concluded:

  swift test   — TestHostDetectionProbe in VideoScanCoreTests (always run;
                 this is the path that was broken)
  xcodebuild   — AppTestHostDetectionProbe in the app host, and the Core
                 package scheme (opt-in: VS_RUN_XCODE_PROBES=1, heavy; run on
                 the M1 per the machine policy). Optional
                 VS_PROBE_DERIVED_DATA=<abs path> for -derivedDataPath.

Each probe writes JSON to $VS_TEST_HOST_PROBE_REPORT. A report file that
exists at all proves the probe EXECUTED (guards the -only-testing /
--filter "0 tests, SUCCEEDED" trap); we also parse the runner's test count.

The probes only evaluate the store factories (pure struct init); nothing
touches Application Support.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CORE = REPO_ROOT / "VideoScan" / "VideoScanCore"
PROJECT = REPO_ROOT / "VideoScan" / "VideoScan.xcodeproj"

# Keys an outer runner could leak into the child and mask the bug. The
# child must detect itself from its OWN signals.
LEAKY_KEYS = ("XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier",
              "XCTESTCONFIGURATION_TEMP_DIR", "SWIFT_TESTING_ENABLED", "VS_UI_TEST",
              "VIDEOSCAN_FAMILY_TREE_COMPILED_ROOT")


def _clean_env(extra: dict[str, str]) -> dict[str, str]:
    env = {k: v for k, v in os.environ.items() if k not in LEAKY_KEYS}
    env.update(extra)
    return env


def _run(cmd: list[str], env: dict[str, str], log: Path, cwd: Path | None = None,
         timeout: int = 1800) -> tuple[int, str]:
    # Output goes to a file, never through a pipe to tail/head: the exit
    # status we assert on must be the runner's own.
    with open(log, "w") as fh:
        proc = subprocess.run(cmd, env=env, cwd=cwd, stdout=fh, stderr=subprocess.STDOUT,
                              timeout=timeout, check=False)
    return proc.returncode, log.read_text(errors="replace")


def _swift_testing_count(output: str) -> int:
    counts = [int(n) for n in re.findall(r"Test run with (\d+) tests?", output)]
    return max(counts, default=0)


class ProbeAssertions:
    def assert_isolated(self, report_path: Path, output: str, rc: int, runner: str) -> dict:
        self.assertTrue(report_path.exists(),
                        f"{runner}: probe never ran (no report) — filter matched nothing?\n{output[-4000:]}")
        report = json.loads(report_path.read_text())
        self.assertEqual(report["detected"], "true", f"{runner}: detector said NOT a test: {report}")
        self.assertEqual(report["compiledRootUnderApplicationSupport"], "false",
                         f"{runner}: production compiled store is the REAL one: {report}")
        self.assertEqual(rc, 0, f"{runner}: runner failed rc={rc}\n{output[-4000:]}")
        return report


class SwiftTestCoreProbe(ProbeAssertions, unittest.TestCase):
    """The broken path: `swift test` + Swift Testing, no XCTest env keys."""

    def test_swift_test_detects_itself_and_sandboxes_the_store(self) -> None:
        with tempfile.TemporaryDirectory(prefix="vs-probe-1713-") as tmp:
            report = Path(tmp) / "report.json"
            log = Path(tmp) / "swift-test.log"
            rc, out = _run(["swift", "test", "--package-path", str(CORE),
                            "--filter", "TestHostDetectionProbe"],
                           _clean_env({"VS_TEST_HOST_PROBE_REPORT": str(report)}), log)
            got = self.assert_isolated(report, out, rc, "swift test")
            self.assertGreater(_swift_testing_count(out), 0, f"executed 0 tests\n{out[-4000:]}")
            # Record which signal carried it, for the next person who reads the log.
            print(f"swift test probe: {got}")


@unittest.skipUnless(os.environ.get("VS_RUN_XCODE_PROBES") == "1",
                     "heavy xcodebuild probes: set VS_RUN_XCODE_PROBES=1 (M1 per machine policy)")
class XcodebuildProbes(ProbeAssertions, unittest.TestCase):

    def _dd(self, tmp: str, name: str) -> str:
        base = os.environ.get("VS_PROBE_DERIVED_DATA")
        return str(Path(base) / name) if base else str(Path(tmp) / name)

    def test_app_host_probe(self) -> None:
        with tempfile.TemporaryDirectory(prefix="vs-probe-1713-") as tmp:
            report = Path(tmp) / "report.json"
            log = Path(tmp) / "xcodebuild-app.log"
            rc, out = _run(["xcodebuild", "test", "-project", str(PROJECT), "-scheme", "VideoScan",
                            "-configuration", "Debug", "-destination", "platform=macOS",
                            "-derivedDataPath", self._dd(tmp, "dd-app"),
                            "-only-testing:VideoScanTests/AppTestHostDetectionProbe"],
                           _clean_env({"TEST_RUNNER_VS_TEST_HOST_PROBE_REPORT": str(report)}), log,
                           timeout=3600)
            got = self.assert_isolated(report, out, rc, "xcodebuild app host")
            self.assertEqual(got["mainGate"], "true", f"main.swift boot gate missed the host: {got}")
            print(f"xcodebuild app-host probe: {got}")

    def test_core_package_scheme_probe(self) -> None:
        with tempfile.TemporaryDirectory(prefix="vs-probe-1713-") as tmp:
            report = Path(tmp) / "report.json"
            log = Path(tmp) / "xcodebuild-core.log"
            # A package has no -project; xcodebuild resolves it from cwd.
            rc, out = _run(["xcodebuild", "test", "-scheme", "VideoScanCore-Package",
                            "-destination", "platform=macOS",
                            "-derivedDataPath", self._dd(tmp, "dd-core"),
                            "-only-testing:VideoScanCoreTests/TestHostDetectionProbe"],
                           _clean_env({"TEST_RUNNER_VS_TEST_HOST_PROBE_REPORT": str(report)}), log,
                           cwd=CORE, timeout=3600)
            got = self.assert_isolated(report, out, rc, "xcodebuild core package")
            print(f"xcodebuild core-package probe: {got}")


if __name__ == "__main__":
    unittest.main()
