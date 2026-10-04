// CatalogDistributionOffMainTests.swift
// 2026-10-04 perf: the Storage tab's Catalog pane (`CatalogDistributionPane
// .recompute()`) filtered the dashboard rows on the MAIN thread with
// `!targets.contains { $0.isRetired && row.fullPath.hasPrefix($0.searchPath) }`
// — two @Published getters per record per target (0.79 s in Rick's
// Release trace). The retired prefixes are now read once (O(targets)) and
// the filter runs inside `CatalogDistributionCalculator.compute`, off the
// main actor.
//
//   Logic/Equivalence — `dashboardRows` keeps exactly the rows the old
//               main-actor filter kept (nested, look-alike and empty cases),
//               and the stats from the new Inputs equal the stats from the
//               old pre-filtered Inputs.
//   Scale     — 100k rows, 12 targets (4 retired): the old main-actor
//               filter timed beside the new prefix read; the off-main filter
//               under an explicit budget.
//   Sensor    — `recompute()` no longer filters per record against the
//               targets.
// Isolation: pure functions over constructed rows and targets.
// Media matrix: N/A — no media opened.
//
// Suites: CatalogDistributionOffMainTests

import Foundation
import Testing
@testable import VideoScan

private func row(_ path: String, bytes: Int64 = 1_000) -> VolumeDashboardInput {
    VolumeDashboardInput(fullPath: path, sizeBytes: bytes, isManuallyDeleted: false, ext: "MOV",
                         streamType: .videoAndAudio, bestDate: nil, disposition: .unreviewed,
                         copiesElsewhere: path.count % 3, starRating: 0, isPromotedCopy: false,
                         fixityVerified: false, isArchived: path.count % 2 == 0, isReviewed: false)
}

@MainActor
private func target(_ path: String, retired: Bool) -> CatalogScanTarget {
    let t = CatalogScanTarget(searchPath: path)
    if retired { t.retiredAt = Date(timeIntervalSince1970: 1_790_000_000) }
    return t
}

/// The pre-2026-10-04 filter, verbatim — the reference.
@MainActor
private func oldFilter(_ rows: [VolumeDashboardInput], targets: [CatalogScanTarget]) -> [VolumeDashboardInput] {
    rows.filter { row in !targets.contains { $0.isRetired && row.fullPath.hasPrefix($0.searchPath) } }
}

@Suite("Catalog distribution — dashboard filter off the main actor", .serialized)
@MainActor
struct CatalogDistributionOffMainTests {

    @Test func theRetiredFilterKeepsExactlyWhatTheOldFilterKept() {
        let targets = [target("/Volumes/Old", retired: true), target("/Volumes/OldDrive/sub", retired: true),
                       target("/Volumes/X9", retired: false), target("/Volumes/Old2", retired: false)]
        let rows = ["/Volumes/Old/a.mov", "/Volumes/Old2/b.mov", "/Volumes/OldDrive/c.mov", "/Volumes/OldDrive/sub/d.mov",
                    "/Volumes/X9/e.mov", "/Users/rick/f.mov", "/Volumes/old/g.mov", ""].map { row($0) }
        let prefixes = targets.filter(\.isRetired).map(\.searchPath)
        let kept = CatalogDistributionCalculator.dashboardRows(rows, retiredPrefixes: prefixes)
        #expect(kept == oldFilter(rows, targets: targets))
        // (A bare prefix test — "/Volumes/Old" also drops "/Volumes/Old2/…"
        // and "/Volumes/OldDrive/…" — is the old behaviour, kept as is:
        // this change moves it, never changes it.)
        #expect(kept.map(\.fullPath) == ["/Volumes/X9/e.mov", "/Users/rick/f.mov", "/Volumes/old/g.mov", ""])
        #expect(CatalogDistributionCalculator.dashboardRows(rows, retiredPrefixes: []) == rows)
    }

    @Test func theStatsFromTheNewInputsEqualTheStatsFromTheOldOnes() {
        let targets = [target("/Volumes/Old", retired: true), target("/Volumes/X9", retired: false)]
        let rows = (0..<200).map { row(["/Volumes/Old", "/Volumes/X9", "/Volumes/LaCie"][$0 % 3] + "/clip\($0).mov", bytes: Int64($0 + 1)) }
        let distribution = MediaDistributionCachedInputs(inputs: [], retiredPrefixes: ["/Volumes/Old"],
                                                         reachableVolumes: ["X9"], knownVolumes: ["X9"])
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let old = CatalogDistributionCalculator.compute(.init(distribution: distribution, dashboard: oldFilter(rows, targets: targets),
                                                              tierByDrive: ["X9": .ssd]), now: now)
        let new = CatalogDistributionCalculator.compute(.init(distribution: distribution, dashboard: rows, tierByDrive: ["X9": .ssd],
                                                              dashboardRetiredPrefixes: ["/Volumes/Old"]), now: now)
        #expect(new == old)
        #expect(new.copies.slices.reduce(0) { $0 + $1.files } == 133, "the retired drive's rows are out")
    }

    /// 100k rows, 12 targets (4 retired). Budgets (Release): the new
    /// main-actor step — reading the retired prefixes — under 5 ms; the
    /// off-main filter under 150 ms. The old main-actor filter is timed
    /// and printed beside them.
    @Test func hundredThousandRowsUnderBudget() async {
        let drives = (0..<12).map { "/Volumes/Drive\($0)" }
        let targets = drives.enumerated().map { target($0.element, retired: $0.offset % 3 == 0) }
        let rows = (0..<100_000).map { row("\(drives[$0 % 12])/folder\($0 % 300)/clip\($0).mov") }
        let clock = ContinuousClock()

        var start = clock.now
        let reference = oldFilter(rows, targets: targets)
        let oldMain = clock.now - start

        start = clock.now
        let prefixes = targets.filter(\.isRetired).map(\.searchPath)
        let newMain = clock.now - start

        let (kept, offMain) = await Task.detached(priority: .utility) {
            let s = ContinuousClock.now
            let k = CatalogDistributionCalculator.dashboardRows(rows, retiredPrefixes: prefixes)
            return (k, ContinuousClock.now - s)
        }.value
        print("PERF_SCALE distribution: old main-actor filter \(oldMain); new main-actor prefix read \(newMain); off-main filter \(offMain)")
        #expect(kept == reference)
        #expect(kept.count == 66_666)
        #expect(newMain < .milliseconds(5), "prefix read took \(newMain)")
        #expect(offMain < .milliseconds(150), "off-main filter took \(offMain)")
    }

    @Test func recomputeNoLongerFiltersPerRecordAgainstTheTargets() throws {
        let src = try SourceTree.appSource(named: "CatalogDistributionPane.swift")
        let start = try #require(src.range(of: "private func recompute() {"))
        let body = String(src[start.upperBound...])
        #expect(!body.contains("targets.contains"), "recompute() walks the targets per record again")
        #expect(body.contains("dashboard: VolumeDashboardCalculator.project(records, under: \"/\"),"))
        #expect(body.contains("dashboardRetiredPrefixes: retiredPrefixes)"))
        #expect(src.contains("inputs: dashboardRows(inputs.dashboard, retiredPrefixes: inputs.dashboardRetiredPrefixes)"),
                "compute applies the filter")
    }
}
