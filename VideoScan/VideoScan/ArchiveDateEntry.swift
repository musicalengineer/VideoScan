// ArchiveDateEntry.swift
// Typing a date at promote time (Rick, 2026-08-31): "the archive helper
// should ask for estimated date if it is suspicious and I can type in an
// estimate rather than going in without a date."
//
// WHY IT MATTERS MORE THAN IT LOOKS. The archive encodes the date in the
// FILENAME and the FOLDER, the manifest is opened O_APPEND and is genuinely
// append-only, and the app has neither a refile nor an un-promote. So a
// promotion is one-way and its date is permanent. The promote sheet
// currently reassures the reader that "you can refile later once the date
// is known" — which is not true today. Asking at the door is the cheap fix;
// gated correction is the expensive one.
//
// DELIBERATELY FORGIVING. Rick is typing what he knows, which is usually a
// year and sometimes a guess. "1947", "March 1947", "1947-03-12" and
// "1940s" are all things a person types; refusing them on syntax teaches
// the reader to skip the field, which puts the file in Undated/ forever.
//
// It never INVENTS precision. "1947" stays a year — it does not become
// 1 January 1947 — because the filename shape (1947-xx-xx) is how the
// archive tells "we know the year" from "we know the day".

import Foundation
import VideoScanCore

enum ArchiveDateEntry {

    struct Parsed: Equatable {
        let hint: ArchiveDateHint
        /// Rendered back for the reader, so they can see what the archive
        /// understood before committing: "1947-03-xx".
        var preview: String { hint.filenamePrefix }
    }

    /// Anything older is a typo, not a home movie. Film is c.1890 at the
    /// very earliest and this is a family archive, not a museum.
    static let earliestPlausibleYear = 1850

    /// Parse what a person typed. Nil when nothing usable is in there —
    /// the caller keeps the resolved hint rather than guessing.
    static func parse(_ raw: String, today: Date = Date()) -> Parsed? {
        let text = normalizeSeparators(
            raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        guard !text.isEmpty else { return nil }

        let thisYear = Calendar(identifier: .gregorian).component(.year, from: today)

        // Ordered: each form is tried in turn and the FIRST that matches
        // the whole string wins. A nil from a matching form means the
        // shape was right but the values were not (31 February), which is
        // a refusal, not a reason to try the next form — so each parser
        // returns .noMatch and .invalid distinctly.
        let parsers = [decade, isoNumeric, monthFirst, dayFirst]
        for parse in parsers {
            switch parse(text, thisYear) {
            case .noMatch:            continue
            case .invalid:            return nil
            case .parsed(let hint):   return Parsed(hint: hint)
            }
        }
        return nil
    }

    /// What one date form made of the input.
    private enum FormResult {
        /// This form does not describe the input at all — try the next.
        case noMatch
        /// This form matched, but the values are impossible. Stop: trying
        /// another form on "february 31 1992" can only produce nonsense.
        case invalid
        case parsed(ArchiveDateHint)
    }

    /// "12-mar-1900" — the unambiguous clinical form Rick types out of
    /// habit from safety-critical medical work, and the one form no locale
    /// can misread. When a month NAME is present, hyphens, dots and
    /// slashes are just separators, so flatten them to spaces and let the
    /// named-month forms do the work.
    ///
    /// Guarded on a letter being present: "1947-03-12" is ISO and must
    /// keep its own branch, and flattening it would break that. "1940s"
    /// has a letter but no separator, so this is a no-op there.
    private static func normalizeSeparators(_ text: String) -> String {
        guard text.contains(where: { $0.isLetter }) else { return text }
        return text.replacing(/[-–—._\/]+/, with: " ")
                   .replacing(/\s+/, with: " ")
                   .trimmingCharacters(in: .whitespaces)
    }

    /// "1940s" / "1940's" — filed at the decade root rather than
    /// inventing a year.
    private static func decade(_ text: String, _ thisYear: Int) -> FormResult {
        guard let m = text.firstMatch(of: /^(\d{4})\s*'?s$/) else { return .noMatch }
        guard let y = Int(m.1), plausible(y, thisYear), y % 10 == 0 else { return .invalid }
        return .parsed(.decade(startYear: y))
    }

    /// 1947, 1947-03, 1947-03-12. Slashes and dots too, because people
    /// type 1947/03/12.
    private static func isoNumeric(_ text: String, _ thisYear: Int) -> FormResult {
        guard let m = text.firstMatch(
            of: /^(\d{4})(?:[-\/.](\d{1,2})(?:[-\/.](\d{1,2}))?)?$/) else { return .noMatch }
        guard let y = Int(m.1), plausible(y, thisYear) else { return .invalid }
        guard let mo = m.2.flatMap({ Int($0) }) else { return .parsed(.year(y)) }
        guard (1...12).contains(mo) else { return .invalid }
        guard let d = m.3.flatMap({ Int($0) }) else { return .parsed(.month(year: y, month: mo)) }
        guard validDay(d, month: mo, year: y) else { return .invalid }
        return .parsed(.day(year: y, month: mo, day: d))
    }

    /// "July 15 1992" / "July 15, 1992" — the American order, which is
    /// what Rick will actually type. Tried before the day-first form: the
    /// two differ only by position, and a month NAME cannot be a day
    /// number, so there is no 03/07 ambiguity to resolve.
    private static func monthFirst(_ text: String, _ thisYear: Int) -> FormResult {
        guard let m = text.firstMatch(
            of: /^([a-z]{3,9})\s+(\d{1,2}),?\s+(\d{4})$/) else { return .noMatch }
        guard let y = Int(m.3), plausible(y, thisYear),
              let mo = monthNumber(String(m.1)),
              let d = Int(m.2), validDay(d, month: mo, year: y) else { return .invalid }
        return .parsed(.day(year: y, month: mo, day: d))
    }

    /// "March 1947" / "Mar 1947" / "12 March 1947" — how people actually
    /// write a half-remembered date.
    private static func dayFirst(_ text: String, _ thisYear: Int) -> FormResult {
        guard let m = text.firstMatch(
            of: /^(?:(\d{1,2})\s+)?([a-z]{3,9})\s+(\d{4})$/) else { return .noMatch }
        guard let y = Int(m.3), plausible(y, thisYear),
              let mo = monthNumber(String(m.2)) else { return .invalid }
        guard let dayText = m.1, let d = Int(dayText) else {
            return .parsed(.month(year: y, month: mo))
        }
        guard validDay(d, month: mo, year: y) else { return .invalid }
        return .parsed(.day(year: y, month: mo, day: d))
    }

    private static func plausible(_ year: Int, _ thisYear: Int) -> Bool {
        year >= earliestPlausibleYear && year <= thisYear
    }

    private static func validDay(_ day: Int, month: Int, year: Int) -> Bool {
        guard day >= 1 else { return false }
        var c = DateComponents(); c.year = year; c.month = month
        let cal = Calendar(identifier: .gregorian)
        guard let date = cal.date(from: c),
              let range = cal.range(of: .day, in: .month, for: date) else { return false }
        return day <= range.count
    }

    private static let months = [
        "jan": 1, "january": 1, "feb": 2, "february": 2, "mar": 3, "march": 3,
        "apr": 4, "april": 4, "may": 5, "jun": 6, "june": 6, "jul": 7, "july": 7,
        "aug": 8, "august": 8, "sep": 9, "sept": 9, "september": 9,
        "oct": 10, "october": 10, "nov": 11, "november": 11, "dec": 12, "december": 12,
    ]

    private static func monthNumber(_ name: String) -> Int? { months[name] }

    /// What to say under the field. Reassurance is dangerous here — the
    /// sheet used to promise a refile that does not exist — so this says
    /// plainly that the choice is permanent.
    static func guidance(for parsed: Parsed?, typed: String) -> String {
        if typed.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Leave blank to file under Undated/. The date becomes part of the path and cannot be changed later."
        }
        guard let parsed else {
            return "Not understood. Try 1947, March 1947, 1947-03, or 1940s."
        }
        return "Files as \(parsed.preview) — permanent once promoted."
    }
}
