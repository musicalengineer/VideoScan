// CatalogDatabaseInfoReaderTests.swift
// Catalog ▸ Catalog Database Info…: the Core half — what the read-only open
// finds inside catalog.sqlite, on REAL SQLite files generated here (no
// family data). Dimensions (rule 8):
//   TRUTH     — the schema fact equals PRAGMA user_version AND
//               catalog_state.schema_version of the fixture, and moves when
//               the fixture migrates (13 → 14); the generation and the last
//               commit's door are the store's own; the layout line names an
//               extra and a missing table.
//   ISOLATION — no catalog_state row, no catalog_state table, a missing
//               -wal, a garbage file, no file: each fact "unknown" with its
//               own words, never a zero, never a crash.
//   READ-ONLY — the database bytes and generation are unchanged by a read.
//   SCALE     — 100k content + 100k files (10 % removed): exact counts,
//               inside a load-aware budget.
// In Store/ because only Store/ folders may import GRDB (CatalogStoreSensorTests).

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import VideoScanCore

@Suite("CatalogDatabaseInfoReader", .serialized)
struct CatalogDatabaseInfoReaderTests {

    private static func pragmaAndState(_ url: URL) throws -> (Int?, Int?) {
        let queue = try DatabaseQueue(path: url.path)
        defer { try? queue.close() }
        return try queue.read { db in
            (try Int.fetchOne(db, sql: "PRAGMA user_version"),
             try Int.fetchOne(db, sql: "SELECT schema_version FROM catalog_state WHERE singleton = 1"))
        }
    }

    // MARK: Truth

    @Test func aFreshStoreReadsItsOwnSchemaGenerationAndLastDoor() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 3)
        defer { fixture.remove() }
        let facts = CatalogDatabaseInfoReader.read(at: fixture.url)
        let (pragma, state) = try Self.pragmaAndState(fixture.url)
        #expect(facts.schemaVersion == .known(try #require(state)))
        #expect(facts.userVersion == .known(try #require(pragma)))
        #expect(facts.schemaVersion.value == CatalogDatabaseInfoReader.expectedSchemaVersion)
        #expect(facts.generation == .known(3))
        let last = try #require(facts.lastCommit.value)
        #expect(last.generation == 3)
        #expect(last.writer == CatalogWriter.ui.rawValue)
        #expect(last.kind == "commit")
        #expect(last.host == "test-host")
        #expect(facts.contents == .known(0))
        #expect(facts.liveFiles == .known(0))
        #expect(facts.records == .known(0))
        let layout = try #require(facts.schemaLayout.value)
        #expect(layout.matches, "\(layout)")
        #expect(layout.tableCount == GRDBCatalogRepository.expectedTableNames?.count)
    }

    @Test func theExpectedTablesComeFromThisBuildsMigrations() throws {
        let expected = try #require(GRDBCatalogRepository.expectedTableNames)
        for name in ["catalog_state", "generations", "generation_history", "files", "content", "provenance_assertions", "provenance_roles", "public_marks", "sound_attempts"] {
            #expect(expected.contains(name), "\(name)")
        }
        #expect(!expected.contains { $0.hasPrefix("sqlite_") })
    }

    @Test func theSchemaFactMovesWhenTheFixtureMigratesFromThirteenToFourteen() async throws {
        let fixture = StoreFixture(kind: .grdb, directory: try StoreFixture.temporaryDirectory())
        defer { fixture.remove() }
        var v13 = DatabaseMigrator()
        v13.registerMigration(CatalogBookkeepingSchema.migrationID, foreignKeyChecks: .immediate) { db in
            for statement in CatalogBookkeepingSchema.statements { try db.execute(sql: statement) }
            try db.execute(sql: "PRAGMA user_version = 7")
            try db.execute(sql: "INSERT INTO catalog_state (singleton, schema_version) VALUES (1, 7)")
            try db.execute(sql: "INSERT INTO generations (id, generation, saved_at, saved_from_host) VALUES (1, 0, 1, 'v13')")
            try db.execute(sql: "INSERT INTO generation_history (generation, committed_at, host, writer, files_live, files_total) VALUES (0, 1, 'v13', 'create', 0, 0)")
        }
        let later: [(String, [String])] = [
            (CatalogDataSchema.migrationID, CatalogDataSchema.statements),
            (CatalogLiveWritesSchema.migrationID, CatalogLiveWritesSchema.statements + CatalogLiveWritesSchema.versionBump),
            (CatalogPendingRowsSchema.migrationID, CatalogPendingRowsSchema.statements + CatalogPendingRowsSchema.versionBump),
            (CatalogCommitB22Schema.migrationID, CatalogCommitB22Schema.statements + CatalogCommitB22Schema.versionBump),
            (CatalogFolderKindSchema.migrationID, CatalogFolderKindSchema.statements + CatalogFolderKindSchema.versionBump),
            (CatalogDecisionTablesSchema.migrationID, CatalogDecisionTablesSchema.statements + CatalogDecisionTablesSchema.versionBump),
            (CatalogProvenanceRolesSchema.migrationID, CatalogProvenanceRolesSchema.statements + CatalogProvenanceRolesSchema.versionBump),
        ]
        for (id, statements) in later {
            v13.registerMigration(id, foreignKeyChecks: .immediate) { db in
                for statement in statements { try db.execute(sql: statement) }
            }
        }
        let queue = try DatabaseQueue(path: fixture.url.path)
        try v13.migrate(queue)
        try queue.close()
        try fixture.writeHighWater("0")

        let before = CatalogDatabaseInfoReader.read(at: fixture.url)
        #expect(before.schemaVersion == .known(13))
        #expect(before.userVersion == .known(13))
        let oldLayout = try #require(before.schemaLayout.value)
        #expect(oldLayout.missing.sorted() == ["provenance_assertions", "public_marks", "sound_attempts"])
        #expect(oldLayout.extra.isEmpty)

        let repository = GRDBCatalogRepository(host: "test-host", durability: .volatileForTests)
        #expect(await repository.open(at: fixture.url) == .readWrite)
        await repository.close()

        let after = CatalogDatabaseInfoReader.read(at: fixture.url)
        let (pragma, state) = try Self.pragmaAndState(fixture.url)
        #expect(pragma == 16 && state == 16)   // 13 → v9 (14) → v10_sound_attempts (15) → v11_public_marks (16)
        #expect(after.schemaVersion == .known(16))
        #expect(after.userVersion == .known(16))
        #expect(after.schemaLayout.value?.matches == true)
    }

    @Test func theLayoutNamesAnExtraAndAMissingTable() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        let queue = try DatabaseQueue(path: fixture.url.path)
        try queue.inDatabase { db in
            try db.execute(sql: "CREATE TABLE stray_table (x INTEGER)")
            try db.execute(sql: "DROP TABLE footage_likeness")
        }
        try queue.close()
        let layout = try #require(CatalogDatabaseInfoReader.read(at: fixture.url).schemaLayout.value)
        #expect(layout.extra == ["stray_table"])
        #expect(layout.missing == ["footage_likeness"])
        #expect(!layout.matches)
    }

    @Test func theLayoutDiffIsPure() {
        let l = CatalogSchemaLayout.compare(live: ["a", "b", "x"], expected: ["a", "b", "c"])
        #expect(l == CatalogSchemaLayout(tableCount: 3, extra: ["x"], missing: ["c"]))
    }

    // MARK: Read-only

    @Test func aReadChangesNoByteAndNoGeneration() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 2)
        defer { fixture.remove() }
        let hash = { SHA256.hash(data: try Data(contentsOf: fixture.url)).map { String(format: "%02x", $0) }.joined() }
        let before = try hash()
        _ = CatalogDatabaseInfoReader.read(at: fixture.url)
        _ = CatalogDatabaseInfoReader.read(at: fixture.url)
        #expect(try hash() == before)
        #expect(CatalogDatabaseInfoReader.read(at: fixture.url).generation == .known(2))
    }

    // MARK: Isolation (poisoned state)

    private static func scratch() throws -> URL {
        try StoreFixture.temporaryDirectory().appendingPathComponent("catalog.sqlite")
    }

    @Test func aCatalogStateWithNoRowIsUnknownInWordsAndTheRestStillReads() throws {
        let url = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE catalog_state (singleton INTEGER PRIMARY KEY, schema_version INTEGER NOT NULL)")
            try db.execute(sql: "CREATE TABLE content (digest TEXT)")
            try db.execute(sql: "INSERT INTO content VALUES ('a'), ('b')")
        }
        try queue.close()
        let facts = CatalogDatabaseInfoReader.read(at: url)
        #expect(facts.schemaVersion == .unknown("catalog_state has no row (singleton 1) — no schema_version was ever stored"))
        #expect(facts.contents == .known(2))
        #expect(facts.generation == .unknown("the file has no generations table"))
        #expect(facts.records == .unknown("the file has no files table"))
        #expect(facts.liveFiles == .unknown("the file has no files table"))
        #expect(facts.lastCommit == .unknown("the file has no generation_history table"))
        #expect(facts.userVersion == .known(0))
        let layout = try #require(facts.schemaLayout.value)
        #expect(layout.extra.isEmpty)
        #expect(layout.missing.contains("files"))
    }

    @Test func noCatalogStateTableIsUnknownInWords() throws {
        let url = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in try db.execute(sql: "CREATE TABLE other (x)") }
        try queue.close()
        #expect(CatalogDatabaseInfoReader.read(at: url).schemaVersion == .unknown("the file has no catalog_state table"))
    }

    @Test func aMissingWalStillReadsEveryFact() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 1)
        defer { fixture.remove() }
        let wal = URL(fileURLWithPath: fixture.url.path + "-wal")
        try? FileManager.default.removeItem(at: wal)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: fixture.url.path + "-shm"))
        let facts = CatalogDatabaseInfoReader.read(at: fixture.url)
        #expect(facts.generation == .known(1))
        #expect(facts.schemaVersion.value == CatalogDatabaseInfoReader.expectedSchemaVersion)
    }

    @Test func aGarbageFileIsUnknownEverywhereNeverACrash() throws {
        let url = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Data(repeating: 0x5A, count: 8192).write(to: url)
        let facts = CatalogDatabaseInfoReader.read(at: url)
        for reading in [facts.schemaVersion, facts.userVersion, facts.generation, facts.contents, facts.records, facts.liveFiles] {
            guard case .unknown(let why) = reading else { Issue.record("expected unknown, got \(reading)"); continue }
            #expect(!why.isEmpty)
        }
        #expect(facts.lastCommit.value == nil)
        #expect(facts.schemaLayout.value == nil)
    }

    @Test func noFileIsUnknownWithThePath() throws {
        let url = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let facts = CatalogDatabaseInfoReader.read(at: url)
        #expect(facts == .allUnknown("no file at \(url.path)"))
        #expect(!FileManager.default.fileExists(atPath: url.path), "a read never creates the database")
    }

    // MARK: Scale

    /// Measured 2026-11-01, M5 Ultra, Debug, load 7.8 on 30 cores: the
    /// whole read (open, ten one-row/count queries, close) at 100k rows in
    /// 9.1 ms. Budget ≈ 27× that, load-aware (TimingBudget).
    static let readBudget: Duration = .milliseconds(250)

    @Test func hundredThousandRowsCountExactlyWithinBudget() async throws {
        let fixture = StoreFixture(kind: .grdb, directory: try StoreFixture.temporaryDirectory())
        defer { fixture.remove() }
        let repository = GRDBCatalogRepository(host: "scale-host", durability: .volatileForTests)
        try #require(await repository.open(at: fixture.url) == .readWrite)
        let rows = 100_000
        let outcome = await repository.write(as: .importRun) { transaction in
            guard let grdb = transaction as? GRDBTransaction else { throw FixtureFailure(words: "not a GRDB transaction") }
            let db = grdb.db
            try db.execute(sql: SchemaSeed.volumeInsert)
            let content = try db.cachedStatement(sql: "INSERT INTO content (digest, byte_count, first_seen_at, first_seen_how) VALUES (?, ?, 1700000000, 'import')")
            let live = try db.cachedStatement(sql: """
                INSERT INTO files (id, content_digest, volume_uuid, volume_case_sensitive, full_path, path_fold, filename, ext, directory,
                                   size_bytes, digest_computed_at, digest_source, stream_type, lifecycle, archive_stage)
                VALUES (?, ?, ?, 0, ?, ?, 'c.mov', 'mov', '/Volumes/A', 100, 1700000000, 'rescan', 'Video+Audio', 'Cataloged', 'None')
                """)
            let removed = try db.cachedStatement(sql: """
                INSERT INTO files (id, content_digest, volume_uuid, volume_case_sensitive, full_path, path_fold, filename, ext, directory,
                                   size_bytes, digest_computed_at, digest_source, stream_type, lifecycle, archive_stage,
                                   removal_state, removal_since, removal_reason)
                VALUES (?, ?, ?, 0, ?, ?, 'c.mov', 'mov', '/Volumes/A', 100, 1700000000, 'rescan', 'Video+Audio', 'Cataloged', 'None',
                        'removedFromCatalog', 1700000000, 'scale test')
                """)
            for index in 0..<rows {
                let hex = String(index, radix: 16)
                let digest = String(repeating: "0", count: 64 - hex.count) + hex
                let idHex = String(index, radix: 16, uppercase: true)
                let id = "00000000-0000-0000-0000-" + String(repeating: "0", count: 12 - idHex.count) + idHex
                let path = "/Volumes/A/d\(index / 100)/Clip\(index).mov"
                try content.execute(arguments: [digest, 100])   // = files.size_bytes (the DDL checks it)
                try (index % 10 == 0 ? removed : live).execute(arguments: [id, digest, SchemaSeed.volume, path, path.lowercased()])
            }
        }
        #expect(outcome == .committed(generation: 1))
        await repository.close()

        let loadBefore = TimingBudget.sampleLoad()
        let clock = ContinuousClock()
        let start = clock.now
        let facts = CatalogDatabaseInfoReader.read(at: fixture.url)
        let elapsed = clock.now - start
        print("[catalog-db-info] 100k-row read: \(elapsed) (\(TimingBudget.loadDescription()))")
        expectWithinTimingBudget("Catalog Database Info read at 100k rows", measured: elapsed,
                                 budget: Self.readBudget, loadBefore: loadBefore)
        #expect(facts.contents == .known(rows))
        #expect(facts.records == .known(rows))
        #expect(facts.liveFiles == .known(rows - rows / 10))
        #expect(facts.generation == .known(1))
        #expect(facts.lastCommit.value?.writer == CatalogWriter.importRun.rawValue)
    }
}
