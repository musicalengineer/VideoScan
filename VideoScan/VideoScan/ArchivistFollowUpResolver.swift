// ArchivistFollowUpResolver.swift
// Pure, model-free resolution of conversational follow-ups against the LAST
// answer: "play one of them, say the first one", "show more", "and in the
// 90s?", "what about matt?". Rick's demo to Donna (2026-08-17) showed each of
// these being sent to the translator as a fresh question and declined with
// "no evidence". They are not new questions; they refer to what Hallie just
// said. Resolution happens BEFORE any translation and never widens the
// evidence set on its own — a media action acts only on citations already
// shown, a refinement edits the previous validated AST field by field.

import Foundation

enum ArchivistFollowUpResolver {

    /// The previous turn, projected to what follow-up resolution needs. The
    /// executor's `ConversationMemory` produces it; tests build it directly.
    struct Snapshot: Sendable, Equatable {
        struct Item: Sendable, Equatable {
            let filename: String
            let fullPath: String
            /// Years the citation was proven for (path/inferred/file dates).
            let years: [Int]
        }

        /// The last executed AST (nil when the last turn was not a query).
        let ast: ArchivistQueryAST?
        /// Citations as displayed, in order.
        let items: [Item]
        /// How many citations have been shown so far across pages.
        let shownCount: Int
        /// The exact match count of the last result set.
        let totalMatchCount: Int

        init(ast: ArchivistQueryAST?, items: [Item], shownCount: Int? = nil,
             totalMatchCount: Int? = nil) {
            self.ast = ast
            self.items = items
            self.shownCount = shownCount ?? items.count
            self.totalMatchCount = totalMatchCount ?? items.count
        }
    }

    enum MediaVerb: String, Sendable, Equatable {
        case play
        case reveal
        case show
    }

    /// Which AST field a refinement replaced, for the basis line.
    enum Replaced: Sendable, Equatable {
        case years(ClosedRange<Int>)
        case person(String)
        case keyword(String)

        var description: String {
            switch self {
            case .years(let range):
                return range.lowerBound == range.upperBound
                    ? "year → \(range.lowerBound)"
                    : "years → \(range.lowerBound)–\(range.upperBound)"
            case .person(let name): return "person → \(name)"
            case .keyword(let word): return "keyword → \(word)"
            }
        }
    }

    enum Resolution: Sendable, Equatable {
        /// Not a follow-up; translate the sentence as usual.
        case none
        /// Act on these 0-based indices of the last result set.
        case mediaAction(verb: MediaVerb, indices: [Int])
        /// "play <something new>": translate the remainder, then auto-play.
        case searchThenPlay(String)
        /// Next page of the same result set.
        case nextPage
        /// The previous AST with one field replaced.
        case refine(ArchivistQueryAST, replaced: Replaced)
        /// A sentence whose shape is unmistakable locally ("show Donna's
        /// family tree"): the AST is built here, no translation needed. Only
        /// used for the family-tree forms; everything else still translates.
        case localQuery(ArchivistQueryAST)
        /// Honest declines — each names why, so the answer can say it.
        case declineNoPriorResult(MediaVerb?)
        case declineOutOfRange(requested: Int, available: Int)
        case declineNoMatchingItem(String)
        case declineNothingMore(total: Int)
        case declineNotRefinable(reason: String)
    }

    // MARK: - Entry

    static func resolve(
        _ text: String,
        snapshot: Snapshot?,
        isKnownPerson: (String) -> Bool
    ) -> Resolution {
        let words = normalizedWords(text)
        guard !words.isEmpty else { return .none }

        if let paging = pagingResolution(words, snapshot: snapshot) {
            return paging
        }
        if let tree = familyTreeResolution(words) {
            return tree
        }
        if let media = mediaResolution(words, original: text, snapshot: snapshot) {
            return media
        }
        if let refinement = refinementResolution(
            words, snapshot: snapshot, isKnownPerson: isKnownPerson) {
            return refinement
        }
        return .none
    }

    // MARK: - Words

    private static let leadFiller: Set<String> = [
        "please", "hallie", "ok", "okay", "now", "just", "and", "then", "also",
        "so", "hey", "can", "could", "would", "you", "lets", "let's", "go",
        "ahead", "kindly", "um", "uh", "well", "yes", "yeah",
    ]

    static func normalizedWords(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "#", with: "number ")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map { String($0) }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
    }

    private static func dropLead(_ words: [String]) -> [String] {
        Array(words.drop { leadFiller.contains($0) })
    }

    // MARK: - Paging

    private static let pagingPhrases: Set<String> = [
        "more", "show more", "show me more", "more please", "next",
        "next page", "next ones", "the next ones", "rest", "the rest",
        "show the rest", "show me the rest", "any more", "anymore",
        "what else", "others", "the others", "show others", "keep going",
        "continue", "go on", "and the rest", "more of them", "show more of them",
        "the next page", "next batch", "another page", "give me more",
    ]

    private static func pagingResolution(
        _ words: [String], snapshot: Snapshot?
    ) -> Resolution? {
        let phrase = dropLead(words).joined(separator: " ")
        let full = words.joined(separator: " ")
        guard pagingPhrases.contains(phrase) || pagingPhrases.contains(full)
        else { return nil }
        guard let snapshot, snapshot.totalMatchCount > 0 || !snapshot.items.isEmpty
        else { return .declineNoPriorResult(nil) }
        guard let ast = snapshot.ast, isPageable(ast) else {
            return .declineNotRefinable(
                reason: "that answer isn't a list I can page through")
        }
        guard snapshot.shownCount < snapshot.totalMatchCount else {
            return .declineNothingMore(total: snapshot.totalMatchCount)
        }
        return .nextPage
    }

    static func isPageable(_ ast: ArchivistQueryAST) -> Bool {
        switch ast {
        case .presence, .cross: return true
        default: return false
        }
    }

    // MARK: - Family tree (local shape)

    private static let treeVerbs: Set<String> = [
        "show", "get", "open", "display", "see", "view", "pull", "bring",
        "give", "draw", "print", "look", "let", "lets", "let's", "up", "at",
    ]
    private static let treeFiller: Set<String> = [
        "me", "us", "the", "a", "our", "my", "your", "please", "hallie",
        "whole", "entire", "full", "complete", "family's",
    ]

    /// "show donna's family tree" / "get me the family tree for the breens" /
    /// "show family tree" → a `graph familyTree` AST built locally. Any extra
    /// content word ("videos", "who is in") means it is not this shape.
    private static func familyTreeResolution(_ rawWords: [String]) -> Resolution? {
        let words = dropLead(rawWords)
        let joined = words.joined(separator: " ")
        let treePhrases = ["family tree", "ancestry", "lineage", "pedigree",
                           "family history", "genealogy", "ancestors", "descendants"]
        guard let phrase = treePhrases.first(where: { joined.contains($0) }) else {
            return nil
        }
        let phraseWords = phrase.split(separator: " ").map(String.init)
        guard let start = words.indices.first(where: { index in
            Array(words[index..<min(words.count, index + phraseWords.count)]) == phraseWords
        }) else { return nil }
        let before = Array(words[..<start]).filter { !treeVerbs.contains($0) && !treeFiller.contains($0) }
        let after = Array(words[(start + phraseWords.count)...])
        // Only a name may precede the phrase; a question ("who is in donna's
        // family tree") is not this shape.
        let notNames: Set<String> = [
            "who", "what", "where", "when", "how", "why", "is", "are", "was",
            "were", "in", "on", "of", "for", "do", "does", "did", "can",
            "could", "i", "we", "you", "want", "need", "like", "would", "there",
            "any", "many", "which", "does", "have", "has", "tell", "about",
        ]
        guard before.count <= 3, !before.contains(where: { notNames.contains($0) })
        else { return nil }

        // Before the phrase: nothing, "donna's", "the breen".
        var people: [String] = []
        var surname: String?
        if let last = before.last, last.hasSuffix("'s") {
            let name = before.joined(separator: " ").dropLast(2)
            people = [String(name)]
        } else if !before.isEmpty {
            // "breen family tree", "the breens family tree"
            people = [before.joined(separator: " ")]
        }
        // After the phrase: nothing, or "for/of (the) X".
        var rest = after
        if let first = rest.first, ["for", "of", "on", "about"].contains(first) {
            rest.removeFirst()
            var name = rest.filter { !treeFiller.contains($0) || $0 == "the" }
            guard !name.isEmpty else { return nil }
            if name.first == "the", name.count >= 2, name.last?.hasSuffix("s") == true {
                surname = name.dropFirst().joined(separator: " ")
                name = []
            } else {
                name = name.filter { $0 != "the" }
                if let last = name.last, last.hasSuffix("'s") {
                    name[name.count - 1] = String(last.dropLast(2))
                }
                people = [name.joined(separator: " ")]
            }
        } else if !rest.isEmpty {
            // Trailing content ("family tree videos") is a different question.
            let trailingFiller = rest.filter { !treeFiller.contains($0) }
            guard trailingFiller.isEmpty else { return nil }
        }
        guard people.count <= 1 else { return nil }
        if let surname {
            return .localQuery(.graph(.init(people: [], operation: .familyTree, surname: surname)))
        }
        return .localQuery(.graph(.init(people: people, operation: .familyTree)))
    }

    // MARK: - Media actions

    private static let playVerbs: Set<String> = ["play", "watch"]
    private static let revealVerbs: Set<String> = ["reveal", "finder"]
    private static let showVerbs: Set<String> = [
        "show", "open", "display", "select", "highlight", "view", "see",
    ]
    private static let referentFiller: Set<String> = [
        "me", "the", "a", "an", "that", "this", "these", "those", "of", "them",
        "it", "one", "ones", "video", "videos", "clip", "clips", "file",
        "files", "item", "items", "result", "results", "match", "matches",
        "please", "in", "catalog", "the catalog", "finder", "up", "for", "us",
        "say", "maybe", "perhaps", "like", "lets", "let's", "again", "now",
        "then", "just", "hallie", "and", "recording", "recordings", "movie",
        "movies", "entry", "entries", "hit", "hits", "list", "listed", "shown",
        "you", "found", "mentioned", "above", "there", "here", "we", "have",
        "got", "either", "any", "some", "cited",
    ]
    private static let allWords: Set<String> = ["all", "both", "every", "each", "everything"]

    private static let ordinals: [String: Int] = [
        "first": 1, "1st": 1, "second": 2, "2nd": 2, "third": 3, "3rd": 3,
        "fourth": 4, "4th": 4, "fifth": 5, "5th": 5, "sixth": 6, "6th": 6,
        "seventh": 7, "7th": 7, "eighth": 8, "8th": 8, "ninth": 9, "9th": 9,
        "tenth": 10, "10th": 10, "eleventh": 11, "twelfth": 12,
    ]
    private static let cardinalWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10,
    ]

    private static func mediaResolution(
        _ rawWords: [String], original: String, snapshot: Snapshot?
    ) -> Resolution? {
        var words = dropLead(rawWords)
        guard let verbWord = words.first else { return nil }
        let verb: MediaVerb
        if playVerbs.contains(verbWord) {
            verb = .play
        } else if revealVerbs.contains(verbWord) {
            verb = .reveal
        } else if showVerbs.contains(verbWord) {
            verb = .show
        } else {
            return nil
        }
        words.removeFirst()
        // "show in finder" / "reveal in finder" / "show in the catalog"
        var effectiveVerb = verb
        if words.contains("finder") { effectiveVerb = .reveal }

        let hasReferentNoun = words.contains { referentNouns.contains($0) }
        // "play them" / "reveal those" = every cited item; "one of them" is
        // still one item.
        let hasAll = words.contains { allWords.contains($0) }
            || (words.contains { ["them", "those", "these"].contains($0) }
                && !words.contains("of"))
        let numbered = numberedIndex(words)
        let wantsLast = words.contains("last") || words.contains("latest")
        let content = words.filter {
            !referentFiller.contains($0) && !allWords.contains($0)
                && ordinals[$0] == nil && cardinalWords[$0] == nil
                && $0 != "number" && $0 != "last" && Int($0) == nil
                && $0 != "from" && $0 != "with" && $0 != "about" && $0 != "called"
                && $0 != "named" && $0 != "titled" && $0 != "which" && $0 != "where"
        }
        let years = words.compactMap { Int($0) }.filter { (1900...2099).contains($0) }
        let items = snapshot?.items ?? []

        // A bare referent ("play it", "play the first one", "show me number 3").
        let bareReferent = content.isEmpty && years.isEmpty
        if bareReferent {
            guard !items.isEmpty else {
                // "play" alone with no prior answer.
                if words.isEmpty || hasReferentNoun || numbered != nil
                    || wantsLast || hasAll {
                    return .declineNoPriorResult(effectiveVerb)
                }
                return effectiveVerb == .play ? .searchThenPlay(remainder(of: original)) : nil
            }
            if hasAll {
                return .mediaAction(verb: effectiveVerb, indices: Array(items.indices))
            }
            if wantsLast {
                return .mediaAction(verb: effectiveVerb, indices: [items.count - 1])
            }
            if let numbered {
                guard items.indices.contains(numbered - 1) else {
                    return .declineOutOfRange(requested: numbered, available: items.count)
                }
                return .mediaAction(verb: effectiveVerb, indices: [numbered - 1])
            }
            return .mediaAction(verb: effectiveVerb, indices: [0])
        }

        // "the one from 1994" / "the cape one" — pick by year or filename
        // token, but only when the sentence points at a shown item.
        if !items.isEmpty, hasReferentNoun || words.contains("from") {
            var candidates = Array(items.indices)
            if !years.isEmpty {
                candidates = candidates.filter { index in
                    years.allSatisfy { items[index].years.contains($0) }
                }
            }
            if !content.isEmpty {
                candidates = candidates.filter { index in
                    let haystack = Set(ArchivistKeywordText.tokens(items[index].filename))
                    return content.allSatisfy { haystack.contains($0) }
                }
            }
            if !candidates.isEmpty {
                if let numbered, candidates.indices.contains(numbered - 1) {
                    return .mediaAction(verb: effectiveVerb, indices: [candidates[numbered - 1]])
                }
                if wantsLast, let last = candidates.last {
                    return .mediaAction(verb: effectiveVerb, indices: [last])
                }
                return .mediaAction(verb: effectiveVerb, indices: hasAll ? candidates : [candidates[0]])
            }
            if hasReferentNoun && content.isEmpty {
                // "the one from 1994" with nothing from 1994 shown.
                return .declineNoMatchingItem(
                    years.map(String.init).joined(separator: " "))
            }
        }
        // Content the last answer cannot satisfy: a fresh question.
        return effectiveVerb == .play ? .searchThenPlay(remainder(of: original)) : nil
    }

    private static let referentNouns: Set<String> = [
        "one", "ones", "it", "that", "this", "them", "those", "these",
    ]

    /// "number 3", "3", "third", "the 3rd one" → 3. Words that are also years
    /// (1994) are not indices.
    private static func numberedIndex(_ words: [String]) -> Int? {
        for (index, word) in words.enumerated() {
            if let ordinal = ordinals[word] { return ordinal }
            if word == "number" || word == "no", index + 1 < words.count {
                if let value = Int(words[index + 1]) { return value }
                if let value = cardinalWords[words[index + 1]] { return value }
            }
            if let value = Int(word), value <= 100 { return value }
        }
        return nil
    }

    /// The text after the leading play verb, original casing preserved.
    private static func remainder(of original: String) -> String {
        var text = original.trimmingCharacters(in: .whitespacesAndNewlines)
        var progressed = true
        while progressed {
            progressed = false
            let lowered = text.lowercased()
            for lead in leadFiller.sorted(by: { $0.count > $1.count })
            where lowered.hasPrefix(lead + " ") {
                text = String(text.dropFirst(lead.count + 1))
                progressed = true
                break
            }
        }
        let lowered = text.lowercased()
        for verb in playVerbs.sorted(by: { $0.count > $1.count })
        where lowered.hasPrefix(verb + " ") {
            return String(text.dropFirst(verb.count + 1))
                .trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    // MARK: - Elliptical refinement

    private static let refinementLeads: [String] = [
        "and what about", "and how about", "what about", "how about",
        "and", "or", "now", "same for", "same but", "and now", "but",
        "also", "and also", "ok and", "okay and", "then",
    ]
    private static let scopeWords: Set<String> = [
        "in", "from", "during", "for", "with", "of", "the", "just", "only",
        "back", "over", "around", "about", "to", "at", "on", "maybe", "say",
        "instead", "please", "then", "hallie", "same", "again", "but",
        "one", "ones", "videos", "video", "clips", "clip",
    ]

    private static func refinementResolution(
        _ words: [String], snapshot: Snapshot?, isKnownPerson: (String) -> Bool
    ) -> Resolution? {
        var residualWords = words
        var hadLead = false
        for lead in refinementLeads.sorted(by: { $0.count > $1.count }) {
            let leadWords = lead.split(separator: " ").map(String.init)
            if Array(residualWords.prefix(leadWords.count)) == leadWords,
               residualWords.count > leadWords.count {
                residualWords = Array(residualWords.dropFirst(leadWords.count))
                hadLead = true
                break
            }
        }
        // Without a lead ("and …", "what about …") only a very short scope
        // phrase counts: "in the 90s?", "1994?", "matt?".
        guard hadLead || residualWords.count <= 4 else { return nil }
        let residual = residualWords.filter { !scopeWords.contains($0) }
        guard !residual.isEmpty, residual.count <= 4 else { return nil }
        // A sentence with a verb is a question of its own.
        let verbs: Set<String> = [
            "show", "play", "find", "who", "what", "when", "where", "how", "is",
            "was", "are", "were", "do", "does", "did", "can", "could", "tell",
            "count", "list", "reveal", "open", "get", "give", "search", "watch",
        ]
        if !hadLead, residualWords.contains(where: { verbs.contains($0) }) { return nil }
        if residual.contains(where: { verbs.contains($0) }) { return nil }
        // "and rick's father?" is a kinship question, not a field swap.
        if residual.contains(where: { $0.hasSuffix("'s") }) { return nil }

        let replaced: Replaced
        if let years = yearExpression(residual) {
            replaced = .years(years)
        } else {
            // A name lookup costs identity sources; only pay it when there is
            // a previous question to refine, and — without a lead — only for
            // a single bare word ("matt?").
            guard snapshot?.ast != nil, hadLead || residual.count == 1 else {
                return hadLead ? .declineNoPriorResult(nil) : nil
            }
            let candidate = residual.joined(separator: " ")
            if isKnownPerson(candidate) {
                replaced = .person(candidate)
            } else if hadLead {
                replaced = .keyword(candidate)
            } else {
                // Bare unknown word with no lead — not confidently a refinement.
                return nil
            }
        }
        guard let snapshot, let ast = snapshot.ast else {
            return hadLead ? .declineNoPriorResult(nil) : nil
        }
        return refine(ast, replaced: replaced)
    }

    /// Year phrases people actually say: "1994", "1990 to 1995", "the 90s",
    /// "1990s", "early 90s", "late eighties".
    static func yearExpression(_ words: [String]) -> ClosedRange<Int>? {
        let decadeWords: [String: Int] = [
            "forties": 1940, "fifties": 1950, "sixties": 1960, "seventies": 1970,
            "eighties": 1980, "nineties": 1990, "aughts": 2000, "twenties": 2020,
            "40s": 1940, "50s": 1950, "60s": 1960, "70s": 1970, "80s": 1980,
            "90s": 1990, "00s": 2000, "10s": 2010, "20s": 2020,
            "1940s": 1940, "1950s": 1950, "1960s": 1960, "1970s": 1970,
            "1980s": 1980, "1990s": 1990, "2000s": 2000, "2010s": 2010,
            "2020s": 2020,
        ]
        var qualifier: String?
        var remaining = words
        if let first = remaining.first, ["early", "mid", "late"].contains(first) {
            qualifier = first
            remaining.removeFirst()
        }
        if remaining.count == 1, let decade = decadeWords[remaining[0]] {
            switch qualifier {
            case "early": return decade...(decade + 3)
            case "mid": return (decade + 4)...(decade + 6)
            case "late": return (decade + 7)...(decade + 9)
            default: return decade...(decade + 9)
            }
        }
        let years = remaining.compactMap { Int($0) }
        guard qualifier == nil, !years.isEmpty,
              years.allSatisfy({ ArchivistQueryAST.yearRange.contains($0) })
        else { return nil }
        let connectors: Set<String> = ["to", "through", "thru", "until", "till", "and"]
        let others = remaining.filter { Int($0) == nil }
        guard others.allSatisfy(connectors.contains) else { return nil }
        if years.count == 1 { return years[0]...years[0] }
        if years.count == 2, years[0] <= years[1] { return years[0]...years[1] }
        return nil
    }

    static func refine(_ ast: ArchivistQueryAST, replaced: Replaced) -> Resolution {
        switch (ast, replaced) {
        case (.presence(var payload), .years(let range)):
            payload.yearStart = range.lowerBound
            payload.yearEnd = range.upperBound
            return .refine(.presence(payload), replaced: replaced)
        case (.presence(var payload), .person(let name)):
            payload.people = [name]
            return .refine(.presence(payload), replaced: replaced)
        case (.presence(var payload), .keyword(let word)):
            payload.keywords = [word]
            return .refine(.presence(payload), replaced: replaced)

        case (.cross(var payload), .years(let range)):
            payload.yearStart = range.lowerBound
            payload.yearEnd = range.upperBound
            return .refine(.cross(payload), replaced: replaced)
        case (.cross(var payload), .person(let name)):
            payload.people = [name]
            return .refine(.cross(payload), replaced: replaced)
        case (.cross(var payload), .keyword(let word)):
            payload.keywords = [word]
            return .refine(.cross(payload), replaced: replaced)

        case (.event(var payload), .years(let range)):
            payload.yearStart = range.lowerBound
            payload.yearEnd = range.upperBound
            return .refine(.event(payload), replaced: replaced)
        case (.event(var payload), .person(let name)):
            payload.people = [name]
            return .refine(.event(payload), replaced: replaced)
        case (.event(var payload), .keyword(let word)):
            payload.keywords = [word]
            return .refine(.event(payload), replaced: replaced)

        case (.graph(var payload), .person(let name)):
            payload.people = [name]
            payload.surname = nil
            return .refine(.graph(payload), replaced: replaced)
        case (.graph, .years):
            return .declineNotRefinable(
                reason: "a family-tree question doesn't take a year")
        case (.graph, .keyword):
            return .declineNotRefinable(
                reason: "a family-tree question doesn't take a topic word")

        case (.temporal(var payload), .person(let name)):
            payload.subject = name
            return .refine(.temporal(payload), replaced: replaced)
        case (.temporal(var payload), .years(let range)):
            guard range.lowerBound == range.upperBound else {
                return .declineNotRefinable(
                    reason: "an age question needs a single year")
            }
            payload.reference = .explicitYear(range.lowerBound)
            return .refine(.temporal(payload), replaced: replaced)
        case (.temporal, .keyword):
            return .declineNotRefinable(
                reason: "an age question doesn't take a topic word")

        case (.aggregate(var payload), .person(let name)):
            payload.anchorPeople = [name]
            return .refine(.aggregate(payload), replaced: replaced)
        case (.aggregate, .years), (.aggregate, .keyword):
            return .declineNotRefinable(
                reason: "a who-appears-with question only takes a person")
        }
    }
}
