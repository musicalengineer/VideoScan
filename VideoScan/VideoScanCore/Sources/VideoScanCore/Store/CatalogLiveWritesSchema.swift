// CatalogLiveWritesSchema.swift (VideoScanCore/Store)
// Schema v1.7, migration `v3_live_writes` (cutover B2, docs/design/
// catalog_cutover_f_prime_2026_10_17.md §3): what the app's commits need
// that v1.6 has no room for. ADDITIVE ONLY — one new table, its index and
// its three guards, and the schema version raised to 8 so a build that does
// not know this table refuses the file instead of writing around it. Every
// v1/v2 table, trigger and CHECK is untouched. Verbatim in
// docs/design/catalog_sqlite_schema_v1.sql §12 (CatalogDataSchemaTests
// diffs the two).
//
// Why a new table and not "knowledge_sources with import_run NULL": the
// brief asked for the relaxation, but SQLite cannot drop a NOT NULL without
// rebuilding the table, and `knowledge_sources` is WITHOUT ROWID with
// (import_run, source_ordinal, field) as its primary key — key columns of
// such a table are NOT NULL by definition. Relaxing it means drop + copy +
// recreate of append-only evidence, which is the non-additive change the
// policy escalates. `row_knowledge` holds the app's rows beside it instead.
//
// `row_knowledge` — values written per `files` row, append-only:
//   * every curated field a commit wrote (source 'app:<door>'): the
//     evidence beside the display row the commit replaced (the display row
//     says what the content SHOWS; this says who set it on which row, when);
//   * the four row-scoped values the load reads per row (lineage,
//     supersededByID, repairConfirmedDate, archivedAt) — latest row wins;
//   * 'pair': the row's A/V pair link (pairedWithID, pairGroupID,
//     pairConfidence, combinedFromPairID) — written by the importer for a
//     row whose confidence or combine link `legacy_pair_ids` cannot hold
//     (its CHECK wants a pair id, and a Combine output has only the link),
//     and by the app whenever the link changes. An empty object = no link.
// A value of JSON `null` records that the field was cleared.
//
// (For Rick: an append-only journal table keyed by the row; "the current
// value" is the newest entry per (row, field), like replaying a log.)

enum CatalogLiveWritesSchema {

    /// Names are permanent: renaming one re-runs it.
    static let migrationID = "v3_live_writes"

    /// `catalog_state.schema_version` once this migration has run.
    static let schemaVersion = 8

    /// The `field` values beyond `CatalogDDL.KnowledgeField`.
    static let pairField = "pair"

    static let statements: [String] = [
        """
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
        ) STRICT
        """,
        """
        CREATE INDEX row_knowledge_by_file ON row_knowledge(file_id, field, write_id)
        """,
        """
        CREATE TRIGGER row_knowledge_no_update BEFORE UPDATE ON row_knowledge
        BEGIN SELECT RAISE(ABORT, 'row_knowledge is append-only evidence'); END
        """,
        """
        CREATE TRIGGER row_knowledge_no_delete BEFORE DELETE ON row_knowledge
        BEGIN SELECT RAISE(ABORT, 'row_knowledge is append-only evidence'); END
        """,
        """
        CREATE TRIGGER row_knowledge_no_replace BEFORE INSERT ON row_knowledge
        WHEN NEW.write_id IS NOT NULL AND EXISTS (SELECT 1 FROM row_knowledge WHERE write_id = NEW.write_id)
        BEGIN SELECT RAISE(ABORT, 'row_knowledge: a duplicate is a finding, never a replacement'); END
        """,
    ]

    /// Run after `statements`, inside the same migration.
    static let versionBump: [String] = [
        "UPDATE catalog_state SET schema_version = \(schemaVersion) WHERE singleton = 1",
        "PRAGMA user_version = \(schemaVersion)",
    ]
}
