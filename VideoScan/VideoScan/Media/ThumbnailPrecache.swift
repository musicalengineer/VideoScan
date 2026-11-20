// ThumbnailPrecache.swift
// Part 3 of the 2026-06-10 catalog-browsing perf batch: when the user
// clicks a volume in the catalog, prewarm the thumbnail cache for that
// volume's records in the background — so arrow-keying down the table
// hits warm cache instead of opening one media file per row.
//
// Split in two:
//   - ThumbnailPrecachePlanner / ThumbnailCachePolicy — PURE functions
//     (ordering, concurrency bound, byte-cost estimation). Unit-tested in
//     ThumbnailPrecacheTests.
//   - ThumbnailPrecacher — the @MainActor orchestration object owned by
//     VideoScanModel. One prewarm run at a time; starting a new run (or a
//     scan) cancels the previous one.
//
// Preview routing (2026-07-26): the prewarm snapshot now carries each
// record's routing fields (container / videoCodec / needsReformat) so
// the shared renderThumbnailCGImage core can send AVFoundation-hostile
// files (FFV1/Matroska masters) straight to ffmpeg instead of letting
// AVF grind through container sniffing per file. The run also consults
// the model's ThumbnailFailureStore (negative cache) so files that
// already failed cost one stat per run, not a repeat decode failure —
// and records fresh failures for the interactive path to skip too.
//
// Preview disk cache (Phase B piece 1, 2026-07-26): the prewarm now
// checks the persistent L2 (PreviewDiskCache) before generating — after
// a relaunch, a warmed volume costs one stat + JPEG decode per record
// instead of a media rip — and writes fresh generations through to
// disk as well as L1. Disk hits populate L1.
//
// Best-frame (commit 2): the prewarm is the BACKGROUND pass that owns
// the disk cache's "best" tier — it generates via the content-scored
// renderBestPreviewCGImage (≤4 candidate rips, VHS blue-leader-proof)
// and upgrades "fast" entries the interactive path left behind. A
// best-tier disk hit is terminal (decode + L1, no rips); a fast-tier
// hit is published to L1 immediately for instant browsing, then the
// best-frame generation replaces it in both caches.
//
// Memory contract (Rick's M4 Max, "use RAM aggressively but leave ~4 GB
// headroom"): thumbnails are capped at 480x270 (~0.5 MB of bitmap each),
// generated ONE frame per file — never batch-loaded. The shared NSCache
// carries a byte-cost limit (ThumbnailCachePolicy.costLimitBytes: 25 % of
// RAM in [8, 32] GB — 24 GB on the 96 GB M5 Ultra) and NSCache
// additionally evicts under system memory pressure. The
// prewarm loop also checks free RAM before dispatching each file and
// stops early below the 4 GB headroom floor. Worst-case footprint:
// costLimitBytes of cached thumbnails + (concurrency × one decoder working
// set — AVAssetImageGenerator or a single-frame ffmpeg child) transient.

import Foundation
import AppKit
import AVFoundation
import os

/// File-scope (not a static on the @MainActor precacher) so the detached
/// prewarm task can log without touching main-actor-isolated state —
/// same fix class as dashboardLog in DossierDashboardView.
private let precacheLog = Logger(subsystem: "Rick-Breen.VideoScan",
                                 category: "precache")

// MARK: - Cache policy (pure)

enum ThumbnailCachePolicy {
    /// Byte-cost ceiling for the model's thumbnailCache, sized once at
    /// launch from this Mac's RAM (see `costLimit(physicalMemory:)`).
    /// NSCache evicts LRU-ish past this and also under system memory
    /// pressure; the model clears it outright at the scan RAM floor.
    static let costLimitBytes: Int = costLimit(physicalMemory: ProcessInfo.processInfo.physicalMemory)

    static let costLimitFloorBytes: Int = 8 * 1024 * 1024 * 1024
    static let costLimitCapBytes: Int = 32 * 1024 * 1024 * 1024

    /// 25 % of physical RAM, clamped to [8 GB, 32 GB] (Rick, 2026-11-19:
    /// "I am often scrolling all over that thing… given our 96GB… make it
    /// run faster than a speeding bullet").
    ///
    /// Why these numbers, at ~518 KB per 480x270 thumbnail:
    ///   - 25 %: the catalog is one of several RAM users (scan workers,
    ///     ffmpeg children, MLX for faces/Hallie). A quarter leaves three
    ///     quarters to them, and NSCache still yields under pressure.
    ///   - 96 GB M5 Ultra → 24 GB ≈ 49K thumbnails: 2.6x the live 18,903-row
    ///     catalog. 64 GB → 16 GB ≈ 33K: still the whole catalog.
    ///   - Floor 8 GB = the previous fixed limit, so a small Mac never gets
    ///     LESS than it had (≈16K thumbnails).
    ///   - Cap 32 GB ≈ 66K thumbnails, 3.5x the catalog: past that more RAM
    ///     buys no scrolling, and the cap bounds the worst case.
    /// Worst-case resident: this limit + the precache's transient decoders;
    /// the precache also stops at `precacheHeadroomBytes` free.
    static func costLimit(physicalMemory: UInt64) -> Int {
        let quarter = physicalMemory / 4
        let capped = min(quarter, UInt64(costLimitCapBytes))
        return max(Int(capped), costLimitFloorBytes)
    }

    /// Free-RAM floor below which the precache loop stops dispatching new
    /// work. Matches the project-wide "leave ~4 GB headroom for OS/CLI"
    /// rule (and MemoryPressureMonitor's default scan floor).
    static let precacheHeadroomBytes: UInt64 = 4 * 1024 * 1024 * 1024

    /// Estimated in-memory cost of a decoded thumbnail bitmap: 4 bytes
    /// per pixel (RGBA). Used as the NSCache `cost:` so the byte limit
    /// above means what it says.
    static func estimatedCost(pixelsWide: Int, pixelsHigh: Int) -> Int {
        max(1, pixelsWide) * max(1, pixelsHigh) * 4
    }

    /// The ONE line a prewarm pass writes to the app log when it finishes,
    /// is cancelled, or stops for memory. `cachedNow` is evidence — the
    /// pass's rows probed in the cache at that moment — so evictions during
    /// the pass show up as cachedNow < stored. Pure, for tests.
    static func outcomeLine(how: String,
                            label: String,
                            cachedNow: Int,
                            rowsNeeding: Int,
                            stored: Int,
                            failed: Int,
                            seconds: Double,
                            cache: ThumbnailMemoryCache.Snapshot,
                            limitBytes: Int) -> String {
        let gb = { (b: Int) in String(format: "%.1f GB", Double(b) / 1_073_741_824) }
        return "Thumbnail prewarm OUTCOME (\(how)) — \(label): \(cachedNow) of \(rowsNeeding) rows needing a thumbnail now cached"
            + " (\(stored) stored this pass, \(failed) skipped/failed)"
            + " · cache ~\(gb(cache.bytesHeld)) of \(gb(limitBytes)) limit, \(cache.entries) entries"
            + " · NSCache evictions since launch \(cache.evictions) (our removals \(cache.removals))"
            + " · " + String(format: "%.1fs", seconds)
    }
}

// MARK: - Planner (pure)

enum ThumbnailPrecachePlanner {

    /// Build the prewarm work list for a volume click.
    ///
    /// Rules (in order):
    ///   1. Only records that can yield a thumbnail (video-only or
    ///      video+audio stream types).
    ///   2. Skip records already in the cache and records on unreachable
    ///      volumes (both injected as closures so tests don't need real
    ///      files or mounts).
    ///   3. Sort by the catalog table's current sort order — so the rows
    ///      Rick is about to scroll warm first.
    ///   4. Dossier-complete records (`dossierProcessedAt != nil`) jump to
    ///      the front, preserving the sort order WITHIN each partition —
    ///      those are the rows he browses most.
    static func orderedCandidates(
        records: [VideoRecord],
        sortOrder: [KeyPathComparator<VideoRecord>],
        isCached: (String) -> Bool,
        isReachable: (String) -> Bool
    ) -> [VideoRecord] {
        var eligible = records.filter { rec in
            (rec.streamType == .videoOnly || rec.streamType == .videoAndAudio)
                && !isCached(rec.fullPath)
                && isReachable(rec.fullPath)
        }
        if !sortOrder.isEmpty {
            eligible.sort(using: sortOrder)
        }
        // Stable partition: two filter passes preserve relative order
        // within each group (Swift's filter is order-preserving).
        let dossierDone = eligible.filter { $0.dossierProcessedAt != nil }
        let rest = eligible.filter { $0.dossierProcessedAt == nil }
        return dossierDone + rest
    }

    /// Per-disk concurrency bound, per the agreed auto-pacing direction
    /// (HDD=1, SSD=4, internal=8). Uses the scan target's user/health-set
    /// `mediaTech` classification — there is no runtime disk-type prober
    /// in the app yet (DriveHealth's diagnostics shell out to diskutil and
    /// are too heavy for a click handler), so anything unclassified gets a
    /// flat, safe 4.
    static func concurrencyBound(mediaTech: VolumeMediaTech, isInternalPath: Bool) -> Int {
        if isInternalPath { return 8 }
        switch mediaTech {
        case .hdd:
            return 1
        case .ssd:
            return 4
        case .network, .cloud:
            // Keep network mounts gentle — parallel AVAsset opens over SMB
            // compete with scans and Finder.
            return 2
        default:
            // unknown / RAID variants — flat default, see note above.
            return 4
        }
    }
}

// MARK: - Precacher (orchestration)

/// Per-file prewarm work item: the path plus the routing fields the
/// shared single-frame core needs (preview routing, 2026-07-26). A
/// Sendable value snapshot — VideoRecord instances never cross into the
/// detached task. Swift tuple-of-value-types ≈ a C++ aggregate struct
/// passed by value. `likelyUnanalyzable` is the record's derived
/// `isLikelyUnanalyzable` (stored needsReformat OR the canonical
/// legacy-codec list), evaluated at snapshot time on the main actor.
/// `durationSeconds` (ffprobe-stamped at scan time) feeds the
/// best-frame candidate plan — preview time never re-probes.
private typealias PrecacheItem = (path: String,
                                  container: String,
                                  videoCodec: String,
                                  likelyUnanalyzable: Bool,
                                  durationSeconds: Double)

/// Owns the single in-flight prewarm task. Owned by VideoScanModel so the
/// catalog view, scan lifecycle, and future callers share one instance.
///
/// `// `@MainActor` ≈ "this object's members must be touched from the UI
/// // thread" — start/cancel are called from SwiftUI onChange handlers.`
@MainActor
final class ThumbnailPrecacher {

    private var task: Task<Void, Never>?

    /// Identifies the latest `start()` so a finished run can clear `task`
    /// without clobbering a newer run that superseded it.
    private var currentRunID = UUID()

    /// True while a prewarm run is in flight (for tests/diagnostics).
    var isRunning: Bool { task != nil }

    /// Cancel any in-flight prewarm. Safe to call when idle.
    func cancel(reason: String = "cancelled") {
        if task != nil {
            precacheLog.info("Prewarm cancel requested — \(reason, privacy: .public)")
        }
        task?.cancel()
        task = nil
    }

    /// Start prewarming thumbnails for `candidates` (already filtered +
    /// ordered by ThumbnailPrecachePlanner). Cancels any previous run.
    ///
    /// `log` is the app's one sink, captured at start so the pass's
    /// OUTCOME lands where it began (tests inject an in-memory sink).
    ///
    /// The heavy work runs in a detached utility-priority task; the main
    /// actor is only touched once per generated thumbnail (the NSCache
    /// write, same hop the interactive path already does).
    func start(volumeLabel: String,
               candidates: [VideoRecord],
               concurrency: Int,
               model: VideoScanModel,
               log: any LogSink = appLog) {
        cancel(reason: "superseded by new prewarm request")
        guard !candidates.isEmpty else { return }

        // Snapshot Sendable data only — paths + routing fields, not
        // VideoRecord instances (preview routing, 2026-07-26).
        let items: [PrecacheItem] = candidates.map {
            ($0.fullPath, $0.container, $0.videoCodec, $0.isLikelyUnanalyzable,
             $0.durationSeconds)
        }
        // Both stores are Sendable (lock-guarded); grab the references
        // on the main actor so the detached task never touches the model
        // for them.
        let failureStore = model.thumbnailFailureStore
        let diskCache = model.previewDiskCache
        let bound = max(1, concurrency)
        let label = volumeLabel
        let runID = UUID()
        currentRunID = runID

        precacheLog.info("Prewarm start — \(label, privacy: .public): \(items.count) candidates, concurrency \(bound)")

        // Swift 6: `[weak model]` would make `model` a captured var, which
        // the task group's children may not read; a let-bound WeakRef is
        // the same weak semantics the checker can prove (WeakRef.swift).
        let model = WeakRef(model)
        task = Task.detached(priority: .utility) { [weak self] in
            let started = CFAbsoluteTimeGetCurrent()

            // Generate one thumbnail; returns true on a cache store.
            // autoreleasepool for the synchronous bitmap work lives inside
            // storePrecachedThumbnail (main-actor side).
            @Sendable func generateOne(_ item: PrecacheItem) async -> Bool {
                if Task.isCancelled { return false }
                // Negative cache: this file already failed and hasn't
                // changed on disk — one stat instead of a repeat
                // deadline-bounded decode failure.
                if failureStore.isKnownFailure(atPath: item.path) { return false }
                // L2 disk cache (Phase B piece 1): a payload persisted by
                // an earlier session/run means one JPEG decode instead of
                // a media rip. Signature nil (dead volume mid-run) →
                // skip L2 and let generation report the truth.
                let signature = PreviewDiskCache.fileSignature(atPath: item.path)
                if let signature,
                   let diskHit = diskCache.lookup(path: item.path,
                                                  mtime: signature.mtime,
                                                  size: signature.size) {
                    await MainActor.run {
                        model.object?.storePrecachedThumbnail(diskHit, forPath: item.path)
                    }
                    // Best-tier entries are terminal. A fast-tier hit is
                    // published above for instant browsing, then falls
                    // through so the best-frame generation below
                    // UPGRADES it in both caches.
                    if diskCache.storedTier(path: item.path,
                                            mtime: signature.mtime,
                                            size: signature.size) == .best {
                        return true
                    }
                }
                let cg: CGImage
                do {
                    cg = try await VideoScanModel.renderBestPreviewCGImage(
                        path: item.path,
                        container: item.container,
                        videoCodec: item.videoCodec,
                        likelyUnanalyzable: item.likelyUnanalyzable,
                        durationSeconds: item.durationSeconds)
                } catch {
                    // Remember GENUINE failures so neither future runs nor
                    // the interactive path pays for them again — but never
                    // (QA 🔴, 2026-07-26):
                    //   - cancellation: clicking volume B cancels volume
                    //     A's in-flight rips (ProcessRunner SIGTERMs the
                    //     child); the file is fine, and recording it here
                    //     would stamp its UNCHANGED (mtime,size) →
                    //     "NO PREVIEW" for the rest of the session.
                    //   - ffmpegUnavailable: environment failure (no
                    //     ffmpeg binary), not a fact about the file.
                    if !(error is CancellationError),
                       !Task.isCancelled,
                       (error as? PreviewFrameError) != .ffmpegUnavailable {
                        failureStore.recordFailure(forPath: item.path)
                    }
                    return false
                }
                if Task.isCancelled { return false }
                // Write-through to disk (already off-main here) at tier
                // "best" — the store reaps any superseded fast payload
                // for the same key.
                if let signature {
                    diskCache.store(cg,
                                    path: item.path,
                                    mtime: signature.mtime,
                                    size: signature.size,
                                    tier: .best)
                }
                await MainActor.run {
                    model.object?.storePrecachedThumbnail(cg, forPath: item.path)
                }
                return true
            }

            var generated = 0
            var failed = 0
            var stoppedForMemory = false

            // Sliding-window task group: at most `bound` files in flight.
            // Deliberately NOT enqueueing all 13K candidates up front —
            // no thousand suspended child tasks, and cancellation drains
            // within one window. (AsyncSemaphore would also work; the
            // window keeps the task count itself bounded.)
            await withTaskGroup(of: Bool.self) { group in
                var iterator = items.makeIterator()
                var inFlight = 0

                while inFlight < bound, let next = iterator.next() {
                    group.addTask { await generateOne(next) }
                    inFlight += 1
                }

                while let landed = await group.next() {
                    inFlight -= 1
                    if landed { generated += 1 } else { failed += 1 }

                    if Task.isCancelled { continue }  // drain, add nothing

                    // 4 GB headroom floor — stop dispatching, keep what
                    // we cached so far. NSCache will also evict on its own
                    // under system pressure.
                    if MemoryPressureMonitor.shared.availableMemory()
                        < ThumbnailCachePolicy.precacheHeadroomBytes {
                        stoppedForMemory = true
                        continue
                    }

                    if let next = iterator.next() {
                        group.addTask { await generateOne(next) }
                        inFlight += 1
                    }
                }
            }

            let secs = CFAbsoluteTimeGetCurrent() - started
            if Task.isCancelled {
                precacheLog.info("Prewarm cancelled — \(label, privacy: .public): \(generated) cached before cancel (\(String(format: "%.1f", secs))s)")
            } else if stoppedForMemory {
                precacheLog.warning("Prewarm stopped early (low memory headroom) — \(label, privacy: .public): \(generated) cached, \(failed) skipped/failed (\(String(format: "%.1f", secs))s)")
            } else {
                precacheLog.info("Prewarm complete — \(label, privacy: .public): \(generated)/\(items.count) cached, \(failed) skipped/failed (\(String(format: "%.1f", secs))s)")
            }

            let how = Task.isCancelled ? "cancelled"
                : stoppedForMemory ? "stopped: low memory headroom" : "complete"
            // OUTCOME through the one log sink; N is probed (evidence),
            // once per pass, never per thumbnail. The cache is read on the
            // main actor, where it lives: capturing it into this detached
            // task compiles under Debug's approachable-concurrency rules but
            // NOT under Release's (RegionIsolation::SendingClosureRisksDataRace,
            // 2026-11-19 — the Release build broke on main). One lock-guarded
            // lookup per pass row, once per pass (~ms for 19k rows).
            let paths = items.map { $0.path }
            await MainActor.run {
                guard let memoryCache = model.object?.previewService.thumbnailCache else { return }
                log.write(ThumbnailCachePolicy.outcomeLine(
                    how: how, label: label,
                    cachedNow: memoryCache.cachedCount(of: paths), rowsNeeding: items.count,
                    stored: generated, failed: failed, seconds: secs,
                    cache: memoryCache.snapshot, limitBytes: memoryCache.totalCostLimit))
            }

            // Clear `task` so isRunning reads false after a natural finish —
            // but only if a newer start() hasn't superseded this run.
            await MainActor.run { [weak self] in
                guard let self, self.currentRunID == runID else { return }
                self.task = nil
            }
        }
    }
}
