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

    // codex #707 item 5: the join used to keep only b's citations; a's
    // evidence vanished from the answer that quoted its prose.
    @Test func joinKeepsBothEvidenceSetsAndRenumbersCollidingClaimTags() throws {
        let ra = Exec.Citation(recordID: UUID(), fullPath: "/v/a.mov", filename: "a.mov", playbackSeconds: nil, bases: [])
        let rb = Exec.Citation(recordID: UUID(), fullPath: "/v/b.mov", filename: "b.mov", playbackSeconds: 3, bases: [])
        let shared = Exec.KnowledgeCitation(id: "cb:1", title: "Rick told me", attribution: "Rick", locator: nil)
        let a = Exec.Result(
            route: .presence, outcome: .answered, prose: "One in 1997. Another in 1998.",
            basisLine: "Basis: A.", queryDescription: "qa", citations: [ra],
            knowledgeCitations: [shared, .init(id: "cb:2", title: "Dad", attribution: nil, locator: nil)],
            catalogPersonName: "Donna", matchCount: 2,
            answerPlan: HallieAnswerPlan(route: .presence, shape: .list,
                                         claims: [.init(id: "c1", text: "One in 1997.", evidenceIDs: ["ra"]),
                                                  .init(id: "c2", text: "Another in 1998.")],
                                         fallbackText: "One in 1997. Another in 1998."),
            transcriptText: "One in 1997. [c1] Another in 1998. [c2]")
        let b = Exec.Result(
            route: .graph, outcome: .answered, prose: "Born 1920. Died 1999.",
            basisLine: "Basis: B.", queryDescription: "qb", citations: [ra, rb],
            knowledgeCitations: [shared], catalogPersonName: "Dick", matchCount: nil,
            answerPlan: HallieAnswerPlan(route: .graph, shape: .biography,
                                         claims: [.init(id: "c1", text: "Born 1920.", evidenceIDs: ["cb:1"]),
                                                  .init(id: "c2", text: "Died 1999.")],
                                         fallbackText: "Born 1920. Died 1999."),
            transcriptText: "Born 1920. [c1] Died 1999. [c1, c2]")
        let r = Exec.joinedTwoQuestionAnswer(a, b)
        #expect(r.citations == [ra, rb])                                   // union, a first, no dup of ra
        #expect(r.knowledgeCitations.map(\.id) == ["cb:1", "cb:2"])        // union by id
        #expect(r.prose == "One in 1997. Another in 1998.\n\nBorn 1920. Died 1999.")
        #expect(r.basisLine == "Basis: A. Basis: B.")
        #expect(r.matchCount == 2)
        #expect(r.catalogPersonName == "Dick")
        let plan = try #require(r.answerPlan)
        #expect(plan.claims.map(\.id) == ["c1", "c2", "c3", "c4"])         // b's c1,c2 → c3,c4
        #expect(plan.claims[2].text == "Born 1920." && plan.claims[2].evidenceIDs == ["cb:1"])
        #expect(plan.shape == .biography)
        #expect(plan.fallbackText == r.prose)
        #expect(r.transcriptText == "One in 1997. [c1] Another in 1998. [c2]\n\nBorn 1920. [c3] Died 1999. [c3, c4]")
        // Tag shifting leaves non-claim brackets and prose alone.
        #expect(Exec.shiftClaimTags(in: "x [c1][c2, c10] y [note] z", by: 4) == "x [c5][c6, c14] y [note] z")
        #expect(Exec.shiftClaimTags(in: "[c1]", by: 0) == "[c1]")
        // A plan-less pair stays plan-less (derived later from the joined prose).
        let plain = Exec.joinedTwoQuestionAnswer(
            Exec.Result(route: .capability, outcome: .answered, prose: "A.", basisLine: "a", queryDescription: nil, citations: [], catalogPersonName: nil),
            Exec.Result(route: .graph, outcome: .answered, prose: "B.", basisLine: "b", queryDescription: nil, citations: [rb], catalogPersonName: nil))
        #expect(plain.answerPlan == nil && plain.transcriptText == nil && plain.citations == [rb])
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
