// HallieOfferAcceptance.swift
// A bare "yes" / "sure" / "ok" right after Hallie asked "Want me to try
// without the words, or with a different name?" takes the FIRST thing
// she offered (live 2026-09-11 22:01Z: "sure" and then "yes" were both
// answered with "I couldn't tell how “sure” narrows down my last
// answer…" — Hallie asked a question and did not recognise its answer).
//
// Two pure pieces. `retry(after:)` is the offer itself: the declined
// presence / cross search with its words dropped (or, with no words, its
// year), mirroring the sentence ArchivistPresenceExecutor.noEvidenceAnswer
// builds — a person-only miss offers nothing, so nil. Conversation
// memory keeps the result as `pendingOffer`; the pre-translation step
// runs it when the next turn is a bare affirmative. Nothing here calls a
// model, and a qualified reply ("yes but only the 90s") is not an
// acceptance — it keeps the follow-up road.

import Foundation
import VideoScanCore

enum HallieOfferAcceptance {
    /// The search a "yes" re-runs, with a label for the basis line
    /// ("taking my offer: without the words").
    struct Offer: Sendable, Equatable {
        let question: String
        let ast: ArchivistQueryAST
        let dropped: String

        var note: String { "taking my offer: without the \(dropped)" }
    }

    /// The offer a declined list search left open, or nil when the miss
    /// offered no retry. Only a fresh search (not a page of one) with a
    /// person AND words or a year: exactly the case whose not-found
    /// sentence ends "Want me to try without the words / the year …".
    static func retry(after intent: HallieTurnExecutor.Intent,
                      result: HallieTurnExecutor.Result) -> Offer? {
        guard result.outcome == .declined, intent.citationOffset == 0,
              intent.dateOrder == nil else { return nil }
        let people: [String]
        let yearStart: Int?, yearEnd: Int?
        let mediaKind: ArchivistQueryAST.MediaKind?
        let words: [String]
        switch intent.ast {
        case .presence(let p):
            people = p.people ?? []
            (yearStart, yearEnd, mediaKind) = (p.yearStart, p.yearEnd, p.mediaKind)
            words = p.keywords ?? []
        case .cross(let c):
            people = c.people ?? []
            (yearStart, yearEnd, mediaKind) = (c.yearStart, c.yearEnd, c.mediaKind)
            words = (c.keywords ?? []) + (c.transcript ?? [])
        default:
            return nil
        }
        guard !people.isEmpty else { return nil }
        if !words.isEmpty {
            return Offer(
                question: intent.originalQuestion,
                ast: .presence(.init(people: people, yearStart: yearStart, yearEnd: yearEnd,
                                     mediaKind: mediaKind)),
                dropped: "words")
        }
        if yearStart != nil || yearEnd != nil {
            return Offer(
                question: intent.originalQuestion,
                ast: .presence(.init(people: people, mediaKind: mediaKind)),
                dropped: "year")
        }
        return nil
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
