import importlib.util
import unittest
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
