// CatalogProvenanceAssertionsSchema.swift (VideoScanCore/Store)
// Schema v1.13, migration `v9_provenance_assertions` — background service
// step 1 (DECISIONS 2026-10-31 "Background service step 1 is the 8B era/OCR
// job": "Schema v14 lands with step 1 — `provenance_assertions` with the
// veto trigger only"); Rick approved the DDL 2026-11-01 (DECISIONS "Schema
// v14 approved").
// ADDITIVE ONLY — one new table, one index, the veto trigger, two
// append-only triggers, and the schema version raised to 14 so a build that
// does not know the table refuses the file instead of writing around it.
// Exactly the C2 table of docs/design/provenance_retroactive_2026_10_26.md
// §v14 — nothing else of v14 (content_excerpts, carriers, capture tables
// wait for their own migration). Verbatim in
// docs/design/catalog_sqlite_schema_v1.sql §18 (CatalogDataSchemaTests
// diffs the two).
//
// `provenance_assertions` — every value a machine OBSERVES (state
// 'inferred', by 'machine:<approach id>@r<revision>') and every value Rick
// DECIDES (confirmed / corrected / rejected, by 'rick'), per (subject,
// field), append-only:
//   * `subject_id` for subject_kind 'content' is the 64-hex digest exactly as
//     `content.digest` stores it — no "sha256:" prefix
//     (ProvenanceAssertionSubject.contentID normalises, one place);
//   * `confidence` is REQUIRED on an inferred row (CHECK) and is the model's
//     own selfConfidence clamped to [0,1]: kept for the Judge, NEVER shown
//     (events_design rule 9 — the UI does not read this column);
//   * the veto: an inferred value whose latest human decision on the same
//     (subject, field, value) is 'rejected' is IGNORED (RAISE(IGNORE), not
//     ABORT, so a batch survives); the writer reads changes() == 0 and
//     records "vetoed";
//   * UPDATE and DELETE are refused: the history is the table;
//   * the literal 'rick' in the `by` CHECK means the catalog's owning (admin)
//     user, not a person's name (DECISIONS 2026-11-01); generalising it to an
//     admin-user value is a later additive migration (BACKLOG).
// Step 1 writes only machine observations (era.yearRange, era.fused,
// ocr.date) through the app's JournalApplier; none of them is a date shown
// as a date (DECISIONS 2026-11-01).
//
// (For Rick: an append-only event log keyed by (subject, field, value),
// with a BEFORE INSERT trigger acting as a blacklist check.)

enum CatalogProvenanceAssertionsSchema {

    /// Names are permanent: renaming one re-runs it.
    static let migrationID = "v9_provenance_assertions"

    /// `catalog_state.schema_version` once this migration has run.
    static let schemaVersion = 14

    static let statements: [String] = [
        """
        CREATE TABLE provenance_assertions (       -- v1.13: every value a machine observes or Rick decides, per field, append-only
          seq           INTEGER PRIMARY KEY,
          subject_kind  TEXT NOT NULL CHECK (subject_kind IN ('content','carrier','captureEvent','captureSetup','excerpt')),
          subject_id    TEXT NOT NULL,                  -- digest hex (as content.digest), or the entity's UUID
          field         TEXT NOT NULL,                  -- 'era.yearRange','era.fused','ocr.date','role','carrier','tapeYear',…
          value         TEXT NOT NULL,
          state         TEXT NOT NULL CHECK (state IN ('inferred','confirmed','corrected','rejected')),
          by            TEXT NOT NULL CHECK (by = 'rick' OR by GLOB 'machine:*'),  -- 'rick' = the catalog's owning (admin) user, not a name; else 'machine:<approach id>@r<revision>'
          at            INTEGER NOT NULL,
          confidence    REAL CHECK (confidence BETWEEN 0 AND 1),
          evidence_json TEXT NOT NULL CHECK (json_valid(evidence_json)),
          CHECK ((state = 'inferred') = (by GLOB 'machine:*')),            -- only the machine infers; only Rick decides
          CHECK (state <> 'inferred' OR confidence IS NOT NULL)
        ) STRICT
        """,
        """
        CREATE INDEX provenance_assertions_by_subject
          ON provenance_assertions(subject_kind, subject_id, field, value, seq)
        """,
        """
        CREATE TRIGGER provenance_assertions_veto BEFORE INSERT ON provenance_assertions
        WHEN NEW.state = 'inferred' AND (
          SELECT state FROM provenance_assertions
           WHERE subject_kind = NEW.subject_kind AND subject_id = NEW.subject_id
             AND field = NEW.field AND value = NEW.value AND state <> 'inferred'
           ORDER BY seq DESC LIMIT 1) = 'rejected'
        BEGIN SELECT RAISE(IGNORE); END
        """,
        """
        CREATE TRIGGER provenance_assertions_no_update BEFORE UPDATE ON provenance_assertions
        BEGIN SELECT RAISE(ABORT, 'provenance_assertions is append-only'); END
        """,
        """
        CREATE TRIGGER provenance_assertions_no_delete BEFORE DELETE ON provenance_assertions
        BEGIN SELECT RAISE(ABORT, 'provenance_assertions is append-only'); END
        """,
    ]

    /// Run after `statements`, inside the same migration.
    static let versionBump: [String] = [
        "UPDATE catalog_state SET schema_version = \(schemaVersion) WHERE singleton = 1",
        "PRAGMA user_version = \(schemaVersion)",
    ]
}
