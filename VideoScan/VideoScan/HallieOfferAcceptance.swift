// HallieOfferAcceptance.swift
// A bare "yes" / "sure" / "ok" right after Hallie asked "Want me to try
// without the words, or with a different name?" takes the FIRST thing
// she offered (live 2026-09-11 22:01Z: "sure" and then "yes" were both
// answered with "I couldn't tell how “sure” narrows down my last
// answer…" — Hallie asked a question and did not recognise its answer).
//
// Two pure pieces. `Offer` is the offer itself: the search that was
// EXECUTED and found nothing, with its words dropped (or, with no words,
// its year). It is built by HallieTurnExecutor.executePresenceLike from
// the typed `retryOffer` the not-found sentence carries
// (ArchivistPresenceAnswerComposer.noEvidence), travels on the Result,
// and conversation memory keeps it as `pendingOffer` for one reply; the
// pre-translation step runs it when the next turn is a bare affirmative.
//
// Codex #1352 (2026-09-11): the first version INFERRED the offer from
// "outcome == .declined + a presence AST with a person and words". But the
// presence path also declines BEFORE querying — "Did you mean X or Y?"
// for an ambiguous spelling, and an unresolved "my dad" — with no offer
// in the prose, so "videos of <ambiguous name> with guitar" → "Did you
// mean…" → "yes" silently dropped "guitar" and reran the unresolved name.
// Nothing here infers any more: an Offer exists only where the sentence
// was written. Nothing here calls a model, and a qualified reply ("yes
// but only the 90s") is not an acceptance — it keeps the follow-up road.

import Foundation
import VideoScanCore

enum HallieOfferAcceptance {
    /// The search a "yes" re-runs, with a label for the basis line
    /// ("taking my offer: without the words").
    struct Offer: Sendable, Equatable {
        let question: String
        let ast: ArchivistQueryAST
        let dropped: ArchivistPresenceAnswerComposer.RetryOffer

        var note: String { "taking my offer: without the \(dropped.rawValue)" }

        /// The offer for the presence query that was EXECUTED and found
        /// nothing — names already recovered, "my dad" already bound, a
        /// demoted name already a word — minus what the sentence offered
        /// to set aside. Built from the executed payload rather than the
        /// translator's AST so the retry is exactly "the same search
        /// without the words / the year", which is what Hallie said.
        init(question: String,
             executed: ArchivistQueryAST.Presence,
             dropping: ArchivistPresenceAnswerComposer.RetryOffer) {
            var relaxed = executed
            switch dropping {
            case .words:
                relaxed.keywords = nil
            case .year:
                relaxed.yearStart = nil
                relaxed.yearEnd = nil
            }
            self.question = question
            self.ast = .presence(relaxed)
            self.dropped = dropping
        }
    }

    /// Whole replies that mean "yes, do that" and nothing more. Normalised:
    /// lower-cased, punctuation dropped, "hallie" removed; "please" on its
    /// own counts, and so does "yes please".
    private static let affirmatives: Set<String> = [
        "yes", "y", "yeah", "yep", "yup", "sure", "ok", "okay", "please",
        "yes please", "sure please", "ok please", "okay please",
        "go ahead", "sure go ahead", "yes go ahead", "ok go ahead", "okay go ahead",
        "sure thing", "of course", "absolutely", "certainly", "definitely",
        "do it", "yes do it", "please do", "yes please do", "go for it",
        "why not", "sure why not", "sounds good", "that would be great",
        "yes that would be great", "ok sure", "okay sure", "yes sure", "yeah sure",
        "ok yes", "okay yes", "alright", "all right", "fine", "yes thanks",
        "yes thank you", "sure thanks", "ok thanks", "okay thanks",
    ]

    /// True for a reply that is an affirmative and NOTHING else. A word of
    /// content beside it ("yes, Donna", "yes but only the 90s", "no") is
    /// not an acceptance.
    static func isBareAffirmative(_ text: String) -> Bool {
        let words = text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: { !$0.isLetter && $0 != "'" })
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty && $0 != "hallie" }
        guard !words.isEmpty, words.count <= 5 else { return false }
        return affirmatives.contains(words.joined(separator: " "))
    }
}
