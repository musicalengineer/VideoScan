// PreviewSweepService.swift
// Background preview sweep, Phase 1 (2026-07-27) — the orchestration.
//
// One low-priority task that walks the work plan built by
// PreviewSweepPlanner (see PreviewSweepPlan.swift for the pure half and
// the one-listing scale invariant) and fills the preview disk cache:
// a best-tier still for every video-bearing record, plus a filmstrip
// for .ffmpegDirect (AVPlayer-unplayable) records only.
//
// Behavior contract (each point pinned by PreviewSweepServiceTests):
//   - OFF by default; NEVER starts while disabled.
//   - Instant yielding: any interactive preview/filmstrip request
//     (VideoScanModel pings noteUserInteraction from its request sites)
//     pauses dispatch; in-flight items (≤ workerCount) finish, then the
//     sweep waits for ~10 s of interactive quiet. Interactive renders
//     also outrank the sweep by priority (.userInitiated vs .background).
//   - Thermal .serious/.critical parks the sweep the same way.
//   - Per-volume serialization: one AsyncSemaphore(limit: 1) per volume
//     root (MediaVolumeGate pattern) — never two sweep rips on one
//     spindle; workerCount (2) only helps across volumes.
//   - Cache-cap honesty: the sweep tracks (listing-time bytes + bytes it
//     wrote) against PreviewDiskCache.sizeCapBytes and STOPS with a
//     "cache full" status instead of feeding the next launch's prune a
//     thrash loop.
//   - Failure rules identical to the interactive paths: genuine still
//     failures go to ThumbnailFailureStore; cancellation, unreachable
//     volumes, and a missing ffmpeg NEVER do (the 2026-07-26
//     cache-poison class). Strip-only failures also never touch the
//     store (the still succeeded — same rule as VideoScanModel+Filmstrip).
//   - Catalog changes (scan commit, import, purge) re-plan via a
//     debounced restart — the diff against the cache index makes a
//     restart cheap (completed work is never redone).
//
// Phase 2 note (SMAppService helper process): this class deliberately
// touches VideoScanModel only through injected closures — the run loop,
// planner, gate, and executor could lift into VideoScanCore with the
// model closures replaced by a catalog-file reader. Don't move it yet.
//
// Memory contract: plan arrays (~100k × ~300 B ≈ 30 MB transient worst
// case, ~5 MB at today's 17k), the cache index (20k keys ≈ 3 MB), and
// per-worker render transients (≤16 CGImages at ≤480 wide ≈ 8 MB each,
// bounded by workerCount=2) — all released between items/runs. No
// unbounded accumulation; the disk side is capped at 2 GB by design.

import Foundation
import SwiftUI
import Combine

// The detached run loop (and its logger) moved to VideoScanCore's
// PreviewSweepEngine; this file is now the thin @MainActor adapter that
// owns the @Published status, the interaction gate, and the run lifecycle.

// MARK: - Status
//
// PreviewSweepStatus moved to VideoScanCore (PreviewSweepStatus.swift) so
// the extracted engine constructs/publishes it. Referenced here via the
// app's @_exported import VideoScanCore.

// MARK: - Interaction gate

/// Tiny lock-box recording the last interactive preview request.
/// `@unchecked Sendable` per the repo's tiny-box convention (see
/// ProcessRunner.DeadlineFlag) — the model pings it from the main actor,
/// the sweep's dispatch loop samples it from a detached task. For Rick:
/// a mutex-guarded timestamp; the pacing decision itself is the pure
/// function in PreviewSweepPlan.swift.
final class PreviewSweepGate: @unchecked Sendable {
    private let lock = NSLock()
    private var last: CFAbsoluteTime?

    func noteInteraction(now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        lock.lock()
        last = now
        lock.unlock()
    }

    var lastInteraction: CFAbsoluteTime? {
        lock.lock()
        defer { lock.unlock() }
        return last
    }
}

// MARK: - Per-item outcome
//
// PreviewSweepItemOutcome + the PreviewSweepExecutor function type moved
// to VideoScanCore (PreviewSweepOutcome.swift) so the Core executor
// factory and the Stage-1 CLI share them. Referenced here unchanged via
// the app's @_exported import VideoScanCore.

// MARK: - Service

@MainActor
final class PreviewSweepService: ObservableObject {

    // MARK: Configuration

    struct Configuration {
        let diskCache: PreviewDiskCache
        let failureStore: ThumbnailFailureStore
        /// Snapshot of eligible records (video-bearing, reachable) as
        /// Sendable values — called on the main actor at plan time.
        let candidates: @MainActor () -> [PreviewSweepCandidate]
        /// NARROW per-item skip: true only for a path an interactive
        /// filmstrip rip currently owns (never rip the same master
        /// twice). Deferred, not lost — the next replan covers it if
        /// still missing. This must NOT be a wholesale "stand down"
        /// signal: a predicate that returns true for every path would
        /// make dispatchNext consume the entire plan as skips and
        /// report .done with the catalog uncovered (QA MAJOR-1). The
        /// "precacher is running" stand-down lives in `isExternallyBusy`
        /// below, which PARKS the sweep instead.
        let shouldSkipPathNow: @MainActor (String) -> Bool
        /// The volume-click thumbnail precacher (or any other bulk
        /// cache-filler) is running right now — DEFER the whole sweep
        /// (park + re-poll) rather than fight it for the same caches
        /// and the same spindle. Folded into the pacing pause (QA
        /// MAJOR-1 fix): when it clears, the sweep resumes and covers
        /// ALL remaining records — nothing is dropped. Sampled once per
        /// pacing evaluation (one cheap main-actor bool read per item,
        /// never a plan-walk burst).
        let isExternallyBusy: @MainActor () -> Bool
        /// Injected reachability (codex's isReachable seam pattern —
        /// tests must never poison the VolumeReachability SWR cache).
        let isReachable: @Sendable (String) -> Bool
        let thermalState: @Sendable () -> ProcessInfo.ThermalState
        let executeItem: PreviewSweepExecutor
        var workerCount = 2
        var quietSeconds: Double = PreviewSweepPacing.defaultQuietSeconds
        var pausePollMilliseconds = 500
        var replanDebounceSeconds: Double = 10
        var cacheCapBytes: Int64 = PreviewDiskCache.sizeCapBytes
    }

    // MARK: State

    @Published private(set) var status: PreviewSweepStatus = .idle

    /// Mirrors the persisted PreviewSweepSettings.enabled — the model is
    /// the source of truth; this copy exists so the sweep machinery has
    /// zero UserDefaults coupling (testability + Phase 2 extraction).
    private(set) var isEnabled = false

    /// Interactive-request timestamp box — the model's request sites
    /// ping this via noteUserInteraction().
    let gate = PreviewSweepGate()

    private var config: Configuration?
    private var sweepTask: Task<Void, Never>?
    /// Identifies the latest run so a superseded run's publishes and
    /// cleanup can't clobber a newer one (same pattern as
    /// ThumbnailPrecacher.currentRunID / filmstripRunID).
    private var runID = UUID()
    private var replanTask: Task<Void, Never>?

    /// True while a sweep run is in flight (tests/diagnostics).
    var isSweeping: Bool { sweepTask != nil }

    // MARK: API

    /// Wire dependencies + the persisted enabled state. Does NOT start
    /// anything — the owner kicks noteCatalogChanged() when the catalog
    /// is ready (that's also how launch-resume happens: enabled setting
    /// restored → configure → first catalog signal → sweep).
    func configure(_ configuration: Configuration, enabled: Bool) {
        config = configuration
        isEnabled = enabled
    }

    /// Settings checkbox handler. Enabling kicks a (debounced) start;
    /// disabling cancels everything immediately.
    func setEnabled(_ on: Bool) {
        guard on != isEnabled else { return }
        isEnabled = on
        if on {
            noteCatalogChanged()
        } else {
            replanTask?.cancel()
            replanTask = nil
            cancelSweep()
            status = .idle
        }
    }

    /// Model ping: an interactive preview/filmstrip request happened.
    /// Cheap enough for every keystroke (one lock + timestamp).
    func noteUserInteraction() {
        gate.noteInteraction()
    }

    /// Records changed (scan commit, import, purge, live-reload append).
    /// Debounced: a scan appending records every second keeps pushing
    /// the replan out, so the expensive stat pass runs once things
    /// settle — not per file. A running sweep is restarted; the cache
    /// diff makes that cheap (finished work never repeats).
    func noteCatalogChanged() {
        guard isEnabled, let config else { return }
        replanTask?.cancel()
        let delay = config.replanDebounceSeconds
        replanTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.startSweep()
        }
    }

    /// Stop and go idle (app teardown / tests). Does not touch the
    /// persisted setting.
    func stop() {
        replanTask?.cancel()
        replanTask = nil
        cancelSweep()
        status = .idle
    }

    // MARK: Run lifecycle (private)

    private func cancelSweep() {
        sweepTask?.cancel()
        sweepTask = nil
        runID = UUID()   // orphan any queued publishes from the old run
    }

    private func startSweep() {
        guard isEnabled, let config else { return }
        // Per-volume "one rip per spindle" is preserved ACROSS replans by
        // making the new run drain the old one before it dispatches (QA
        // MINOR-2, 2026-07-27): volumeGates are per-run, so without this
        // an old run still parked at a cancellation point could rip the
        // same volume as the new run under a separate gate dict. The old
        // task is already cancelled here, so its next checkCancellation
        // unwinds it promptly; awaiting `.value` costs one park cycle.
        let previous = sweepTask
        cancelSweep()
        let id = UUID()
        runID = id
        status = .planning

        // Build the Core engine (PreviewSweepEngine) with THIS run's
        // dependencies injected. The model-facing @MainActor state
        // (candidates, isExternallyBusy, shouldSkipPathNow) and the status
        // sinks are reached only through these guarded closures — the
        // engine itself holds no reference to the service. The runID guard
        // inside each closure is what makes a superseded run's publishes
        // and cleanup no-ops (the old service.publish(id)/clearTask(id)
        // guard, now inlined into the sinks).
        let gate = self.gate
        let engine = PreviewSweepEngine(
            plan: { [weak self] in
                await MainActor.run {
                    guard let self, self.runID == id, self.isEnabled else { return [] }
                    return self.config?.candidates() ?? []
                }
            },
            cache: config.diskCache,
            failureStore: config.failureStore,
            thermalState: config.thermalState,
            lastInteraction: { gate.lastInteraction },
            isExternallyBusy: { [weak self] in
                await MainActor.run {
                    guard let self, self.runID == id else { return false }
                    return self.config?.isExternallyBusy() ?? false
                }
            },
            shouldSkipPathNow: { [weak self] path in
                await MainActor.run {
                    guard let self, self.runID == id else { return false }
                    return self.config?.shouldSkipPathNow(path) ?? false
                }
            },
            executeItem: config.executeItem,
            publishOnMain: { [weak self] newStatus in
                guard let self, self.runID == id else { return }
                self.status = newStatus
            },
            finishOnMain: { [weak self] in
                guard let self, self.runID == id else { return }
                self.sweepTask = nil
            },
            workerCount: config.workerCount,
            quietSeconds: config.quietSeconds,
            pausePollMilliseconds: config.pausePollMilliseconds,
            cacheCapBytes: config.cacheCapBytes)

        sweepTask = Task.detached(priority: .background) {
            await previous?.value
            await engine.run()
        }
    }

    // MARK: - Default executor (real renderers)

    /// The production per-item work. The classification logic (the
    /// negative-cache poison contract) now lives in VideoScanCore's
    /// `makePreviewSweepExecutor`, composed from the injected seams: the
    /// app's PreviewDiskCache (as `PreviewCache`) and `VideoScanMediaRenderer`
    /// (as `PreviewMediaRenderer`, wrapping the same routed cores the
    /// interactive paths use). Signature unchanged so existing wire-in and
    /// media-matrix test call sites are untouched.
    static func defaultExecutor(diskCache: PreviewDiskCache,
                                isReachable: @escaping @Sendable (String) -> Bool) -> PreviewSweepExecutor {
        makePreviewSweepExecutor(cache: diskCache,
                                 renderer: VideoScanMediaRenderer(),
                                 isReachable: isReachable)
    }
}

// MARK: - Status line (shared by Settings pane + catalog)

/// Unobtrusive one-line sweep status. Self-observing subview so ONLY
/// this line re-renders on sweep progress — parents embed it without
/// re-evaluating their own bodies (no O(records) work, no table churn).
struct PreviewSweepStatusLine: View {
    @ObservedObject var sweep: PreviewSweepService

    var body: some View {
        if !sweep.status.displayText.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 10))
                Text(sweep.status.displayText)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .lineLimit(1)
            }
            .foregroundColor(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
        }
    }
}
