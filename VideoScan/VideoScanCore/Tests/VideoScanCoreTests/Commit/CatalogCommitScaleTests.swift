// CatalogCommitScaleTests.swift
// The change detector and the one-row commit at catalog scale (cutover B2):
// detection over a 14k-row catalog < 150 ms (Debug, load-aware) and a
// one-row commit into it < 150 ms — the gate; the same at 100k, and the
// worst case (14k "rich" rows, every one of the 129 keys set, captions and a
// report card each), RECORDED with a budget that only catches a collapse.
// Measured 2026-10-17 (M4, Debug): 14k rows 45 ms + 25 ms; 100k 330 ms +
// 130 ms; 14k rich 158 ms alone, ~500 ms while the whole Core suite runs
// beside it (the detector uses every core, and so do the other suites).
//
// Suite (filter by SUITE): CatalogCommitScaleTests

import Foundation
import Testing
@testable import VideoScanCore

@Suite("CatalogCommitScale — detection and a one-row commit at 14k and 100k rows", .serialized)
struct CatalogCommitScaleTests {

    static let detectionBudget: Duration = .milliseconds(150)
    static let oneRowCommitBudget: Duration = .milliseconds(150)
    /// The worst case is recorded; ×6 the gate only catches a collapse.
    static let worstCaseBudget: Duration = .milliseconds(900)
    /// 100k is recorded; the budget only catches a collapse (×10 the rows).
    static let hundredThousandBudget: Duration = .seconds(2)

    /// Snapshot (what the app does on the main actor) + fingerprints.
    private static func detect(_ records: [VideoRecord]) -> (Duration, Int) {
        let clock = ContinuousClock()
        let start = clock.now
        let prints = CatalogChangeDetector.fingerprints(of: records.map(VideoRecordDTO.init))
        return (clock.now - start, prints.count)
    }

    @Test("14k rich records (every key set): detection recorded (worst case; budget catches a collapse)")
    func richDetection() {
        let other = UUID()
        let records = (0..<14_000).map { i in
            RichRecord.make(id: UUID(), path: "/Volumes/F/c\(i).mov", digest: String(repeating: "a", count: 64),
                            sizeBytes: 4_096, pairWith: other, otherRow: other)
        }
        _ = Self.detect(Array(records.prefix(500)))   // warm the code paths
        let load = TimingBudget.sampleLoad()
        let (elapsed, count) = Self.detect(records)
        print("[commit-scale] detection, 14k rich records: \(elapsed) (\(TimingBudget.loadDescription()))")
        #expect(count == 14_000)
        expectWithinTimingBudget("14k rich detection", measured: elapsed, budget: Self.worstCaseBudget, loadBefore: load)
    }

    @Test("a 14k-row catalog.sqlite: detection and a one-row commit, each within 150 ms")
    func fourteenThousand() async throws {
        try await Self.oneRow(rows: 14_000, detectionBudget: Self.detectionBudget, commitBudget: Self.oneRowCommitBudget)
    }

    @Test("a 100k-row catalog.sqlite: detection and a one-row commit (recorded)")
    func hundredThousand() async throws {
        try await Self.oneRow(rows: 100_000, detectionBudget: Self.hundredThousandBudget, commitBudget: Self.hundredThousandBudget)
    }

    // MARK: - B2.2: the committer's whole synchronous turn

    /// The main actor is blocked for the whole commit (cutover B2.2):
    /// snapshot → fingerprints → changed rows → ONE blocking write, archival
    /// durability (the production fsync). 1 changed row < 150 ms; 1,000
    /// changed rows < 1.5 s — 14k rows, Debug, load-aware.
    static let syncOneRowBudget: Duration = .milliseconds(150)
    static let syncThousandRowsBudget: Duration = .milliseconds(1_500)

    @Test("B2.2: a synchronous commit of 1 changed row in a 14k-row catalog.sqlite (detection included) < 150 ms")
    func syncCommitOneRow() async throws {
        try await Self.syncCommit(rows: 14_000, changed: 1, budget: Self.syncOneRowBudget)
    }

    @Test("B2.2: a synchronous commit of 1,000 changed rows in a 14k-row catalog.sqlite (detection included) < 1.5 s")
    func syncCommitThousandRows() async throws {
        try await Self.syncCommit(rows: 14_000, changed: 1_000, budget: Self.syncThousandRowsBudget)
    }

    private static func syncCommit(rows: Int, changed: Int, budget: Duration) async throws {
        let s = try await CommitScene.make(healthyRows: rows); defer { s.remove() }
        let loaded = try await s.load()
        let records = Array(loaded.records.values)
        let baseline = Dictionary(uniqueKeysWithValues: zip(records.map(\.id),
                                                            CatalogChangeDetector.fingerprints(of: records.map(VideoRecordDTO.init))))
        let step = rows / changed
        for index in 0..<changed {
            let target = try #require(loaded.records[PoisonedCatalogFixture.bulkID(index * step)])
            target.starRating = 2
            target.userNotes = "sync \(index)"
        }
        let repository = GRDBCatalogRepository(host: "commit-scale", durability: .archival)
        _ = await repository.open(at: s.scene.databaseURL)
        let load = TimingBudget.sampleLoad()
        let clock = ContinuousClock()
        let start = clock.now
        let snapshots = records.map(VideoRecordDTO.init)
        let prints = CatalogChangeDetector.fingerprints(of: snapshots)
        let dirty = CatalogChangeDetector.changed(records.map(\.id), fingerprints: prints, baseline: baseline)
        let items = dirty.map { CatalogCommit.Item(id: records[$0].id, snapshot: snapshots[$0], fingerprint: prints[$0]) }
        let outcome = CatalogCommit.runBlocking(CatalogCommit.Plan(door: .save, items: items), on: repository)
        let elapsed = clock.now - start
        await repository.close()
        print("[commit-scale] B2.2 sync commit, \(rows) rows, \(changed) changed: \(elapsed) (\(TimingBudget.loadDescription()))")
        #expect(items.count == changed)
        #expect(outcome.isCommitted)
        expectWithinTimingBudget("\(rows)-row sync commit of \(changed)", measured: elapsed, budget: budget, loadBefore: load)
    }

    private static func oneRow(rows: Int, detectionBudget: Duration, commitBudget: Duration) async throws {
        let s = try await CommitScene.make(healthyRows: rows); defer { s.remove() }
        let loaded = try await s.load()
        let records = Array(loaded.records.values)
        _ = detect(Array(records.prefix(500)))
        let detectLoad = TimingBudget.sampleLoad()
        let (detection, _) = detect(records)
        let target = try #require(loaded.records[PoisonedCatalogFixture.bulkID(rows / 2)])
        target.starRating = 3
        target.userNotes = "scale"
        let repository = GRDBCatalogRepository(host: "commit-scale", durability: .volatileForTests)
        _ = await repository.open(at: s.scene.databaseURL)
        let commitLoad = TimingBudget.sampleLoad()
        let clock = ContinuousClock()
        let start = clock.now
        let outcome = await CatalogCommit.run(CatalogCommit.Plan(door: .save, items: [CommitScene.item(target)]), on: repository)
        let commit = clock.now - start
        await repository.close()
        print("[commit-scale] \(records.count) rows: detection \(detection), one-row commit \(commit) (\(TimingBudget.loadDescription()))")
        #expect(outcome.isCommitted)
        expectWithinTimingBudget("\(rows) detection", measured: detection, budget: detectionBudget, loadBefore: detectLoad)
        expectWithinTimingBudget("\(rows) one-row commit", measured: commit, budget: commitBudget, loadBefore: commitLoad)
    }
}
