"""A synthetic catalog.sqlite for the Python tests, built from the REAL DDL.

The schema is not copied: it is read out of the Swift schema files
(VideoScanCore/Sources/VideoScanCore/Store/*Schema*.swift), whose raw-SQL
string literals ARE the catalog's DDL (CatalogDataSchemaTests diffs them
against docs/design/catalog_sqlite_schema_v1.sql). So a schema change that
breaks scripts/catalog_db.py breaks these tests too.

`Catalog(tmp_path)` creates <tmp>/catalog.sqlite in WAL mode (as the app
does), with `catalog.cutover` beside it unless `latch=False`; `add(...)`
inserts one record through the same tables the app's import fills; `close()`
leaves a closed database for the code under test to open.
"""
from __future__ import annotations

import json
import re
import sqlite3
import uuid
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
STORE = REPO / "VideoScan" / "VideoScanCore" / "Sources" / "VideoScanCore" / "Store"
SCHEMA_FILES = [
    "CatalogBookkeepingSchema.swift",
    "CatalogDataSchema.swift",
    "CatalogDataSchema+Knowledge.swift",
    "CatalogDataSchema+Relations.swift",
    "CatalogDataSchema+Import.swift",
    "CatalogLiveWritesSchema.swift",
    "CatalogPendingRowsSchema.swift",
    "CatalogCommitB22Schema.swift",
]
_BLOCK = re.compile(r'"""\n(.*?)\n\s*"""', re.S)


def ddl_blocks() -> list[str]:
    """Every raw-SQL literal of the schema files, CREATE TABLEs first."""
    blocks: list[str] = []
    for name in SCHEMA_FILES:
        text = (STORE / name).read_text(encoding="utf-8")
        for body in _BLOCK.findall(text):
            sql = body.strip()
            if sql.upper().startswith("CREATE") and "\\(" not in sql:
                blocks.append(sql)
    tables = [b for b in blocks if b.upper().startswith("CREATE TABLE") or b.upper().startswith("CREATE VIRTUAL TABLE")]
    return tables + [b for b in blocks if b not in tables]


def new_id() -> str:
    return str(uuid.uuid4()).upper()


class Catalog:
    def __init__(self, folder: Path, latch: bool = True, generation: int = 3):
        self.folder = Path(folder)
        self.path = self.folder / "catalog.sqlite"
        self.conn = sqlite3.connect(self.path)
        self.conn.execute("PRAGMA journal_mode = WAL")
        for sql in ddl_blocks():
            self.conn.executescript(sql)
        self.conn.execute("INSERT INTO catalog_state (singleton, schema_version) VALUES (1, 10)")
        self.conn.execute("INSERT INTO generations (id, generation, saved_at, saved_from_host) VALUES (1, ?, 0, 'test')",
                          (generation,))
        self.conn.execute("INSERT INTO volumes (volume_uuid, last_name) VALUES ('', 'LaCie')")
        if latch:
            (self.folder / "catalog.cutover").write_text("{}")

    def add(self, path: str, *, digest: str | None = None, rid: str | None = None, size: int = 1000,
            stream: str = "Video+Audio", duration: float = 60.0, lifecycle: str = "Cataloged",
            removal: tuple[str, str] | None = None, user_date: str | None = None, stars: int | None = None,
            transcript: str | None = None, captions: list[tuple[float, str]] | None = None,
            tags: list[str] | None = None, confirmed: list[str] | None = None, detected: list[str] | None = None,
            unverified: dict[str, list] | None = None, created_at: int | None = None,
            partial_md5: str | None = None) -> str:
        """One files row (+ its content and curated/derived rows); returns the id."""
        rid = rid or new_id()
        digest = digest or uuid.uuid4().hex + uuid.uuid4().hex
        c = self.conn
        c.execute("INSERT OR IGNORE INTO content (digest, byte_count, first_seen_at, first_seen_how) "
                  "VALUES (?, ?, 0, 'import')", (digest, size))
        filename = path.rsplit("/", 1)[-1]
        state, reason = removal or (None, None)
        c.execute(
            "INSERT INTO files (id, content_digest, volume_uuid, volume_case_sensitive, full_path, path_fold, filename,"
            " ext, directory, size_bytes, fs_created_at, digest_computed_at, digest_source, partial_md5, stream_type,"
            " duration_s, lifecycle, archive_stage, removal_state, removal_since, removal_reason)"
            " VALUES (?, ?, '', 0, ?, ?, ?, ?, ?, ?, ?, 0, 'rescan', ?, ?, ?, ?, 'None', ?, ?, ?)",
            (rid, digest, path, path.lower(), filename, filename.rsplit(".", 1)[-1], path.rsplit("/", 1)[0], size,
             created_at, partial_md5, stream, duration, lifecycle, state, 1_700_000_000 if state else None, reason))
        if user_date is not None:
            c.execute("INSERT OR IGNORE INTO user_dates (digest, value) VALUES (?, ?)", (digest, user_date))
        if stars is not None:
            c.execute("INSERT OR IGNORE INTO stars (digest, rating) VALUES (?, ?)", (digest, stars))
        if transcript is not None:
            c.execute("INSERT OR IGNORE INTO transcripts (digest, text) VALUES (?, ?)", (digest, transcript))
        for seq, (at, text) in enumerate(captions or []):
            c.execute("INSERT INTO captions (digest, kind, seq, at_s, text) VALUES (?, 'scene', ?, ?, ?)",
                      (digest, seq, at, text))
        for tag in tags or []:
            c.execute("INSERT OR IGNORE INTO workflow_tags (digest, tag) VALUES (?, ?)", (digest, tag))
        for name in confirmed or []:
            c.execute("INSERT OR IGNORE INTO people_tags (digest, name, kind, confirmed_at) VALUES (?, ?, 'confirmed', 0)",
                      (digest, name))
        for name in detected or []:
            c.execute("INSERT OR IGNORE INTO people_tags (digest, name, kind, provenance) VALUES (?, ?, 'detected', 'bound')",
                      (digest, name))
        for kind, values in (unverified or {}).items():
            for seq, value in enumerate(values):
                c.execute("INSERT INTO derived_unverified (digest, kind, seq, source_json_row_id, value_json) "
                          "VALUES (?, ?, ?, ?, ?)", (digest, kind, seq, rid, json.dumps(value)))
        return rid

    def hold(self, record: dict) -> None:
        """A new record the app holds in pending_rows (no whole-file hash yet)."""
        self.conn.execute("INSERT INTO pending_rows (id, json, queued_at) VALUES (?, ?, 0)",
                          (record["id"], json.dumps(record)))

    def close(self) -> Path:
        self.conn.commit()
        self.conn.close()
        return self.path
