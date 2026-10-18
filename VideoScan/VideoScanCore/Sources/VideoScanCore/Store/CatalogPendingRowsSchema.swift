// CatalogPendingRowsSchema.swift (VideoScanCore/Store)
// Schema v1.8, migration `v4_pending_rows` (cutover B2.1, docs/design/
// catalog_cutover_f_prime_2026_10_17.md §3): the durable holding place for a
// NEW record that has no whole-file digest yet. ADDITIVE ONLY — one new
// table and one guard, and the schema version raised to 9 so a build that
// does not know the table refuses the file instead of writing around it.
// Verbatim in docs/design/catalog_sqlite_schema_v1.sql §13 (CatalogDataSchemaTests
// diffs the two).
//
// Why it exists. A `files` row needs a whole-file digest (contract §e.2), so
// a scan result, a Combine / Transcode output or a Promote copy that has none
// yet cannot be stored as a row. Without this table it lived in memory only
// and vanished at the next launch. Now the commit that defers it writes the
// app encoder's record payload here (data in a column, like
// `quarantine.raw_row`: evidence, never parsed by SQL), the loader turns it
// back into a record at launch (still deferred), Fill In Full Hashes is
// queued for it, and the commit that finally stores the row deletes it here
// in the same transaction.
//
// A held row is never a stored row: the guard refuses a pending row whose id
// is already in `files`.
//
// (For Rick: a parking lot beside the real table — rows wait here, as an
// opaque blob, until they can be filed properly.)

enum CatalogPendingRowsSchema {

    /// Names are permanent: renaming one re-runs it.
    static let migrationID = "v4_pending_rows"

    /// `catalog_state.schema_version` once this migration has run.
    static let schemaVersion = 9

    static let statements: [String] = [
        """
        CREATE TABLE pending_rows (                -- v1.8: new records waiting for a whole-file digest (cutover B2.1)
          id         TEXT    PRIMARY KEY NOT NULL,
          json       TEXT    NOT NULL CHECK (json_valid(json)),   -- the app encoder's record payload, verbatim
          queued_at  INTEGER NOT NULL
        ) STRICT
        """,
        """
        CREATE TRIGGER pending_rows_not_stored BEFORE INSERT ON pending_rows
        WHEN EXISTS (SELECT 1 FROM files WHERE id = NEW.id)
        BEGIN SELECT RAISE(ABORT, 'pending_rows: this id is already a files row'); END
        """,
    ]

    /// Run after `statements`, inside the same migration.
    static let versionBump: [String] = [
        "UPDATE catalog_state SET schema_version = \(schemaVersion) WHERE singleton = 1",
        "PRAGMA user_version = \(schemaVersion)",
    ]
}
