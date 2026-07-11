import importlib.util
import pathlib
import sys
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
PATH = ROOT / "tools/person-eval/compare_reports.py"
SPEC = importlib.util.spec_from_file_location("compare_reports", PATH)
module = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
sys.modules[SPEC.name] = module
SPEC.loader.exec_module(module)


def report(engine, predictions, elapsed):
    return {
        "datasetVersion": "v1", "engine": engine, "score": 50,
        "identityPresence": {"f1": .5, "precision": .5, "recall": .5},
        "facePresence": {"recall": 1.0},
        "performance": {"elapsedSeconds": elapsed, "peakRSSMB": 100},
        "cases": [
            {"id": key, "video": key, "expected": {"targetPerson": expected},
             "predicted": {"targetPerson": predicted}, "bestDistance": distance}
            for key, expected, predicted, distance in predictions
        ],
    }


class CompareReportsTests(unittest.TestCase):
    def test_classifies_recovery_and_regression(self):
        baseline = report("Vision", [("p", True, False, .6), ("n", False, False, .8)], 10)
        candidate = report("ArcFace", [("p", True, True, .2), ("n", False, True, .3)], 5)
        result = module.compare(baseline, candidate)
        self.assertEqual(result["transitionCounts"]["recovered"], 1)
        self.assertEqual(result["transitionCounts"]["regressed"], 1)
        self.assertEqual(result["metrics"]["elapsedSeconds"]["delta"], -5)

    def test_rejects_different_datasets(self):
        baseline = report("A", [], 1)
        candidate = report("B", [], 1)
        candidate["datasetVersion"] = "v2"
        with self.assertRaisesRegex(ValueError, "datasetVersion"):
            module.compare(baseline, candidate)


if __name__ == "__main__":
    unittest.main()
