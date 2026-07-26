import Foundation
import Testing
@testable import VideoScan

// MARK: - Rescan field preservation regression
//
// Rick 2026-06-07: clicked "Update Catalog" on LaCieWorkspace and the
// dossier dial dropped from ~28% to <1%. Cause: startTarget() does
// `records.removeAll { $0.fullPath.hasPrefix(target.searchPath) }`
// then the fresh scan creates new VideoRecord instances with no
// dossier fields, no user-edit tags, no dispositions. Hours of Qwen
// + Whisper work would be silently destroyed on every rescan.
//
// These tests pin the snapshot-and-restore contract: anything the
// user or the dossier pipeline added must survive a routine rescan.
// Scan-derived fields (size, codec, etc.) are NOT preserved — the
// rescan correctly refreshes those from current disk state.

@MainActor
@Suite("Rescan preservation")
struct RescanPreservationTests {

    // MARK: - Helpers

    private func dossierLoadedRecord(
        path: String = "/Volumes/Test/clip.mov",
        captionText: String = "kitchen birthday cake"
    ) -> VideoRecord {
        let r = VideoRecord()
        r.filename = (path as NSString).lastPathComponent
        r.fullPath = path
        r.sceneCaptions = [SceneCaption(timestamp: 1.0, text: captionText)]
        r.sceneCaptionModel = "qwen2.5-vl-3b-4bit"
        r.sceneCaptionDate = Date(timeIntervalSince1970: 1_700_000_000)
        r.audioTranscript = "happy birthday Matt"
        r.audioTranscriptModel = "whisper-medium-mlx-q4"
        r.audioTranscriptDate = Date(timeIntervalSince1970: 1_700_000_000)
        r.ocrDateCandidates = [SceneCaption(timestamp: 0.5, text: "JUN 21 1991")]
        r.ocrText = [SceneCaption(timestamp: 2.0, text: "HAPPY BIRTHDAY")]
        r.inferredRecordDate = Date(timeIntervalSince1970: 678_000_000)
        r.inferredDateConfidence = 0.95
        r.dossierProcessedAt = Date(timeIntervalSince1970: 1_700_000_000)
        r.dossierProcessedBy = "qwen+whisper"
        // User-edit fields
        r.detectedPeople = ["Matt"]
        r.suspectedPeople = ["Tim"]
        r.confirmedByUserPeople = [ConfirmedTag(name: "Donna", confirmedAt: Date(timeIntervalSince1970: 1_700_000_000))]
        r.rejectedPeople = ["Anna"]
        r.mediaDisposition = .important
        r.lifecycleStage = .archived
        r.starRating = 3
        r.junkScore = 0
        r.notes = "Matt's 4th birthday"
        // Scan-derived (should NOT be preserved — rescan refreshes these)
        r.sizeBytes = 12345
        r.videoCodec = "h264-OLD"
        r.resolution = "320x240"
        return r
    }

    private func freshlyScannedRecord(
        path: String,
        codec: String = "h264-NEW",
        resolution: String = "1920x1080"
    ) -> VideoRecord {
        let r = VideoRecord()
        r.filename = (path as NSString).lastPathComponent
        r.fullPath = path
        r.videoCodec = codec
        r.resolution = resolution
        r.sizeBytes = 99_999
        // No dossier fields, no user-edit tags — scan starts blank.
        return r
    }

    // MARK: - RescanPreservedFields struct

    @Test func snapshotCapturesAllDossierAndUserFields() {
        let r = dossierLoadedRecord()
        let snap = RescanPreservedFields(from: r)

        // Dossier channels
        #expect(snap.sceneCaptions.count == 1)
        #expect(snap.sceneCaptions.first?.text == "kitchen birthday cake")
        #expect(snap.audioTranscript == "happy birthday Matt")
        #expect(snap.ocrDateCandidates.first?.text == "JUN 21 1991")
        #expect(snap.ocrText.first?.text == "HAPPY BIRTHDAY")
        #expect(snap.inferredDateConfidence == 0.95)
        #expect(snap.dossierProcessedBy == "qwen+whisper")

        // User-edit
        #expect(snap.detectedPeople == ["Matt"])
        #expect(snap.suspectedPeople == ["Tim"])
        #expect(snap.confirmedByUserPeople.first?.name == "Donna")
        #expect(snap.rejectedPeople == ["Anna"])
        #expect(snap.mediaDisposition == .important)
        #expect(snap.lifecycleStage == .archived)
        #expect(snap.starRating == 3)
        #expect(snap.notes == "Matt's 4th birthday")
    }

    @Test func snapshotIsWorthRestoringForLoadedRecord() {
        let r = dossierLoadedRecord()
        #expect(RescanPreservedFields(from: r).isWorthRestoring,
                "A record with dossier + user tags MUST be flagged as worth restoring.")
    }

    @Test func snapshotIsNotWorthRestoringForBlankRecord() {
        // A freshly-scanned record with no dossier and no user edits
        // has nothing to preserve — the snapshot map can drop it to
        // stay small.
        let r = VideoRecord()
        r.filename = "blank.mov"
        r.fullPath = "/Volumes/Test/blank.mov"
        #expect(!RescanPreservedFields(from: r).isWorthRestoring)
    }

    // regression: GH #113 — a purged record is a catalog tombstone, so a
    // same-path rescan must preserve it even when it has no other curated data.
    @Test func purgedRecordDoesNotResurrectOnRescan() {
        let purgedAt = Date(timeIntervalSince1970: 1_720_000_000)
        let original = VideoRecord()
        original.filename = "purged.mov"
        original.fullPath = "/Volumes/Test/purged.mov"
        original.purgedAt = purgedAt

        let snap = RescanPreservedFields(from: original)
        #expect(snap.isWorthRestoring,
                "purgedAt alone must keep the snapshot in the rescan map")

        let fresh = freshlyScannedRecord(path: original.fullPath)
        #expect(fresh.purgedAt == nil)
        snap.apply(to: fresh)

        #expect(fresh.purgedAt == purgedAt,
                "rescan must not silently return purged media to the catalog")
    }

    @Test func applyRestoresFieldsButDoesNotTouchScanDerived() {
        let original = dossierLoadedRecord()
        let snap = RescanPreservedFields(from: original)

        // Simulate what the scan produces: same path, refreshed
        // technical fields, blank dossier + user-edit fields.
        let fresh = freshlyScannedRecord(
            path: "/Volumes/Test/clip.mov",
            codec: "hevc-NEW",
            resolution: "3840x2160"
        )
        fresh.sizeBytes = 555_555

        snap.apply(to: fresh)

        // Dossier + user fields restored.
        #expect(fresh.sceneCaptions.count == 1)
        #expect(fresh.dossierProcessedAt != nil)
        #expect(fresh.detectedPeople == ["Matt"])
        #expect(fresh.starRating == 3)
        #expect(fresh.mediaDisposition == .important)

        // Scan-derived fields NOT overwritten — the freshly-scanned
        // values stand because they reflect the current disk state.
        #expect(fresh.videoCodec == "hevc-NEW")
        #expect(fresh.resolution == "3840x2160")
        #expect(fresh.sizeBytes == 555_555)
    }

    // Regression marker (seam B, 2026-06-29): exhaustively pin EVERY
    // preserved field through a full snapshot -> apply round-trip. The
    // older tests above sample a subset; archiveStage, junkScore, and
    // the *Model / *Date provenance fields were unasserted. This path
    // protects user-curated + expensive-to-recompute data, so a missed
    // field is a silent data-loss bug. If RescanPreservedFields grows a
    // field, add it here.
    @Test func applyRoundTripPreservesEveryCuratedField() {
        let original = VideoRecord()
        original.fullPath = "/Volumes/Test/everything.mov"
        original.filename = "everything.mov"

        // Distinct, non-default values for every preserved field.
        let capDate = Date(timeIntervalSince1970: 1_600_000_000)
        let txDate  = Date(timeIntervalSince1970: 1_600_111_111)
        let inferDate = Date(timeIntervalSince1970: 700_000_000)
        let procDate = Date(timeIntervalSince1970: 1_650_000_000)
        let confDate = Date(timeIntervalSince1970: 1_660_000_000)

        original.sceneCaptions = [SceneCaption(timestamp: 3.0, text: "porch summer 1985")]
        original.sceneCaptionModel = "qwen2.5-vl-7b-4bit"
        original.sceneCaptionDate = capDate
        original.audioTranscript = "and there's grandpa waving"
        original.audioTranscriptModel = "whisper-large-v3-mlx"
        original.audioTranscriptDate = txDate
        original.ocrDateCandidates = [SceneCaption(timestamp: 0.2, text: "AUG 1985")]
        original.ocrText = [SceneCaption(timestamp: 4.0, text: "REUNION")]
        original.inferredRecordDate = inferDate
        original.inferredDateConfidence = 0.42
        original.dossierProcessedAt = procDate
        original.dossierProcessedBy = "qwen7b+whisperLargeV3"
        original.detectedPeople = ["Grandpa", "Donna"]
        original.suspectedPeople = ["Uncle Joe"]
        original.confirmedByUserPeople = [ConfirmedTag(name: "Donna", confirmedAt: confDate)]
        original.rejectedPeople = ["Stranger", "Neighbor"]
        original.mediaDisposition = .confirmedJunk
        original.lifecycleStage = .reviewing
        original.archiveStage = .archived
        original.starRating = 5
        original.junkScore = 7
        original.notes = "reunion reel, second tape"
        let purgedAt = Date(timeIntervalSince1970: 1_670_000_000)
        original.purgedAt = purgedAt

        let snap = RescanPreservedFields(from: original)

        // Fresh record with DIFFERENT scan-derived + blank curated state,
        // to prove apply() overwrites curated fields with snapshot values.
        let fresh = VideoRecord()
        fresh.fullPath = "/Volumes/Test/everything.mov"
        fresh.filename = "everything.mov"
        fresh.videoCodec = "hevc-NEW"
        fresh.sizeBytes = 42

        snap.apply(to: fresh)

        // Dossier channels — all twelve.
        #expect(fresh.sceneCaptions.count == 1)
        #expect(fresh.sceneCaptions.first?.text == "porch summer 1985")
        #expect(fresh.sceneCaptionModel == "qwen2.5-vl-7b-4bit")
        #expect(fresh.sceneCaptionDate == capDate)
        #expect(fresh.audioTranscript == "and there's grandpa waving")
        #expect(fresh.audioTranscriptModel == "whisper-large-v3-mlx")
        #expect(fresh.audioTranscriptDate == txDate)
        #expect(fresh.ocrDateCandidates.first?.text == "AUG 1985")
        #expect(fresh.ocrText.first?.text == "REUNION")
        #expect(fresh.inferredRecordDate == inferDate)
        #expect(fresh.inferredDateConfidence == 0.42)
        #expect(fresh.dossierProcessedAt == procDate)
        #expect(fresh.dossierProcessedBy == "qwen7b+whisperLargeV3")

        // User-edit fields — all ten.
        #expect(fresh.detectedPeople == ["Grandpa", "Donna"])
        #expect(fresh.suspectedPeople == ["Uncle Joe"])
        #expect(fresh.confirmedByUserPeople.first?.name == "Donna")
        #expect(fresh.confirmedByUserPeople.first?.confirmedAt == confDate)
        #expect(fresh.rejectedPeople == ["Stranger", "Neighbor"])
        #expect(fresh.mediaDisposition == .confirmedJunk)
        #expect(fresh.lifecycleStage == .reviewing)
        #expect(fresh.archiveStage == .archived)
        #expect(fresh.starRating == 5)
        #expect(fresh.junkScore == 7)
        #expect(fresh.notes == "reunion reel, second tape")
        #expect(fresh.purgedAt == purgedAt)

        // Scan-derived field left untouched by apply().
        #expect(fresh.videoCodec == "hevc-NEW")
        #expect(fresh.sizeBytes == 42)
    }

    // MARK: - Model-level snapshot/restore

    @Test func endToEnd_snapshotThenApplyRestoresOnFreshRecord() {
        // Simulates the full lifecycle:
        //   1. Catalog has a dossier-loaded record under a target.
        //   2. startTarget snapshots the preserved fields.
        //   3. (records.removeAll happens — not exercised here, the
        //       snapshot is the part that matters.)
        //   4. Scan produces a fresh record for the same path.
        //   5. ScanExecution calls applyPreservedFieldsAfterRescan
        //       which merges the snapshot onto the fresh record.
        let model = VideoScanModel()
        let target = CatalogScanTarget(searchPath: "/Volumes/Test")
        let original = dossierLoadedRecord(path: "/Volumes/Test/clip.mov")
        model.records = [original]
        model.scanTargets = [target]

        // Step 2 — snapshot before removeAll
        model.snapshotPreservedFieldsForRescan(of: target)

        // Step 3 — wipe records (the dangerous part)
        model.records.removeAll()

        // Step 4 — scan produces a fresh, blank record
        let fresh = freshlyScannedRecord(path: "/Volumes/Test/clip.mov")
        let freshRecords = [fresh]

        // Step 5 — restore
        let restored = model.applyPreservedFieldsAfterRescan(of: target, onto: freshRecords)
        #expect(restored == 1, "Exactly one record had preserved fields restored.")

        // Verify the fresh record carries the dossier + user data.
        #expect(fresh.dossierProcessedAt == original.dossierProcessedAt)
        #expect(fresh.sceneCaptions.count == 1)
        #expect(fresh.detectedPeople == ["Matt"])
        #expect(fresh.notes == "Matt's 4th birthday")
    }

    @Test func newPathsAreLeftAsScanned_existingPathsRestore() {
        // The user-facing case: a rescan often finds NEW files
        // (we just copied them over) alongside existing ones. New
        // files have no snapshot to restore (correct); existing
        // files restore.
        let model = VideoScanModel()
        let target = CatalogScanTarget(searchPath: "/Volumes/Test")
        let oldRec = dossierLoadedRecord(path: "/Volumes/Test/old.mov")
        model.records = [oldRec]
        model.scanTargets = [target]
        model.snapshotPreservedFieldsForRescan(of: target)
        model.records.removeAll()

        // Scan finds two files: the existing one + a new one.
        let oldFresh = freshlyScannedRecord(path: "/Volumes/Test/old.mov")
        let newFresh = freshlyScannedRecord(path: "/Volumes/Test/new.mov")

        let restored = model.applyPreservedFieldsAfterRescan(of: target, onto: [oldFresh, newFresh])

        #expect(restored == 1)
        #expect(oldFresh.dossierProcessedAt != nil, "Old path's dossier survived the rescan.")
        #expect(newFresh.dossierProcessedAt == nil, "New path correctly has no dossier yet.")
        #expect(newFresh.sceneCaptions.isEmpty)
    }

    @Test func snapshotMapIsClearedAfterApply() {
        // After applyPreservedFieldsAfterRescan runs, the snapshot
        // for that target must be removed from pendingPreservedFields
        // so a future rescan starts with a clean slate.
        let model = VideoScanModel()
        let target = CatalogScanTarget(searchPath: "/Volumes/Test")
        let original = dossierLoadedRecord()
        model.records = [original]
        model.scanTargets = [target]

        model.snapshotPreservedFieldsForRescan(of: target)
        #expect(model.pendingPreservedFields[target.searchPath]?.isEmpty == false)
        model.records.removeAll()

        _ = model.applyPreservedFieldsAfterRescan(of: target, onto: [])
        #expect(model.pendingPreservedFields[target.searchPath] == nil,
                "Snapshot must be cleared after apply so the map doesn't grow unbounded.")
    }

    @Test func discardSnapshotRemovesEntryWithoutRestoring() {
        // Cancel path: the snapshot should be discarded so the map
        // doesn't accumulate stale entries from cancelled rescans.
        let model = VideoScanModel()
        let target = CatalogScanTarget(searchPath: "/Volumes/Test")
        model.records = [dossierLoadedRecord()]
        model.scanTargets = [target]

        model.snapshotPreservedFieldsForRescan(of: target)
        #expect(model.pendingPreservedFields[target.searchPath]?.isEmpty == false)

        model.discardPreservedFieldsSnapshot(of: target)
        #expect(model.pendingPreservedFields[target.searchPath] == nil)
    }

    @Test func relinkRunsEvenWhenThePreservationMapIsEmpty() {
        // QA m1 (overnight review 2026-07-24): the only record under the
        // rescanned tree is a pointer TARGET carrying nothing restorable
        // itself — a plain original that an awaiting repair on ANOTHER
        // volume points at. The old `guard !map.isEmpty else { return 0 }`
        // returned BEFORE the re-link pass, leaving the repair's
        // derivedFrom dangling once the rescan minted a fresh id —
        // Confirm could never find the original again.
        let model = VideoScanModel()
        let target = CatalogScanTarget(searchPath: "/Volumes/B")
        let original = freshlyScannedRecord(path: "/Volumes/B/tape.mov")
        let repair = VideoRecord()
        repair.filename = "tape_RepairedAudio.mov"
        repair.fullPath = "/Volumes/A/tape_RepairedAudio.mov"
        repair.derivedFrom = original.id
        repair.derivationKind = "rebuildAudio"
        model.records = [original, repair]
        model.scanTargets = [target]

        model.snapshotPreservedFieldsForRescan(of: target)
        #expect(model.pendingPreservedFields[target.searchPath]?.isEmpty == true,
                "precondition: the pointer target carries nothing restorable, so the map is empty")
        model.records.removeAll { $0.fullPath.hasPrefix("/Volumes/B") }

        let fresh = freshlyScannedRecord(path: "/Volumes/B/tape.mov")   // fresh id
        let restored = model.applyPreservedFieldsAfterRescan(of: target, onto: [fresh])

        #expect(restored == 0, "nothing restorable — but the re-link must still run")
        #expect(repair.derivedFrom == fresh.id,
                "the repair's pointer follows the original's fresh id")
        #expect(repair.isAwaitingConfirmation, "the repair stays in the confirm worklist")
    }

    @Test func twoConcurrentRescansDoNotCollide() {
        // Each target keys its snapshot by searchPath so a
        // simultaneous rescan of two volumes can't cross-contaminate.
        let model = VideoScanModel()
        let targetA = CatalogScanTarget(searchPath: "/Volumes/A")
        let targetB = CatalogScanTarget(searchPath: "/Volumes/B")
        let recA = dossierLoadedRecord(path: "/Volumes/A/a.mov", captionText: "from A")
        let recB = dossierLoadedRecord(path: "/Volumes/B/b.mov", captionText: "from B")
        model.records = [recA, recB]
        model.scanTargets = [targetA, targetB]

        model.snapshotPreservedFieldsForRescan(of: targetA)
        model.snapshotPreservedFieldsForRescan(of: targetB)
        model.records.removeAll()

        // Restore A only — B's snapshot must still be intact.
        let freshA = freshlyScannedRecord(path: "/Volumes/A/a.mov")
        let restoredA = model.applyPreservedFieldsAfterRescan(of: targetA, onto: [freshA])
        #expect(restoredA == 1)
        #expect(freshA.sceneCaptions.first?.text == "from A")
        #expect(model.pendingPreservedFields[targetB.searchPath] != nil,
                "B's snapshot must survive A's restore.")

        // Now restore B — should still work.
        let freshB = freshlyScannedRecord(path: "/Volumes/B/b.mov")
        let restoredB = model.applyPreservedFieldsAfterRescan(of: targetB, onto: [freshB])
        #expect(restoredB == 1)
        #expect(freshB.sceneCaptions.first?.text == "from B")
    }
}
