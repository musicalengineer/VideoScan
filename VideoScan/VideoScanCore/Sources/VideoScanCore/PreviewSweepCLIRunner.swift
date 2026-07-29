// PreviewSweepCLIRunner.swift (VideoScanCore)
// The out-of-process helper's driver (2026-07-28, Stage 1): wires the
// file-backed catalog source + the SHARED PreviewDiskCache + the ffmpeg
// renderer into the SAME PreviewSweepEngine the app runs in-process, and
// surfaces honest progress to a stdout sink. Kept in Core so it can be
// exercised by VideoScanCoreTests with a fake renderer (no real ffmpeg).
//
// Modes:
//   .once  — one plan+sweep pass, then return.
//   .watch — sweep, sleep `intervalSeconds`, re-check catalog.json's mtime;
//            re-read + re-sweep only when it changed (or something was
//            deferred last pass). Ctrl-C ends it (the process just exits).
//   dry-run — plan via the SAME shared planner functions the engine uses,
//            print the work-item counts, rip NOTHING.
//
// The runner treats catalog.json as READ-ONLY (FileBackedCatalogSource only
// reads) and never touches metadata_cache.sqlite.

import Foundation

public struct PreviewSweepCLIRunner {

    public let options: PreviewSweepCLIOptions
    public let cacheRootURL: URL
    public let renderer: any PreviewMediaRenderer
    public let failureStore: any PreviewSweepFailureStore
    /// Volume reachability probe (injected so tests never poison a shared
    /// cache). Default: the containing volume root exists.
    public let isReachable: @Sendable (String) -> Bool
    /// stdout sink (injectable for tests).
    public let out: @Sendable (String) -> Void

    public init(options: PreviewSweepCLIOptions,
                cacheRootURL: URL = PreviewDiskCache.productionRootURL,
                renderer: any PreviewMediaRenderer = FFmpegPreviewRenderer(),
                failureStore: any PreviewSweepFailureStore = InMemoryPreviewSweepFailureStore(),
                isReachable: @escaping @Sendable (String) -> Bool = { path in
                    FileManager.default.fileExists(atPath: previewVolumeRoot(forPath: path))
                },
                out: @escaping @Sendable (String) -> Void = { print($0) }) {
        self.options = options
        self.cacheRootURL = cacheRootURL
        self.renderer = renderer
        self.failureStore = failureStore
        self.isReachable = isReachable
        self.out = out
    }

    // MARK: - Plan summary (dry-run + reporting)

    public struct PlanSummary: Equatable {
        public var eligible: Int
        public var keyed: Int
        public var needBestStill: Int
        public var needFilmstrip: Int
        public var totalWorkItems: Int
        public var cacheFileCount: Int
        public var cacheBytes: Int64
        public var knownFailures: Int
        public var vanished: Int
    }

    /// Compute the plan with the SAME Core building blocks the engine's plan
    /// phase uses (no drift): eligible snapshot → one cache listing →
    /// per-file signature/key → work-item diff.
    public func computePlan(cache: PreviewDiskCache,
                            catalogSource: any PreviewCatalogSource) async -> PlanSummary {
        let snapshot = await catalogSource.eligibleCandidates()
        let files = cache.currentListing()
        let index = PreviewSweepPlanner.buildCacheIndex(files: files)

        var keyed: [PreviewSweepKeyedCandidate] = []
        keyed.reserveCapacity(snapshot.count)
        var knownFailures = 0
        var vanished = 0
        for candidate in snapshot {
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
                                         mtime: sig.mtime, size: sig.size)))
            }
        }
        let items = PreviewSweepPlanner.workItems(candidates: keyed, index: index)
        return PlanSummary(
            eligible: snapshot.count,
            keyed: keyed.count,
            needBestStill: items.filter(\.needsBestStill).count,
            needFilmstrip: items.filter(\.needsFilmstrip).count,
            totalWorkItems: items.count,
            cacheFileCount: files.count,
            cacheBytes: index.totalBytes,
            knownFailures: knownFailures,
            vanished: vanished)
    }

    // MARK: - One real pass (drives the shared engine)

    /// Run one plan+sweep pass through PreviewSweepEngine. Returns the final
    /// published status (`.done` / `.cacheFull` / `.idle`).
    @discardableResult
    public func runPass(cache: PreviewDiskCache,
                        catalogSource: any PreviewCatalogSource) async -> PreviewSweepStatus {
        let finalStatus = FinalStatusBox()
        let sink = self.out
        let engine = PreviewSweepEngine(
            plan: { await catalogSource.eligibleCandidates() },
            cache: cache,
            failureStore: failureStore,
            thermalState: { ProcessInfo.processInfo.thermalState },
            // The CLI has no interactive previews of its own — pacing
            // proceeds unless the machine is thermally pressured.
            lastInteraction: { nil },
            // Stage 1: the CLI can't see the app's in-memory precacher flag
            // across the process boundary; the advisory cache write lock is
            // what keeps them from corrupting each other. Deferring to the
            // app's precacher is a Stage-2 nicety (see report).
            isExternallyBusy: { false },
            shouldSkipPathNow: { _ in false },
            executeItem: makePreviewSweepExecutor(cache: cache,
                                                  renderer: renderer,
                                                  isReachable: isReachable),
            publishOnMain: { status in
                finalStatus.record(status)
                let text = status.displayText
                if !text.isEmpty { sink(text) }
            },
            finishOnMain: {},
            workerCount: options.workerCount,
            quietSeconds: PreviewSweepPacing.defaultQuietSeconds,
            pausePollMilliseconds: 250,
            cacheCapBytes: PreviewDiskCache.sizeCapBytes)
        await engine.run()
        return finalStatus.value
    }

    // MARK: - Top-level run

    /// Run according to `options.mode`. Returns when a `.once` pass finishes;
    /// loops forever in `.watch` (the process exits on signal).
    public func run() async {
        let cache = PreviewDiskCache(rootURL: cacheRootURL)
        let catalogSource = FileBackedCatalogSource(
            catalogURL: options.catalogURL,
            isReachable: isReachable)

        out("preview sweep helper: catalog=\(options.catalogURL.path)")
        out("preview sweep helper: cache=\(cacheRootURL.path)")

        if options.dryRun {
            let plan = await computePlan(cache: cache, catalogSource: catalogSource)
            out("preview sweep (dry-run): \(plan.eligible) eligible, \(plan.keyed) keyed, "
                + "\(plan.totalWorkItems) need work (\(plan.needBestStill) stills, "
                + "\(plan.needFilmstrip) filmstrips); cache \(plan.cacheFileCount) files, "
                + "\(plan.cacheBytes / (1024 * 1024)) MB; \(plan.knownFailures) known-unpreviewable, "
                + "\(plan.vanished) unreadable. Nothing ripped.")
            return
        }

        switch options.mode {
        case .once:
            _ = await runPass(cache: cache, catalogSource: catalogSource)
        case .watch:
            await watchLoop(cache: cache, catalogSource: catalogSource)
        }
    }

    /// The `.watch` loop: sweep, sleep, re-sweep only when the catalog
    /// changed or the last pass deferred work — and, per Stage 2, SELF-EXIT
    /// once the cache has been warm and the catalog unchanged for
    /// `options.idleExitSeconds` (so a detached helper doesn't linger
    /// forever). Any catalog change or deferred work resets the idle clock.
    private func watchLoop(cache: PreviewDiskCache,
                           catalogSource: any PreviewCatalogSource) async {
        var freshness = CatalogFreshness()
        _ = freshness.hasChanged(catalogURL: options.catalogURL)  // seed
        let idlePolicy = HelperIdleExitPolicy(idleGraceSeconds: options.idleExitSeconds)
        var idleElapsed: Double = 0

        while !Task.isCancelled {
            let status = await runPass(cache: cache, catalogSource: catalogSource)
            // "Warm" = the pass finished with nothing deferred: every work
            // item this run could touch was written (or there was none).
            let deferredWork: Bool
            if case .done(_, _, let deferred) = status { deferredWork = deferred > 0 } else { deferredWork = false }
            let cacheWarm = !deferredWork

            do {
                try await Task.sleep(for: .seconds(options.intervalSeconds))
            } catch {
                return  // cancelled
            }

            if freshness.hasChanged(catalogURL: options.catalogURL) {
                idleElapsed = 0          // fresh work — reset the idle clock
                continue                 // re-sweep immediately
            }
            if !cacheWarm {
                idleElapsed = 0          // still had deferred work — keep going
                continue
            }
            // Warm + unchanged: accrue idle time, self-exit at the grace mark.
            idleElapsed += options.intervalSeconds
            if idlePolicy.shouldExit(cacheWarm: true,
                                     catalogUnchanged: true,
                                     idleElapsedSeconds: idleElapsed) {
                out("preview sweep helper: cache warm + catalog unchanged for "
                    + "\(Int(idleElapsed))s — exiting")
                return
            }
            out("preview sweep helper: idle (cache warm, catalog unchanged) — "
                + "\(Int(idleElapsed))s")
        }
    }
}

// MARK: - Final-status box

/// Captures the last status the engine published so a pass can report its
/// terminal state. `@unchecked Sendable` tiny box (lock-guarded) — the
/// publish sink runs on the main actor, the reader on the caller's task.
private final class FinalStatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var status: PreviewSweepStatus = .idle

    func record(_ s: PreviewSweepStatus) {
        lock.lock(); status = s; lock.unlock()
    }
    var value: PreviewSweepStatus {
        lock.lock(); defer { lock.unlock() }; return status
    }
}
