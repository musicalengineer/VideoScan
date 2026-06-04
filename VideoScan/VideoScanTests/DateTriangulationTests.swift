import Testing
import Foundation
@testable import VideoScan

// MARK: - pfInferRecordDate
//
// Triangulates a record's true date from independent signals.
// Confidence priors (empirical, tunable):
//   - OCR consensus across ≥3 frames: 0.95
//   - Single OCR hit:                  0.75
//   - Path year hint:                  0.50
//   - File mtime alone:                0.30
//   - Nothing:                         0.0
//
// PROVEN 2026-06-04: Clip 03_converted.mov has mtime 2024-04-20 but OCR
// across 11/15 frames reads "JUN 21 1991". The helper must produce
// 1991-06-21 with high confidence, not 2024.

struct DateTriangulationTests {

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var dc = DateComponents()
        dc.year = y; dc.month = m; dc.day = d; dc.hour = 12
        dc.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: dc) ?? Date.distantPast
    }

    // MARK: OCR cases — the main signal

    @Test func ocrConsensusOverridesFileMtime() {
        // The Clip 03 case: file says 2024, OCR says 1991 across many
        // frames. OCR wins, high confidence.
        let ocr = [
            "JUN.21 1991",
            "PM11:30 JUN.21 1991",
            "JUN.21 1991",
            "JUN.21 1991",
            "P.M. 11 = 30 JUN. 21 1991"
        ]
        let result = pfInferRecordDate(
            ocrDateCandidates: ocr,
            audioTranscript: nil,
            pathYearHints: [],
            fileMtime: date(2024, 4, 20),
            containerCreationTime: nil
        )
        let expected = date(1991, 6, 21)
        #expect(result.date == expected, "Expected 1991-06-21, got \(String(describing: result.date))")
        #expect(result.confidence >= 0.90,
                "Multi-frame consensus should be ≥0.90, got \(result.confidence)")
    }

    @Test func singleOcrHitGivesMediumConfidence() {
        let ocr = ["DEC 25 2010"]
        let result = pfInferRecordDate(
            ocrDateCandidates: ocr,
            audioTranscript: nil,
            pathYearHints: [],
            fileMtime: nil,
            containerCreationTime: nil
        )
        #expect(result.date == date(2010, 12, 25))
        #expect(result.confidence >= 0.65 && result.confidence < 0.90)
    }

    @Test func ocrHandlesVariousMonthFormats() {
        // Real OCR output includes "JUN.21 1991", "JUN. 21 1991",
        // "JUNE 21 1991", "Jun 21, 1991", etc. All should parse.
        for ocrText in ["JUN.21 1991", "JUN. 21 1991", "JUNE 21 1991", "Jun 21 1991"] {
            let result = pfInferRecordDate(
                ocrDateCandidates: [ocrText],
                audioTranscript: nil,
                pathYearHints: [],
                fileMtime: nil,
                containerCreationTime: nil
            )
            #expect(result.date == date(1991, 6, 21),
                    "Failed to parse: \(ocrText), got \(String(describing: result.date))")
        }
    }

    @Test func ocrIgnoresNoiseStrings() {
        // The dossier prompt sometimes returns "NONE" or partial junk;
        // those should be skipped, not crash the consensus.
        let ocr = [
            "JUN.21 1991",
            "NONE",
            "1:55",         // partial time-only, no date
            "JUN.21 1991",
            "JUN.21 1991"
        ]
        let result = pfInferRecordDate(
            ocrDateCandidates: ocr,
            audioTranscript: nil,
            pathYearHints: [],
            fileMtime: nil,
            containerCreationTime: nil
        )
        #expect(result.date == date(1991, 6, 21))
        // Three real hits → consensus
        #expect(result.confidence >= 0.90)
    }

    // MARK: fallback chain — when OCR is absent

    @Test func pathYearHintsFallback() {
        let result = pfInferRecordDate(
            ocrDateCandidates: [],
            audioTranscript: nil,
            pathYearHints: [2010],
            fileMtime: nil,
            containerCreationTime: nil
        )
        // No exact date — but year is known. Pick Jan 1 of that year
        // as the placeholder; confidence reflects the imprecision.
        #expect(result.date != nil)
        let cal = Calendar(identifier: .gregorian)
        let yr = cal.component(.year, from: result.date ?? .distantPast)
        #expect(yr == 2010)
        #expect(result.confidence >= 0.40 && result.confidence <= 0.60)
    }

    @Test func fileMtimeIsLastResortLowConfidence() {
        let mt = date(2024, 4, 20)
        let result = pfInferRecordDate(
            ocrDateCandidates: [],
            audioTranscript: nil,
            pathYearHints: [],
            fileMtime: mt,
            containerCreationTime: nil
        )
        #expect(result.date == mt)
        #expect(result.confidence <= 0.40,
                "File mtime should be low-confidence (we know it's often wrong)")
    }

    @Test func noSignalsReturnsNil() {
        let result = pfInferRecordDate(
            ocrDateCandidates: [],
            audioTranscript: nil,
            pathYearHints: [],
            fileMtime: nil,
            containerCreationTime: nil
        )
        #expect(result.date == nil)
        #expect(result.confidence == 0.0)
    }

    // MARK: realistic mixed case

    @Test func ocrBeatsPathYearWhenBothPresent() {
        // Real common scenario: file is in a folder named "Christmas2010"
        // but the OCR burn-in reads "DEC 25 2011" (different year).
        // OCR should win.
        let result = pfInferRecordDate(
            ocrDateCandidates: ["DEC 25 2011", "DEC 25 2011"],
            audioTranscript: nil,
            pathYearHints: [2010],
            fileMtime: nil,
            containerCreationTime: nil
        )
        let cal = Calendar(identifier: .gregorian)
        #expect(cal.component(.year, from: result.date ?? .distantPast) == 2011)
    }
}
