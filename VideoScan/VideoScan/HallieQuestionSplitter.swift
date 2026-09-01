// HallieQuestionSplitter.swift
// "who was Martha Lamson and do we have any videos of her"
//
// Rick, 2026-09-01. Measured that day: the translator collapses a conjunction
// to ONE shape and silently drops the other clause. That question produced
//
//     query: media ask: pronoun her (no subject)
//
// — the media half survived, "who was Martha Lamson" was thrown away, and
// then "her" had no antecedent even though it was named six words earlier.
// The control proves it is not a pronoun problem: repeat the name and Hallie
// answers the BIOGRAPHY and never mentions videos. Either way half the
// question is answered and nothing says the other half was discarded.
//
// NO MODEL CAN FIX THIS. ArchivistQueryAST permits exactly one shape per
// query, so asking a better translator to emit two is asking for something
// the strict decoder would reject. The split has to happen before
// translation, which is what this file does.
//
// WHAT IT DELIBERATELY DOES NOT DO. "who was Martha Lamson and where was she
// born" already works, because both halves collapse into `biography`, which
// carries places. Splitting that would replace one good answer with two
// thinner ones. So this returns nil unless the clauses look like genuinely
// DIFFERENT questions — see `looksLikeSeparateQuestion`. When in doubt it
// declines to split, because the existing single-query path is the tested one.

import Foundation

enum HallieQuestionSplitter {

    /// The most clauses worth running for one typed line. Three is already
    /// generous for speech; beyond that the reader is dictating a list and a
    /// wall of answers helps nobody.
    static let maxClauses = 3

    /// Clauses to answer in order, or nil to leave the question alone.
    ///
    /// Pronouns in later clauses are bound to a person named in an earlier
    /// one, so the second query carries "Martha Lamson" rather than "her".
    static func split(_ question: String) -> [String]? {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 300 else { return nil }

        let parts = clauses(of: trimmed)
        guard parts.count >= 2, parts.count <= maxClauses else { return nil }

        // Every clause must read as its own question. One clause that is a
        // bare fragment ("and tall") means this was a compound noun phrase,
        // not two questions.
        guard parts.allSatisfy(looksLikeSeparateQuestion) else { return nil }

        // Two clauses asking the SAME kind of thing are already served better
        // by the single-query path.
        let kinds = Set(parts.map(kind))
        guard kinds.count >= 2 else { return nil }

        return bindPronouns(in: parts)
    }

    // MARK: Splitting

    /// Split on a conjunction that joins two questions. Only " and " and
    /// " then " — deliberately not commas, which appear inside names
    /// ("Sudbury, Middlesex, Massachusetts") far more often than they
    /// separate questions.
    private static func clauses(of question: String) -> [String] {
        let lowered = question.lowercased()
        var out: [String] = []
        var start = lowered.startIndex
        var index = lowered.startIndex

        for separator in [" and then ", " and also ", " and ", " then "] where out.isEmpty {
            start = lowered.startIndex
            index = lowered.startIndex
            out = []
            while let range = lowered.range(of: separator, range: index..<lowered.endIndex) {
                out.append(String(question[start..<range.lowerBound]))
                start = range.upperBound
                index = range.upperBound
            }
            if !out.isEmpty { out.append(String(question[start...])) }
        }
        return out.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines
                .union(CharacterSet(charactersIn: "?,.")))
        }
        .filter { !$0.isEmpty }
    }

    // MARK: Is this really a question of its own?

    /// Words that open a question. A clause without one is a fragment.
    private static let openers: Set<String> = [
        "who", "what", "where", "when", "why", "how", "which", "whose",
        "did", "do", "does", "is", "was", "are", "were", "can", "could",
        "show", "tell", "find", "play", "list", "give", "any",
    ]

    private static func words(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map(String.init)
    }

    static func looksLikeSeparateQuestion(_ clause: String) -> Bool {
        let w = words(clause)
        guard w.count >= 2 else { return false }
        // "do we have any videos of her" — the opener may follow a lead-in
        // ("and also do we have…"), so look at the first two words.
        return openers.contains(w[0]) || openers.contains(w[1])
    }

    // MARK: What KIND of question — coarse on purpose

    /// Coarse buckets, matched to the AST shapes that actually exist. This is
    /// only used to answer "are these two clauses the same sort of question?",
    /// so it must be cheap and wrong-in-the-safe-direction: an unrecognised
    /// clause is `.other`, and two `.other`s do not split.
    enum Kind: Hashable { case person, place, date, media, other }

    static func kind(_ clause: String) -> Kind {
        let w = Set(words(clause))
        if !w.isDisjoint(with: ["video", "videos", "photo", "photos", "picture",
                                "pictures", "footage", "clip", "clips", "film"]) {
            return .media
        }
        if w.contains("where") { return .place }
        if w.contains("when") { return .date }
        if !w.isDisjoint(with: ["who", "whose", "tell", "about", "children",
                                "parents", "married", "spouse", "siblings"]) {
            return .person
        }
        return .other
    }

    // MARK: Pronoun binding

    private static let pronouns: Set<String> = [
        "her", "him", "she", "he", "them", "they", "his", "hers", "their",
    ]

    /// Replace a bare pronoun in a later clause with the person named in an
    /// earlier one. The antecedent is in the same sentence the reader typed,
    /// so resolving it needs no conversation history and no model — the case
    /// that failed on 2026-09-01 had the name six words away.
    static func bindPronouns(in parts: [String]) -> [String] {
        guard let subject = firstPersonName(in: parts) else { return parts }
        var out: [String] = []
        for (index, clause) in parts.enumerated() {
            guard index > 0 else { out.append(clause); continue }
            var rebuilt: [String] = []
            var replaced = false
            for token in clause.split(separator: " ", omittingEmptySubsequences: false) {
                let bare = token.lowercased()
                    .trimmingCharacters(in: CharacterSet(charactersIn: "?,.!'"))
                if !replaced, pronouns.contains(bare) {
                    rebuilt.append(subject)
                    replaced = true
                } else {
                    rebuilt.append(String(token))
                }
            }
            out.append(rebuilt.joined(separator: " "))
        }
        return out
    }

    /// The capitalised run of words in the first clause, which is how a
    /// person is written in a typed question ("who was Martha Lamson").
    /// Nil when nothing looks like a name — then the pronoun is left alone
    /// and the normal "who do you mean?" decline still applies.
    static func firstPersonName(in parts: [String]) -> String? {
        guard let first = parts.first else { return nil }
        var run: [String] = []
        var best: [String] = []
        for token in first.split(separator: " ") {
            let word = String(token).trimmingCharacters(
                in: CharacterSet(charactersIn: "?,.!"))
            let isName = word.first?.isUppercase == true
                && word.count > 1
                && !openers.contains(word.lowercased())
            if isName {
                run.append(word)
                if run.count > best.count { best = run }
            } else {
                run = []
            }
        }
        return best.count >= 2 ? best.joined(separator: " ") : nil
    }
}
