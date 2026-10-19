// CatalogFolderKindSchema.swift (VideoScanCore/Store)
// Schema v1.10, migration `v6_folder_kind` (Catalog folders live in
// catalog.sqlite, 2026-10-19). ADDITIVE ONLY — one column on `events` and
// the schema version raised to 11, so a build that does not know the column
// refuses the file instead of writing events without it. Verbatim in
// docs/design/catalog_sqlite_schema_v1.sql §15 (CatalogDataSchemaTests diffs
// the two; §7's `events` CREATE shows the table as sqlite_master holds it
// once this migration has run).
//
// A Catalog folder is a confirmed event (Rick 2026-10-19: "Finder's
// handling, Photos albums' meaning" — a label, never a place on disk). Its
// KIND says what the label is about:
//   event   an occasion (Thanksgiving 1990) — every folder made before this
//           migration, and the default;
//   person  one person's footage (Dad);
//   other   anything else.
// The kind is a word, not a type: nothing else in the schema reads it.
//
// (For Rick: `ALTER TABLE … ADD COLUMN … DEFAULT` is SQLite's only
// in-place schema change that needs no table rebuild — every existing row
// reads the default, and the CHECK holds for every row written after.)

enum CatalogFolderKindSchema {

    /// Names are permanent: renaming one re-runs it.
    static let migrationID = "v6_folder_kind"

    /// `catalog_state.schema_version` once this migration has run.
    static let schemaVersion = 11

    /// The words the column holds.
    static let kinds = ["event", "person", "other"]

    static let statements: [String] = [
        """
        ALTER TABLE events ADD COLUMN kind TEXT NOT NULL DEFAULT 'event' CHECK (kind IN ('event','person','other'))
        """,
    ]

    /// Run after `statements`, inside the same migration.
    static let versionBump: [String] = [
        "UPDATE catalog_state SET schema_version = \(schemaVersion) WHERE singleton = 1",
        "PRAGMA user_version = \(schemaVersion)",
    ]
}
