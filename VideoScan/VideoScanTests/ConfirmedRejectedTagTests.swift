import Testing
import Foundation
@testable import VideoScan

// MARK: - confirmedByUserPeople + rejectedPeople schema
//
// New schema additions (2026-06-04) for the manual-tagging roadmap
// item. confirmedByUserPeople is the user's ground-truth ("yes, that
// IS Donna"), distinct from detectedPeople (algorithm-confidence).
// rejectedPeople is "no, that's NOT Anna" — suppresses future
// auto-tag of that name on this record AND feeds the eventual
// classifier-training loop as a hard negative.
//
// Additive optional fields with decodeIfPresent so legacy
// catalog.json files round-trip unchanged. Same pattern as
// suspectedPeople / sceneCaptions / audioTranscript migrations.

struct ConfirmedRejectedTagSchemaTests {

    // MARK: round-trip preservation

    @Test func confirmedTagRoundTripsNameAndDate() throws {
        let d = Date(timeIntervalSince1970: 1748966400)   // arbitrary fixed point
        let r = VideoRecord()
        r.filename = "IMG_4521.MOV"
        r.confirmedByUserPeople = [ConfirmedTag(name: "Donna", confirmedAt: d)]

        let data = try JSONEncoder().encode(r)
        let decoded = try JSONDecoder().decode(VideoRecord.self, from: data)

        #expect(decoded.confirmedByUserPeople.count == 1)
        #expect(decoded.confirmedByUserPeople.first?.name == "Donna")
        #expect(decoded.confirmedByUserPeople.first?.confirmedAt == d)
    }

    @Test func multipleConfirmedTagsRoundTrip() throws {
        let d1 = Date(timeIntervalSince1970: 1748966400)
        let d2 = Date(timeIntervalSince1970: 1749052800)
        let r = VideoRecord()
        r.confirmedByUserPeople = [
            ConfirmedTag(name: "Donna", confirmedAt: d1),
            ConfirmedTag(name: "Matt", confirmedAt: d2)
        ]

        let data = try JSONEncoder().encode(r)
        let decoded = try JSONDecoder().decode(VideoRecord.self, from: data)

        #expect(decoded.confirmedByUserPeople.count == 2)
        #expect(decoded.confirmedByUserPeople.map(\.name) == ["Donna", "Matt"])
    }

    @Test func rejectedPeopleRoundTrip() throws {
        let r = VideoRecord()
        r.rejectedPeople = ["Anna", "Tim"]

        let data = try JSONEncoder().encode(r)
        let decoded = try JSONDecoder().decode(VideoRecord.self, from: data)

        #expect(decoded.rejectedPeople == ["Anna", "Tim"])
    }

    // MARK: delta-minimal encoding

    @Test func emptyConfirmedTagsNotEncodedInJSON() throws {
        let r = VideoRecord()
        // Don't set confirmedByUserPeople — stays empty default
        let data = try JSONEncoder().encode(r)
        let json = String(data: data, encoding: .utf8) ?? ""
        // The catalog.json delta-minimal pattern: missing arrays are
        // not present in the JSON. Old records pre-confirmedByUserPeople
        // should byte-match this output once both are empty.
        #expect(!json.contains("confirmedByUserPeople"),
                "Empty confirmedByUserPeople should not appear in JSON")
    }

    @Test func emptyRejectedPeopleNotEncodedInJSON() throws {
        let r = VideoRecord()
        let data = try JSONEncoder().encode(r)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(!json.contains("rejectedPeople"),
                "Empty rejectedPeople should not appear in JSON")
    }

    // MARK: legacy decode (the critical migration test)

    @Test func legacyJsonWithoutNewFieldsDecodesAsEmpty() throws {
        // Simulates a record encoded BEFORE the new fields existed.
        let legacyJson = """
        {
          "id": "\(UUID().uuidString)",
          "filename": "old_record.mov",
          "ext": ".mov",
          "size": "1.0 MB",
          "sizeBytes": 1048576,
          "duration": "00:00:10",
          "durationSeconds": 10,
          "dateCreated": "",
          "dateModified": "",
          "container": "mov",
          "videoCodec": "h264",
          "resolution": "1920x1080",
          "frameRate": "30",
          "videoBitrate": "",
          "totalBitrate": "",
          "colorSpace": "",
          "bitDepth": "",
          "scanType": "",
          "audioCodec": "",
          "audioChannels": "",
          "audioSampleRate": "",
          "timecode": "",
          "tapeName": "",
          "isPlayable": "",
          "partialMD5": "",
          "fullPath": "/v/old.mov",
          "directory": "/v",
          "notes": "",
          "avidClipName": "",
          "avidMobID": "",
          "avidMaterialUUID": "",
          "avidBinFile": "",
          "avidMobType": "",
          "avidMediaPath": "",
          "avidTapeName": "",
          "avidEditRate": 0,
          "avidTracks": "",
          "duplicateDisposition": "",
          "duplicateReasons": "",
          "duplicateBestMatchFilename": "",
          "duplicateGroupCount": 0,
          "sourceHost": "",
          "lifecycleStage": "Cataloged",
          "mediaDisposition": "Unreviewed",
          "archiveStage": "None",
          "junkScore": 0
        }
        """
        let data = legacyJson.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(VideoRecord.self, from: data)
        #expect(decoded.confirmedByUserPeople.isEmpty)
        #expect(decoded.rejectedPeople.isEmpty)
        #expect(decoded.filename == "old_record.mov")
    }

    // MARK: search semantics

    @Test func confirmedByUserPeopleIsSearched() {
        let r = VideoRecord()
        r.filename = "IMG_4521.MOV"
        r.confirmedByUserPeople = [ConfirmedTag(name: "Donna", confirmedAt: Date())]
        // Manual-confirm names should match the catalog search bar
        // the same way detectedPeople do — same "tag on this video"
        // semantics.
        #expect(pfRecordFilenameOrPersonMatch(r, query: "donna"))
        #expect(pfRecordFilenameOrPersonMatch(r, query: "DONNA"))
        #expect(!pfRecordFilenameOrPersonMatch(r, query: "tim"))
    }

    @Test func rejectedPeopleAreNotSearched() {
        // Rejected names are explicit non-matches; they should NOT
        // surface in catalog search. Otherwise typing "Anna" on
        // Rick's rejection list would surface Donna-but-rejected-Anna
        // results, which is exactly the wrong UX.
        let r = VideoRecord()
        r.filename = "IMG_4521.MOV"
        r.rejectedPeople = ["Anna"]
        #expect(!pfRecordFilenameOrPersonMatch(r, query: "anna"))
        #expect(!pfRecordFilenameOrPersonMatch(r, query: "ANNA"))
    }
}
