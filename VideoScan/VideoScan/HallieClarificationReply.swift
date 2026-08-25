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
        let exact = candidates.filter {
            PersonResolver.normalize($0.label) == folded
                || PersonResolver.normalize($0.canonicalName) == folded
        }
        if exact.count == 1 { return exact[0].id }

        // "the one born in 1785" / "1785 one" — a year unique to one label.
        if let m = trimmed.firstMatch(of: /\b(1[0-9]{3}|20[0-9]{2})\b/) {
            let year = String(m.1)
            let byYear = candidates.filter { $0.label.contains(year) }
            if byYear.count == 1 { return byYear[0].id }
            return nil   // a year that matches nothing or several: re-ask
        }

        func labelYear(_ c: Candidate) -> Int? {
            c.label.firstMatch(of: /\b(1[0-9]{3}|20[0-9]{2})\b/).flatMap { Int($0.1) }
        }
        let dated = candidates.compactMap { c in labelYear(c).map { (c, $0) } }
        if dated.count == candidates.count,
           Set(dated.map(\.1)).count == candidates.count {
            if ["older", "oldest", "earlier", "earliest", "elder"].contains(where: folded.contains) {
                return dated.min { $0.1 < $1.1 }?.0.id
            }
            if ["younger", "youngest", "later", "latest", "newer", "most recent"].contains(where: folded.contains) {
                return dated.max { $0.1 < $1.1 }?.0.id
            }
        }

        let ordinals = ["first": 0, "second": 1, "third": 2, "fourth": 3,
                        "fifth": 4, "last": candidates.count - 1]
        for (word, index) in ordinals where folded.contains(word) {
            if candidates.indices.contains(index) { return candidates[index].id }
        }
        return nil
    }
}
