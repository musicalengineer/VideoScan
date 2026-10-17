// GRDBCatalogRepositoryTests.swift
// GRDB-only behaviour of the catalog store: the pragmas, the generation
// CAS, the history rows, the two-phase high-water, adoption, the open
// refusals, and the poisoned-state (isolation) and restored-copy (TRUTH)
// cases. One condition per #expect.
//
// This file imports GRDB to open the SAME file with a plain DatabaseQueue
// and attack the DDL directly (a plain jump, a newer schema). It lives
// under Tests/…/Store/, which is the one place outside Sources/…/Store/
// the sensor allows that import.

import Foundation
import GRDB
import Testing
@testable import VideoScanCore

@Suite("GRDBCatalogRepository")
struct GRDBCatalogRepositoryTests {

    // MARK: - Helpers

    private func openAtFive(durability: GRDBCatalogRepository.Durability = .volatileForTests) async throws
        -> (StoreFixture, GRDBCatalogRepository) {
        let fixture = try await StoreFixture.make(.grdb, generation: 5, durability: durability)
        let repository = GRDBCatalogRepository(host: "test-host", durability: durability)
        let opened = await repository.open(at: fixture.url)
        try #require(opened == .readWrite)
        return (fixture, repository)
    }

    private func rawQueue(_ fixture: StoreFixture) throws -> DatabaseQueue {
        try DatabaseQueue(path: fixture.url.path)
    }

    private struct HistoryRow: Equatable {
        let generation: Int
        let writer: String
        let kind: String
        let fromGeneration: Int?
    }

    private func history(_ fixture: StoreFixture) throws -> [HistoryRow] {
        try rawQueue(fixture).inDatabase { db in
            try Row.fetchAll(db, sql: "SELECT generation, writer, kind, from_generation FROM generation_history ORDER BY generation")
                .map { HistoryRow(generation: $0[0], writer: $0[1], kind: $0[2], fromGeneration: $0[3]) }
        }
    }

    // MARK: - Logic: create / open / pragmas

    @Test func aFreshFileIsCreatedAtGenerationZero() async throws {
        let directory = try StoreFixture.temporaryDirectory()
        let fixture = StoreFixture(kind: .grdb, directory: directory)
        defer { fixture.remove() }
        let repository = GRDBCatalogRepository(host: "test-host", durability: .volatileForTests)
        let opened = await repository.open(at: fixture.url)
        #expect(opened == .readWrite)
        let generation = await repository.generation
        #expect(generation == 0)
        #expect(fixture.highWaterText() == "0")
        await repository.close()
        #expect(try history(fixture) == [HistoryRow(generation: 0, writer: "create", kind: "commit", fromGeneration: nil)])
    }

    @Test func archivalPragmasQueriedBack() async throws {
        let (fixture, repository) = try await openAtFive(durability: .archival)
        defer { fixture.remove() }
        let pragmas = try await repository.pragmas()
        #expect(pragmas["journal_mode"] == "wal")
        #expect(pragmas["synchronous"] == "2")          // FULL
        #expect(pragmas["fullfsync"] == "1")
        #expect(pragmas["foreign_keys"] == "1")
        #expect(pragmas["busy_timeout"] == "5000")
        #expect(pragmas["user_version"] == "7")
        await repository.close()
    }

    @Test func volatileDurabilityIsOnlyWeakerWhereItSays() async throws {
        let (fixture, repository) = try await openAtFive()
        defer { fixture.remove() }
        let pragmas = try await repository.pragmas()
        #expect(pragmas["synchronous"] == "1")          // NORMAL
        #expect(pragmas["fullfsync"] == "0")
        #expect(pragmas["journal_mode"] == "wal")
        #expect(pragmas["foreign_keys"] == "1")
        await repository.close()
    }

    // MARK: - Logic: the CAS and its history

    @Test func aWriteAdvancesByOneAndRecordsHistory() async throws {
        let (fixture, repository) = try await openAtFive()
        defer { fixture.remove() }
        let outcome = await repository.write(as: .rescan) { _ in }
        #expect(outcome == .committed(generation: 6))
        let generation = await repository.generation
        #expect(generation == 6)
        #expect(fixture.highWaterText() == "6")
        await repository.close()
        let rows = try history(fixture)
        #expect(rows.count == 7)
        #expect(rows.last == HistoryRow(generation: 6, writer: "rescan", kind: "commit", fromGeneration: nil))
    }

    @Test func theBodySeesTheGenerationItWritesTo() async throws {
        let (fixture, repository) = try await openAtFive()
        defer { fixture.remove() }
        let seen = Seen()
        _ = await repository.write(as: .ui) { transaction in seen.record(transaction.generation) }
        #expect(seen.value == 6)
        await repository.close()
    }

    @Test func aStaleSessionGetsGenerationMismatch() async throws {
        let (fixture, first) = try await openAtFive()
        defer { fixture.remove() }
        let second = GRDBCatalogRepository(host: "other-host", durability: .volatileForTests)
        _ = await second.open(at: fixture.url)
        _ = await first.write(as: .ui) { _ in }                       // 5 → 6
        let stale = await second.write(as: .ui) { _ in }
        #expect(stale == .generationMismatch(expected: 5, found: 6))
        let unchanged = await second.generation
        #expect(unchanged == 5)
        #expect(fixture.highWaterText() == "6")                       // never lowered by the loser
        await first.close()
        await second.close()
    }

    @Test func aThrowingBodyRollsBackEverything() async throws {
        let (fixture, repository) = try await openAtFive()
        defer { fixture.remove() }
        let outcome = await repository.write(as: .ui) { _ in throw FixtureFailure(words: "body refused") }
        guard case .refused(let reason) = outcome else {
            Issue.record("expected .refused, got \(outcome)")
            return
        }
        #expect(reason.contains("body refused"))
        let generation = await repository.generation
        #expect(generation == 5)
        #expect(fixture.highWaterText() == "5")
        await repository.close()
        #expect(try history(fixture).count == 6)
    }

    // MARK: - Logic: adoption and the +1 rule

    @Test func adoptFiveToTenSucceedsWithItsOwnHistoryRow() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 5)
        defer { fixture.remove() }
        try fixture.writeHighWater("10")
        let repository = GRDBCatalogRepository(host: "test-host", durability: .volatileForTests)
        let opened = await repository.open(at: fixture.url)
        guard case .readOnly = opened else {
            Issue.record("expected .readOnly, got \(opened)")
            return
        }
        let adopted = await repository.adopt(toHighWater: 10)
        #expect(adopted == .adopted(from: 5, to: 10))
        let generation = await repository.generation
        #expect(generation == 10)
        let next = await repository.write(as: .ui) { _ in }
        #expect(next == .committed(generation: 11))
        await repository.close()
        let rows = try history(fixture)
        #expect(rows[6] == HistoryRow(generation: 10, writer: "adopt", kind: "adopt", fromGeneration: 5))
        #expect(rows.last == HistoryRow(generation: 11, writer: "ui", kind: "commit", fromGeneration: nil))
    }

    @Test func adoptingANumberTheFileDoesNotHoldIsRefused() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 5)
        defer { fixture.remove() }
        try fixture.writeHighWater("10")
        let repository = GRDBCatalogRepository(host: "test-host", durability: .volatileForTests)
        _ = await repository.open(at: fixture.url)
        let outcome = await repository.adopt(toHighWater: 9)
        guard case .refused(let reason) = outcome else {
            Issue.record("expected .refused, got \(outcome)")
            return
        }
        #expect(reason.contains("reads 10, not 9"))
        let generation = await repository.generation
        #expect(generation == 5)
        await repository.close()
    }

    @Test func adoptingWithNothingToAdoptIsRefused() async throws {
        let (fixture, repository) = try await openAtFive()
        defer { fixture.remove() }
        let outcome = await repository.adopt(toHighWater: 5)
        #expect(outcome == .refused(reason: "nothing to adopt: generation 5 is not below 5"))
        await repository.close()
    }

    @Test func aPlainJumpIsRefusedByTheTrigger() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 5)
        defer { fixture.remove() }
        let queue = try rawQueue(fixture)
        #expect(throws: DatabaseError.self) {
            try queue.inDatabase { db in try db.execute(sql: "UPDATE generations SET generation = 10 WHERE id = 1") }
        }
        let generation = try queue.inDatabase { db in try Int.fetchOne(db, sql: "SELECT generation FROM generations WHERE id = 1") }
        #expect(generation == 5)
    }

    @Test func aPlusOneStepThroughRawSQLStillWorks() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 5)
        defer { fixture.remove() }
        let queue = try rawQueue(fixture)
        let changes = try queue.inDatabase { db -> Int in
            try db.execute(sql: "UPDATE generations SET generation = generation + 1 WHERE id = 1 AND generation = 5")
            return db.changesCount
        }
        #expect(changes == 1)
    }

    // MARK: - Logic: crash between the phases

    @Test func aCrashBetweenPhasesOpensReadOnlyUntilAdopted() async throws {
        let (fixture, repository) = try await openAtFive()
        defer { fixture.remove() }
        await repository.injectCrashBeforeCommit { throw FixtureFailure(words: "power lost") }
        let crashed = await repository.write(as: .ui) { _ in }
        guard case .refused = crashed else {
            Issue.record("expected .refused, got \(crashed)")
            return
        }
        #expect(fixture.highWaterText() == "6")                       // phase 1 landed
        await repository.close()

        let reopened = GRDBCatalogRepository(host: "test-host", durability: .volatileForTests)
        let outcome = await reopened.open(at: fixture.url)
        guard case .readOnly(let reason) = outcome else {
            Issue.record("expected .readOnly, got \(outcome)")
            return
        }
        #expect(reason.contains("restoredBelowHighWater"))
        let refused = await reopened.write(as: .ui) { _ in }
        guard case .refused(let why) = refused else {
            Issue.record("expected .refused, got \(refused)")
            return
        }
        #expect(why.hasPrefix("read-only:"))
        let adopted = await reopened.adopt(toHighWater: 6)
        #expect(adopted == .adopted(from: 5, to: 6))
        let next = await reopened.write(as: .ui) { _ in }
        #expect(next == .committed(generation: 7))
        await reopened.close()
    }

    // MARK: - Logic: open refusals

    @Test func aNewerSchemaIsRefused() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 1)
        defer { fixture.remove() }
        try rawQueue(fixture).inDatabase { db in
            try db.execute(sql: "UPDATE catalog_state SET schema_version = 8 WHERE singleton = 1")
        }
        let repository = GRDBCatalogRepository(host: "test-host", durability: .volatileForTests)
        let outcome = await repository.open(at: fixture.url)
        guard case .refused(let reason) = outcome else {
            Issue.record("expected .refused, got \(outcome)")
            return
        }
        #expect(reason.contains("schema version 8 is newer"))
    }

    @Test func aCorruptedFileIsRefusedWithTheEnginesWords() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 1_500)
        defer { fixture.remove() }
        // Pages 2–4 (4 KB each) overwritten with noise: the b-tree pages
        // behind generation_history. The header (page 1) stays intact so
        // the file still opens and integrity_check is what says no.
        let handle = try FileHandle(forWritingTo: fixture.url)
        try handle.seek(toOffset: 4096)
        try handle.write(contentsOf: Data((0..<(3 * 4096)).map { UInt8(truncatingIfNeeded: $0 &* 2_654_435_761) }))
        try handle.close()
        let repository = GRDBCatalogRepository(host: "test-host", durability: .volatileForTests)
        let outcome = await repository.open(at: fixture.url)
        guard case .refused(let reason) = outcome else {
            Issue.record("expected .refused, got \(outcome)")
            return
        }
        #expect(!reason.isEmpty)
    }

    // MARK: - Isolation: poisoned high-water, read-only folder, stale WAL

    @Test("a poisoned high-water opens read-only", arguments: ["banana", "", "-3", "5 apples"])
    func poisonedHighWaterOpensReadOnly(text: String) async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 5)
        defer { fixture.remove() }
        try fixture.writeHighWater(text)
        let repository = GRDBCatalogRepository(host: "test-host", durability: .volatileForTests)
        let outcome = await repository.open(at: fixture.url)
        guard case .readOnly(let reason) = outcome else {
            Issue.record("expected .readOnly for '\(text)', got \(outcome)")
            return
        }
        #expect(reason.contains("not a generation number"))
        await repository.close()
    }

    @Test func aPoisonedHighWaterIsRepairedByAnExplicitAdoption() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 5)
        defer { fixture.remove() }
        try fixture.writeHighWater("banana")
        let repository = GRDBCatalogRepository(host: "test-host", durability: .volatileForTests)
        _ = await repository.open(at: fixture.url)
        let adopted = await repository.adopt(toHighWater: 7)
        #expect(adopted == .adopted(from: 5, to: 7))
        #expect(fixture.highWaterText() == "7")
        await repository.close()
    }

    @Test func aLowerHighWaterIsRaisedToTheGeneration() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 5)
        defer { fixture.remove() }
        try fixture.writeHighWater("2")
        let repository = GRDBCatalogRepository(host: "test-host", durability: .volatileForTests)
        let outcome = await repository.open(at: fixture.url)
        #expect(outcome == .readWrite)
        #expect(fixture.highWaterText() == "5")
        await repository.close()
    }

    @Test func aMissingHighWaterIsRecreatedFromTheDatabase() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 5)
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.highWaterURL)
        let repository = GRDBCatalogRepository(host: "test-host", durability: .volatileForTests)
        let outcome = await repository.open(at: fixture.url)
        #expect(outcome == .readWrite)
        #expect(fixture.highWaterText() == "5")
        await repository.close()
    }

    @Test func aReadOnlyFolderNeverOpensForWriting() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 5)
        let manager = FileManager.default
        try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fixture.directory.path)
        defer {
            try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.directory.path)
            fixture.remove()
        }
        let repository = GRDBCatalogRepository(host: "test-host", durability: .volatileForTests)
        let outcome = await repository.open(at: fixture.url)
        guard case .readOnly(let reason) = outcome else {
            Issue.record("expected .readOnly, got \(outcome)")
            return
        }
        #expect(reason.contains("is not writable"))
        let write = await repository.write(as: .ui) { _ in }
        guard case .refused(let why) = write else {
            Issue.record("expected .refused, got \(write)")
            await repository.close()
            return
        }
        #expect(why.hasPrefix("read-only:"))
        await repository.close()
    }

    @Test func garbageWalAndShmBesideACheckpointedDatabaseAreHarmless() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 5)
        defer { fixture.remove() }
        // GRDB's close leaves the WAL in place (SQLite recovers it at the
        // next open); checkpoint it into the main file first, then poison
        // the two sidecars so only the main file holds the truth.
        try rawQueue(fixture).inDatabase { db in try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
        let noise = Data((0..<8192).map { UInt8(truncatingIfNeeded: $0 &* 2_654_435_761) })
        try noise.write(to: URL(fileURLWithPath: fixture.url.path + "-wal"))
        try noise.write(to: URL(fileURLWithPath: fixture.url.path + "-shm"))
        let repository = GRDBCatalogRepository(host: "test-host", durability: .volatileForTests)
        let outcome = await repository.open(at: fixture.url)
        #expect(outcome == .readWrite)
        let generation = await repository.generation
        #expect(generation == 5)
        await repository.close()
    }

    // MARK: - TRUTH: a restored older copy says so

    @Test func aDatabaseRestoredFromAnOlderCopyOpensReadOnlyAndSaysSo() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 5)
        defer { fixture.remove() }
        // The backup the way §9.6 says: a completed VACUUM INTO, never a
        // copy of the main file alone (its WAL may hold the newest frames).
        let backup = fixture.directory.appendingPathComponent("catalog.backup-at-5.sqlite")
        try rawQueue(fixture).inDatabase { db in try db.execute(sql: "VACUUM INTO ?", arguments: [backup.path]) }

        let writer = GRDBCatalogRepository(host: "test-host", durability: .volatileForTests)
        _ = await writer.open(at: fixture.url)
        for _ in 0..<5 { _ = await writer.write(as: .ui) { _ in } }     // 5 → 10
        await writer.close()
        #expect(fixture.highWaterText() == "10")

        // The restore: yesterday's file back in place, the sidecars of the newer one gone.
        try FileManager.default.removeItem(at: fixture.url)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: fixture.url.path + "-wal"))
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: fixture.url.path + "-shm"))
        try FileManager.default.copyItem(at: backup, to: fixture.url)

        let restored = GRDBCatalogRepository(host: "test-host", durability: .volatileForTests)
        let outcome = await restored.open(at: fixture.url)
        guard case .readOnly(let reason) = outcome else {
            Issue.record("expected .readOnly, got \(outcome)")
            return
        }
        #expect(reason.contains("at generation 5"))
        #expect(reason.contains("already wrote generation 10"))
        let verdict = await restored.verify()
        guard case .problems(let problems) = verdict else {
            Issue.record("expected .problems, got \(verdict)")
            return
        }
        #expect(problems.contains { $0.contains("restoredBelowHighWater") })
        let adopted = await restored.adopt(toHighWater: 10)
        #expect(adopted == .adopted(from: 5, to: 10))
        let afterAdoption = await restored.verify()
        #expect(afterAdoption == .ok(generation: 10, highWater: 10))
        await restored.close()
    }
}

/// A box a `@Sendable` body can write into (the body runs on the store's
/// queue; the test reads after the write returns).
private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var value: Int { lock.withLock { stored } }
    func record(_ value: Int) { lock.withLock { stored = value } }
}
