#!/usr/bin/env python3
from __future__ import annotations

import unittest
from argparse import Namespace

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


if __name__ == "__main__":
    unittest.main()
