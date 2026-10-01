// TreeWalkDate.swift (VideoScanCore)
// A GEDCOM date as the tree walk's checks need it: a closed interval of
// MONTHS (months since year 0, so 1702-03 = 1702*12 + 2), with how precise
// the record was. Month granularity because two of Rick's checks are about
// months ("born more than nine months after the father's death").
//
// Everything a check says must be PROVEN by the interval, never by a
// qualifier-dropping year: "ABT 1700" is [1698-01, 1702-12], "BEF 1700" is
// (−∞, 1699-12], "AFT 1837" is [1838-01, +∞). A check fires only when the
// whole of both intervals agrees — the same rule as GedcomYearInterval
// (codex #721/#723), one level finer.
//
// Pure. (C++ readers: a value struct of two optional ints; nil = unbounded.)

import Foundation

public enum DatePrecision: String, Sendable, Codable, Equatable, CaseIterable {
    /// Day, month and year ("4 MAR 1959").
    case day
    /// Month and year ("MAR 1959").
    case month
    /// Year only ("1959").
    case year
    /// ABT / CAL / EST / INT: a window of ±2 years.
    case approximate
    /// BEF / AFT / BET … AND / FROM … TO: bounded on one or both sides.
    case bounded
}

public struct TreeWalkDate: Sendable, Equatable {
    /// Earliest possible month (nil = unbounded below).
    public let lowerMonth: Int?
    /// Latest possible month (nil = unbounded above).
    public let upperMonth: Int?
    public let precision: DatePrecision
    /// The year as written (first four-digit run).
    public let year: Int
    /// Day of month when recorded with day precision.
    public let day: Int?

    public init(lowerMonth: Int?, upperMonth: Int?, precision: DatePrecision, year: Int, day: Int? = nil) {
        self.lowerMonth = lowerMonth
        self.upperMonth = upperMonth
        self.precision = precision
        self.year = year
        self.day = day
    }

    static let monthNames = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN",
                             "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]

    /// Nil when the raw text carries no year.
    public static func parse(_ raw: String?) -> TreeWalkDate? {
        guard let raw, let interval = GedcomYearInterval.parse(raw), let year = interval.anchor else { return nil }
        switch interval.qualifier {
        case .exact:
            // "/" does not split a word, so a dual year stays whole
            // ("1930/31"): splitting on it made the "31" a day of the month
            // (generated-input F8). The day is the word next to the month —
            // before it as GEDCOM writes it ("4 MAR 1959"), or after it
            // ("MAR 4 1959") — never any other short number in the text.
            let words = raw.uppercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "/" }).map(String.init)
            if let mi = words.firstIndex(where: { monthNames.contains($0) }),
               let m = monthNames.firstIndex(of: words[mi]) {
                let month = year * 12 + m
                func dayWord(_ i: Int) -> Int? {
                    guard words.indices.contains(i), words[i].count <= 2, let d = Int(words[i]),
                          (1...31).contains(d) else { return nil }
                    return d
                }
                let day = dayWord(mi - 1) ?? dayWord(mi + 1)
                return TreeWalkDate(lowerMonth: month, upperMonth: month,
                                    precision: day == nil ? .month : .day, year: year, day: day)
            }
            return TreeWalkDate(lowerMonth: year * 12, upperMonth: year * 12 + 11, precision: .year, year: year)
        case .about, .calculated, .estimated:
            return TreeWalkDate(lowerMonth: interval.lower.map { $0 * 12 }, upperMonth: interval.upper.map { $0 * 12 + 11 },
                                precision: .approximate, year: year)
        case .before, .after, .between, .range:
            return TreeWalkDate(lowerMonth: interval.lower.map { $0 * 12 }, upperMonth: interval.upper.map { $0 * 12 + 11 },
                                precision: .bounded, year: year)
        }
    }

    /// Months by which `self` is PROVEN to start after `other` ends
    /// (self.lower − other.upper); nil when either side is unbounded.
    public func provenMonthsAfter(_ other: TreeWalkDate) -> Int? {
        guard let lo = lowerMonth, let hi = other.upperMonth else { return nil }
        return lo - hi
    }
}

/// Age at death as the two dates prove it: `minYears...maxYears`. Equal
/// ends = exact. Day-precise on both sides computes completed years.
public struct AgeAtDeath: Sendable, Codable, Equatable {
    public let minYears: Int
    public let maxYears: Int
    public var isExact: Bool { minYears == maxYears }

    public init(minYears: Int, maxYears: Int) {
        self.minYears = minYears
        self.maxYears = maxYears
    }

    /// "71", "about 70–71", nil when either date is unbounded.
    public var spoken: String {
        isExact ? "\(minYears)" : "\(minYears)–\(maxYears)"
    }

    public static func between(birth: TreeWalkDate?, death: TreeWalkDate?) -> AgeAtDeath? {
        guard let birth, let death,
              let bLo = birth.lowerMonth, let bHi = birth.upperMonth,
              let dLo = death.lowerMonth, let dHi = death.upperMonth else { return nil }
        if birth.precision == .day, death.precision == .day, let bd = birth.day, let dd = death.day {
            var months = dLo - bLo
            if dd < bd { months -= 1 }
            let years = Int((Double(months) / 12).rounded(.down))
            return AgeAtDeath(minYears: years, maxYears: years)
        }
        // Completed years: floor(months / 12). Shortest possible life is
        // dLo − bHi months (born as late, died as early as recorded).
        func completed(_ months: Int) -> Int { Int((Double(months) / 12).rounded(.down)) }
        var lo = completed(dLo - bHi)
        let hi = completed(dHi - bLo)
        // A birth and death in the same year, either year-only, make the
        // shortest life NEGATIVE ("1838"–"1838" spoke "-1–0"): nobody dies
        // before being born, so the floor is 0 (generated-input F7). Only
        // when the dates CAN agree — a death wholly before the birth is a
        // contradiction the tree-walk checks report, left as computed.
        if hi >= 0 { lo = max(lo, 0) }
        return AgeAtDeath(minYears: min(lo, hi), maxYears: max(lo, hi))
    }
}
