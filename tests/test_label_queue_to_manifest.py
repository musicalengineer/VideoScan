import importlib.util
import pathlib
import sys
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
PATH = ROOT / "tools/person-eval/label_queue_to_manifest.py"
SPEC = importlib.util.spec_from_file_location("label_queue_to_manifest", PATH)
module = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
sys.modules[SPEC.name] = module
SPEC.loader.exec_module(module)


def candidate(identifier, target, selected_set="holdout", eligible=True, warnings=None):
    return {
        "id": identifier, "video": f"/media/{identifier}.mov",
        "suggestedClass": "positive" if target else "hard-negative",
        "otherFamilyCandidates": [] if target else ["Rick"],
        "sourceGroup": f"hash:{identifier}", "context": {"date": "1991-01-01"},
        "derivedMediaReason": None, "goldenHoldoutEligible": eligible,
        "leakageWarnings": warnings or [],
        "review": {"status": "reviewed", "anyFace": True,
                   "targetPerson": target, "segments": [],
                   "reviewedBy": "Rick", "notes": None, "set": selected_set},
    }


class QueueToManifestTests(unittest.TestCase):
    def test_quality_holdout_requires_balanced_reviewed_cases(self):
        queue = {"targetPerson": "Donna", "candidates": [candidate("p", True)]}
        with self.assertRaisesRegex(ValueError, "positive and negative"):
            module.make_manifest(queue, "Vision", "/refs", "v1", "holdout", True)

    def test_quality_holdout_rejects_leakage_warning(self):
        queue = {"targetPerson": "Donna", "candidates": [
            candidate("p", True), candidate("n", False, warnings=["duplicate"]),
        ]}
        with self.assertRaisesRegex(ValueError, "leakage"):
            module.make_manifest(queue, "Vision", "/refs", "v1", "holdout", True)

    def test_balanced_clean_holdout_exports_quality_manifest(self):
        queue = {"targetPerson": "Donna", "generatedAt": "now", "candidates": [
            candidate("p", True), candidate("n", False),
        ]}
        manifest = module.make_manifest(queue, "ArcFace", "/refs", "donna-v1", "holdout", True)
        self.assertEqual(manifest["publication"]["tier"], "quality")
        self.assertTrue(manifest["publication"]["holdout"])
        self.assertEqual(manifest["datasetSummary"], {
            "cases": 2, "positives": 1, "negatives": 1, "sourceQueueGeneratedAt": "now"
        })
        self.assertIn("1990s", manifest["cases"][0]["tags"])

    def test_unreviewed_candidates_are_not_exported(self):
        unreviewed = candidate("u", False)
        unreviewed["review"]["targetPerson"] = None
        queue = {"targetPerson": "Donna", "candidates": [candidate("p", True), unreviewed]}
        manifest = module.make_manifest(queue, "Vision", "/refs", "dev-v1", None, False)
        self.assertEqual(len(manifest["cases"]), 1)


if __name__ == "__main__":
    unittest.main()
