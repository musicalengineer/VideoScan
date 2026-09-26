// HalliePronounInSentenceAntecedentTests.swift
// Live 2026-09-23 22:26, tree mode: "show timmy playing guitar", then
// "tell me about thankful pratt and her husband" →
// "I wasn't sure which person you meant — thankful pratt or timmy?"
// (queryDescription: person=thankful pratt,timmy relation=husband).
//
// Cause: HalliePronounContinuity.rewrite replaced "her" with the LAST
// answer's person before translation — "…thankful pratt and Timmy's
// husband" — although the sentence itself names her antecedent. Pinned: a
// pronoun whose antecedent is a known person named EARLIER IN THE SAME
// SENTENCE is left for the translator; with no in-sentence name the
// last-answer rewrite still applies. The pronoun is bound to the
// in-sentence name (so the translator sees one clear person) — the
// unrewritten sentence came back from the translator as a no-person event
// in the clean replay the same night.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Hallie pronoun with an in-sentence antecedent")
struct HalliePronounInSentenceAntecedentTests {
    typealias P = HalliePronounContinuity

    private static let known: Set<String> = ["thankful pratt", "donna", "martha lamson", "timmy"]
    private let isKnown: (String) -> Bool = { known.contains($0.lowercased()) }

    @Test func aNameEarlierInTheSentenceOwnsThePronoun() {
        #expect(P.rewrite("tell me about thankful pratt and her husband",
                          lastPeople: ["Timmy"], isKnownPerson: isKnown)?.question
                == "tell me about thankful pratt and thankful pratt's husband")
        #expect(P.rewrite("when did martha lamson marry and who were her children",
                          lastPeople: ["Donna"], isKnownPerson: isKnown)?.question
                == "when did martha lamson marry and who were martha lamson's children")
        // No conversation memory at all: the sentence still binds itself.
        #expect(P.rewrite("Thankful Pratt and her husband",
                          lastPeople: [], isKnownPerson: isKnown)?.question
                == "Thankful Pratt and Thankful Pratt's husband")
        // A plural pronoun after a single named person is left as typed.
        #expect(P.rewrite("tell me about thankful pratt and their children",
                          lastPeople: ["Timmy"], isKnownPerson: isKnown) == nil)
    }

    /// With no name before the pronoun the last answer still supplies it.
    @Test func withoutAnInSentenceNameTheLastAnswerStillBinds() {
        #expect(P.rewrite("and her husband?", lastPeople: ["Martha Lamson"],
                          isKnownPerson: isKnown)?.question == "and Martha Lamson's husband?")
        #expect(P.rewrite("tell me about her husband", lastPeople: ["Thankful Pratt"],
                          isKnownPerson: isKnown)?.question == "tell me about Thankful Pratt's husband")
        // A name AFTER the pronoun is not its antecedent.
        #expect(P.rewrite("was her husband related to donna", lastPeople: ["Thankful Pratt"],
                          isKnownPerson: isKnown)?.question == "was Thankful Pratt's husband related to donna")
    }

    /// Filler words and unknown phrases before the pronoun never count as a
    /// name, even when the oracle is generous about single words.
    @Test func fillerWordsAreNotAntecedents() {
        let generous: (String) -> Bool = { _ in true }
        #expect(P.rewrite("tell me about her husband", lastPeople: ["Donna"],
                          isKnownPerson: generous)?.question == "tell me about Donna's husband")
        #expect(P.rewrite("and who was her father", lastPeople: ["Donna"],
                          isKnownPerson: generous)?.question == "and who was Donna's father")
    }

    /// The pre-translation lane passes its person oracle: the live sentence
    /// reaches the translator unrewritten after a Timmy answer.
    @Test func theFollowUpLaneLeavesTheLiveSentenceAlone() {
        var memory = HallieTurnExecutor.ConversationMemory()
        memory.record(
            intent: .init(originalQuestion: "show timmy playing guitar",
                          ast: .presence(.init(people: ["Timmy"], keywords: ["playing", "guitar"]))),
            result: .init(route: .presence, outcome: .answered,
                          prose: "I found 2 catalog items matching that.",
                          basisLine: "Basis: fixture", queryDescription: "shape=presence",
                          citations: [], catalogPersonName: "Timmy"))
        #expect(memory.pronounReferents == ["Timmy"])
        let turn = HallieTurnExecutor.preTranslation(
            question: "tell me about thankful pratt and her husband",
            playAfterAnswer: false, memory: memory, isKnownPerson: isKnown)
        guard case .translate(let question, _) = turn else {
            Issue.record("expected a translation, got \(turn)")
            return
        }
        #expect(question == "tell me about thankful pratt and thankful pratt's husband")
        #expect(!question.lowercased().contains("timmy"))
    }
}
