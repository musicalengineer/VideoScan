// CatalogCodex143FailedReadBackTests.swift
// Codex closing pass on #141 F2, finding 1 (docs/reviews/codex/
// codex-review-committer-lost-writes-2026-10-25.md): a failed read on
// Reopen made the committer writable again — `reopen` advanced the
// generation and scheduled the stale retry, and a failed generation read
// substituted the old generation. The promise (CatalogCommitter.swift
// header): a failed read-back keeps saving BLOCKED, with words; the next
// Reopen that can read holds and names the row.
//
// Red/green (Debug, M4 Max):
//   failedReadBackStaysBlocked   RED by construction on 549a9b798 (no read-back; `generationNow()`
//                                swallowed the error — Codex #1) and RED by mutation here (readBack's
//                                catch returning `.checked`: blockedReason nil, retry overwrote B)  → GREEN
//
// Dimensions: ISOLATION (an injected read failure through a repository
// decorator; CutoverScene sandbox, never Application Support); TRUTH (the
// store keeps the other writer's decision through the failure and after
// the recovery); LOGIC (blocked → read again → held). MEDIA / SCALE /
// SENSOR N/A.
//
// Suites (filter by SUITE): CatalogReopenFailedReadBackTests

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

/// A repository whose `read` fails on request; everything else is the real
/// GRDB store underneath. (For Rick: a decorator with one fault switch.)
final class FlakyReadRepository: CatalogRepository, @unchecked Sendable {
    private let inner: GRDBCatalogRepository
    private let lock = NSLock()
    private var failing = false

    init(_ inner: GRDBCatalogRepository) { self.inner = inner }

    var failReads: Bool {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }

    struct Injected: Error, CustomStringConvertible {
        var description: String { "injected read failure" }
    }

    func open(at url: URL) async -> CatalogOpenOutcome { await inner.open(at: url) }
    func open(at url: URL, requiringLatch: Bool) async -> CatalogOpenOutcome { await inner.open(at: url, requiringLatch: requiringLatch) }
    var generation: Int { get async { await inner.generation } }
    func write(as door: CatalogWriter, _ body: @Sendable (any CatalogTransaction) throws -> Void) async -> CatalogWriteOutcome {
        await inner.write(as: door, body)
    }
    func writeBlocking(as door: CatalogWriter, _ body: (any CatalogTransaction) throws -> Void) -> CatalogWriteOutcome {
        inner.writeBlocking(as: door, body)
    }
    func read<T: Sendable>(_ body: @Sendable (any CatalogReader) throws -> T) async throws -> T {
        if failReads { throw Injected() }
        return try await inner.read(body)
    }
    func verify() async -> CatalogVerifyOutcome { await inner.verify() }
    func adopt(toHighWater highWater: Int) async -> CatalogAdoptOutcome { await inner.adopt(toHighWater: highWater) }
    func close() async { await inner.close() }
    func sealedCopyBlocking(to target: URL) -> String? { inner.sealedCopyBlocking(to: target) }
    var fileStopWords: String? { inner.fileStopWords }
    var lastCloseNotes: [String] { inner.lastCloseNotes }
    func quarantineAfterTimedOutClose() -> CatalogTimedOutClose { inner.quarantineAfterTimedOutClose() }
}

/// The lines a committer under test says (its one sink).
@MainActor
final class SinkLog {
    var lines: [String] = []
    var text: String { lines.joined(separator: "\n") }
}

@Suite("Catalog Reopen — a failed read-back keeps saving blocked (codex #143 F1)", .serialized)
@MainActor
struct CatalogReopenFailedReadBackTests {

    @Test("the read fails: blocked with words, nothing written; the read works again: the row is held and named, the other writer's decision survives throughout")
    func failedReadBackStaysBlocked() async throws {
        let scene = try CutoverScene.make("codex143_flaky")
        defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        try #require(try scene.committer().commitNow(), "the launch commit lands")

        // A second committer over the same records, through a repository whose reads can fail.
        let flaky = FlakyReadRepository(GRDBCatalogRepository(host: "flaky-session"))
        guard case .readWrite = await flaky.open(at: scene.databaseURL, requiringLatch: true) else {
            Issue.record("the flaky repository did not open read-write"); return
        }
        let loaded = try await SQLiteCatalogLoader.load(repository: flaky)
        let log = SinkLog()
        let committer = CatalogCommitter(repository: flaky, storedDesignationJSON: nil,
                                         input: { CatalogCommitter.Input(records: scene.model.records, designation: nil, clearAuthorized: false,
                                                                         holdReason: nil, holdOwner: nil) },
                                         sink: { log.lines.append($0) })
        committer.adoptBaseline(scene.model.records, held: [], generation: loaded.generation, locks: loaded.locks)

        let a = try scene.record(.healthy)
        let other = try scene.record(.stalePrint)
        try await scene.otherWriterDecides(rowOf: a, about: other.id)
        a.userNotes = "A's note"
        #expect(committer.commitNow() == false, "the generation check refuses")
        #expect(committer.blockedReason?.contains("another writer") == true, "the CAS or the door refuses: \(committer.blockedReason ?? "nil")")

        flaky.failReads = true
        await committer.reopen(at: scene.databaseURL)
        let blocked = try #require(committer.blockedReason, "a failed read-back keeps the committer blocked")
        #expect(blocked.contains("could not be compared"), Comment(rawValue: blocked))
        #expect(blocked.contains("relaunch"), Comment(rawValue: blocked))
        #expect(log.text.contains("REFUSED Reopen's read-back"), Comment(rawValue: log.text))
        #expect(committer.commitNow() == false, "nothing may be written while blocked")
        let during = try await scene.reloaded(.healthy)
        #expect(during.footageDecisions.map(\.otherID) == [other.id], "B's decision survives the failed read-back")
        #expect(during.userNotes != "A's note")

        flaky.failReads = false
        await committer.reopen(at: scene.databaseURL)
        #expect(committer.blockedReason == nil, "a read-back that could read lifts the block")
        #expect(log.text.contains("HELD \(a.id.uuidString)"), "the row is held and named: \(log.text)")
        #expect(committer.commitNow() == false, "the held row is not saved")
        let back = try await scene.reloaded(.healthy)
        #expect(back.footageDecisions.map(\.otherID) == [other.id])
        #expect(back.userNotes != "A's note")
        await flaky.close()
    }
}
