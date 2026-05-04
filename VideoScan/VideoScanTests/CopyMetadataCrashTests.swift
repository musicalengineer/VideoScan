import Testing
import Foundation
@testable import VideoScan

// Regression test for "Copy All Metadata" crash (2026-05-04).
// Root cause: formatAllMetadata passes closures that capture `lines`
// by reference AND passes `lines` as inout to formatDuplicateSection.
// Swift's exclusivity checker aborts on the overlapping access.
// Only triggers when the record has duplicate or Avid metadata.

@MainActor
struct CopyMetadataCrashTests {

    @Test func copyMetadataWithDuplicateDataDoesNotCrash() throws {
        let rec = VideoRecord()
        rec.filename = "DonnaRockPiano.mov"
        rec.fullPath = "/Volumes/TestDrive/DonnaRockPiano.mov"
        rec.streamTypeRaw = StreamType.videoAndAudio.rawValue
        rec.size = "1.2 GB"
        rec.duration = "00:03:22"
        rec.durationSeconds = 202
        rec.notes = "Great video of Donna"
        rec.starRating = 3
        rec.mediaDisposition = .important
        rec.archiveStage = .backedUp
        rec.duplicateDisposition = .keep
        rec.duplicateBestMatchFilename = "DonnaRockPiano_copy.mov"
        rec.duplicateGroupCount = 2
        rec.duplicateConfidence = .high
        rec.duplicateReasons = "Hash match"

        let panel = InspectorPanel(
            record: rec,
            duplicateGroupMembers: [],
            previewImage: nil,
            previewOfflineVolumeName: nil
        )

        let result = panel.formatAllMetadata(rec)
        #expect(result.contains("DonnaRockPiano.mov"))
        #expect(result.contains("Duplicates"))
        #expect(result.contains("Keep"))
    }

    @Test func copyMetadataWithAvidDataDoesNotCrash() throws {
        let rec = VideoRecord()
        rec.filename = "A001_clip.mxf"
        rec.fullPath = "/Volumes/Avid/A001_clip.mxf"
        rec.streamTypeRaw = StreamType.videoOnly.rawValue
        rec.avidClipName = "Interview_01"
        rec.avidMobID = "060a2b340101010101010f00-13-00-00-00"
        rec.avidBinFile = "Project.avb"
        rec.avidTapeName = "A001"
        rec.avidTracks = "V1, A1-A2"
        rec.avidEditRate = 29.97

        let panel = InspectorPanel(
            record: rec,
            duplicateGroupMembers: [],
            previewImage: nil,
            previewOfflineVolumeName: nil
        )

        let result = panel.formatAllMetadata(rec)
        #expect(result.contains("A001_clip.mxf"))
        #expect(result.contains("Avid"))
        #expect(result.contains("Interview_01"))
    }
}
