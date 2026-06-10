#!/usr/bin/env python3
"""Unit tests for scripts/folder_date_interp.py.

The pure logic (compute_interpolations) is straightforward to test
without touching the filesystem. JSONL writing is covered by the
existing merge_dossier_jsonl test for the same shape."""
from __future__ import annotations

import unittest
from pathlib import Path
import sys

SCRIPTS = Path(__file__).resolve().parent.parent / "scripts"
sys.path.insert(0, str(SCRIPTS))

from folder_date_interp import (  # noqa: E402
    compute_interpolations,
    folder_signal_years,
    parse_iso_year,
    propose_date_for_year,
)


def rec(path: str, directory: str | None = None,
        inferred: str | None = None) -> dict:
    """Tiny record builder. `directory` defaults to the path's parent."""
    if directory is None:
        directory = path.rsplit("/", 1)[0]
    r = {
        "fullPath": path,
        "filename": path.rsplit("/", 1)[-1],
        "directory": directory,
    }
    if inferred is not None:
        r["inferredRecordDate"] = inferred
    return r


class TestParseIsoYear(unittest.TestCase):

    def test_extracts_year_from_full_iso(self):
        self.assertEqual(parse_iso_year("1991-06-15T12:00:00+00:00"), 1991)

    def test_extracts_year_from_iso_with_z(self):
        self.assertEqual(parse_iso_year("2003-12-25T00:00:00Z"), 2003)

    def test_returns_none_for_none(self):
        self.assertIsNone(parse_iso_year(None))

    def test_returns_none_for_empty(self):
        self.assertIsNone(parse_iso_year(""))

    def test_returns_none_for_garbage(self):
        self.assertIsNone(parse_iso_year("not a date"))

    def test_rejects_year_out_of_range(self):
        # 1899 / 2100 are almost certainly parse junk, not real dates.
        self.assertIsNone(parse_iso_year("1899-01-01"))
        self.assertIsNone(parse_iso_year("2100-01-01"))


class TestProposedDateFormat(unittest.TestCase):

    def test_mid_year_iso(self):
        self.assertEqual(propose_date_for_year(1991),
                         "1991-06-15T12:00:00+00:00")


class TestFolderSignalYears(unittest.TestCase):

    def test_extracts_only_records_with_inferred_date(self):
        recs = [
            rec("/a/x.mov", inferred="1991-06-15T12:00:00+00:00"),
            rec("/a/y.mov"),  # no inferred date
            rec("/a/z.mov", inferred="1992-08-01T00:00:00+00:00"),
        ]
        self.assertEqual(sorted(folder_signal_years(recs)), [1991, 1992])

    def test_empty_when_no_dates(self):
        recs = [rec("/a/x.mov"), rec("/a/y.mov")]
        self.assertEqual(folder_signal_years(recs), [])

    def test_drops_unparseable_dates(self):
        recs = [
            rec("/a/x.mov", inferred="1991-06-15T12:00:00+00:00"),
            rec("/a/y.mov", inferred="garbage"),
        ]
        self.assertEqual(folder_signal_years(recs), [1991])


class TestComputeInterpolations(unittest.TestCase):

    def test_propagates_year_from_dated_siblings_to_undated_ones(self):
        # Cape Cod 1997 folder: 2 dated, 3 undated → all 3 get 1997.
        recs = [
            rec("/Cape Cod 1997/clip01.dv", inferred="1997-06-15T12:00:00+00:00"),
            rec("/Cape Cod 1997/clip02.dv", inferred="1997-07-01T00:00:00+00:00"),
            rec("/Cape Cod 1997/clip03.dv"),
            rec("/Cape Cod 1997/clip04.dv"),
            rec("/Cape Cod 1997/clip05.dv"),
        ]
        deltas = compute_interpolations(recs)
        self.assertEqual(len(deltas), 3)
        for d in deltas:
            self.assertEqual(d["fields"]["inferredRecordDate"],
                             "1997-06-15T12:00:00+00:00")
            self.assertAlmostEqual(d["fields"]["inferredDateConfidence"], 0.55)
            self.assertEqual(d["host"], "folder-interp")
            # CRITICAL: must NOT write dossierProcessedAt — folder
            # interpolation is not dossier work.
            self.assertNotIn("dossierProcessedAt", d["fields"])

    def test_requires_min_signals_default_2(self):
        # Single signal isn't enough — too easy to spoof.
        recs = [
            rec("/A/x.mov", inferred="1991-06-15T12:00:00+00:00"),
            rec("/A/y.mov"),
            rec("/A/z.mov"),
        ]
        self.assertEqual(compute_interpolations(recs), [])

    def test_min_signals_can_be_lowered(self):
        recs = [
            rec("/A/x.mov", inferred="1991-06-15T12:00:00+00:00"),
            rec("/A/y.mov"),
        ]
        deltas = compute_interpolations(recs, min_signals=1)
        self.assertEqual(len(deltas), 1)
        self.assertEqual(deltas[0]["fullPath"], "/A/y.mov")

    def test_median_is_robust_to_outlier_year(self):
        # 4 dates from 1991, 1 from 2018 (a misdated VLM hit?). Median
        # is 1991 — outlier doesn't drag the propagation off-era.
        recs = [
            rec("/F/a.mov", inferred="1991-01-01T00:00:00+00:00"),
            rec("/F/b.mov", inferred="1991-02-01T00:00:00+00:00"),
            rec("/F/c.mov", inferred="1991-03-01T00:00:00+00:00"),
            rec("/F/d.mov", inferred="1991-04-01T00:00:00+00:00"),
            rec("/F/e.mov", inferred="2018-01-01T00:00:00+00:00"),
            rec("/F/undated.mov"),
        ]
        deltas = compute_interpolations(recs)
        self.assertEqual(len(deltas), 1)
        self.assertEqual(deltas[0]["fields"]["inferredRecordDate"],
                         "1991-06-15T12:00:00+00:00")

    def test_records_with_inferred_date_are_left_alone(self):
        # A record that already has its own dossier-inferred date must
        # NOT be overwritten by folder interpolation — dossier evidence
        # outranks coherence.
        recs = [
            rec("/F/a.mov", inferred="1991-06-15T12:00:00+00:00"),
            rec("/F/b.mov", inferred="1992-06-15T12:00:00+00:00"),
            rec("/F/c.mov", inferred="2008-12-25T12:00:00+00:00"),
            rec("/F/d.mov"),
        ]
        deltas = compute_interpolations(recs)
        self.assertEqual(len(deltas), 1)
        self.assertEqual(deltas[0]["fullPath"], "/F/d.mov")

    def test_records_with_empty_directory_skipped(self):
        recs = [
            rec("/A/x.mov", inferred="1991-06-15T12:00:00+00:00"),
            rec("/A/y.mov", inferred="1991-07-01T00:00:00+00:00"),
            # Empty directory — never a "coherent folder".
            {"fullPath": "/orphan.mov", "filename": "orphan.mov",
             "directory": ""},
        ]
        deltas = compute_interpolations(recs)
        # The orphan should not get a date.
        self.assertEqual(deltas, [])

    def test_confidence_is_configurable(self):
        recs = [
            rec("/F/a.mov", inferred="1991-06-15T12:00:00+00:00"),
            rec("/F/b.mov", inferred="1991-07-01T00:00:00+00:00"),
            rec("/F/c.mov"),
        ]
        deltas = compute_interpolations(recs, confidence=0.42)
        self.assertEqual(len(deltas), 1)
        self.assertEqual(deltas[0]["fields"]["inferredDateConfidence"], 0.42)

    def test_each_folder_independent(self):
        # Two folders: one has signals, one doesn't.
        recs = [
            rec("/Dated/x.mov", inferred="1991-06-15T12:00:00+00:00"),
            rec("/Dated/y.mov", inferred="1991-07-01T00:00:00+00:00"),
            rec("/Dated/undated.mov"),
            rec("/Undated/a.mov"),
            rec("/Undated/b.mov"),
        ]
        deltas = compute_interpolations(recs)
        self.assertEqual(len(deltas), 1)
        self.assertEqual(deltas[0]["fullPath"], "/Dated/undated.mov")

    def test_records_without_fullPath_skipped(self):
        recs = [
            rec("/F/a.mov", inferred="1991-06-15T12:00:00+00:00"),
            rec("/F/b.mov", inferred="1991-07-01T00:00:00+00:00"),
            {"filename": "c.mov", "directory": "/F"},  # no fullPath
        ]
        deltas = compute_interpolations(recs)
        self.assertEqual(deltas, [])


if __name__ == "__main__":
    unittest.main()
