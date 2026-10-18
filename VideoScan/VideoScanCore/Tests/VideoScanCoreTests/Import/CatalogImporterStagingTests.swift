// CatalogImporterStagingTests.swift
// Codex 2026-10-17 (docs/reviews/codex/codex-review-import-quit-path-hold-drain-2026-10-17.md)
// P1 "force-release is not a rollback or COMMIT fence" — closed BY
// CONSTRUCTION in Core: a commit run writes into a STAGING folder beside the
// target (`catalog.sqlite.importing-<runID>/`, its own database, WAL and
// high-water witnesses) and PUBLISHES onto `catalog.sqlite` only after the
// commit returned, the store closed (WAL folded in) and the staged set
// verified — and only if Stop has not been raised. A COMMIT that completes
// after the app has given up on the run therefore lands in staging, never
// in catalog.sqlite; the next import moves the leftover aside (MOVE, never
// delete) and starts clean.
//
//   LOGIC     — a Stop raised while COMMIT is in flight (the store's
//               before-COMMIT seam, after the importer's last poll): the
//               commit lands in staging, the outcome is `stopped`, the target
//               does not exist; a comparator miss leaves only staging; an
//               existing (even empty) target refuses before anything is
//               written.
//   ISOLATION — poisoned leftovers: a stale staging folder and orphan
//               witnesses (no catalog.sqlite beside them) are moved into ONE
//               dated aside folder, byte-for-byte, and the import proceeds.
//   SENSOR    — the published set: opens `.readWrite`, verifies ok at
//               generation 1, holds every row (the WAL travelled with the
//               database — GRDB's close does not fold it in), both witnesses
//               read 1, no staging folder is left.
// SCALE: CatalogImporterScaleTests (100k) runs the same publish path.
// MEDIA MATRIX: N/A (JSON in, SQLite out).

import Foundation
import Testing
@testable import VideoScanCore

@Suite("CatalogImporter — staging + publish (codex 2026-10-17 P1 fence)", .serialized)
struct CatalogImporterStagingTests {

    private static let stagingPrefix = "catalog.sqlite.importing-"
    private static let asidePrefix = "catalog.sqlite.import-aside-"

    private static func entries(_ folder: URL, prefix: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(prefix) }.sorted()
    }

    private static func importer(_ scene: ImporterScene, beforeCommit: (@Sendable () throws -> Void)? = nil)
        async -> CatalogImporter {
        let repository = GRDBCatalogRepository(host: "import-test", durability: .volatileForTests)
        if let beforeCommit { await repository.injectCrashBeforeCommit(beforeCommit) }
        let sink = scene.sink
        return CatalogImporter(repository: repository) { sink.append($0) }
    }

    // MARK: - LOGIC: the late COMMIT never reaches catalog.sqlite

    @Test("P1: Stop raised while COMMIT is in flight (after the last poll) — the commit lands in staging, the outcome is stopped, catalog.sqlite does not exist")
    func aLateCommitStaysInStaging() async throws {
        let scene = try ImporterScene.make()
        defer { scene.remove() }
        let flag = StopFlag()
        let importer = await Self.importer(scene, beforeCommit: { flag.raise() })
        let outcome = await importer.run(scene.inputs, stopRequested: { flag.isRaised })
        #expect(outcome == .stopped)
        #expect(!FileManager.default.fileExists(atPath: scene.databaseURL.path))
        #expect(try Self.entries(scene.databaseFolder, prefix: Self.stagingPrefix).count == 1)
        #expect(scene.sink.lines.contains { $0.contains("was NOT published") })
    }

    @Test("P1: the next import after a late COMMIT starts clean — the staging folder is moved aside whole and the import publishes")
    func theNextImportAfterALateCommitStartsClean() async throws {
        let scene = try ImporterScene.make()
        defer { scene.remove() }
        let flag = StopFlag()
        let first = await Self.importer(scene, beforeCommit: { flag.raise() })
        _ = await first.run(scene.inputs, stopRequested: { flag.isRaised })
        let staged = try Self.entries(scene.databaseFolder, prefix: Self.stagingPrefix)
        let second = await scene.run()
        #expect(second.outcome.reconciliation != nil, Comment(rawValue: "\(second.outcome)"))
        #expect(FileManager.default.fileExists(atPath: scene.databaseURL.path))
        let aside = try Self.entries(scene.databaseFolder, prefix: Self.asidePrefix)
        #expect(aside.count == 1)
        let moved = scene.databaseFolder.appendingPathComponent(aside.first ?? "?").appendingPathComponent(staged.first ?? "?")
        #expect(FileManager.default.fileExists(atPath: moved.appendingPathComponent("catalog.sqlite").path))
    }

    @Test("a comparator miss rolls back inside staging: catalog.sqlite does not exist")
    func aRolledBackRunLeavesOnlyStaging() async throws {
        let scene = try ImporterScene.make()
        defer { scene.remove() }
        let ordinal = try #require(scene.fixture.ordinals(of: .curatedConflictA).first)
        let run = await scene.run(seam: { side in
            side.knowledgeSources.removeAll { $0.ordinal == ordinal && $0.field == .starRating }
        })
        #expect(run.outcome.misses?.count == 1)
        #expect(!FileManager.default.fileExists(atPath: scene.databaseURL.path))
    }

    @Test("an existing catalog.sqlite — even an empty one — refuses before anything is written; it is left as it was")
    func anExistingEmptyTargetRefuses() async throws {
        let scene = try ImporterScene.make()
        defer { scene.remove() }
        let repository = GRDBCatalogRepository(host: "import-test", durability: .volatileForTests)
        #expect(await repository.open(at: scene.databaseURL) == .readWrite)
        await repository.close()
        let run = await scene.run()
        let words = try #require(run.outcome.failureWords, Comment(rawValue: "\(run.outcome)"))
        #expect(words.hasPrefix("catalog.sqlite already exists"))
        #expect(try Self.entries(scene.databaseFolder, prefix: Self.stagingPrefix).isEmpty)
    }

    // MARK: - ISOLATION: poisoned leftovers

    @Test("a stale staging folder and orphan witnesses (no catalog.sqlite) are MOVED into one dated aside folder, bytes intact, and the import publishes")
    func leftoversAreMovedAsideNotDeleted() async throws {
        let scene = try ImporterScene.make()
        defer { scene.remove() }
        let stale = scene.databaseFolder.appendingPathComponent(Self.stagingPrefix + "STALE", isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: stale.appendingPathComponent("catalog.sqlite"))
        try Data("7\n".utf8).write(to: scene.databaseFolder.appendingPathComponent(CatalogHighWater.fileName))
        try Data("7 2026-10-17T00:00:00Z old\n".utf8).write(to: scene.databaseFolder.appendingPathComponent(CatalogHighWaterLedger.fileName))
        let run = await scene.run()
        #expect(run.outcome.reconciliation != nil, Comment(rawValue: "\(run.outcome)"))
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        let aside = try Self.entries(scene.databaseFolder, prefix: Self.asidePrefix)
        #expect(aside.count == 1)
        let folder = scene.databaseFolder.appendingPathComponent(aside.first ?? "?")
        #expect(try Data(contentsOf: folder.appendingPathComponent(Self.stagingPrefix + "STALE/catalog.sqlite")) == Data("stale".utf8))
        #expect(try Data(contentsOf: folder.appendingPathComponent(CatalogHighWater.fileName)) == Data("7\n".utf8))
        #expect(CatalogHighWater.read(besideDatabaseAt: scene.databaseURL) == .value(1))
    }

    // MARK: - SENSOR: the published set

    @Test("the published set opens read-write and verifies ok at generation 1; both witnesses read 1; no staging folder or WAL is left")
    func thePublishedSetIsWholeAndWritable() async throws {
        let scene = try ImporterScene.make()
        defer { scene.remove() }
        let run = await scene.run()
        #expect(run.outcome.reconciliation != nil, Comment(rawValue: "\(run.outcome)"))
        #expect(try Self.entries(scene.databaseFolder, prefix: Self.stagingPrefix).isEmpty)
        let counts = try await scene.read { try $0.recordCounts() }
        #expect(counts == CatalogRow.TableCounts(files: 5, quarantine: 12, content: 12, importRuns: 1))
        #expect(CatalogHighWater.read(besideDatabaseAt: scene.databaseURL) == .value(1))
        #expect(CatalogHighWaterLedger.read(besideDatabaseAt: scene.databaseURL) == .value(1))
        let repository = GRDBCatalogRepository(host: "import-test-reader", durability: .volatileForTests)
        #expect(await repository.open(at: scene.databaseURL) == .readWrite)
        #expect(await repository.verify() == .ok(generation: 1, highWater: 1))
        await repository.close()
        #expect(scene.sink.lines.contains { $0.hasPrefix("published ") })
    }
}
