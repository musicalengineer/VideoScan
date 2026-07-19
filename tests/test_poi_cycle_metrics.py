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
    def test_c1_through_c4_are_present_and_honestly_tiered(self):
        rows = module.load_and_validate(module.DEFAULT_SOURCE)
        self.assertEqual([row["cycleLabel"] for row in rows], ["C1", "C2", "C3", "C4"])
        self.assertEqual([row["evidenceTier"] for row in rows[:3]], ["grade"] * 3)
        self.assertEqual(rows[3]["evidenceTier"], "development")
        self.assertEqual(rows[3]["verdict"], "development")
        self.assertEqual(rows[3]["balancedAccuracy"], 0.7692307692)

    def test_publisher_is_idempotent_and_emits_valid_jsonl(self):
        rows = module.load_and_validate(module.DEFAULT_SOURCE)
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory) / "metrics" / "poi_cycles.jsonl"
            self.assertTrue(module.publish(module.serialize(rows), output))
            self.assertFalse(module.publish(module.serialize(rows), output))
            published = [json.loads(line) for line in output.read_text().splitlines()]
            self.assertEqual(published, rows)

    def test_metric_math_cannot_drift_from_confusion_counts(self):
        row = module.load_and_validate(module.DEFAULT_SOURCE)[0].copy()
        row["f1"] = 0.99
        with self.assertRaisesRegex(ValueError, "f1 does not match"):
            module.validate_row(row, 1)

    def test_dashboard_consumes_cycle_stream_and_renders_graph(self):
        page = (ROOT / "docs" / "index.html").read_text()
        self.assertIn('rawUrl("poi_cycles.jsonl")', page)
        self.assertIn('id="chart-poi-cycles"', page)
        self.assertIn('evidenceTier === "development"', page)
        self.assertIn('balancedAccuracy', page)


if __name__ == "__main__":
    unittest.main()
