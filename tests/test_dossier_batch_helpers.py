#!/usr/bin/env python3
"""Unit tests for the pure helpers in scripts/dossier_batch.py.

Cover the bits that don't need the MLX model loaded:

  - `select_records` — filter the catalog by paths_file or filter_expr
  - `parse_ocr_date`  — regex parse of camcorder burn-in strings (Swift
                        parity with pfParseOcrDate)
  - `infer_record_date` — consensus + confidence (Swift parity with
                          pfInferRecordDate)

The JSONL line format itself is tested implicitly: select_records gives
us the iteration order, and `dossier_one`'s return shape is the same
dict that gets json.dumps'd into the JSONL — so testing select_records
+ the dossier-fields-shape is enough to bound the contract.
"""
from __future__ import annotations

import json
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

import sys
SCRIPTS = Path(__file__).resolve().parent.parent / "scripts"
sys.path.insert(0, str(SCRIPTS))

from dossier_batch import (  # noqa: E402
    infer_record_date,
    parse_ocr_date,
    select_records,
)


class TestSelectRecords(unittest.TestCase):
    """`select_records` filters catalog['records'] by paths_file or
    a key=value filter expression."""

    def _catalog(self, recs):
        return {"version": 6, "records": recs}

    def test_paths_file_returns_matching_records_only(self):
        cat = self._catalog([
            {"fullPath": "/a", "filename": "a"},
            {"fullPath": "/b", "filename": "b"},
            {"fullPath": "/c", "filename": "c"},
        ])
        with tempfile.TemporaryDirectory() as tmp:
            paths = Path(tmp) / "p.txt"
            paths.write_text("/a\n/c\n")
            sel = select_records(cat, paths_file=str(paths))
            paths_returned = sorted([r["fullPath"] for _, r in sel])
            self.assertEqual(paths_returned, ["/a", "/c"])

    def test_paths_file_skips_blank_lines(self):
        cat = self._catalog([
            {"fullPath": "/a", "filename": "a"},
            {"fullPath": "/b", "filename": "b"},
        ])
        with tempfile.TemporaryDirectory() as tmp:
            paths = Path(tmp) / "p.txt"
            paths.write_text("\n/a\n\n/b\n\n")
            sel = select_records(cat, paths_file=str(paths))
            self.assertEqual(len(sel), 2)

    def test_paths_file_preserves_catalog_order(self):
        # Records returned in catalog-index order, NOT paths-file order.
        # The script uses `enumerate(records)` so the second arg of each
        # tuple is the catalog index.
        cat = self._catalog([
            {"fullPath": "/x", "filename": "x"},  # idx 0
            {"fullPath": "/y", "filename": "y"},  # idx 1
            {"fullPath": "/z", "filename": "z"},  # idx 2
        ])
        with tempfile.TemporaryDirectory() as tmp:
            paths = Path(tmp) / "p.txt"
            paths.write_text("/z\n/x\n/y\n")
            sel = select_records(cat, paths_file=str(paths))
            indices = [i for i, _ in sel]
            self.assertEqual(indices, [0, 1, 2])

    def test_filter_expr_people_matches_detected(self):
        cat = self._catalog([
            {"fullPath": "/a", "detectedPeople": ["Matt"], "suspectedPeople": []},
            {"fullPath": "/b", "detectedPeople": [], "suspectedPeople": ["Donna"]},
            {"fullPath": "/c", "detectedPeople": ["Donna"], "suspectedPeople": []},
        ])
        sel = select_records(cat, filter_expr="people=Donna")
        paths_returned = sorted([r["fullPath"] for _, r in sel])
        self.assertEqual(paths_returned, ["/b", "/c"])

    def test_filter_expr_people_matches_suspected(self):
        cat = self._catalog([
            {"fullPath": "/a", "detectedPeople": [], "suspectedPeople": ["Matt"]},
        ])
        sel = select_records(cat, filter_expr="people=Matt")
        self.assertEqual(len(sel), 1)

    def test_filter_expr_unsupported_key_raises(self):
        cat = self._catalog([{"fullPath": "/a"}])
        with self.assertRaises(ValueError):
            select_records(cat, filter_expr="zorbar=anything")

    def test_no_filter_returns_all_records(self):
        cat = self._catalog([
            {"fullPath": "/a"}, {"fullPath": "/b"}, {"fullPath": "/c"}
        ])
        sel = select_records(cat)
        self.assertEqual(len(sel), 3)


class TestParseOcrDate(unittest.TestCase):
    """`parse_ocr_date` is the Python parity of Swift's pfParseOcrDate
    — both must accept the same camcorder burn-in shapes and produce
    the same calendar date."""

    def test_canonical_three_letter_month(self):
        d = parse_ocr_date("JUN 21 1991")
        self.assertEqual((d.year, d.month, d.day), (1991, 6, 21))

    def test_with_dots(self):
        d = parse_ocr_date("JUN.21 1991")
        self.assertEqual((d.year, d.month, d.day), (1991, 6, 21))

    def test_with_pm_prefix(self):
        d = parse_ocr_date("PM 11:30 JUN.21 1991")
        self.assertEqual((d.year, d.month, d.day), (1991, 6, 21))

    def test_full_month_name(self):
        d = parse_ocr_date("DECEMBER 25 2010")
        self.assertEqual((d.year, d.month, d.day), (2010, 12, 25))

    def test_lowercase_input(self):
        d = parse_ocr_date("jun 21 1991")
        self.assertEqual((d.year, d.month, d.day), (1991, 6, 21))

    def test_none_returns_none(self):
        self.assertIsNone(parse_ocr_date("NONE"))

    def test_empty_returns_none(self):
        self.assertIsNone(parse_ocr_date(""))

    def test_time_only_returns_none(self):
        self.assertIsNone(parse_ocr_date("PM 11:30"))

    def test_invalid_day_returns_none(self):
        # Day > 31 is rejected at the regex / int-check stage.
        self.assertIsNone(parse_ocr_date("JUN 99 1991"))

    def test_two_digit_year_returns_none(self):
        # Regex requires (19|20)\d{2}, so "91" alone is not a valid year.
        self.assertIsNone(parse_ocr_date("JUN 21 91"))


class TestInferRecordDate(unittest.TestCase):
    """`infer_record_date` triangulates the date + confidence — Swift
    parity with pfInferRecordDate. Confidence buckets:
        ≥3 OCR consensus → 0.95
        2 OCR             → 0.85
        1 OCR             → 0.75
        file mtime alone  → 0.30
        nothing           → 0.0
    """

    def test_three_frame_consensus_high_confidence(self):
        # All three frames read the same date → strong.
        d, conf = infer_record_date(
            ["JUN.21 1991", "JUN 21 1991", "JUN.21 1991"],
            file_mtime=None,
        )
        self.assertEqual((d.year, d.month, d.day), (1991, 6, 21))
        self.assertEqual(conf, 0.95)

    def test_two_frame_consensus_lower(self):
        d, conf = infer_record_date(["JUN 21 1991", "JUN.21 1991"], file_mtime=None)
        self.assertEqual(conf, 0.85)

    def test_single_ocr_hit_medium(self):
        d, conf = infer_record_date(["JUN 21 1991"], file_mtime=None)
        self.assertEqual(conf, 0.75)

    def test_mtime_fallback_low_confidence(self):
        ts = datetime(2010, 5, 1, tzinfo=timezone.utc).timestamp()
        d, conf = infer_record_date([], file_mtime=ts)
        self.assertEqual((d.year, d.month, d.day), (2010, 5, 1))
        self.assertEqual(conf, 0.30)

    def test_no_signals_zero_confidence(self):
        d, conf = infer_record_date([], file_mtime=None)
        self.assertIsNone(d)
        self.assertEqual(conf, 0.0)

    def test_garbage_ocr_strings_fall_through_to_mtime(self):
        # Strings that don't parse as dates are dropped; if nothing
        # parses we fall to mtime (with 0.30 conf).
        ts = datetime(2020, 1, 1, tzinfo=timezone.utc).timestamp()
        d, conf = infer_record_date(["NONE", "PM 11:30", "", "garbage"], file_mtime=ts)
        self.assertEqual(d.year, 2020)
        self.assertEqual(conf, 0.30)


if __name__ == "__main__":
    unittest.main()
