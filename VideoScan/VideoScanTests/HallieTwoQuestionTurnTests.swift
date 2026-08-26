// HallieTwoQuestionTurnTests.swift
// ITEM 5 (live 2026-08-26): "who do you know about? tell me about Thankful
// Pratt" answered only the second. The first model-free answer is now
// given, and the second is answered too (model-free) or offered as a chip.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Two questions in one turn")
struct HallieTwoQuestionTurnTests {
    typealias Exec = HallieTurnExecutor
    private let graph = GedcomFamilyGraph(gedcomText: """
    0 HEAD
    0 @I1@ INDI
    1 NAME Thankful /Pratt/
    1 SEX F
    1 BIRT
    2 DATE 1700
    0 TRLR
    """)
    private var context: Exec.Context {
        .init(profiles: [.init(stableID: "d", canonicalName: "Donna")], graph: graph,
              speakers: .init(ownerName: "Rick Breen", archivistName: nil))
    }
    private func pre(_ q: String) -> Exec.PreTranslation {
        Exec.preTranslation(
            question: q, playAfterAnswer: false, memory: .init(), isKnownPerson: { _ in false },
            rosterAnswer: { Exec.PeopleTab.rosterAnswer(context: context) },
            lineageAnswer: { HallieLineageAnswer.answer($0, context: context) })
    }

    @Test func splitting() {
        #expect(Exec.splitTwoQuestions("who do you know about? tell me about Thankful Pratt")! == ("who do you know about?", "tell me about Thankful Pratt"))
        #expect(Exec.splitTwoQuestions("who do you know about?") == nil)
        #expect(Exec.splitTwoQuestions("what? tell me about Thankful Pratt") == nil)
        #expect(Exec.splitTwoQuestions("a? b? c?") == nil)
    }

    @Test func theLiveUtteranceAnswersTheRosterAndOffersTheSecond() {
        guard case .answer(let r) = pre("who do you know about? tell me about Thankful Pratt") else {
            Issue.record("expected the roster answer"); return
        }
        #expect(r.route == .capability)
        #expect(r.prose.contains("Donna"))
        #expect(r.prose.contains("You also asked “tell me about Thankful Pratt” — tap it and I’ll answer that next."))
        #expect(r.offeredActions.contains(.ask(question: "tell me about Thankful Pratt", label: "Tell me about Thankful Pratt")))
        #expect(r.queryDescription == "two questions: shape=roster + deferred")
    }

    @Test func twoModelFreeQuestionsAreBothAnswered() {
        guard case .answer(let r) = pre("what is gedcom? who is the oldest person in the tree") else {
            Issue.record("expected a joined answer"); return
        }
        #expect(r.prose.contains("GEDCOM is the standard text format"))
        #expect(r.prose.contains("Thankful Pratt — born 1700"))
        #expect(r.route == .graph)
        #expect(r.offeredActions == [.openFamilyTreePerson(personID: "@I1@", personName: "Thankful Pratt")])
        #expect(r.basisLine.contains("capability answer") && r.basisLine.contains("GEDCOM"))
    }

    @Test func singleQuestionsAreUntouched() {
        guard case .answer(let r) = pre("who do you know about?") else { Issue.record("expected roster"); return }
        #expect(!r.prose.contains("You also asked"))
        #expect(r.offeredActions.isEmpty)
        // A first question the model owns is not split off from the second.
        guard case .translate(let q, _) = pre("show me donna in the 90s? and rick too") else {
            Issue.record("expected translate"); return
        }
        #expect(q == "show me donna in the 90s? and rick too")
    }
}
