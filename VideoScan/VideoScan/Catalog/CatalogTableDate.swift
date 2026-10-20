// CatalogTableDate.swift
// The Catalog table's ONE date format (Rick 2026-10-20): `25-Dec-1995`.
//
// Day, 3-letter English month, 4-digit year, no time — on file rows and
// folder rows alike, and in the folder inspector's Dates row. A partial
// date keeps its precision and never gains an invented day:
//
//   "1995-12-25"           → "25-Dec-1995"
//   "1995-12"              → "Dec-1995"
//   "1995"                 → "1995"
//   "2003–2004"            → "2003–2004"          (a year span, unchanged)
//   "1995-12 (est.)"       → "Dec-1995 (est.)"
//   "2023-11-14 10:22:33"  → "14-Nov-2023"        (the time moves to the tooltip)
//   two days on a folder   → "25-Dec-1995 – 01-Jan-1996"
//
// DISPLAY ONLY. The stored dates, the CSV export, the logs and every other
// tab keep their own spellings; `VideoRecord.resolvedDateDisplay` (Core)
// is unchanged — this reads its reduced-ISO output and respells it. A
// string this does not recognise is shown exactly as given: never hide
// data behind a formatter.
//
// Time zone: UTC. The table's dates are CALENDAR DAYS, not instants —
// hand-entered and filed dates are UTC midnight (`UserDateEntry.date`),
// embedded stamps are already shown as their UTC day by Core. Formatting
// UTC midnight in Massachusetts local time would print the day before.
//
// Cost: one DateFormatter, built once (ICU setup is the expensive part —
// like holding one std::locale instead of constructing one per call). A
// cell costs a few string slices and at most one `string(from:)` — O(1),
// visible rows only, no allocation per record beyond the result.

import Foundation
import VideoScanCore

enum CatalogTableDate {

    /// The one formatter. DateFormatter is Sendable in this SDK and Apple
    /// documents it thread-safe for formatting (macOS 10.9+) as long as
    /// nobody mutates it — and nothing does after this initialiser. The
    /// folder join reads it off the main actor.
    /// (≈ a C++ `static const` object shared by every thread: safe because
    /// it is never written after construction.)
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC") ?? .current
        f.dateFormat = "dd-MMM-yyyy"
        return f
    }()

    /// " – " — a span's separator, the en dash the folder rows always used.
    static let rangeSeparator = " \u{2013} "

    /// The suffix Core puts on a best-guess date.
    static let estimatedSuffix = " (est.)"

    /// What a Date cell shows, and — only when the source carried a time
    /// of day — the full date and time for its tooltip.
    struct Cell: Equatable {
        let text: String
        let dateAndTime: String?
    }

    // MARK: - Dates as values (folder rows, the folder inspector)

    /// "25-Dec-1995".
    static func day(_ date: Date) -> String {
        formatter.string(from: date)
    }

    /// "25-Dec-1995" for one day; "25-Dec-1995 – 01-Jan-1996" for a span,
    /// whichever order the two days come in.
    static func range(_ a: Date, _ b: Date) -> String {
        let from = day(min(a, b))
        let to = day(max(a, b))
        return from == to ? from : from + rangeSeparator + to
    }

    // MARK: - Dates as Core's display strings (file rows)

    /// Respell `VideoRecord.resolvedDateDisplay` for the table. Empty stays
    /// empty (the cell shows "—"); anything unrecognised comes back as is.
    static func cell(forResolved resolved: String) -> Cell {
        let estimated = resolved.hasSuffix(estimatedSuffix)
        let suffix = estimated ? estimatedSuffix : ""
        let body = estimated ? String(resolved.dropLast(estimatedSuffix.count)) : resolved
        let (datePart, time) = splitTimeOfDay(body)
        guard let shown = reducedISO(datePart) else { return Cell(text: resolved, dateAndTime: nil) }
        return Cell(text: shown + suffix, dateAndTime: time.map { "\(shown) \($0)" })
    }

    /// A canonical reduced-ISO date ("1995" / "1995-12" / "1995-12-25") in
    /// the table's spelling at the SAME precision; nil when it is not one.
    static func reducedISO(_ canonical: String) -> String? {
        guard let (year, month, dayOfMonth) = UserDateEntry.components(of: canonical) else { return nil }
        guard let month else { return String(year) }
        guard dayOfMonth != nil, let date = UserDateEntry.date(from: canonical) else {
            return "\(formatter.shortMonthSymbols[month - 1])-\(year)"
        }
        return day(date)
    }

    /// "2023-11-14 10:22:33" → ("2023-11-14", "10:22:33"); a string with
    /// no time after a 10-character day comes back whole with nil.
    /// (`Substring` ≈ a std::string_view into the original — no copy until
    /// `String(...)`.)
    static func splitTimeOfDay(_ text: String) -> (date: String, time: String?) {
        let dayLength = 10   // "yyyy-MM-dd"
        guard text.count > dayLength + 1 else { return (text, nil) }
        let datePart = text.prefix(dayLength)
        let rest = text.dropFirst(dayLength)
        guard let separator = rest.first, separator == " " || separator == "T" else { return (text, nil) }
        let time = rest.dropFirst().trimmingCharacters(in: .whitespaces)
        return (String(datePart), time.isEmpty ? nil : time)
    }
}
