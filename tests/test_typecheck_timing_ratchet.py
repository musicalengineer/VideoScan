#!/usr/bin/env python3
"""Unit tests for scripts/typecheck_timing_ratchet.py.

The thing under test is an IDENTITY function. The old nightly metric keyed on
the whole warning line, milliseconds and all, so the same slow function read as
a new finding whenever the shared runner's timing wobbled. Every test here is
ultimately asking one question: does the same function stay the same entry?

  Logic   — each warning shape parses; the saturated "unable to type-check"
            error is a first-class entry.
  Jitter  — the same function at 405/412/418ms across three nights collapses to
            ONE identity carrying max=418. This is the bug being fixed.
  Ratchet — a genuinely new slow function is detected as new; a new fast one is
            not; a known slow one stays grandfathered even when it drifts.
  Scale   — a few thousand warning lines parse inside a time budget.
  Sensor  — real warning text from the 2026-09-13 nightly run parses to the
            identity we expect.
"""
from __future__ import annotations

import json
import random
import sys
import tempfile
import time
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "scripts"))

import typecheck_timing_ratchet as tc  # noqa: E402

RUNNER_PREFIX = "/Users/runner/work/VideoScan/VideoScan/VideoScan/VideoScan"
WORKSPACE = "/Users/runner/work/VideoScan/VideoScan"


def warn(file_name, line, col, message):
    return f"{RUNNER_PREFIX}/{file_name}:{line}:{col}: warning: {message}"


# Verbatim lines from run 34750465600 (nightly, main, 2026-09-13).
REAL_LOG_SAMPLE = [
    f"{RUNNER_PREFIX}/HallieLineageAnswer+CommonAncestor.swift:93:17: warning: "
    "static method 'commonAncestor(_:_:request:context:)' took 254ms to type-check (limit: 100ms)",
    f"{RUNNER_PREFIX}/HalliePronunciationHint.swift:471:9: warning: "
    "expression took 311ms to type-check (limit: 100ms)",
    f"{RUNNER_PREFIX}/HalliePronunciationHint.swift:473:9: warning: "
    "expression took 301ms to type-check (limit: 100ms)",
    f"{RUNNER_PREFIX}/MediaDistribution.swift:379:22: warning: "
    "expression took 770ms to type-check (limit: 100ms)",
    f"{RUNNER_PREFIX}/CatalogContent+Table.swift:181:9: warning: "
    "getter for property 'tableWithCatalogTriggers' took 17311ms to type-check (limit: 100ms)",
]


class TestParsing(unittest.TestCase):
    def test_named_function_body(self):
        table = tc.parse_log([warn(
            "ContentView.swift", 954, 5,
            "instance method 'withAlerts' took 4636ms to type-check (limit: 100ms)")],
            WORKSPACE)
        (entry,) = table.values()
        self.assertEqual(entry.path, "VideoScan/VideoScan/ContentView.swift")
        self.assertEqual(entry.symbol, "instance method 'withAlerts'")
        self.assertEqual(entry.max_ms, 4636)
        self.assertEqual(entry.identity,
                         "VideoScan/VideoScan/ContentView.swift::instance method 'withAlerts'")

    def test_getter_for_property(self):
        table = tc.parse_log([warn(
            "InspectorPanel.swift", 44, 9,
            "getter for property 'body' took 1849ms to type-check (limit: 100ms)")],
            WORKSPACE)
        (entry,) = table.values()
        self.assertEqual(entry.symbol, "getter for property 'body'")

    def test_expression_warnings_aggregate_per_file(self):
        lines = [
            warn("HalliePronunciationHint.swift", 471, 9,
                 "expression took 311ms to type-check (limit: 100ms)"),
            warn("HalliePronunciationHint.swift", 473, 9,
                 "expression took 301ms to type-check (limit: 100ms)"),
        ]
        table = tc.parse_log(lines, WORKSPACE)
        self.assertEqual(len(table), 1)
        (entry,) = table.values()
        self.assertEqual(entry.symbol, "expression")
        self.assertEqual(entry.max_ms, 311)
        self.assertEqual(entry.hits, 2)

    def test_closure_body_aggregates_per_file(self):
        lines = [
            warn("CatalogToolbar.swift", 263, 9,
                 "closure body took 240ms to type-check (limit: 100ms)"),
            warn("CatalogToolbar.swift", 301, 9,
                 "closure body took 190ms to type-check (limit: 100ms)"),
        ]
        table = tc.parse_log(lines, WORKSPACE)
        self.assertEqual(len(table), 1)
        self.assertEqual(list(table.values())[0].max_ms, 240)

    def test_unable_to_type_check_is_saturated(self):
        """The shape that turned CI red on 2026-09-01 — CatalogView.body
        compiling on the M4 and not on the runner."""
        line = (f"{RUNNER_PREFIX}/ContentView.swift:490:5: error: the compiler is "
                "unable to type-check this expression in reasonable time; try "
                "breaking up the expression into distinct sub-expressions")
        table = tc.parse_log([line], WORKSPACE)
        (entry,) = table.values()
        self.assertTrue(entry.is_saturated)
        self.assertEqual(entry.ms_text(), "unable")
        self.assertGreater(entry.max_ms, 10 ** 9)

    def test_unrelated_lines_are_ignored(self):
        lines = [
            "** BUILD SUCCEEDED **",
            warn("Foo.swift", 1, 1, "unused variable 'x'"),
            "/tmp/Bar.swift:3:1: warning: 'baz' is deprecated",
        ]
        self.assertEqual(tc.parse_log(lines, WORKSPACE), {})

    def test_runner_paths_normalise_without_an_explicit_workspace(self):
        table = tc.parse_log([warn(
            "InspectorPanel.swift", 44, 9,
            "getter for property 'body' took 900ms to type-check (limit: 100ms)")],
            None)
        (entry,) = table.values()
        self.assertFalse(entry.path.startswith("/Users/runner"))
        self.assertTrue(entry.path.endswith("InspectorPanel.swift"))


class TestJitterCollapsesToOneIdentity(unittest.TestCase):
    """The whole reason this script exists."""

    def _night(self, ms):
        return tc.parse_log([warn(
            "CatalogToolbar.swift", 263, 9,
            f"getter for property 'body' took {ms}ms to type-check (limit: 100ms)")],
            WORKSPACE)

    def test_three_nights_of_jitter_are_one_entry(self):
        keys = set()
        for ms in (405, 412, 418):
            keys |= set(self._night(ms).keys())
        self.assertEqual(len(keys), 1,
                         "millisecond jitter must not create new identities")

    def test_jitter_within_one_log_collapses_and_keeps_the_max(self):
        lines = [warn("CatalogToolbar.swift", 263, 9,
                      f"getter for property 'body' took {ms}ms to type-check (limit: 100ms)")
                 for ms in (405, 418, 412)]
        table = tc.parse_log(lines, WORKSPACE)
        self.assertEqual(len(table), 1)
        (entry,) = table.values()
        self.assertEqual(entry.max_ms, 418)
        self.assertEqual(entry.hits, 3)

    def test_the_line_number_moving_does_not_change_the_identity(self):
        """Somebody adds 40 lines of comments above the function."""
        before = self._night(412)
        after = tc.parse_log([warn(
            "CatalogToolbar.swift", 303, 9,
            "getter for property 'body' took 409ms to type-check (limit: 100ms)")],
            WORKSPACE)
        self.assertEqual(set(before), set(after))

    def test_the_old_sort_u_approach_would_have_seen_three_findings(self):
        """Contrast test — documents the bug being fixed."""
        raw = {warn("CatalogToolbar.swift", 263, 9,
                    f"getter for property 'body' took {ms}ms to type-check (limit: 100ms)")
               for ms in (405, 412, 418)}
        self.assertEqual(len(raw), 3)          # what `sort -u` counted
        self.assertEqual(len(tc.parse_log(sorted(raw), WORKSPACE)), 1)   # the truth


class TestRatchet(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.baseline_path = str(Path(self.tmp.name) / "typecheck.json")
        self.known = tc.parse_log([warn(
            "CatalogToolbar.swift", 263, 9,
            "getter for property 'body' took 1296ms to type-check (limit: 100ms)")],
            WORKSPACE)
        tc.write_baseline(self.baseline_path, self.known)
        self.baseline = tc.load_baseline(self.baseline_path)

    def tearDown(self):
        self.tmp.cleanup()

    def test_a_genuinely_new_slow_function_is_detected(self):
        table = dict(self.known)
        table.update(tc.parse_log([warn(
            "NewSheet.swift", 12, 5,
            "getter for property 'body' took 900ms to type-check (limit: 100ms)")],
            WORKSPACE))
        new = tc.new_over_threshold(table, self.baseline)
        self.assertEqual([e.path for e in new], ["VideoScan/VideoScan/NewSheet.swift"])

    def test_a_new_but_fast_function_is_not_gated(self):
        table = dict(self.known)
        table.update(tc.parse_log([warn(
            "NewSheet.swift", 12, 5,
            "getter for property 'body' took 220ms to type-check (limit: 100ms)")],
            WORKSPACE))
        self.assertEqual(tc.new_over_threshold(table, self.baseline), [])

    def test_the_threshold_is_exactly_one_named_constant(self):
        self.assertEqual(tc.NEW_FUNCTION_THRESHOLD_MS, 500)
        boundary = tc.parse_log([warn(
            "Edge.swift", 1, 1,
            f"getter for property 'body' took {tc.NEW_FUNCTION_THRESHOLD_MS}ms "
            "to type-check (limit: 100ms)")], WORKSPACE)
        self.assertEqual(len(tc.new_over_threshold(boundary, {})), 1)
        under = tc.parse_log([warn(
            "Edge.swift", 1, 1,
            f"getter for property 'body' took {tc.NEW_FUNCTION_THRESHOLD_MS - 1}ms "
            "to type-check (limit: 100ms)")], WORKSPACE)
        self.assertEqual(tc.new_over_threshold(under, {}), [])

    def test_a_known_slow_function_that_jitters_stays_grandfathered(self):
        drifted = tc.parse_log([warn(
            "CatalogToolbar.swift", 263, 9,
            "getter for property 'body' took 1340ms to type-check (limit: 100ms)")],
            WORKSPACE)
        self.assertEqual(tc.new_over_threshold(drifted, self.baseline), [])

    def test_a_new_saturated_expression_always_fails(self):
        table = tc.parse_log([
            f"{RUNNER_PREFIX}/ContentView.swift:490:5: error: the compiler is "
            "unable to type-check this expression in reasonable time"], WORKSPACE)
        self.assertEqual(len(tc.new_over_threshold(table, self.baseline)), 1)

    def test_growth_is_reported_but_never_gated(self):
        grown = tc.parse_log([warn(
            "CatalogToolbar.swift", 263, 9,
            "getter for property 'body' took 3000ms to type-check (limit: 100ms)")],
            WORKSPACE)
        self.assertEqual(tc.new_over_threshold(grown, self.baseline), [],
                         "gating on a jittering ms value rebuilds the noise")
        self.assertEqual(len(tc.regressions(grown, self.baseline)), 1)

    def test_baseline_round_trips_including_the_saturated_value(self):
        table = tc.parse_log([
            f"{RUNNER_PREFIX}/ContentView.swift:490:5: error: the compiler is "
            "unable to type-check this expression in reasonable time"], WORKSPACE)
        path = str(Path(self.tmp.name) / "sat.json")
        tc.write_baseline(path, table)
        with open(path, encoding="utf-8") as handle:
            self.assertIn("unable", json.dumps(json.load(handle)["entries"]))
        reloaded = tc.load_baseline(path)
        self.assertEqual(tc.new_over_threshold(table, reloaded), [])


class TestTopOffenders(unittest.TestCase):
    def test_sorted_worst_first_and_saturated_above_every_number(self):
        lines = [
            warn("A.swift", 1, 1, "getter for property 'body' took 200ms to type-check (limit: 100ms)"),
            warn("B.swift", 1, 1, "getter for property 'body' took 9000ms to type-check (limit: 100ms)"),
            f"{RUNNER_PREFIX}/C.swift:1:1: error: the compiler is unable to "
            "type-check this expression in reasonable time",
        ]
        top = tc.top_offenders(tc.parse_log(lines, WORKSPACE))
        self.assertEqual([e.path.split("/")[-1] for e in top],
                         ["C.swift", "B.swift", "A.swift"])

    def test_limit_is_respected(self):
        lines = [warn(f"F{i}.swift", 1, 1,
                      f"getter for property 'body' took {600 + i}ms to type-check (limit: 100ms)")
                 for i in range(50)]
        self.assertEqual(len(tc.top_offenders(tc.parse_log(lines, WORKSPACE), 20)), 20)

    def test_the_top_list_is_stable_across_a_jittery_rerun(self):
        rng = random.Random(1979)

        def night():
            lines = [warn(f"F{i}.swift", 1, 1,
                          f"getter for property 'body' took "
                          f"{1000 + i * 100 + rng.randint(-30, 30)}ms "
                          "to type-check (limit: 100ms)")
                     for i in range(25)]
            return [e.identity for e in tc.top_offenders(tc.parse_log(lines, WORKSPACE), 20)]

        self.assertEqual(night(), night())


class TestScale(unittest.TestCase):
    def test_a_few_thousand_warning_lines_parse_quickly(self):
        rng = random.Random(7)
        lines = []
        for i in range(4000):
            lines.append(warn(f"File{i % 400}.swift", rng.randint(1, 900), 5,
                              f"getter for property 'body{i % 40}' took "
                              f"{rng.randint(101, 2000)}ms to type-check (limit: 100ms)"))
        # Plus realistic build chatter the parser must skip cheaply.
        lines += ["CompileSwiftSources normal arm64"] * 4000
        started = time.monotonic()
        table = tc.parse_log(lines, WORKSPACE)
        elapsed = time.monotonic() - started
        self.assertLess(elapsed, 3.0, f"parse of 8000 lines took {elapsed:.2f}s")
        self.assertLessEqual(len(table), 400 * 40)
        self.assertGreater(len(table), 0)

    def test_identity_table_does_not_grow_with_repeated_emission(self):
        """xcodebuild emits the same warning once per target/pass. Memory is
        bounded by DISTINCT identities, not by log length."""
        one = warn("A.swift", 10, 5,
                   "getter for property 'body' took 700ms to type-check (limit: 100ms)")
        table = tc.parse_log([one] * 5000, WORKSPACE)
        self.assertEqual(len(table), 1)
        self.assertEqual(list(table.values())[0].hits, 5000)


class TestAgainstRealNightlyOutput(unittest.TestCase):
    """Sensor: verbatim lines from nightly run 34750465600 (main, 2026-09-13)."""

    def test_real_sample_parses_to_the_expected_identities(self):
        table = tc.parse_log(REAL_LOG_SAMPLE, WORKSPACE)
        identities = set(table)
        self.assertIn(
            "VideoScan/VideoScan/CatalogContent+Table.swift::"
            "getter for property 'tableWithCatalogTriggers'", identities)
        self.assertIn(
            "VideoScan/VideoScan/HallieLineageAnswer+CommonAncestor.swift::"
            "static method 'commonAncestor(_:_:request:context:)'", identities)
        # The two HalliePronunciationHint expressions folded into one entry.
        self.assertEqual(len(identities), 4)

    def test_the_worst_real_offender_is_the_seventeen_second_getter(self):
        worst = tc.top_offenders(tc.parse_log(REAL_LOG_SAMPLE, WORKSPACE), 1)[0]
        self.assertEqual(worst.max_ms, 17311)
        self.assertTrue(worst.path.endswith("CatalogContent+Table.swift"))

    def test_committed_baseline_is_well_formed_and_grandfathers_the_sample(self):
        path = REPO_ROOT / "ci" / "baselines" / "typecheck_timing.json"
        with open(path, encoding="utf-8") as handle:
            payload = json.load(handle)
        self.assertEqual(payload["threshold_ms"], tc.NEW_FUNCTION_THRESHOLD_MS)
        self.assertEqual(payload["entry_count"], len(payload["entries"]))
        baseline = tc.load_baseline(str(path))
        self.assertEqual(
            tc.new_over_threshold(tc.parse_log(REAL_LOG_SAMPLE, WORKSPACE), baseline), [],
            "today's real warnings must all be grandfathered")


if __name__ == "__main__":
    unittest.main()
