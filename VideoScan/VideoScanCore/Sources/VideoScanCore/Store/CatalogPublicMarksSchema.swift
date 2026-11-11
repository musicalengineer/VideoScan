// CatalogPublicMarksSchema.swift (VideoScanCore/Store)
// Schema v1.15, migration `v11_public_marks` (Rick approved the table
// 2026-11-09, docs/DECISIONS.md "Make Public is one bit").
// ADDITIVE ONLY — one new table, one index, two append-only triggers, and
// the schema version raised to 16 so a build that does not know the table
// refuses the file instead of writing around it. Verbatim in
// docs/design/catalog_sqlite_schema_v1.sql §20 (CatalogDataSchemaTests
// diffs the two).
//
// `public_marks` — the ONE bit "the whole family may watch this" (Rick
// 2026-11-09: "it is kind of a unix-like bit, if the bit is off, it is
// presumed private"). The bit belongs to the CONTENT (whole-file SHA-256),
// never the path: byte-identical copies share it.
//   * PRIVATE IS THE DEFAULT AND NEEDS NO ROW: a content with no row is
//     private; so is one whose newest row says 0, and one whose newest row
//     this build cannot read (fail closed);
//   * append-only: Make Public and Make Private each append a row; the
//     triggers refuse UPDATE and DELETE, so the history is the table;
//   * the CURRENT bit of a digest is its row with the highest `mark_id`
//     (insertion order — never `decided_at`, a clock that can step back).
//
// (For Rick: an append-only event log keyed by content hash; "current" is
// the last event per key, found through a (digest, mark_id) B-tree. Same
// shape as provenance_roles, with a bool where that has an enum.)

enum CatalogPublicMarksSchema {

    /// Names are permanent: renaming one re-runs it.
    static let migrationID = "v11_public_marks"

    /// `catalog_state.schema_version` once this migration has run.
    static let schemaVersion = 16

    static let statements: [String] = [
        """
        CREATE TABLE public_marks (                -- v1.15: family-wide viewing, set by Rick; the newest row per digest is current; no row = private
          mark_id        INTEGER PRIMARY KEY,
          digest         TEXT    NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
          is_public      INTEGER NOT NULL CHECK (is_public IN (0,1)),
          decided_at     INTEGER NOT NULL
        ) STRICT
        """,
        """
        CREATE INDEX public_marks_by_digest ON public_marks(digest, mark_id)
        """,
        """
        CREATE TRIGGER public_marks_no_update BEFORE UPDATE ON public_marks
        BEGIN SELECT RAISE(ABORT, 'public_marks is append-only history'); END
        """,
        """
        CREATE TRIGGER public_marks_no_delete BEFORE DELETE ON public_marks
        BEGIN SELECT RAISE(ABORT, 'public_marks is append-only history'); END
        """,
    ]

    /// Run after `statements`, inside the same migration.
    static let versionBump: [String] = [
        "UPDATE catalog_state SET schema_version = \(schemaVersion) WHERE singleton = 1",
        "PRAGMA user_version = \(schemaVersion)",
    ]
}
