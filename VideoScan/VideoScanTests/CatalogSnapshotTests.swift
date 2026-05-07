import Testing
import Foundation
@testable import VideoScan

// MARK: - VideoRecordSnapshot tests
//
// The snapshot is the foundation for migrating cross-actor work to a
// Sendable representation of catalog records. Tests pin the field
// mapping so adding a new property to `VideoRecord` doesn't silently
// drop it from the snapshot when callers expect it.

struct VideoRecordSnapshotTests {

    // regression: #66 — Snapshot copies identity fields verbatim
    @Test func copiesIdentityFields() {
        let r = VideoRecord()
        r.filename = "clip.mov"
        r.fullPath = "/Volumes/X/clip.mov"
        r.directory = "/Volumes/X"
        r.ext = "mov"
        let s = r.snapshot()
        #expect(s.id == r.id)
        #expect(s.filename == "clip.mov")
        #expect(s.fullPath == "/Volumes/X/clip.mov")
        #expect(s.directory == "/Volumes/X")
        #expect(s.ext == "mov")
    }

    // regression: #66 — Stream / size / duration carry across the snapshot
    @Test func copiesStreamFields() {
        let r = VideoRecord()
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        r.sizeBytes = 1_234_567
        r.durationSeconds = 60.5
        let s = r.snapshot()
        #expect(s.streamTypeRaw == StreamType.videoAndAudio.rawValue)
        #expect(s.streamType == .videoAndAudio)
        #expect(s.sizeBytes == 1_234_567)
        #expect(s.durationSeconds == 60.5)
    }

    // regression: #66 — Codec / format fields carry across the snapshot
    @Test func copiesCodecFields() {
        let r = VideoRecord()
        r.container = "mov"
        r.videoCodec = "h264"
        r.audioCodec = "aac"
        r.resolution = "1920x1080"
        r.frameRate = "29.97"
        r.timecode = "01:00:00:00"
        let s = r.snapshot()
        #expect(s.container == "mov")
        #expect(s.videoCodec == "h264")
        #expect(s.audioCodec == "aac")
        #expect(s.resolution == "1920x1080")
        #expect(s.frameRate == "29.97")
        #expect(s.timecode == "01:00:00:00")
    }

    // regression: #66 — Avid metadata carries across the snapshot
    @Test func copiesAvidMetadata() {
        let r = VideoRecord()
        r.avidClipName = "MyClip.V01.A01"
        r.avidMobID = "0d010301-aaaa-bbbb-cccc-dddddddddddd"
        r.avidMaterialUUID = "ffffffff-1234"
        r.avidTapeName = "Tape42"
        let s = r.snapshot()
        #expect(s.avidClipName == "MyClip.V01.A01")
        #expect(s.avidMobID == "0d010301-aaaa-bbbb-cccc-dddddddddddd")
        #expect(s.avidMaterialUUID == "ffffffff-1234")
        #expect(s.avidTapeName == "Tape42")
    }

    // regression: #66 — Reference fields are flattened to IDs
    @Test func referencesFlattenToIDs() {
        let video = VideoRecord()
        let audio = VideoRecord()
        video.pairedWith = audio
        let groupID = UUID()
        video.pairGroupID = groupID

        let s = video.snapshot()
        #expect(s.pairedWithID == audio.id)
        #expect(s.pairGroupID == groupID)
    }

    // regression: #66 — Records with no pair partner have nil pairedWithID
    @Test func unpairedRecordHasNilPairedID() {
        let r = VideoRecord()
        let s = r.snapshot()
        #expect(s.pairedWithID == nil)
    }

    // regression: #66 — Lifecycle / archive / disposition enums carry across
    @Test func copiesLifecycleFields() {
        let r = VideoRecord()
        r.lifecycleStage = .archived
        r.mediaDisposition = .important
        r.archiveStage = .healthy
        r.starRating = 3
        let s = r.snapshot()
        #expect(s.lifecycleStage == .archived)
        #expect(s.mediaDisposition == .important)
        #expect(s.archiveStage == .healthy)
        #expect(s.starRating == 3)
    }

    // regression: #66 — Catalog signals (detectedPeople, junkScore) carry
    @Test func copiesCatalogSignals() {
        let r = VideoRecord()
        r.detectedPeople = ["Donna", "Tim"]
        r.junkScore = 42
        let s = r.snapshot()
        #expect(s.detectedPeople == ["Donna", "Tim"])
        #expect(s.junkScore == 42)
    }

    // regression: #66 — Date fields carry across as Date? values
    @Test func copiesDateFields() {
        let r = VideoRecord()
        let created = Date(timeIntervalSince1970: 1_000_000_000)
        let modified = Date(timeIntervalSince1970: 1_500_000_000)
        r.dateCreatedRaw = created
        r.dateModifiedRaw = modified
        let s = r.snapshot()
        #expect(s.dateCreatedRaw == created)
        #expect(s.dateModifiedRaw == modified)
    }

    // regression: #66 — Snapshot is hashable (so it works in Sets / dictionaries)
    @Test func snapshotIsHashable() {
        let r = VideoRecord()
        r.filename = "clip.mov"
        let s1 = r.snapshot()
        let s2 = r.snapshot()
        #expect(s1 == s2)
        let set: Set<VideoRecordSnapshot> = [s1, s2]
        #expect(set.count == 1)
    }

    // regression: #66 — Two records with the same content have different IDs (so different snapshots)
    @Test func differentRecordsProduceDifferentSnapshots() {
        let r1 = VideoRecord()
        r1.filename = "clip.mov"
        let r2 = VideoRecord()
        r2.filename = "clip.mov"
        let s1 = r1.snapshot()
        let s2 = r2.snapshot()
        #expect(s1 != s2)
    }

    // regression: #66 — Bulk snapshot via Collection extension
    @Test func bulkSnapshotPreservesOrder() {
        let r1 = VideoRecord()
        r1.filename = "a.mov"
        let r2 = VideoRecord()
        r2.filename = "b.mov"
        let r3 = VideoRecord()
        r3.filename = "c.mov"
        let snaps = [r1, r2, r3].snapshots()
        #expect(snaps.count == 3)
        #expect(snaps.map(\.filename) == ["a.mov", "b.mov", "c.mov"])
    }
}
