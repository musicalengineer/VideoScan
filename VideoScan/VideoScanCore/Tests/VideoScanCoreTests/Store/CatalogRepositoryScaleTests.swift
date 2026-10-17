// CatalogRepositoryScaleTests.swift
// SCALE: 10k and 100k generation advances through the full write path
// (body, CAS, high-water file, history row, commit), load-aware budgeted
// (TimingBudget, GH #208). `.volatileForTests` so the numbers measure the
// store, not the drive's F_FULLFSYNC; a separate small run records the
// real archival cost per commit so Rick knows what a save costs.
//
// Memory: nothing is buffered — each advance is one transaction and one
// 2-byte file publish; the WAL auto-checkpoints every 1000 pages.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("CatalogRepositoryScale", .serialized)   // one measurement at a time
struct CatalogRepositoryScaleTests {

    private func advance(_ count: Int, durability: GRDBCatalogRepository.Durability) async throws
        -> (elapsed: Duration, fixture: StoreFixture, loadBefore: TimingBudget.LoadSample) {
        let fixture = StoreFixture(kind: .grdb, directory: try StoreFixture.temporaryDirectory())
        let repository = GRDBCatalogRepository(host: "scale-host", durability: durability)
        let opened = await repository.open(at: fixture.url)
        try #require(opened == .readWrite)
        let loadBefore = TimingBudget.sampleLoad()
        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0..<count {
            let outcome = await repository.write(as: .ui) { _ in }
            guard case .committed = outcome else {
                throw FixtureFailure(words: "advance failed: \(outcome)")
            }
        }
        let elapsed = clock.now - start
        let generation = await repository.generation
        #expect(generation == count)
        let verdict = await repository.verify()
        #expect(verdict == .ok(generation: count, highWater: count))
        await repository.close()
        return (elapsed, fixture, loadBefore)
    }

    /// Measured 2026-10-17, M4 Max, Debug, serialized, load 15–24 on 16
    /// cores (other agents building): 10k in 4.8 s, 100k in 44.9 s
    /// (~0.45 ms per advance). Budgets ≈ 4× / 3× of that busy run.
    /// The 200 archival commits measured 11.8 ms each on the internal SSD
    /// (FULL + fullfsync + F_FULLFSYNC on the high-water file).
    static let tenThousandBudget: Duration = .seconds(20)
    static let hundredThousandBudget: Duration = .seconds(150)

    @Test func tenThousandAdvances() async throws {
        let run = try await advance(10_000, durability: .volatileForTests)
        defer { run.fixture.remove() }
        print("[store-scale] 10k advances: \(run.elapsed) (\(TimingBudget.loadDescription()))")
        expectWithinTimingBudget("10k generation advances", measured: run.elapsed,
                                 budget: Self.tenThousandBudget, loadBefore: run.loadBefore)
    }

    @Test func hundredThousandAdvances() async throws {
        let run = try await advance(100_000, durability: .volatileForTests)
        defer { run.fixture.remove() }
        print("[store-scale] 100k advances: \(run.elapsed) (\(TimingBudget.loadDescription()))")
        expectWithinTimingBudget("100k generation advances", measured: run.elapsed,
                                 budget: Self.hundredThousandBudget, loadBefore: run.loadBefore)
    }

    /// The real cost: FULL + fullfsync + F_FULLFSYNC on the high-water.
    /// Recorded, not budgeted — it measures the drive.
    @Test func twoHundredArchivalCommitsRecordTheirCost() async throws {
        let run = try await advance(200, durability: .archival)
        defer { run.fixture.remove() }
        let perCommitMs = TimingBudget.seconds(run.elapsed) * 1_000 / 200
        print("[store-scale] 200 archival commits: \(run.elapsed), \(String(format: "%.1f", perCommitMs)) ms per commit (\(TimingBudget.loadDescription()))")
        #expect(run.fixture.highWaterText() == "200")
    }
}
