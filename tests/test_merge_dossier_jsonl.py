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
    migrate_legacy_offsets,
    read_new_deltas,
    save_offsets,
    sha256_hex_of_file,
    validate_delta_fields,
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


class TestDisasterRecoveryViaOffsetReset(unittest.TestCase):
    """Regression for Rick 2026-06-07: rescan of LaCieWorkspace wiped
    the dossier fields off ~4,690 catalog records (dial dropped from
    28% → <1%). Recovery was: stop the merger, delete the offsets file
    so it replays JSONLs from byte 0, restart it. Catalog went from
    2 → 3,834 dossier records in one merger pass.

    The Swift-side fix (RescanPreservedFields) prevents the wipe at
    its source. THIS test pins the recovery channel so a future change
    to merge_dossier_jsonl.py can't silently break our ability to
    rebuild catalog from JSONL deltas — that's the only durable
    record of weeks of Qwen + Whisper compute across three nodes.

    The scenario is the disaster, end-to-end:
      1. JSONLs exist on disk (workers have been emitting them).
      2. Catalog records exist with matching fullPath but blank
         dossier fields (rescan just blew them away).
      3. Offsets file is missing/empty (operator deleted it to force
         replay).
      4. One merger pass MUST restore every dossier field that has a
         matching catalog record."""

    def _make_jsonl(self, dir_path: Path, name: str, lines: list[dict]) -> Path:
        p = dir_path / name
        with p.open("w") as f:
            for d in lines:
                f.write(json.dumps(d) + "\n")
        return p

    def test_offset_reset_replays_all_deltas_onto_wiped_catalog(self):
        # The complete disaster-recovery cycle. If this test ever goes
        # red, the merger has lost its ability to recover from a
        # dossier wipe — investigate immediately, that's the safety net.
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)

            # 1. Three workers have been emitting deltas (m4 / m1 / m5).
            self._make_jsonl(d, "m4.jsonl", [
                {"fullPath": "/Volumes/LaCieWorkspace/clipA.mov",
                 "fields": {"sceneCaptions": [{"timestamp": 1.0, "text": "birthday cake"}],
                            "dossierProcessedAt": "2026-06-05T10:00:00+00:00",
                            "dossierProcessedBy": "qwen+whisper"}},
                {"fullPath": "/Volumes/LaCieWorkspace/clipB.mov",
                 "fields": {"audioTranscript": "happy birthday Matt",
                            "dossierProcessedAt": "2026-06-05T10:05:00+00:00"}},
            ])
            self._make_jsonl(d, "m1.jsonl", [
                {"fullPath": "/Volumes/LaCieWorkspace/clipC.mov",
                 "fields": {"ocrText": [{"timestamp": 0.5, "text": "JUN 1991"}],
                            "dossierProcessedAt": "2026-06-05T11:00:00+00:00"}},
            ])
            self._make_jsonl(d, "m5.jsonl", [
                {"fullPath": "/Volumes/LaCieWorkspace/clipD.mov",
                 "fields": {"inferredRecordDate": "1991-06-21T12:00:00+00:00",
                            "inferredDateConfidence": 0.95,
                            "dossierProcessedAt": "2026-06-05T12:00:00+00:00"}},
            ])

            # 2. Catalog has the matching records (same fullPath) but
            #    dossier fields were wiped by the rescan bug — they
            #    exist but carry nothing.
            wiped_catalog = {
                "version": 6,
                "records": [
                    {"fullPath": "/Volumes/LaCieWorkspace/clipA.mov", "filename": "clipA.mov",
                     "sceneCaptions": [], "dossierProcessedAt": None,
                     "detectedPeople": ["Matt"]},   # user edits unrelated to dossier
                    {"fullPath": "/Volumes/LaCieWorkspace/clipB.mov", "filename": "clipB.mov",
                     "audioTranscript": None, "dossierProcessedAt": None},
                    {"fullPath": "/Volumes/LaCieWorkspace/clipC.mov", "filename": "clipC.mov",
                     "ocrText": [], "dossierProcessedAt": None},
                    {"fullPath": "/Volumes/LaCieWorkspace/clipD.mov", "filename": "clipD.mov",
                     "inferredRecordDate": None, "dossierProcessedAt": None},
                ],
            }

            # 3. Offsets file does not exist — operator deleted it to
            #    force full replay. load_offsets returns {}.
            offsets_path = d / "dossier-merger-offsets.json"
            self.assertFalse(offsets_path.exists())
            offsets = load_offsets(offsets_path)
            self.assertEqual(offsets, {})

            # 4. Merger pass: read ALL deltas from byte 0, apply to catalog.
            deltas, new_offsets = read_new_deltas(d, offsets, _noop_log)
            self.assertEqual(len(deltas), 4,
                             "Replay from offset 0 must read every JSONL line.")
            applied = apply_deltas(wiped_catalog, deltas, _noop_log)
            self.assertEqual(applied, 4,
                             "Every delta with a matching catalog record must apply.")

            by_path = {r["fullPath"]: r for r in wiped_catalog["records"]}

            # clipA — dossier RESTORED, unrelated user edit (detectedPeople) UNTOUCHED.
            recA = by_path["/Volumes/LaCieWorkspace/clipA.mov"]
            self.assertEqual(len(recA["sceneCaptions"]), 1)
            self.assertEqual(recA["sceneCaptions"][0]["text"], "birthday cake")
            self.assertEqual(recA["dossierProcessedAt"], "2026-06-05T10:00:00+00:00")
            self.assertEqual(recA["dossierProcessedBy"], "qwen+whisper")
            self.assertEqual(recA["detectedPeople"], ["Matt"],
                             "User edits not in the delta must survive replay.")

            # clipB
            recB = by_path["/Volumes/LaCieWorkspace/clipB.mov"]
            self.assertEqual(recB["audioTranscript"], "happy birthday Matt")
            self.assertEqual(recB["dossierProcessedAt"], "2026-06-05T10:05:00+00:00")

            # clipC
            recC = by_path["/Volumes/LaCieWorkspace/clipC.mov"]
            self.assertEqual(recC["ocrText"][0]["text"], "JUN 1991")

            # clipD
            recD = by_path["/Volumes/LaCieWorkspace/clipD.mov"]
            self.assertEqual(recD["inferredDateConfidence"], 0.95)
            self.assertEqual(recD["inferredRecordDate"], "1991-06-21T12:00:00+00:00")

            # Offsets now non-zero for every JSONL — second pass would no-op.
            self.assertEqual(set(new_offsets.keys()), {"m4.jsonl", "m1.jsonl", "m5.jsonl"})
            for k, v in new_offsets.items():
                self.assertGreater(v, 0, f"{k} offset must advance past byte 0.")

    def test_replay_is_idempotent_apply_twice_same_result(self):
        # Running the merger pass twice in a row (e.g. operator resets
        # offsets twice, or two merger processes race) must produce the
        # same final catalog state — apply_deltas writes fields by key,
        # not by accumulation. Without this, a duplicate replay could
        # corrupt list-valued fields (sceneCaptions, ocrText) by appending.
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            self._make_jsonl(d, "m4.jsonl", [
                {"fullPath": "/a.mov", "fields": {
                    "sceneCaptions": [{"timestamp": 1.0, "text": "cake"},
                                      {"timestamp": 2.0, "text": "candle"}],
                    "ocrText": [{"timestamp": 0.5, "text": "1991"}],
                    "dossierProcessedAt": "2026-06-05T10:00:00+00:00",
                }},
            ])
            catalog = {"version": 6, "records": [
                {"fullPath": "/a.mov", "filename": "a.mov",
                 "sceneCaptions": [], "ocrText": []},
            ]}

            # First pass.
            deltas, _ = read_new_deltas(d, {}, _noop_log)
            apply_deltas(catalog, deltas, _noop_log)
            first_state = json.loads(json.dumps(catalog))   # deep copy

            # Second pass from offset 0 again (simulating offset reset
            # after the operator forced another replay).
            deltas2, _ = read_new_deltas(d, {}, _noop_log)
            apply_deltas(catalog, deltas2, _noop_log)

            self.assertEqual(catalog, first_state,
                             "Replay must be idempotent — same JSONL applied twice "
                             "must not duplicate, accumulate, or otherwise diverge.")
            # Specifically: list fields stay at their original size.
            self.assertEqual(len(catalog["records"][0]["sceneCaptions"]), 2)
            self.assertEqual(len(catalog["records"][0]["ocrText"]), 1)

    def test_replay_matches_records_by_fullPath_even_after_record_rebuild(self):
        # The Swift-side wipe destroys VideoRecord instances and the
        # rescan re-creates them. The new instances have the SAME
        # fullPath (it's just the file's location on disk). The
        # merger must match on fullPath, NOT identity / object pointer
        # / row index — otherwise recovery is impossible after a wipe.
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            self._make_jsonl(d, "m4.jsonl", [
                {"fullPath": "/Volumes/X/clip.mov",
                 "fields": {"sceneCaptions": [{"timestamp": 0.0, "text": "found"}],
                            "dossierProcessedAt": "2026-06-05T10:00:00+00:00"}},
            ])
            # Rebuild scenario: same path, brand-new record dict with
            # different/extra technical fields (sizeBytes, codec) that
            # the rescan refreshed from current disk state. The merger
            # should still find this record by fullPath alone.
            rebuilt_catalog = {"version": 6, "records": [
                {"fullPath": "/Volumes/X/clip.mov", "filename": "clip.mov",
                 "sizeBytes": 999_999, "videoCodec": "hevc-NEW",  # rescan refreshed
                 "sceneCaptions": [], "dossierProcessedAt": None},
            ]}
            deltas, _ = read_new_deltas(d, {}, _noop_log)
            applied = apply_deltas(rebuilt_catalog, deltas, _noop_log)
            self.assertEqual(applied, 1)
            rec = rebuilt_catalog["records"][0]
            self.assertEqual(rec["sceneCaptions"][0]["text"], "found")
            # Rescan-refreshed technical fields are NOT clobbered.
            self.assertEqual(rec["sizeBytes"], 999_999)
            self.assertEqual(rec["videoCodec"], "hevc-NEW")


class TestSchemaValidation(unittest.TestCase):
    """Schema validation in apply_deltas — Rick 2026-06-07 audit
    identified the 'buggy worker silently corrupts records' weak link.
    apply_deltas now type-checks each known field; bad fields are
    dropped (with rest-of-delta still applying), and a delta whose
    every field is rejected counts as schema-rejected.

    Unknown field names pass through — forward-compat hook so workers
    can introduce new dossier channels without a merger update."""

    def test_validate_accepts_well_formed_dossier_fields(self):
        good = {
            "sceneCaptions": [{"timestamp": 1.0, "text": "cake"}],
            "audioTranscript": "happy birthday",
            "ocrText": [{"timestamp": 0.5, "text": "1991"}],
            "ocrDateCandidates": [{"timestamp": 0.5, "text": "JUN 1991"}],
            "inferredRecordDate": "1991-06-21T12:00:00Z",
            "inferredDateConfidence": 0.95,
            "dossierProcessedAt": "2026-06-05T10:00:00+00:00",
            "dossierProcessedBy": "qwen+whisper",
        }
        kept, rejected = validate_delta_fields(good)
        self.assertEqual(kept, good)
        self.assertEqual(rejected, [])

    def test_validate_rejects_bad_iso_date_string(self):
        # The bug the validator exists to prevent: a worker writes
        # "not a date" into dossierProcessedAt and corrupts the record.
        kept, rejected = validate_delta_fields({
            "dossierProcessedAt": "not a date",
        })
        self.assertEqual(kept, {})
        self.assertEqual(len(rejected), 1)
        self.assertEqual(rejected[0][0], "dossierProcessedAt")

    def test_validate_rejects_wrong_type_for_caption_list(self):
        # sceneCaptions must be list-of-dicts; a worker passing the
        # raw caption string would silently corrupt the record without
        # this gate.
        kept, rejected = validate_delta_fields({
            "sceneCaptions": "this is not a list",
        })
        self.assertEqual(kept, {})
        self.assertEqual(len(rejected), 1)

    def test_validate_rejects_caption_list_with_wrong_inner_shape(self):
        # Inner item missing required 'text' key — must be rejected
        # because the Swift decoder will crash on it later.
        kept, rejected = validate_delta_fields({
            "ocrText": [{"timestamp": 1.0, "no_text_key": "oops"}],
        })
        self.assertEqual(kept, {})
        self.assertEqual(len(rejected), 1)

    def test_validate_accepts_null_for_nullable_fields(self):
        # Workers may legitimately clear a field by writing null.
        good = {
            "audioTranscript": None,
            "dossierProcessedAt": None,
            "inferredDateConfidence": None,
        }
        kept, rejected = validate_delta_fields(good)
        self.assertEqual(kept, good)
        self.assertEqual(rejected, [])

    def test_validate_rejects_bool_disguised_as_number(self):
        # Python booleans are ints under the hood; we must NOT accept
        # True as a valid confidence value (it would round-trip as
        # `true` and the Swift Float? decoder would reject the whole
        # record).
        kept, rejected = validate_delta_fields({
            "inferredDateConfidence": True,
        })
        self.assertEqual(kept, {})
        self.assertEqual(len(rejected), 1)

    def test_validate_passes_unknown_fields_through(self):
        # Forward-compat: a worker adding a new dossier channel
        # ("musicSignature") should be accepted without a merger
        # update. The Swift decoder is the final gate.
        kept, rejected = validate_delta_fields({
            "musicSignature": {"genre": "pop", "tempo": 120},
            "futureChannel123": [1, 2, 3],
        })
        self.assertEqual(kept,
                         {"musicSignature": {"genre": "pop", "tempo": 120},
                          "futureChannel123": [1, 2, 3]})
        self.assertEqual(rejected, [])

    def test_validate_mixes_kept_and_rejected_fields(self):
        # Realistic: a delta has 5 fields, 1 is bad — keep the 4 good
        # ones, log the bad one. The record gets partial dossier data
        # instead of being silently corrupted by the bad field.
        kept, rejected = validate_delta_fields({
            "audioTranscript": "good",
            "sceneCaptions": [{"timestamp": 0.0, "text": "good"}],
            "dossierProcessedAt": "bad-date",     # rejected
            "dossierProcessedBy": "qwen+whisper",
            "inferredDateConfidence": 0.9,
        })
        self.assertEqual(set(kept.keys()), {
            "audioTranscript", "sceneCaptions",
            "dossierProcessedBy", "inferredDateConfidence"
        })
        self.assertEqual(len(rejected), 1)
        self.assertEqual(rejected[0][0], "dossierProcessedAt")

    def test_apply_deltas_skips_bad_fields_but_applies_rest(self):
        # End-to-end: a delta with mixed good+bad fields lands the
        # good fields on the record and skips the bad one.
        catalog = {"version": 6, "records": [
            {"fullPath": "/a", "filename": "a",
             "audioTranscript": None, "dossierProcessedAt": None,
             "sceneCaptions": []},
        ]}
        deltas = [
            ("m4.jsonl", {"fullPath": "/a", "fields": {
                "audioTranscript": "good transcript",
                "dossierProcessedAt": "not a date",     # rejected
                "sceneCaptions": [{"timestamp": 1.0, "text": "good caption"}],
            }})
        ]
        applied = apply_deltas(catalog, deltas, _noop_log)
        self.assertEqual(applied, 1, "Delta with at least one good field still counts as applied.")
        rec = catalog["records"][0]
        self.assertEqual(rec["audioTranscript"], "good transcript")
        self.assertEqual(rec["sceneCaptions"][0]["text"], "good caption")
        # The bad field was NOT applied — record keeps its prior None.
        self.assertIsNone(rec["dossierProcessedAt"])

    def test_apply_deltas_skips_whole_delta_when_all_fields_rejected(self):
        # Defensive: a delta where every field is bad must not silently
        # touch the record. Counts as "not applied" so the merger log
        # surfaces the upstream worker bug.
        catalog = {"version": 6, "records": [
            {"fullPath": "/a", "filename": "a",
             "audioTranscript": "untouched", "dossierProcessedAt": None},
        ]}
        deltas = [
            ("m4.jsonl", {"fullPath": "/a", "fields": {
                "audioTranscript": 12345,                # not a string
                "dossierProcessedAt": "garbage",         # bad date
            }})
        ]
        applied = apply_deltas(catalog, deltas, _noop_log)
        self.assertEqual(applied, 0, "All-bad delta must not count as applied.")
        rec = catalog["records"][0]
        self.assertEqual(rec["audioTranscript"], "untouched",
                         "Record must be untouched when every field was rejected.")


class TestOffsetMigration(unittest.TestCase):
    """Rick 2026-06-07: the legacy /tmp offsets path is volatile across
    reboots. The new default lives under Application Support and a
    migration shim copies the legacy file over on first run if the new
    path doesn't exist. Idempotent and silent when there's nothing to
    do."""

    def test_migrate_copies_legacy_offsets_when_new_path_missing(self):
        with tempfile.TemporaryDirectory() as tmp:
            legacy = Path(tmp) / "tmp-offsets.json"
            new = Path(tmp) / "appsupport" / "offsets.json"
            legacy.write_text('{"m4.jsonl": 4711}')
            self.assertFalse(new.exists())
            self.assertTrue(migrate_legacy_offsets(new, legacy_path=legacy))
            self.assertTrue(new.exists())
            self.assertEqual(load_offsets(new), {"m4.jsonl": 4711})

    def test_migrate_no_op_when_new_path_already_exists(self):
        # If the new path has offsets, leave them alone — don't clobber
        # with the legacy file (which may be older / wrong after a
        # reboot).
        with tempfile.TemporaryDirectory() as tmp:
            legacy = Path(tmp) / "tmp-offsets.json"
            new = Path(tmp) / "appsupport" / "offsets.json"
            new.parent.mkdir(parents=True, exist_ok=True)
            legacy.write_text('{"m4.jsonl": 1}')
            new.write_text('{"m4.jsonl": 9999}')
            self.assertFalse(migrate_legacy_offsets(new, legacy_path=legacy))
            self.assertEqual(load_offsets(new), {"m4.jsonl": 9999})

    def test_migrate_no_op_when_legacy_path_missing(self):
        # Normal steady-state: no legacy file, nothing to do.
        with tempfile.TemporaryDirectory() as tmp:
            legacy = Path(tmp) / "tmp-offsets.json"
            new = Path(tmp) / "appsupport" / "offsets.json"
            self.assertFalse(migrate_legacy_offsets(new, legacy_path=legacy))
            self.assertFalse(new.exists())

    def test_migrate_creates_parent_dir(self):
        # On a fresh Application Support setup, the parent dir may not
        # exist yet — migration must create it.
        with tempfile.TemporaryDirectory() as tmp:
            legacy = Path(tmp) / "tmp-offsets.json"
            new = Path(tmp) / "deeply" / "nested" / "appsupport" / "offsets.json"
            legacy.write_text('{"m4.jsonl": 5}')
            self.assertTrue(migrate_legacy_offsets(new, legacy_path=legacy))
            self.assertTrue(new.exists())


if __name__ == "__main__":
    unittest.main()
