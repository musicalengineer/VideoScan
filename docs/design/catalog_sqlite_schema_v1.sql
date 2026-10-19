-- catalog_sqlite_schema_v1.sql — VideoScan catalog, SQLite schema v1.6 (BUILT: §2 onward is
-- VideoScanCore/Store/CatalogDataSchema.swift verbatim, migration `v2_data`; §1 is
-- CatalogBookkeepingSchema.swift, migration `v1_bookkeeping`; CatalogDataSchemaTests diffs this
-- file against sqlite_master, so the Swift copy cannot drift from this document)
-- Step B of docs/design/catalog_sqlite_migration_2026_10_16.md §10 (contract freeze, 2026-10-17;
-- revision 2 closes codex's 12 findings, docs/reviews/codex/
-- codex-review-contract-freeze-sqlite-schema-v1-step-b-2026-10-17.md; each change cites `-- F<N>`).
-- Revision 3 (v1.2) closes the closing pass's 6 (docs/reviews/codex/
-- codex-review-contract-freeze-r2-closing-pass-2026-10-17.md): F5, F8, F9 reopened (`-- F<N>r3`)
-- and the new N1 (audit evidence bound to the snapshot), N2 (derived collisions), N3 (Unicode
-- case fold) (`-- N<N>`). Decisions: docs/briefs/cloud/CONTRACT_FREEZE_R3.md.
-- Revision 4 (v1.3, GATED 2026-10-17): F5 final — `findings` must be a JSON array (CHECK + the
-- F5final check). Revision 5 (v1.4, 2026-10-17, C′ part 2a, built; each change is marked
-- `-- fix 2026-10-17` in place): `files_no_replace` split into two EXISTS terms so each lookup
-- uses its partial index (the OR form could use neither and scanned the volume's rows on EVERY
-- insert: 20k rows 23.6 s, 100k rows ~10 min → 0.44 s / 2.2 s; same refusals, F12 + N3 prove it);
-- §6d `content_text_fts`, the FTS5 search text (an addition, with its reasons).
-- Revision 6 (v1.5, 2026-10-17, codex C′ pass on the BUILT store, docs/reviews/codex/
-- codex-review-sqlite-store-parts-1-2a-step-c-2026-10-17.md; each change is marked
-- `-- fix 2026-10-17 (codex C′ #N)` in place): #1/#2 — a REPLACE conflict resolution deleted the row
-- in the way without its delete trigger (`UPDATE OR REPLACE files` onto a live path removed the
-- other file; `INSERT OR REPLACE INTO generations` moved the counter 5 → 99; replacing the current
-- history row rewrote it). Now `PRAGMA recursive_triggers = ON` (the store sets it per connection
-- and queries it back) lets REPLACE's delete reach the delete triggers, every history / evidence
-- table has one (`catalog_state`, `generation_history`, `import_runs`, `import_items`,
-- `audit_results`, `regen_context`, `legacy_pair_ids`, `job_markers` gained theirs), and BEFORE
-- INSERT / BEFORE UPDATE no-replace guards (`catalog_state_no_replace`, `generations_no_replace`,
-- `generation_history_no_replace`, `files_no_replace_upd`, `files_id_immutable`) refuse the
-- statement before any conflict is resolved, which binds a connection that never set the pragma.
-- #7 — `derived_unverified_flags_conflict` walked every row of a (digest, kind, seq) group on each
-- insert (quadratic): the WHEN is now two range probes on the new `derived_unverified_by_value`
-- index and the body no longer re-tests each row. #3/#4/#5/#6 are store-side (the second witness
-- `catalog.highwater.log`, reconciliation under the writer lock, the exact-mark rule of phase 1,
-- the session box) and are described in §1 and §11 below. The two migrations (`v1_bookkeeping`,
-- `v2_data`) were amended IN PLACE: no catalog outside test fixtures had been created by this store
-- (the app does not construct it yet); from the first shipped build on, changes are new migrations.
-- Companion: docs/design/catalog_contract_freeze_2026_10_17.md (field inventory, invariants,
-- importer gate §f, reconciliation §g). Reproductions: catalog_sqlite_schema_v1_checks.sql
-- (`sqlite3 :memory: < catalog_sqlite_schema_v1_checks.sql`). GH #328.
-- Revision 7 (v1.6, 2026-10-17, codex D′ pass on the importer, docs/reviews/codex/
-- codex-review-sqlite-importer-step-d-data-risk-2026-10-17.md #6): `quarantine.reason_code` gains
-- `unrepresentable` — a catalog.json row that a row-local CHECK of files/volumes/content/backup_destinations/
-- sound_prints/footage_decisions would refuse is quarantined with the check's words (RowPreflight.swift)
-- instead of aborting the whole import. Marked `-- fix 2026-10-17 (codex D′ #6)` in place.
-- Revision 8 (v1.7, 2026-10-18, cutover B2 — the app's write side): §12 `row_knowledge`, the one
-- table the live commits need that v1.6 has no room for (VideoScanCore/Store/CatalogLiveWritesSchema
-- .swift, migration `v3_live_writes`, which also raises catalog_state.schema_version to 8). ADDITIVE:
-- no v1.6 table, trigger or CHECK changes.
-- Revision 9 (v1.8, 2026-10-18, cutover B2.1): §13 `pending_rows`, the durable holding place for a
-- NEW record that has no whole-file digest yet (VideoScanCore/Store/CatalogPendingRowsSchema.swift,
-- migration `v4_pending_rows`, which raises catalog_state.schema_version to 9). ADDITIVE.
-- Revision 10 (v1.9, 2026-10-18, cutover B2.2): §14 `pending_purges` — a purge of a held record
-- tombstones its payload instead of deleting it — and the index `import_items_landed_files` the
-- commit's one-row read-back needs (VideoScanCore/Store/CatalogCommitB22Schema.swift, migration
-- `v5_b22_commit`, which raises catalog_state.schema_version to 10). ADDITIVE: no earlier table,
-- trigger, index or CHECK changes.
-- Revision 11 (v1.10, 2026-10-19, Catalog folders live in catalog.sqlite): §15 — `events.kind`
-- (event | person | other, default 'event') by ALTER TABLE … ADD COLUMN (VideoScanCore/Store/
-- CatalogFolderKindSchema.swift, migration `v6_folder_kind`, which raises
-- catalog_state.schema_version to 11). ADDITIVE: one column with a default; no row rewritten, no
-- earlier table, trigger, index or CHECK changed.
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
--     triggers unless recursive_triggers is on — BEFORE INSERT triggers fire before the conflict is
--     resolved, so they can refuse it whatever the connection's pragmas.                       -- F4
--     fix 2026-10-17 (codex C′ #1): the store sets `PRAGMA recursive_triggers = ON` on every
--     connection (below), so on its connections REPLACE's implicit delete ALSO reaches the
--     `*_no_delete` triggers — two layers; and `files` refuses the UPDATE form too
--     (`files_no_replace_upd`), since an UPDATE onto another live row's path is the same deletion.
--   * Enum CHECKs list the raw values written by the Swift enums today (cited in the .md §a/§b).

PRAGMA foreign_keys = ON;          -- per connection; the store asserts it after open (§9.2)
PRAGMA journal_mode = WAL;         -- persistent in the file
PRAGMA synchronous = FULL;
PRAGMA fullfsync = ON;             -- macOS: FULL alone does not flush the drive (§9.5)
PRAGMA recursive_triggers = ON;    -- fix 2026-10-17 (codex C′ #1): REPLACE's implicit delete fires the
                                   -- delete triggers only with this on; per connection, queried back
PRAGMA user_version = 7;           -- JSON schema was v6 (CatalogStore.swift:79); SQLite starts at 7

-- ---------------------------------------------------------------------------------------------
-- 1. Catalog state and the generation counter.                                                -- F8
--    The CAS runs INSIDE the write transaction, against the counter itself:
--      UPDATE generations SET generation = generation + 1, saved_at = :now, saved_from_host = :host
--       WHERE id = 1 AND generation = :expected;      -- changes() must be 1, else ROLLBACK
--    The HIGH-WATER is NOT in this database: a restore of the database would rewind it. It lives
--    in `catalog.highwater` beside the database (one integer, never lowered).
--    F8r3 — TWO-PHASE, high-water FIRST. Every write that advances the generation from g:
--      (1) write `catalog.highwater` = g+1 (temp file, fsync, rename, fsync the directory), append
--          one line `g+1 <ISO 8601> <host>` to `catalog.highwater.log` (the store's own append-only
--          witness, O_APPEND + F_FULLFSYNC; fix 2026-10-17, codex C′ #3), and append
--          `generationHighWater {intended: g+1}` to ledger/media-ledger.jsonl (the app's further
--          witness, part 2b);
--      (2) commit the transaction that runs the CAS g → g+1.
--    fix 2026-10-17 (codex C′ #5): before (1) the sidecar must read EXACTLY g — this session's own
--    generation — and the log's last line must not exceed g. Any other reading is a mark this
--    session did not write (another writer's, or its own from a write that died after (1)): the
--    write is refused, nothing commits, and the session refuses every later write until it is
--    reopened, which runs the open check below. A surviving writer never consumes a crash warning.
--    fix 2026-10-17 (codex C′ #6): the session's CAS expectation is read inside the serialized
--    write, after every earlier write on the same repository has committed — two queued writes
--    commit g+1 then g+2; a stale SECOND repository still gets `generationMismatch`.
--    Invariant at open: highwater >= generation, always. highwater > generation means a restore
--    of the database, or a crash between (1) and (2) — told apart only by the JSONL's last line —
--    and either way the database opens READ-ONLY with the named refusal `restoredBelowHighWater`
--    ("this catalog is older than one this Mac already wrote — open the newer copy or adopt this
--    one explicitly") until a person ADOPTS it. highwater < generation means the high-water file
--    itself was rolled back: it is raised to the generation (never the reverse) and a ledger line
--    says so.
--    ADOPTION is an explicit operation, not a CAS. In one transaction:
--      INSERT INTO generation_history (generation, kind, from_generation, …)
--        VALUES (:hw, 'adopt', :old, …);
--      UPDATE generations SET generation = :hw, adopted_at = :now, adopted_from = :old
--       WHERE id = 1 AND :hw > generation;
--    The step trigger allows the jump only when that `adopt` row (same :hw, same :old) exists.
--    SQLite cannot see transaction boundaries, so "same transaction" is enforced by shape: the
--    adopt row is insertable only while the counter still reads :old, and while an adopt row sits
--    above the counter every ordinary +1 step is refused — a half-done adoption cannot commit
--    and be followed by normal writes. Restore-then-crash-then-restore (codex F8: generation 6
--    commits, the process dies, generation 5 is restored) now trips the rule: (1) already wrote 6.
-- ---------------------------------------------------------------------------------------------
CREATE TABLE catalog_state (
  singleton        INTEGER PRIMARY KEY NOT NULL CHECK (singleton = 1),
  schema_version   INTEGER NOT NULL CHECK (schema_version >= 7),
  master_archive   TEXT    CHECK (master_archive IS NULL OR json_valid(master_archive)), -- MasterArchiveDesignation
  imported_from    TEXT    -- 'catalog.json gen <N> sha256 <hex>' — the frozen backup this DB came from (§10 F′)
) STRICT;
-- fix 2026-10-17 (codex C′ #2): one row; a second insert can only be a REPLACE of it.
CREATE TRIGGER catalog_state_no_replace BEFORE INSERT ON catalog_state
WHEN EXISTS (SELECT 1 FROM catalog_state)
BEGIN SELECT RAISE(ABORT, 'catalog_state is one row, never replaced'); END;
CREATE TRIGGER catalog_state_no_delete BEFORE DELETE ON catalog_state
BEGIN SELECT RAISE(ABORT, 'catalog_state is never deleted'); END;

CREATE TABLE generations (                -- the CAS counter (one row)                          -- F8
  id               INTEGER PRIMARY KEY NOT NULL CHECK (id = 1),
  generation       INTEGER NOT NULL CHECK (generation >= 0),
  saved_at         INTEGER NOT NULL,
  saved_from_host  TEXT    NOT NULL,
  adopted_at       INTEGER,                -- F8r3: the last adoption of a restore (NULL = never)
  adopted_from     INTEGER,                -- F8r3: the generation the restored database carried
  CHECK ((adopted_at IS NULL) = (adopted_from IS NULL)),
  CHECK (adopted_from IS NULL OR adopted_from < generation)
) STRICT;

-- F8: +1 per commit. F8r3: or a jump by ADOPTION, only with its `adopt` history row.
CREATE TRIGGER generations_step_by_one                                                       -- F8 F8r3
BEFORE UPDATE OF generation ON generations
WHEN NEW.generation <> OLD.generation + 1
 AND NOT (NEW.generation > OLD.generation
          AND NEW.adopted_from IS OLD.generation AND NEW.adopted_at IS NOT NULL
          AND EXISTS (SELECT 1 FROM generation_history h
                       WHERE h.generation = NEW.generation AND h.kind = 'adopt'
                         AND h.from_generation = OLD.generation))
BEGIN SELECT RAISE(ABORT, 'generation must advance by exactly one (CAS), or jump by an adopt row'); END;
CREATE TRIGGER generations_no_step_over_pending_adopt                                        -- F8r3
BEFORE UPDATE OF generation ON generations
WHEN NEW.generation = OLD.generation + 1
 AND EXISTS (SELECT 1 FROM generation_history h WHERE h.kind = 'adopt' AND h.generation > NEW.generation)
BEGIN SELECT RAISE(ABORT, 'an adoption is half done: finish it or roll it back'); END;
CREATE TRIGGER generations_adoption_fields_only_by_adoption                                  -- F8r3
BEFORE UPDATE OF adopted_at, adopted_from ON generations
WHEN (NEW.adopted_at IS NOT OLD.adopted_at OR NEW.adopted_from IS NOT OLD.adopted_from)
 AND NEW.adopted_from IS NOT OLD.generation
BEGIN SELECT RAISE(ABORT, 'adopted_from names the generation the adoption jumped from'); END;
CREATE TRIGGER generations_no_delete BEFORE DELETE ON generations
BEGIN SELECT RAISE(ABORT, 'the generation counter is never deleted'); END;
-- fix 2026-10-17 (codex C′ #2): `INSERT OR REPLACE INTO generations … 99` moved the counter 5 → 99
-- with no adoption (REPLACE = delete + insert; the delete trigger fires only with
-- recursive_triggers on). The counter is ONE row: a second insert can only be a REPLACE of it.
CREATE TRIGGER generations_no_replace BEFORE INSERT ON generations
WHEN EXISTS (SELECT 1 FROM generations)
BEGIN SELECT RAISE(ABORT, 'the generation counter is one row, never replaced'); END;

-- One row per committed generation (the CAS history; §4), written in the same transaction.
CREATE TABLE generation_history (
  generation   INTEGER PRIMARY KEY NOT NULL CHECK (generation >= 0),
  committed_at INTEGER NOT NULL,
  host         TEXT    NOT NULL,
  writer       TEXT    NOT NULL,           -- the door: 'import','rescan','promote','audit','ui','adopt', …
  files_live   INTEGER NOT NULL CHECK (files_live >= 0),
  files_total  INTEGER NOT NULL CHECK (files_total >= 0),
  export_sha256 TEXT CHECK (export_sha256 IS NULL OR (length(export_sha256) = 64 AND export_sha256 NOT GLOB '*[^0-9a-f]*')),
  kind         TEXT    NOT NULL DEFAULT 'commit' CHECK (kind IN ('commit','adopt')),        -- F8r3
  from_generation INTEGER,                                                                  -- F8r3: adopt only
  CHECK ((kind = 'adopt') = (from_generation IS NOT NULL)),
  CHECK (from_generation IS NULL OR from_generation < generation)
) STRICT;
CREATE TRIGGER generation_history_names_this_commit                                         -- F8
BEFORE INSERT ON generation_history
WHEN NEW.kind = 'commit' AND NEW.generation IS NOT (SELECT generation FROM generations WHERE id = 1)
BEGIN SELECT RAISE(ABORT, 'a history row names the generation this transaction advanced to'); END;
-- F8r3: an adopt row is written FIRST, while the counter still reads :old, and names a jump up.
CREATE TRIGGER generation_history_adopt_precedes_jump                                       -- F8r3
BEFORE INSERT ON generation_history
WHEN NEW.kind = 'adopt'
 AND (NEW.from_generation IS NOT (SELECT generation FROM generations WHERE id = 1)
      OR NEW.generation <= NEW.from_generation)
BEGIN SELECT RAISE(ABORT, 'an adopt row names the current generation and the high-water above it'); END;
CREATE TRIGGER generation_history_no_update BEFORE UPDATE ON generation_history             -- F8r3
BEGIN SELECT RAISE(ABORT, 'generation history is append-only'); END;
-- fix 2026-10-17 (codex C′ #2): replacing the CURRENT history row rewrote its writer despite the
-- no-update trigger. A row for a generation that already has one can only be a REPLACE of it.
CREATE TRIGGER generation_history_no_replace BEFORE INSERT ON generation_history
WHEN EXISTS (SELECT 1 FROM generation_history WHERE generation = NEW.generation)
BEGIN SELECT RAISE(ABORT, 'generation history is append-only (no replace)'); END;
CREATE TRIGGER generation_history_no_delete BEFORE DELETE ON generation_history
BEGIN SELECT RAISE(ABORT, 'generation history is append-only'); END;

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
  -- F12 / N3: the store's fold of full_path, COMPUTED BY THE APP and stored: NFC, then Unicode
  -- case folding ONLY — diacritics are kept (`é` ≠ `e`):
  --   full_path.precomposedStringWithCanonicalMapping
  --            .folding(options: [.caseInsensitive], locale: nil)    // NOT .diacriticInsensitive
  -- So `É.mov` and `é.mov` share one fold; `é.mov` and `e.mov` do not.
  -- N3: SQLite's lower()/upper()/LIKE/NOCASE are ASCII-only (`lower('É') = 'É'`). They must NEVER
  -- be used for path identity: every trigger and index here compares the STORED path_fold. The
  -- CHECK below is a shape check only (absolute, no ASCII capital survived the fold), not a fold.
  path_fold       TEXT    NOT NULL CHECK (length(path_fold) > 0 AND substr(path_fold,1,1) = '/'
                                          AND path_fold NOT GLOB '*[A-Z]*'),
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
-- F12 / N3: r2's `files_path_fold_follows_path` compared lower(NEW.full_path) with
-- lower(OLD.full_path) and so refused the legal case-only rename `É.mov` → `é.mov` (codex N3).
-- It is REMOVED: the engine cannot compute a Unicode fold, and any approximation with lower()
-- is wrong for non-ASCII names. Instead:
--   * the store has ONE path door (`setPath(id, path)`) that writes full_path AND path_fold
--     (the app's fold, above) in the same UPDATE;
--   * the engine compares stored folds only (files_live_path_fold, files_no_replace);
--   * Verify Catalog's tier-5 rule `pathFoldMatchesPath` recomputes the fold with the same Swift
--     function for every row (a stale fold is a finding, not silently trusted).           -- N3

-- F4: no REPLACE on files (it would delete a row — and its history — without a delete trigger)
-- fix 2026-10-17 (v1.4, scale): the live-path test was ONE subquery with `full_path = … OR
-- (NEW.volume_case_sensitive = 0 AND path_fold = …)`. SQLite uses a partial index only when the
-- index's WHERE terms stand at the top level of the query, never inside an OR branch, so that
-- subquery could use neither files_live_path nor files_live_path_fold and walked every row of the
-- volume on EVERY insert (quadratic: 20k rows 23.6 s, 100k ~10 min). The same test as two EXISTS
-- terms — path, then fold, each with the index's own terms at its top level — runs each lookup
-- through its index (100k rows 2.2 s). The meaning is unchanged: a case-insensitive volume's rows
-- all carry volume_case_sensitive = 0 (files_case_flag_matches_volume_*), so adding that term to
-- the fold lookup excludes nothing. The refusals F12 and N3 reproduce are the proof.
CREATE TRIGGER files_no_replace
BEFORE INSERT ON files
WHEN EXISTS (SELECT 1 FROM files WHERE id = NEW.id)
  OR (NEW.removal_state IS NULL AND EXISTS (SELECT 1 FROM files WHERE removal_state IS NULL
        AND volume_uuid = NEW.volume_uuid AND full_path = NEW.full_path))
  OR (NEW.removal_state IS NULL AND NEW.volume_case_sensitive = 0
      AND EXISTS (SELECT 1 FROM files WHERE removal_state IS NULL AND volume_case_sensitive = 0
        AND volume_uuid = NEW.volume_uuid AND path_fold = NEW.path_fold))
BEGIN SELECT RAISE(ABORT, 'files rows are never replaced (id or live path already taken)'); END;
CREATE TRIGGER files_no_delete BEFORE DELETE ON files
BEGIN SELECT RAISE(ABORT, 'files rows are never deleted; stamp a removal marker'); END;
-- fix 2026-10-17 (codex C′ #1): `UPDATE OR REPLACE files SET full_path = A's path WHERE id = B`
-- deleted A (the UNIQUE live-path conflict; REPLACE's delete never reached files_no_delete with
-- recursive_triggers off). The UPDATE form of files_no_replace: a live row may not take a path
-- another live row holds on its volume (exact, or by fold on a case-insensitive volume). Same
-- two indexed lookups as the INSERT form; `id <> NEW.id` leaves the row's own path alone.
CREATE TRIGGER files_no_replace_upd                                                         -- fix 2026-10-17 (codex C′ #1)
BEFORE UPDATE OF full_path, path_fold, volume_uuid, volume_case_sensitive, removal_state ON files
WHEN NEW.removal_state IS NULL
 AND (EXISTS (SELECT 1 FROM files WHERE removal_state IS NULL
                AND volume_uuid = NEW.volume_uuid AND full_path = NEW.full_path AND id <> NEW.id)
      OR (NEW.volume_case_sensitive = 0
          AND EXISTS (SELECT 1 FROM files WHERE removal_state IS NULL AND volume_case_sensitive = 0
                        AND volume_uuid = NEW.volume_uuid AND path_fold = NEW.path_fold AND id <> NEW.id)))
BEGIN SELECT RAISE(ABORT, 'files rows are never replaced (a live path is already taken)'); END;
-- and the PRIMARY KEY form of the same deletion (`UPDATE OR REPLACE files SET id = A WHERE id = B`):
CREATE TRIGGER files_id_immutable BEFORE UPDATE OF id ON files                            -- fix 2026-10-17 (codex C′ #1)
WHEN NEW.id IS NOT OLD.id
BEGIN SELECT RAISE(ABORT, 'files.id is immutable'); END;

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
  provenance   TEXT CHECK (provenance = 'bound'),                          -- F9 N2 (machine kinds; imported → derived_unverified)
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
--     N2: the per-content tables below hold BOUND values only (`provenance = 'bound'`), keyed by
--     digest (+ kind, seq). Every UNVERIFIED value — all imported derived values but sound prints
--     (contract §e.8) — lives in `derived_unverified`, keyed by its SOURCE ROW as well, so two
--     same-digest rows carrying different first captions both land. A second BOUND value for the
--     same key: byte-identical → dropped as a duplicate (RAISE(IGNORE)); different → refused,
--     and the writer moves BOTH into derived_unverified with conflict = 1.
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
  provenance      TEXT    NOT NULL DEFAULT 'bound' CHECK (provenance = 'bound')  -- F9
) STRICT, WITHOUT ROWID;

CREATE TABLE captions (                    -- sceneCaptions / ocrDateCandidates / ocrText
  digest      TEXT    NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
  kind        TEXT    NOT NULL CHECK (kind IN ('scene','ocrDate','ocrText')),
  seq         INTEGER NOT NULL CHECK (seq >= 0),   -- array order is meaningful (§9.3)
  at_s        REAL    NOT NULL,                     -- SceneCaption.timestamp
  text        TEXT    NOT NULL,
  provenance  TEXT    NOT NULL DEFAULT 'bound' CHECK (provenance = 'bound'),  -- F9
  PRIMARY KEY (digest, kind, seq)
) STRICT, WITHOUT ROWID;
-- N2: a bound value arriving for an occupied (digest, kind, seq). Plain INSERT (no OR IGNORE /
-- OR REPLACE): the trigger decides. Same bytes → the duplicate is dropped; different → refused.
CREATE TRIGGER captions_bound_dedupe BEFORE INSERT ON captions                               -- N2
WHEN EXISTS (SELECT 1 FROM captions c WHERE c.digest = NEW.digest AND c.kind = NEW.kind AND c.seq = NEW.seq
              AND c.text = NEW.text AND c.at_s = NEW.at_s)
BEGIN SELECT RAISE(IGNORE); END;
CREATE TRIGGER captions_bound_conflict BEFORE INSERT ON captions                             -- N2
WHEN EXISTS (SELECT 1 FROM captions c WHERE c.digest = NEW.digest AND c.kind = NEW.kind AND c.seq = NEW.seq
              AND (c.text IS NOT NEW.text OR c.at_s IS NOT NEW.at_s))
BEGIN SELECT RAISE(ABORT, 'derived conflict: two bound values for one (digest, kind, seq) — move both to derived_unverified'); END;

-- N2: every unverified derived value, keyed (digest, kind, seq, source_json_row_id): the row it
-- came from is part of the key, so copies never collide. `source_json_row_id` is the JSON row id
-- for an imported value (unique among main rows: a repeated id is quarantined, F4), or the
-- files.id a SQLite-era value was computed through when it is moved here by a bound conflict.
-- Rows are evidence: never deleted, never replaced; the only update is raising `conflict`.
CREATE TABLE derived_unverified (
  digest         TEXT    NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
  kind           TEXT    NOT NULL CHECK (kind IN (
                   'scene','ocrDate','ocrText',            -- captions (seq = array index)
                   'captionRun','transcript','dossier','inferredDate',
                   'audioCheck','videoCheck','reportCard','perceptualPrint','footageMembership',
                   'detectedPerson','suspectedPerson')),   -- seq = array index; value = the name
  seq            INTEGER NOT NULL DEFAULT 0 CHECK (seq >= 0),
  source_json_row_id TEXT NOT NULL CHECK (length(source_json_row_id) = 36),
  value_json     TEXT    NOT NULL CHECK (json_valid(value_json)),   -- the DTO value, verbatim
  stamp_json     TEXT    NOT NULL DEFAULT '{}' CHECK (json_valid(stamp_json)), -- model / date / size it carried
  import_run     TEXT    REFERENCES import_runs(run_id) ON DELETE RESTRICT,
  source_ordinal INTEGER,
  conflict       INTEGER NOT NULL DEFAULT 0 CHECK (conflict IN (0,1)),
  CHECK ((import_run IS NULL) = (source_ordinal IS NULL)),
  PRIMARY KEY (digest, kind, seq, source_json_row_id)
) STRICT, WITHOUT ROWID;
CREATE INDEX derived_unverified_by_source ON derived_unverified(import_run, source_ordinal) WHERE import_run IS NOT NULL;
-- fix 2026-10-17 (codex C′ #7): the conflict trigger's probes seek this index (group, then value).
CREATE INDEX derived_unverified_by_value ON derived_unverified(digest, kind, seq, value_json);   -- fix 2026-10-17 (codex C′ #7)
CREATE TRIGGER derived_unverified_no_replace BEFORE INSERT ON derived_unverified             -- N2
WHEN EXISTS (SELECT 1 FROM derived_unverified d WHERE d.digest = NEW.digest AND d.kind = NEW.kind
              AND d.seq = NEW.seq AND d.source_json_row_id = NEW.source_json_row_id)
BEGIN SELECT RAISE(ABORT, 'derived_unverified: a duplicate is a finding, never a replacement'); END;
-- different values for one (digest, kind, seq) from different rows flag each other
-- fix 2026-10-17 (codex C′ #7): the WHEN walked every row of the group on EVERY insert (100 /
-- 400 / 1,600 identical-value sources: 56k / 706k / 10.5M VM steps — quadratic). Now two range
-- probes on derived_unverified_by_value: a value below NEW's, a value above it (value_json is NOT
-- NULL, so "different" is exactly "below or above"; the row's own source id cannot repeat, by the
-- no-replace trigger, so the only row with NEW's value AND NEW's source is NEW itself). The body
-- no longer re-tests each row: once the WHEN holds the group carries two distinct values, so EVERY
-- row of it has a differing partner. Same verdicts (N2, C7); CatalogDataSchemaScaleTests pins the
-- growth (1,600 rows ≈ 4× the work of 400, not 15×).
CREATE TRIGGER derived_unverified_flags_conflict AFTER INSERT ON derived_unverified           -- N2
WHEN EXISTS (SELECT 1 FROM derived_unverified d WHERE d.digest = NEW.digest AND d.kind = NEW.kind
              AND d.seq = NEW.seq AND d.value_json < NEW.value_json)
  OR EXISTS (SELECT 1 FROM derived_unverified d WHERE d.digest = NEW.digest AND d.kind = NEW.kind
              AND d.seq = NEW.seq AND d.value_json > NEW.value_json)
BEGIN
  UPDATE derived_unverified SET conflict = 1
   WHERE digest = NEW.digest AND kind = NEW.kind AND seq = NEW.seq AND conflict = 0;
END;
CREATE TRIGGER derived_unverified_only_flag BEFORE UPDATE ON derived_unverified              -- N2
WHEN NEW.digest IS NOT OLD.digest OR NEW.kind IS NOT OLD.kind OR NEW.seq IS NOT OLD.seq
  OR NEW.source_json_row_id IS NOT OLD.source_json_row_id OR NEW.value_json IS NOT OLD.value_json
  OR NEW.stamp_json IS NOT OLD.stamp_json OR NEW.import_run IS NOT OLD.import_run
  OR NEW.source_ordinal IS NOT OLD.source_ordinal OR NEW.conflict < OLD.conflict
BEGIN SELECT RAISE(ABORT, 'derived_unverified is evidence: only conflict may rise'); END;
CREATE TRIGGER derived_unverified_no_delete BEFORE DELETE ON derived_unverified              -- N2
BEGIN SELECT RAISE(ABORT, 'derived_unverified is evidence; regeneration writes a bound row beside it'); END;

CREATE TABLE caption_runs (                -- sceneCaptionModel / sceneCaptionDate
  digest      TEXT PRIMARY KEY NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
  model       TEXT NOT NULL,
  made_at     INTEGER NOT NULL,
  provenance  TEXT NOT NULL DEFAULT 'bound' CHECK (provenance = 'bound')     -- F9
) STRICT, WITHOUT ROWID;

CREATE TABLE transcripts (
  digest      TEXT PRIMARY KEY NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
  text        TEXT NOT NULL,                -- '' = ran, found no speech (distinct from no row)
  model       TEXT,
  made_at     INTEGER,
  provenance  TEXT NOT NULL DEFAULT 'bound' CHECK (provenance = 'bound')     -- F9
) STRICT, WITHOUT ROWID;

CREATE TABLE dossiers (
  digest       TEXT PRIMARY KEY NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
  processed_at INTEGER NOT NULL,
  processed_by TEXT    NOT NULL,
  provenance   TEXT    NOT NULL DEFAULT 'bound' CHECK (provenance = 'bound')  -- F9
) STRICT, WITHOUT ROWID;

CREATE TABLE inferred_dates (
  digest      TEXT PRIMARY KEY NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
  date_at     INTEGER,                      -- NULL with a reason = "examined, no evidence"
  confidence  REAL    CHECK (confidence IS NULL OR confidence BETWEEN 0 AND 1),
  source      TEXT,                         -- NULL | 'catch-up' | 'propagated from <uuid>' | 'folder-year'
  range_start INTEGER,
  range_end   INTEGER,
  reason      TEXT,
  provenance  TEXT    NOT NULL DEFAULT 'bound' CHECK (provenance = 'bound'),  -- F9
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
  provenance  TEXT NOT NULL DEFAULT 'bound' CHECK (provenance = 'bound'),   -- F9
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
                   'donorDate')),     -- 'propagated from <uuid>' + reason; the donor row id verbatim
                   -- F9r3: r2's 'personSearched' (read from detected/suspected names) is REMOVED:
                   -- those are a search's OUTPUTS (hits), not its inputs; a zero-hit search left
                   -- none. Search evidence is `person_searches` below.
  value_json     TEXT    NOT NULL CHECK (json_valid(value_json)),
  reason         TEXT,
  PRIMARY KEY (import_run, source_ordinal, kind, value_json)
) STRICT, WITHOUT ROWID;
CREATE TRIGGER regen_context_no_delete BEFORE DELETE ON regen_context                        -- fix 2026-10-17 (codex C′ #1)
BEGIN SELECT RAISE(ABORT, 'regen_context is imported evidence; never deleted'); END;

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
CREATE TRIGGER legacy_pair_ids_no_delete BEFORE DELETE ON legacy_pair_ids                    -- fix 2026-10-17 (codex C′ #1)
BEGIN SELECT RAISE(ABORT, 'legacy_pair_ids is imported evidence; never deleted'); END;

-- F9r3: person-search evidence — ONE row per (file, search) INCLUDING ZERO HITS, so "Donna was
-- looked for here and not found" survives. Source today (contract §e.8): catalog.json carries
-- none (detectedPeople / suspectedPeople are hits only; mediaReportCard is media health). The
-- only per-file search record is Person Finder's cache, `personfinder_cache.sqlite` table
-- `pf_cache` (A/People/PersonFinderCache.swift:78–91; written :311 from
-- PersonFinderModel+JobLifecycle.swift:1152 and :1162), keyed by (video_path, file_size,
-- mod_date, person_name, engine, threshold, ref_hash) with `total_hits` (0 stored; a
-- watchdog-aborted partial is not, :18). It is a PATH + size + mtime key, a latest-only cache
-- (INSERT OR REPLACE): imported verbatim as `unverified`, never as identity. The SQLite-era
-- search writes `bound` rows (it hashes, then searches).
CREATE TABLE person_searches (
  search_id      INTEGER PRIMARY KEY,
  digest         TEXT    REFERENCES content(digest) ON DELETE RESTRICT,  -- NULL: no main row with a digest at that path
  person_id      TEXT    CHECK (person_id IS NULL OR length(person_id) = 36),  -- POIProfile.uuid; pf_cache names only
  person_name    TEXT    NOT NULL CHECK (length(trim(person_name)) > 0),
  searched_at    INTEGER NOT NULL,         -- pf_cache.cached_at (REAL seconds, floored)
  engine         TEXT    NOT NULL,
  threshold      REAL    NOT NULL,
  hits           INTEGER NOT NULL CHECK (hits >= 0),
  outcome        TEXT    NOT NULL CHECK (outcome IN ('searched','unreadable')),  -- :1162 caches an
                                           -- unreadable file as 0 hits, 0 s, 0 fps: NOT a zero-hit search
  source_json_row_id TEXT,                 -- the catalog row whose fullPath + sizeBytes the cache key named
  provenance     TEXT    NOT NULL CHECK (provenance IN ('bound','unverified')),
  source_key     TEXT    NOT NULL DEFAULT '{}' CHECK (json_valid(source_key)),  -- the pf_cache key, verbatim
  import_run     TEXT    REFERENCES import_runs(run_id) ON DELETE RESTRICT,
  source_ordinal INTEGER,
  CHECK ((import_run IS NULL) = (source_ordinal IS NULL)),
  CHECK (import_run IS NULL OR provenance = 'unverified'),
  CHECK (provenance <> 'bound' OR digest IS NOT NULL),
  CHECK (outcome = 'searched' OR hits = 0)
) STRICT;
CREATE UNIQUE INDEX person_searches_by_source ON person_searches(import_run, source_ordinal) WHERE import_run IS NOT NULL;
CREATE INDEX person_searches_by_digest ON person_searches(digest, person_name COLLATE NOCASE);
CREATE TRIGGER person_searches_no_update BEFORE UPDATE ON person_searches                    -- F9r3
BEGIN SELECT RAISE(ABORT, 'person_searches is append-only evidence'); END;
CREATE TRIGGER person_searches_no_delete BEFORE DELETE ON person_searches                    -- F9r3
BEGIN SELECT RAISE(ABORT, 'person_searches is append-only evidence'); END;
CREATE TRIGGER person_searches_no_replace BEFORE INSERT ON person_searches                   -- F9r3
WHEN (NEW.search_id IS NOT NULL AND EXISTS (SELECT 1 FROM person_searches WHERE search_id = NEW.search_id))
  OR (NEW.import_run IS NOT NULL AND EXISTS (SELECT 1 FROM person_searches
        WHERE import_run = NEW.import_run AND source_ordinal = NEW.source_ordinal))
BEGIN SELECT RAISE(ABORT, 'person_searches: a duplicate is a finding, never a replacement'); END;

-- 6d. SEARCH TEXT — v1.4 addition (2026-10-17, C′ part 2a). ONE FTS5 table over every searchable
--     text a content carries: the BOUND captions / OCR / transcripts of 6b AND the imported,
--     unverified ones in derived_unverified — so a person finds "Donna at the lake" whichever table
--     the words sit in, and every hit names its row (digest, kind, seq, provenance, source row).
--     It is a REGENERABLE index (§10b: derived), never evidence: the importer and the cyclers write
--     it beside the rows they write, and Verify Catalog may rebuild it from 6b and
--     derived_unverified at any time. Why a plain FTS5 table, not external-content and not
--     contentless:
--       * external content reads from ONE rowid table, and every text table above is WITHOUT ROWID
--         (keyed by digest): it would take a mirror table plus three sync triggers;
--       * contentless (content='') cannot return the key columns (even UNINDEXED ones read NULL)
--         and cannot produce snippet() / highlight(), so a hit could not name its row.
--     A plain FTS5 table stores the text once in its own shadow tables (content_text_fts_data,
--     _idx, _content, _docsize, _config — engine-managed, not part of this DDL), returns the key
--     columns with every hit and supports snippets. A virtual table takes no STRICT / CHECK / FK,
--     so the WRITER owns consistency: digest names a content row; kind is 'scene' | 'ocrText' |
--     'ocrDate' | 'transcript'; seq is captions.seq (0 for a transcript); provenance is 'bound'
--     (6b) or 'unverified' (derived_unverified); source_json_row_id is derived_unverified's, or
--     '' for a bound row. unicode61 folds case; remove_diacritics 2 lets "Jose" find "José" —
--     text search is not path identity (N3's rule is about path_fold, which keeps diacritics).
--     No comments inside the parentheses: FTS5 receives the argument text verbatim.
CREATE VIRTUAL TABLE content_text_fts USING fts5(
  text,
  digest UNINDEXED,
  kind UNINDEXED,
  seq UNINDEXED,
  provenance UNINDEXED,
  source_json_row_id UNINDEXED,
  tokenize = 'unicode61 remove_diacritics 2'
);

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
  provenance   TEXT NOT NULL DEFAULT 'bound' CHECK (provenance = 'bound')    -- F9
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
  kind         TEXT NOT NULL DEFAULT 'event' CHECK (kind IN ('event','person','other')),   -- v1.10: added by §15's ALTER
  CHECK ((import_run IS NULL) = (source_ordinal IS NULL))
) STRICT, WITHOUT ROWID;
-- (v1.10) The `kind` line is NOT in `v2_data`'s CREATE: migration `v6_folder_kind` (§15) adds it
-- with ALTER TABLE … ADD COLUMN, and SQLite writes the column into sqlite_master's text right
-- after the last column — this is the table as a fully migrated database holds it.
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
--    F5r3: `findings` holds EVERY tier-5 finding for the row, whichever reason won the precedence
--    (an `auditGone` row with a `referenceMovie` finding keeps it) — never dropped. Any finding
--    closes the byte-match door, even on a presence reason.
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
                   'stillBeingWritten','pathReplaced','unreadable',
                   'unrepresentable')),                        -- fix 2026-10-17 (codex D′ #6): a row a row-local CHECK would refuse
  reason_class  TEXT    NOT NULL GENERATED ALWAYS AS (CASE                                  -- F5
                  WHEN reason_code IN ('auditGone','auditNeverSeen','auditCouldNotCheck',
                                       'noWholeFileDigest','removedNoDigest') THEN 'presence'
                  ELSE 'finding' END) VIRTUAL,
  words         TEXT    NOT NULL,            -- family-app words: what is wrong and what to do
  findings      TEXT    NOT NULL DEFAULT '[]'                                 -- integrity findings for the row
                        CHECK (json_valid(findings) AND json_type(findings) = 'array'),  -- F5 final: an object is not an empty array
  raw_row       TEXT    CHECK (raw_row IS NULL OR json_valid(raw_row)),      -- the full VideoRecordDTO JSON
  quarantined_at INTEGER NOT NULL,
  generation    INTEGER NOT NULL,
  resolved_file_id TEXT REFERENCES files(id) ON DELETE RESTRICT,
  resolved_at   INTEGER,
  resolution    TEXT    CHECK (resolution IN                                                -- F5r3
                  ('foundByDigest','resolvedAsCopy','personDecided','importedAfterHash','resolvedByRule')),
  resolution_note TEXT,                      -- resolvedByRule / personDecided: in words
  resolved_rule TEXT,                        -- F5r3: resolvedByRule — the CatalogConstraints rule name
  resolved_integrity_run TEXT,               -- F5r3: the integrity run id that no longer reports it
  CHECK ((resolved_at IS NULL) = (resolution IS NULL)),
  CHECK (resolution IS NULL OR resolution = 'resolvedByRule' OR resolved_file_id IS NOT NULL),
  CHECK (resolution IS NULL OR resolution NOT IN ('resolvedByRule','personDecided') OR resolution_note IS NOT NULL),
  CHECK ((resolution IS 'resolvedByRule') = (resolved_rule IS NOT NULL AND resolved_integrity_run IS NOT NULL)),  -- F5r3
  CHECK ((resolved_rule IS NULL) = (resolved_integrity_run IS NULL)),                                              -- F5r3
  -- F5 / F5r3: a rescan's byte match resolves a row ONLY when its reason is a presence reason
  -- AND it carries no integrity finding (the CHECK spans both columns). A row WITH findings is
  -- resolved only by resolvedByRule (its rule name + the integrity run that no longer reports it).
  CHECK (resolution IS NULL OR resolution NOT IN ('foundByDigest','resolvedAsCopy')
         OR (reason_class = 'presence' AND json_array_length(findings) = 0)),
  CHECK (resolution IS NULL OR json_array_length(findings) = 0 OR resolution = 'resolvedByRule'),
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
  OR NEW.findings IS NOT OLD.findings     -- F5r3: emptying findings cannot open the byte-match door
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
  -- N1: the snapshot the audit evidence belongs to. The audit saves its auditSeenOn stamps and
  -- records the generation that save produced (`savedGeneration`, A′ adds it with the per-row
  -- results); the integrity report certifies `snapshotGeneration`; the frozen file carries
  -- `source_generation`. All three must be ONE generation, and the audit must have finished
  -- before the integrity run started. Any save in between bumps the generation: refused.
  audit_run_finished_at INTEGER NOT NULL,                                                    -- N1
  audit_generation      INTEGER NOT NULL,   -- catalog-audit.json savedGeneration          -- N1
  integrity_started_at  INTEGER NOT NULL,   -- integrity-latest.json run.startedAt         -- N1
  integrity_generation  INTEGER NOT NULL,   -- integrity-latest.json snapshotGeneration    -- N1
  rows_before     INTEGER NOT NULL DEFAULT 0,
  rows_main       INTEGER NOT NULL DEFAULT 0,
  rows_quarantine INTEGER NOT NULL DEFAULT 0,
  digests_seen    INTEGER NOT NULL DEFAULT 0,
  knowledge_rows  INTEGER NOT NULL DEFAULT 0,
  comparator_ok   INTEGER NOT NULL DEFAULT 0 CHECK (comparator_ok IN (0,1)),
  CHECK (rows_before = rows_main + rows_quarantine),            -- backstop only (F1)
  CHECK (finished_at IS NULL OR comparator_ok = 1),
  CHECK (audit_run_started_at <= audit_run_finished_at),                                     -- N1
  CHECK (audit_run_finished_at < integrity_started_at),                                      -- N1
  CHECK (audit_generation = source_generation AND integrity_generation = source_generation)  -- N1
) STRICT, WITHOUT ROWID;

CREATE TABLE import_items (                                                                  -- F1
  import_run     TEXT    NOT NULL REFERENCES import_runs(run_id) ON DELETE RESTRICT,
  source_file    TEXT    NOT NULL CHECK (source_file IN
                   ('catalog.json','events-decisions.json','ignored-content.json',
                    'media-ledger.jsonl','catalog-audit.json','fullhash-backfill.json',
                    'personfinder_cache.sqlite')),                                           -- F9r3
  source_ordinal INTEGER NOT NULL CHECK (source_ordinal >= 0),
  item_kind      TEXT    NOT NULL CHECK (item_kind IN
                   ('row','event','eventDecision','ignored','ledgerLine','marker','auditResult',
                    'personSearch')),                                                        -- F9r3
  source_key     TEXT,                    -- the id the occurrence carries, verbatim (non-unique)
  -- catalog rows: the §10b curated fields this occurrence carried (non-default), as the importer
  -- decoded them; the comparator re-derives this list from catalog.json independently.
  curated_fields TEXT    NOT NULL DEFAULT '[]' CHECK (json_valid(curated_fields)),
  landed_table   TEXT    NOT NULL CHECK (landed_table IN
                   ('files','quarantine','events','event_decisions','ignored_content','ledger',
                    'job_markers','audit_results','person_searches')),                       -- F9r3
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
CREATE TRIGGER import_items_no_delete BEFORE DELETE ON import_items                          -- fix 2026-10-17 (codex C′ #1)
BEGIN SELECT RAISE(ABORT, 'import_items is the map of an import; never deleted'); END;

-- per-row Tier 0 results, read from catalog-audit.json (F6: the importer does not walk the disk)
-- N1: every result is kept verbatim, and `accepted` says whether it may gate the row:
--   * `present` only when the ROW's own auditSeenOn stamp (from the frozen catalog.json) exists
--     and its seenAt lies within the audit run's [startedAt, finishedAt]. The model clears the
--     stamp on ANY fullPath change (VideoRecord.fullPath didSet, C/VideoRecord.swift:140), so a
--     row moved after the audit cannot carry the old `present`;
--   * any other result only when the path it was judged at equals the row's fullPath.
-- An unaccepted result reads as "no result" → `neverSeen` (contract §f). Codex N1's scenario —
-- path changed after an older completed audit, UUID kept — is refused twice: the stamp is gone,
-- and the save that changed the path bumped the generation (import_runs N1 CHECK).
CREATE TABLE audit_results (                                                                 -- F6 N1
  import_run     TEXT    NOT NULL REFERENCES import_runs(run_id) ON DELETE RESTRICT,
  source_ordinal INTEGER NOT NULL CHECK (source_ordinal >= 0),   -- position in catalog-audit.json's rows
  json_row_id    TEXT    NOT NULL,
  result         TEXT    NOT NULL CHECK (result IN ('present','gone','neverSeen','couldNotCheck','changed','link')),
  detail         TEXT    NOT NULL DEFAULT '{}' CHECK (json_valid(detail)),  -- errno, link component, stamp seen
  judged_path    TEXT,                     -- N1: the path the audit judged (required unless present)
  row_full_path  TEXT    NOT NULL,         -- N1: the row's fullPath in the frozen catalog.json
  row_audit_seen_at INTEGER,               -- N1: the row's auditSeenOn.seenAt; NULL = no stamp
  accepted       INTEGER NOT NULL CHECK (accepted IN (0,1)),                                 -- N1
  CHECK (result = 'present' OR judged_path IS NOT NULL),                                     -- N1
  PRIMARY KEY (import_run, source_ordinal)
) STRICT, WITHOUT ROWID;
CREATE INDEX audit_results_by_row ON audit_results(import_run, json_row_id);
CREATE TRIGGER audit_results_bound_to_snapshot BEFORE INSERT ON audit_results               -- N1
WHEN NEW.accepted IS NOT (
  SELECT CASE WHEN NEW.result = 'present'
              THEN (NEW.row_audit_seen_at IS NOT NULL
                    AND NEW.row_audit_seen_at BETWEEN r.audit_run_started_at AND r.audit_run_finished_at)
              ELSE (NEW.judged_path IS NEW.row_full_path) END
    FROM import_runs r WHERE r.run_id = NEW.import_run)
BEGIN SELECT RAISE(ABORT, 'audit_results.accepted must follow the snapshot rule (N1)'); END;
CREATE TRIGGER audit_results_no_update BEFORE UPDATE ON audit_results                       -- N1
BEGIN SELECT RAISE(ABORT, 'audit results are evidence'); END;
CREATE TRIGGER audit_results_no_delete BEFORE DELETE ON audit_results                       -- fix 2026-10-17 (codex C′ #1)
BEGIN SELECT RAISE(ABORT, 'audit results are evidence'); END;

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
  OR EXISTS (SELECT 1 FROM import_items i WHERE i.import_run = NEW.run_id AND i.landed_table = 'person_searches'  -- F9r3
              AND NOT EXISTS (SELECT 1 FROM person_searches s WHERE s.import_run = i.import_run AND s.source_ordinal = i.source_ordinal))
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
CREATE TRIGGER import_runs_no_delete BEFORE DELETE ON import_runs                            -- fix 2026-10-17 (codex C′ #1)
BEGIN SELECT RAISE(ABORT, 'an import run is history; never deleted'); END;

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
CREATE TRIGGER job_markers_no_delete BEFORE DELETE ON job_markers                            -- fix 2026-10-17 (codex C′ #1)
BEGIN SELECT RAISE(ABORT, 'job markers are history; never deleted'); END;

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
--     no `adopt` history row above the counter (a half-done adoption, F8r3);
--     then the EFFECTIVE high-water (F8 final; fix 2026-10-17, codex C′ #3/#4), INSIDE ONE
--     `BEGIN IMMEDIATE` so no other writer's phase (1) can land between the read and the publish:
--     the largest of THREE witnesses, read on EVERY open —
--       catalog.highwater      — the sidecar, replaced before each commit (F8r3);
--       catalog.highwater.log  — the store's append-only log beside the database, one line per
--                                publication (`<generation> <ISO 8601> <host>`), its LAST parseable
--                                line; a restore that rewinds database AND sidecar together is
--                                caught by this file, which is never replaced (the app's JSONL
--                                ledger line, part 2b, is the further witness; a restore of all
--                                three files from one moment is undetectable by construction);
--       MAX(generation) FROM generation_history — restored with the database, so it only catches a
--                                counter rewound inside the file —
--     and then:
--       high-water = generation ⇒ normal open;
--       high-water > generation ⇒ READ-ONLY, named refusal `restoredBelowHighWater`, until a
--         person adopts (§1); the words name the witness that recorded it;
--       a witness that exists but holds no readable value ⇒ READ-ONLY until a person adopts
--         (adoption rewrites the sidecar and appends a readable line);
--       sidecar < generation (rolled back) or missing ⇒ raised to the generation by
--         COMPARE-AND-RAISE: re-read immediately before writing, never written below what it then
--         holds (codex C′ #4: an opener could otherwise publish 5 over a 6 landed meanwhile); the
--         log gains the same line so both witnesses agree.
--     ADOPTION (§1) takes the person's number only when it is the witnesses' highest value while
--     every witness is readable; with a witness missing or poisoned the person's number becomes
--     the mark, never below a readable witness. Both files are written BEFORE the database jumps.
-- ---------------------------------------------------------------------------------------------

-- ---------------------------------------------------------------------------------------------
-- 12. LIVE WRITES (v1.7, cutover B2, migration `v3_live_writes`). What the app's commits write per
--     `files` row, append-only. `knowledge_sources` keeps the import's evidence untouched: its key
--     (import_run, source_ordinal, field) is NOT NULL by construction (WITHOUT ROWID), so an app row
--     cannot live there without rebuilding that table. Here:
--       * every curated field a commit wrote, source 'app:<door>', beside the display row it replaced;
--       * the four row-scoped values a load reads per row (lineage, supersededByID,
--         repairConfirmedDate, archivedAt) — the newest entry per (row, field) wins; 'null' = cleared;
--       * 'pair': the A/V link {pairedWithID, pairGroupID, pairConfidence, combinedFromPairID} — by
--         the importer (source 'catalog.json') for a row whose confidence or Combine link
--         legacy_pair_ids cannot hold (its CHECK wants a pair id; a Combine output has only the
--         link), and by the app whenever the link changes ('{}' = no link).
--     The migration then runs: UPDATE catalog_state SET schema_version = 8; PRAGMA user_version = 8.
-- ---------------------------------------------------------------------------------------------
CREATE TABLE row_knowledge (               -- v1.7: values written per files row (cutover B2)
  write_id    INTEGER PRIMARY KEY,
  file_id     TEXT    NOT NULL REFERENCES files(id) ON DELETE RESTRICT,
  digest      TEXT    REFERENCES content(digest) ON DELETE RESTRICT,
  field       TEXT    NOT NULL CHECK (field IN (
                'userNotes','tags','mediaDisposition','starRating','confirmedByUserPeople',
                'rejectedPeople','userDate','userDateConfidence','userPlace','userPlaceConfidence',
                'backupAttestations','repairConfirmedDate','footageDecisions','familyMusic',
                'setAsideReason','archivedAt','archiveFixity','lineage','supersededByID',
                'mediaReportCard','pair')),
  value_json  TEXT    NOT NULL CHECK (json_valid(value_json)),   -- 'null' = the value was cleared
  set_at      INTEGER NOT NULL,
  source      TEXT    NOT NULL CHECK (source = 'catalog.json' OR source GLOB 'app:*'),
  import_run  TEXT    REFERENCES import_runs(run_id) ON DELETE RESTRICT,
  generation  INTEGER NOT NULL,
  CHECK ((source = 'catalog.json') = (import_run IS NOT NULL))
) STRICT;
CREATE INDEX row_knowledge_by_file ON row_knowledge(file_id, field, write_id);
CREATE TRIGGER row_knowledge_no_update BEFORE UPDATE ON row_knowledge
BEGIN SELECT RAISE(ABORT, 'row_knowledge is append-only evidence'); END;
CREATE TRIGGER row_knowledge_no_delete BEFORE DELETE ON row_knowledge
BEGIN SELECT RAISE(ABORT, 'row_knowledge is append-only evidence'); END;
CREATE TRIGGER row_knowledge_no_replace BEFORE INSERT ON row_knowledge
WHEN NEW.write_id IS NOT NULL AND EXISTS (SELECT 1 FROM row_knowledge WHERE write_id = NEW.write_id)
BEGIN SELECT RAISE(ABORT, 'row_knowledge: a duplicate is a finding, never a replacement'); END;

-- ---------------------------------------------------------------------------------------------
-- 13. PENDING ROWS (v1.8, cutover B2.1, migration `v4_pending_rows`). A new record (a scan result,
--     a Combine / Transcode output, a Promote copy) with no whole-file digest cannot be a `files` row
--     (§10: identity is the digest). The commit that defers it writes the app encoder's record
--     payload here verbatim (data in a column, like quarantine.raw_row — never parsed by SQL); the
--     load turns it back into a record (still deferred) and Fill In Full Hashes is queued for it;
--     the commit that stores the row deletes its pending row in the same transaction. A held row is
--     never a stored row (the guard). A purge of a record that never got a digest tombstones its
--     row in §14 and keeps it (v1.9; v1.8 deleted it).
--     The migration then runs: UPDATE catalog_state SET schema_version = 9; PRAGMA user_version = 9.
-- ---------------------------------------------------------------------------------------------
CREATE TABLE pending_rows (                -- v1.8: new records waiting for a whole-file digest (cutover B2.1)
  id         TEXT    PRIMARY KEY NOT NULL,
  json       TEXT    NOT NULL CHECK (json_valid(json)),   -- the app encoder's record payload, verbatim
  queued_at  INTEGER NOT NULL
) STRICT;
CREATE TRIGGER pending_rows_not_stored BEFORE INSERT ON pending_rows
WHEN EXISTS (SELECT 1 FROM files WHERE id = NEW.id)
BEGIN SELECT RAISE(ABORT, 'pending_rows: this id is already a files row'); END;

-- ---------------------------------------------------------------------------------------------
-- 14. B2.2 COMMIT SUPPORT (v1.9, cutover B2.2, migration `v5_b22_commit`).
--     PENDING PURGES: a held record (§13) that left the app's catalog array is purged by a
--     TOMBSTONE here; its pending row — the sole copy of its payload — is KEPT. The load skips a
--     tombstoned pending row (the record stays gone at relaunch, as a purged `files` row does);
--     the record coming back (its payload put again) deletes the tombstone; the commit that stores
--     it as a `files` row removes both (the payload then lives on as the row). Nothing else ever
--     deletes a pending row.
--     THE READ-BACK INDEX: a commit reads each changed row back the way a load does, which joins
--     `import_items` on `landed_ref` (§F1) — a full scan per row without this index (1,000
--     read-backs at 14k rows: 3.09 s, Debug, 2026-10-18).
--     The migration then runs: UPDATE catalog_state SET schema_version = 10; PRAGMA user_version = 10.
-- ---------------------------------------------------------------------------------------------
CREATE TABLE pending_purges (              -- v1.9: a held record the app no longer has; its payload is KEPT (cutover B2.2)
  id         TEXT    PRIMARY KEY NOT NULL REFERENCES pending_rows(id) ON DELETE RESTRICT,
  purged_at  INTEGER NOT NULL,
  door       TEXT    NOT NULL
) STRICT;
CREATE INDEX import_items_landed_files ON import_items(landed_ref)
 WHERE source_file = 'catalog.json' AND landed_table = 'files';

-- ---------------------------------------------------------------------------------------------
-- 15. FOLDER KIND (v1.10, Catalog folders, migration `v6_folder_kind`). A Catalog folder is a
--     confirmed event — a label Rick makes, never a place on disk ("Finder's handling, Photos
--     albums' meaning", 2026-10-19). Its kind says what the label is about: 'event' (an
--     occasion — every folder made before v1.10), 'person' (one person's footage), 'other'.
--     The app's folder edits write `events` (upsert by event_id), append to `event_decisions`
--     (import_run NULL — the append-only stream keeps every add, move, remove, rename, kind
--     change and delete) and rebuild `event_members` for the folders a change touched (the fold,
--     digests only: a "pair:" key stays in the stream).
--     The migration runs (not a CREATE, so it is written here as a comment — §7 shows its result):
--       ALTER TABLE events ADD COLUMN kind TEXT NOT NULL DEFAULT 'event' CHECK (kind IN ('event','person','other'));
--       UPDATE catalog_state SET schema_version = 11 WHERE singleton = 1; PRAGMA user_version = 11.
-- ---------------------------------------------------------------------------------------------
