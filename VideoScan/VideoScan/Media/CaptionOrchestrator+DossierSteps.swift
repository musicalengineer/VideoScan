// CaptionOrchestrator+DossierSteps.swift
// The building blocks of the two dossier batch loops in
// CaptionOrchestrator+Dossier.swift (refactor 2026-10-07, GH #281).
//
// Before this split, `runDossierBatch` (pipelined, ~450 lines) and
// `runDossierBatchSerial` (~270 lines) each carried their own copy of the
// per-file preflight (already analyzed / missing / DRM), the pause gate,
// the "bank a dossier and close the lane" sequence and the end-of-batch
// summary. Each step now lives here once and both loops call it, so a fix
// to, say, the DRM gate can no longer land in one loop and miss the other.
// Behaviour is pinned by DossierBatchCharacterizationTests (goldens
// recorded from the pre-refactor code).
//
// (C++ reading: an `extension` adds member functions to the existing
// class; `DossierFilePlan` is a plain value struct, like a const POD
// passed by value.)

import Foundation
import os

/// Everything one file's dossier needs, decided once before any work runs.
struct DossierFilePlan {
    let record: VideoRecord
    let index: Int
    let path: String
    let filename: String
    let timestamps: [Double]
    /// Video-only stream: never dispatch Whisper.
    let hasNoAudio: Bool
    /// Audio-class file (mp3 with cover art, …): never extract frames.
    let hasNoVideo: Bool
}

/// What a per-file step tells its batch loop to do next.
enum DossierLoopControl {
    case next
    case stop
}

extension CaptionOrchestrator {

    // MARK: - Shared gates

    /// Pause gate: while paused, poll every 200 ms. Work already in
    /// flight keeps running; only the next file waits. Stop still breaks
    /// through a paused state because the loop re-checks cancellation.
    func waitWhileDossierPaused() async {
        while paused && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    /// The per-file preflight both loops share. Returns nil when the file
    /// is skipped (counters, logs and progress already handled), otherwise
    /// publishes "starting file idx" and returns the file's plan.
    func preflightDossierFile(
        _ record: VideoRecord,
        index idx: Int,
        total: Int,
        force: Bool,
        framesPerFile: Int,
        started: CFAbsoluteTime
    ) async -> DossierFilePlan? {
        let path = record.fullPath
        let filename = record.filename
        if let skip = await dossierSkipReason(record, force: force) {
            countDossierSkip(skip, record: record)
            publishProgress(idx: idx + 1, total: total, currentFile: filename, started: started)
            return nil
        }
        publishProgress(idx: idx, total: total, currentFile: filename, started: started)
        let dur = max(0.5, record.durationSeconds)
        return DossierFilePlan(
            record: record,
            index: idx,
            path: path,
            filename: filename,
            timestamps: framesEvenlySpaced(framesPerFile: framesPerFile, durationSec: dur),
            hasNoAudio: record.streamType == .videoOnly,
            hasNoVideo: Self.isAudioClass(record)
        )
    }

    enum DossierSkip {
        case alreadyAnalyzed, missingOnDisk, drmCached, drmProbed
    }

    /// Why a file is skipped, if it is. Checked in this order:
    /// - already analyzed: any record with a dossier timestamp is left
    ///   alone regardless of which stack produced it (`force` overrides);
    /// - missing on disk: the volume is mounted (the candidate filter
    ///   checked) but the entry is stale;
    /// - DRM, cached flag, then an AVAsset metadata probe (no decode).
    ///   Encrypted iTunes purchases would otherwise eat hours of Whisper.
    func dossierSkipReason(_ record: VideoRecord, force: Bool) async -> DossierSkip? {
        if !force, record.dossierProcessedAt != nil { return .alreadyAnalyzed }
        if !FileManager.default.fileExists(atPath: record.fullPath) { return .missingOnDisk }
        if record.drmProtected { return .drmCached }
        if await Self.isDRMProtected(path: record.fullPath) { return .drmProbed }
        return nil
    }

    /// Counters, flags and log lines for one skipped file.
    func countDossierSkip(_ skip: DossierSkip, record: VideoRecord) {
        let path = record.fullPath
        let filename = record.filename
        liveSkipped += 1
        switch skip {
        case .alreadyAnalyzed:
            liveSkipAlreadyAnalyzed += 1
        case .missingOnDisk:
            // Soft-purge so the row's eligible count drops and "Analyze
            // Complete" can become true. Reversible via the catalog's
            // restore action. Rick 2026-06-13.
            Self.flagMissingOnDisk(record)
            liveSkipMissing += 1
            captionOrchLog.notice("Dossier: missing on disk → auto-purged: \(path, privacy: .public)")
            appLog.write("Dossier: auto-purged missing on disk: \(filename)")
        case .drmCached:
            liveSkipProtected += 1
            captionOrchLog.notice("Dossier: skip DRM-protected (cached): \(filename, privacy: .public)")
            appLog.write("Dossier: skip protected (can't read): \(filename)")
        case .drmProbed:
            Self.flagDRMSuspectJunk(record)
            liveSkipProtected += 1
            captionOrchLog.notice("Dossier: skip DRM-protected (probed, → suspectedJunk): \(filename, privacy: .public)")
            appLog.write("Dossier: skip DRM-protected: \(filename) (flagged suspectedJunk)")
        }
    }

    /// Audio-class record: no frame extraction / VLM. Extension-aware —
    /// an mp3 with embedded cover art probes as Video+Audio (2026-07-14).
    static func isAudioClass(_ record: VideoRecord) -> Bool {
        if case .audio = AnalysisScope.classify(
            streamTypeRaw: record.streamTypeRaw,
            filename: record.filename) { return true }
        return false
    }

    // MARK: - Banking and lane close-out

    /// Bank the dossier on the record, VLM result only (no transcript).
    func bankVLMOnly(_ extraction: DossierExtraction, _ plan: DossierFilePlan,
                     model: VideoScanModel, vlmModelID: String) {
        _ = model.applyDossier(
            extraction, to: plan.path,
            vlmModel: vlmModelID,
            transcript: nil,
            whisperModel: nil
        )
    }

    /// Snapshot the lane into the activity feed, close it, count the file.
    /// Order matters: `recordCompletion(fromLane:)` reads the lane that
    /// `endLane` removes.
    func completeDossierLane(_ laneID: UUID, vlmSeconds: Double?,
                             whisperSeconds: Double?, note: String?) {
        recordCompletion(fromLane: laneID, vlmSeconds: vlmSeconds,
                         whisperSeconds: whisperSeconds, note: note)
        endLane(laneID)
        liveCaptioned += 1
    }

    /// One visible line per extraction failure — the 2026-07-14 perf
    /// diagnosis found 1,097 failed attempts that produced ~1 log line.
    func countDossierExtractionFailure(_ laneID: UUID, filename: String, error: Error, label: String) {
        endLane(laneID)
        liveFailed += 1
        captionOrchLog.warning("Dossier: \(label, privacy: .public) on \(filename, privacy: .public): \(error.localizedDescription, privacy: .public)")
        appLog.write("Dossier: failed (extraction error): \(filename) — \(error.localizedDescription)")
    }

    /// Dashboard ✓ follows banked truth: an empty or whitespace-only
    /// transcript is "no useful content", not "got it".
    static func isUsableTranscript(_ transcript: String?) -> Bool {
        transcript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    // MARK: - End of batch

    /// Settle the batch: nothing is in flight, history stays, the Whisper
    /// worker exits, the summary is logged and the status published.
    /// `reportCancellation` adds the pipelined loop's trailing
    /// "cancelled" line (the serial loop logs its own on the way out).
    func finishDossierBatch(
        model: VideoScanModel,
        transcriber: AudioTranscriber?,
        stackID: String,
        started: CFAbsoluteTime,
        reportCancellation: Bool
    ) async {
        clearActiveLanes()
        await settleWhisperWorker(transcriber)

        let elapsed = CFAbsoluteTimeGetCurrent() - started
        let captioned = liveCaptioned, skipped = liveSkipped, failed = liveFailed
        captionOrchLog.info("Dossier batch done: captioned=\(captioned), skipped=\(skipped), failed=\(failed) in \(String(format: "%.1f", elapsed))s")
        appLog.write(String(format: "Dossier: done — %d processed, %d skipped (%d already analyzed, %d missing, %d protected), %d failed in %.1fs (%@)",
                            captioned, skipped,
                            liveSkipAlreadyAnalyzed, liveSkipMissing, liveSkipProtected,
                            failed, elapsed, stackID))
        // #160: auto-purged missing-on-disk rows flipped purgedAt in place;
        // announce once per batch so cached table/aggregates recompute.
        if liveSkipMissing > 0 { model.noteCatalogRecordsMutated() }
        if reportCancellation, Task.isCancelled {
            appLog.write("Dossier: cancelled (done \(captioned), skipped \(skipped), failed \(failed))")
        }
        currentStatus = .finished(captioned: captioned, skipped: skipped, failed: failed)
    }

    /// The serial loop's early exits (cancelled before or during a file):
    /// settle without the summary line.
    func settleCancelledDossierBatch(_ transcriber: AudioTranscriber?) async {
        clearActiveLanes()
        await settleWhisperWorker(transcriber)
        currentStatus = .finished(captioned: liveCaptioned, skipped: liveSkipped, failed: liveFailed)
    }
}
