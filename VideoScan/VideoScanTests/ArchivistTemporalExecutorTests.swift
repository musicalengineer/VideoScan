import Foundation
import Testing
@testable import VideoScan

@MainActor
@Suite("Family Archivist deterministic temporal executor", .serialized)
struct ArchivistTemporalExecutorTests {
    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(
            timeZone: calendar.timeZone, year: year, month: month, day: day,
            hour: 12))!
    }

    private func subject(
        birthdate: Date? = nil,
        id: String = "timmy",
        name: String = "Timmy"
    ) -> ArchivistTemporalSubjectResolution {
        .resolved(
            requested: "Timmy",
            subject: ArchivistTemporalSubjectSnapshot(
                stableID: id, canonicalName: name, birthdate: birthdate))
    }

    private func query(
        _ reference: ArchivistQueryAST.Temporal.Reference
    ) -> ArchivistQueryAST.Temporal {
        .init(subject: "Timmy", operation: .age, reference: reference)
    }

    @Test func currentSelectionComputesCompletedCalendarYears() {
        let recordID = UUID()
        let result = ArchivistTemporalExecutor.execute(
            query(.currentSelection),
            subject: subject(birthdate: date(2000, 8, 4)),
            currentSelection: .dossierInferred(
                recordID: recordID, fullPath: "/Archive/2020-08-03.mov",
                date: date(2020, 8, 3), confidence: 0.95))

        #expect(result.value == .exactAge(19))
        #expect(result.decline == nil)
        #expect(result.prose
                == "Using the selected record's inferred date 2020-08-03, "
                    + "Timmy's calculated age is 19 years "
                    + "(inference confidence 0.95).")
        #expect(result.basisLine.contains("dossier inferred date"))
        #expect(result.basisLine.contains("confidence 0.95"))
        #expect(result.evidence?.subjectID == "timmy")
    }

    @Test func exactAgeAdvancesOnBirthday() {
        let result = ArchivistTemporalExecutor.execute(
            query(.currentSelection),
            subject: subject(birthdate: date(2000, 8, 4)),
            currentSelection: .dossierInferred(
                recordID: UUID(), fullPath: "/Archive/birthday.mov",
                date: date(2020, 8, 4), confidence: nil))

        #expect(result.value == .exactAge(20))
    }

    @Test func explicitYearReturnsHonestRangeWithoutInventedMonthDay() {
        let result = ArchivistTemporalExecutor.execute(
            query(.explicitYear(2020)),
            subject: subject(birthdate: date(2000, 8, 4)),
            currentSelection: nil)

        #expect(result.value == .ageRange(19...20))
        #expect(result.prose
                == "Timmy was 19\u{2013}20 years old during 2020, depending on the date.")
        #expect(result.basisLine.contains("without a month/day"))
        #expect(result.evidence?.reference == .explicitYear(2020))
    }

    @Test func birthYearUsesYearBasedWording() {
        let result = ArchivistTemporalExecutor.execute(
            query(.explicitYear(2000)),
            subject: subject(birthdate: date(2000, 8, 4)),
            currentSelection: nil)

        #expect(result.value == .ageRange(0...0))
        #expect(result.prose
                == "Timmy was 0 years old during the part of 2000 after their birth.")
    }

    @Test func januaryFirstBirthHasExactAgeThroughoutCalendarYear() {
        let laterYear = ArchivistTemporalExecutor.execute(
            query(.explicitYear(2020)),
            subject: subject(birthdate: date(2000, 1, 1)),
            currentSelection: nil)
        #expect(laterYear.value == .ageRange(20...20))
        #expect(laterYear.prose
                == "Timmy was 20 years old throughout 2020 by calendar-date precision.")

        let birthYear = ArchivistTemporalExecutor.execute(
            query(.explicitYear(2000)),
            subject: subject(birthdate: date(2000, 1, 1)),
            currentSelection: nil)
        #expect(birthYear.value == .ageRange(0...0))
        #expect(birthYear.prose
                == "Timmy was 0 years old throughout 2000 by calendar-date precision.")
    }

    @Test func missingAndAmbiguousSubjectsFailClosed() {
        let missing = ArchivistTemporalExecutor.execute(
            query(.explicitYear(2020)),
            subject: .missing(requested: "Timmy"), currentSelection: nil)
        #expect(missing.decline == .missingSubject)
        #expect(missing.evidence == nil)
        #expect(missing.prose
                .hasPrefix("I need to know who you mean — and which video."))

        let candidates = [
            ArchivistTemporalSubjectResolution.Candidate(
                stableID: "tim", canonicalName: "Tim"),
            ArchivistTemporalSubjectResolution.Candidate(
                stableID: "timmy", canonicalName: "Timmy"),
        ]
        let ambiguous = ArchivistTemporalExecutor.execute(
            query(.explicitYear(2020)),
            subject: .ambiguous(requested: "Timmy", candidates: candidates),
            currentSelection: nil)
        #expect(ambiguous.decline == .ambiguousSubject(candidates))
        #expect(ambiguous.basisLine.contains("Tim, Timmy"))
    }

    @Test func missingBirthdateAndReferenceFailClosed() {
        let noBirthdate = ArchivistTemporalExecutor.execute(
            query(.explicitYear(2020)), subject: subject(),
            currentSelection: nil)
        #expect(noBirthdate.decline == .missingBirthdate)
        #expect(noBirthdate.prose == "I don't have a birthdate for Timmy.")

        let noReference = ArchivistTemporalExecutor.execute(
            query(.currentSelection),
            subject: subject(birthdate: date(2000, 8, 4)),
            currentSelection: nil)
        #expect(noReference.decline == .missingReference)
    }

    @Test func beforeBirthAndInvalidInputsFailClosed() {
        let beforeBirth = ArchivistTemporalExecutor.execute(
            query(.explicitYear(1999)),
            subject: subject(birthdate: date(2000, 8, 4)),
            currentSelection: nil)
        #expect(beforeBirth.decline == .referenceBeforeBirth)

        let selectedBeforeBirth = ArchivistTemporalExecutor.execute(
            query(.currentSelection),
            subject: subject(birthdate: date(2000, 8, 4)),
            currentSelection: .dossierInferred(
                recordID: UUID(), fullPath: "/Archive/too-early.mov",
                date: date(2000, 8, 3), confidence: 0.9))
        #expect(selectedBeforeBirth.decline == .referenceBeforeBirth)

        let invalidBirthdate = ArchivistTemporalExecutor.execute(
            query(.explicitYear(2020)),
            subject: subject(birthdate: Date(timeIntervalSinceReferenceDate: .infinity)),
            currentSelection: nil)
        #expect(invalidBirthdate.decline == .invalidDate)

        let invalidReference = ArchivistTemporalExecutor.execute(
            query(.currentSelection),
            subject: subject(birthdate: date(2000, 8, 4)),
            currentSelection: .catalogCreation(
                recordID: UUID(), fullPath: "/Archive/bad.mov",
                date: Date(timeIntervalSinceReferenceDate: .nan)))
        #expect(invalidReference.decline == .invalidDate)

        let invalidYear = ArchivistTemporalExecutor.execute(
            query(.explicitYear(2200)),
            subject: subject(birthdate: date(2000, 8, 4)),
            currentSelection: nil)
        #expect(invalidYear.decline == .invalidReferenceYear)
    }

    @Test func mismatchedResolverResultCannotCrossWireEvidence() {
        let result = ArchivistTemporalExecutor.execute(
            query(.explicitYear(2020)),
            subject: .resolved(
                requested: "Donna",
                subject: ArchivistTemporalSubjectSnapshot(
                    stableID: "donna", canonicalName: "Donna",
                    birthdate: date(1960, 1, 1))),
            currentSelection: nil)

        #expect(result.decline == .resolutionMismatch)
        #expect(result.evidence == nil)
    }

    /// Production sensor: real POIProfile and VideoRecord fields produce the
    /// same immutable values used by the pure executor. A confident dossier
    /// inference is a RecordDateResolver source (2026-09-01), so it arrives
    /// as `.resolved(source: .inferred)` with its confidence intact.
    @Test func productionSnapshotsPreferDossierDateAndRetainProvenance() throws {
        let profile = POIProfile(
            name: "Timmy", referencePath: "/People/Timmy",
            birthdate: date(2000, 8, 4))
        let record = VideoRecord()
        record.fullPath = "/Archive/event.mov"
        record.inferredRecordDate = date(2020, 8, 4)
        record.inferredDateConfidence = 0.85
        record.dateCreatedRaw = date(2024, 1, 1)
        record.dateModifiedRaw = date(2025, 1, 1)

        let subjectSnapshot = ArchivistTemporalSubjectSnapshot(profile: profile)
        let referenceSnapshot = try #require(
            ArchivistTemporalSelectionDateSnapshot.capture(record: record))
        let result = ArchivistTemporalExecutor.execute(
            query(.currentSelection),
            subject: .resolved(requested: "Timmy", subject: subjectSnapshot),
            currentSelection: referenceSnapshot)

        #expect(result.value == .exactAge(20))
        #expect(result.prose.contains("date 2020-08-04 (the dossier's inferred date)"))
        #expect(result.basisLine.contains("from inferred (day precision, confidence 0.85"))
        #expect(result.evidence?.subjectID == profile.id)
        guard case .currentSelection(.resolved(
            let recordID, let path, let selectedDate, let source, let precision, let confidence))
            = result.evidence?.reference else {
            Issue.record("expected resolved (inferred) production provenance")
            return
        }
        #expect(recordID == record.id)
        #expect(path == record.fullPath)
        #expect(selectedDate == date(2020, 8, 4))
        #expect(source == .inferred)
        #expect(precision == .day)
        #expect(confidence == 0.85)
    }

    /// The bug (eval 2026-09-01): Christmas_1994_etc.mkv carries Rick's
    /// userDate "1994" and a 2026-07-14 catalog stamp from the transcode.
    /// The old capture skipped the user date and answered "Donna is 66".
    /// The app snapshot now resolves through RecordDateResolver first.
    @Test func appSnapshotResolvesRicksYearAheadOfTheTranscodeStamp() throws {
        let record = VideoRecord()
        record.fullPath = "/Volumes/MediaExpansion/Converted_VHS_Tapes_2026/Christmas1994/Christmas_1994_etc.mkv"
        record.filename = "Christmas_1994_etc.mkv"
        record.userDate = "1994"
        record.userDateConfidence = UserDateConfidence.known.rawValue
        record.dateCreatedRaw = date(2026, 7, 14)
        record.dateModifiedRaw = date(2026, 7, 15)

        let snapshot = try #require(
            ArchivistTemporalSelectionDateSnapshot.capture(record: record))
        guard case .resolved(let id, let path, let selectedDate, let source, let precision, let confidence)
            = snapshot else {
            Issue.record("expected a resolver-backed snapshot, got \(snapshot)")
            return
        }
        #expect(id == record.id)
        #expect(path == record.fullPath)
        #expect(selectedDate == date(1994, 1, 1))
        #expect(source == .userDate)
        #expect(precision == .year)
        #expect(confidence == 1.0)

        // Donna-shaped subject: born mid-1959 → 34–35 during 1994, never 66.
        let result = ArchivistTemporalExecutor.execute(
            query(.currentSelection),
            subject: subject(birthdate: date(1959, 6, 15), id: "donna", name: "Donna"),
            currentSelection: snapshot)
        #expect(result.value == .ageRange(34...35))
        #expect(result.prose.contains("34\u{2013}35 years old during 1994"))
        #expect(result.prose.contains("dated to the year only (from the date Rick entered)"))
        #expect(result.basisLine.contains("date 1994 from userDate (year precision, confidence 1.00"))
        #expect(!result.prose.contains("66"))
    }

    /// Same record shape, no user date: the year in the FILENAME still beats
    /// the transcode stamp, at year precision and filename confidence.
    @Test func appSnapshotFallsBackToTheFilenameYearBeforeAnyStamp() throws {
        let record = VideoRecord()
        record.fullPath = "/isolated/Christmas1994/Christmas_1994_etc.mkv"
        record.filename = "Christmas_1994_etc.mkv"
        record.dateCreatedRaw = date(2026, 7, 14)

        let snapshot = try #require(
            ArchivistTemporalSelectionDateSnapshot.capture(record: record))
        guard case .resolved(_, _, let selectedDate, let source, let precision, let confidence)
            = snapshot else {
            Issue.record("expected a resolver-backed snapshot, got \(snapshot)")
            return
        }
        #expect(selectedDate == date(1994, 1, 1))
        #expect(source == .filename)
        #expect(precision == .year)
        #expect(confidence == RecordDateResolver.filenameConfidence)
    }

    /// An embedded camera stamp gives day precision and an exact age.
    @Test func appSnapshotUsesTheEmbeddedCameraDateAtDayPrecision() throws {
        let record = VideoRecord()
        record.fullPath = "/isolated/tape.mov"
        record.filename = "tape.mov"
        record.embeddedCreationDate = date(1994, 12, 25)
        record.originMake = "Sony"
        record.dateCreatedRaw = date(2026, 7, 14)

        let snapshot = try #require(
            ArchivistTemporalSelectionDateSnapshot.capture(record: record))
        #expect(snapshot.precision == .day)
        #expect(snapshot.sourceLabel == "the camera's embedded date")
        let result = ArchivistTemporalExecutor.execute(
            query(.currentSelection),
            subject: subject(birthdate: date(1959, 6, 15), id: "donna", name: "Donna"),
            currentSelection: snapshot)
        #expect(result.value == .exactAge(35))
        #expect(result.prose == "Using the selected record's date 1994-12-25 (the camera's embedded date), Donna's calculated age is 35 years.")
    }

    /// The shell and the app must capture the SAME snapshot for a record.
    @Test func shellAndAppCapturePathsAgree() {
        let record = VideoRecord()
        record.fullPath = "/isolated/Christmas1994/Christmas_1994_etc.mkv"
        record.filename = "Christmas_1994_etc.mkv"
        record.userDate = "1994"
        record.userDateConfidence = UserDateConfidence.known.rawValue
        record.dateCreatedRaw = date(2026, 7, 14)
        #expect(HallieShellCLI.temporalSelectionDate(record)
                == ArchivistTemporalSelectionDateSnapshot.capture(record: record))

        let undated = VideoRecord()
        undated.fullPath = "/isolated/tape.mov"
        undated.filename = "tape.mov"
        undated.dateCreatedRaw = date(2026, 7, 14)
        #expect(HallieShellCLI.temporalSelectionDate(undated)
                == ArchivistTemporalSelectionDateSnapshot.capture(record: undated))
        #expect(HallieShellCLI.temporalSelectionDate(undated)?.isUnverifiedFallback == true)
    }

    /// A dossier inference UNDER the resolver's floor (0.6) is not a
    /// resolver source; the legacy chain still surfaces it, labelled.
    @Test func lowConfidenceInferenceStaysOnTheLegacyChain() throws {
        let record = VideoRecord()
        record.fullPath = "/isolated/tape.mov"
        record.filename = "tape.mov"
        record.inferredRecordDate = date(1994, 1, 1)
        record.inferredDateConfidence = 0.5
        record.dateCreatedRaw = date(2026, 7, 14)
        let snapshot = try #require(
            ArchivistTemporalSelectionDateSnapshot.capture(record: record))
        guard case .dossierInferred(_, _, let selectedDate, let confidence) = snapshot else {
            Issue.record("expected the legacy dossierInferred case, got \(snapshot)")
            return
        }
        #expect(selectedDate == date(1994, 1, 1))
        #expect(confidence == 0.5)
    }

    @Test func catalogFallbackIsExplicitlyLabeledAsPotentialIngestDate() throws {
        let record = VideoRecord()
        record.fullPath = "/Archive/transcoded.mov"
        record.dateCreatedRaw = date(2024, 1, 1)
        record.dateModifiedRaw = date(2025, 1, 1)

        let reference = try #require(
            ArchivistTemporalSelectionDateSnapshot.capture(record: record))
        let result = ArchivistTemporalExecutor.execute(
            query(.currentSelection),
            subject: subject(birthdate: date(2000, 8, 4)),
            currentSelection: reference)

        #expect(result.value == .exactAge(23))
        #expect(result.prose.contains("as a fallback"))
        #expect(result.prose.contains("not verified recording-age evidence"))
        #expect(result.basisLine.contains("catalog creation date"))
        #expect(result.basisLine.contains("may reflect ingest/transcode"))
    }

    @Test func fileModificationFallbackNeverMasqueradesAsFamilyEventDate() throws {
        let record = VideoRecord()
        record.fullPath = "/Archive/old-tape-transcoded.mov"
        record.dateModifiedRaw = date(2025, 1, 1)

        let reference = try #require(
            ArchivistTemporalSelectionDateSnapshot.capture(record: record))
        let result = ArchivistTemporalExecutor.execute(
            query(.currentSelection),
            subject: subject(birthdate: date(2000, 8, 4)),
            currentSelection: reference)

        #expect(result.value == .exactAge(24))
        #expect(result.prose.contains("as a fallback"))
        #expect(result.prose.contains("not verified recording-age evidence"))
        #expect(result.basisLine.contains("file modification date"))
        #expect(result.basisLine.contains("may reflect ingest/transcode"))
    }


    // MARK: - Present tense: "how old is Donna" with nothing selected (ft022)

    private func resolved(
        _ name: String, birthdate: Date?, deathdate: Date? = nil
    ) -> ArchivistTemporalSubjectResolution {
        .resolved(
            requested: name,
            subject: ArchivistTemporalSubjectSnapshot(
                stableID: name.lowercased(), canonicalName: name,
                birthdate: birthdate, deathdate: deathdate))
    }

    private func ageQuery(_ name: String) -> ArchivistQueryAST.Temporal {
        .init(subject: name, operation: .age, reference: .currentSelection)
    }

    @Test(arguments: [
        "how old is Donna", "How old is Donna?", "what age is Rick",
        "how old is Matt now", "how old is donna today", "what is Donna's age now",
        "how old's Timmy",
    ])
    func presentTenseAgeIsRecognised(text: String) {
        #expect(ArchivistTemporalExecutor.isPresentTenseAge(text), Comment(rawValue: text))
    }

    @Test(arguments: [
        "how old was Donna", "how old was Donna in 1995?", "how old is Donna here",
        "how old is Donna in this video", "how old is Timmy in the clip",
        "what age was Rick", "how old were the boys", "how old is that",
        "show me Donna", "when was Donna born",
    ])
    func pastTenseAndSelectionPointersAreNotPresentTense(text: String) {
        #expect(!ArchivistTemporalExecutor.isPresentTenseAge(text), Comment(rawValue: text))
    }

    @Test func presentAgeCountsFromTheProfileBirthdateToToday() {
        let result = ArchivistTemporalExecutor.executePresentAge(
            ageQuery("Donna"),
            subject: resolved("Donna", birthdate: date(1959, 8, 4)),
            now: date(2026, 9, 1))
        #expect(result.value == .exactAge(67))
        #expect(result.decline == nil)
        #expect(result.prose == "Donna is 67 today — born 4 August 1959.")
        #expect(result.basisLine == "Basis: from Donna's People profile birthdate 1959-08-04, "
                + "counted to today (2026-09-01); no video selected.")
        #expect(result.evidence?.reference == .today(date(2026, 9, 1)))

        // The day before the birthday is still the previous age.
        let eve = ArchivistTemporalExecutor.executePresentAge(
            ageQuery("Donna"),
            subject: resolved("Donna", birthdate: date(1959, 8, 4)),
            now: date(2026, 8, 3))
        #expect(eve.value == .exactAge(66))
    }

    @Test func someoneWhoHasPassedOnGetsTheirAgeAtDeathNotAnAgeToday() {
        let result = ArchivistTemporalExecutor.executePresentAge(
            ageQuery("Dad"),
            subject: resolved("Dad", birthdate: date(1936, 5, 10), deathdate: date(2011, 2, 1)),
            now: date(2026, 9, 1))
        #expect(result.value == .exactAge(74))
        #expect(result.prose == "Dad passed on in 2011 at 74.")
        #expect(result.basisLine.contains("recorded death 2011-02-01"))
        #expect(!result.prose.contains("today"))
        #expect(result.evidence?.reference == .death(date(2011, 2, 1)))
    }

    @Test func aTreeBirthYearAloneGivesAnApproximateAgeAndSaysSo() {
        let result = ArchivistTemporalExecutor.executePresentAge(
            ageQuery("Nana"),
            subject: resolved("Nana", birthdate: nil),
            approximateBirthYear: .init(year: 1936, source: "the family tree"),
            now: date(2026, 9, 1))
        #expect(result.value == .approximateAge(90))
        #expect(result.prose == "Nana is about 90 — the family tree gives only the birth year, 1936.")
        #expect(result.basisLine.contains("birth year 1936 from the family tree"))
        #expect(result.evidence == nil)
    }

    @Test func presentAgeStillFailsClosedWithoutAnyBirthEvidence() {
        let noBirth = ArchivistTemporalExecutor.executePresentAge(
            ageQuery("Nana"), subject: resolved("Nana", birthdate: nil), now: date(2026, 9, 1))
        #expect(noBirth.decline == .missingBirthdate)
        #expect(noBirth.prose == "I don't have a birthdate for Nana.")

        let missing = ArchivistTemporalExecutor.executePresentAge(
            ageQuery("Nobody"), subject: .missing(requested: "Nobody"), now: date(2026, 9, 1))
        #expect(missing.decline == .missingSubject)

        let crossWired = ArchivistTemporalExecutor.executePresentAge(
            ageQuery("Donna"), subject: resolved("Rick", birthdate: date(1958, 1, 1)),
            now: date(2026, 9, 1))
        #expect(crossWired.decline == .resolutionMismatch)
    }

    @Test func turnExecutorAnswersTodayOnlyForPresentTenseWithNothingSelected() async throws {
        let context = HallieTurnExecutor.Context(
            presenceRecords: [],
            profiles: [.init(stableID: "donna", canonicalName: "Donna", birthdate: date(1959, 8, 4))])
        let now = ArchivistTemporalExecutor.executePresentAge(
            ageQuery("Donna"), subject: resolved("Donna", birthdate: date(1959, 8, 4)))
        guard case .exactAge(let expected)? = now.value else {
            Issue.record("fixture should compute an age"); return
        }

        let present = try await HallieTurnExecutor.execute(
            .init(intent: .init(originalQuestion: "how old is Donna", ast: .temporal(ageQuery("Donna")))),
            context: context)
        #expect(present.route == .temporal)
        #expect(present.outcome == .answered)
        #expect(present.prose == "Donna is \(expected) today — born 4 August 1959.", Comment(rawValue: present.prose))
        #expect(present.basisLine.contains("People profile birthdate 1959-08-04"))

        // Past tense with nothing selected keeps today's honest ask.
        let past = try await HallieTurnExecutor.execute(
            .init(intent: .init(originalQuestion: "how old was Donna", ast: .temporal(ageQuery("Donna")))),
            context: context)
        #expect(past.outcome == .declined)
        #expect(past.prose.hasPrefix("I need a dated video to count from"))

        // A selection wins even for present-tense wording ("how old is Donna here").
        let selected = HallieTurnExecutor.Context(
            presenceRecords: [],
            profiles: [.init(stableID: "donna", canonicalName: "Donna", birthdate: date(1959, 8, 4))],
            selectedTemporalDate: .dossierInferred(
                recordID: UUID(), fullPath: "/Archive/1994.mkv", date: date(1994, 12, 25), confidence: 0.9))
        let here = try await HallieTurnExecutor.execute(
            .init(intent: .init(originalQuestion: "how old is Donna here", ast: .temporal(ageQuery("Donna")))),
            context: selected)
        #expect(here.outcome == .answered)
        #expect(here.prose.contains("calculated age is 35 years"), Comment(rawValue: here.prose))
    }

    // MARK: - Several people, born-yet, would-have-been (2026-09-02)

    private func boy(_ name: String, _ y: Int, _ m: Int, _ d: Int) -> ArchivistTemporalSubjectSnapshot {
        .init(stableID: name.lowercased(), canonicalName: name, birthdate: date(y, m, d), sex: .male)
    }

    private var theBoys: [ArchivistTemporalSubjectSnapshot] {
        [boy("Dan", 1984, 6, 1), boy("Mark", 1986, 11, 15), boy("Matt", 1996, 5, 10), boy("Timmy", 1999, 4, 22)]
    }

    private var christmas1994: ArchivistTemporalSelectionDateSnapshot {
        .resolved(recordID: UUID(), fullPath: "/Archive/Christmas_1994_etc.mkv",
                  date: date(1994, 1, 1), source: .userDate, precision: .year, confidence: 0.9)
    }

    @Test func theQuestionsWordingDecidesTheAsk() {
        #expect(ArchivistTemporalExecutor.detectAsk(in: "were the boys born yet when this was shot") == .bornYet)
        #expect(ArchivistTemporalExecutor.detectAsk(in: "had the boys been born when this was shot?") == .bornYet)
        #expect(ArchivistTemporalExecutor.detectAsk(in: "was Timmy already born here") == .bornYet)
        #expect(ArchivistTemporalExecutor.detectAsk(in: "how old would my dad have been in this video") == .wouldHaveBeen)
        #expect(ArchivistTemporalExecutor.detectAsk(in: "how old would Dad be here") == .wouldHaveBeen)
        #expect(ArchivistTemporalExecutor.detectAsk(in: "how old were the boys then") == .age)
        #expect(ArchivistTemporalExecutor.detectAsk(in: "how old was Mark when this was taken") == .age)
    }

    @Test func agesOfSeveralPeopleAgainstAYearOnlyRecordAreOneAnswer() {
        let result = ArchivistTemporalExecutor.executeGroup(
            subjects: theBoys, phrase: "'the boys'", ask: .age, reference: .selection(christmas1994))
        #expect(result.value == .group(answered: 4, of: 4))
        #expect(result.prose == "In 1994 Dan was 9 or 10 and Mark 7 or 8. Matt and Timmy weren't born yet (Matt was born in 1996, Timmy in 1999).", Comment(rawValue: result.prose))
        #expect(result.basisLine.hasPrefix("Basis: People profile birthdates Dan 1984-06-01, Mark 1986-11-15"))
        #expect(result.basisLine.contains("selected record date 1994 from userDate (year precision"))
    }

    @Test func agesAtDayPrecisionAndAnExplicitYearKeepTheSinglePersonArithmetic() {
        let day = ArchivistTemporalSelectionDateSnapshot.resolved(
            recordID: UUID(), fullPath: "/Archive/xmas.mov", date: date(1994, 12, 25),
            source: .embedded, precision: .day, confidence: 0.95)
        let onTheDay = ArchivistTemporalExecutor.executeGroup(
            subjects: Array(theBoys.prefix(2)), phrase: "'the boys'", ask: .age, reference: .selection(day))
        #expect(onTheDay.prose == "On 25 December 1994 Dan was 10 and Mark 8.", Comment(rawValue: onTheDay.prose))

        let year = ArchivistTemporalExecutor.executeGroup(
            subjects: Array(theBoys.prefix(2)), phrase: "'the boys'", ask: .age, reference: .explicitYear(2000))
        #expect(year.prose == "In 2000 Dan was 15 or 16 and Mark 13 or 14.", Comment(rawValue: year.prose))
    }

    @Test func bornYetIsAYesNoPerPerson() {
        let mixed = ArchivistTemporalExecutor.executeGroup(
            subjects: theBoys, phrase: "the boys", ask: .bornYet, reference: .selection(christmas1994))
        #expect(mixed.value == .group(answered: 4, of: 4))
        #expect(mixed.prose == "Dan and Mark were born by 1994; Matt and Timmy were not (Matt was born in 1996, Timmy in 1999).", Comment(rawValue: mixed.prose))

        let all = ArchivistTemporalExecutor.executeGroup(
            subjects: theBoys, phrase: "the boys", ask: .bornYet, reference: .explicitYear(2005))
        #expect(all.prose == "Yes — all four of them (Dan, Mark, Matt and Timmy) were born by 2005.", Comment(rawValue: all.prose))

        let none = ArchivistTemporalExecutor.executeGroup(
            subjects: theBoys, phrase: "the boys", ask: .bornYet, reference: .explicitYear(1980))
        #expect(none.prose == "No — none of the boys were born yet (Dan was born in 1984, Mark in 1986, Matt in 1996, Timmy in 1999).", Comment(rawValue: none.prose))

        // Born during the record's own year: honest about the month.
        let sameYear = ArchivistTemporalExecutor.executeGroup(
            subjects: [boy("Dan", 1984, 6, 1), boy("Baby", 1994, 3, 3)], phrase: "the boys",
            ask: .bornYet, reference: .selection(christmas1994))
        #expect(sameYear.prose == "Dan was born by 1994. Baby was born during 1994 itself, so it depends on the month — the record is dated to the year only.", Comment(rawValue: sameYear.prose))

        // Day precision compares real dates.
        let day = ArchivistTemporalSelectionDateSnapshot.resolved(
            recordID: UUID(), fullPath: "/Archive/xmas.mov", date: date(1996, 5, 9),
            source: .embedded, precision: .day, confidence: 0.95)
        let eve = ArchivistTemporalExecutor.executeGroup(
            subjects: [boy("Matt", 1996, 5, 10)], phrase: "Matt", ask: .bornYet, reference: .selection(day))
        #expect(eve.prose == "No — Matt wasn't born yet (born 1996).", Comment(rawValue: eve.prose))
    }

    @Test func someoneWhoHadPassedOnGetsAWouldHaveBeenWithTheDeathYear() {
        let dad = ArchivistTemporalSubjectSnapshot(
            stableID: "dad", canonicalName: "Dad", birthdate: date(1936, 5, 10),
            deathdate: date(1977, 6, 25), sex: .male)
        let result = ArchivistTemporalExecutor.executeGroup(
            subjects: [dad], phrase: "'my dad'", ask: .wouldHaveBeen, reference: .selection(christmas1994))
        #expect(result.value == .group(answered: 1, of: 1))
        #expect(result.prose == "Dad would have been 57 or 58 in 1994 — he passed on in 1977.", Comment(rawValue: result.prose))
        #expect(result.basisLine.contains("Dad 1936-05-10 (died 1977-06-25)"))

        // Alive at the record: a would-have-been is just his age.
        let alive = ArchivistTemporalExecutor.executeGroup(
            subjects: [dad], phrase: "'my dad'", ask: .wouldHaveBeen, reference: .explicitYear(1970))
        #expect(alive.prose == "In 1970 Dad would have been 33 or 34.", Comment(rawValue: alive.prose))

        // A plain "how old was" after his death is still honest about it.
        let plain = ArchivistTemporalExecutor.executeGroup(
            subjects: [dad], phrase: "'my dad'", ask: .age, reference: .explicitYear(1994))
        #expect(plain.prose == "Dad would have been 57 or 58 in 1994 — he passed on in 1977.", Comment(rawValue: plain.prose))
    }

    @Test func aMissingBirthdateInTheGroupIsSaidNotGuessed() {
        let nana = ArchivistTemporalSubjectSnapshot(stableID: "nana", canonicalName: "Nana", birthdate: nil)
        let result = ArchivistTemporalExecutor.executeGroup(
            subjects: [boy("Dan", 1984, 6, 1), nana], phrase: "'the kids'", ask: .age, reference: .selection(christmas1994))
        #expect(result.value == .group(answered: 1, of: 2))
        #expect(result.prose == "In 1994 Dan was 9 or 10. I don't have a birthdate for Nana.", Comment(rawValue: result.prose))

        let nobody = ArchivistTemporalExecutor.executeGroup(
            subjects: [nana], phrase: "'the kids'", ask: .bornYet, reference: .selection(christmas1994))
        #expect(nobody.value == nil)
        #expect(nobody.decline == .missingBirthdate)
    }

    /// The turn executor: "the boys" = the household's children from the
    /// People-tab relationships (Rick's card and Donna's card), "my dad" =
    /// Rick's father — never the model, never a bare name lookup.
    @Test func turnExecutorResolvesTheBoysAndMyDadThroughThePeopleTab() async throws {
        let profiles: [HallieTurnExecutor.ProfileSnapshot] = [
            .init(stableID: "rick", canonicalName: "Rick", birthdate: date(1958, 3, 1),
                  kinships: [
                      .init(relation: .spouse, relativeTo: .profile(name: "Donna")),
                      .init(relation: .parent, relativeTo: .profile(name: "Dan")),
                      .init(relation: .parent, relativeTo: .profile(name: "Mark")),
                      .init(relation: .child, relativeTo: .profile(name: "Dad")),
                  ], sex: .male),
            .init(stableID: "donna", canonicalName: "Donna", birthdate: date(1959, 8, 4),
                  kinships: [
                      .init(relation: .parent, relativeTo: .profile(name: "Matt")),
                      .init(relation: .parent, relativeTo: .profile(name: "Timmy")),
                  ], sex: .female),
            .init(stableID: "dan", canonicalName: "Dan", birthdate: date(1984, 6, 1), sex: .male),
            .init(stableID: "mark", canonicalName: "Mark", birthdate: date(1986, 11, 15), sex: .male),
            .init(stableID: "matt", canonicalName: "Matt", birthdate: date(1996, 5, 10), sex: .male),
            .init(stableID: "timmy", canonicalName: "Timmy", birthdate: date(1999, 4, 22), sex: .male),
            .init(stableID: "dad", canonicalName: "Dad", aliases: ["Dad Breen"], birthdate: date(1936, 5, 10),
                  sex: .male, deathdate: date(1977, 6, 25)),
        ]
        let context = HallieTurnExecutor.Context(
            profiles: profiles, selectedTemporalDate: christmas1994,
            speakers: .init(ownerName: "Rick Breen", archivistName: "Hallie"))
        func ask(_ question: String, subject: String) async throws -> HallieTurnExecutor.Result {
            try await HallieTurnExecutor.execute(
                .init(intent: .init(originalQuestion: question, ast: .temporal(
                    .init(subject: subject, operation: .age, reference: .currentSelection)))),
                context: context)
        }

        let bornYet = try await ask("were the boys born yet when this was shot", subject: "the boys")
        #expect(bornYet.route == .temporal)
        #expect(bornYet.outcome == .answered)
        #expect(bornYet.prose == "Dan and Mark were born by 1994; Matt and Timmy were not (Matt was born in 1996, Timmy in 1999).", Comment(rawValue: bornYet.prose))
        #expect(bornYet.basisLine.hasPrefix("Basis: 'the boys' = Dan, Mark (children of Rick) and Matt, Timmy (children of Donna) in the People tab relationships; People profile birthdates Dan 1984-06-01"), Comment(rawValue: bornYet.basisLine))
        #expect(bornYet.refinableQuery == .list(.presence(.init(people: ["Dan", "Mark", "Matt", "Timmy"], mediaKind: .video)), anyOfPeople: true))

        // The translator trimmed the subject to the noun.
        let ages = try await ask("how old were the boys then", subject: "boys")
        #expect(ages.prose == "In 1994 Dan was 9 or 10 and Mark 7 or 8. Matt and Timmy weren't born yet (Matt was born in 1996, Timmy in 1999).", Comment(rawValue: ages.prose))

        let dad = try await ask("how old would my dad have been in this video", subject: "my dad")
        #expect(dad.outcome == .answered)
        #expect(dad.prose == "Dad would have been 57 or 58 in 1994 — he passed on in 1977.", Comment(rawValue: dad.prose))
        #expect(dad.basisLine.contains("'my dad' = Dad, father of Rick Breen in the People tab relationships"), Comment(rawValue: dad.basisLine))
        #expect(dad.catalogPersonName == "Dad")
        #expect(dad.refinableQuery == .list(.presence(.init(people: ["Dad"], mediaKind: .video)), anyOfPeople: false))

        // A named subject is untouched by a kin phrase elsewhere in the question.
        let donna = try await ask("how old was Donna when my dad died", subject: "Donna")
        #expect(donna.prose.contains("Donna was 34\u{2013}35 years old during 1994"), Comment(rawValue: donna.prose))

        // Nobody has said who "the boys" belong to.
        let noOwner = try await HallieTurnExecutor.execute(
            .init(intent: .init(originalQuestion: "how old were the boys then", ast: .temporal(
                .init(subject: "the boys", operation: .age, reference: .currentSelection)))),
            context: .init(profiles: profiles, selectedTemporalDate: christmas1994, speakers: .none))
        #expect(noOwner.outcome == .declined)
        #expect(noOwner.prose.hasPrefix("I don't know who “the boys” are — no one has told me who is using the archive."), Comment(rawValue: noOwner.prose))
    }
}
