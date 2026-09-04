import Foundation
import VideoScanCore

enum ArchivistTemporalBirthdateProvenance: Sendable, Equatable {
    case poiProfile(profileID: String)
}

/// Immutable canonical identity resolved before temporal execution.
struct ArchivistTemporalSubjectSnapshot: Sendable, Equatable {
    let stableID: String
    let canonicalName: String
    let birthdate: Date?
    let birthdateProvenance: ArchivistTemporalBirthdateProvenance
    /// The profile's recorded death (LifeStatus, 2026-09-01). Only the
    /// present-tense path reads it: "how old is X" for someone who has
    /// passed on is answered as the age at death, never an age today.
    let deathdate: Date?
    /// The profile's recorded sex, for the pronoun in "(he passed on in
    /// 1977)". Nil = no pronoun is used. Additive (2026-09-02).
    let sex: PersonSex?

    init(
        stableID: String,
        canonicalName: String,
        birthdate: Date?,
        birthdateProvenance: ArchivistTemporalBirthdateProvenance? = nil,
        deathdate: Date? = nil,
        sex: PersonSex? = nil
    ) {
        self.stableID = stableID
        self.canonicalName = canonicalName
        self.birthdate = birthdate
        self.birthdateProvenance = birthdateProvenance
            ?? .poiProfile(profileID: stableID)
        self.deathdate = deathdate
        self.sex = sex
    }

    /// Copies the actor-owned profile into an immutable value. `@MainActor`
    /// is the Swift equivalent of reading a UI-owned object on its UI thread.
    @MainActor
    init(profile: POIProfile) {
        self.init(
            stableID: profile.id,
            canonicalName: profile.name,
            birthdate: profile.birthdate,
            birthdateProvenance: .poiProfile(profileID: profile.id),
            deathdate: profile.deathdate,
            sex: profile.sex)
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
    /// The Catalog's own answer to "when was this shot" — RecordDateResolver
    /// (2026-09-01): Rick's hand-entered date, the embedded camera stamp, a
    /// confident dossier inference, or a date in the filename, in that order.
    /// `date` is the START of the resolved period at UTC noon ("1994" →
    /// 1994-01-01); `precision` says how much of it is real.
    case resolved(
        recordID: UUID, fullPath: String, date: Date,
        source: RecordDateResolution.Source,
        precision: RecordDateResolution.Precision,
        confidence: Float)
    case dossierInferred(
        recordID: UUID, fullPath: String, date: Date, confidence: Float?)
    case catalogCreation(recordID: UUID, fullPath: String, date: Date)
    case fileModification(recordID: UUID, fullPath: String, date: Date)

    var date: Date {
        switch self {
        case .resolved(_, _, let date, _, _, _),
             .dossierInferred(_, _, let date, _),
             .catalogCreation(_, _, let date),
             .fileModification(_, _, let date):
            return date
        }
    }

    var recordID: UUID {
        switch self {
        case .resolved(let id, _, _, _, _, _),
             .dossierInferred(let id, _, _, _),
             .catalogCreation(let id, _, _),
             .fileModification(let id, _, _):
            return id
        }
    }

    var fullPath: String {
        switch self {
        case .resolved(_, let path, _, _, _, _),
             .dossierInferred(_, let path, _, _),
             .catalogCreation(_, let path, _),
             .fileModification(_, let path, _):
            return path
        }
    }

    /// How much of `date` is a recorded fact. The filesystem stamps are
    /// full timestamps (day). A low-confidence dossier inference sitting
    /// exactly on noon-UTC 1 January is the codebase's year-only
    /// placeholder (DateTriangulation.yearOnlyDate), not New Year's Day.
    var precision: RecordDateResolution.Precision {
        switch self {
        case .resolved(_, _, _, _, let precision, _):
            return precision
        case .dossierInferred(_, _, let date, _):
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(secondsFromGMT: 0)!
            let parts = utc.dateComponents([.month, .day, .hour], from: date)
            return parts.month == 1 && parts.day == 1 && parts.hour == 12 ? .year : .day
        case .catalogCreation, .fileModification:
            return .day
        }
    }

    /// Where the date came from, in words a family member would use.
    var sourceLabel: String {
        switch self {
        case .resolved(_, _, _, let source, _, _):
            switch source {
            case .userDate: return "the date Rick entered"
            case .embedded: return "the camera's embedded date"
            case .inferred: return "the dossier's inferred date"
            case .filename: return "the filename"
            case .none: return "no recorded source"
            }
        case .dossierInferred: return "the dossier's inferred date"
        case .catalogCreation: return "the catalog creation stamp"
        case .fileModification: return "the file modification stamp"
        }
    }

    /// True for the legacy stamps that may be an ingest/transcode date.
    var isUnverifiedFallback: Bool {
        switch self {
        case .resolved, .dossierInferred: return false
        case .catalogCreation, .fileModification: return true
        }
    }

    /// Production extraction: the Catalog's shared date ranking first
    /// (RecordDateResolver — the same one placement and ArchiveReadiness
    /// use), then the older chain only when the resolver has nothing. The
    /// old chain preferred `inferredRecordDate` then the CATALOG CREATION
    /// stamp, which for a 2026 transcode of a 1994 tape answered "how old is
    /// Donna" with 66 instead of 35 (eval 2026-09-01). The lower-confidence
    /// catalog fallbacks are never presented as inferred family truth; their
    /// provenance remains attached to the answer.
    @MainActor
    static func capture(record: VideoRecord) -> Self? {
        if let resolved = resolvedCatalogDate(record: record) { return resolved }
        return legacyFallback(record: record)
    }

    /// RecordDateResolver's verdict for the record, or nil when it has no
    /// dated signal at all. Shared by the app (`capture`) and the shell.
    static func resolvedCatalogDate(record: VideoRecord) -> Self? {
        let resolution = RecordDateResolver.resolve(
            userDate: record.userDate,
            userDateConfidence: record.userDateConfidence,
            embeddedCreationDate: record.embeddedCreationDate,
            originMake: record.originMake,
            originModel: record.originModel,
            originEncoder: record.originEncoder,
            inferredRecordDate: record.inferredRecordDate,
            inferredDateConfidence: record.inferredDateConfidence,
            filename: record.filename.isEmpty ? nil : record.filename)
        guard resolution.precision <= .year, let start = resolution.date else { return nil }
        // Noon, not midnight: the executor canonicalises to UTC noon and
        // the resolver hands back 00:00Z — same day either way, but a
        // noon instant survives any later local-time rendering intact.
        return .resolved(
            recordID: record.id, fullPath: record.fullPath,
            date: start.addingTimeInterval(12 * 3600),
            source: resolution.source, precision: resolution.precision,
            confidence: resolution.confidence)
    }

    /// The pre-2026-09-01 chain, kept only for records the resolver cannot
    /// date: a low-confidence inference, then the filesystem stamps.
    static func legacyFallback(record: VideoRecord) -> Self? {
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
    /// Year arithmetic only — the tree gave a birth YEAR, no month/day.
    case approximateAge(Int)
    /// Several people at once ("the boys"), or a born-yet / would-have-been
    /// ask: `answered` of `of` subjects got a definite verdict. The prose
    /// carries the per-person facts (ArchivistTemporalExecutor.executeGroup).
    case group(answered: Int, of: Int)
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
    /// "how old is Donna" with nothing selected: counted to this day.
    case today(Date)
    /// The subject has passed on: counted to the recorded death date.
    case death(Date)
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
            let evidence = ArchivistTemporalEvidence(
                subjectID: subject.stableID,
                canonicalName: subject.canonicalName,
                birthdate: birthdate,
                birthdateProvenance: subject.birthdateProvenance,
                reference: .currentSelection(selection))
            let birthYear = calendar.component(.year, from: birthdate)
            let referenceYear = calendar.component(.year, from: referenceDate)
            let basis = "Basis: POI profile birthdate \(dayString(birthdate)); "
                + referenceBasis(selection, date: referenceDate) + "."

            // A year-only date ("1994" typed by Rick, or a bare year in the
            // filename) is the whole year, not 1 January: the honest answer
            // is the same range the explicit-year path gives.
            if selection.precision == .year {
                guard referenceYear >= birthYear else {
                    return decline(.referenceBeforeBirth, name: subject.canonicalName)
                }
                let upper = referenceYear - birthYear
                let birthParts = calendar.dateComponents([.month, .day], from: birthdate)
                let bornOnJanuaryFirst = birthParts.month == 1 && birthParts.day == 1
                let lower = bornOnJanuaryFirst ? upper : max(0, upper - 1)
                let ages = lower == upper ? "\(upper)" : "\(lower)\u{2013}\(upper)"
                return ArchivistTemporalResult(
                    value: .ageRange(lower...upper), decline: nil,
                    prose: "\(subject.canonicalName) was \(ages) years old during "
                        + "\(referenceYear) — the selected record is dated to the "
                        + "year only (from \(selection.sourceLabel)).",
                    basisLine: basis, evidence: evidence)
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
            if selection.precision == .month {
                return ArchivistTemporalResult(
                    value: .approximateAge(age), decline: nil,
                    prose: "\(subject.canonicalName) was about \(age) in "
                        + "\(monthYearString(referenceDate)) — the selected record "
                        + "is dated to the month (from \(selection.sourceLabel)).",
                    basisLine: basis, evidence: evidence)
            }
            return ArchivistTemporalResult(
                value: .exactAge(age), decline: nil,
                prose: referenceProse(
                    selection, name: subject.canonicalName, age: age,
                    date: referenceDate),
                basisLine: basis,
                evidence: evidence)
        }
    }

    // MARK: - Present tense ("how old is Donna", nothing selected)

    /// A birth YEAR from the family tree, offered when the profile has no
    /// full birthdate; the answer is then "about N" and says why.
    struct ApproximateBirthYear: Sendable, Equatable {
        let year: Int
        let source: String
    }

    private static let selectionReferents: [String] = [
        "here", "this", "that", "in the video", "in the clip", "in the tape",
        "in the footage", "in the recording", "in the film", "on the tape",
        "on screen", "on the screen",
    ]

    /// True for a question that asks someone's age NOW ("how old is Donna",
    /// "what age is Rick today", "how old is Matt now"). Past tense ("how
    /// old was") and a pointer at the selected video ("how old is Donna
    /// here / in this video") are NOT present-tense asks — those keep the
    /// selected-record semantics.
    static func isPresentTenseAge(_ question: String) -> Bool {
        let lowered = question.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
        let collapsed = lowered.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return false }
        if collapsed.contains("how old was") || collapsed.contains("what age was")
            || collapsed.contains("how old were") || collapsed.contains(" was ") {
            return false
        }
        let asksNow = collapsed.contains("how old is ") || collapsed.contains("how old's ")
            || collapsed.contains("what age is ") || collapsed.contains("how old are ")
            || collapsed.contains("'s age now") || collapsed.contains("'s age today")
            || collapsed.contains("'s current age") || collapsed.contains("what is the age of ")
            || collapsed.contains("what's the age of ")
        guard asksNow else { return false }
        let words = Set(collapsed.split(whereSeparator: { !$0.isLetter }).map(String.init))
        for referent in selectionReferents {
            if referent.contains(" ") {
                if collapsed.contains(referent) { return false }
            } else if words.contains(referent) {
                return false
            }
        }
        return true
    }

    /// Age today from the profile birthdate — or, for someone who has passed
    /// on, the age at death ("Dad passed on in 2011 at 74"). With only a
    /// tree birth year the answer is "about N". `now` is injected so the
    /// tests are not a function of the wall clock.
    static func executePresentAge(
        _ query: ArchivistQueryAST.Temporal,
        subject resolution: ArchivistTemporalSubjectResolution,
        approximateBirthYear: ApproximateBirthYear? = nil,
        now: Date = Date()
    ) -> ArchivistTemporalResult {
        let requested = query.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty else { return decline(.missingSubject) }
        let subject: ArchivistTemporalSubjectSnapshot
        switch resolution {
        case .missing(let resolvedText):
            guard sameRequest(requested, resolvedText) else { return decline(.resolutionMismatch) }
            return decline(.missingSubject)
        case .ambiguous(let resolvedText, let candidates):
            guard sameRequest(requested, resolvedText) else { return decline(.resolutionMismatch) }
            return decline(.ambiguousSubject(candidates))
        case .resolved(let resolvedText, let value):
            guard sameRequest(requested, resolvedText) else { return decline(.resolutionMismatch) }
            subject = value
        }
        guard !subject.stableID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !subject.canonicalName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return decline(.invalidSubject)
        }
        let name = subject.canonicalName
        guard let today = canonicalDay(now) else { return decline(.invalidDate, name: name) }
        let status = LifeStatus.ofProfile(deathdate: subject.deathdate, now: now)

        if let rawBirthdate = subject.birthdate {
            guard let birthdate = canonicalDay(rawBirthdate) else {
                return decline(.invalidDate, name: name)
            }
            if status != .living, let rawDeath = subject.deathdate,
               let deathDay = canonicalDay(rawDeath) {
                guard deathDay >= birthdate,
                      let age = calendar.dateComponents([.year], from: birthdate, to: deathDay).year,
                      age >= 0 else {
                    return decline(.invalidDate, name: name)
                }
                let deathYear = calendar.component(.year, from: deathDay)
                return ArchivistTemporalResult(
                    value: .exactAge(age), decline: nil,
                    prose: "\(name) passed on in \(deathYear) at \(age).",
                    basisLine: "Basis: from \(name)'s People profile birthdate \(dayString(birthdate)) "
                        + "and recorded death \(dayString(deathDay)); no video selected.",
                    evidence: ArchivistTemporalEvidence(
                        subjectID: subject.stableID, canonicalName: name,
                        birthdate: birthdate, birthdateProvenance: subject.birthdateProvenance,
                        reference: .death(deathDay)))
            }
            guard today >= birthdate else { return decline(.referenceBeforeBirth, name: name) }
            guard let age = calendar.dateComponents([.year], from: birthdate, to: today).year,
                  age >= 0 else {
                return decline(.invalidDate, name: name)
            }
            return ArchivistTemporalResult(
                value: .exactAge(age), decline: nil,
                prose: "\(name) is \(age) today — born \(longDayString(birthdate)).",
                basisLine: "Basis: from \(name)'s People profile birthdate \(dayString(birthdate)), "
                    + "counted to today (\(dayString(today))); no video selected.",
                evidence: ArchivistTemporalEvidence(
                    subjectID: subject.stableID, canonicalName: name,
                    birthdate: birthdate, birthdateProvenance: subject.birthdateProvenance,
                    reference: .today(today)))
        }

        // No full birthdate on the profile: a tree birth YEAR gives "about N".
        if let approximate = approximateBirthYear {
            let nowYear = calendar.component(.year, from: today)
            if status != .living, let rawDeath = subject.deathdate,
               let deathDay = canonicalDay(rawDeath) {
                let deathYear = calendar.component(.year, from: deathDay)
                guard deathYear >= approximate.year else {
                    return decline(.invalidDate, name: name)
                }
                return ArchivistTemporalResult(
                    value: .approximateAge(deathYear - approximate.year), decline: nil,
                    prose: "\(name) passed on in \(deathYear) at about \(deathYear - approximate.year) "
                        + "— \(approximate.source) gives only the birth year, \(approximate.year).",
                    basisLine: "Basis: birth year \(approximate.year) from \(approximate.source) "
                        + "(no month/day) and recorded death \(dayString(deathDay)); no video selected.",
                    evidence: nil)
            }
            guard nowYear >= approximate.year else {
                return decline(.referenceBeforeBirth, name: name)
            }
            let about = nowYear - approximate.year
            return ArchivistTemporalResult(
                value: .approximateAge(about), decline: nil,
                prose: "\(name) is about \(about) — \(approximate.source) gives only the birth year, "
                    + "\(approximate.year).",
                basisLine: "Basis: birth year \(approximate.year) from \(approximate.source) "
                    + "(no month/day), counted to \(nowYear); no video selected.",
                evidence: nil)
        }
        return decline(.missingBirthdate, name: name)
    }

    /// The house format, through the one formatter (`HallieDateStyle`).
    /// Unchanged output — this renderer was already right; it now shares
    /// the definition instead of restating it.
    private static func longDayString(_ date: Date) -> String {
        HallieDateStyle.spoken(date, calendar: calendar)
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

    /// "December 1994" in the executor's UTC calendar.
    static func monthYearString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: date)
    }

    /// ISO at the given precision: "1994-12-25" / "1994-12" / "1994".
    static func periodString(
        _ date: Date, precision: RecordDateResolution.Precision
    ) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        switch precision {
        case .day, .unknown, .decade:
            return String(format: "%04d-%02d-%02d",
                          parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        case .month:
            return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
        case .year:
            return String(format: "%04d", parts.year ?? 0)
        }
    }

    static func precisionLabel(_ precision: RecordDateResolution.Precision) -> String {
        switch precision {
        case .day: return "day"
        case .month: return "month"
        case .year: return "year"
        case .decade: return "decade"
        case .unknown: return "unknown"
        }
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
        case .resolved(_, let path, _, let source, let precision, let confidence):
            return "selected record date \(periodString(date, precision: precision)) "
                + "from \(source.rawValue) (\(precisionLabel(precision)) precision, "
                + "confidence \(String(format: "%.2f", confidence)), \(path))"
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
        case .resolved:
            return "Using the selected record's date \(dayString(date)) "
                + "(\(selection.sourceLabel)), \(name)'s calculated age is "
                + "\(age) years."
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
            prose = "I need to know who you mean — and which video. Select a video in the Catalog and ask, for example, “how old was Donna in this video?”"
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
            prose = "I need a dated video to count from — select one in the Catalog and ask again, or give me a year (“how old was \(name ?? "Donna") in 1995?”)."
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

// MARK: - Several people at once, "born yet", "would have been"

/// "were the boys born yet when this was shot" / "how old would my dad have
/// been in this video" / "how old were the boys then" (eval tm008, tm014,
/// tm019, 2026-09-01). The subjects arrive already resolved — the turn
/// executor turns "the boys" into the owner's children and "my dad" into the
/// owner's father through the People-tab relationships — and the date
/// arithmetic is the SAME single-person `execute` / `executePresentAge`
/// run once per person; this section only phrases the verdicts together.
extension ArchivistTemporalExecutor {

    /// What the question is really asking about the reference date.
    enum Ask: Sendable, Equatable {
        /// "how old was / were …" — an age per person.
        case age
        /// "were they born yet …" — yes / no per person.
        case bornYet
        /// "how old would … have been" — an age, said as a would-have-been
        /// (with the death year) for someone who had passed on by then.
        case wouldHaveBeen
    }

    /// Deterministic read of the ORIGINAL question. Born-yet wording wins
    /// over would-have-been ("would the boys have been born yet").
    static func detectAsk(in question: String) -> Ask {
        let lowered = question.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        let collapsed = lowered.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let bornYet = [
            #"\bborn yet\b"#, #"\bbeen born\b"#, #"\balready born\b"#,
            #"\bborn (?:by|before|already|at the time|at that point|back then)\b"#,
            #"\bborn (?:when|then)\b"#, #"\balive (?:yet|then|at the time)\b"#,
            #"\baround yet\b"#, #"\bon the scene yet\b"#,
        ]
        if bornYet.contains(where: { collapsed.range(of: $0, options: .regularExpression) != nil }) {
            return .bornYet
        }
        if collapsed.range(of: #"\bwould(?:'ve)?\b[^.?!]{0,40}?\b(?:have been|been|be)\b"#,
                           options: .regularExpression) != nil {
            return .wouldHaveBeen
        }
        return .age
    }

    /// The point in time the group answer counts to.
    enum GroupReference: Sendable, Equatable {
        case explicitYear(Int)
        case selection(ArchivistTemporalSelectionDateSnapshot)
        /// Present tense with nothing selected ("how old are the boys now").
        case today(Date)
    }

    /// One person's verdict against the reference, before phrasing.
    private enum GroupVerdict {
        case age(text: String, wouldHaveBeen: Bool, deathYear: Int?)
        case notYetBorn(birthYear: Int)
        case bornThatPeriod(birthYear: Int)
        case wasBorn
        case noBirthdate
        case other(prose: String)
    }

    /// `subjects` in the order the answer should name them (the caller
    /// sorts oldest first). `phrase` is what the question called them
    /// ("the boys") for the basis line. Reuses the single-person paths for
    /// every date computation; nothing here resolves a date on its own.
    static func executeGroup(
        subjects: [ArchivistTemporalSubjectSnapshot],
        phrase: String,
        ask: Ask,
        reference: GroupReference,
        now: Date = Date()
    ) -> ArchivistTemporalResult {
        guard !subjects.isEmpty else { return decline(.missingSubject) }
        let names = subjects.map(\.canonicalName)

        // The reference as a canonical day + precision, for born-yet
        // comparisons and the lead-in ("In 1994", "On 25 December 1994").
        let referenceDay: Date?
        let referenceYear: Int
        let precision: RecordDateResolution.Precision
        let leadIn: String
        let byLabel: String
        let referenceBasisText: String
        switch reference {
        case .explicitYear(let year):
            guard validReferenceYears.contains(year) else {
                return decline(.invalidReferenceYear, name: names.first)
            }
            referenceDay = nil
            referenceYear = year
            precision = .year
            leadIn = "In \(year)"
            byLabel = "by \(year)"
            referenceBasisText = "the question supplied year \(year) without a month/day"
        case .selection(let selection):
            guard let day = canonicalDay(selection.date) else {
                return decline(.invalidDate, name: names.first)
            }
            referenceDay = day
            referenceYear = calendar.component(.year, from: day)
            precision = selection.precision
            switch precision {
            case .year, .decade, .unknown:
                leadIn = "In \(referenceYear)"
                byLabel = "by \(referenceYear)"
            case .month:
                leadIn = "In \(monthYearString(day))"
                byLabel = "by \(monthYearString(day))"
            case .day:
                leadIn = "On \(longDayString(day))"
                byLabel = "by \(longDayString(day))"
            }
            referenceBasisText = referenceBasis(selection, date: day)
        case .today(let date):
            guard let day = canonicalDay(date) else {
                return decline(.invalidDate, name: names.first)
            }
            referenceDay = day
            referenceYear = calendar.component(.year, from: day)
            precision = .day
            leadIn = "Today"
            byLabel = "by today"
            referenceBasisText = "counted to today (\(dayString(day))); no video selected"
        }

        // One single-person computation per subject; the verdict is read
        // from the result's value / decline, never recomputed here.
        var verdicts: [(name: String, verdict: GroupVerdict)] = []
        var birthLines: [String] = []
        for subject in subjects {
            let name = subject.canonicalName
            guard let rawBirth = subject.birthdate, let birthdate = canonicalDay(rawBirth) else {
                verdicts.append((name, .noBirthdate))
                birthLines.append("no birthdate for \(name)")
                continue
            }
            let birthYear = calendar.component(.year, from: birthdate)
            birthLines.append("\(name) \(dayString(birthdate))"
                + (subject.deathdate.flatMap(canonicalDay).map { " (died \(dayString($0)))" } ?? ""))

            if ask == .bornYet {
                let born: Bool
                var thatPeriod = false
                if precision == .year || referenceDay == nil {
                    born = birthYear < referenceYear
                    thatPeriod = birthYear == referenceYear
                } else if precision == .month, let referenceDay {
                    let birthMonth = calendar.dateComponents([.year, .month], from: birthdate)
                    let referenceMonth = calendar.dateComponents([.year, .month], from: referenceDay)
                    let sameMonth = birthMonth.year == referenceMonth.year && birthMonth.month == referenceMonth.month
                    born = !sameMonth && birthdate < referenceDay
                    thatPeriod = sameMonth
                } else if let referenceDay {
                    born = birthdate <= referenceDay
                } else {
                    born = false
                }
                if thatPeriod {
                    verdicts.append((name, .bornThatPeriod(birthYear: birthYear)))
                } else {
                    verdicts.append((name, born ? .wasBorn : .notYetBorn(birthYear: birthYear)))
                }
                continue
            }

            let single = ArchivistQueryAST.Temporal(
                subject: name, operation: .age,
                reference: {
                    if case .explicitYear(let year) = reference { return .explicitYear(year) }
                    return .currentSelection
                }())
            let resolution = ArchivistTemporalSubjectResolution.resolved(requested: name, subject: subject)
            let result: ArchivistTemporalResult
            switch reference {
            case .today:
                result = executePresentAge(single, subject: resolution, now: now)
            case .explicitYear:
                result = execute(single, subject: resolution, currentSelection: nil)
            case .selection(let selection):
                result = execute(single, subject: resolution, currentSelection: selection)
            }
            if case .today = reference {
                // The present-tense path already phrases death correctly
                // ("Dad passed on in 1977 at 41").
                verdicts.append((name, .other(prose: result.prose)))
                continue
            }
            if let value = result.value {
                let text: String
                switch value {
                case .exactAge(let age): text = "\(age)"
                case .approximateAge(let age): text = "about \(age)"
                case .ageRange(let range):
                    text = range.lowerBound == range.upperBound
                        ? "\(range.upperBound)" : "\(range.lowerBound) or \(range.upperBound)"
                case .group: text = ""
                }
                // Passed on before the reference: the age is a would-have-been.
                var deathYear: Int?
                if let rawDeath = subject.deathdate, let deathDay = canonicalDay(rawDeath) {
                    let year = calendar.component(.year, from: deathDay)
                    let after: Bool
                    if precision == .year || referenceDay == nil {
                        after = referenceYear > year
                    } else if let referenceDay {
                        after = referenceDay > deathDay
                    } else {
                        after = false
                    }
                    if after { deathYear = year }
                }
                verdicts.append((name, .age(
                    text: text,
                    wouldHaveBeen: deathYear != nil || ask == .wouldHaveBeen,
                    deathYear: deathYear)))
            } else if result.decline == .referenceBeforeBirth {
                verdicts.append((name, .notYetBorn(birthYear: birthYear)))
            } else {
                verdicts.append((name, .other(prose: result.prose)))
            }
        }

        let prose = ask == .bornYet
            ? bornYetProse(verdicts, subjects: subjects, phrase: phrase, byLabel: byLabel, precision: precision)
            : ageProse(verdicts, subjects: subjects, leadIn: leadIn, isToday: { if case .today = reference { return true }; return false }())
        let answered = verdicts.filter {
            switch $0.verdict {
            case .noBirthdate, .other: return false
            case .age, .notYetBorn, .bornThatPeriod, .wasBorn: return true
            }
        }.count
        // The caller prefixes how the people were found ("'the boys' =
        // Dan, Mark (children of Rick) …"); this line carries the facts.
        let basis = "Basis: People profile birthdates "
            + birthLines.joined(separator: ", ") + "; " + referenceBasisText + "."
        return ArchivistTemporalResult(
            value: answered > 0 ? .group(answered: answered, of: subjects.count) : nil,
            decline: answered > 0 ? nil : .missingBirthdate,
            prose: prose, basisLine: basis, evidence: nil)
    }

    /// "In 1994 Dan was 9 or 10 and Mark 7 or 8. Matt and Timmy weren't
    /// born yet (Matt was born in 1996, Timmy in 1999)."
    private static func ageProse(
        _ verdicts: [(name: String, verdict: GroupVerdict)],
        subjects: [ArchivistTemporalSubjectSnapshot],
        leadIn: String,
        isToday: Bool
    ) -> String {
        var sentences: [String] = []
        var agedClauses: [String] = []
        var wouldHaveBeen: [String] = []
        var notYet: [(String, Int)] = []
        var thatPeriod: [(String, Int)] = []
        var others: [String] = []
        let pronoun: (String) -> String = { name in
            switch subjects.first(where: { $0.canonicalName == name })?.sex {
            case .male?: return "he"
            case .female?: return "she"
            case nil: return "they"
            }
        }
        for (name, verdict) in verdicts {
            switch verdict {
            case .age(let text, let would, let deathYear):
                if let deathYear {
                    let year = leadIn.split(separator: " ").last.map(String.init) ?? ""
                    wouldHaveBeen.append("\(name) would have been \(text) in \(year) — \(pronoun(name)) passed on in \(deathYear).")
                } else if would {
                    agedClauses.append(agedClauses.isEmpty ? "\(name) would have been \(text)" : "\(name) \(text)")
                } else {
                    agedClauses.append(agedClauses.isEmpty ? "\(name) was \(text)" : "\(name) \(text)")
                }
            case .notYetBorn(let year): notYet.append((name, year))
            case .bornThatPeriod(let year): thatPeriod.append((name, year))
            case .wasBorn: break
            case .noBirthdate: others.append("I don't have a birthdate for \(name).")
            case .other(let prose): others.append(prose)
            }
        }
        if !agedClauses.isEmpty {
            sentences.append((isToday ? "" : leadIn + " ") + joinClauses(agedClauses) + ".")
        }
        sentences.append(contentsOf: wouldHaveBeen)
        if !notYet.isEmpty {
            let names = joinNames(notYet.map(\.0))
            let born = notYet.enumerated().map { index, entry in
                index == 0 ? "\(entry.0) was born in \(entry.1)" : "\(entry.0) in \(entry.1)"
            }.joined(separator: ", ")
            sentences.append("\(names) \(notYet.count == 1 ? "wasn't" : "weren't") born yet (\(born)).")
        }
        for (name, year) in thatPeriod {
            sentences.append("\(name) was born that year (\(year)), so it depends on the month.")
        }
        sentences.append(contentsOf: others)
        return sentences.joined(separator: " ")
    }

    /// "Dan and Mark were born by 1994; Matt and Timmy were not (Matt was
    /// born in 1996, Timmy in 1999)." / "Yes — all four of them (…) were
    /// born by 1994." / "No — none of the boys were born yet in 1994."
    private static func bornYetProse(
        _ verdicts: [(name: String, verdict: GroupVerdict)],
        subjects: [ArchivistTemporalSubjectSnapshot],
        phrase: String,
        byLabel: String,
        precision: RecordDateResolution.Precision
    ) -> String {
        var yes: [String] = []
        var no: [(String, Int)] = []
        var thatPeriod: [(String, Int)] = []
        var others: [String] = []
        for (name, verdict) in verdicts {
            switch verdict {
            case .wasBorn: yes.append(name)
            case .notYetBorn(let year): no.append((name, year))
            case .bornThatPeriod(let year): thatPeriod.append((name, year))
            case .noBirthdate: others.append("I don't have a birthdate for \(name).")
            case .other(let prose): others.append(prose)
            case .age: break
            }
        }
        let known = yes.count + no.count + thatPeriod.count
        var sentences: [String] = []
        let bornList = no.enumerated().map { index, entry in
            index == 0 ? "\(entry.0) was born in \(entry.1)" : "\(entry.0) in \(entry.1)"
        }.joined(separator: ", ")
        if known > 0 {
            if no.isEmpty, thatPeriod.isEmpty {
                sentences.append(yes.count == 1
                    ? "Yes — \(yes[0]) was born \(byLabel)."
                    : "Yes — \(yes.count == 2 ? "both" : "all \(countWord(yes.count))") of them (\(joinNames(yes))) were born \(byLabel).")
            } else if yes.isEmpty, thatPeriod.isEmpty {
                sentences.append(no.count == 1
                    ? "No — \(no[0].0) wasn't born yet (born \(no[0].1))."
                    : "No — none of \(phrase) were born yet (\(bornList)).")
            } else {
                var parts: [String] = []
                if !yes.isEmpty {
                    parts.append("\(joinNames(yes)) \(yes.count == 1 ? "was" : "were") born \(byLabel)")
                }
                if !no.isEmpty {
                    parts.append("\(joinNames(no.map(\.0))) \(no.count == 1 ? "was" : "were") not (\(bornList))")
                }
                sentences.append(parts.joined(separator: "; ") + ".")
            }
            for (name, year) in thatPeriod {
                sentences.append(precision == .year
                    ? "\(name) was born during \(year) itself, so it depends on the month — the record is dated to the year only."
                    : "\(name) was born that same month (\(year)), so it depends on the day.")
            }
        }
        sentences.append(contentsOf: others)
        return sentences.joined(separator: " ")
    }

    private static func joinClauses(_ clauses: [String]) -> String {
        guard clauses.count > 1 else { return clauses.first ?? "" }
        return clauses.dropLast().joined(separator: ", ") + " and " + clauses[clauses.count - 1]
    }

    static func joinNames(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }

    private static func countWord(_ count: Int) -> String {
        let words = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
        return count < words.count ? words[count] : "\(count)"
    }
}
