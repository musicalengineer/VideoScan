// CatalogCommitB22Schema.swift (VideoScanCore/Store)
// Schema v1.9, migration `v5_b22_commit` (cutover B2.2). ADDITIVE ONLY —
// one new table, one new index, and the schema version raised to 10 so a
// build that does not know them refuses the file instead of writing around
// it. Verbatim in docs/design/catalog_sqlite_schema_v1.sql §14
// (CatalogDataSchemaTests diffs the two).
//
// 1. `pending_purges` (codex B2.1 closing pass, the finding on
//    GRDBCatalogRepository+LivePending.swift:58). A purge used to DELETE the
//    pending row of a held record (a new record with no whole-file digest
//    yet) — its sole payload. A record only momentarily absent from the
//    app's array, or a purge that turns out wrong, then had nothing left
//    anywhere. Now a purge of a held record writes a tombstone HERE and keeps
//    the payload: the load skips a tombstoned pending row (the record stays
//    gone at relaunch, as a purged `files` row does), and the record coming
//    back (`putPendingRow`) clears its tombstone. Only the commit that stores
//    the record as a `files` row removes the pending row (and its tombstone)
//    — the payload then lives on as the row itself.
//
// 2. `import_items_landed_files` — the commit reads each changed row back
//    (`storedRow(id:)`) and that read joins `import_items` on `landed_ref`
//    twice; without an index each join scanned the whole table. Measured
//    2026-10-18 (M4, Debug, 14k rows): 1,000 read-backs 3.09 s → the B2.2
//    synchronous commit of 1,000 rows took 3.85 s against its 1.5 s budget.
//    A partial index on exactly the join's terms.
//
// (For Rick: a soft-delete flag kept in a side table, so the parking-lot
// table itself is not altered; and the missing secondary index on a
// foreign-key-ish column that every one-row lookup was paying for.)

enum CatalogCommitB22Schema {

    /// Names are permanent: renaming one re-runs it.
    static let migrationID = "v5_b22_commit"

    /// `catalog_state.schema_version` once this migration has run.
    static let schemaVersion = 10

    static let statements: [String] = [
        """
        CREATE TABLE pending_purges (              -- v1.9: a held record the app no longer has; its payload is KEPT (cutover B2.2)
          id         TEXT    PRIMARY KEY NOT NULL REFERENCES pending_rows(id) ON DELETE RESTRICT,
          purged_at  INTEGER NOT NULL,
          door       TEXT    NOT NULL
        ) STRICT
        """,
        """
        CREATE INDEX import_items_landed_files ON import_items(landed_ref)
         WHERE source_file = 'catalog.json' AND landed_table = 'files'
        """,
    ]

    /// Run after `statements`, inside the same migration.
    static let versionBump: [String] = [
        "UPDATE catalog_state SET schema_version = \(schemaVersion) WHERE singleton = 1",
        "PRAGMA user_version = \(schemaVersion)",
    ]
}
