import importlib.util
import json
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location(
    "hallie_harvest_queries", ROOT / "scripts" / "hallie_harvest_queries.py")
harvest = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(harvest)


def turn(text, session="s1", ts="2026-09-01T20:00:00Z"):
    return {"client": "app", "kind": "user", "text": text, "sessionID": session, "timestamp": ts}


class HarvestTests(unittest.TestCase):
    def test_questions_are_kept_and_statements_skipped_by_default(self):
        turns = [turn("who is rick's brother?"), turn("Ellen is my sister. Tim is my brother."),
                 turn("where was martha lamson born")]
        out = harvest.harvest(turns, existing=set(), stamp="2026-09-01")
        self.assertEqual([e["text"] for e in out],
                         ["who is rick's brother?", "where was martha lamson born"])
        self.assertTrue(all(e["category"] == "live" for e in out))
        self.assertIn("unconfirmed", out[0]["notes"])

    def test_existing_corpus_text_and_pronunciation_turns_are_dropped(self):
        turns = [turn("Who is Donna"), turn("say latta"), turn("let me rate the pronunciations of latta")]
        out = harvest.harvest(turns, existing={"who is donna"}, stamp="2026-09-01")
        self.assertEqual(out, [])

    def test_follow_up_in_the_same_session_is_marked(self):
        turns = [turn("who was martha lampson"), turn("who did she marry?"),
                 turn("when was matt born?", session="s2")]
        out = harvest.harvest(turns, existing=set(), stamp="2026-09-02")
        self.assertNotIn("followsPrevious", out[0])
        self.assertTrue(out[1]["followsPrevious"])
        self.assertNotIn("followsPrevious", out[2])
        self.assertEqual(out[0]["id"], "lv260902-001")

    def test_expectation_guesses(self):
        self.assertEqual(harvest.guess_expect("how are you today hallie?"), "social")
        self.assertEqual(harvest.guess_expect("show me videos of Donna down the Cape"), "catalog")
        self.assertEqual(harvest.guess_expect("who are rick's brothers?"), "kinship")
        self.assertEqual(harvest.guess_expect("tell me about peter ronan"), "biography")
        self.assertEqual(harvest.guess_expect("how many videos in the archive now?"), "catalog")

    def test_sibling_corpora_texts_count_as_already_harvested(self):
        with tempfile.TemporaryDirectory() as tmp:
            corpus = Path(tmp) / "hallie_eval_corpus.json"
            corpus.write_text(json.dumps({"description": "1 questions", "questions": [
                {"id": "a1", "text": "who is donna", "expect": "biography"}]}, indent=2) + "\n")
            (Path(tmp) / "hallie_strict_regressions.json").write_text(json.dumps({"categories": [
                {"id": "c", "prompts": ["what country was John Hastings born in?", {"text": "tell me about dad"}],
                 "sessions": [{"id": "s", "turns": ["who is tim", {"text": "and his brother?"}]}]}]}))
            self.assertEqual(harvest.sibling_texts(corpus), {
                "what country was john hastings born in?", "tell me about dad",
                "who is tim", "and his brother?"})
            turns = [turn("who is tim"), turn("tell me about DAD"), turn("who is beth?")]
            with patch.object(harvest, "read_turns", return_value=turns):
                harvest.main(["--since", "2026-09-01", "--corpus", str(corpus), "--append"])
            written = json.loads(corpus.read_text())
            self.assertEqual([q["text"] for q in written["questions"]], ["who is donna", "who is beth?"])
            self.assertEqual(written["description"], "2 questions")

    def test_append_keeps_the_indent_the_file_already_uses(self):
        for indent in (1, 2):
            with tempfile.TemporaryDirectory() as tmp:
                corpus = Path(tmp) / "hallie_eval_corpus.json"
                body = {"description": "1 questions", "questions": [
                    {"id": "a1", "text": "who is donna", "expect": "biography"}]}
                before = json.dumps(body, indent=indent, ensure_ascii=False) + "\n"
                corpus.write_text(before)
                self.assertEqual(harvest.detect_indent(before), indent)
                with patch.object(harvest, "read_turns", return_value=[turn("who is beth?")]):
                    harvest.main(["--since", "2026-09-01", "--corpus", str(corpus), "--append"])
                after = corpus.read_text()
                # Every original line survives untouched (the last row only
                # gains a comma); only rows were added.
                before_lines, after_lines = before.splitlines(), after.splitlines()
                self.assertIn('"2 questions"', after_lines[1])  # the count line is the one change
                self.assertEqual(after_lines[2:len(before_lines) - 3], before_lines[2:-3], indent)
                self.assertEqual(harvest.detect_indent(after), indent)
                self.assertEqual(json.loads(after)["questions"][-1]["text"], "who is beth?")
