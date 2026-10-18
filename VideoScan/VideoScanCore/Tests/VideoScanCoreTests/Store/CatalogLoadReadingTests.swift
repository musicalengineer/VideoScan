// CatalogLoadReadingTests.swift
// The store's load readings (cutover B1) where they need the engine itself:
//   * bound beats unverified — a derived kind written to its bound table
//     (as a cycler will after cutover) is what the row loads, and the row's
//     own imported value of that kind is no longer counted as unverified;
//   * ISOLATION (poisoned state): a store that opens READ-ONLY (a restore
//     below the high-water mark) cannot take the display pass, and the load
//     REFUSES with the store's words instead of showing a catalog with every
//     curated value missing;
//   * the load writes nothing else: after a load whose display pass already
//     ran, the generation is unchanged.
//
// Suite (filter by SUITE): CatalogLoadReadingTests

import Foundation
import GRDB
import Testing
@testable import VideoScanCore

@Suite("CatalogLoadReading — bound beats unverified; a read-only store refuses the load", .serialized)
struct CatalogLoadReadingTests {

    private static func importedScene(bulk: Int = 1) async throws -> ImporterScene {
        let scene = try ImporterScene.make(healthyRows: bulk)
        let run = await scene.run()
        _ = try #require(run.outcome.reconciliation, Comment(rawValue: "\(run.outcome)"))
        return scene
    }

    private static func row(_ loaded: LoadedCatalog, _ id: String) throws -> CatalogLoadedRow {
        try #require(loaded.snapshot.rows.first { $0.file.id == id })
    }

    @Test("without a bound value the row loads its own imported caption, counted as unverified")
    func unverifiedWhenNothingIsBound() async throws {
        let scene = try await Self.importedScene(); defer { scene.remove() }
        let loaded = try await LoadedCatalog.load(scene)
        let id = PoisonedCatalogFixture.bulkID(0)
        #expect(loaded.records[id]?.sceneCaptions.map(\.text) == ["bulk caption 0"])
        #expect(try Self.row(loaded, id).unverifiedDerived == 1)
    }

    @Test("a bound caption for the digest replaces the imported one and is not counted as unverified")
    func boundBeatsUnverified() async throws {
        let scene = try await Self.importedScene(); defer { scene.remove() }
        let repository = GRDBCatalogRepository(host: "bound", durability: .volatileForTests)
        _ = await repository.open(at: scene.databaseURL)
        let digest = PoisonedCatalogFixture.digest("bulk-0")
        let outcome = await repository.write(as: .ui) { tx in
            let db = try #require(tx as? GRDBTransaction).db
            try db.execute(sql: "INSERT INTO captions (digest, kind, seq, at_s, text) VALUES (?, 'scene', 0, 9.5, 'a bound caption')",
                           arguments: [digest])
            try db.execute(sql: "INSERT INTO caption_runs (digest, model, made_at) VALUES (?, 'vlm-2', 1790000000)", arguments: [digest])
        }
        await repository.close()
        guard case .committed = outcome else { Issue.record("\(outcome)"); return }
        let loaded = try await LoadedCatalog.load(scene)
        let id = PoisonedCatalogFixture.bulkID(0)
        let record = try #require(loaded.records[id])
        #expect(record.sceneCaptions.map(\.text) == ["a bound caption"])
        #expect(record.sceneCaptions.first?.timestamp == 9.5)
        #expect(record.sceneCaptionModel == "vlm-2")
        #expect(try Self.row(loaded, id).unverifiedDerived == 0)
    }

    @Test("ISOLATION: a store restored below its high-water opens read-only; the display pass cannot run; the load refuses with words")
    func readOnlyStoreRefusesTheLoad() async throws {
        let scene = try await Self.importedScene(); defer { scene.remove() }
        try CatalogHighWater.write(999, besideDatabaseAt: scene.databaseURL, durability: .fast)
        let repository = GRDBCatalogRepository(host: "readonly", durability: .volatileForTests)
        let opened = await repository.open(at: scene.databaseURL)
        guard case .readOnly(let reason) = opened else { Issue.record("expected read-only, got \(opened)"); await repository.close(); return }
        #expect(reason.contains("restoredBelowHighWater"))
        do {
            _ = try await CatalogLoad.read(repository)
            Issue.record("the load must refuse")
        } catch let failure as CatalogLoad.Failure {
            #expect(failure.words.contains("could not be prepared for display"), Comment(rawValue: failure.words))
            #expect(failure.words.contains("read-only"), Comment(rawValue: failure.words))
        }
        await repository.close()
    }

    @Test("a load after the display pass writes nothing: the generation is unchanged")
    func aLoadWritesNothing() async throws {
        let scene = try await Self.importedScene(); defer { scene.remove() }
        let first = try await LoadedCatalog.load(scene)
        let second = try await LoadedCatalog.load(scene)
        #expect(second.snapshot.generation == first.snapshot.generation)
        #expect(second.snapshot.displayPass == .alreadyFilled)
        #expect(second.records.count == first.records.count)
    }
}
