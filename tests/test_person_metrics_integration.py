import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class PersonMetricsIntegrationSensors(unittest.TestCase):
    def test_every_nightly_publication_path_merges_person_fields(self):
        """Every published row carries person metrics.

        Rewritten 2026-08-30. The old version pinned three literal lines,
        including one inline `zero-tests-ran` publication. codex's watchdog
        rewrite moved that verdict into a precedence function and
        consolidated the publishers -- behaviour preserved, wording gone --
        so the test failed on a refactor that IMPROVED the script. It was
        pinning a shape, not a contract.

        The contract is: no call to make_status_row escapes
        with_person_metrics. That survives rearrangement and is stronger
        than three string literals, because it covers publication paths
        nobody has written yet.
        """
        script = (ROOT / "scripts/nightly_local_tests.sh").read_text()
        invocations = [
            line.strip()
            for line in script.splitlines()
            if "make_status_row " in line and not line.lstrip().startswith("#")
        ]
        self.assertTrue(invocations, "no make_status_row call sites found at all")
        unwrapped = [l for l in invocations if "with_person_metrics" not in l]
        self.assertEqual(
            unwrapped, [],
            "these publication paths would emit a row without person metrics:\n  "
            + "\n  ".join(unwrapped),
        )
        # The ghost-pass guard itself: a run where nothing executed must
        # publish a FAILED row, never a silent green one.
        self.assertIn("zero-tests-ran:test-rc=", script)

    def test_dashboard_has_honest_missing_and_stale_states(self):
        page = (ROOT / "docs/index.html").read_text()
        self.assertIn("PERSON_METRIC_STALE_HOURS = 36", page)
        self.assertIn('person_eval_status: "not-configured"', page)
        self.assertIn('person_eval_quality_score: null', page)
        self.assertIn('person_eval_status: "stale"', page)
        self.assertIn('person_eval_publish_eligible: false', page)
        self.assertIn('personStatusValue.textContent', page)
        self.assertNotIn('rawUrl("poi_cycles.jsonl")', page)
        self.assertNotIn('id="poi-cycle-cards"', page)

    def test_morning_digest_rejects_stale_and_non_main_rows(self):
        script = (ROOT / "scripts/morning_metrics.sh").read_text()
        self.assertIn('r.get("source") == "nightly-local"', script)
        self.assertIn('r.get("branch") == "main"', script)
        self.assertIn('r.get("dirty") is not True', script)
        self.assertIn('metric_age_h > 36', script)
        self.assertIn('"person_eval_quality_score": None', script)
        self.assertIn('poi_cycle_stream_status', script)

    def test_nightly_collector_version_and_fallback_expose_cycle_sensor(self):
        script = (ROOT / "scripts/nightly_local_tests.sh").read_text()
        # The version's job is to identify which script produced a row, so
        # the contract is "it exists, it is non-empty, and it is published".
        # Pinning the literal made every legitimate bump a CI failure --
        # which is exactly how this test broke.
        # `[^"]*` not `[^"]+`: with the plus, an empty value fails to match
        # and reports "not defined", leaving the emptiness check below
        # unreachable -- an assertion that cannot fail.
        version = re.search(r'NIGHTLY_SCRIPT_VERSION="([^"]*)"', script)
        self.assertIsNotNone(version, "NIGHTLY_SCRIPT_VERSION is not defined")
        self.assertTrue(version.group(1).strip(), "NIGHTLY_SCRIPT_VERSION is empty")
        self.assertIn("nightly_script_v", script,
                      "the version is defined but never published in the row")
        self.assertIn('"poi_cycle_stream_status":"collector-failed"', script)


if __name__ == "__main__":
    unittest.main()
