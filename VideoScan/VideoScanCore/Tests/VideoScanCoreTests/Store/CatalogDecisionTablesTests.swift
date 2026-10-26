// CatalogDecisionTablesTests.swift
// Rick's decision tables in catalog.sqlite (schema v1.11, migration
// `v7_decision_tables`; CatalogDecisionRows.swift, GRDBCatalogRepository
// +Decisions.swift):
//   LOGIC      — a pair is stored ordered (a < b) whichever way it is handed
//                in; a second record of it is `alreadyRecorded` (the first
//                stands); a digest that is not stored content writes nothing
//                (`contentMissing`); the review reads the LATEST person's
//                verdict between the two contents, either direction. An
//                ignore entry round-trips; a put-back hides it from the live
//                list and is never repeated; a re-ignore is a new row.
//   GUARDS     — UPDATE / DELETE of either table is refused with the
//                trigger's words; an unordered pair and an unknown strength
//                are refused by the CHECKs; an imported ignored row that was
//                put back cannot be deleted (the foreign key).
//   MIGRATION  — a v1.10 database (schema 11) with ignored rows opens as
//                schema 12 with both tables empty and every row intact.
//   READ-ONLY  — a read-only open refuses a write: nothing lands.
//   SCALE      — 100k pairs recorded in one write and read back with their
//                verdicts, inside budgets.
// One condition per #expect. Synthetic names only.

import Foundation
import GRDB
import Testing
@testable import VideoScanCore

@Suite("CatalogDecisionTables")
struct CatalogDecisionTablesTests {

    private static func hex(_ n: Int) -> String { String(format: "%064x", n) }
    private static let entryOne = "BBBBBBBB-0000-0000-0000-000000000001"
    private static let entryTwo = "BBBBBBBB-0000-0000-0000-000000000002"

    private func open(_ fixture: StoreFixture) async throws -> GRDBCatalogRepository {
        let repository = GRDBCatalogRepository(host: "test-host", durability: .volatileForTests)
        let opened = await repository.open(at: fixture.url)
        try #require(opened == .readWrite)
        return repository
    }

    /// `count` content rows hex(1)…hex(count), raw (one transaction).
    private func seedContent(_ fixture: StoreFixture, count: Int) throws {
        try DatabaseQueue(path: fixture.url.path).inDatabase { db in
            try db.inTransaction {
                for n in 1...count {
                    try db.execute(sql: "INSERT INTO content (digest, byte_count, first_seen_at, first_seen_how) VALUES (?, 100, 1700000000, 'rescan')",
                                   arguments: [Self.hex(n)])
                }
                return .commit
            }
        }
    }

    private static func pair(_ x: Int, _ y: Int, strength: String = "weak", source: String = "duplicateCheck",
                             reasons: String = "timecode+duration") -> CatalogRow.FootageLikeness {
        CatalogRow.FootageLikeness(hex(x), hex(y), reasons: reasons, strength: strength, source: source, recordedAt: 1_760_850_000)
    }

    private static func entry(_ id: String = entryOne, name: String = "test_synthetic_junk.mov") -> CatalogRow.IgnoredEntry {
        CatalogRow.IgnoredEntry(entryID: id, partialMD5: "p-\(name)", sizeBytes: 4_096, filename: name, reason: "removed-by-user",
                                addedAt: 1_760_850_000, samplePath: "/Volumes/Synthetic/\(name)")
    }

    private func reviews(_ repository: GRDBCatalogRepository) async throws -> [CatalogRow.FootageLikenessReview] {
        try await repository.read { reader in
            var out: [CatalogRow.FootageLikenessReview] = []
            try reader.footageLikenessReviews { out.append($0) }
            return out
        }
    }

    private func ignored(_ repository: GRDBCatalogRepository) async throws -> [CatalogRow.IgnoredReading] {
        try await repository.read { reader in
            var out: [CatalogRow.IgnoredReading] = []
            try reader.ignoredRows { out.append($0) }
            return out
        }
    }

    private func refusal(_ fixture: StoreFixture, _ sql: String) -> String? {
        do {
            try DatabaseQueue(path: fixture.url.path).inDatabase { db in try db.execute(sql: sql) }
            return nil
        } catch {
            return ChecksRun.words(error)
        }
    }

    // MARK: - Logic: footage_likeness

    @Test func aPairIsStoredOrderedOnceAndAMissingContentWritesNothing() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        try seedContent(fixture, count: 3)
        let repository = try await open(fixture)
        let landings = LandingBox()
        let outcome = await repository.write(as: .ui) { tx in
            landings.values.append(try tx.recordFootageLikeness(Self.pair(2, 1)))
            landings.values.append(try tx.recordFootageLikeness(Self.pair(1, 2, strength: "anchored", reasons: "hash+duration")))
            landings.values.append(try tx.recordFootageLikeness(Self.pair(1, 99)))
        }
        #expect(outcome == .committed(generation: 1))
        #expect(landings.values == [.recorded, .alreadyRecorded, .contentMissing])
        let read = try await reviews(repository)
        #expect(read.map(\.likeness.digestA) == [Self.hex(1)])
        #expect(read.first?.likeness.digestB == Self.hex(2))
        #expect(read.first?.likeness.strength == "weak", "the first record stands")
        let count = try await repository.read { try $0.footageLikenessCount() }
        #expect(count == 1)
        await repository.close()
    }

    @Test func theReviewReadsTheLatestPersonsVerdictEitherDirection() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        try seedContent(fixture, count: 4)
        let queue = try DatabaseQueue(path: fixture.url.path)
        try queue.inDatabase { db in
            // (1,2): notSame, then same later — from the b side. (3,4): nobody said.
            try db.execute(sql: """
                INSERT INTO footage_decisions (row_id, other_row_id, digest, other_digest, verdict, decided_at)
                VALUES ('r1', 'r2', '\(Self.hex(1))', '\(Self.hex(2))', 'notSame', 100),
                       ('r2', 'r1', '\(Self.hex(2))', '\(Self.hex(1))', 'same', 200)
                """)
        }
        try queue.close()
        let repository = try await open(fixture)
        _ = await repository.write(as: .ui) { tx in
            _ = try tx.recordFootageLikeness(Self.pair(1, 2))
            _ = try tx.recordFootageLikeness(Self.pair(3, 4))
        }
        let read = try await reviews(repository)
        #expect(read.map(\.verdict) == ["same", nil])
        await repository.close()
    }

    // MARK: - Logic: the ignore list

    @Test func anIgnoreEntryRoundTripsAndAPutBackHidesItOnce() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        let repository = try await open(fixture)
        _ = await repository.write(as: .ui) { tx in
            try tx.appendIgnoredEntry(Self.entry())
            try tx.appendIgnoredEntry(Self.entry(Self.entryTwo, name: "test_other_junk.mov"))
        }
        let putBacks = LandingBox()
        _ = await repository.write(as: .ui) { tx in
            putBacks.counts.append(try tx.putBackIgnored(entryID: Self.entryOne, at: 1_760_900_000))
            putBacks.counts.append(try tx.putBackIgnored(entryID: Self.entryOne, at: 1_760_900_001))
        }
        #expect(putBacks.counts == [1, 0], "one put-back per ignored row")
        let rows = try await ignored(repository)
        #expect(rows.map(\.entry) == [Self.entry(), Self.entry(Self.entryTwo, name: "test_other_junk.mov")])
        #expect(rows.map(\.putBack) == [true, false])
        #expect(rows.allSatisfy { !$0.imported })
        // Ignoring the same content again is a NEW row.
        _ = await repository.write(as: .ui) { tx in try tx.appendIgnoredEntry(Self.entry("BBBBBBBB-0000-0000-0000-000000000003")) }
        let counts = try await repository.read { try $0.ignoredCounts() }
        #expect(counts == CatalogRow.IgnoredCounts(rows: 3, putBack: 1))
        #expect(counts.live == 2)
        await repository.close()
    }

    // MARK: - Guards

    @Test func bothTablesAreAppendOnlyAndTheirChecksHold() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        try seedContent(fixture, count: 2)
        let repository = try await open(fixture)
        _ = await repository.write(as: .ui) { tx in
            _ = try tx.recordFootageLikeness(Self.pair(1, 2))
            try tx.appendIgnoredEntry(Self.entry())
            try tx.putBackIgnored(entryID: Self.entryOne, at: 1)
        }
        await repository.close()
        #expect(refusal(fixture, "UPDATE footage_likeness SET strength = 'anchored'") == "footage_likeness is append-only evidence")
        #expect(refusal(fixture, "DELETE FROM footage_likeness") == "footage_likeness is append-only evidence")
        #expect(refusal(fixture, "UPDATE ignored_content_put_back SET put_back_at = 2") == "ignored_content_put_back is append-only evidence")
        #expect(refusal(fixture, "DELETE FROM ignored_content_put_back") == "ignored_content_put_back is append-only evidence")
        let unordered = refusal(fixture, """
            INSERT INTO footage_likeness (digest_a, digest_b, reasons, strength, source, recorded_at)
            VALUES ('\(Self.hex(2))', '\(Self.hex(1))', 'x', 'weak', 'duplicateCheck', 1)
            """)
        #expect(unordered?.contains("CHECK constraint failed") == true)
        let strength = refusal(fixture, """
            INSERT INTO footage_likeness (digest_a, digest_b, reasons, strength, source, recorded_at)
            VALUES ('\(Self.hex(1))', '\(Self.hex(3))', 'x', 'strong', 'duplicateCheck', 1)
            """)
        #expect(strength != nil)
        #expect(refusal(fixture, "DELETE FROM ignored_content") == "FOREIGN KEY constraint failed", "a put-back row pins its ignored row")
    }

    // MARK: - Migration from a v1.10 database

    @Test func aSchemaElevenDatabaseOpensAsTwelveWithEveryRowIntact() async throws {
        let fixture = StoreFixture(kind: .grdb, directory: try StoreFixture.temporaryDirectory())
        defer { fixture.remove() }
        var v110 = DatabaseMigrator()
        v110.registerMigration(CatalogBookkeepingSchema.migrationID, foreignKeyChecks: .immediate) { db in
            for statement in CatalogBookkeepingSchema.statements { try db.execute(sql: statement) }
            try db.execute(sql: "PRAGMA user_version = 7")
            try db.execute(sql: "INSERT INTO catalog_state (singleton, schema_version) VALUES (1, 7)")
            try db.execute(sql: "INSERT INTO generations (id, generation, saved_at, saved_from_host) VALUES (1, 0, 1, 'v1.10')")
            try db.execute(sql: "INSERT INTO generation_history (generation, committed_at, host, writer, files_live, files_total) VALUES (0, 1, 'v1.10', 'create', 0, 0)")
        }
        v110.registerMigration(CatalogDataSchema.migrationID, foreignKeyChecks: .immediate) { db in
            for statement in CatalogDataSchema.statements { try db.execute(sql: statement) }
        }
        let later: [(String, [String])] = [
            (CatalogLiveWritesSchema.migrationID, CatalogLiveWritesSchema.statements + CatalogLiveWritesSchema.versionBump),
            (CatalogPendingRowsSchema.migrationID, CatalogPendingRowsSchema.statements + CatalogPendingRowsSchema.versionBump),
            (CatalogCommitB22Schema.migrationID, CatalogCommitB22Schema.statements + CatalogCommitB22Schema.versionBump),
            (CatalogFolderKindSchema.migrationID, CatalogFolderKindSchema.statements + CatalogFolderKindSchema.versionBump),
        ]
        for (id, statements) in later {
            v110.registerMigration(id, foreignKeyChecks: .immediate) { db in
                for statement in statements { try db.execute(sql: statement) }
            }
        }
        let queue = try DatabaseQueue(path: fixture.url.path)
        try v110.migrate(queue)
        try queue.inDatabase { db in
            try db.execute(sql: """
                INSERT INTO ignored_content (entry_id, partial_md5, size_bytes, filename, reason, added_at, sample_path)
                VALUES ('\(Self.entryOne)', 'p', 10, 'test_synthetic_junk.mov', 'removed-by-user', 1, '/Volumes/Synthetic/x')
                """)
        }
        let before = try queue.inDatabase { db in try Int.fetchOne(db, sql: "SELECT schema_version FROM catalog_state") }
        #expect(before == 11)
        try queue.close()
        try fixture.writeHighWater("0")

        let repository = try await open(fixture)
        let rows = try await ignored(repository)
        #expect(rows.map(\.entry.entryID) == [Self.entryOne])
        #expect(rows.first?.putBack == false)
        let pairs = try await repository.read { try $0.footageLikenessCount() }
        #expect(pairs == 0)
        await repository.close()
        let after = try DatabaseQueue(path: fixture.url.path).inDatabase { db in
            try Int.fetchOne(db, sql: "SELECT schema_version FROM catalog_state")
        }
        #expect(after == GRDBCatalogRepository.currentSchemaVersion)
    }

    // MARK: - Read-only

    @Test func aReadOnlyOpenRefusesADecisionWrite() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        try seedContent(fixture, count: 2)
        let repository = GRDBCatalogRepository(host: "test-host", durability: .volatileForTests)
        let opened = await repository.openReadOnly(at: fixture.url, reason: "test: a viewer")
        guard case .readOnly = opened else {
            Issue.record("expected .readOnly, got \(opened)")
            return
        }
        let outcome = await repository.write(as: .ui) { tx in
            _ = try tx.recordFootageLikeness(Self.pair(1, 2))
            try tx.appendIgnoredEntry(Self.entry())
        }
        guard case .refused = outcome else {
            Issue.record("expected .refused, got \(outcome)")
            return
        }
        let pairs = try await repository.read { try $0.footageLikenessCount() }
        #expect(pairs == 0)
        let counts = try await repository.read { try $0.ignoredCounts() }
        #expect(counts.rows == 0)
        await repository.close()
    }

    // MARK: - Scale

    /// 100k pairs over 100,001 contents in ONE write, then read back with
    /// their verdicts. Budgets (Debug, M4 Max): write 20 s, read 10 s — a
    /// per-row scan of footage_decisions or a missing index would be
    /// minutes. Load-aware (GH #208 busy-machine rule, 2026-10-21): measured
    /// 5.2 s on its own, 33 s at load 40–190 on 16 cores — a busy miss
    /// within 3× is a known issue, a real miss still fails.
    @Test(.timeLimit(.minutes(3)))
    func oneHundredThousandPairsRecordAndReadInsideBudgets() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        let n = 100_000
        try seedContent(fixture, count: n + 1)
        let repository = try await open(fixture)
        let clock = ContinuousClock()
        var outcome: CatalogWriteOutcome?
        let loadBeforeWrite = TimingBudget.sampleLoad()
        let write = await clock.measure {
            outcome = await repository.write(as: .ui) { tx in
                for i in 1...n { _ = try tx.recordFootageLikeness(Self.pair(i, i + 1)) }
            }
        }
        #expect(outcome == .committed(generation: 1))
        var read: [CatalogRow.FootageLikenessReview] = []
        let loadBeforeRead = TimingBudget.sampleLoad()
        let reading = try await clock.measure { read = try await reviews(repository) }
        print("[decision-tables] 100k pairs: write \(write), read \(reading) (\(TimingBudget.loadDescription()))")
        #expect(read.count == n)
        expectWithinTimingBudget("100k footage-likeness pairs written", measured: write,
                                 budget: .seconds(20), loadBefore: loadBeforeWrite)
        expectWithinTimingBudget("100k footage-likeness pairs read", measured: reading,
                                 budget: .seconds(10), loadBefore: loadBeforeRead)
        await repository.close()
    }
}

/// Collects what a write body returns (the body is `@Sendable`).
private final class LandingBox: @unchecked Sendable {
    var values: [CatalogRow.FootageLikenessLanding] = []
    var counts: [Int] = []
}
