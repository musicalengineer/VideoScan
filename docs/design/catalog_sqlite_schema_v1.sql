-- catalog_sqlite_schema_v1.sql — VideoScan catalog, SQLite schema v1.1 (DESIGN, not built)
-- Step B of docs/design/catalog_sqlite_migration_2026_10_16.md §10 (contract freeze, 2026-10-17;
-- revision 2 closes codex's 12 findings, docs/reviews/codex/
-- codex-review-contract-freeze-sqlite-schema-v1-step-b-2026-10-17.md; each change cites `-- F<N>`).
-- Companion: docs/design/catalog_contract_freeze_2026_10_17.md (field inventory, invariants,
-- importer gate §f, reconciliation §g). Reproductions: catalog_sqlite_schema_v1_checks.sql
-- (`sqlite3 :memory: < catalog_sqlite_schema_v1_checks.sql`). GH #328.
--
-- THE ONE RULE (§10): identity is the whole-file SHA-256 (64 lowercase hex), never the path and
-- never the sampled `v1:` contentHash. Knowledge (people, dates, places, stars, captions,
-- transcripts, sound prints, lineage, events) is keyed by DIGEST so a rescanned file re-attaches to
-- it wherever it now sits. Rows (`files`) are WHERE content is; `content` is WHAT it is.
-- And its companion (r2): NOTHING THE JSON CARRIED IS MERGED AWAY. Every imported occurrence is a
-- row keyed by (import_run, source_ordinal); the per-content tables hold only the DISPLAY choice.
--
-- Conventions
--   * Every table is STRICT (SQLite >= 3.37; macOS 13 ships 3.39). Every timestamp is INTEGER
--     unix seconds UTC: the JSON catalog encodes dates with JSONEncoder `.iso8601` (CatalogStore
--     .swift:1322), which carries whole seconds only, so INTEGER seconds is lossless for imported
--     values. FileIdentityStamp's mtime/ctime stay INTEGER nanoseconds (as stored today).
--   * UUIDs are TEXT, uppercase, 36 chars (Foundation's UUID encoding).
--   * Digests are TEXT, lowercase, 64 hex; `storedFullDigest` (VideoScanModel+Cleanup.swift:124)
--     lowercases archive digests — the importer lowercases every digest before insert, and strips
--     the `sha256:` prefix a sound-print stamp carries before it is a digest.
--   * Lineage / knowledge references are ON DELETE RESTRICT (§9.2: "no ON DELETE SET NULL").
--     Nothing in this schema is ever deleted to express "gone": a file row carries its removal
--     state; content rows are never deleted while anything refers to them.
--   * Imported evidence is keyed by (import_run, source_ordinal): the 0-based position of the
--     occurrence in its source file. A JSON UUID is a NON-unique column next to it.            -- F4
--   * The importer uses plain INSERT only. No `INSERT OR REPLACE` / `REPLACE` / `ON CONFLICT DO
--     UPDATE` anywhere: a duplicate is a finding, never a replacement. Every evidence table also
--     carries a `*_no_replace` trigger, because REPLACE deletes the old row WITHOUT firing delete
--     triggers (recursive_triggers is off) — BEFORE INSERT triggers fire before the conflict is
--     resolved, so they can refuse it.                                                         -- F4
--   * Enum CHECKs list the raw values written by the Swift enums today (cited in the .md §a/§b).

PRAGMA foreign_keys = ON;          -- per connection; the store asserts it after open (§9.2)
PRAGMA journal_mode = WAL;         -- persistent in the file
PRAGMA synchronous = FULL;
PRAGMA fullfsync = ON;             -- macOS: FULL alone does not flush the drive (§9.5)
PRAGMA user_version = 7;           -- JSON schema was v6 (CatalogStore.swift:79); SQLite starts at 7

-- ---------------------------------------------------------------------------------------------
-- 1. Catalog state and the generation counter.                                                -- F8
--    The CAS runs INSIDE the write transaction, against the counter itself:
--      UPDATE generations SET generation = generation + 1, saved_at = :now, saved_from_host = :host
--       WHERE id = 1 AND generation = :expected;      -- changes() must be 1, else ROLLBACK
--    The HIGH-WATER is NOT in this database: a restore of the database would rewind it. It lives
--    in `catalog.highwater` beside the database (one integer, written atomically after every
--    commit, never lowered) and each value is also appended to ledger/media-ledger.jsonl
--    (`generationHighWater`). At open: a database whose generation is BELOW the high-water opens
--    READ-ONLY with the named refusal `restoredBelowHighWater` ("this catalog is older than one
--    this Mac already wrote — restore refused for writing; open the newer copy or adopt this one
--    explicitly"). Adopting a restore is a person's act that raises the database to the
--    high-water first (one CAS step per generation is NOT replayed: adoption writes one
--    `generation_history` row with writer 'adoptRestore').
-- ---------------------------------------------------------------------------------------------
CREATE TABLE catalog_state (
  singleton        INTEGER PRIMARY KEY NOT NULL CHECK (singleton = 1),
  schema_version   INTEGER NOT NULL CHECK (schema_version >= 7),
  master_archive   TEXT    CHECK (master_archive IS NULL OR json_valid(master_archive)), -- MasterArchiveDesignation
  imported_from    TEXT    -- 'catalog.json gen <N> sha256 <hex>' — the frozen backup this DB came from (§10 F′)
) STRICT;

CREATE TABLE generations (                -- the CAS counter (one row)                          -- F8
  id               INTEGER PRIMARY KEY NOT NULL CHECK (id = 1),
  generation       INTEGER NOT NULL CHECK (generation >= 0),
  saved_at         INTEGER NOT NULL,
  saved_from_host  TEXT    NOT NULL
) STRICT;

CREATE TRIGGER generations_step_by_one                                                       -- F8
BEFORE UPDATE OF generation ON generations
WHEN NEW.generation <> OLD.generation + 1
BEGIN SELECT RAISE(ABORT, 'generation must advance by exactly one (CAS)'); END;
CREATE TRIGGER generations_no_delete BEFORE DELETE ON generations
BEGIN SELECT RAISE(ABORT, 'the generation counter is never deleted'); END;

-- One row per committed generation (the CAS history; §4), written in the same transaction.
CREATE TABLE generation_history (
  generation   INTEGER PRIMARY KEY NOT NULL CHECK (generation >= 0),
  committed_at INTEGER NOT NULL,
  host         TEXT    NOT NULL,
  writer       TEXT    NOT NULL,           -- the door: 'import','rescan','promote','audit','ui','adoptRestore', …
  files_live   INTEGER NOT NULL CHECK (files_live >= 0),
  files_total  INTEGER NOT NULL CHECK (files_total >= 0),
  export_sha256 TEXT CHECK (export_sha256 IS NULL OR (length(export_sha256) = 64 AND export_sha256 NOT GLOB '*[^0-9a-f]*'))
) STRICT;
CREATE TRIGGER generation_history_names_this_commit                                         -- F8
BEFORE INSERT ON generation_history
WHEN NEW.generation IS NOT (SELECT generation FROM generations WHERE id = 1)
BEGIN SELECT RAISE(ABORT, 'a history row names the generation this transaction advanced to'); END;

-- ---------------------------------------------------------------------------------------------
-- 2. content — ONE row per whole-file SHA-256. §10: "identity is the whole-file SHA-256".
--    A content row may exist with NO live file (a quarantined row's knowledge, a trashed file's
--    history); the rescan re-attaches files to it by digest (contract §g).
-- ---------------------------------------------------------------------------------------------
CREATE TABLE content (
  digest          TEXT    PRIMARY KEY NOT NULL
                  CHECK (length(digest) = 64 AND digest NOT GLOB '*[^0-9a-f]*'),
  algorithm       TEXT    NOT NULL DEFAULT 'sha256' CHECK (algorithm = 'sha256'),
  byte_count      INTEGER NOT NULL CHECK (byte_count >= 0),
  first_seen_at   INTEGER NOT NULL,        -- earliest computedAt/verifiedAt the import or rescan saw
  first_seen_how  TEXT    NOT NULL CHECK (first_seen_how IN ('import','rescan','job'))
) STRICT, WITHOUT ROWID;

-- ---------------------------------------------------------------------------------------------
-- 3. volumes — the persistent volume UUID is the namespace a path lives in (ScanContext
--    .volumeUUID, AuditSeenOn.volumeUUID). '' = the scan could not read one (kept explicit so
--    the live-path UNIQUE below still binds those rows).
-- ---------------------------------------------------------------------------------------------
CREATE TABLE volumes (
  volume_uuid  TEXT PRIMARY KEY NOT NULL
               CHECK (volume_uuid = '' OR (length(volume_uuid) = 36 AND volume_uuid NOT GLOB '*[^0-9A-F-]*')),
  last_name    TEXT NOT NULL DEFAULT '',   -- ScanContext.volumeName
  mount_type   TEXT NOT NULL DEFAULT '',   -- ScanContext.volumeMountType (local/smb/nfs/afp)
  remote_server TEXT NOT NULL DEFAULT '',
  -- F12: read from the volume (VOL_CAP_FMT_CASE_SENSITIVE) at first scan; 0 = case-insensitive,
  -- which is APFS's default and the conservative answer for an unknown ('' ) volume.
  case_sensitive INTEGER NOT NULL DEFAULT 0 CHECK (case_sensitive IN (0,1))
) STRICT, WITHOUT ROWID;
CREATE TRIGGER volumes_case_sensitivity_fixed                                                -- F12
BEFORE UPDATE OF case_sensitive ON volumes
WHEN NEW.case_sensitive IS NOT OLD.case_sensitive
 AND EXISTS (SELECT 1 FROM files WHERE volume_uuid = NEW.volume_uuid)
BEGIN SELECT RAISE(ABORT, 'a volume with files keeps its case sensitivity (re-fold first)'); END;

-- ---------------------------------------------------------------------------------------------
-- 4. files — one row per FILE AT A PATH (the old VideoRecord row, minus the knowledge that moved
--    to digest tables). Disk facts (stat + ffprobe) + where it is + its removal state.
--    Rows are never deleted: a file that leaves carries its removal marker (§9.2 tombstones).
-- ---------------------------------------------------------------------------------------------
CREATE TABLE files (
  id              TEXT    PRIMARY KEY NOT NULL
                  CHECK (length(id) = 36 AND id NOT GLOB '*[^0-9A-F-]*'),   -- VideoRecord.id, kept from JSON
  content_digest  TEXT    NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,  -- §10: no digest, no main row
  volume_uuid     TEXT    NOT NULL REFERENCES volumes(volume_uuid) ON DELETE RESTRICT,
  volume_case_sensitive INTEGER NOT NULL CHECK (volume_case_sensitive IN (0,1)),  -- F12: copy of volumes.case_sensitive (trigger)
  full_path       TEXT    NOT NULL CHECK (length(trim(full_path)) > 0 AND substr(full_path,1,1) = '/'),
  -- F12: the store's fold of full_path — Unicode lowercase of the NFC form (Swift
  -- `precomposedStringWithCanonicalMapping.lowercased()`); SQLite's lower() is ASCII-only, so the
  -- CHECK can only prove the ASCII part is folded.
  path_fold       TEXT    NOT NULL CHECK (length(path_fold) > 0 AND path_fold = lower(path_fold)),
  filename        TEXT    NOT NULL,
  ext             TEXT    NOT NULL,
  directory       TEXT    NOT NULL,
  size_bytes      INTEGER NOT NULL CHECK (size_bytes >= 0),
  -- stat facts (dateCreatedRaw / dateModifiedRaw — the display strings are dropped, derived)
  fs_created_at   INTEGER,
  fs_modified_at  INTEGER,
  -- the stat stamp the digest was bound to (ContentFixity.stamp / FileIdentityStamp); NULL for an
  -- archive-only fixity, which never carried one (MasterArchive.swift:1290–1297)            -- F10
  stamp_device    INTEGER,
  stamp_inode     INTEGER,
  stamp_mtime_ns  INTEGER,
  stamp_ctime_ns  INTEGER,                 -- -1 = unknown (FileIdentityStamp.unknownCtime)
  stamp_volume_uuid TEXT,
  digest_computed_at INTEGER NOT NULL,     -- contentFixity.computedAt or archiveFixity.verifiedAt
  digest_source   TEXT    NOT NULL CHECK (digest_source IN ('contentFixity','archiveFixity','rescan')),
  -- sampled evidence: NEVER identity, never an equality that yields "copy" (integrity_first §2.4)
  sampled_hash    TEXT    CHECK (sampled_hash IS NULL OR sampled_hash GLOB 'v1:*'),
  sampled_hash_at INTEGER,
  partial_md5     TEXT,                    -- legacy candidate key; kept as evidence only
  -- ffprobe facts promoted to columns because a query or CHECK uses them (§4 hybrid)
  stream_type     TEXT    NOT NULL CHECK (stream_type IN
                    ('Video+Audio','Video only','Audio only','No A/V streams','ffprobe failed','')),
  duration_s      REAL    NOT NULL DEFAULT 0 CHECK (duration_s >= 0),
  container       TEXT    NOT NULL DEFAULT '',
  video_codec     TEXT    NOT NULL DEFAULT '',
  audio_codec     TEXT    NOT NULL DEFAULT '',
  embedded_created_at     INTEGER,
  embedded_created_source TEXT,
  probe_extra     TEXT    NOT NULL DEFAULT '{}' CHECK (json_valid(probe_extra)),
                  -- resolution, frameRate, videoBitrate, totalBitrate, colorSpace, bitDepth,
                  -- scanType, audioChannels, audioSampleRate, timecode, tapeName, isPlayable,
                  -- originMake/Model/Encoder, materialPackageUMID, proAppsMediaIdentifier, avid*,
                  -- drmProtected — by DTO key (contract §a, "extra")
  scan_host       TEXT    NOT NULL DEFAULT '',
  scanned_at      INTEGER,                 -- ScanContext.scannedAt; NULL = unknown, never invented (§9.2)
  scan_root_label TEXT    NOT NULL DEFAULT '',
  bundle_container TEXT   NOT NULL DEFAULT '',
  source_host     TEXT    NOT NULL DEFAULT '',
  original_full_path TEXT,                 -- Relocate provenance, set once
  origin_volume   TEXT,
  machine_notes   TEXT    NOT NULL DEFAULT '',  -- VideoRecord.notes (pipeline-written log)
  -- state machines
  lifecycle       TEXT    NOT NULL CHECK (lifecycle IN
                    ('Cataloged','In Triage','Workbench','Archived','Trashed','Deleted')),
  archive_stage   TEXT    NOT NULL CHECK (archive_stage IN
                    ('None','Healthy','Master','Backed Up','Ready','Archived','Manually Deleted','Salvage Failed')),
  master_location TEXT    NOT NULL DEFAULT '',
  set_aside_reason TEXT,                   -- CatalogScopePolicy.SetAsideReason key; NULL = in scope (also verbatim in knowledge_sources, F1)
  needs_reformat  INTEGER NOT NULL DEFAULT 0 CHECK (needs_reformat IN (0,1)),
  workspace_active INTEGER NOT NULL DEFAULT 0 CHECK (workspace_active IN (0,1)),
  -- removal marker (RemovalMarker.swift:64) — THE one "gone" shape; written only by the engine
  removal_state   TEXT    CHECK (removal_state IN ('inTrash','removedFromCatalog','missing')),
  removal_since   INTEGER,
  removal_reason  TEXT,
  removal_trash_path TEXT,
  removal_trash_emptied_at INTEGER,
  removal_last_seen INTEGER,
  removal_revision INTEGER NOT NULL DEFAULT 0 CHECK (removal_revision >= 0),
  -- the audit's where-seen stamp (AuditSeenOn) — auditStampNamesItsVolume (rule 9)
  audit_seen_volume_uuid TEXT CHECK (audit_seen_volume_uuid IS NULL OR length(trim(audit_seen_volume_uuid)) > 0),
  audit_seen_mount_from  TEXT,
  audit_seen_device_key  TEXT,
  audit_seen_at   INTEGER,
  catalogued_at   INTEGER,  -- NULLable: an unknown scan date stays unknown (§9.2)
  -- table constraints (SQLite requires them after the columns)
  CHECK ((embedded_created_at IS NULL) = (embedded_created_source IS NULL)),
  CHECK ((removal_state IS NULL) = (removal_since IS NULL)),
  CHECK ((removal_state IS NULL) = (removal_reason IS NULL)),
  CHECK (removal_trash_path IS NULL OR removal_state = 'inTrash'),
  CHECK (removal_trash_emptied_at IS NULL OR (removal_state = 'inTrash' AND removal_trash_path IS NOT NULL)),
  CHECK (removal_last_seen IS NULL OR removal_state = 'missing'),
  CHECK (removal_state IS NOT 'inTrash' OR lifecycle = 'Trashed'),   -- rule removalMirrorsLifecycle
  CHECK ((audit_seen_volume_uuid IS NULL) = (audit_seen_at IS NULL)),
  -- F10: a contentFixity digest is bound to a stat stamp; an archive-only fixity may have none
  CHECK (digest_source <> 'contentFixity'
         OR (stamp_device IS NOT NULL AND stamp_inode IS NOT NULL
             AND stamp_mtime_ns IS NOT NULL AND stamp_ctime_ns IS NOT NULL))
) STRICT;

-- UNIQUE live path per volume (rule 2 oneLiveRowPerPath). A removed row may share the path of
-- the row that replaced it. volume_uuid '' rows bind on path alone — today's rule.
CREATE UNIQUE INDEX files_live_path ON files(volume_uuid, full_path) WHERE removal_state IS NULL;
-- F12: on a case-insensitive volume two live rows whose paths differ only by case are ONE file:
-- refused by the engine (pathAliasByCase is no longer a finding there). On a case-sensitive
-- volume both may exist, and nothing is reported.
CREATE UNIQUE INDEX files_live_path_fold ON files(volume_uuid, path_fold)
  WHERE removal_state IS NULL AND volume_case_sensitive = 0;
-- queries the app runs
-- F12: path-prefix query, correct for UTF-8 under the BINARY collation (byte order = code-point
-- order; 0xFF never occurs in UTF-8, so every path that starts with :p sorts below :p || X'FF'):
--   WHERE volume_uuid = :v AND full_path >= :p AND full_path < :p || X'FF'
-- (:p ends with '/' when it names a folder). Uses this index as a range scan.
CREATE INDEX files_by_path_prefix ON files(volume_uuid, full_path);
CREATE INDEX files_by_directory   ON files(directory);
CREATE INDEX files_by_digest      ON files(content_digest);        -- copies of one content
CREATE INDEX files_by_removal     ON files(removal_state, removal_since) WHERE removal_state IS NOT NULL;
CREATE INDEX files_by_lifecycle   ON files(lifecycle, archive_stage);

-- F12: files.volume_case_sensitive mirrors its volume (a partial index cannot read another table)
CREATE TRIGGER files_case_flag_matches_volume_ins
BEFORE INSERT ON files
WHEN NEW.volume_case_sensitive IS NOT (SELECT case_sensitive FROM volumes WHERE volume_uuid = NEW.volume_uuid)
BEGIN SELECT RAISE(ABORT, 'volume_case_sensitive must equal volumes.case_sensitive'); END;
CREATE TRIGGER files_case_flag_matches_volume_upd
BEFORE UPDATE OF volume_uuid, volume_case_sensitive ON files
WHEN NEW.volume_case_sensitive IS NOT (SELECT case_sensitive FROM volumes WHERE volume_uuid = NEW.volume_uuid)
BEGIN SELECT RAISE(ABORT, 'volume_case_sensitive must equal volumes.case_sensitive'); END;
-- F12: a moved path carries a recomputed fold (the ASCII part is checkable here)
CREATE TRIGGER files_path_fold_follows_path
BEFORE UPDATE OF full_path, path_fold ON files
WHEN NEW.full_path IS NOT OLD.full_path AND NEW.path_fold IS OLD.path_fold
     AND lower(NEW.full_path) <> lower(OLD.full_path)
BEGIN SELECT RAISE(ABORT, 'path_fold must be recomputed when full_path changes'); END;

-- F4: no REPLACE on files (it would delete a row — and its history — without a delete trigger)
CREATE TRIGGER files_no_replace
BEFORE INSERT ON files
WHEN EXISTS (SELECT 1 FROM files WHERE id = NEW.id)
  OR (NEW.removal_state IS NULL AND EXISTS (SELECT 1 FROM files WHERE removal_state IS NULL
        AND volume_uuid = NEW.volume_uuid
        AND (full_path = NEW.full_path OR (NEW.volume_case_sensitive = 0 AND path_fold = NEW.path_fold))))
BEGIN SELECT RAISE(ABORT, 'files rows are never replaced (id or live path already taken)'); END;
CREATE TRIGGER files_no_delete BEFORE DELETE ON files
BEGIN SELECT RAISE(ABORT, 'files rows are never deleted; stamp a removal marker'); END;

-- F11: the removal marker. Every marker field is covered; removal_revision changes IF AND ONLY IF
-- the marker changes, by exactly one; and the change must already have its tombstone (written
-- first, in the same transaction, by the door that made it).
CREATE TRIGGER files_removal_revision_monotonic
BEFORE UPDATE OF removal_revision ON files
WHEN NEW.removal_revision < OLD.removal_revision
BEGIN SELECT RAISE(ABORT, 'removal_revision never decreases'); END;

CREATE TRIGGER files_removal_change_bumps_revision                                          -- F11
BEFORE UPDATE OF removal_state, removal_since, removal_reason, removal_trash_path,
                 removal_trash_emptied_at, removal_last_seen, removal_revision ON files
WHEN ((NEW.removal_state IS NOT OLD.removal_state OR NEW.removal_since IS NOT OLD.removal_since
       OR NEW.removal_reason IS NOT OLD.removal_reason OR NEW.removal_trash_path IS NOT OLD.removal_trash_path
       OR NEW.removal_trash_emptied_at IS NOT OLD.removal_trash_emptied_at
       OR NEW.removal_last_seen IS NOT OLD.removal_last_seen)
      AND NEW.removal_revision <> OLD.removal_revision + 1)
  OR (NEW.removal_state IS OLD.removal_state AND NEW.removal_since IS OLD.removal_since
      AND NEW.removal_reason IS OLD.removal_reason AND NEW.removal_trash_path IS OLD.removal_trash_path
      AND NEW.removal_trash_emptied_at IS OLD.removal_trash_emptied_at
      AND NEW.removal_last_seen IS OLD.removal_last_seen
      AND NEW.removal_revision <> OLD.removal_revision)
BEGIN SELECT RAISE(ABORT, 'a removal-marker change bumps removal_revision by one, and only a marker change does'); END;

CREATE TRIGGER files_removal_change_has_tombstone                                           -- F11
BEFORE UPDATE OF removal_revision ON files
WHEN NEW.removal_revision <> OLD.removal_revision
 AND NOT EXISTS (SELECT 1 FROM tombstones t
                  WHERE t.file_id = NEW.id AND t.revision = NEW.removal_revision
                    AND t.state IS NEW.removal_state AND t.since IS NEW.removal_since
                    AND t.reason IS NEW.removal_reason AND t.trash_path IS NEW.removal_trash_path
                    AND t.trash_emptied_at IS NEW.removal_trash_emptied_at
                    AND t.last_seen IS NEW.removal_last_seen)
BEGIN SELECT RAISE(ABORT, 'a removal-marker change must append its tombstone first'); END;

-- F11: an imported row that arrives WITH a marker (or a non-zero revision) records it as its first
-- tombstone. Only the importer inserts a marked row (a rescan's new rows are live). Legacy
-- revision 0 with a marker (pre-revision catalogs) is allowed and recorded as revision 0.
CREATE TRIGGER files_imported_marker_recorded
AFTER INSERT ON files
WHEN NEW.removal_state IS NOT NULL OR NEW.removal_revision > 0
BEGIN
  INSERT INTO tombstones (file_id, revision, state, since, reason, trash_path, trash_emptied_at,
                          last_seen, written_at, door, generation)
  VALUES (NEW.id, NEW.removal_revision, NEW.removal_state, NEW.removal_since, NEW.removal_reason,
          NEW.removal_trash_path, NEW.removal_trash_emptied_at, NEW.removal_last_seen,
          CAST(strftime('%s','now') AS INTEGER), 'import',
          (SELECT generation FROM generations WHERE id = 1));
END;

-- a file's size must equal its content's byte count (wholeFileDigestsAreWhole + storedFullDigest's
-- byteCount == sizeBytes condition, VideoScanModel+Cleanup.swift:125)
CREATE TRIGGER files_size_matches_content_ins
BEFORE INSERT ON files
WHEN NEW.size_bytes <> (SELECT byte_count FROM content WHERE digest = NEW.content_digest)
BEGIN SELECT RAISE(ABORT, 'size_bytes differs from content.byte_count'); END;
CREATE TRIGGER files_size_matches_content_upd
BEFORE UPDATE OF size_bytes, content_digest ON files
WHEN NEW.size_bytes <> (SELECT byte_count FROM content WHERE digest = NEW.content_digest)
BEGIN SELECT RAISE(ABORT, 'size_bytes differs from content.byte_count'); END;

-- a file row's content never changes: a file replaced at its path is a NEW row (contract §g).
CREATE TRIGGER files_digest_immutable
BEFORE UPDATE OF content_digest ON files
WHEN NEW.content_digest IS NOT OLD.content_digest
BEGIN SELECT RAISE(ABORT, 'content_digest is immutable; a replaced file is a new row'); END;

-- moving a file clears the where-seen stamp (VideoRecord.swift:140, D10)
CREATE TRIGGER files_path_change_clears_audit_stamp
AFTER UPDATE OF full_path, volume_uuid ON files
WHEN (NEW.full_path IS NOT OLD.full_path OR NEW.volume_uuid IS NOT OLD.volume_uuid)
     AND NEW.audit_seen_volume_uuid IS NOT NULL
BEGIN
  UPDATE files SET audit_seen_volume_uuid = NULL, audit_seen_mount_from = NULL,
                   audit_seen_device_key = NULL, audit_seen_at = NULL WHERE id = NEW.id;
END;

-- tombstones — the append-only removal history: one row per marker change (revision), so
-- "nil → Trash → Put Back → Restore → nil" is visible, not just the current marker (§9.2).
-- F11: carries EVERY marker field.
CREATE TABLE tombstones (
  file_id     TEXT    NOT NULL REFERENCES files(id) ON DELETE RESTRICT,
  revision    INTEGER NOT NULL CHECK (revision >= 0),
  state       TEXT    CHECK (state IN ('inTrash','removedFromCatalog','missing')),  -- NULL = restored
  since       INTEGER,
  reason      TEXT,
  trash_path  TEXT,
  trash_emptied_at INTEGER,                -- F11
  last_seen   INTEGER,                     -- F11
  written_at  INTEGER NOT NULL,
  door        TEXT    NOT NULL,           -- 'stampRemoval','clearRemoval','revertRemoval','trashEmptied','undo','replacedAtPath','import'
  generation  INTEGER NOT NULL,
  CHECK (revision >= 1 OR door = 'import'),   -- F11: legacy revision 0 only as imported history
  PRIMARY KEY (file_id, revision)
) STRICT, WITHOUT ROWID;
CREATE TRIGGER tombstones_no_update BEFORE UPDATE ON tombstones
BEGIN SELECT RAISE(ABORT, 'tombstones are append-only'); END;
CREATE TRIGGER tombstones_no_delete BEFORE DELETE ON tombstones
BEGIN SELECT RAISE(ABORT, 'tombstones are append-only'); END;
CREATE TRIGGER tombstones_no_replace BEFORE INSERT ON tombstones
WHEN EXISTS (SELECT 1 FROM tombstones WHERE file_id = NEW.file_id AND revision = NEW.revision)
BEGIN SELECT RAISE(ABORT, 'tombstones are append-only (no replace)'); END;
CREATE TRIGGER tombstones_next_revision BEFORE INSERT ON tombstones                          -- F11
WHEN NEW.door <> 'import'
 AND NEW.revision IS NOT (SELECT removal_revision + 1 FROM files WHERE id = NEW.file_id)
BEGIN SELECT RAISE(ABORT, 'a tombstone records the NEXT removal revision'); END;

-- ---------------------------------------------------------------------------------------------
-- 5. Archive evidence (file-level: the archive COPY at a path is a file fact; its digest is the
--    content's). archiveFixity / archivedAt / promotion source.
-- ---------------------------------------------------------------------------------------------
CREATE TABLE archive_copies (
  file_id        TEXT    PRIMARY KEY NOT NULL REFERENCES files(id) ON DELETE RESTRICT,
  source_file_id TEXT    REFERENCES files(id) ON DELETE RESTRICT,  -- derivedFrom on an archivePromotion row
  source_row_id  TEXT,                    -- F1: the JSON derivedFrom verbatim, kept when the source is quarantined
  archived_at    INTEGER,                 -- Promote's stamp; NULL on old copies (resolvedArchivedAt fallback)
  fixity_verified_at INTEGER NOT NULL,    -- archiveFixity.verifiedAt (Verify Archive refreshes)
  promoted_by    TEXT    NOT NULL CHECK (promoted_by IN ('promote','orphanAdopt','import')),
  CHECK (source_file_id IS NULL OR source_file_id <> file_id)
) STRICT, WITHOUT ROWID;
-- promotionsHaveASource (rule 4) for new promotions: only the import may carry a NULL source,
-- and it carries the finding with it (contract §f).
CREATE TRIGGER archive_copies_need_source
BEFORE INSERT ON archive_copies
WHEN NEW.source_file_id IS NULL AND NEW.promoted_by <> 'import'
BEGIN SELECT RAISE(ABORT, 'an archive copy names its source'); END;
-- MOPS-3: nothing trashes a Master Archive copy. (Missing / removed-from-catalog stay possible:
-- they say what the catalog knows, they move no media.)
CREATE TRIGGER archive_copy_never_trashed
BEFORE UPDATE OF removal_state ON files
WHEN NEW.removal_state = 'inTrash' AND EXISTS (SELECT 1 FROM archive_copies WHERE file_id = NEW.id)
BEGIN SELECT RAISE(ABORT, 'MOPS-3: an archive copy is never moved to the Trash'); END;
CREATE INDEX archive_copies_by_source ON archive_copies(source_file_id);

-- Backups recorded per file (BackupEntry) and the person's attestations per content.
CREATE TABLE backup_destinations (
  file_id  TEXT    NOT NULL REFERENCES files(id) ON DELETE RESTRICT,
  name     TEXT    NOT NULL,
  kind     TEXT    NOT NULL CHECK (kind IN ('Local','Cloud','Offsite')),
  recorded_at INTEGER NOT NULL,
  PRIMARY KEY (file_id, name, recorded_at)
) STRICT, WITHOUT ROWID;

-- ---------------------------------------------------------------------------------------------
-- 6. KNOWLEDGE BY DIGEST (§10: "after the port they live on DIGESTS").
-- ---------------------------------------------------------------------------------------------

-- 6.0 knowledge_sources — EVERY curated value of every imported row occurrence, verbatim, one row
--     per (occurrence, field). The display tables below are a CHOICE made from these rows; the
--     rows themselves are never merged, never updated, never deleted.             -- F1 F2 F3
CREATE TABLE knowledge_sources (
  import_run     TEXT    NOT NULL REFERENCES import_runs(run_id) ON DELETE RESTRICT,
  source_ordinal INTEGER NOT NULL CHECK (source_ordinal >= 0),   -- the row's position in catalog.json
  json_row_id    TEXT    NOT NULL,                               -- VideoRecord.id as written (non-unique, F4)
  digest         TEXT    REFERENCES content(digest) ON DELETE RESTRICT, -- NULL: the row had no (agreeing) whole-file digest
  field          TEXT    NOT NULL CHECK (field IN (
                   -- §10b "curated — must survive", and the contract §a C rows:
                   'userNotes','tags','mediaDisposition','starRating','confirmedByUserPeople',
                   'rejectedPeople','userDate','userDateConfidence','userPlace','userPlaceConfidence',
                   'backupAttestations','repairConfirmedDate','footageDecisions','familyMusic',
                   'setAsideReason','archivedAt','archiveFixity','lineage','supersededByID',
                   'mediaReportCard')),
  value_json     TEXT    NOT NULL CHECK (json_valid(value_json)),  -- the DTO value, verbatim (lineage = the
                                                                  -- derivedFrom/derivationKind/cleanup*/trim* object)
  set_at         INTEGER,                                        -- when the value carries a stamp; else NULL
  source         TEXT    NOT NULL DEFAULT 'catalog.json',
  PRIMARY KEY (import_run, source_ordinal, field)
) STRICT, WITHOUT ROWID;
CREATE INDEX knowledge_sources_by_digest ON knowledge_sources(digest, field) WHERE digest IS NOT NULL;
CREATE TRIGGER knowledge_sources_no_update BEFORE UPDATE ON knowledge_sources
BEGIN SELECT RAISE(ABORT, 'knowledge_sources is append-only evidence'); END;
CREATE TRIGGER knowledge_sources_no_delete BEFORE DELETE ON knowledge_sources
BEGIN SELECT RAISE(ABORT, 'knowledge_sources is append-only evidence'); END;
CREATE TRIGGER knowledge_sources_no_replace BEFORE INSERT ON knowledge_sources              -- F4
WHEN EXISTS (SELECT 1 FROM knowledge_sources WHERE import_run = NEW.import_run
              AND source_ordinal = NEW.source_ordinal AND field = NEW.field)
BEGIN SELECT RAISE(ABORT, 'knowledge_sources: a duplicate is a finding, never a replacement'); END;

-- 6a. Curated by Rick — DISPLAY values (contract §h Q2). `conflict = 1` when the source rows
--     sharing the digest disagree; the display value is the Q2 rule's pick, or NULL when the rule
--     ties ("left empty until Rick chooses"). The originals stay in knowledge_sources.     -- F2
--     F3: a date's / place's confidence is independent of its value (VideoRecord.swift:909–914).
CREATE TABLE user_dates (
  digest      TEXT PRIMARY KEY NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
  value       TEXT CHECK (value IS NULL
                          OR value GLOB '[0-9][0-9][0-9][0-9]'
                          OR value GLOB '[0-9][0-9][0-9][0-9]-[0-1][0-9]'
                          OR value GLOB '[0-9][0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9]'),
  confidence  TEXT CHECK (confidence IS NULL OR confidence IN ('estimated','known')),     -- F3
  set_at      INTEGER,                    -- unknown for imported values (JSON had no stamp)
  conflict    INTEGER NOT NULL DEFAULT 0 CHECK (conflict IN (0,1)),                       -- F2
  CHECK (value IS NOT NULL OR confidence IS NOT NULL OR conflict = 1)
) STRICT, WITHOUT ROWID;

CREATE TABLE user_places (
  digest      TEXT PRIMARY KEY NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
  place       TEXT CHECK (place IS NULL OR length(trim(place)) > 0),
  confidence  TEXT CHECK (confidence IS NULL OR confidence IN ('estimated','known')),     -- F3
  set_at      INTEGER,
  conflict    INTEGER NOT NULL DEFAULT 0 CHECK (conflict IN (0,1)),                       -- F2
  CHECK (place IS NOT NULL OR confidence IS NOT NULL OR conflict = 1)
) STRICT, WITHOUT ROWID;

CREATE TABLE stars (
  digest      TEXT PRIMARY KEY NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
  rating      INTEGER CHECK (rating IS NULL OR rating BETWEEN 1 AND 3),  -- 0 = unrated = no row
  conflict    INTEGER NOT NULL DEFAULT 0 CHECK (conflict IN (0,1)),                       -- F2
  CHECK (rating IS NOT NULL OR conflict = 1)
) STRICT, WITHOUT ROWID;

CREATE TABLE user_notes (
  digest      TEXT PRIMARY KEY NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
  text        TEXT CHECK (text IS NULL OR length(text) > 0),
  conflict    INTEGER NOT NULL DEFAULT 0 CHECK (conflict IN (0,1)),                       -- F2
  CHECK (text IS NOT NULL OR conflict = 1)
) STRICT, WITHOUT ROWID;

CREATE TABLE workflow_tags (              -- a set: the union of the copies' tags (nothing to lose)
  digest      TEXT NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
  tag         TEXT NOT NULL CHECK (length(trim(tag)) > 0),  -- canonical display form (WorkflowTags)
  PRIMARY KEY (digest, tag)
) STRICT, WITHOUT ROWID;
CREATE INDEX workflow_tags_by_tag ON workflow_tags(tag COLLATE NOCASE);

-- People: detected / suspected (machine), confirmed / rejected (Rick). One table, one kind column.
-- F2: a name CONFIRMED on one copy and REJECTED on another is written as both rows with
-- conflict = 1 — neither verdict wins silently. A rejected name still hides a machine
-- (detected / suspected) name: that is Rick over the machine, not curated against curated.
CREATE TABLE people_tags (
  digest       TEXT NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
  name         TEXT NOT NULL CHECK (length(trim(name)) > 0),
  kind         TEXT NOT NULL CHECK (kind IN ('detected','suspected','confirmed','rejected')),
  confirmed_at INTEGER,                    -- ConfirmedTag.confirmedAt (confirmed only; earliest of the copies')
  conflict     INTEGER NOT NULL DEFAULT 0 CHECK (conflict IN (0,1)),                      -- F2
  provenance   TEXT CHECK (provenance IN ('bound','unverified')),                          -- F9 (machine kinds)
  CHECK ((kind = 'confirmed') = (confirmed_at IS NOT NULL)),
  CHECK ((kind IN ('detected','suspected')) = (provenance IS NOT NULL)),
  PRIMARY KEY (digest, name, kind)
) STRICT, WITHOUT ROWID;
CREATE INDEX people_tags_by_name ON people_tags(name COLLATE NOCASE, kind);

CREATE TABLE family_music (
  digest      TEXT PRIMARY KEY NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
  performer   TEXT,
  title       TEXT,
  marked_at   INTEGER,
  conflict    INTEGER NOT NULL DEFAULT 0 CHECK (conflict IN (0,1)),                       -- F2
  CHECK (marked_at IS NOT NULL OR conflict = 1)
) STRICT, WITHOUT ROWID;

CREATE TABLE backup_attestations (        -- a set: every copy's attestation is kept
  digest      TEXT NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
  kind        TEXT NOT NULL CHECK (kind IN ('cloud','offsite','drive')),
  answer      TEXT NOT NULL CHECK (answer IN ('yes','no','notApplicable')),
  label       TEXT,
  attested_at INTEGER NOT NULL,
  by_whom     TEXT NOT NULL,
  conflict    INTEGER NOT NULL DEFAULT 0 CHECK (conflict IN (0,1)),   -- F2: same kind, different answers
  PRIMARY KEY (digest, kind, attested_at, answer, by_whom)
) STRICT, WITHOUT ROWID;

-- The person's footage verdicts ("same footage" / "not the same"). F3: a decision is between two
-- ROWS (FootageDecision.otherID is a row id, FindSimilarFootage.swift:349–352); both row ids and
-- both digests are kept, two rows sharing one digest are a legal pair, and either digest may be
-- NULL while that row has none (the row ids still name the decision).
CREATE TABLE footage_decisions (
  decision_id    INTEGER PRIMARY KEY,
  import_run     TEXT REFERENCES import_runs(run_id) ON DELETE RESTRICT,   -- NULL: decided after cutover
  source_ordinal INTEGER,                  -- the owning row's position in catalog.json
  row_id         TEXT NOT NULL,            -- the row that carried footageDecisions
  other_row_id   TEXT NOT NULL,            -- FootageDecision.otherID
  digest         TEXT REFERENCES content(digest) ON DELETE RESTRICT,
  other_digest   TEXT REFERENCES content(digest) ON DELETE RESTRICT,
  verdict        TEXT NOT NULL CHECK (verdict IN ('same','notSame')),
  decided_at     INTEGER NOT NULL,
  CHECK (row_id <> other_row_id),          -- two rows; their digests may be equal            -- F3
  CHECK ((import_run IS NULL) = (source_ordinal IS NULL)),
  UNIQUE (import_run, source_ordinal, other_row_id, decided_at)
) STRICT;
CREATE INDEX footage_decisions_by_digest ON footage_decisions(digest, other_digest);

-- Media disposition (Triage, Rick) — curated; MediaAnalyzer writes it only while 'Unreviewed'.
CREATE TABLE dispositions (
  digest      TEXT PRIMARY KEY NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
  disposition TEXT CHECK (disposition IS NULL OR disposition IN
                ('Important','Recoverable','Suspected Junk','Confirmed Junk')),  -- 'Unreviewed' = no row
  conflict    INTEGER NOT NULL DEFAULT 0 CHECK (conflict IN (0,1)),                       -- F2
  CHECK (disposition IS NOT NULL OR conflict = 1)
) STRICT, WITHOUT ROWID;

-- 6b. Derived stamps. F9: a digest KEY is not proof of derivation. `provenance = 'bound'` only
--     when the value's own stamp names this digest (sound prints: `contentDigest` = 'sha256:'+hex)
--     or the row's fixity stat stamp equals the stat stamp the value was computed against; else
--     'unverified' — kept, not shown as fact, replaced by the cyclers' regeneration. A value
--     computed by the SQLite-era cyclers is 'bound' by construction (it hashes, then derives).
CREATE TABLE sound_prints (                -- AudioFingerprintStamp; landmarks stay in audio-fingerprints.sqlite
  digest          TEXT PRIMARY KEY NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
  engine_version  INTEGER NOT NULL CHECK (engine_version >= 1),
  outcome         TEXT    NOT NULL CHECK (outcome IN ('fingerprinted','noAudio')),
  analyzed_s      REAL    NOT NULL CHECK (analyzed_s >= 0),
  complete        INTEGER NOT NULL CHECK (complete IN (0,1)),
  landmarks       INTEGER NOT NULL CHECK (landmarks >= 0),
  blob_bytes      INTEGER NOT NULL CHECK (blob_bytes >= 0),
  computed_at     INTEGER NOT NULL,
  -- the sidecar's self-describing key; decoding a stamp INTO a digest strips this prefix
  sidecar_key     TEXT    NOT NULL GENERATED ALWAYS AS ('sha256:' || digest) VIRTUAL,
  CHECK (outcome = 'fingerprinted' OR (landmarks = 0 AND blob_bytes = 0))
) STRICT;                                  -- always bound: only a 'sha256:' stamp imports (F9)

CREATE TABLE perceptual_prints (           -- StoredPerceptualFingerprint (carries sizeBytes only)
  digest          TEXT PRIMARY KEY NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
  algorithm_version INTEGER NOT NULL CHECK (algorithm_version >= 1),
  hashes_b64      TEXT    NOT NULL,
  duration_s      REAL    NOT NULL,
  computed_at     INTEGER NOT NULL,
  provenance      TEXT    NOT NULL DEFAULT 'bound' CHECK (provenance IN ('bound','unverified'))  -- F9
) STRICT, WITHOUT ROWID;

CREATE TABLE captions (                    -- sceneCaptions / ocrDateCandidates / ocrText
  digest      TEXT    NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
  kind        TEXT    NOT NULL CHECK (kind IN ('scene','ocrDate','ocrText')),
  seq         INTEGER NOT NULL CHECK (seq >= 0),   -- array order is meaningful (§9.3)
  at_s        REAL    NOT NULL,                     -- SceneCaption.timestamp
  text        TEXT    NOT NULL,
  provenance  TEXT    NOT NULL DEFAULT 'bound' CHECK (provenance IN ('bound','unverified')),  -- F9
  PRIMARY KEY (digest, kind, seq)
) STRICT, WITHOUT ROWID;

CREATE TABLE caption_runs (                -- sceneCaptionModel / sceneCaptionDate
  digest      TEXT PRIMARY KEY NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
  model       TEXT NOT NULL,
  made_at     INTEGER NOT NULL,
  provenance  TEXT NOT NULL DEFAULT 'bound' CHECK (provenance IN ('bound','unverified'))     -- F9
) STRICT, WITHOUT ROWID;

CREATE TABLE transcripts (
  digest      TEXT PRIMARY KEY NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
  text        TEXT NOT NULL,                -- '' = ran, found no speech (distinct from no row)
  model       TEXT,
  made_at     INTEGER,
  provenance  TEXT NOT NULL DEFAULT 'bound' CHECK (provenance IN ('bound','unverified'))     -- F9
) STRICT, WITHOUT ROWID;

CREATE TABLE dossiers (
  digest       TEXT PRIMARY KEY NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
  processed_at INTEGER NOT NULL,
  processed_by TEXT    NOT NULL,
  provenance   TEXT    NOT NULL DEFAULT 'bound' CHECK (provenance IN ('bound','unverified'))  -- F9
) STRICT, WITHOUT ROWID;

CREATE TABLE inferred_dates (
  digest      TEXT PRIMARY KEY NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
  date_at     INTEGER,                      -- NULL with a reason = "examined, no evidence"
  confidence  REAL    CHECK (confidence IS NULL OR confidence BETWEEN 0 AND 1),
  source      TEXT,                         -- NULL | 'catch-up' | 'propagated from <uuid>' | 'folder-year'
  range_start INTEGER,
  range_end   INTEGER,
  reason      TEXT,
  provenance  TEXT    NOT NULL DEFAULT 'bound' CHECK (provenance IN ('bound','unverified')),  -- F9
  CHECK ((range_start IS NULL) = (range_end IS NULL)),
  CHECK (range_start IS NULL OR range_start <= range_end),
  CHECK (date_at IS NOT NULL OR reason IS NOT NULL)
) STRICT, WITHOUT ROWID;

CREATE TABLE media_checks (                -- Verify Audio / Verify Video / Check Media report card
  digest      TEXT NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
  kind        TEXT NOT NULL CHECK (kind IN ('audio','video','reportCard')),
  status      TEXT NOT NULL,
  note        TEXT NOT NULL DEFAULT '',
  checked_at  INTEGER,
  card        TEXT CHECK (card IS NULL OR json_valid(card)),   -- MediaReportCard, reportCard only
  provenance  TEXT NOT NULL DEFAULT 'bound' CHECK (provenance IN ('bound','unverified')),   -- F9
  CHECK (kind <> 'audio'      OR status IN ('ok','damaged')),
  CHECK (kind <> 'video'      OR status IN ('ok','warning','broken')),
  CHECK (kind <> 'reportCard' OR (status IN ('quick','full') AND card IS NOT NULL)),
  PRIMARY KEY (digest, kind)
) STRICT, WITHOUT ROWID;

-- 6c. Context regeneration cannot recover from the file alone (codex F9 / brief §5). Kept per
--     source occurrence, verbatim; the cyclers READ it when they regenerate.          -- F9
CREATE TABLE regen_context (
  import_run     TEXT    NOT NULL REFERENCES import_runs(run_id) ON DELETE RESTRICT,
  source_ordinal INTEGER NOT NULL CHECK (source_ordinal >= 0),
  json_row_id    TEXT    NOT NULL,
  digest         TEXT    REFERENCES content(digest) ON DELETE RESTRICT,
  kind           TEXT    NOT NULL CHECK (kind IN (
                   'folderDate',      -- inferredDateSource 'folder-year' + its reason (the folder may be gone)
                   'donorDate',       -- 'propagated from <uuid>' + reason; the donor row id verbatim
                   'personSearched')),-- a detected/suspected name: the named person a Person Finder run
                                      -- was asked for — the reference input a re-run needs
  value_json     TEXT    NOT NULL CHECK (json_valid(value_json)),
  reason         TEXT,
  PRIMARY KEY (import_run, source_ordinal, kind, value_json)
) STRICT, WITHOUT ROWID;

-- Original A/V pair ids, and the event member keys that cite them ('pair:<pairGroupID>',
-- 'id:<recordID>'), so an event member survives a re-run of Correlate that mints new ids.   -- F9
CREATE TABLE legacy_pair_ids (
  import_run     TEXT    NOT NULL REFERENCES import_runs(run_id) ON DELETE RESTRICT,
  source_ordinal INTEGER NOT NULL CHECK (source_ordinal >= 0),
  json_row_id    TEXT    NOT NULL,
  digest         TEXT    REFERENCES content(digest) ON DELETE RESTRICT,
  paired_with_id TEXT,                     -- pairedWithID verbatim
  pair_group_id  TEXT,                     -- pairGroupID verbatim
  event_member_keys TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(event_member_keys)),
  CHECK (paired_with_id IS NOT NULL OR pair_group_id IS NOT NULL),
  PRIMARY KEY (import_run, source_ordinal)
) STRICT, WITHOUT ROWID;
CREATE INDEX legacy_pair_ids_by_group ON legacy_pair_ids(pair_group_id);

-- ---------------------------------------------------------------------------------------------
-- 7. RELATIONS
-- ---------------------------------------------------------------------------------------------
-- Lineage between CONTENTS (derivedFrom + derivationKind + recipe/trim payload). A derivative is
-- other bytes than its source, so both ends are digests and survive a rescan. Archive promotion
-- is NOT here (same bytes): it is archive_copies (file → file).
CREATE TABLE lineage (
  child_digest   TEXT NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
  parent_digest  TEXT NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
  kind           TEXT NOT NULL CHECK (kind IN
                   ('trim','balanceAudio','rebuildAudio','repair','externalRepair',
                    'cleanup','reformat','transcode','triage','combine','unrecorded')),
  cleanup_recipe_id      TEXT,
  cleanup_recipe_version INTEGER,
  trim_in_s      REAL,
  trim_out_s     REAL,
  recorded_at    INTEGER,
  CHECK (child_digest <> parent_digest),
  CHECK ((kind = 'cleanup') = (cleanup_recipe_id IS NOT NULL)),
  CHECK ((cleanup_recipe_id IS NULL) = (cleanup_recipe_version IS NULL)),
  CHECK ((kind = 'trim') = (trim_in_s IS NOT NULL AND trim_out_s IS NOT NULL)),
  CHECK (trim_in_s IS NULL OR trim_in_s < trim_out_s),
  PRIMARY KEY (child_digest, parent_digest)
) STRICT, WITHOUT ROWID;
CREATE INDEX lineage_by_parent ON lineage(parent_digest);

-- F1: a lineage or supersession edge one of whose ends has NO digest (a main child whose parent
-- is quarantined without one, or the reverse) is kept here by row ids — never dropped. When both
-- ends gain digests (rescan / person decision) the edge moves into lineage / supersessions and
-- this row is marked resolved (never deleted).
CREATE TABLE lineage_pending (
  import_run     TEXT    NOT NULL REFERENCES import_runs(run_id) ON DELETE RESTRICT,
  source_ordinal INTEGER NOT NULL CHECK (source_ordinal >= 0),   -- the CHILD row's occurrence
  relation       TEXT    NOT NULL CHECK (relation IN ('derivedFrom','supersededBy')),
  child_row_id   TEXT    NOT NULL,
  child_digest   TEXT    REFERENCES content(digest) ON DELETE RESTRICT,
  parent_row_id  TEXT    NOT NULL,       -- derivedFrom / supersededByID verbatim
  parent_digest  TEXT    REFERENCES content(digest) ON DELETE RESTRICT,
  payload        TEXT    NOT NULL CHECK (json_valid(payload)),  -- derivationKind, recipe, trim, repairConfirmedDate
  resolved_at    INTEGER,
  CHECK (child_digest IS NULL OR parent_digest IS NULL OR resolved_at IS NOT NULL),
  PRIMARY KEY (import_run, source_ordinal, relation)
) STRICT, WITHOUT ROWID;
CREATE TRIGGER lineage_pending_no_delete BEFORE DELETE ON lineage_pending
BEGIN SELECT RAISE(ABORT, 'pending lineage is resolved, never deleted'); END;

-- Supersession (repair lifecycle, GH #132): the repaired content retires the original.
CREATE TABLE supersessions (
  retired_digest TEXT PRIMARY KEY NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
  by_digest      TEXT NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
  confirmed_at   INTEGER,                   -- repairConfirmedDate on the repair; NULL = awaiting Rick
  CHECK (retired_digest <> by_digest)
) STRICT, WITHOUT ROWID;
-- supersessionCycle (rule 12): refuse a link that would close a circle.
CREATE TRIGGER supersessions_acyclic
BEFORE INSERT ON supersessions
WHEN EXISTS (
  WITH RECURSIVE chain(d) AS (
    SELECT NEW.by_digest
    UNION SELECT s.by_digest FROM supersessions s JOIN chain ON s.retired_digest = chain.d)
  SELECT 1 FROM chain WHERE d = NEW.retired_digest)
BEGIN SELECT RAISE(ABORT, 'supersession would run in a circle'); END;

CREATE TRIGGER supersessions_no_rewrite BEFORE UPDATE OF retired_digest, by_digest ON supersessions
BEGIN SELECT RAISE(ABORT, 'supersession links are not rewritten; delete (un-confirm) and insert'); END;

-- A/V pairs (correlate): a video-only and an audio-only content that belong together. Derived
-- and rebuildable; the ORIGINAL ids events cite are in legacy_pair_ids (F9).
CREATE TABLE av_pairs (
  pair_group_id TEXT PRIMARY KEY NOT NULL CHECK (length(pair_group_id) = 36),
  video_digest  TEXT NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
  audio_digest  TEXT NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
  confidence    TEXT NOT NULL CHECK (confidence IN ('High','Medium','Low')),
  combined_digest TEXT REFERENCES content(digest) ON DELETE RESTRICT,  -- combinedFromPairID, inverted
  CHECK (video_digest <> audio_digest),
  UNIQUE (video_digest, audio_digest)
) STRICT, WITHOUT ROWID;

-- Duplicate CANDIDATE groups (Analyze Duplicates) with their reasons. Byte-identical copies need
-- no table (files_by_digest: same digest = same bytes); this keeps the machine's candidate groups
-- and its keeper election. Rebuildable: the importer may leave it empty and re-run analysis.
-- D:530 (codex "other checks"): a candidate group MAY hold different digests — similarity
-- (duration, timecode, audio, created…) never promised byte identity
-- (CatalogConstraints.swift:515–524). Only a group formed on a `hash` reason with differing
-- digests is a finding: a JOB reading the view below, not a CHECK.
CREATE TABLE duplicate_groups (
  group_id     TEXT PRIMARY KEY NOT NULL CHECK (length(group_id) = 36),
  analyzed_at  INTEGER NOT NULL
) STRICT, WITHOUT ROWID;
CREATE TABLE duplicate_members (
  group_id     TEXT NOT NULL REFERENCES duplicate_groups(group_id) ON DELETE CASCADE,
  file_id      TEXT NOT NULL REFERENCES files(id) ON DELETE RESTRICT,
  confidence   TEXT NOT NULL CHECK (confidence IN ('High','Medium','Low')),
  disposition  TEXT NOT NULL CHECK (disposition IN ('Keep','Review','Extra copy')),
  reasons      TEXT NOT NULL DEFAULT '',  -- DuplicateDetector's comma-separated reason words, verbatim
  best_match   TEXT NOT NULL DEFAULT '',
  PRIMARY KEY (group_id, file_id),
  UNIQUE (file_id)                          -- a file is in at most one group (one duplicateGroupID)
) STRICT, WITHOUT ROWID;
CREATE VIEW duplicate_hash_groups_disagree AS          -- D:530: rule 13's finding, for the job
  SELECT m.group_id, count(DISTINCT f.content_digest) AS digests
    FROM duplicate_members m JOIN files f ON f.id = m.file_id
   WHERE f.removal_state IS NULL
   GROUP BY m.group_id
  HAVING count(DISTINCT f.content_digest) > 1
     AND max(instr(',' || replace(m.reasons, ' ', '') || ',', ',hash,') > 0) = 1;
CREATE VIEW byte_copies AS
  SELECT content_digest AS digest, count(*) AS live_files
    FROM files WHERE removal_state IS NULL GROUP BY content_digest HAVING count(*) > 1;

-- Find Similar Footage — the MACHINE's current answer per file (FootageMembership), rewritten each
-- run; rebuildable. Kept as JSON per row: no check or query reaches inside it today.
CREATE TABLE footage_membership (
  digest       TEXT PRIMARY KEY NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
  group_id     TEXT NOT NULL,
  membership   TEXT NOT NULL CHECK (json_valid(membership)),
  scanned_at   INTEGER NOT NULL,
  provenance   TEXT NOT NULL DEFAULT 'bound' CHECK (provenance IN ('bound','unverified'))    -- F9
) STRICT, WITHOUT ROWID;
CREATE INDEX footage_membership_by_group ON footage_membership(group_id);

-- Events (events-decisions.json, EventsDecisionStore.swift:154). The file is a STREAM of decisions
-- folded into membership (EventsDecisionSnapshot :173); member keys are ContentRange.contentKey =
-- the stored full SHA-256, else 'pair:<pairGroupID>', else 'id:<recordID>' (:35). Imported as they
-- are (Rick: events "only just starting"): the stream verbatim — EVERY decision, membership and
-- non-membership (differentOccasions, merged, categoryRejected, suggestionDismissed, unknown
-- kinds) — plus the folded snapshot by digest.                                          -- F1
CREATE TABLE events (
  event_id     TEXT PRIMARY KEY NOT NULL CHECK (length(event_id) = 36),
  name         TEXT NOT NULL,
  state        TEXT NOT NULL CHECK (state IN ('confirmed','dismissed')),
  categories   TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(categories)),
  note         TEXT,
  created_at   INTEGER NOT NULL,
  updated_at   INTEGER NOT NULL,
  import_run   TEXT REFERENCES import_runs(run_id) ON DELETE RESTRICT,   -- F4
  source_ordinal INTEGER,
  CHECK ((import_run IS NULL) = (source_ordinal IS NULL))
) STRICT, WITHOUT ROWID;
-- A duplicated event id in events-decisions.json is a RUN-LEVEL refusal (contract §f), not a
-- replacement: the PK above refuses the second plain INSERT and the run rolls back.     -- F4
CREATE TABLE event_decisions (               -- the stream, verbatim, in order; unknown kinds kept
  seq          INTEGER PRIMARY KEY,
  kind         TEXT NOT NULL,                -- member | differentOccasions | merged | categoryRejected | suggestionDismissed | <unknown>
  payload      TEXT NOT NULL CHECK (json_valid(payload)),
  import_run   TEXT REFERENCES import_runs(run_id) ON DELETE RESTRICT,   -- F4
  source_ordinal INTEGER,
  CHECK ((import_run IS NULL) = (source_ordinal IS NULL))
) STRICT;
CREATE UNIQUE INDEX event_decisions_by_source ON event_decisions(import_run, source_ordinal) WHERE import_run IS NOT NULL;
CREATE TRIGGER event_decisions_no_update BEFORE UPDATE ON event_decisions
BEGIN SELECT RAISE(ABORT, 'the decision stream is append-only'); END;
CREATE TRIGGER event_decisions_no_delete BEFORE DELETE ON event_decisions
BEGIN SELECT RAISE(ABORT, 'the decision stream is append-only'); END;
CREATE TRIGGER event_decisions_no_replace BEFORE INSERT ON event_decisions                  -- F4
WHEN (NEW.seq IS NOT NULL AND EXISTS (SELECT 1 FROM event_decisions WHERE seq = NEW.seq))
  OR (NEW.import_run IS NOT NULL AND EXISTS (SELECT 1 FROM event_decisions
        WHERE import_run = NEW.import_run AND source_ordinal = NEW.source_ordinal))
BEGIN SELECT RAISE(ABORT, 'the decision stream is append-only (no replace)'); END;
CREATE TABLE event_members (                 -- the fold (accepted − rejected, merges followed)
  event_id     TEXT NOT NULL REFERENCES events(event_id) ON DELETE RESTRICT,
  digest       TEXT NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,  -- eventMembersExist (rule 10) as an FK
  range_start_s REAL,                         -- ContentRange.start/end; NULL = whole file
  range_end_s   REAL,
  imported_key TEXT NOT NULL,                 -- the original contentKey, for the comparator
  CHECK ((range_start_s IS NULL) = (range_end_s IS NULL)),
  CHECK (range_start_s IS NULL OR range_start_s <= range_end_s)
) STRICT;
CREATE UNIQUE INDEX event_members_unique ON event_members(event_id, digest, ifnull(range_start_s,-1), ifnull(range_end_s,-1));
CREATE INDEX event_members_by_digest ON event_members(digest);
-- Members whose key is 'id:'/'pair:' and whose row has no whole-file digest cannot be keyed:
-- they stay in event_decisions (verbatim) and legacy_pair_ids, and are listed against the row's
-- quarantine entry.

-- Ignored content (ignored-content.json, IgnoredContentStore.swift:76/109). Its key today is
-- (partialMD5, sizeBytes), fallback (lower(filename), sizeBytes) — a SAMPLED key; an entry
-- carries no row id and no whole-file digest. F7: a sampled key NEVER binds, even when exactly
-- one hashed file matches it. `digest` is set only by (a) a whole-file digest established from
-- the JSON for the original row, (b) a person's decision, or (c) after cutover, the act of
-- ignoring a hashed file. Otherwise the entry stays sampled-keyed, verbatim, `unbound`.
CREATE TABLE ignored_content (
  ignored_seq  INTEGER PRIMARY KEY,
  entry_id     TEXT NOT NULL CHECK (length(entry_id) = 36),   -- IgnoredContentEntry.id, NON-unique (F4)
  import_run   TEXT REFERENCES import_runs(run_id) ON DELETE RESTRICT,
  source_ordinal INTEGER,
  partial_md5  TEXT NOT NULL,
  size_bytes   INTEGER NOT NULL CHECK (size_bytes >= 0),
  filename     TEXT NOT NULL,
  reason       TEXT NOT NULL,
  added_at     INTEGER NOT NULL,
  sample_path  TEXT NOT NULL,                 -- shown, never matched on
  digest       TEXT REFERENCES content(digest) ON DELETE RESTRICT,
  binding      TEXT NOT NULL DEFAULT 'unbound'                                           -- F7
               CHECK (binding IN ('unbound','jsonDigest','personDecided','hashedWhenIgnored')),
  CHECK ((digest IS NULL) = (binding = 'unbound')),
  CHECK ((import_run IS NULL) = (source_ordinal IS NULL))
) STRICT;
CREATE UNIQUE INDEX ignored_by_source ON ignored_content(import_run, source_ordinal) WHERE import_run IS NOT NULL;
CREATE INDEX ignored_by_md5  ON ignored_content(partial_md5, size_bytes);
CREATE INDEX ignored_by_name ON ignored_content(lower(filename), size_bytes);
CREATE TRIGGER ignored_content_no_replace BEFORE INSERT ON ignored_content                  -- F4
WHEN (NEW.ignored_seq IS NOT NULL AND EXISTS (SELECT 1 FROM ignored_content WHERE ignored_seq = NEW.ignored_seq))
  OR (NEW.import_run IS NOT NULL AND EXISTS (SELECT 1 FROM ignored_content
        WHERE import_run = NEW.import_run AND source_ordinal = NEW.source_ordinal))
BEGIN SELECT RAISE(ABORT, 'ignored_content: a duplicate is a finding, never a replacement'); END;

-- ---------------------------------------------------------------------------------------------
-- 8. QUARANTINE — every JSON row occurrence (and later every rescan item) that cannot enter
--    `files`, with its words and EVERYTHING it carried. Nothing is dropped (§10 D′).
--    F4: an import row is keyed by (import_run, source_ordinal); json_row_id is evidence and may
--    repeat (two occurrences of one UUID are two rows, both `duplicateId`).
--    F5: a row's reason has a CLASS. A `presence` reason (where is the file?) may be resolved by a
--    rescan that finds the digest; a `finding` reason stays open until its own rule clears it.
-- ---------------------------------------------------------------------------------------------
CREATE TABLE quarantine (
  qid           INTEGER PRIMARY KEY,
  origin        TEXT    NOT NULL CHECK (origin IN ('import','rescan')),
  import_run    TEXT    REFERENCES import_runs(run_id) ON DELETE RESTRICT,                -- F4
  source_ordinal INTEGER CHECK (source_ordinal IS NULL OR source_ordinal >= 0),           -- F4
  json_row_id   TEXT    CHECK (json_row_id IS NULL OR length(json_row_id) = 36),  -- VideoRecord.id, NON-unique
  full_path     TEXT    NOT NULL,
  size_bytes    INTEGER,
  digest        TEXT    CHECK (digest IS NULL OR (length(digest) = 64 AND digest NOT GLOB '*[^0-9a-f]*')),
  -- F10: every whole-file digest the row carried (both, when contentFixity and archiveFixity
  -- disagree). On disagreement `digest` stays NULL: no knowledge identity is selected.
  evidence_digests TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(evidence_digests)),
  sampled_hash  TEXT,                        -- the v1: value, as evidence only
  reason_code   TEXT    NOT NULL CHECK (reason_code IN
                  ('noWholeFileDigest','auditGone','auditNeverSeen','auditCouldNotCheck','auditChanged',
                   'tier5Finding','referenceMovie','fixityDisagree','duplicateId','removedNoDigest',
                   'stillBeingWritten','pathReplaced','unreadable')),
  reason_class  TEXT    NOT NULL GENERATED ALWAYS AS (CASE                                  -- F5
                  WHEN reason_code IN ('auditGone','auditNeverSeen','auditCouldNotCheck',
                                       'noWholeFileDigest','removedNoDigest') THEN 'presence'
                  ELSE 'finding' END) VIRTUAL,
  words         TEXT    NOT NULL,            -- family-app words: what is wrong and what to do
  findings      TEXT    NOT NULL DEFAULT '[]' CHECK (json_valid(findings)),  -- integrity findings for the row
  raw_row       TEXT    CHECK (raw_row IS NULL OR json_valid(raw_row)),      -- the full VideoRecordDTO JSON
  quarantined_at INTEGER NOT NULL,
  generation    INTEGER NOT NULL,
  resolved_file_id TEXT REFERENCES files(id) ON DELETE RESTRICT,
  resolved_at   INTEGER,
  resolution    TEXT    CHECK (resolution IN
                  ('foundByDigest','resolvedAsCopy','personDecided','importedAfterHash','findingCleared')),
  resolution_note TEXT,                      -- findingCleared / personDecided: which rule or decision
  CHECK ((resolved_at IS NULL) = (resolution IS NULL)),
  CHECK (resolution IS NULL OR resolution = 'findingCleared' OR resolved_file_id IS NOT NULL),
  CHECK (resolution IS NULL OR resolution NOT IN ('findingCleared','personDecided') OR resolution_note IS NOT NULL),
  -- F5: a rescan's byte match resolves only a presence reason
  CHECK (resolution IS NULL OR resolution NOT IN ('foundByDigest','resolvedAsCopy') OR reason_class = 'presence'),
  CHECK (origin <> 'import' OR (import_run IS NOT NULL AND source_ordinal IS NOT NULL
                                AND json_row_id IS NOT NULL AND raw_row IS NOT NULL)),
  CHECK (origin <> 'rescan' OR (import_run IS NULL AND source_ordinal IS NULL)),
  CHECK (reason_code <> 'fixityDisagree' OR (digest IS NULL AND json_array_length(evidence_digests) >= 2))  -- F10
) STRICT;
CREATE UNIQUE INDEX quarantine_by_source ON quarantine(import_run, source_ordinal) WHERE origin = 'import';  -- F4
CREATE INDEX quarantine_by_json_row ON quarantine(json_row_id) WHERE json_row_id IS NOT NULL;
CREATE INDEX quarantine_by_digest  ON quarantine(digest) WHERE digest IS NOT NULL;
CREATE INDEX quarantine_open       ON quarantine(reason_code) WHERE resolved_at IS NULL;
CREATE TRIGGER quarantine_never_deleted BEFORE DELETE ON quarantine
BEGIN SELECT RAISE(ABORT, 'quarantine rows are history; resolve, never delete'); END;
CREATE TRIGGER quarantine_no_replace BEFORE INSERT ON quarantine                            -- F4
WHEN (NEW.qid IS NOT NULL AND EXISTS (SELECT 1 FROM quarantine WHERE qid = NEW.qid))
  OR (NEW.import_run IS NOT NULL AND EXISTS (SELECT 1 FROM quarantine
        WHERE import_run = NEW.import_run AND source_ordinal = NEW.source_ordinal))
BEGIN SELECT RAISE(ABORT, 'quarantine rows are history (no replace)'); END;
-- a resolved row stays resolved; only the resolution columns may change, once
CREATE TRIGGER quarantine_resolve_once BEFORE UPDATE ON quarantine
WHEN OLD.resolved_at IS NOT NULL
  OR NEW.raw_row IS NOT OLD.raw_row OR NEW.json_row_id IS NOT OLD.json_row_id
  OR NEW.digest IS NOT OLD.digest OR NEW.words IS NOT OLD.words
  OR NEW.reason_code IS NOT OLD.reason_code OR NEW.evidence_digests IS NOT OLD.evidence_digests
  OR NEW.import_run IS NOT OLD.import_run OR NEW.source_ordinal IS NOT OLD.source_ordinal
BEGIN SELECT RAISE(ABORT, 'quarantine evidence is immutable; a row is resolved once'); END;

-- ---------------------------------------------------------------------------------------------
-- 8a. IMPORT RUNS and the per-occurrence map the comparator checks. F1: rows, not counters.
--     Every occurrence in every imported file — each catalog.json row, each event record and
--     decision, each ignored entry, each ledger line, each marker file, each per-row audit
--     result — is one import_items row naming the ONE table row it landed in. A run can only be
--     finished (finished_at set) when the map is total and every landing exists; the counters
--     must equal the map's counts; the CHECK on the counters stays as a backstop only.
-- ---------------------------------------------------------------------------------------------
CREATE TABLE import_runs (
  run_id          TEXT PRIMARY KEY NOT NULL,
  started_at      INTEGER NOT NULL,
  finished_at     INTEGER,
  source_sha256   TEXT NOT NULL CHECK (length(source_sha256) = 64 AND source_sha256 NOT GLOB '*[^0-9a-f]*'),
  source_generation INTEGER NOT NULL,
  integrity_run_id TEXT NOT NULL,           -- integrity-latest.json runID used as the gate
  audit_run_started_at INTEGER NOT NULL,    -- catalog-audit.json startedAt: the per-row results' run (F6)
  rows_before     INTEGER NOT NULL DEFAULT 0,
  rows_main       INTEGER NOT NULL DEFAULT 0,
  rows_quarantine INTEGER NOT NULL DEFAULT 0,
  digests_seen    INTEGER NOT NULL DEFAULT 0,
  knowledge_rows  INTEGER NOT NULL DEFAULT 0,
  comparator_ok   INTEGER NOT NULL DEFAULT 0 CHECK (comparator_ok IN (0,1)),
  CHECK (rows_before = rows_main + rows_quarantine),            -- backstop only (F1)
  CHECK (finished_at IS NULL OR comparator_ok = 1)
) STRICT, WITHOUT ROWID;

CREATE TABLE import_items (                                                                  -- F1
  import_run     TEXT    NOT NULL REFERENCES import_runs(run_id) ON DELETE RESTRICT,
  source_file    TEXT    NOT NULL CHECK (source_file IN
                   ('catalog.json','events-decisions.json','ignored-content.json',
                    'media-ledger.jsonl','catalog-audit.json','fullhash-backfill.json')),
  source_ordinal INTEGER NOT NULL CHECK (source_ordinal >= 0),
  item_kind      TEXT    NOT NULL CHECK (item_kind IN
                   ('row','event','eventDecision','ignored','ledgerLine','marker','auditResult')),
  source_key     TEXT,                    -- the id the occurrence carries, verbatim (non-unique)
  -- catalog rows: the §10b curated fields this occurrence carried (non-default), as the importer
  -- decoded them; the comparator re-derives this list from catalog.json independently.
  curated_fields TEXT    NOT NULL DEFAULT '[]' CHECK (json_valid(curated_fields)),
  landed_table   TEXT    NOT NULL CHECK (landed_table IN
                   ('files','quarantine','events','event_decisions','ignored_content','ledger',
                    'job_markers','audit_results')),
  landed_ref     TEXT    NOT NULL,        -- files.id | quarantine.qid | events.event_id | '' (keyed by run+ordinal)
  PRIMARY KEY (import_run, source_file, source_ordinal),
  CHECK ((source_file = 'catalog.json') = (item_kind = 'row')),
  CHECK (item_kind <> 'row' OR landed_table IN ('files','quarantine')),
  CHECK (item_kind <> 'row' OR json_array_length(curated_fields) >= 0)
) STRICT, WITHOUT ROWID;
CREATE TRIGGER import_items_no_replace BEFORE INSERT ON import_items
WHEN EXISTS (SELECT 1 FROM import_items WHERE import_run = NEW.import_run
              AND source_file = NEW.source_file AND source_ordinal = NEW.source_ordinal)
BEGIN SELECT RAISE(ABORT, 'import_items: one occurrence, one row'); END;

-- per-row Tier 0 results, read from catalog-audit.json (F6: the importer does not walk the disk)
CREATE TABLE audit_results (                                                                 -- F6
  import_run     TEXT    NOT NULL REFERENCES import_runs(run_id) ON DELETE RESTRICT,
  source_ordinal INTEGER NOT NULL CHECK (source_ordinal >= 0),   -- position in catalog-audit.json's rows
  json_row_id    TEXT    NOT NULL,
  result         TEXT    NOT NULL CHECK (result IN ('present','gone','neverSeen','couldNotCheck','changed','link')),
  detail         TEXT    NOT NULL DEFAULT '{}' CHECK (json_valid(detail)),  -- errno, link component, stamp seen
  PRIMARY KEY (import_run, source_ordinal)
) STRICT, WITHOUT ROWID;
CREATE INDEX audit_results_by_row ON audit_results(import_run, json_row_id);

-- A run is inserted OPEN and finished by one UPDATE inside the import transaction. F1
CREATE TRIGGER import_runs_open_first BEFORE INSERT ON import_runs
WHEN NEW.finished_at IS NOT NULL OR NEW.comparator_ok <> 0
BEGIN SELECT RAISE(ABORT, 'an import run starts open; it is finished by the comparator'); END;

CREATE TRIGGER import_runs_finish_checks_rows                                                -- F1
BEFORE UPDATE OF finished_at ON import_runs
WHEN NEW.finished_at IS NOT NULL AND OLD.finished_at IS NULL AND (
     -- counters equal the map (the counters cannot be supplied independently)
     NEW.rows_before     <> (SELECT count(*) FROM import_items WHERE import_run = NEW.run_id AND item_kind = 'row')
  OR NEW.rows_main       <> (SELECT count(*) FROM import_items WHERE import_run = NEW.run_id AND item_kind = 'row' AND landed_table = 'files')
  OR NEW.rows_quarantine <> (SELECT count(*) FROM import_items WHERE import_run = NEW.run_id AND item_kind = 'row' AND landed_table = 'quarantine')
  OR NEW.knowledge_rows  <> (SELECT count(*) FROM knowledge_sources WHERE import_run = NEW.run_id)
  -- every landing exists, and no two rows landed on one files row
  OR EXISTS (SELECT 1 FROM import_items i WHERE i.import_run = NEW.run_id AND i.landed_table = 'files'
              AND NOT EXISTS (SELECT 1 FROM files f WHERE f.id = i.landed_ref))
  OR EXISTS (SELECT landed_ref FROM import_items WHERE import_run = NEW.run_id AND landed_table = 'files'
              GROUP BY landed_ref HAVING count(*) > 1)
  OR EXISTS (SELECT 1 FROM import_items i WHERE i.import_run = NEW.run_id AND i.landed_table = 'quarantine'
              AND NOT EXISTS (SELECT 1 FROM quarantine q WHERE q.import_run = i.import_run
                               AND q.source_ordinal = i.source_ordinal AND q.qid = CAST(i.landed_ref AS INTEGER)))
  OR EXISTS (SELECT 1 FROM import_items i WHERE i.import_run = NEW.run_id AND i.landed_table = 'events'
              AND NOT EXISTS (SELECT 1 FROM events e WHERE e.event_id = i.landed_ref
                               AND e.import_run = i.import_run AND e.source_ordinal = i.source_ordinal))
  OR EXISTS (SELECT 1 FROM import_items i WHERE i.import_run = NEW.run_id AND i.landed_table = 'event_decisions'
              AND NOT EXISTS (SELECT 1 FROM event_decisions d WHERE d.import_run = i.import_run AND d.source_ordinal = i.source_ordinal))
  OR EXISTS (SELECT 1 FROM import_items i WHERE i.import_run = NEW.run_id AND i.landed_table = 'ignored_content'
              AND NOT EXISTS (SELECT 1 FROM ignored_content g WHERE g.import_run = i.import_run AND g.source_ordinal = i.source_ordinal))
  OR EXISTS (SELECT 1 FROM import_items i WHERE i.import_run = NEW.run_id AND i.landed_table = 'ledger'
              AND NOT EXISTS (SELECT 1 FROM ledger l WHERE l.import_run = i.import_run AND l.source_ordinal = i.source_ordinal))
  OR EXISTS (SELECT 1 FROM import_items i WHERE i.import_run = NEW.run_id AND i.landed_table = 'job_markers'
              AND NOT EXISTS (SELECT 1 FROM job_markers j WHERE j.import_run = i.import_run
                               AND j.source_file = i.source_file AND j.source_ordinal = i.source_ordinal))
  OR EXISTS (SELECT 1 FROM import_items i WHERE i.import_run = NEW.run_id AND i.landed_table = 'audit_results'
              AND NOT EXISTS (SELECT 1 FROM audit_results a WHERE a.import_run = i.import_run AND a.source_ordinal = i.source_ordinal))
  -- every curated field an occurrence carried has its verbatim knowledge_sources row
  OR EXISTS (SELECT 1 FROM import_items i, json_each(i.curated_fields) cf
              WHERE i.import_run = NEW.run_id AND i.item_kind = 'row'
                AND NOT EXISTS (SELECT 1 FROM knowledge_sources k WHERE k.import_run = i.import_run
                                 AND k.source_ordinal = i.source_ordinal AND k.field = cf.value))
  -- every lineage / supersession value is an edge or a pending edge (never dropped)
  OR EXISTS (SELECT 1 FROM knowledge_sources k WHERE k.import_run = NEW.run_id AND k.field = 'lineage'
              AND NOT EXISTS (SELECT 1 FROM lineage_pending p WHERE p.import_run = k.import_run
                               AND p.source_ordinal = k.source_ordinal AND p.relation = 'derivedFrom')
              AND NOT (k.digest IS NOT NULL AND EXISTS (SELECT 1 FROM lineage l WHERE l.child_digest = k.digest))
              AND NOT (k.digest IS NOT NULL AND EXISTS (SELECT 1 FROM archive_copies a JOIN files f ON f.id = a.file_id
                                                         WHERE f.content_digest = k.digest)))
  OR EXISTS (SELECT 1 FROM knowledge_sources k WHERE k.import_run = NEW.run_id AND k.field = 'supersededByID'
              AND NOT EXISTS (SELECT 1 FROM lineage_pending p WHERE p.import_run = k.import_run
                               AND p.source_ordinal = k.source_ordinal AND p.relation = 'supersededBy')
              AND NOT (k.digest IS NOT NULL AND EXISTS (SELECT 1 FROM supersessions s WHERE s.retired_digest = k.digest)))
  -- every footage decision of an occurrence is a footage_decisions row
  OR EXISTS (SELECT 1 FROM knowledge_sources k, json_each(k.value_json) d
              WHERE k.import_run = NEW.run_id AND k.field = 'footageDecisions'
                AND NOT EXISTS (SELECT 1 FROM footage_decisions fd WHERE fd.import_run = k.import_run
                                 AND fd.source_ordinal = k.source_ordinal
                                 AND fd.other_row_id = json_extract(d.value, '$.otherID'))))
BEGIN SELECT RAISE(ABORT, 'import run cannot finish: an occurrence, a landing or a curated value is unaccounted for'); END;

CREATE TRIGGER import_runs_finished_is_final BEFORE UPDATE ON import_runs
WHEN OLD.finished_at IS NOT NULL
BEGIN SELECT RAISE(ABORT, 'a finished import run is history'); END;

-- ---------------------------------------------------------------------------------------------
-- 9. Certifying sidecars as tables (§9.7): completion stamps carry scope + generation certified.
-- ---------------------------------------------------------------------------------------------
CREATE TABLE integrity_runs (              -- integrity-*.json per tier (IntegrityReport.swift)
  run_id        TEXT    NOT NULL,
  tier          INTEGER NOT NULL CHECK (tier BETWEEN 0 AND 6),
  verified_at   INTEGER,
  generation    INTEGER,
  result        TEXT    NOT NULL,
  checked       INTEGER NOT NULL DEFAULT 0,
  passed        INTEGER NOT NULL DEFAULT 0,
  needs_decision INTEGER NOT NULL DEFAULT 0,
  could_not_check INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (run_id, tier)
) STRICT, WITHOUT ROWID;

CREATE TABLE job_markers (                 -- catalog-audit.json, fullhash-backfill.json (F1), sound-print backfill, freshness
  job           TEXT    NOT NULL CHECK (job IN ('audit','fullHash','soundPrint','freshness','verifyCatalog')),
  scope         TEXT    NOT NULL,          -- '*', a volume UUID, a path prefix
  started_at    INTEGER NOT NULL,
  finished_at   INTEGER,
  outcome       TEXT    CHECK (outcome IN ('completed','stopped','failed')),
  generation    INTEGER NOT NULL,          -- the generation the stamp certifies
  detail        TEXT    NOT NULL DEFAULT '{}' CHECK (json_valid(detail)),  -- verbatim file body (hashedSoFar, counts, marked …)
  import_run    TEXT    REFERENCES import_runs(run_id) ON DELETE RESTRICT,   -- F1
  source_file   TEXT,
  source_ordinal INTEGER,
  CHECK ((import_run IS NULL) = (source_file IS NULL) AND (import_run IS NULL) = (source_ordinal IS NULL)),
  PRIMARY KEY (job, scope, started_at)
) STRICT, WITHOUT ROWID;

-- ---------------------------------------------------------------------------------------------
-- 10. LEDGER (§9.7): commits with the mutation it records; append-only by trigger; the JSONL
--     export (ledger/media-ledger.jsonl) is retained as independent evidence (and carries the
--     generation high-water lines, F8 — outside this database on purpose).
-- ---------------------------------------------------------------------------------------------
CREATE TABLE ledger (
  seq          INTEGER PRIMARY KEY,         -- rowid; never reused (no DELETE)
  at           INTEGER NOT NULL,
  generation   INTEGER NOT NULL,
  kind         TEXT    NOT NULL,            -- MediaLedgerEvent.event, verbatim (MediaLedgerEvent.swift:35)
  actor        TEXT    NOT NULL,            -- rick | tidy | promote | angel | app
  record_id    TEXT    NOT NULL,            -- the line's recordID — NOT an FK: an old line may name a quarantined row
  content_key  TEXT    NOT NULL,            -- verbatim 'h:<v1…>' | 'p:<md5>:<size>' | '' — sampled, never identity
  digest       TEXT    REFERENCES content(digest) ON DELETE RESTRICT,  -- via record_id's JSON whole-file digest only (F7)
  path         TEXT    NOT NULL,
  payload      TEXT    NOT NULL CHECK (json_valid(payload)),   -- the JSONL line, verbatim
  imported     INTEGER NOT NULL DEFAULT 0 CHECK (imported IN (0,1)),
  import_run   TEXT    REFERENCES import_runs(run_id) ON DELETE RESTRICT,   -- F4
  source_ordinal INTEGER,                   -- the line number (0-based) in the JSONL
  CHECK ((import_run IS NULL) = (source_ordinal IS NULL)),
  CHECK (imported = (import_run IS NOT NULL))
) STRICT;
CREATE INDEX ledger_by_record ON ledger(record_id);
CREATE INDEX ledger_by_digest ON ledger(digest);
CREATE UNIQUE INDEX ledger_by_source ON ledger(import_run, source_ordinal) WHERE import_run IS NOT NULL;
CREATE TRIGGER ledger_no_update BEFORE UPDATE ON ledger
BEGIN SELECT RAISE(ABORT, 'the ledger is append-only'); END;
CREATE TRIGGER ledger_no_delete BEFORE DELETE ON ledger
BEGIN SELECT RAISE(ABORT, 'the ledger is append-only'); END;
-- INSERT OR REPLACE deletes the old row WITHOUT firing delete triggers (unless recursive_triggers
-- is on), so the replace is refused at insert time instead (verified against SQLite 3.45):
CREATE TRIGGER ledger_no_replace BEFORE INSERT ON ledger
WHEN (NEW.seq IS NOT NULL AND EXISTS (SELECT 1 FROM ledger WHERE seq = NEW.seq))
  OR (NEW.import_run IS NOT NULL AND EXISTS (SELECT 1 FROM ledger
        WHERE import_run = NEW.import_run AND source_ordinal = NEW.source_ordinal))
BEGIN SELECT RAISE(ABORT, 'the ledger is append-only (no replace)'); END;

-- ---------------------------------------------------------------------------------------------
-- 11. Open checks at every open (§9.2): PRAGMA integrity_check; PRAGMA foreign_key_check;
--     SELECT * FROM catalog_state and generations — exactly one row each, schema_version known;
--     then read catalog.highwater: generations.generation < high-water ⇒ open READ-ONLY with the
--     named refusal `restoredBelowHighWater` (F8); a missing high-water file is recreated from the
--     larger of the database generation and the newest `generationHighWater` ledger line.
-- ---------------------------------------------------------------------------------------------
