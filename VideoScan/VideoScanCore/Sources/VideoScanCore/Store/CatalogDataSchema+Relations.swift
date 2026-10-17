// CatalogDataSchema+Relations.swift (VideoScanCore/Store)
// §7: relations — lineage, supersessions, A/V pairs, duplicates, footage, events, ignored content
// of catalog schema v1.4, verbatim from docs/design/catalog_sqlite_schema_v1.sql.
// See CatalogDataSchema.swift for the rule (raw SQL, character for
// character, interior comments kept) and the migration that runs these.
// Split from the main file along the DDL's own section boundary so each
// file stays readable. For Rick: an `extension` on an enum may hold
// static constants — a namespace continued in a second file.

extension CatalogDataSchema {

    // MARK: - lineage + 1 index

    static let lineage: [String] = [
        """
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
        ) STRICT, WITHOUT ROWID
        """,
        """
        CREATE INDEX lineage_by_parent ON lineage(parent_digest)
        """,
    ]

    // MARK: - lineage_pending + 1 trigger

    static let lineagePending: [String] = [
        """
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
        ) STRICT, WITHOUT ROWID
        """,
        """
        CREATE TRIGGER lineage_pending_no_delete BEFORE DELETE ON lineage_pending
        BEGIN SELECT RAISE(ABORT, 'pending lineage is resolved, never deleted'); END
        """,
    ]

    // MARK: - supersessions + 2 triggers

    static let supersessions: [String] = [
        """
        CREATE TABLE supersessions (
          retired_digest TEXT PRIMARY KEY NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
          by_digest      TEXT NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
          confirmed_at   INTEGER,                   -- repairConfirmedDate on the repair; NULL = awaiting Rick
          CHECK (retired_digest <> by_digest)
        ) STRICT, WITHOUT ROWID
        """,
        """
        CREATE TRIGGER supersessions_acyclic
        BEFORE INSERT ON supersessions
        WHEN EXISTS (
          WITH RECURSIVE chain(d) AS (
            SELECT NEW.by_digest
            UNION SELECT s.by_digest FROM supersessions s JOIN chain ON s.retired_digest = chain.d)
          SELECT 1 FROM chain WHERE d = NEW.retired_digest)
        BEGIN SELECT RAISE(ABORT, 'supersession would run in a circle'); END
        """,
        """
        CREATE TRIGGER supersessions_no_rewrite BEFORE UPDATE OF retired_digest, by_digest ON supersessions
        BEGIN SELECT RAISE(ABORT, 'supersession links are not rewritten; delete (un-confirm) and insert'); END
        """,
    ]

    // MARK: - av_pairs

    static let avPairs: [String] = [
        """
        CREATE TABLE av_pairs (
          pair_group_id TEXT PRIMARY KEY NOT NULL CHECK (length(pair_group_id) = 36),
          video_digest  TEXT NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
          audio_digest  TEXT NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
          confidence    TEXT NOT NULL CHECK (confidence IN ('High','Medium','Low')),
          combined_digest TEXT REFERENCES content(digest) ON DELETE RESTRICT,  -- combinedFromPairID, inverted
          CHECK (video_digest <> audio_digest),
          UNIQUE (video_digest, audio_digest)
        ) STRICT, WITHOUT ROWID
        """,
    ]

    // MARK: - duplicate_groups

    static let duplicateGroups: [String] = [
        """
        CREATE TABLE duplicate_groups (
          group_id     TEXT PRIMARY KEY NOT NULL CHECK (length(group_id) = 36),
          analyzed_at  INTEGER NOT NULL
        ) STRICT, WITHOUT ROWID
        """,
    ]

    // MARK: - duplicate_members + 2 views

    static let duplicateMembers: [String] = [
        """
        CREATE TABLE duplicate_members (
          group_id     TEXT NOT NULL REFERENCES duplicate_groups(group_id) ON DELETE CASCADE,
          file_id      TEXT NOT NULL REFERENCES files(id) ON DELETE RESTRICT,
          confidence   TEXT NOT NULL CHECK (confidence IN ('High','Medium','Low')),
          disposition  TEXT NOT NULL CHECK (disposition IN ('Keep','Review','Extra copy')),
          reasons      TEXT NOT NULL DEFAULT '',  -- DuplicateDetector's comma-separated reason words, verbatim
          best_match   TEXT NOT NULL DEFAULT '',
          PRIMARY KEY (group_id, file_id),
          UNIQUE (file_id)                          -- a file is in at most one group (one duplicateGroupID)
        ) STRICT, WITHOUT ROWID
        """,
        """
        CREATE VIEW duplicate_hash_groups_disagree AS          -- D:530: rule 13's finding, for the job
          SELECT m.group_id, count(DISTINCT f.content_digest) AS digests
            FROM duplicate_members m JOIN files f ON f.id = m.file_id
           WHERE f.removal_state IS NULL
           GROUP BY m.group_id
          HAVING count(DISTINCT f.content_digest) > 1
             AND max(instr(',' || replace(m.reasons, ' ', '') || ',', ',hash,') > 0) = 1
        """,
        """
        CREATE VIEW byte_copies AS
          SELECT content_digest AS digest, count(*) AS live_files
            FROM files WHERE removal_state IS NULL GROUP BY content_digest HAVING count(*) > 1
        """,
    ]

    // MARK: - footage_membership + 1 index

    static let footageMembership: [String] = [
        """
        CREATE TABLE footage_membership (
          digest       TEXT PRIMARY KEY NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
          group_id     TEXT NOT NULL,
          membership   TEXT NOT NULL CHECK (json_valid(membership)),
          scanned_at   INTEGER NOT NULL,
          provenance   TEXT NOT NULL DEFAULT 'bound' CHECK (provenance = 'bound')    -- F9
        ) STRICT, WITHOUT ROWID
        """,
        """
        CREATE INDEX footage_membership_by_group ON footage_membership(group_id)
        """,
    ]

    // MARK: - events

    static let events: [String] = [
        """
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
        ) STRICT, WITHOUT ROWID
        """,
    ]

    // MARK: - event_decisions + 1 index, 3 triggers

    static let eventDecisions: [String] = [
        """
        CREATE TABLE event_decisions (               -- the stream, verbatim, in order; unknown kinds kept
          seq          INTEGER PRIMARY KEY,
          kind         TEXT NOT NULL,                -- member | differentOccasions | merged | categoryRejected | suggestionDismissed | <unknown>
          payload      TEXT NOT NULL CHECK (json_valid(payload)),
          import_run   TEXT REFERENCES import_runs(run_id) ON DELETE RESTRICT,   -- F4
          source_ordinal INTEGER,
          CHECK ((import_run IS NULL) = (source_ordinal IS NULL))
        ) STRICT
        """,
        """
        CREATE UNIQUE INDEX event_decisions_by_source ON event_decisions(import_run, source_ordinal) WHERE import_run IS NOT NULL
        """,
        """
        CREATE TRIGGER event_decisions_no_update BEFORE UPDATE ON event_decisions
        BEGIN SELECT RAISE(ABORT, 'the decision stream is append-only'); END
        """,
        """
        CREATE TRIGGER event_decisions_no_delete BEFORE DELETE ON event_decisions
        BEGIN SELECT RAISE(ABORT, 'the decision stream is append-only'); END
        """,
        """
        CREATE TRIGGER event_decisions_no_replace BEFORE INSERT ON event_decisions                  -- F4
        WHEN (NEW.seq IS NOT NULL AND EXISTS (SELECT 1 FROM event_decisions WHERE seq = NEW.seq))
          OR (NEW.import_run IS NOT NULL AND EXISTS (SELECT 1 FROM event_decisions
                WHERE import_run = NEW.import_run AND source_ordinal = NEW.source_ordinal))
        BEGIN SELECT RAISE(ABORT, 'the decision stream is append-only (no replace)'); END
        """,
    ]

    // MARK: - event_members + 2 indexes

    static let eventMembers: [String] = [
        """
        CREATE TABLE event_members (                 -- the fold (accepted − rejected, merges followed)
          event_id     TEXT NOT NULL REFERENCES events(event_id) ON DELETE RESTRICT,
          digest       TEXT NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,  -- eventMembersExist (rule 10) as an FK
          range_start_s REAL,                         -- ContentRange.start/end; NULL = whole file
          range_end_s   REAL,
          imported_key TEXT NOT NULL,                 -- the original contentKey, for the comparator
          CHECK ((range_start_s IS NULL) = (range_end_s IS NULL)),
          CHECK (range_start_s IS NULL OR range_start_s <= range_end_s)
        ) STRICT
        """,
        """
        CREATE UNIQUE INDEX event_members_unique ON event_members(event_id, digest, ifnull(range_start_s,-1), ifnull(range_end_s,-1))
        """,
        """
        CREATE INDEX event_members_by_digest ON event_members(digest)
        """,
    ]

    // MARK: - ignored_content + 3 indexes, 1 trigger

    static let ignoredContent: [String] = [
        """
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
        ) STRICT
        """,
        """
        CREATE UNIQUE INDEX ignored_by_source ON ignored_content(import_run, source_ordinal) WHERE import_run IS NOT NULL
        """,
        """
        CREATE INDEX ignored_by_md5  ON ignored_content(partial_md5, size_bytes)
        """,
        """
        CREATE INDEX ignored_by_name ON ignored_content(lower(filename), size_bytes)
        """,
        """
        CREATE TRIGGER ignored_content_no_replace BEFORE INSERT ON ignored_content                  -- F4
        WHEN (NEW.ignored_seq IS NOT NULL AND EXISTS (SELECT 1 FROM ignored_content WHERE ignored_seq = NEW.ignored_seq))
          OR (NEW.import_run IS NOT NULL AND EXISTS (SELECT 1 FROM ignored_content
                WHERE import_run = NEW.import_run AND source_ordinal = NEW.source_ordinal))
        BEGIN SELECT RAISE(ABORT, 'ignored_content: a duplicate is a finding, never a replacement'); END
        """,
    ]
}
