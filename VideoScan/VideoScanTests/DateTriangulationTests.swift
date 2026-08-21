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

    // MARK: GH #166 — content evidence vs copy-era stamps
    //
    // The Clip 01.dv case (real record, 2026-08-20): OCR burn-in reads
    // "JUN 21 '97" (two-digit year, camcorder OSD apostrophe), the
    // transcript and a scene caption both say 1997 — but the file was
    // copied in 2007 so mtime is 2007-12-06. The old parser required a
    // 4-digit year, so ALL content evidence was dropped and the copy
    // date leaked into inferredRecordDate at 0.30.

    @Test func clip01TwoDigitYearOcrBeatsCopyMtime() {
        let result = pfInferRecordDate(
            ocrDateCandidates: ["JUN 21 '97"],
            audioTranscript: "Here he comes. Hey, Timmy. This is Cape Cod, summer 1997.",
            pathYearHints: [],
            fileMtime: date(2007, 12, 6),
            containerCreationTime: date(2007, 12, 6)
        )
        let cal = Calendar(identifier: .gregorian)
        #expect(cal.component(.year, from: result.date ?? .distantPast) == 1997,
                "Content evidence (OCR '97) must beat the 2007 copy mtime, got \(String(describing: result.date))")
        #expect(result.confidence >= 0.60,
                "A parsed OCR burn-in is content evidence, not an mtime guess — got \(result.confidence)")
    }

    @Test func twoDigitApostropheYearParses() {
        // Camcorder OSD forms seen in the real catalog (ocrText has the
        // stacked "JUN\n21\n'97" shape). Two-digit years REQUIRE the
        // apostrophe; pivot 30 ('30–'99 → 19xx, '00–'29 → 20xx).
        for (raw, y, m, d) in [
            ("JUN 21 '97", 1997, 6, 21),
            ("JUN\n21\n'97", 1997, 6, 21),
            ("JUN. 21 ’97", 1997, 6, 21),     // Unicode right-quote
            ("DEC 25 '07", 2007, 12, 25),
        ] {
            let result = pfInferRecordDate(
                ocrDateCandidates: [raw], audioTranscript: nil,
                pathYearHints: [], fileMtime: nil, containerCreationTime: nil)
            #expect(result.date == date(y, m, d), "Failed to parse \(raw.debugDescription): \(String(describing: result.date))")
        }
        // A bare trailing two-digit number is NOT a year (more likely a
        // truncated "11:30") — pinned so relaxing it is deliberate.
        let bare = pfInferRecordDate(
            ocrDateCandidates: ["JUN 21 11"], audioTranscript: nil,
            pathYearHints: [], fileMtime: nil, containerCreationTime: nil)
        #expect(bare.date == nil)
    }

    @Test func independentChannelCorroborationLiftsSingleOcrHit() {
        // One OCR frame alone is 0.75; the transcript naming the same
        // year makes it "content agreeing with itself" → ≥ 0.90, which
        // clears RecordDateResolver.contentAgreementFloor (0.85) so it
        // can outvote a copy-era container stamp.
        let corroborated = pfInferRecordDate(
            ocrDateCandidates: ["JUN 21 '97"],
            audioTranscript: "Cape Cod, the summer of 1997.",
            pathYearHints: [], fileMtime: date(2007, 12, 6), containerCreationTime: nil)
        #expect(corroborated.date == date(1997, 6, 21))
        #expect(corroborated.confidence >= 0.90)

        let viaCaption = pfInferRecordDate(
            ocrDateCandidates: ["JUN 21 '97"],
            audioTranscript: nil,
            sceneCaptionTexts: ["Two children on a couch; a burned-in date reads 1997."],
            pathYearHints: [], fileMtime: date(2007, 12, 6), containerCreationTime: nil)
        #expect(viaCaption.confidence >= 0.90)

        let uncorroborated = pfInferRecordDate(
            ocrDateCandidates: ["JUN 21 '97"],
            audioTranscript: "no year spoken here",
            pathYearHints: [], fileMtime: date(2007, 12, 6), containerCreationTime: nil)
        #expect(uncorroborated.date == date(1997, 6, 21))
        #expect(abs(uncorroborated.confidence - 0.75) < 0.001,
                "single uncorroborated OCR frame stays below the stamp-outvote tier")
    }

    // MARK: no parseable OCR date — year mentions (GH #166, year precision)

    @Test func mentionAgreementBeatsMtimeButStaysBelowResolverFloor() {
        // Transcript AND caption agree on 1997 → the year (as Jan 1
        // placeholder) at 0.58: shown to Rick instead of the 2007 copy
        // date, but deliberately under the 0.6 floor so the archive
        // never files a fabricated "Jan 1" day.
        let both = pfInferRecordDate(
            ocrDateCandidates: [],
            audioTranscript: "summer 1997 on the Cape",
            sceneCaptionTexts: ["a caption mentioning 1997"],
            pathYearHints: [], fileMtime: date(2007, 12, 6), containerCreationTime: nil)
        let cal = Calendar(identifier: .gregorian)
        #expect(cal.component(.year, from: both.date ?? .distantPast) == 1997)
        #expect(abs(both.confidence - 0.58) < 0.001)

        // One channel, one distinct year → 0.55.
        let single = pfInferRecordDate(
            ocrDateCandidates: [],
            audioTranscript: "that was 1997, remember?",
            sceneCaptionTexts: [],
            pathYearHints: [], fileMtime: date(2007, 12, 6), containerCreationTime: nil)
        #expect(cal.component(.year, from: single.date ?? .distantPast) == 1997)
        #expect(abs(single.confidence - 0.55) < 0.001)

        // Conflicting mentions ("born in 1962 ... this is 1997") are
        // ambiguous → fall through to mtime, NOT a coin flip.
        let ambiguous = pfInferRecordDate(
            ocrDateCandidates: [],
            audioTranscript: "he was born in 1962, and now it's 1997",
            sceneCaptionTexts: [],
            pathYearHints: [], fileMtime: date(2007, 12, 6), containerCreationTime: nil)
        #expect(ambiguous.date == date(2007, 12, 6))
        #expect(abs(ambiguous.confidence - 0.30) < 0.001)

        // Future years are not recording dates (real catalog has a
        // caption reading "2040").
        let future = pfInferRecordDate(
            ocrDateCandidates: [],
            audioTranscript: nil,
            sceneCaptionTexts: ["a screen shows the number 2040"],
            pathYearHints: [], fileMtime: date(2007, 12, 6), containerCreationTime: nil)
        #expect(future.date == date(2007, 12, 6), "2040 must not become the record year")
    }

    // MARK: GH #166 sensor helper — pfContentEvidenceYear

    @Test func contentEvidenceYearExtraction() {
        #expect(pfContentEvidenceYear(ocrDateCandidates: ["JUN 21 '97"], audioTranscript: nil, sceneCaptionTexts: []) == 1997)
        #expect(pfContentEvidenceYear(ocrDateCandidates: ["JUN 21 '97", "JUN 21 1997", "NONE"],
                                      audioTranscript: "1997", sceneCaptionTexts: []) == 1997)
        // No OCR: unanimity required.
        #expect(pfContentEvidenceYear(ocrDateCandidates: [], audioTranscript: "summer 1997",
                                      sceneCaptionTexts: ["caption says 1997"]) == 1997)
        #expect(pfContentEvidenceYear(ocrDateCandidates: [], audioTranscript: "1962 and 1997",
                                      sceneCaptionTexts: []) == nil)
        #expect(pfContentEvidenceYear(ocrDateCandidates: [], audioTranscript: nil, sceneCaptionTexts: []) == nil)
    }

    // MARK: scale — 100k records through the triangulation + sensor core

    @Test(.timeLimit(.minutes(1))) func scaleHundredThousandRecords() {
        let transcripts: [String?] = ["Cape Cod, summer of 1997, with Timmy and Matt.", nil,
                                      "he was born in 1962, and now it's 1997", "no year at all"]
        let captions = [["a beach scene", "a caption mentioning 1997"], [], ["screen shows 2040"]]
        let ocr: [[String]] = [["JUN 21 '97"], [], ["JUN.21 1991", "JUN.21 1991", "JUN.21 1991"], ["NONE"]]
        let start = Date()
        var dated = 0
        for i in 0..<100_000 {
            let r = pfInferRecordDate(
                ocrDateCandidates: ocr[i % ocr.count],
                audioTranscript: transcripts[i % transcripts.count],
                sceneCaptionTexts: captions[i % captions.count],
                pathYearHints: i % 5 == 0 ? [2010] : [],
                fileMtime: date(2007, 12, 6),
                containerCreationTime: nil)
            if r.date != nil { dated += 1 }
            _ = pfContentEvidenceYear(ocrDateCandidates: ocr[i % ocr.count],
                                      audioTranscript: transcripts[i % transcripts.count],
                                      sceneCaptionTexts: captions[i % captions.count])
        }
        let elapsed = Date().timeIntervalSince(start)
        #expect(dated == 100_000, "mtime fallback means every record gets SOME date here")
        #expect(elapsed < 10.0, "100k triangulations + sensor extractions took \(elapsed)s")
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
