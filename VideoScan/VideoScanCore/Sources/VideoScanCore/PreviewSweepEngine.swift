// PreviewSweepEngine.swift (VideoScanCore)
// The lifted preview-sweep run loop — planner + gate + dispatch/executor
// orchestration — extracted from PreviewSweepService (2026-07-28, Stage 0
// of the out-of-process helper). Composed ENTIRELY from injected
// abstractions (PreviewCache, PreviewSweepFailureStore, the executor
// closure) and injected main-actor sinks; it holds NO reference to
// VideoScanModel, the ObservableObject service, or any app singleton. The
// same engine can be driven in-process by the app today and out-of-process
// by a CLI helper (Stage 1) — the CLI just supplies a file-backed catalog
// snapshot, the real cache/renderer, and a no-op/stdout status sink.
//
// Behavior contract is PINNED by PreviewSweepServiceTests (driven through
// the thin service adapter) — this file is a MECHANICAL relocation of the
// former PreviewSweepService.run: the model-facing @MainActor closures the
// old run reached through `service` are now explicit injected sinks, and
// the disk-cache statics it called are VideoScanCore free functions
// (previewFileSignature / previewCacheKey). No logic, threading, priority,
// or accounting change.
//
// Preemption granularity is per WORK ITEM, not sub-item (QA MINOR-3,
// documented tradeoff, 2026-07-27): an interaction (or the precacher
// starting) that arrives mid-rip is honored only when the CURRENT ≤2
// in-flight items finish. Worst case is one multi-second ffmpeg rip of
// yield latency per busy worker — acceptable because the interactive
// preview runs at .userInitiated and outranks these .background rips on the
// CPU regardless.

import Foundation
import os

private let sweepEngineLog = Logger(subsystem: "Rick-Breen.VideoScan",
                                    category: "preview-sweep")

/// The dependency-injected sweep engine. Value type composed of its
/// collaborators (composition over inheritance) — build one per run and
/// call `run()`.
public struct PreviewSweepEngine: Sendable {

    // MARK: Injected collaborators

    /// Guarded eligible-candidate snapshot — the impl returns [] when the
    /// run was superseded or the feature was disabled (the old run's
    /// `MainActor.run { guard runID==… && isEnabled }`).
    public let plan: @Sendable () async -> [PreviewSweepCandidate]
    /// Read-index (one listing) + write-through target.
    public let cache: any PreviewCache
    /// Genuine-failure negative cache.
    public let failureStore: any PreviewSweepFailureStore
    /// Sampled thermal pressure.
    public let thermalState: @Sendable () -> ProcessInfo.ThermalState
    /// Last interactive-request timestamp (the interaction gate).
    public let lastInteraction: @Sendable () -> CFAbsoluteTime?
    /// "A bulk cache-filler (the volume-click precacher) is running" —
    /// guarded main read; DEFERS the whole sweep.
    public let isExternallyBusy: @Sendable () async -> Bool
    /// Narrow per-path skip: a path an interactive rip currently owns —
    /// guarded main read.
    public let shouldSkipPathNow: @Sendable (String) async -> Bool
    /// The per-item work (real renderers in production, a fake in tests).
    public let executeItem: PreviewSweepExecutor
    /// Main-actor status sink (guarded by the run id in the adapter);
    /// silently dropped when a newer run rotated the id.
    public let publishOnMain: @MainActor @Sendable (PreviewSweepStatus) -> Void
    /// Main-actor "this run finished naturally" sink (clears the task
    /// handle), guarded like `publishOnMain`.
    public let finishOnMain: @MainActor @Sendable () -> Void

    // MARK: Config scalars

    public let workerCount: Int
    public let quietSeconds: Double
    public let pausePollMilliseconds: Int
    public let cacheCapBytes: Int64

    public init(plan: @escaping @Sendable () async -> [PreviewSweepCandidate],
                cache: any PreviewCache,
                failureStore: any PreviewSweepFailureStore,
                thermalState: @escaping @Sendable () -> ProcessInfo.ThermalState,
                lastInteraction: @escaping @Sendable () -> CFAbsoluteTime?,
                isExternallyBusy: @escaping @Sendable () async -> Bool,
                shouldSkipPathNow: @escaping @Sendable (String) async -> Bool,
                executeItem: @escaping PreviewSweepExecutor,
                publishOnMain: @escaping @MainActor @Sendable (PreviewSweepStatus) -> Void,
                finishOnMain: @escaping @MainActor @Sendable () -> Void,
                workerCount: Int,
                quietSeconds: Double,
                pausePollMilliseconds: Int,
                cacheCapBytes: Int64) {
        self.plan = plan
        self.cache = cache
        self.failureStore = failureStore
        self.thermalState = thermalState
        self.lastInteraction = lastInteraction
        self.isExternallyBusy = isExternallyBusy
        self.shouldSkipPathNow = shouldSkipPathNow
        self.executeItem = executeItem
        self.publishOnMain = publishOnMain
        self.finishOnMain = finishOnMain
        self.workerCount = workerCount
        self.quietSeconds = quietSeconds
        self.pausePollMilliseconds = pausePollMilliseconds
        self.cacheCapBytes = cacheCapBytes
    }

    // MARK: Main-actor sinks (guarded in the adapter)

    private func publish(_ newStatus: PreviewSweepStatus) async {
        await MainActor.run { publishOnMain(newStatus) }
    }

    private func clearTask() async {
        await MainActor.run { finishOnMain() }
    }

    // MARK: The sweep run

    public func run() async {
        do {
            // ---- Plan: snapshot candidates (guarded main hop) --------
            let snapshot: [PreviewSweepCandidate] = await plan()
            guard !snapshot.isEmpty else {
                await publish(.idle)
                await clearTask()
                return
            }

            // ---- Plan: ONE cache-directory listing -------------------
            // (See the scale invariant in PreviewSweepPlan.swift — this
            // is the only cache probe in the whole run.)
            let files = cache.currentListing()
            let index = PreviewSweepPlanner.buildCacheIndex(files: files)

            // ---- Plan: key candidates (one stat each, off-main) ------
            var keyed: [PreviewSweepKeyedCandidate] = []
            keyed.reserveCapacity(snapshot.count)
            var knownFailures = 0
            var vanished = 0
            for (i, candidate) in snapshot.enumerated() {
                if i % 256 == 0 { try Task.checkCancellation() }
                // autoreleasepool per chunk of stats — attributesOfItem
                // returns autoreleased Foundation objects and the plan
                // pass may cover 100k files (media-loop memory rule).
                autoreleasepool {
                    guard let sig = previewFileSignature(atPath: candidate.path) else {
                        vanished += 1
                        return
                    }
                    if failureStore.isKnownFailure(atPath: candidate.path) {
                        knownFailures += 1
                        return
                    }
                    keyed.append(PreviewSweepKeyedCandidate(
                        candidate: candidate,
                        key: previewCacheKey(path: candidate.path,
                                             mtime: sig.mtime,
                                             size: sig.size)))
                }
            }

            let items = PreviewSweepPlanner.workItems(candidates: keyed, index: index)
            // Records already fully covered on the still side.
            let readyBase = keyed.count - items.filter(\.needsBestStill).count
            let total = items.count
            sweepEngineLog.info("Sweep plan: \(snapshot.count) eligible, \(keyed.count) keyed, \(total) need work (\(files.count) cache files, \(index.totalBytes / (1024 * 1024)) MB), \(knownFailures) known-unpreviewable, \(vanished) unreadable")

            guard total > 0 else {
                await publish(.done(ready: readyBase,
                                    unpreviewable: knownFailures,
                                    deferred: 0))
                await clearTask()
                return
            }

            if index.totalBytes >= cacheCapBytes {
                // Already at cap before doing anything — report, don't spin.
                await publish(.cacheFull(done: 0, total: total))
                await clearTask()
                return
            }
            // MINOR-4 (QA, 2026-07-27) — cross-launch cap thrash: for a
            // catalog whose full preview set exceeds cacheCapBytes (2 GB
            // ≈ 20k+ records today, so not reachable at Rick's 17k), each
            // launch's sweep would fill to the cap, PreviewDiskCache's
            // init prune would reap oldest-by-INSERTION (not access), and
            // the next launch would regenerate the reaped tail — a
            // perpetual-motion rip cycle that never converges. Not fixed
            // here (today's catalog is comfortably under cap and the
            // .cacheFull stop already bounds a single run); the real fix
            // is access-ordered prune + a "don't regenerate what we just
            // reaped this session" guard, tracked for Phase 2. Sensor:
            // PreviewSweepServiceTests.cacheCapStops pins the single-run
            // stop; a cross-launch thrash sensor is a Phase-2 item.

            // ---- Execute: bounded workers, per-volume serialization --
            var volumeGates: [String: AsyncSemaphore] = [:]
            for item in items where volumeGates[item.volumeRoot] == nil {
                // Limit 1: a sweep must never run two rips against one
                // spindle regardless of media tech — workerCount only
                // buys parallelism ACROSS volumes.
                volumeGates[item.volumeRoot] = AsyncSemaphore(limit: 1)
            }

            var done = 0
            var newlyReady = 0
            var newFailures = 0
            var deferred = 0
            var bytesWritten: Int64 = 0
            var cacheFull = false
            var ffmpegMissing = false
            let throttle = ThrottledMainActorUpdate(intervalSecs: 0.3)

            await publish(.sweeping(done: 0, total: total))

            try await withThrowingTaskGroup(of: (PreviewSweepWorkItem, PreviewSweepItemOutcome).self) { group in
                var iterator = items.makeIterator()

                // Park until the pacing decision says proceed. Publishes
                // the pause state once per transition, polls at
                // pausePollMilliseconds, and stays cancellation-prompt.
                // Samples `isExternallyBusy` (precacher running) via one
                // cheap main-actor bool read per evaluation — folded into
                // the pause so the sweep DEFERS to the precacher rather
                // than consuming its plan (QA MAJOR-1).
                func waitUntilClear() async throws {
                    var published: PreviewSweepStatus?
                    while true {
                        try Task.checkCancellation()
                        let externallyBusy = await isExternallyBusy()
                        let action = PreviewSweepPacing.action(
                            lastInteraction: lastInteraction(),
                            now: CFAbsoluteTimeGetCurrent(),
                            quietSeconds: quietSeconds,
                            thermalState: thermalState(),
                            externallyBusy: externallyBusy)
                        if action == .proceed {
                            if published != nil {
                                // Leaving a pause — restore live progress.
                                await publish(.sweeping(done: done, total: total))
                            }
                            return
                        }
                        let pause: PreviewSweepStatus = action == .pauseForInteraction
                            ? .pausedForInteraction(done: done, total: total)
                            : .pausedForThermal(done: done, total: total)
                        if pause != published {
                            await publish(pause)
                            published = pause
                        }
                        try await Task.sleep(for: .milliseconds(pausePollMilliseconds))
                    }
                }

                // Dispatch the next dispatchable item; false = plan
                // exhausted or cap reached (cacheFull set).
                func dispatchNext() async throws -> Bool {
                    while let item = iterator.next() {
                        try await waitUntilClear()
                        if index.totalBytes + bytesWritten >= cacheCapBytes {
                            cacheFull = true
                            return false
                        }
                        if ffmpegMissing, item.needsFilmstrip || PreviewFrameRouter.previewRoute(
                            container: item.candidate.container,
                            videoCodec: item.candidate.videoCodec,
                            likelyUnanalyzable: item.candidate.likelyUnanalyzable) == .ffmpegDirect {
                            // No ffmpeg on this machine — every ffmpeg-
                            // routed item is doomed; defer without verdicts
                            // (installing ffmpeg + a replan covers them).
                            done += 1
                            deferred += 1
                            continue
                        }
                        let skipNow = await shouldSkipPathNow(item.candidate.path)
                        if skipNow {
                            // An interactive filmstrip rip owns this path
                            // right now — DEFER it; the next replan covers
                            // it if still missing (NOT a terminal skip).
                            done += 1
                            deferred += 1
                            continue
                        }
                        guard let volumeGate = volumeGates[item.volumeRoot] else { continue }
                        group.addTask {
                            try await volumeGate.withPermit {
                                (item, try await executeItem(item))
                            }
                        }
                        return true
                    }
                    return false
                }

                var inFlight = 0
                while inFlight < max(1, workerCount), try await dispatchNext() {
                    inFlight += 1
                }
                while inFlight > 0, let (item, outcome) = try await group.next() {
                    inFlight -= 1
                    done += 1
                    bytesWritten += outcome.bytesWritten
                    if outcome.environmentFailure { ffmpegMissing = true }
                    if outcome.stillFailedGenuinely {
                        newFailures += 1
                        // Same negative-cache rule as the interactive path;
                        // the executor already excluded cancel/unreachable/
                        // ffmpegUnavailable classes.
                        failureStore.recordFailure(forPath: item.candidate.path)
                    } else if outcome.skippedUnreachable || outcome.environmentFailure {
                        // Volume vanished mid-run / no ffmpeg — no verdict;
                        // the next replan (or a remount) covers it.
                        deferred += 1
                    } else if item.needsBestStill, outcome.stillReady {
                        newlyReady += 1
                    }
                    if outcome.stripFailed {
                        sweepEngineLog.notice("Sweep strip failed (still OK) — \((item.candidate.path as NSString).lastPathComponent, privacy: .public)")
                    }
                    // Throttled progress — per-item main hops must not
                    // spam the UI (ThrottledMainActorUpdate pattern).
                    let progress = PreviewSweepStatus.sweeping(done: done, total: total)
                    await throttle.update { publishOnMain(progress) }
                    if !cacheFull, try await dispatchNext() {
                        inFlight += 1
                    }
                }
            }

            if cacheFull {
                sweepEngineLog.notice("Sweep stopped at cache cap: \(done)/\(total) done, wrote \(bytesWritten / (1024 * 1024)) MB on top of \(index.totalBytes / (1024 * 1024)) MB")
                await publish(.cacheFull(done: done, total: total))
            } else {
                sweepEngineLog.info("Sweep done: \(newlyReady) generated, \(newFailures) failed, \(deferred) deferred of \(total) planned")
                await publish(.done(ready: readyBase + newlyReady,
                                    unpreviewable: knownFailures + newFailures,
                                    deferred: deferred))
            }
            await clearTask()
        } catch {
            // Cancellation (the only throw that escapes the loop): the
            // canceller owns the status — nothing to publish here.
            sweepEngineLog.debug("Sweep run cancelled")
        }
    }
}
