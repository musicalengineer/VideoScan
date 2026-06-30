import Foundation

// MARK: - Rescan field preservation
//
// Rick 2026-06-07: triggered "Update Catalog" rescan on LaCieWorkspace
// (after a successful rescue copy) and the dossier dial dropped from
// ~28% to <1%. Root cause: startTarget() does
//   records.removeAll { $0.fullPath.hasPrefix(target.searchPath) }
// then the fresh scan re-creates VideoRecord instances. Brand-new
// records have no dossier fields, no user-edit tags, no dispositions.
// The expensive Qwen + Whisper work — *hours* of compute per volume —
// would be silently lost on every routine rescan.
//
// This file adds a snapshot-and-restore pass. Before the removeAll,
// VideoScanModel captures the user-bearing fields keyed by fullPath.
// After the scan completes and produces targetRecords, the
// preservation helper merges the snapshotted fields back onto any
// new record whose fullPath was previously known. New paths land
// without preservation (no prior data to restore); paths that are
// no longer on disk drop out (the file genuinely went away).
//
// What we preserve (the irreplaceable bits):
//   Dossier channels    — captions, transcript, OCR text, OCR dates,
//                         inferredRecordDate, confidence, processed
//                         provenance.
//   User-edit fields    — detectedPeople, suspectedPeople,
//                         confirmedByUserPeople, rejectedPeople,
//                         mediaDisposition, lifecycleStage,
//                         archiveStage, starRating, junkScore, notes.
//
// What we DON'T preserve (the scan re-derives these from disk):
//   filename, ext, size, sizeBytes, duration, durationSeconds,
//   container, videoCodec, resolution, frameRate, audioCodec,
//   audioChannels, audioSampleRate, timecode, dateCreatedRaw,
//   dateModifiedRaw, partialMD5, etc. — these reflect the file's
//   current bytes, so a rescan refreshing them is correct.

/// Snapshot of the fields a rescan must not destroy. One per record.
///
/// This is a `Sendable` value-type carrier: all stored properties are
/// themselves Sendable (the LifecycleStage / MediaDisposition /
/// ArchiveStage enums conform), so an instance can be stashed in
/// `pendingPreservedFields` and cross actor boundaries freely.
///
/// `init(from:)` and `apply(to:)` are the only members that touch a
/// `VideoRecord`. They are `@MainActor` because VideoRecord is moving
/// toward main-actor isolation — reading/writing its fields must happen
/// on the main actor. Both are invoked solely from the @MainActor
/// snapshot/apply helpers below, so the annotation is a runtime no-op
/// (the calls were already on the main actor); it just makes the
/// isolation explicit for the compiler.
// `@MainActor` on a method ≈ "this member may only run on the UI thread";
// the struct itself stays a plain Sendable value (like a POD that's safe
// to copy across threads — only these two accessors are pinned).
struct RescanPreservedFields: Sendable {

    // Dossier channels
    let sceneCaptions: [SceneCaption]
    let sceneCaptionModel: String?
    let sceneCaptionDate: Date?
    let audioTranscript: String?
    let audioTranscriptModel: String?
    let audioTranscriptDate: Date?
    let ocrDateCandidates: [SceneCaption]
    let ocrText: [SceneCaption]
    let inferredRecordDate: Date?
    let inferredDateConfidence: Float?
    let dossierProcessedAt: Date?
    let dossierProcessedBy: String?

    // User-edit fields — manual tags, dispositions, ratings, notes.
    let detectedPeople: [String]
    let suspectedPeople: [String]
    let confirmedByUserPeople: [ConfirmedTag]
    let rejectedPeople: [String]
    let mediaDisposition: MediaDisposition
    let lifecycleStage: LifecycleStage
    let archiveStage: ArchiveStage
    let starRating: Int
    let junkScore: Int
    let notes: String

    /// True if this snapshot carries anything worth restoring.
    /// Records that have only scan-derived data don't need to be in
    /// the snapshot map at all — caller can use this to filter and
    /// keep the map small.
    var isWorthRestoring: Bool {
        !sceneCaptions.isEmpty
            || !(audioTranscript ?? "").isEmpty
            || !ocrDateCandidates.isEmpty
            || !ocrText.isEmpty
            || dossierProcessedAt != nil
            || !detectedPeople.isEmpty
            || !suspectedPeople.isEmpty
            || !confirmedByUserPeople.isEmpty
            || !rejectedPeople.isEmpty
            || mediaDisposition != .unreviewed
            || lifecycleStage != .cataloged
            || archiveStage != .none
            || starRating != 0
            || junkScore != 0
            || !notes.isEmpty
    }

    @MainActor
    init(from rec: VideoRecord) {
        self.sceneCaptions = rec.sceneCaptions
        self.sceneCaptionModel = rec.sceneCaptionModel
        self.sceneCaptionDate = rec.sceneCaptionDate
        self.audioTranscript = rec.audioTranscript
        self.audioTranscriptModel = rec.audioTranscriptModel
        self.audioTranscriptDate = rec.audioTranscriptDate
        self.ocrDateCandidates = rec.ocrDateCandidates
        self.ocrText = rec.ocrText
        self.inferredRecordDate = rec.inferredRecordDate
        self.inferredDateConfidence = rec.inferredDateConfidence
        self.dossierProcessedAt = rec.dossierProcessedAt
        self.dossierProcessedBy = rec.dossierProcessedBy
        self.detectedPeople = rec.detectedPeople
        self.suspectedPeople = rec.suspectedPeople
        self.confirmedByUserPeople = rec.confirmedByUserPeople
        self.rejectedPeople = rec.rejectedPeople
        self.mediaDisposition = rec.mediaDisposition
        self.lifecycleStage = rec.lifecycleStage
        self.archiveStage = rec.archiveStage
        self.starRating = rec.starRating
        self.junkScore = rec.junkScore
        self.notes = rec.notes
    }

    /// Apply the snapshotted fields onto a freshly-scanned record.
    /// The new record's scan-derived fields (size, codec, etc.) are
    /// preserved as-is; only the dossier + user-edit fields are
    /// restored.
    @MainActor
    func apply(to rec: VideoRecord) {
        rec.sceneCaptions = self.sceneCaptions
        rec.sceneCaptionModel = self.sceneCaptionModel
        rec.sceneCaptionDate = self.sceneCaptionDate
        rec.audioTranscript = self.audioTranscript
        rec.audioTranscriptModel = self.audioTranscriptModel
        rec.audioTranscriptDate = self.audioTranscriptDate
        rec.ocrDateCandidates = self.ocrDateCandidates
        rec.ocrText = self.ocrText
        rec.inferredRecordDate = self.inferredRecordDate
        rec.inferredDateConfidence = self.inferredDateConfidence
        rec.dossierProcessedAt = self.dossierProcessedAt
        rec.dossierProcessedBy = self.dossierProcessedBy
        rec.detectedPeople = self.detectedPeople
        rec.suspectedPeople = self.suspectedPeople
        rec.confirmedByUserPeople = self.confirmedByUserPeople
        rec.rejectedPeople = self.rejectedPeople
        rec.mediaDisposition = self.mediaDisposition
        rec.lifecycleStage = self.lifecycleStage
        rec.archiveStage = self.archiveStage
        rec.starRating = self.starRating
        rec.junkScore = self.junkScore
        rec.notes = self.notes
    }
}

extension VideoScanModel {

    // MARK: - Snapshot helpers
    //
    // Called by startTarget() right before records.removeAll, and by
    // the scan-complete codepath in ScanExecution right before
    // records.append(contentsOf: targetRecords). The intermediate
    // storage `pendingPreservedFields` is keyed by the target's
    // searchPath so two concurrent rescans of different volumes don't
    // collide.

    /// Snapshot dossier + user-edit fields for records under `target`,
    /// keyed by fullPath. Stash on the model so the post-scan merge
    /// can find them. Records that have nothing worth preserving are
    /// skipped to keep the map small.
    @MainActor
    func snapshotPreservedFieldsForRescan(of target: CatalogScanTarget) {
        var map: [String: RescanPreservedFields] = [:]
        for rec in records where PathScope.contains(rec.fullPath, within: target.searchPath) { // regression: codex C2
            let snap = RescanPreservedFields(from: rec)
            if snap.isWorthRestoring {
                map[rec.fullPath] = snap
            }
        }
        pendingPreservedFields[target.searchPath] = map
    }

    /// Apply the snapshotted fields onto freshly-scanned records.
    /// Called by ScanExecution right after the scan completes, before
    /// `records.append(contentsOf: targetRecords)`. Returns the count
    /// of records that had preserved fields restored, for logging.
    /// Side effect: clears the snapshot for this target (the data is
    /// no longer needed since it's been merged into the new records).
    @MainActor
    @discardableResult
    func applyPreservedFieldsAfterRescan(
        of target: CatalogScanTarget,
        onto targetRecords: [VideoRecord]
    ) -> Int {
        guard let map = pendingPreservedFields.removeValue(forKey: target.searchPath),
              !map.isEmpty
        else { return 0 }
        var restored = 0
        for rec in targetRecords {
            guard let snap = map[rec.fullPath] else { continue }
            snap.apply(to: rec)
            restored += 1
        }
        return restored
    }

    /// Discard the preservation snapshot WITHOUT restoring it.
    /// Called when something has gone wrong and we want to abandon
    /// the snapshot rather than rebuild records from it (e.g. the
    /// volume was retired mid-scan, or a programming bug means the
    /// new records aren't usable). Today only used as a defensive
    /// cleanup so the map doesn't grow unbounded.
    @MainActor
    func discardPreservedFieldsSnapshot(of target: CatalogScanTarget) {
        pendingPreservedFields.removeValue(forKey: target.searchPath)
    }
}
