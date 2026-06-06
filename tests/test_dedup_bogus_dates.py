#!/usr/bin/env python3
"""Unit tests for scripts/dedup_bogus_dates.py.

Cover the pure helpers (`is_bogus`, `classify_records`) without
touching the on-disk catalog. The atomic write is structurally
identical to merge_dossier_jsonl's already-tested atomic_write_catalog
so we don't re-test it here.
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent.parent / "scripts"
sys.path.insert(0, str(SCRIPTS))

from dedup_bogus_dates import (  # noqa: E402
    BOGUS_2040,
    classify_records,
    is_bogus,
)


class TestIsBogus(unittest.TestCase):

    def test_exact_match_is_bogus(self):
        self.assertTrue(is_bogus(BOGUS_2040))

    def test_none_is_not_bogus(self):
        self.assertFalse(is_bogus(None))

    def test_empty_string_is_not_bogus(self):
        self.assertFalse(is_bogus(""))

    def test_other_2040_dates_are_not_bogus(self):
        # We deliberately match the sentinel BYTE-FOR-BYTE so a real
        # 2040 timestamp (when the year actually arrives) doesn't get
        # silently dropped.
        self.assertFalse(is_bogus("2040-06-15T12:00:00Z"))
        self.assertFalse(is_bogus("2040-02-06T06:28:17Z"))  # one second off
        self.assertFalse(is_bogus("2040-02-06T06:28:15Z"))  # one second under


class TestClassifyRecords(unittest.TestCase):

    def test_empty_catalog_yields_empty_classifications(self):
        drop, clear = classify_records([])
        self.assertEqual(drop, [])
        self.assertEqual(clear, [])

    def test_bogus_record_with_real_sibling_is_dropped(self):
        records = [
            {"fullPath": "/a", "dateCreatedRaw": BOGUS_2040},
            {"fullPath": "/a", "dateCreatedRaw": "2009-11-25T23:59:18Z"},
        ]
        drop, clear = classify_records(records)
        self.assertEqual(drop, [0], "bogus row at index 0 should be dropped")
        self.assertEqual(clear, [])

    def test_bogus_record_alone_is_cleared_not_dropped(self):
        records = [
            {"fullPath": "/lonely", "dateCreatedRaw": BOGUS_2040},
        ]
        drop, clear = classify_records(records)
        self.assertEqual(drop, [])
        self.assertEqual(clear, [0], "no sibling → clear the date, keep the record")

    def test_real_record_alone_is_left_alone(self):
        records = [
            {"fullPath": "/real", "dateCreatedRaw": "2010-01-01T00:00:00Z"},
        ]
        drop, clear = classify_records(records)
        self.assertEqual(drop, [])
        self.assertEqual(clear, [])

    def test_multiple_bogus_with_one_real_sibling_drops_all_bogus(self):
        # Unlikely but defensible: if two scans on different PRAM-dead
        # machines both wrote the sentinel for the same file, we drop
        # both bogus rows and keep the one real one.
        records = [
            {"fullPath": "/x", "dateCreatedRaw": BOGUS_2040},
            {"fullPath": "/x", "dateCreatedRaw": BOGUS_2040},
            {"fullPath": "/x", "dateCreatedRaw": "2008-04-12T15:00:00Z"},
        ]
        drop, clear = classify_records(records)
        self.assertEqual(sorted(drop), [0, 1])
        self.assertEqual(clear, [])

    def test_unrelated_records_in_same_catalog_are_untouched(self):
        # A bogus pair on /a must not affect a non-bogus row on /b.
        records = [
            {"fullPath": "/a", "dateCreatedRaw": BOGUS_2040},
            {"fullPath": "/a", "dateCreatedRaw": "2010-05-01T00:00:00Z"},
            {"fullPath": "/b", "dateCreatedRaw": "2015-06-01T00:00:00Z"},
        ]
        drop, clear = classify_records(records)
        self.assertEqual(drop, [0])
        self.assertEqual(clear, [])

    def test_two_bogus_records_without_a_real_sibling_both_get_cleared(self):
        # Two scans on bad-clock machines, no real sibling — clear both
        # rather than drop. Loses no records from the catalog.
        records = [
            {"fullPath": "/orphan", "dateCreatedRaw": BOGUS_2040},
            {"fullPath": "/orphan", "dateCreatedRaw": BOGUS_2040},
        ]
        drop, clear = classify_records(records)
        self.assertEqual(drop, [])
        self.assertEqual(sorted(clear), [0, 1])

    def test_index_stability(self):
        # The returned indices must reference the ORIGINAL records list,
        # not a re-sorted or filtered copy — the caller uses them to
        # mutate the list in place.
        records = [
            {"fullPath": "/x", "dateCreatedRaw": "2010-01-01T00:00:00Z"},  # idx 0
            {"fullPath": "/y", "dateCreatedRaw": BOGUS_2040},               # idx 1 - to drop
            {"fullPath": "/y", "dateCreatedRaw": "2011-02-02T00:00:00Z"},   # idx 2
            {"fullPath": "/z", "dateCreatedRaw": "2012-03-03T00:00:00Z"},   # idx 3
        ]
        drop, clear = classify_records(records)
        self.assertEqual(drop, [1])
        self.assertEqual(clear, [])


if __name__ == "__main__":
    unittest.main()
