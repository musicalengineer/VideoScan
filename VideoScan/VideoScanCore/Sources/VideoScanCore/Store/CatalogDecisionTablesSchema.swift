// CatalogDecisionTablesSchema.swift (VideoScanCore/Store)
// Schema v1.11, migration `v7_decision_tables` (2026-10-19: "every decision
// Rick makes lives in catalog.sqlite"). ADDITIVE ONLY — two new tables, one
// index, their guards, and the schema version raised to 12 so a build that
// does not know them refuses the file instead of writing around them.
// Verbatim in docs/design/catalog_sqlite_schema_v1.sql §16
// (CatalogDataSchemaTests diffs the two).
//
// 1. `footage_likeness` (Rick approved 2026-10-19). A PAIR of contents the
//    duplicate check found alike although their bytes differ — a re-encode,
//    a rewrap, an Avid render or channel file — with the check's reasons
//    verbatim. Find Similar Footage gives a file ONE group whose confidence
//    is its weakest link, so a WEAK likeness (a default timecode, a camera-
//    counter name, format + length) between files that are already grouped
//    had nowhere to live; Split Duplicate Groups by Full Hash therefore HELD
//    403 of 466 multi-digest groups on Rick's catalog. This table is that
//    place: the split records each pair here BEFORE it splits, so nothing
//    the old group knew is lost.
//      digest_a < digest_b       one row per unordered pair (UNIQUE)
//      reasons                   "timecode+duration+resolution", verbatim
//      strength                  'anchored' (sampled hash, a specific
//                                timecode or name, + length) | 'weak'
//      source                    'duplicateCheck' (today's likeness rule
//                                scored the pair) | 'oldGroup' (only the old
//                                duplicate group remembered they matched)
//    Evidence, never a decision and NEVER delete eligibility: nothing on a
//    delete path reads it (SameFootageSensorTests). A person confirms or
//    rejects a pair with the existing footage_decisions (same / notSame);
//    an undecided WEAK pair is Verify Catalog's yellow, informational item.
//    Append-only: the triggers refuse UPDATE and DELETE.
//
// 2. `ignored_content_put_back`. The ignore list (`ignored_content`, v1)
//    moves to catalog.sqlite; its override — "put back", catalog this
//    content again on the next scan — must not DELETE an ignored row (an
//    imported row is the import's evidence: `import_items` and the run's
//    counters name it). A put-back is a row here naming the ignored row;
//    the live list is `ignored_content` minus these. Append-only; one
//    put-back per ignored row (UNIQUE). Ignoring the content again is a NEW
//    `ignored_content` row.
//
// (For Rick: two append-only side tables — an adjacency list of "possibly
// the same recording" edges keyed by content hash, and a tombstone table
// so the ignore list is never edited in place.)

enum CatalogDecisionTablesSchema {

    /// Names are permanent: renaming one re-runs it.
    static let migrationID = "v7_decision_tables"

    /// `catalog_state.schema_version` once this migration has run.
    static let schemaVersion = 12

    /// The words `footage_likeness.strength` holds.
    static let strengths = ["weak", "anchored"]
    /// The words `footage_likeness.source` holds.
    static let sources = ["duplicateCheck", "oldGroup"]

    static let statements: [String] = [
        """
        CREATE TABLE footage_likeness (            -- v1.11: two contents the duplicate check found alike, bytes differ
          likeness_id  INTEGER PRIMARY KEY,
          digest_a     TEXT    NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
          digest_b     TEXT    NOT NULL REFERENCES content(digest) ON DELETE RESTRICT,
          reasons      TEXT    NOT NULL,           -- the duplicate check's reasons, verbatim ("timecode+duration")
          strength     TEXT    NOT NULL CHECK (strength IN ('weak','anchored')),
          source       TEXT    NOT NULL CHECK (source IN ('duplicateCheck','oldGroup')),
          recorded_at  INTEGER NOT NULL,
          CHECK (digest_a < digest_b),             -- one row per unordered pair
          UNIQUE (digest_a, digest_b)
        ) STRICT
        """,
        """
        CREATE INDEX footage_likeness_by_b ON footage_likeness(digest_b)
        """,
        """
        CREATE TRIGGER footage_likeness_no_update BEFORE UPDATE ON footage_likeness
        BEGIN SELECT RAISE(ABORT, 'footage_likeness is append-only evidence'); END
        """,
        """
        CREATE TRIGGER footage_likeness_no_delete BEFORE DELETE ON footage_likeness
        BEGIN SELECT RAISE(ABORT, 'footage_likeness is append-only evidence'); END
        """,
        """
        CREATE TABLE ignored_content_put_back (    -- v1.11: the ignore list's override, never a DELETE of ignored_content
          put_back_seq INTEGER PRIMARY KEY,
          ignored_seq  INTEGER NOT NULL UNIQUE REFERENCES ignored_content(ignored_seq) ON DELETE RESTRICT,
          put_back_at  INTEGER NOT NULL
        ) STRICT
        """,
        """
        CREATE TRIGGER ignored_content_put_back_no_update BEFORE UPDATE ON ignored_content_put_back
        BEGIN SELECT RAISE(ABORT, 'ignored_content_put_back is append-only evidence'); END
        """,
        """
        CREATE TRIGGER ignored_content_put_back_no_delete BEFORE DELETE ON ignored_content_put_back
        BEGIN SELECT RAISE(ABORT, 'ignored_content_put_back is append-only evidence'); END
        """,
    ]

    /// Run after `statements`, inside the same migration.
    static let versionBump: [String] = [
        "UPDATE catalog_state SET schema_version = \(schemaVersion) WHERE singleton = 1",
        "PRAGMA user_version = \(schemaVersion)",
    ]
}
