// HallieTwoQuestionMergeTests.swift
// GH #210 (decided 2026-10-01): a two-question turn joins two Results into
// one; the join dropped `superlative`, `subjectLifeStatus`, `refinableQuery`
// and `retryOffer`, so "that is donna's line" right after a two-question
// turn had no ranking to re-run. The rules (docs/guides/hallie.md, "Two questions
// in one turn"):
//   • later clause wins (like `mode`): superlative, refinableQuery;
//   • life status follows the subject the join names;
//   • a's retry offer survives only when b asks nothing of its own;
//   • a deferred second question keeps EVERY field of the one answer given.

import Foundation
import Testing
@testable import VideoScan

@Suite("HallieTwoQuestionMerge")
struct HallieTwoQuestionMergeTests {
    private typealias R = HallieTurnExecutor.Result

    private let offer = HallieOfferAcceptance.Offer(
        question: "videos of donna at the cape",
        executed: .init(people: ["Donna"], keywords: ["cape"]),
        dropping: .words)
    private let ranking = HallieLineageQuestion.SuperlativeAsk(kind: .earliestBorn, scope: .ancestorsOf(nil))

    private func result(prose: String, person: String? = nil,
                        life: LifeStatus? = nil, refinable: HallieTurnExecutor.RefinableQuery? = nil,
                        retry: HallieOfferAcceptance.Offer? = nil,
                        superlative: HallieLineageQuestion.SuperlativeAsk? = nil) -> R {
        R(route: .graph, outcome: .answered, prose: prose, basisLine: "Basis: fixture.",
          queryDescription: prose, citations: [], catalogPersonName: person,
          subjectLifeStatus: life, refinableQuery: refinable, retryOffer: retry,
          superlative: superlative)
    }

    @Test func theFirstAnswersFieldsSurviveWhenTheSecondHasNone() {
        let a = result(prose: "The earliest-born is Sal.", person: "Sal Quill", life: .deceased,
                       refinable: .wholeCatalog, retry: offer, superlative: ranking)
        let b = result(prose: "There are 12 videos.")
        let joined = HallieTurnExecutor.joinedTwoQuestionAnswer(a, b)
        #expect(joined.superlative == ranking, "a scope correction must still find the ranking")
        #expect(joined.refinableQuery == .wholeCatalog)
        #expect(joined.retryOffer == offer, "b asked nothing, so a's offer is still open")
        #expect(joined.subjectLifeStatus == .deceased, "the subject is a's (b names nobody)")
        #expect(joined.catalogPersonName == "Sal Quill")
    }

    @Test func theLaterClauseWins() {
        let other = HallieLineageQuestion.SuperlativeAsk(kind: .longestLived, scope: .wholeTree)
        let a = result(prose: "a", person: "Sal Quill", life: .deceased, refinable: .wholeCatalog, superlative: ranking)
        let b = result(prose: "b", person: "Beth Sample", life: .living,
                       refinable: .list(.presence(.init(people: ["Beth"])), anyOfPeople: false), superlative: other)
        let joined = HallieTurnExecutor.joinedTwoQuestionAnswer(a, b)
        #expect(joined.superlative == other)
        #expect(joined.refinableQuery == .list(.presence(.init(people: ["Beth"])), anyOfPeople: false))
        #expect(joined.subjectLifeStatus == .living)
        #expect(joined.catalogPersonName == "Beth Sample")
    }

    @Test func lifeStatusIsNeverPairedWithTheOtherClausesPerson() {
        // b names a person but has no verdict: a's "deceased" must not be
        // attached to b's subject.
        let a = result(prose: "a", person: "Sal Quill", life: .deceased)
        let b = result(prose: "b", person: "Beth Sample", life: nil)
        #expect(HallieTurnExecutor.joinedTwoQuestionAnswer(a, b).subjectLifeStatus == nil)
    }

    /// QA P3-1: b's verdict with NO person of its own must not be attached to
    /// a's subject — the join names a's person, so a's tense goes with it.
    @Test func bsLifeStatusWithoutAPersonIsNotPairedWithAsSubject() {
        let a = result(prose: "a", person: "Sal Quill", life: .deceased)
        let b = result(prose: "b", person: nil, life: .living)
        let joined = HallieTurnExecutor.joinedTwoQuestionAnswer(a, b)
        #expect(joined.catalogPersonName == "Sal Quill")
        #expect(joined.subjectLifeStatus == .deceased)
    }

    /// QA P3-1 (trailing-offer hypothesis, pinned): an offer sentence on b
    /// ("Want to see her photos?") always arrives with a clarification, so
    /// it is b's open question and a's retry offer does not survive it.
    @Test func bsTrailingOfferEndsAsRetryOffer() async throws {
        let graph = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME John /Smith/
        0 @I2@ INDI
        1 NAME John /Smith/
        0 TRLR
        """)
        let asked = try await HallieTurnExecutor.execute(
            .init(intent: .init(originalQuestion: "tell me about john smith",
                                ast: .graph(.init(people: ["john smith"], operation: .biography)))),
            context: .init(profiles: [], graph: graph))
        let clarification = try #require(asked.clarification)
        let a = result(prose: "Nothing found — want me to try without the words?", retry: offer)
        let b = result(prose: "Rick's father was Dick.").offering("Want to see his photos?", clarification: clarification)
        let joined = HallieTurnExecutor.joinedTwoQuestionAnswer(a, b)
        #expect(joined.retryOffer == nil)
        #expect(joined.prose.hasSuffix("Want to see his photos?"))
    }

    @Test func aRetryOfferDoesNotOutliveALaterQuestion() async throws {
        let a = result(prose: "Nothing found — want me to try without the words?", retry: offer)
        let graph = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME John /Smith/
        0 @I2@ INDI
        1 NAME John /Smith/
        0 TRLR
        """)
        let asked = try await HallieTurnExecutor.execute(
            .init(intent: .init(originalQuestion: "tell me about john smith",
                                ast: .graph(.init(people: ["john smith"], operation: .biography)))),
            context: .init(profiles: [], graph: graph))
        #expect(asked.clarification != nil)
        let joined = HallieTurnExecutor.joinedTwoQuestionAnswer(a, asked)
        #expect(joined.retryOffer == nil, "b's which-one is the open question; 'yes' must not run a's retry")
    }

    @Test func aDeferredSecondQuestionKeepsEveryFieldOfTheAnswerGiven() {
        let a = result(prose: "The earliest-born is Sal.", person: "Sal Quill", life: .deceased,
                       refinable: .wholeCatalog, retry: offer, superlative: ranking)
        let deferred = HallieTurnExecutor.deferringSecondQuestion(a, second: "how many videos are there")
        #expect(deferred.superlative == ranking)
        #expect(deferred.subjectLifeStatus == .deceased)
        #expect(deferred.refinableQuery == .wholeCatalog)
        #expect(deferred.retryOffer == offer)
        #expect(deferred.prose.hasSuffix("You also asked “how many videos are there” — tap it and I’ll answer that next."))
        #expect(deferred.offeredActions.last == .ask(question: "how many videos are there", label: "How many videos are there"))
    }
}
