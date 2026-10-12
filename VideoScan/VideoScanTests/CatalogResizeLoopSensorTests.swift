// CatalogResizeLoopSensorTests.swift
// Regression tests for the 2026-10-11 Catalog-window resize beachball and
// the 22:53 crash ("…more Update Constraints in Window passes than there
// are views in the window").
//
// Two causes, both fixed (see VolumeColumnAnchors.swift and
// VideoScanModel+CatalogChromeCounts.swift for the full story):
//   A. O(records) work in a view body — CatalogToolbar counted the
//      unreadable extensionless rows over every record on every body
//      evaluation. Now a cached Int, recomputed once per burst of catalog
//      changes.
//   B. A layout feedback loop — measured column frames were CatalogView
//      @State and drove minimum widths, so a column moving during layout
//      changed the window's constraints during layout. Now the frames live
//      in an object only two small views observe, are snapped (whole
//      points, x + width), and only ever take slack.
//
// Checklist dimensions covered: logic (cache + anchors), scale (100k
// records, explicit budget), sensor (source scans pinning the moved
// calls), isolation (per-test model; CatalogStore/MediaLedger are already
// test-host-isolated). Media matrix: n/a (no media opened).
//
// (Swift Testing for a C++ reader: `#expect` ≈ EXPECT_*, keeps going;
// `#require` ≈ ASSERT_*, stops the test.)

import Testing
import Foundation
import CoreGraphics
import Combine
@testable import VideoScan

// MARK: - Fixtures

@MainActor
private func record(_ name: String, ext: String, stream: StreamType, purged: Bool = false) -> VideoRecord {
    let r = VideoRecord()
    r.filename = name
    r.fullPath = "/Volumes/TestVol/\(name)"
    r.directory = "/Volumes/TestVol"
    r.ext = ext
    r.streamTypeRaw = stream.rawValue
    r.sizeBytes = 1_000
    if purged { r.purgedAt = Date() }
    return r
}

/// Unreadable + extensionless — what the toolbar item offers to remove.
@MainActor
private func junk(_ i: Int, purged: Bool = false) -> VideoRecord {
    record("blob\(i)", ext: "", stream: .ffprobeFailed, purged: purged)
}

@MainActor
private func media(_ i: Int) -> VideoRecord {
    record("clip\(i).mov", ext: "mov", stream: .videoAndAudio)
}

/// Debounce is 250 ms — wait it out with margin.
private func settle() async throws {
    try await Task.sleep(nanoseconds: 450_000_000)
}

// MARK: - A. The toolbar count cache (logic + invalidation)

@Suite("Catalog chrome counts — cache logic", .serialized)
@MainActor
struct CatalogChromeCountsCacheTests {

    @Test func countMatchesTheIDSelectorOnAMixedCorpus() {
        let recs: [VideoRecord] = [
            junk(1), junk(2), junk(3, purged: true),
            media(1), media(2),
            record("odd.xyz", ext: "xyz", stream: .ffprobeFailed),   // has an extension: kept
            record("noext", ext: "", stream: .videoOnly),            // readable: kept
            record("spaces", ext: "  ", stream: .ffprobeFailed),     // whitespace ext = none
        ]
        let ids = VideoScanModel.unreadableExtensionlessIDs(in: recs)
        #expect(VideoScanModel.unreadableExtensionlessCount(in: recs) == ids.count)
        #expect(ids.count == 3, "junk 1, junk 2 and the whitespace-ext row; the purged one is excluded")
    }

    @Test func readsNeverRecomputeAndOneMutationRecomputesOnce() async throws {
        let model = VideoScanModel()
        try await settle()
        let baseline = model.catalogChromeCounts.recomputeCount

        model.records = [junk(1), junk(2), media(1)]
        try await settle()
        #expect(model.catalogChromeCounts.recomputeCount == baseline + 1)
        #expect(model.unreadableExtensionlessCount == 2)

        for _ in 0..<1_000 { _ = model.unreadableExtensionlessCount }
        #expect(model.catalogChromeCounts.recomputeCount == baseline + 1,
                "Body-style reads must never recompute")
    }

    @Test func purgeRestoreAndAppendUpdateTheCount() async throws {
        let model = VideoScanModel()
        let a = junk(1), b = junk(2)
        model.records = [a, b, media(1)]
        try await settle()
        #expect(model.unreadableExtensionlessCount == 2)

        // Purge (in place — no array mutation; reaches the cache through
        // the save funnel).
        #expect(model.purgeRecords(ids: [a.id]) == 1)
        try await settle()
        #expect(model.unreadableExtensionlessCount == 1, "a purged row leaves the count")

        // Restore.
        #expect(model.restoreRecord(id: a.id))
        try await settle()
        #expect(model.unreadableExtensionlessCount == 2, "a restored row returns to the count")

        // Added.
        model.records.append(junk(3))
        try await settle()
        #expect(model.unreadableExtensionlessCount == 3, "an added row joins the count")

        // The toolbar's own action empties it.
        #expect(model.softDeleteUnreadableExtensionless() == 3)
        try await settle()
        #expect(model.unreadableExtensionlessCount == 0)
    }

    @Test func aBurstOfSavesCoalescesIntoOneRecompute() async throws {
        let model = VideoScanModel()
        model.records = (0..<50).map { junk($0) }
        try await settle()
        let baseline = model.catalogChromeCounts.recomputeCount

        // The dossier-writeback / full-hash-checkpoint shape: many saves
        // in one burst.
        for _ in 0..<200 { model.saveCatalogDebounced() }
        try await settle()
        #expect(model.catalogChromeCounts.recomputeCount == baseline + 1,
                "200 saves in a burst → one recount, got \(model.catalogChromeCounts.recomputeCount - baseline)")
    }

    /// The toolbar observes the MODEL; a changed count must reach it
    /// through the model's objectWillChange (what @Published would do).
    @Test func aChangedCountAnnouncesThroughTheModel() async throws {
        let model = VideoScanModel()
        let a = junk(1)
        model.records = [a, junk(2)]
        try await settle()
        #expect(model.unreadableExtensionlessCount == 2)
        var announced = 0
        let sub = model.objectWillChange.sink { _ in announced += 1 }
        defer { sub.cancel() }

        a.purgedAt = Date()                    // in place: nothing published
        model.refreshCatalogChromeCountsNow()
        #expect(model.unreadableExtensionlessCount == 1)
        #expect(announced == 1, "exactly one objectWillChange for the changed count, got \(announced)")
    }

    @Test func anUnchangedCountPublishesNothing() async throws {
        let model = VideoScanModel()
        model.records = [junk(1), media(1)]
        try await settle()
        let published = model.catalogChromeCounts.publishCount
        let recounts = model.catalogChromeCounts.recomputeCount

        model.refreshCatalogChromeCountsNow()
        model.saveCatalogDebounced()      // in-place save, nothing changed
        try await settle()
        #expect(model.catalogChromeCounts.recomputeCount == recounts + 2, "both recounts ran")
        #expect(model.catalogChromeCounts.publishCount == published,
                "a recount that finds the same number must not invalidate views")
    }
}

// MARK: - A (scale). 100k records — reads are O(1), a burst is one pass

@Suite("Catalog chrome counts — 100k scale sensor", .serialized)
@MainActor
struct CatalogChromeCountsScaleTests {

    @Test func hundredThousandRecordsReadsAreFreeAndAPassFitsTheBudget() async throws {
        let model = VideoScanModel()
        var recs: [VideoRecord] = []
        recs.reserveCapacity(100_000)
        for i in 0..<100_000 { recs.append(i % 50 == 0 ? junk(i) : media(i)) }
        model.records = recs
        try await settle()
        #expect(model.unreadableExtensionlessCount == 2_000)
        let baseline = model.catalogChromeCounts.recomputeCount

        // 10,000 "body evaluations" — what a resize + catalog churn does.
        let readStart = Date()
        var sum = 0
        for _ in 0..<10_000 { sum &+= model.unreadableExtensionlessCount }
        let readCost = Date().timeIntervalSince(readStart)
        #expect(sum == 20_000_000)
        #expect(model.catalogChromeCounts.recomputeCount == baseline, "reads paid for a recount")
        #expect(readCost < 0.05, "10k reads took \(readCost) s — not O(1)")

        // One recount of 100k rows: the cost a burst of mutations pays ONCE.
        let passStart = Date()
        model.refreshCatalogChromeCountsNow()
        let passCost = Date().timeIntervalSince(passStart)
        #if DEBUG
        let budget = 0.5      // unoptimized build — a smoke bound only
        #else
        let budget = 0.05
        #endif
        #expect(passCost < budget, "one 100k recount took \(passCost) s (budget \(budget) s)")
    }
}

// MARK: - B. Column anchors (logic + convergence)

@Suite("Volume column anchors — no layout feedback")
@MainActor
struct VolumeColumnAnchorsTests {

    private let measured: [String: CGRect] = [
        VolumeColumnID.mediaSize: CGRect(x: 412.3, y: 4.5, width: 90.2, height: 22),
        VolumeColumnID.scanned: CGRect(x: 510.6, y: 4.5, width: 110.4, height: 22),
        VolumeColumnID.phase: CGRect(x: 628.0, y: 4.5, width: 120, height: 22),
    ]

    @Test func scrollingAndSubPixelJitterPublishNothing() {
        let anchors = VolumeColumnAnchors()
        #expect(anchors.update(measured))
        #expect(anchors.publishCount == 1)

        // Vertical scroll: every y changes, x/width do not.
        let scrolled = measured.mapValues { $0.offsetBy(dx: 0, dy: 137.5) }
        #expect(!anchors.update(scrolled))
        // Sub-pixel jitter between layout passes.
        let jitter = measured.mapValues { CGRect(x: $0.minX + 0.2, y: $0.minY, width: $0.width - 0.1, height: $0.height) }
        #expect(!anchors.update(jitter))
        #expect(anchors.publishCount == 1)
    }

    @Test func aRealColumnMovePublishesOnceAndEmptyIsIgnored() {
        let anchors = VolumeColumnAnchors()
        anchors.update(measured)
        let moved = measured.mapValues { $0.offsetBy(dx: 24, dy: 0) }
        #expect(anchors.update(moved))
        #expect(!anchors.update(moved))
        #expect(!anchors.update([:]), "an empty measurement must not wipe the anchors")
        #expect(anchors.frames[VolumeColumnID.phase]?.minX == 652)
        #expect(anchors.publishCount == 2)
    }

    /// The crash shape: a layout loop re-measuring the same columns pass
    /// after pass. The wobble crosses a .5 rounding boundary (412.3 →
    /// 412.6), which defeated rounding alone (5,000 publishes — this test's
    /// first run); the one-point dead band holds it to one publish, so a
    /// measurement can never schedule the next pass.
    @Test func tenThousandJitteringPassesConverge() {
        let anchors = VolumeColumnAnchors()
        for pass in 0..<10_000 {
            let wobble = CGFloat(pass % 4) * 0.1      // 0, .1, .2, .3
            anchors.update(measured.mapValues {
                CGRect(x: $0.minX + wobble, y: $0.minY + CGFloat(pass), width: $0.width, height: $0.height)
            })
        }
        #expect(anchors.publishCount == 1, "published \(anchors.publishCount) times — the loop would not converge")
    }

    @Test func catalogGroupOriginFollowsPhaseWithFallback() {
        #expect(VolumeColumnAnchors.catalogGroupOriginX(frames: [:])
                == max(0, VolumeTableMetrics.fallbackMediaSizeX + 210 - 16))
        let anchors = VolumeColumnAnchors()
        anchors.update(measured)
        #expect(anchors.catalogGroupOriginX == CGFloat(612))
    }
}

// MARK: - Cached date text (the volume table's Scanned column)

@Suite("Volume table date text — cached formatters")
@MainActor
struct VolumeTableDateTextTests {

    @Test func sameYearDropsTheYearOtherYearKeepsIt() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let now = try #require(cal.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 12)))
        let thisYear = try #require(cal.date(from: DateComponents(year: 2026, month: 3, day: 5, hour: 12)))
        let lastYear = try #require(cal.date(from: DateComponents(year: 2025, month: 3, day: 5, hour: 12)))
        let a = VolumeTableDateText.short(thisYear, now: now, calendar: cal)
        let b = VolumeTableDateText.short(lastYear, now: now, calendar: cal)
        #expect(!a.contains("2026"), "this year's date omits the year: \(a)")
        #expect(b.contains("2025"), "another year's date keeps it: \(b)")
        // Reuse, not rebuild: the same input gives the same text again.
        #expect(VolumeTableDateText.short(lastYear, now: now, calendar: cal) == b)
    }
}

// MARK: - Sensors (source scans pinning the moved calls)

@Suite("Catalog resize loop — source sensors")
struct CatalogResizeLoopSourceSensors {

    private static var app: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VideoScan", isDirectory: true)
    }

    private static func source(_ rel: String) throws -> String {
        try String(contentsOf: app.appendingPathComponent(rel), encoding: .utf8)
    }

    /// Code lines only — comments may (and do) quote the old calls.
    private static func code(_ rel: String) throws -> String {
        try source(rel).split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    @Test func toolbarBodyNeverWalksRecords() throws {
        let toolbar = try Self.code("Catalog/CatalogToolbar.swift")
        #expect(!toolbar.contains("unreadableExtensionlessIDs("),
                "CatalogToolbar must read model.unreadableExtensionlessCount, not recompute it")
        #expect(!toolbar.contains("(in: model.records)"),
                "no catalog-wide selector over model.records in the toolbar body")
        #expect(toolbar.contains("model.unreadableExtensionlessCount"))
    }

    @Test func columnFramesAreNotCatalogViewState() throws {
        let content = try Self.code("App/ContentView.swift")
        #expect(!content.contains("var volumeColumnFrames"),
                "measured frames as CatalogView @State re-render the whole window per layout pass")
        #expect(content.contains("@State var volumeColumnAnchors = VolumeColumnAnchors()"))

        let pane = try Self.code("Catalog/CatalogView+ScanTargetsPane.swift")
        #expect(!pane.contains("minWidth: catalogGroupOriginX"),
                "a measured anchor must never become a minimum width")
        #expect(pane.contains("VolumeColumnLeadingReserve(anchors: volumeColumnAnchors)"))
        #expect(pane.contains("AnchoredVolumeTableTotalsFooter(anchors: volumeColumnAnchors"))
        #expect(!pane.contains("VolumeTableTotalsFooter(totals:"),
                "the footer must go through the anchored wrapper (zero minimum width)")
        #expect(pane.contains("volumeColumnAnchors.update(frames)"))
    }

    @Test func anchoredRowsOnlyTakeSlack() throws {
        let anchors = try Self.code("Catalog/VolumeColumnAnchors.swift")
        #expect(anchors.contains(".frame(maxWidth: anchors.catalogGroupOriginX, alignment: .leading)"))
        #expect(anchors.contains(".frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, alignment: .leading)"))
    }

    @Test func volumeTableBuildsNoFormatterPerCell() throws {
        let table = try Self.code("Catalog/CatalogView+VolumeTable.swift")
        #expect(!table.contains("let fmt = DateFormatter()"),
                "a DateFormatter per cell per body was the volume table's hottest frame")
    }

    /// The MFO row's subtitle changes every second (Fill In Full Hashes
    /// names up to 8 files). One line, truncated — its height can never
    /// change with the text.
    @Test func mfoRowSubtitleIsOneTruncatedLine() throws {
        let window = try Self.code("MediaOps/MediaFileOperationsWindow.swift")
        let start = try #require(window.range(of: "Text(job.subtitle)"))
        let after = window[start.upperBound...].prefix(260)
        #expect(after.contains(".lineLimit(1)"))
        #expect(after.contains(".truncationMode(.tail)"))
    }
}
