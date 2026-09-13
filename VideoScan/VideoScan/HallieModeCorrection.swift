// HallieModeCorrection.swift
// Correcting the mode by talking (design §3.6, ledger row 2 / eval
// lv260907-003): "not in videos, in family tree" / "I meant the catalog"
// / "no, the archive" / "check the tree instead". The sentence names ONE
// family (the other may be negated), carries a correction cue, and
// nothing else. The turn forces that family and re-asks the last
// question under it — the same re-ask shape `isTreeCorrection` uses —
// or, with nothing to re-ask, says so honestly and still switches.
//
// Pure text. Narrow on purpose: every word must be a cue, a family name
// or filler, so "no that's wrong, you gave me videos" (a repair) and
// "who is in the family tree" (a question) are never claimed.

import Foundation

enum HallieModeCorrection {
    typealias Exec = HallieTurnExecutor

    struct Correction: Equatable, Sendable {
        /// The family the sentence asks for.
        let mode: HallieMode
        /// The words that named (or negated) it, for the basis line.
        let phrase: String
    }

    private static let treeWords: Set<String> = [
        "tree", "genealogy", "gedcom", "ancestry", "pedigree", "lineage",
    ]
    private static let catalogWords: Set<String> = [
        "catalog", "catalogue", "archive", "archives", "videos", "video",
        "footage", "collection", "library", "media", "tapes", "films",
        "movies", "clips", "recordings",
    ]
    /// A word that makes the sentence a correction rather than a scope.
    private static let cueWords: Set<String> = [
        "meant", "mean", "instead", "rather", "actually", "check", "use",
        "try", "search", "look", "switch", "go", "ask", "asking", "want",
        "wanted", "answer", "rerun", "redo", "again",
    ]
    /// "no" / "nope" opening the sentence is a cue too (never a negation).
    private static let openers: Set<String> = ["no", "nope", "nah", "uh"]
    private static let filler: Set<String> = [
        "not", "i", "im", "i'm", "the", "a", "an", "in", "from", "my", "our",
        "your", "family", "it", "that", "this", "to", "of", "one", "please",
        "hallie", "mode", "side", "and", "but", "was", "is", "be", "should",
        "did", "do", "question", "there", "here", "him", "her", "them",
        "just", "um", "at", "with", "up", "on", "for", "me", "us", "so",
        "then", "now", "sorry", "oops", "hmm", "well", "you", "can", "could",
        "would", "there's", "its", "it's", "thats", "that's", "whole", "entire",
    ]

    /// The correction in these words, or nil when the sentence is not one.
    static func detect(_ text: String) -> Correction? {
        guard text.count <= 160 else { return nil }
        // Bare "check the tree" / "look it up in the family tree" is the
        // person-fact lane's own tree correction (a graph re-ask by name);
        // that road is unchanged.
        guard !HalliePersonFactQuestion.isTreeCorrection(text) else { return nil }
        let folded = HallieRepairTurn.fold(text)
        guard !folded.isEmpty else { return nil }
        // Clauses: "not in videos, in family tree" is two, and the negation
        // in the first must not reach the second.
        let clauses = folded
            .replacingOccurrences(of: " but ", with: ",")
            .split(whereSeparator: { ",;:—–-".contains($0) })
            .map { clause in
                clause.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
                    .map(String.init)
            }
            .filter { !$0.isEmpty }
        let tokens = clauses.flatMap { $0 }
        guard !tokens.isEmpty, tokens.count <= 14 else { return nil }
        let vocabulary = treeWords.union(catalogWords).union(cueWords).union(openers).union(filler)
        guard tokens.allSatisfy({ vocabulary.contains($0) }) else { return nil }

        var affirmed: [(HallieMode, String)] = []
        var negated: [(HallieMode, String)] = []
        for clause in clauses {
            var negating = false
            for (index, word) in clause.enumerated() {
                if word == "not" { negating = true; continue }
                let family: HallieMode? = treeWords.contains(word) ? .tree
                    : catalogWords.contains(word) ? .catalog : nil
                guard let family else { continue }
                let phrase = clause[max(0, index - 2)...index].joined(separator: " ")
                if negating { negated.append((family, phrase)) } else { affirmed.append((family, phrase)) }
            }
        }
        let affirmedModes = Set(affirmed.map(\.0))
        let negatedModes = Set(negated.map(\.0))
        let target: (HallieMode, String)
        if affirmedModes.count == 1, let one = affirmed.first {
            guard !negatedModes.contains(one.0) else { return nil }
            target = one
        } else if affirmedModes.isEmpty, negatedModes.count == 1, let one = negated.first {
            target = (one.0 == .tree ? .catalog : .tree, one.1)
        } else {
            return nil
        }
        let hasCue = tokens.contains { cueWords.contains($0) }
            || openers.contains(tokens[0])
            || !negated.isEmpty
        guard hasCue else { return nil }
        return Correction(mode: target.0, phrase: target.1)
    }

    /// What memory should do: naming the OTHER family than the one
    /// currently forced returns to automatic (the force was wrong, not
    /// just the guess); otherwise the named family is held.
    static func force(for correction: Correction, forcedMode: HallieMode?) -> HallieModeForce {
        if let forcedMode, forcedMode != correction.mode { return .unforce }
        return .force(correction.mode)
    }

    /// The honest reply when there is no last question to re-ask: the
    /// switch still happens, and the next question goes there.
    static func nothingToReask(_ correction: Correction, force: HallieModeForce) -> Exec.Result {
        let family = correction.mode == .tree ? "the family tree" : "the catalog"
        let held = force == .unforce ? "back to choosing automatically" : "holding it there"
        return Exec.Result(
            route: .followUp,
            outcome: .declined,
            prose: "Okay — \(family) it is; I'm \(held). I don't have a question to re-ask yet, "
                + "so ask me again and I'll take it in \(family).",
            basisLine: "Basis: mode correction (“\(correction.phrase)”) with no previous question to re-run. Nothing was looked up.",
            queryDescription: "mode correction: \(correction.mode.rawValue), nothing to re-ask",
            citations: [],
            catalogPersonName: nil,
            mode: correction.mode,
            modeForce: force)
    }
}
