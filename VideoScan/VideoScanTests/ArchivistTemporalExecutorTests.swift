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
    /// same immutable values used by the pure executor, with dossier priority.
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
        #expect(result.prose.contains("inferred date 2020-08-04"))
        #expect(result.prose.contains("inference confidence 0.85"))
        #expect(result.evidence?.subjectID == profile.id)
        guard case .currentSelection(.dossierInferred(
            let recordID, let path, let selectedDate, let confidence))
            = result.evidence?.reference else {
            Issue.record("expected dossier-inferred production provenance")
            return
        }
        #expect(recordID == record.id)
        #expect(path == record.fullPath)
        #expect(selectedDate == date(2020, 8, 4))
        #expect(confidence == 0.85)
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
}
