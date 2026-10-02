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

    def test_metrics_page_does_not_render_person_recognition(self):
        """2026-10-02: the one metrics page (Rick) dropped the person-recognition
        panel. Every nightly row since July says `not-configured` (PersonFinder
        was demoted 2026-09-26), so the panel only ever showed a red 0% readiness.
        The fields still ride on the nightly row and the morning digest still
        reports them (test below); the public page must not invent a number
        from them."""
        page = (ROOT / "docs/index.html").read_text()
        self.assertNotIn("person_eval_", page)
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

    def test_nightly_builds_release_from_one_configuration_and_publishes_it(self):
        """Rick, 2026-09-29 21:00: the 2 AM nightly builds RELEASE (production
        parity); rapid dev and day testing stay Debug.

        The contract: every xcodebuild in the lane takes its configuration
        from the one NIGHTLY_CONFIGURATION value, nothing spells
        Build/Products/<name> by hand, the build passes ENABLE_TESTABILITY=YES
        so @testable imports resolve in an optimised build, and every row
        shape carries the configuration (additive field; the gauntlet rows use
        the same key). A stale "-configuration Debug" or "Products/Debug"
        anywhere in the script is the regression this pins.
        """
        script = (ROOT / "scripts/nightly_local_tests.sh").read_text()
        code = [l for l in script.splitlines() if not l.lstrip().startswith("#")]
        self.assertIn('NIGHTLY_CONFIGURATION="Release"', script)
        self.assertEqual([l for l in code if "-configuration Debug" in l], [])
        self.assertEqual([l for l in code if "Products/Debug" in l], [])
        invocations = [l for l in code if "-configuration " in l]
        self.assertTrue(invocations, "no xcodebuild -configuration lines found")
        self.assertEqual(
            [l for l in invocations if '"$NIGHTLY_CONFIGURATION"' not in l], [],
            "an xcodebuild does not read NIGHTLY_CONFIGURATION",
        )
        products = [l for l in code if "Build/Products/" in l]
        self.assertTrue(products, "no derived products path found")
        self.assertEqual(
            [l for l in products if "$NIGHTLY_CONFIGURATION" not in l], [],
            "a products path is spelled by hand instead of derived",
        )

        def body(fn):
            start = script.index(fn + "() {")
            return script[start:script.index("\n}\n", start)]

        self.assertIn("ENABLE_TESTABILITY=YES", body("run_nightly_build"))
        for fn in ("make_status_row", "make_current_test_result_row"):
            self.assertIn('"configuration":"%s"', body(fn), f"{fn} row lacks configuration")
            self.assertIn("${NIGHTLY_CONFIGURATION:-unknown}", body(fn),
                          f"{fn} would abort under set -u when sourced alone")


if __name__ == "__main__":
    unittest.main()
