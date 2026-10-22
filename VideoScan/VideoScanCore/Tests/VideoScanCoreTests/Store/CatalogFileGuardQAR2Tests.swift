// CatalogFileGuardQAR2Tests.swift — QA round 2 on GH #359 (commit 23715984d).
// RED tests authored by the reviewer.
//
// R2-1: close() after ANY file-stop skips the checkpoint and quarantines the
// session's -wal (GRDBCatalogRepository.swift close(), `quarantineSidecars =
// stop != nil && mode == .readWrite`). That is right when catalog.sqlite at
// the path is ANOTHER file. It is wrong when the database at the path is
// still the session's own inode — a latch-only stop (catalog.cutover removed
// or replaced), or a catalog.sqlite moved away and back: the quarantined -wal
// then holds the LIVE catalog's last commits, and catalog.sqlite at the path
// silently drops back to its last checkpoint.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("QA r2 #359 — quarantine scope", .serialized)
struct CatalogFileGuardQAR2Tests {

    private static func reopenGeneration(_ fixture: StoreFixture) async -> (CatalogOpenOutcome, Int) {
        let reopened = GRDBCatalogRepository(host: "qa-r2", durability: .volatileForTests)
        let outcome = await reopened.open(at: fixture.url)
        let generation = await reopened.generation
        await reopened.close()
        return (outcome, generation)
    }

    @Test("QA r2-1 (#359): catalog.cutover REPLACED mid-session after a commit — catalog.sqlite is untouched, so close must keep its committed generation (no quarantine of the live catalog's -wal)")
    func latchOnlyStopKeepsTheLiveCatalogsCommits() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 2)
        defer { fixture.remove() }
        let latch = fixture.directory.appendingPathComponent(SQLiteCatalogReader.latchFileName)
        try Data("switched\n".utf8).write(to: latch)
        let repository = GRDBCatalogRepository(host: "qa-r2", durability: .volatileForTests)
        try #require(await repository.open(at: fixture.url, requiringLatch: true) == .readWrite)
        try #require(await repository.write(as: .ui) { _ in } == .committed(generation: 3))
        try FileManager.default.removeItem(at: latch)
        try Data("switched\n".utf8).write(to: latch)                           // same name, new inode
        _ = await repository.write(as: .ui) { _ in }                           // the stop
        await repository.close()
        let quarantined = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path)
            .filter { $0.hasPrefix("catalog-wal-quarantine-") }
        let (outcome, generation) = await Self.reopenGeneration(fixture)
        print("[qa-r2 #359] latch-only stop: quarantine dirs \(quarantined); reopened \(outcome), generation \(generation)")
        #expect(quarantined.isEmpty, "the live catalog's -wal was quarantined although catalog.sqlite never moved")
        #expect(generation == 3, "catalog.sqlite lost generation 3, committed before the stop: \(outcome)")
    }

    @Test("QA r2-1b (#359): catalog.sqlite moved away and BACK (same inode) after a commit — close must keep generation 3 in the file at the path")
    func movedAwayAndBackKeepsItsCommits() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 2)
        defer { fixture.remove() }
        let repository = GRDBCatalogRepository(host: "qa-r2", durability: .volatileForTests)
        try #require(await repository.open(at: fixture.url) == .readWrite)
        try #require(await repository.write(as: .ui) { _ in } == .committed(generation: 3))
        let aside = fixture.directory.appendingPathComponent("moved-aside.sqlite")
        try FileManager.default.moveItem(at: fixture.url, to: aside)
        _ = await repository.write(as: .ui) { _ in }                           // the stop (sticky)
        try FileManager.default.moveItem(at: aside, to: fixture.url)
        await repository.close()
        let (outcome, generation) = await Self.reopenGeneration(fixture)
        print("[qa-r2 #359] moved away and back: reopened \(outcome), generation \(generation)")
        #expect(generation == 3, "catalog.sqlite lost generation 3: \(outcome)")
    }
}
