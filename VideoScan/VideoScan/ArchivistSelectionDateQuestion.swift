// ArchivistSelectionDateQuestion.swift
// "when was this filmed?" / "what year is that from?" / "how old is this
// tape?" / "how long ago was that?" / "what season was this filmed in?" —
// a question about the DATE of the selected video, not about a person.
// Before 2026-09-01 the translator turned every one of these into
// `temporal subject=this` and Hallie declined with "I need to know who you
// mean". This pure recogniser runs BEFORE translation, only when a Catalog
// row is selected, and answers from the record's resolved date
// (RecordDateResolver — the same ranking placement and ArchiveReadiness
// use) with wording that says how much of the date is real.
//
// Person-age questions ("how old was Timmy in this", "when was Donna
// born") are NOT this shape: every pattern requires the selection pronoun
// or a media noun to follow the verb directly, so a name in that slot
// falls through to the existing temporal path.
//
// (For Rick: an `enum` with no payload used as a namespace + a value —
// like a C++ `enum class` with static member functions beside it.)

import Foundation
import VideoScanCore

enum ArchivistSelectionDateQuestion: String, Sendable, Equatable, CaseIterable {
    /// "when was this filmed" / "what date is this" / "what month was that".
    case when
    /// "what year is that from" / "which decade is this".
    case year
    /// "how old is this tape".
    case age
    /// "how long ago was that".
    case howLongAgo
    /// "what season was this filmed in" / "what time of year is this".
    case season

    // MARK: - Recognition

    /// The selected video, as the sentence names it. "here" is deliberately
    /// absent: "how old is Donna here" is a person question.
    private static let referent =
        #"(?:this|that|it|the (?:tape|video|clip|footage|recording|film|movie|one|file|selected video|selection))"#
    /// Optional media noun after "this"/"that"/"the".
    private static let mediaNoun =
        #"(?: (?:tape|video|clip|footage|recording|film|movie|one|file|selected video|selection))?"#
    /// "hallie, " / "do you know " / "can you tell me " in front.
    private static let lead =
        #"^(?:hallie[, ]+)?(?:do you know |can you tell me |tell me |could you tell me |i wonder )?"#

    private static let patterns: [(ArchivistSelectionDateQuestion, NSRegularExpression)] = {
        func rx(_ body: String) -> NSRegularExpression {
            // Force-unwrap is deliberate: these are compile-time literals;
            // a bad one should fail the first test, not hide.
            try! NSRegularExpression(pattern: lead + body, options: [])
        }
        // "was this" / "is this" / "'s this" (the contraction has no space).
        let verb = #"(?: (?:was|is|were|did|does)|'s) "#
        return [
            // Order matters: "how long ago" before "how old", season/year
            // before the generic "when".
            (.howLongAgo, rx(#"how long ago\#(verb)\#(referent)\b"#)),
            // The whole remainder is pinned: "how old is that boy" must not
            // match (the tape is not the boy).
            (.age, rx(#"how old\#(verb)(?:this|that|it|the)\#(mediaNoun)(?: (?:from|now|then|anyway|hallie|of yours|in years))*[?.! ]*$"#)),
            (.season, rx(#"(?:what|which) (?:season|time of year)\#(verb)(?:it )?(?:in |from )?\#(referent)\b"#)),
            (.year, rx(#"(?:what|which) (?:year|decade)\#(verb)\#(referent)\b"#)),
            // "when was this filmed" and the inverted "when this was filmed".
            (.when, rx(#"(?:when|what date|what day|what month|which month)(?:\#(verb)\#(referent)\b| \#(referent) (?:was|is|were|got)\b)"#)),
        ]
    }()

    /// The ask, or nil when the sentence is not about the selection's date.
    static func detect(_ question: String) -> ArchivistSelectionDateQuestion? {
        let normalized = question.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !normalized.isEmpty else { return nil }
        let range = NSRange(normalized.startIndex..., in: normalized)
        for (ask, regex) in patterns
        where regex.firstMatch(in: normalized, options: [], range: range) != nil {
            return ask
        }
        return nil
    }

    // MARK: - Answer

    /// The deterministic answer for the selected record's date snapshot.
    /// `selection == nil` means the record has no date signal at all;
    /// the legacy filesystem stamps are answered honestly as "not a filming
    /// date". `now` is injected so the age/ago arithmetic is testable.
    static func answer(
        _ ask: ArchivistSelectionDateQuestion,
        selection: ArchivistTemporalSelectionDateSnapshot?,
        now: Date = Date()
    ) -> HallieTurnExecutor.Result {
        guard let selection else {
            return result(
                outcome: .declined, ask: ask,
                prose: undatedProse,
                basis: "Basis: the selected record has no resolvable date "
                    + "(RecordDateResolver: none; no filesystem stamp either).")
        }
        let parts = calendar.dateComponents([.year, .month], from: selection.date)
        guard let year = parts.year, let month = parts.month else {
            return result(
                outcome: .declined, ask: ask,
                prose: undatedProse,
                basis: "Basis: the selected record's date could not be read.")
        }
        let path = selection.fullPath

        // A filesystem stamp is when the file was written, which for every
        // transcode is the transcode date. Never present it as filming.
        if selection.isUnverifiedFallback {
            return result(
                outcome: .declined, ask: ask,
                prose: "I don't have a filming date for this one. The only stamp is "
                    + "\(selection.sourceLabel), \(longDay(selection.date)), and that "
                    + "may be when it was copied or transcoded, not when it was "
                    + "filmed. Set its date in the Catalog inspector and ask me again.",
                basis: "Basis: selected record \(path); no user date, embedded camera "
                    + "date, confident inference, or dated filename; "
                    + "\(selection.sourceLabel) \(iso(selection.date, .day)) is not "
                    + "recording-date evidence.")
        }

        let precision = selection.precision
        let period = periodPhrase(selection.date, precision: precision)   // "on 25 December 1994"
        let bare = barePeriod(selection.date, precision: precision)      // "25 December 1994"
        let fromFilename: String
        if case .resolved(_, _, _, .filename, _, _) = selection {
            fromFilename = " (from the filename)"
        } else {
            fromFilename = ""
        }
        var basis = "Basis: selected record \(path); date \(iso(selection.date, precision)) "
            + "from \(selection.sourceLabel) (\(ArchivistTemporalExecutor.precisionLabel(precision)) "
            + "precision"
        if case .resolved(_, _, _, _, _, let confidence) = selection {
            basis += String(format: ", confidence %.2f", confidence)
        } else if case .dossierInferred(_, _, _, let confidence) = selection {
            basis += ", low-confidence inference "
                + (confidence.map { String(format: "%.2f", $0) } ?? "unrecorded")
        }
        basis += ")."
        let lowConfidenceNote: String
        if case .dossierInferred = selection {
            lowConfidenceNote = " That is a low-confidence guess from the dossier — set the date in the Catalog inspector if you know it."
        } else {
            lowConfidenceNote = ""
        }

        let prose: String
        switch ask {
        case .when:
            prose = "This was filmed \(period)\(fromFilename).\(lowConfidenceNote)"

        case .year:
            switch precision {
            case .day, .month:
                prose = "This is from \(year) — filmed \(period).\(lowConfidenceNote)"
            default:
                prose = "This is from \(year)\(fromFilename).\(lowConfidenceNote)"
            }

        case .season:
            switch precision {
            case .day:
                prose = "This was filmed in \(season(month)), \(period)\(fromFilename).\(lowConfidenceNote)"
            case .month:
                prose = "This was filmed in \(season(month)), \(bare)\(fromFilename).\(lowConfidenceNote)"
            default:
                prose = "I only know the year — \(year)\(fromFilename) — so I can't say "
                    + "the season; the month isn't recorded. Set a fuller date in "
                    + "the Catalog inspector if you know it."
            }
            basis += " Season for the northern hemisphere."

        case .age:
            let years = elapsedYears(from: selection.date, precision: precision, now: now)
            prose = "About \(years) years old — filmed \(period)\(fromFilename).\(lowConfidenceNote)"
            basis += " Counted to \(iso(now, .day))."

        case .howLongAgo:
            let years = elapsedYears(from: selection.date, precision: precision, now: now)
            let inner = fromFilename.isEmpty ? "" : ", from the filename"
            prose = "About \(years) years ago (\(bare)\(inner)).\(lowConfidenceNote)"
            basis += " Counted to \(iso(now, .day))."
        }
        return result(outcome: .answered, ask: ask, prose: prose, basis: basis)
    }

    // MARK: - Wording helpers

    private static let undatedProse =
        "I don't have a date for the selected video — no date entered, no camera "
        + "date in the file, no confident inference, and nothing dated in the "
        + "filename. Set its date in the Catalog inspector and ask me again."

    /// Meteorological seasons, northern hemisphere (Rick is in the Berkshires).
    static func season(_ month: Int) -> String {
        switch month {
        case 12, 1, 2: return "winter"
        case 3, 4, 5: return "spring"
        case 6, 7, 8: return "summer"
        default: return "fall"
        }
    }

    /// Whole years elapsed. Day precision counts real birthdays-of-the-tape;
    /// coarser dates can only subtract years.
    static func elapsedYears(
        from date: Date, precision: RecordDateResolution.Precision, now: Date
    ) -> Int {
        if precision == .day,
           let years = calendar.dateComponents([.year], from: date, to: now).year {
            return max(0, years)
        }
        let then = calendar.component(.year, from: date)
        let today = calendar.component(.year, from: now)
        return max(0, today - then)
    }

    /// "on 25 December 1994" / "in December 1994" / "in 1994".
    static func periodPhrase(_ date: Date, precision: RecordDateResolution.Precision) -> String {
        switch precision {
        case .day: return "on \(barePeriod(date, precision: precision))"
        default: return "in \(barePeriod(date, precision: precision))"
        }
    }

    /// "25 December 1994" / "December 1994" / "1994".
    static func barePeriod(_ date: Date, precision: RecordDateResolution.Precision) -> String {
        switch precision {
        case .day: return longDay(date)
        case .month: return ArchivistTemporalExecutor.monthYearString(date)
        default: return String(calendar.component(.year, from: date))
        }
    }

    private static func iso(_ date: Date, _ precision: RecordDateResolution.Precision) -> String {
        ArchivistTemporalExecutor.periodString(date, precision: precision)
    }

    /// The house format, through the one formatter (`HallieDateStyle`).
    /// Unchanged output — this renderer was already right; it now shares
    /// the definition instead of restating it.
    private static func longDay(_ date: Date) -> String {
        HallieDateStyle.spoken(date, calendar: calendar)
    }

    private static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private static func result(
        outcome: HallieTurnExecutor.Outcome,
        ask: ArchivistSelectionDateQuestion,
        prose: String,
        basis: String
    ) -> HallieTurnExecutor.Result {
        HallieTurnExecutor.Result(
            route: .temporal,
            outcome: outcome,
            prose: prose,
            basisLine: basis,
            queryDescription: "shape=temporal operation=selectionDate ask=\(ask.rawValue)",
            citations: [],
            catalogPersonName: nil)
    }
}
