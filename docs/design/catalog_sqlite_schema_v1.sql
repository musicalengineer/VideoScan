-- catalog_sqlite_schema_v1.sql — VideoScan catalog, SQLite schema v1 (DESIGN, not built)
-- Step B of docs/design/catalog_sqlite_migration_2026_10_16.md §10 (contract freeze, 2026-10-17).
-- Companion: docs/design/catalog_contract_freeze_2026_10_17.md (field inventory, invariants,
-- importer gate §f, reconciliation §g). GH #328.
--
-- THE ONE RULE (§10): identity is the whole-file SHA-256 (64 lowercase hex), never the path and
-- never the sampled `v1:` contentHash. Knowledge (people, dates, places, stars, captions,
-- transcripts, sound prints, lineage, events) is keyed by DIGEST so a rescanned file re-attaches to
-- it wherever it now sits. Rows (`files`) are WHERE content is; `content` is WHAT it is.
--
-- Conventions
--   * Every table is STRICT (SQLite >= 3.37; macOS 13 ships 3.39). Every timestamp is INTEGER
--     unix seconds UTC: the JSON catalog encodes dates with JSONEncoder `.iso8601` (CatalogStore
--     .swift:1322), which carries whole seconds only, so INTEGER seconds is lossless for imported
--     values. FileIdentityStamp's mtime/ctime stay INTEGER nanoseconds (as stored today).
--   * UUIDs are TEXT, uppercase, 36 chars (Foundation's UUID encoding).
--   * Digests are TEXT, lowercase, 64 hex; `storedFullDigest` (VideoScanModel+Cleanup.swift:124)
--     lowercases archive digests — the importer lowercases every digest before insert.
--   * Lineage / knowledge references are ON DELETE RESTRICT (§9.2: "no ON DELETE SET NULL").
--     Nothing in this schema is ever deleted to express "gone": a file row carries its removal
--     state; content rows are never deleted while anything refers to them.
--   * Enum CHECKs list the raw values written by the Swift enums today (cited in the .md §a/§b).

PRAGMA foreign_keys = ON;          -- per connection; the store asserts it after open (§9.2)
PRAGMA journal_mode = WAL;         -- persistent in the file
PRAGMA synchronous = FULL;
PRAGMA fullfsync = ON;             -- macOS: FULL alone does not flush the drive (§9.5)
PRAGMA user_version = 7;           -- JSON schema was v6 (CatalogStore.swift:79); SQLite starts at 7

-- ---------------------------------------------------------------------------------------------
-- 1. Catalog state, generations (CAS) — replaces the JSON header {version, generation, savedAt,
--    savedFromHost, masterArchive} (CatalogStore.swift:100). §9.5: the write precondition is a
--    compare-and-set on `generation` in the SAME transaction as the row changes:
--      UPDATE catalog_state SET generation = :g + 1, saved_at = :now, saved_from_host = :host
--       WHERE singleton = 1 AND generation = :g;      -- changes() must be 1, else ROLLBACK
-- ---------------------------------------------------------------------------------------------
CREATE TABLE catalog_state (
  singleton        INTEGER PRIMARY KEY NOT NULL CHECK (singleton = 1),
  schema_version   INTEGER NOT NULL CHECK (schema_version >= 7),
  generation       INTEGER NOT NULL CHECK (generation >= 0),
  -- §9.5: survives a backup restore; writes are refused while generation < high_water.
  generation_high_water INTEGER NOT NULL CHECK (generation_high_water >= 0),
  saved_at         INTEGER NOT NULL,
  saved_from_host  TEXT    NOT NULL,
  master_archive   TEXT    CHECK (master_archive IS NULL OR json_valid(master_archive)), -- MasterArchiveDesignation
  imported_from    TEXT,   -- 'catalog.json gen <N> sha256 <hex>' — the frozen backup this DB came from (§10 F′)
  CHECK (generation <= generation_high_water OR generation_high_water = 0)
) STRICT;

CREATE TRIGGER catalog_state_generation_steps_by_one
BEFORE UPDATE OF generation ON catalog_state
WHEN NEW.generation <> OLD.generation + 1
BEGIN SELECT RAISE(ABORT, 'generation must advance by exactly one (CAS)'); END;

CREATE TRIGGER catalog_state_high_water_never_falls
BEFORE UPDATE OF generation_high_water ON catalog_state
WHEN NEW.generation_high_water < OLD.generation_high_water
BEGIN SELECT RAISE(ABORT, 'generation high-water mark never falls'); END;

-- One row per committed generation (the CAS history; §4 `generations`).
CREATE TABLE generations (
  generation   INTEGER PRIMARY KEY NOT NULL CHECK (generation >= 0),
  committed_at INTEGER NOT NULL,
  host         TEXT    NOT NULL,
  writer       TEXT    NOT NULL,           -- the door: 'import','rescan','promote','audit','ui', …
  files_live   INTEGER NOT NULL CHECK (files_live >= 0),
  files_total  INTEGER NOT NULL CHECK (files_total >= 0),
  export_sha256 TEXT CHECK (export_sha256 IS NULL OR (length(export_sha256) = 64 AND export_sha256 NOT GLOB '*[^0-9a-f]*'))
) STRICT;

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
  remote_server TEXT NOT NULL DEFAULT ''
) STRICT, WITHOUT ROWID;

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
  full_path       TEXT    NOT NULL CHECK (length(trim(full_path)) > 0 AND substr(full_path,1,1) = '/'),
  filename        TEXT    NOT NULL,
  ext             TEXT    NOT NULL,
  directory       TEXT    NOT NULL,
  size_bytes      INTEGER NOT NULL CHECK (size_bytes >= 0),
  -- stat facts (dateCreatedRaw / dateModifiedRaw — the display strings are dropped, derived)
  fs_created_at   INTEGER,
  fs_modified_at  INTEGER,
  -- the stat stamp the digest was bound to (ContentFixity.stamp / FileIdentityStamp)
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
  set_aside_reason TEXT,                   -- CatalogScopePolicy.SetAsideReason key; NULL = in scope
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
  CHECK ((audit_seen_volume_uuid IS NULL) = (audit_seen_at IS NULL))
) STRICT;

-- UNIQUE live path per volume (rule 2 oneLiveRowPerPath). A removed row may share the path of
-- the row that replaced it. volume_uuid '' rows bind on path alone — today's rule.
CREATE UNIQUE INDEX files_live_path ON files(volume_uuid, full_path) WHERE removal_state IS NULL;
-- queries the app runs
CREATE INDEX files_by_path_prefix ON files(full_path);            -- `full_path >= :p AND full_path < :p || x'7f'`
CREATE INDEX files_by_directory   ON files(directory);
CREATE INDEX files_by_digest      ON files(content_digest);        -- copies of one content
CREATE INDEX files_by_removal     ON files(removal_state, removal_since) WHERE removal_state IS NOT NULL;
CREATE INDEX files_by_lifecycle   ON files(lifecycle, archive_stage);
CREATE INDEX files_case_folded    ON files(volume_uuid, lower(full_path)) WHERE removal_state IS NULL;
                                  -- pathAliasByCase stays a FINDING (a case-sensitive volume may hold both)

-- removal_revision only increases, and only when the marker changes (codex r2 F4; MOPS-14)
CREATE TRIGGER files_removal_revision_monotonic
BEFORE UPDATE OF removal_revision ON files
WHEN NEW.removal_revision < OLD.removal_revision
BEGIN SELECT RAISE(ABORT, 'removal_revision never decreases'); END;

CREATE TRIGGER files_removal_change_bumps_revision
BEFORE UPDATE OF removal_state, removal_since, removal_reason, removal_trash_path ON files
WHEN (NEW.removal_state IS NOT OLD.removal_state OR NEW.removal_since IS NOT OLD.removal_since
      OR NEW.removal_reason IS NOT OLD.removal_reason OR NEW.removal_trash_path IS NOT OLD.removal_trash_path)
     AND NEW.removal_revision <> OLD.removal_revision + 1
BEGIN SELECT RAISE(ABORT, 'a removal-marker change must bump removal_revision by one'); END;

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

-- a file row's content never changes: a file replaced at its path is a NEW row (contract §g case 4);
-- this also keeps duplicate_members' one-digest rule true after insert.
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
CREATE TABLE tombstones (
  file_id     TEXT    NOT NULL REFERENCES files(id) ON DELETE RESTRICT,
  revision    INTEGER NOT NULL CHECK (revision >= 1),
  state       TEXT    CHECK (state IN ('inTrash','removedFromCatalog','missing')),  -- NULL = restored
  since       INTEGER,
  reason      TEXT,
  trash_path  TEXT,
  written_at  INTEGER NOT NULL,
  door        TEXT    NOT NULL,           -- 'stampRemoval','clearRemoval','revertRemoval','import'
  generation  INTEGER NOT NULL,
  PRIMARY KEY (file_id, revision)
) STRICT, WITHOUT ROWID;
CREATE TRIGGER tombstones_no_update BEFORE UPDATE ON tombstones
BEGIN SELECT RAISE(ABORT, 'tombstones are append-only'); END;
CREATE TRIGGER tombstones_no_delete BEFORE DELETE ON tombstones
BEGIN SELECT RAISE(ABORT, 'tombstones are append-only'); END;
CREATE TRIGGER tombstones_no_replace BEFORE INSERT ON tombstones
WHEN EXISTS (SELECT 1 FROM tombstones WHERE file_id = NEW.file_id AND revision = NEW.revision)
BEGIN SELECT RAISE(ABORT, 'tombstones are append-only (no replace)'); END;

-- ---------------------------------------------------------------------------------------------
-- 5. Archive evidence (file-level: the archive COPY at a path is a file fact; its digest is the
--    content's). archiveFixity / archivedAt / promotion source.
-- ---------------------------------------------------------------------------------------------
CREATE TABLE archive_copies (
  file_id        TEXT    PRIMARY KEY NOT NULL REFERENCES files(id) ON DELETE RESTRICT,
  source_file_id TEXT    REFERENCES files(id) ON DELETE RESTRICT,  -- derivedFrom on an archivePromotion row
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
-- 6. KNOWLEDGE BY DIGEST (§10: "after the port they live on DIGESTS"). Curated (Rick) and
--    derived-with-binding (machine) tables. Every table: digest FK RESTRICT to content.
-- ---------------------------------------------------------------------------------------------

-- 6a. Curated by Rick
CREATE TABLE user_dates (
  digest      TEXT PRIMARY KEY NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
  value       TEXT NOT NULL CHECK (value GLOB '[0-9][0-9][0-9][0-9]'
                                OR value GLOB '[0-9][0-9][0-9][0-9]-[0-1][0-9]'
                                OR value GLOB '[0-9][0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9]'),
  confidence  TEXT NOT NULL CHECK (confidence IN ('estimated','known')),
  set_at      INTEGER                     -- unknown for imported values (JSON had no stamp)
) STRICT, WITHOUT ROWID;

CREATE TABLE user_places (
  digest      TEXT PRIMARY KEY NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
  place       TEXT NOT NULL CHECK (length(trim(place)) > 0),
  confidence  TEXT NOT NULL CHECK (confidence IN ('estimated','known')),
  set_at      INTEGER
) STRICT, WITHOUT ROWID;

CREATE TABLE stars (
  digest      TEXT PRIMARY KEY NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
  rating      INTEGER NOT NULL CHECK (rating BETWEEN 1 AND 3)  -- 0 = unrated = no row
) STRICT, WITHOUT ROWID;

CREATE TABLE user_notes (
  digest      TEXT PRIMARY KEY NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
  text        TEXT NOT NULL CHECK (length(text) > 0)
) STRICT, WITHOUT ROWID;

CREATE TABLE workflow_tags (
  digest      TEXT NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
  tag         TEXT NOT NULL CHECK (length(trim(tag)) > 0),  -- canonical display form (WorkflowTags)
  PRIMARY KEY (digest, tag)
) STRICT, WITHOUT ROWID;
CREATE INDEX workflow_tags_by_tag ON workflow_tags(tag COLLATE NOCASE);

-- People: detected / suspected (machine), confirmed / rejected (Rick). One table, one kind column.
CREATE TABLE people_tags (
  digest       TEXT NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
  name         TEXT NOT NULL CHECK (length(trim(name)) > 0),
  kind         TEXT NOT NULL CHECK (kind IN ('detected','suspected','confirmed','rejected')),
  confirmed_at INTEGER,                    -- ConfirmedTag.confirmedAt (confirmed only)
  CHECK ((kind = 'confirmed') = (confirmed_at IS NOT NULL)),
  PRIMARY KEY (digest, name, kind)
) STRICT, WITHOUT ROWID;
CREATE INDEX people_tags_by_name ON people_tags(name COLLATE NOCASE, kind);

CREATE TABLE family_music (
  digest      TEXT PRIMARY KEY NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
  performer   TEXT,
  title       TEXT,
  marked_at   INTEGER NOT NULL
) STRICT, WITHOUT ROWID;

CREATE TABLE backup_attestations (
  digest      TEXT NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
  kind        TEXT NOT NULL CHECK (kind IN ('cloud','offsite','drive')),
  answer      TEXT NOT NULL CHECK (answer IN ('yes','no','notApplicable')),
  label       TEXT,
  attested_at INTEGER NOT NULL,
  by_whom     TEXT NOT NULL,
  PRIMARY KEY (digest, kind, attested_at)
) STRICT, WITHOUT ROWID;

-- The person's footage verdicts ("same footage" / "not the same"), a symmetric pair of contents.
CREATE TABLE footage_decisions (
  digest_a    TEXT NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
  digest_b    TEXT NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
  verdict     TEXT NOT NULL CHECK (verdict IN ('same','notSame')),
  decided_at  INTEGER NOT NULL,
  CHECK (digest_a < digest_b),            -- one row per unordered pair
  PRIMARY KEY (digest_a, digest_b)
) STRICT, WITHOUT ROWID;

-- Media disposition (Triage, Rick) — curated; MediaAnalyzer writes it only while 'Unreviewed'.
CREATE TABLE dispositions (
  digest      TEXT PRIMARY KEY NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
  disposition TEXT NOT NULL CHECK (disposition IN
                ('Important','Recoverable','Suspected Junk','Confirmed Junk'))  -- 'Unreviewed' = no row
) STRICT, WITHOUT ROWID;

-- 6b. Derived stamps WITH content binding (integrity tier 4: the digest they were made from IS
--     the key, so a changed file cannot keep stale knowledge — it is another digest).
CREATE TABLE sound_prints (                -- AudioFingerprintStamp; landmarks stay in audio-fingerprints.sqlite
  digest          TEXT PRIMARY KEY NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
  engine_version  INTEGER NOT NULL CHECK (engine_version >= 1),
  outcome         TEXT    NOT NULL CHECK (outcome IN ('fingerprinted','noAudio')),
  analyzed_s      REAL    NOT NULL CHECK (analyzed_s >= 0),
  complete        INTEGER NOT NULL CHECK (complete IN (0,1)),
  landmarks       INTEGER NOT NULL CHECK (landmarks >= 0),
  blob_bytes      INTEGER NOT NULL CHECK (blob_bytes >= 0),
  computed_at     INTEGER NOT NULL,
  sidecar_key     TEXT    NOT NULL GENERATED ALWAYS AS ('sha256:' || digest) VIRTUAL,
  CHECK (outcome = 'fingerprinted' OR (landmarks = 0 AND blob_bytes = 0))
) STRICT;

CREATE TABLE perceptual_prints (           -- StoredPerceptualFingerprint
  digest          TEXT PRIMARY KEY NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
  algorithm_version INTEGER NOT NULL CHECK (algorithm_version >= 1),
  hashes_b64      TEXT    NOT NULL,
  duration_s      REAL    NOT NULL,
  computed_at     INTEGER NOT NULL
) STRICT, WITHOUT ROWID;

CREATE TABLE captions (                    -- sceneCaptions / ocrDateCandidates / ocrText
  digest      TEXT    NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
  kind        TEXT    NOT NULL CHECK (kind IN ('scene','ocrDate','ocrText')),
  seq         INTEGER NOT NULL CHECK (seq >= 0),   -- array order is meaningful (§9.3)
  at_s        REAL    NOT NULL,                     -- SceneCaption.timestamp
  text        TEXT    NOT NULL,
  PRIMARY KEY (digest, kind, seq)
) STRICT, WITHOUT ROWID;

CREATE TABLE caption_runs (                -- sceneCaptionModel / sceneCaptionDate
  digest      TEXT PRIMARY KEY NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
  model       TEXT NOT NULL,
  made_at     INTEGER NOT NULL
) STRICT, WITHOUT ROWID;

CREATE TABLE transcripts (
  digest      TEXT PRIMARY KEY NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
  text        TEXT NOT NULL,                -- '' = ran, found no speech (distinct from no row)
  model       TEXT,
  made_at     INTEGER
) STRICT, WITHOUT ROWID;

CREATE TABLE dossiers (
  digest       TEXT PRIMARY KEY NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
  processed_at INTEGER NOT NULL,
  processed_by TEXT    NOT NULL
) STRICT, WITHOUT ROWID;

CREATE TABLE inferred_dates (
  digest      TEXT PRIMARY KEY NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
  date_at     INTEGER,                      -- NULL with a reason = "examined, no evidence"
  confidence  REAL    CHECK (confidence IS NULL OR confidence BETWEEN 0 AND 1),
  source      TEXT,                         -- NULL | 'catch-up' | 'propagated from <uuid>' | 'folder-year'
  range_start INTEGER,
  range_end   INTEGER,
  reason      TEXT,
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
  CHECK (kind <> 'audio'      OR status IN ('ok','damaged')),
  CHECK (kind <> 'video'      OR status IN ('ok','warning','broken')),
  CHECK (kind <> 'reportCard' OR (status IN ('quick','full') AND card IS NOT NULL)),
  PRIMARY KEY (digest, kind)
) STRICT, WITHOUT ROWID;

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

-- A/V pairs (correlate): a video-only and an audio-only content that belong together.
-- pair_group_id is kept: confirmed events reference members as 'pair:<pairGroupID>'.
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
CREATE TABLE duplicate_groups (
  group_id     TEXT PRIMARY KEY NOT NULL CHECK (length(group_id) = 36),
  analyzed_at  INTEGER NOT NULL
) STRICT, WITHOUT ROWID;
CREATE TABLE duplicate_members (
  group_id     TEXT NOT NULL REFERENCES duplicate_groups(group_id) ON DELETE CASCADE,
  file_id      TEXT NOT NULL REFERENCES files(id) ON DELETE RESTRICT,
  confidence   TEXT NOT NULL CHECK (confidence IN ('High','Medium','Low')),
  disposition  TEXT NOT NULL CHECK (disposition IN ('Keep','Review','Extra copy')),
  reasons      TEXT NOT NULL DEFAULT '',
  best_match   TEXT NOT NULL DEFAULT '',
  PRIMARY KEY (group_id, file_id),
  UNIQUE (file_id)                          -- a file is in at most one group (one duplicateGroupID)
) STRICT, WITHOUT ROWID;
-- duplicateGroupDigestsAgree (rule 13): every member of a group carries one digest.
CREATE TRIGGER duplicate_members_one_digest
BEFORE INSERT ON duplicate_members
WHEN EXISTS (SELECT 1 FROM duplicate_members m JOIN files f ON f.id = m.file_id
             WHERE m.group_id = NEW.group_id
               AND f.content_digest <> (SELECT content_digest FROM files WHERE id = NEW.file_id))
BEGIN SELECT RAISE(ABORT, 'duplicate group members must share one whole-file digest'); END;
CREATE VIEW byte_copies AS
  SELECT content_digest AS digest, count(*) AS live_files
    FROM files WHERE removal_state IS NULL GROUP BY content_digest HAVING count(*) > 1;

-- Find Similar Footage — the MACHINE's current answer per file (FootageMembership), rewritten each
-- run; rebuildable. Kept as JSON per row: no check or query reaches inside it today.
CREATE TABLE footage_membership (
  digest       TEXT PRIMARY KEY NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
  group_id     TEXT NOT NULL,
  membership   TEXT NOT NULL CHECK (json_valid(membership)),
  scanned_at   INTEGER NOT NULL
) STRICT, WITHOUT ROWID;
CREATE INDEX footage_membership_by_group ON footage_membership(group_id);

-- Events (events-decisions.json, EventsDecisionStore.swift:154). The file is a STREAM of decisions
-- folded into membership (EventsDecisionSnapshot :173); member keys are ContentRange.contentKey =
-- the stored full SHA-256, else 'pair:<pairGroupID>', else 'id:<recordID>' (:35). Imported as they
-- are (Rick: events "only just starting"): the stream verbatim, plus the folded snapshot by digest.
CREATE TABLE events (
  event_id     TEXT PRIMARY KEY NOT NULL CHECK (length(event_id) = 36),
  name         TEXT NOT NULL,
  state        TEXT NOT NULL CHECK (state IN ('confirmed','dismissed')),
  categories   TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(categories)),
  note         TEXT,
  created_at   INTEGER NOT NULL,
  updated_at   INTEGER NOT NULL
) STRICT, WITHOUT ROWID;
CREATE TABLE event_decisions (               -- the stream, verbatim, in order; unknown kinds kept
  seq          INTEGER PRIMARY KEY,
  kind         TEXT NOT NULL,                -- member | differentOccasions | merged | categoryRejected | suggestionDismissed | <unknown>
  payload      TEXT NOT NULL CHECK (json_valid(payload))
) STRICT;
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
-- they stay in event_decisions and are listed in quarantine (reason 'noWholeFileDigest').

-- Ignored content (ignored-content.json, IgnoredContentStore.swift:76/109). Its key today is
-- (partialMD5, sizeBytes), fallback (lower(filename), sizeBytes) — a SAMPLED key. It only makes the
-- scanner SKIP a file (never a delete), so it stays a candidate key here; `digest` is filled when
-- the rescan hashes a match, and an ignored file is still hashed (contract §h Q4).
CREATE TABLE ignored_content (
  entry_id     TEXT PRIMARY KEY NOT NULL CHECK (length(entry_id) = 36),
  partial_md5  TEXT NOT NULL,
  size_bytes   INTEGER NOT NULL CHECK (size_bytes >= 0),
  filename     TEXT NOT NULL,
  reason       TEXT NOT NULL,
  added_at     INTEGER NOT NULL,
  sample_path  TEXT NOT NULL,                 -- shown, never matched on
  digest       TEXT REFERENCES content(digest) ON DELETE RESTRICT
) STRICT, WITHOUT ROWID;
CREATE INDEX ignored_by_md5  ON ignored_content(partial_md5, size_bytes);
CREATE INDEX ignored_by_name ON ignored_content(lower(filename), size_bytes);

-- ---------------------------------------------------------------------------------------------
-- 8. QUARANTINE — every JSON row (and later every rescan item) that cannot enter `files`, with
--    its words and EVERYTHING it carried. Nothing is dropped (§10 D′). A quarantined row is
--    resolved when a rescan finds its digest (contract §g); unresolved rows stay as history.
-- ---------------------------------------------------------------------------------------------
CREATE TABLE quarantine (
  qid           INTEGER PRIMARY KEY,
  origin        TEXT    NOT NULL CHECK (origin IN ('import','rescan')),
  json_row_id   TEXT    CHECK (json_row_id IS NULL OR length(json_row_id) = 36),  -- VideoRecord.id (import)
  full_path     TEXT    NOT NULL,
  size_bytes    INTEGER,
  digest        TEXT    CHECK (digest IS NULL OR (length(digest) = 64 AND digest NOT GLOB '*[^0-9a-f]*')),
  sampled_hash  TEXT,                        -- the v1: value, as evidence only
  reason_code   TEXT    NOT NULL CHECK (reason_code IN
                  ('noWholeFileDigest','auditGone','auditNeverSeen','auditCouldNotCheck','auditChanged',
                   'tier5Finding','fixityDisagree','duplicateId','removedNoDigest','stillBeingWritten',
                   'pathReplaced','unreadable')),
  words         TEXT    NOT NULL,            -- family-app words: what is wrong and what to do
  findings      TEXT    NOT NULL DEFAULT '[]' CHECK (json_valid(findings)),  -- integrity findings for the row
  raw_row       TEXT    CHECK (raw_row IS NULL OR json_valid(raw_row)),      -- the full VideoRecordDTO JSON
  quarantined_at INTEGER NOT NULL,
  generation    INTEGER NOT NULL,
  resolved_file_id TEXT REFERENCES files(id) ON DELETE RESTRICT,
  resolved_at   INTEGER,
  resolution    TEXT    CHECK (resolution IN ('foundByDigest','personDecided','importedAfterHash')),
  CHECK ((resolved_file_id IS NULL) = (resolved_at IS NULL)),
  CHECK ((resolved_at IS NULL) = (resolution IS NULL)),
  CHECK (origin <> 'import' OR (json_row_id IS NOT NULL AND raw_row IS NOT NULL))
) STRICT;
CREATE UNIQUE INDEX quarantine_one_per_json_row ON quarantine(json_row_id) WHERE origin = 'import';
CREATE INDEX quarantine_by_digest  ON quarantine(digest) WHERE digest IS NOT NULL;
CREATE INDEX quarantine_open       ON quarantine(reason_code) WHERE resolved_at IS NULL;
CREATE TRIGGER quarantine_never_deleted BEFORE DELETE ON quarantine
BEGIN SELECT RAISE(ABORT, 'quarantine rows are history; resolve, never delete'); END;
CREATE TRIGGER quarantine_no_replace BEFORE INSERT ON quarantine
WHEN NEW.qid IS NOT NULL AND EXISTS (SELECT 1 FROM quarantine WHERE qid = NEW.qid)
BEGIN SELECT RAISE(ABORT, 'quarantine rows are history (no replace)'); END;
-- a resolved row stays resolved; only the resolution columns may change, once
CREATE TRIGGER quarantine_resolve_once BEFORE UPDATE ON quarantine
WHEN OLD.resolved_at IS NOT NULL
  OR NEW.raw_row IS NOT OLD.raw_row OR NEW.json_row_id IS NOT OLD.json_row_id
  OR NEW.digest IS NOT OLD.digest OR NEW.words IS NOT OLD.words
BEGIN SELECT RAISE(ABORT, 'quarantine evidence is immutable; a row is resolved once'); END;

-- Import reconciliation line (contract §f): one row per import run; the comparator's verdict.
CREATE TABLE import_runs (
  run_id          TEXT PRIMARY KEY NOT NULL,
  started_at      INTEGER NOT NULL,
  finished_at     INTEGER,
  source_sha256   TEXT NOT NULL CHECK (length(source_sha256) = 64),
  source_generation INTEGER NOT NULL,
  integrity_run_id TEXT NOT NULL,           -- integrity-latest.json runID used as the gate
  rows_before     INTEGER NOT NULL,
  rows_main       INTEGER NOT NULL,
  rows_quarantine INTEGER NOT NULL,
  digests_seen    INTEGER NOT NULL,
  knowledge_rows  INTEGER NOT NULL,
  comparator_ok   INTEGER NOT NULL CHECK (comparator_ok IN (0,1)),
  CHECK (rows_before = rows_main + rows_quarantine)            -- zero loss, or no commit
) STRICT, WITHOUT ROWID;

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

CREATE TABLE job_markers (                 -- catalog-audit.json, fullhash-backfill.json, sound-print backfill, freshness
  job           TEXT    NOT NULL CHECK (job IN ('audit','fullHash','soundPrint','freshness','verifyCatalog')),
  scope         TEXT    NOT NULL,          -- '*', a volume UUID, a path prefix
  started_at    INTEGER NOT NULL,
  finished_at   INTEGER,
  outcome       TEXT    CHECK (outcome IN ('completed','stopped','failed')),
  generation    INTEGER NOT NULL,          -- the generation the stamp certifies
  detail        TEXT    NOT NULL DEFAULT '{}' CHECK (json_valid(detail)),
  PRIMARY KEY (job, scope, started_at)
) STRICT, WITHOUT ROWID;

-- ---------------------------------------------------------------------------------------------
-- 10. LEDGER (§9.7): commits with the mutation it records; append-only by trigger; the JSONL
--     export (ledger/media-ledger.jsonl) is retained as independent evidence.
-- ---------------------------------------------------------------------------------------------
CREATE TABLE ledger (
  seq          INTEGER PRIMARY KEY,         -- rowid; never reused (no DELETE)
  at           INTEGER NOT NULL,
  generation   INTEGER NOT NULL,
  kind         TEXT    NOT NULL,            -- MediaLedgerEvent.event, verbatim (MediaLedgerEvent.swift:35)
  actor        TEXT    NOT NULL,            -- rick | tidy | promote | angel | app
  record_id    TEXT    NOT NULL,            -- the line's recordID — NOT an FK: an old line may name a quarantined row
  content_key  TEXT    NOT NULL,            -- verbatim 'h:<v1…>' | 'p:<md5>:<size>' | '' — sampled, never identity
  digest       TEXT    REFERENCES content(digest) ON DELETE RESTRICT,  -- resolved at import via record_id when known
  path         TEXT    NOT NULL,
  payload      TEXT    NOT NULL CHECK (json_valid(payload)),   -- the JSONL line, verbatim
  imported     INTEGER NOT NULL DEFAULT 0 CHECK (imported IN (0,1))
) STRICT;
CREATE INDEX ledger_by_record ON ledger(record_id);
CREATE INDEX ledger_by_digest ON ledger(digest);
CREATE TRIGGER ledger_no_update BEFORE UPDATE ON ledger
BEGIN SELECT RAISE(ABORT, 'the ledger is append-only'); END;
CREATE TRIGGER ledger_no_delete BEFORE DELETE ON ledger
BEGIN SELECT RAISE(ABORT, 'the ledger is append-only'); END;
-- INSERT OR REPLACE deletes the old row WITHOUT firing delete triggers (unless recursive_triggers
-- is on), so the replace is refused at insert time instead (verified against SQLite 3.45):
CREATE TRIGGER ledger_no_replace BEFORE INSERT ON ledger
WHEN NEW.seq IS NOT NULL AND EXISTS (SELECT 1 FROM ledger WHERE seq = NEW.seq)
BEGIN SELECT RAISE(ABORT, 'the ledger is append-only (no replace)'); END;

-- ---------------------------------------------------------------------------------------------
-- 11. Open checks at every open (§9.2): PRAGMA integrity_check; PRAGMA foreign_key_check;
--     SELECT * FROM catalog_state — exactly one row, schema_version known, generation >= high water.
-- ---------------------------------------------------------------------------------------------
