import importlib.util
import pathlib
import sys
import tempfile
import unittest
import json


ROOT = pathlib.Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "tools/person-eval/person_eval.py"
SPEC = importlib.util.spec_from_file_location("person_eval", MODULE_PATH)
person_eval = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
sys.modules[SPEC.name] = person_eval
SPEC.loader.exec_module(person_eval)


class PersonEvaluationTests(unittest.TestCase):
    def test_scores_identity_face_presence_segments_and_tags(self):
        manifest = ROOT / "tests/fixtures/person_eval/example_manifest.json"
        report = person_eval.evaluate(manifest)

        self.assertEqual(report["caseCount"], 3)
        self.assertEqual(report["facePresence"]["tp"], 2)
        self.assertEqual(report["facePresence"]["tn"], 1)
        self.assertEqual(report["identityPresence"]["tp"], 1)
        self.assertEqual(report["identityPresence"]["fp"], 1)
        self.assertAlmostEqual(report["identityPresence"]["f1"], 2 / 3)
        self.assertEqual(report["score"], 66.7)
        self.assertAlmostEqual(report["segment"]["recall"], 0.6)
        self.assertAlmostEqual(report["segment"]["precision"], 0.75)
        self.assertEqual(report["byTag"]["family-similarity"]["fp"], 1)
        self.assertEqual(report["performance"]["peakRSSMB"], 520)
        self.assertFalse(report["publishEligible"])
        self.assertEqual(report["resultSource"], "fixture")
        self.assertIn("contains prerecorded result fixtures", report["ineligibilityReasons"])

    def test_markdown_surfaces_false_positive(self):
        manifest = ROOT / "tests/fixtures/person_eval/example_manifest.json"
        text = person_eval.markdown(person_eval.evaluate(manifest))
        self.assertIn("66.7/100", text)
        self.assertIn("FALSE POSITIVE", text)
        self.assertIn("Any face", text)
        self.assertIn("NOT ELIGIBLE", text)

    def test_empty_denominators_are_not_invented(self):
        counts = person_eval.Counts(tn=4)
        self.assertIsNone(counts.precision)
        self.assertIsNone(counts.recall)
        self.assertIsNone(counts.f1)
        self.assertEqual(counts.accuracy, 1.0)

    def test_overlapping_segments_use_union_not_double_counting(self):
        intervals = [(0.0, 10.0), (5.0, 15.0)]
        self.assertEqual(person_eval._interval_union_length(intervals), 15.0)
        self.assertEqual(
            person_eval._intersection_length(intervals, [(8.0, 12.0)]),
            4.0,
        )

    def test_app_override_drives_live_command_and_makes_balanced_suite_publishable(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / "positive.mov").touch()
            (root / "negative.mov").touch()
            manifest = {
                "schemaVersion": 1,
                "suite": "live adapter contract",
                "publication": {"tier": "quality", "datasetVersion": "test-v1", "holdout": True},
                "engine": {
                    "name": "fake-live",
                    "person": "Donna",
                    "command": [
                        "{app}", "-c",
                        "import json,sys; print(json.dumps({'facesDetected': 1, 'hits': int('positive' in sys.argv[1]), 'segments': [{'start': 0, 'end': 1}] if 'positive' in sys.argv[1] else []}))",
                        "{video}",
                    ],
                },
                "cases": [
                    {"id": "p", "video": "positive.mov", "expected": {"anyFace": True, "targetPerson": True}},
                    {"id": "n", "video": "negative.mov", "expected": {"anyFace": True, "targetPerson": False}},
                ],
            }
            path = root / "manifest.json"
            path.write_text(json.dumps(manifest))

            report = person_eval.evaluate(path, pathlib.Path(sys.executable))

            self.assertTrue(report["publishEligible"])
            self.assertEqual(report["resultSource"], "live-engine")
            self.assertEqual(report["score"], 100.0)
            self.assertEqual(report["datasetVersion"], "test-v1")


if __name__ == "__main__":
    unittest.main()
