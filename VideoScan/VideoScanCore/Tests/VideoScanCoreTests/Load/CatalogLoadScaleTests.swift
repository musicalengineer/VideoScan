// CatalogLoadScaleTests.swift
// SCALE (cutover B1, catalog_cutover_f_prime §8): 100k healthy rows (one in
// ten starred, one in 25 captioned) plus the poisoned fixture's main shapes,
// imported once, then LOADED — the store read (CatalogLoad.read: one cursor
// over files ⋈ its single-valued tables, digest-ordered side cursors) and
// the record build (`VideoRecord(loaded:)`, what the app's init(row:) wraps)
// — within a load-aware budget. The display pass (a one-time migration) is
// run before the clock starts. The printed line splits read from build.
//
// Suite (filter by SUITE): CatalogLoadScaleTests

import Foundation
import Testing
@testable import VideoScanCore

@Suite("CatalogLoadScale — 100k rows load within a load-aware budget", .serialized)
struct CatalogLoadScaleTests {

    /// 2 s design budget (§8 risk 7) at 15k rows; ×(100/15) for 100k and the
    /// Debug build, rounded to the 5 s the brief names. TimingBudget scales it
    /// with the machine's load.
    static let hundredThousandBudget: Duration = .seconds(5)

    @Test func oneHundredThousandRowsLoadWithinBudget() async throws {
        let rows = 100_000
        let scene = try ImporterScene.make(healthyRows: rows)
        defer { scene.remove() }
        let run = await scene.run()
        _ = try #require(run.outcome.reconciliation, Comment(rawValue: "\(run.outcome)"))
        // The display pass is a one-time migration, not the load: run it first.
        let warm = GRDBCatalogRepository(host: "load-scale", durability: .volatileForTests)
        _ = await warm.open(at: scene.databaseURL)
        _ = try await CatalogLoad.fillDisplayTablesIfEmpty(warm)
        await warm.close()
        let loadBefore = TimingBudget.sampleLoad()
        let clock = ContinuousClock()
        let start = clock.now
        let loaded = try await LoadedCatalog.load(scene)
        let elapsed = clock.now - start
        print("[load-scale] \(loaded.records.count) records from catalog.sqlite: \(elapsed) — store read \(loaded.readDuration), "
              + "records built \(loaded.buildDuration) (\(TimingBudget.loadDescription()))")
        #expect(loaded.records.count == rows + 5)
        #expect(loaded.records[PoisonedCatalogFixture.bulkID(10)]?.starRating == 2)
        #expect(loaded.records[PoisonedCatalogFixture.bulkID(25)]?.sceneCaptions.count == 1)
        expectWithinTimingBudget("100k-row load", measured: elapsed, budget: Self.hundredThousandBudget, loadBefore: loadBefore)
    }
}
