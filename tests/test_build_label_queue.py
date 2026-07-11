import importlib.util
import pathlib
import sys
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "tools/person-eval/build_label_queue.py"
SPEC = importlib.util.spec_from_file_location("build_label_queue", MODULE_PATH)
module = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
sys.modules[SPEC.name] = module
SPEC.loader.exec_module(module)


class BuildLabelQueueTests(unittest.TestCase):
    def test_human_confirmed_target_is_positive_candidate(self):
        record = {
            "fullPath": "/media/raw-birthday.mov",
            "durationSeconds": 30,
            "confirmedByUserPeople": [{"name": "Donna"}],
            "partialMD5": "abc",
        }
        queue = module.make_queue(
            [record], "Donna", {"Donna", "Rick"}, 10, 10, 300,
            path_exists=lambda _: True,
        )
        item = queue["candidates"][0]
        self.assertEqual(item["suggestedClass"], "positive")
        self.assertTrue(item["goldenHoldoutEligible"])
        self.assertEqual(item["sourceGroup"], "hash:abc")
        self.assertEqual(item["review"]["status"], "imported-catalog-confirmation")
        self.assertTrue(item["review"]["targetPerson"])

    def test_other_family_detection_is_only_a_hard_negative_suggestion(self):
        record = {
            "fullPath": "/media/rick.mov",
            "durationSeconds": 20,
            "detectedPeople": ["Rick"],
        }
        queue = module.make_queue(
            [record], "Donna", {"Donna", "Rick"}, 10, 10, 300,
            path_exists=lambda _: True,
        )
        item = queue["candidates"][0]
        self.assertEqual(item["suggestedClass"], "hard-negative")
        self.assertIn("NOT confirmed", item["suggestionEvidence"])
        self.assertIsNone(item["review"]["targetPerson"])

    def test_derived_and_long_media_are_not_holdout_eligible(self):
        records = [
            {"fullPath": "/media/Donna_compilation.mov", "durationSeconds": 10,
             "confirmedByUserPeople": [{"name": "Donna"}]},
            {"fullPath": "/media/raw.mov", "durationSeconds": 301,
             "confirmedByUserPeople": [{"name": "Donna"}]},
        ]
        queue = module.make_queue(
            records, "Donna", {"Donna"}, 10, 10, 300,
            path_exists=lambda _: True,
        )
        self.assertTrue(all(not x["goldenHoldoutEligible"] for x in queue["candidates"]))

    def test_source_group_normalizes_derived_name_variants(self):
        first = module._source_group({"fullPath": "/a/Donna_Clip_03_converted.mov"})
        second = module._source_group({"fullPath": "/b/Donna03.mov"})
        self.assertEqual(first, second)

    def test_timestamped_extract_is_not_holdout_eligible(self):
        record = {
            "fullPath": "/media/Donna_source_00h09m23s_022.mov",
            "durationSeconds": 17,
            "confirmedByUserPeople": [{"name": "Donna"}],
        }
        queue = module.make_queue(
            [record], "Donna", {"Donna"}, 10, 10, 300,
            path_exists=lambda _: True,
        )
        item = queue["candidates"][0]
        self.assertFalse(item["goldenHoldoutEligible"])
        self.assertIn("timestamp", item["derivedMediaReason"])

    def test_same_source_in_positive_and_negative_suggestions_is_flagged(self):
        records = [
            {"fullPath": "/a/source.mov", "durationSeconds": 20, "partialMD5": "same",
             "confirmedByUserPeople": [{"name": "Donna"}]},
            {"fullPath": "/b/copy.mov", "durationSeconds": 20, "partialMD5": "same",
             "detectedPeople": ["Rick"]},
        ]
        queue = module.make_queue(
            records, "Donna", {"Donna", "Rick"}, 10, 10, 300,
            path_exists=lambda _: True,
        )
        self.assertEqual(queue["counts"]["crossLabelConflicts"], 2)
        self.assertTrue(all(not x["goldenHoldoutEligible"] for x in queue["candidates"]))
        self.assertTrue(all(x["leakageWarnings"] for x in queue["candidates"]))


if __name__ == "__main__":
    unittest.main()
