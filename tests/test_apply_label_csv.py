import importlib.util
import pathlib
import sys
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
PATH = ROOT / "tools/person-eval/apply_label_csv.py"
SPEC = importlib.util.spec_from_file_location("apply_label_csv", PATH)
module = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
sys.modules[SPEC.name] = module
SPEC.loader.exec_module(module)


def queue():
    return {"candidates": [{"id": "a", "review": {
        "status": "needs-review", "targetPerson": None, "anyFace": None,
        "set": None, "reviewedBy": None, "notes": None,
    }}]}


class ApplyLabelCSVTests(unittest.TestCase):
    def test_applies_reviewed_negative(self):
        value = queue()
        updated = module.apply_rows(value, [{
            "id": "a", "targetPerson": "no", "anyFace": "yes",
            "set": "holdout", "reviewedBy": "Rick", "notes": "Dan only",
        }])
        self.assertEqual(updated, 1)
        self.assertEqual(value["candidates"][0]["review"]["status"], "human-reviewed")
        self.assertFalse(value["candidates"][0]["review"]["targetPerson"])

    def test_rejects_target_without_face(self):
        with self.assertRaisesRegex(ValueError, "requires anyFace"):
            module.apply_rows(queue(), [{
                "id": "a", "targetPerson": "yes", "anyFace": "no",
                "set": "", "reviewedBy": "Rick", "notes": "",
            }])

    def test_reviewer_is_required(self):
        with self.assertRaisesRegex(ValueError, "reviewedBy"):
            module.apply_rows(queue(), [{
                "id": "a", "targetPerson": "no", "anyFace": "yes",
                "set": "", "reviewedBy": "", "notes": "",
            }])


if __name__ == "__main__":
    unittest.main()
