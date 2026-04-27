#!/usr/bin/env python3
"""Unit tests for the pure helpers in scripts/find_person.py.

These cover the framing logic (timestamp planning, verdict bucketing,
path filtering, gallery distance) without requiring torch, ffmpeg, or
the embeddings.npz gallery file.
"""
from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path

import numpy as np

from scripts.find_person import (
    DEFAULT_FRAME_INTERVAL,
    DEFAULT_MAX_FRAMES,
    STRONG_HIT_COUNT,
    WEAK_VIA_WEAK_COUNT,
    compute_sample_timestamps,
    is_video_path,
    iter_videos,
    min_distance_to_gallery,
    should_skip_dir,
    verdict_for_counts,
)


class ComputeSampleTimestampsTests(unittest.TestCase):
    def test_too_short_returns_empty(self) -> None:
        self.assertEqual(compute_sample_timestamps(2.0, 5.0, 120), [])
        self.assertEqual(compute_sample_timestamps(4.0, 5.0, 120), [])

    def test_zero_or_negative_args_return_empty(self) -> None:
        self.assertEqual(compute_sample_timestamps(60.0, 5.0, 0), [])
        self.assertEqual(compute_sample_timestamps(60.0, 0.0, 120), [])
        self.assertEqual(compute_sample_timestamps(60.0, -1.0, 120), [])

    def test_endpoints_are_avoided(self) -> None:
        ts = compute_sample_timestamps(120.0, 5.0, 120)
        self.assertTrue(ts, "expected non-empty timestamps for 2-min video")
        self.assertGreaterEqual(ts[0], 2.0)
        self.assertLessEqual(ts[-1], 120.0 - 2.0)

    def test_caps_at_max_frames(self) -> None:
        # Long video, low interval — would generate way more than max
        ts = compute_sample_timestamps(7200.0, 1.0, 120)
        self.assertLessEqual(len(ts), 120)

    def test_minimum_four_samples_when_usable(self) -> None:
        # Short-but-valid video with high interval still yields ≥ 4 samples
        ts = compute_sample_timestamps(20.0, 60.0, 120)
        self.assertGreaterEqual(len(ts), 4)

    def test_timestamps_are_strictly_increasing(self) -> None:
        ts = compute_sample_timestamps(600.0, 5.0, 120)
        self.assertTrue(all(b > a for a, b in zip(ts, ts[1:])))


class VerdictForCountsTests(unittest.TestCase):
    def test_no_hits_is_no(self) -> None:
        self.assertEqual(verdict_for_counts(0, 0), "NO")

    def test_strong_threshold_promotes_to_strong(self) -> None:
        self.assertEqual(
            verdict_for_counts(STRONG_HIT_COUNT, 0), "STRONG"
        )
        self.assertEqual(
            verdict_for_counts(STRONG_HIT_COUNT + 5, 0), "STRONG"
        )

    def test_one_strong_is_weak(self) -> None:
        self.assertEqual(verdict_for_counts(1, 0), "WEAK")
        self.assertEqual(verdict_for_counts(STRONG_HIT_COUNT - 1, 0), "WEAK")

    def test_many_weak_promotes_to_weak(self) -> None:
        self.assertEqual(
            verdict_for_counts(0, WEAK_VIA_WEAK_COUNT), "WEAK"
        )

    def test_few_weak_alone_is_no(self) -> None:
        self.assertEqual(
            verdict_for_counts(0, WEAK_VIA_WEAK_COUNT - 1), "NO"
        )

    def test_strong_dominates_weak(self) -> None:
        # Even with many weak hits, strong threshold wins outright
        self.assertEqual(
            verdict_for_counts(STRONG_HIT_COUNT, 999), "STRONG"
        )


class IsVideoPathTests(unittest.TestCase):
    def test_known_extensions_match(self) -> None:
        for ext in (".mp4", ".mov", ".MKV", ".avi", ".dv", ".m2ts"):
            self.assertTrue(
                is_video_path(Path(f"/tmp/clip{ext}")),
                f"{ext} should be recognized",
            )

    def test_dotfiles_rejected(self) -> None:
        self.assertFalse(is_video_path(Path("/tmp/.hidden.mp4")))

    def test_non_video_extensions_rejected(self) -> None:
        for name in ("notes.txt", "image.jpg", "song.mp3", "archive.zip",
                     "no_extension"):
            self.assertFalse(is_video_path(Path(f"/tmp/{name}")))


class ShouldSkipDirTests(unittest.TestCase):
    def test_dot_dirs_skipped(self) -> None:
        self.assertTrue(should_skip_dir(".git"))
        self.assertTrue(should_skip_dir(".Spotlight-V100"))
        self.assertTrue(should_skip_dir(".whatever"))

    def test_known_skip_patterns(self) -> None:
        for name in ("node_modules", "venv", ".venv",
                     "System Volume Information", "$RECYCLE.BIN"):
            self.assertTrue(should_skip_dir(name), name)

    def test_normal_dirs_kept(self) -> None:
        for name in ("Movies", "Family", "2010", "Christmas Eve"):
            self.assertFalse(should_skip_dir(name), name)


class IterVideosTests(unittest.TestCase):
    def test_finds_videos_skips_junk(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            # videos that should be found
            (root / "a.mov").touch()
            (root / "sub").mkdir()
            (root / "sub" / "b.MP4").touch()
            # noise that should be ignored
            (root / ".hidden.mov").touch()
            (root / "notes.txt").touch()
            # skip-listed directories — contents must NOT appear
            for skip in (".git", "node_modules", ".Spotlight-V100"):
                d = root / skip
                d.mkdir()
                (d / "should_not_find.mp4").touch()

            found = sorted(p.name for p in iter_videos(root))
            self.assertEqual(found, ["a.mov", "b.MP4"])

    def test_empty_dir_yields_nothing(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            self.assertEqual(list(iter_videos(Path(td))), [])


class MinDistanceToGalleryTests(unittest.TestCase):
    @staticmethod
    def _unit(v: list[float]) -> np.ndarray:
        a = np.asarray(v, dtype=np.float32)
        return a / (np.linalg.norm(a) + 1e-9)

    def test_identical_vector_distance_zero(self) -> None:
        face = self._unit([1.0, 0.0, 0.0])
        gallery = np.stack([face])
        self.assertAlmostEqual(
            min_distance_to_gallery(face, gallery), 0.0, places=5
        )

    def test_orthogonal_distance_one(self) -> None:
        face = self._unit([1.0, 0.0, 0.0])
        gallery = np.stack([self._unit([0.0, 1.0, 0.0])])
        self.assertAlmostEqual(
            min_distance_to_gallery(face, gallery), 1.0, places=5
        )

    def test_opposite_distance_two(self) -> None:
        face = self._unit([1.0, 0.0, 0.0])
        gallery = np.stack([self._unit([-1.0, 0.0, 0.0])])
        self.assertAlmostEqual(
            min_distance_to_gallery(face, gallery), 2.0, places=5
        )

    def test_returns_minimum_across_gallery(self) -> None:
        face = self._unit([1.0, 0.1, 0.0])
        gallery = np.stack([
            self._unit([0.0, 1.0, 0.0]),       # ~orthogonal
            self._unit([1.0, 0.0, 0.0]),       # near
            self._unit([-1.0, 0.0, 0.0]),      # far
        ])
        d = min_distance_to_gallery(face, gallery)
        self.assertLess(d, 0.05)
        # And it equals what we get against just the closest row
        d_solo = min_distance_to_gallery(face, gallery[1:2])
        self.assertAlmostEqual(d, d_solo, places=5)


class ConstantsSanityTests(unittest.TestCase):
    """Guardrails so accidental constant edits don't silently break verdicts."""

    def test_threshold_ordering(self) -> None:
        from scripts.find_person import (
            DEFAULT_STRONG_THRESH, DEFAULT_WEAK_THRESH,
        )
        self.assertLess(DEFAULT_STRONG_THRESH, DEFAULT_WEAK_THRESH)

    def test_hit_counts_positive(self) -> None:
        self.assertGreaterEqual(STRONG_HIT_COUNT, 1)
        self.assertGreaterEqual(WEAK_VIA_WEAK_COUNT, STRONG_HIT_COUNT)

    def test_frame_defaults_reasonable(self) -> None:
        self.assertGreater(DEFAULT_FRAME_INTERVAL, 0)
        self.assertGreater(DEFAULT_MAX_FRAMES, 0)


if __name__ == "__main__":
    unittest.main()
