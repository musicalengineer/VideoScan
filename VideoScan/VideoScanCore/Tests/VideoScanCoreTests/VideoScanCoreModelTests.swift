// VideoScanCoreModelTests.swift
//
// Package-level ISOLATION suite for the VideoScanCore domain model. Unlike
// the app target's VideoScanTests/ModelSchemaTests.swift (which validates
// the same public surface THROUGH the app via @_exported), this file uses a
// plain `import VideoScanCore` — NOT `@testable` — so it proves two things
// at once:
//
//   1. The package is buildable and testable in complete isolation
//      (`swift test` with zero app/SwiftUI dependencies — the real
//      extraction proof).
//   2. Everything these tests touch is genuinely PUBLIC. A non-public
//      member would fail to compile here, catching an under-exported API
//      before the app ever links against it.
//
// Scope (per the extraction task):
//   (a) VideoRecord full Codable round-trip — construct via decoding a JSON
//       literal that names every persisted field, then encode→decode and
//       compare field by field. Encoder/decoder mirror CatalogStore's real
//       on-disk config (.iso8601 dates, otherwise default).
//   (b) Exact rawValue contracts for every persisted enum, freezing the
//       on-disk vocabulary so a rename can't silently mis-decode catalogs.
//
// Style: Swift Testing (`@Test` / `#expect`). For Rick (C++): `#expect`
// ≈ GoogleTest `EXPECT_*` (soft — reports every drifted field, not just the
// first); `try #require` ≈ `ASSERT_*` (hard — aborts on failure).

import Testing
import Foundation
import VideoScanCore

struct VideoScanCoreModelTests {

    // MARK: - Shared encoder/decoder (mirrors CatalogStore.swift on-disk config)

    private static func catalogDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private static func catalogEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    // MARK: - Fully-populated fixture
    //
    // Every persisted field set to a distinctive NON-default value, built by
    // DECODING a hand-authored JSON object naming every CodingKey — so the
    // fixture itself exercises init(from:) for each key. `pairedWithID` is
    // omitted (paired refs are resolved post-decode by CatalogStore, not a
    // value the record owns). Dates use whole-second ISO-8601 because that's
    // what `.iso8601` emits/parses; sub-second values wouldn't survive.

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

    // MARK: - (a) Full Codable round-trip

    @Test
    func videoRecordFullRoundTrip() throws {
        let original = try Self.makeFullyPopulated()

        let data = try Self.catalogEncoder().encode(VideoRecordDTO(original))
        let decoded = try Self.catalogDecoder().decode(VideoRecord.self, from: data)

        // Sanity: the fixture really populated (guards a JSON-literal typo
        // silently leaving the fixture half-empty → vacuous pass).
        #expect(!original.filename.isEmpty)
        #expect(original.scanContext.isPopulated)
        #expect(original.archiveStage == .backedUp)

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

        // nested struct (ScanContext — also a public package type)
        #expect(decoded.scanContext == original.scanContext)
        #expect(decoded.scanContext.volumeName == "MyBook3Terabytes")
        #expect(decoded.scanContext.scanRootLabel == "Movies")
        #expect(decoded.scanContext.isRemoteMount)
    }

    // MARK: - (b) Persisted enum rawValue contracts
    //
    // Freezes the EXACT on-disk vocabulary. `allCases` sweeps prove no case
    // is added without a contract here.

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
        // Custom decoder maps legacy rawValue "New" → .noCatalog. Pin it.
        let decoded = try Self.catalogDecoder().decode(VolumePhase.self, from: Data("\"New\"".utf8))
        #expect(decoded == .noCatalog)
    }

    @Test
    func volumeRoleRawValues() {
        #expect(VolumeRole.unassigned.rawValue == "Unassigned")
        #expect(VolumeRole.system.rawValue == "System")
        #expect(VolumeRole.original.rawValue == "Original")
        #expect(VolumeRole.backup.rawValue == "Backup")
        #expect(VolumeRole.archive.rawValue == "Archive")
        #expect(VolumeRole.lta.rawValue == "Long-Term Archive")
        #expect(VolumeRole.retired.rawValue == "Retired")
        #expect(VolumeRole.allCases.count == 7)
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
}
