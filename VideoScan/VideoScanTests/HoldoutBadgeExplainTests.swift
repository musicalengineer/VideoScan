// HoldoutBadgeExplainTests.swift
// The purple "Review N" badge must explain itself, and a row that can't
// be reviewed must have a way out (feature/holdout-review-explain-clear,
// Rick 2026-09-13).
//
// THE BUG THIS PINS: Donna's badge read "Review 1" forever. The newest
// queue (output/person-eval-private/2026-08-05/rick-review-neutral.csv,
// 50 rows, 49 answered) had one pending row —
//   /Volumes/MediaExpansion/Converted_VHS_Tapes_2026/Montana/
//   2026-07-05_13-09-52.mkv  —  FFV1 video + pcm_s32le audio in Matroska.
// HoldoutNavigation classified anything on the PreviewFrameRouter
// .ffmpegDirect route as unplayable, ConfirmPersonSheet hid it, and
// HoldoutReviewCenter.pendingQueue(for:) still counted it pending. Badge
// lit, nothing to review, no exit.
//
// Everything here is the PURE layer (HoldoutNavigation) — no disk, no
// volumes, no sheet, no view. The five house dimensions:
//   1. Logic       — pending-with-clears, the classification table
//   2. Media matrix— mp4/h264, mov/prores, mkv/ffv1+pcm, mxf, avi/dv
//   3. Isolation   — poisoned clear sets (see HoldoutClearStoreTests too)
//   4. Scale       — 100k-row breakdown with a time budget
//   5. Sensor      — the FFV1-only queue must be REVIEWABLE

import Foundation
import Testing
@testable import VideoScan

@Suite("Holdout Badge Explain + Clear")
struct HoldoutBadgeExplainTests {

    // MARK: Fixtures

    private func row(_ id: String, _ path: String, answered: Bool = false) -> HoldoutReviewRow {
        HoldoutReviewRow(reviewId: id, fullPath: path,
                         rickConfirm: answered ? "yes" : "",
                         notes: "", extraColumns: [])
    }

    private func meta(_ container: String, _ codec: String,
                      duration: Double = 227.7,
                      unanalyzable: Bool = false) -> HoldoutMediaMeta {
        HoldoutMediaMeta(container: container, videoCodec: codec,
                         durationSeconds: duration,
                         likelyUnanalyzable: unanalyzable)
    }

    /// Rick's live row, exactly as the catalog describes it.
    private var donnaRowPath: String {
        "/Volumes/MediaExpansion/Converted_VHS_Tapes_2026/Montana/2026-07-05_13-09-52.mkv"
    }
    private var donnaMeta: HoldoutMediaMeta {
        meta("Matroska / WebM", "ffv1", duration: 227.7)
    }

    // MARK: - 1. Logic — the ONE pending definition, with clears

    @Test func pending_isRowNotAnsweredAndNotCleared() {
        let r = row("A", "/Volumes/T/a.mov")
        #expect(HoldoutNavigation.isPending(r, cleared: []))
        #expect(!HoldoutNavigation.isPending(r, cleared: ["A"]))
        // An ANSWERED row is not pending whatever the clear set says.
        let answered = row("B", "/Volumes/T/b.mov", answered: true)
        #expect(!HoldoutNavigation.isPending(answered, cleared: []))
        #expect(!HoldoutNavigation.isPending(answered, cleared: ["B"]))
    }

    @Test func pendingCount_subtractsClearsExactlyOnce() {
        let rows = [row("A", "/a.mov"), row("B", "/b.mov"),
                    row("C", "/c.mov", answered: true)]
        #expect(HoldoutNavigation.pendingCount(rows: rows, cleared: []) == 2)
        #expect(HoldoutNavigation.pendingCount(rows: rows, cleared: ["A"]) == 1)
        #expect(HoldoutNavigation.pendingCount(rows: rows, cleared: ["A", "B"]) == 0)
        // Clearing an ALREADY-ANSWERED row subtracts nothing (it was
        // never in the count).
        #expect(HoldoutNavigation.pendingCount(rows: rows, cleared: ["C"]) == 2)
    }

    @Test func clearedRowsLeaveNavigation_andComeBackOnUndo() {
        let rows = [row("A", "/a.mov"), row("B", "/b.mov")]
        #expect(HoldoutNavigation.firstActionableIndex(
            rows: rows, inFlight: [], offlineExcluded: [],
            unplayableExcluded: [], cleared: ["A"]) == 1)
        #expect(HoldoutNavigation.nextActionableIndex(
            after: 1, rows: rows, inFlight: [], offlineExcluded: [],
            unplayableExcluded: [], cleared: ["A"]) == nil)
        // Clear everything → nothing to show.
        #expect(HoldoutNavigation.firstActionableIndex(
            rows: rows, inFlight: [], offlineExcluded: [],
            unplayableExcluded: [], cleared: ["A", "B"]) == nil)
        // Undo (the clear set shrinks) → the row is back, first in line.
        #expect(HoldoutNavigation.firstActionableIndex(
            rows: rows, inFlight: [], offlineExcluded: [],
            unplayableExcluded: [], cleared: []) == 0)
    }

    @Test func clearSetIsNarrowedToReviewIdsTheQueueStillHas() {
        let rows = [row("A", "/a.mov"), row("B", "/b.mov")]
        // A regenerated queue: the sidecar still names "GHOST".
        let live = HoldoutNavigation.clearedReviewIds(
            rows: rows, storeCleared: ["A", "GHOST"])
        #expect(live == ["A"])
        // ...so any count derived from the SET SIZE stays honest.
        #expect(live.count == 1)
    }

    // MARK: - 1. Logic — the classification table

    @Test func classification_readyOfflineFilmstripCleared() {
        let rows = [
            row("READY",   "/Volumes/Live/ready.mov"),
            row("STRIP",   donnaRowPath),
            row("OFFLINE", "/Volumes/Backups/gone.mov"),
            row("NOFRAME", "/Volumes/Live/audio.wav"),
            row("CLEARED", "/Volumes/Live/setaside.mov"),
            row("DONE",    "/Volumes/Live/answered.mov", answered: true),
        ]
        let metaMap: [String: HoldoutMediaMeta] = [
            "/Volumes/Live/ready.mov": meta("QuickTime / MOV", "h264"),
            donnaRowPath: donnaMeta,
            "/Volumes/Backups/gone.mov": meta("QuickTime / MOV", "h264"),
            "/Volumes/Live/audio.wav": meta("WAV / WAVE", ""),   // no video stream
            "/Volumes/Live/setaside.mov": meta("QuickTime / MOV", "h264"),
        ]
        let b = HoldoutNavigation.breakdown(
            rows: rows, meta: metaMap, cleared: ["CLEARED"],
            offlinePaths: ["/Volumes/Backups/gone.mov"])

        #expect(b.ready == 1)
        #expect(b.needsFilmstrip == 1)
        #expect(b.offline == 1)
        #expect(b.unrenderable == 1)
        #expect(b.cleared == 1)
        #expect(b.offlineVolumes == ["Backups"])
        #expect(b.actionable == 2)          // ready + filmstrip
        #expect(b.pending == 4)             // cleared is NOT pending
        #expect(b.blocked == 2)
        #expect(b.offlineReviewIds == ["OFFLINE"])
        #expect(b.unrenderableReviewIds == ["NOFRAME"])
        #expect(b.clearableReviewIds == ["OFFLINE", "NOFRAME"])
    }

    @Test func classification_offlineOutranksFormat() {
        // An FFV1 row on an unmounted drive is OFFLINE, not
        // needs-filmstrip: reconnecting the drive is the actual remedy,
        // and reachability is a separate axis from format.
        let rows = [row("X", donnaRowPath)]
        let b = HoldoutNavigation.breakdown(
            rows: rows, meta: [donnaRowPath: donnaMeta],
            cleared: [], offlinePaths: [donnaRowPath])
        #expect(b.offline == 1)
        #expect(b.needsFilmstrip == 0)
        #expect(b.offlineVolumes == ["MediaExpansion"])
    }

    @Test func classification_inFlightRowsCountTowardNothing() {
        let rows = [row("A", "/Volumes/Live/a.mov")]
        let b = HoldoutNavigation.breakdown(
            rows: rows, meta: ["/Volumes/Live/a.mov": meta("QuickTime / MOV", "h264")],
            cleared: [], offlinePaths: [], inFlight: ["A"])
        #expect(b.pending == 0)
        #expect(b.ready == 0)
        #expect(b.cleared == 0)
    }

    @Test func classification_catalogMissIsReady_unknownIsNotUnplayable() {
        let rows = [row("A", "/Volumes/Live/mystery.mov")]
        let b = HoldoutNavigation.breakdown(rows: rows, meta: [:],
                                            cleared: [], offlinePaths: [])
        #expect(b.ready == 1)
        #expect(b.unrenderable == 0)
        #expect(b.needsFilmstrip == 0)
    }

    @Test func volumeLabel_namesTheDriveOrTheMac() {
        #expect(HoldoutNavigation.volumeLabel(forPath: donnaRowPath) == "MediaExpansion")
        #expect(HoldoutNavigation.volumeLabel(forPath: "/Users/rickb/Movies/x.mov") == "this Mac")
    }

    @Test func volumeLevelOfflinePaths_asksOncePerVolume() {
        var asked: [String] = []
        let offline = HoldoutNavigation.volumeLevelOfflinePaths(
            paths: ["/Volumes/A/1.mov", "/Volumes/A/2.mov",
                    "/Volumes/B/3.mov", "/Users/rickb/Movies/4.mov"],
            isVolumeReachable: { key in
                asked.append(key)
                return key == "/Volumes/A"
            })
        #expect(offline == ["/Volumes/B/3.mov"])
        #expect(asked == ["/Volumes/A", "/Volumes/B"])   // memoised, internal skipped
    }

    // MARK: - 1. Logic — the metadata map (extracted from the sheet)

    @Test func mediaMetaMap_onePassOverTheCatalog() {
        let wanted = VideoRecord()
        wanted.fullPath = donnaRowPath
        wanted.container = "Matroska / WebM"
        wanted.videoCodec = "ffv1"
        wanted.durationSeconds = 227.7
        let other = VideoRecord()
        other.fullPath = "/Volumes/Live/not-in-the-queue.mov"
        other.container = "QuickTime / MOV"
        other.videoCodec = "h264"

        let map = HoldoutNavigation.mediaMetaMap(paths: [donnaRowPath],
                                                 records: [wanted, other])
        #expect(map.count == 1)
        #expect(map[donnaRowPath]?.videoCodec == "ffv1")
        #expect(HoldoutNavigation.playback(meta: map[donnaRowPath]) == .filmstrip)
        // Empty request does no work and returns nothing.
        #expect(HoldoutNavigation.mediaMetaMap(paths: [], records: [wanted, other]).isEmpty)
    }

    // MARK: - 2. MEDIA MATRIX — which surface each format lands on

    @Test func mediaMatrix_routesEachFormatToTheRightSurface() {
        let cases: [(name: String, meta: HoldoutMediaMeta,
                     expected: HoldoutNavigation.Playback)] = [
            ("mp4/h264",      meta("QuickTime / MOV", "h264"),                     .player),
            ("mov/prores",    meta("QuickTime / MOV", "prores"),                   .player),
            ("mkv/ffv1+pcm",  donnaMeta,                                           .filmstrip),
            ("mxf/mpeg2",     meta("MXF (Material eXchange Format)", "mpeg2video"), .player),
            ("avi/dv",        meta("AVI (Audio Video Interleaved)", "dvvideo"),    .player),
        ]
        for c in cases {
            #expect(HoldoutNavigation.playback(meta: c.meta) == c.expected,
                    "\(c.name) should land on \(c.expected)")
        }
        // THE REGRESSION: mkv/ffv1 must be the FILMSTRIP, never excluded.
        #expect(HoldoutNavigation.playback(meta: donnaMeta) == .filmstrip)
        #expect(HoldoutNavigation.unrenderablePaths(
            rows: [row("X", donnaRowPath)],
            meta: [donnaRowPath: donnaMeta]).isEmpty)
        // ...while still being honest that QuickTime can't play it.
        #expect(HoldoutNavigation.isUnplayable(meta: donnaMeta))
    }

    @Test func mediaMatrix_legacyCodecsAlsoGetTheFilmstrip() {
        for codec in ["svq3", "cinepak", "indeo5", "msmpeg4v2", "vp9"] {
            let m = meta("AVI (Audio Video Interleaved)", codec)
            #expect(HoldoutNavigation.playback(meta: m) == .filmstrip,
                    "\(codec) should be reviewable as frames")
        }
        // The derived can't-analyze flag is a backstop, still filmstrip.
        #expect(HoldoutNavigation.playback(
            meta: meta("QuickTime / MOV", "h264", unanalyzable: true)) == .filmstrip)
    }

    @Test func noFrames_isNarrow_onlyAKnownRecordWithNoVideoStream() {
        // Audio-only catalog record → nothing to show.
        #expect(HoldoutNavigation.playback(meta: meta("WAV / WAVE", "")) == .noFrames)
        #expect(HoldoutNavigation.playback(meta: meta("MXF (Material eXchange Format)", "")) == .noFrames)
        // A half-populated record (no container either) is NOT excluded —
        // over-eager exclusion is the bug being fixed.
        #expect(HoldoutNavigation.playback(meta: meta("", "")) == .player)
        #expect(HoldoutNavigation.playback(meta: nil) == .player)
    }

    // MARK: - 4. SCALE — 100k-row queue, explicit budget

    @Test func scale_breakdownOver100kRowsStaysLinear() {
        var rows: [HoldoutReviewRow] = []
        rows.reserveCapacity(100_000)
        var metaMap: [String: HoldoutMediaMeta] = [:]
        metaMap.reserveCapacity(100_000)
        var offline = Set<String>()
        var cleared = Set<String>()
        let mkv = donnaMeta
        let mov = meta("QuickTime / MOV", "h264")
        for i in 0..<100_000 {
            let path = "/Volumes/Test\(i % 4)/video_\(i).mov"
            rows.append(row("R\(i)", path, answered: i % 5 == 0))
            metaMap[path] = (i % 3 == 0) ? mkv : mov
            if i % 7 == 0 { offline.insert(path) }
            if i % 11 == 0 { cleared.insert("R\(i)") }
        }
        let clock = ContinuousClock()
        var result = HoldoutNavigation.Breakdown()
        let elapsed = clock.measure {
            _ = HoldoutNavigation.pendingCount(rows: rows, cleared: cleared)
            _ = HoldoutNavigation.clearedReviewIds(rows: rows, storeCleared: cleared)
            result = HoldoutNavigation.breakdown(rows: rows, meta: metaMap,
                                                 cleared: cleared,
                                                 offlinePaths: offline)
        }
        // Budget: the whole thing is three O(rows) passes over values
        // already in memory. 2 s is ~100x headroom and catches an
        // accidental O(rows²).
        #expect(elapsed < .seconds(2))
        // Sanity: every pending row landed in exactly one bucket.
        let pending = HoldoutNavigation.pendingCount(rows: rows, cleared: cleared)
        #expect(result.pending == pending)
        #expect(result.ready + result.needsFilmstrip + result.offline
                + result.unrenderable + result.cleared
                == rows.filter(\.isPending).count)
    }

    // MARK: - 5. SENSOR — Donna's row, at production shape

    /// A queue whose ONLY pending row is FFV1/mkv must be REVIEWABLE.
    /// This is the regression: before 2026-09-13 the badge said 1 and the
    /// sheet had nothing to show.
    @Test func sensor_ffv1OnlyQueueIsReviewable() {
        var rows: [HoldoutReviewRow] = []
        for i in 0..<49 { rows.append(row("A\(i)", "/Volumes/MediaExpansion/answered_\(i).mov", answered: true)) }
        rows.append(row("469E9ABDE1B3", donnaRowPath))
        let metaMap = [donnaRowPath: donnaMeta]

        // It is not excluded...
        #expect(HoldoutNavigation.unrenderablePaths(rows: rows, meta: metaMap).isEmpty)
        // ...navigation lands on it...
        #expect(HoldoutNavigation.firstActionableIndex(
            rows: rows, inFlight: [],
            offlineExcluded: [],
            unplayableExcluded: HoldoutNavigation.unrenderablePaths(rows: rows, meta: metaMap),
            cleared: []) == 49)
        // ...and the badge popover says "1 will be shown as frames".
        let b = HoldoutNavigation.breakdown(rows: rows, meta: metaMap,
                                            cleared: [], offlinePaths: [])
        #expect(b.pending == 1)
        #expect(b.needsFilmstrip == 1)
        #expect(b.actionable == 1)
        #expect(b.blocked == 0)
    }

    /// ...and after Rick clears it, the badge reports ZERO pending.
    @Test func sensor_afterAClearTheBadgeReportsZeroPending() {
        var rows: [HoldoutReviewRow] = []
        for i in 0..<49 { rows.append(row("A\(i)", "/Volumes/MediaExpansion/answered_\(i).mov", answered: true)) }
        rows.append(row("469E9ABDE1B3", donnaRowPath))
        let cleared: Set<String> = ["469E9ABDE1B3"]

        #expect(HoldoutNavigation.pendingCount(rows: rows, cleared: cleared) == 0)
        #expect(HoldoutNavigation.firstActionableIndex(
            rows: rows, inFlight: [], offlineExcluded: [],
            unplayableExcluded: [], cleared: cleared) == nil)
        let b = HoldoutNavigation.breakdown(rows: rows, meta: [donnaRowPath: donnaMeta],
                                            cleared: cleared, offlinePaths: [])
        #expect(b.pending == 0)
        #expect(b.cleared == 1)
        #expect(b.actionable == 0)
    }

    /// The clear must never reach the sealed CSV. Pinned structurally:
    /// nothing in the clear path touches HoldoutReviewRow's answer cell,
    /// so a row cleared in the app still reads pending in the file.
    @Test func sensor_clearingDoesNotAlterTheCSVAnswerCell() {
        let r = row("469E9ABDE1B3", donnaRowPath)
        let clearedIds: Set<String> = ["469E9ABDE1B3"]
        // The row value is untouched by any of the clear-aware helpers.
        _ = HoldoutNavigation.pendingCount(rows: [r], cleared: clearedIds)
        _ = HoldoutNavigation.breakdown(rows: [r], meta: [:],
                                        cleared: clearedIds, offlinePaths: [])
        #expect(r.rickConfirm.isEmpty)    // still pending on disk
        #expect(r.isPending)              // the CSV's own opinion is unchanged
        #expect(!HoldoutNavigation.isPending(r, cleared: clearedIds))  // the app's is
    }
}
