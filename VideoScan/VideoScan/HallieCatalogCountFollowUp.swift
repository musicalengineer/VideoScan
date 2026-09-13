// HallieCatalogCountFollowUp.swift
// The sticky count scope (design §3.5, eval cc001 → cc002 → cc003):
//   "how many videos do we have?"          → 18 (catalog-wide count)
//   "how many of those are from the 90s?"  → 8 catalog items from the 1990s
//   "and how many from the 80s"            → 6 catalog items from the 1980s
// Each follow-up re-runs the remembered scope with the NEW year range
// written over the old one — a decade replaces the previous decade, it
// never intersects with it (ListFields.yearStart/yearEnd are scalar; the
// same rule `applyCumulative` uses). Pure: memory in, intent out.

import Foundation

enum HallieCatalogCountFollowUp {
    typealias Exec = HallieTurnExecutor

    /// Count filler: the words that make "how many of those are from the
    /// 90s" a count of the remembered scope rather than content.
    private static let filler: Set<String> = [
        "how", "many", "much", "of", "those", "them", "these", "that", "are",
        "is", "were", "was", "there", "from", "in", "the", "and", "what",
        "about", "do", "we", "have", "has", "had", "videos", "video", "clips",
        "clip", "files", "file", "items", "item", "recordings", "recording",
        "count", "number", "total", "ones", "one", "it", "then", "so", "ok",
        "okay", "please", "hallie", "now", "also", "more", "were", "with",
        "got", "any", "made", "shot", "filmed", "taken", "recorded",
    ]

    /// The count re-run for this fragment, or nil when the turn is not a
    /// count follow-up (no scope in memory, or content beyond a year
    /// phrase — a person or a topic word is the refinement lane's).
    static func detect(_ question: String, memory: Exec.ConversationMemory) -> Exec.Intent? {
        guard let scope = memory.catalog.countScope else { return nil }
        let words = ArchivistFollowUpResolver.normalizedWords(question)
        guard !words.isEmpty, words.count <= 12 else { return nil }
        let content = words.filter { !filler.contains($0) }
        guard !content.isEmpty,
              let years = ArchivistFollowUpResolver.extractYears(from: content),
              years.remaining.isEmpty else { return nil }
        guard let ast = writing(years.range, into: scope.ast) else { return nil }
        // The chain carries the refinement lane's own year label ("1990–1999")
        // so the basis line reads exactly as a refinement of the last
        // question — which it is, done as a count; the prose gets the
        // spoken form ("from the 1990s").
        let chain = ArchivistFollowUpResolver.Chain(
            terms: ArchivistFollowUpResolver.Chain.base(for: scope.ast).terms,
            yearLabel: years.label)
        return Exec.Intent(
            originalQuestion: question,
            ast: ast,
            refinementNote: "refining: \(chain.description)",
            refinementChain: chain,
            refinementChange: "from \(Self.label(for: years.range))",
            countOnly: true)
    }

    /// "the 1980s" / "1994" / "1990–1995".
    static func label(for range: ClosedRange<Int>) -> String {
        let lower = range.lowerBound, upper = range.upperBound
        if lower == upper { return "\(lower)" }
        if lower % 10 == 0, upper == lower + 9 { return "the \(lower)s" }
        return "\(lower)–\(upper)"
    }

    /// The scope AST with the year range REPLACED. Only the list shapes
    /// carry years; anything else is not a count scope.
    static func writing(_ range: ClosedRange<Int>, into ast: ArchivistQueryAST) -> ArchivistQueryAST? {
        switch ast {
        case .presence(var p):
            p.yearStart = range.lowerBound; p.yearEnd = range.upperBound
            return .presence(p)
        case .cross(var p):
            p.yearStart = range.lowerBound; p.yearEnd = range.upperBound
            return .cross(p)
        case .event(var p):
            p.yearStart = range.lowerBound; p.yearEnd = range.upperBound
            return .event(p)
        default:
            return nil
        }
    }
}
