"""Replay speech uses the app binary and its selected voice, never system say."""
import importlib.util
import io
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from contextlib import redirect_stdout
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "hallie_eval_speech", Path(__file__).resolve().parents[1] / "scripts/hallie_eval.py"
)
harness = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(harness)


class HallieSpeechTests(unittest.TestCase):
    def replay(self, speech, returncode=0):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            corpus = root / "corpus.json"
            corpus.write_text(json.dumps({"questions": [{"id": "q1", "text": "Hello Hallie"}]}))
            binary = root / "VideoScan"
            binary.touch()
            output = root / "run.jsonl"
            args = SimpleNamespace(corpus=str(corpus), limit=None, no_compose=True,
                                   host=None, model=None, bin=str(binary), timeout=5,
                                   out=str(output), live=False, speech=speech)
            turns = [{"kind": "user", "text": "Hello Hallie"},
                     {"kind": "assistant", "text": "Hello Rick", "outcome": "answered"}]
            responses = [SimpleNamespace(returncode=returncode, stdout="", stderr="unsupported option"),
                         SimpleNamespace(stdout="fixture-sha")]
            with patch.object(harness.subprocess, "run", side_effect=responses) as run, \
                    patch.object(harness, "read_run_turns", return_value=turns), \
                    patch.object(harness, "live_transcript") as viewer, \
                    redirect_stdout(io.StringIO()), patch("sys.stderr", new_callable=io.StringIO) as terminal:
                viewer.return_value.__enter__.return_value.review_count = 0
                code = harness.run(args)
                shell_call = run.call_args_list[0]
                self.assertEqual(shell_call.kwargs["env"]["VIDEOSCAN_APP_BIN"], str(binary))
                self.assertEqual(run.call_count, 2, "only Hallie's shell and git; no separate speech process")
                if speech:
                    viewer.assert_called_once()
                    self.assertIn("app voice", terminal.getvalue())
                else:
                    viewer.assert_not_called()
                meta = json.loads(output.read_text().splitlines()[0])["meta"]
                return code, shell_call.args[0], meta

    def test_speech_is_forwarded_to_the_pinned_app_and_enables_live_view(self):
        code, command, meta = self.replay(True)
        self.assertEqual(code, 0)
        self.assertIn("--speech", command)
        self.assertIn("--no-actions", command)
        self.assertEqual(meta["paired"], 1)

    def test_default_replay_remains_silent(self):
        code, command, _ = self.replay(False)
        self.assertEqual(code, 0)
        self.assertNotIn("--speech", command)

    def test_old_binary_rejection_is_a_failed_run_not_a_voice_fallback(self):
        code, _, meta = self.replay(True, returncode=64)
        self.assertEqual(code, 2)
        self.assertEqual(meta["processReturnCode"], 64)


if __name__ == "__main__":
    unittest.main()
