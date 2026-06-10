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
// Memory contract (Rick's M4 Max, "use RAM aggressively but leave ~4 GB
// headroom"): thumbnails are capped at 480x270 (~0.5 MB of bitmap each),
// generated ONE frame per file — never batch-loaded. The shared NSCache
// carries a byte-cost limit (ThumbnailCachePolicy.costLimitBytes, 8 GB)
// and NSCache additionally evicts under system memory pressure. The
// prewarm loop also checks free RAM before dispatching each file and
// stops early below the 4 GB headroom floor. Worst-case footprint:
// 8 GB of cached thumbnails + (concurrency × one AVAssetImageGenerator
// decoder working set) transient.

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
    /// Byte-cost ceiling for the model's thumbnailCache. 8 GB default —
    /// Rick wants the 128 GB M4 Max RAM used aggressively; NSCache evicts
    /// LRU-ish past this and also responds to system memory pressure.
    /// At ~0.5 MB per 480x270 thumbnail this comfortably covers the whole
    /// 13.5K-record catalog with room to grow.
    static let costLimitBytes: Int = 8 * 1024 * 1024 * 1024

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
    /// The heavy work runs in a detached utility-priority task; the main
    /// actor is only touched once per generated thumbnail (the NSCache
    /// write, same hop the interactive path already does).
    func start(volumeLabel: String,
               candidates: [VideoRecord],
               concurrency: Int,
               model: VideoScanModel) {
        cancel(reason: "superseded by new prewarm request")
        guard !candidates.isEmpty else { return }

        // Snapshot Sendable data only — paths, not VideoRecord instances.
        let paths = candidates.map(\.fullPath)
        let bound = max(1, concurrency)
        let label = volumeLabel
        let runID = UUID()
        currentRunID = runID

        precacheLog.info("Prewarm start — \(label, privacy: .public): \(paths.count) candidates, concurrency \(bound)")

        task = Task.detached(priority: .utility) { [weak model, weak self] in
            let started = CFAbsoluteTimeGetCurrent()

            // Generate one thumbnail; returns true on a cache store.
            // autoreleasepool for the synchronous bitmap work lives inside
            // storePrecachedThumbnail (main-actor side).
            @Sendable func generateOne(_ path: String) async -> Bool {
                if Task.isCancelled { return false }
                guard let cg = try? await VideoScanModel.renderThumbnailCGImage(path: path) else {
                    return false
                }
                if Task.isCancelled { return false }
                await MainActor.run { [weak model] in
                    model?.storePrecachedThumbnail(cg, forPath: path)
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
                var iterator = paths.makeIterator()
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
                precacheLog.info("Prewarm complete — \(label, privacy: .public): \(generated)/\(paths.count) cached, \(failed) skipped/failed (\(String(format: "%.1f", secs))s)")
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
