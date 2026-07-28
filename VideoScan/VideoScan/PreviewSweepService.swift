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
import os

/// File-scope so the detached sweep task can log without touching
/// main-actor state — same fix class as previewLog/precacheLog.
private let sweepLog = Logger(subsystem: "Rick-Breen.VideoScan",
                              category: "preview-sweep")

// MARK: - Status

/// What the sweep is doing right now — drives the settings pane line and
/// the catalog's unobtrusive progress line. Counts are WORK ITEMS this
/// run (records that actually needed something), not the whole catalog —
/// honest numbers: a warm cache sweeps "3 of 12", not "17,398 of 17,401".
enum PreviewSweepStatus: Equatable {
    case idle
    case planning
    case sweeping(done: Int, total: Int)
    case pausedForInteraction(done: Int, total: Int)
    case pausedForThermal(done: Int, total: Int)
    /// Stopped honestly: cache bytes (existing + written) reached the
    /// 2 GB cap — continuing would just thrash the prune.
    case cacheFull(done: Int, total: Int)
    /// ready = eligible records with a best still on disk when the run
    /// ended; unpreviewable = known + fresh genuine failures.
    case done(ready: Int, unpreviewable: Int)

    /// Friendly-family language (no surveillance terms), one line.
    var displayText: String {
        switch self {
        case .idle:
            return ""
        case .planning:
            return "Preview sweep: checking what's needed…"
        case .sweeping(let done, let total):
            return "Preview sweep: \(done.formatted()) of \(total.formatted())"
        case .pausedForInteraction(let done, let total):
            return "Preview sweep: \(done.formatted()) of \(total.formatted()) · paused while you browse"
        case .pausedForThermal(let done, let total):
            return "Preview sweep: \(done.formatted()) of \(total.formatted()) · paused to keep the Mac cool"
        case .cacheFull(let done, let total):
            return "Preview sweep stopped at \(done.formatted()) of \(total.formatted()) — preview storage is full (2 GB limit)"
        case .done(let ready, let unpreviewable):
            return unpreviewable == 0
                ? "Previews are fresh — \(ready.formatted()) ready"
                : "Previews are fresh — \(ready.formatted()) ready, \(unpreviewable.formatted()) unpreviewable"
        }
    }
}

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

/// What one work item's execution produced. The executor CLASSIFIES;
/// the service applies the failure-store rule and the counters — that
/// split is what lets the sensor tests inject a scripted executor.
struct PreviewSweepItemOutcome: Sendable, Equatable {
    var bytesWritten: Int64 = 0
    /// A best-tier still is on disk for this record after this item.
    var stillReady = false
    /// The still generation failed for reasons that ARE facts about the
    /// file (decode failure on a reachable volume). The ONLY flag that
    /// reaches ThumbnailFailureStore.
    var stillFailedGenuinely = false
    /// Volume went away / file vanished mid-run — no verdict, no record.
    var skippedUnreachable = false
    /// ffmpeg missing — an environment fact, never a file verdict. Also
    /// makes the sweep stop attempting further ffmpeg-routed items.
    var environmentFailure = false
    /// Strip generation failed but the still is fine. Never poisons the
    /// failure store (same rule as the filmstrip prewarm).
    var stripFailed = false
}

/// The per-item work function. Throws ONLY CancellationError; everything
/// else is classified into the outcome.
typealias PreviewSweepExecutor = @Sendable (PreviewSweepWorkItem) async throws -> PreviewSweepItemOutcome

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
        /// True when the sweep should NOT touch this path right now
        /// (interactive filmstrip in flight for it, or the volume-click
        /// precacher is running) — coexist, don't fight. Skipped items
        /// are picked up by the next replan.
        let shouldSkipPathNow: @MainActor (String) -> Bool
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
        cancelSweep()
        let id = UUID()
        runID = id
        status = .planning

        // Sendable captures only — the model-facing @MainActor closures
        // are reached through `self` hops inside the run.
        sweepTask = Task.detached(priority: .background) { [weak self] in
            await Self.run(service: self,
                           runID: id,
                           diskCache: config.diskCache,
                           failureStore: config.failureStore,
                           isReachable: config.isReachable,
                           thermalState: config.thermalState,
                           executeItem: config.executeItem,
                           workerCount: config.workerCount,
                           quietSeconds: config.quietSeconds,
                           pausePollMilliseconds: config.pausePollMilliseconds,
                           cacheCapBytes: config.cacheCapBytes)
        }
    }

    /// Publish a status for `runID` — silently dropped when a newer run
    /// (or a cancel) rotated the id.
    private nonisolated func publish(_ id: UUID, _ newStatus: PreviewSweepStatus) async {
        await MainActor.run { [weak self] in
            guard let self, self.runID == id else { return }
            self.status = newStatus
        }
    }

    /// Clear the finished run's task handle (natural completion only —
    /// cancelSweep is the preemption path).
    private nonisolated func clearTask(_ id: UUID) async {
        await MainActor.run { [weak self] in
            guard let self, self.runID == id else { return }
            self.sweepTask = nil
        }
    }

    // MARK: The sweep run (detached)

    // Static so the compiler proves the run touches the main-actor
    // service ONLY through the explicit await hops below. `service` is
    // weak — the model (and its service) outliving the run is the normal
    // case, but a torn-down window must not be pinned by a sweep.
    private static func run(service: PreviewSweepService?,
                            runID: UUID,
                            diskCache: PreviewDiskCache,
                            failureStore: ThumbnailFailureStore,
                            isReachable: @escaping @Sendable (String) -> Bool,
                            thermalState: @escaping @Sendable () -> ProcessInfo.ThermalState,
                            executeItem: @escaping PreviewSweepExecutor,
                            workerCount: Int,
                            quietSeconds: Double,
                            pausePollMilliseconds: Int,
                            cacheCapBytes: Int64) async {
        guard let service else { return }
        let gate = service.gate

        do {
            // ---- Plan: snapshot candidates (main hop) ----------------
            let snapshot: [PreviewSweepCandidate] = await MainActor.run {
                guard service.runID == runID, service.isEnabled else { return [] }
                return service.config?.candidates() ?? []
            }
            guard !snapshot.isEmpty else {
                await service.publish(runID, .idle)
                await service.clearTask(runID)
                return
            }

            // ---- Plan: ONE cache-directory listing -------------------
            // (See the scale invariant in PreviewSweepPlan.swift — this
            // is the only cache probe in the whole run.)
            let files: [(name: String, size: Int64)] = (try? FileManager.default
                .contentsOfDirectory(at: diskCache.rootURL,
                                     includingPropertiesForKeys: [.fileSizeKey],
                                     options: .skipsHiddenFiles).map { url in
                    (url.lastPathComponent,
                     Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0))
                }) ?? []
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
                    guard let sig = PreviewDiskCache.fileSignature(atPath: candidate.path) else {
                        vanished += 1
                        return
                    }
                    if failureStore.isKnownFailure(atPath: candidate.path) {
                        knownFailures += 1
                        return
                    }
                    keyed.append(PreviewSweepKeyedCandidate(
                        candidate: candidate,
                        key: PreviewDiskCache.cacheKey(path: candidate.path,
                                                       mtime: sig.mtime,
                                                       size: sig.size)))
                }
            }

            let items = PreviewSweepPlanner.workItems(candidates: keyed, index: index)
            // Records already fully covered on the still side.
            let readyBase = keyed.count - items.filter(\.needsBestStill).count
            let total = items.count
            sweepLog.info("Sweep plan: \(snapshot.count) eligible, \(keyed.count) keyed, \(total) need work (\(files.count) cache files, \(index.totalBytes / (1024 * 1024)) MB), \(knownFailures) known-unpreviewable, \(vanished) unreadable")

            guard total > 0 else {
                await service.publish(runID, .done(ready: readyBase,
                                                   unpreviewable: knownFailures))
                await service.clearTask(runID)
                return
            }

            if index.totalBytes >= cacheCapBytes {
                // Already at cap before doing anything — report, don't spin.
                await service.publish(runID, .cacheFull(done: 0, total: total))
                await service.clearTask(runID)
                return
            }

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
            var skipped = 0
            var bytesWritten: Int64 = 0
            var cacheFull = false
            var ffmpegMissing = false
            let throttle = ThrottledMainActorUpdate(intervalSecs: 0.3)

            await service.publish(runID, .sweeping(done: 0, total: total))

            try await withThrowingTaskGroup(of: (PreviewSweepWorkItem, PreviewSweepItemOutcome).self) { group in
                var iterator = items.makeIterator()

                // Park until the pacing decision says proceed. Publishes
                // the pause state once per transition, polls at
                // pausePollMilliseconds, and stays cancellation-prompt.
                func waitUntilClear() async throws {
                    var published: PreviewSweepStatus?
                    while true {
                        try Task.checkCancellation()
                        let action = PreviewSweepPacing.action(
                            lastInteraction: gate.lastInteraction,
                            now: CFAbsoluteTimeGetCurrent(),
                            quietSeconds: quietSeconds,
                            thermalState: thermalState())
                        if action == .proceed {
                            if published != nil {
                                // Leaving a pause — restore live progress.
                                await service.publish(runID, .sweeping(done: done, total: total))
                            }
                            return
                        }
                        let pause: PreviewSweepStatus = action == .pauseForInteraction
                            ? .pausedForInteraction(done: done, total: total)
                            : .pausedForThermal(done: done, total: total)
                        if pause != published {
                            await service.publish(runID, pause)
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
                            // routed item is doomed; skip without verdicts.
                            done += 1
                            skipped += 1
                            continue
                        }
                        let skipNow: Bool = await MainActor.run {
                            guard service.runID == runID else { return false }
                            return service.config?.shouldSkipPathNow(item.candidate.path) ?? false
                        }
                        if skipNow {
                            // Someone interactive owns this path right now —
                            // the next replan will catch it if still missing.
                            done += 1
                            skipped += 1
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
                        skipped += 1
                    } else if item.needsBestStill, outcome.stillReady {
                        newlyReady += 1
                    }
                    if outcome.stripFailed {
                        sweepLog.notice("Sweep strip failed (still OK) — \((item.candidate.path as NSString).lastPathComponent, privacy: .public)")
                    }
                    // Throttled progress — per-item main hops must not
                    // spam the UI (ThrottledMainActorUpdate pattern).
                    let progress = PreviewSweepStatus.sweeping(done: done, total: total)
                    await throttle.update { [weak service] in
                        guard let service, service.runID == runID else { return }
                        service.status = progress
                    }
                    if !cacheFull, try await dispatchNext() {
                        inFlight += 1
                    }
                }
            }

            if cacheFull {
                sweepLog.notice("Sweep stopped at cache cap: \(done)/\(total) done, wrote \(bytesWritten / (1024 * 1024)) MB on top of \(index.totalBytes / (1024 * 1024)) MB")
                await service.publish(runID, .cacheFull(done: done, total: total))
            } else {
                sweepLog.info("Sweep done: \(newlyReady) generated, \(newFailures) failed, \(skipped) skipped of \(total) planned")
                await service.publish(runID, .done(ready: readyBase + newlyReady,
                                                   unpreviewable: knownFailures + newFailures))
            }
            await service.clearTask(runID)
        } catch {
            // Cancellation (the only throw that escapes the loop): the
            // canceller owns the status — nothing to publish here.
            sweepLog.debug("Sweep run cancelled")
        }
    }

    // MARK: - Default executor (real renderers)

    /// The production per-item work: render via the same routed cores the
    /// interactive paths use, write through to the disk cache, classify
    /// failures under the interactive paths' exact rules.
    ///
    /// Memory: one best-frame pass (≤4 candidates ≈ 2 MB) or one strip
    /// (≤16 frames ≈ 8 MB) alive per worker at a time, released on store.
    static func defaultExecutor(diskCache: PreviewDiskCache,
                                isReachable: @escaping @Sendable (String) -> Bool) -> PreviewSweepExecutor {
        { item in
            var outcome = PreviewSweepItemOutcome()
            let c = item.candidate

            // Volume may have unmounted since planning — no verdict.
            guard isReachable(c.path) else {
                outcome.skippedUnreachable = true
                return outcome
            }
            // Signature from BEFORE generation — the key must describe
            // the file we decode (same rule as the interactive paths).
            guard let sig = PreviewDiskCache.fileSignature(atPath: c.path) else {
                outcome.skippedUnreachable = true
                return outcome
            }

            if item.needsBestStill {
                do {
                    let cg = try await VideoScanModel.renderBestPreviewCGImage(
                        path: c.path,
                        container: c.container,
                        videoCodec: c.videoCodec,
                        likelyUnanalyzable: c.likelyUnanalyzable,
                        durationSeconds: c.durationSeconds)
                    try Task.checkCancellation()
                    outcome.bytesWritten += diskCache.store(cg,
                                                            path: c.path,
                                                            mtime: sig.mtime,
                                                            size: sig.size,
                                                            tier: .best)
                    outcome.stillReady = true
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    if (error as? PreviewFrameError) == .ffmpegUnavailable {
                        outcome.environmentFailure = true
                        return outcome
                    }
                    // Genuine only while the volume is still there — a
                    // drive dying mid-rip is not a fact about the file.
                    if isReachable(c.path) {
                        outcome.stillFailedGenuinely = true
                    } else {
                        outcome.skippedUnreachable = true
                    }
                    return outcome
                }
            } else {
                outcome.stillReady = true
            }

            if item.needsFilmstrip {
                do {
                    let strip = try await VideoScanModel.renderPreviewFilmstrip(
                        path: c.path,
                        container: c.container,
                        videoCodec: c.videoCodec,
                        likelyUnanalyzable: c.likelyUnanalyzable,
                        durationSeconds: c.durationSeconds)
                    try Task.checkCancellation()
                    outcome.bytesWritten += diskCache.storeFilmstrip(
                        strip.frames.map { ($0.offsetSeconds, $0.image) },
                        path: c.path,
                        mtime: sig.mtime,
                        size: sig.size)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    if (error as? PreviewFrameError) == .ffmpegUnavailable {
                        outcome.environmentFailure = true
                    } else {
                        // Still succeeded, strip didn't — never a
                        // ThumbnailFailureStore entry (poison class).
                        outcome.stripFailed = true
                    }
                }
            }
            return outcome
        }
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
