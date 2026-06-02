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

    // Current schema version canary. If this fails, someone bumped
    // CatalogSnapshot.currentVersion without adding migration tests
    // for the new version. When updating: bump the literal AND add a
    // `vNCatalogJson…` round-trip test below.
    //
    // History: v2 (legacy), v3 (added caption fields), v4 (sceneCaption
    // model/date metadata), v5 (scanContext nested on record), v6
    // (originVolume + originalFullPath for Bucket-A/D adoption).
    // v5 and v6 migration tests are a known gap — only forward round-
    // trip is covered by `vNCatalogJsonRoundTripsCaptions` below.
    @Test func currentVersionIs6() {
        #expect(CatalogSnapshot.currentVersion == 6)
    }

    // MARK: - Round-trip

    // A current-schema catalog with captions populated round-trips
    // through encode + decode unchanged. Locks down encode-if-non-empty
    // and encodeIfPresent for the new fields. Asserts the live schema
    // version (currently 6) — bump the assertion when the canary above
    // is bumped.
    @Test func v6CatalogJsonRoundTripsCaptions() throws {
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

        #expect(decoded.version == 6)
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

    // MARK: - applyCaptions writeback (S2)

    private func record(_ path: String) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = path
        r.filename = (path as NSString).lastPathComponent
        return r
    }

    // Basic round-trip: applyCaptions writes the captions, model id,
    // and a current date. Future "re-caption with current model" UI
    // reads these to know which records are stale.
    @Test func applyCaptionsWritesCaptionsAndProvenance() {
        let model = VideoScanModel()
        let r = record("/v/family.mov")
        model.records = [r]
        let before = Date()

        let captions = [
            SceneCaption(timestamp: 1.0, text: "A kitchen scene"),
            SceneCaption(timestamp: 5.0, text: "Person at a piano")
        ]
        let ok = model.applyCaptions(captions, to: "/v/family.mov",
                                     model: "qwen2.5-vl-3b-4bit")

        #expect(ok)
        #expect(r.sceneCaptions == captions)
        #expect(r.sceneCaptionModel == "qwen2.5-vl-3b-4bit")
        #expect(r.sceneCaptionDate != nil)
        #expect((r.sceneCaptionDate ?? .distantPast) >= before)
    }

    // Re-captioning replaces the array wholesale (per plan: "we don't
    // merge captions from different models"). The new model id wins;
    // any prior captions are gone.
    @Test func applyCaptionsReplacesPriorCaptions() {
        let model = VideoScanModel()
        let r = record("/v/family.mov")
        r.sceneCaptions = [SceneCaption(timestamp: 0, text: "OLD CAPTION")]
        r.sceneCaptionModel = "older-model"
        model.records = [r]

        let fresh = [SceneCaption(timestamp: 1, text: "NEW CAPTION")]
        _ = model.applyCaptions(fresh, to: "/v/family.mov", model: "qwen2.5-vl-3b-4bit")

        #expect(r.sceneCaptions == fresh)
        #expect(r.sceneCaptionModel == "qwen2.5-vl-3b-4bit")
    }

    // Empty captions is a valid result — "we ran the VLM and it found
    // nothing recognizable on this video." Records this distinctly
    // from "never captioned" (sceneCaptionModel == nil).
    @Test func applyCaptionsEmptyArrayMarksRanWithNoResults() {
        let model = VideoScanModel()
        let r = record("/v/blank.mov")
        model.records = [r]

        let ok = model.applyCaptions([], to: "/v/blank.mov", model: "qwen2.5-vl-3b-4bit")

        #expect(ok)
        #expect(r.sceneCaptions.isEmpty)
        #expect(r.sceneCaptionModel == "qwen2.5-vl-3b-4bit")
        #expect(r.sceneCaptionDate != nil)
    }

    // Unknown path → no-op. Captioning pipeline may produce results
    // for files not yet cataloged; we don't conjure ghost records.
    @Test func applyCaptionsReturnsFalseOnUnknownPath() {
        let model = VideoScanModel()
        model.records = []

        let ok = model.applyCaptions(
            [SceneCaption(timestamp: 0, text: "X")],
            to: "/v/unknown.mov",
            model: "qwen2.5-vl-3b-4bit"
        )

        #expect(!ok)
    }

    // Empty model id defends against accidental empty-provenance writes.
    @Test func applyCaptionsRejectsEmptyModelId() {
        let model = VideoScanModel()
        let r = record("/v/family.mov")
        model.records = [r]

        let ok = model.applyCaptions(
            [SceneCaption(timestamp: 0, text: "x")],
            to: "/v/family.mov",
            model: ""
        )

        #expect(!ok)
        #expect(r.sceneCaptions.isEmpty)
        #expect(r.sceneCaptionModel == nil)
    }

    // Touching one record doesn't disturb others. Captioning a single
    // file at a time should be a localized mutation.
    @Test func applyCaptionsPreservesOtherRecords() {
        let model = VideoScanModel()
        let a = record("/v/a.mov")
        let b = record("/v/b.mov")
        b.sceneCaptions = [SceneCaption(timestamp: 0, text: "untouched")]
        b.sceneCaptionModel = "earlier-model"
        model.records = [a, b]

        _ = model.applyCaptions(
            [SceneCaption(timestamp: 1, text: "new for a")],
            to: "/v/a.mov",
            model: "qwen2.5-vl-3b-4bit"
        )

        #expect(a.sceneCaptions.first?.text == "new for a")
        #expect(b.sceneCaptions == [SceneCaption(timestamp: 0, text: "untouched")])
        #expect(b.sceneCaptionModel == "earlier-model")
    }

    // Bulk variant maps a [path: captions] dict in one pass. Used by
    // the captioning loop to flush a batch through a single debounced
    // save.
    @Test func applyCaptionsBatchUpdatesAllMatchedPaths() {
        let model = VideoScanModel()
        let a = record("/v/a.mov")
        let b = record("/v/b.mov")
        let c = record("/v/c.mov")
        model.records = [a, b, c]

        let batch: [String: [SceneCaption]] = [
            "/v/a.mov": [SceneCaption(timestamp: 0, text: "alpha")],
            "/v/c.mov": [SceneCaption(timestamp: 0, text: "charlie")]
        ]
        let updated = model.applyCaptions(batch, model: "qwen2.5-vl-3b-4bit")

        #expect(updated == 2)
        #expect(a.sceneCaptions.first?.text == "alpha")
        #expect(b.sceneCaptions.isEmpty)
        #expect(c.sceneCaptions.first?.text == "charlie")
    }

    // Batch with unknown paths silently skips them — same forgiving
    // behavior as the single-record variant.
    @Test func applyCaptionsBatchSkipsUnknownPaths() {
        let model = VideoScanModel()
        let a = record("/v/a.mov")
        model.records = [a]

        let batch: [String: [SceneCaption]] = [
            "/v/a.mov":       [SceneCaption(timestamp: 0, text: "known")],
            "/v/missing.mov": [SceneCaption(timestamp: 0, text: "ghost")]
        ]
        let updated = model.applyCaptions(batch, model: "qwen2.5-vl-3b-4bit")

        #expect(updated == 1)
        #expect(a.sceneCaptions.first?.text == "known")
    }

    // MARK: - CaptionRunner protocol (S3)

    // Stub engines exist and announce their model IDs so the
    // provenance string passed to applyCaptions is consistent across
    // builds (today's "qwen2.5-vl-3b-4bit" is tomorrow's filter
    // criterion).
    @Test func mlxRunnerExposesQwen25Model() {
        let runner = MLXVLMCaptionRunner()
        #expect(runner.modelID == "qwen2.5-vl-3b-4bit")
    }

    @Test func pythonRunnerExposesDistinctModelID() {
        let runner = PythonSubprocessCaptionRunner(pythonPath: "/usr/bin/python3",
                                                   scriptPath: "/tmp/vlm.py")
        // Distinct from the MLX runner so logs / filters can tell them
        // apart even though both run the same underlying VLM family.
        #expect(runner.modelID == "python-vlm-qwen25vl-3b-4bit")
        #expect(runner.modelID != MLXVLMCaptionRunner().modelID)
    }

    // Both stubs throw notImplemented today. When the MLX engine ships,
    // its branch of this test will flip to "returns one caption per
    // timestamp" — that's the red-then-green signal we get for the
    // wiring change.
    @Test func mlxRunnerThrowsNotImplementedForNow() async {
        let runner = MLXVLMCaptionRunner()
        await #expect(throws: CaptionRunnerError.self) {
            _ = try await runner.caption(videoPath: "/v/anything.mov",
                                         atTimestamps: [0, 1, 2])
        }
    }

    @Test func pythonRunnerThrowsNotImplementedForNow() async {
        let runner = PythonSubprocessCaptionRunner(pythonPath: "/x", scriptPath: "/y")
        await #expect(throws: CaptionRunnerError.self) {
            _ = try await runner.caption(videoPath: "/v/anything.mov",
                                         atTimestamps: [0])
        }
    }

    // CaptionRunnerError.notImplemented carries the engine name so
    // diagnostic logs say WHICH engine isn't wired.
    @Test func notImplementedErrorIncludesEngineName() {
        let err = CaptionRunnerError.notImplemented(engine: "MLXVLM")
        #expect(err.description.contains("MLXVLM"))
    }

    // A mock CaptionRunner producing canned captions composes cleanly
    // with applyCaptions — exercises the end-to-end "engine output →
    // catalog row" path without needing a real VLM. This is the
    // integration seam the future MLX engine slots into.
    struct MockCaptionRunner: CaptionRunner {
        let modelID: String
        let canned: [SceneCaption]
        func caption(
            videoPath: String,
            atTimestamps timestamps: [Double]
        ) async throws -> [SceneCaption] {
            return canned
        }
    }

    @Test func mockRunnerCaptionsAppliedToCatalogEndToEnd() async throws {
        let videoModel = VideoScanModel()
        let r = record("/v/family.mov")
        videoModel.records = [r]

        let captions = [
            SceneCaption(timestamp: 1.0, text: "A man playing guitar"),
            SceneCaption(timestamp: 5.0, text: "A dog asleep on a couch")
        ]
        let runner = MockCaptionRunner(modelID: "mock-engine", canned: captions)

        // Mimic the captioning loop: extract captions via the runner,
        // then write them back through applyCaptions.
        let produced = try await runner.caption(videoPath: r.fullPath,
                                                atTimestamps: [1.0, 5.0])
        let ok = videoModel.applyCaptions(produced,
                                          to: r.fullPath,
                                          model: runner.modelID)

        #expect(ok)
        #expect(r.sceneCaptions == captions)
        #expect(r.sceneCaptionModel == "mock-engine")
        #expect(r.sceneCaptionDate != nil)
        // And the search bar can now find Donna's guitar moment
        // via caption text alone.
        #expect(pfRecordMatchesQuery(r, query: "guitar") == true)
    }
}
