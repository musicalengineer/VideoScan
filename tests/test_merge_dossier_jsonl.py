#!/usr/bin/env python3
"""Unit tests for scripts/merge_dossier_jsonl.py.

Cover the pure helpers (offset round-trip, atomic write, delta reading
with offset advance, malformed-line skip, delta application). The
daemon main() loop is not exercised here — those are integration
concerns and would require a sleep harness.
"""
from __future__ import annotations

import json
import shutil
import tempfile
import unittest
from pathlib import Path

# Path manipulation so the test can import the script as a module.
import sys
SCRIPTS = Path(__file__).resolve().parent.parent / "scripts"
sys.path.insert(0, str(SCRIPTS))

from merge_dossier_jsonl import (  # noqa: E402
    apply_deltas,
    atomic_write_catalog,
    load_offsets,
    read_new_deltas,
    save_offsets,
)


def _noop_log(_msg):
    """Swallow log lines — tests only care about return values."""
    pass


class TestOffsetsRoundTrip(unittest.TestCase):
    """`save_offsets` then `load_offsets` should reproduce the dict
    exactly, including across process restarts."""

    def test_round_trip_writes_and_reads(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "offsets.json"
            offsets = {"m4.jsonl": 1234, "m1.jsonl": 0, "m5.jsonl": 99999}
            save_offsets(path, offsets)
            self.assertEqual(load_offsets(path), offsets)

    def test_load_missing_file_returns_empty(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "does-not-exist.json"
            self.assertEqual(load_offsets(path), {})

    def test_load_malformed_file_returns_empty(self):
        # Corrupt file shouldn't poison the merger — empty offsets just
        # means "re-read from byte 0" which is safe + idempotent.
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "bad.json"
            path.write_text("{not valid json")
            self.assertEqual(load_offsets(path), {})

    def test_atomic_write_uses_tmp_rename(self):
        # The tmp file should not exist after the call — atomic rename
        # moves it into place.
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "offsets.json"
            save_offsets(path, {"a": 1})
            tmp_path = path.with_suffix(".json.tmp")
            self.assertFalse(tmp_path.exists())
            self.assertTrue(path.exists())


class TestReadNewDeltas(unittest.TestCase):
    """`read_new_deltas` walks *.jsonl files, advances offsets, and
    returns parsed lines. Malformed JSON lines should be skipped, not
    aborted."""

    def _make_jsonl(self, dir_path: Path, name: str, lines: list[dict]) -> Path:
        p = dir_path / name
        with p.open("w") as f:
            for d in lines:
                f.write(json.dumps(d) + "\n")
        return p

    def test_reads_all_lines_when_offset_is_zero(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            self._make_jsonl(d, "m4.jsonl", [
                {"fullPath": "/a", "fields": {"x": 1}},
                {"fullPath": "/b", "fields": {"x": 2}},
            ])
            deltas, offsets = read_new_deltas(d, {}, _noop_log)
            self.assertEqual(len(deltas), 2)
            self.assertEqual([d_["fullPath"] for _, d_ in deltas], ["/a", "/b"])
            self.assertGreater(offsets["m4.jsonl"], 0)

    def test_advances_offset_so_next_call_reads_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            self._make_jsonl(d, "m4.jsonl", [{"fullPath": "/a", "fields": {}}])
            _, offsets = read_new_deltas(d, {}, _noop_log)
            # Second call with the advanced offset should pick up nothing.
            deltas2, offsets2 = read_new_deltas(d, offsets, _noop_log)
            self.assertEqual(deltas2, [])
            self.assertEqual(offsets, offsets2)

    def test_picks_up_appended_lines_after_offset(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            p = self._make_jsonl(d, "m4.jsonl", [{"fullPath": "/a", "fields": {}}])
            _, offsets = read_new_deltas(d, {}, _noop_log)
            # Append a second line (simulating a worker writing more).
            with p.open("a") as f:
                f.write(json.dumps({"fullPath": "/b", "fields": {"new": True}}) + "\n")
            deltas2, _ = read_new_deltas(d, offsets, _noop_log)
            self.assertEqual(len(deltas2), 1)
            self.assertEqual(deltas2[0][1]["fullPath"], "/b")

    def test_skips_malformed_lines_without_aborting(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            p = d / "m4.jsonl"
            p.write_text(
                json.dumps({"fullPath": "/a", "fields": {}}) + "\n" +
                "{not valid json}\n" +
                json.dumps({"fullPath": "/c", "fields": {}}) + "\n"
            )
            deltas, _ = read_new_deltas(d, {}, _noop_log)
            self.assertEqual(len(deltas), 2)
            self.assertEqual([x[1]["fullPath"] for x in deltas], ["/a", "/c"])

    def test_handles_multiple_jsonl_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            self._make_jsonl(d, "m4.jsonl", [{"fullPath": "/a4", "fields": {}}])
            self._make_jsonl(d, "m5.jsonl", [{"fullPath": "/a5", "fields": {}}])
            self._make_jsonl(d, "m1.jsonl", [{"fullPath": "/a1", "fields": {}}])
            deltas, offsets = read_new_deltas(d, {}, _noop_log)
            paths = sorted([d_["fullPath"] for _, d_ in deltas])
            self.assertEqual(paths, ["/a1", "/a4", "/a5"])
            self.assertEqual(set(offsets.keys()), {"m4.jsonl", "m5.jsonl", "m1.jsonl"})

    def test_empty_file_returns_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            (d / "m4.jsonl").write_text("")
            deltas, _ = read_new_deltas(d, {}, _noop_log)
            self.assertEqual(deltas, [])

    def test_short_circuits_when_file_smaller_than_offset(self):
        # Edge case: a JSONL file was rotated/truncated externally.
        # If size <= last_offset, we shouldn't try to read negative
        # bytes; just no-op until the file grows past the stored offset.
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            p = d / "m4.jsonl"
            p.write_text("short\n")
            offsets = {"m4.jsonl": 10_000}
            deltas, new_offsets = read_new_deltas(d, offsets, _noop_log)
            self.assertEqual(deltas, [])
            self.assertEqual(new_offsets["m4.jsonl"], 10_000)


class TestApplyDeltas(unittest.TestCase):
    """`apply_deltas` writes fields onto catalog records matched by
    fullPath. Deltas with no matching record are skipped (logged but
    not raised)."""

    def _catalog(self, records: list[dict]) -> dict:
        return {"version": 6, "records": records}

    def test_applies_fields_to_matching_record(self):
        catalog = self._catalog([
            {"fullPath": "/a", "filename": "a", "sceneCaptions": []},
        ])
        deltas = [
            ("m4.jsonl", {"fullPath": "/a", "fields": {
                "sceneCaptions": [{"timestamp": 0.5, "text": "hi"}],
                "dossierProcessedAt": "2026-06-05T22:00:00+00:00",
            }})
        ]
        applied = apply_deltas(catalog, deltas, _noop_log)
        self.assertEqual(applied, 1)
        rec = catalog["records"][0]
        self.assertEqual(len(rec["sceneCaptions"]), 1)
        self.assertEqual(rec["sceneCaptions"][0]["text"], "hi")
        self.assertEqual(rec["dossierProcessedAt"], "2026-06-05T22:00:00+00:00")

    def test_skips_delta_with_no_matching_record(self):
        catalog = self._catalog([{"fullPath": "/a", "filename": "a"}])
        deltas = [
            ("m4.jsonl", {"fullPath": "/b", "fields": {"x": 1}}),
        ]
        applied = apply_deltas(catalog, deltas, _noop_log)
        self.assertEqual(applied, 0)
        # /a record untouched.
        self.assertNotIn("x", catalog["records"][0])

    def test_skips_delta_with_empty_path_or_fields(self):
        catalog = self._catalog([{"fullPath": "/a", "filename": "a"}])
        deltas = [
            ("m4.jsonl", {"fullPath": "", "fields": {"x": 1}}),
            ("m4.jsonl", {"fullPath": "/a", "fields": {}}),
            ("m4.jsonl", {"fullPath": "/a"}),  # no fields key at all
        ]
        applied = apply_deltas(catalog, deltas, _noop_log)
        self.assertEqual(applied, 0)

    def test_preserves_unrelated_fields_on_the_record(self):
        # The merger must NEVER blow away user-editable fields like
        # detectedPeople or notes — it copies fields by key, not by
        # whole-record replace.
        catalog = self._catalog([
            {
                "fullPath": "/a",
                "filename": "a",
                "detectedPeople": ["Matt"],
                "notes": "ground truth",
                "sceneCaptions": [],
            },
        ])
        deltas = [
            ("m4.jsonl", {"fullPath": "/a", "fields": {
                "sceneCaptions": [{"timestamp": 0.5, "text": "hi"}],
            }})
        ]
        apply_deltas(catalog, deltas, _noop_log)
        rec = catalog["records"][0]
        self.assertEqual(rec["detectedPeople"], ["Matt"])
        self.assertEqual(rec["notes"], "ground truth")
        self.assertEqual(len(rec["sceneCaptions"]), 1)

    def test_applies_in_order_when_multiple_deltas_target_one_record(self):
        # If a worker re-processes the same file (e.g. retry), the LAST
        # delta should win — apply_deltas iterates in order and the
        # second write overwrites the first.
        catalog = self._catalog([{"fullPath": "/a", "filename": "a"}])
        deltas = [
            ("m4.jsonl", {"fullPath": "/a", "fields": {"audioTranscript": "first"}}),
            ("m4.jsonl", {"fullPath": "/a", "fields": {"audioTranscript": "second"}}),
        ]
        apply_deltas(catalog, deltas, _noop_log)
        self.assertEqual(catalog["records"][0]["audioTranscript"], "second")


class TestAtomicWriteCatalog(unittest.TestCase):
    """`atomic_write_catalog` should: rotate primary → .prev, write to
    a tmp file, and rename atomically. No half-written catalog ever
    visible at the primary path."""

    def test_writes_primary_and_rotates_backup(self):
        with tempfile.TemporaryDirectory() as tmp:
            primary = Path(tmp) / "catalog.json"
            primary.write_text(json.dumps({"version": 6, "records": [{"fullPath": "/old"}]}))
            new_data = {"version": 6, "records": [{"fullPath": "/new"}]}
            atomic_write_catalog(new_data, primary)
            # Primary holds new content.
            self.assertEqual(json.loads(primary.read_text())["records"][0]["fullPath"], "/new")
            # Backup holds old content.
            backup = primary.with_suffix(".json.prev")
            self.assertTrue(backup.exists())
            self.assertEqual(json.loads(backup.read_text())["records"][0]["fullPath"], "/old")

    def test_no_tmp_file_remains_after_call(self):
        with tempfile.TemporaryDirectory() as tmp:
            primary = Path(tmp) / "catalog.json"
            atomic_write_catalog({"version": 6, "records": []}, primary)
            tmp_path = primary.with_suffix(".json.tmp")
            self.assertFalse(tmp_path.exists())

    def test_handles_missing_primary_on_first_write(self):
        # First-ever write — no existing primary to rotate. Should
        # succeed and produce the primary; backup may or may not exist
        # (we don't require one in that case).
        with tempfile.TemporaryDirectory() as tmp:
            primary = Path(tmp) / "catalog.json"
            self.assertFalse(primary.exists())
            atomic_write_catalog({"version": 6, "records": []}, primary)
            self.assertTrue(primary.exists())


if __name__ == "__main__":
    unittest.main()
