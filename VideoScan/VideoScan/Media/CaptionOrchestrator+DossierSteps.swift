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
// 2026-10-10 (Dossier admits Archived / In Triage, Rick): the preflight
// also
//   * skips a file an earlier run flagged needsReformat (batches only — an
//     explicit single-file Analyze retries it),
//   * skips a file whose VOLUME is offline (never "missing", never failed),
//   * carries a same-footage sibling's text over instead of decoding,
// and an archived row (`VideoScanModel.isDossierReadOnly`) is never
// purged, junk-flagged or reformat-flagged by analysis — it is left as is
// and counted. A videoUnreadable failure flags needsReformat (live rows).
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
    /// Archived row: analysis may write only the dossier channels.
    let readOnly: Bool
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
    /// is skipped or its text was carried over (counters, logs and
    /// progress already handled), otherwise publishes "starting file idx"
    /// and returns the file's plan.
    func preflightDossierFile(
        _ record: VideoRecord,
        index idx: Int,
        total: Int,
        force: Bool,
        framesPerFile: Int,
        started: CFAbsoluteTime,
        model: VideoScanModel
    ) async -> DossierFilePlan? {
        let path = record.fullPath
        let filename = record.filename
        let readOnly = model.isDossierReadOnly(record)
        if let skip = await dossierSkipReason(record, force: force) {
            countDossierSkip(skip, record: record, readOnly: readOnly)
            publishProgress(idx: idx + 1, total: total, currentFile: filename, started: started)
            return nil
        }
        // Same-footage carry-over (zero decode). `force` means "analyze
        // again", so it never carries.
        if !force, let carry = dossierCarryOver, let donor = carry.donor(for: record) {
            model.carryOverDossierText(from: donor.record, to: record, relation: donor.relation)
            liveSkipped += 1
            liveCarriedOver += 1
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
            hasNoVideo: Self.isAudioClass(record),
            readOnly: readOnly
        )
    }

    enum DossierSkip {
        case alreadyAnalyzed, needsReformat, offline, missingOnDisk, drmCached, drmProbed
    }

    /// Why a file is skipped, if it is. Checked in this order:
    /// - already analyzed: any record with a dossier timestamp is left
    ///   alone regardless of which stack produced it (`force` overrides);
    /// - needs reformat: an earlier run could not decode it (batches skip
    ///   it; `force` or an explicit single-file Analyze retries);
    /// - the file is not there: its VOLUME is offline (skipped, not
    ///   failed — never purged), else it is missing on a mounted volume;
    /// - DRM, cached flag, then an AVAsset metadata probe (no decode).
    ///   Encrypted iTunes purchases would otherwise eat hours of Whisper.
    func dossierSkipReason(_ record: VideoRecord, force: Bool) async -> DossierSkip? {
        if !force, record.dossierProcessedAt != nil { return .alreadyAnalyzed }
        if !force, !dossierRetriesNeedsReformat, record.needsReformat { return .needsReformat }
        if !FileManager.default.fileExists(atPath: record.fullPath) {
            return Self.isOnOfflineVolume(record.fullPath) ? .offline : .missingOnDisk
        }
        if record.drmProtected { return .drmCached }
        if await drmProbe(record.fullPath) { return .drmProbed }
        return nil
    }

    /// True when `path` is under /Volumes/<X> and X is not mounted. Internal
    /// paths are never "offline" (the boot disk is always there; a missing
    /// file on it is missing). No disk I/O — the mount table and the
    /// reachability cache.
    static func isOnOfflineVolume(_ path: String) -> Bool {
        path.hasPrefix("/Volumes/") && !VolumeReachability.isVolumeReachable(path: path)
    }

    /// Counters, flags and log lines for one skipped file. A read-only
    /// (archived) row is never purged or junk-flagged here.
    func countDossierSkip(_ skip: DossierSkip, record: VideoRecord, readOnly: Bool) {
        let path = record.fullPath
        let filename = record.filename
        liveSkipped += 1
        switch skip {
        case .alreadyAnalyzed:
            liveSkipAlreadyAnalyzed += 1
        case .needsReformat:
            liveSkipNeedsReformat += 1
            captionOrchLog.info("Dossier: skip needs-reformat (not retried by a batch): \(filename, privacy: .public)")
        case .offline:
            liveSkipOffline += 1
            captionOrchLog.info("Dossier: skip volume offline (not failed): \(path, privacy: .public)")
        case .missingOnDisk:
            liveSkipMissing += 1
            // The auto-purge was ruled for the live pool (Cataloged /
            // Workbench). An Archived or In Triage row — admitted
            // 2026-10-10 — is left as is: it may sit on the FamilyArchive
            // volume, where nothing is removed, and this purge does not
            // pass through that volume's guard.
            if readOnly || !LifecycleStage.liveMediaStages.contains(record.lifecycleStage) {
                liveReadOnlyLeftAsIs += 1
                captionOrchLog.warning("Dossier: missing on disk — left as is (\(record.lifecycleStage.rawValue, privacy: .public)): \(path, privacy: .public)")
                appLog.write("Dossier: missing on disk — left as is (\(record.lifecycleStage.rawValue) rows are not auto-purged by analysis): \(filename)")
                return
            }
            // Soft-purge so the row's eligible count drops and "Analyze
            // Complete" can become true. Reversible via the catalog's
            // restore action. Rick 2026-06-13.
            Self.flagMissingOnDisk(record)
            captionOrchLog.notice("Dossier: missing on disk → auto-purged: \(path, privacy: .public)")
            appLog.write("Dossier: auto-purged missing on disk: \(filename)")
        case .drmCached:
            liveSkipProtected += 1
            captionOrchLog.notice("Dossier: skip DRM-protected (cached): \(filename, privacy: .public)")
            appLog.write("Dossier: skip protected (can't read): \(filename)")
        case .drmProbed:
            liveSkipProtected += 1
            if readOnly {
                liveReadOnlyLeftAsIs += 1
                appLog.write("Dossier: skip DRM-protected archived file (not flagged — archived rows are read-only to analysis): \(filename)")
                return
            }
            Self.flagDRMSuspectJunk(record)
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
    /// A `videoUnreadable` failure also flags the record needsReformat so
    /// the next batch does not try it again (2026-10-10: the same 28 files
    /// had failed on every pass, 26–102 times each).
    func countDossierExtractionFailure(_ laneID: UUID, plan: DossierFilePlan, model: VideoScanModel,
                                       error: Error, label: String) {
        endLane(laneID)
        liveFailed += 1
        captionOrchLog.warning("Dossier: \(label, privacy: .public) on \(plan.filename, privacy: .public): \(error.localizedDescription, privacy: .public)")
        appLog.write("Dossier: failed (extraction error): \(plan.filename) — \(error.localizedDescription)")
        if case CaptionRunnerError.videoUnreadable = error {
            flagUnreadableNeedsReformat(plan, model: model)
        }
    }

    /// Flag a file the extractor could not open at all. Only when the file
    /// is still there on a mounted volume (a drive that dropped mid-batch
    /// is not a codec problem), only on a live row (an archived row is
    /// read-only: the flag would offer to write a reformatted file next
    /// to it), and only once.
    func flagUnreadableNeedsReformat(_ plan: DossierFilePlan, model: VideoScanModel) {
        let record = plan.record
        guard !record.needsReformat,
              FileManager.default.fileExists(atPath: plan.path),
              !Self.isOnOfflineVolume(plan.path) else { return }
        if plan.readOnly {
            liveReadOnlyLeftAsIs += 1
            appLog.write("Dossier: archived file could not be decoded — not flagged (archived rows are read-only to analysis): \(plan.filename)")
            return
        }
        record.needsReformat = true
        liveFlaggedNeedsReformat += 1
        model.noteCatalogChangedForDossierCounts()
        model.saveCatalogDebounced()
        appLog.write("Dossier: flagged needsReformat (video could not be read; batches will not retry it — right-click Analyze to try again): \(plan.filename)")
    }

    /// The extractor DID decode a file flagged needsReformat (an explicit
    /// retry, or a newer ffmpeg): the flag is stale — clear it.
    func clearStaleNeedsReformat(_ plan: DossierFilePlan, extraction: DossierExtraction) {
        guard plan.record.needsReformat, !plan.readOnly, !extraction.scenes.isEmpty else { return }
        plan.record.needsReformat = false
        appLog.write("Dossier: cleared needsReformat (decoded on retry): \(plan.filename)")
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
        // Format unchanged (log formats are a Rick decision); the
        // 2026-10-10 split rides on the separate coverage line below.
        appLog.write(String(format: "Dossier: done — %d processed, %d skipped (%d already analyzed, %d missing, %d protected), %d failed in %.1fs (%@)",
                            captioned, skipped,
                            liveSkipAlreadyAnalyzed, liveSkipMissing, liveSkipProtected,
                            failed, elapsed, stackID))
        appLog.write(dossierCoverageLine())
        // #160: auto-purged missing-on-disk rows flipped purgedAt in place;
        // announce once per batch so cached table/aggregates recompute.
        if liveSkipMissing > 0 { model.noteCatalogRecordsMutated() }
        if reportCancellation, Task.isCancelled {
            appLog.write("Dossier: cancelled (done \(captioned), skipped \(skipped), failed \(failed))")
        }
        currentStatus = .finished(captioned: captioned, skipped: skipped, failed: failed)
    }

    /// The OUTCOME line's second half (additive — the "done" line keeps its
    /// format): what was carried over, not retried, newly flagged, offline,
    /// left as is on archived rows, and what the stage gate admitted / kept
    /// out. Counts and words only; never transcript or caption text.
    func dossierCoverageLine() -> String {
        var parts = [
            "\(liveCarriedOver) carried over from same-footage copies (no decode)",
            "\(liveSkipNeedsReformat) not retried (needs reformat)",
            "\(liveFlaggedNeedsReformat) newly flagged needs reformat",
            "\(liveSkipOffline) on offline volumes (skipped, not failed)",
            "\(liveReadOnlyLeftAsIs) archived / in-triage rows left as is (not purged or flagged)",
            // GH #402: captions refused as degenerate model output (not stored).
            "degenerate refused · \(liveDegenerateRefused)",
        ]
        if let a = dossierAdmission {
            parts.append("admitted \(a.archived) Archived + \(a.inTriage) In Triage")
            parts.append("\(a.offline) eligible on offline volumes not queued")
            parts.append("\(a.notEligibleByStage) not eligible (stage: Trashed / Deleted)")
        }
        return "Dossier: coverage — " + parts.joined(separator: ", ")
    }

    /// The serial loop's early exits (cancelled before or during a file):
    /// settle without the summary line.
    func settleCancelledDossierBatch(_ transcriber: AudioTranscriber?) async {
        clearActiveLanes()
        await settleWhisperWorker(transcriber)
        currentStatus = .finished(captioned: liveCaptioned, skipped: liveSkipped, failed: liveFailed)
    }
}
