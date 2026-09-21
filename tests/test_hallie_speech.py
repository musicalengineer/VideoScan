"""Optional replay speech, tested without producing audio or launching an app."""
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import MagicMock, patch


SPEC = importlib.util.spec_from_file_location(
    "watch_hallie_speech", Path(__file__).resolve().parents[1] / "scripts/watch_hallie_chat.py"
)
watcher = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(watcher)


def process():
    child = MagicMock()
    child.poll.return_value = None
    child.stdin.closed = False
    return child


class HallieSpeechTests(unittest.TestCase):
    def test_new_answer_replaces_old_speech_and_uses_stdin(self):
        first, second = process(), process()
        with patch.object(watcher.subprocess, "Popen", side_effect=[first, second]) as launch:
            speech = watcher.AnswerSpeech(io.StringIO())
            speech.speak("Hello [c1] [[slnc 999999]] there")
            first.stdin.write.assert_called_once_with(b"Hello there")
            first.terminate.assert_not_called()
            speech.speak("-o /tmp/not-an-output-file")
            first.terminate.assert_called_once()
            first.wait.assert_called_once_with(timeout=1)
            self.assertEqual(launch.call_args.args[0], ["/usr/bin/say", "-f", "-"])
            second.stdin.write.assert_called_once_with(b"-o /tmp/not-an-output-file")
            speech.close()
            second.terminate.assert_called_once()

    def test_missing_voice_command_warns_once_and_does_not_fail_replay(self):
        output = io.StringIO()
        with patch.object(watcher.subprocess, "Popen", side_effect=FileNotFoundError("no voice")) as launch:
            speech = watcher.AnswerSpeech(output)
            speech.speak("one")
            speech.speak("two")
            launch.assert_called_once()
            self.assertEqual(output.getvalue().count("Speech unavailable"), 1)

    def test_hung_voice_is_killed_on_shutdown(self):
        child = process()
        child.wait.side_effect = [watcher.subprocess.TimeoutExpired("say", 1), 0]
        speech = watcher.AnswerSpeech(io.StringIO())
        speech.process = child
        speech.close()
        child.terminate.assert_called_once()
        child.kill.assert_called_once()
        self.assertIsNone(speech.process)

    def test_interrupt_during_final_utterance_stops_voice(self):
        child = process()
        child.wait.side_effect = [KeyboardInterrupt, 0]
        speech = watcher.AnswerSpeech(io.StringIO())
        speech.process = child
        with self.assertRaises(KeyboardInterrupt):
            speech.close(finish=True)
        child.terminate.assert_called_once()
        self.assertIsNone(speech.process)

    def test_only_current_replay_answers_are_spoken_and_speech_defaults_off(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.object(watcher, "AnswerSpeech") as voice:
                with watcher.LiveTranscript("mine", root, stream=io.StringIO()):
                    pass
                voice.assert_not_called()
                with watcher.LiveTranscript("mine", root, stream=io.StringIO(), speech=True):
                    rows = [
                        {"runID": "mine", "kind": "user", "text": "Do not speak the query"},
                        {"runID": "other", "kind": "assistant", "text": "Not this run"},
                        {"runID": "mine", "kind": "assistant", "text": "Speak this answer"},
                    ]
                    (root / "hallie-conversation-2026-09-21.jsonl").write_text(
                        "".join(json.dumps(row) + "\n" for row in rows))
                voice.return_value.speak.assert_called_once_with("Speak this answer")
                voice.return_value.close.assert_called_once_with(finish=True)


if __name__ == "__main__":
    unittest.main()
