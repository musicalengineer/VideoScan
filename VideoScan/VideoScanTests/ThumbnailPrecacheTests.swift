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
    //
    // NSCache evicts when IT chooses: under memory pressure (the M5 Ultra
    // suite of 2026-11-24 ran with ~16 GB of swap) it dropped every entry
    // inside the setObject that stored it, and the exact-count asserts that
    // only held on a quiet machine went red. So the tests are in two layers:
    //
    //   * NSCache-backed tests run under both Regimes and assert what holds
    //     whatever NSCache does — entries == keys actually held, bytesHeld ==
    //     their costs, entries + evictions + removals == inserts, and each of
    //     OUR removals counted as a removal whenever no eviction overlapped
    //     it. On a quiet machine these reduce to the old exact counts.
    //   * Ledger tests play NSCache's event orders (including a pressure
    //     eviction at every step) into ThumbnailMemoryCache.Ledger directly
    //     and pin exact counts deterministically.

    /// How hard NSCache is squeezed. `.pressure` reproduces the M5 Ultra
    /// suite of 2026-11-24: NSCache dropped every entry inside the setObject
    /// that stored it. A 1-byte cost limit plus a 1-entry count limit makes
    /// NSCache do that (a 0-cost entry survives only until the next set), on
    /// its own eviction path, on any machine.
    enum Regime: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case quiet, pressure
        var testDescription: String { rawValue }
        func apply(_ cache: ThumbnailMemoryCache) {
            if self == .pressure { cache.totalCostLimit = 1; cache.countLimit = 1 }
        }
    }

    private static func image(_ w: Int = 4, _ h: Int = 4) -> NSImage {
        let cg = PreviewTestImages.solid(red: 0.2, green: 0.4, blue: 0.6, width: w, height: h)
        return NSImage(cgImage: cg, size: NSSize(width: w, height: h))
    }

    /// The ledger and the evidence read together so a background purge
    /// cannot tear them: the key probe is bracketed by two snapshots and
    /// retried until they agree (every NSCache removal moves `entries`, so
    /// equal brackets mean nothing left in between). O(keys) per try.
    private static func settled(_ cache: ThumbnailMemoryCache,
                                keys: [String]) -> (snap: ThumbnailMemoryCache.Snapshot, held: [String]) {
        var last = (snap: cache.snapshot, held: [String]())
        for _ in 0..<20 {
            let before = cache.snapshot
            let held = keys.filter(cache.contains)
            last = (cache.snapshot, held)
            if before == last.snap { break }
        }
        return last
    }

    /// The invariants that hold under any memory pressure. `inserts` counts
    /// setObject calls that put a new object in (a silent same-object
    /// re-store is not one).
    private static func expectLedgerMatchesEvidence(
        _ cache: ThumbnailMemoryCache, keys: [String], costEach: Int, inserts: Int,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let (snap, held) = settled(cache, keys: keys)
        #expect(snap.entries == held.count, "ledger \(snap) vs held \(held)", sourceLocation: sourceLocation)
        #expect(snap.bytesHeld == held.count * costEach, "\(snap)", sourceLocation: sourceLocation)
        #expect(snap.entries + snap.evictions + snap.removals == inserts, "\(snap)", sourceLocation: sourceLocation)
    }

    /// Runs one of OUR removals and pins how it is filed: when no NSCache
    /// eviction overlapped it, removals rise by exactly the number of `keys`
    /// held just before and evictions do not move. (When one did overlap,
    /// the documented misfile window means only an upper bound holds.)
    private static func expectOurRemoval(
        _ cache: ThumbnailMemoryCache, of keys: [String],
        sourceLocation: SourceLocation = #_sourceLocation, _ op: () -> Void
    ) {
        let before = cache.snapshot
        let held = keys.filter(cache.contains).count
        op()
        let after = cache.snapshot
        if after.evictions == before.evictions {
            #expect(after.removals - before.removals == held,
                    "before \(before), after \(after), held \(held)", sourceLocation: sourceLocation)
        } else {
            #expect(after.removals - before.removals <= held,
                    "before \(before), after \(after), held \(held)", sourceLocation: sourceLocation)
        }
    }

    @Test("Logic: NSCache's own cost-limit evictions are counted; bytes and entries match what is held")
    func meterCountsCostLimitEvictions() {
        let cache = ThumbnailMemoryCache()
        let one = ThumbnailMemoryCache.cost(of: Self.image())      // 64 bytes
        cache.totalCostLimit = one * 5
        let keys = (0..<20).map { "k\($0)" }
        for k in keys { cache.setObject(Self.image(), forKey: k as NSString, cost: one) }
        #expect(cache.snapshot.evictions > 0, "a 5-entry limit holding 20 must evict")
        #expect(cache.snapshot.removals == 0)
        Self.expectLedgerMatchesEvidence(cache, keys: keys, costEach: one, inserts: 20)
    }

    @Test("Logic: replacing a key, removeObject and removeAllObjects are removals, not evictions", arguments: Regime.allCases)
    func ourRemovalsAreNotEvictions(regime: Regime) {
        let cache = ThumbnailMemoryCache()
        regime.apply(cache)
        let one = ThumbnailMemoryCache.cost(of: Self.image())
        let keys = ["a", "b0", "b1", "b2"]
        cache.setObject(Self.image(), forKey: "a", cost: one)
        Self.expectOurRemoval(cache, of: ["a"]) {
            cache.setObject(Self.image(), forKey: "a", cost: one)  // fast→best upgrade shape
        }
        Self.expectLedgerMatchesEvidence(cache, keys: keys, costEach: one, inserts: 2)
        Self.expectOurRemoval(cache, of: ["a"]) { cache.removeObject(forKey: "a") }
        Self.expectLedgerMatchesEvidence(cache, keys: keys, costEach: one, inserts: 2)
        for i in 0..<3 { cache.setObject(Self.image(), forKey: "b\(i)" as NSString, cost: one) }
        Self.expectOurRemoval(cache, of: keys) { cache.removeAllObjects() }
        Self.expectLedgerMatchesEvidence(cache, keys: keys, costEach: one, inserts: 5)
        #expect(cache.snapshot.entries == 0)
    }

    @Test("Isolation: a 0-cost caller, the two-argument setObject and a missing-key remove cannot drift the ledger", arguments: Regime.allCases)
    func ledgerCannotDrift(regime: Regime) {
        let cache = ThumbnailMemoryCache()
        regime.apply(cache)
        let big = ThumbnailMemoryCache.cost(of: Self.image(480, 270))
        let keys = ["zero", "twoArg"]
        cache.setObject(Self.image(480, 270), forKey: "zero", cost: 0)
        // bytes come from the image, not the caller's cost
        Self.expectLedgerMatchesEvidence(cache, keys: keys, costEach: big, inserts: 1)
        cache.setObject(Self.image(480, 270), forKey: "twoArg")
        Self.expectLedgerMatchesEvidence(cache, keys: keys, costEach: big, inserts: 2)
        Self.expectOurRemoval(cache, of: []) { cache.removeObject(forKey: "never-stored") }
        Self.expectOurRemoval(cache, of: keys) { cache.removeAllObjects() }
        Self.expectOurRemoval(cache, of: keys) { cache.removeAllObjects() }
        Self.expectLedgerMatchesEvidence(cache, keys: keys, costEach: big, inserts: 2)
        #expect(cache.snapshot.entries == 0 && cache.snapshot.bytesHeld == 0)
    }

    // Review findings 2026-11-19 (fix/thumb-cache-review): ledger drift.
    @Test("Isolation: re-storing the SAME image under the same key is one entry, one cost (NSCache fires no willEvict)", arguments: Regime.allCases)
    func sameImageRestoredDoesNotDrift(regime: Regime) {
        let cache = ThumbnailMemoryCache()
        regime.apply(cache)
        let img = Self.image()
        let one = ThumbnailMemoryCache.cost(of: img)
        cache.setObject(img, forKey: "a", cost: one)
        let heldBefore = cache.contains("a")
        cache.setObject(img, forKey: "a", cost: one)
        // A drifting ledger says 2 entries for the one key; the truth is ≤ 1.
        let (snap, held) = Self.settled(cache, keys: ["a"])
        #expect(snap.entries == held.count, "\(snap)")
        #expect(snap.bytesHeld == held.count * one, "\(snap)")
        #expect(snap.removals == 0, "re-storing the same object is not one of our removals: \(snap)")
        // Still held across the re-store with nothing evicted = the silent
        // re-store: exactly one entry, one cost.
        if heldBefore, snap.evictions == 0 {
            #expect(snap == .init(entries: 1, bytesHeld: one, evictions: 0, removals: 0))
        }
    }

    @Test("Isolation: an object NSCache evicts inside its own setObject (cost > limit) is not counted as held")
    func overLimitObjectIsNotCountedAsHeld() {
        let cache = ThumbnailMemoryCache()
        cache.totalCostLimit = 10
        let img = Self.image()                                     // 64 bytes > 10
        cache.setObject(img, forKey: "big", cost: 64)
        Self.expectLedgerMatchesEvidence(cache, keys: ["big"], costEach: 64, inserts: 1)
    }

    @Test("The model's preview cache is the metering cache and storePrecachedThumbnail feeds it", arguments: Regime.allCases)
    @MainActor
    func modelCacheMeters(regime: Regime) {
        let model = VideoScanModel()
        let cache = model.previewService.thumbnailCache
        regime.apply(cache)
        #expect(cache.delegate === cache)
        model.storePrecachedThumbnail(PreviewTestImages.solid(red: 1, green: 0, blue: 0), forPath: "/v/a.mov")
        Self.expectLedgerMatchesEvidence(cache, keys: ["/v/a.mov"], costEach: Self.fullThumbCost, inserts: 1)
        Self.expectOurRemoval(cache, of: ["/v/a.mov"]) { model.invalidateThumbnailCacheEntry(forPath: "/v/a.mov") }
        Self.expectLedgerMatchesEvidence(cache, keys: ["/v/a.mov"], costEach: Self.fullThumbCost, inserts: 1)
        #expect(cache.snapshot.entries == 0)
    }

    // MARK: - Ledger, deterministic (NSCache's event orders played directly)

    /// A stand-in object whose identity the ledger files by.
    private final class Obj {}
    private typealias Ledger = ThumbnailMemoryCache.Ledger
    private typealias Snap = ThumbnailMemoryCache.Snapshot
    private static func id(_ o: Obj) -> ObjectIdentifier { ObjectIdentifier(o) }

    @Test("Ledger: replace, removeObject and removeAllObjects are removals — the exact counts, independent of NSCache's discretion")
    func ledgerOurRemovalsAreRemovals() {
        var l = Ledger()
        let a1 = Obj(), a2 = Obj(), b = [Obj(), Obj(), Obj()]
        l.willSet(replacing: nil, cost: 64); l.didSet(replacing: nil)
        // fast→best upgrade: NSCache fires willEvict(a1) inside super.setObject
        l.willSet(replacing: Self.id(a1), cost: 64)
        l.willEvict(Self.id(a1), cost: 64)
        l.didSet(replacing: Self.id(a1))
        #expect(l.snapshot == Snap(entries: 1, bytesHeld: 64, evictions: 0, removals: 1))
        l.willRemove(Self.id(a2)); l.willEvict(Self.id(a2), cost: 64); l.didRemove(Self.id(a2))
        #expect(l.snapshot == Snap(entries: 0, bytesHeld: 0, evictions: 0, removals: 2))
        for _ in b { l.willSet(replacing: nil, cost: 64); l.didSet(replacing: nil) }
        l.willPurge()
        for o in b { l.willEvict(Self.id(o), cost: 64) }
        l.didPurge()
        #expect(l.snapshot == Snap(entries: 0, bytesHeld: 0, evictions: 0, removals: 5))
        #expect(l.outgoing.isEmpty && l.purging == 0)
    }

    @Test("Ledger: the M5 Ultra shape — NSCache evicting each object inside its own setObject — is evictions, never removals")
    func ledgerPressureEvictionInsideSet() {
        var l = Ledger()
        let a1 = Obj(), a2 = Obj()
        l.willSet(replacing: nil, cost: 64); l.willEvict(Self.id(a1), cost: 64)
        l.didSet(replacing: nil)
        // the key is gone, so the second set finds no old object
        l.willSet(replacing: nil, cost: 64); l.willEvict(Self.id(a2), cost: 64)
        l.didSet(replacing: nil)
        #expect(l.snapshot == Snap(entries: 0, bytesHeld: 0, evictions: 2, removals: 0))
    }

    @Test("Ledger: a pressure eviction of ANOTHER entry during our replace/remove is an eviction; ours stays a removal")
    func ledgerUnrelatedEvictionDuringOurs() {
        var l = Ledger()
        let a = Obj(), other = Obj(), a2 = Obj()
        for _ in 0..<2 { l.willSet(replacing: nil, cost: 10); l.didSet(replacing: nil) }
        l.willSet(replacing: Self.id(a), cost: 10)
        l.willEvict(Self.id(other), cost: 10)          // pressure, mid-replace
        l.willEvict(Self.id(a), cost: 10)              // the replace itself
        l.didSet(replacing: Self.id(a))
        #expect(l.snapshot == Snap(entries: 1, bytesHeld: 10, evictions: 1, removals: 1))
        l.willRemove(Self.id(a2)); l.didRemove(Self.id(a2))   // pressure took it first: no delegate
        l.willEvict(Self.id(a2), cost: 10)                    // a late id is not ours any more
        #expect(l.snapshot == Snap(entries: 0, bytesHeld: 0, evictions: 2, removals: 1))
    }

    @Test("Ledger: pressure taking the old object between our look-up and super's replace is filed as ours, and the counts stay exact")
    func ledgerPressureInsideOurReplace() {
        var l = Ledger()
        let a1 = Obj()
        l.willSet(replacing: nil, cost: 64); l.didSet(replacing: nil)
        l.willSet(replacing: Self.id(a1), cost: 64)
        l.willEvict(Self.id(a1), cost: 64)      // pressure, before super (documented misfile)
        l.didSet(replacing: Self.id(a1))        // super stored the new object with no willEvict
        #expect(l.snapshot == Snap(entries: 1, bytesHeld: 64, evictions: 0, removals: 1))
        #expect(l.outgoing.isEmpty)
    }

    /// One scripted operation against a model NSCache that drives the
    /// Ledger in the same order the ThumbnailMemoryCache shell does, with a
    /// pressure eviction of every held entry injectable at any hook.
    private struct ModelCache {
        var ledger = Ledger()
        var held: [String: Obj] = [:]
        var inserts = 0, ours = 0, pressured = 0, hook = 0
        var pressureInWindow = false
        let pressureAt: Int?

        /// `inWindow`: between a willX and its didX (the misfile window).
        mutating func pressure(inWindow: Bool) {
            defer { hook += 1 }
            guard hook == pressureAt else { return }
            if inWindow && !held.isEmpty { pressureInWindow = true }
            for (k, o) in held {
                held[k] = nil; pressured += 1
                ledger.willEvict(ObjectIdentifier(o), cost: 4)
            }
        }
        /// NSCache removing an entry because WE asked.
        mutating func ourExit(_ k: String) {
            guard let cur = held[k] else { return }
            held[k] = nil; ours += 1
            ledger.willEvict(ObjectIdentifier(cur), cost: 4)
        }
        mutating func set(_ k: String, _ o: Obj) {
            pressure(inWindow: false)
            if let cur = held[k], cur === o { return }     // the shell's same-object no-op
            let old = held[k].map(ObjectIdentifier.init)
            ledger.willSet(replacing: old, cost: 4)
            pressure(inWindow: true)
            if let cur = held[k], cur !== o { ourExit(k) }
            if held[k] == nil { inserts += 1 }
            held[k] = o
            pressure(inWindow: true)
            ledger.didSet(replacing: old)
        }
        mutating func remove(_ k: String) {
            pressure(inWindow: false)
            guard let o = held[k] else { return }
            ledger.willRemove(ObjectIdentifier(o))
            pressure(inWindow: true)
            ourExit(k)
            ledger.didRemove(ObjectIdentifier(o))
        }
        mutating func removeAll() {
            pressure(inWindow: false)
            ledger.willPurge()
            pressure(inWindow: true)
            for k in held.keys { ourExit(k) }
            ledger.didPurge()
        }
    }

    @Test("Ledger: a pressure eviction at EVERY step of a replace/re-store/remove/purge script keeps entries, bytes and the totals exact, and never files ours as evictions")
    func ledgerExactUnderPressureAtEveryStep() {
        func run(_ at: Int?) -> ModelCache {
            var m = ModelCache(pressureAt: at)
            let o = (0..<5).map { _ in Obj() }
            m.set("a", o[0]); m.set("a", o[1]); m.set("a", o[1]); m.set("b", o[2])
            m.remove("a"); m.remove("never"); m.set("c", o[3]); m.removeAll(); m.set("d", o[4])
            withExtendedLifetime(o) {}
            return m
        }
        let quiet = run(nil)
        #expect(quiet.ledger.snapshot == Snap(entries: 1, bytesHeld: 4, evictions: 0, removals: 4))
        for at in 0..<quiet.hook {
            let m = run(at)
            let s = m.ledger.snapshot
            #expect(s.entries == m.held.count, "pressure at hook \(at): \(s)")
            #expect(s.bytesHeld == 4 * m.held.count, "pressure at hook \(at): \(s)")
            #expect(s.entries + s.evictions + s.removals == m.inserts, "pressure at hook \(at): \(s)")
            #expect(m.ledger.outgoing.isEmpty && m.ledger.purging == 0, "pressure at hook \(at)")
            // Ours are never evictions; NSCache's are evictions except in
            // the documented in-flight window.
            #expect(s.removals >= m.ours, "pressure at hook \(at): \(s), ours \(m.ours)")
            if m.pressureInWindow {
                #expect(s.evictions <= m.pressured, "pressure at hook \(at): \(s)")
            } else {
                #expect(s.evictions == m.pressured && s.removals == m.ours, "pressure at hook \(at): \(s)")
            }
        }
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

    @Test("Truth: a finished pass writes ONE OUTCOME line whose N is what the cache holds, not what the pass stored", arguments: Regime.allCases)
    @MainActor
    func passWritesOneOutcomeLineFromEvidence(regime: Regime) async throws {
        let model = VideoScanModel()
        regime.apply(model.previewService.thumbnailCache)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThumbOutcome-\(UUID().uuidString)", isDirectory: true)
        // Files that do not exist: every generation fails fast, stores nothing.
        let paths = (0..<3).map { dir.appendingPathComponent("clip\($0).mov").path }
        // One row is already in L1 from an earlier pass — the evidence probe
        // must count it although this pass stores nothing.
        model.storePrecachedThumbnail(PreviewTestImages.solid(red: 0, green: 1, blue: 0), forPath: paths[0])
        let evictionsAtStart = model.previewService.thumbnailCache.snapshot.evictions
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
        // N is whatever the cache holds at the probe: 1 while paths[0] is
        // still in L1, 0 once NSCache has dropped it — never the pass's
        // `stored` (0), never the once-written entry. No writer runs after
        // the pass, so entries only fall: N ≥ held-now, and N == held-now
        // when nothing was evicted since the store.
        let cache = model.previewService.thumbnailCache
        let heldNow = cache.contains(paths[0]) ? 1 : 0
        let n = outcomes.first.flatMap { line in
            line.firstMatch(of: /: (\d+) of 3 rows needing a thumbnail now cached \(0 stored this pass, 3 skipped\/failed\)/)
                .flatMap { Int($0.1) }
        }
        #expect(outcomes.first?.contains("(complete) — \(label): ") == true, "\(outcomes)")
        #expect(n != nil, "\(outcomes)")
        if let n {
            #expect(n >= heldNow && n <= 1, "\(outcomes)")
            if cache.snapshot.evictions == evictionsAtStart { #expect(n == heldNow, "\(outcomes)") }
            // Forced pressure dropped the entry inside its own store: the
            // once-written row must read 0, not 1.
            if regime == .pressure { #expect(n == 0, "\(outcomes)") }
        }
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

    @Test("Scale: 100k entries metered and probed for the OUTCOME within budget", arguments: Regime.allCases)
    func scale100kEntries(regime: Regime) {
        let cache = ThumbnailMemoryCache()
        regime.apply(cache)
        let img = Self.image(1, 1)                     // one shared 4-byte image: meters the ledger, not CG
        let clock = ContinuousClock()
        let keys = (0..<100_000).map { "/v/\($0).mov" }
        var probed = 0
        let elapsed = clock.measure {
            for k in keys { cache.setObject(img, forKey: k as NSString, cost: 4) }
            probed = cache.cachedCount(of: keys)
        }
        // Whatever NSCache kept or dropped, the ledger agrees with it and
        // every insert is accounted for. On a quiet machine: 100,000 held.
        #expect(probed <= 100_000)
        Self.expectLedgerMatchesEvidence(cache, keys: keys, costEach: 4, inserts: 100_000)
        #expect(cache.snapshot.removals == 0)
        if regime == .pressure { #expect(cache.snapshot.entries <= 1) }
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
        // The ledger sweep's ModelCache mirrors this shell order; the same-
        // object no-op is what keeps it exact under pressure (2026-11-24).
        #expect(service.contains("if let old, old === obj { return }"))
    }
}
