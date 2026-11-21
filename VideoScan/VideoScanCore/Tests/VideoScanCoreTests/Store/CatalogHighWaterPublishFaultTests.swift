// CatalogHighWaterPublishFaultTests.swift
//
// Caller test 1 of the AtomicFilePublish seam: the catalog's commit door.
//
// `catalog.highwater` is raised to g+1 BEFORE the transaction that takes the
// catalog from g to g+1 commits (two-phase rule, F8r3). If that publish
// fails — disk full, I/O error, the rename refused — the commit must NOT
// happen: the write is `.refused` in words that name the file, the database
// still reads g, the sidecar still reads g, no temp is left beside the
// catalog, and the next write (the disk having recovered) commits g+1.
//
// The fault comes through `AtomicFilePublish.$hooks`. `writeBlocking` runs
// the transaction on the calling thread, so the task-local reaches it; each
// test proves that by counting the fault's hits.

import Darwin
import Foundation
import Testing
@testable import VideoScanCore

@Suite("Catalog commit — a failed catalog.highwater publish refuses the commit")
struct CatalogHighWaterPublishFaultTests {

    final class Hits: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func hit() { lock.lock(); n += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    private func openAtFive() async throws -> (StoreFixture, GRDBCatalogRepository) {
        let fixture = try await StoreFixture.make(.grdb, generation: 5)
        let repository = GRDBCatalogRepository(host: "test-host", durability: .volatileForTests)
        let opened = await repository.open(at: fixture.url)
        try #require(opened == .readWrite)
        return (fixture, repository)
    }

    private func temps(_ fixture: StoreFixture) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path)
            .filter(AtomicFilePublish.isTemporaryPublishArtifact)
    }

    @Test("the commit is refused naming the file; generation, sidecar and ledger stay at 5; the next commit lands",
          arguments: [(AtomicFilePublish.Hooks.Step.writeFast, ENOSPC), (.rename, EIO), (.rename, EACCES)])
    func aFailedMarkRefusesTheCommit(step: AtomicFilePublish.Hooks.Step, code: Int32) async throws {
        let (fixture, repository) = try await openAtFive()
        defer { fixture.remove() }
        let ledgerBefore = fixture.highWaterLogText()
        let hits = Hits()

        let outcome = AtomicFilePublish.$hooks.withValue(.failing(step, errno: code, onHit: { hits.hit() })) {
            repository.writeBlocking(as: .ui) { _ in }
        }

        #expect(hits.count == 1, "the fault was never reached — this test proved nothing")
        guard case .refused(let reason) = outcome else {
            Issue.record("expected .refused, got \(outcome)")
            return
        }
        #expect(reason.contains("\(CatalogHighWater.fileName) could not be written"))
        #expect(await repository.generation == 5, "nothing may be reported as committed")
        #expect(fixture.highWaterText() == "5", "the previous mark must stand")
        #expect(fixture.highWaterLogText() == ledgerBefore, "the ledger must not record a mark that was never published")
        #expect(try temps(fixture).isEmpty)

        // The fault is gone: the same session commits, with no reopen needed.
        let retried = repository.writeBlocking(as: .ui) { _ in }
        #expect(retried == .committed(generation: 6))
        #expect(fixture.highWaterText() == "6")
        await repository.close()

        // And a fresh open agrees with all of it (nothing half-written).
        let reopened = GRDBCatalogRepository(host: "test-host", durability: .volatileForTests)
        #expect(await reopened.open(at: fixture.url) == .readWrite)
        #expect(await reopened.generation == 6)
        await reopened.close()
    }

    @Test("CatalogHighWater.write throws the publish's own error and leaves the old mark")
    func theWriterItselfThrows() async throws {
        let (fixture, repository) = try await openAtFive()
        defer { fixture.remove() }
        await repository.close()

        let thrown = #expect(throws: AtomicFilePublish.Failure.self) {
            try AtomicFilePublish.$hooks.withValue(.failing(.fullFsync, errno: EIO)) {
                try CatalogHighWater.write(6, besideDatabaseAt: fixture.url, durability: .fullFsync)
            }
        }

        #expect(thrown?.operation == "F_FULLFSYNC")
        #expect(CatalogHighWater.read(besideDatabaseAt: fixture.url) == .value(5))
        #expect(try temps(fixture).isEmpty)
    }
}
