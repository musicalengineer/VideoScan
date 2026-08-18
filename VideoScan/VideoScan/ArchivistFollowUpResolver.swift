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
        /// The refinement chain so far (nil = derive from the AST).
        let chain: Chain?

        init(ast: ArchivistQueryAST?, items: [Item], shownCount: Int? = nil,
             totalMatchCount: Int? = nil, chain: Chain? = nil) {
            self.ast = ast
            self.items = items
            self.shownCount = shownCount ?? items.count
            self.totalMatchCount = totalMatchCount ?? items.count
            self.chain = chain
        }
    }

    enum MediaVerb: String, Sendable, Equatable {
        case play
        case reveal
        case show
    }

    /// The cumulative refinement chain the user has stacked onto the base
    /// question — what the basis line prints ("refining: rick + guitar +
    /// westford · around 2005"). Terms are people and topic words in the
    /// order they were said; the year label is whatever the last year phrase
    /// was ("around 2005", "1990–1999", "as a baby").
    struct Chain: Sendable, Equatable {
        var terms: [String]
        var yearLabel: String?

        init(terms: [String] = [], yearLabel: String? = nil) {
            self.terms = terms
            self.yearLabel = yearLabel
        }

        var description: String {
            var text = terms.joined(separator: " + ")
            if let yearLabel {
                text += text.isEmpty ? yearLabel : " · " + yearLabel
            }
            return text
        }

        /// The chain a fresh (translated or local) AST starts with: its
        /// people, then its topic words, then its years.
        static func base(for ast: ArchivistQueryAST) -> Chain {
            func label(_ start: Int?, _ end: Int?) -> String? {
                guard let lower = start ?? end, let upper = end ?? start else { return nil }
                return lower == upper ? "\(lower)" : "\(lower)–\(upper)"
            }
            switch ast {
            case .presence(let p):
                return Chain(terms: (p.people ?? []) + (p.keywords ?? []),
                             yearLabel: label(p.yearStart, p.yearEnd))
            case .cross(let p):
                return Chain(terms: (p.people ?? []) + (p.keywords ?? []) + (p.transcript ?? []),
                             yearLabel: label(p.yearStart, p.yearEnd))
            case .event(let p):
                return Chain(terms: (p.people ?? []) + (p.keywords ?? []),
                             yearLabel: label(p.yearStart, p.yearEnd))
            case .temporal(let p):
                if case .explicitYear(let year) = p.reference {
                    return Chain(terms: [p.subject], yearLabel: "\(year)")
                }
                return Chain(terms: [p.subject])
            case .aggregate(let p): return Chain(terms: p.anchorPeople)
            case .graph(let p): return Chain(terms: p.people + (p.surname.map { ["the \($0)s"] } ?? []))
            }
        }

        static func capitalized(_ text: String) -> String {
            text.split(separator: " ")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }

    /// One edit to the previous AST. Adds are cumulative (AND); replaces
    /// happen for comparative leads ("what about matt?", "instead of").
    enum Change: Sendable, Equatable {
        case years(ClosedRange<Int>, label: String)
        /// "as a baby": years cleared, keyword kept; the presence executor
        /// turns it into a birth-year band and cites the source.
        case ageBand(keyword: String)
        case addPerson(String)
        /// "what about matt?" (of: nil → all people) or "matt instead of
        /// donna" (of: donna → just that one).
        case replacePerson(String, of: String?)
        case removePerson(String)
        case addKeyword(String)
        case replaceKeyword(String)

        /// Human label for the answer's "what changed" lead.
        var prose: String {
            switch self {
            case .years(_, let label): return "Narrowed to \(label)"
            case .ageBand(let keyword): return "Narrowed to \(keyword)"
            case .addPerson(let name): return "Added \(Chain.capitalized(name))"
            case .replacePerson(let name, _): return "Switched to \(Chain.capitalized(name))"
            case .removePerson(let name): return "Dropped \(Chain.capitalized(name))"
            case .addKeyword(let word): return "Narrowed to \(Chain.capitalized(word))"
            case .replaceKeyword(let word): return "Switched to \(Chain.capitalized(word))"
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
        /// The previous AST with the fragment's edits applied cumulatively.
        /// `chain` is the full chain after this step (for the basis line and
        /// for the next turn's memory); `whatChanged` is the answer's lead
        /// ("Narrowed to Westford, around 2005").
        case refine(ArchivistQueryAST, chain: Chain, whatChanged: String)
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
        /// A short fragment while a list answer is active that could not be
        /// read as any refinement ("hmm?", "and then"). The client offers the
        /// help card.
        case declineUninterpretable(String)
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

    // MARK: - Cumulative refinement (Rick 2026-08-17)
    //
    // After an answered list question, BARE FRAGMENTS refine the previous AST
    // cumulatively: "playing guitar" → keywords += guitar; "in westford" →
    // keywords += westford; "around 2005" → years 2004–2006; "with donna" →
    // people += donna. Each step keeps the prior constraints (AND). A
    // comparative lead ("what about matt?", "matt instead of donna") swaps
    // the like field instead of adding. Non-list shapes (family tree, age,
    // who-appears-with) keep single-field replacement. A fully formed
    // question — a sentence verb, or a person plus other content with no
    // lead — is never a refinement; it starts fresh through the translator.

    private enum LeadKind { case additive, comparative, subtractive }

    private struct Lead {
        let phrase: String
        let kind: LeadKind
        /// Prepositions ("in", "at") are soft: they shape the fragment but
        /// are not, by themselves, evidence that the user is continuing a
        /// conversation the way "and …" / "what about …" are.
        let soft: Bool
    }

    private static let leads: [Lead] = [
        // Comparative — swap the like field.
        .init(phrase: "and what about", kind: .comparative, soft: false),
        .init(phrase: "and how about", kind: .comparative, soft: false),
        .init(phrase: "what about", kind: .comparative, soft: false),
        .init(phrase: "how about", kind: .comparative, soft: false),
        .init(phrase: "what bout", kind: .comparative, soft: false),
        .init(phrase: "how bout", kind: .comparative, soft: false),
        .init(phrase: "same for", kind: .comparative, soft: false),
        .init(phrase: "same but", kind: .comparative, soft: false),
        .init(phrase: "or maybe", kind: .comparative, soft: false),
        .init(phrase: "or just", kind: .comparative, soft: false),
        .init(phrase: "or", kind: .comparative, soft: false),
        .init(phrase: "but", kind: .comparative, soft: false),
        .init(phrase: "just", kind: .comparative, soft: false),
        .init(phrase: "only", kind: .comparative, soft: false),
        .init(phrase: "rather", kind: .comparative, soft: false),
        // Subtractive — drop a person.
        .init(phrase: "but not", kind: .subtractive, soft: false),
        .init(phrase: "and not", kind: .subtractive, soft: false),
        .init(phrase: "without", kind: .subtractive, soft: false),
        .init(phrase: "not", kind: .subtractive, soft: false),
        .init(phrase: "minus", kind: .subtractive, soft: false),
        .init(phrase: "except", kind: .subtractive, soft: false),
        .init(phrase: "drop", kind: .subtractive, soft: false),
        .init(phrase: "remove", kind: .subtractive, soft: false),
        // Additive — keep everything and add.
        .init(phrase: "and also", kind: .additive, soft: false),
        .init(phrase: "and now", kind: .additive, soft: false),
        .init(phrase: "and then", kind: .additive, soft: false),
        .init(phrase: "and with", kind: .additive, soft: false),
        .init(phrase: "ok and", kind: .additive, soft: false),
        .init(phrase: "okay and", kind: .additive, soft: false),
        .init(phrase: "also with", kind: .additive, soft: false),
        .init(phrase: "and", kind: .additive, soft: false),
        .init(phrase: "also", kind: .additive, soft: false),
        .init(phrase: "with", kind: .additive, soft: false),
        .init(phrase: "plus", kind: .additive, soft: false),
        .init(phrase: "now", kind: .additive, soft: false),
        .init(phrase: "then", kind: .additive, soft: false),
        .init(phrase: "in", kind: .additive, soft: true),
        .init(phrase: "at", kind: .additive, soft: true),
        .init(phrase: "from", kind: .additive, soft: true),
        .init(phrase: "during", kind: .additive, soft: true),
        .init(phrase: "for", kind: .additive, soft: true),
        .init(phrase: "of", kind: .additive, soft: true),
        .init(phrase: "on", kind: .additive, soft: true),
    ]

    /// Words a fragment may carry that add nothing to the search: function
    /// words, the media nouns, and the "doing" verbs people put in front of
    /// a topic ("playing guitar", "saying peekaboo", "wearing the red hat").
    private static let fragmentFiller: Set<String> = ArchivistKeywordText.stopwords.union([
        "the", "a", "an", "just", "only", "back", "over", "to", "maybe", "say",
        "please", "then", "hallie", "same", "again", "one", "ones", "those",
        "these", "them", "it", "he", "she", "they", "him", "her", "his",
        "hers", "their", "as", "well", "too", "also", "plus", "and",
        "with", "at", "in", "on", "of", "from", "during", "for", "playing",
        "plays", "played", "play", "doing", "does", "did", "do", "having",
        "has", "have", "had", "being", "wearing", "riding", "rides", "rode",
        "saying", "says", "said", "singing", "sings", "sang", "talking",
        "talks", "talked", "sitting", "sits", "sat", "standing", "stands",
        "holding", "holds", "held", "using", "uses", "used", "going", "goes",
        "went", "getting", "gets", "got", "making", "makes", "made", "eating",
        "eats", "ate", "opening", "opens", "opened", "where", "when", "while",
        "yes", "yeah", "yep", "no", "nope", "ok", "okay", "hmm", "um", "uh",
        "sure", "right", "so", "oh", "ah", "like", "kind", "sort", "stuff",
        "things", "thing", "something", "anything", "everything", "there",
        "here", "who", "whom", "which", "what", "about", "around", "circa",
        "roughly", "approximately", "near", "nearly", "sometime", "somewhere",
        "some", "any", "instead", "rather", "than", "not", "without", "except",
        "minus", "but", "or", "ish", "time", "times", "day", "days", "year",
        "years", "old", "little", "young", "still", "more", "less", "other",
        "others", "another", "again", "either", "both", "each", "every", "all",
        "many", "much", "lot", "lots", "few", "several", "way", "ways",
    ])

    private static let politeness: Set<String> = [
        "please", "hallie", "ok", "okay", "hey", "um", "uh", "well", "yes",
        "yeah", "kindly", "so", "oh", "ah", "hmm", "right", "sure", "cool",
        "great", "thanks",
    ]

    private static let mediaNouns: Set<String> = [
        "video", "videos", "clip", "clips", "movie", "movies", "footage",
        "recording", "recordings", "tape", "tapes", "film", "films", "reel",
        "reels", "photo", "photos", "picture", "pictures",
    ]

    private static let approxWords: Set<String> = [
        "around", "about", "circa", "roughly", "approximately", "near",
        "nearly", "sometime", "close", "like", "maybe", "say", "ish",
    ]

    private static let sentenceVerbs: Set<String> = [
        "show", "play", "find", "who", "what", "when", "where", "how", "is",
        "was", "are", "were", "do", "does", "did", "can", "could", "tell",
        "count", "list", "reveal", "open", "get", "give", "search", "watch",
        "which", "why", "would", "should", "will", "want", "need", "know",
        "think", "remember", "have", "has", "had", "i", "we", "you", "let",
        "let's", "lets", "please", "help",
    ]

    /// Cap on people/topics one question can hold (the AST list bound), so a
    /// runaway chain is stopped with an honest message instead of an invalid
    /// query.
    private static let maxChainTerms = ArchivistQueryAST.maxListItems

    private static func refinementResolution(
        _ rawWords: [String], snapshot: Snapshot?, isKnownPerson: (String) -> Bool
    ) -> Resolution? {
        let original = rawWords.joined(separator: " ")
        // Politeness only — "and", "then", "just" are leads with meaning here.
        var residual = Array(rawWords.drop { politeness.contains($0) })
        var kind: LeadKind?
        var explicitLead = false
        var softLead = false
        // Peel leads while they keep matching ("and with donna").
        var progressed = true
        while progressed {
            progressed = false
            for lead in leads.sorted(by: { $0.phrase.count > $1.phrase.count }) {
                let leadWords = lead.phrase.split(separator: " ").map(String.init)
                guard Array(residual.prefix(leadWords.count)) == leadWords,
                      residual.count > leadWords.count else { continue }
                residual = Array(residual.dropFirst(leadWords.count))
                if lead.soft { softLead = true } else { explicitLead = true }
                // Comparative / subtractive beat additive.
                switch (kind, lead.kind) {
                case (nil, let new): kind = new
                case (.additive?, let new): kind = new
                default: break
                }
                progressed = true
                break
            }
        }
        let hadLead = explicitLead || softLead

        // Nothing but filler ("ok", "and", "hmm?"): not a question at all.
        let contentAtAll = residual.filter { !fragmentFiller.contains($0) }
        if contentAtAll.isEmpty {
            return snapshot?.ast == nil ? .none : .declineUninterpretable(original)
        }
        // A sentence of its own — verbs, kinship possessives, or too long.
        if residual.contains(where: { sentenceVerbs.contains($0) }) { return nil }
        if residual.contains(where: { $0.hasSuffix("'s") }) { return nil }
        guard residual.count <= (hadLead ? 6 : 4) else { return nil }
        // "videos of nobody" / "christmas videos": asking FOR media is a
        // fresh question, not a narrowing of the last one — unless a
        // continuation lead says otherwise ("and the christmas videos").
        if !explicitLead, residual.contains(where: { mediaNouns.contains($0) }) { return nil }

        // Years first ("around 2005", "in the 90s", "1990 to 1995"), then an
        // age band ("as a baby"), then whatever content is left.
        var changes: [Change] = []
        var rest = residual
        if let extracted = extractYears(from: rest) {
            changes.append(.years(extracted.range, label: extracted.label))
            rest = extracted.remaining
        }
        if let band = extractAgeBand(from: rest) {
            changes.append(.ageBand(keyword: band.keyword))
            rest = band.remaining
        }

        // "matt instead of donna" / "instead of donna" / "donna instead".
        var insteadNew: [String] = []
        var insteadOld: [String] = []
        var hadInstead = false
        if let index = rest.firstIndex(of: "instead") {
            hadInstead = true
            insteadNew = Array(rest[..<index]).filter { !fragmentFiller.contains($0) }
            var after = Array(rest[(index + 1)...])
            if after.first == "of" { after.removeFirst() }
            insteadOld = after.filter { !fragmentFiller.contains($0) }
            rest = []
        }

        // Content groups split at filler boundaries: "with donna at the cape"
        // → [donna] [cape]; "playing guitar" → [guitar]; "red bike" → [red bike].
        var groups: [[String]] = []
        var current: [String] = []
        for word in rest {
            if fragmentFiller.contains(word) {
                if !current.isEmpty { groups.append(current); current = [] }
            } else {
                current.append(word)
            }
        }
        if !current.isEmpty { groups.append(current) }

        // No previous question: a year alone or a bare topic word may still
        // be a fresh question for the translator; an explicit continuation
        // lead ("and …") is an honest decline. Name lookups cost identity
        // sources, so nothing below runs without something to refine.
        guard let snapshot, let ast = snapshot.ast else {
            return explicitLead ? .declineNoPriorResult(nil) : .none
        }
        let listShape: Bool
        switch ast {
        case .presence, .cross, .event: listShape = true
        default: listShape = false
        }

        if hadInstead {
            let newName = insteadNew.joined(separator: " ")
            let oldName = insteadOld.joined(separator: " ")
            let newKnown = !newName.isEmpty && isKnownPerson(newName)
            let oldKnown = !oldName.isEmpty && isKnownPerson(oldName)
            if newKnown {
                changes.append(.replacePerson(newName, of: oldKnown ? oldName : nil))
            } else if oldKnown, newName.isEmpty {
                changes.append(.removePerson(oldName))
            } else if !newName.isEmpty {
                changes.append(.replaceKeyword(newName))
            } else {
                return .declineUninterpretable(original)
            }
        }

        // People and topics. Without any lead, a person plus anything else
        // ("donna at christmas", "matt in 2005") is a fresh question.
        var personGroups: [String] = []
        var topicGroups: [String] = []
        for group in groups {
            let phrase = group.joined(separator: " ")
            if isKnownPerson(phrase) {
                personGroups.append(phrase)
            } else {
                topicGroups.append(phrase)
            }
        }
        if !hadLead, !personGroups.isEmpty,
           personGroups.count + topicGroups.count + changes.count > 1 {
            return nil
        }
        // For non-list shapes an unknown bare word without a lead is not
        // confidently a refinement (old behavior: let the translator decide).
        if !listShape, !hadLead, !topicGroups.isEmpty { return nil }

        for name in personGroups {
            switch kind {
            case .comparative?: changes.append(.replacePerson(name, of: nil))
            case .subtractive?: changes.append(.removePerson(name))
            default: changes.append(.addPerson(name))
            }
        }
        for topic in topicGroups {
            switch kind {
            case .comparative?: changes.append(.replaceKeyword(topic))
            case .subtractive?:
                return .declineNotRefinable(
                    reason: "I can only drop a person, not a topic word — ask it fresh")
            default: changes.append(.addKeyword(topic))
            }
        }
        guard !changes.isEmpty else { return .declineUninterpretable(original) }

        if listShape {
            return applyCumulative(changes, to: ast, previousChain: snapshot.chain)
        }
        return applyReplacement(changes[0], to: ast)
    }

    // MARK: Year and age extraction

    private static let decadeWords: [String: Int] = [
        "forties": 1940, "fifties": 1950, "sixties": 1960, "seventies": 1970,
        "eighties": 1980, "nineties": 1990, "aughts": 2000, "twenties": 2020,
        "40s": 1940, "50s": 1950, "60s": 1960, "70s": 1970, "80s": 1980,
        "90s": 1990, "00s": 2000, "10s": 2010, "20s": 2020,
        "1940s": 1940, "1950s": 1950, "1960s": 1960, "1970s": 1970,
        "1980s": 1980, "1990s": 1990, "2000s": 2000, "2010s": 2010,
        "2020s": 2020,
    ]
    private static let yearQualifiers: Set<String> = ["early", "mid", "late"]
    private static let yearConnectors: Set<String> = [
        "to", "through", "thru", "until", "till", "and", "or",
    ]

    private static func decade(_ word: String) -> Int? {
        decadeWords[word.replacingOccurrences(of: "'", with: "")]
    }

    private static func isYear(_ word: String) -> Bool {
        if let value = Int(word) { return ArchivistQueryAST.yearRange.contains(value) }
        return false
    }

    /// The first year phrase in the fragment, its label as said, and the
    /// words that remain. "around 2005" → 2004–2006 / "around 2005".
    static func extractYears(
        from words: [String]
    ) -> (range: ClosedRange<Int>, label: String, remaining: [String])? {
        guard let start = words.firstIndex(where: { isYear($0) || decade($0) != nil })
        else { return nil }
        var lower = start
        var group: [String] = []
        if lower > 0, yearQualifiers.contains(words[lower - 1]) {
            lower -= 1
        }
        var approx = false
        var approxIndex: Int?
        if lower > 0, approxWords.contains(words[lower - 1]) {
            approx = true
            approxIndex = lower - 1
        }
        group = Array(words[lower...start])
        var upper = start
        var index = start + 1
        while index < words.count {
            let word = words[index]
            if isYear(word) {
                group.append(word); upper = index; index += 1
            } else if yearConnectors.contains(word), index + 1 < words.count,
                      isYear(words[index + 1]) {
                group.append(word); group.append(words[index + 1])
                upper = index + 1; index += 2
            } else {
                break
            }
        }
        // Trailing "ish" / "or so": approximate.
        var trailing = upper
        if trailing + 1 < words.count, words[trailing + 1] == "ish" {
            approx = true; trailing += 1
        } else if trailing + 2 < words.count, words[trailing + 1] == "or",
                  words[trailing + 2] == "so" {
            approx = true; trailing += 2
        }
        guard var range = yearExpression(group) else { return nil }
        var label: String
        if range.lowerBound == range.upperBound {
            let year = range.lowerBound
            if approx {
                let bounds = ArchivistQueryAST.yearRange
                range = max(bounds.lowerBound, year - 1)...min(bounds.upperBound, year + 1)
                label = "around \(year)"
            } else {
                label = "\(year)"
            }
        } else {
            label = "\(range.lowerBound)–\(range.upperBound)"
        }
        var remaining: [String] = []
        for (position, word) in words.enumerated() {
            if position >= lower, position <= trailing { continue }
            if let approxIndex, position == approxIndex { continue }
            remaining.append(word)
        }
        return (range, label, remaining)
    }

    /// "as a baby" (alone or inside the fragment) → the age keyword the
    /// presence executor turns into a birth-year band, plus what remains.
    static func extractAgeBand(
        from words: [String]
    ) -> (keyword: String, remaining: [String])? {
        guard let index = words.firstIndex(where: { ArchivistAgePhrase.band(forWord: $0) != nil })
        else { return nil }
        let word = words[index]
        // Only the carriers leading into the band word belong to the phrase
        // ("as a", "when she was a"); the rest of the fragment is kept.
        var start = index
        while start > 0, ArchivistAgePhrase.isCarrier(words[start - 1]) { start -= 1 }
        let remaining = Array(words[..<start]) + Array(words[(index + 1)...])
        return ("as a \(word)", remaining)
    }

    /// Year phrases people actually say: "1994", "1990 to 1995", "the 90s",
    /// "1990s", "early 90s", "late eighties".
    static func yearExpression(_ words: [String]) -> ClosedRange<Int>? {
        var qualifier: String?
        var remaining = words
        if let first = remaining.first, yearQualifiers.contains(first) {
            qualifier = first
            remaining.removeFirst()
        }
        if remaining.count == 1, let decade = decade(remaining[0]) {
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
        let others = remaining.filter { Int($0) == nil }
        guard others.allSatisfy(yearConnectors.contains) else { return nil }
        if years.count == 1 { return years[0]...years[0] }
        if years.count == 2, years[0] <= years[1] { return years[0]...years[1] }
        return nil
    }

    // MARK: Applying changes

    private static func sameName(_ lhs: String, _ rhs: String) -> Bool {
        lhs.lowercased() == rhs.lowercased()
    }

    /// Cumulative apply for list shapes. Adds AND onto the previous
    /// constraints; comparative changes swap the like field; the chain and
    /// the "what changed" lead are rebuilt so the answer can say so.
    static func applyCumulative(
        _ changes: [Change], to ast: ArchivistQueryAST, previousChain: Chain?
    ) -> Resolution {
        var people: [String]
        var keywords: [String]
        var yearStart: Int?
        var yearEnd: Int?
        switch ast {
        case .presence(let p):
            people = p.people ?? []; keywords = p.keywords ?? []
            yearStart = p.yearStart; yearEnd = p.yearEnd
        case .cross(let p):
            people = p.people ?? []; keywords = p.keywords ?? []
            yearStart = p.yearStart; yearEnd = p.yearEnd
        case .event(let p):
            people = p.people ?? []; keywords = p.keywords ?? []
            yearStart = p.yearStart; yearEnd = p.yearEnd
        default:
            return applyReplacement(changes[0], to: ast)
        }
        var yearLabel: String? = previousChain?.yearLabel ?? Chain.base(for: ast).yearLabel

        for change in changes {
            switch change {
            case .years(let range, let label):
                yearStart = range.lowerBound; yearEnd = range.upperBound
                yearLabel = label
                // An explicit year replaces an earlier age band.
                keywords.removeAll { ArchivistAgePhrase.detect(in: [$0]) != nil }
            case .ageBand(let keyword):
                yearStart = nil; yearEnd = nil
                yearLabel = keyword
                keywords.removeAll { ArchivistAgePhrase.detect(in: [$0]) != nil }
                keywords.append(keyword)
            case .addPerson(let name):
                if people.contains(where: { sameName($0, name) }) {
                    return .declineNotRefinable(
                        reason: "\(Chain.capitalized(name)) is already part of the question")
                }
                people.append(name)
            case .replacePerson(let name, let old):
                if let old, let index = people.firstIndex(where: { sameName($0, old) }) {
                    people[index] = name
                } else {
                    people = [name]
                }
            case .removePerson(let name):
                guard people.contains(where: { sameName($0, name) }) else {
                    return .declineNotRefinable(
                        reason: "\(Chain.capitalized(name)) isn't part of the question")
                }
                people.removeAll { sameName($0, name) }
            case .addKeyword(let word):
                if keywords.contains(where: { sameName($0, word) }) {
                    return .declineNotRefinable(
                        reason: "“\(word)” is already part of the question")
                }
                keywords.append(word)
            case .replaceKeyword(let word):
                keywords = [word]
            }
        }
        if people.count > maxChainTerms || keywords.count > maxChainTerms {
            return .declineNotRefinable(
                reason: "I can hold at most \(maxChainTerms) people and \(maxChainTerms) topics "
                + "in one question — say “start over” to begin again")
        }
        if people.isEmpty, keywords.isEmpty, yearStart == nil, yearEnd == nil {
            return .declineNotRefinable(reason: "that would leave nothing to search for")
        }
        if yearStart == nil, yearEnd == nil, !keywords.contains(where: { ArchivistAgePhrase.detect(in: [$0]) != nil }) {
            yearLabel = nil
        }

        let refined: ArchivistQueryAST
        switch ast {
        case .presence(var p):
            p.people = people.isEmpty ? nil : people
            p.keywords = keywords.isEmpty ? nil : keywords
            p.yearStart = yearStart; p.yearEnd = yearEnd
            refined = .presence(p)
        case .cross(var p):
            p.people = people.isEmpty ? nil : people
            p.keywords = keywords.isEmpty ? nil : keywords
            p.yearStart = yearStart; p.yearEnd = yearEnd
            refined = .cross(p)
        case .event(var p):
            p.people = people.isEmpty ? nil : people
            p.keywords = keywords.isEmpty ? nil : keywords
            p.yearStart = yearStart; p.yearEnd = yearEnd
            refined = .event(p)
        default:
            fatalError("unreachable: list shapes only")
        }

        // Chain: previous terms that survived, in the order they were said,
        // then the new ones. Age keywords live in the year label, not terms.
        var spoken: [String] = []
        if case .cross(let p) = ast { spoken = p.transcript ?? [] }
        let live = (people + keywords + spoken).filter { ArchivistAgePhrase.detect(in: [$0]) == nil }
        var terms = (previousChain?.terms ?? Chain.base(for: ast).terms).filter { term in
            live.contains { sameName($0, term) }
        }
        for term in live where !terms.contains(where: { sameName($0, term) }) {
            terms.append(term)
        }
        let chain = Chain(terms: terms, yearLabel: yearLabel)
        return .refine(refined, chain: chain, whatChanged: whatChanged(changes))
    }

    /// "Narrowed to Westford, around 2005" / "Added Donna; narrowed to guitar".
    static func whatChanged(_ changes: [Change]) -> String {
        var topics: [String] = []
        var times: [String] = []
        var others: [String] = []
        for change in changes {
            switch change {
            case .years(_, let label): times.append(label)
            case .ageBand(let keyword): times.append(keyword)
            case .addKeyword(let word): topics.append(Chain.capitalized(word))
            default: others.append(change.prose)
            }
        }
        var parts = others
        let narrowed = topics + times
        if !narrowed.isEmpty {
            let lead = parts.isEmpty ? "Narrowed to " : "narrowed to "
            parts.append(lead + narrowed.joined(separator: ", "))
        }
        return parts.joined(separator: "; ")
    }

    /// Single-field replacement for the non-list shapes (family tree, age,
    /// who-appears-with), where "and matt?" can only mean "matt instead".
    static func applyReplacement(_ change: Change, to ast: ArchivistQueryAST) -> Resolution {
        func person(_ change: Change) -> String? {
            switch change {
            case .addPerson(let name), .replacePerson(let name, _): return name
            default: return nil
            }
        }
        func years(_ change: Change) -> ClosedRange<Int>? {
            if case .years(let range, _) = change { return range }
            return nil
        }
        func done(_ refined: ArchivistQueryAST) -> Resolution {
            .refine(refined, chain: Chain.base(for: refined), whatChanged: change.prose)
        }
        switch ast {
        case .presence, .cross, .event:
            return applyCumulative([change], to: ast, previousChain: nil)

        case .graph(var payload):
            if let name = person(change) {
                payload.people = [name]
                payload.surname = nil
                return done(.graph(payload))
            }
            if years(change) != nil {
                return .declineNotRefinable(
                    reason: "a family-tree question doesn't take a year")
            }
            return .declineNotRefinable(
                reason: "a family-tree question doesn't take a topic word")

        case .temporal(var payload):
            if let name = person(change) {
                payload.subject = name
                return done(.temporal(payload))
            }
            if let range = years(change) {
                guard range.lowerBound == range.upperBound else {
                    return .declineNotRefinable(
                        reason: "an age question needs a single year")
                }
                payload.reference = .explicitYear(range.lowerBound)
                return done(.temporal(payload))
            }
            return .declineNotRefinable(
                reason: "an age question doesn't take a topic word")

        case .aggregate(var payload):
            if let name = person(change) {
                payload.anchorPeople = [name]
                return done(.aggregate(payload))
            }
            return .declineNotRefinable(
                reason: "a who-appears-with question only takes a person")
        }
    }
}
