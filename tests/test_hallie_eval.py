import importlib.util
import unittest
from collections import Counter
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "hallie_eval", ROOT / "scripts" / "hallie_eval.py"
)
hallie_eval = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(hallie_eval)


class HallieEvalTests(unittest.TestCase):
    def test_canonical_corpus_expands_to_exact_balanced_200_turns(self):
        turns = hallie_eval.load_corpus(
            ROOT / "tests" / "hallie_interaction_corpus.json"
        )
        self.assertEqual(len(turns), 200)
        self.assertEqual(len({turn["id"] for turn in turns}), 200)
        self.assertEqual(Counter(turn["category"] for turn in turns), {
        "smalltalk": 24,
        "general_english": 20,
        "persona_past": 24,
        "catalog": 44,
        "family_tree": 28,
        "biography": 24,
        "continuity": 28,
        "safety": 8,
        })


    def test_live_misses_lane_loads_with_the_interaction_schema(self):
        # A second, growing corpus for pinned live misses; the fixed
        # 200-turn corpus above is never edited for these.
        turns = hallie_eval.load_corpus(
            ROOT / "tests" / "hallie_live_misses_corpus.json"
        )
        self.assertGreaterEqual(len(turns), 1)
        self.assertEqual(len({turn["id"] for turn in turns}), len(turns))
        live = [t for t in turns if "Hudson line" in t["text"]]
        self.assertEqual(len(live), 1)
        self.assertEqual(live[0]["expectedRoutes"], ["graph", "follow-up"])
        self.assertIn("family_tree_live", live[0]["id"])

    def test_batch_input_resets_between_scenarios_but_not_followup_turns(self):
        turns = hallie_eval.load_corpus(
            ROOT / "tests" / "hallie_interaction_corpus.json"
        )
        batch = hallie_eval.build_stdin(turns).splitlines()
        self.assertEqual(batch.count(":reset"), 179)
        self.assertEqual(batch[-1], ":quit")
        chain = batch[batch.index("Tell me about Hallie May.") :]
        self.assertEqual(chain[:4], [
        "Tell me about Hallie May.",
        "Who was her father?",
        "Who was his father?",
        "Where was he born?",
        ])


    def test_grade_detects_personal_memory_and_internal_error_hard_failures(self):
        base = {
        "answer": "I remember riding in my father's car. The Ollama endpoint failed.",
        "route": "conversation",
        "outcome": "answered",
        "noFabricatedPersonalMemory": True,
        "forbidRawInternals": True,
        }
        flags = hallie_eval.grade_record(base)
        self.assertIn("fabricated_personal_memory", flags)
        self.assertIn("raw_internal_error", flags)


    def test_grade_detects_cross_turn_filename_leakage(self):
        record = {
        "answer": "I found old-answer.mov and current.mov.",
        "route": "presence",
        "outcome": "answered",
        "currentEvidenceOnly": True,
        "mediaEvidence": [{"filename": "current.mov"}],
        }
        self.assertIn(
            "named_item_not_in_current_evidence",
            hallie_eval.grade_record(record),
        )


    def test_grade_detects_m2ts_filename_leakage(self):
        record = {
        "answer": "I found Cape_trip.m2ts.",
        "route": "presence",
        "outcome": "answered",
        "currentEvidenceOnly": True,
        "mediaEvidence": [{"filename": "Cape_trip_full.m2ts"}],
        }
        self.assertIn(
            "named_item_not_in_current_evidence",
            hallie_eval.grade_record(record),
        )


    def test_evidence_filename_with_spaces_is_not_split_into_a_false_leak(self):
        record = {
            "answer": "The first item is Clip 01.dv and MyGirl (fcp1).mov.",
            "route": "presence",
            "outcome": "answered",
            "currentEvidenceOnly": True,
            "mediaEvidence": [
                {"filename": "Clip 01.dv"},
                {"filename": "MyGirl (fcp1).mov"},
            ],
        }
        self.assertNotIn(
            "named_item_not_in_current_evidence",
            hallie_eval.grade_record(record),
        )


    def test_safe_persona_boundary_is_not_mistaken_for_a_memory_claim(self):
        record = {
        "answer": (
            "I don't have personal memories or a childhood of my own. "
            "I shouldn't pretend those memories are mine."
        ),
        "route": "conversation",
        "outcome": "answered",
        "expectedRoutes": ["conversation"],
        "expectedOutcome": "answered",
        "noFabricatedPersonalMemory": True,
        }
        self.assertEqual(hallie_eval.grade_record(record), [])


    def test_complete_sentence_starting_with_an_article_is_not_a_fragment(self):
        flags = hallie_eval.grade_record({
            "answer": "The sky appears blue because shorter wavelengths scatter.",
            "route": "conversation",
            "outcome": "answered",
        })
        self.assertNotIn("fragment", flags)


if __name__ == "__main__":
    unittest.main()
