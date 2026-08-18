// ArchivistAgePhrase.swift
// "show timmy as a baby saying peekaboo" — the translator (correctly) has no
// birth dates, so it can only pass "as a baby" through as a keyword. Swift
// turns that keyword into a year band from the person's known birth year,
// deterministically and with the source cited. Pure; no model, no I/O.

import Foundation

enum ArchivistAgePhrase {
    enum Band: String, Sendable, Equatable, CaseIterable {
        case baby
        case child
        case teenager

        /// Offsets from the birth year, inclusive.
        var offsets: ClosedRange<Int> {
            switch self {
            case .baby: return 0...2
            case .child: return 3...12
            case .teenager: return 13...19
            }
        }

        var phrase: String {
            switch self {
            case .baby: return "as a baby"
            case .child: return "as a kid"
            case .teenager: return "as a teenager"
            }
        }
    }

    struct Detection: Sendable, Equatable {
        let band: Band
        /// The exact keyword that carried the age phrase (removed from the
        /// keyword AND so "baby" is not also demanded of the transcript).
        let keyword: String
    }

    private static let bandWords: [String: Band] = [
        "baby": .baby, "babies": .baby, "infant": .baby, "newborn": .baby,
        "toddler": .baby,
        "kid": .child, "kids": .child, "child": .child, "children": .child,
        "boy": .child, "girl": .child,
        "teenager": .teenager, "teen": .teenager, "teens": .teenager,
        "adolescent": .teenager,
    ]

    /// Words that carry no meaning in an age phrase ("as a baby", "when she
    /// was a little kid", "as a young teenager").
    private static let carriers: Set<String> = [
        "as", "a", "an", "when", "he", "she", "they", "was", "were", "little",
        "young", "still", "just", "the", "being",
    ]

    /// The band a single word names ("baby" → .baby), or nil. Lets the
    /// follow-up resolver spot "as a baby" inside a fragment.
    static func band(forWord word: String) -> Band? {
        bandWords[word]
    }

    /// Whether the word carries no meaning in an age phrase ("as", "a").
    static func isCarrier(_ word: String) -> Bool {
        carriers.contains(word)
    }

    /// The first keyword that is an age phrase and nothing else. A keyword
    /// with additional content ("baby shower") is a real topic and is left
    /// alone.
    static func detect(in keywords: [String]) -> Detection? {
        for keyword in keywords {
            let tokens = ArchivistKeywordText.tokens(keyword)
                .filter { !carriers.contains($0) }
            guard tokens.count == 1, let band = bandWords[tokens[0]] else {
                continue
            }
            return Detection(band: band, keyword: keyword)
        }
        return nil
    }

    /// The year band for a birth year, clamped to the AST's legal range.
    static func years(birthYear: Int, band: Band) -> ClosedRange<Int>? {
        let range = ArchivistQueryAST.yearRange
        let start = max(range.lowerBound, birthYear + band.offsets.lowerBound)
        let end = min(range.upperBound, birthYear + band.offsets.upperBound)
        guard start <= end else { return nil }
        return start...end
    }
}
