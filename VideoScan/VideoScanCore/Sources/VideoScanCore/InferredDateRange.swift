// InferredDateRange.swift
// GH #201 (Rick 2026-09-26): an inferred date is a machine GUESSTIMATE
// that combines criteria; when the criteria only know the YEAR — or a
// tape that ran across a New Year ("2003–2004") — the honest answer is a
// span of years, not a fabricated "Jan 1". This is that span.
//
// Stored beside `VideoRecord.inferredRecordDate` (which keeps the point
// estimate every existing reader sorts and files by). ADDITIVE optional:
// legacy catalogs decode nil and round-trip byte-identical because the
// DTO writes the key only when present. nil on a record whose inferred
// date is day-precise (an on-screen burn-in, a camera stamp).
//
// (For Rick: a two-Int POD with a normalising constructor and a
// to-string; `Codable` is the compiler-written JSON serializer.)

import Foundation

public struct InferredDateRange: Codable, Equatable, Hashable, Sendable {
    public var startYear: Int
    public var endYear: Int

    /// Normalises the order so `startYear <= endYear` always holds.
    public init(startYear: Int, endYear: Int) {
        self.startYear = min(startYear, endYear)
        self.endYear = max(startYear, endYear)
    }

    public init(year: Int) {
        self.init(startYear: year, endYear: year)
    }

    public var isSingleYear: Bool { startYear == endYear }

    public func contains(_ year: Int) -> Bool { year >= startYear && year <= endYear }

    /// "2004" for a single year, "2003–2004" (en dash, the typographic
    /// range mark) for a span. Human surfaces only — never a storage key.
    public var displayString: String {
        isSingleYear ? String(startYear) : "\(startYear)–\(endYear)"
    }
}
