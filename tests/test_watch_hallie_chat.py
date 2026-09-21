import importlib.util
import io
import json
import re
import tempfile
import threading
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location(
    "watch_hallie_chat", Path(__file__).resolve().parents[1] / "scripts/watch_hallie_chat.py"
)
watcher = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(watcher)


class WatchHallieChatTests(unittest.TestCase):
    def render(self, event, color):
        output = io.StringIO()
        with redirect_stdout(output):
            watcher.render(json.dumps(event), False, color=color)
        return output.getvalue()

    def test_colors_distinguish_speakers_without_changing_conversation(self):
        for kind, tint in (("user", "36"), ("assistant", "32")):
            event = {"kind": kind, "client": "cli", "text": "Hello Hallie"}
            with self.subTest(kind=kind):
                colored = self.render(event, True)
                plain = self.render(event, False)
                self.assertIn(f"\033[{tint}m", colored)
                self.assertTrue(colored.endswith("\033[0m\n"))
                self.assertEqual(re.sub(r"\x1b\[[0-9;]*m", "", colored), plain)
                self.assertNotIn("\033", plain)

    def test_warning_stays_yellow_while_answer_stays_green(self):
        colored = self.render({"kind": "assistant", "outcome": "failed", "text": "Try again"}, True)
        self.assertTrue(colored.startswith("\033[33m⚠ REVIEW \033[0m\033[32m"))

    def test_auto_respects_terminal_and_no_color_with_explicit_overrides(self):
        with patch.dict(watcher.os.environ, {}, clear=True):
            with patch.object(watcher.sys.stdout, "isatty", return_value=False):
                self.assertFalse(watcher.use_color("auto"))
                self.assertTrue(watcher.use_color("always"))
            with patch.object(watcher.sys.stdout, "isatty", return_value=True):
                self.assertTrue(watcher.use_color("auto"))
                self.assertFalse(watcher.use_color("never"))
                with patch.dict(watcher.os.environ, {"NO_COLOR": "1"}):
                    self.assertFalse(watcher.use_color("auto"))
                    self.assertTrue(watcher.use_color("always"))

    def test_live_stream_is_immediate_filtered_and_drains_rotation_and_partial_lines(self):
        class VisibleOutput(io.StringIO):
            query_visible = threading.Event()

            def write(self, text):
                result = super().write(text)
                if "live query" in text:
                    self.query_visible.set()
                return result

        def event(kind, text, run="current"):
            return json.dumps({"kind": kind, "text": text, "runID": run}) + "\n"

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / "hallie-conversation-2026-09-21.jsonl"
            log.write_text(event("user", "old history"))
            output = VisibleOutput()
            captured_stdout = io.StringIO()
            with redirect_stdout(captured_stdout), watcher.LiveTranscript("current", root, stream=output) as live:
                with log.open("a") as f:
                    f.write(event("user", "unrelated app chat", run="other"))
                    f.write(event("user", "live query"))
                    f.write(event("assistant", "I couldn't finish the partial answer")[:-1])
                self.assertTrue(output.query_visible.wait(2), "query must appear before replay finishes")
                with log.open("a") as f:
                    f.write("\n")
                (root / "hallie-conversation-2026-09-22.jsonl").write_text(event("assistant", "last answer"))
            self.assertFalse(live._thread.is_alive())
            self.assertEqual(live.review_count, 1)
            text = output.getvalue()
            self.assertNotIn("old history", text)
            self.assertNotIn("unrelated app chat", text)
            for phrase in ("live query", "partial answer", "last answer"):
                self.assertEqual(text.count(phrase), 1)
            self.assertEqual(captured_stdout.getvalue(), "")
            self.assertIn("\033[36m", text)
            self.assertIn("\033[32m", text)

    def test_live_thread_stops_when_replay_is_interrupted(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(KeyboardInterrupt):
                with watcher.LiveTranscript("interrupted", Path(directory), stream=io.StringIO()) as live:
                    raise KeyboardInterrupt
            self.assertFalse(live._thread.is_alive())


if __name__ == "__main__":
    unittest.main()
