// CatalogDataSchema.swift (VideoScanCore/Store)
// The DATA tables of catalog schema v1.4 as RAW SQL, verbatim from
// docs/design/catalog_sqlite_schema_v1.sql §2 onward (every table, index,
// trigger and view after the bookkeeping of §1, which is
// CatalogBookkeepingSchema.swift). Step C′ part 2a of
// docs/design/catalog_sqlite_migration_2026_10_16.md §10a.
//
// THE RULE (Rick, 2026-10-17): every integrity-critical statement is raw
// SQL, never the query builder, so this file reads like the DDL it came
// from and a diff against the design document is a text diff. The
// statements are copied character for character, interior comments
// included (SQLite keeps them in sqlite_master too); CatalogDataSchemaTests
// loads the DDL FILE at test time and diffs it against what the migration
// created, so a change to one side without the other fails a test.
//
// Grouped by TABLE in document order: each group is the CREATE TABLE
// followed by the indexes, triggers and views the DDL places after it, up
// to the next CREATE TABLE. `statements` is the concatenation, in the
// DDL's order — forward references (a `files` trigger that names
// `tombstones`, a REFERENCES to `import_runs`) are legal in SQLite, which
// resolves them when the statement runs, not when the trigger is created.
// The groups of §6 onward live in the `CatalogDataSchema+*.swift` files,
// split along the DDL's own section boundaries.
//
// What this file does NOT contain: §1 (catalog_state, generations,
// generation_history and their triggers — part 1), the PRAGMAs (set per
// connection by GRDBCatalogRepository.makePool), and any record mapping
// (part 2b).
//
// For Rick: `enum` with only statics is Swift's way to write a namespace
// that cannot be instantiated; a `"""` literal is a raw multi-line string
// (no escapes are needed because the DDL contains no backslash).

enum CatalogDataSchema {

    /// The migration identifier GRDB records in its own `grdb_migrations`
    /// table, registered after `v1_bookkeeping` with immediate foreign-key
    /// checks. Names are permanent: renaming one re-runs it.
    static let migrationID = "v2_data"

    /// Every statement, in the DDL's document order.
    static let statements: [String] = [
        content,
        volumes,
        files,
        tombstones,
        archiveCopies,
        backupDestinations,
        knowledgeSources,
        userDates,
        userPlaces,
        stars,
        userNotes,
        workflowTags,
        peopleTags,
        familyMusic,
        backupAttestations,
        footageDecisions,
        dispositions,
        soundPrints,
        perceptualPrints,
        captions,
        derivedUnverified,
        captionRuns,
        transcripts,
        dossiers,
        inferredDates,
        mediaChecks,
        regenContext,
        legacyPairIds,
        personSearches,
        contentTextFts,
        lineage,
        lineagePending,
        supersessions,
        avPairs,
        duplicateGroups,
        duplicateMembers,
        footageMembership,
        events,
        eventDecisions,
        eventMembers,
        ignoredContent,
        quarantine,
        importRuns,
        importItems,
        auditResults,
        integrityRuns,
        jobMarkers,
        ledger,
    ].flatMap { $0 }

    // MARK: - content

    static let content: [String] = [
        """
        CREATE TABLE content (
          digest          TEXT    PRIMARY KEY NOT NULL
                          CHECK (length(digest) = 64 AND digest NOT GLOB '*[^0-9a-f]*'),
          algorithm       TEXT    NOT NULL DEFAULT 'sha256' CHECK (algorithm = 'sha256'),
          byte_count      INTEGER NOT NULL CHECK (byte_count >= 0),
          first_seen_at   INTEGER NOT NULL,        -- earliest computedAt/verifiedAt the import or rescan saw
          first_seen_how  TEXT    NOT NULL CHECK (first_seen_how IN ('import','rescan','job'))
        ) STRICT, WITHOUT ROWID
        """,
    ]

    // MARK: - volumes + 1 trigger

    static let volumes: [String] = [
        """
        CREATE TABLE volumes (
          volume_uuid  TEXT PRIMARY KEY NOT NULL
                       CHECK (volume_uuid = '' OR (length(volume_uuid) = 36 AND volume_uuid NOT GLOB '*[^0-9A-F-]*')),
          last_name    TEXT NOT NULL DEFAULT '',   -- ScanContext.volumeName
          mount_type   TEXT NOT NULL DEFAULT '',   -- ScanContext.volumeMountType (local/smb/nfs/afp)
          remote_server TEXT NOT NULL DEFAULT '',
          -- F12: read from the volume (VOL_CAP_FMT_CASE_SENSITIVE) at first scan; 0 = case-insensitive,
          -- which is APFS's default and the conservative answer for an unknown ('' ) volume.
          case_sensitive INTEGER NOT NULL DEFAULT 0 CHECK (case_sensitive IN (0,1))
        ) STRICT, WITHOUT ROWID
        """,
        """
        CREATE TRIGGER volumes_case_sensitivity_fixed                                                -- F12
        BEFORE UPDATE OF case_sensitive ON volumes
        WHEN NEW.case_sensitive IS NOT OLD.case_sensitive
         AND EXISTS (SELECT 1 FROM files WHERE volume_uuid = NEW.volume_uuid)
        BEGIN SELECT RAISE(ABORT, 'a volume with files keeps its case sensitivity (re-fold first)'); END
        """,
    ]

    // MARK: - files + 6 indexes, 12 triggers

    static let files: [String] = [
        """
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
        ) STRICT
        """,
        """
        CREATE UNIQUE INDEX files_live_path ON files(volume_uuid, full_path) WHERE removal_state IS NULL
        """,
        """
        CREATE UNIQUE INDEX files_live_path_fold ON files(volume_uuid, path_fold)
          WHERE removal_state IS NULL AND volume_case_sensitive = 0
        """,
        """
        CREATE INDEX files_by_path_prefix ON files(volume_uuid, full_path)
        """,
        """
        CREATE INDEX files_by_directory   ON files(directory)
        """,
        """
        CREATE INDEX files_by_digest      ON files(content_digest);        -- copies of one content
        CREATE INDEX files_by_removal     ON files(removal_state, removal_since) WHERE removal_state IS NOT NULL
        """,
        """
        CREATE INDEX files_by_lifecycle   ON files(lifecycle, archive_stage)
        """,
        """
        CREATE TRIGGER files_case_flag_matches_volume_ins
        BEFORE INSERT ON files
        WHEN NEW.volume_case_sensitive IS NOT (SELECT case_sensitive FROM volumes WHERE volume_uuid = NEW.volume_uuid)
        BEGIN SELECT RAISE(ABORT, 'volume_case_sensitive must equal volumes.case_sensitive'); END
        """,
        """
        CREATE TRIGGER files_case_flag_matches_volume_upd
        BEFORE UPDATE OF volume_uuid, volume_case_sensitive ON files
        WHEN NEW.volume_case_sensitive IS NOT (SELECT case_sensitive FROM volumes WHERE volume_uuid = NEW.volume_uuid)
        BEGIN SELECT RAISE(ABORT, 'volume_case_sensitive must equal volumes.case_sensitive'); END
        """,
        """
        CREATE TRIGGER files_no_replace
        BEFORE INSERT ON files
        WHEN EXISTS (SELECT 1 FROM files WHERE id = NEW.id)
          OR (NEW.removal_state IS NULL AND EXISTS (SELECT 1 FROM files WHERE removal_state IS NULL
                AND volume_uuid = NEW.volume_uuid AND full_path = NEW.full_path))
          OR (NEW.removal_state IS NULL AND NEW.volume_case_sensitive = 0
              AND EXISTS (SELECT 1 FROM files WHERE removal_state IS NULL AND volume_case_sensitive = 0
                AND volume_uuid = NEW.volume_uuid AND path_fold = NEW.path_fold))
        BEGIN SELECT RAISE(ABORT, 'files rows are never replaced (id or live path already taken)'); END
        """,
        """
        CREATE TRIGGER files_no_delete BEFORE DELETE ON files
        BEGIN SELECT RAISE(ABORT, 'files rows are never deleted; stamp a removal marker'); END
        """,
        """
        CREATE TRIGGER files_removal_revision_monotonic
        BEFORE UPDATE OF removal_revision ON files
        WHEN NEW.removal_revision < OLD.removal_revision
        BEGIN SELECT RAISE(ABORT, 'removal_revision never decreases'); END
        """,
        """
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
        BEGIN SELECT RAISE(ABORT, 'a removal-marker change bumps removal_revision by one, and only a marker change does'); END
        """,
        """
        CREATE TRIGGER files_removal_change_has_tombstone                                           -- F11
        BEFORE UPDATE OF removal_revision ON files
        WHEN NEW.removal_revision <> OLD.removal_revision
         AND NOT EXISTS (SELECT 1 FROM tombstones t
                          WHERE t.file_id = NEW.id AND t.revision = NEW.removal_revision
                            AND t.state IS NEW.removal_state AND t.since IS NEW.removal_since
                            AND t.reason IS NEW.removal_reason AND t.trash_path IS NEW.removal_trash_path
                            AND t.trash_emptied_at IS NEW.removal_trash_emptied_at
                            AND t.last_seen IS NEW.removal_last_seen)
        BEGIN SELECT RAISE(ABORT, 'a removal-marker change must append its tombstone first'); END
        """,
        """
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
        END
        """,
        """
        CREATE TRIGGER files_size_matches_content_ins
        BEFORE INSERT ON files
        WHEN NEW.size_bytes <> (SELECT byte_count FROM content WHERE digest = NEW.content_digest)
        BEGIN SELECT RAISE(ABORT, 'size_bytes differs from content.byte_count'); END
        """,
        """
        CREATE TRIGGER files_size_matches_content_upd
        BEFORE UPDATE OF size_bytes, content_digest ON files
        WHEN NEW.size_bytes <> (SELECT byte_count FROM content WHERE digest = NEW.content_digest)
        BEGIN SELECT RAISE(ABORT, 'size_bytes differs from content.byte_count'); END
        """,
        """
        CREATE TRIGGER files_digest_immutable
        BEFORE UPDATE OF content_digest ON files
        WHEN NEW.content_digest IS NOT OLD.content_digest
        BEGIN SELECT RAISE(ABORT, 'content_digest is immutable; a replaced file is a new row'); END
        """,
        """
        CREATE TRIGGER files_path_change_clears_audit_stamp
        AFTER UPDATE OF full_path, volume_uuid ON files
        WHEN (NEW.full_path IS NOT OLD.full_path OR NEW.volume_uuid IS NOT OLD.volume_uuid)
             AND NEW.audit_seen_volume_uuid IS NOT NULL
        BEGIN
          UPDATE files SET audit_seen_volume_uuid = NULL, audit_seen_mount_from = NULL,
                           audit_seen_device_key = NULL, audit_seen_at = NULL WHERE id = NEW.id;
        END
        """,
    ]

    // MARK: - tombstones + 4 triggers

    static let tombstones: [String] = [
        """
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
        ) STRICT, WITHOUT ROWID
        """,
        """
        CREATE TRIGGER tombstones_no_update BEFORE UPDATE ON tombstones
        BEGIN SELECT RAISE(ABORT, 'tombstones are append-only'); END
        """,
        """
        CREATE TRIGGER tombstones_no_delete BEFORE DELETE ON tombstones
        BEGIN SELECT RAISE(ABORT, 'tombstones are append-only'); END
        """,
        """
        CREATE TRIGGER tombstones_no_replace BEFORE INSERT ON tombstones
        WHEN EXISTS (SELECT 1 FROM tombstones WHERE file_id = NEW.file_id AND revision = NEW.revision)
        BEGIN SELECT RAISE(ABORT, 'tombstones are append-only (no replace)'); END
        """,
        """
        CREATE TRIGGER tombstones_next_revision BEFORE INSERT ON tombstones                          -- F11
        WHEN NEW.door <> 'import'
         AND NEW.revision IS NOT (SELECT removal_revision + 1 FROM files WHERE id = NEW.file_id)
        BEGIN SELECT RAISE(ABORT, 'a tombstone records the NEXT removal revision'); END
        """,
    ]

    // MARK: - archive_copies + 2 triggers, 1 index

    static let archiveCopies: [String] = [
        """
        CREATE TABLE archive_copies (
          file_id        TEXT    PRIMARY KEY NOT NULL REFERENCES files(id) ON DELETE RESTRICT,
          source_file_id TEXT    REFERENCES files(id) ON DELETE RESTRICT,  -- derivedFrom on an archivePromotion row
          source_row_id  TEXT,                    -- F1: the JSON derivedFrom verbatim, kept when the source is quarantined
          archived_at    INTEGER,                 -- Promote's stamp; NULL on old copies (resolvedArchivedAt fallback)
          fixity_verified_at INTEGER NOT NULL,    -- archiveFixity.verifiedAt (Verify Archive refreshes)
          promoted_by    TEXT    NOT NULL CHECK (promoted_by IN ('promote','orphanAdopt','import')),
          CHECK (source_file_id IS NULL OR source_file_id <> file_id)
        ) STRICT, WITHOUT ROWID
        """,
        """
        CREATE TRIGGER archive_copies_need_source
        BEFORE INSERT ON archive_copies
        WHEN NEW.source_file_id IS NULL AND NEW.promoted_by <> 'import'
        BEGIN SELECT RAISE(ABORT, 'an archive copy names its source'); END
        """,
        """
        CREATE TRIGGER archive_copy_never_trashed
        BEFORE UPDATE OF removal_state ON files
        WHEN NEW.removal_state = 'inTrash' AND EXISTS (SELECT 1 FROM archive_copies WHERE file_id = NEW.id)
        BEGIN SELECT RAISE(ABORT, 'MOPS-3: an archive copy is never moved to the Trash'); END
        """,
        """
        CREATE INDEX archive_copies_by_source ON archive_copies(source_file_id)
        """,
    ]

    // MARK: - backup_destinations

    static let backupDestinations: [String] = [
        """
        CREATE TABLE backup_destinations (
          file_id  TEXT    NOT NULL REFERENCES files(id) ON DELETE RESTRICT,
          name     TEXT    NOT NULL,
          kind     TEXT    NOT NULL CHECK (kind IN ('Local','Cloud','Offsite')),
          recorded_at INTEGER NOT NULL,
          PRIMARY KEY (file_id, name, recorded_at)
        ) STRICT, WITHOUT ROWID
        """,
    ]
}
