// HallieAggregateFallback.swift
// GH #182 (live 2026-09-11): six questions in one session were routed to
// the co-occurrence lane with an anchor the lane could not resolve
// ("rick", "rick breen", "breen"), and each one dead-ended on "I couldn't
// resolve the anchor". The lane's identity catalog admits People-tab
// profiles only, by exact alias. This decides, purely over what the
// executor already knows, where such a turn goes INSTEAD of a decline:
//   • the anchor is a known person (People / CyberBrain / tree / owner)
//     → a catalog presence search for that person plus the question's
//       remaining words as keywords ("show rick playing guitar");
//   • the anchor is a surname the tree knows → the surname family tree;
//   • otherwise → the honest decline, unchanged.

import Foundation

enum HallieAggregateFallback {
    enum Route: Equatable, Sendable {
        case presence(people: [String], keywords: [String], wantsVideo: Bool)
        case surnameTree(surname: String)
        case decline
    }

    private static let mediaWords: Set<String> = ["video", "videos", "clip", "clips", "footage", "film", "films", "movie", "movies"]
    private static let stopWords: Set<String> = [
        "show", "me", "us", "find", "play", "get", "watch", "see", "please", "hallie", "the", "a", "an", "some", "any",
        "of", "for", "with", "and", "or", "to", "in", "on", "at", "about", "what", "who", "which", "are", "is", "was",
        "were", "there", "any", "all", "names", "name", "list", "give", "tell", "identify", "family", "together",
    ]

    /// The question's content words once the anchors, lead verbs and
    /// stop words are gone — the keywords a presence search should carry.
    static func keywords(question: String, anchors: [String]) -> (keywords: [String], wantsVideo: Bool) {
        var text = question.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        for anchor in anchors.sorted(by: { $0.count > $1.count }) {
            let a = anchor.lowercased()
            text = text.replacingOccurrences(of: a + "'s", with: " ")
            text = text.replacingOccurrences(of: a, with: " ")
        }
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let wantsVideo = words.contains { mediaWords.contains($0) }
        let keywords = words.filter { !stopWords.contains($0) && !mediaWords.contains($0) && $0.count > 1 }
        return (Array(keywords.prefix(6)), wantsVideo)
    }

    /// `unresolved` = anchors the aggregate catalog could not resolve;
    /// `isKnownPerson` / `isKnownSurname` are the executor's oracles.
    static func route(question: String, anchors: [String], unresolved: [String],
                      isKnownPerson: (String) -> Bool, isKnownSurname: (String) -> Bool) -> Route {
        guard !unresolved.isEmpty else { return .decline }
        if unresolved.allSatisfy(isKnownPerson) {
            let k = keywords(question: question, anchors: anchors)
            return .presence(people: anchors, keywords: k.keywords, wantsVideo: k.wantsVideo)
        }
        if unresolved.count == 1, anchors.count == 1, isKnownSurname(unresolved[0]) {
            return .surnameTree(surname: unresolved[0].lowercased())
        }
        return .decline
    }
}
