// CatalogProvenanceRolesSchema.swift (VideoScanCore/Store)
// Schema v1.12, migration `v8_provenance_roles` (Rick approved the table
// 2026-10-26, docs/DECISIONS.md "Schema: `provenance_roles` approved").
// ADDITIVE ONLY — one new table, one index, two append-only triggers, and
// the schema version raised to 13 so a build that does not know the table
// refuses the file instead of writing around it. Verbatim in
// docs/design/catalog_sqlite_schema_v1.sql §17 (CatalogDataSchemaTests
// diffs the two).
//
// `provenance_roles` — what a content IS, in Rick's words
// (docs/guides/provenance_roles.md): Master, Camera Original, Alternate
// Capture, Remastered Copy, Edit Copy, Excerpt, View Copy, Test Copy,
// Unknown. A role belongs to the CONTENT (whole-file SHA-256), never the
// path: byte-identical copies share it.
//   * append-only: every choice Rick makes is a new row; the triggers
//     refuse UPDATE and DELETE, so the history is the table;
//   * the CURRENT role of a digest is its row with the highest `role_id`
//     (insertion order — never `decided_at`, a clock that can step back);
//     no row = Unknown; setting Unknown appends an `unknown` row;
//   * `source_missing` is 1 only when Rick marked an only-surviving clip
//     or copy as Master ("source not in the catalog"); the reader ignores
//     it on any other role;
//   * `role` holds stable keys (ProvenanceRole.rawValue), never the words
//     shown — the words can change, the keys cannot.
//
// (For Rick: an append-only event log keyed by content hash; "current" is
// the last event per key, found through a (digest, role_id) B-tree.)

enum CatalogProvenanceRolesSchema {

    /// Names are permanent: renaming one re-runs it.
    static let migrationID = "v8_provenance_roles"

    /// `catalog_state.schema_version` once this migration has run.
    static let schemaVersion = 13

    static let statements: [String] = [
        """
        CREATE TABLE provenance_roles (            -- v1.12: what a content is, set by Rick; the newest row per digest is current
          role_id        INTEGER PRIMARY KEY,
          digest         TEXT    NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
          role           TEXT    NOT NULL CHECK (role IN ('master','cameraOriginal','alternateCapture','remasteredCopy','editCopy','excerpt','viewCopy','testCopy','unknown')),
          decided_at     INTEGER NOT NULL,
          source_missing INTEGER NOT NULL DEFAULT 0 CHECK (source_missing IN (0,1)),   -- only meaningful for 'master'
          note           TEXT
        ) STRICT
        """,
        """
        CREATE INDEX provenance_roles_by_digest ON provenance_roles(digest, role_id)
        """,
        """
        CREATE TRIGGER provenance_roles_no_update BEFORE UPDATE ON provenance_roles
        BEGIN SELECT RAISE(ABORT, 'provenance_roles is append-only history'); END
        """,
        """
        CREATE TRIGGER provenance_roles_no_delete BEFORE DELETE ON provenance_roles
        BEGIN SELECT RAISE(ABORT, 'provenance_roles is append-only history'); END
        """,
    ]

    /// Run after `statements`, inside the same migration.
    static let versionBump: [String] = [
        "UPDATE catalog_state SET schema_version = \(schemaVersion) WHERE singleton = 1",
        "PRAGMA user_version = \(schemaVersion)",
    ]
}
