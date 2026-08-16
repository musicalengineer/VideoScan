// ModelSchemaTests.swift
//
// SAFETY NET for the upcoming Models.swift restructure (UI decoupling →
// file decomposition → VideoScanCore SPM extraction). These tests pin the
// CURRENT persisted behavior of the model layer so the refactor can be
// proven byte-for-byte behavior-preserving: re-run after every step, they
// must stay green.
//
// Scope — the persisted Codable data layer only:
//   1. VideoRecord full Codable round-trip (every persisted field, distinct
//      non-default values, encode→decode→equality field by field).
//   2. Forward-compat decode of an OLDER catalog record that omits newer keys.
//   3. snapshotClone() parity via Mirror (the "4-place sync hazard" guard).
//   4. Persisted enum rawValue contracts (freezes the on-disk vocabulary).
//   5. Comparable orderings for PairConfidence / DuplicateConfidence /
//      ArchiveStage.
//
// Style: Swift Testing (`@Test` / `#expect`) to match the dominant suite
// style (ModelTests.swift, CatalogStoreAsyncSaveTests.swift). For Rick, who
// reads C++ test code: `#expect(x == y)` ≈ GoogleTest `EXPECT_EQ(x, y)` —
// a soft assertion that records a failure but lets the test body continue,
// so one round-trip test reports EVERY field that drifted, not just the
// first. `try #require(x)` ≈ `ASSERT_*` — a hard assertion that aborts the
// test if it fails (used for unwrapping).
//
// Encoder/decoder config MIRRORS CatalogStore exactly (see CatalogStore.swift
// `encodeAndWrite` / `decode`): JSONEncoder + JSONDecoder both with
// `.iso8601` date strategy and otherwise-default options (compact output,
// no .prettyPrinted / .sortedKeys). That is what actually touches disk for
// catalog.json, so these tests reflect real persistence rather than some
// idealized config.

import Testing
import Foundation
@testable import VideoScan

struct ModelSchemaTests {

    // MARK: - Shared encoder/decoder (mirrors CatalogStore.swift)

    /// Exactly the decoder CatalogStore.decode(url:) uses.
    private static func catalogDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Exactly the encoder CatalogStore.encodeAndWrite uses — compact,
    /// no .sortedKeys / .prettyPrinted, .iso8601 dates.
    private static func catalogEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    // MARK: - Fully-populated fixture

    /// A VideoRecord with EVERY persisted field set to a distinctive,
    /// NON-default value. Built once and reused by the round-trip test (1)
    /// and the clone-parity test (3).
    ///
    /// Construction note: rather than set ~60 fields imperatively (and risk
    /// a typo masking a real default), this builds the record by DECODING a
    /// hand-authored JSON object that names every CodingKey. That doubles as
    /// a check that each key actually round-trips through init(from:).
    /// `pairedWithID` is deliberately omitted here — paired references are a
    /// back-reference resolved by CatalogStore after the whole array decodes,
    /// not a value the record owns. Tests 1 and 3 set `pairedWith` explicitly
    /// where they need it.
    ///
    /// Dates use ISO-8601 with whole-second precision because that is what
    /// the `.iso8601` strategy emits/parses; sub-second values would not
    /// survive a round trip and would create a false failure.
    private static let fullyPopulatedJSON = """
    {
      "id": "11111111-2222-3333-4444-555555555555",
      "filename": "birthday_clip.mov",
      "ext": "mov",
      "streamTypeRaw": "Video+Audio",
      "size": "1.2 GB",
      "sizeBytes": 1288490188,
      "duration": "00:01:00",
      "durationSeconds": 60.5,
      "dateCreated": "1991-06-21",
      "dateModified": "1991-06-22",
      "dateCreatedRaw": "1991-06-21T12:00:00Z",
      "dateModifiedRaw": "1991-06-22T13:30:00Z",
      "container": "mov",
      "videoCodec": "h264",
      "resolution": "720x480",
      "frameRate": "29.97",
      "videoBitrate": "8 Mb/s",
      "totalBitrate": "9 Mb/s",
      "colorSpace": "bt601",
      "bitDepth": "8",
      "scanType": "interlaced",
      "audioCodec": "pcm_s16le",
      "audioChannels": "2",
      "audioSampleRate": "48000",
      "timecode": "01:00:00:00",
      "tapeName": "TAPE001",
      "isPlayable": "Yes",
      "partialMD5": "ABC123DEF456",
      "fullPath": "/Volumes/LaCie/birthday_clip.mov",
      "directory": "/Volumes/LaCie",
      "notes": "Matt's 5th birthday",
      "originalFullPath": "/Volumes/RicksBackups/birthday_clip.mov",
      "originVolume": "RicksBackups",
      "avidClipName": "Birthday Clip",
      "avidMobID": "060a2b34mob",
      "avidMaterialUUID": "amu-9988",
      "avidBinFile": "Birthdays.avb",
      "avidMobType": "MasterMob",
      "avidMediaPath": "/Avid MediaFiles/MXF/1/clip.mxf",
      "avidTapeName": "AVTAPE",
      "avidEditRate": 29.97,
      "avidTracks": "V1, A1-A2",
      "materialPackageUMID": "0x060A2B340101010501010D43",
      "pairGroupID": "88888888-8888-8888-8888-888888888888",
      "pairConfidence": "High",
      "duplicateGroupID": "77777777-7777-7777-7777-777777777777",
      "duplicateConfidence": "Medium",
      "duplicateDisposition": "Keep",
      "duplicateReasons": "identical partial md5",
      "duplicateBestMatchFilename": "birthday_copy.mov",
      "duplicateGroupCount": 3,
      "lifecycleStage": "Workbench",
      "mediaDisposition": "Important",
      "archiveStage": "Backed Up",
      "masterLocation": "Mac Studio SSD",
      "backupDestinations": [
        {"name": "LTA_Crucial", "kind": "Local", "date": "2026-01-01T00:00:00Z"},
        {"name": "iCloud", "kind": "Cloud", "date": "2026-01-02T00:00:00Z"},
        {"name": "Breen NAS", "kind": "Offsite", "date": "2026-01-03T00:00:00Z"}
      ],
      "junkScore": 7,
      "junkReasons": ["short", "low-bitrate"],
      "starRating": 3,
      "detectedPeople": ["Donna", "Rick"],
      "suspectedPeople": ["Tim"],
      "confirmedByUserPeople": [
        {"name": "Donna", "confirmedAt": "2026-04-12T00:00:00Z"}
      ],
      "rejectedPeople": ["Anna"],
      "sceneCaptions": [
        {"timestamp": 1.5, "text": "a man playing guitar in a kitchen"}
      ],
      "ocrDateCandidates": [
        {"timestamp": 2.0, "text": "JUN.21 1991"}
      ],
      "ocrText": [
        {"timestamp": 3.0, "text": "Happy Birthday Matt"}
      ],
      "inferredRecordDate": "1991-06-21T00:00:00Z",
      "inferredDateConfidence": 0.95,
      "dossierProcessedAt": "2026-06-04T00:00:00Z",
      "dossierProcessedBy": "qwen2.5-vl-3b-4bit+whisper-medium-mlx-q4",
      "sceneCaptionModel": "qwen2.5-vl-3b-4bit",
      "sceneCaptionDate": "2026-05-22T00:00:00Z",
      "audioTranscript": "happy birthday matt",
      "audioTranscriptModel": "whisper-medium-mlx-q4",
      "audioTranscriptDate": "2026-06-04T01:00:00Z",
      "combinedFromPairID": "66666666-6666-6666-6666-666666666666",
      "sourceHost": "MacStudio",
      "scanContext": {
        "scanHost": "MacStudio",
        "volumeUUID": "VU-1234",
        "volumeMountType": "smbfs",
        "volumeName": "MyBook3Terabytes",
        "remoteServerName": "macpro.local",
        "scannedAt": "2026-05-01T00:00:00Z",
        "scanRootLabel": "Movies"
      },
      "purgedAt": "2026-06-01T00:00:00Z",
      "drmProtected": true,
      "needsReformat": true,
      "derivedFrom": "55555555-aaaa-bbbb-cccc-555555555555",
      "workspaceActive": true
    }
    """

    private static func makeFullyPopulated() throws -> VideoRecord {
        try catalogDecoder().decode(VideoRecord.self, from: Data(fullyPopulatedJSON.utf8))
    }

    // MARK: - 1. Full Codable round-trip

    @Test
    func videoRecordFullRoundTrip() throws {
        let original = try Self.makeFullyPopulated()

        let data = try Self.catalogEncoder().encode(VideoRecordDTO(original))
        let decoded = try Self.catalogDecoder().decode(VideoRecord.self, from: data)

        // Sanity: the fixture really did populate things (guards against a
        // future JSON-literal typo silently leaving the fixture half-empty,
        // which would make the round-trip pass vacuously).
        #expect(!original.filename.isEmpty)
        #expect(original.scanContext.isPopulated)
        #expect(original.archiveStage == .backedUp)

        // Field-by-field equality. Soft #expect so a refactor that drops a
        // single field reports exactly which one. Grouped by type for
        // readability.

        // identity / strings
        #expect(decoded.id == original.id)
        #expect(decoded.filename == original.filename)
        #expect(decoded.ext == original.ext)
        #expect(decoded.streamTypeRaw == original.streamTypeRaw)
        #expect(decoded.size == original.size)
        #expect(decoded.duration == original.duration)
        #expect(decoded.dateCreated == original.dateCreated)
        #expect(decoded.dateModified == original.dateModified)
        #expect(decoded.container == original.container)
        #expect(decoded.videoCodec == original.videoCodec)
        #expect(decoded.resolution == original.resolution)
        #expect(decoded.frameRate == original.frameRate)
        #expect(decoded.videoBitrate == original.videoBitrate)
        #expect(decoded.totalBitrate == original.totalBitrate)
        #expect(decoded.colorSpace == original.colorSpace)
        #expect(decoded.bitDepth == original.bitDepth)
        #expect(decoded.scanType == original.scanType)
        #expect(decoded.audioCodec == original.audioCodec)
        #expect(decoded.audioChannels == original.audioChannels)
        #expect(decoded.audioSampleRate == original.audioSampleRate)
        #expect(decoded.timecode == original.timecode)
        #expect(decoded.tapeName == original.tapeName)
        #expect(decoded.isPlayable == original.isPlayable)
        #expect(decoded.partialMD5 == original.partialMD5)
        #expect(decoded.fullPath == original.fullPath)
        #expect(decoded.directory == original.directory)
        #expect(decoded.notes == original.notes)
        #expect(decoded.originalFullPath == original.originalFullPath)
        #expect(decoded.originVolume == original.originVolume)
        #expect(decoded.masterLocation == original.masterLocation)
        #expect(decoded.sourceHost == original.sourceHost)

        // numbers
        #expect(decoded.sizeBytes == original.sizeBytes)
        #expect(decoded.durationSeconds == original.durationSeconds)
        #expect(decoded.avidEditRate == original.avidEditRate)
        #expect(decoded.duplicateGroupCount == original.duplicateGroupCount)
        #expect(decoded.junkScore == original.junkScore)
        #expect(decoded.starRating == original.starRating)
        #expect(decoded.inferredDateConfidence == original.inferredDateConfidence)

        // dates (optional)
        #expect(decoded.dateCreatedRaw == original.dateCreatedRaw)
        #expect(decoded.dateModifiedRaw == original.dateModifiedRaw)
        #expect(decoded.inferredRecordDate == original.inferredRecordDate)
        #expect(decoded.dossierProcessedAt == original.dossierProcessedAt)
        #expect(decoded.sceneCaptionDate == original.sceneCaptionDate)
        #expect(decoded.audioTranscriptDate == original.audioTranscriptDate)
        #expect(decoded.purgedAt == original.purgedAt)

        // avid metadata
        #expect(decoded.avidClipName == original.avidClipName)
        #expect(decoded.avidMobID == original.avidMobID)
        #expect(decoded.avidMaterialUUID == original.avidMaterialUUID)
        #expect(decoded.avidBinFile == original.avidBinFile)
        #expect(decoded.avidMobType == original.avidMobType)
        #expect(decoded.avidMediaPath == original.avidMediaPath)
        #expect(decoded.avidTapeName == original.avidTapeName)
        #expect(decoded.avidTracks == original.avidTracks)
        #expect(decoded.materialPackageUMID == original.materialPackageUMID)

        // pairing / duplicate UUIDs + enums
        #expect(decoded.pairGroupID == original.pairGroupID)
        #expect(decoded.pairConfidence == original.pairConfidence)
        #expect(decoded.duplicateGroupID == original.duplicateGroupID)
        #expect(decoded.duplicateConfidence == original.duplicateConfidence)
        #expect(decoded.duplicateDisposition == original.duplicateDisposition)
        #expect(decoded.duplicateReasons == original.duplicateReasons)
        #expect(decoded.duplicateBestMatchFilename == original.duplicateBestMatchFilename)
        #expect(decoded.combinedFromPairID == original.combinedFromPairID)
        #expect(decoded.derivedFrom == original.derivedFrom)

        // lifecycle / archive enums + bools
        #expect(decoded.lifecycleStage == original.lifecycleStage)
        #expect(decoded.mediaDisposition == original.mediaDisposition)
        #expect(decoded.archiveStage == original.archiveStage)
        #expect(decoded.drmProtected == original.drmProtected)
        #expect(decoded.needsReformat == original.needsReformat)
        #expect(decoded.workspaceActive == original.workspaceActive)

        // arrays
        #expect(decoded.backupDestinations == original.backupDestinations)
        #expect(decoded.junkReasons == original.junkReasons)
        #expect(decoded.detectedPeople == original.detectedPeople)
        #expect(decoded.suspectedPeople == original.suspectedPeople)
        #expect(decoded.confirmedByUserPeople == original.confirmedByUserPeople)
        #expect(decoded.rejectedPeople == original.rejectedPeople)
        #expect(decoded.sceneCaptions == original.sceneCaptions)
        #expect(decoded.ocrDateCandidates == original.ocrDateCandidates)
        #expect(decoded.ocrText == original.ocrText)

        // dossier / caption / transcript provenance strings
        #expect(decoded.dossierProcessedBy == original.dossierProcessedBy)
        #expect(decoded.sceneCaptionModel == original.sceneCaptionModel)
        #expect(decoded.audioTranscript == original.audioTranscript)
        #expect(decoded.audioTranscriptModel == original.audioTranscriptModel)

        // nested struct
        #expect(decoded.scanContext == original.scanContext)
    }

    // MARK: - 2. Forward-compatibility decode (older catalog record)

    @Test
    func decodesLegacyRecordMissingNewerKeysWithDefaults() throws {
        // A v2-era catalog record: only the original core fields are present.
        // Every key added later (suspectedPeople, confirmedByUserPeople,
        // rejectedPeople, scene/ocr/dossier/audioTranscript, purgedAt,
        // drmProtected, needsReformat, derivedFrom, workspaceActive,
        // originalFullPath/originVolume, scanContext, materialPackageUMID,
        // the lifecycle/archive enums) is OMITTED. This locks the
        // decodeIfPresent forward-compat contract: old catalog.json files
        // must decode WITHOUT throwing and missing fields must take their
        // documented defaults.
        let legacyJSON = """
        {
          "id": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
          "filename": "old_clip.mov",
          "ext": "mov",
          "streamTypeRaw": "Video+Audio",
          "size": "500 MB",
          "sizeBytes": 524288000,
          "duration": "00:00:30",
          "durationSeconds": 30.0,
          "dateCreated": "2008-01-01",
          "dateModified": "2008-01-02",
          "container": "mov",
          "videoCodec": "h264",
          "resolution": "640x480",
          "fullPath": "/Volumes/Old/old_clip.mov",
          "directory": "/Volumes/Old"
        }
        """

        // Must not throw.
        let r = try Self.catalogDecoder().decode(VideoRecord.self, from: Data(legacyJSON.utf8))

        // Present fields decoded.
        #expect(r.filename == "old_clip.mov")
        #expect(r.sizeBytes == 524288000)
        #expect(r.durationSeconds == 30.0)

        // Missing fields → documented defaults.
        #expect(r.materialPackageUMID == "")
        #expect(r.originalFullPath == nil)
        #expect(r.originVolume == nil)
        #expect(r.suspectedPeople.isEmpty)
        #expect(r.confirmedByUserPeople.isEmpty)
        #expect(r.rejectedPeople.isEmpty)
        #expect(r.detectedPeople.isEmpty)
        #expect(r.sceneCaptions.isEmpty)
        #expect(r.ocrDateCandidates.isEmpty)
        #expect(r.ocrText.isEmpty)
        #expect(r.sceneCaptionModel == nil)
        #expect(r.sceneCaptionDate == nil)
        #expect(r.inferredRecordDate == nil)
        #expect(r.inferredDateConfidence == nil)
        #expect(r.dossierProcessedAt == nil)
        #expect(r.dossierProcessedBy == nil)
        #expect(r.audioTranscript == nil)
        #expect(r.audioTranscriptModel == nil)
        #expect(r.audioTranscriptDate == nil)
        #expect(r.purgedAt == nil)
        #expect(r.isPurged == false)
        #expect(r.drmProtected == false)
        #expect(r.needsReformat == false)
        #expect(r.derivedFrom == nil)
        #expect(r.workspaceActive == false)
        #expect(r.backupDestinations.isEmpty)
        #expect(r.junkReasons.isEmpty)
        #expect(r.junkScore == 0)
        #expect(r.starRating == 0)

        // Enum defaults.
        #expect(r.lifecycleStage == .cataloged)
        #expect(r.mediaDisposition == .unreviewed)
        #expect(r.archiveStage == .none)
        #expect(r.duplicateDisposition == .none)
        #expect(r.pairConfidence == nil)
        #expect(r.duplicateConfidence == nil)

        // Nested struct default (empty/unpopulated).
        #expect(r.scanContext.isPopulated == false)
        #expect(r.scanContext.scannedAt == nil)
    }

    // MARK: - 3. snapshotClone() parity via Mirror

    @Test
    func snapshotCloneCopiesEveryStoredProperty() throws {
        // The "4-place sync hazard": adding a VideoRecord field means
        // updating CodingKeys, init(from:), encode(to:), AND snapshotClone().
        // This test reflects over EVERY stored property on both the original
        // and its clone and asserts each matches — so a field forgotten in
        // snapshotClone() fails here with the property name, even if it round-
        // trips fine through Codable.
        let original = try Self.makeFullyPopulated()

        // `pairedWith` is a back-reference into the live record graph (and a
        // potential cycle). By design snapshotClone() does NOT copy it — see
        // Models.swift: CatalogStore.deepCopySnapshot rewires pairedWith to
        // the partner's CLONE, mirroring decode()'s pendingPairedWithID step.
        // Comparing it via Mirror would therefore ALWAYS fail (original has a
        // partner ref, clone has nil) — a false positive. We exclude it here
        // and assert its documented behavior separately below.
        let excluded: Set<String> = ["pairedWith"]

        // Give the original a paired partner so we can prove the exclusion is
        // real (clone.pairedWith stays nil even though original's is set).
        let partner = try Self.makeFullyPopulated()
        original.pairedWith = partner

        let clone = original.snapshotClone()
        #expect(clone !== original, "Clone must be a distinct object")

        let om = Mirror(reflecting: original)
        let cm = Mirror(reflecting: clone)

        // Map clone children by label for lookup.
        var cloneChildren: [String: Any] = [:]
        for child in cm.children {
            if let label = child.label { cloneChildren[label] = child.value }
        }

        var checked = 0
        for child in om.children {
            guard let label = child.label else { continue }
            if excluded.contains(label) { continue }

            guard let cloneValue = cloneChildren[label] else {
                Issue.record("snapshotClone() is MISSING stored property '\(label)' (present on original, absent on clone)")
                continue
            }

            // Compare via String(describing:) — VideoRecord's properties are
            // strings/numbers/dates/enums/Codable arrays, all of which render
            // stably and uniquely. (Equatable conformance isn't guaranteed for
            // every field type, so this is the robust common denominator the
            // task calls for.)
            let lhs = String(describing: child.value)
            let rhs = String(describing: cloneValue)
            #expect(lhs == rhs,
                    "snapshotClone() drifted on stored property '\(label)': original=\(lhs) clone=\(rhs)")
            checked += 1
        }

        // Guard against the Mirror enumerating nothing (e.g. if VideoRecord
        // ever became a struct/opaque) and the loop passing vacuously.
        #expect(checked >= 60,
                "Expected to reflect ~60+ stored properties; only saw \(checked) — Mirror enumeration may be broken")

        // Documented pairedWith behavior: snapshotClone leaves it nil; the
        // partner ref is rewired later by deepCopySnapshot, NOT by clone.
        #expect(original.pairedWith != nil, "fixture sanity: original should have a partner")
        #expect(clone.pairedWith == nil,
                "snapshotClone() must NOT copy pairedWith — it is rewired by deepCopySnapshot")
    }

    // MARK: - 4. Persisted enum rawValue contracts
    //
    // Freezes the EXACT on-disk vocabulary. If the refactor silently renames
    // a case rawValue, every catalog.json on disk would mis-decode — these
    // assertions catch it at compile/test time. `allCases` sweeps prove no
    // case is left unasserted (a new case added without a contract here fails
    // the count check).

    @Test
    func streamTypeRawValues() {
        #expect(StreamType.videoAndAudio.rawValue == "Video+Audio")
        #expect(StreamType.videoOnly.rawValue == "Video only")
        #expect(StreamType.audioOnly.rawValue == "Audio only")
        #expect(StreamType.noStreams.rawValue == "No A/V streams")
        #expect(StreamType.ffprobeFailed.rawValue == "ffprobe failed")
    }

    @Test
    func pairConfidenceRawValues() {
        #expect(PairConfidence.high.rawValue == "High")
        #expect(PairConfidence.medium.rawValue == "Medium")
        #expect(PairConfidence.low.rawValue == "Low")
    }

    @Test
    func duplicateConfidenceRawValues() {
        #expect(DuplicateConfidence.high.rawValue == "High")
        #expect(DuplicateConfidence.medium.rawValue == "Medium")
        #expect(DuplicateConfidence.low.rawValue == "Low")
    }

    @Test
    func duplicateDispositionRawValues() {
        #expect(DuplicateDisposition.none.rawValue == "")
        #expect(DuplicateDisposition.keep.rawValue == "Keep")
        #expect(DuplicateDisposition.review.rawValue == "Review")
        #expect(DuplicateDisposition.extraCopy.rawValue == "Extra copy")
    }

    @Test
    func lifecycleStageRawValues() {
        #expect(LifecycleStage.cataloged.rawValue == "Cataloged")
        #expect(LifecycleStage.reviewing.rawValue == "In Triage")
        #expect(LifecycleStage.workbench.rawValue == "Workbench")
        #expect(LifecycleStage.archived.rawValue == "Archived")
        #expect(LifecycleStage.trashed.rawValue == "Trashed")
        #expect(LifecycleStage.deletedPermanently.rawValue == "Deleted")
        // No case left unasserted.
        #expect(LifecycleStage.allCases.count == 6)
    }

    @Test
    func mediaDispositionRawValues() {
        #expect(MediaDisposition.unreviewed.rawValue == "Unreviewed")
        #expect(MediaDisposition.important.rawValue == "Important")
        #expect(MediaDisposition.recoverable.rawValue == "Recoverable")
        #expect(MediaDisposition.suspectedJunk.rawValue == "Suspected Junk")
        #expect(MediaDisposition.confirmedJunk.rawValue == "Confirmed Junk")
        #expect(MediaDisposition.allCases.count == 5)
    }

    @Test
    func archiveStageRawValues() {
        #expect(ArchiveStage.none.rawValue == "None")
        #expect(ArchiveStage.healthy.rawValue == "Healthy")
        #expect(ArchiveStage.masterAssigned.rawValue == "Master")
        #expect(ArchiveStage.backedUp.rawValue == "Backed Up")
        #expect(ArchiveStage.readyForArchive.rawValue == "Ready")
        #expect(ArchiveStage.archived.rawValue == "Archived")
        #expect(ArchiveStage.manuallyDeleted.rawValue == "Manually Deleted")
        #expect(ArchiveStage.salvageFailed.rawValue == "Salvage Failed")
        #expect(ArchiveStage.allCases.count == 8)
    }

    @Test
    func backupKindRawValues() {
        #expect(BackupEntry.BackupKind.local.rawValue == "Local")
        #expect(BackupEntry.BackupKind.cloud.rawValue == "Cloud")
        #expect(BackupEntry.BackupKind.offsite.rawValue == "Offsite")
        #expect(BackupEntry.BackupKind.allCases.count == 3)
    }

    // Volume* enums are persisted via BundleModels (VolumeMetadataSnapshot
    // stores their rawValue strings — see BundleModels.swift). Freezing them
    // here protects bundle export/import compatibility across the refactor.

    @Test
    func volumePhaseRawValues() {
        #expect(VolumePhase.noCatalog.rawValue == "NO CATALOG")
        #expect(VolumePhase.cataloged.rawValue == "Cataloged")
        #expect(VolumePhase.reviewed.rawValue == "Reviewed")
        #expect(VolumePhase.consolidated.rawValue == "Consolidated")
        #expect(VolumePhase.archived.rawValue == "Archived")
        #expect(VolumePhase.allCases.count == 5)
    }

    @Test
    func volumePhaseLegacyNewAlias() throws {
        // VolumePhase has a custom decoder mapping the legacy rawValue "New"
        // → .noCatalog. Pin it so the refactor preserves the alias.
        let decoded = try Self.catalogDecoder().decode(VolumePhase.self, from: Data("\"New\"".utf8))
        #expect(decoded == .noCatalog)
    }

    @Test
    func volumeRoleRawValues() {
        #expect(VolumeRole.unassigned.rawValue == "Unassigned")
        #expect(VolumeRole.system.rawValue == "System")
        #expect(VolumeRole.workspace.rawValue == "Workspace")
        #expect(VolumeRole.backup.rawValue == "Backup")
        #expect(VolumeRole.cloud.rawValue == "Cloud")
        #expect(VolumeRole.archive.rawValue == "Master Archive")
        // Taxonomy 2026-08-16 (final): `.retired` removed (retirement =
        // retiredAt), `.original` merged into `.workspace`, `.lta` → `.cloud`.
        #expect(VolumeRole.allCases.count == 6)
    }

    @Test
    func volumeTrustRawValues() {
        #expect(VolumeTrust.unknown.rawValue == "Unknown")
        #expect(VolumeTrust.reliable.rawValue == "Reliable")
        #expect(VolumeTrust.aging.rawValue == "Aging")
        #expect(VolumeTrust.unreliable.rawValue == "Unreliable")
        #expect(VolumeTrust.allCases.count == 4)
    }

    @Test
    func volumeMediaTechRawValues() {
        #expect(VolumeMediaTech.unknown.rawValue == "Unknown")
        #expect(VolumeMediaTech.ssd.rawValue == "SSD")
        #expect(VolumeMediaTech.hdd.rawValue == "HDD")
        #expect(VolumeMediaTech.raid0.rawValue == "RAID-0")
        #expect(VolumeMediaTech.raid1.rawValue == "RAID-1")
        #expect(VolumeMediaTech.raid5.rawValue == "RAID-5")
        #expect(VolumeMediaTech.raid10.rawValue == "RAID-10")
        #expect(VolumeMediaTech.cloud.rawValue == "Cloud")
        #expect(VolumeMediaTech.network.rawValue == "Network")
        #expect(VolumeMediaTech.allCases.count == 9)
    }

    // MARK: - 5. Comparable orderings
    //
    // These enums conform to Comparable; ordering drives UI sort + archive-
    // health gating (e.g. `archiveStage >= .backedUp`). Pin the full ordering
    // so the refactor can't reorder cases.

    @Test
    func pairConfidenceOrdering() {
        #expect(PairConfidence.low < PairConfidence.medium)
        #expect(PairConfidence.medium < PairConfidence.high)
        #expect(PairConfidence.low < PairConfidence.high)
        // Strictness / direction.
        #expect(!(PairConfidence.high < PairConfidence.low))
        #expect(PairConfidence.high > PairConfidence.medium)
    }

    @Test
    func duplicateConfidenceOrdering() {
        #expect(DuplicateConfidence.low < DuplicateConfidence.medium)
        #expect(DuplicateConfidence.medium < DuplicateConfidence.high)
        #expect(DuplicateConfidence.low < DuplicateConfidence.high)
        #expect(!(DuplicateConfidence.high < DuplicateConfidence.low))
    }

    @Test
    func archiveStageOrdering() {
        // Full declared order: none < healthy < masterAssigned < backedUp
        // < readyForArchive < archived < manuallyDeleted < salvageFailed.
        #expect(ArchiveStage.none < ArchiveStage.healthy)
        #expect(ArchiveStage.healthy < ArchiveStage.masterAssigned)
        #expect(ArchiveStage.masterAssigned < ArchiveStage.backedUp)
        #expect(ArchiveStage.backedUp < ArchiveStage.readyForArchive)
        #expect(ArchiveStage.readyForArchive < ArchiveStage.archived)
        #expect(ArchiveStage.archived < ArchiveStage.manuallyDeleted)
        #expect(ArchiveStage.manuallyDeleted < ArchiveStage.salvageFailed)

        // The gate used in production code (filenameColor / archiveHealth):
        // `archiveStage >= .backedUp` must hold for backedUp and everything
        // above it in the happy path.
        #expect(ArchiveStage.backedUp >= ArchiveStage.backedUp)
        #expect(ArchiveStage.archived >= ArchiveStage.backedUp)
        #expect(!(ArchiveStage.masterAssigned >= ArchiveStage.backedUp))
    }
}
