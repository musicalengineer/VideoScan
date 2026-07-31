import copy
import importlib.util
import sys
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).parents[1] / "tools/person-eval/grade_paired_presence_report.py"
SPEC = importlib.util.spec_from_file_location("paired_grader", MODULE_PATH)
grader = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
sys.modules[SPEC.name] = grader
SPEC.loader.exec_module(grader)

H = "a" * 64


def report():
    identities = {
        "control": {"commit": "fbb8e6a", "binarySHA256": H, "configSHA256": "b" * 64},
        "candidate": {"commit": "c9d16c6", "binarySHA256": "c" * 64, "configSHA256": "d" * 64, "modelSHA256": "e" * 64},
    }
    fingerprints = {"corpusSHA256": "f" * 64, "referencesSHA256": "1" * 64}
    # Control has one FP. Candidate fixes it in both repeats with unchanged recall.
    cases = [
        ("p1", True, "confirmed", "confirmed"),
        ("p2", True, "confirmed", "confirmed"),
        ("n1", False, "confirmed", "none"),
        ("n2", False, "none", "none"),
    ]
    rounds = []
    for order in (["control", "candidate"], ["candidate", "control"]):
        rounds.append({
            "order": order, "identities": copy.deepcopy(identities),
            "fingerprints": copy.deepcopy(fingerprints),
            "cases": [{
                "caseId": case_id, "expected": expected,
                "results": {
                    "control": {"exitCode": 0, "schemaVersion": 2, "presence": control},
                    "candidate": {"exitCode": 0, "schemaVersion": 2, "presence": candidate},
                },
            } for case_id, expected, control, candidate in cases],
        })
    return {"schemaVersion": 2, "identities": identities, "fingerprints": fingerprints, "rounds": rounds}


class PairedGraderTests(unittest.TestCase):
    def test_passes_only_strict_repeatable_improvement(self):
        result = grader.grade_report(report())
        self.assertEqual(result["verdict"], "pass")
        self.assertEqual(result["gates"], {"accuracy": True, "safety": True, "stability": True})

    def test_tie_fails_accuracy_gate(self):
        value = report()
        for round_ in value["rounds"]:
            round_["cases"][2]["results"]["candidate"]["presence"] = "confirmed"
        result = grader.grade_report(value)
        self.assertEqual(result["verdict"], "fail")
        self.assertFalse(result["gates"]["accuracy"])

    def test_recall_regression_fails_safety_gate(self):
        value = report()
        for round_ in value["rounds"]:
            round_["cases"][0]["results"]["candidate"]["presence"] = "none"
        result = grader.grade_report(value)
        self.assertEqual(result["verdict"], "fail")
        self.assertFalse(result["gates"]["safety"])
        self.assertEqual(result["falseNegativeChanges"][0]["newFalseNegatives"], ["p1"])

    def test_candidate_flip_fails_stability_gate(self):
        value = report()
        value["rounds"][1]["cases"][2]["results"]["candidate"]["presence"] = "confirmed"
        result = grader.grade_report(value)
        self.assertEqual(result["verdict"], "fail")
        self.assertFalse(result["gates"]["stability"])
        self.assertEqual(result["predictionFlips"]["candidate"], ["n1"])

    def test_control_flip_also_fails_stability_gate(self):
        value = report()
        value["rounds"][1]["cases"][2]["results"]["control"]["presence"] = "none"
        result = grader.grade_report(value)
        self.assertEqual(result["verdict"], "fail")
        self.assertFalse(result["gates"]["stability"])
        self.assertEqual(result["predictionFlips"]["control"], ["n1"])

    def test_absolute_false_negatives_are_disclosed_even_when_shared(self):
        value = report()
        for round_ in value["rounds"]:
            for arm in ("control", "candidate"):
                round_["cases"][0]["results"][arm]["presence"] = "none"
        result = grader.grade_report(value)
        self.assertEqual(result["falseNegativeChanges"][0]["controlFalseNegatives"], ["p1"])
        self.assertEqual(result["falseNegativeChanges"][0]["candidateFalseNegatives"], ["p1"])
        self.assertEqual(result["falseNegativeChanges"][0]["newFalseNegatives"], [])

    def test_fail_closed_contract_errors(self):
        mutations = []
        invalid_presence = report(); invalid_presence["rounds"][0]["cases"][0]["results"]["control"]["presence"] = "likely"; mutations.append(invalid_presence)
        bad_exit = report(); bad_exit["rounds"][0]["cases"][0]["results"]["candidate"]["exitCode"] = 1; mutations.append(bad_exit)
        drift = report(); drift["rounds"][1]["fingerprints"]["corpusSHA256"] = "9" * 64; mutations.append(drift)
        duplicate = report(); duplicate["rounds"][0]["cases"].append(copy.deepcopy(duplicate["rounds"][0]["cases"][0])); mutations.append(duplicate)
        missing = report(); missing["rounds"][1]["cases"].pop(); mutations.append(missing)
        wrong_order = report(); wrong_order["rounds"][1]["order"] = ["control", "candidate"]; mutations.append(wrong_order)
        unknown_root = report(); unknown_root["ignored"] = True; mutations.append(unknown_root)
        unknown_round = report(); unknown_round["rounds"][0]["ignored"] = True; mutations.append(unknown_round)
        unknown_case = report(); unknown_case["rounds"][0]["cases"][0]["ignored"] = True; mutations.append(unknown_case)
        unknown_result = report(); unknown_result["rounds"][0]["cases"][0]["results"]["control"]["ignored"] = True; mutations.append(unknown_result)
        unknown_identity = report(); unknown_identity["identities"]["control"]["ignored"] = H; mutations.append(unknown_identity)
        float_schema = report(); float_schema["schemaVersion"] = 2.0; mutations.append(float_schema)
        bool_exit = report(); bool_exit["rounds"][0]["cases"][0]["results"]["control"]["exitCode"] = False; mutations.append(bool_exit)
        object_presence = report(); object_presence["rounds"][0]["cases"][0]["results"]["control"]["presence"] = []; mutations.append(object_presence)
        label_drift = report(); label_drift["rounds"][1]["cases"][0]["expected"] = False; mutations.append(label_drift)
        one_class = report();
        for round_ in one_class["rounds"]:
            for case in round_["cases"]: case["expected"] = True
        mutations.append(one_class)
        same_binary = report();
        same_binary["identities"]["candidate"]["binarySHA256"] = same_binary["identities"]["control"]["binarySHA256"]
        for round_ in same_binary["rounds"]: round_["identities"] = copy.deepcopy(same_binary["identities"])
        mutations.append(same_binary)
        same_config = report();
        same_config["identities"]["candidate"]["configSHA256"] = same_config["identities"]["control"]["configSHA256"]
        for round_ in same_config["rounds"]: round_["identities"] = copy.deepcopy(same_config["identities"])
        mutations.append(same_config)
        for value in mutations:
            with self.subTest(value=value):
                with self.assertRaises(grader.GradeError):
                    grader.grade_report(value)


if __name__ == "__main__":
    unittest.main()
