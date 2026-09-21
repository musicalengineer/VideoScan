// HallieSocialShapeGuard.swift
// A social or identity turn is never a catalog search, whatever shape the
// translator guessed (codex replay 2026-09-21 on 9818ff51, nine cases new
// since the 09-18 baseline): "nice to meet you" became a presence search
// for the words "nice to meet you" (51 videos where someone says it),
// "that was terrible lol" an event search (Christmas 1990), "ok" a search
// for "ok" (960 videos), "Do you ever get tired?" "10489 matching catalog
// items", and "You're helpful, you know that?" / "what should I call you"
// the presence decline "I need something to look for".
//
// Why now: before 6f81e4a9 an `event` AST was refused outright and a
// social sentence the model mis-shaped as an event went nowhere; since
// then event runs on the presence executor (the right fix for "show me
// Donna down the cape in the early 90s"), and the same prompt was nudged
// toward `presence`. The deterministic social pre-lane
// (HallieConversationGuard.generalVerdict) still runs first in every
// mode — it deliberately grounds any sentence addressed to "you", because
// "when were you born" is a tree fact about Hallie Mae — and then the
// model's guess was executed as-is. This is the missing backstop AFTER
// interpretation: an archive AST that names nobody, no year and no place,
// for a sentence that is addressed to Hallie or is a bare reaction and
// carries no archive, media, family, date or typed-name cue, is
// conversation. It goes to the bounded social lane (which has its own
// family-claim boundary) and the catalog is never touched.
//
// What stays a search on purpose: anyone named ("do you remember donna at
// the cape"), any year or decade, a media word ("did you find any
// videos"), a retrieval opener ("show me", "find"), a kin or tree word,
// a typed family name, a place facet, and a sentence with a content word
// of its own and no "you" in it ("the cape", "what happened when someone
// said surprise?").
//
// C++ analogy: a pure predicate object — every input is a parameter, the
// two identity oracles are function references the caller supplies, and
// the cheap shape test runs before anything that would load a source.

import Foundation

enum HallieSocialShapeGuard {
    struct Verdict: Equatable, Sendable {
        let kind: HallieConversationKind
        let reason: String

        /// One `[hallie-social]` line per claimed turn, beside
        /// `[hallie-general]` and `[hallie-mode]`.
        func logLine(question: String, ast: ArchivistQueryAST) -> String {
            "[hallie-social] kept \(HallieTurnExecutor.description(of: ast)) out of the catalog: "
                + "\(reason) — “\(question.prefix(120))”"
        }
    }

    /// The AST shapes a mis-read social sentence arrives as: a catalog
    /// search that names nobody and no time. Anything else is left alone.
    /// Cheap and oracle-free, so callers can test it before loading
    /// identity sources.
    static func isUnanchoredCatalogShape(_ ast: ArchivistQueryAST) -> Bool {
        func named(_ people: [String]?) -> Bool {
            (people ?? []).contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        switch ast {
        case .presence(let p):
            return !named(p.people) && p.yearStart == nil && p.yearEnd == nil
                && (p.place?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        case .cross(let p):
            return !named(p.people) && p.yearStart == nil && p.yearEnd == nil
        case .event(let p):
            return !named(p.people) && p.yearStart == nil && p.yearEnd == nil
        case .aggregate, .graph, .temporal, .record:
            return false
        }
    }

    /// Bare reactions and acknowledgements: a sentence made only of these
    /// and of filler is conversation ("that was terrible lol", "ok",
    /// "thanks hallie").
    static let reactionWords: Set<String> = [
        "ok", "okay", "k", "kk", "thanks", "thank", "thx", "ty", "cheers",
        "lol", "lmao", "haha", "hahaha", "ha", "hehe", "wow", "cool", "nice",
        "great", "awesome", "amazing", "terrible", "awful", "sad", "funny",
        "hilarious", "sorry", "oops", "yes", "yeah", "yep", "yup", "no",
        "nope", "nah", "sure", "fine", "alright", "right", "good", "bad",
        "hi", "hello", "hey", "bye", "goodbye", "goodnight", "morning",
        "evening", "afternoon", "night", "welcome", "indeed", "exactly",
        "agreed", "perfect", "excellent", "interesting", "true", "wonderful",
        "lovely", "brilliant", "neat", "sweet", "whoa", "yay", "ugh", "meh",
        "gotcha", "understood", "noted", "done", "please",
    ]

    /// Words that carry no content of their own in a reaction. Contraction
    /// tails ("that's" → "that", "s") are here because the tokenizer
    /// splits on the apostrophe.
    static let fillerWords: Set<String> = [
        "the", "a", "an", "that", "this", "it", "is", "was", "were", "are",
        "so", "very", "too", "really", "just", "pretty", "quite", "and",
        "but", "i", "me", "my", "we", "us", "you", "your", "hallie", "oh",
        "ah", "well", "hmm", "hm", "mm", "um", "uh", "of", "for", "to",
        "all", "one", "then", "now", "again", "much", "lot", "lots",
        "kind", "sort", "s", "m", "re", "ve", "d", "ll", "t",
    ]

    /// Nil when the turn is a search after all (or not a catalog shape);
    /// else the conversation kind to answer it with and why.
    static func verdict(
        question: String,
        ast: ArchivistQueryAST,
        isKnownPerson: (String) -> Bool,
        isInnerCircleName: (String) -> Bool
    ) -> Verdict? {
        guard isUnanchoredCatalogShape(ast) else { return nil }
        let normalized = HallieGeneralKnowledgeLane.normalize(question)
        let tokens = HallieGeneralKnowledgeLane.words(normalized)
        guard !tokens.isEmpty else { return nil }
        guard archiveCue(normalized: normalized, tokens: tokens, question: question) == nil else {
            return nil
        }
        // A typed family name — possessive, apposition, capitalised run,
        // or a lone inner-circle name — is a family question whatever the
        // translator did with it.
        guard HallieGeneralKnowledgeLane.typedFamilyName(
            question, isKnownPerson: isKnownPerson,
            isInnerCircleName: isInnerCircleName) == nil else { return nil }

        if let hit = HallieGeneralKnowledgeLane.secondPersonSubject(tokens: tokens) {
            return Verdict(
                kind: .casual,
                reason: "addressed to Hallie (“\(hit)”) with nobody, no year and no place to search for")
        }
        if let reaction = tokens.first(where: reactionWords.contains),
           tokens.allSatisfy({ reactionWords.contains($0) || fillerWords.contains($0) }) {
            return Verdict(kind: .casual, reason: "a reaction (“\(reaction)”), not a search")
        }
        return nil
    }

    /// The first archive, media, family, date or capability cue in the
    /// sentence, or nil. Every table here already exists for the lanes
    /// that run before the model; this guard only re-reads them.
    static func archiveCue(normalized: String, tokens: [String], question: String) -> String? {
        typealias Lane = HallieGeneralKnowledgeLane
        if let hit = Lane.capabilityPhrases.first(where: normalized.contains) { return hit }
        if let hit = Lane.hardArchivePhrases.first(where: normalized.contains) { return hit }
        if let hit = Lane.retrievalLeads.first(where: normalized.hasPrefix) {
            return hit.trimmingCharacters(in: .whitespaces)
        }
        if let hit = Lane.retrievalPhrases.first(where: normalized.contains) { return hit }
        if let hit = HallieConversationGuard.directPersonaFacts.first(where: normalized.contains) { return hit }
        if let hit = HallieConversationGuard.archivePhrases.first(where: normalized.contains) {
            return hit.trimmingCharacters(in: .whitespaces)
        }
        if let hit = tokens.first(where: Lane.hardArchiveWords.contains) { return hit }
        if let hit = tokens.first(where: Lane.isCatalogDate) { return hit }
        if let hit = HallieMediaVocabulary.words(question).first(where: HallieMediaVocabulary.all.contains) {
            return hit
        }
        let padded = " " + tokens.joined(separator: " ") + " "
        if let hit = HallieModeClassifier.catalogCuePhrases.first(where: { padded.contains(" " + $0 + " ") }) {
            return hit
        }
        if let hit = HallieModeClassifier.treeCuePhrases.first(where: { padded.contains(" " + $0 + " ") }) {
            return hit
        }
        if let hit = tokens.first(where: {
            HallieModeClassifier.catalogCues.contains($0) || HallieModeClassifier.treeCues.contains($0)
        }) {
            return hit
        }
        // "what do you know about the Breens": the whole-family road.
        if let family = HallieModeGate.familyWideAsk(in: question) { return family.cue }
        return nil
    }
}
