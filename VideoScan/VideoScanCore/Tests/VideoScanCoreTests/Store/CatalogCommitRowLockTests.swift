// CatalogCommitRowLockTests.swift
// The per-row lock at the commit door (codex #141 F2 closing pass, cycle
// #143 — CatalogRowLock.swift, CatalogCommitBody.verifyExpectations):
//   LOGIC     a row another CONNECTION changed since this session saw it
//             refuses the WHOLE commit — nothing written, the generation
//             untouched, the words name the row; the same row at its current
//             lock commits, and the result carries the lock the store holds
//             after the write; a held record another connection stored as a
//             row is refused; a shared SCALAR both writers changed is
//             refused, one only this session changed passes;
//   TRUTH     the lock covers the row's OWN parts only: a sibling copy's
//             shared edit (notes, per content) does not move it, a footage
//             decision (per row) does — so a sibling's save never reads as
//             a stranger's;
//   SCALE     100 submitted rows with expectations: the check reuses the
//             read `land` makes; the post-write read-back is the only extra
//             (≈ 0.7 ms a written row). Timed and printed; budget 5 s Debug;
//   ISOLATION a second repository on the same file plays the other writer;
//             every case on a temp fixture, never Application Support.
//
// Red/green (Debug, M4 Max): RED by construction on 549a9b798 — the door had
// no per-row check (`Item.expected` did not exist): a stale snapshot's diff
// deleted the other connection's decision and the commit reported written.
// GREEN here.
//
// Lives under Tests/…/Store/ because it reads the database with a plain
// GRDB queue (the sensor allows `import GRDB` only here and in Sources/…/Store/).
//
// Suites (filter by SUITE): CatalogCommitRowLockTests

import Foundation
import GRDB
import Testing
@testable import VideoScanCore

private let healthyID = PoisonedCatalogFixture.id(.healthy)
private let staleID = PoisonedCatalogFixture.id(.stalePrint)
private let conflictA = PoisonedCatalogFixture.id(.curatedConflictA)
private let conflictB = PoisonedCatalogFixture.id(.curatedConflictB)

@Suite("CatalogCommitRowLock — the door refuses a row another connection changed since this session saw it (codex #143)", .serialized)
struct CatalogCommitRowLockTests {

    /// The lock the store reports for `id` now, through the seam.
    private static func lock(_ s: CommitScene, _ id: String) async throws -> CatalogRowLock.Value {
        let repository = GRDBCatalogRepository(host: "lock-test", durability: .volatileForTests)
        guard await repository.open(at: s.scene.databaseURL) == .readWrite else { throw FixtureFailure(words: "lock read could not open") }
        let row = try await repository.read { try $0.storedRow(id: id) }
        await repository.close()
        return CatalogRowLock.of(try #require(row, "no stored row for \(id)"))
    }

    /// Another connection: a footage decision on `record` (a per-row part).
    private static func otherWriterDecides(_ s: CommitScene, rowOf record: VideoRecord, about otherID: UUID) async throws {
        let digest = try #require(CatalogCommit.digest(of: record))
        let rowID = record.id.uuidString
        let decision = CatalogRecordDTO.FootageDecisionRow(rowID: rowID, otherRowID: otherID.uuidString, verdict: "notSame", decidedAt: 1_790_600_000)
        try await Self.otherWriter(s) { tx in try tx.replaceFootageDecisions(rowID: rowID, digest: digest, [decision]) }
    }

    /// Another connection: the SHARED `field` of `record`'s content (per content).
    private static func otherWriterSets(_ s: CommitScene, _ field: CatalogDDL.KnowledgeField, of record: VideoRecord,
                                        _ change: (inout CatalogRecordDTO.CuratedKnowledge) -> Void) async throws {
        let digest = try #require(CatalogCommit.digest(of: record))
        var curated = try CatalogRecordDTO(record: record, migrationLoadedAt: 0).curated
        change(&curated)
        let value = curated
        try await Self.otherWriter(s) { tx in try tx.writeDisplayValue(digest: digest, field: field, value, setAt: 1_790_600_000) }
    }

    private static func otherWriter(_ s: CommitScene, _ body: @Sendable @escaping (any CatalogTransaction) throws -> Void) async throws {
        let repository = GRDBCatalogRepository(host: "other-writer", durability: .volatileForTests)
        guard await repository.open(at: s.scene.databaseURL) == .readWrite else { throw FixtureFailure(words: "the other writer could not open") }
        let outcome = await repository.write(as: .ui, body)
        await repository.close()
        guard case .committed = outcome else { throw FixtureFailure(words: "the other writer's commit: \(outcome)") }
    }

    private static func item(_ record: VideoRecord, baseline: CatalogSharedCurated?, expected: CatalogCommit.Expectation?) -> CatalogCommit.Item {
        let snapshot = VideoRecordDTO(record)
        return CatalogCommit.Item(id: record.id, snapshot: snapshot, fingerprint: CatalogChangeDetector.fingerprint(snapshot),
                                  sharedBaseline: baseline, expected: expected)
    }

    private static func decisions(_ s: CommitScene, _ id: String) throws -> Int {
        try s.scalar("SELECT count(*) FROM footage_decisions WHERE row_id = ?", [id]) ?? -1
    }

    // MARK: - LOGIC

    @Test("a row another connection changed refuses the whole commit: nothing written, generation kept, the row named, their decision intact")
    func doorRefusesChangedRow() async throws {
        let s = try await CommitScene.make(); defer { s.remove() }
        let loaded = try await s.load()
        let healthy = try #require(loaded.records[healthyID])
        let stale = try #require(loaded.records[staleID])
        let seen = try await Self.lock(s, healthyID)                       // what this session last saw
        let baseline = CatalogSharedCurated(healthy)

        try await Self.otherWriterDecides(s, rowOf: healthy, about: stale.id)
        let generation = try s.generation()                               // the CAS alone would let a fresh connection through
        healthy.userNotes = "a stale session's note"
        stale.starRating = 3
        let outcome = try await s.commitItems([Self.item(healthy, baseline: baseline, expected: .row(lock: seen)),
                                               Self.item(stale, baseline: CatalogSharedCurated(stale), expected: nil)])

        guard case .refused(let words, let rows) = outcome else { Issue.record("expected .refused, got \(outcome)"); return }
        #expect(words.contains(healthyID), Comment(rawValue: words))
        #expect(words.contains("another writer changed its row"), Comment(rawValue: words))
        #expect(words.contains("Reopen"), Comment(rawValue: words))
        #expect(rows.isEmpty, "no row ran: the check comes before every write")
        #expect(try s.generation() == generation, "the generation is untouched")
        #expect(try Self.decisions(s, healthyID) == 1, "the other connection's decision survives")
        let after = try await s.load()
        #expect(after.records[healthyID]?.userNotes != "a stale session's note")
        #expect(after.records[staleID]?.starRating != 3, "the whole commit was refused — the neighbour too")
    }

    @Test("the same row at its current lock commits, and the result carries the lock the store holds after the write")
    func doorAcceptsCurrentLockAndReportsTheNext() async throws {
        let s = try await CommitScene.make(); defer { s.remove() }
        let loaded = try await s.load()
        let healthy = try #require(loaded.records[healthyID])
        let current = try await Self.lock(s, healthyID)
        healthy.setAsideReason = "checked"
        let outcome = try await s.commitItems([Self.item(healthy, baseline: CatalogSharedCurated(healthy), expected: .row(lock: current))])
        #expect(outcome.isCommitted)
        let row = try #require(outcome.rows.first)
        #expect(row.landing.landed)
        let after = try await Self.lock(s, healthyID)
        #expect(row.storedLock == after, "the store read the row back after the write")
        #expect(after != current, "a row-scoped edit moved the lock")
        // Unchanged: the lock reported is the one read before (nothing moved).
        let again = try await s.commitItems([Self.item(healthy, baseline: CatalogSharedCurated(healthy), expected: .row(lock: after))])
        #expect(again.landing(healthyID) == .unchanged)
        #expect(again.rows.first?.storedLock == after)
    }

    @Test("a held record another connection stored as a row is refused")
    func doorRefusesMaterialisedPending() async throws {
        let s = try await CommitScene.make(); defer { s.remove() }
        let loaded = try await s.load()
        let healthy = try #require(loaded.records[healthyID])
        let fresh = try FreshRecord.copy(healthy, path: "/Volumes/Fixture/fresh/held.mov")
        let held = try await s.commit([fresh])
        #expect(held.rows.first?.heldPending == true, "held in pending_rows")

        // The other connection finishes its hash first and stores the same id as a row.
        let twin = try CatalogPendingRecord.record(try CatalogPendingRecord.json(VideoRecordDTO(fresh)))
        let digest = String(repeating: "cd", count: 32)
        FreshRecord.giveDigest(twin, digest)
        #expect(try await s.commit([twin]).isCommitted)
        let rows: Int? = try s.scalar("SELECT count(*) FROM files WHERE id = ?", [fresh.id.uuidString])
        #expect(rows == 1)

        FreshRecord.giveDigest(fresh, digest)
        fresh.userNotes = "this session's note"
        let outcome = try await s.commitItems([Self.item(fresh, baseline: nil, expected: .pending)])
        guard case .refused(let words, _) = outcome else { Issue.record("expected .refused, got \(outcome)"); return }
        #expect(words.contains("stored it as a row"), Comment(rawValue: words))
        #expect(try await s.load().records[fresh.id.uuidString]?.userNotes != "this session's note")
    }

    @Test("a shared scalar both writers changed is refused; one only this session changed passes (the other writer changed a different group)")
    func doorChecksSharedScalarsThroughTheBaseline() async throws {
        let s = try await CommitScene.make(); defer { s.remove() }
        let loaded = try await s.load()
        let healthy = try #require(loaded.records[healthyID])
        let baseline = CatalogSharedCurated(healthy)
        let lock = try await Self.lock(s, healthyID)

        try await Self.otherWriterSets(s, .userNotes, of: healthy) { $0.userNotes = "B's note" }
        #expect(try await Self.lock(s, healthyID) == lock, "a shared value is not under the row lock")
        healthy.userNotes = "A's note"
        let refused = try await s.commitItems([Self.item(healthy, baseline: baseline, expected: .row(lock: lock))])
        guard case .refused(let words, _) = refused else { Issue.record("expected .refused, got \(refused)"); return }
        #expect(words.contains("notes"), Comment(rawValue: words))
        #expect(try await s.load().records[healthyID]?.userNotes == "B's note", "B's note is kept")

        // Only this session changed the stars; the other writer's note is a different group: passes, and B's note stays.
        healthy.userNotes = baseline.userNotes
        healthy.starRating = 3                                                // the DDL keeps stars 1…3
        let committed = try await s.commitItems([Self.item(healthy, baseline: baseline, expected: .row(lock: lock))])
        #expect(committed.isCommitted, "\(committed)")
        let after = try await s.load()
        #expect(after.records[healthyID]?.starRating == 3)
        #expect(after.records[healthyID]?.userNotes == "B's note", "the note this session did not edit is not written")
    }

    // MARK: - TRUTH: what the lock covers

    @Test("a sibling copy's shared edit does not move this row's lock; a footage decision on the row does")
    func lockCoversRowPartsOnly() async throws {
        let s = try await CommitScene.make(); defer { s.remove() }
        let loaded = try await s.load()
        let a = try #require(loaded.records[conflictA])
        let b = try #require(loaded.records[conflictB])
        let before = try await Self.lock(s, conflictB)

        a.userNotes = "A's note, shared by content"
        a.starRating = 3
        let shared = try await s.commit([a])
        #expect(shared.isCommitted, "\(shared)")
        #expect(try await Self.lock(s, conflictB) == before, "the sibling's shared write left B's row lock alone")
        #expect(try await s.load().records[conflictB]?.userNotes == "A's note, shared by content", "and yet B shows it (per content)")

        try await Self.otherWriterDecides(s, rowOf: b, about: a.id)
        #expect(try await Self.lock(s, conflictB) != before, "a per-row part moved the lock")
    }

    // MARK: - SCALE

    @Test("SCALE: 100 submitted rows with expectations commit under budget (the check reuses land's read; the read-back is the only extra)")
    func hundredRowsUnderBudget() async throws {
        let s = try await CommitScene.make(healthyRows: 100); defer { s.remove() }
        let loaded = try await s.load()
        let ids = loaded.records.keys.sorted().prefix(100)
        let repository = GRDBCatalogRepository(host: "lock-test", durability: .volatileForTests)
        guard await repository.open(at: s.scene.databaseURL) == .readWrite else { throw FixtureFailure(words: "open") }
        let wanted = Array(ids)
        let locks = try await repository.read { reader in
            try wanted.map { id in CatalogRowLock.of(try #require(try reader.storedRow(id: id))) }
        }
        await repository.close()
        var items: [CatalogCommit.Item] = []
        for (id, lock) in zip(wanted, locks) {
            let record = try #require(loaded.records[id])
            let baseline = CatalogSharedCurated(record)
            record.setAsideReason = "scale"
            items.append(Self.item(record, baseline: baseline, expected: .row(lock: lock)))
        }
        let clock = ContinuousClock()
        let start = clock.now
        let outcome = try await s.commitItems(items)
        let elapsed = clock.now - start
        print("CatalogCommitRowLockTests: 100 rows with expectations committed in \(elapsed)")
        #expect(outcome.isCommitted, "\(outcome)")
        #expect(outcome.rows.allSatisfy { $0.storedLock != nil })
        #expect(elapsed < .seconds(5), "100 rows took \(elapsed)")
    }
}
