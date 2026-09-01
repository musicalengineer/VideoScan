import importlib.util
import io
import json
import tempfile
import unittest
from collections import Counter
from contextlib import redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch


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
        self.assertGreaterEqual(len(turns), 23)
        self.assertEqual(len({turn["id"] for turn in turns}), len(turns))
        live = [t for t in turns if "Hudson line" in t["text"]]
        self.assertEqual(len(live), 1)
        self.assertEqual(live[0]["expectedRoutes"], ["graph", "follow-up"])
        self.assertIn("family_tree_live", live[0]["id"])

        by_id = {turn["id"]: turn for turn in turns}
        required_august_29_sensors = {
            "miss-02-owner-binding",
            "miss-06-center-spelling-recovery",
            "miss-07-complete-biography-card",
            "miss-10-fragment-guard",
            "miss-11-surname-roster",
            "miss-12-relationships-overview",
            "miss-14-pronunciation-hint",
            "miss-15-pronunciation-query",
            "miss-16-cross-world-card",
            "miss-17-freeform-pronunciation",
            "miss-18-pronunciation-precedence",
            "miss-19-kinship-word-property",
            "which_one_and_repair_2026_08_29-miss-03-year-selection-t1",
            "which_one_and_repair_2026_08_29-miss-03-year-selection-t2",
            "which_one_and_repair_2026_08_29-miss-04-conversation-repair-t1",
            "which_one_and_repair_2026_08_29-miss-04-conversation-repair-t2",
            "conversation_focus_2026_08_29-miss-09-our-common-ancestor-t1",
            "conversation_focus_2026_08_29-miss-09-our-common-ancestor-t2",
        }
        self.assertTrue(required_august_29_sensors.issubset(by_id))

        self.assertIn(
            "child(?:ren)?",
            by_id["miss-07-complete-biography-card"]["mustMatch"][0],
        )
        self.assertEqual(
            by_id["miss-11-surname-roster"]["mustNotContain"],
            ["try a fuller name"],
        )
        self.assertIn(
            "kinship",
            by_id["miss-12-relationships-overview"]["mustMatch"][0],
        )
        self.assertEqual(
            by_id["miss-16-cross-world-card"]["mustContain"],
            ["G89Q-34N", "GNZ5-428"],
        )
        self.assertIn(
            "sibling",
            by_id["miss-16-cross-world-card"]["mustMatch"][1],
        )

        # These were once route-only corpus rows: any generic answer passed.
        # Keep the live contracts tied to the concrete facts their Swift
        # regression fixtures prove, without freezing whole model sentences.
        owner = by_id["miss-02-owner-binding"]
        self.assertEqual(owner["expectedRoutes"], ["graph"])
        self.assertEqual(
            owner["mustContain"],
            ["Richard Harding Breen Jr", "Donna Hudson"],
        )
        self.assertIn("Which Rick", owner["mustNotContain"])
        self.assertIn("have no common ancestor", owner["mustNotContain"])

        center = by_id["miss-06-center-spelling-recovery"]
        self.assertEqual(center["mustContain"], ["Marhta Lamson", "Martha Lamson"])
        self.assertEqual(len(center["mustMatch"]), 2)
        self.assertIn("I cannot center", center["mustNotContain"])

        fragment = by_id["miss-10-fragment-guard"]
        self.assertIn("Edith Lucy Parker", fragment["mustContain"])
        self.assertIn("George Breen", fragment["mustContain"])
        self.assertEqual(
            fragment["mustNotContain"],
            [". ,", "Muriel was not married"],
        )

        for turn_id in (
            "miss-14-pronunciation-hint",
            "miss-15-pronunciation-query",
            "miss-17-freeform-pronunciation",
            "miss-18-pronunciation-precedence",
        ):
            turn = by_id[turn_id]
            self.assertEqual(turn["expectedRoutes"], ["telling"])
            self.assertIn("Latta", turn["mustContain"])
            self.assertTrue(turn["mustMatch"])
            self.assertIn("catalog items matching", turn["mustNotContain"])

        focus = by_id[
            "conversation_focus_2026_08_29-miss-09-our-common-ancestor-t2"
        ]
        self.assertTrue(focus["followsPrevious"])
        self.assertEqual(focus["mustContain"], ["Martha Lamson"])
        self.assertEqual(focus["mustNotContain"], ["Donna Hudson"])

        repair = by_id[
            "which_one_and_repair_2026_08_29-miss-04-conversation-repair-t2"
        ]
        self.assertTrue(repair["followsPrevious"])
        self.assertEqual(repair["expectedRoutes"], ["follow-up"])
        self.assertEqual(repair["expectedOutcome"], "repaired")

        batch = hallie_eval.build_stdin(turns).splitlines()
        complaint = "you presented me a list of people born hundreds or years ago"
        complaint_index = batch.index(complaint)
        self.assertEqual(
            batch[complaint_index - 1],
            "tell me about Nathaniel Parker",
        )

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

    def test_must_match_accepts_semantic_alternatives_case_insensitively(self):
        turns = hallie_eval.load_corpus(
            ROOT / "tests" / "hallie_live_misses_corpus.json"
        )
        by_id = {turn["id"]: turn for turn in turns}
        examples = [
            (
                "miss-07-complete-biography-card",
                "graph",
                "Matthew Rice married Martha Lamson. His SONS were Isaac Rice "
                "and Patience Rice. His GRANDPARENTS are recorded in the tree.",
            ),
            (
                "miss-12-relationships-overview",
                "capability",
                "Rick's closest KINSHIP relationships begin with his parents.",
            ),
            (
                "miss-16-cross-world-card",
                "graph",
                "The People-tab lists Tim as Rick's sibling. G89Q-34N and "
                "GNZ5-428 may be the same person and should be reviewed.",
            ),
        ]
        for turn_id, route, answer in examples:
            record = dict(by_id[turn_id])
            record.update(answer=answer, route=route, outcome="answered")
            self.assertEqual(
                hallie_eval.grade_record(record),
                [],
                msg=turn_id,
            )

    def test_live_miss_textual_fact_contracts_reject_generic_answers(self):
        turns = hallie_eval.load_corpus(
            ROOT / "tests" / "hallie_live_misses_corpus.json"
        )
        by_id = {turn["id"]: turn for turn in turns}
        clean_examples = {
            "miss-02-owner-binding": (
                "graph",
                "Richard Harding Breen Jr and Donna Hudson share 1 recorded "
                "ancestor; the nearest is Z Common.",
            ),
            "miss-06-center-spelling-recovery": (
                "graph",
                "I took Marhta Lamson to mean Martha Lamson. Centering the "
                "Family Tree on Martha Lamson.",
            ),
            "miss-10-fragment-guard": (
                "graph",
                "Muriel Lamb was the child of Edith Lucy Parker and Frederick "
                "Burton Lamb; her recorded grandparents included Clarissa "
                "Horton Schoolcraft. She married George Breen and had Richard "
                "Harding Breen Sr.",
            ),
            "miss-14-pronunciation-hint": (
                "telling",
                "OK, noted — Latta. I'll say Latta as LAT-uh (short a).",
            ),
            "miss-15-pronunciation-query": (
                "telling",
                "I say Latta as LAT-uh — you taught me that pronunciation.",
            ),
            "miss-17-freeform-pronunciation": (
                "telling",
                "OK, noted — Latta. I'll say LAT-tah (short a, then ah) and "
                "keep LAD-dah too.",
            ),
            "miss-18-pronunciation-precedence": (
                "telling",
                "OK, noted — Latta. I'll say Latta as LAT-uh (short a).",
            ),
        }

        for turn_id, (route, answer) in clean_examples.items():
            record = dict(by_id[turn_id])
            record.update(answer=answer, route=route, outcome="answered")
            self.assertEqual(
                hallie_eval.grade_record(record),
                [],
                msg=f"substantive answer rejected for {turn_id}",
            )

            generic = dict(by_id[turn_id])
            generic.update(
                answer="I found an answer for that request in the archive.",
                route=route,
                outcome="answered",
            )
            flags = hallie_eval.grade_record(generic)
            self.assertTrue(
                {"missing_required_text", "missing_required_match"} & set(flags),
                msg=f"generic answer passed {turn_id}: {flags}",
            )

    def test_live_miss_exact_known_bad_phrases_are_rejected(self):
        turns = hallie_eval.load_corpus(
            ROOT / "tests" / "hallie_live_misses_corpus.json"
        )
        by_id = {turn["id"]: turn for turn in turns}
        reversed_examples = {
            "miss-02-owner-binding": (
                "graph",
                "Richard Harding Breen Jr and Donna Hudson have no common "
                "ancestor; there is no nearest shared ancestor.",
            ),
            "miss-06-center-spelling-recovery": (
                "graph",
                "I took Marhta Lamson to mean Martha Lamson, but I cannot "
                "center the Family Tree on Martha Lamson.",
            ),
            "miss-10-fragment-guard": (
                "graph",
                "Muriel Lamb was the child of Edith Lucy Parker and Frederick "
                "Burton Lamb; her recorded grandparents included Clarissa "
                "Horton Schoolcraft. Muriel was not married to George Breen; "
                "Richard Harding Breen Sr is recorded.",
            ),
            "miss-14-pronunciation-hint": (
                "telling",
                "OK, noted — Latta. I did not keep LAT-uh (short a), and I "
                "won't say that pronunciation.",
            ),
            "miss-15-pronunciation-query": (
                "telling",
                "For Latta, I did not keep LAT-uh, and I do not pronounce it "
                "that way.",
            ),
            "miss-17-freeform-pronunciation": (
                "telling",
                "For Latta, I did not keep LAT-tah (short a, then ah) or the "
                "LAD-dah alternative.",
            ),
            "miss-18-pronunciation-precedence": (
                "telling",
                "OK, noted — Latta. I did not keep LAT-uh (short a), and I "
                "won't pronounce it that way.",
            ),
        }

        for turn_id, (route, answer) in reversed_examples.items():
            record = dict(by_id[turn_id])
            record.update(answer=answer, route=route, outcome="answered")
            self.assertEqual(
                hallie_eval.grade_record(record),
                ["forbidden_text"],
                msg=f"known bad phrase was not isolated for {turn_id}",
            )

    def test_live_miss_phrase_guards_do_not_claim_general_polarity(self):
        turns = hallie_eval.load_corpus(
            ROOT / "tests" / "hallie_live_misses_corpus.json"
        )
        by_id = {turn["id"]: turn for turn in turns}
        valid_examples = {
            "miss-02-owner-binding": (
                "graph",
                "There is no doubt Richard Harding Breen Jr and Donna Hudson "
                "share 1 recorded ancestor; the nearest is Z Common.",
            ),
            "miss-10-fragment-guard": (
                "graph",
                "Muriel Lamb was not only married to George Breen; she was "
                "the child of Edith Lucy Parker and Frederick Burton Lamb, "
                "with Clarissa Horton Schoolcraft among her grandparents, "
                "and had Richard Harding Breen Sr.",
            ),
            "miss-17-freeform-pronunciation": (
                "telling",
                "For Latta, I did not keep the old pronunciation; I kept "
                "LAT-tah (short a, then ah) and the LAD-dah alternative.",
            ),
        }
        for turn_id, (route, answer) in valid_examples.items():
            record = dict(by_id[turn_id])
            record.update(answer=answer, route=route, outcome="answered")
            self.assertEqual(
                hallie_eval.grade_record(record),
                [],
                msg=f"valid wording was rejected for {turn_id}",
            )

    def test_must_match_reports_missing_and_invalid_patterns_without_crashing(self):
        base = {
            "answer": "This answer has enough ordinary words.",
            "route": "graph",
            "outcome": "answered",
        }
        self.assertEqual(
            hallie_eval.grade_record(base | {"mustMatch": [r"\bchildren?\b"]}),
            ["missing_required_match"],
        )
        self.assertEqual(
            hallie_eval.grade_record(base | {"mustMatch": ["("]}),
            ["invalid_expected_regex"],
        )
        for malformed in (42, True, {"pattern": "family"}, [42]):
            self.assertEqual(
                hallie_eval.grade_record(base | {"mustMatch": malformed}),
                ["invalid_expected_regex"],
                msg=repr(malformed),
            )

    def test_must_match_is_inherited_and_can_be_overridden_per_turn(self):
        corpus = {
            "categories": [{
                "id": "semantic",
                "mustMatch": ["family"],
                "prompts": [
                    {"text": "inherited"},
                    {
                        "text": "overridden",
                        "mustMatch": ["tree"],
                    },
                ],
            }],
        }
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "semantic.json"
            path.write_text(json.dumps(corpus), encoding="utf-8")
            turns = hallie_eval.load_corpus(path)
        self.assertEqual(turns[0]["mustMatch"], ["family"])
        self.assertEqual(turns[1]["mustMatch"], ["tree"])

    def test_run_carries_must_match_from_corpus_into_emitted_record(self):
        question = "tell me about the family"
        semantic_contract = [r"\b(?:child(?:ren)?|sons?|daughters?)\b"]
        corpus = {
            "categories": [{
                "id": "semantic",
                "mustMatch": semantic_contract,
                "prompts": [{"id": "semantic-001", "text": question}],
            }],
        }
        logged_turns = [
            {"kind": "user", "text": question},
            {
                "kind": "assistant",
                "text": "This answer lists no descendants at all.",
                "route": "graph",
                "outcome": "answered",
            },
        ]
        shell_result = SimpleNamespace(returncode=0, stdout="", stderr="")
        git_result = SimpleNamespace(returncode=0, stdout="abc123\n", stderr="")

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            corpus_path = root / "corpus.json"
            output_path = root / "run.jsonl"
            binary_path = root / "VideoScan"
            corpus_path.write_text(json.dumps(corpus), encoding="utf-8")
            binary_path.touch()
            args = SimpleNamespace(
                corpus=str(corpus_path),
                limit=None,
                no_compose=True,
                host=None,
                model=None,
                bin=str(binary_path),
                timeout=1,
                out=str(output_path),
            )
            with redirect_stdout(io.StringIO()):
                with patch.object(
                    hallie_eval.subprocess,
                    "run",
                    side_effect=[shell_result, git_result],
                ), patch.object(
                    hallie_eval,
                    "read_run_turns",
                    return_value=logged_turns,
                ):
                    self.assertEqual(hallie_eval.run(args), 0)

            lines = output_path.read_text(encoding="utf-8").splitlines()
            self.assertEqual(len(lines), 2)
            emitted = json.loads(lines[1])

        self.assertEqual(emitted["mustMatch"], semantic_contract)
        self.assertIn(
            "missing_required_match",
            hallie_eval.grade_record(emitted),
        )

    def test_repaired_outcome_needs_substantive_content_to_count_clean(self):
        generic = {
            "id": "repair-generic",
            "category": "repair",
            "question": "you presented me a list of people born hundreds or years ago",
            "answer": "Sorry about that. Tell me what was off, and I'll look again.",
            "route": "follow-up",
            "outcome": "repaired",
            "expectedRoutes": ["follow-up"],
            "expectedOutcome": "repaired",
            "mustContain": [
                "You asked “tell me about Nathaniel Parker”",
                "Everyone I offered was born centuries ago",
                "Give me the full name, or a birth year",
            ],
            "mustNotContain": ["catalog items matching"],
        }
        self.assertEqual(
            hallie_eval.grade_record(generic),
            ["~repaired", "missing_required_text"],
        )

        substantive = dict(generic)
        substantive.update({
            "id": "repair-substantive",
            "answer": (
                "Sorry — that list was no help. "
                "You asked “tell me about Nathaniel Parker”. "
                "Everyone I offered was born centuries ago, and I have no recent "
                "person by that name. Give me the full name, or a birth year, "
                "and I'll try again."
            ),
        })
        self.assertEqual(hallie_eval.grade_record(substantive), ["~repaired"])

        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory) / "repair.jsonl"
            run.write_text(
                json.dumps({"meta": {"elapsed_s": 1, "git": "test", "binary_built": "test"}})
                + "\n" + json.dumps(generic)
                + "\n" + json.dumps(substantive) + "\n",
                encoding="utf-8",
            )
            output = io.StringIO()
            with redirect_stdout(output):
                result = hallie_eval.grade(SimpleNamespace(
                    run=str(run), compare=None, show=0))

            self.assertEqual(result, 0)
            self.assertIn("turns: 2   clean: 1 (50%)", output.getvalue())
            graded = [
                json.loads(line)
                for line in run.with_suffix(".graded.jsonl").read_text().splitlines()
            ]
            self.assertEqual(
                graded[0]["flags"],
                ["~repaired", "missing_required_text"],
            )
            self.assertEqual(graded[1]["flags"], ["~repaired"])


if __name__ == "__main__":
    unittest.main()


class PairTurnsTests(unittest.TestCase):
    """A split conjunction logs one user turn and several assistant turns
    (2026-09-01); the harness must grade the reader's question on all of
    them, not lose the second half as an unmatched turn."""

    def test_plain_turns_pair_one_to_one(self):
        turns = [
            {"kind": "user", "text": "who is Donna"},
            {"kind": "assistant", "text": "Donna is…", "outcome": "answered"},
            {"kind": "user", "text": "when was she born"},
            {"kind": "assistant", "text": "1957.", "outcome": "answered"},
        ]
        pairs = hallie_eval.pair_turns(turns)
        self.assertEqual([q for q, _ in pairs], ["who is Donna", "when was she born"])
        self.assertEqual(pairs[0][1]["outcomes"], ["answered"])

    def test_split_answers_fold_into_the_question_they_answer(self):
        turns = [
            {"kind": "user", "text": "where was Martha Lamson born and when was she born"},
            {"kind": "assistant", "text": "Ridgewell, Essex.", "outcome": "answered",
             "knowledgeEvidence": [{"id": "a"}]},
            {"kind": "assistant", "text": "Before 1633.", "outcome": "answered",
             "knowledgeEvidence": [{"id": "b"}]},
            {"kind": "user", "text": "did she have kids"},
            {"kind": "assistant", "text": "Yes.", "outcome": "answered"},
        ]
        pairs = hallie_eval.pair_turns(turns)
        self.assertEqual(len(pairs), 2)
        question, answer = pairs[0]
        self.assertEqual(question, "where was Martha Lamson born and when was she born")
        self.assertEqual(answer["text"], "Ridgewell, Essex. Before 1633.")
        self.assertEqual(answer["outcomes"], ["answered", "answered"])
        self.assertEqual([e["id"] for e in answer["knowledgeEvidence"]], ["a", "b"])
        self.assertEqual(pairs[1][0], "did she have kids")

    def test_a_declined_half_marks_the_whole_question_declined(self):
        turns = [
            {"kind": "user", "text": "who was Martha Lamson and do we have any videos of her"},
            {"kind": "assistant", "text": "Martha Lamson was…", "outcome": "answered"},
            {"kind": "assistant", "text": "I'm not sure who you mean.", "outcome": "declined"},
        ]
        (_, answer), = hallie_eval.pair_turns(turns)
        self.assertEqual(answer["outcome"], "declined")
        flags = hallie_eval.grade_record({
            "answer": answer["text"], "expect": "biography",
            "outcome": answer["outcome"], "route": "graph"})
        self.assertIn("declined_expected_answer", flags)

    def test_a_system_turn_resets_pairing_and_orphans_do_not_merge(self):
        turns = [
            {"kind": "system", "text": "session start"},
            {"kind": "assistant", "text": "Hello.", "outcome": "answered"},
            {"kind": "user", "text": "hi"},
            {"kind": "assistant", "text": "Hi.", "outcome": "answered"},
        ]
        pairs = hallie_eval.pair_turns(turns)
        self.assertEqual(len(pairs), 1)
        self.assertEqual(pairs[0][1]["text"], "Hi.")


class OrderTurnsTests(unittest.TestCase):
    """The shell writes the transcript asynchronously with whole-second
    timestamps; an answer can be filed after the next scenario's :reset
    (17 unmatched questions on 2026-09-01). Order by session, then sequence."""

    def test_an_answer_filed_after_the_next_reset_returns_to_its_session(self):
        t = "2026-09-01T23:03:03Z"
        turns = [
            {"kind": "system", "text": ":reset", "sessionID": "A", "sequence": 1, "timestamp": t},
            {"kind": "user", "text": "did you have cars", "sessionID": "A", "sequence": 2, "timestamp": t},
            {"kind": "system", "text": ":reset", "sessionID": "B", "sequence": 1, "timestamp": t},
            {"kind": "assistant", "text": "No childhood.", "sessionID": "A", "sequence": 3, "timestamp": t},
            {"kind": "user", "text": "what was school like", "sessionID": "B", "sequence": 2, "timestamp": t},
            {"kind": "assistant", "text": "No school.", "sessionID": "B", "sequence": 3, "timestamp": t},
        ]
        ordered = hallie_eval.order_turns(turns)
        self.assertEqual([e["text"] for e in ordered],
                         [":reset", "did you have cars", "No childhood.",
                          ":reset", "what was school like", "No school."])
        pairs = hallie_eval.pair_turns(ordered)
        self.assertEqual([(q, a["text"]) for q, a in pairs],
                         [("did you have cars", "No childhood."),
                          ("what was school like", "No school.")])

    def test_events_without_sequence_keep_file_order(self):
        turns = [{"kind": "user", "text": "a", "sessionID": None},
                 {"kind": "assistant", "text": "b", "sessionID": None}]
        self.assertEqual([e["text"] for e in hallie_eval.order_turns(turns)], ["a", "b"])

    def test_an_orphan_after_a_reset_never_merges_into_the_previous_question(self):
        turns = [
            {"kind": "user", "text": "who is Donna"},
            {"kind": "assistant", "text": "Donna is…", "outcome": "answered"},
            {"kind": "system", "text": ":reset"},
            {"kind": "assistant", "text": "stray", "outcome": "answered"},
        ]
        pairs = hallie_eval.pair_turns(turns)
        self.assertEqual(len(pairs), 1)
        self.assertEqual(pairs[0][1]["text"], "Donna is…")


class ConfiguredModelTests(unittest.TestCase):
    def test_falls_back_to_the_shipped_brain_when_settings_are_silent(self):
        with patch.object(hallie_eval.subprocess, "run",
                          return_value=SimpleNamespace(stdout="")):
            self.assertEqual(hallie_eval.configured_model(), hallie_eval.SHIPPED_BRAIN)
        self.assertEqual(hallie_eval.SHIPPED_BRAIN, "qwen3.8:27b-mlx")

    def test_settings_win(self):
        with patch.object(hallie_eval.subprocess, "run",
                          return_value=SimpleNamespace(stdout="qwen3.6:27b-mlx\n")):
            self.assertEqual(hallie_eval.configured_model(), "qwen3.6:27b-mlx")

    def test_floor_line_offer_is_not_a_dead_end(self):
        flags = hallie_eval.grade_record({
            "answer": "Thomasine Frost died in 1654, nearly two centuries before photography "
                      "begins in 1838 — there can’t be a photograph of her. If the family has a "
                      "painting, put it in her People folder and I’ll show it.",
            "expect": "graceful_decline", "outcome": "declined", "route": "graph"})
        self.assertNotIn("dead_end_decline", flags)
