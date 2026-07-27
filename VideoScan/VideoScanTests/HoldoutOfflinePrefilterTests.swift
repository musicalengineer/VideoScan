// HoldoutOfflinePrefilterTests.swift
// Pins the pure prefilter/navigation decisions behind Rick's
// 2026-07-26 requests: "if a video is offline, don't present it" and
// "the prefilter should check that these are even playable."
// (fix/review-offline-prefilter)
//
// Everything here is the PURE layer (HoldoutNavigation) — no disk, no
// volumes, no sheet. The I/O sweep feeding offlineExcluded is exercised
// by the sheet at runtime; the decision logic is what must never drift.

import Foundation
import Testing
@testable import VideoScan

@Suite("Holdout Offline/Unplayable Prefilter")
struct HoldoutOfflinePrefilterTests {

    // MARK: Fixtures

    private func row(_ id: String, _ path: String, answered: Bool = false) -> HoldoutReviewRow {
        HoldoutReviewRow(reviewId: id, fullPath: path,
                         rickConfirm: answered ? "yes" : "",
                         notes: "", extraColumns: [])
    }

    /// 5 rows: 0 pending, 1 answered, 2 pending, 3 pending, 4 pending.
    private var rows: [HoldoutReviewRow] {
        [row("A", "/Volumes/LaCie/a.mov"),
         row("B", "/Volumes/LaCie/b.mov", answered: true),
         row("C", "/Volumes/T/c.mov"),
         row("D", "/Volumes/T/d.mkv"),
         row("E", "/Users/rickb/Movies/e.mov")]
    }

    private let mkvMeta = HoldoutMediaMeta(container: "Matroska / WebM",
                                           videoCodec: "ffv1",
                                           durationSeconds: 60,
                                           likelyUnanalyzable: false)
    private let movMeta = HoldoutMediaMeta(container: "QuickTime / MOV",
                                           videoCodec: "h264",
                                           durationSeconds: 60,
                                           likelyUnanalyzable: false)

    // MARK: Baseline — empty sets == pre-prefilter behavior

    @Test func emptySets_matchOriginalPendingNavigation() {
        // Mirrors HoldoutReviewQueue.nextPendingIndex semantics: skip
        // answered, wrap to front, a row is never its own successor.
        #expect(HoldoutNavigation.firstActionableIndex(
            rows: rows, inFlight: [], offlineExcluded: [], unplayableExcluded: []) == 0)
        #expect(HoldoutNavigation.nextActionableIndex(
            after: 0, rows: rows, inFlight: [], offlineExcluded: [], unplayableExcluded: []) == 2)
        #expect(HoldoutNavigation.nextActionableIndex(
            after: 4, rows: rows, inFlight: [], offlineExcluded: [], unplayableExcluded: []) == 0)
        // Single-row queue: no successor.
        let one = [row("A", "/Volumes/T/a.mov")]
        #expect(HoldoutNavigation.nextActionableIndex(
            after: 0, rows: one, inFlight: [], offlineExcluded: [], unplayableExcluded: []) == nil)
    }

    // MARK: Offline rows skipped

    @Test func offlineRowsAreNeverPresented() {
        let offline: Set<String> = ["/Volumes/LaCie/a.mov"]
        #expect(HoldoutNavigation.firstActionableIndex(
            rows: rows, inFlight: [], offlineExcluded: offline, unplayableExcluded: []) == 2)
        // Wrap navigation also skips it.
        #expect(HoldoutNavigation.nextActionableIndex(
            after: 4, rows: rows, inFlight: [], offlineExcluded: offline, unplayableExcluded: []) == 2)
    }

    // MARK: Unplayable rows skipped

    @Test func unplayableRowsAreNeverPresented() {
        let unplayable: Set<String> = ["/Volumes/T/d.mkv"]
        #expect(HoldoutNavigation.nextActionableIndex(
            after: 2, rows: rows, inFlight: [], offlineExcluded: [], unplayableExcluded: unplayable) == 4)
    }

    // MARK: Combined skips

    @Test func offlinePlusUnplayablePlusInFlightCombine() {
        // A offline, D unplayable, C's answer in flight → only E remains.
        let offline: Set<String> = ["/Volumes/LaCie/a.mov"]
        let unplayable: Set<String> = ["/Volumes/T/d.mkv"]
        let inFlight: Set<String> = ["C"]
        #expect(HoldoutNavigation.firstActionableIndex(
            rows: rows, inFlight: inFlight,
            offlineExcluded: offline, unplayableExcluded: unplayable) == 4)
        #expect(HoldoutNavigation.nextActionableIndex(
            after: 4, rows: rows, inFlight: inFlight,
            offlineExcluded: offline, unplayableExcluded: unplayable) == nil)
    }

    // MARK: All-excluded → done-pane path

    @Test func allExcludedYieldsNoIndex_donePanePath() {
        let offline: Set<String> = ["/Volumes/LaCie/a.mov", "/Users/rickb/Movies/e.mov"]
        let unplayable: Set<String> = ["/Volumes/T/c.mov", "/Volumes/T/d.mkv"]
        #expect(HoldoutNavigation.firstActionableIndex(
            rows: rows, inFlight: [],
            offlineExcluded: offline, unplayableExcluded: unplayable) == nil)
        // ...and the honest counts the done pane renders from:
        let counts = HoldoutNavigation.hiddenPendingCounts(
            rows: rows, inFlight: [], offlineExcluded: offline, unplayableExcluded: unplayable)
        #expect(counts.offline == 2)
        #expect(counts.unplayable == 2)
    }

    // MARK: Playability classification (zero-I/O, catalog facts)

    @Test func unplayableClassificationFollowsPreviewRoute() {
        #expect(HoldoutNavigation.isUnplayable(meta: mkvMeta))       // matroska/ffv1
        #expect(!HoldoutNavigation.isUnplayable(meta: movMeta))      // mov/h264
        // likelyUnanalyzable is a backstop even with friendly fields.
        var legacy = movMeta
        legacy.likelyUnanalyzable = true
        #expect(HoldoutNavigation.isUnplayable(meta: legacy))
    }

    @Test func catalogMissIsPresented_unknownIsNotUnplayable() {
        #expect(!HoldoutNavigation.isUnplayable(meta: nil))
        // Only D has (hostile) metadata; A/C/E have no catalog record
        // and must NOT be excluded.
        let excluded = HoldoutNavigation.unplayablePaths(
            rows: rows, meta: ["/Volumes/T/d.mkv": mkvMeta])
        #expect(excluded == ["/Volumes/T/d.mkv"])
    }

    // MARK: Honest counts

    @Test func hiddenCounts_ignoreAnsweredAndPreferUnplayable() {
        // Answered row B offline → not counted (needs nothing from Rick).
        let counts1 = HoldoutNavigation.hiddenPendingCounts(
            rows: rows, inFlight: [],
            offlineExcluded: ["/Volumes/LaCie/b.mov"], unplayableExcluded: [])
        #expect(counts1 == (0, 0))
        // A row in BOTH sets counts as unplayable — the permanent fact;
        // "reconnect to finish" must only claim recoverable rows.
        let counts2 = HoldoutNavigation.hiddenPendingCounts(
            rows: rows, inFlight: [],
            offlineExcluded: ["/Volumes/T/d.mkv", "/Volumes/LaCie/a.mov"],
            unplayableExcluded: ["/Volumes/T/d.mkv"])
        #expect(counts2.offline == 1)
        #expect(counts2.unplayable == 1)
    }

    // regression pin (QA 2026-07-26 minor 2): an excluded row whose
    // answer is IN FLIGHT counts toward NEITHER hidden bucket —
    // holdoutEffectivePending already subtracts in-flight rows, so
    // counting it here would double-subtract and transiently overstate
    // the done pane's all-hidden state.
    @Test func hiddenCounts_skipInFlightRows_noDoubleSubtraction() {
        // A offline AND its answer mid-commit; D unplayable, untouched.
        let counts = HoldoutNavigation.hiddenPendingCounts(
            rows: rows, inFlight: ["A"],
            offlineExcluded: ["/Volumes/LaCie/a.mov"],
            unplayableExcluded: ["/Volumes/T/d.mkv"])
        #expect(counts.offline == 0)     // A is in flight — not "hidden"
        #expect(counts.unplayable == 1)  // D unaffected
        // Once the write commits (in-flight cleared, row answered), the
        // recompute sees it as answered → still zero.
        var committed = rows
        committed[0].rickConfirm = "yes"
        let after = HoldoutNavigation.hiddenPendingCounts(
            rows: committed, inFlight: [],
            offlineExcluded: ["/Volumes/LaCie/a.mov"],
            unplayableExcluded: ["/Volumes/T/d.mkv"])
        #expect(after.offline == 0)
        #expect(after.unplayable == 1)
    }

    // MARK: Volume grouping for the sweep

    @Test func volumeKeyGroupsVolumesPathsAndPassesInternal() {
        #expect(HoldoutNavigation.volumeKey(forPath: "/Volumes/LaCie/sub/a.mov") == "/Volumes/LaCie")
        #expect(HoldoutNavigation.volumeKey(forPath: "/Volumes/T/c.mov") == "/Volumes/T")
        #expect(HoldoutNavigation.volumeKey(forPath: "/Users/rickb/Movies/e.mov") == nil)
        #expect(HoldoutNavigation.volumeKey(forPath: "/Volumes") == nil)
    }

    // MARK: Scale (queue can pathologically be 100k rows — house dim 2)

    @Test func scale_navigationDecisionsAreFastAt100kRows() {
        var bigRows: [HoldoutReviewRow] = []
        bigRows.reserveCapacity(100_000)
        var offline = Set<String>()
        for i in 0..<100_000 {
            let path = "/Volumes/Test/video_\(i).mov"
            bigRows.append(row("R\(i)", path, answered: i % 2 == 0))
            if i % 3 == 0 { offline.insert(path) }
        }
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            _ = HoldoutNavigation.firstActionableIndex(
                rows: bigRows, inFlight: [], offlineExcluded: offline, unplayableExcluded: [])
            _ = HoldoutNavigation.nextActionableIndex(
                after: 99_999, rows: bigRows, inFlight: [],
                offlineExcluded: offline, unplayableExcluded: [])
            _ = HoldoutNavigation.hiddenPendingCounts(
                rows: bigRows, inFlight: [], offlineExcluded: offline, unplayableExcluded: [])
        }
        #expect(elapsed < .seconds(2))
    }
}
