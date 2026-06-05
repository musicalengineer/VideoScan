import Foundation
import Testing
@testable import VideoScan

// MARK: - Dossier writeback tests
//
// Exercise `VideoScanModel.applyDossier` and its supporting helpers
// (pfPathYearHints, the triangulation hop into pfInferRecordDate) without
// touching MLX. These cover the writeback contract:
//
//   - 3-channel writeback (scenes / dates / texts) lands on the record
//   - Optional transcript channel is written iff non-nil
//   - Date triangulation invokes correctly from the writeback
//   - Provenance stack id reflects which engines actually ran
//   - Re-dossiering REPLACES wholesale, doesn't accumulate
//   - Path-key miss returns false without mutating state
//
// The matching orchestrator tests (StubDossierRunner driving
// runDossierBatch) live in CaptionOrchestratorDossierTests.swift.

@MainActor
@Suite("VideoScanModel.applyDossier writeback")
struct DossierWritebackTests {

    // MARK: - Helpers

    /// Build a VideoRecord with the minimum fields the dossier code path
    /// reads. `dateModifiedRaw` is what `pfInferRecordDate` uses for the
    /// last-resort mtime branch.
    private func makeRecord(
        path: String,
        mtime: Date? = nil
    ) -> VideoRecord {
        let r = VideoRecord()
        r.filename = (path as NSString).lastPathComponent
        r.fullPath = path
        r.dateModifiedRaw = mtime
        return r
    }

    // MARK: - Three-channel writeback

    @Test("applyDossier writes scenes / dates / texts to the record")
    func threeChannelWriteback() {
        let model = VideoScanModel()
        let path = "/Volumes/MyBook3Terabytes/Family/clip.mov"
        let rec = makeRecord(path: path, mtime: Date(timeIntervalSince1970: 1_700_000_000))
        model.records = [rec]

        let extraction = DossierExtraction(
            scenes: [
                SceneCaption(timestamp: 0.5, text: "Boy in striped shirt at kitchen table"),
                SceneCaption(timestamp: 1.5, text: "Same boy with a piece of cake")
            ],
            dates: [
                SceneCaption(timestamp: 0.5, text: "JUN 21 1991"),
                SceneCaption(timestamp: 1.5, text: "JUN 21 1991")
            ],
            texts: [
                SceneCaption(timestamp: 0.5, text: "HAPPY BIRTHDAY")
            ]
        )

        let updated = model.applyDossier(
            extraction,
            to: path,
            vlmModel: "qwen2.5-vl-3b-4bit",
            transcript: "Happy birthday Matt happy birthday to you",
            whisperModel: "whisper-medium-mlx-q4"
        )

        #expect(updated == true)
        #expect(rec.sceneCaptions.count == 2)
        #expect(rec.ocrDateCandidates.count == 2)
        #expect(rec.ocrText.count == 1)
        #expect(rec.sceneCaptions.first?.text == "Boy in striped shirt at kitchen table")
        #expect(rec.ocrDateCandidates.first?.text == "JUN 21 1991")
        #expect(rec.ocrText.first?.text == "HAPPY BIRTHDAY")
    }

    // MARK: - Provenance + dates

    @Test("applyDossier stamps provenance stack id with VLM + Whisper")
    func provenanceStackWithBoth() {
        let model = VideoScanModel()
        let path = "/Vols/foo/a.mov"
        let rec = makeRecord(path: path)
        model.records = [rec]

        _ = model.applyDossier(
            DossierExtraction(scenes: [], dates: [], texts: []),
            to: path,
            vlmModel: "qwen2.5-vl-3b-4bit",
            transcript: "",
            whisperModel: "whisper-medium-mlx-q4"
        )

        #expect(rec.dossierProcessedAt != nil)
        #expect(rec.dossierProcessedBy == "qwen2.5-vl-3b-4bit+whisper-medium-mlx-q4")
        #expect(rec.sceneCaptionModel == "qwen2.5-vl-3b-4bit")
        #expect(rec.audioTranscriptModel == "whisper-medium-mlx-q4")
    }

    @Test("applyDossier records VLM-only stack when transcript is nil")
    func provenanceStackVLMOnly() {
        let model = VideoScanModel()
        let path = "/Vols/foo/b.mov"
        let rec = makeRecord(path: path)
        model.records = [rec]

        _ = model.applyDossier(
            DossierExtraction(scenes: [SceneCaption(timestamp: 1.0, text: "scene")], dates: [], texts: []),
            to: path,
            vlmModel: "qwen2.5-vl-3b-4bit",
            transcript: nil,
            whisperModel: nil
        )

        #expect(rec.dossierProcessedBy == "qwen2.5-vl-3b-4bit")
        #expect(rec.audioTranscript == nil, "Nil transcript should not write the audio channel")
        #expect(rec.audioTranscriptModel == nil)
    }

    // MARK: - Triangulation invocation

    @Test("applyDossier triangulates inferred date from OCR consensus")
    func ocrConsensusDriveInferredDate() {
        let model = VideoScanModel()
        let path = "/Vols/MyBook/Family/clip.mov"
        // Bogus mtime — a transcode date that shouldn't be the inferred
        // date once OCR consensus dominates.
        let bogusMtime = Date(timeIntervalSince1970: 1_700_000_000)  // ≈2023
        let rec = makeRecord(path: path, mtime: bogusMtime)
        model.records = [rec]

        let extraction = DossierExtraction(
            scenes: [],
            dates: [
                SceneCaption(timestamp: 0.5, text: "JUN 21 1991"),
                SceneCaption(timestamp: 1.5, text: "JUN 21 1991"),
                SceneCaption(timestamp: 2.5, text: "JUN 21 1991")
            ],
            texts: []
        )

        _ = model.applyDossier(
            extraction,
            to: path,
            vlmModel: "qwen2.5-vl-3b-4bit",
            transcript: nil,
            whisperModel: nil
        )

        guard let inferred = rec.inferredRecordDate else {
            Issue.record("Expected inferredRecordDate to be set")
            return
        }
        let cal = Calendar(identifier: .gregorian)
        var calUTC = cal
        calUTC.timeZone = TimeZone(identifier: "UTC")!
        let components = calUTC.dateComponents([.year, .month, .day], from: inferred)
        #expect(components.year == 1991)
        #expect(components.month == 6)
        #expect(components.day == 21)
        // 3-frame consensus → 0.95 per DateTriangulation.swift
        #expect((rec.inferredDateConfidence ?? 0) > 0.9)
    }

    // MARK: - Replace-not-merge

    @Test("re-dossiering replaces prior signals wholesale")
    func reDossierReplacesNotMerges() {
        let model = VideoScanModel()
        let path = "/Vols/foo/c.mov"
        let rec = makeRecord(path: path)
        rec.sceneCaptions = [SceneCaption(timestamp: 0.0, text: "OLD")]
        rec.ocrDateCandidates = [SceneCaption(timestamp: 0.0, text: "OLD DATE")]
        rec.ocrText = [SceneCaption(timestamp: 0.0, text: "OLD TEXT")]
        model.records = [rec]

        _ = model.applyDossier(
            DossierExtraction(
                scenes: [SceneCaption(timestamp: 1.0, text: "NEW")],
                dates: [SceneCaption(timestamp: 1.0, text: "NEW DATE")],
                texts: []      // empty replaces — proves NOT a merge
            ),
            to: path,
            vlmModel: "vlm-2",
            transcript: nil,
            whisperModel: nil
        )

        #expect(rec.sceneCaptions.count == 1)
        #expect(rec.sceneCaptions.first?.text == "NEW")
        #expect(rec.ocrDateCandidates.count == 1)
        #expect(rec.ocrDateCandidates.first?.text == "NEW DATE")
        #expect(rec.ocrText.isEmpty,
                "Empty replacement should clear prior ocrText, not merge")
    }

    // MARK: - Path-key miss

    @Test("applyDossier returns false for unknown path without mutating other records")
    func unknownPathIsNoOp() {
        let model = VideoScanModel()
        let knownPath = "/Vols/foo/known.mov"
        let known = makeRecord(path: knownPath)
        known.sceneCaptions = [SceneCaption(timestamp: 0.0, text: "untouched")]
        model.records = [known]

        let updated = model.applyDossier(
            DossierExtraction(scenes: [SceneCaption(timestamp: 1.0, text: "stray")], dates: [], texts: []),
            to: "/Vols/foo/ghost-does-not-exist.mov",
            vlmModel: "vlm-x",
            transcript: nil,
            whisperModel: nil
        )

        #expect(updated == false)
        #expect(known.sceneCaptions.first?.text == "untouched")
        #expect(known.dossierProcessedAt == nil)
    }

    // MARK: - Empty record-path / empty model — defensive

    @Test("applyDossier rejects empty path or empty vlmModel")
    func defensiveEmptyInputs() {
        let model = VideoScanModel()
        let rec = makeRecord(path: "/Vols/foo/d.mov")
        model.records = [rec]

        #expect(model.applyDossier(.empty, to: "", vlmModel: "vlm-x", transcript: nil, whisperModel: nil) == false)
        #expect(model.applyDossier(.empty, to: "/Vols/foo/d.mov", vlmModel: "", transcript: nil, whisperModel: nil) == false)
        #expect(rec.dossierProcessedAt == nil, "Defensive guards must NOT touch the record")
    }
}

// MARK: - Path year hints (free function)

@Suite("pfPathYearHints")
struct PathYearHintsTests {

    @Test("4-digit year embedded in a directory component is picked up")
    func yearInDirectory() {
        let hints = pfPathYearHints(in: "/Volumes/MyBook/Christmas2010/clip.mp4")
        #expect(hints == [2010])
    }

    @Test("multiple year-bearing components return deepest-first")
    func multipleComponentsDeepestFirst() {
        let hints = pfPathYearHints(in: "/Volumes/Archive2024/Summer 2010/Holiday1991/clip.mp4")
        // Walk should return [1991, 2010, 2024] — Holiday1991 is the deepest
        // year-bearing component, then "Summer 2010", then "Archive2024".
        #expect(hints.first == 1991)
        #expect(hints.contains(2010))
        #expect(hints.contains(2024))
    }

    @Test("filename-only year is excluded")
    func filenameYearExcluded() {
        // The filename "DSC_2010.MP4" should NOT contribute a year — only
        // directory components do. This avoids picking up serial numbers
        // / sequence numbers that happen to look like years.
        let hints = pfPathYearHints(in: "/Volumes/MyBook/Unsorted/DSC_2010.MP4")
        #expect(hints.isEmpty)
    }

    @Test("non-year four-digit numbers are filtered")
    func nonYearNumbersFiltered() {
        // "5000" is not a valid year.
        let hints = pfPathYearHints(in: "/Volumes/MyBook/Clip5000/file.mp4")
        #expect(hints.isEmpty)
    }

    @Test("empty path returns no hints")
    func emptyPath() {
        let hints = pfPathYearHints(in: "")
        #expect(hints.isEmpty)
    }
}
