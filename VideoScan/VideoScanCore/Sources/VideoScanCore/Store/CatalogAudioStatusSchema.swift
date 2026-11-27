// CatalogAudioStatusSchema.swift (VideoScanCore/Store)
// Schema v1.16, migration `v12_audio_status` (Rick 2026-11-27, docs/DECISIONS.md
// "#518 + orange rows, one additive migration"). The stored audio verdict
// (`media_checks.status` where kind = 'audio') gains two words:
//   * 'attention'  — a QuickTime reference movie, or sound that needs
//                    rebuilding: not usable as it stands, so every gate refuses
//                    it exactly as it refuses 'damaged'; but it is not damage,
//                    so its row is orange, not red;
//   * 'unverified' — a pre-fix "ok" WITHDRAWN by a re-measure (GH #518): the
//                    sound pass that stored it did not see the filter graph
//                    rebuilt mid-stream. Read as "never verified" everywhere.
//                    It is a BOUND row, so it outranks the imported catalog.json
//                    value in `derived_unverified` at every load (bound beats
//                    unverified, kind by kind) — clearing the row instead would
//                    let the imported "ok" come back at relaunch.
// Verbatim in docs/design/catalog_sqlite_schema_v1.sql §6b (the CHECK) and
// §21 (this note); CatalogDataSchemaTests diffs the document against the
// migrated file.
//
// WIDENING A CHECK IS A TABLE REBUILD in SQLite (ALTER TABLE cannot change a
// constraint; https://sqlite.org/lang_altertable.html §"Making other kinds of
// table schema changes"). Additive in effect: every row is copied verbatim, no
// value changes, nothing is dropped that is not first copied; the only change
// is that two more words are allowed. The order is chosen so the new table is
// created under its REAL name from the document's text (a rename of a new
// table would store `CREATE TABLE "media_checks"` with quotes, and the
// document diff would see a different statement):
//   1. RENAME the old table aside (`media_checks_v16`). Nothing references
//      media_checks (no foreign key, trigger or view names it), so no other
//      object is rewritten;
//   2. CREATE media_checks with the widened CHECK;
//   3. INSERT … SELECT every row, columns named (foreign keys are checked as
//      each row lands: `.immediate`, like every migration here — no PARENT
//      table is dropped, so GRDB's `.deferred` exception does not apply);
//   4. DROP the old table;
//   5. the row count before = after, or the migration throws and GRDB rolls
//      the whole transaction back (the file stays at 16, untouched).
// The version is raised to 17 so a build that does not know the two words
// refuses the file instead of misreading them.
//
// Cost: one pass over media_checks (≤ 3 rows per content: audio, video,
// reportCard). Measured at 100k contents (300k rows, cards included) in
// CatalogAudioStatusMigrationTests. Worst-case extra disk during the
// transaction: one copy of the table (the old one is freed at commit).
//
// (For Rick: the classic "copy to a new table with the new constraint, swap"
// — what you would do in any SQL engine without ALTER CONSTRAINT, inside one
// transaction so a crash leaves the old table whole.)

import GRDB

enum CatalogAudioStatusSchema {

    /// Names are permanent: renaming one re-runs it.
    static let migrationID = "v12_audio_status"

    /// `catalog_state.schema_version` once this migration has run.
    static let schemaVersion = 17

    /// The old table's name while its rows are copied.
    static let asideName = "media_checks_v16"

    /// The widened table — verbatim in the document's §6b.
    static let mediaChecks = """
        CREATE TABLE media_checks (                -- Verify Audio / Verify Video / Check Media report card
          digest      TEXT NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
          kind        TEXT NOT NULL CHECK (kind IN ('audio','video','reportCard')),
          status      TEXT NOT NULL,
          note        TEXT NOT NULL DEFAULT '',
          checked_at  INTEGER,
          card        TEXT CHECK (card IS NULL OR json_valid(card)),   -- MediaReportCard, reportCard only
          provenance  TEXT NOT NULL DEFAULT 'bound' CHECK (provenance = 'bound'),   -- F9
          CHECK (kind <> 'audio'      OR status IN ('ok','damaged','attention','unverified')),   -- v1.16: 'attention' = reference movie / needs rebuilding (orange; refused like damaged); 'unverified' = an "ok" withdrawn by a re-measure
          CHECK (kind <> 'video'      OR status IN ('ok','warning','broken')),
          CHECK (kind <> 'reportCard' OR (status IN ('quick','full') AND card IS NOT NULL)),
          PRIMARY KEY (digest, kind)
        ) STRICT, WITHOUT ROWID
        """

    private static let columns = "digest, kind, status, note, checked_at, card, provenance"

    static let statements: [String] = [
        "ALTER TABLE media_checks RENAME TO \(asideName)",
        mediaChecks,
        "INSERT INTO media_checks (\(columns)) SELECT \(columns) FROM \(asideName)",
        "DROP TABLE \(asideName)",
    ]

    /// Run after `statements`, inside the same migration.
    static let versionBump: [String] = [
        "UPDATE catalog_state SET schema_version = \(schemaVersion) WHERE singleton = 1",
        "PRAGMA user_version = \(schemaVersion)",
    ]

    /// Why a rebuild refused: the copy did not carry every row.
    struct RowCountMismatch: Error, CustomStringConvertible {
        let before: Int
        let after: Int
        var description: String {
            "media_checks rebuild copied \(after) of \(before) rows — refused, nothing changed"
        }
    }

    /// The migration body: the rebuild, the row-count proof, the version bump.
    /// Throws (and GRDB rolls back) unless every row arrived.
    static func run(_ db: Database) throws {
        let before = try Int.fetchOne(db, sql: "SELECT count(*) FROM media_checks") ?? 0
        try db.execute(sql: statements[0])
        try db.execute(sql: statements[1])
        try db.execute(sql: statements[2])
        let copied = try Int.fetchOne(db, sql: "SELECT count(*) FROM media_checks") ?? -1
        guard copied == before else { throw RowCountMismatch(before: before, after: copied) }
        try db.execute(sql: statements[3])
        for statement in versionBump { try db.execute(sql: statement) }
    }
}
