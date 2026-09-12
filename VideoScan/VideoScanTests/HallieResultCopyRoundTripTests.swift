// HallieResultCopyRoundTripTests.swift
// `HallieTurnExecutor.Result` is copied field by field in several helpers.
// Every one of them must carry EVERY field: `prefixingBasis` dropped
// `subjectLifeStatus` (noted by the 2026-09-11 offer-fix agent), so a
// template kinship answer with an owner or roster note in its basis lost
// its tense for the composer. This is a reflection-free table test — add a
// row when a copy helper is added, and a field check when `Result` grows.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@MainActor
@Suite("Result copy helpers carry every field", .serialized)
struct HallieResultCopyRoundTripTests {

    private static let tree = GedcomFamilyGraph(gedcomText: """
    0 HEAD
    0 @I1@ INDI
    1 NAME John /Smith/
    1 SEX M
    1 BIRT
    2 DATE 1800
    0 @I2@ INDI
    1 NAME John /Smith/
    1 SEX M
    1 BIRT
    2 DATE 1850
    0 TRLR
    """)

    private let extra = HallieAttachment.photoRequest(
        personName: "Extra", folderURL: URL(fileURLWithPath: "/isolated/extra"))

    private func fullResult() -> (HallieTurnExecutor.Result, HallieOfferAcceptance.Offer) {
        let offer = HallieOfferAcceptance.Offer(
            question: "videos of donna at the cape",
            executed: .init(people: ["Donna"], keywords: ["cape"]),
            dropping: .words)
        let plan = HallieAnswerPlan(
            route: .graph, shape: .fact,
            claims: [.init(id: "c1", text: "Rick Breen's father was Richard Breen Sr.")],
            fallbackText: "Rick Breen's father was Richard Breen Sr.",
            subjectLifeStatus: .deceased)
        let result = HallieTurnExecutor.Result(
            route: .graph,
            outcome: .answered,
            prose: "Rick Breen's father was Richard Breen Sr.",
            basisLine: "Basis: fixture tree.",
            queryDescription: "fixture kinship",
            citations: [],
            knowledgeCitations: [.init(id: "k1", title: "Told", attribution: "Rick", locator: nil)],
            catalogPersonName: "Rick",
            clarification: nil,
            matchCount: 3,
            mediaAction: nil,
            offeredActions: [.openFamilyTree(personName: "Richard Breen Sr")],
            answerPlan: plan,
            composedBy: .template,
            transcriptText: "Rick Breen's father was Richard Breen Sr. [c1]",
            attachments: [.photoRequest(personName: "Rick", folderURL: URL(fileURLWithPath: "/isolated/rick"))],
            performsFirstOfferedAction: true,
            subjectLifeStatus: .deceased,
            refinableQuery: .wholeCatalog,
            retryOffer: offer)
        return (result, offer)
    }

    private func clarification() async throws -> HallieTurnExecutor.Clarification {
        let context = HallieTurnExecutor.Context(profiles: [], graph: Self.tree)
        let intent = HallieTurnExecutor.Intent(
            originalQuestion: "tell me about john smith",
            ast: .graph(.init(people: ["john smith"], operation: .biography)))
        let asked = try await HallieTurnExecutor.execute(.init(intent: intent), context: context)
        return try #require(asked.clarification)
    }

    @Test func everyCopyHelperRoundTripsTheLifeStatusAndTheRetryOffer() async throws {
        let (original, offer) = fullResult()
        let clarification = try await clarification()
        let plan = try #require(original.answerPlan)
        let helpers: [(String, (HallieTurnExecutor.Result) -> HallieTurnExecutor.Result)] = [
            ("adding(attachments:)", { $0.adding(attachments: [self.extra]) }),
            ("offering(_:clarification:)", { $0.offering("Want to see her photos?", clarification: clarification) }),
            ("carryingProvenance(_:)", { $0.carryingProvenance(" (taking Dad as Richard Breen Sr)") }),
            ("applying(_:)", { $0.applying(.template(plan, note: "template: fixture")) }),
            ("prefixingBasis(_:)", { $0.prefixingBasis("reading “ricks” as “rick’s”") }),
            ("FamilyKnowledgeSupplement.notFoundOffer", {
                HallieTurnExecutor.FamilyKnowledgeSupplement.notFoundOffer($0, typed: "nobody", graph: nil)
            }),
        ]
        for (name, copy) in helpers {
            let copied = copy(original)
            #expect(copied.subjectLifeStatus == .deceased, Comment(rawValue: "\(name) dropped subjectLifeStatus"))
            #expect(copied.retryOffer == offer, Comment(rawValue: "\(name) dropped retryOffer"))
            #expect(copied.refinableQuery == .wholeCatalog, Comment(rawValue: "\(name) dropped refinableQuery"))
            #expect(copied.performsFirstOfferedAction, Comment(rawValue: "\(name) dropped performsFirstOfferedAction"))
            #expect(copied.immediateOfferedAction == original.immediateOfferedAction,
                    Comment(rawValue: "\(name) changed immediateOfferedAction"))
            #expect(!copied.attachments.isEmpty, Comment(rawValue: "\(name) dropped attachments"))
            #expect(copied.knowledgeCitations == original.knowledgeCitations,
                    Comment(rawValue: "\(name) dropped knowledgeCitations"))
            #expect(copied.catalogPersonName == "Rick", Comment(rawValue: "\(name) dropped catalogPersonName"))
            #expect(copied.matchCount == 3, Comment(rawValue: "\(name) dropped matchCount"))
            #expect(copied.queryDescription == "fixture kinship", Comment(rawValue: "\(name) changed queryDescription"))
            #expect(copied.route == .graph && copied.outcome == .answered, Comment(rawValue: name))
        }
    }

    @Test func prefixingBasisOnlyTouchesTheBasisLine() {
        let (original, _) = fullResult()
        let copied = original.prefixingBasis("note")
        #expect(copied.basisLine == "Basis: note; fixture tree.")
        #expect(copied.prose == original.prose)
        #expect(copied.answerPlan == original.answerPlan)
        #expect(copied.transcriptText == original.transcriptText)
        #expect(copied.attachments == original.attachments)
        #expect(copied.subjectLifeStatus == original.subjectLifeStatus)
    }
}
