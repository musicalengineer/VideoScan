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
