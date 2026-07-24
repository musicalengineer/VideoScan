import json
import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "agent-status.sh"


class AgentStatusMachineTests(unittest.TestCase):
    def run_status(self, *arguments):
        with tempfile.TemporaryDirectory() as directory:
            feed = pathlib.Path(directory) / "agent-status.jsonl"
            environment = {**os.environ, "ENGINEERING_ROOM_STATUS_FEED": str(feed)}
            result = subprocess.run(
                [str(SCRIPT), *arguments], text=True, capture_output=True,
                env=environment, check=False,
            )
            rows = [json.loads(line) for line in feed.read_text().splitlines()] if feed.exists() else []
            return result, rows

    def test_explicit_machine_is_emitted(self):
        result, rows = self.run_status(
            "codex", "testing/gauntlet", "working", "UI gauntlet",
            "building", "", "m4",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(rows[0]["machine"], "m4")

    def test_legacy_headless_caller_defaults_to_none(self):
        result, rows = self.run_status("codex", "metrics", "done", "Metrics", "green")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(rows[0]["machine"], "none")

    def test_unknown_machine_is_rejected_without_writing(self):
        result, rows = self.run_status(
            "codex", "testing", "working", "Bad route", "", "", "m2",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid machine", result.stderr)
        self.assertEqual(rows, [])


if __name__ == "__main__":
    unittest.main()
