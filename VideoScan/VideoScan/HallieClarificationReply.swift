// HallieClarificationReply.swift
// Deterministic matching of a TYPED reply to a pending "which one do you
// mean?" clarification (Rick, live 2026-08-25: "the one born in 1785"
// fell through to the language model — and the model was unreachable;
// live 2026-08-28: "the one born in 1959" matched none of the offered
// chips and was routed as a NEW question, so the translator declined it).
// People answer these in words, not numbers; every shape here resolves
// locally against the candidates, and anything ambiguous comes back as a
// narrowed list or an honest "none of them", never a guess.

import Foundation
import VideoScanCore

extension HallieTurnExecutor {

    /// What a typed reply to a pending which-one means.
    enum ClarificationReplyMatch: Sendable, Equatable {
        /// Exactly one candidate — resume the original ask with it.
        case selected(CandidateID)
        /// The discriminator fits several: re-ask over just these.
        case narrowed([Candidate], discriminator: String)
        /// The discriminator fits nobody offered: say so, re-ask the same list.
        case unmatched(discriminator: String)
        /// Not an attempt to pick (a new question, a negation, a bare
        /// "yes" with several choices): the caller's policy decides.
        case notASelection
    }

    /// Reply → the ONE candidate it selects, or nil.
    /// Accepted shapes: "2" · exact label or canonical name · a 4-digit
    /// year that appears in exactly one label ("the one born in 1785") ·
    /// "older/oldest/earlier/earliest" vs "younger/youngest/later/latest"
    /// when every label carries a distinct year · ordinals ("the first
    /// one", "second") · a place, parent or spouse the candidate's facts
    /// carry ("the one from Sudbury", "Matthew Rice's wife").
    static func clarificationSelection(
        _ reply: String,
        from candidates: [Candidate]
    ) -> CandidateID? {
        if case .selected(let id) = clarificationReply(reply, from: candidates) { return id }
        return nil
    }

    /// The full reading of a reply, including the narrowed / unmatched
    /// cases a client should re-ask with (2026-08-29).
    static func clarificationReply(
        _ reply: String,
        from candidates: [Candidate]
    ) -> ClarificationReplyMatch {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !candidates.isEmpty else { return .notASelection }

        if let number = Int(trimmed), candidates.indices.contains(number - 1) {
            return .selected(candidates[number - 1].id)
        }

        let folded = PersonResolver.normalize(trimmed)
        let wordList = folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        let words = Set(wordList)
        // A negated selector is not permission to guess. Re-ask rather than
        // treating "not the older one" as an affirmative "older" match.
        guard !words.contains("not"), !words.contains("neither") else { return .notASelection }
        // "Did you mean Judson Lamb?" → "yes" is a complete answer when
        // there is exactly one choice.
        if candidates.count == 1,
           ["yes", "y", "yeah", "yep", "yup", "correct", "right", "thats right",
            "that's right", "sure", "please", "yes please", "exactly"].contains(folded) {
            return .selected(candidates[0].id)
        }
        let exact = candidates.filter {
            PersonResolver.normalize($0.label) == folded
                || PersonResolver.normalize($0.canonicalName) == folded
        }
        if exact.count == 1 { return .selected(exact[0].id) }

        // Everything below reads the reply as an ATTEMPT to pick. A long
        // sentence, a request opener ("show…", "what…") or a question mark
        // is someone changing the subject; the policy layer handles that.
        let looksLikeAnAttempt = wordList.count <= 7
            && !trimmed.hasSuffix("?")
            && !(wordList.first.map { HallieClarificationPolicy.requestVerbs.contains($0) } ?? false)
        guard looksLikeAnAttempt else { return .notASelection }

        // "the one born in 1785" / "1785 one" / "donna 1959" — a year,
        // honouring birth/death qualifiers so a death in 1785 cannot
        // satisfy "born in 1785".
        if let m = trimmed.firstMatch(of: /\b(1[0-9]{3}|20[0-9]{2})\b/), let year = Int(m.1) {
            return clarificationYearMatch(year, words: words, candidates: candidates)
        }

        func labelYear(_ c: Candidate) -> Int? {
            c.label.firstMatch(of: /\b(1[0-9]{3}|20[0-9]{2})\b/).flatMap { Int($0.1) }
        }
        let dated = candidates.compactMap { c in labelYear(c).map { (c, $0) } }
        if dated.count == candidates.count,
           Set(dated.map(\.1)).count == candidates.count {
            let asksOlder = ["older", "oldest", "earlier", "earliest", "elder"]
                .contains { words.contains($0) }
            let asksYounger = ["younger", "youngest", "later", "latest", "newer"]
                .contains { words.contains($0) } || folded.contains("most recent")
            if asksOlder || asksYounger {
                guard asksOlder != asksYounger else { return .notASelection }
                if asksOlder, let pick = dated.min(by: { $0.1 < $1.1 }) {
                    return .selected(pick.0.id)
                }
                if let pick = dated.max(by: { $0.1 < $1.1 }) { return .selected(pick.0.id) }
            }
        }

        let ordinals = ["first": 0, "second": 1, "third": 2, "fourth": 3,
                        "fifth": 4, "last": candidates.count - 1]
        let selectedOrdinals = ordinals.filter { words.contains($0.key) }
        guard selectedOrdinals.count <= 1 else { return .notASelection }
        if let (_, index) = selectedOrdinals.first {
            return candidates.indices.contains(index)
                ? .selected(candidates[index].id) : .notASelection
        }

        return clarificationFactMatch(wordList, candidates: candidates)
    }

    private static func clarificationYearMatch(
        _ year: Int,
        words: Set<String>,
        candidates: [Candidate]
    ) -> ClarificationReplyMatch {
        let asksBirth = words.contains("born") || words.contains("birth")
        let asksDeath = words.contains("died") || words.contains("death")
        guard !(asksBirth && asksDeath) else { return .notASelection }

        func labeledYear(_ candidate: Candidate, birth: Bool) -> Int? {
            let label = candidate.label.lowercased()
            // "b. 1785" and the full-date label "b. 16 MAY 1651" alike:
            // the first year after the marker.
            let match = birth
                ? label.firstMatch(of: /\b(?:born|b\.).*?\b(1[0-9]{3}|20[0-9]{2})\b/)
                : label.firstMatch(of: /\b(?:died|d\.).*?\b(1[0-9]{3}|20[0-9]{2})\b/)
            return match.flatMap { Int($0.1) }
        }

        let byYear = candidates.filter { candidate in
            if asksBirth { return labeledYear(candidate, birth: true) == year }
            if asksDeath { return labeledYear(candidate, birth: false) == year }
            return candidate.label.contains(String(year))
        }
        let discriminator = asksBirth ? "born in \(year)" : asksDeath ? "died in \(year)" : "\(year)"
        switch byYear.count {
        case 0: return .unmatched(discriminator: discriminator)
        case 1: return .selected(byYear[0].id)
        default: return .narrowed(byYear, discriminator: discriminator)
        }
    }

    /// Words that carry no identity of their own in a which-one reply.
    /// Relationship words are here on purpose: "Matthew Rice's wife" picks
    /// by MATTHEW RICE (a spouse fact), not by the word "wife".
    private static let replyStopWords: Set<String> = [
        "the", "one", "ones", "a", "an", "that", "this", "it", "its", "i", "me", "my",
        "mean", "meant", "from", "in", "at", "of", "to", "on", "who", "whom", "whose",
        "was", "is", "were", "be", "born", "died", "birth", "death", "married", "wife",
        "husband", "spouse", "mother", "father", "mom", "dad", "parent", "parents",
        "son", "daughter", "child", "children", "s", "and", "or", "with", "guy",
        "person", "woman", "man", "lady", "her", "his", "him", "she", "he", "they",
        "them", "yes", "please", "think", "probably", "maybe", "lived", "live", "lives",
    ]
    /// Reply words that announce a discriminating fact, so a miss is said
    /// ("none of them is from Sudbury") rather than treated as a new turn.
    private static let replyFactMarkers: Set<String> = [
        "from", "born", "died", "married", "wife", "husband", "spouse", "mother",
        "father", "mom", "dad", "parent", "parents", "son", "daughter", "child", "lived",
    ]

    /// "the one from Sudbury" / "Matthew Rice's wife" / "the one married to
    /// Rick" / "hudson": every content word must be found in the
    /// candidate's own name, label or facts (places, parents, spouses).
    /// Words every candidate shares (the asked-about given name) carry no
    /// information and are ignored; a nickname counts as its full name.
    private static func clarificationFactMatch(
        _ wordList: [String],
        candidates: [Candidate]
    ) -> ClarificationReplyMatch {
        func tokens(_ text: String) -> Set<String> {
            Set(PersonResolver.normalize(text)
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        }
        let names = candidates.map { tokens($0.canonicalName) }
        let shared = names.dropFirst().reduce(names.first ?? []) { $0.intersection($1) }
        let content = wordList.filter {
            !replyStopWords.contains($0) && !shared.contains($0) && Int($0) == nil
        }
        guard !content.isEmpty else { return .notASelection }

        let matching = candidates.filter { candidate in
            var facts = tokens(candidate.label).union(tokens(candidate.canonicalName))
            for fact in candidate.discriminators { facts.formUnion(tokens(fact)) }
            return content.allSatisfy { word in
                facts.contains(word)
                    || GedcomFamilyGraph.diminutives[word].map(facts.contains) == true
            }
        }
        let discriminator = content.joined(separator: " ")
        switch matching.count {
        case 1:
            return .selected(matching[0].id)
        case 0:
            let announced = wordList.contains { replyFactMarkers.contains($0) }
            return announced ? .unmatched(discriminator: discriminator) : .notASelection
        default:
            return .narrowed(matching, discriminator: discriminator)
        }
    }

    // MARK: Shared re-ask wording (chat window + shell say the same thing)

    static func narrowedClarificationPreface(count: Int, discriminator: String) -> String {
        "\(count) of them match “\(discriminator)” — which one? "
    }

    static func unmatchedClarificationPreface(_ discriminator: String) -> String {
        "None of them matches “\(discriminator)”. "
    }
}
