// HallieMediaActivityAsk.swift
// GH #182 (live 2026-09-11): "show rick playing guitar" and "show rick
// breen playing guitar video" were sent to the co-occurrence lane and
// dead-ended on "could not resolve anchor". A media ask about a KNOWN
// person doing something is a catalog presence search: person + the
// remaining words as keywords, video when the sentence says so. Pure
// over the text plus an `isKnownPerson` oracle; the caller dispatches.
//
// Deliberately narrow: a lead verb, a known name of 1–3 words, then a
// short remainder that reads as an activity or a place (a gerund, or a
// preposition phrase). No possessives ("rick's biography source" is a
// provenance follow-up), no "videos of X" (the lineage detector owns it),
// no bare "show me rick" (no remainder → not this shape).

import Foundation

enum HallieMediaActivityAsk {
    struct Ask: Equatable, Sendable {
        let person: String
        let keywords: [String]
        let wantsVideo: Bool
    }

    private static let leads = ["show me", "show us", "show", "find me", "find", "play me", "play",
                                "pull up", "get me", "get", "watch", "see", "look for", "search for"]
    private static let mediaWords: Set<String> = ["video", "videos", "clip", "clips", "footage", "film", "films", "movie", "movies"]
    private static let stopWords: Set<String> = ["a", "an", "the", "some", "any", "of", "please", "hallie", "me", "us"]
    private static let prepositions: Set<String> = ["at", "in", "on", "with", "during", "near", "by"]

    static func detect(_ text: String, isKnownPerson: (String) -> Bool) -> Ask? {
        var lower = text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while lower.hasSuffix("?") || lower.hasSuffix(".") || lower.hasSuffix("!") { lower.removeLast() }
        guard let lead = leads.first(where: { lower.hasPrefix($0 + " ") }) else { return nil }
        var words = lower.dropFirst(lead.count).split(separator: " ").map(String.init)
        while let first = words.first, ["a", "an", "the", "some", "any"].contains(first) { words.removeFirst() }
        guard words.count >= 2, words.count <= 9 else { return nil }
        // Possessives and "of" phrases are other shapes; two people joined
        // by "and" are a search the translator owns.
        guard !words.contains(where: { $0.hasSuffix("'s") || $0 == "of" || $0 == "and" || $0 == "&" }) else { return nil }
        // Longest known name first (3, 2, 1 words); the remainder must be an activity.
        for n in stride(from: min(3, words.count - 1), through: 1, by: -1) {
            let name = words.prefix(n).joined(separator: " ")
            guard isKnownPerson(name) else { continue }
            var rest = Array(words.dropFirst(n))
            // "show rick with donna" names a second person: not this shape.
            if let w = rest.firstIndex(of: "with"), w + 1 < rest.count,
               isKnownPerson(rest[(w + 1)...].prefix(2).joined(separator: " ")) || isKnownPerson(rest[w + 1]) {
                return nil
            }
            let wantsVideo = rest.contains { mediaWords.contains($0) }
            rest = rest.filter { !mediaWords.contains($0) && !stopWords.contains($0) }
            guard !rest.isEmpty, rest.count <= 5 else { return nil }
            let activity = rest.contains { $0.hasSuffix("ing") && $0.count > 4 } || prepositions.contains(rest[0])
            guard activity else { return nil }
            let keywords = rest.filter { !prepositions.contains($0) }
            guard !keywords.isEmpty else { return nil }
            return Ask(person: HallieLineageQuestion.capitalizedName(name), keywords: keywords, wantsVideo: wantsVideo)
        }
        return nil
    }
}
