// ConfirmedDateFilterScaleTests.swift
// SCALE for the "Confirmed date" Show filter (its logic / truth / isolation /
// sensor live in ConfirmedDateFilterTests.swift): 100k records through
// pfRecordHasConfirmedDate inside the Catalog's filter budget, judged by
// TimingBudget (strict only on the pinned nightly; a miss up to 3× is a known
// issue elsewhere — DECISIONS 2026-10-31). Its own file because a test file
// maps to exactly one gauntlet stage and this one is `performance`.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

// MARK: - SCALE

@Suite("Confirmed date filter at 100k", .tags(.scale), .serialized)
struct ConfirmedDateFilterScaleTests {

    @Test("SCALE: 100k records through the predicate inside the Catalog's filter budget")
    func predicateOver100kStaysInBudget() {
        // Worst case memory: 100k VideoRecord objects (~1 KB each) ≈ 100 MB, freed at return.
        var recs: [VideoRecord] = []
        recs.reserveCapacity(100_000)
        for i in 0..<100_000 {
            let r = VideoRecord()
            r.filename = "v\(i).mov"
            r.fullPath = "/Volumes/T/v\(i).mov"
            r.directory = "/Volumes/T"
            if i % 10 == 7 { r.userDate = "1992-06-14"; r.userDateConfidence = i % 20 == 7 ? "known" : "estimated" }
            recs.append(r)
        }
        let load = TimingBudget.sampleLoad()
        let clock = ContinuousClock()
        var kept = 0
        let measured = clock.measure { kept = recs.filter(pfRecordHasConfirmedDate).count }
        #expect(kept == 10_000)
        // Same ceiling as the archived-hits split in the same filter pass.
        expectWithinTimingBudget("confirmed-date filter over 100k records", measured: measured,
                                 budget: PerformanceLane.debugCeiling(.milliseconds(500)), loadBefore: load)
    }
}
