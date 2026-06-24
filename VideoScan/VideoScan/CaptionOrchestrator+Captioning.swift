// CaptionOrchestrator+Captioning.swift
// The single-prompt caption batch loop (runBatch) plus the shared
// progress/ETA publisher (publishProgress) — extracted verbatim from
// CaptionOrchestrator.swift (refactor 2026-06-24). A cross-file
// `extension` can't see `private` members; `runBatch` (called from
// CaptionOrchestrator+Lifecycle) and `publishProgress` (called from
// CaptionOrchestrator+Dossier) were widened to internal in the main file.
// (Swift extension ≈ C++ partial class via free member functions: no new
// stored state allowed, methods share the same `self`.)

import Foundation
import Combine
import os

extension CaptionOrchestrator {

    // MARK: - Batch loop

    /// The heart of the orchestrator. Runs on the active task; calls
    /// back to MainActor for every status write and for the catalog
    /// writeback.
    ///
    /// nonisolated note: this function is on the MainActor (the class
    /// is @MainActor); the per-file work happens by stepping out via
    /// `await runner.caption(...)` which is `nonisolated` already.
    func runBatch(
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
            appLog.write("Analyzing volume: no eligible videos under target")
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
                appLog.write("Analyzing volume: cancelled at file \(idx) of \(total) (analyzed \(captioned), skipped \(skipped), failed \(failed))")
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
                appLog.write("Analyzing volume: cancelled mid-file \(filename) (analyzed \(captioned), skipped \(skipped), failed \(failed))")
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
    func publishProgress(
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
}
