#!/usr/bin/env python3
"""catalog_db.py — the ONE door Python scripts use to read the catalog.

Since the 2026-10-18 cutover the catalog lives in catalog.sqlite (GRDB,
schema in VideoScan/VideoScanCore/Sources/VideoScanCore/Store/), and
catalog.json is frozen. Rick, 2026-10-19: "jettison json as fast as we can
while still being responsible" — so scripts READ catalog.sqlite, through
this module only, and never write it:

  * `connect()` opens the file with the SQLite URI `?mode=ro` (the engine
    refuses every write) and `PRAGMA query_only`, and refuses outright when
    `catalog.cutover` is not beside it (the catalog was never switched) —
    there is no fallback to catalog.json;
  * `records()` gives the live records as plain dicts keyed by the old
    catalog.json names (fullPath, sceneCaptions, userDate, …) so a script's
    logic reads as it did. The mapping follows the app's own load
    (GRDBCatalogRepository+Load.swift): rows the app purged are skipped,
    curated values whose copies disagree read as empty, and a derived value
    (captions, transcript, inferred date, machine-found people) comes from
    its bound table when there is one, else from this row's own imported
    `derived_unverified` value. New records the app holds in `pending_rows`
    (no whole-file hash yet) are included from their stored payload.

tests/test_no_script_writes_catalog.py is the sensor: no script under
scripts/ or tools/ writes catalog.json, and only this file names
catalog.sqlite.
"""
from __future__ import annotations

import json
import sqlite3
import urllib.parse
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

APP_SUPPORT = Path.home() / "Library" / "Application Support" / "VideoScan"
DATABASE_FILE_NAME = "catalog.sqlite"
LATCH_FILE_NAME = "catalog.cutover"
DEFAULT_DATABASE = APP_SUPPORT / DATABASE_FILE_NAME


class CatalogUnavailable(RuntimeError):
    """The catalog cannot be read; the message says why, in plain words."""


def preflight(db_path: Path) -> None:
    """Raise CatalogUnavailable unless `db_path` is a switched catalog.sqlite."""
    db_path = Path(db_path)
    if db_path.suffix.lower() == ".json":
        raise CatalogUnavailable(
            f"{db_path} is catalog.json, which is frozen since the switch to SQLite — "
            f"read {DATABASE_FILE_NAME} instead")
    latch = db_path.parent / LATCH_FILE_NAME
    if not latch.exists():
        raise CatalogUnavailable(
            f"no {LATCH_FILE_NAME} beside {db_path}: this folder holds no switched {DATABASE_FILE_NAME}. "
            "Read the catalog folder VideoScan uses (or restore it from the catalog backup); "
            "if VideoScan says saving stopped, use Catalog > Reopen SQLite Catalog "
            "(catalog.json is not read as a fallback)")
    if not db_path.exists():
        raise CatalogUnavailable(
            f"{LATCH_FILE_NAME} says the catalog is in SQLite, but there is no "
            f"{DATABASE_FILE_NAME} at {db_path}")


def connect(db_path: Path | str | None = None) -> sqlite3.Connection:
    """Open catalog.sqlite READ-ONLY (URI mode=ro + query_only)."""
    path = Path(db_path).expanduser() if db_path else DEFAULT_DATABASE
    preflight(path)
    uri = "file:" + urllib.parse.quote(str(path.resolve())) + "?mode=ro"
    conn = sqlite3.connect(uri, uri=True)
    conn.execute("PRAGMA query_only = ON")
    conn.row_factory = sqlite3.Row
    return conn


def generation(conn: sqlite3.Connection) -> int:
    row = conn.execute("SELECT generation FROM generations WHERE id = 1").fetchone()
    return int(row[0]) if row else 0


def iso(unix_seconds) -> str | None:
    """Unix seconds → the ISO-8601 text catalog.json carried (UTC, 'Z')."""
    if unix_seconds is None:
        return None
    return datetime.fromtimestamp(int(unix_seconds), tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# The app's main load SELECT, trimmed to what scripts read.
_MAIN = """
SELECT f.id, f.content_digest, f.full_path, f.filename, f.ext, f.directory, f.size_bytes,
       f.fs_created_at, f.fs_modified_at, f.sampled_hash, f.partial_md5, f.stream_type, f.duration_s,
       f.container, f.video_codec, f.audio_codec, f.embedded_created_at, f.embedded_created_source,
       f.machine_notes, f.lifecycle, f.archive_stage, f.removal_state, f.removal_since, f.removal_reason,
       v.volume_uuid, v.last_name,
       dm.group_id, dm.confidence, dm.disposition,
       st.rating, st.conflict,
       ud.value, ud.confidence, ud.conflict,
       up.place, up.confidence, up.conflict,
       un.text, un.conflict,
       di.disposition, di.conflict
  FROM files f
  JOIN volumes v ON v.volume_uuid = f.volume_uuid
  LEFT JOIN duplicate_members dm ON dm.file_id = f.id
  LEFT JOIN stars st ON st.digest = f.content_digest
  LEFT JOIN user_dates ud ON ud.digest = f.content_digest
  LEFT JOIN user_places up ON up.digest = f.content_digest
  LEFT JOIN user_notes un ON un.digest = f.content_digest
  LEFT JOIN dispositions di ON di.digest = f.content_digest
 ORDER BY f.content_digest, f.id
"""


def _shown(value, conflict):
    """A curated display value; a conflict between copies reads as empty (the app's rule)."""
    return None if conflict else value


def _derived_bound(conn) -> dict[str, dict[str, list]]:
    """digest → kind → [(seq, value)] from the bound derived tables (the app's arms)."""
    out: dict[str, dict[str, list]] = defaultdict(lambda: defaultdict(list))
    for r in conn.execute("SELECT digest, seq, at_s, text FROM captions WHERE kind = 'scene'"):
        out[r[0]]["scene"].append((r[1], {"timestamp": r[2], "text": r[3]}))
    for r in conn.execute("SELECT digest, text FROM transcripts"):
        out[r[0]]["transcript"].append((0, r[1]))
    for r in conn.execute("SELECT digest, processed_at, processed_by FROM dossiers"):
        out[r[0]]["dossier"].append((0, {"dossierProcessedAt": iso(r[1]), "dossierProcessedBy": r[2]}))
    for r in conn.execute("SELECT digest, date_at, confidence, source, range_start, range_end, reason FROM inferred_dates"):
        out[r[0]]["inferredDate"].append((0, {
            "inferredRecordDate": iso(r[1]), "inferredDateConfidence": r[2], "inferredDateSource": r[3],
            "inferredDateRange": None if r[4] is None else {"startYear": r[4], "endYear": r[5]},
            "inferredDateReason": r[6]}))
    for r in conn.execute("SELECT digest, name, kind FROM people_tags WHERE kind IN ('detected','suspected') "
                          "ORDER BY digest, kind, name"):
        kind = "detectedPerson" if r[2] == "detected" else "suspectedPerson"
        out[r[0]][kind].append((len(out[r[0]][kind]), r[1]))
    return out


_UNVERIFIED_KINDS = ("scene", "transcript", "dossier", "inferredDate", "detectedPerson", "suspectedPerson")


def _derived_unverified(conn) -> dict[tuple[str, str], dict[str, list]]:
    """(digest, row id) → kind → [(seq, value)] — the row's OWN imported values."""
    out: dict[tuple[str, str], dict[str, list]] = defaultdict(lambda: defaultdict(list))
    marks = ",".join("?" * len(_UNVERIFIED_KINDS))
    for r in conn.execute(f"SELECT digest, source_json_row_id, kind, seq, value_json FROM derived_unverified "
                          f"WHERE kind IN ({marks})", _UNVERIFIED_KINDS):
        out[(r[0], r[1])][r[2]].append((r[3], json.loads(r[4])))
    return out


def _apply_derived(rec: dict, kinds: dict[str, list]) -> None:
    def values(kind):
        return [v for _, v in sorted(kinds.get(kind, []), key=lambda p: p[0])]
    if "scene" in kinds:
        rec["sceneCaptions"] = values("scene")
    if "transcript" in kinds:
        rec["audioTranscript"] = values("transcript")[0]
    for kind in ("dossier", "inferredDate"):
        if kind in kinds:
            rec.update({k: v for k, v in values(kind)[0].items() if v is not None})
    if "detectedPerson" in kinds:
        rec["detectedPeople"] = values("detectedPerson")
    if "suspectedPerson" in kinds:
        rec["suspectedPeople"] = values("suspectedPerson")


def records(conn: sqlite3.Connection) -> list[dict]:
    """Every record the app loads, as catalog.json-shaped dicts (read-only)."""
    tags: dict[str, list[str]] = defaultdict(list)
    for r in conn.execute("SELECT digest, tag FROM workflow_tags ORDER BY digest, tag"):
        tags[r[0]].append(r[1])
    people: dict[str, list] = defaultdict(list)
    for r in conn.execute("SELECT digest, name, kind, confirmed_at, conflict FROM people_tags "
                          "WHERE kind IN ('confirmed','rejected') ORDER BY digest, kind, name"):
        people[r[0]].append(r)
    bound = _derived_bound(conn)
    unverified = _derived_unverified(conn)

    out: list[dict] = []
    for r in conn.execute(_MAIN):
        (rid, digest, full_path, filename, ext, directory, size, created, modified, sampled, md5, stream,
         duration, container, vcodec, acodec, embedded, embedded_src, notes, lifecycle, archive_stage,
         removal_state, removal_since, removal_reason, volume_uuid, volume_name,
         dup_group, dup_conf, dup_disp, stars, stars_c, udate, udate_conf, udate_c,
         place, place_conf, place_c, unotes, unotes_c, dispo, dispo_c) = tuple(r)
        if removal_state == "removedFromCatalog" and removal_reason == "purged":
            continue  # the app purged it (CatalogCommitWords.isPurged)
        rec = {
            "id": rid, "fullPath": full_path, "filename": filename, "ext": ext, "directory": directory,
            "sizeBytes": size, "durationSeconds": duration, "streamTypeRaw": stream,
            "container": container, "videoCodec": vcodec, "audioCodec": acodec,
            "partialMD5": md5 or "", "contentHash": sampled or "",
            "contentFixity": {"sha256": digest} if digest else None,
            "dateCreatedRaw": iso(created), "dateModifiedRaw": iso(modified),
            "embeddedCreationDate": iso(embedded), "embeddedCreationSource": embedded_src,
            "notes": notes, "lifecycleStage": lifecycle, "archiveStage": archive_stage,
            "scanContext": {"volumeName": volume_name, "volumeUUID": volume_uuid},
            "removal": None if removal_state is None else
                {"state": removal_state, "since": iso(removal_since), "reason": removal_reason},
            # catalog.json's purgedAt: the row is out of the catalog (legacy purges included).
            "purgedAt": iso(removal_since) if removal_state == "removedFromCatalog" else None,
            "duplicateGroupID": dup_group, "duplicateConfidence": dup_conf, "duplicateDisposition": dup_disp,
            "starRating": _shown(stars, stars_c) or 0,
            "userDate": _shown(udate, udate_c), "userDateConfidence": _shown(udate_conf, udate_c),
            "userPlace": _shown(place, place_c), "userPlaceConfidence": _shown(place_conf, place_c),
            "userNotes": _shown(unotes, unotes_c), "mediaDisposition": _shown(dispo, dispo_c),
            "tags": [], "confirmedByUserPeople": [], "rejectedPeople": [],
        }
        if digest:
            rec["tags"] = list(tags.get(digest, []))
            mine = people.get(digest, [])
            if not any(p[4] for p in mine):  # any conflict ⇒ both lists read as empty (the app's rule)
                rec["confirmedByUserPeople"] = [{"name": p[1], "confirmedAt": iso(p[3])}
                                                for p in mine if p[2] == "confirmed"]
                rec["rejectedPeople"] = [p[1] for p in mine if p[2] == "rejected"]
            kinds = dict(bound.get(digest, {}))
            for kind, vals in unverified.get((digest, rid), {}).items():
                kinds.setdefault(kind, vals)  # bound beats unverified, kind by kind
            _apply_derived(rec, kinds)
        out.append(rec)

    stored = {rec["id"] for rec in out}
    for r in conn.execute("SELECT id, json FROM pending_rows p "
                          "WHERE NOT EXISTS (SELECT 1 FROM pending_purges q WHERE q.id = p.id) ORDER BY id"):
        if r[0] in stored:
            continue
        try:
            out.append(json.loads(r[1]))  # the app encoder's record payload — catalog.json's shape
        except ValueError:
            continue
    return out


def load(db_path: Path | str | None = None) -> tuple[list[dict], int]:
    """connect + records + generation, then close. Raises CatalogUnavailable."""
    conn = connect(db_path)
    try:
        return records(conn), generation(conn)
    finally:
        conn.close()
