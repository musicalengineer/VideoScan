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
    assert rrc.NUM_PREDICT == 24576


def test_a_finished_answer_is_returned_without_its_thinking():
    answer, error = rrc.interpret({"done_reason": "stop",
                                   "message": {"content": "<think>hmm</think>\nNO FINDINGS"}})
    assert error is None and answer == "NO FINDINGS"


def test_a_reply_cut_at_the_cap_is_an_error_not_a_finding():
    answer, error = rrc.interpret({"done_reason": "length",
                                   "message": {"content": "<think>still reasoning about line 12"}})
    assert answer == ""
    assert error.startswith("reply cut off at the 24576-token cap")


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


def _diff(files):
    head = "subject\n\n body\n a.swift | 3 +\n"
    return head + "".join(f"\ndiff --git a/{n} b/{n}\n" + "+x\n" * size for n, size in files)


def test_a_small_diff_is_one_part():
    d = _diff([("a.swift", 10)])
    assert rrc.split_diff(d, limit=16_000) == [d]


def test_a_big_diff_splits_at_file_boundaries_and_keeps_the_header():
    d = _diff([("a.swift", 3000), ("b.swift", 3000), ("c.swift", 3000)])
    parts = rrc.split_diff(d, limit=10_000)
    assert len(parts) == 3
    for i, p in enumerate(parts, 1):
        assert p.startswith("subject")
        assert f"[part {i} of 3" in p
    assert "diff --git a/b.swift" in parts[1] and "a.swift b/a.swift" not in parts[1]
    # every file appears exactly once across the parts
    assert sum(p.count("diff --git ") for p in parts) == 3


def test_review_unit_error_in_any_part_makes_the_commit_unreviewed():
    d = _diff([("a.swift", 3000), ("b.swift", 3000)])
    replies = iter([("NO FINDINGS", 1.0, None), ("", 2.0, "timed out")])
    state, text, secs, error = rrc.review_unit(lambda _p: next(replies), d, limit=7000)
    assert state == "ERROR" and "timed out" in error and secs == 3.0


def test_review_unit_one_flagged_part_flags_the_commit():
    d = _diff([("a.swift", 3000), ("b.swift", 3000)])
    replies = iter([("NO FINDINGS", 1.0, None), ("Finding 1: bug", 1.0, None)])
    state, text, _, error = rrc.review_unit(lambda _p: next(replies), d, limit=7000)
    assert state == "FLAGGED" and error is None and text.startswith("[part 2/2] Finding 1")


def test_review_unit_all_quiet():
    d = _diff([("a.swift", 3000), ("b.swift", 3000)])
    state, text, _, _ = rrc.review_unit(lambda _p: ("NO FINDINGS", 1.0, None), d, limit=7000)
    assert state == "quiet" and text == "NO FINDINGS (2 parts)"


def test_an_errored_commit_keeps_the_findings_of_the_parts_that_answered():
    d = _diff([("a.swift", 3000), ("b.swift", 3000)])
    replies = iter([("", 2.0, "cut off"), ("Finding 1: bug in b", 1.0, None)])
    state, text, _, error = rrc.review_unit(lambda _p: next(replies), d, limit=7000)
    assert state == "ERROR" and error == "[part 1/2] cut off"
    assert "[part 2/2] Finding 1: bug in b" in text

# RED 2026-09-25 (night QA): nightly_review.sh reviews with qwen2.5-coder:32b,
# which ollama refuses with HTTP 400 'does not support thinking' when the
# request carries "think": true. Every unit ERRORed 9/23-9/25.
def test_a_model_without_thinking_is_still_reviewed():
    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            if body.get("think") is True:          # what ollama does for a non-thinking model
                reply = json.dumps({"error": '"qwen2.5-coder:32b" does not support thinking'}).encode()
                self.send_response(400)
            else:
                reply = json.dumps({"done_reason": "stop", "message": {"content": "NO FINDINGS"}}).encode()
                self.send_response(200)
            self.send_header("Content-Length", str(len(reply)))
            self.end_headers()
            self.wfile.write(reply)

        def log_message(self, *args):
            pass

    server = HTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        answer, _, error = rrc.ask(f"http://127.0.0.1:{server.server_port}",
                                   "qwen2.5-coder:32b", "Review this change.", 10)
    finally:
        server.shutdown()
    assert error is None, error
    assert answer == "NO FINDINGS"


def _chat_server(handler_body):
    """Tiny /api/chat stub; `handler_body(body) -> (status, payload)`. Records every request."""
    seen = []

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            seen.append(body)
            status, payload = handler_body(body)
            reply = json.dumps(payload).encode()
            self.send_response(status)
            self.send_header("Content-Length", str(len(reply)))
            self.end_headers()
            self.wfile.write(reply)

        def log_message(self, *args):
            pass

    server = HTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, seen


def test_think_is_not_sent_unless_asked_for():
    server, seen = _chat_server(lambda b: (200, {"done_reason": "stop", "message": {"content": "NO FINDINGS"}}))
    try:
        rrc.ask(f"http://127.0.0.1:{server.server_port}", "m", "p", 10)
    finally:
        server.shutdown()
    assert "think" not in seen[0]


def test_an_explicit_think_refused_with_that_400_is_retried_once_without_it():
    def reply(body):
        if "think" in body:
            return 400, {"error": '"qwen2.5-coder:32b" does not support thinking'}
        return 200, {"done_reason": "stop", "message": {"content": "NO FINDINGS"}}
    server, seen = _chat_server(reply)
    try:
        answer, _, error = rrc.ask(f"http://127.0.0.1:{server.server_port}",
                                   "qwen2.5-coder:32b", "p", 10, think=True)
    finally:
        server.shutdown()
    assert error is None and answer == "NO FINDINGS"
    assert [("think" in b) for b in seen] == [True, False]


def test_any_other_400_is_an_error_naming_ollamas_reason_and_is_not_retried():
    server, seen = _chat_server(lambda b: (400, {"error": "model 'x' not found"}))
    try:
        answer, _, error = rrc.ask(f"http://127.0.0.1:{server.server_port}", "x", "p", 10, think=True)
    finally:
        server.shutdown()
    assert answer == "" and "400" in error and "model 'x' not found" in error
    assert len(seen) == 1
