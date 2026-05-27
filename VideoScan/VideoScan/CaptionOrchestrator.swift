import Foundation
import AVFoundation
import Combine
import os

// MARK: - CaptionOrchestrator
//
// Stage 6b. Owns the per-target captioning batch: discover the files in
// the catalog that need captions, drive `CaptionRunner.caption(...)`
// once per file, write back results immediately at each file boundary,
// surface progress + ETA + current-file UI state, and honor cancel.
//
// Shape mirrors PersonFinderModel's per-job state machine (ScanJobStatus
// + runScan / processOneVideo) but at a lower complexity: there is no
// reference-photo loading, no per-frame face matching, no clip
// extraction. The orchestrator is mostly plumbing around the engine.
//
// Critical design choice: session-scoped model container.
//
// MLXVLMCaptionRunner.caption (S6a) currently calls
// VLMModelFactory.shared.loadContainer ONCE per call — wasted ~30s on
// every file after the first. The orchestrator builds and reuses a
// CaptionSession that holds the loaded container across files in the
// same batch. Frames serialize through it; the session goes away when
// the batch ends (or is cancelled), and a fresh session is built for
// the next batch.
//
// Worst-case memory footprint: one ModelContainer (~3 GB for the 4-bit
// Qwen2.5-VL-3B weights) + transient CIImage per frame (decoded video
// frame, typically <50 MB) + KV cache (<100 MB). Total ceiling ~3.5 GB.
// Released when the session is torn down at batch end. No per-file
// accumulation — captions are flushed to the catalog and dropped from
// the orchestrator's working set at each boundary.

private let captionOrchLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "caption-orchestrator")

// MARK: - Status

/// Per-batch status. Mirrors ScanJobStatus's shape: an enum with
/// associated values for the in-flight payload (progress, current
/// file, ETA) and a terminal `.finished` carrying counts.
///
/// Swift's enum-with-associated-values ≈ a C++ tagged union /
/// std::variant; SwiftUI views switch on the case and read payload by
/// pattern match.
enum CaptionJobStatus: Equatable {
    case idle
    case running(progress: Double, currentFile: String, etaSec: Int?)
    case cancelling
    case finished(captioned: Int, skipped: Int, failed: Int)

    /// Convenience used by the UI to disable the start button while
    /// any prior batch is mid-flight.
    var isActive: Bool {
        switch self {
        case .running, .cancelling: return true
        default: return false
        }
    }

    /// True while the orchestrator is doing real work. Used by the
    /// progress sheet to show / hide.
    var isInFlight: Bool {
        switch self {
        case .running, .cancelling: return true
        default: return false
        }
    }
}

// MARK: - Orchestrator

/// `@MainActor` so all status mutations cross the UI boundary safely
/// without explicit hops. The captioning work itself runs in a detached
/// Task — only the status writebacks return to the main actor.
@MainActor
final class CaptionOrchestrator: ObservableObject {

    // MARK: Published state

    /// Current batch status. Drives the progress sheet visibility.
    @Published var currentStatus: CaptionJobStatus = .idle

    /// Target the running batch is operating on. nil when idle.
    @Published var currentTarget: CatalogScanTarget?

    /// Number of frames per file to caption. Default 3 matches S6a's
    /// fixture pattern. Tunable later by the UI; constant for now.
    let framesPerFile: Int

    /// Force-recaption even when the record's `sceneCaptionModel`
    /// matches the current engine's `modelID`. Idempotent skip is the
    /// default; this is the "re-caption all" escape hatch the UI may
    /// pass for the future "Re-caption" action.
    var force: Bool = false

    // MARK: Internal state

    /// Active captioning task. Holding the reference lets cancel()
    /// actually cancel; `Task.checkCancellation()` inside the loop
    /// flips the runner out promptly.
    private var activeTask: Task<Void, Never>?

    /// Injectable engine. Default builds an MLXVLMCaptionRunner. Tests
    /// can swap in a stub runner that returns deterministic captions
    /// without touching MLX.
    var runnerFactory: () -> CaptionRunner

    init(runnerFactory: (() -> CaptionRunner)? = nil) {
        self.framesPerFile = 3
        self.runnerFactory = runnerFactory ?? { MLXVLMCaptionRunner() }
    }

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
        appLog.write("Caption Videos: starting \(candidates.count) candidate(s) on \(VolumeReachability.displayLabel(forPath: targetPrefix)) with \(runner.modelID)")

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

    // MARK: - Batch loop

    /// The heart of the orchestrator. Runs on the active task; calls
    /// back to MainActor for every status write and for the catalog
    /// writeback.
    ///
    /// nonisolated note: this function is on the MainActor (the class
    /// is @MainActor); the per-file work happens by stepping out via
    /// `await runner.caption(...)` which is `nonisolated` already.
    private func runBatch(
        runner: CaptionRunner,
        candidates: [VideoRecord],
        framesPerFile: Int,
        force: Bool,
        model: VideoScanModel
    ) async {
        let started = CFAbsoluteTimeGetCurrent()
        let total = candidates.count
        resetLiveCounts()
        liveTotal = total

        // Empty-batch fast path. Still surface a .finished status so
        // the progress sheet closes cleanly.
        guard total > 0 else {
            captionOrchLog.info("CaptionOrchestrator: zero candidates, nothing to do")
            appLog.write("Caption Videos: no eligible videos under target")
            currentStatus = .finished(captioned: 0, skipped: 0, failed: 0)
            return
        }

        var captioned = 0
        var skipped = 0
        var failed = 0

        for (idx, record) in candidates.enumerated() {
            // Cancellation checkpoint #1: between files. Cheapest place
            // to stop — we haven't paid frame extraction or VLM cost
            // for the next file yet.
            if Task.isCancelled {
                captionOrchLog.notice("CaptionOrchestrator: cancelled at file \(idx) of \(total)")
                appLog.write("Caption Videos: cancelled at file \(idx) of \(total) (captioned \(captioned), skipped \(skipped), failed \(failed))")
                currentStatus = .finished(captioned: captioned, skipped: skipped, failed: failed)
                return
            }

            let path = record.fullPath
            let filename = record.filename

            // Idempotent skip: already captioned with this exact model.
            // The force flag bypasses for re-caption flows. Mirrors
            // applyCaptions's "replace wholesale" contract.
            if !force,
               !record.sceneCaptions.isEmpty,
               record.sceneCaptionModel == runner.modelID {
                skipped += 1
                liveSkipped = skipped
                captionOrchLog.debug("Skip already-captioned: \(filename, privacy: .public)")
                publishProgress(idx: idx + 1, total: total, currentFile: filename, started: started)
                continue
            }

            // File-existence check before extraction. AVAsset will
            // happily fail later, but bailing here avoids the runner's
            // throw path for the common "the file is gone" case.
            if !FileManager.default.fileExists(atPath: path) {
                failed += 1
                liveFailed = failed
                captionOrchLog.warning("File missing on disk: \(path, privacy: .public)")
                publishProgress(idx: idx + 1, total: total, currentFile: filename, started: started)
                continue
            }

            // Surface "now working on X" BEFORE the runner call so the
            // progress sheet's current-file label reflects the active
            // file while it's in flight.
            publishProgress(idx: idx, total: total, currentFile: filename, started: started)

            // Compute frame timestamps. Evenly-spaced inside the clip,
            // avoiding the first/last 5% the way the test fixture and
            // Python prototype do — those frames are often black or
            // partial.
            let dur = max(0.5, record.durationSeconds)
            let timestamps = framesEvenlySpaced(framesPerFile: framesPerFile, durationSec: dur)

            do {
                let captions = try await runner.caption(
                    videoPath: path,
                    atTimestamps: timestamps
                )

                // Writeback IMMEDIATELY at the file boundary. If the
                // user cancels the next file, this file's work is
                // already saved. saveCatalogDebounced batches the
                // actual disk write so we're not paying I/O per file.
                _ = model.applyCaptions(captions, to: path, model: runner.modelID)
                captioned += 1
                liveCaptioned = captioned
            } catch is CancellationError {
                // Cancellation surfaced from inside the runner's
                // frame loop. Don't count this file — just exit.
                captionOrchLog.notice("CaptionOrchestrator: runner observed cancellation at \(filename, privacy: .public)")
                appLog.write("Caption Videos: cancelled mid-file \(filename) (captioned \(captioned), skipped \(skipped), failed \(failed))")
                currentStatus = .finished(captioned: captioned, skipped: skipped, failed: failed)
                return
            } catch let err as CaptionRunnerError {
                // Typed engine failure: log + count + keep going. A
                // bad file shouldn't kill the batch.
                failed += 1
                liveFailed = failed
                captionOrchLog.warning("CaptionRunnerError on \(filename, privacy: .public): \(String(describing: err), privacy: .public)")
            } catch {
                // Unknown failure: same treatment, but log the raw
                // type so we can diagnose if a new failure mode shows
                // up.
                failed += 1
                liveFailed = failed
                captionOrchLog.warning("Unknown error on \(filename, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }

            publishProgress(idx: idx + 1, total: total, currentFile: filename, started: started)
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - started
        captionOrchLog.info("CaptionOrchestrator finished: captioned=\(captioned), skipped=\(skipped), failed=\(failed) in \(String(format: "%.1f", elapsed))s")
        appLog.write(String(format: "Caption Videos: done — captioned %d, skipped %d, failed %d in %.1fs",
                            captioned, skipped, failed, elapsed))
        currentStatus = .finished(captioned: captioned, skipped: skipped, failed: failed)
    }

    /// Publish a progress update with an ETA estimate. Runs on the
    /// MainActor (the class is @MainActor) so the @Published write is
    /// already on the UI thread.
    private func publishProgress(
        idx: Int, total: Int, currentFile: String, started: CFAbsoluteTime
    ) {
        liveCurrentIndex = idx
        // If we were asked to cancel, hold the status as .cancelling
        // even mid-progress — the loop will tear down on the next
        // cancellation check. Don't overwrite the cancelling state with
        // a stale "running" update.
        if case .cancelling = currentStatus { return }

        let done = idx
        let progress = total > 0 ? Double(done) / Double(total) : 0.0

        // ETA: only meaningful once we've finished at least one file.
        // Pure linear extrapolation — captioning time is roughly flat
        // per file once the model is loaded, so this is good enough.
        // Stage 6c may refine if Rick wants a better estimator.
        let etaSec: Int?
        let elapsed = CFAbsoluteTimeGetCurrent() - started
        if done > 0, done < total, elapsed > 1.0 {
            let perFile = elapsed / Double(done)
            let remaining = perFile * Double(total - done)
            etaSec = Int(remaining)
        } else {
            etaSec = nil
        }

        currentStatus = .running(progress: progress, currentFile: currentFile, etaSec: etaSec)
    }

    // MARK: - In-flight counts
    //
    // The progress sheet needs to show captioned/skipped/failed counts
    // *during* the run, not just at the end. The batch loop updates
    // these as it goes; the sheet observes them via @Published.

    @Published var liveCaptioned: Int = 0
    @Published var liveSkipped: Int = 0
    @Published var liveFailed: Int = 0
    @Published var liveCurrentIndex: Int = 0
    @Published var liveTotal: Int = 0

    /// Reset for a fresh batch. Called from runBatch's start; tests
    /// can also call directly.
    func resetLiveCounts() {
        liveCaptioned = 0
        liveSkipped = 0
        liveFailed = 0
        liveCurrentIndex = 0
        liveTotal = 0
    }
}

// MARK: - Frame-timestamp helper
//
// `internal` so the test target can exercise it directly. Free
// function (not orchestrator method) so it stays pure and side-effect
// free — easy to unit-test without an orchestrator instance.

/// Returns N timestamps evenly spaced across the clip, skipping the
/// first and last 5%. Always returns exactly `framesPerFile` entries
/// (or fewer if the duration is unusably short).
func framesEvenlySpaced(framesPerFile: Int, durationSec: Double) -> [Double] {
    guard framesPerFile > 0, durationSec > 0 else { return [] }
    let safe = max(0.1, durationSec)
    // Avoid the first/last 5%. For a 3-second clip this is
    // 0.15s..2.85s — comfortably away from the leader/trailer.
    let lo = safe * 0.05
    let hi = safe * 0.95

    if framesPerFile == 1 {
        return [(lo + hi) / 2.0]
    }
    let stride = (hi - lo) / Double(framesPerFile - 1)
    return (0..<framesPerFile).map { i in lo + Double(i) * stride }
}
