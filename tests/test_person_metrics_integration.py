import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class PersonMetricsIntegrationSensors(unittest.TestCase):
    def test_every_nightly_publication_path_merges_person_fields(self):
        script = (ROOT / "scripts/nightly_local_tests.sh").read_text()
        self.assertIn(
            'with_person_metrics "$(make_status_row failed "build-rc:$BUILD_RC"',
            script,
        )
        self.assertIn(
            'with_person_metrics "$(make_status_row failed "zero-tests-ran:test-rc=$TEST_RC"',
            script,
        )
        self.assertIn('ROW=$(with_person_metrics "$ROW")', script)

    def test_dashboard_has_honest_missing_and_stale_states(self):
        page = (ROOT / "docs/index.html").read_text()
        self.assertIn("PERSON_METRIC_STALE_HOURS = 36", page)
        self.assertIn('person_eval_status: "not-configured"', page)
        self.assertIn('person_eval_quality_score: null', page)
        self.assertIn('person_eval_status: "stale"', page)
        self.assertIn('person_eval_publish_eligible: false', page)
        self.assertIn('personStatusValue.textContent', page)

    def test_morning_digest_rejects_stale_and_non_main_rows(self):
        script = (ROOT / "scripts/morning_metrics.sh").read_text()
        self.assertIn('r.get("source") == "nightly-local"', script)
        self.assertIn('r.get("branch") == "main"', script)
        self.assertIn('r.get("dirty") is not True', script)
        self.assertIn('metric_age_h > 36', script)
        self.assertIn('"person_eval_quality_score": None', script)


if __name__ == "__main__":
    unittest.main()
