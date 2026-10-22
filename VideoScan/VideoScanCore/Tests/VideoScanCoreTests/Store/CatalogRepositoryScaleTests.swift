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
        // GH #359: a latch beside, so every advance runs the full file check
        // (database + latch identity, three times per commit).
        try Data("switched\n".utf8).write(to: fixture.directory.appendingPathComponent(SQLiteCatalogReader.latchFileName))
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

    /// GH #359 SENSOR: the identity check a commit pays — three checks of
    /// two files (database + latch), six `stat` calls — for 100k commits.
    /// Rick's bar: well under 1 ms a commit; the budget is 0.1 ms (100k in
    /// 10 s, load-aware). Measured 2026-10-21, M4 Max, Debug: see the
    /// printed line (a few µs per commit).
    static let hundredThousandChecksBudget: Duration = .seconds(10)

    @Test("100k commits' worth of file-identity checks (GH #359) cost well under 1 ms a commit; none is a false refusal")
    func hundredThousandCommitsOfIdentityChecks() throws {
        let fixture = StoreFixture(kind: .grdb, directory: try StoreFixture.temporaryDirectory())
        defer { fixture.remove() }
        try Data("db".utf8).write(to: fixture.url)
        try Data("switched\n".utf8).write(to: fixture.directory.appendingPathComponent(SQLiteCatalogReader.latchFileName))
        let fileGuard = try CatalogFileGuard.record(databaseAt: fixture.url)
        #expect(fileGuard.latch != nil, "the latch is watched")
        let loadBefore = TimingBudget.sampleLoad()
        let clock = ContinuousClock()
        let start = clock.now
        var refusals = 0
        for _ in 0..<100_000 {
            for _ in 0..<3 where fileGuard.violation() != nil { refusals += 1 }
        }
        let elapsed = clock.now - start
        let perCommitMicroseconds = TimingBudget.seconds(elapsed) * 1_000_000 / 100_000
        print("[store-scale] 100k commits of identity checks: \(elapsed), \(String(format: "%.1f", perCommitMicroseconds)) µs per commit (\(TimingBudget.loadDescription()))")
        #expect(refusals == 0)
        expectWithinTimingBudget("100k commits of file-identity checks", measured: elapsed,
                                 budget: Self.hundredThousandChecksBudget, loadBefore: loadBefore)
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
