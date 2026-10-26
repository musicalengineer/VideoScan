// CatalogDataSchemaTests.swift
// The data tables of schema v1.4 (CatalogDataSchema, migration `v2_data`)
// proved with raw SQL against the design documents:
//   LOGIC     — what the migration creates, counted; a part-1 database
//               gains the tables on open; the engine has what the DDL needs;
//               the FTS5 search text finds words.
//   SENSOR    — every CREATE statement of docs/design/catalog_sqlite_schema_v1.sql,
//               loaded from the FILE, is what sqlite_master holds, and
//               nothing beyond the document was created.
//   CHECKS    — docs/design/catalog_sqlite_schema_v1_checks.sql played block
//               by block: every `<block> ok` row, every announced refusal
//               refused, no unannounced error, 85 assertions, then the store
//               reopens the same file and says it is sound.
//   ISOLATION — a raw sqlite3-style connection poisons the file; the
//               trigger's words come back; a foreign-key violation is
//               refused; a row smuggled in with foreign keys OFF is caught
//               at the next open.
// One condition per #expect.
//
// This file imports GRDB to open the SAME file with a plain DatabaseQueue
// (one connection, like the sqlite3 shell). It lives under Tests/…/Store/,
// the one place outside Sources/…/Store/ the sensor allows that import.

import Foundation
import GRDB
import Testing
@testable import VideoScanCore

@Suite("CatalogDataSchema")
struct CatalogDataSchemaTests {

    // MARK: - Helpers

    private func rawQueue(_ fixture: StoreFixture, foreignKeys: Bool = true) throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = foreignKeys
        return try DatabaseQueue(path: fixture.url.path, configuration: configuration)
    }

    /// Runs `sql` on a raw connection; the engine's words when it refuses, nil when it lands.
    private func refusal(_ queue: DatabaseQueue, _ sql: String) -> String? {
        do {
            try queue.inDatabase { db in try db.execute(sql: sql) }
            return nil
        } catch {
            return ChecksRun.words(error)
        }
    }

    private func count(_ queue: DatabaseQueue, _ sql: String) throws -> Int {
        try queue.inDatabase { db in try Int.fetchOne(db, sql: sql) ?? -1 }
    }

    private func integrityIsOk(_ queue: DatabaseQueue) throws -> Bool {
        try queue.inDatabase { db in try String.fetchAll(db, sql: "PRAGMA integrity_check") == ["ok"] }
    }

    private func reopens(_ fixture: StoreFixture) async -> CatalogOpenOutcome {
        let repository = GRDBCatalogRepository(host: "test-host", durability: .volatileForTests)
        let outcome = await repository.open(at: fixture.url)
        await repository.close()
        return outcome
    }

    // MARK: - Logic: what the migration creates

    @Test func theMigrationCreatesTheDocumentsObjects() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        let inventory = try rawQueue(fixture).inDatabase { db in try SchemaInventory(db) }
        #expect(inventory.tables.count == 55)                  // 3 bookkeeping + 47 data + 1 live (v1.7 row_knowledge) + 1 pending (v1.8) + 1 pending purges (v1.9) + 2 decision tables (v1.11)
        #expect(inventory.virtualTables == ["content_text_fts"])
        #expect(inventory.triggers.count == 78)                // 12 bookkeeping + 58 data (v1.5: +5, +8 for codex C′ #1/#2) + 3 live + 1 pending + 4 append-only (v1.11)
        #expect(inventory.indexes.count == 36)                 // 8 UNIQUE + 25 plain + 1 live + 1 read-back (v1.9) + footage_likeness_by_b (v1.11), all named in the DDL
        #expect(inventory.views.sorted() == ["byte_copies", "duplicate_hash_groups_disagree"])
        #expect(inventory.shadowTables.count == 5)             // FTS5's _config _content _data _docsize _idx
        let migrations = try rawQueue(fixture).inDatabase { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
        }
        #expect(migrations == [CatalogBookkeepingSchema.migrationID, CatalogDataSchema.migrationID, CatalogLiveWritesSchema.migrationID,
                               CatalogPendingRowsSchema.migrationID, CatalogCommitB22Schema.migrationID,
                               CatalogFolderKindSchema.migrationID, CatalogDecisionTablesSchema.migrationID])
        let version = try count(try rawQueue(fixture), "SELECT schema_version FROM catalog_state")
        #expect(version == CatalogDecisionTablesSchema.schemaVersion)
    }

    @Test func theSwiftSchemaIsSplitByTableInDocumentOrder() throws {
        let documented = try SchemaDocument.ddl().tableNames.filter { !["catalog_state", "generations", "generation_history"].contains($0) }
        let swiftOrder = (CatalogDataSchema.statements + CatalogLiveWritesSchema.statements + CatalogPendingRowsSchema.statements
                         + CatalogCommitB22Schema.statements + CatalogDecisionTablesSchema.statements).compactMap { sql in
            sql.firstMatch(of: #/^CREATE (?:VIRTUAL )?TABLE (\w+)/#).map { String($0.1) }
        }
        #expect(swiftOrder == documented)
    }

    @Test func aPartOneDatabaseGainsTheDataTablesOnOpen() async throws {
        let fixture = StoreFixture(kind: .grdb, directory: try StoreFixture.temporaryDirectory())
        defer { fixture.remove() }
        // A file exactly as a part-1 build left it: v1_bookkeeping only.
        var partOne = DatabaseMigrator()
        partOne.registerMigration(CatalogBookkeepingSchema.migrationID, foreignKeyChecks: .immediate) { db in
            for statement in CatalogBookkeepingSchema.statements { try db.execute(sql: statement) }
            try db.execute(sql: "PRAGMA user_version = 7")
            try db.execute(sql: "INSERT INTO catalog_state (singleton, schema_version) VALUES (1, 7)")
            try db.execute(sql: "INSERT INTO generations (id, generation, saved_at, saved_from_host) VALUES (1, 0, 1, 'part-1')")
            try db.execute(sql: "INSERT INTO generation_history (generation, committed_at, host, writer, files_live, files_total) VALUES (0, 1, 'part-1', 'create', 0, 0)")
        }
        try partOne.migrate(try rawQueue(fixture))
        try fixture.writeHighWater("0")

        let outcome = await reopens(fixture)
        #expect(outcome == .readWrite)
        let inventory = try rawQueue(fixture).inDatabase { db in try SchemaInventory(db) }
        #expect(inventory.tables.contains("files"))
        #expect(inventory.tables.count == 55)                  // + pending_rows (v1.8), pending_purges (v1.9), the two decision tables (v1.11)
        let generation = try count(try rawQueue(fixture), "SELECT generation FROM generations WHERE id = 1")
        #expect(generation == 0)
    }

    @Test func theEngineHasWhatTheDDLNeeds() async throws {
        print("[catalog-schema] sqlite3_libversion() = \(SchemaDocument.engineVersion)")
        #expect(SchemaDocument.engineVersionNumber >= SchemaDocument.strictTablesSince)
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        let queue = try rawQueue(fixture)
        // STRICT is enforced (a text in an INTEGER column is refused, not coerced).
        let strict = refusal(queue, "INSERT INTO volumes (volume_uuid, case_sensitive) VALUES ('', 'no')")
        #expect(strict?.contains("cannot store TEXT value in INTEGER column") == true)
        // JSON functions are built in (a CHECK uses json_type).
        let json = try queue.inDatabase { db in try String.fetchOne(db, sql: "SELECT json_type('[1]')") }
        #expect(json == "array")
    }

    @Test func searchTextFindsWordsAcrossCaseAndDiacritics() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        let queue = try rawQueue(fixture)
        try queue.inDatabase { db in
            try db.execute(sql: "INSERT INTO content_text_fts (text, digest, kind, seq, provenance, source_json_row_id) VALUES ('Donna at the lake', ?, 'scene', 0, 'bound', '')",
                           arguments: [SchemaSeed.digestA])
            try db.execute(sql: "INSERT INTO content_text_fts (text, digest, kind, seq, provenance, source_json_row_id) VALUES ('José blows out the candles', ?, 'transcript', 0, 'unverified', ?)",
                           arguments: [SchemaSeed.digestB, SchemaSeed.fileTwo])
        }
        let lake = try queue.inDatabase { db in
            try Row.fetchAll(db, sql: "SELECT digest, kind, provenance FROM content_text_fts WHERE content_text_fts MATCH 'LAKE'")
        }
        #expect(lake.count == 1)
        #expect(lake.first.map { $0[0] as String } == SchemaSeed.digestA)
        let jose = try queue.inDatabase { db in
            try Row.fetchAll(db, sql: "SELECT digest, source_json_row_id FROM content_text_fts WHERE content_text_fts MATCH 'jose'")
        }
        #expect(jose.first.map { $0[1] as String } == SchemaSeed.fileTwo)
        let snippet = try queue.inDatabase { db in
            try String.fetchOne(db, sql: "SELECT snippet(content_text_fts, 0, '[', ']', '…', 6) FROM content_text_fts WHERE content_text_fts MATCH 'candles'")
        }
        #expect(snippet == "José blows out the [candles]")
    }

    // MARK: - Sensor: the DDL file is what the migration created

    @Test func everyStatementOfTheDDLIsWhatTheMigrationCreated() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        let documented = try SchemaDocument.ddl().statements.filter { $0.hasPrefix("CREATE") }
        #expect(documented.count == 172)                       // 56 tables + 78 triggers + 36 indexes + 2 views
        let created = try rawQueue(fixture).inDatabase { db in try SchemaInventory(db) }.normalizedSQL
        let createdText = Set(created.values)
        for statement in documented {
            let normalized = SQLScript.normalized(statement)
            #expect(createdText.contains(normalized), Comment(rawValue: "missing or different: \(statement.prefix(70))"))
        }
    }

    @Test func nothingBeyondTheDDLWasCreated() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        let documented = Set(try SchemaDocument.ddl().statements.filter { $0.hasPrefix("CREATE") }.map(SQLScript.normalized))
        let created = try rawQueue(fixture).inDatabase { db in try SchemaInventory(db) }.normalizedSQL
        let strangers = created.filter { name, sql in
            !documented.contains(sql) && !SchemaInventory.engineOwned.contains(name) && !name.hasPrefix(SchemaInventory.shadowPrefix)
        }
        #expect(strangers.isEmpty, Comment(rawValue: "not in the DDL: \(strangers.keys.sorted())"))
    }

    // MARK: - The checks file, block by block

    @Test func theChecksFileHoldsAgainstTheMigration() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 5)   // the fixture's "generation 5", through the store
        defer { fixture.remove() }
        let script = try SchemaDocument.checks()
        let run = try rawQueue(fixture).inDatabase { db in ChecksRun.play(script, on: db) }

        #expect(run.skippedSeeding.count == 2)
        #expect(run.expectedOk.count == 22)                     // F1…F12, D530, F5r3, F8r3, F9r3, N1, N2, N3, C1, C7, F5final
        for label in run.expectedOk {
            #expect(run.okRows.contains(label), Comment(rawValue: label))
        }
        #expect(run.problems.isEmpty, Comment(rawValue: run.problems.map(\.description).joined(separator: "\n")))
        #expect(run.refusals.count == 63)
        #expect(run.summary.contains("integrity_check: ok"))
        #expect(run.summary.contains("all checks ok (85 assertions)"))
        #expect(run.queryPlans.first?.contains("USING INDEX files_by_path_prefix") == true)
        #expect(run.queryPlans.contains { $0.contains("INDEX derived_unverified_by_value") })   // C7's probe
        #expect(run.refusals.contains { $0.block == "C1" && $0.words == "files rows are never replaced (a live path is already taken)" })
        // Three of the refusals, by their words — the triggers and CHECKs speak, not the harness.
        #expect(run.refusals.contains { $0.words == "a removal-marker change must append its tombstone first" })
        #expect(run.refusals.contains { $0.words == "files rows are never replaced (id or live path already taken)" })
        #expect(run.refusals.contains { $0.block == "F5final" && $0.words.contains("json_type(findings) = 'array'") })
        // The store opens the file the checks left behind and finds it sound (generation 20 after F8r3's adoptions).
        let repository = GRDBCatalogRepository(host: "test-host", durability: .volatileForTests)
        let outcome = await repository.open(at: fixture.url)
        #expect(outcome == .readWrite)
        let verdict = await repository.verify()
        #expect(verdict == .ok(generation: 20, highWater: 20))
        await repository.close()
    }

    // MARK: - Isolation: a raw connection poisons the file

    @Test func aRemovalMarkerWithoutItsTombstoneIsRefusedWithTheTriggersWords() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 1)
        defer { fixture.remove() }
        let queue = try rawQueue(fixture)
        try queue.inDatabase(SchemaSeed.plant)
        let words = refusal(queue, "UPDATE files SET removal_state = 'missing', removal_since = 1700000500, removal_reason = 'audit', removal_last_seen = 1700000400, removal_revision = 1 WHERE id = '\(SchemaSeed.fileOne)'")
        #expect(words == "a removal-marker change must append its tombstone first")
        let marked = try count(queue, "SELECT count(*) FROM files WHERE removal_state IS NOT NULL")
        #expect(marked == 0)
        #expect(try integrityIsOk(queue))
    }

    @Test func aCaseAliasOnACaseInsensitiveVolumeIsRefusedWithTheTriggersWords() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 1)
        defer { fixture.remove() }
        let queue = try rawQueue(fixture)
        try queue.inDatabase(SchemaSeed.plant)
        let alias = SchemaSeed.fileInsert(id: SchemaSeed.fileTwo, digest: SchemaSeed.digestA,
                                          path: "/Volumes/A/movie.mov", fold: "/volumes/a/movie.mov")
        let words = refusal(queue, alias)
        #expect(words == "files rows are never replaced (id or live path already taken)")
        let rows = try count(queue, "SELECT count(*) FROM files")
        #expect(rows == 1)
    }

    @Test func aPlainGenerationJumpIsRefusedWithTheTriggersWords() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 3)
        defer { fixture.remove() }
        let queue = try rawQueue(fixture)
        let words = refusal(queue, "UPDATE generations SET generation = 9 WHERE id = 1")
        #expect(words == "generation must advance by exactly one (CAS), or jump by an adopt row")
        let generation = try count(queue, "SELECT generation FROM generations WHERE id = 1")
        #expect(generation == 3)
    }

    @Test func aDanglingReferenceIsRefused() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 1)
        defer { fixture.remove() }
        let queue = try rawQueue(fixture)
        try queue.inDatabase(SchemaSeed.plant)
        let dangling = SchemaSeed.fileInsert(id: SchemaSeed.fileTwo, digest: SchemaSeed.digestB,
                                             path: "/Volumes/A/Other.mov", fold: "/volumes/a/other.mov")
        let words = refusal(queue, dangling)
        #expect(words == "FOREIGN KEY constraint failed")
        let rows = try count(queue, "SELECT count(*) FROM files")
        #expect(rows == 1)
        let outcome = await reopens(fixture)
        #expect(outcome == .readWrite)
    }

    @Test func aRowSmuggledInWithForeignKeysOffIsCaughtAtTheNextOpen() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 1)
        defer { fixture.remove() }
        // The sqlite3 shell's default: foreign_keys OFF. The file takes the row; the store must not.
        let shell = try rawQueue(fixture, foreignKeys: false)
        try shell.inDatabase(SchemaSeed.plant)
        let smuggled = SchemaSeed.fileInsert(id: SchemaSeed.fileTwo, digest: SchemaSeed.digestB,
                                             path: "/Volumes/A/Other.mov", fold: "/volumes/a/other.mov")
        let words = refusal(shell, smuggled)
        #expect(words == nil)
        let outcome = await reopens(fixture)
        guard case .refused(let reason) = outcome else {
            Issue.record("expected .refused, got \(outcome)")
            return
        }
        // #387: the check's words, then what the refusal did to the file.
        #expect(reason.hasPrefix("foreign_key_check: 1 violation(s) — "), Comment(rawValue: reason))
        #expect(reason.contains("VideoScan left catalog.sqlite as found"), Comment(rawValue: reason))
    }

    // MARK: - Isolation: REPLACE conflict resolution on a raw connection (codex C′ #1, #2)
    //
    // A raw DatabaseQueue runs with recursive_triggers OFF — the sqlite3
    // shell's default — so REPLACE's implicit delete of the row in the way
    // never reaches a delete trigger. These pins prove the BEFORE INSERT /
    // BEFORE UPDATE guards refuse the statement before any conflict is
    // resolved, which binds every connection whatever its pragmas.

    /// Codex C′ #1, verbatim: A at /A, B at /Other, `UPDATE OR REPLACE …
    /// WHERE id = B`. Before the fix A silently disappeared.
    @Test func updateOrReplaceOntoAnotherLivePathIsRefusedAndTheOtherRowStays() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 1)
        defer { fixture.remove() }
        let queue = try rawQueue(fixture)
        try queue.inDatabase { db in
            try db.execute(sql: SchemaSeed.volumeInsert)
            try db.execute(sql: SchemaSeed.contentAInsert)
            try db.execute(sql: SchemaSeed.fileInsert(id: SchemaSeed.fileOne, digest: SchemaSeed.digestA, path: "/A", fold: "/a"))
            try db.execute(sql: SchemaSeed.fileInsert(id: SchemaSeed.fileTwo, digest: SchemaSeed.digestA, path: "/Other", fold: "/other"))
        }
        let words = refusal(queue, "UPDATE OR REPLACE files SET full_path = '/A', path_fold = '/a' WHERE id = '\(SchemaSeed.fileTwo)'")
        #expect(words == "files rows are never replaced (a live path is already taken)")
        let paths = try queue.inDatabase { db in try String.fetchAll(db, sql: "SELECT full_path FROM files ORDER BY full_path") }
        #expect(paths == ["/A", "/Other"])
        let idWords = refusal(queue, "UPDATE OR REPLACE files SET id = '\(SchemaSeed.fileOne)' WHERE id = '\(SchemaSeed.fileTwo)'")
        #expect(idWords == "files.id is immutable")
        let rows = try count(queue, "SELECT count(*) FROM files")
        #expect(rows == 2)
    }

    /// Codex C′ #2: `INSERT OR REPLACE INTO generations … 99` moved the
    /// counter 5 → 99 with no adoption; integrity and FK checks stayed clean.
    @Test func insertOrReplaceOverTheGenerationCounterIsRefused() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 5)
        defer { fixture.remove() }
        let queue = try rawQueue(fixture)
        let words = refusal(queue, "INSERT OR REPLACE INTO generations (id, generation, saved_at, saved_from_host) VALUES (1, 99, 1, 'test')")
        #expect(words == "the generation counter is one row, never replaced")
        let generation = try count(queue, "SELECT generation FROM generations WHERE id = 1")
        #expect(generation == 5)
    }

    /// Codex C′ #2: replacing the CURRENT history row rewrote its writer
    /// despite generation_history_no_update (REPLACE is a delete + insert).
    @Test func insertOrReplaceOverTheCurrentHistoryRowIsRefused() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 5)
        defer { fixture.remove() }
        let queue = try rawQueue(fixture)
        let words = refusal(queue, "INSERT OR REPLACE INTO generation_history (generation, committed_at, host, writer, files_live, files_total) VALUES (5, 2, 'x', 'forged', 0, 0)")
        #expect(words == "generation history is append-only (no replace)")
        let writer = try queue.inDatabase { db in try String.fetchOne(db, sql: "SELECT writer FROM generation_history WHERE generation = 5") }
        #expect(writer == "ui")
        let deleted = refusal(queue, "DELETE FROM generation_history WHERE generation = 5")
        #expect(deleted == "generation history is append-only")
    }

    /// WHY the store sets recursive_triggers: SQLite fires a BEFORE DELETE
    /// trigger for REPLACE's implicit delete only when the pragma is on.
    /// Pinned on a scratch table so the mechanism itself is on record.
    @Test("REPLACE reaches the delete trigger only with recursive_triggers on", arguments: [false, true])
    func replaceReachesTheDeleteTriggerOnlyWithRecursiveTriggers(recursive: Bool) throws {
        let queue = try DatabaseQueue()
        try queue.inDatabase { db in
            try db.execute(sql: "PRAGMA recursive_triggers = \(recursive ? "ON" : "OFF")")
            try db.execute(sql: "CREATE TABLE evidence (k INTEGER PRIMARY KEY, v TEXT NOT NULL)")
            try db.execute(sql: "CREATE TRIGGER evidence_no_delete BEFORE DELETE ON evidence BEGIN SELECT RAISE(ABORT, 'evidence is never deleted'); END")
            try db.execute(sql: "INSERT INTO evidence VALUES (1, 'original')")
        }
        let words = refusal(queue, "INSERT OR REPLACE INTO evidence VALUES (1, 'forged')")
        #expect((words == "evidence is never deleted") == recursive)
        let value = try queue.inDatabase { db in try String.fetchOne(db, sql: "SELECT v FROM evidence WHERE k = 1") }
        #expect(value == (recursive ? "original" : "forged"))
    }
}
