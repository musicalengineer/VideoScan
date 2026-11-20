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

    @Test("Cache cost limit is derived from this Mac's RAM and wired into the cache factory")
    func cacheLimitWired() {
        #expect(ThumbnailCachePolicy.costLimitBytes
                == ThumbnailCachePolicy.costLimit(physicalMemory: ProcessInfo.processInfo.physicalMemory))
        let cache = VideoScanModel.makeThumbnailCache()
        #expect(cache.totalCostLimit == ThumbnailCachePolicy.costLimitBytes)
    }

    // MARK: - Cost limit sized from RAM (fix/thumbnail-cache-size, 2026-11-19)
    //
    // The fixed 8 GB limit was sized for a 13.5K-row catalog; the live
    // catalog is 18,903 rows, ~9.1 GiB of 480x270 thumbnails, so NSCache
    // evicted and scrolling re-ripped thumbnails from the video files.

    private static let gib: UInt64 = 1024 * 1024 * 1024
    private static let liveCatalogRows = 18_903
    private static let fullThumbCost = ThumbnailCachePolicy.estimatedCost(pixelsWide: 480, pixelsHigh: 270)

    @Test("The live 18,903-row catalog's thumbnails fit under the limit on the 96 GB M5 Ultra")
    func liveCatalogFitsOn96GB() {
        let limit = ThumbnailCachePolicy.costLimit(physicalMemory: 96 * Self.gib)
        let catalogBytes = Self.liveCatalogRows * Self.fullThumbCost
        #expect(catalogBytes < limit,
                "18,903 x 480x270 thumbnails = \(catalogBytes) bytes, limit \(limit)")
        #expect(limit == 24 * Int(Self.gib))   // 25 % of 96 GB
    }

    @Test("64 GB machine: 25 % of RAM = 16 GB, still holds the live catalog")
    func sixtyFourGB() {
        let limit = ThumbnailCachePolicy.costLimit(physicalMemory: 64 * Self.gib)
        #expect(limit == 16 * Int(Self.gib))
        #expect(Self.liveCatalogRows * Self.fullThumbCost < limit)
    }

    @Test("Floor: a 16 GB (or smaller) machine keeps the old 8 GB limit")
    func floorIsEightGB() {
        #expect(ThumbnailCachePolicy.costLimit(physicalMemory: 16 * Self.gib) == 8 * Int(Self.gib))
        #expect(ThumbnailCachePolicy.costLimit(physicalMemory: 8 * Self.gib) == 8 * Int(Self.gib))
        #expect(ThumbnailCachePolicy.costLimit(physicalMemory: 0) == 8 * Int(Self.gib))
    }

    @Test("Cap: 128 GB and larger machines stop at 32 GB")
    func capIsThirtyTwoGB() {
        #expect(ThumbnailCachePolicy.costLimit(physicalMemory: 128 * Self.gib) == 32 * Int(Self.gib))
        #expect(ThumbnailCachePolicy.costLimit(physicalMemory: 512 * Self.gib) == 32 * Int(Self.gib))
        #expect(ThumbnailCachePolicy.costLimit(physicalMemory: UInt64.max) == 32 * Int(Self.gib))
    }

    // MARK: - Self-metering cache (ThumbnailMemoryCache)

    private static func image(_ w: Int = 4, _ h: Int = 4) -> NSImage {
        let cg = PreviewTestImages.solid(red: 0.2, green: 0.4, blue: 0.6, width: w, height: h)
        return NSImage(cgImage: cg, size: NSSize(width: w, height: h))
    }

    @Test("Logic: NSCache's own cost-limit evictions are counted; bytes and entries match what is held")
    func meterCountsCostLimitEvictions() {
        let cache = ThumbnailMemoryCache()
        let one = ThumbnailMemoryCache.cost(of: Self.image())      // 64 bytes
        cache.totalCostLimit = one * 5
        for i in 0..<20 {
            cache.setObject(Self.image(), forKey: "k\(i)" as NSString, cost: one)
        }
        let snap = cache.snapshot
        let present = (0..<20).filter { cache.contains("k\($0)") }.count
        #expect(snap.evictions > 0, "a 5-entry limit holding 20 must evict")
        #expect(snap.removals == 0)
        #expect(snap.entries == present)
        #expect(snap.bytesHeld == present * one)
        #expect(snap.entries + snap.evictions == 20)
    }

    @Test("Logic: replacing a key, removeObject and removeAllObjects are removals, not evictions")
    func ourRemovalsAreNotEvictions() {
        let cache = ThumbnailMemoryCache()
        let one = ThumbnailMemoryCache.cost(of: Self.image())
        cache.setObject(Self.image(), forKey: "a", cost: one)
        cache.setObject(Self.image(), forKey: "a", cost: one)      // fast→best upgrade shape
        #expect(cache.snapshot == .init(entries: 1, bytesHeld: one, evictions: 0, removals: 1))
        cache.removeObject(forKey: "a")
        #expect(cache.snapshot == .init(entries: 0, bytesHeld: 0, evictions: 0, removals: 2))
        for i in 0..<3 { cache.setObject(Self.image(), forKey: "b\(i)" as NSString, cost: one) }
        cache.removeAllObjects()
        #expect(cache.snapshot == .init(entries: 0, bytesHeld: 0, evictions: 0, removals: 5))
    }

    @Test("Isolation: a 0-cost caller, the two-argument setObject and a missing-key remove cannot drift the ledger")
    func ledgerCannotDrift() {
        let cache = ThumbnailMemoryCache()
        let big = ThumbnailMemoryCache.cost(of: Self.image(480, 270))
        cache.setObject(Self.image(480, 270), forKey: "zero", cost: 0)
        #expect(cache.snapshot.bytesHeld == big, "bytes come from the image, not the caller's cost")
        cache.setObject(Self.image(480, 270), forKey: "twoArg")
        #expect(cache.snapshot.entries == 2)
        #expect(cache.snapshot.bytesHeld == 2 * big)
        cache.removeObject(forKey: "never-stored")
        cache.removeAllObjects()
        cache.removeAllObjects()
        #expect(cache.snapshot == .init(entries: 0, bytesHeld: 0, evictions: 0, removals: 2))
    }

    // Review findings 2026-11-19 (fix/thumb-cache-review): ledger drift.
    @Test("Isolation: re-storing the SAME image under the same key is one entry, one cost (NSCache fires no willEvict)")
    func sameImageRestoredDoesNotDrift() {
        let cache = ThumbnailMemoryCache()
        let img = Self.image()
        let one = ThumbnailMemoryCache.cost(of: img)
        cache.setObject(img, forKey: "a", cost: one)
        cache.setObject(img, forKey: "a", cost: one)
        #expect(cache.contains("a"))
        #expect(cache.snapshot == .init(entries: 1, bytesHeld: one, evictions: 0, removals: 0))
    }

    @Test("Isolation: an object NSCache evicts inside its own setObject (cost > limit) is not counted as held")
    func overLimitObjectIsNotCountedAsHeld() {
        let cache = ThumbnailMemoryCache()
        cache.totalCostLimit = 10
        let img = Self.image()                                     // 64 bytes > 10
        cache.setObject(img, forKey: "big", cost: 64)
        let held = cache.contains("big")
        #expect(cache.snapshot.entries == (held ? 1 : 0))
        #expect(cache.snapshot.bytesHeld == (held ? 64 : 0))
        #expect(cache.snapshot.entries + cache.snapshot.evictions == 1)
    }

    @Test("The model's preview cache is the metering cache and storePrecachedThumbnail feeds it")
    @MainActor
    func modelCacheMeters() {
        let model = VideoScanModel()
        let cache = model.previewService.thumbnailCache
        #expect(cache.delegate === cache)
        model.storePrecachedThumbnail(PreviewTestImages.solid(red: 1, green: 0, blue: 0), forPath: "/v/a.mov")
        #expect(cache.snapshot.entries == 1)
        #expect(cache.snapshot.bytesHeld == Self.fullThumbCost)
        model.invalidateThumbnailCacheEntry(forPath: "/v/a.mov")
        #expect(cache.snapshot == .init(entries: 0, bytesHeld: 0, evictions: 0, removals: 1))
    }

    // MARK: - OUTCOME line

    @Test("OUTCOME line carries N of M, the pass counts, bytes held of the limit, and evictions")
    func outcomeLineFormat() {
        let line = ThumbnailCachePolicy.outcomeLine(
            how: "complete", label: "VHS Rescue",
            cachedNow: 18_000, rowsNeeding: 18_903, stored: 18_100, failed: 803, seconds: 412.34,
            cache: .init(entries: 18_000, bytesHeld: 9_331_200_000, evictions: 100, removals: 7),
            limitBytes: 24 * Int(Self.gib))
        #expect(line == "Thumbnail prewarm OUTCOME (complete) — VHS Rescue: 18000 of 18903 rows needing a thumbnail now cached"
                + " (18100 stored this pass, 803 skipped/failed) · cache ~8.7 GB of 24.0 GB limit, 18000 entries"
                + " · NSCache evictions since launch 100 (our removals 7) · 412.3s")
    }

    @Test("Truth: a finished pass writes ONE OUTCOME line whose N is what the cache holds, not what the pass stored")
    @MainActor
    func passWritesOneOutcomeLineFromEvidence() async throws {
        let model = VideoScanModel()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThumbOutcome-\(UUID().uuidString)", isDirectory: true)
        // Files that do not exist: every generation fails fast, stores nothing.
        let paths = (0..<3).map { dir.appendingPathComponent("clip\($0).mov").path }
        // One row is already in L1 from an earlier pass — the evidence probe
        // must count it although this pass stores nothing.
        model.storePrecachedThumbnail(PreviewTestImages.solid(red: 0, green: 1, blue: 0), forPath: paths[0])
        let sink = InMemoryLogSink()
        let label = "outcome-\(UUID().uuidString)"
        model.thumbnailPrecacher.start(volumeLabel: label,
                                       candidates: paths.map { makeRecord(path: $0) },
                                       concurrency: 2, model: model, log: sink)
        let deadline = Date().addingTimeInterval(30)
        while model.thumbnailPrecacher.isRunning, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!model.thumbnailPrecacher.isRunning)
        let outcomes = sink.lines.filter { $0.contains("Thumbnail prewarm OUTCOME") && $0.contains(label) }
        #expect(outcomes.count == 1)
        #expect(outcomes.first?.contains("(complete) — \(label): 1 of 3 rows needing a thumbnail now cached (0 stored this pass, 3 skipped/failed)") == true,
                "\(outcomes)")
        // MFO: the START line goes through the same sink, before the OUTCOME.
        let starts = sink.lines.enumerated().filter { $0.element.contains("Thumbnail prewarm START") && $0.element.contains(label) }
        #expect(starts.count == 1, "\(sink.lines)")
        let outcomeIndex = sink.lines.firstIndex { $0.contains("Thumbnail prewarm OUTCOME") && $0.contains(label) }
        if let s = starts.first?.offset, let o = outcomeIndex { #expect(s < o) }
        #expect(starts.first?.element.contains("\(label): 3 candidates, concurrency 2") == true, "\(starts)")
    }

    @Test("Isolation: the model gone before the probe still writes ONE OUTCOME line that says the cache could not be probed")
    @MainActor
    func modelGoneStillWritesOutcome() async {
        // The pass's end step, called directly with the model already gone
        // (a released VideoScanModel is freed asynchronously, so an
        // end-to-end start() cannot pin the timing).
        let sink = InMemoryLogSink()
        let label = "gone-\(UUID().uuidString)"
        await ThumbnailPrecacher.writePassOutcome(
            how: "complete", label: label, paths: ["/v/a.mov", "/v/b.mov"],
            stored: 0, failed: 2, seconds: 0.1, model: WeakRef<VideoScanModel>(nil), log: sink)
        let outcomes = sink.lines.filter { $0.contains("Thumbnail prewarm OUTCOME") && $0.contains(label) }
        #expect(outcomes.count == 1, "\(sink.lines)")
        #expect(outcomes.first?.contains("cache could not be probed") == true, "\(outcomes)")
        #expect(outcomes.first?.contains("2 rows needing a thumbnail (0 stored this pass, 2 skipped/failed)") == true, "\(outcomes)")
    }

    @Test("Unprobed OUTCOME line format")
    func unprobedOutcomeLineFormat() {
        let line = ThumbnailCachePolicy.outcomeLine(
            how: "cancelled", label: "VHS Rescue", rowsNeeding: 10, stored: 4, failed: 1,
            seconds: 2.04, probe: nil)
        #expect(line == "Thumbnail prewarm OUTCOME (cancelled) — VHS Rescue: cache could not be probed (model gone);"
                + " 10 rows needing a thumbnail (4 stored this pass, 1 skipped/failed) · 2.0s")
    }

    // MARK: - Scale

    @Test("Scale: 100k entries metered and probed for the OUTCOME within budget")
    func scale100kEntries() {
        let cache = ThumbnailMemoryCache()
        let img = Self.image(1, 1)                     // one shared 4-byte image: meters the ledger, not CG
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for i in 0..<100_000 { cache.setObject(img, forKey: "/v/\(i).mov" as NSString, cost: 4) }
            let present = (0..<100_000).reduce(0) { $0 + (cache.contains("/v/\($1).mov") ? 1 : 0) }
            #expect(present == cache.snapshot.entries)
        }
        #expect(cache.snapshot.entries == 100_000)
        #expect(cache.snapshot.bytesHeld == 400_000)
        #expect(elapsed < .seconds(5), "100k sets + probes took \(elapsed)")
    }

    // MARK: - Sensor

    @Test("Sensor: the limit is derived from RAM (no fixed constant) and the pass OUTCOME goes to the log sink")
    func sizingAndOutcomeSensor() throws {
        let code = SourceTree.strippingComments(try SourceTree.appCode(named: "ThumbnailPrecache.swift"))
        #expect(code.contains("static let costLimitBytes: Int = costLimit(physicalMemory: ProcessInfo.processInfo.physicalMemory)"))
        #expect(code.contains("log.write(ThumbnailCachePolicy.outcomeLine("))
        #expect(code.contains("log.write(ThumbnailCachePolicy.startLine("))
        // The OUTCOME is written off the main actor: the hop only probes and
        // returns a Sendable value (review finding 5, 2026-11-19).
        #expect(code.contains("let probe: ThumbnailCachePolicy.Probe? = await MainActor.run"))
        let service = SourceTree.strippingComments(try SourceTree.appCode(named: "PreviewService.swift"))
        #expect(service.contains("cache.totalCostLimit = ThumbnailCachePolicy.costLimitBytes"))
        #expect(service.contains("let thumbnailCache: ThumbnailMemoryCache"))
    }
}
