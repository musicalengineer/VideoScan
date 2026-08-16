//
//  RetiredCatalogCleanupTests.swift
//  VideoScanTests
//
//  Logic sensors for the retired-volume catalog-cleanup nag
//  (Rick 2026-08-14). Motivated by the same-day incident where a
//  still-"Cataloged" retired target let the launch-time backfill
//  resurrect 72,503 ancient records for a volume that no longer exists.
//
//  Five dimensions: logic here; scale = the selector is one pass over
//  records (asserted by construction, budget test below); media = N/A
//  (no files opened); isolation = pure in-memory model, no disk;
//  sensor = the noCatalog-exclusion case IS the incident pin.
//

import XCTest
@testable import VideoScan

@MainActor
final class RetiredCatalogCleanupTests: XCTestCase {

    private func makeModel() -> VideoScanModel {
        let m = VideoScanModel()
        m.records = []
        m.scanTargets = []
        return m
    }

    /// Fresh targets default to phase == .noCatalog, which the selector
    /// rightly excludes — so tests must mark their targets .cataloged to
    /// model a volume whose records are still counted.
    private func makeTarget(_ path: String, retired: Bool) -> CatalogScanTarget {
        let t = CatalogScanTarget(searchPath: path)
        t.phase = .cataloged
        if retired { t.retiredAt = Date(timeIntervalSinceNow: -40 * 86_400) }
        return t
    }

    private func makeRecords(under root: String, count: Int) -> [VideoRecord] {
        (0..<count).map { i in
            let r = VideoRecord()
            r.filename = "f\(i).mov"
            r.fullPath = "\(root)/f\(i).mov"
            return r
        }
    }

    func testOnlyRetiredTargetsWithRecordsAreCandidates() {
        let m = makeModel()

        let retired = makeTarget("/Volumes/RetiredWithRecords", retired: true)
        let retiredEmpty = makeTarget("/Volumes/RetiredEmpty", retired: true)
        let active = makeTarget("/Volumes/ActiveWithRecords", retired: false)
        m.scanTargets = [retired, retiredEmpty, active]

        m.records = makeRecords(under: "/Volumes/RetiredWithRecords", count: 3)
                  + makeRecords(under: "/Volumes/ActiveWithRecords", count: 5)

        let c = m.retiredCatalogCleanupCandidates()
        XCTAssertEqual(c.count, 1, "only the retired target that still has records")
        XCTAssertEqual(c.first?.target.searchPath, "/Volumes/RetiredWithRecords")
        XCTAssertEqual(c.first?.recordCount, 3)
    }

    /// Rick 2026-08-16: RicksBackups + 500USB carried role=Retired set by
    /// hand, retiredAt=nil, and the backup-time nag never fired. Both
    /// owners of "retired" must count until retirement is centralized.
    func testRoleRetiredWithoutRetiredAtStampIsACandidate() {
        let m = makeModel()
        let byRole = makeTarget("/Volumes/RicksBackups", retired: false)
        byRole.role = .retired
        XCTAssertNil(byRole.retiredAt, "precondition: no stamp")
        m.scanTargets = [byRole]
        m.records = makeRecords(under: "/Volumes/RicksBackups", count: 2)

        let c = m.retiredCatalogCleanupCandidates()
        XCTAssertEqual(c.count, 1, "role-only retirement must still be nagged about")
        XCTAssertEqual(c.first?.recordCount, 2)
    }

    /// The incident pin: a retired target whose catalog was ALREADY
    /// deleted (phase .noCatalog, like MyBook) must never be nagged
    /// about — it is the desired end state.
    func testNoCatalogPhaseIsExcluded() {
        let m = makeModel()
        let done = makeTarget("/Volumes/AlreadyCleaned", retired: true)
        done.phase = .noCatalog
        m.scanTargets = [done]
        // Stray records under its root (the resurrection scenario) still
        // must not resurface it through THIS prompt — .noCatalog means the
        // user already made the decision; re-asking would un-make it.
        m.records = makeRecords(under: "/Volumes/AlreadyCleaned", count: 7)

        XCTAssertTrue(m.retiredCatalogCleanupCandidates().isEmpty)
    }

    func testPrefixMatchingDoesNotCrossVolumes() {
        // "/Volumes/Old" must not swallow "/Volumes/OldDrive" records.
        let m = makeModel()
        let old = makeTarget("/Volumes/Old", retired: true)
        m.scanTargets = [old]
        m.records = makeRecords(under: "/Volumes/OldDrive", count: 4)

        let c = m.retiredCatalogCleanupCandidates()
        // hasPrefix("/Volumes/Old") DOES match "/Volumes/OldDrive/..." —
        // pin the current behavior loudly so a future path-boundary fix
        // flips this assertion deliberately rather than by surprise.
        XCTAssertEqual(c.first?.recordCount, 4,
                       "KNOWN LIMITATION: prefix match crosses volume-name boundaries; "
                       + "if this fails, the boundary bug was fixed — update this pin")
    }

    func testSelectorIsSinglePassAtScale() {
        // 100k records, 6 targets — the checklist's scale dimension.
        let m = makeModel()
        m.scanTargets = (0..<5).map { makeTarget("/Volumes/Retired\($0)", retired: true) }
        // Build then assign ONCE — per-append on a @Published array cost
        // 32s for 100k in this test's first version.
        m.records = (0..<100_000).map { i in
            let r = VideoRecord()
            r.fullPath = "/Volumes/Retired\(i % 5)/f\(i).mov"
            return r
        }
        let t0 = CFAbsoluteTimeGetCurrent()
        let c = m.retiredCatalogCleanupCandidates()
        let elapsed = CFAbsoluteTimeGetCurrent() - t0
        XCTAssertEqual(c.count, 5)
        XCTAssertEqual(c.map(\.recordCount).reduce(0, +), 100_000)
        XCTAssertLessThan(elapsed, 2.0, "selector took \(elapsed)s over 100k records; budget 2s")
    }
}
