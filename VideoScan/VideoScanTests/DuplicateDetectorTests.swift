import Testing
import Foundation
@testable import VideoScan

// MARK: - DuplicateDetector Tests

struct DuplicateDetectorTests {

    @Test func exactDuplicateHashProducesKeeperAndExtraCopy() {
        let original = makeDuplicateRecord(
            filename: "clip.mov",
            streamType: .videoAndAudio,
            sizeBytes: 5_000_000_000,
            durationSeconds: 60,
            partialMD5: "abc123",
            resolution: "1920x1080",
            videoCodec: "prores",
            audioCodec: "pcm_s16le"
        )

        let copy = makeDuplicateRecord(
            filename: "clip copy.mov",
            streamType: .videoAndAudio,
            sizeBytes: 5_000_000_000,
            durationSeconds: 60,
            partialMD5: "abc123",
            resolution: "1920x1080",
            videoCodec: "prores",
            audioCodec: "pcm_s16le"
        )

        let summary = DuplicateDetector.analyze(records: [original, copy])

        #expect(summary.groups == 1)
        #expect(summary.highConfidenceGroups == 1)
        #expect(original.duplicateDisposition == .keep || copy.duplicateDisposition == .keep)
        #expect(original.duplicateDisposition == .extraCopy || copy.duplicateDisposition == .extraCopy)
        #expect(original.duplicateGroupID == copy.duplicateGroupID)
    }

    @Test func metadataOnlyDuplicateWithStrongSignals() {
        let a = makeDuplicateRecord(
            filename: "Interview_01.mov",
            streamType: .videoAndAudio,
            sizeBytes: 1_000_000_000,
            durationSeconds: 42.0,
            partialMD5: "",
            resolution: "1280x720",
            videoCodec: "h264",
            audioCodec: "aac",
            timecode: "01:00:00:00"
        )

        let b = makeDuplicateRecord(
            filename: "Interview_01 (1).mov",
            streamType: .videoAndAudio,
            sizeBytes: 995_000_000,
            durationSeconds: 42.1,
            partialMD5: "",
            resolution: "1280x720",
            videoCodec: "h264",
            audioCodec: "aac",
            timecode: "01:00:00:00"
        )

        let summary = DuplicateDetector.analyze(records: [a, b])

        #expect(summary.groups == 1)
        #expect(summary.highConfidenceGroups == 1)
        #expect(summary.extraCopies == 1)
        #expect(a.duplicateDisposition == .keep || b.duplicateDisposition == .keep)
        #expect(a.duplicateDisposition == .extraCopy || b.duplicateDisposition == .extraCopy)
    }

    @Test func mismatchedStreamTypesDoNotGroup() {
        let withAudio = makeDuplicateRecord(
            filename: "same.mov",
            streamType: .videoAndAudio,
            sizeBytes: 100,
            durationSeconds: 10,
            partialMD5: "samehash"
        )

        let videoOnly = makeDuplicateRecord(
            filename: "same_copy.mov",
            streamType: .videoOnly,
            sizeBytes: 100,
            durationSeconds: 10,
            partialMD5: "samehash"
        )

        let summary = DuplicateDetector.analyze(records: [withAudio, videoOnly])

        #expect(summary.groups == 0)
        #expect(withAudio.duplicateDisposition == .none)
        #expect(videoOnly.duplicateDisposition == .none)
    }

    // MARK: - Threshold & confidence banding regression tests

    @Test func scoreBelowThresholdProducesNoGroup() {
        let a = makeDuplicateRecord(
            filename: "clip.mov",
            streamType: .videoAndAudio,
            sizeBytes: 100,
            durationSeconds: 30.0,
            partialMD5: "",
            audioCodec: "aac"
        )
        let b = makeDuplicateRecord(
            filename: "clip.mov",
            streamType: .videoAndAudio,
            sizeBytes: 200,
            durationSeconds: 30.0,
            partialMD5: "",
            audioCodec: "mp3"
        )

        let summary = DuplicateDetector.analyze(records: [a, b])

        #expect(summary.groups == 0)
        #expect(a.duplicateDisposition == .none)
        #expect(b.duplicateDisposition == .none)
    }

    @Test func scoreInLowBandProducesLowConfidenceGroup() {
        let a = makeDuplicateRecord(
            filename: "clip.mov",
            streamType: .videoAndAudio,
            sizeBytes: 100,
            durationSeconds: 30.0,
            partialMD5: "",
            audioCodec: "aac"
        )
        let b = makeDuplicateRecord(
            filename: "clip.mov",
            streamType: .videoAndAudio,
            sizeBytes: 200,
            durationSeconds: 30.0,
            partialMD5: "",
            audioCodec: "aac"
        )

        let summary = DuplicateDetector.analyze(records: [a, b])

        #expect(summary.groups == 1)
        #expect(summary.lowConfidenceGroups == 1)
        #expect(summary.mediumConfidenceGroups == 0)
        #expect(summary.highConfidenceGroups == 0)
    }

    @Test func scoreInMediumBandProducesMediumConfidenceGroup() {
        let a = makeDuplicateRecord(
            filename: "clip.mov",
            streamType: .videoAndAudio,
            sizeBytes: 100,
            durationSeconds: 30.0,
            partialMD5: "",
            resolution: "1920x1080",
            audioCodec: "aac"
        )
        let b = makeDuplicateRecord(
            filename: "clip.mov",
            streamType: .videoAndAudio,
            sizeBytes: 200,
            durationSeconds: 30.0,
            partialMD5: "",
            resolution: "1920x1080",
            audioCodec: "aac"
        )

        let summary = DuplicateDetector.analyze(records: [a, b])

        #expect(summary.groups == 1)
        #expect(summary.mediumConfidenceGroups == 1)
        #expect(summary.lowConfidenceGroups == 0)
        #expect(summary.highConfidenceGroups == 0)
    }
}

// MARK: - DuplicateDetector Same-Volume Safety Tests

struct DuplicateDeletionSafetyTests {

    @Test func keeperOnSameVolumeIsDeletable() {
        let keeper = makeDuplicateRecord(
            filename: "original.mov", streamType: .videoAndAudio,
            sizeBytes: 5_000_000, durationSeconds: 60,
            partialMD5: "aaa", resolution: "1920x1080",
            videoCodec: "h264", audioCodec: "aac"
        )
        keeper.fullPath = "/Volumes/MyDrive/videos/original.mov"

        let extra = makeDuplicateRecord(
            filename: "original copy.mov", streamType: .videoAndAudio,
            sizeBytes: 5_000_000, durationSeconds: 60,
            partialMD5: "aaa", resolution: "1920x1080",
            videoCodec: "h264", audioCodec: "aac"
        )
        extra.fullPath = "/Volumes/MyDrive/videos/original copy.mov"

        let summary = DuplicateDetector.analyze(records: [keeper, extra])
        #expect(summary.groups == 1)
        #expect(summary.highConfidenceGroups == 1)

        let keepRec = [keeper, extra].first { $0.duplicateDisposition == .keep }
        let extraRec = [keeper, extra].first { $0.duplicateDisposition == .extraCopy }
        #expect(keepRec != nil)
        #expect(extraRec != nil)
        #expect(keepRec?.duplicateGroupID == extraRec?.duplicateGroupID)
    }

    @Test func duplicateGroupIDAssignment() {
        let a = makeDuplicateRecord(
            filename: "clip.mov", streamType: .videoAndAudio,
            sizeBytes: 1_000_000, durationSeconds: 30,
            partialMD5: "hash1", resolution: "1280x720",
            videoCodec: "h264", audioCodec: "aac"
        )
        let b = makeDuplicateRecord(
            filename: "clip (1).mov", streamType: .videoAndAudio,
            sizeBytes: 1_000_000, durationSeconds: 30,
            partialMD5: "hash1", resolution: "1280x720",
            videoCodec: "h264", audioCodec: "aac"
        )
        let c = makeDuplicateRecord(
            filename: "unrelated.mov", streamType: .videoAndAudio,
            sizeBytes: 2_000_000, durationSeconds: 120,
            partialMD5: "hash2", resolution: "1920x1080",
            videoCodec: "prores", audioCodec: "pcm_s16le"
        )

        _ = DuplicateDetector.analyze(records: [a, b, c])

        #expect(a.duplicateGroupID != nil)
        #expect(a.duplicateGroupID == b.duplicateGroupID)
        #expect(c.duplicateGroupID == nil)
    }

    @Test func clearResetsAllDuplicateFields() {
        let rec = makeDuplicateRecord(
            filename: "test.mov", streamType: .videoAndAudio,
            sizeBytes: 1_000, durationSeconds: 10, partialMD5: "x"
        )
        rec.duplicateGroupID = UUID()
        rec.duplicateConfidence = .high
        rec.duplicateDisposition = .extraCopy
        rec.duplicateReasons = "hash+duration"
        rec.duplicateBestMatchFilename = "other.mov"
        rec.duplicateGroupCount = 2

        DuplicateDetector.clear(records: [rec])

        #expect(rec.duplicateGroupID == nil)
        #expect(rec.duplicateConfidence == nil)
        #expect(rec.duplicateDisposition == .none)
        #expect(rec.duplicateReasons.isEmpty)
        #expect(rec.duplicateBestMatchFilename.isEmpty)
        #expect(rec.duplicateGroupCount == 0)
    }
}

// MARK: - KeepersByGroupID Tests

@MainActor
struct KeepersByGroupIDTests {

    @Test func findsKeepers() {
        let model = VideoScanModel()
        let groupID = UUID()

        let keeper = VideoRecord()
        keeper.fullPath = "/Volumes/Drive/keeper.mov"
        keeper.duplicateGroupID = groupID
        keeper.duplicateDisposition = .keep

        let extra = VideoRecord()
        extra.fullPath = "/Volumes/Drive/extra.mov"
        extra.duplicateGroupID = groupID
        extra.duplicateDisposition = .extraCopy

        model.records = [keeper, extra]

        let result = model.keepersByGroupID()
        #expect(result.count == 1)
        #expect(result[groupID]?.fullPath == "/Volumes/Drive/keeper.mov")
    }

    @Test func emptyRecordsReturnsEmpty() {
        let model = VideoScanModel()
        model.records = []
        #expect(model.keepersByGroupID().isEmpty)
    }
}

// MARK: - VolumesWithDeletableDuplicates Tests

@MainActor
struct VolumesWithDeletableDuplicatesTests {

    @Test func sameVolumeIsReported() {
        let model = VideoScanModel()
        let groupID = UUID()

        let keeper = VideoRecord()
        keeper.fullPath = "/Volumes/Drive/folder1/keeper.mov"
        keeper.duplicateGroupID = groupID
        keeper.duplicateDisposition = .keep

        let extra = VideoRecord()
        extra.fullPath = "/Volumes/Drive/folder2/extra.mov"
        extra.duplicateGroupID = groupID
        extra.duplicateDisposition = .extraCopy
        extra.duplicateConfidence = .high

        model.records = [keeper, extra]

        let result = model.volumesWithDeletableDuplicates()
        #expect(result.count == 1)
        #expect(result.first?.path == "/Volumes/Drive")
        #expect(result.first?.count == 1)
    }

    @Test func crossVolumeDupsNotReported() {
        let model = VideoScanModel()
        let groupID = UUID()

        let keeper = VideoRecord()
        keeper.fullPath = "/Volumes/Primary/keeper.mov"
        keeper.duplicateGroupID = groupID
        keeper.duplicateDisposition = .keep

        let extra = VideoRecord()
        extra.fullPath = "/Volumes/Backup/extra.mov"
        extra.duplicateGroupID = groupID
        extra.duplicateDisposition = .extraCopy
        extra.duplicateConfidence = .high

        model.records = [keeper, extra]

        let result = model.volumesWithDeletableDuplicates()
        #expect(result.isEmpty)
    }
}
