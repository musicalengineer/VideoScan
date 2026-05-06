#!/usr/bin/env python3
from __future__ import annotations

import unittest
import json
import subprocess
import sys
from argparse import Namespace
from pathlib import Path

from scripts.face_recognize import cluster_segments


class ClusterSegmentsTests(unittest.TestCase):
    def test_empty_input_returns_empty_list(self) -> None:
        args = Namespace(pad=2.0, min_duration=1.0)
        self.assertEqual(cluster_segments([], args), [])

    def test_overlapping_segments_are_padded_merged_and_averaged(self) -> None:
        args = Namespace(pad=1.0, min_duration=1.0)
        raw_segments = [
            (10.0, 10.0, 0.40, 0.40, 1),
            (11.0, 11.0, 0.35, 0.35, 1),
            (20.0, 20.0, 0.50, 1.05, 2),
        ]

        segments = cluster_segments(raw_segments, args)

        self.assertEqual(len(segments), 2)
        self.assertEqual(
            segments[0],
            {
                "start": 9.0,
                "end": 12.0,
                "best_dist": 0.35,
                "avg_dist": 0.375,
                "hit_count": 2,
            },
        )
        self.assertEqual(
            segments[1],
            {
                "start": 19.0,
                "end": 21.0,
                "best_dist": 0.5,
                "avg_dist": 0.525,
                "hit_count": 2,
            },
        )

    def test_short_segments_are_filtered(self) -> None:
        args = Namespace(pad=0.0, min_duration=2.0)
        raw_segments = [(5.0, 6.0, 0.42, 0.42, 1)]
        self.assertEqual(cluster_segments(raw_segments, args), [])


class FaceRecognizeCLITests(unittest.TestCase):
    def run_script(self, *args: str) -> subprocess.CompletedProcess[str]:
        script = Path(__file__).resolve().parents[1] / "scripts" / "face_recognize.py"
        return subprocess.run(
            [sys.executable, str(script), *args],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )

    def test_invalid_frame_step_returns_json_error(self) -> None:
        proc = self.run_script("--self-test", "--frame-step", "0")

        self.assertNotEqual(proc.returncode, 0)
        payload = json.loads(proc.stdout)
        self.assertIn("Invalid argument", payload["error"])
        self.assertIn("--frame-step", payload["error"])

    def test_invalid_threshold_returns_json_error(self) -> None:
        proc = self.run_script("--self-test", "--threshold", "1.5")

        self.assertNotEqual(proc.returncode, 0)
        payload = json.loads(proc.stdout)
        self.assertIn("Invalid argument", payload["error"])
        self.assertIn("--threshold", payload["error"])


if __name__ == "__main__":
    unittest.main()
