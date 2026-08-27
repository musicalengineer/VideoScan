// HallieClarificationReply.swift
// Deterministic matching of a TYPED reply to a pending "which one do you
// mean?" clarification (Rick, live 2026-08-25: "the one born in 1785"
// fell through to the language model — and the model was unreachable).
// People answer these in words, not numbers; every shape here resolves
// locally against the candidate labels, and anything ambiguous returns
// nil so the caller re-asks rather than guesses.

import Foundation

extension HallieTurnExecutor {

    /// Reply → the ONE candidate it selects, or nil.
    /// Accepted shapes: "2" · exact label or canonical name · a 4-digit
    /// year that appears in exactly one label ("the one born in 1785") ·
    /// "older/oldest/earlier/earliest" vs "younger/youngest/later/latest"
    /// when every label carries a distinct year · ordinals ("the first
    /// one", "second").
    static func clarificationSelection(
        _ reply: String,
        from candidates: [Candidate]
    ) -> CandidateID? {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !candidates.isEmpty else { return nil }

        if let number = Int(trimmed), candidates.indices.contains(number - 1) {
            return candidates[number - 1].id
        }

        let folded = PersonResolver.normalize(trimmed)
        let words = Set(folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init))
        // A negated selector is not permission to guess. Re-ask rather than
        // treating "not the older one" as an affirmative "older" match.
        guard !words.contains("not"), !words.contains("neither") else { return nil }
        // "Did you mean Judson Lamb?" → "yes" is a complete answer when
        // there is exactly one choice.
        if candidates.count == 1,
           ["yes", "y", "yeah", "yep", "yup", "correct", "right", "thats right",
            "that's right", "sure", "please", "yes please", "exactly"].contains(folded) {
            return candidates[0].id
        }
        let exact = candidates.filter {
            PersonResolver.normalize($0.label) == folded
                || PersonResolver.normalize($0.canonicalName) == folded
        }
        if exact.count == 1 { return exact[0].id }

        // "the one born in 1785" / "1785 one" — a year unique to one
        // candidate. Birth/death qualifiers are honored, so a death in 1785
        // cannot satisfy "born in 1785".
        if let m = trimmed.firstMatch(of: /\b(1[0-9]{3}|20[0-9]{2})\b/) {
            return clarificationYearSelection(Int(m.1), words: words, candidates: candidates)
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
                guard asksOlder != asksYounger else { return nil }
                if asksOlder {
                    return dated.min { $0.1 < $1.1 }?.0.id
                }
                return dated.max { $0.1 < $1.1 }?.0.id
            }
        }

        let ordinals = ["first": 0, "second": 1, "third": 2, "fourth": 3,
                        "fifth": 4, "last": candidates.count - 1]
        let selectedOrdinals = ordinals.filter { words.contains($0.key) }
        guard selectedOrdinals.count <= 1 else { return nil }
        if let (_, index) = selectedOrdinals.first,
           candidates.indices.contains(index) { return candidates[index].id }
        return nil
    }

    private static func clarificationYearSelection(
        _ year: Int?,
        words: Set<String>,
        candidates: [Candidate]
    ) -> CandidateID? {
        guard let year else { return nil }
        let asksBirth = words.contains("born") || words.contains("birth")
        let asksDeath = words.contains("died") || words.contains("death")
        guard !(asksBirth && asksDeath) else { return nil }

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
        return byYear.count == 1 ? byYear[0].id : nil
    }
}
