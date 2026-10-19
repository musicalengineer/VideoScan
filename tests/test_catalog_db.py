"""scripts/catalog_db.py — the scripts' read of catalog.sqlite follows the
app's load (GRDBCatalogRepository+Load.swift), on a synthetic catalog built
from the real DDL (tests/catalog_sqlite_fixture.py):

  * a purged row is not a record; a row marked missing / in the Trash is,
    with its removal marker (the scripts filter as they did on catalog.json);
  * curated values are shared by every copy of one content (digest-keyed);
  * a bound derived value beats the row's own imported (unverified) value,
    kind by kind; with no bound value the row's OWN unverified value is used,
    never a sibling copy's;
  * a held record (pending_rows, no whole-file hash yet) is included from its
    stored payload; a purged held record is not;
  * SCALE: 20k rows read within a generous budget.
"""
from __future__ import annotations

import json
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "tests"))

import catalog_db  # noqa: E402
from catalog_sqlite_fixture import Catalog, new_id  # noqa: E402


def _by_path(records):
    return {r["fullPath"]: r for r in records}


def test_purged_rows_are_not_records_but_removed_ones_carry_their_marker(tmp_path):
    db = Catalog(tmp_path)
    db.add("/Volumes/LaCie/live.mov")
    db.add("/Volumes/LaCie/purged.mov", removal=("removedFromCatalog", "purged"))
    db.add("/Volumes/LaCie/missing.mov", removal=("missing", "legacyDeleted"))
    recs, generation = catalog_db.load(db.close())
    got = _by_path(recs)
    assert set(got) == {"/Volumes/LaCie/live.mov", "/Volumes/LaCie/missing.mov"}
    assert got["/Volumes/LaCie/live.mov"]["removal"] is None
    assert got["/Volumes/LaCie/missing.mov"]["removal"]["state"] == "missing"
    assert generation == 3


def test_curated_values_are_shared_by_copies(tmp_path):
    db = Catalog(tmp_path)
    digest = "d" * 64
    db.add("/Volumes/A/tape.mov", digest=digest, user_date="1984-11", stars=3, tags=["Thanksgiving"],
           confirmed=["Donna"])
    db.add("/Volumes/B/tape.mov", digest=digest)
    got = _by_path(catalog_db.load(db.close())[0])
    for path in ("/Volumes/A/tape.mov", "/Volumes/B/tape.mov"):
        r = got[path]
        assert r["userDate"] == "1984-11" and r["starRating"] == 3 and r["tags"] == ["Thanksgiving"]
        assert [p["name"] for p in r["confirmedByUserPeople"]] == ["Donna"]
        assert r["contentFixity"] == {"sha256": digest}


def test_bound_beats_unverified_and_unverified_is_the_rows_own(tmp_path):
    db = Catalog(tmp_path)
    shared = "e" * 64
    own = db.add("/Volumes/A/a.mov", digest=shared,
                 unverified={"transcript": ["old words"], "scene": [{"timestamp": 1, "text": "old scene"}]})
    db.add("/Volumes/B/a.mov", digest=shared)                      # a sibling copy: carries nothing of its own
    db.add("/Volumes/C/c.mov", transcript="bound words",
           unverified={"transcript": ["stale words"]}, captions=[(2.0, "bound scene")], detected=["Matt"])
    got = _by_path(catalog_db.load(db.close())[0])
    a = got["/Volumes/A/a.mov"]
    assert a["id"] == own and a["audioTranscript"] == "old words"
    assert a["sceneCaptions"] == [{"timestamp": 1, "text": "old scene"}]
    assert "audioTranscript" not in got["/Volumes/B/a.mov"]       # never a sibling's unverified value
    c = got["/Volumes/C/c.mov"]
    assert c["audioTranscript"] == "bound words"
    assert c["sceneCaptions"] == [{"timestamp": 2.0, "text": "bound scene"}]
    assert c["detectedPeople"] == ["Matt"]


def test_held_records_are_included_from_their_payload(tmp_path):
    db = Catalog(tmp_path)
    held = {"id": new_id(), "fullPath": "/Volumes/New/fresh.mov", "filename": "fresh.mov", "streamTypeRaw": "Video only"}
    db.hold(held)
    gone = {"id": new_id(), "fullPath": "/Volumes/New/gone.mov"}
    db.hold(gone)
    db.conn.execute("INSERT INTO pending_purges (id, purged_at, door) VALUES (?, 0, 'test')", (gone["id"],))
    got = _by_path(catalog_db.load(db.close())[0])
    assert got["/Volumes/New/fresh.mov"]["streamTypeRaw"] == "Video only"
    assert "/Volumes/New/gone.mov" not in got


def test_scale_20k_rows(tmp_path):
    db = Catalog(tmp_path)
    for i in range(20_000):
        db.add(f"/Volumes/LaCie/clip{i:05d}.mov", captions=[(0.0, "a lawn")], transcript="hello")
    path = db.close()
    start = time.monotonic()
    recs, _ = catalog_db.load(path)
    elapsed = time.monotonic() - start
    assert len(recs) == 20_000
    assert elapsed < 20, f"20k rows took {elapsed:.1f}s"
    json.dumps(recs[0])  # plain, serialisable values


def test_hallie_snapshot_exports_from_catalog_sqlite(tmp_path):
    """scripts/hallie_demo/snapshot.py's catalog side reads catalog.sqlite and skips purged / trashed rows."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("hallie_snapshot", ROOT / "scripts" / "hallie_demo" / "snapshot.py")
    snapshot = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(snapshot)
    db = Catalog(tmp_path)
    db.add("/Volumes/LaCie/AtHudsons-Thanksgiving-1984.mov", tags=["Hudson Family"], confirmed=["Donna"],
           transcript="happy thanksgiving")
    db.add("/Volumes/LaCie/purged.mov", removal=("removedFromCatalog", "purged"))
    db.add("/Volumes/LaCie/trashed.mov", lifecycle="Trashed", removal=("inTrash", "user"))
    db.close()
    catalog, meta = snapshot.build_catalog(str(tmp_path))
    assert [r["filename"] for r in catalog["records"]] == ["AtHudsons-Thanksgiving-1984.mov"]
    rec = catalog["records"][0]
    assert rec["year"] == 1984 and rec["yearSource"] == "filename"
    assert rec["confirmedPeople"] == ["Donna"] and rec["tags"] == ["Hudson Family"]
    assert rec["transcriptSnippet"] == "happy thanksgiving" and rec["volume"] == "LaCie"
    assert meta["generation"] == 3 and meta["recordsInCatalog"] == 2
    assert meta["skipped"] == {"purged": 0, "deletedOrTrashed": 1}
