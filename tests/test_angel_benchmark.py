import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch
import signal
import subprocess

spec = importlib.util.spec_from_file_location("angel_benchmark", Path(__file__).resolve().parents[1] / "scripts/angel_benchmark.py")
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)


def report(mode="direct", seconds=10):
    return dict(status="ok", exitCode=0, buildSHA="abc", corpusSHA256="def", configuration="Release",
                machine="fixture", makeLossless=False, mode=mode, runRoot="/fixture/results",
                outputStorage=dict(DeviceIdentifier="disk99s1", VolumeUUID="fixture-uuid"),
                summary=dict(requested=100, completed=100, passed=100, failed=0, incomplete=0,
                             results=[dict(success=True, sourceUnchanged=True, endToEndSeconds=seconds) for _ in range(100)]))


class AngelBenchmarkTests(unittest.TestCase):
    def test_timeout_cleanup_kills_remaining_group_after_leader_exits(self):
        process = Mock(pid=98765)
        with patch.object(bench.os, "killpg") as kill:
            bench.stop_group(process, grace=0, kill_wait=0.1)
        kill.assert_any_call(98765, signal.SIGKILL)
        process.poll.assert_not_called()
        process.wait.assert_called_once_with(timeout=0.1)

    def test_unreapable_group_returns_without_unbounded_wait(self):
        process = Mock(pid=98765)
        process.wait.side_effect = subprocess.TimeoutExpired("fixture", 0.1)
        with patch.object(bench.os, "killpg"):
            self.assertFalse(bench.stop_group(process, grace=0, kill_wait=0.1))
    def test_complete_run(self):
        self.assertEqual(bench.verdict(report()["summary"], 0), "ok")

    def test_incomplete_is_not_speedup(self):
        r = report(); r["summary"]["completed"] = 99
        self.assertEqual(bench.verdict(r["summary"], 0), "incomplete")
        with self.assertRaises(ValueError):
            bench.compare_reports(r, report("ram-staged"))

    def test_changed_source_and_fallback_fail(self):
        for field in ("success", "sourceUnchanged"):
            r = report(); r["summary"]["results"][0][field] = False
            self.assertEqual(bench.verdict(r["summary"], 0), "failed")

    def test_missing_rows_and_nonzero_exit_fail(self):
        r = report(); r["summary"]["results"].pop()
        self.assertEqual(bench.verdict(r["summary"], 0), "failed")
        self.assertEqual(bench.verdict(None, 124), "incomplete")
        self.assertEqual(bench.verdict(report()["summary"], 65), "failed")

    def test_comparison_includes_per_file_end_to_end(self):
        result = bench.compare_reports(report(), report("ram-staged", 8))
        self.assertEqual(result["reductionPct"], 20)
        self.assertEqual(result["candidate"]["p95Seconds"], 8)

    def test_different_build_corpus_machine_or_settings_refused(self):
        for field in ("buildSHA", "corpusSHA256", "machine", "configuration", "makeLossless", "runRoot"):
            candidate = report("ssd-staged"); candidate[field] = "different"
            with self.assertRaises(ValueError):
                bench.compare_reports(report(), candidate)

    def test_changed_or_unverified_output_storage_refused(self):
        for storage in ({}, {"unverified": True}, {"DeviceIdentifier": "disk98s1"}):
            candidate = report("ram-staged")
            candidate["outputStorage"] = storage
            with self.assertRaises(ValueError):
                bench.compare_reports(report(), candidate)

    def test_explicit_source_list_and_unique_paths_required(self):
        with self.assertRaises(ValueError):
            bench.validate_paths([])
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "test_fixture.mov"; path.write_bytes(b"small fixture")
            with self.assertRaises(ValueError):
                bench.validate_paths([str(path)] * 100)

    def test_atomic_report(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "report.json"
            bench.atomic_json(path, {"status": "incomplete"})
            self.assertIn("incomplete", path.read_text())
            self.assertFalse(path.with_name("report.json.tmp").exists())
