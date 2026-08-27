// GedcomYearInterval.swift
// What a GEDCOM date PROVES about a year, as a closed interval with
// optional open ends (codex #721/#723, 2026-08-26). `Person.deathYear`
// strips the qualifier — "AFT 1837" → 1837 — and a rule that compares
// bare integers then concludes "died 1837, before photography" for
// someone the record says died AFTER 1837. The interval keeps the
// qualifier's meaning as data so every date rule reasons about bounds,
// not a guessed point.
//
// Qualifier → interval (year precision):
//   "1837" / "4 MAR 1837"        → [1837, 1837]
//   "BEF 1838"                   → (−∞, 1837]   year-only: strictly before that year
//   "BEF 4 MAR 1838"             → (−∞, 1838]   a day/month is given: the same year is possible
//   "AFT 1837"                   → [1838, ∞)    year-only: strictly after
//   "AFT 4 MAR 1837"             → [1837, ∞)
//   "ABT / CAL / EST / INT 1700" → [1700−k, 1700+k], k = `approximateSlack`
//   "BET 1930 AND 1931"          → [1930, 1931]
//   "FROM 1900 TO 1910"          → [1900, 1910]; "FROM 1900" → [1900, ∞); "TO 1910" → (−∞, 1910]
//   no four-digit year            → nil (unknown)
//
// Why k = 2 for ABT/CAL/EST: the qualifiers mean "the record-keeper was
// not sure of the year". Genealogical practice (FamilySearch, Ancestry
// guidance) treats ABT as "within a year or two"; a calculated (CAL)
// year from an age at death is off by at most one when the birthday
// falls after the event; estimates (EST) are the loosest. Two years
// covers all three without pretending a guess is precise. It is a
// heuristic, in one place, documented here so a future reader can
// widen it deliberately.
//
// C++ readers: a plain immutable value type; `lower`/`upper` are
// `Optional<Int>` (std::optional) where nil means "unbounded on that
// side". `parse` is a static factory returning an optional — nil for
// "no year at all", never for "I couldn't read the qualifier" (an
// unreadable qualifier with a year degrades to exact, matching the old
// `year(in:)` behaviour).

import Foundation

public struct GedcomYearInterval: Sendable, Equatable, Hashable {

    public enum Qualifier: String, Sendable, Equatable, Hashable {
        case exact, before, after, about, calculated, estimated, between, range
    }

    /// Earliest possible year, or nil when unbounded below.
    public let lower: Int?
    /// Latest possible year, or nil when unbounded above.
    public let upper: Int?
    public let qualifier: Qualifier
    /// The year as written (first four-digit run) — for the spoken form.
    public let anchor: Int?

    /// Half-width of the ABT / CAL / EST / INT window (see header).
    public static let approximateSlack = 2

    public init(lower: Int?, upper: Int?, qualifier: Qualifier, anchor: Int? = nil) {
        self.lower = lower
        self.upper = upper
        self.qualifier = qualifier
        self.anchor = anchor ?? lower ?? upper
    }

    public static func exact(_ year: Int) -> GedcomYearInterval {
        GedcomYearInterval(lower: year, upper: year, qualifier: .exact, anchor: year)
    }

    /// True when the whole interval lies strictly before `year`.
    public func isEntirelyBefore(_ year: Int) -> Bool {
        guard let upper else { return false }
        return upper < year
    }

    /// True when the whole interval lies at or after `year`.
    public func isEntirelyAtOrAfter(_ year: Int) -> Bool {
        guard let lower else { return false }
        return lower >= year
    }

    /// Two intervals contradict when one ends before the other starts.
    public func endsBefore(_ other: GedcomYearInterval) -> Bool {
        guard let upper, let otherLower = other.lower else { return false }
        return upper < otherLower
    }

    /// "1737", "before 1800", "after 1837", "about 1700", "between 1700
    /// and 1710", "1700 or later", "1710 or earlier".
    public var spoken: String {
        switch (qualifier, lower, upper) {
        case (.exact, let y?, _): return "\(y)"
        case (.before, _, _): return "before \(anchor ?? upper ?? 0)"
        case (.after, _, _): return "after \(anchor ?? lower ?? 0)"
        case (.about, _, _), (.calculated, _, _), (.estimated, _, _):
            return "about \(anchor ?? lower ?? 0)"
        case (.between, let l?, let u?), (.range, let l?, let u?):
            return l == u ? "\(l)" : "between \(l) and \(u)"
        case (_, let l?, nil): return "\(l) or later"
        case (_, nil, let u?): return "\(u) or earlier"
        default: return "an unknown year"
        }
    }

    // MARK: - Parse

    /// Parse a raw GEDCOM DATE value. Case-insensitive; tolerates the
    /// calendar escape ("@#DJULIAN@ 1700") and trailing phrases.
    public static func parse(_ raw: String?) -> GedcomYearInterval? {
        guard let raw else { return nil }
        let text = raw.uppercased()
        // Split on the conjunctions first so each half is dated alone.
        if let (a, b) = pair(text, head: "BET", joiner: "AND") {
            guard let lo = yearAndPrecision(a)?.year, let hi = yearAndPrecision(b)?.year else {
                return single(text)
            }
            return GedcomYearInterval(lower: min(lo, hi), upper: max(lo, hi), qualifier: .between)
        }
        if let (a, b) = pair(text, head: "FROM", joiner: "TO") {
            let lo = yearAndPrecision(a)?.year
            let hi = yearAndPrecision(b)?.year
            switch (lo, hi) {
            case (let l?, let h?): return GedcomYearInterval(lower: min(l, h), upper: max(l, h), qualifier: .range)
            case (let l?, nil): return GedcomYearInterval(lower: l, upper: nil, qualifier: .range)
            case (nil, let h?): return GedcomYearInterval(lower: nil, upper: h, qualifier: .range)
            default: return nil
            }
        }
        return single(text)
    }

    private static func single(_ text: String) -> GedcomYearInterval? {
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let parsed = yearAndPrecision(text) else { return nil }
        let y = parsed.year
        let hasDayOrMonth = parsed.hasDayOrMonth
        // The qualifier is the first word that is not a calendar escape.
        let head = words.first(where: { !$0.hasPrefix("@#") }) ?? ""
        switch head {
        case "BEF", "BEFORE":
            return GedcomYearInterval(lower: nil, upper: hasDayOrMonth ? y : y - 1, qualifier: .before, anchor: y)
        case "AFT", "AFTER":
            return GedcomYearInterval(lower: hasDayOrMonth ? y : y + 1, upper: nil, qualifier: .after, anchor: y)
        case "ABT", "ABOUT":
            return GedcomYearInterval(lower: y - approximateSlack, upper: y + approximateSlack, qualifier: .about, anchor: y)
        case "CAL":
            return GedcomYearInterval(lower: y - approximateSlack, upper: y + approximateSlack, qualifier: .calculated, anchor: y)
        case "EST", "INT":
            return GedcomYearInterval(lower: y - approximateSlack, upper: y + approximateSlack, qualifier: .estimated, anchor: y)
        case "TO":
            return GedcomYearInterval(lower: nil, upper: y, qualifier: .range)
        case "FROM":
            return GedcomYearInterval(lower: y, upper: nil, qualifier: .range)
        default:
            return .exact(y)
        }
    }

    /// "BET a AND b" / "FROM a TO b" → (a-part, b-part). Nil when the
    /// text does not open with `head` or lacks the joiner.
    private static func pair(_ text: String, head: String, joiner: String) -> (String, String)? {
        let words = text.split(separator: " ").map(String.init).filter { !$0.hasPrefix("@#") }
        guard words.first == head, let j = words.firstIndex(of: joiner), j > 1 else { return nil }
        return (words[1..<j].joined(separator: " "), words[(j + 1)...].joined(separator: " "))
    }

    /// First four-digit run (the same rule as `GedcomFamilyGraph.year(in:)`)
    /// plus whether a day or month name accompanies it — "4 MAR 1838"
    /// and "MAR 1838" do, "1838" does not.
    private static func yearAndPrecision(_ text: String) -> (year: Int, hasDayOrMonth: Bool)? {
        guard let year = GedcomFamilyGraph.year(in: text) else { return nil }
        let months: Set<String> = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN",
                                   "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
        let tokens = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let hasMonth = tokens.contains { months.contains($0) }
        let hasDay = tokens.contains { $0.count <= 2 && Int($0) != nil }
        return (year, hasMonth || hasDay)
    }
}
