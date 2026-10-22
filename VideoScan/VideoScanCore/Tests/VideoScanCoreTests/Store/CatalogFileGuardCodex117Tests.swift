// CatalogFileGuardCodex117Tests.swift — codex cycle #117 on GH #359 (bf48fc7dc).
// Findings 1 and 2 (close()); 3 and 4 are app-level (CatalogAuthorityCornerTests).
//
//   1. close() treated an UNREADABLE identity (stat → EIO) as "moved" and
//      quarantined the live catalog's -wal. An indeterminate identity must
//      never authorize moving sidecars: no checkpoint, no quarantine, the
//      -wal stays at the path, and the words say nothing was moved.
//   2. close() decided "moved or not" BEFORE waiting for the writer queue;
//      a swap during that wait left this session's -wal for the replacement.
//      The decision is re-read after the queue drains.
//
// Seam: CatalogFileIdentity.TestOverride, keyed by one exact path.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("Codex #117 (#359) — close decides on a confirmed identity, after the writer drains", .serialized)
struct CatalogFileGuardCodex117Tests {

    static func quarantineFolders(_ folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("catalog-wal-quarantine-") }
    }

    @Test("codex #117 F1: stat of catalog.sqlite fails (EIO) at close — nothing is moved, the -wal stays, the words say the identity could not be read; the reopen keeps generation 3")
    func unreadableIdentityNeverMovesTheWAL() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 2)
        defer { fixture.remove() }
        let repository = GRDBCatalogRepository(host: "codex-117", durability: .volatileForTests)
        try #require(await repository.open(at: fixture.url) == .readWrite)
        try #require(await repository.write(as: .ui) { _ in } == .committed(generation: 3))
        let wal = URL(fileURLWithPath: fixture.url.path + "-wal")
        let walBefore = try CatalogOpenCornerTests.sha256(wal)
        CatalogFileIdentity.TestOverride.set(.unreadable(errno: EIO), for: fixture.url.path)
        await repository.close()
        CatalogFileIdentity.TestOverride.set(nil, for: fixture.url.path)
        let notes = repository.lastCloseNotes
        print("[codex-117 F1] notes: \(notes)")
        #expect(try Self.quarantineFolders(fixture.directory).isEmpty, "an unreadable identity moved the live catalog's -wal")
        #expect(try CatalogOpenCornerTests.sha256(wal) == walBefore, "the live -wal changed or moved")
        #expect(notes.contains { $0.contains("could not be read") && $0.contains("nothing was moved") }, "\(notes)")
        let reopened = GRDBCatalogRepository(host: "codex-117", durability: .volatileForTests)
        _ = await reopened.open(at: fixture.url)
        let generation = await reopened.generation
        await reopened.close()
        #expect(generation == 3, "the live catalog lost generation 3")
    }

    @Test("codex #117 F2: catalog.sqlite replaced WHILE close waits for the writer — the decision is made after the wait: the session's -wal is quarantined and the replacement keeps its own generation",
          .timeLimit(.minutes(1)))
    func swapDuringTheWriterWaitIsSeen() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 2)
        defer { fixture.remove() }
        let repository = GRDBCatalogRepository(host: "codex-117", durability: .volatileForTests)
        try #require(await repository.open(at: fixture.url) == .readWrite)
        let replacement = fixture.directory.appendingPathComponent("replacement.sqlite")
        #expect(repository.sealedCopyBlocking(to: replacement) == nil)         // generation 2
        try #require(await repository.write(as: .ui) { _ in } == .committed(generation: 3))
        let wal = URL(fileURLWithPath: fixture.url.path + "-wal")

        // A write that holds the writer queue for 1.5 s (its body sleeps).
        let busy = Task { await repository.write(as: .ui) { _ in Thread.sleep(forTimeInterval: 1.5) } }
        try await Task.sleep(nanoseconds: 200_000_000)
        let closing = Task { await repository.close() }                        // enters, then waits for the writer
        try await Task.sleep(nanoseconds: 300_000_000)
        try FileManager.default.moveItem(at: fixture.url, to: fixture.directory.appendingPathComponent("moved-aside.sqlite"))
        try FileManager.default.moveItem(at: replacement, to: fixture.url)    // the swap, during the wait
        let busyOutcome = await busy.value
        await closing.value
        print("[codex-117 F2] busy write: \(busyOutcome); notes: \(repository.lastCloseNotes)")

        #expect(!busyOutcome.isCommitted, "the write in flight committed after the swap")
        #expect(!FileManager.default.fileExists(atPath: wal.path), "the session's -wal was left beside the replacement")
        #expect(try Self.quarantineFolders(fixture.directory).count == 1)
        let reopened = GRDBCatalogRepository(host: "codex-117", durability: .volatileForTests)
        _ = await reopened.open(at: fixture.url)
        let generation = await reopened.generation
        await reopened.close()
        #expect(generation == 2, "the replacement took the old session's frames: generation \(generation)")
    }
}
