// HallieModeClassifier.swift
// Pure, model-free decision of which FAMILY a turn belongs to — catalog
// or family tree — before any lane runs (docs/hallie_two_mode_design.md
// §3.3). It reads the sentence, the previous mode and at most two
// identity-oracle answers; it never reads globals and never guesses:
// when nothing settles the question the verdict is `.unknown`, which
// means "today's chain, unchanged".
//
// Decision order (first that settles wins):
//   1. forced mode (the user picked one);
//   2. scope override phrases ("in the family tree", "not in videos");
//   3. explicit cue words, two disjoint families — one family → that
//      mode, both → step 4;
//   4. subject resolution through the oracle: a tree person → tree, a
//      named file → catalog; a tree person PLUS an item noun → catalog;
//      "photo(s) of <tree person>" → tree;
//   5. stickiness: an elliptical turn inherits the previous mode;
//   6. otherwise unknown.

import Foundation

enum HallieModeClassifier {

    /// The identity questions the classifier may ask. Closures, so the
    /// clients keep loading identity sources lazily; the classifier calls
    /// at most TWO of them per turn (isExactPersonName, isNamedFile), and
    /// only in step 4.
    struct Oracle {
        let isExactPersonName: (String) -> Bool
        let isKnownPerson: (String) -> Bool
        let isNamedFile: (String) -> Bool

        /// An oracle that knows nobody and no file — tests and clients
        /// without identity sources.
        static let none = Oracle(
            isExactPersonName: { _ in false },
            isKnownPerson: { _ in false },
            isNamedFile: { _ in false })
    }

    enum Reason: Equatable, Sendable {
        case forced
        /// "marry", "videos", "in the family tree" — the word or phrase
        /// that settled it.
        case explicitCue(HallieMode, String)
        /// "Edward III" → tree person; "New Hampshire.mov" → file.
        case subjectResolved(HallieMode, String)
        /// An elliptical turn inherited the previous mode.
        case sticky(HallieMode)
        /// Both families cued and nothing settled it.
        case conflict
        case none
    }

    struct Verdict: Equatable, Sendable {
        let mode: HallieMode
        let reason: Reason

        static let unknown = Verdict(mode: .unknown, reason: .none)

        /// One log line per turn, the shape the general lane uses.
        func logLine(question: String, forced: Bool) -> String {
            "[hallie-mode] mode=\(mode.rawValue) reason=\(reasonText) forced=\(forced) — “\(question.prefix(120))”"
        }

        var reasonText: String {
            switch reason {
            case .forced: return "forced"
            case .explicitCue(_, let cue): return "explicitCue(\(cue))"
            case .subjectResolved(_, let subject): return "subjectResolved(\(subject))"
            case .sticky: return "sticky"
            case .conflict: return "conflict"
            case .none: return "none"
            }
        }
    }

    // MARK: - Tables

    /// Phrases that OVERRIDE everything, stickiness included: they are how
    /// a user corrects a wrong guess by talking. Longest first at match.
    static let treeScopePhrases: [String] = [
        "in the family tree", "in my family tree", "in our family tree", "in family tree",
        "in the tree", "in my tree", "in our tree",
        "from the tree", "from the family tree", "from my family tree",
        "not in the videos", "not in videos", "not the videos", "not videos",
        "not in the catalog", "not in the archive", "not the catalog", "not the archive",
        "in the genealogy", "in the gedcom",
    ]

    static let catalogScopePhrases: [String] = [
        "in the archive", "in the archives", "in the catalog", "in the catalogue",
        "in the videos", "in videos", "in the footage", "in the collection",
        "in the library", "in the media", "in our videos", "in my videos",
        "not in the tree", "not in the family tree", "not the tree", "not the family tree",
        "from the archive", "from the catalog", "from the videos", "from the footage",
        "from the collection", "from the library",
    ]

    /// Catalog cue WORDS: the guard's catalog half, minus the photo nouns
    /// (handled in step 4) and the mode-neutral provenance words, plus the
    /// verbs and superlatives that only make sense of a catalog item.
    static let catalogCues: Set<String> = HallieConversationGuard.catalogCues
        .subtracting(["photo", "picture", "evidence", "source", "sources"])
        .union([
            "archives", "catalogue", "films", "movies", "tapes", "transcripts",
            "play", "watch", "reveal", "longest", "shortest", "biggest",
            "smallest", "largest", "reel", "reels", "collection", "library",
        ])

    /// Catalog cue PHRASES ("how many videos" is a count of items).
    static let catalogCuePhrases: [String] = [
        "how many videos", "how many clips", "how many files", "how many recordings",
        "how many tapes", "how many movies", "how much footage", "how many hours",
    ]

    /// Tree cue WORDS: the guard's tree half plus the one-hop kin nouns
    /// and the vocabulary of vital facts and lineage.
    static let treeCues: Set<String> = HallieConversationGuard.treeCues
        .union(HalliePronounContinuity.kinNouns)
        .union([
            "buried", "burial", "marry", "marries", "marriage", "ancestor",
            "ancestors", "descendant", "descendants", "lineage", "generation",
            "generations", "genealogy", "pedigree", "gedcom", "biography",
            "bio", "relative", "relatives", "relation", "kinship", "nee",
            "widow", "widower", "baptized", "baptised", "christened",
            "birthplace", "grave", "cemetery", "obituary", "royalty", "ancestry",
        ])

    /// Tree cue PHRASES.
    static let treeCuePhrases: [String] = [
        "tell me all about", "tell me more about", "tell me everything about",
        "tell me about", "tell us about", "who is", "who was", "who are", "who were",
        "how am i related", "how are we related", "family tree", "family history",
    ]

    /// Leads that mark an elliptical continuation.
    private static let leads: [String] = [
        "and what about", "what about", "how about", "and the", "and", "also",
        "then", "ok", "okay", "so", "or",
    ]

    /// Words that carry no content for the ≤ 4-content-words test.
    private static let filler: Set<String> = [
        "the", "a", "an", "me", "us", "of", "in", "is", "are", "was", "were",
        "it", "that", "this", "these", "those", "please", "hallie", "ok", "okay",
        "and", "what", "about", "how", "who", "do", "does", "did", "we", "you",
        "have", "has", "there", "any", "to", "for", "from", "with", "on", "at",
        "one", "ones", "them", "again", "now", "just", "so", "then", "many",
        "much", "more", "some", "all", "i", "my", "our", "your", "let", "let's",
        "lets", "see", "show", "tell", "give", "can", "could", "would", "be",
    ]

    private static let pronouns: Set<String> = HalliePronounContinuity.singular
        .union(HalliePronounContinuity.plural)
    /// "of those", "of them", "of it": never a name, never worth an
    /// oracle call.
    private static let demonstratives: Set<String> = [
        "those", "these", "them", "it", "that", "this", "one", "ones", "which",
    ]

    // MARK: - Entry

    static func classify(
        _ question: String,
        previous: HallieMode,
        forced: HallieMode? = nil,
        oracle: Oracle
    ) -> Verdict {
        if let forced { return Verdict(mode: forced, reason: .forced) }

        let words = HallieMediaVocabulary.words(question)
        guard !words.isEmpty else { return .unknown }
        let padded = " " + words.joined(separator: " ") + " "

        // 2. Scope overrides. The LONGEST matching phrase across both
        // families wins, so "not in the tree" is not read as "in the tree".
        if let override = longestOverride(in: padded) {
            return Verdict(mode: override.mode, reason: .explicitCue(override.mode, override.phrase))
        }

        // 3. Explicit cues, one family only.
        let catalogCue = firstPhrase(catalogCuePhrases, in: padded)
            ?? words.first(where: { catalogCues.contains($0) })
        let treeCue = firstPhrase(treeCuePhrases, in: padded)
            ?? words.first(where: { treeCues.contains($0) })
        switch (catalogCue, treeCue) {
        case (let cue?, nil): return Verdict(mode: .catalog, reason: .explicitCue(.catalog, cue))
        case (nil, let cue?): return Verdict(mode: .tree, reason: .explicitCue(.tree, cue))
        default: break
        }
        let conflicted = catalogCue != nil && treeCue != nil

        // 4. Subject resolution — the only oracle calls, at most two.
        if let subject = subjectPhrase(question) {
            if oracle.isExactPersonName(subject) {
                if HallieMediaVocabulary.containsItemNoun(question) {
                    return Verdict(mode: .catalog, reason: .subjectResolved(.catalog, subject))
                }
                return Verdict(mode: .tree, reason: .subjectResolved(.tree, subject))
            }
            if oracle.isNamedFile(subject) {
                return Verdict(mode: .catalog, reason: .subjectResolved(.catalog, subject))
            }
        }
        if conflicted { return Verdict(mode: .unknown, reason: .conflict) }

        // 5. Stickiness for an elliptical turn.
        if previous != .unknown, isElliptical(words) {
            return Verdict(mode: previous, reason: .sticky(previous))
        }
        return .unknown
    }

    /// The same decision read from conversation memory (the previous mode
    /// and any forced mode live there).
    static func classify(
        _ question: String,
        memory: HallieTurnExecutor.ConversationMemory,
        oracle: Oracle
    ) -> Verdict {
        classify(question, previous: memory.mode, forced: memory.forcedMode, oracle: oracle)
    }

    // MARK: - Pieces

    private static func firstPhrase(_ phrases: [String], in padded: String) -> String? {
        phrases.first { padded.contains(" " + $0 + " ") }
    }

    private static func longestOverride(in padded: String) -> (mode: HallieMode, phrase: String)? {
        var best: (mode: HallieMode, phrase: String)?
        for (mode, phrases) in [(HallieMode.tree, treeScopePhrases), (.catalog, catalogScopePhrases)] {
            for phrase in phrases where padded.contains(" " + phrase + " ") {
                if phrase.count > (best?.phrase.count ?? -1) { best = (mode, phrase) }
            }
        }
        return best
    }

    /// Verbs that make a short sentence a sentence of its own ("what do
    /// you KNOW about X"), so the ≤ 4-content-words rule does not read it
    /// as a fragment. A pronoun or a lead still makes it elliptical.
    ///
    /// The copulas used to be in here, and they are NOT evidence of a
    /// standalone sentence -- they are in `filler` for exactly that reason,
    /// so the same word was simultaneously "no content" for the word count
    /// and "enough content to stand alone" for this check. Because this
    /// check runs FIRST, the copula won, and every natural follow-up about
    /// the thing on screen -- "when was this filmed", "which one is the
    /// oldest", "how old was Timmy in this" -- was read as a fresh question
    /// with no context and answered with nothing. 2026-09-17.
    private static let sentenceVerbs: Set<String> = [
        "know", "think", "remember", "want", "need", "mean", "say", "find",
        "search", "look", "get", "give", "count", "list", "describe", "explain",
        "help", "make", "write", "suggest",
    ]

    /// The name phrase after about/of/with/for, or a leading possessive
    /// ("rick's …"). Trimmed of an article and a trailing scope phrase.
    static func subjectPhrase(_ question: String) -> String? {
        let text = question
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "?.!,;:"))
        guard !text.isEmpty else { return nil }
        if let match = text.range(
            of: #"^([A-Za-z][A-Za-z' .-]{0,60}?)'s\b"#, options: .regularExpression) {
            let owner = String(text[match]).dropLast(2)
            let cleaned = owner.trimmingCharacters(in: .whitespaces)
            if !cleaned.isEmpty, cleaned.split(separator: " ").count <= 5 { return cleaned }
        }
        guard let range = text.range(
            of: #"\b(?:about|of|with|for)\s+(?:the\s+|a\s+|an\s+)?(.+)$"#,
            options: [.regularExpression, .caseInsensitive]) else { return nil }
        var phrase = String(text[range])
        // Drop the preposition itself.
        if let space = phrase.firstIndex(of: " ") { phrase = String(phrase[phrase.index(after: space)...]) }
        for article in ["the ", "a ", "an "] where phrase.lowercased().hasPrefix(article) {
            phrase = String(phrase.dropFirst(article.count))
        }
        // A trailing scope or time phrase is not part of the name.
        if let cut = phrase.range(
            of: #"\s+(in|from|at|on|during|around|as)\s+.*$"#,
            options: [.regularExpression, .caseInsensitive]) {
            phrase = String(phrase[..<cut.lowerBound])
        }
        phrase = phrase.trimmingCharacters(in: .whitespaces)
        let lead = phrase.lowercased().split(separator: " ").first.map(String.init) ?? ""
        guard !phrase.isEmpty, phrase.split(separator: " ").count <= 6,
              !pronouns.contains(phrase.lowercased()),
              !demonstratives.contains(lead) else { return nil }
        return phrase
    }

    /// A third-person pronoun, a continuation lead, or ≤ 4 content words —
    /// and short enough to be a fragment rather than a sentence of its own.
    static func isElliptical(_ words: [String]) -> Bool {
        guard words.count <= 9 else { return false }
        let padded = " " + words.joined(separator: " ") + " "
        if leads.contains(where: { padded.hasPrefix(" " + $0 + " ") }) { return true }
        if words.contains(where: { pronouns.contains($0) }) { return true }
        // "how many of those are from the 90s": a count of "those" is a
        // continuation by construction (design §3.5), verb or no verb.
        if HallieCountAsk.isCountAsk(words.joined(separator: " ")) { return true }
        if words.contains(where: { sentenceVerbs.contains($0) }) { return false }
        return words.filter { !filler.contains($0) }.count <= 4
    }
}
