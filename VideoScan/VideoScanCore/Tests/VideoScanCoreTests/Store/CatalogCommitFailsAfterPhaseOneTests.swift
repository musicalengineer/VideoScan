// CatalogCommitFailsAfterPhaseOneTests.swift
// GH #338, the residual window: every page is flushed to the WAL before
// phase 1 now (so a full disk refuses while the witnesses still read g), but
// COMMIT itself can still fail AFTER phase 1 raised them to g+1 — an fsync
// error, or the one commit frame not fitting. Then nothing may be reported
// saved, the witnesses stay (F8r3: never lowered — whether the frames reached
// the disk is not knowable from here), and the words must say what happened:
// "the save of generation g+1 failed at COMMIT", never "another writer
// published generation g+1" (the misleading words #338 reported).
//
// The failing COMMIT is made deterministically by a DEFERRED foreign-key
// violation in two TEMP tables: SQLite checks it only at COMMIT and refuses
// with SQLITE_CONSTRAINT_FOREIGNKEY. Temp tables live outside the catalog
// file, so the catalog's own schema is untouched.
//
// Dimensions: LOGIC (the words, the refusal of every later write, the
// generation unchanged, relaunch read-only with the restore words) ·
// ISOLATION (a temp-folder fixture, volatile durability) · SCALE / MEDIA N/A.

import Foundation
import GRDB
import Testing
@testable import VideoScanCore

@Suite("Catalog commit fails after phase 1 — named as a failed COMMIT, refuses until reopened, never reported saved")
struct CatalogCommitFailsAfterPhaseOneTests {

    /// A body whose COMMIT fails (deferred FK violation, checked at COMMIT).
    static let failsAtCommit: @Sendable (any CatalogTransaction) throws -> Void = { tx in
        guard let db = (tx as? GRDBTransaction)?.db else { throw FixtureFailure(words: "not a GRDB transaction") }
        try db.execute(sql: "CREATE TEMP TABLE IF NOT EXISTS gh338_parent (id INTEGER PRIMARY KEY)")
        try db.execute(sql: "CREATE TEMP TABLE IF NOT EXISTS gh338_child (pid INTEGER REFERENCES gh338_parent(id) DEFERRABLE INITIALLY DEFERRED)")
        try db.execute(sql: "INSERT INTO gh338_child (pid) VALUES (42)")
    }

    @Test("a COMMIT that fails after phase 1: refused with 'failed at COMMIT' and the engine's words; the next write says the same, not 'another writer published'; generation unchanged")
    func commitFailureIsNamed() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 5)
        defer { fixture.remove() }
        let repository = GRDBCatalogRepository(host: "test-host", durability: .volatileForTests)
        try #require(await repository.open(at: fixture.url) == .readWrite)

        let failed = await repository.write(as: .ui, Self.failsAtCommit)
        guard case .refused(let words) = failed else {
            Issue.record("a COMMIT that failed was reported as \(failed)"); await repository.close(); return
        }
        #expect(words.contains("the save of generation 6 failed at COMMIT"), Comment(rawValue: words))
        #expect(words.lowercased().contains("foreign key"), "the engine's words are missing: \(words)")
        #expect(words.contains("kept in memory") && words.contains("reopen the catalog"), Comment(rawValue: words))
        #expect(await repository.generation == 5, "the session's generation moved on a failed COMMIT")
        #expect(fixture.highWaterText() == "6", "phase 1 ran: the witness reads g+1 (never lowered)")

        let next = await repository.write(as: .ui) { _ in }
        guard case .refused(let why) = next else {
            Issue.record("the write after a failed COMMIT was \(next)"); await repository.close(); return
        }
        #expect(why.contains("failed at COMMIT"), Comment(rawValue: why))
        #expect(!why.contains("another writer"), "misleading words after this session's own failed COMMIT: \(why)")
        await repository.close()

        // Relaunch: the database reads 5, the witness 6 — exactly the
        // crash-between-phases shape, which refuses rather than guesses.
        let reopened = GRDBCatalogRepository(host: "test-host", durability: .volatileForTests)
        guard case .readOnly(let reason) = await reopened.open(at: fixture.url) else {
            Issue.record("a relaunch after a failed COMMIT did not open read-only"); await reopened.close(); return
        }
        #expect(reason.contains("restoredBelowHighWater"), Comment(rawValue: reason))
        await reopened.close()
    }

    @Test("a body that throws before phase 1 still says 'write rolled back' — the COMMIT words are only for a failed COMMIT")
    func bodyFailureKeepsItsWords() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 5)
        defer { fixture.remove() }
        let repository = GRDBCatalogRepository(host: "test-host", durability: .volatileForTests)
        try #require(await repository.open(at: fixture.url) == .readWrite)
        let failed = await repository.write(as: .ui) { _ in throw FixtureFailure(words: "the body said no") }
        guard case .refused(let words) = failed else { Issue.record("\(failed)"); await repository.close(); return }
        #expect(words.hasPrefix("write rolled back:"), Comment(rawValue: words))
        #expect(!words.contains("failed at COMMIT"), Comment(rawValue: words))
        #expect(fixture.highWaterText() == "5", "phase 1 must not run for a body that threw")
        #expect(await repository.write(as: .ui) { _ in } == .committed(generation: 6), "a body refusal blocks nothing")
        await repository.close()
    }
}
