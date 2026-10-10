// HallieInventedPresenceYears.swift
// A year the question never said is not a constraint — presence lane.
// Demo probe 2026-10-09.

import Foundation

/// The temporal lane already drops a translator-invented year (live
/// 2026-09-21, "how old was dad breen when he passed?" → explicitYear 1994).
/// The presence lane did not: the 2026-10-09 visitor probe saw
/// "show me videos with <First>" arrive as person=<first> year=2025 and
/// "videos of <A> and <B> together" as year=2026 — the current year leaking
/// in — and Hallie answered "I don't see anything from 2025…".
///
/// Deliberately conservative: the years are dropped ONLY when the question
/// has no digit, no 'NN, no spelled year and no word that can carry a time
/// ("last", "this", "nineties", "baby", "young", "when", …). Anything that
/// might be the reader's own time stays exactly as the translator gave it.
///
/// C++ analogy: a caseless `enum` is a namespace of static functions.
enum HallieInventedPresenceYears {

    /// Words that can carry a time or an age, so a year range beside them
    /// may be the reader's own words rather than an invention.
    static let timeWords: Set<String> = [
        "year", "years", "yr", "yrs", "decade", "decades", "century", "centuries", "era",
        "ago", "last", "this", "next", "past", "recent", "recently", "lately", "latest",
        "newest", "oldest", "earliest", "today", "yesterday", "tonight", "now", "nowadays",
        "early", "late", "mid", "before", "after", "since", "until", "till", "between",
        "during", "when", "while", "then", "back",
        "young", "younger", "youngest", "old", "older", "little", "small", "grown",
        "baby", "babies", "toddler", "kid", "kids", "child", "children", "childhood",
        "teen", "teens", "teenager", "teenage", "grew", "growing", "born", "birth",
        "twenties", "thirties", "forties", "fifties", "sixties", "seventies",
        "eighties", "nineties", "aughts", "millennium",
        "nineteen", "twenty", "eighteen", "seventeen", "sixteen", "thousand",
    ]

    /// True when the question could have supplied a year or an age band.
    static func questionMentionsTime(_ question: String) -> Bool {
        let lowered = question.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        if lowered.contains(where: \.isNumber) { return true }
        let words = lowered.split(whereSeparator: { !$0.isLetter && $0 != "'" })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
        return words.contains { timeWords.contains($0) }
    }
}

extension HallieTurnExecutor {
    /// Drops a year range the question never mentions, on a FRESH
    /// translation only — a refinement or paging re-run carries the
    /// previous turn's years on purpose. Returns the basis note (0 or 1).
    static func dropInventedPresenceYears(
        _ effective: inout ArchivistQueryAST.Presence, request: Request
    ) -> [String] {
        let intent = request.intent
        let isReRun = intent.refinementNote != nil || intent.refinementChain != nil
            || intent.refinementChange != nil || intent.citationOffset > 0
        let question = intent.originalQuestion
        guard !isReRun, effective.yearStart != nil || effective.yearEnd != nil,
              !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !HallieInventedPresenceYears.questionMentionsTime(question) else { return [] }
        let span = [effective.yearStart, effective.yearEnd].compactMap { $0 }
            .map(String.init).joined(separator: "–")
        effective.yearStart = nil
        effective.yearEnd = nil
        return ["the translator supplied \(span), which the question never mentions, so it was ignored"]
    }
}
