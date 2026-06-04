import Testing
import Foundation
@testable import VideoScan

// MARK: - Video metadata dossier schema
//
// The dossier is the structured output of one full multi-signal pass
// over a video: targeted VLM prompts (OCR date / on-screen text /
// scene description) + Whisper audio transcript + file metadata. The
// fields below are additive optionals on VideoRecord, sharing the same
// decodeIfPresent migration shape as suspectedPeople / sceneCaptions /
// audioTranscript / confirmedByUserPeople did earlier today. Legacy
// catalog.json files round-trip byte-identical until a record is
// actually dossiered.
//
// PROVEN on Clip 03_converted.mov 2026-06-04:
//   - file mtime: 2024-04-20 (transcode date — wrong)
//   - OCR consensus across 11/15 frames: "JUN 21 1991, PM 11:30"
//   - Triangulated truth: 1991-06-21
// → ocrDateCandidates per-frame, inferredRecordDate +
//   inferredDateConfidence as the consensus output.

struct DossierSchemaTests {

    @Test func ocrDateCandidatesRoundTrip() throws {
        let r = VideoRecord()
        r.ocrDateCandidates = [
            SceneCaption(timestamp: 2.4, text: "JUN.21 1991"),
            SceneCaption(timestamp: 7.3, text: "PM11:30 JUN.21 1991")
        ]
        let data = try JSONEncoder().encode(r)
        let decoded = try JSONDecoder().decode(VideoRecord.self, from: data)
        #expect(decoded.ocrDateCandidates.count == 2)
        #expect(decoded.ocrDateCandidates[0].text == "JUN.21 1991")
        #expect(decoded.ocrDateCandidates[1].timestamp == 7.3)
    }

    @Test func ocrTextRoundTrip() throws {
        let r = VideoRecord()
        r.ocrText = [SceneCaption(timestamp: 0.0, text: "PLAY")]
        let data = try JSONEncoder().encode(r)
        let decoded = try JSONDecoder().decode(VideoRecord.self, from: data)
        #expect(decoded.ocrText.count == 1)
        #expect(decoded.ocrText[0].text == "PLAY")
    }

    @Test func inferredRecordDateRoundTrip() throws {
        let r = VideoRecord()
        let ts = Date(timeIntervalSince1970: 677462400)   // 1991-06-21
        r.inferredRecordDate = ts
        r.inferredDateConfidence = 0.95
        let data = try JSONEncoder().encode(r)
        let decoded = try JSONDecoder().decode(VideoRecord.self, from: data)
        #expect(decoded.inferredRecordDate == ts)
        #expect(decoded.inferredDateConfidence == 0.95)
    }

    @Test func dossierProvenanceRoundTrip() throws {
        let r = VideoRecord()
        let when = Date(timeIntervalSince1970: 1749100000)
        r.dossierProcessedAt = when
        r.dossierProcessedBy = "qwen2.5-vl-3b-4bit+whisper-medium-mlx-q4"
        let data = try JSONEncoder().encode(r)
        let decoded = try JSONDecoder().decode(VideoRecord.self, from: data)
        #expect(decoded.dossierProcessedAt == when)
        #expect(decoded.dossierProcessedBy == "qwen2.5-vl-3b-4bit+whisper-medium-mlx-q4")
    }

    // Delta-minimal encode: empty / nil dossier fields don't pollute
    // catalog.json for the 13,569 records that haven't been processed.
    @Test func emptyDossierFieldsAreOmittedFromJSON() throws {
        let r = VideoRecord()
        let data = try JSONEncoder().encode(r)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(!json.contains("ocrDateCandidates"))
        #expect(!json.contains("ocrText"))
        #expect(!json.contains("inferredRecordDate"))
        #expect(!json.contains("inferredDateConfidence"))
        #expect(!json.contains("dossierProcessedAt"))
        #expect(!json.contains("dossierProcessedBy"))
    }

    // Legacy catalog.json files have NONE of the new keys. They must
    // round-trip without throwing — same migration contract as the
    // confirmedByUserPeople work earlier today.
    @Test func legacyJsonWithoutDossierFieldsDecodes() throws {
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
        #expect(decoded.ocrDateCandidates.isEmpty)
        #expect(decoded.ocrText.isEmpty)
        #expect(decoded.inferredRecordDate == nil)
        #expect(decoded.inferredDateConfidence == nil)
        #expect(decoded.dossierProcessedAt == nil)
        #expect(decoded.dossierProcessedBy == nil)
    }

    // Search-bar match: OCR date candidates and OCR text should be
    // searchable like captions/transcripts — they're semantic content.
    // A user typing "1991" should surface this video even if the file
    // mtime says 2024.
    @Test func ocrDateCandidatesAreSearched() {
        let r = VideoRecord()
        r.filename = "Clip 03.mov"
        r.ocrDateCandidates = [SceneCaption(timestamp: 7.3, text: "PM11:30 JUN.21 1991")]
        #expect(pfRecordFilenameOrPersonMatch(r, query: "1991"))
        #expect(pfRecordFilenameOrPersonMatch(r, query: "JUN"))
        #expect(!pfRecordFilenameOrPersonMatch(r, query: "1992"))
    }

    @Test func ocrTextIsSearched() {
        let r = VideoRecord()
        r.filename = "thing.mov"
        r.ocrText = [SceneCaption(timestamp: 0.0, text: "Happy Birthday Donna")]
        #expect(pfRecordFilenameOrPersonMatch(r, query: "birthday"))
        #expect(pfRecordFilenameOrPersonMatch(r, query: "donna"))
    }
}
