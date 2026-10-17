// CatalogBookkeepingSchema.swift (VideoScanCore/Store)
// The bookkeeping tables of catalog schema v1 as RAW SQL, verbatim from
// docs/design/catalog_sqlite_schema_v1.sql §1 (revision 3, F8 / F8r3;
// revision 6 / v1.5 adds the no-replace and no-delete guards of codex C′
// #2): `catalog_state`, `generations`, `generation_history` and their
// triggers.
//
// Rick's ruling (2026-10-17): every integrity-critical statement is raw
// SQL, never the query builder, so it reads like the DDL it came from and
// a diff against the design document is a text diff. The data tables
// (§2 onward) are part 2.
//
// The +1 rule lives in the TRIGGERS, not in Swift. Why: the trigger binds
// every writer of the file — this app, a second process, the sqlite3
// shell, a future tool — while a Swift guard binds only callers of this
// module. GRDBCatalogRepository still names the outcome
// (`.generationMismatch`) from the CAS's own `changes()` BEFORE the trigger
// would have a say, so the person sees words, not an engine error.
//
// Codex C′ #2 (2026-10-17): a REPLACE conflict resolution is a delete plus
// an insert, and SQLite fires the delete's trigger only with
// recursive_triggers on. So every row that must never be rewritten has
// BOTH a BEFORE INSERT no-replace guard (fires before the conflict is
// resolved, whatever the connection's pragmas) and a BEFORE DELETE guard
// (what the pragma, set by the store, lets REPLACE's delete reach).
//
// For Rick: `enum` with only statics is Swift's way to write a namespace
// that cannot be instantiated.

enum CatalogBookkeepingSchema {

    /// `catalog_state.schema_version` this build understands. The JSON
    /// catalog was v6 (CatalogStore.swift); SQLite starts at 7. A database
    /// carrying a HIGHER number was written by a newer build and is refused
    /// at open — never migrated down, never guessed at.
    static let schemaVersion = 7

    /// The migration identifier GRDB records in its own `grdb_migrations`
    /// table. Names are permanent: renaming one re-runs it.
    static let migrationID = "v1_bookkeeping"

    /// The DDL, one statement per element, in dependency order.
    static let statements: [String] = [
        """
        CREATE TABLE catalog_state (
          singleton        INTEGER PRIMARY KEY NOT NULL CHECK (singleton = 1),
          schema_version   INTEGER NOT NULL CHECK (schema_version >= 7),
          master_archive   TEXT    CHECK (master_archive IS NULL OR json_valid(master_archive)),
          imported_from    TEXT
        ) STRICT
        """,
        """
        CREATE TRIGGER catalog_state_no_replace BEFORE INSERT ON catalog_state
        WHEN EXISTS (SELECT 1 FROM catalog_state)
        BEGIN SELECT RAISE(ABORT, 'catalog_state is one row, never replaced'); END
        """,
        """
        CREATE TRIGGER catalog_state_no_delete BEFORE DELETE ON catalog_state
        BEGIN SELECT RAISE(ABORT, 'catalog_state is never deleted'); END
        """,
        """
        CREATE TABLE generations (
          id               INTEGER PRIMARY KEY NOT NULL CHECK (id = 1),
          generation       INTEGER NOT NULL CHECK (generation >= 0),
          saved_at         INTEGER NOT NULL,
          saved_from_host  TEXT    NOT NULL,
          adopted_at       INTEGER,
          adopted_from     INTEGER,
          CHECK ((adopted_at IS NULL) = (adopted_from IS NULL)),
          CHECK (adopted_from IS NULL OR adopted_from < generation)
        ) STRICT
        """,
        """
        CREATE TABLE generation_history (
          generation   INTEGER PRIMARY KEY NOT NULL CHECK (generation >= 0),
          committed_at INTEGER NOT NULL,
          host         TEXT    NOT NULL,
          writer       TEXT    NOT NULL,
          files_live   INTEGER NOT NULL CHECK (files_live >= 0),
          files_total  INTEGER NOT NULL CHECK (files_total >= 0),
          export_sha256 TEXT CHECK (export_sha256 IS NULL OR (length(export_sha256) = 64 AND export_sha256 NOT GLOB '*[^0-9a-f]*')),
          kind         TEXT    NOT NULL DEFAULT 'commit' CHECK (kind IN ('commit','adopt')),
          from_generation INTEGER,
          CHECK ((kind = 'adopt') = (from_generation IS NOT NULL)),
          CHECK (from_generation IS NULL OR from_generation < generation)
        ) STRICT
        """,
        // F8: +1 per commit. F8r3: or a jump by ADOPTION, only with its `adopt` history row.
        """
        CREATE TRIGGER generations_step_by_one
        BEFORE UPDATE OF generation ON generations
        WHEN NEW.generation <> OLD.generation + 1
         AND NOT (NEW.generation > OLD.generation
                  AND NEW.adopted_from IS OLD.generation AND NEW.adopted_at IS NOT NULL
                  AND EXISTS (SELECT 1 FROM generation_history h
                               WHERE h.generation = NEW.generation AND h.kind = 'adopt'
                                 AND h.from_generation = OLD.generation))
        BEGIN SELECT RAISE(ABORT, 'generation must advance by exactly one (CAS), or jump by an adopt row'); END
        """,
        """
        CREATE TRIGGER generations_no_step_over_pending_adopt
        BEFORE UPDATE OF generation ON generations
        WHEN NEW.generation = OLD.generation + 1
         AND EXISTS (SELECT 1 FROM generation_history h WHERE h.kind = 'adopt' AND h.generation > NEW.generation)
        BEGIN SELECT RAISE(ABORT, 'an adoption is half done: finish it or roll it back'); END
        """,
        """
        CREATE TRIGGER generations_adoption_fields_only_by_adoption
        BEFORE UPDATE OF adopted_at, adopted_from ON generations
        WHEN (NEW.adopted_at IS NOT OLD.adopted_at OR NEW.adopted_from IS NOT OLD.adopted_from)
         AND NEW.adopted_from IS NOT OLD.generation
        BEGIN SELECT RAISE(ABORT, 'adopted_from names the generation the adoption jumped from'); END
        """,
        """
        CREATE TRIGGER generations_no_delete BEFORE DELETE ON generations
        BEGIN SELECT RAISE(ABORT, 'the generation counter is never deleted'); END
        """,
        // codex C′ #2: the counter is ONE row; a second insert can only be a REPLACE of it.
        """
        CREATE TRIGGER generations_no_replace BEFORE INSERT ON generations
        WHEN EXISTS (SELECT 1 FROM generations)
        BEGIN SELECT RAISE(ABORT, 'the generation counter is one row, never replaced'); END
        """,
        """
        CREATE TRIGGER generation_history_names_this_commit
        BEFORE INSERT ON generation_history
        WHEN NEW.kind = 'commit' AND NEW.generation IS NOT (SELECT generation FROM generations WHERE id = 1)
        BEGIN SELECT RAISE(ABORT, 'a history row names the generation this transaction advanced to'); END
        """,
        // F8r3: an adopt row is written FIRST, while the counter still reads :old, and names a jump up.
        """
        CREATE TRIGGER generation_history_adopt_precedes_jump
        BEFORE INSERT ON generation_history
        WHEN NEW.kind = 'adopt'
         AND (NEW.from_generation IS NOT (SELECT generation FROM generations WHERE id = 1)
              OR NEW.generation <= NEW.from_generation)
        BEGIN SELECT RAISE(ABORT, 'an adopt row names the current generation and the high-water above it'); END
        """,
        """
        CREATE TRIGGER generation_history_no_update BEFORE UPDATE ON generation_history
        BEGIN SELECT RAISE(ABORT, 'generation history is append-only'); END
        """,
        // codex C′ #2: a row for a generation that already has one can only be a REPLACE of it.
        """
        CREATE TRIGGER generation_history_no_replace BEFORE INSERT ON generation_history
        WHEN EXISTS (SELECT 1 FROM generation_history WHERE generation = NEW.generation)
        BEGIN SELECT RAISE(ABORT, 'generation history is append-only (no replace)'); END
        """,
        """
        CREATE TRIGGER generation_history_no_delete BEFORE DELETE ON generation_history
        BEGIN SELECT RAISE(ABORT, 'generation history is append-only'); END
        """,
    ]
}
