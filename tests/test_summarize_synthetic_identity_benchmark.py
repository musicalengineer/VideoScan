import importlib.util
import sys
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "tools/person-eval/summarize_synthetic_identity_benchmark.py"
SPEC = importlib.util.spec_from_file_location("summarize_synthetic", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


SAMPLE = """### identity-a
  Donna/query.mkv: 0.383 (24 frames, 24 gated faces) [0.3s]
  Donna/query.mp4: 0.544 (24 frames, 24 gated faces) [0.3s]
  NotDonna/query.mkv: 0.100 (24 frames, 24 gated faces) [0.3s]
  NotDonna/query.mp4: 0.110 (24 frames, 24 gated faces) [0.3s]
### identity-b
  Donna/query.mkv: 0.600 (24 frames, 24 gated faces) [0.3s]
  Donna/query.mp4: 0.590 (24 frames, 24 gated faces) [0.3s]
  NotDonna/query.mkv: ERR decoder failed
  NotDonna/query.mp4: 0.200 (24 frames, 24 gated faces) [0.3s]
"""


class SyntheticBenchmarkSummaryTests(unittest.TestCase):
    def test_parser_preserves_scores_counts_and_errors(self):
        rows, errors = MODULE.parse_log(SAMPLE)
        self.assertEqual(len(rows), 7)
        self.assertEqual(len(errors), 1)
        self.assertEqual(rows[0]["identity"], "identity-a")
        self.assertEqual(rows[0]["frames"], 24)
        self.assertEqual(errors[0]["transport"], "mkv")

    def test_summary_detects_route_tier_flip(self):
        rows, errors = MODULE.parse_log(SAMPLE)
        report = MODULE.summarize(rows, errors)
        self.assertEqual(report["routeComparison"]["tierFlipCount"], 1)
        flip = report["routeComparison"]["tierFlips"][0]
        self.assertEqual(flip["mp4Tier"], "detected")
        self.assertEqual(flip["mkvTier"], "suspected")
        self.assertAlmostEqual(flip["absoluteDelta"], 0.161)

    def test_summary_never_counts_suspected_as_detected(self):
        rows, errors = MODULE.parse_log(SAMPLE)
        report = MODULE.summarize(rows, errors)
        self.assertEqual(report["sameIdentity"]["detectedCount"], 3)
        self.assertEqual(report["sameIdentity"]["surfacedCount"], 4)


if __name__ == "__main__":
    unittest.main()
