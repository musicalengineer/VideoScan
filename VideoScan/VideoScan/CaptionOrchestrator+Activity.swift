// CaptionOrchestrator+Activity.swift
// Live pipeline activity + bookkeeping for CaptionOrchestrator: in-flight
// count reset, user-initiated skip, the DRM / missing-on-disk flagging
// helpers, the stage-name mapper, and the dashboard lane lifecycle
// (begin/update/end/clear + recordCompletion) — extracted verbatim from
// CaptionOrchestrator.swift (refactor 2026-06-24). The @Published count and
// lane *properties* stay in the main file (extensions can't hold stored
// state); only the methods move here. The pendingWhisper handles and
// userSkippedLaneIDs this code shares with CaptionOrchestrator+Dossier were
// widened to internal in the main file. (Swift extension ≈ C++ partial
// class via free member functions: methods share the same `self`.)

import Foundation
import AVFoundation
import Combine
import os

extension CaptionOrchestrator {

    /// Reset for a fresh batch. Called from runBatch's start; tests
    /// can also call directly.
    func resetLiveCounts() {
        liveCaptioned = 0
        liveSkipped = 0
        liveFailed = 0
        liveCurrentIndex = 0
        liveTotal = 0
        transcriptFailures = 0
        // Stale user-skip flags from a prior batch must not leak into
        // a fresh run — a lane ID is per-batch and never reused, but
        // clearing the set keeps `userSkippedLaneIDs.contains(id)`
        // semantics honest under repeated batches.
        userSkippedLaneIDs.removeAll()
    }

    /// User-initiated skip on an in-flight file. Called from the
    /// dashboard's right-click → Skip on an active lane row.
    ///
    /// Behavior depends on which stage the lane is currently in:
    ///   - **Whisper stage** (most common — long subprocess): cancels
    ///     the in-flight `pendingWhisperTask`. The existing
    ///     CancellationError branch in the Whisper task banks VLM-only
    ///     and tags the completion `"user skipped"`. The Swift Task
    ///     cancellation propagates into AudioTranscriber's cancelTask
    ///     poll, which calls `proc.terminate()` on the Python whisper
    ///     subprocess.
    ///   - **VLM stage**: VLM inference is GPU work that doesn't
    ///     observe Swift cancellation cleanly, so we don't try to
    ///     cancel mid-VLM. Instead we mark the lane as user-skipped;
    ///     when the VLM finishes naturally the loop checks the set,
    ///     skips Whisper dispatch entirely, banks VLM-only, and tags
    ///     `"user skipped"`. Worst-case wait is one VLM duration —
    ///     usually <30s on M4 Max.
    ///
    /// Idempotent: re-skipping a lane that already finished is a no-op.
    func skipLane(_ id: UUID) {
        userSkippedLaneIDs.insert(id)
        // Whisper is the stuck case — if THIS lane is the one whose
        // Whisper is in flight, kill it now. Cancelling a nil task is
        // a no-op so the bookkeeping is safe even after the lane has
        // moved on.
        if pendingWhisperLaneID == id {
            pendingWhisperTask?.cancel()
        }
        captionOrchLog.notice("skipLane: user skipped lane \(id, privacy: .public)")
    }

    /// Cheap DRM probe via AVAsset. Loads only protected-content
    /// metadata (no decode, no audio extraction) — typically tens of
    /// milliseconds even on a slow disk. On any error (file gone,
    /// permission denied, AVFoundation choke) we return false so a
    /// transient miss falls through to the regular VLM/Whisper path
    /// instead of incorrectly marking the record drmProtected forever.
    ///
    /// Static + nonisolated so it doesn't pull the MainActor while
    /// AVAsset's metadata work runs on its own queue.
    nonisolated static func isDRMProtected(path: String) async -> Bool {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        do {
            return try await asset.load(.hasProtectedContent)
        } catch {
            return false
        }
    }

    /// Marker that goes into junkReasons when DRM detection flags a
    /// record. Constant so tests and any future UI surface can match
    /// on it without duplicating the string. Keep "DRM" capitalized
    /// so a future per-reason filter / chip can group on it.
    static let drmSuspectJunkReason = "DRM-protected (no decryption key)"

    /// Mark a record as drm-protected and propose suspectedJunk so it
    /// lands in Rick's triage flow for confirmation. Preserves any
    /// stronger pre-existing disposition — once the user has decided
    /// (important / recoverable / confirmedJunk) we don't second-guess
    /// them. Idempotent on junkReasons so re-flagging across multiple
    /// runs doesn't multiply the entry.
    ///
    /// Rick 2026-06-13: "auto-detect any DRM and skip it and even
    /// flag it as suspected Junk, and later I can confirm it as junk."
    static func flagDRMSuspectJunk(_ record: VideoRecord) {
        record.drmProtected = true
        if record.mediaDisposition == .unreviewed {
            record.mediaDisposition = .suspectedJunk
        }
        if !record.junkReasons.contains(drmSuspectJunkReason) {
            record.junkReasons.append(drmSuspectJunkReason)
        }
    }

    /// Marker that goes into junkReasons when the orchestrator
    /// auto-purges a record because the file isn't on disk anymore.
    /// Distinct from the DRM marker so the user (and future filters)
    /// can tell them apart at triage time.
    static let missingOnDiskReason = "auto-purged: missing on disk"

    /// Soft-purge a record whose underlying file went missing while
    /// the volume IS mounted. `purgedAt` excludes it from the
    /// candidate filter and the eligible coverage count; the row's
    /// "Analyze Complete" can then become true. junkReasons logs
    /// WHY so a future un-purge UI can show context. Idempotent.
    ///
    /// Rick 2026-06-13: "4228/5883 give the impression it is not done."
    /// Auto-purging missing-on-disk drops the denominator so it does.
    static func flagMissingOnDisk(_ record: VideoRecord) {
        if record.purgedAt == nil {
            record.purgedAt = Date()
        }
        if !record.junkReasons.contains(missingOnDiskReason) {
            record.junkReasons.append(missingOnDiskReason)
        }
    }

    /// Map an engine modelID to a short stage family name for the lane
    /// header. Unknown engines fall through to their raw modelID, so a
    /// new stage appears on the dashboard with zero UI changes.
    static func stageDisplayName(forModelID id: String) -> String {
        let lower = id.lowercased()
        if lower.contains("whisper") { return "Whisper" }
        if lower.contains("vlm") || lower.contains("qwen") { return "MLXVLM" }
        return id
    }

    /// Open a lane for a file entering the pipeline. Returns the lane
    /// id so the caller can target it from `updateLane` / `endLane`.
    /// Deduplicates by `path`: a stale lane for the same file (e.g.
    /// from a previous abandoned attempt) is replaced.
    @discardableResult
    func beginLane(
        path: String,
        filename: String,
        isVideoOnly: Bool,
        stage: String,
        verb: String
    ) -> UUID {
        let lane = PipelineLane(
            id: UUID(),
            path: path,
            filename: filename,
            stageName: stage,
            verb: verb,
            startedAt: Date(),
            isVideoOnly: isVideoOnly,
            hasCaptions: false,
            hasTranscript: false,
            transcriptFailed: false
        )
        activeLanes.removeAll { $0.path == path }
        activeLanes.append(lane)
        return lane.id
    }

    /// Patch fields on an active lane in place. Nil arguments leave the
    /// field unchanged — call with only the bits that actually changed
    /// (e.g. just `stage` + `verb` on a stage transition, or just
    /// `hasCaptions: true` when VLM banks its result). No-op if the
    /// lane has already ended.
    func updateLane(
        _ id: UUID,
        stage: String? = nil,
        verb: String? = nil,
        hasCaptions: Bool? = nil,
        hasTranscript: Bool? = nil,
        transcriptFailed: Bool? = nil
    ) {
        guard let i = activeLanes.firstIndex(where: { $0.id == id }) else { return }
        if let stage { activeLanes[i].stageName = stage }
        if let verb { activeLanes[i].verb = verb }
        if let hasCaptions { activeLanes[i].hasCaptions = hasCaptions }
        if let hasTranscript { activeLanes[i].hasTranscript = hasTranscript }
        if let transcriptFailed { activeLanes[i].transcriptFailed = transcriptFailed }
    }

    /// Close a lane. No-op if it was already cleared.
    func endLane(_ id: UUID) {
        activeLanes.removeAll { $0.id == id }
    }

    /// Batch settled (finished or cancelled) — nothing is in flight.
    func clearActiveLanes() {
        activeLanes.removeAll()
    }

    /// Prepend a completed file to the history, enforcing the cap.
    /// Indicator state is mirrored from the lane's final values; the
    /// dashboard's "Recently Completed" rows render ✓/✗/— from these
    /// (Rick 2026-06-13 — indicators moved off the in-flight lane).
    func recordCompletion(
        filename: String,
        path: String,
        vlmSeconds: Double?,
        whisperSeconds: Double?,
        note: String?,
        isVideoOnly: Bool = false,
        hasCaptions: Bool = false,
        hasTranscript: Bool = false,
        transcriptFailed: Bool = false
    ) {
        let entry = CompletedActivity(
            id: UUID(), filename: filename, path: path,
            vlmSeconds: vlmSeconds, whisperSeconds: whisperSeconds,
            note: note, syncedAt: Date(),
            isVideoOnly: isVideoOnly,
            hasCaptions: hasCaptions,
            hasTranscript: hasTranscript,
            transcriptFailed: transcriptFailed
        )
        recentActivity.insert(entry, at: 0)
        if recentActivity.count > Self.recentActivityCap {
            recentActivity.removeLast(recentActivity.count - Self.recentActivityCap)
        }
    }

    /// Snapshot the lane's indicator state and forward to recordCompletion.
    /// Callers should invoke BEFORE endLane(_:) so the lane is still in
    /// activeLanes when we read it. No-op if the lane has already been
    /// closed — the completion still records, just without indicators.
    func recordCompletion(
        fromLane laneID: UUID,
        vlmSeconds: Double?,
        whisperSeconds: Double?,
        note: String?
    ) {
        guard let lane = activeLanes.first(where: { $0.id == laneID }) else {
            // Defensive: lane already ended. Record without indicators
            // or path — the completion still shows in the history but
            // Show in Catalog won't have a target.
            recordCompletion(filename: "?", path: "",
                             vlmSeconds: vlmSeconds,
                             whisperSeconds: whisperSeconds, note: note)
            return
        }
        recordCompletion(
            filename: lane.filename,
            path: lane.path,
            vlmSeconds: vlmSeconds,
            whisperSeconds: whisperSeconds,
            note: note,
            isVideoOnly: lane.isVideoOnly,
            hasCaptions: lane.hasCaptions,
            hasTranscript: lane.hasTranscript,
            transcriptFailed: lane.transcriptFailed
        )
    }
}
