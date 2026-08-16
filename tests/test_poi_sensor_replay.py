import datetime
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
COLLECTOR = ROOT / "tools/person-eval/nightly_metrics.py"
DASHBOARD = ROOT / "docs/index.html"
MORNING = ROOT / "scripts/morning_metrics.sh"


class POISensorReplayTests(unittest.TestCase):
    def test_cycle_only_cli_emits_only_validated_public_poi_fields(self):
        result = subprocess.run(
            [sys.executable, str(COLLECTOR), "--cycle-only",
             "--manifest", "/Volumes/Family/private-holdout.json",
             "--cycle-metrics", str(ROOT / "docs/poi-cycles/metrics.jsonl")],
            check=True, capture_output=True, text=True,
        )
        row = json.loads(result.stdout)
        self.assertEqual(row["poi_cycle_stream_status"], "ok")
        self.assertEqual(row["poi_cycle_production_label"], "C3")
        self.assertTrue(row)
        self.assertTrue(all(key.startswith("poi_cycle_") for key in row))
        self.assertFalse(any(key.startswith("person_") for key in row))
        self.assertTrue({"host", "passed", "failed", "total", "source"}.isdisjoint(row))
        self.assertNotIn("/Volumes/", result.stdout)
        self.assertNotIn("private-holdout", result.stdout)

    def test_cycle_only_cli_preserves_invalid_stream_status(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".jsonl") as stream:
            stream.write('{"cycle":4}\n')
            stream.flush()
            result = subprocess.run(
                [sys.executable, str(COLLECTOR), "--cycle-only",
                 "--cycle-metrics", stream.name],
                check=True, capture_output=True, text=True,
            )
        row = json.loads(result.stdout)
        self.assertEqual(row["poi_cycle_stream_status"], "invalid")
        self.assertTrue(all(key.startswith("poi_cycle_") for key in row))
        self.assertIsNone(row["poi_cycle_production_label"])

    def test_dashboard_filters_cycle_replay_from_product_tests_without_rendering_it(self):
        page = DASHBOARD.read_text()
        rows = [
            {"source": "nightly-local", "branch": "main", "dirty": False,
             "poi_cycle_stream_status": "ok", "passed": 100},
            {"source": "poi-cycle-metrics", "poi_cycle_stream_status": "ok",
             "passed": 999},
            {"source": "nightly-local", "branch": "feature", "dirty": True,
             "poi_cycle_stream_status": "ok", "passed": 50},
        ]
        product_tests = [
            row["passed"] for row in rows
            if row.get("source") != "poi-cycle-metrics"
        ]
        self.assertEqual(product_tests, [100, 50])
        self.assertIn(
            'const isTestRunRow = row => row.source !== "poi-cycle-metrics";',
            page,
        )
        self.assertIn("const tdRows = allTdRows.filter(isTestRunRow);", page)
        self.assertNotIn("isPoiCycleSensorRow", page)
        self.assertNotIn('rawUrl("poi_cycles.jsonl")', page)

    def test_morning_replay_updates_sensor_not_host_or_green_run_state(self):
        script = MORNING.read_text()
        match = re.search(r"python3 - <<'PY'\n(.*?)\nPY\s*$", script, re.DOTALL)
        self.assertIsNotNone(match)
        now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
        rows = [
            {
                "ts": now.isoformat().replace("+00:00", "Z"),
                "source": "nightly-local", "host": "M4", "branch": "main",
                "dirty": False, "status": "failed", "reason": "build-rc:65",
                "passed": 0, "failed": 0, "skipped": 0, "total": 0,
            },
            {
                "ts": (now + datetime.timedelta(seconds=1)).isoformat().replace("+00:00", "Z"),
                "source": "poi-cycle-metrics", "host": "ReplayHost",
                "status": "ok", "passed": 999, "failed": 0, "total": 999,
                "coverage_logic_pct": 100,
                "poi_cycle_stream_status": "ok",
                "poi_cycle_latest_label": "C5",
                "poi_cycle_latest_evidence_tier": "grade",
                "poi_cycle_production_label": "C3",
            },
        ]
        env = os.environ.copy()
        env["TD_ROWS"] = "\n".join(json.dumps(row) for row in rows)
        env["TD_SA"] = ""
        result = subprocess.run(
            [sys.executable, "-c", match.group(1)], env=env,
            check=True, capture_output=True, text=True,
        )
        output = result.stdout
        self.assertIn("M4    ❌ failed build-rc:65", output)
        self.assertNotIn("REPLAY", output)
        self.assertNotIn("999", output)
        self.assertIn("POI cycle sensor: ok | latest C5 (grade) | production C3", output)
        self.assertIn("CRITICAL: no green nightly run for today yet", output)

    def test_morning_delta_uses_product_runs_not_newer_replay(self):
        script = MORNING.read_text()
        match = re.search(r"python3 - <<'PY'\n(.*?)\nPY\s*$", script, re.DOTALL)
        self.assertIsNotNone(match)
        now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
        yesterday = now - datetime.timedelta(days=1)
        rows = [
            {
                "ts": yesterday.isoformat().replace("+00:00", "Z"),
                "source": "nightly-local", "host": "M1", "branch": "main",
                "dirty": False, "status": "ok", "passed": 100, "failed": 0,
                "skipped": 0, "total": 100, "coverage_logic_pct": 70.0,
            },
            {
                "ts": now.isoformat().replace("+00:00", "Z"),
                "source": "nightly-local", "host": "M4", "branch": "main",
                "dirty": False, "status": "ok", "passed": 101, "failed": 0,
                "skipped": 0, "total": 101, "coverage_logic_pct": 71.0,
                "person_eval_readiness_pct": 100,
                "person_eval_readiness_band": "green",
                "person_eval_publish_eligible": True,
                "person_eval_quality_score": 90.0,
            },
            {
                "ts": (now + datetime.timedelta(seconds=1)).isoformat().replace("+00:00", "Z"),
                "source": "poi-cycle-metrics", "host": "ReplayHost",
                "status": "ok", "passed": 999, "failed": 0, "total": 999,
                "coverage_logic_pct": 100.0,
                "poi_cycle_stream_status": "ok",
                "poi_cycle_latest_label": "C5",
                "poi_cycle_latest_evidence_tier": "grade",
                "poi_cycle_production_label": "C3",
            },
        ]
        env = os.environ.copy()
        env["TD_ROWS"] = "\n".join(json.dumps(row) for row in rows)
        env["TD_SA"] = ""
        result = subprocess.run(
            [sys.executable, "-c", match.group(1)], env=env,
            check=True, capture_output=True, text=True,
        )
        output = result.stdout
        self.assertNotIn("REPLAY", output)
        self.assertNotIn("999", output)
        self.assertIn("coverage +1.0%", output)
        self.assertNotIn("coverage +30.0%", output)


if __name__ == "__main__":
    unittest.main()
