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
    compute_manifest_lines,
    load_offsets,
    read_new_deltas,
    save_offsets,
    sha256_hex_of_file,
    write_manifest,
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


class TestManifestWriter(unittest.TestCase):
    """`write_manifest` + `compute_manifest_lines` must match the
    Swift master's manifest format byte-for-byte so the viewer's
    verifyManifest step accepts what we wrote. Regression for the
    'MASTER OFFLINE / sha256 mismatch' bug Rick hit 2026-06-06 — the
    merger was updating catalog.json without re-stamping manifest
    so viewer rsync succeeded but the manifest verify failed.
    """

    def _setup_minimal_root(self, tmp: str) -> Path:
        """Build the smallest root_dir the manifest cares about:
        catalog.json + a tiny POI subtree."""
        root = Path(tmp)
        (root / "catalog.json").write_text('{"version":6,"records":[]}')
        (root / "catalog.json.prev").write_text('{"version":6,"records":[]}')
        poi = root / "POI" / "donna"
        poi.mkdir(parents=True)
        (poi / "ref_001.jpg").write_bytes(b"\xff\xd8\xff\xe0fake-jpeg")
        (poi / "ref_002.jpg").write_bytes(b"\xff\xd8\xff\xe0another")
        return root

    def test_sha256_hex_of_file_matches_known_value(self):
        # Locked-in known hash for "abc" — sanity check that we're
        # calling the same algorithm the Swift side uses.
        # SHA-256("abc") = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
        with tempfile.NamedTemporaryFile("wb", delete=False) as f:
            f.write(b"abc")
            path = Path(f.name)
        try:
            self.assertEqual(
                sha256_hex_of_file(path),
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
            )
        finally:
            path.unlink()

    def test_compute_manifest_lines_format_matches_shasum(self):
        # Each line is "<sha256_hex>  <relpath>" with two spaces — same
        # as `shasum -a 256 <file>` so `shasum -a 256 -c manifest.sha256`
        # can verify the output.
        with tempfile.TemporaryDirectory() as tmp:
            root = self._setup_minimal_root(tmp)
            lines = compute_manifest_lines(root)
            self.assertTrue(len(lines) >= 4,
                            "Expected catalog + .prev + 2 POI files at minimum")
            for line in lines:
                # 64-char hex hash + two spaces + path
                self.assertRegex(line, r"^[0-9a-f]{64}  \S")

    def test_compute_manifest_lines_sorted_by_relpath(self):
        # Sorting is required because the Swift verifier compares
        # lines order-sensitively.
        with tempfile.TemporaryDirectory() as tmp:
            root = self._setup_minimal_root(tmp)
            lines = compute_manifest_lines(root)
            relpaths = [l.split("  ", 1)[1] for l in lines]
            self.assertEqual(relpaths, sorted(relpaths))

    def test_compute_manifest_lines_skips_hidden_files_in_poi(self):
        # macOS sprinkles .DS_Store everywhere; we must NOT hash them
        # because the Swift side skips them and would mismatch.
        with tempfile.TemporaryDirectory() as tmp:
            root = self._setup_minimal_root(tmp)
            (root / "POI" / "donna" / ".DS_Store").write_bytes(b"junk")
            lines = compute_manifest_lines(root)
            self.assertFalse(any(".DS_Store" in l for l in lines),
                             "Hidden files must be skipped to match Swift output")

    def test_compute_manifest_lines_handles_missing_roots_gracefully(self):
        # An older install might not have POI yet — that's fine, just
        # produce the catalog lines and move on.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "catalog.json").write_text('{}')
            lines = compute_manifest_lines(root)
            self.assertEqual(len(lines), 1)
            self.assertIn("catalog.json", lines[0])

    def test_write_manifest_round_trips_through_disk(self):
        # End-to-end: write the manifest, re-compute, expect same lines.
        with tempfile.TemporaryDirectory() as tmp:
            root = self._setup_minimal_root(tmp)
            n = write_manifest(root)
            self.assertGreaterEqual(n, 4)
            manifest = (root / "manifest.sha256").read_text()
            lines_on_disk = [l for l in manifest.split("\n") if l]
            recomputed = compute_manifest_lines(root)
            # The manifest itself is NOT in manifestRoots, so writing
            # it doesn't change the recomputed lines.
            self.assertEqual(lines_on_disk, recomputed)

    def test_write_manifest_is_atomic_no_tmp_left_behind(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = self._setup_minimal_root(tmp)
            write_manifest(root)
            tmp_path = root / "manifest.sha256.tmp"
            self.assertFalse(tmp_path.exists(),
                             "tmp file must be renamed away, not left behind")

    def test_manifest_changes_when_catalog_changes(self):
        # The whole point of re-stamping after a write: when catalog
        # changes, the manifest hash for catalog.json must change too.
        with tempfile.TemporaryDirectory() as tmp:
            root = self._setup_minimal_root(tmp)
            lines_v1 = compute_manifest_lines(root)
            (root / "catalog.json").write_text('{"version":6,"records":[1]}')
            lines_v2 = compute_manifest_lines(root)
            self.assertNotEqual(lines_v1, lines_v2,
                                "Manifest must reflect the catalog change")


if __name__ == "__main__":
    unittest.main()
