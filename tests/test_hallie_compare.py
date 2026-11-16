"""scripts/hallie_compare.py — one corpus on several Hallie brains, side by side.

No model, no network, no app binary: the per-brain replay and the Ollama tag
list are injected, and the table is built from run files written here.

  logic      brain parsing, the eval command per brain, the cloud refusal,
             the skipped-model row, the measured row, the rendered table
  truth      the table's counts are re-derived from the records by the same
             grader the nightly uses; an incomplete run says INCOMPLETE
  isolation  garbage run files, a missing run, an empty folder
  scale      100,000 records measured inside a budget
"""

import argparse
import importlib.util
import io
import json
import sys
import tempfile
import time
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


compare = load("hallie_compare")
hallie_eval = load("hallie_eval")


def record(qid, route="graph", outcome="answered", composed="model", ms=1000, **extra):
    base = {"id": qid, "question": f"question {qid}", "answer": f"Here is the answer on file for {qid}.",
            "route": route, "outcome": outcome, "composedBy": composed, "latencyMs": ms}
    base.update(extra)
    return base


def write_run(directory, label, records, questions=None, **brain):
    name = compare.slug(label) + ".jsonl"
    meta = {"questions": len(records) if questions is None else questions,
            "git": "abc1234", "binary_built": "2026-11-15T18:00:00", "when": "2026-11-15T19:00:00",
            "elapsed_s": 12, "corpusSHA256": "f" * 64}
    (Path(directory) / name).write_text(
        "\n".join(json.dumps(row) for row in [{"meta": meta}] + records) + "\n")
    (Path(directory) / (compare.slug(label) + ".brain.json")).write_text(
        json.dumps(dict({"label": label, "run": name}, **brain)) + "\n")


def run_args(directory, **overrides):
    values = dict(brains="alpha:1b", corpus="corpus.json", limit=None, out_dir=str(directory),
                  host=None, bin=None, gedcom=None, timeout=60, allow_cloud=False,
                  keep_loaded=False)
    values.update(overrides)
    return SimpleNamespace(**values)


class BrainParsingTests(unittest.TestCase):
    def test_local_tags_and_cloud_models_keep_their_order(self):
        brains = compare.parse_brains(" qwen3.8:27b-mlx , cloud:claude-sonnet-5-5,llama3.3:70b ")
        self.assertEqual([b["label"] for b in brains],
                         ["qwen3.8:27b-mlx", "Cloud · claude-sonnet-5-5", "llama3.3:70b"])
        self.assertEqual([b["kind"] for b in brains], ["local", "cloud", "local"])
        self.assertEqual(brains[1]["model"], "claude-sonnet-5-5")

    def test_empty_duplicate_and_modelless_cloud_are_refused(self):
        for text in ["", " , ", "a,a", "cloud:", "cloud:x,cloud:x"]:
            with self.assertRaises(ValueError, msg=text):
                compare.parse_brains(text)

    def test_a_local_brain_gets_model_and_host_a_cloud_brain_gets_cloud_model_only(self):
        args = run_args("out", host="http://h:1", limit=5, bin="/b/VideoScan")
        local = compare.eval_command({"kind": "local", "model": "m:1"}, args, Path("o.jsonl"))
        self.assertEqual(local[local.index("--model") + 1], "m:1")
        self.assertEqual(local[local.index("--host") + 1], "http://h:1")
        self.assertEqual(local[local.index("--limit") + 1], "5")
        self.assertEqual(local[local.index("--bin") + 1], "/b/VideoScan")
        self.assertNotIn("--cloud-model", local)
        cloud = compare.eval_command({"kind": "cloud", "model": "claude-x"}, args, Path("o.jsonl"))
        self.assertEqual(cloud[cloud.index("--cloud-model") + 1], "claude-x")
        self.assertNotIn("--model", cloud)
        self.assertNotIn("--host", cloud)

    def test_the_eval_harness_accepts_what_the_command_passes(self):
        text = (ROOT / "scripts/hallie_eval.py").read_text()
        self.assertIn('"--cloud-model"', text)
        self.assertIn('cmd += ["--cloud-model", cloud_model]', text)


class RunTests(unittest.TestCase):
    def test_a_cloud_brain_is_refused_without_allow_cloud_and_nothing_runs(self):
        with tempfile.TemporaryDirectory() as directory:
            said, calls = [], []
            code = compare.run(run_args(directory, brains="alpha:1b,cloud:claude-x"),
                               tags=lambda host: ["alpha:1b"],
                               call=lambda *a, **k: calls.append(a) or SimpleNamespace(returncode=0),
                               say=said.append)
            self.assertEqual(code, 2)
            self.assertEqual(calls, [])
            self.assertIn("Anthropic", said[0])
            self.assertIn("Cloud · claude-x", said[0])
            self.assertEqual(list(Path(directory).glob("*.jsonl")), [])

    def test_brains_run_one_after_another_and_a_missing_model_is_a_named_row(self):
        with tempfile.TemporaryDirectory() as directory:
            said, calls, released = [], [], []

            def call(cmd, **kwargs):
                calls.append(cmd)
                out = Path(cmd[cmd.index("--out") + 1])
                out.write_text(json.dumps({"meta": {"questions": 1}}) + "\n"
                               + json.dumps(record("q1")) + "\n")
                return SimpleNamespace(returncode=0)

            code = compare.run(
                run_args(directory, brains="alpha:1b,missing:2b,cloud:claude-x", allow_cloud=True),
                tags=lambda host: ["alpha:1b"], call=call, say=said.append,
                release=lambda host, model: released.append((host, model)))
            self.assertEqual(released, [("http://127.0.0.1:11434", "alpha:1b")])   # local only, after its run
            self.assertEqual(code, 2)                      # one brain was skipped
            self.assertEqual(len(calls), 2)
            self.assertIn("--model", calls[0])
            self.assertIn("--cloud-model", calls[1])
            text = (Path(directory) / "table.md").read_text()
            self.assertIn("| missing:2b | not run: http://127.0.0.1:11434 does not have this model |", text)
            self.assertIn("| alpha:1b | 1 | 1 of 1 (100%) |", text)
            self.assertIn("| Cloud · claude-x | 1 | 1 of 1 (100%) |", text)
            self.assertTrue(any(line.startswith("START alpha:1b") for line in said))
            self.assertTrue(any(line.startswith("OUTCOME Cloud · claude-x complete") for line in said))

    def test_an_ollama_that_does_not_answer_skips_local_brains_and_says_so(self):
        with tempfile.TemporaryDirectory() as directory:
            said = []
            code = compare.run(run_args(directory), tags=lambda host: None,
                               call=lambda *a, **k: self.fail("must not run"), say=said.append)
            self.assertEqual(code, 2)
            self.assertIn("SKIPPED alpha:1b: http://127.0.0.1:11434 did not answer", said)

    def test_an_incomplete_replay_is_reported_and_fails_the_run(self):
        with tempfile.TemporaryDirectory() as directory:
            said = []

            def call(cmd, **kwargs):
                Path(cmd[cmd.index("--out") + 1]).write_text(
                    json.dumps({"meta": {"questions": 3}}) + "\n" + json.dumps(record("q1")) + "\n")
                return SimpleNamespace(returncode=2)

            released = []
            code = compare.run(run_args(directory, keep_loaded=True), tags=lambda host: ["alpha:1b"],
                               call=call, say=said.append,
                               release=lambda host, model: released.append(model))
            self.assertEqual(released, [])                 # --keep-loaded
            self.assertEqual(code, 2)
            self.assertTrue(any("INCOMPLETE (exit 2)" in line for line in said))
            self.assertIn("3 (1 answered — INCOMPLETE)", (Path(directory) / "table.md").read_text())


class MeasureTests(unittest.TestCase):
    def measured(self, records):
        return compare.measure(records, hallie_eval.grade_record, hallie_eval.latency_summary)

    def test_counts_match_the_nightly_grader_record_by_record(self):
        records = [
            record("t1", route="graph", expectedRoutes=["graph"]),
            record("t2", route="presence", expectedRoutes=["graph"]),          # misrouted: a defect
            record("c1", route="presence", composed="template", ms=3000),
            record("c2", route="aggregate", outcome="declined", composed=None, ms=5000,
                   answer="I couldn't find any of those, but want me to try a different year?"),
            record("s1", route="smalltalk", composed="model", ms=200),
            record("x1", route=None, outcome=None, composed=None, ms=None),
        ]
        row = self.measured(records)
        expected_clean = sum(
            1 for r in records
            if not [f for f in hallie_eval.grade_record(r) if not f.startswith("~")])
        self.assertEqual(row["turns"], 6)
        self.assertEqual(row["clean"], expected_clean)
        self.assertIn("t2", row["defect_ids"])
        self.assertEqual(row["sides"]["tree"]["n"], 2)        # by the EXPECTED route
        self.assertEqual(row["sides"]["tree"]["clean"], 1)
        self.assertEqual(row["sides"]["catalog"]["n"], 2)
        self.assertEqual(row["sides"]["talk"]["n"], 1)
        self.assertEqual(row["declined"], 1)
        self.assertEqual(row["failed"], 1)
        self.assertEqual((row["by_model"], row["composable"]), (3, 4))
        self.assertEqual(row["latency"]["n"], 5)
        self.assertEqual(row["latency"]["median_ms"], 1000)

    def test_no_records_measures_to_zeros_not_a_crash(self):
        row = self.measured([])
        self.assertEqual((row["turns"], row["clean"], row["latency"]["n"]), (0, 0, 0))
        self.assertEqual(compare.pct(0, 0), "—")
        self.assertEqual(compare.seconds(None), "—")

    def test_a_hundred_thousand_records_measure_inside_the_budget(self):
        records = [record(f"q{i}", route=("graph", "presence", "smalltalk")[i % 3], ms=i % 9000)
                   for i in range(100_000)]
        t0 = time.perf_counter()
        row = self.measured(records)
        elapsed = time.perf_counter() - t0
        self.assertEqual(row["turns"], 100_000)
        self.assertLess(elapsed, 60, f"100k records took {elapsed:.1f} s")


class TableTests(unittest.TestCase):
    def table(self, directory):
        said = []
        code = compare.table(argparse.Namespace(dir=str(directory)), say=said.append)
        return code, (Path(directory) / "table.md"), (Path(directory) / "answers.md"), said

    def test_two_brains_one_table_and_every_answer_under_its_question(self):
        with tempfile.TemporaryDirectory() as directory:
            write_run(directory, "alpha:1b", [
                record("q1", ms=2000), record("q2", route="presence", composed="template", ms=4000)])
            time.sleep(0.01)
            write_run(directory, "Cloud · claude-x", [
                record("q1", ms=900, answer="She was born in 1790 in Vermont."),
                record("q2", route="presence", ms=1100, answer="X" * 400 + " tail" * 200)])
            code, table, answers, said = self.table(directory)
            self.assertEqual(code, 0)
            text = table.read_text()
            rows = [line for line in text.splitlines() if line.startswith("| ")]
            self.assertEqual([r.split(" | ")[0] for r in rows],
                             ["| Brain", "| alpha:1b", "| Cloud · claude-x"])
            self.assertIn("| alpha:1b | 2 | 2 of 2 (100%) | 1 of 1 (100%) | 1 of 1 (100%) | — | "
                          "0 of 2 (0%) | 1 of 2 (50%) | 0 | 3.0 s | 4.0 s | none |", text)
            self.assertIn("| Cloud · claude-x | 2 | 2 of 2 (100%) |", text)
            self.assertIn("2 of 2 (100%) | 0 | 1.0 s | 1.1 s | none |", text)
            self.assertIn("A proxy for natural speech, not a measure of it", text)
            self.assertIn("- alpha:1b: git abc1234, binary built 2026-11-15T18:00:00, corpus ffffffffffff", text)
            body = answers.read_text()
            self.assertIn("## q1 — question q1", body)
            self.assertIn("- **Cloud · claude-x** (clean, graph, model, 0.9 s): She was born in 1790 in Vermont.", body)
            self.assertIn("- **alpha:1b** (clean, presence, template, 4.0 s): Here is the answer on file for q2.", body)
            self.assertIn("X" * 400 + " …", body)
            self.assertNotIn("tail", body)
            self.assertIn("Keep this file out of git", body)

    def test_a_defect_is_marked_and_named_and_a_missing_answer_is_said(self):
        with tempfile.TemporaryDirectory() as directory:
            write_run(directory, "alpha:1b", [
                record("q1", route="presence", expectedRoutes=["graph"]), record("q2")])
            time.sleep(0.01)
            write_run(directory, "beta:2b", [record("q2")], questions=2)
            _, table, answers, _ = self.table(directory)
            self.assertIn("route_mismatch ×1", table.read_text())
            self.assertIn("| beta:2b | 2 (1 answered — INCOMPLETE) |", table.read_text())
            body = answers.read_text()
            self.assertIn("- **alpha:1b** (DEFECT, presence, model, 1.0 s)", body)
            self.assertIn("- **beta:2b** — no answer recorded", body)

    def test_a_run_file_dropped_in_by_hand_counts_and_graded_copies_do_not(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "byhand.jsonl").write_text(
                json.dumps({"meta": {"questions": 1}}) + "\n" + json.dumps(record("q1")) + "\n")
            (root / "byhand.graded.jsonl").write_text(json.dumps(record("q1")) + "\n")
            code, table, _, _ = self.table(directory)
            self.assertEqual(code, 0)
            rows = [line for line in table.read_text().splitlines() if line.startswith("| ")]
            self.assertEqual(len(rows), 2)
            self.assertTrue(rows[1].startswith("| byhand | 1 | 1 of 1 (100%) |"))

    def test_an_empty_folder_and_a_file_that_is_not_a_run_are_refused_in_words(self):
        with tempfile.TemporaryDirectory() as directory:
            code, table, _, said = self.table(directory)
            self.assertEqual(code, 2)
            self.assertFalse(table.exists())
            self.assertIn("no runs in", said[0])
            (Path(directory) / "junk.jsonl").write_text('{"not": "a run"}\n')
            with self.assertRaises(ValueError):
                compare.table(argparse.Namespace(dir=directory), say=lambda _: None)
            with redirect_stderr(io.StringIO()) as err:
                self.assertEqual(compare.main(["table", directory]), 2)
            self.assertIn("is not a hallie_eval run", err.getvalue())

    def test_the_default_output_folder_is_ignored_by_git(self):
        ignore = (ROOT / ".gitignore").read_text()
        self.assertTrue(any(line.strip().rstrip("/") == ".scratch" for line in ignore.splitlines()),
                        ".scratch/ must stay ignored: compare output holds family data")
        self.assertIn('REPO / ".scratch/hallie-compare"', (ROOT / "scripts/hallie_compare.py").read_text())


if __name__ == "__main__":
    unittest.main()
