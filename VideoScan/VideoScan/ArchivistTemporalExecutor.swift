import Foundation

enum ArchivistTemporalBirthdateProvenance: Sendable, Equatable {
    case poiProfile(profileID: String)
}

/// Immutable canonical identity resolved before temporal execution.
struct ArchivistTemporalSubjectSnapshot: Sendable, Equatable {
    let stableID: String
    let canonicalName: String
    let birthdate: Date?
    let birthdateProvenance: ArchivistTemporalBirthdateProvenance

    init(
        stableID: String,
        canonicalName: String,
        birthdate: Date?,
        birthdateProvenance: ArchivistTemporalBirthdateProvenance? = nil
    ) {
        self.stableID = stableID
        self.canonicalName = canonicalName
        self.birthdate = birthdate
        self.birthdateProvenance = birthdateProvenance
            ?? .poiProfile(profileID: stableID)
    }

    /// Copies the actor-owned profile into an immutable value. `@MainActor`
    /// is the Swift equivalent of reading a UI-owned object on its UI thread.
    @MainActor
    init(profile: POIProfile) {
        self.init(
            stableID: profile.id,
            canonicalName: profile.name,
            birthdate: profile.birthdate,
            birthdateProvenance: .poiProfile(profileID: profile.id))
    }
}

/// PersonResolver outcome is explicit so missing and ambiguous names cannot
/// accidentally execute against an arbitrary POI.
enum ArchivistTemporalSubjectResolution: Sendable, Equatable {
    struct Candidate: Sendable, Equatable {
        let stableID: String
        let canonicalName: String
    }

    case resolved(requested: String, subject: ArchivistTemporalSubjectSnapshot)
    case missing(requested: String)
    case ambiguous(requested: String, candidates: [Candidate])
}

/// Exact selected-record date and its provenance. Catalog timestamps remain
/// labeled because a transcode or ingest can change them without changing the
/// family event date.
enum ArchivistTemporalSelectionDateSnapshot: Sendable, Equatable {
    case dossierInferred(
        recordID: UUID, fullPath: String, date: Date, confidence: Float?)
    case catalogCreation(recordID: UUID, fullPath: String, date: Date)
    case fileModification(recordID: UUID, fullPath: String, date: Date)

    var date: Date {
        switch self {
        case .dossierInferred(_, _, let date, _),
             .catalogCreation(_, _, let date),
             .fileModification(_, _, let date):
            return date
        }
    }

    /// Production extraction prefers the dossier's family-event inference.
    /// The lower-confidence catalog fallbacks are never presented as inferred
    /// family truth; their provenance remains attached to the answer.
    @MainActor
    static func capture(record: VideoRecord) -> Self? {
        if let date = record.inferredRecordDate {
            return .dossierInferred(
                recordID: record.id, fullPath: record.fullPath, date: date,
                confidence: record.inferredDateConfidence)
        }
        if let date = record.dateCreatedRaw {
            return .catalogCreation(
                recordID: record.id, fullPath: record.fullPath, date: date)
        }
        if let date = record.dateModifiedRaw {
            return .fileModification(
                recordID: record.id, fullPath: record.fullPath, date: date)
        }
        return nil
    }
}

enum ArchivistTemporalValue: Sendable, Equatable {
    case exactAge(Int)
    case ageRange(ClosedRange<Int>)
}

enum ArchivistTemporalDecline: Sendable, Equatable {
    case missingSubject
    case ambiguousSubject([ArchivistTemporalSubjectResolution.Candidate])
    case resolutionMismatch
    case invalidSubject
    case missingBirthdate
    case missingReference
    case referenceBeforeBirth
    case invalidDate
    case invalidReferenceYear
}

enum ArchivistTemporalReferenceEvidence: Sendable, Equatable {
    case explicitYear(Int)
    case currentSelection(ArchivistTemporalSelectionDateSnapshot)
}

struct ArchivistTemporalEvidence: Sendable, Equatable {
    let subjectID: String
    let canonicalName: String
    let birthdate: Date
    let birthdateProvenance: ArchivistTemporalBirthdateProvenance
    let reference: ArchivistTemporalReferenceEvidence
}

struct ArchivistTemporalResult: Sendable, Equatable {
    let value: ArchivistTemporalValue?
    let decline: ArchivistTemporalDecline?
    let prose: String
    let basisLine: String
    let evidence: ArchivistTemporalEvidence?
}

/// Pure deterministic temporal executor. The LLM supplies only QueryAST; it
/// never receives the snapshots, evidence, or factual prose produced here.
enum ArchivistTemporalExecutor {
    private static let validReferenceYears = 1900...2099

    static func execute(
        _ query: ArchivistQueryAST.Temporal,
        subject resolution: ArchivistTemporalSubjectResolution,
        currentSelection: ArchivistTemporalSelectionDateSnapshot?
    ) -> ArchivistTemporalResult {
        let requested = query.subject.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !requested.isEmpty else { return decline(.missingSubject) }

        let subject: ArchivistTemporalSubjectSnapshot
        switch resolution {
        case .missing(let resolvedText):
            guard sameRequest(requested, resolvedText) else {
                return decline(.resolutionMismatch)
            }
            return decline(.missingSubject)
        case .ambiguous(let resolvedText, let candidates):
            guard sameRequest(requested, resolvedText) else {
                return decline(.resolutionMismatch)
            }
            return decline(.ambiguousSubject(candidates))
        case .resolved(let resolvedText, let value):
            guard sameRequest(requested, resolvedText) else {
                return decline(.resolutionMismatch)
            }
            subject = value
        }

        guard !subject.stableID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !subject.canonicalName.trimmingCharacters(
                in: .whitespacesAndNewlines).isEmpty else {
            return decline(.invalidSubject)
        }
        guard let rawBirthdate = subject.birthdate else {
            return decline(.missingBirthdate, name: subject.canonicalName)
        }
        guard let birthdate = canonicalDay(rawBirthdate) else {
            return decline(.invalidDate, name: subject.canonicalName)
        }

        switch query.reference {
        case .explicitYear(let year):
            guard validReferenceYears.contains(year) else {
                return decline(.invalidReferenceYear,
                               name: subject.canonicalName)
            }
            let birthYear = calendar.component(.year, from: birthdate)
            guard year >= birthYear else {
                return decline(.referenceBeforeBirth,
                               name: subject.canonicalName)
            }
            let upper = year - birthYear
            let birthParts = calendar.dateComponents(
                [.month, .day], from: birthdate)
            let bornOnJanuaryFirst = birthParts.month == 1 && birthParts.day == 1
            let lower = bornOnJanuaryFirst ? upper : max(0, upper - 1)
            let range = lower...upper
            let evidence = ArchivistTemporalEvidence(
                subjectID: subject.stableID,
                canonicalName: subject.canonicalName,
                birthdate: birthdate,
                birthdateProvenance: subject.birthdateProvenance,
                reference: .explicitYear(year))
            let prose: String
            if bornOnJanuaryFirst {
                prose = "\(subject.canonicalName) was \(upper) years old throughout "
                    + "\(year) by calendar-date precision."
            } else if lower == upper {
                prose = "\(subject.canonicalName) was 0 years old during "
                    + "the part of \(year) after their birth."
            } else {
                prose = "\(subject.canonicalName) was \(lower)\u{2013}\(upper) years old "
                    + "during \(year), depending on the date."
            }
            return ArchivistTemporalResult(
                value: .ageRange(range), decline: nil, prose: prose,
                basisLine: "Basis: POI profile birthdate \(dayString(birthdate)); "
                    + "the question supplied year \(year) without a month/day.",
                evidence: evidence)

        case .currentSelection:
            guard let selection = currentSelection else {
                return decline(.missingReference, name: subject.canonicalName)
            }
            guard let referenceDate = canonicalDay(selection.date) else {
                return decline(.invalidDate, name: subject.canonicalName)
            }
            guard referenceDate >= birthdate else {
                return decline(.referenceBeforeBirth,
                               name: subject.canonicalName)
            }
            guard let age = calendar.dateComponents(
                [.year], from: birthdate, to: referenceDate).year,
                  age >= 0 else {
                return decline(.invalidDate, name: subject.canonicalName)
            }
            let evidence = ArchivistTemporalEvidence(
                subjectID: subject.stableID,
                canonicalName: subject.canonicalName,
                birthdate: birthdate,
                birthdateProvenance: subject.birthdateProvenance,
                reference: .currentSelection(selection))
            return ArchivistTemporalResult(
                value: .exactAge(age), decline: nil,
                prose: referenceProse(
                    selection, name: subject.canonicalName, age: age,
                    date: referenceDate),
                basisLine: "Basis: POI profile birthdate \(dayString(birthdate)); "
                    + referenceBasis(selection, date: referenceDate) + ".",
                evidence: evidence)
        }
    }

    private static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private static func canonicalDay(_ date: Date) -> Date? {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return nil }
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month,
              let day = components.day else { return nil }
        var canonical = DateComponents()
        canonical.calendar = calendar
        canonical.timeZone = calendar.timeZone
        canonical.year = year
        canonical.month = month
        canonical.day = day
        canonical.hour = 12
        return calendar.date(from: canonical)
    }

    private static func sameRequest(_ lhs: String, _ rhs: String) -> Bool {
        lhs.folding(options: [.caseInsensitive, .diacriticInsensitive],
                    locale: Locale(identifier: "en_US"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            == rhs.folding(options: [.caseInsensitive, .diacriticInsensitive],
                           locale: Locale(identifier: "en_US"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func dayString(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d",
                      parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func referenceBasis(
        _ selection: ArchivistTemporalSelectionDateSnapshot,
        date: Date
    ) -> String {
        switch selection {
        case .dossierInferred(_, let path, _, let confidence):
            let confidenceText = confidence.map { String(format: "%.2f", $0) }
                ?? "not recorded"
            return "selected record dossier inferred date \(dayString(date)) "
                + "(confidence \(confidenceText), \(path))"
        case .catalogCreation(_, let path, _):
            return "selected record catalog creation date \(dayString(date)) "
                + "fallback (not verified recording-age evidence; may reflect "
                + "ingest/transcode, \(path))"
        case .fileModification(_, let path, _):
            return "selected record file modification date \(dayString(date)) "
                + "fallback (not verified recording-age evidence; may reflect "
                + "ingest/transcode, \(path))"
        }
    }

    private static func referenceProse(
        _ selection: ArchivistTemporalSelectionDateSnapshot,
        name: String,
        age: Int,
        date: Date
    ) -> String {
        switch selection {
        case .dossierInferred(_, _, _, let confidence):
            let confidenceText = confidence.map { String(format: "%.2f", $0) }
                ?? "not recorded"
            return "Using the selected record's inferred date "
                + "\(dayString(date)), \(name)'s calculated age is \(age) years "
                + "(inference confidence \(confidenceText))."
        case .catalogCreation:
            return "Using the selected record's catalog creation date "
                + "\(dayString(date)) as a fallback, \(name)'s calculated age is "
                + "\(age) years; this is not verified recording-age evidence."
        case .fileModification:
            return "Using the selected record's file modification date "
                + "\(dayString(date)) as a fallback, \(name)'s calculated age is "
                + "\(age) years; this is not verified recording-age evidence."
        }
    }

    private static func decline(
        _ reason: ArchivistTemporalDecline,
        name: String? = nil
    ) -> ArchivistTemporalResult {
        let prose: String
        let basis: String
        switch reason {
        case .missingSubject:
            prose = "I don't have a resolved person for that question."
            basis = "Basis: no canonical subject was resolved."
        case .ambiguousSubject(let candidates):
            prose = "I can't determine which person you mean."
            let names = candidates.map(\.canonicalName).joined(separator: ", ")
            basis = names.isEmpty
                ? "Basis: subject resolution was ambiguous."
                : "Basis: subject resolution matched multiple people: \(names)."
        case .resolutionMismatch:
            prose = "I can't safely connect that question to the resolved person."
            basis = "Basis: the resolver result belongs to a different request."
        case .invalidSubject:
            prose = "I don't have a valid canonical person for that question."
            basis = "Basis: the resolved subject lacks a stable ID or name."
        case .missingBirthdate:
            prose = "I don't have a birthdate for \(name ?? "that person")."
            basis = "Basis: the canonical POI profile has no birthdate."
        case .missingReference:
            prose = "I don't have a usable date for the current selection."
            basis = "Basis: the selected catalog record has no dated evidence."
        case .referenceBeforeBirth:
            prose = "I can't calculate that age because the reference is before "
                + "\(name ?? "the person's") birthdate."
            basis = "Basis: reference date/year precedes the POI birthdate."
        case .invalidDate:
            prose = "I can't calculate that age because a stored date is invalid."
            basis = "Basis: date validation failed."
        case .invalidReferenceYear:
            prose = "I can't calculate that age because the reference year is invalid."
            basis = "Basis: reference year must be within 1900...2099."
        }
        return ArchivistTemporalResult(
            value: nil, decline: reason, prose: prose, basisLine: basis,
            evidence: nil)
    }
}
