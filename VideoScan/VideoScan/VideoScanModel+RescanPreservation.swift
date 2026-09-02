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
//                         archiveStage, starRating, junkScore, notes,
//                         tags, userNotes, userDate, userDateConfidence.
//   Archive provenance  — archiveFixity, originalFullPath, originVolume,
//                         masterLocation. Stamped by Promote / Verify
//                         Archive Copies / move-adoption, never by a
//                         scan, so a rescan can only ever lose them.
//
// 2026-09-02: archiveFixity was never in the list; a rescan of the
// archive volume dropped 28 fixity records' worth of provenance in
// Rick's catalog. The sidebar then showed every archive copy as
// unverified ("cataloged by rescan, not by Promote") and the only way
// back was Verify Copies re-reading every byte (one file is 73 GB).
// Same audit found originalFullPath / originVolume / masterLocation
// (Promote's self-contained "where did this come from" provenance) and
// userDate / userDateConfidence (Rick's hand-typed Estimated Date —
// which the Update Catalog sheet promises "stays with the file") were
// missing too. All six are additive here; the scan never writes any of
// them, so restoring verbatim can never clobber a fresher value.
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
    // Workflow tags + user notes (2026-07-23) — user-authored, so a
    // rescan must never destroy them (same contract as notes above).
    let tags: [String]
    let userNotes: String
    /// Catalog soft-delete tombstone (GH #113). Without preservation, a
    /// same-path rescan silently resurrects the record as active.
    let purgedAt: Date?

    /// Catalog-scope set-aside state (2026-07-15). Preserved so a rescan's
    /// fresh instance can NEVER silently resurrect a set-aside record into
    /// the default view (rescan-never-resurrects sensor) — only Tidy undo
    /// or an explicit "Put Back in Catalog" flips this field.
    let setAsideReason: String?

    /// Repair-lifecycle state (GH #132). Same sensor contract as
    /// setAsideReason: a rescan must NEVER resurrect a superseded
    /// original into the default view, and must never un-confirm a
    /// confirmed repair — only "Restore Original (Un-supersede)" flips
    /// supersededByID.
    let supersededByID: UUID?
    let repairConfirmedDate: Date?

    /// Derivation provenance (deep-test finding 1, GH #132, 2026-07-24):
    /// WITHOUT these, a routine rescan silently dropped every
    /// unconfirmed repair out of the awaiting-confirmation worklist
    /// forever (isAwaitingConfirmation needs derivedFrom + a repair
    /// derivationKind) and broke confirmed repairs' inspector links —
    /// the exact curated-state-loss class this file exists to prevent.
    /// The restored pointer VALUE can still be stale (the scan mints
    /// fresh ids) — finding 2's re-link pass in
    /// `applyPreservedFieldsAfterRescan` fixes that.
    let derivedFrom: UUID?
    let derivationKind: String?

    /// Master Archive fixity (2026-09-02): the whole-file SHA-256 that
    /// Promote stamps after read-back and Verify Archive Copies restores
    /// after re-reading every byte. A rescan of the archive volume
    /// produced fresh instances with archiveFixity == nil, so every
    /// verified copy silently became "unverified" (see header note).
    /// Restored VERBATIM — if the file on disk has since changed, the
    /// stale sizeBytes inside the record IS the tamper signal Verify
    /// Copies looks for; dropping it would destroy the evidence.
    let archiveFixity: ArchiveFixity?

    /// Promote's self-contained provenance on the archive copy (codex QA
    /// major b): where the file came from, so the copy can still say so
    /// after a retired-volume cleanup removes the source record. Also
    /// written by move-adoption and Relocate for renamed/moved files.
    /// Never written by a scan.
    let originalFullPath: String?
    let originVolume: String?

    /// Which Master Archive holds this record's master ("Mac Studio SSD",
    /// the archive target path). Stamped on BOTH the source and the copy
    /// by Promote; "" = none.
    let masterLocation: String

    /// Rick's hand-entered Estimated Date (GH #117) + its confidence.
    /// User-edit class (same contract as notes/tags) — and Promote copies
    /// it onto the archive copy, so losing it on a rescan also loses the
    /// copy's archive date.
    let userDate: String?
    let userDateConfidence: String?

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
            || !tags.isEmpty
            || !userNotes.isEmpty
            || purgedAt != nil
            || setAsideReason != nil
            || supersededByID != nil
            || repairConfirmedDate != nil
            || derivedFrom != nil
            || derivationKind != nil
            || archiveFixity != nil
            || originalFullPath != nil
            || originVolume != nil
            || !masterLocation.isEmpty
            || userDate != nil
            || userDateConfidence != nil
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
        self.tags = rec.tags
        self.userNotes = rec.userNotes
        self.purgedAt = rec.purgedAt
        self.setAsideReason = rec.setAsideReason
        self.supersededByID = rec.supersededByID
        self.repairConfirmedDate = rec.repairConfirmedDate
        self.derivedFrom = rec.derivedFrom
        self.derivationKind = rec.derivationKind
        self.archiveFixity = rec.archiveFixity
        self.originalFullPath = rec.originalFullPath
        self.originVolume = rec.originVolume
        self.masterLocation = rec.masterLocation
        self.userDate = rec.userDate
        self.userDateConfidence = rec.userDateConfidence
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
        rec.tags = self.tags
        rec.userNotes = self.userNotes
        rec.purgedAt = self.purgedAt
        rec.setAsideReason = self.setAsideReason
        rec.supersededByID = self.supersededByID
        rec.repairConfirmedDate = self.repairConfirmedDate
        rec.derivedFrom = self.derivedFrom
        rec.derivationKind = self.derivationKind
        rec.archiveFixity = self.archiveFixity
        rec.originalFullPath = self.originalFullPath
        rec.originVolume = self.originVolume
        rec.masterLocation = self.masterLocation
        rec.userDate = self.userDate
        rec.userDateConfidence = self.userDateConfidence
    }
}

extension VideoScanModel {

    // MARK: - Snapshot helpers
    //
    // Snapshot is taken by startTarget() AND resumeTarget() when the scan
    // begins (resume re-verifies the full checkpoint list, so its
    // completion merge replaces re-seen records exactly like a fresh scan
    // — it needs the same snapshot); applied by the scan-complete codepath
    // in ScanExecution right before
    // commitScanResults performs the root-scoped replace (2026-07-02:
    // the old wipe-at-scan-start is gone — see VideoScanModel+ScanMerge).
    // The intermediate storage `pendingPreservedFields` is keyed by the
    // target's searchPath so two concurrent rescans of different volumes
    // don't collide.

    /// Snapshot dossier + user-edit fields for records under `target`,
    /// keyed by fullPath. Stash on the model so the post-scan merge
    /// can find them. Records that have nothing worth preserving are
    /// skipped to keep the map small.
    @MainActor
    func snapshotPreservedFieldsForRescan(of target: CatalogScanTarget) {
        var map: [String: RescanPreservedFields] = [:]
        var oldIDs: [String: UUID] = [:]
        for rec in records where PathScope.contains(rec.fullPath, within: target.searchPath) { // regression: codex C2
            // Every record's pre-rescan id — the re-link pass needs the
            // POINTER TARGETS too, which may carry nothing else worth
            // restoring (deep-test finding 2).
            oldIDs[rec.fullPath] = rec.id
            let snap = RescanPreservedFields(from: rec)
            if snap.isWorthRestoring {
                map[rec.fullPath] = snap
            }
        }
        pendingPreservedFields[target.searchPath] = map
        pendingRescanOldIDs[target.searchPath] = oldIDs
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
        let oldIDs = pendingRescanOldIDs.removeValue(forKey: target.searchPath) ?? [:]
        let map = pendingPreservedFields.removeValue(forKey: target.searchPath) ?? [:]
        var restored = 0
        for rec in targetRecords {
            guard let snap = map[rec.fullPath] else { continue }
            snap.apply(to: rec)
            restored += 1
        }
        // Re-link runs even when the preservation map is EMPTY (QA m1,
        // 2026-07-24): pendingRescanOldIDs was captured for exactly this
        // case — pointer TARGETS often carry nothing worth restoring
        // themselves (an awaiting repair's original is a plain record),
        // yet records elsewhere in the catalog point at their pre-rescan
        // ids. The old early-return left those pointers dangling.
        // NOTE: must stay AFTER the apply loop — apply() restores the
        // pointer fields the relink then remaps.
        relinkLifecyclePointersAfterRescan(oldIDs: oldIDs,
                                           targetRecords: targetRecords)
        return restored
    }

    /// Re-link the repair-lifecycle pointers after a rescan (deep-test
    /// finding 2, GH #132). The scan merge mints FRESH record ids
    /// (only move-adoption preserves them), so a restored
    /// `supersededByID` / `derivedFrom` still holds the pointer
    /// target's PRE-RESCAN id and stops resolving — a superseded
    /// original stays safely hidden but "Show Repaired Copy in
    /// Catalog" breaks, and confirm can no longer find an awaiting
    /// repair's original.
    ///
    /// Mechanism: join the pre-rescan fullPath → oldID capture with the
    /// fresh instances (same fullPath) to build oldID → newID, then
    /// remap both pointers wherever the OLD id has a mapping — on the
    /// fresh instances AND on every record elsewhere in the catalog
    /// that points INTO the rescanned tree (repair on volume A,
    /// original on rescanned volume B). Pointers whose old id has no
    /// mapping are left alone: either the target lives outside the
    /// rescan (its id is unchanged and still resolves) or its file
    /// genuinely vanished (nothing to re-link). Identity mappings from
    /// move-adopted ids are harmless no-ops.
    @MainActor
    private func relinkLifecyclePointersAfterRescan(
        oldIDs: [String: UUID],
        targetRecords: [VideoRecord]
    ) {
        guard !oldIDs.isEmpty else { return }
        var oldToNew: [UUID: UUID] = [:]
        oldToNew.reserveCapacity(targetRecords.count)
        for rec in targetRecords {
            if let oldID = oldIDs[rec.fullPath] {
                oldToNew[oldID] = rec.id
            }
        }
        guard !oldToNew.isEmpty else { return }

        func relink(_ rec: VideoRecord) {
            if let sup = rec.supersededByID, let fresh = oldToNew[sup], fresh != sup {
                rec.supersededByID = fresh
            }
            if let src = rec.derivedFrom, let fresh = oldToNew[src], fresh != src {
                rec.derivedFrom = fresh
            }
        }
        for rec in targetRecords { relink(rec) }
        // Records OUTSIDE the rescanned tree can point into it — the
        // old instances under the root are about to be replaced by the
        // merge, so touching them is harmless; everything else gets its
        // pointers fixed. One O(catalog) pass, pointer fields only.
        for rec in records { relink(rec) }

        // A confirm-undo batch armed before this rescan references the
        // PRE-RESCAN ids; after the instance swap its Undo would be a
        // silent no-op. Drop the stale banner — precisely, only when it
        // references a record this rescan replaced with a NEW id.
        if let batch = lastConfirmBatch,
           batch.snapshots.contains(where: { snap in
               (oldToNew[snap.repairID] ?? snap.repairID) != snap.repairID
                   || (oldToNew[snap.originalID] ?? snap.originalID) != snap.originalID
           }) {
            lastConfirmBatch = nil
        }
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
        pendingRescanOldIDs.removeValue(forKey: target.searchPath)
    }
}
