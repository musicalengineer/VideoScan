import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / "scripts" / "hallie_question_testbed.py"


def _log(tmp_path, questions):
    path = tmp_path / "hallie-conversation-2026-08-18.jsonl"
    events = []
    for i, question in enumerate(questions, 1):
        sid = "session"
        events.append({"kind": "user", "sessionID": sid, "sequence": i * 2, "text": question})
        events.append({"kind": "assistant", "sessionID": sid, "outcome": "answered",
                       "route": "presence", "queryDescription": "shape=presence",
                       "text": "Here is the answer", "mediaEvidence": [],
                       "knowledgeEvidence": [], "offeredActions": []})
    path.write_text("\n".join(json.dumps(e) for e in events) + "\n", encoding="utf-8")
    return path


class HallieQuestionTestbedTests(unittest.TestCase):
    def test_extract_creates_one_case_per_user_turn(self):
        with tempfile.TemporaryDirectory() as directory:
            tmp_path = Path(directory)
            log = _log(tmp_path, ["Find Donna", "Find Tim", "Find Donna"])
            out = tmp_path / "manifest.json"
            subprocess.run([sys.executable, str(TOOL), "extract", str(log), "-o", str(out)], check=True)
            manifest = json.loads(out.read_text())
            self.assertEqual(manifest["schemaVersion"], 1)
            self.assertEqual([c["question"] for c in manifest["cases"]], ["Find Donna", "Find Tim", "Find Donna"])
            self.assertEqual(len({c["id"] for c in manifest["cases"]}), 3)


    def test_grade_reports_missing_response_and_per_case_scores(self):
        with tempfile.TemporaryDirectory() as directory:
            tmp_path = Path(directory)
            reference_log = _log(tmp_path, ["Find Donna", "Find Tim"])
            manifest_path = tmp_path / "manifest.json"
            subprocess.run([sys.executable, str(TOOL), "extract", str(reference_log), "-o", str(manifest_path)], check=True)
            # A replay with one matching answer and one omitted question.
            actual_log = _log(tmp_path, ["Find Donna"])
            report = subprocess.check_output([sys.executable, str(TOOL), "grade", str(manifest_path), str(actual_log)])
            result = json.loads(report)
            self.assertEqual(result["summary"]["count"], 2)
            self.assertEqual(result["cases"][0]["score"], 100.0)
            self.assertEqual(result["cases"][1]["checks"], {"responsePresent": False})
