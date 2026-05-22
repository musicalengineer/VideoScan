import Testing
import Foundation
@testable import VideoScan

// MARK: - Scene Captions Tests
//
// Coverage for the v4 schema additions (SceneCaption, sceneCaptions,
// sceneCaptionModel, sceneCaptionDate on VideoRecord, CatalogSnapshot
// currentVersion bump to 4) and the v3 → v4 migration path.
//
// Mirrors the FamilyTaggingTests v2 → v3 migration pattern: synthesize
// a JSON without the new keys, decode under the current schema, assert
// the new fields default cleanly. Then a v4 round-trip test to lock
// down encode/decode symmetry.

@MainActor
struct SceneCaptionsTests {

    // MARK: - Schema migration (v3 → v4)

    // A v3 catalog.json (no sceneCaptions / sceneCaptionModel /
    // sceneCaptionDate keys) must load cleanly under v4, with each
    // record's caption fields defaulting to [] / nil. decodeIfPresent
    // in the VideoRecord decoder is the safety net — this test pins
    // it down.
    @Test func v3CatalogJsonLoadsWithEmptyCaptionFields() throws {
        let v3Json = """
        {
          "version": 3,
          "savedAt": 0,
          "records": [
            {
              "id": "11111111-1111-1111-1111-111111111111",
              "fullPath": "/v/old.mov",
              "filename": "old.mov",
              "detectedPeople": ["Donna"],
              "suspectedPeople": ["Tim"]
            }
          ]
        }
        """.data(using: .utf8)!

        let snap = try JSONDecoder().decode(CatalogSnapshot.self, from: v3Json)

        #expect(snap.records.count == 1)
        #expect(snap.records[0].detectedPeople == ["Donna"])
        #expect(snap.records[0].suspectedPeople == ["Tim"])
        #expect(snap.records[0].sceneCaptions.isEmpty)
        #expect(snap.records[0].sceneCaptionModel == nil)
        #expect(snap.records[0].sceneCaptionDate == nil)
    }

    // A v2 catalog.json (no suspectedPeople OR caption fields) also
    // still loads under v4 — the migrations compose. Older catalogs
    // shouldn't break because someone added a newer field.
    @Test func v2CatalogJsonLoadsWithEmptyEverything() throws {
        let v2Json = """
        {
          "version": 2,
          "savedAt": 0,
          "records": [
            {
              "id": "22222222-2222-2222-2222-222222222222",
              "fullPath": "/v/very_old.mov",
              "filename": "very_old.mov",
              "detectedPeople": ["Donna"]
            }
          ]
        }
        """.data(using: .utf8)!

        let snap = try JSONDecoder().decode(CatalogSnapshot.self, from: v2Json)

        #expect(snap.records.count == 1)
        #expect(snap.records[0].detectedPeople == ["Donna"])
        #expect(snap.records[0].suspectedPeople.isEmpty)
        #expect(snap.records[0].sceneCaptions.isEmpty)
        #expect(snap.records[0].sceneCaptionModel == nil)
        #expect(snap.records[0].sceneCaptionDate == nil)
    }

    // Current schema version is 4. If this fails, someone bumped it
    // without updating the migration tests.
    @Test func currentVersionIs4() {
        #expect(CatalogSnapshot.currentVersion == 4)
    }

    // MARK: - Round-trip

    // A v4 catalog with captions populated round-trips through
    // encode + decode unchanged. Locks down encode-if-non-empty and
    // encodeIfPresent for the new fields.
    @Test func v4CatalogJsonRoundTripsCaptions() throws {
        let r = VideoRecord()
        r.fullPath = "/v/family.mov"
        r.filename = "family.mov"
        r.detectedPeople = ["Donna"]
        r.suspectedPeople = ["Tim"]
        r.sceneCaptions = [
            SceneCaption(timestamp: 0, text: "A man playing guitar in a kitchen"),
            SceneCaption(timestamp: 12.5, text: "Two children laughing at a table")
        ]
        r.sceneCaptionModel = "qwen2.5-vl-3b-4bit"
        r.sceneCaptionDate = Date(timeIntervalSince1970: 1_716_000_000)
        let snap = CatalogSnapshot(records: [r])

        let data = try JSONEncoder().encode(snap)
        let decoded = try JSONDecoder().decode(CatalogSnapshot.self, from: data)

        #expect(decoded.version == 4)
        #expect(decoded.records.count == 1)
        let rec = decoded.records[0]
        #expect(rec.detectedPeople == ["Donna"])
        #expect(rec.suspectedPeople == ["Tim"])
        #expect(rec.sceneCaptions.count == 2)
        #expect(rec.sceneCaptions[0].timestamp == 0)
        #expect(rec.sceneCaptions[0].text == "A man playing guitar in a kitchen")
        #expect(rec.sceneCaptions[1].timestamp == 12.5)
        #expect(rec.sceneCaptionModel == "qwen2.5-vl-3b-4bit")
        #expect(rec.sceneCaptionDate?.timeIntervalSince1970 == 1_716_000_000)
    }

    // Records without captions encode minimal JSON — caption keys are
    // omitted, not written as empty arrays / null. Keeps catalog.json
    // diffs small for the common case (most records will be untagged
    // until "Caption Videos" runs).
    @Test func uncaptionedRecordDoesNotEncodeCaptionKeys() throws {
        let r = VideoRecord()
        r.fullPath = "/v/untouched.mov"
        r.filename = "untouched.mov"

        let data = try JSONEncoder().encode(r)
        let json = String(data: data, encoding: .utf8) ?? ""

        #expect(!json.contains("sceneCaptions"))
        #expect(!json.contains("sceneCaptionModel"))
        #expect(!json.contains("sceneCaptionDate"))
    }

    // MARK: - SceneCaption equality

    // SceneCaption is Hashable + Sendable — required for ferrying
    // captioning results across actor boundaries (the VLM runs off
    // MainActor, the catalog mutation is on MainActor).
    @Test func sceneCaptionEquality() {
        let a = SceneCaption(timestamp: 5.0, text: "A dog on a sofa")
        let b = SceneCaption(timestamp: 5.0, text: "A dog on a sofa")
        let c = SceneCaption(timestamp: 5.1, text: "A dog on a sofa")
        #expect(a == b)
        #expect(a != c)
    }

    // MARK: - Sendable snapshot

    // VideoRecordSnapshot carries sceneCaptions across actor boundaries
    // alongside detected/suspected people. The Sendable struct is what
    // worker actors will use to inspect what a record currently has so
    // they don't re-caption files that already have fresh captions.
    @Test func snapshotCarriesCaptions() {
        let r = VideoRecord()
        r.sceneCaptions = [
            SceneCaption(timestamp: 0, text: "A man playing guitar")
        ]
        let s = r.snapshot()
        #expect(s.sceneCaptions.count == 1)
        #expect(s.sceneCaptions[0].text == "A man playing guitar")
    }
}
