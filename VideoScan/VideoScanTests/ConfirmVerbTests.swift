// ConfirmVerbTests.swift
// Tests for the v1.1 Confirm-Person verb introduced 2026-06-16.
// Covers three layers:
//
//   1. PersonFinderTrainCandidates — scoring + round assembly
//   2. ConfirmRating — Codable backward compat (v1 raw values + Cameo)
//   3. ValidationLabelStore — roundtrip persistence + summary stats
//
// All tests use synthetic VideoRecords + temp directories — none touch
// the live catalog or the live validation_labels.json so they're safe
// to run while Rick is using the app.

import Testing
import Foundation
@testable import VideoScan

@MainActor
@Suite("Confirm Verb v1.1")
struct ConfirmVerbTests {

    // MARK: - Synthetic record helper

    private func makeRec(
        path: String,
        filename: String? = nil,
        people: [String] = [],
        confirmed: [String] = [],
        suspected: [String] = [],
        transcript: String? = nil,
        captions: [String] = [],
        ocr: [String] = [],
        md5: String = "",
        dgid: UUID? = nil,
        size: Int64 = 0,
        streamType: StreamType = .videoAndAudio
    ) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = path
        r.filename = filename ?? (path as NSString).lastPathComponent
        r.directory = (path as NSString).deletingLastPathComponent
        r.detectedPeople = people
        r.suspectedPeople = suspected
        r.confirmedByUserPeople = confirmed.map { ConfirmedTag(name: $0, confirmedAt: Date()) }
        r.audioTranscript = transcript
        r.sceneCaptions = captions.map { SceneCaption(timestamp: 0, text: $0) }
        r.ocrText = ocr.map { SceneCaption(timestamp: 0, text: $0) }
        r.partialMD5 = md5
        r.duplicateGroupID = dgid
        r.sizeBytes = size
        r.streamTypeRaw = streamType.rawValue
        return r
    }

    // MARK: - pfCandidatesForPerson: scoring

    @Test func scoring_emptyNameReturnsEmpty() {
        let recs = [makeRec(path: "/v/A.mov", transcript: "Donna is here")]
        #expect(pfCandidatesForPerson(name: "", records: recs).isEmpty)
    }

    @Test func scoring_filenameHitWeights10() {
        let rec = makeRec(path: "/v/Donna-Wedding.mov")
        let result = pfCandidatesForPerson(name: "Donna", records: [rec])
        #expect(result.count == 1)
        #expect(result[0].score == 10)
        #expect(result[0].signals.contains("filename"))
    }

    @Test func scoring_directoryHitWeights5() {
        let rec = makeRec(path: "/v/Donna_Folder/clip.mov", filename: "clip.mov")
        let result = pfCandidatesForPerson(name: "Donna", records: [rec])
        #expect(result.count == 1)
        #expect(result[0].signals.contains("directory"))
        // 5 for directory; no other matches
        #expect(result[0].score == 5)
    }

    @Test func scoring_transcriptCountedAndCapped() {
        // 6 mentions × 2 = 12, capped at 10
        let many = String(repeating: "Donna ", count: 6)
        let rec = makeRec(path: "/v/x.mov", transcript: many)
        let result = pfCandidatesForPerson(name: "Donna", records: [rec])
        #expect(result.count == 1)
        #expect(result[0].score == 10)  // capped
        #expect(result[0].signals.contains("transcript×6"))
    }

    @Test func scoring_pfConfirmedDominates() {
        let rec = makeRec(path: "/v/x.mov", confirmed: ["Donna"])
        let result = pfCandidatesForPerson(name: "Donna", records: [rec])
        #expect(result[0].score == 25)
        #expect(result[0].signals.contains("user-confirmed"))
    }

    @Test func scoring_zeroScoreExcluded() {
        let rec = makeRec(path: "/v/random.mov", transcript: "no one mentioned")
        let result = pfCandidatesForPerson(name: "Donna", records: [rec])
        #expect(result.isEmpty)
    }

    @Test func scoring_sortedDescendingByScore() {
        let weak = makeRec(path: "/v/dir1/a.mov", filename: "a.mov", transcript: "Donna")  // transcript×1 = 17
        let strong = makeRec(path: "/v/dir2/Donna.mov")  // filename = 10
        let stronger = makeRec(path: "/v/Donna_dir/x.mov", confirmed: ["Donna"])  // 25 + 5 = 30
        let result = pfCandidatesForPerson(name: "Donna", records: [weak, strong, stronger])
        #expect(result.count == 3)
        #expect(result[0].recordPath == "/v/Donna_dir/x.mov")
        #expect(result[0].score > result[1].score)
        #expect(result[1].score > result[2].score)
    }

    @Test func scoring_caseInsensitiveName() {
        let rec = makeRec(path: "/v/donna-clip.mov")
        let result = pfCandidatesForPerson(name: "DONNA", records: [rec])
        #expect(result.count == 1)
        #expect(result[0].signals.contains("filename"))
    }

    // MARK: - pfConfirmRound: assembly

    @Test func round_dedupsByPartialMD5() {
        let a = makeRec(path: "/V1/Donna.mov", md5: "abc123")
        let b = makeRec(path: "/V2/Donna.mov", md5: "abc123")  // same content, different volume
        let c = makeRec(path: "/V3/Donna.mov", md5: "different")
        var rng = SystemRandomNumberGenerator()
        let result = pfConfirmRound(
            name: "Donna", records: [a, b, c],
            topN: 50, controlK: 0,
            alreadyLabeled: [], rng: &rng
        )
        let donnaPaths = Set(result.candidates.map { $0.recordPath })
        #expect(donnaPaths.count == 2, "MD5-identical records should collapse to one")
        #expect(result.stats.dupesCollapsed == 1)
    }

    @Test func round_dedupsByDuplicateGroupID() {
        let groupID = UUID()
        // Both have Donna in filename so both score
        let a = makeRec(path: "/V1/Donna-x.mov", dgid: groupID)
        let b = makeRec(path: "/V2/Donna-y.mov", dgid: groupID)
        var rng = SystemRandomNumberGenerator()
        let result = pfConfirmRound(
            name: "Donna", records: [a, b],
            topN: 50, controlK: 0,
            alreadyLabeled: [], rng: &rng
        )
        #expect(result.candidates.count == 1)
        #expect(result.stats.dupesCollapsed == 1)
    }

    @Test func round_dedupFallsBackToBasenameAndSize() {
        let a = makeRec(path: "/V1/sub/Donna.mov", size: 1024)
        let b = makeRec(path: "/V2/other/Donna.mov", size: 1024)  // same name + size, no md5/dgid
        let c = makeRec(path: "/V3/DonnaBig.mov", size: 2048)  // different basename + size, NOT a dup
        var rng = SystemRandomNumberGenerator()
        let result = pfConfirmRound(
            name: "Donna", records: [a, b, c],
            topN: 50, controlK: 0,
            alreadyLabeled: [], rng: &rng
        )
        let paths = result.candidates.map { $0.recordPath }
        let msg = "Got \(result.candidates.count) candidates: \(paths)"
        #expect(result.candidates.count == 2, .init(rawValue: msg))
        #expect(result.stats.dupesCollapsed == 1)
    }

    @Test func round_skipsAlreadyLabeled() {
        let a = makeRec(path: "/v/Donna.mov")
        let b = makeRec(path: "/v/Donna2.mov")
        var rng = SystemRandomNumberGenerator()
        let result = pfConfirmRound(
            name: "Donna", records: [a, b],
            topN: 50, controlK: 0,
            alreadyLabeled: ["/v/Donna.mov"],
            rng: &rng
        )
        #expect(result.candidates.count == 1)
        #expect(result.candidates[0].recordPath == "/v/Donna2.mov")
        #expect(result.stats.alreadyLabeled == 1)
    }

    @Test func round_capsAtTopN() {
        var recs: [VideoRecord] = []
        for i in 0..<20 {
            recs.append(makeRec(path: "/v/Donna-\(i).mov"))
        }
        var rng = SystemRandomNumberGenerator()
        let result = pfConfirmRound(
            name: "Donna", records: recs,
            topN: 5, controlK: 0,
            alreadyLabeled: [], rng: &rng
        )
        #expect(result.candidates.count == 5)
        #expect(result.stats.candidatesSurfaced == 20)
    }

    @Test func round_statsReportSurfacedCount() {
        let recs = [
            makeRec(path: "/v/Donna1.mov"),
            makeRec(path: "/v/Donna2.mov"),
            makeRec(path: "/v/unrelated.mov", transcript: "nothing here"),
        ]
        var rng = SystemRandomNumberGenerator()
        let result = pfConfirmRound(
            name: "Donna", records: recs,
            topN: 100, controlK: 0,
            alreadyLabeled: [], rng: &rng
        )
        #expect(result.stats.candidatesSurfaced == 2)
    }

    // MARK: - ConfirmRating Codable backward compat

    @Test func rating_v1UnsureDecodesAsLegacy() throws {
        // Round-trip via JSON ensures the custom init(from decoder:)
        // gets exercised exactly the way the on-disk store does.
        let json = "[\"Unsure\"]".data(using: .utf8)!
        let decoded = try JSONDecoder().decode([ConfirmRating].self, from: json)
        #expect(decoded == [.unsure])
    }

    @Test func rating_v1UnlikelyDecodesAsLegacy() throws {
        let json = "[\"Unlikely\"]".data(using: .utf8)!
        let decoded = try JSONDecoder().decode([ConfirmRating].self, from: json)
        #expect(decoded == [.unlikely])
    }

    @Test func rating_newCameoDecodes() throws {
        let json = "[\"Cameo\"]".data(using: .utf8)!
        let decoded = try JSONDecoder().decode([ConfirmRating].self, from: json)
        #expect(decoded == [.cameo])
    }

    @Test func rating_garbageThrows() {
        let json = "[\"Bogus\"]".data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([ConfirmRating].self, from: json)
        }
    }

    @Test func rating_userFacingExcludesLegacy() {
        let visible = ConfirmRating.userFacing
        #expect(!visible.contains(.unsure))
        #expect(!visible.contains(.unlikely))
        #expect(visible.contains(.definitely))
        #expect(visible.contains(.likely))
        #expect(visible.contains(.cameo))
        #expect(visible.contains(.no))
    }

    @Test func rating_writebackTiers() {
        #expect(ConfirmRating.definitely.writebackTier == .confirmed)
        #expect(ConfirmRating.likely.writebackTier == .suspected)
        #expect(ConfirmRating.cameo.writebackTier == .none)  // sidecar only
        #expect(ConfirmRating.no.writebackTier == .rejected)
        #expect(ConfirmRating.unsure.writebackTier == .none)
        #expect(ConfirmRating.unlikely.writebackTier == .none)
    }

    // MARK: - ValidationLabelStore

    private func tempDir(_ name: String) -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vs_confirm_tests_\(UUID().uuidString.prefix(8))",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func store_recordPersistsImmediately() {
        let dir = tempDir("immediate")
        let store = ValidationLabelStore(directory: dir)
        store.record(
            recordPath: "/v/x.mov", person: "Donna",
            rating: .definitely, signals: ["filename"], score: 10
        )
        // Re-open from disk
        let reopened = ValidationLabelStore(directory: dir)
        #expect(reopened.labels.count == 1)
        #expect(reopened.labels[0].recordPath == "/v/x.mov")
        #expect(reopened.labels[0].rating == .definitely)
    }

    @Test func store_labeledByPathReturnsLatestForPerson() {
        let dir = tempDir("byPath")
        let store = ValidationLabelStore(directory: dir)
        store.record(
            recordPath: "/v/a.mov", person: "Donna",
            rating: .likely, signals: [], score: 5
        )
        store.record(
            recordPath: "/v/a.mov", person: "Donna",
            rating: .definitely, signals: [], score: 10
        )
        store.record(
            recordPath: "/v/a.mov", person: "Matt",
            rating: .no, signals: [], score: 0
        )
        let donnaLabels = store.labeledByPath(for: "Donna")
        #expect(donnaLabels["/v/a.mov"]?.rating == .definitely,
                "Newest label for the matching person wins")
        #expect(donnaLabels.count == 1, "Other person's labels excluded")
    }

    @Test func store_roundSummaryCountsAndSignalSources() {
        let dir = tempDir("summary")
        let store = ValidationLabelStore(directory: dir)
        let since = Date()
        store.record(
            recordPath: "/v/a.mov", person: "Donna",
            rating: .definitely, signals: ["filename", "transcript×3"], score: 16
        )
        store.record(
            recordPath: "/v/b.mov", person: "Donna",
            rating: .definitely, signals: ["PF-tagged"], score: 10
        )
        store.record(
            recordPath: "/v/c.mov", person: "Donna",
            rating: .no, signals: ["transcript×1"], score: 17
        )
        let summary = store.roundSummary(for: "Donna", since: since)
        #expect(summary.total == 3)
        #expect(summary.counts[.definitely] == 2)
        #expect(summary.counts[.no] == 1)
        // signalsByPositive only includes signals from .definitely/.likely
        // (writebackTier != .none). The .no record's "transcript×1"
        // should NOT appear here.
        #expect(summary.signalsByPositive["filename"] == 1)
        #expect(summary.signalsByPositive["transcript×3"] == 1)
        #expect(summary.signalsByPositive["PF-tagged"] == 1)
        #expect(summary.signalsByPositive["transcript×1"] == nil,
                "Negative-rated signals must not pollute positive precision")
    }
}
