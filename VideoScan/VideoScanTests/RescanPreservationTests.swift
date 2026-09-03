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
        resolution: String = "1920x1080",
        sizeBytes: Int64 = 99_999,
        partialMD5: String = ""
    ) -> VideoRecord {
        let r = VideoRecord()
        r.filename = (path as NSString).lastPathComponent
        r.fullPath = path
        r.videoCodec = codec
        r.resolution = resolution
        r.sizeBytes = sizeBytes
        r.partialMD5 = partialMD5     // "" = hashing skipped on this scan
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
        // Archive provenance + user date (2026-09-02 audit) — see the
        // archive-provenance section below for the incident.
        let fixityAt = Date(timeIntervalSince1970: 1_690_000_000)
        // fixity.sizeBytes == the FRESH probe's size below (42): the
        // identity guard (codex #975) carries a fixity only when the
        // bytes still match — the drop branches are pinned in the
        // archive-provenance section.
        original.archiveFixity = ArchiveFixity(digest: "ab" + String(repeating: "cd", count: 31),
                                               verifiedAt: fixityAt, sizeBytes: 42)
        original.originalFullPath = "/Volumes/LaCie/tapes/reunion.mov"
        original.originVolume = "LaCie"
        original.masterLocation = "/Volumes/FamilyArchive"
        original.userDate = "1985-08"
        original.userDateConfidence = "known"

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

        // Archive provenance + user date — all six (2026-09-02).
        #expect(fresh.archiveFixity?.digest == "ab" + String(repeating: "cd", count: 31))
        #expect(fresh.archiveFixity?.verifiedAt == fixityAt)
        #expect(fresh.archiveFixity?.sizeBytes == 42)
        #expect(fresh.originalFullPath == "/Volumes/LaCie/tapes/reunion.mov")
        #expect(fresh.originVolume == "LaCie")
        #expect(fresh.masterLocation == "/Volumes/FamilyArchive")
        #expect(fresh.userDate == "1985-08")
        #expect(fresh.userDateConfidence == "known")

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

    // MARK: - Archive provenance survives a rescan (2026-09-02)
    //
    // Rick 2026-09-02: an Update Catalog rescan of the Master Archive volume
    // (/Volumes/FamilyArchive — 39 records under the root, 28 carrying a
    // SHA-256 fixity record stamped by Promote / Verify Archive Copies)
    // replaced every same-path record with a fresh instance, and
    // `archiveFixity` was NOT in RescanPreservedFields. All 28 fixity
    // records vanished; the sidebar showed every archive copy as
    // unverified ("cataloged by rescan, not by Promote") and the only way
    // back was Verify Copies re-reading every byte (one file is 73 GB).
    // The same audit found Promote's self-contained provenance
    // (originalFullPath / originVolume / masterLocation) and Rick's
    // hand-typed userDate / userDateConfidence were missing too.
    //
    // codex #975 (2026-09-02, safety-critical): the first cut restored the
    // fixity VERBATIM — onto a fresh probe whose size/fingerprint could
    // already disagree with it — while every UI reader treats a non-nil
    // archiveFixity as "verified". The contract pinned below:
    //
    //     archiveFixity present ⇒ verified for THESE bytes.
    //
    // The fixity carries across a rescan only while identity continuity
    // holds (fixity.sizeBytes == fresh size; and when BOTH sides carry a
    // partialMD5, they agree). Any definite disagreement drops it. The
    // sibling provenance (originalFullPath / originVolume / masterLocation
    // / userDate / userDateConfidence) is a history + location association,
    // NOT a byte claim, and stays unconditional.
    //
    // Five dimensions (feature-test checklist): logic (carry + every drop
    // branch + the pure rule + move adoption), negative, isWorthRestoring,
    // 100k scale (identity-matching AND all-dropped), and two end-to-end
    // pipeline SENSORS (carry with the file's REAL digest; drop when the
    // bytes change at the same size).

    /// The real SHA-256 of 64 zero bytes — the pipeline fixtures below.
    /// (`head -c 64 /dev/zero | shasum -a 256`.) The first cut's sensor
    /// seeded a digest that was NOT the file's and asserted "verified".
    private var sha256Of64ZeroBytes: String {
        "f5a5fd42d16a20302798ef6ed309979b43003d2320d9f0e8ea9831a92759fb4b"
    }

    /// One archive copy the way `registerPromotedCopy` leaves it. The
    /// fixity's sizeBytes matches the record's; `partialMD5` is the
    /// fingerprint the LAST scan recorded ("" = hashing was skipped).
    private func archiveCopyRecord(
        path: String = "/Volumes/FamilyArchive/BreenFamilyArchive/1980s/1985/reunion.mov",
        sourceID: UUID = UUID(),
        verifiedAt: Date = Date(timeIntervalSince1970: 1_755_000_000),
        digest: String = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
        sizeBytes: Int64 = 4_242,
        partialMD5: String = ""
    ) -> VideoRecord {
        let r = VideoRecord()
        r.filename = (path as NSString).lastPathComponent
        r.fullPath = path
        r.directory = (path as NSString).deletingLastPathComponent
        r.sizeBytes = sizeBytes
        r.partialMD5 = partialMD5
        r.archiveFixity = ArchiveFixity(digest: digest, verifiedAt: verifiedAt, sizeBytes: sizeBytes)
        r.derivedFrom = sourceID
        r.derivationKind = ArchivePromotion.derivationKind
        r.originalFullPath = "/Volumes/LaCie/Tapes/reunion.mov"
        r.originVolume = "LaCie"
        r.masterLocation = "/Volumes/FamilyArchive"
        r.archiveStage = .masterAssigned
        r.lifecycleStage = .archived
        r.mediaDisposition = .important
        r.starRating = 3
        r.userDate = "1985-08"
        r.userDateConfidence = "known"
        return r
    }

    /// The five unconditional siblings — asserted on BOTH carried and
    /// dropped records, because they are not byte claims.
    private func expectProvenanceRestored(_ rec: VideoRecord,
                                          _ comment: Comment = "provenance is unconditional") {
        #expect(rec.originalFullPath == "/Volumes/LaCie/Tapes/reunion.mov", comment)
        #expect(rec.originVolume == "LaCie", comment)
        #expect(rec.masterLocation == "/Volumes/FamilyArchive", comment)
        #expect(rec.userDate == "1985-08", comment)
        #expect(rec.userDateConfidence == "known", comment)
    }

    // (a) LOGIC — CARRY: same size, no fingerprint evidence → the whole
    // fixity record survives, field by field.
    @Test func archiveFixityCarriesWhenSizeMatches_andNoFingerprintDisagrees() {
        let verifiedAt = Date(timeIntervalSince1970: 1_755_123_456)
        let original = archiveCopyRecord(verifiedAt: verifiedAt)
        let snap = RescanPreservedFields(from: original)

        let fresh = freshlyScannedRecord(path: original.fullPath, sizeBytes: 4_242)
        #expect(fresh.archiveFixity == nil, "precondition: a scan never mints fixity")
        let carry = snap.apply(to: fresh)

        #expect(carry == .carried)
        let fixity = fresh.archiveFixity
        #expect(fixity != nil, "rescan dropped the archive copy's fixity record — 2026-09-02 sensor")
        #expect(fixity?.algorithm == "sha256")
        #expect(fixity?.digest == "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08")
        #expect(fixity?.verifiedAt == verifiedAt)
        #expect(fixity?.sizeBytes == 4_242)
        #expect(fixity == original.archiveFixity, "restored verbatim (Equatable)")
        expectProvenanceRestored(fresh)
        #expect(fresh.sizeBytes == 4_242, "scan-derived size stays the FRESH value")
    }

    // (a2) LOGIC — DROP on size change: the bytes the digest covered are
    // not the bytes on disk. 4_242 → 99_999 is exactly the stale carryover
    // codex #975 flagged.
    @Test func archiveFixityDroppedWhenSizeChanged() {
        let original = archiveCopyRecord()
        let snap = RescanPreservedFields(from: original)

        let fresh = freshlyScannedRecord(path: original.fullPath, sizeBytes: 99_999)
        let carry = snap.apply(to: fresh)

        #expect(carry == .dropped)
        #expect(fresh.archiveFixity == nil,
                "a fixity for 4,242 bytes must not follow a 99,999-byte file — present means verified")
        #expect(fresh.sizeBytes == 99_999)
        // Everything that is NOT a byte claim still comes back.
        expectProvenanceRestored(fresh, "a dropped fixity must not take the provenance with it")
        #expect(fresh.derivedFrom == original.derivedFrom)
        #expect(fresh.derivationKind == ArchivePromotion.derivationKind)
        #expect(fresh.archiveStage == .masterAssigned)
        #expect(fresh.lifecycleStage == .archived)
        #expect(fresh.mediaDisposition == .important)
        #expect(fresh.starRating == 3)
    }

    // (a3) LOGIC — DROP on fingerprint change at the SAME size: the case
    // the size check alone cannot see (a same-length overwrite).
    @Test func archiveFixityDroppedWhenFingerprintChangedAtSameSize() {
        let original = archiveCopyRecord(partialMD5: "0123456789abcdef0123456789abcdef")
        let snap = RescanPreservedFields(from: original)

        let fresh = freshlyScannedRecord(path: original.fullPath, sizeBytes: 4_242,
                                         partialMD5: "fedcba9876543210fedcba9876543210")
        let carry = snap.apply(to: fresh)

        #expect(carry == .dropped)
        #expect(fresh.archiveFixity == nil, "same size, different bytes — the digest no longer describes the file")
        #expect(fresh.partialMD5 == "fedcba9876543210fedcba9876543210",
                "partialMD5 is scan-derived: snapshotted for comparison only, NEVER restored")
        expectProvenanceRestored(fresh)
    }

    // (a4) LOGIC — CARRY on matching fingerprint (both sides hashed).
    @Test func archiveFixityCarriesWhenSizeAndFingerprintBothMatch() {
        let original = archiveCopyRecord(partialMD5: "0123456789abcdef0123456789abcdef")
        let snap = RescanPreservedFields(from: original)

        let fresh = freshlyScannedRecord(path: original.fullPath, sizeBytes: 4_242,
                                         partialMD5: "0123456789abcdef0123456789abcdef")
        #expect(snap.apply(to: fresh) == .carried)
        #expect(fresh.archiveFixity == original.archiveFixity)
    }

    // (a5) LOGIC — CARRY when only ONE side has a fingerprint: "hashing
    // skipped" is absence of evidence, not disagreement. Both directions.
    @Test func archiveFixityCarriesWhenOnlyOneSideHasAFingerprint() {
        // Previous scan hashed; this rescan skipped checksums (SMB).
        let hashedBefore = archiveCopyRecord(partialMD5: "0123456789abcdef0123456789abcdef")
        let freshUnhashed = freshlyScannedRecord(path: hashedBefore.fullPath, sizeBytes: 4_242)
        #expect(RescanPreservedFields(from: hashedBefore).apply(to: freshUnhashed) == .carried)
        #expect(freshUnhashed.archiveFixity == hashedBefore.archiveFixity)
        #expect(freshUnhashed.partialMD5.isEmpty, "the skipped hash is not back-filled from the snapshot")

        // Previous scan skipped; this rescan hashed.
        let unhashedBefore = archiveCopyRecord(path: "/Volumes/FamilyArchive/b.mov")
        let freshHashed = freshlyScannedRecord(path: unhashedBefore.fullPath, sizeBytes: 4_242,
                                               partialMD5: "0123456789abcdef0123456789abcdef")
        #expect(RescanPreservedFields(from: unhashedBefore).apply(to: freshHashed) == .carried)
        #expect(freshHashed.archiveFixity == unhashedBefore.archiveFixity)
    }

    // (a6) LOGIC — the pure rule, branch by branch.
    @Test func fixityIdentityRule_pinnedBranchByBranch() {
        typealias R = RescanPreservedFields
        let fx = ArchiveFixity(digest: "00", verifiedAt: Date(), sizeBytes: 100)
        // Holds
        #expect(R.fixityIdentityHolds(fixity: fx, freshSizeBytes: 100, snapshotPartialMD5: "", freshPartialMD5: ""))
        #expect(R.fixityIdentityHolds(fixity: fx, freshSizeBytes: 100, snapshotPartialMD5: "a", freshPartialMD5: "a"))
        #expect(R.fixityIdentityHolds(fixity: fx, freshSizeBytes: 100, snapshotPartialMD5: "a", freshPartialMD5: ""))
        #expect(R.fixityIdentityHolds(fixity: fx, freshSizeBytes: 100, snapshotPartialMD5: "", freshPartialMD5: "b"))
        // Fails
        #expect(!R.fixityIdentityHolds(fixity: fx, freshSizeBytes: 101, snapshotPartialMD5: "", freshPartialMD5: ""),
                "size disagreement alone drops")
        #expect(!R.fixityIdentityHolds(fixity: fx, freshSizeBytes: 100, snapshotPartialMD5: "a", freshPartialMD5: "b"),
                "fingerprint disagreement at the same size drops")
        #expect(!R.fixityIdentityHolds(fixity: fx, freshSizeBytes: 0, snapshotPartialMD5: "a", freshPartialMD5: "a"),
                "size disagreement wins even when fingerprints agree")
        // No fixity → nothing to decide.
        let none = VideoRecord()
        none.fullPath = "/Volumes/FamilyArchive/none.mov"
        #expect(R(from: none).fixityCarry(onto: freshlyScannedRecord(path: none.fullPath)) == .notApplicable)
    }

    // (a7) LOGIC — move adoption reuses the same struct on the OLD
    // instance, which still HOLDS its fixity: the nil assignment on drop
    // is load-bearing there (a fresh probe starts nil; the old record
    // does not).
    @Test func moveAdoptionDropsFixityWhenTheMovedFileChangedSize_andCarriesOtherwise() {
        let model = VideoScanModel()

        let changed = archiveCopyRecord(path: "/Volumes/FamilyArchive/a/old.mov", partialMD5: "aa11")
        let changedFresh = freshlyScannedRecord(path: "/Volumes/FamilyArchive/b/new.mov",
                                                sizeBytes: 4_243, partialMD5: "aa11")
        #expect(model.adoptMovedRecord(old: changed, fresh: changedFresh) == .dropped)
        #expect(changed.archiveFixity == nil,
                "the OLD instance carried a fixity — apply() must clear it, not leave it standing")
        #expect(changed.fullPath == "/Volumes/FamilyArchive/b/new.mov", "the record still followed its file")
        #expect(changed.sizeBytes == 4_243)
        #expect(changed.originalFullPath == "/Volumes/LaCie/Tapes/reunion.mov",
                "first-move provenance (already stamped by Promote) untouched")
        #expect(changed.masterLocation == "/Volumes/FamilyArchive")

        let same = archiveCopyRecord(path: "/Volumes/FamilyArchive/c/old.mov", partialMD5: "bb22")
        let sameFresh = freshlyScannedRecord(path: "/Volumes/FamilyArchive/d/new.mov",
                                             sizeBytes: 4_242, partialMD5: "bb22")
        let before = same.archiveFixity
        #expect(model.adoptMovedRecord(old: same, fresh: sameFresh) == .carried)
        #expect(same.archiveFixity == before, "a rename with identical bytes keeps its fixity")
    }

    // (b) NEGATIVE — no fixity in, no fixity out; unknown paths get none.
    @Test func recordsWithoutFixityNeverGainOne_andUnknownPathsGetNone() {
        let model = VideoScanModel()
        let target = CatalogScanTarget(searchPath: "/Volumes/FamilyArchive")
        let copy = archiveCopyRecord(path: "/Volumes/FamilyArchive/a/copy.mov")
        // A curated record (in the map because of its note) with NO fixity.
        let plain = freshlyScannedRecord(path: "/Volumes/FamilyArchive/a/plain.mov")
        plain.notes = "not an archive copy"
        model.records = [copy, plain]
        model.scanTargets = [target]

        model.snapshotPreservedFieldsForRescan(of: target)
        model.records.removeAll()

        let freshCopy = freshlyScannedRecord(path: copy.fullPath, sizeBytes: 4_242)
        let freshPlain = freshlyScannedRecord(path: plain.fullPath)
        let freshNew = freshlyScannedRecord(path: "/Volumes/FamilyArchive/a/never-seen.mov")
        let restored = model.applyPreservedFieldsAfterRescan(
            of: target, onto: [freshCopy, freshPlain, freshNew])

        #expect(restored == 2, "copy + plain had snapshots; the never-seen path had none")
        #expect(freshCopy.archiveFixity == copy.archiveFixity)
        #expect(freshPlain.archiveFixity == nil, "a record with no fixity must not acquire one")
        #expect(freshPlain.notes == "not an archive copy", "its own curated data still restores")
        #expect(freshPlain.originalFullPath == nil)
        #expect(freshPlain.masterLocation.isEmpty)
        #expect(freshPlain.userDate == nil)
        #expect(freshNew.archiveFixity == nil, "a fresh record at an unknown path gets no fixity")
        #expect(freshNew.derivedFrom == nil)
        #expect(freshNew.userDate == nil)
    }

    // (b2) MERGE-LEVEL — a mixed rescan drops only where the bytes
    // changed, restores everything else on every record, and reports the
    // drops as ONE summary line (fa24921 console etiquette), naming them.
    @Test func rescanDropsFixityOnlyWhereBytesChanged_andLogsOneSummaryLine() async {
        let model = VideoScanModel()
        let target = CatalogScanTarget(searchPath: "/Volumes/FamilyArchive")
        let intact = archiveCopyRecord(path: "/Volumes/FamilyArchive/1985/intact.mov", partialMD5: "same")
        let grew = archiveCopyRecord(path: "/Volumes/FamilyArchive/1985/grew.mov")
        let rewritten = archiveCopyRecord(path: "/Volumes/FamilyArchive/1985/rewritten.mov", partialMD5: "before")
        model.records = [intact, grew, rewritten]
        model.scanTargets = [target]

        model.snapshotPreservedFieldsForRescan(of: target)
        model.records.removeAll()

        let freshIntact = freshlyScannedRecord(path: intact.fullPath, sizeBytes: 4_242, partialMD5: "same")
        let freshGrew = freshlyScannedRecord(path: grew.fullPath, sizeBytes: 99_999)
        let freshRewritten = freshlyScannedRecord(path: rewritten.fullPath, sizeBytes: 4_242, partialMD5: "after")
        let restored = model.applyPreservedFieldsAfterRescan(
            of: target, onto: [freshIntact, freshGrew, freshRewritten])

        #expect(restored == 3, "every record still had its curated fields restored")
        #expect(freshIntact.archiveFixity == intact.archiveFixity)
        #expect(freshGrew.archiveFixity == nil)
        #expect(freshRewritten.archiveFixity == nil)
        expectProvenanceRestored(freshGrew, "dropped fixity, provenance intact")
        expectProvenanceRestored(freshRewritten, "dropped fixity, provenance intact")
        #expect(freshRewritten.derivationKind == ArchivePromotion.derivationKind)
        #expect(freshRewritten.partialMD5 == "after", "partialMD5 never restored")

        // Console flush is on a 150ms debounce timer — give it a beat.
        try? await Task.sleep(nanoseconds: 400_000_000)
        let console = model.dashboard.consoleLines.joined(separator: "\n")
        #expect(console.contains("2 fixity record(s) dropped: bytes changed since verification"),
                "console: \(console)")
        #expect(console.contains("grew.mov") && console.contains("rewritten.mov"), "the dropped files are named")
        #expect(!console.contains("intact.mov"), "the carried file is not named")
        #expect(console.components(separatedBy: "fixity record(s) dropped").count == 2,
                "ONE summary line per merge, not one per record")
    }

    // (c) isWorthRestoring — fixity ALONE keeps the record in the map.
    @Test func fixityAloneMakesSnapshotWorthRestoring() {
        let r = VideoRecord()
        r.filename = "copy.mov"
        r.fullPath = "/Volumes/FamilyArchive/copy.mov"
        r.archiveFixity = ArchiveFixity(digest: "00", verifiedAt: Date(), sizeBytes: 1)
        #expect(RescanPreservedFields(from: r).isWorthRestoring,
                "fixity alone must keep the snapshot in the rescan map, or the merge drops it")

        // Each sibling provenance field alone must do the same.
        let byPath = VideoRecord(); byPath.originalFullPath = "/Volumes/LaCie/x.mov"
        #expect(RescanPreservedFields(from: byPath).isWorthRestoring, "originalFullPath alone")
        let byVolume = VideoRecord(); byVolume.originVolume = "LaCie"
        #expect(RescanPreservedFields(from: byVolume).isWorthRestoring, "originVolume alone")
        let byMaster = VideoRecord(); byMaster.masterLocation = "/Volumes/FamilyArchive"
        #expect(RescanPreservedFields(from: byMaster).isWorthRestoring, "masterLocation alone")
        let byDate = VideoRecord(); byDate.userDate = "1992"
        #expect(RescanPreservedFields(from: byDate).isWorthRestoring, "userDate alone")
        let byConfidence = VideoRecord(); byConfidence.userDateConfidence = "estimated"
        #expect(RescanPreservedFields(from: byConfidence).isWorthRestoring, "userDateConfidence alone")

        // partialMD5 is comparison-only evidence, NOT a reason to keep a
        // record in the map (it is never restored).
        let byMD5 = VideoRecord(); byMD5.partialMD5 = "0123456789abcdef0123456789abcdef"
        #expect(!RescanPreservedFields(from: byMD5).isWorthRestoring, "partialMD5 alone")

        // And the blank-record contract still holds (map stays small).
        #expect(!RescanPreservedFields(from: VideoRecord()).isWorthRestoring)
    }

    // (d) SCALE — snapshot + restore + re-link over 100k archive copies,
    // identity-matching (every fresh probe reports the verified size).
    // Real catalog is ~103k records; the pipeline applies the snapshot
    // BEFORE commitScanResults, so `records` still holds the old 100k
    // while the re-link pass walks them — modeled here (no removeAll).
    @Test("scale: snapshot + restore of 100k fixity-bearing records within budget",
          .timeLimit(.minutes(1)))
    func scale_snapshotAndRestore100kArchiveCopiesWithinBudget() {
        let model = VideoScanModel()
        let target = CatalogScanTarget(searchPath: "/Volumes/FamilyArchive")
        let verifiedAt = Date(timeIntervalSince1970: 1_755_000_000)
        var old: [VideoRecord] = []
        old.reserveCapacity(100_000)
        for i in 0..<100_000 {
            let path = "/Volumes/FamilyArchive/BreenFamilyArchive/1990s/199\(i % 10)/clip\(i).mov"
            let r = VideoRecord()
            r.filename = "clip\(i).mov"
            r.fullPath = path
            r.sizeBytes = Int64(i)
            r.partialMD5 = String(format: "%032x", i)
            r.archiveFixity = ArchiveFixity(digest: String(format: "%064x", i),
                                            verifiedAt: verifiedAt, sizeBytes: Int64(i))
            r.derivedFrom = UUID()
            r.derivationKind = ArchivePromotion.derivationKind
            r.archiveStage = .masterAssigned
            old.append(r)
        }
        model.records = old
        model.scanTargets = [target]

        var fresh: [VideoRecord] = []
        fresh.reserveCapacity(100_000)
        for r in old {
            // The file is unchanged: same size, same fingerprint.
            fresh.append(freshlyScannedRecord(path: r.fullPath, sizeBytes: r.sizeBytes,
                                              partialMD5: r.partialMD5))
        }

        let clock = ContinuousClock()
        var restored = 0
        let elapsed = clock.measure {
            model.snapshotPreservedFieldsForRescan(of: target)
            restored = model.applyPreservedFieldsAfterRescan(of: target, onto: fresh)
        }
        #expect(restored == 100_000)
        #expect(fresh[0].archiveFixity == old[0].archiveFixity)
        #expect(fresh[99_999].archiveFixity?.digest == String(format: "%064x", 99_999))
        #expect(fresh[54_321].derivationKind == ArchivePromotion.derivationKind)
        #expect(fresh[54_321].archiveStage == .masterAssigned)
        #expect(fresh[54_321].sizeBytes == 54_321, "scan-derived size untouched")
        #expect(fresh.allSatisfy { $0.archiveFixity != nil }, "identity held everywhere — nothing dropped")
        #expect(elapsed < .seconds(2),
                "100k snapshot + restore took \(elapsed) — budget 2s")
    }

    // (d2) SCALE — the drop path at 100k: every file changed size. The
    // guard must cost nothing extra, and the report must stay ONE line
    // (a bounded sample of names, never 100k lines).
    @Test("scale: 100k dropped fixities stay within budget and log one summary line",
          .timeLimit(.minutes(1)))
    func scale_100kDroppedFixitiesWithinBudget_oneSummaryLine() async {
        let model = VideoScanModel()
        let target = CatalogScanTarget(searchPath: "/Volumes/FamilyArchive")
        let verifiedAt = Date(timeIntervalSince1970: 1_755_000_000)
        var old: [VideoRecord] = []
        old.reserveCapacity(100_000)
        for i in 0..<100_000 {
            let r = VideoRecord()
            r.filename = "clip\(i).mov"
            r.fullPath = "/Volumes/FamilyArchive/BreenFamilyArchive/1990s/199\(i % 10)/clip\(i).mov"
            r.sizeBytes = Int64(i)
            r.archiveFixity = ArchiveFixity(digest: String(format: "%064x", i),
                                            verifiedAt: verifiedAt, sizeBytes: Int64(i))
            r.masterLocation = "/Volumes/FamilyArchive"
            old.append(r)
        }
        model.records = old
        model.scanTargets = [target]
        var fresh: [VideoRecord] = []
        fresh.reserveCapacity(100_000)
        for r in old { fresh.append(freshlyScannedRecord(path: r.fullPath, sizeBytes: r.sizeBytes + 1)) }

        let clock = ContinuousClock()
        var restored = 0
        let elapsed = clock.measure {
            model.snapshotPreservedFieldsForRescan(of: target)
            restored = model.applyPreservedFieldsAfterRescan(of: target, onto: fresh)
        }
        #expect(restored == 100_000, "curated fields still restored on every record")
        #expect(fresh.allSatisfy { $0.archiveFixity == nil }, "every fixity dropped")
        #expect(fresh[77_777].masterLocation == "/Volumes/FamilyArchive", "location association kept")
        #expect(elapsed < .seconds(2), "100k drop path took \(elapsed) — budget 2s")

        try? await Task.sleep(nanoseconds: 400_000_000)
        let console = model.dashboard.consoleLines.joined(separator: "\n")
        #expect(console.contains("100000 fixity record(s) dropped"), "console: \(console.prefix(400))")
        #expect(console.contains("and 99995 more"), "five names, then a count — never 100k lines")
        #expect(console.components(separatedBy: "fixity record(s) dropped").count == 2, "exactly one line")
    }

    // (e) SENSOR — end to end through the REAL pipeline (startTarget →
    // walker → probe → applyPreservedFieldsAfterRescan → commitScanResults),
    // ScanMergeScopeTests style: a same-path rescan of the archive tree
    // REPLACES the copy with a fresh instance, and that instance must
    // still carry its fixity AND its Promote lineage (derivedFrom +
    // derivationKind) together. RED before 2026-09-02 (fixity nil after
    // the merge — exactly what Rick saw on /Volumes/FamilyArchive).
    //
    // codex #975: the seeded fixity is the file's REAL SHA-256 and the
    // seeded fingerprint is the file's REAL partialMD5; the rescan hashes
    // (checksums ON), so identity is established on evidence from both
    // sides, not by the absence of it.
    @Test func sensor_archiveCopyFixityAndPromotionProvenanceSurviveSamePathRescan_2026_09_02() async throws {
        let dir = try makeArchiveTempDir("fixity")
        defer { try? FileManager.default.removeItem(at: dir) }
        let filePath = dir.appendingPathComponent("reunion.mov").path
        // Junk bytes: ffprobe fails but extensioned damaged media is still
        // cataloged, so the path IS re-seen and replaced by the merge.
        try Data(repeating: 0, count: 64).write(to: URL(fileURLWithPath: filePath))
        let realMD5 = FileHasher.partialMD5(path: filePath)
        #expect(!realMD5.isEmpty, "precondition: the fixture hashes")

        let model = makeArchivePipelineModel(hashing: true)
        // The promotion SOURCE lives on another volume (outside the
        // rescanned root) — its id is untouched by the merge, so the
        // copy's derivedFrom must still point at it afterwards.
        let source = freshlyScannedRecord(path: "/Volumes/LaCie/Tapes/reunion.mov")
        let verifiedAt = Date(timeIntervalSince1970: 1_755_000_000)
        let seed = archiveCopyRecord(path: filePath, sourceID: source.id, verifiedAt: verifiedAt,
                                     digest: sha256Of64ZeroBytes, sizeBytes: 64, partialMD5: realMD5)
        // The record's OWN sizeBytes is stale on purpose: the identity
        // reference is fixity.sizeBytes (what the digest covered), not
        // whatever the last scan happened to write.
        seed.sizeBytes = 999_999
        model.records = [source, seed]

        let target = CatalogScanTarget(searchPath: dir.path)
        model.scanTargets = [target]
        model.startTarget(target)
        _ = await target.scanTask?.value

        let refreshed = try #require(model.records.first { $0.fullPath == filePath },
                                     "Re-seen path must still be cataloged after the rescan")
        #expect(refreshed !== seed,
                "The merge must have REPLACED the record with a freshly-scanned instance")
        #expect(refreshed.sizeBytes == 64,
                "Scan-derived fields must be refreshed from disk (got \(refreshed.sizeBytes))")
        #expect(refreshed.partialMD5 == realMD5, "the rescan hashed the file — both sides carried evidence")

        // The archive copy is still a VERIFIED archive copy — the exact
        // test the sidebar / Volume dashboard / Hallie stats apply.
        #expect(refreshed.archiveFixity != nil,
                "fixity dropped by a same-path rescan of UNCHANGED bytes — 2026-09-02 FamilyArchive incident")
        #expect(refreshed.archiveFixity == seed.archiveFixity, "restored verbatim")
        #expect(refreshed.archiveFixity?.digest == sha256Of64ZeroBytes, "and it IS the digest of these bytes")
        #expect(refreshed.archiveFixity?.verifiedAt == verifiedAt)
        #expect(refreshed.archiveFixity?.sizeBytes == 64)
        // …and it still knows it is a Promote output of THAT source.
        #expect(refreshed.derivedFrom == source.id, "Promote lineage must survive with the fixity")
        #expect(refreshed.derivationKind == ArchivePromotion.derivationKind)
        expectProvenanceRestored(refreshed)
        #expect(refreshed.archiveStage == .masterAssigned)
        #expect(refreshed.lifecycleStage == .archived)
        // The source outside the tree is untouched.
        #expect(model.records.contains { $0 === source })
    }

    // (f) SENSOR — the codex #975 shape through the REAL pipeline: the
    // archive copy was verified, then its bytes were overwritten with
    // DIFFERENT bytes of the SAME length (size alone cannot see it). The
    // rescan must drop the fixity (the badge goes honestly orange), keep
    // the provenance, and say so in one console line.
    @Test func sensor_fixityDroppedWhenBytesChangeAtSameSize_2026_09_02() async throws {
        let dir = try makeArchiveTempDir("fixitydrop")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("reunion.mov")
        let filePath = fileURL.path
        try Data(repeating: 0, count: 64).write(to: fileURL)
        let verifiedMD5 = FileHasher.partialMD5(path: filePath)

        // Verified state as Promote left it — for the ORIGINAL bytes.
        let verifiedAt = Date(timeIntervalSince1970: 1_755_000_000)
        let seed = archiveCopyRecord(path: filePath, verifiedAt: verifiedAt,
                                     digest: sha256Of64ZeroBytes, sizeBytes: 64, partialMD5: verifiedMD5)
        // Then the file rots / is overwritten: same length, other bytes.
        try Data(repeating: 0x01, count: 64).write(to: fileURL)
        #expect(FileHasher.partialMD5(path: filePath) != verifiedMD5, "precondition: the fingerprint moved")

        let model = makeArchivePipelineModel(hashing: true)
        model.records = [seed]
        let target = CatalogScanTarget(searchPath: dir.path)
        model.scanTargets = [target]
        model.startTarget(target)
        _ = await target.scanTask?.value

        let refreshed = try #require(model.records.first { $0.fullPath == filePath })
        #expect(refreshed !== seed)
        #expect(refreshed.sizeBytes == 64, "same size — the size check alone would have passed")
        #expect(refreshed.archiveFixity == nil,
                "bytes changed under a verified copy — a present fixity would be a false 'verified'")
        expectProvenanceRestored(refreshed, "location association + user date survive the drop")
        #expect(refreshed.derivationKind == ArchivePromotion.derivationKind)
        #expect(refreshed.archiveStage == .masterAssigned)

        try? await Task.sleep(nanoseconds: 400_000_000)
        let console = model.dashboard.consoleLines.joined(separator: "\n")
        #expect(console.contains("1 fixity record(s) dropped: bytes changed since verification (reunion.mov)"),
                "console: \(console)")
        #expect(console.contains("Verify copies…"), "the line tells Rick the way back")
    }
}

// MARK: - Pipeline helpers for the end-to-end sensor (ScanMergeScopeTests style)

/// Model with a DETERMINISTIC in-memory scan policy. VideoScanModel's
/// default `scanOptions = .restored()` reads the developer's LIVE
/// UserDefaults in the test host, so with factory defaults
/// (skipSmallFiles=true) the 64-byte fixture would never be discovered.
/// Pinned in memory only; `ScanOptions.save()` is never called, so real
/// prefs are untouched (settings-pollution class).
///
/// `hashing: true` turns checksums ON so the fresh probe carries a
/// partialMD5 — the fixity identity guard then has evidence on both
/// sides (the sensors need that; a 64-byte fixture hashes in microseconds).
@MainActor
private func makeArchivePipelineModel(hashing: Bool = false) -> VideoScanModel {
    let model = VideoScanModel()
    var opts = ScanOptions()
    opts.skipSmallFiles = false      // fixture is a tiny junk-byte file
    opts.skipChecksums = !hashing
    opts.probeExtensionless = false
    model.scanOptions = opts
    return model
}

private func makeArchiveTempDir(_ label: String) throws -> URL {
    // Canonicalize: NSTemporaryDirectory() is /var/folders/…, but the
    // walker yields realpath'd /private/var/folders/… URLs. Seeded
    // record paths must share the walker's prefix or nothing matches.
    var dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("vs_rescanfixity_\(label)_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    if let canonical = try dir.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath {
        dir = URL(fileURLWithPath: canonical, isDirectory: true)
    }
    return dir
}
