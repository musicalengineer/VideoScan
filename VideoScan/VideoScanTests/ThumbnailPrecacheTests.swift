import Testing
import Foundation
import AppKit
@testable import VideoScan

// MARK: - ThumbnailPrecache tests (perf batch 2026-06-10)
//
// Pins the PURE pieces of the volume-click thumbnail prewarm:
//
//   1. ORDERING — dossier-complete records jump the queue, table-sort
//      order is preserved within each partition, and cached/unreachable/
//      non-video records never make the work list. If ordering drifts,
//      the prewarm warms the wrong rows first and the feature silently
//      stops paying off.
//
//   2. COST MODEL — the byte-cost estimate (4 bytes/pixel) and the 8 GB
//      cache ceiling, including that makeThumbnailCache() actually wires
//      the constant. Without the cost wiring, NSCache's totalCostLimit
//      is a no-op and the cache grows unbounded — the exact class of bug
//      that has crashed the M4 Max before.
//
//   3. PACING — the per-disk concurrency bounds (HDD=1, SSD=4,
//      internal=8) agreed in the Combine concurrency direction memo.
//
// No SwiftUI, no real files, no timing — the debounce and the prewarm
// task loop are deliberately not unit-tested here.

@Suite("ThumbnailPrecache")
struct ThumbnailPrecacheTests {

    // MARK: - Fixtures

    private func makeRecord(
        path: String,
        streamType: StreamType = .videoAndAudio,
        dossierDone: Bool = false,
        filename: String? = nil
    ) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = path
        r.filename = filename ?? (path as NSString).lastPathComponent
        r.streamTypeRaw = streamType.rawValue
        if dossierDone {
            r.dossierProcessedAt = Date(timeIntervalSince1970: 1_000_000)
        }
        return r
    }

    private let byFilename = [KeyPathComparator(\VideoRecord.filename)]

    // MARK: - Ordering

    @Test("Dossier-complete records come first, sort order preserved within each group")
    func dossierFirstPreservesSortWithinGroups() {
        // Deliberately constructed so a plain filename sort would
        // interleave the two groups.
        let recs = [
            makeRecord(path: "/Volumes/V/d_plain.mov"),
            makeRecord(path: "/Volumes/V/b_dossier.mov", dossierDone: true),
            makeRecord(path: "/Volumes/V/a_plain.mov"),
            makeRecord(path: "/Volumes/V/c_dossier.mov", dossierDone: true)
        ]
        let out = ThumbnailPrecachePlanner.orderedCandidates(
            records: recs,
            sortOrder: byFilename,
            isCached: { _ in false },
            isReachable: { _ in true }
        )
        #expect(out.map(\.filename) == [
            "b_dossier.mov", "c_dossier.mov",   // dossier-complete, sorted
            "a_plain.mov", "d_plain.mov"        // rest, sorted
        ])
    }

    @Test("Empty sort order preserves catalog order within each partition")
    func emptySortOrderIsStable() {
        let recs = [
            makeRecord(path: "/Volumes/V/z.mov"),
            makeRecord(path: "/Volumes/V/m.mov", dossierDone: true),
            makeRecord(path: "/Volumes/V/a.mov"),
            makeRecord(path: "/Volumes/V/k.mov", dossierDone: true)
        ]
        let out = ThumbnailPrecachePlanner.orderedCandidates(
            records: recs,
            sortOrder: [],
            isCached: { _ in false },
            isReachable: { _ in true }
        )
        // Partition only — original relative order kept on both sides.
        #expect(out.map(\.filename) == ["m.mov", "k.mov", "z.mov", "a.mov"])
    }

    @Test("Already-cached records are excluded")
    func cachedExcluded() {
        let cachedPath = "/Volumes/V/cached.mov"
        let recs = [
            makeRecord(path: cachedPath, dossierDone: true),
            makeRecord(path: "/Volumes/V/fresh.mov")
        ]
        let out = ThumbnailPrecachePlanner.orderedCandidates(
            records: recs,
            sortOrder: byFilename,
            isCached: { $0 == cachedPath },
            isReachable: { _ in true }
        )
        #expect(out.map(\.fullPath) == ["/Volumes/V/fresh.mov"])
    }

    @Test("Records on unreachable volumes are excluded")
    func unreachableExcluded() {
        let recs = [
            makeRecord(path: "/Volumes/Offline/a.mov", dossierDone: true),
            makeRecord(path: "/Volumes/Online/b.mov")
        ]
        let out = ThumbnailPrecachePlanner.orderedCandidates(
            records: recs,
            sortOrder: byFilename,
            isCached: { _ in false },
            isReachable: { !$0.hasPrefix("/Volumes/Offline") }
        )
        #expect(out.map(\.fullPath) == ["/Volumes/Online/b.mov"])
    }

    @Test("Only thumbnail-able stream types are candidates")
    func nonVideoExcluded() {
        let recs = [
            makeRecord(path: "/Volumes/V/audio.wav", streamType: .audioOnly),
            makeRecord(path: "/Volumes/V/failed.mxf", streamType: .ffprobeFailed),
            makeRecord(path: "/Volumes/V/none.dat", streamType: .noStreams),
            makeRecord(path: "/Volumes/V/videoonly.mxf", streamType: .videoOnly),
            makeRecord(path: "/Volumes/V/full.mov", streamType: .videoAndAudio)
        ]
        let out = ThumbnailPrecachePlanner.orderedCandidates(
            records: recs,
            sortOrder: byFilename,
            isCached: { _ in false },
            isReachable: { _ in true }
        )
        #expect(Set(out.map(\.fullPath)) == [
            "/Volumes/V/videoonly.mxf", "/Volumes/V/full.mov"
        ])
    }

    // MARK: - Concurrency bounds

    @Test("Per-disk pacing: HDD=1, SSD=4, internal=8, unknown=flat 4, network gentle")
    func concurrencyBounds() {
        #expect(ThumbnailPrecachePlanner.concurrencyBound(mediaTech: .hdd, isInternalPath: false) == 1)
        #expect(ThumbnailPrecachePlanner.concurrencyBound(mediaTech: .ssd, isInternalPath: false) == 4)
        #expect(ThumbnailPrecachePlanner.concurrencyBound(mediaTech: .unknown, isInternalPath: true) == 8)
        // Internal wins regardless of (likely-unset) mediaTech
        #expect(ThumbnailPrecachePlanner.concurrencyBound(mediaTech: .hdd, isInternalPath: true) == 8)
        #expect(ThumbnailPrecachePlanner.concurrencyBound(mediaTech: .unknown, isInternalPath: false) == 4)
        #expect(ThumbnailPrecachePlanner.concurrencyBound(mediaTech: .raid5, isInternalPath: false) == 4)
        #expect(ThumbnailPrecachePlanner.concurrencyBound(mediaTech: .network, isInternalPath: false) == 2)
        #expect(ThumbnailPrecachePlanner.concurrencyBound(mediaTech: .cloud, isInternalPath: false) == 2)
    }

    // MARK: - Cost model

    @Test("Thumbnail cost estimate is 4 bytes per pixel, never zero")
    func costEstimate() {
        // The interactive path caps generation at 480x270.
        #expect(ThumbnailCachePolicy.estimatedCost(pixelsWide: 480, pixelsHigh: 270) == 480 * 270 * 4)
        #expect(ThumbnailCachePolicy.estimatedCost(pixelsWide: 1, pixelsHigh: 1) == 4)
        // Degenerate dims must not produce a 0-cost entry (0-cost entries
        // are invisible to totalCostLimit).
        #expect(ThumbnailCachePolicy.estimatedCost(pixelsWide: 0, pixelsHigh: 0) == 4)
    }

    @Test("Cache cost limit constant is 8 GB and wired into the cache factory")
    func cacheLimitWired() {
        #expect(ThumbnailCachePolicy.costLimitBytes == 8 * 1024 * 1024 * 1024)
        let cache = VideoScanModel.makeThumbnailCache()
        #expect(cache.totalCostLimit == ThumbnailCachePolicy.costLimitBytes)
    }
}
