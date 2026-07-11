import importlib.util
import pathlib
import sys
import unittest


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

    def test_markdown_surfaces_false_positive(self):
        manifest = ROOT / "tests/fixtures/person_eval/example_manifest.json"
        text = person_eval.markdown(person_eval.evaluate(manifest))
        self.assertIn("66.7/100", text)
        self.assertIn("FALSE POSITIVE", text)
        self.assertIn("Any face", text)

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


if __name__ == "__main__":
    unittest.main()
