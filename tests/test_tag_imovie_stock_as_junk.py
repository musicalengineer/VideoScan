#!/usr/bin/env python3
"""Unit tests for scripts/tag_imovie_stock_as_junk.py.

The pure logic — is_imovie_stock pattern recognition + compute_tag_deltas
sibling-safety check — is the part most likely to bite us if iMovie
filename conventions change or someone over-broadens the prefix list.
These tests pin the narrow contract: ONLY unambiguous stock-asset
patterns, never family-content patterns like "Clip N.dv".
"""
from __future__ import annotations

import unittest
from pathlib import Path
import sys

SCRIPTS = Path(__file__).resolve().parent.parent / "scripts"
sys.path.insert(0, str(SCRIPTS))

from tag_imovie_stock_as_junk import (  # noqa: E402
    is_imovie_stock,
    compute_tag_deltas,
)


class TestIsImovieStock(unittest.TestCase):
    """Pattern recognition for iMovie HD stock asset filenames."""

    # --- positive matches (must tag) ---

    def test_animated_gradient_with_number(self):
        self.assertTrue(is_imovie_stock("Animated Gradient 01.dv"))

    def test_bounce_across_multiple(self):
        self.assertTrue(is_imovie_stock("Bounce Across Multiple 03.dv"))

    def test_typewriter(self):
        self.assertTrue(is_imovie_stock("Typewriter 02.dv"))

    def test_rolling_credits(self):
        self.assertTrue(is_imovie_stock("Rolling Centered Credits 01.dv"))

    def test_push_just_prefix_and_ext(self):
        # Edge case: filename is exactly the prefix + extension, no number.
        self.assertTrue(is_imovie_stock("Push.dv"))

    def test_zoom_with_space_and_number(self):
        self.assertTrue(is_imovie_stock("Zoom 04.dv"))

    # --- negative matches (must NOT tag) ---

    def test_pusher_does_not_match_push(self):
        # The trailing-char check prevents false matches like Pusher.mov
        # being eaten by the "Push" prefix.
        self.assertFalse(is_imovie_stock("Pusher.mov"))

    def test_clip_n_dv_intentionally_excluded(self):
        # The whole reason we don't include "Clip" in IMOVIE_STOCK_PREFIXES
        # is that Clip N.dv is how iMovie names REAL captured miniDV
        # footage. This test pins that intent.
        self.assertFalse(is_imovie_stock("Clip 06.dv"))
        self.assertFalse(is_imovie_stock("Clip 01.dv"))

    def test_empty_filename(self):
        self.assertFalse(is_imovie_stock(""))

    def test_non_imovie_filename(self):
        self.assertFalse(is_imovie_stock("IMG_1234.MOV"))
        self.assertFalse(is_imovie_stock("Cape Cod 1990.mov"))
        self.assertFalse(is_imovie_stock("Donna_at_beach.mp4"))

    def test_random_video_with_lowercase_prefix(self):
        # Case-sensitive — iMovie's stock assets are always capitalised
        # exactly. A lowercase variant is almost certainly user content.
        self.assertFalse(is_imovie_stock("push.mov"))


class TestComputeTagDeltas(unittest.TestCase):
    """End-to-end: given records, emit the right tagging deltas."""

    def _r(self, filename, full=None, md5=None, dossiered=False,
           disposition=None, sizeBytes=1000):
        rec = {
            "filename": filename,
            "fullPath": full or f"/Volumes/Test/{filename}",
            "sizeBytes": sizeBytes,
        }
        if md5:
            rec["partialMD5"] = md5
        if dossiered:
            rec["dossierProcessedAt"] = "2026-06-10T10:00:00+00:00"
        if disposition:
            rec["mediaDisposition"] = disposition
        return rec

    def test_basic_stock_asset_gets_tagged(self):
        records = [self._r("Animated Gradient 01.dv")]
        deltas = compute_tag_deltas(records)
        self.assertEqual(len(deltas), 1)
        # The Swift enum case is `confirmedJunk` but its RAW VALUE is
        # "Confirmed Junk" (case-sensitive, space-separated). The Swift
        # JSONDecoder silently falls back to .unreviewed on raw-value
        # mismatch, so this assertion is the regression sensor for the
        # 2026-06-10 corruption (132 records written with case name
        # instead of raw value).
        self.assertEqual(deltas[0]["fields"]["mediaDisposition"], "Confirmed Junk")

    def test_writes_swift_enum_raw_value(self):
        # Defensive pin: regardless of the records, the delta payload
        # MUST use the Swift enum's RAW VALUE for mediaDisposition. If
        # someone "cleans up" the string to the Swift case name, this
        # test fires before bad data reaches the catalog. Keep this in
        # lock-step with VideoScanTests/MediaDispositionRawValueContractTests.
        deltas = compute_tag_deltas([self._r("Push.dv")])
        self.assertEqual(deltas[0]["fields"]["mediaDisposition"], "Confirmed Junk",
                         "raw value must match MediaDisposition.confirmedJunk.rawValue in Models.swift")

    def test_non_stock_asset_skipped(self):
        records = [self._r("Clip 06.dv")]
        self.assertEqual(compute_tag_deltas(records), [])

    def test_already_confirmedJunk_skipped(self):
        # Idempotent: don't re-tag records that already have the tag.
        records = [self._r("Animated Gradient 01.dv",
                           disposition="confirmedJunk")]
        self.assertEqual(compute_tag_deltas(records), [])

    def test_dossier_state_does_not_affect_tagging(self):
        # Rick 2026-06-10: the sibling veto was dropped — the narrow
        # prefix list is the sole safety check. Dossier'd or not, a
        # stock-name record gets tagged. Reversibility lives in the
        # "Delete Confirmed Junk…" UI gate, not here.
        # Concrete case from Rick's catalog: Matt's "Centered Title
        # 03.dv" exists on both LaCieWorkspace and Seagate2TB and
        # BOTH copies got Whisper'd before this filter existed. We
        # want to tag both, not let them mutually veto each other.
        records = [
            self._r("Push.dv", full="/V1/Push.dv", md5="abc", dossiered=True),
            self._r("Push.dv", full="/V2/Push.dv", md5="abc", dossiered=True),
        ]
        deltas = compute_tag_deltas(records)
        tagged_paths = {d["fullPath"] for d in deltas}
        self.assertEqual(len(deltas), 2)
        self.assertIn("/V1/Push.dv", tagged_paths)
        self.assertIn("/V2/Push.dv", tagged_paths)

    def test_records_with_undossiered_sibling_still_tagged(self):
        # If the siblings are all undossier'd, no veto — tag them.
        records = [
            self._r("Push.dv", full="/V1/Push.dv", md5="abc"),
            self._r("Push.dv", full="/V2/Push.dv", md5="abc"),
        ]
        deltas = compute_tag_deltas(records)
        # Both get tagged.
        self.assertEqual(len(deltas), 2)

    def test_notes_field_marker_appended(self):
        records = [self._r("Animated Gradient 01.dv")]
        deltas = compute_tag_deltas(records)
        notes = deltas[0]["fields"]["notes"]
        self.assertIn("iMovie stock asset", notes)
        self.assertIn("auto-tagged confirmedJunk", notes)

    def test_existing_notes_preserved(self):
        rec = self._r("Animated Gradient 01.dv")
        rec["notes"] = "Rick's prior note"
        deltas = compute_tag_deltas([rec])
        notes = deltas[0]["fields"]["notes"]
        self.assertIn("Rick's prior note", notes)
        self.assertIn("iMovie stock asset", notes)

    def test_no_fullpath_skipped(self):
        records = [{"filename": "Animated Gradient 01.dv"}]
        self.assertEqual(compute_tag_deltas(records), [])

    def test_delta_shape_matches_merger_contract(self):
        records = [self._r("Animated Gradient 01.dv")]
        deltas = compute_tag_deltas(records)
        d = deltas[0]
        # The merger expects these top-level keys.
        self.assertIn("fullPath", d)
        self.assertIn("host", d)
        self.assertIn("ts", d)
        self.assertIn("fields", d)
        self.assertEqual(d["host"], "junk-tagger")


if __name__ == "__main__":
    unittest.main()
