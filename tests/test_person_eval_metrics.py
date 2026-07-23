import importlib.util
import pathlib
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "tools/person-eval/nightly_metrics.py"
SPEC = importlib.util.spec_from_file_location("person_eval_metrics", MODULE_PATH)
module = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
sys.modules[SPEC.name] = module
SPEC.loader.exec_module(module)


class PersonEvaluationMetricsTests(unittest.TestCase):
    def test_canonical_cycle_status_keeps_failed_latest_cycle_out_of_production_fields(self):
        row = module.cycle_metrics_for(module.DEFAULT_CYCLE_METRICS)
        self.assertEqual(row["poi_cycle_stream_status"], "ok")
        self.assertEqual(row["poi_cycle_latest_label"], "C5")
        self.assertEqual(row["poi_cycle_latest_evidence_tier"], "grade")
        self.assertEqual(row["poi_cycle_latest_verdict"], "fail")
        self.assertEqual(row["poi_cycle_production_label"], "C3")
        self.assertNotIn("poi_cycle_latest_balanced_accuracy", row)

    def test_missing_or_invalid_cycle_stream_is_visible_not_fabricated(self):
        with tempfile.TemporaryDirectory() as directory:
            missing = module.cycle_metrics_for(pathlib.Path(directory) / "missing.jsonl")
            self.assertEqual(missing["poi_cycle_stream_status"], "missing")
            self.assertIsNone(missing["poi_cycle_production_balanced_accuracy"])
            invalid_path = pathlib.Path(directory) / "invalid.jsonl"
            invalid_path.write_text('{"cycle":4}\n')
            invalid = module.cycle_metrics_for(invalid_path)
            self.assertEqual(invalid["poi_cycle_stream_status"], "invalid")
            self.assertIsNone(invalid["poi_cycle_production_label"])

    def test_score_band_boundaries(self):
        cases = [
            (None, "red"), (float("nan"), "red"), (-1, "red"),
            (0, "red"), (24.9, "red"),
            (25, "yellow"), (49.9, "yellow"),
            (50, "orange"), (79.9, "orange"),
            (80, "green"), (100, "green"), (101, "green"),
        ]
        for value, expected in cases:
            with self.subTest(value=value):
                self.assertEqual(module.score_band(value), expected)

    def test_unconfigured_is_red_zero_but_quality_is_unknown(self):
        row = module.metrics_for(None)
        self.assertEqual(row["person_eval_readiness_pct"], 0)
        self.assertEqual(row["person_eval_readiness_band"], "red")
        self.assertIsNone(row["person_eval_quality_score"])
        self.assertFalse(row["person_eval_publish_eligible"])

    def test_configured_manifest_waiting_for_run_is_yellow(self):
        row = module.metrics_for({"schemaVersion": 1})
        self.assertEqual(row["person_eval_readiness_pct"], 25)
        self.assertEqual(row["person_eval_readiness_band"], "yellow")
        self.assertIsNone(row["person_eval_quality_score"])

    def test_ineligible_development_score_is_firewalled(self):
        report = {
            "publishEligible": False, "score": 100.0, "caseCount": 6,
            "engine": "ArcFace", "suite": "private dev",
            "ineligibilityReasons": ["has no identity-negative cases"],
            "identityPresence": {"precision": 1.0, "recall": 1.0, "fp": 0, "fn": 0},
        }
        row = module.metrics_for({"schemaVersion": 1}, report)
        self.assertEqual(row["person_eval_readiness_pct"], 50)
        self.assertEqual(row["person_eval_readiness_band"], "orange")
        self.assertIsNone(row["person_eval_quality_score"])
        self.assertIsNone(row["person_eval_identity_precision"])
        self.assertEqual(row["person_eval_case_count"], 6)

    def test_quality_holdout_failure_reaches_75_but_not_green(self):
        manifest = {
            "publication": {"tier": "quality", "holdout": True,
                            "datasetVersion": "donna-v1"}
        }
        row = module.metrics_for(manifest, run_error="evaluation-timeout")
        self.assertEqual(row["person_eval_readiness_pct"], 75)
        self.assertEqual(row["person_eval_readiness_band"], "orange")
        self.assertIsNone(row["person_eval_quality_score"])

    def test_publishable_report_maps_quality_fields(self):
        manifest = {
            "publication": {"tier": "quality", "holdout": True,
                            "datasetVersion": "donna-v1"}
        }
        report = {
            "publishEligible": True, "score": 82.4, "caseCount": 40,
            "engine": "ArcFace", "suite": "Donna golden",
            "datasetVersion": "donna-v1", "generatedAt": "2026-07-14T06:00:00Z",
            "identityPresence": {"precision": 0.9, "recall": 0.76, "fp": 2, "fn": 6},
            "facePresence": {"recall": 0.95},
            "segment": {"precision": 0.81, "recall": 0.73},
            "performance": {"elapsedSeconds": 120, "peakRSSMB": 320},
        }
        row = module.metrics_for(manifest, report, allow_quality=True)
        self.assertEqual(row["person_eval_readiness_pct"], 100)
        self.assertEqual(row["person_eval_quality_score"], 82.4)
        self.assertEqual(row["person_eval_quality_band"], "green")
        self.assertEqual(row["person_eval_identity_precision"], 0.9)
        self.assertEqual(row["person_eval_identity_recall"], 0.76)
        self.assertEqual(row["person_eval_false_positives"], 2)
        self.assertEqual(row["person_eval_false_negatives"], 6)

    def test_publishable_report_stays_gated_until_provenance_is_approved(self):
        manifest = {
            "publication": {"tier": "quality", "holdout": True,
                            "datasetVersion": "donna-v1"}
        }
        report = {"publishEligible": True, "score": 100.0, "caseCount": 2}
        row = module.metrics_for(manifest, report)
        self.assertEqual(row["person_eval_readiness_pct"], 75)
        self.assertFalse(row["person_eval_publish_eligible"])
        self.assertIsNone(row["person_eval_quality_score"])
        self.assertEqual(row["person_eval_status"], "quality-awaiting-approval")

    def test_public_row_contains_no_private_paths(self):
        manifest = {
            "engine": {"referencePath": "/Volumes/Family/Donna/private"},
            "cases": [{"video": "/Volumes/Family/private.mov"}],
        }
        text = str(module.metrics_for(manifest))
        self.assertNotIn("/Volumes/", text)
        self.assertNotIn("private.mov", text)

    def test_public_labels_are_whitelisted_and_suite_is_omitted(self):
        manifest = {
            "publication": {"tier": "quality", "holdout": True,
                            "datasetVersion": "donna-v1"}
        }
        report = {
            "publishEligible": True, "score": 90.0, "caseCount": 4,
            "engine": "<img src=x onerror=alert(1)>",
            "suite": "/Volumes/Family/Donna-secret",
            "datasetVersion": "../../Donna secret",
            "identityPresence": {}, "facePresence": {}, "segment": {},
            "performance": {},
        }
        row = module.metrics_for(manifest, report, allow_quality=True)
        text = str(row)
        self.assertIsNone(row["person_eval_engine"])
        self.assertIsNone(row["person_eval_dataset_version"])
        self.assertNotIn("person_eval_suite", row)
        self.assertNotIn("<img", text)
        self.assertNotIn("/Volumes/", text)


if __name__ == "__main__":
    unittest.main()
