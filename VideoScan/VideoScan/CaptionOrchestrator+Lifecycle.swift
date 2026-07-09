// CaptionOrchestrator+Lifecycle.swift
// Public batch-control surface for CaptionOrchestrator: the single-target
// and catalog-wide caption entry points, plus cancel / pause / resume and
// the quit-time shutdown drain — extracted verbatim from
// CaptionOrchestrator.swift (refactor 2026-06-24). A cross-file `extension`
// can't see `private` members, so the handful of orchestrator members this
// code shares with the other split files were widened to internal in the
// main file. (Swift extension ≈ C++ partial class via free member
// functions: no new stored state allowed, methods share the same `self`.)

import Foundation
import Combine
import os

extension CaptionOrchestrator {

    // MARK: - Public API

    /// Kick off captioning for every video record under `target` in the
    /// catalog. Returns when the batch finishes (status transitions to
    /// `.finished`) or is cancelled. Safe to call from a SwiftUI
    /// `.task { ... }` modifier or a button action.
    ///
    /// Idempotent on skip: records with `sceneCaptions` non-empty AND
    /// `sceneCaptionModel == runner.modelID` are skipped unless `force`
    /// is true.
    func startCaptioning(target: CatalogScanTarget, model: VideoScanModel) async {
        // App is quitting — refuse to start a new batch. See
        // isShuttingDown's doc comment for why this matters for the
        // catalog-wide sweep loops.
        guard !isShuttingDown else {
            captionOrchLog.notice("startCaptioning refused — app is shutting down")
            return
        }
        // Guard against double-start. Mirrors PersonFinderModel.startJob's
        // `guard !job.status.isActive` pattern.
        guard !currentStatus.isActive else {
            captionOrchLog.warning("startCaptioning called while already \(String(describing: self.currentStatus))")
            return
        }

        currentTarget = target
        currentStatus = .running(progress: 0.0, currentFile: "(loading model…)", etaSec: nil)

        // Capture refs we need inside the detached task — orchestrator
        // mutations happen back on MainActor via `await MainActor.run`.
        let runner = runnerFactory()
        let force = self.force
        let frames = self.framesPerFile

        // Filter the catalog records to this target's volume. We
        // include videoAndAudio + videoOnly (the latter is correlated
        // / orphan media that often DOES carry video essence — and the
        // user may want captions there too). Audio-only and no-stream
        // records are skipped — no video frames to caption.
        let allRecords = model.records
        let targetPrefix = target.searchPath
        let candidates: [VideoRecord] = allRecords.filter { r in
            r.fullPath.hasPrefix(targetPrefix) &&
            (r.streamType == .videoAndAudio || r.streamType == .videoOnly)
        }

        captionOrchLog.info("CaptionOrchestrator starting: target=\(targetPrefix, privacy: .public), candidates=\(candidates.count), engine=\(runner.modelID, privacy: .public), force=\(force)")
        appLog.write("Analyzing volume: starting \(candidates.count) candidate(s) on \(VolumeReachability.displayLabel(forPath: targetPrefix)) with \(runner.modelID)")

        activeTask = Task { [weak self] in
            await self?.runBatch(
                runner: runner,
                candidates: candidates,
                framesPerFile: frames,
                force: force,
                model: model
            )
        }

        // Await the task so callers can `await startCaptioning(...)`
        // and get back when the batch settles.
        await activeTask?.value
    }

    /// Catalog-wide captioning: iterate every reachable scan target in
    /// sequence, captioning every eligible video. Idempotent: records
    /// already captioned with the current engine's modelID are skipped
    /// by the existing per-target loop (the same skip predicate that
    /// drives `startCaptioning(target:)`). That property gives us "free"
    /// pause/resume — if the user quits mid-batch, the next invocation
    /// picks up where we left off because the completed records are
    /// already persisted with their captions.
    ///
    /// Sequential by design (v1): the VLM is GPU-heavy; running
    /// multiple targets in parallel would just contend for the same
    /// MLX compute. Per-target progress lights up through the existing
    /// currentStatus / currentTarget published state.
    ///
    /// Roadmap item #4 (2026-06-04). See
    /// docs/family-tagging-and-search-roadmap.md and
    /// `pfCatalogWideMetadataCandidates`.
    func startCatalogWideCaptioning(model: VideoScanModel) async {
        guard !isShuttingDown else {
            captionOrchLog.notice("startCatalogWideCaptioning refused — app is shutting down")
            return
        }
        guard !currentStatus.isActive else {
            captionOrchLog.warning("startCatalogWideCaptioning called while already \(String(describing: self.currentStatus))")
            return
        }

        let reachable = CatalogScanTarget.analyzeCandidates(model.scanTargets)
        captionOrchLog.info("Catalog-wide caption: \(reachable.count) reachable target(s)")
        appLog.write("Analyzing catalog: starting across \(reachable.count) reachable volume(s)")

        guard !reachable.isEmpty else {
            currentStatus = .finished(captioned: 0, skipped: 0, failed: 0)
            return
        }

        for target in reachable {
            if Task.isCancelled { break }
            // Per-target invocation reuses the existing batch loop,
            // including idempotent skip + per-file cancellation. Status
            // publishing already happens inside.
            await startCaptioning(target: target, model: model)
            // After each target settles, currentStatus is .finished —
            // reset to idle before the next target's startCaptioning
            // call so its guard doesn't bail.
            if !Task.isCancelled {
                currentStatus = .idle
            }
        }

        appLog.write("Analyzing catalog: completed sweep across \(reachable.count) volume(s)")
        currentStatus = .finished(captioned: 0, skipped: 0, failed: 0)
    }

    /// Request cancellation. Flips status to `.cancelling`. The active
    /// task observes `Task.isCancelled` / `Task.checkCancellation()` in
    /// the per-file loop (and inside the runner's per-frame loop, see
    /// CaptionRunner.swift) and exits promptly.
    func cancel() {
        guard currentStatus.isActive else { return }
        captionOrchLog.notice("CaptionOrchestrator cancel requested")
        currentStatus = .cancelling
        activeTask?.cancel()
    }

    /// Halt new work without cancelling in-flight tasks. The loop
    /// checks `paused` before dispatching the next file and awaits
    /// until cleared (200ms poll — cheap enough for a UI gesture).
    /// The currently-running VLM/Whisper task is NOT signaled so it
    /// runs to completion, then the loop pauses before the next.
    ///
    /// Setting paused while idle is legal: the next batch start will
    /// trip the gate on its first iteration. (Useful for tests and
    /// for a "pause before resuming on launch" UX if we add it.)
    func pause() {
        guard !paused else { return }
        captionOrchLog.notice("CaptionOrchestrator pause requested")
        paused = true
    }

    /// Resume after `pause()`. The loop's await-while-paused exits and
    /// the next file dispatches. No-op if not paused.
    func resume() {
        guard paused else { return }
        captionOrchLog.notice("CaptionOrchestrator resume requested")
        paused = false
    }

    /// Quit-time drain. Latches `isShuttingDown` (so no new batch can
    /// start — including the next volume in a catalog-wide sweep),
    /// cancels the active batch, and waits for the in-flight task to
    /// settle, bounded by `deadline`.
    ///
    /// Returns `true` if the batch fully drained (or nothing was
    /// running), `false` if the deadline expired with inference still
    /// in flight. On `false` the caller must NOT touch MLX (no stream
    /// synchronize — it could block behind the running generation);
    /// the `_exit` backstop in applicationWillTerminate covers teardown.
    ///
    /// Unfinished captions are simply not written back — per-file
    /// writeback means everything completed before the cancel is
    /// already persisted, and the idempotent skip resumes the batch on
    /// next launch exactly where it left off.
    ///
    /// Must be awaited off the main thread's *blocking* path: the batch
    /// task hops through the MainActor for status writes, so a
    /// synchronous wait on the main thread would deadlock. AppDelegate
    /// uses `.terminateLater` + `NSApp.reply` to keep the runloop alive
    /// while this awaits.
    /// Synchronously latch `isShuttingDown` WITHOUT draining. For quit
    /// paths where no batch is active yet — most importantly a fast
    /// Cmd-Q during the DossierAutoResume launch delay (VideoScanApp
    /// schedules startCatalogWideDossier ~3s after launch): with
    /// nothing active, applicationShouldTerminate skips the drain, so
    /// without this latch the deferred auto-resume task could still
    /// start fresh VLM inference while AppKit tears down. ≈ C++
    /// `std::atomic<bool> g_shutting_down` set in the quit handler;
    /// here MainActor isolation replaces the atomic.
    func beginShutdown() {
        isShuttingDown = true
    }

    @discardableResult
    func drainForShutdown(deadline: TimeInterval = 5.0) async -> Bool {
        isShuttingDown = true
        guard currentStatus.isActive, let task = activeTask else { return true }
        shutdownLog.notice("drainForShutdown: cancelling active VLM batch, waiting up to \(String(format: "%.1f", deadline))s")
        currentStatus = .cancelling
        task.cancel()

        // Race batch completion against the deadline with two
        // unstructured tasks + a once-latch. Deliberately NOT a
        // `withTaskGroup` race: the group awaits ALL children before
        // returning, and `await task.value` on a non-throwing Task is
        // not cancellation-responsive — so a group would block until
        // the batch actually finished, defeating the bound (caught by
        // CaptionOrchestratorShutdownTests' stubborn-engine test).
        // If the deadline wins, the orphaned waiter just finishes
        // silently whenever the batch does; the latch makes its
        // continuation-resume a no-op.
        let drained = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let once = DrainOnceLatch()
            let timer = Task {
                try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                if once.tryClaim() { cont.resume(returning: false) }
            }
            Task {
                await task.value
                timer.cancel()  // stop the deadline clock; sleep throws out
                if once.tryClaim() { cont.resume(returning: true) }
            }
        }
        if drained {
            shutdownLog.notice("drainForShutdown: batch drained cleanly")
        } else {
            shutdownLog.error("drainForShutdown: deadline expired — inference may still be dispatching GPU work")
        }
        return drained
    }
}

// MARK: - Drain race latch

/// Thread-safe claim-once flag for the drain's completion-vs-deadline
/// race — whichever side claims first resumes the continuation; the
/// loser's claim fails and it does nothing. ≈ C++ `std::call_once`
/// guarding a promise's set_value.
private final class DrainOnceLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func tryClaim() -> Bool {
        lock.withLock {
            if claimed { return false }
            claimed = true
            return true
        }
    }
}
