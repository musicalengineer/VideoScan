"""The local reviewer's reply handling (2026-09-25: qwen3.8 timed out on a
40 KB diff; the wait went to 40 min and replies are capped). A cut-off reply
must be an ERROR, never a FLAGGED review."""
import importlib.util
import json
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "tools/model-fitness/review_real_commits.py"
spec = importlib.util.spec_from_file_location("review_real_commits", SCRIPT)
rrc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rrc)


def test_defaults_are_the_new_limits():
    assert rrc.DEFAULT_TIMEOUT_SECONDS == 2400.0
    assert rrc.NUM_PREDICT == 8192


def test_a_finished_answer_is_returned_without_its_thinking():
    answer, error = rrc.interpret({"done_reason": "stop",
                                   "message": {"content": "<think>hmm</think>\nNO FINDINGS"}})
    assert error is None and answer == "NO FINDINGS"


def test_a_reply_cut_at_the_cap_is_an_error_not_a_finding():
    answer, error = rrc.interpret({"done_reason": "length",
                                   "message": {"content": "<think>still reasoning about line 12"}})
    assert answer == ""
    assert error.startswith("reply cut off at the 8192-token cap")


def test_the_cut_off_error_names_the_cap_actually_used():
    _, error = rrc.interpret({"done_reason": "length", "message": {"content": ""}}, num_predict=24576)
    assert error.startswith("reply cut off at the 24576-token cap")


def test_an_empty_reply_is_an_error():
    answer, error = rrc.interpret({"done_reason": "stop", "message": {"content": "<think>x</think>"}})
    assert answer == "" and error.startswith("empty reply")


def test_ask_sends_the_reply_cap_to_ollama():
    seen = {}

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            seen["body"] = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            reply = json.dumps({"done_reason": "stop", "message": {"content": "NO FINDINGS"}}).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(reply)))
            self.end_headers()
            self.wfile.write(reply)

        def log_message(self, *args):
            pass

    server = HTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.handle_request, daemon=True).start()
    answer, _, error = rrc.ask(f"http://127.0.0.1:{server.server_port}", "m", "p", timeout=10, num_predict=123, think=False)
    server.server_close()
    assert error is None and answer == "NO FINDINGS"
    assert seen["body"]["options"]["num_predict"] == 123
    assert seen["body"]["options"]["num_ctx"] == 32768
    assert seen["body"]["think"] is False
