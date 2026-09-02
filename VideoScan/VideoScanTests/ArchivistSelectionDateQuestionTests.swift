import Foundation
import Testing
@testable import VideoScan

/// "when was this filmed" with a Catalog row selected is a question about
/// the RECORD's date, not a person's age (Hallie eval 2026-09-01: every
/// phrasing below declined with "I need to know who you mean"). These pin
/// the recogniser (positive and negative) and the precision-aware wording.
@Suite("Family Archivist selection-date questions")
struct ArchivistSelectionDateQuestionTests {
    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(
            timeZone: calendar.timeZone, year: year, month: month, day: day,
            hour: 12))!
    }

    private let recordID = UUID()
    private let path = "/isolated/Christmas1994/Christmas_1994_etc.mkv"
    /// The eval's "today".
    private var now: Date { date(2026, 9, 1) }

    private func resolved(
        _ date: Date, source: RecordDateResolution.Source,
        precision: RecordDateResolution.Precision, confidence: Float = 1.0
    ) -> ArchivistTemporalSelectionDateSnapshot {
        .resolved(recordID: recordID, fullPath: path, date: date,
                  source: source, precision: precision, confidence: confidence)
    }

    // MARK: - Recognition

    @Test(arguments: [
        ("when was this filmed", ArchivistSelectionDateQuestion.when),
        ("When was this filmed?", .when),
        ("when was that taken", .when),
        ("when is this from", .when),
        ("when's this from?", .when),
        ("when was it shot", .when),
        ("when was this video filmed", .when),
        ("Hallie, do you know when this was filmed?", .when),
        ("what date is this", .when),
        ("what month was this filmed", .when),
        ("what year is that from", .year),
        ("what year was this", .year),
        ("which year is this video from?", .year),
        ("what decade is this from", .year),
        ("how old is this tape", .age),
        ("how old is this", .age),
        ("how old is it", .age),
        ("how old is that video anyway?", .age),
        ("how old's the tape", .age),
        ("what season was this filmed in", .season),
        ("what season is it in this video", .season),
        ("what time of year was that", .season),
        ("how long ago was that", .howLongAgo),
        ("how long ago was this filmed", .howLongAgo),
        ("how long ago was the tape made", .howLongAgo),
    ])
    func selectionDatePhrasingsAreRecognised(text: String, expected: ArchivistSelectionDateQuestion) {
        #expect(ArchivistSelectionDateQuestion.detect(text) == expected, "\(text)")
    }

    @Test(arguments: [
        // Person questions keep their existing routes.
        "when was Donna born",
        "when was donna born?",
        "what year was Donna born",
        "how old was Timmy in this",
        "how old was Timmy in this video?",
        "how old is Donna",
        "how old is Donna here",
        "how old is Donna in the video",
        "how old is that boy",
        "how old is the man in the tape",
        "how long ago was Donna born",
        "what season was Donna born in",
        "when were you born",
        "when did Rick and Donna get married",
        // Not date questions at all.
        "play this",
        "who is in this video",
        "what is this",
        "",
    ])
    func personAndOtherQuestionsAreNotSelectionDateQuestions(text: String) {
        #expect(ArchivistSelectionDateQuestion.detect(text) == nil, "\(text)")
    }

    // MARK: - Wording by precision

    @Test func dayPrecisionAnswersEveryAskWithTheFullDate() {
        let selection = resolved(date(1994, 12, 25), source: .embedded, precision: .day, confidence: 0.95)
        let when = ArchivistSelectionDateQuestion.answer(.when, selection: selection, now: now)
        #expect(when.outcome == .answered)
        #expect(when.route == .temporal)
        #expect(when.prose == "This was filmed on 25 December 1994.")
        #expect(when.basisLine.contains("date 1994-12-25 from the camera's embedded date"))
        #expect(when.basisLine.contains("day precision, confidence 0.95"))

        let year = ArchivistSelectionDateQuestion.answer(.year, selection: selection, now: now)
        #expect(year.prose == "This is from 1994 — filmed on 25 December 1994.")

        let season = ArchivistSelectionDateQuestion.answer(.season, selection: selection, now: now)
        #expect(season.prose == "This was filmed in winter, on 25 December 1994.")
        #expect(season.basisLine.contains("northern hemisphere"))

        // 25 Dec 1994 → 1 Sep 2026 is 31 full years, not 32.
        let age = ArchivistSelectionDateQuestion.answer(.age, selection: selection, now: now)
        #expect(age.prose == "About 31 years old — filmed on 25 December 1994.")
        #expect(age.basisLine.contains("Counted to 2026-09-01"))

        let ago = ArchivistSelectionDateQuestion.answer(.howLongAgo, selection: selection, now: now)
        #expect(ago.prose == "About 31 years ago (25 December 1994).")
    }

    @Test func monthPrecisionNamesTheMonthAndSeason() {
        let selection = resolved(date(1994, 12, 1), source: .filename, precision: .month, confidence: 0.5)
        let when = ArchivistSelectionDateQuestion.answer(.when, selection: selection, now: now)
        #expect(when.prose == "This was filmed in December 1994 (from the filename).")
        let season = ArchivistSelectionDateQuestion.answer(.season, selection: selection, now: now)
        #expect(season.prose == "This was filmed in winter, December 1994 (from the filename).")
        let ago = ArchivistSelectionDateQuestion.answer(.howLongAgo, selection: selection, now: now)
        #expect(ago.prose == "About 32 years ago (December 1994, from the filename).")
    }

    @Test func yearPrecisionFromRicksDateIsTheYearAlone() {
        // The real Christmas_1994_etc.mkv: userDate "1994" (known), a 2026
        // transcode stamp. The date Rick entered needs no parenthetical.
        let selection = resolved(date(1994, 1, 1), source: .userDate, precision: .year)
        #expect(ArchivistSelectionDateQuestion.answer(.when, selection: selection, now: now).prose
                == "This was filmed in 1994.")
        #expect(ArchivistSelectionDateQuestion.answer(.year, selection: selection, now: now).prose
                == "This is from 1994.")
        #expect(ArchivistSelectionDateQuestion.answer(.age, selection: selection, now: now).prose
                == "About 32 years old — filmed in 1994.")
        #expect(ArchivistSelectionDateQuestion.answer(.howLongAgo, selection: selection, now: now).prose
                == "About 32 years ago (1994).")
        let season = ArchivistSelectionDateQuestion.answer(.season, selection: selection, now: now)
        #expect(season.outcome == .answered)
        #expect(season.prose.hasPrefix("I only know the year — 1994 — so I can't say the season"))
        let basis = ArchivistSelectionDateQuestion.answer(.when, selection: selection, now: now).basisLine
        #expect(basis.contains("date 1994 from the date Rick entered (year precision, confidence 1.00)"))
    }

    @Test func yearPrecisionFromTheFilenameSaysSo() {
        let selection = resolved(date(1994, 1, 1), source: .filename, precision: .year, confidence: 0.5)
        #expect(ArchivistSelectionDateQuestion.answer(.when, selection: selection, now: now).prose
                == "This was filmed in 1994 (from the filename).")
        #expect(ArchivistSelectionDateQuestion.answer(.year, selection: selection, now: now).prose
                == "This is from 1994 (from the filename).")
    }

    @Test func seasonsAreNorthernHemisphere() {
        #expect(ArchivistSelectionDateQuestion.season(12) == "winter")
        #expect(ArchivistSelectionDateQuestion.season(2) == "winter")
        #expect(ArchivistSelectionDateQuestion.season(3) == "spring")
        #expect(ArchivistSelectionDateQuestion.season(7) == "summer")
        #expect(ArchivistSelectionDateQuestion.season(10) == "fall")
    }

    // MARK: - Honest declines

    @Test func undatedSelectionOffersToSetTheDate() {
        let result = ArchivistSelectionDateQuestion.answer(.when, selection: nil, now: now)
        #expect(result.outcome == .declined)
        #expect(result.prose.contains("I don't have a date for the selected video"))
        #expect(result.prose.contains("Set its date in the Catalog inspector"))
    }

    @Test func transcodeStampIsNeverPresentedAsAFilmingDate() {
        // The legacy fallback for an undated file: the 2026 catalog stamp.
        let stamp = ArchivistTemporalSelectionDateSnapshot.catalogCreation(
            recordID: recordID, fullPath: path, date: date(2026, 7, 14))
        for ask in ArchivistSelectionDateQuestion.allCases {
            let result = ArchivistSelectionDateQuestion.answer(ask, selection: stamp, now: now)
            #expect(result.outcome == .declined, "\(ask)")
            #expect(result.prose.contains("may be when it was copied or transcoded"), "\(ask)")
            #expect(result.prose.contains("14 July 2026"), "\(ask)")
            #expect(!result.prose.contains("filmed on"), "\(ask)")
        }
    }

    @Test func lowConfidenceInferenceIsAnsweredAsAGuess() {
        // Noon-UTC 1 January is the dossier's year-only placeholder: the
        // answer says "in 1994", never "on 1 January 1994".
        let guess = ArchivistTemporalSelectionDateSnapshot.dossierInferred(
            recordID: recordID, fullPath: path, date: date(1994, 1, 1), confidence: 0.5)
        #expect(guess.precision == .year)
        let result = ArchivistSelectionDateQuestion.answer(.when, selection: guess, now: now)
        #expect(result.outcome == .answered)
        #expect(result.prose.hasPrefix("This was filmed in 1994."))
        #expect(result.prose.contains("low-confidence guess"))
        #expect(result.basisLine.contains("low-confidence inference 0.50"))

        // A real day from the dossier keeps day precision.
        let real = ArchivistTemporalSelectionDateSnapshot.dossierInferred(
            recordID: recordID, fullPath: path, date: date(1994, 12, 25), confidence: 0.5)
        #expect(real.precision == .day)
        #expect(ArchivistSelectionDateQuestion.answer(.when, selection: real, now: now).prose
                .hasPrefix("This was filmed on 25 December 1994."))
    }

    // MARK: - Pre-translation lane

    @Test func laneAnswersOnlyWithASelectionAndLeavesPersonAgeAlone() {
        let selected = HallieTurnExecutor.SelectedRecord(
            recordID: recordID,
            date: resolved(date(1994, 1, 1), source: .userDate, precision: .year))
        let memory = HallieTurnExecutor.ConversationMemory()

        // With a selection: answered locally, no translation.
        let answered = HallieTurnExecutor.preTranslation(
            question: "when was this filmed", playAfterAnswer: false,
            memory: memory, isKnownPerson: { _ in false }, selectedRecord: selected)
        guard case .answer(let result) = answered else {
            Issue.record("expected a local answer, got \(answered)")
            return
        }
        #expect(result.prose == "This was filmed in 1994.")

        // Without a selection: the words go to the translator as before.
        let translated = HallieTurnExecutor.preTranslation(
            question: "when was this filmed", playAfterAnswer: false,
            memory: memory, isKnownPerson: { _ in false }, selectedRecord: nil)
        #expect(translated == .translate(question: "when was this filmed", playAfterAnswer: false))

        // A person-age question with a selection keeps the temporal path.
        let personAge = HallieTurnExecutor.preTranslation(
            question: "how old was Timmy in this", playAfterAnswer: false,
            memory: memory, isKnownPerson: { $0 == "timmy" }, selectedRecord: selected)
        #expect(personAge == .translate(question: "how old was Timmy in this", playAfterAnswer: false))

        // A selected but undated record: the honest line, still local.
        let undated = HallieTurnExecutor.preTranslation(
            question: "how old is this tape", playAfterAnswer: false,
            memory: memory, isKnownPerson: { _ in false },
            selectedRecord: .init(recordID: recordID, date: nil))
        guard case .answer(let honest) = undated else {
            Issue.record("expected a local decline, got \(undated)")
            return
        }
        #expect(honest.outcome == .declined)
    }
}
