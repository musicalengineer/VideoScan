import importlib.util
import json
import pathlib
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "scripts" / "publish_poi_cycle_metrics.py"
SPEC = importlib.util.spec_from_file_location("publish_poi_cycle_metrics", MODULE_PATH)
module = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
sys.modules[SPEC.name] = module
SPEC.loader.exec_module(module)


class POICycleMetricsTests(unittest.TestCase):
    def test_c1_through_c5_are_present_and_honestly_tiered(self):
        rows = module.load_and_validate(module.DEFAULT_SOURCE)
        self.assertEqual([row["cycleLabel"] for row in rows], ["C1", "C2", "C3", "C4", "C5"])
        self.assertEqual([row["evidenceTier"] for row in rows[:3]], ["grade"] * 3)
        self.assertEqual(rows[3]["evidenceTier"], "development")
        self.assertEqual(rows[3]["verdict"], "development")
        self.assertEqual(rows[3]["balancedAccuracy"], 0.7692307692)
        self.assertEqual(rows[4]["evidenceTier"], "grade")
        self.assertEqual(rows[4]["verdict"], "fail")
        self.assertEqual(rows[4]["roundBalancedAccuracy"], [0.6153846154, 0.6923076923])
        production = [row for row in rows if row.get("productionBaseline")]
        self.assertEqual([row["cycleLabel"] for row in production], ["C3"])

    def test_nightly_summary_keeps_failed_latest_cycle_out_of_production_score(self):
        rows = module.load_and_validate(module.DEFAULT_SOURCE)
        summary = module.nightly_summary(rows)
        self.assertEqual(summary["poi_cycle_latest_label"], "C5")
        self.assertEqual(summary["poi_cycle_latest_evidence_tier"], "grade")
        self.assertEqual(summary["poi_cycle_latest_verdict"], "fail")
        self.assertEqual(summary["poi_cycle_production_label"], "C3")
        self.assertEqual(summary["poi_cycle_production_balanced_accuracy"], rows[2]["balancedAccuracy"])
        self.assertNotIn("poi_cycle_latest_balanced_accuracy", summary)

    def test_development_cycle_cannot_be_marked_as_production(self):
        rows = module.load_and_validate(module.DEFAULT_SOURCE)
        for row in rows:
            row.pop("productionBaseline", None)
        rows[-1]["productionBaseline"] = True
        with tempfile.NamedTemporaryFile(mode="w", suffix=".jsonl") as stream:
            stream.write(module.serialize(rows))
            stream.flush()
            with self.assertRaisesRegex(ValueError, "passing grade"):
                module.load_and_validate(pathlib.Path(stream.name))

    def test_publisher_is_idempotent_and_emits_valid_jsonl(self):
        rows = module.load_and_validate(module.DEFAULT_SOURCE)
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory) / "metrics" / "poi_cycles.jsonl"
            self.assertTrue(module.publish(module.serialize(rows), output))
            self.assertFalse(module.publish(module.serialize(rows), output))
            published = [json.loads(line) for line in output.read_text().splitlines()]
            self.assertEqual(published, rows)

    def test_empty_stream_is_invalid(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".jsonl") as stream:
            with self.assertRaisesRegex(ValueError, "at least one"):
                module.load_and_validate(pathlib.Path(stream.name))

    def test_metric_math_cannot_drift_from_confusion_counts(self):
        row = module.load_and_validate(module.DEFAULT_SOURCE)[0].copy()
        row["f1"] = 0.99
        with self.assertRaisesRegex(ValueError, "f1 does not match"):
            module.validate_row(row, 1)

    def test_dashboard_does_not_render_retired_cycle_scoreboard(self):
        page = (ROOT / "docs" / "index.html").read_text()
        self.assertNotIn('rawUrl("poi_cycles.jsonl")', page)
        self.assertNotIn('id="chart-poi-cycles"', page)
        self.assertNotIn('id="poi-cycle-cards"', page)
        self.assertNotIn("POI Cycle Quality", page)
        self.assertNotIn("Production Baseline", page)
        self.assertNotIn("POI Sensor", page)


if __name__ == "__main__":
    unittest.main()
