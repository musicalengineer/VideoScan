// HallieCapabilityDeclineFallbackTests.swift
//
// STUB for the testing agent (feature-dev added this while implementing the
// fallback itself; the testing agent owns the suite going forward and should
// expand/relocate as it sees fit — see HallieCapabilityDeclineFallback.swift
// for the feature this pins).
//
// Two live examples from Rick's brother's demo eve (2026-09-03) that dead-
// ended instead of being answered:
//   "why do old home videos feel so emotional"
//     -> "Event queries are not supported yet; I did not run a broader
//        search." (an app-capability decline — `.unsupported`)
//   "what questions could I ask my grandmother about her childhood"
//     -> a tree lookup on the bare kinship word "grandmother" declining with
//        "I don't find … in the family tree." (a no-referent decline)
// Both now retry once through the general-knowledge lane instead.

import Foundation
import Testing
@testable import VideoScan

// MARK: - Logic: the pure qualification rule

@Suite("Hallie capability/no-referent decline fallback — logic")
struct HallieCapabilityDeclineFallbackLogicTests {

    private func result(
        outcome: HallieTurnExecutor.Outcome,
        noReferentDecline: Bool = false
    ) -> HallieTurnExecutor.Result {
        HallieTurnExecutor.Result(
            route: .graph, outcome: outcome, prose: "fixture", basisLine: "fixture",
            queryDescription: nil, citations: [], catalogPersonName: nil,
            noReferentDecline: noReferentDecline)
    }

    @Test func unsupportedOutcomeQualifies() {
        #expect(HallieCapabilityDeclineFallback.qualifies(result(outcome: .unsupported)))
    }

    @Test func declinedWithNoReferentFlagQualifies() {
        #expect(HallieCapabilityDeclineFallback.qualifies(
            result(outcome: .declined, noReferentDecline: true)))
    }

    @Test(arguments: [
        HallieTurnExecutor.Outcome.answered,
        .needsClarification,
        .failed,
        .repaired,
    ])
    func everyOtherOutcomeNeverQualifies(outcome: HallieTurnExecutor.Outcome) {
        #expect(!HallieCapabilityDeclineFallback.qualifies(result(outcome: outcome)))
    }

    /// NEGATIVE — the shape that matters most: a real archive fact declined
    /// plainly ("nothing from 1950-1959", "I don't find Frank among his
    /// three siblings") never sets the flag and must never fall through.
    @Test func plainDeclineWithoutTheFlagNeverQualifies() {
        #expect(!HallieCapabilityDeclineFallback.qualifies(result(outcome: .declined)))
    }

    @Test func isBoundaryRefusalMatchesOnlyTheBoundarysOwnText() {
        let refusal = HallieSocialConversation.Reply(
            text: HallieGeneralAnswerBoundary.replacement,
            composedByModel: false,
            note: HallieGeneralAnswerBoundary.replacementNote)
        #expect(HallieCapabilityDeclineFallback.isBoundaryRefusal(refusal))

        let ordinary = HallieSocialConversation.Reply(
            text: "Old footage often carries more feeling because it is unrehearsed.",
            composedByModel: true,
            note: "test")
        #expect(!HallieCapabilityDeclineFallback.isBoundaryRefusal(ordinary))
    }

    @Test func basisLineNeverClaimsArchiveEvidence() {
        let lowered = HallieCapabilityDeclineFallback.basisLine.lowercased()
        #expect(lowered.contains("general knowledge"))
        #expect(!lowered.contains("citation"))
    }
}

// MARK: - Logic: the flag is set exactly where "no referent at all" is decided

@Suite("Hallie no-referent decline flag")
struct HallieNoReferentDeclineFlagTests {
    @Test func notFoundOfferMarksADeclineAsNoReferent() {
        let base = HallieTurnExecutor.Result(
            route: .graph, outcome: .declined,
            prose: "I don't find \u{201C}grandmother\u{201D} in the family tree.",
            basisLine: "Basis: checked the family tree.",
            queryDescription: nil, citations: [], catalogPersonName: nil)
        let offered = HallieTurnExecutor.FamilyKnowledgeSupplement.notFoundOffer(
            base, typed: "grandmother", graph: nil)
        #expect(offered.noReferentDecline)
        #expect(HallieCapabilityDeclineFallback.qualifies(offered))
    }

    /// NEGATIVE — a real-fact decline never runs through `notFoundOffer` and
    /// must default to `false`.
    @Test func anOrdinaryDeclineDefaultsToNotNoReferent() {
        let real = HallieTurnExecutor.Result(
            route: .graph, outcome: .declined,
            prose: "His siblings are Alice and Ben — I don't find Carl there.",
            basisLine: "Basis: checked 2 siblings of Frank by name.",
            queryDescription: nil, citations: [], catalogPersonName: nil)
        #expect(!real.noReferentDecline)
        #expect(!HallieCapabilityDeclineFallback.qualifies(real))
    }
}

// MARK: - Sensor: end-to-end through the app coordinator

/// Pins the exact behaviour that failed live on 2026-09-03 eve. If this ever
/// goes red, a real visitor's ordinary reflective question is dead-ending
/// again — see HallieCapabilityDeclineFallback.swift.
@MainActor
@Suite("Hallie dead-end decline falls through to general knowledge — sensor", .serialized)
struct HallieDeadEndGeneralKnowledgeFallbackSensorTests {

    private final class Recorder<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Value] = []
        func append(_ value: Value) { lock.withLock { storage.append(value) } }
        var values: [Value] { lock.withLock { storage } }
    }

    private func fixtureGraph() -> GedcomFamilyGraph {
        GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME Hallie Mae /Breen/
        0 TRLR
        """)
    }

    private func dependencies(
        archiveAST: ArchivistQueryAST,
        archiveResult: HallieTurnExecutor.Result,
        generalReplyText: String,
        generalComposedByModel: Bool = true,
        graph: GedcomFamilyGraph? = nil,
        composeCalls: Recorder<HallieConversationKind>
    ) -> HallieAppTurnCoordinator.Dependencies {
        HallieAppTurnCoordinator.Dependencies(
            startLocalBrain: { hosts in hosts },
            translateAST: { _, _, _ in
                .init(ast: archiveAST, responderHost: "fixture-host")
            },
            composeConversation: { kind, _, _, _, _ in
                composeCalls.append(kind)
                let reply = HallieSocialConversation.Reply(
                    text: generalReplyText,
                    composedByModel: generalComposedByModel,
                    note: "fixture general reply")
                return .init(value: reply, responderHost: "fixture-general-host")
            },
            loadProfiles: { [] },
            loadGraph: { graph },
            executeRequest: { _, _ in archiveResult },
            continueTurn: { clarification, selectedID, context in
                try await HallieTurnExecutor.continue(
                    pending: clarification, selecting: selectedID, context: context)
            },
            resolveBiographyPhoto: { _ in nil })
    }

    /// LIVE EXAMPLE 1: "why do old home videos feel so emotional" reached
    /// the archive lane (its "home video" wording is a hard archive cue),
    /// the model translated it into an event search, and the fixed
    /// unsupported-event decline is exactly the shape that must now retry.
    @Test func aDeadEndCapabilityDeclineFallsThroughToGeneralKnowledge() async throws {
        let decline = HallieTurnExecutor.Result(
            route: .unsupportedEvent, outcome: .unsupported,
            prose: "Event queries are not supported yet; I did not run a broader search.",
            basisLine: "Basis: no event-shaped query is implemented.",
            queryDescription: "event", citations: [], catalogPersonName: nil)
        let composeCalls = Recorder<HallieConversationKind>()
        let dependencies = dependencies(
            archiveAST: .event(.init(keywords: ["home", "videos"])),
            archiveResult: decline,
            generalReplyText: "Old footage often feels emotional because it is unrehearsed and unrepeatable.",
            composeCalls: composeCalls)

        let response = try await HallieAppTurnCoordinator.execute(
            question: "why do old home videos feel so emotional",
            records: [], referent: .init(recordID: nil, temporalDate: nil),
            hosts: ["fixture.invalid"], modelName: "fixture-model",
            dependencies: dependencies)

        #expect(composeCalls.values == [.generalKnowledge])
        #expect(response.result.outcome == .answered)
        #expect(response.result.prose != decline.prose)
        #expect(!response.result.prose.contains("not supported yet"))
        #expect(response.result.basisLine == HallieCapabilityDeclineFallback.basisLine)
    }

    /// LIVE EXAMPLE 2: a bare kinship word ("grandmother") the tree cannot
    /// resolve to anyone real also retries through general knowledge.
    @Test func aBareKinshipWordTreeMissFallsThroughToGeneralKnowledge() async throws {
        let base = HallieTurnExecutor.Result(
            route: .graph, outcome: .declined,
            prose: "I don't find \u{201C}grandmother\u{201D} in the family tree.",
            basisLine: "Basis: checked the family tree.",
            queryDescription: "graph", citations: [], catalogPersonName: nil)
        let decline = HallieTurnExecutor.FamilyKnowledgeSupplement.notFoundOffer(
            base, typed: "grandmother", graph: nil)
        let composeCalls = Recorder<HallieConversationKind>()
        let dependencies = dependencies(
            archiveAST: .graph(.init(people: ["grandmother"], operation: .biography)),
            archiveResult: decline,
            generalReplyText: "You could ask about a favorite recipe, a first job, or what the neighborhood was like.",
            composeCalls: composeCalls)

        let response = try await HallieAppTurnCoordinator.execute(
            question: "what questions could I ask my grandmother about her childhood",
            records: [], referent: .init(recordID: nil, temporalDate: nil),
            hosts: ["fixture.invalid"], modelName: "fixture-model",
            dependencies: dependencies)

        #expect(composeCalls.values == [.generalKnowledge])
        #expect(response.result.outcome == .answered)
        #expect(!response.result.prose.contains("I don't find"))
    }

    /// NEGATIVE: a genuine archive fact ("nothing from 1950-1959") must
    /// never fall through — it is a correct, informative answer.
    @Test func aRealArchiveFactDeclineIsNeverRetried() async throws {
        let decline = HallieTurnExecutor.Result(
            route: .temporal, outcome: .declined,
            prose: "I don't see anything from 1950\u{2013}1959.",
            basisLine: "Basis: searched the catalog for that decade; nothing matched.",
            queryDescription: "temporal", citations: [], catalogPersonName: nil)
        let composeCalls = Recorder<HallieConversationKind>()
        let dependencies = dependencies(
            archiveAST: .temporal(.init(subject: "catalog", operation: .age,
                                        reference: .currentSelection)),
            archiveResult: decline,
            generalReplyText: "should never be called",
            composeCalls: composeCalls)

        let response = try await HallieAppTurnCoordinator.execute(
            question: "show me videos from 1953",
            records: [], referent: .init(recordID: nil, temporalDate: nil),
            hosts: ["fixture.invalid"], modelName: "fixture-model",
            dependencies: dependencies)

        #expect(composeCalls.values.isEmpty)
        #expect(response.result.prose == decline.prose)
        #expect(response.result.outcome == .declined)
    }

    /// NEGATIVE: the boundary rejects the fallback answer (it names a real
    /// tree person) — the user must see the ORIGINAL decline, never a
    /// boundary refusal stacked on top of it.
    @Test func boundaryRejectionKeepsTheOriginalDecline() async throws {
        let decline = HallieTurnExecutor.Result(
            route: .unsupportedEvent, outcome: .unsupported,
            prose: "Event queries are not supported yet; I did not run a broader search.",
            basisLine: "Basis: no event-shaped query is implemented.",
            queryDescription: "event", citations: [], catalogPersonName: nil)
        let composeCalls = Recorder<HallieConversationKind>()
        let dependencies = dependencies(
            // "home video" is a hard archive cue (HallieGeneralKnowledgeLane),
            // so this reaches the archive lane and the decline below, exactly
            // like the other capability-decline test — the only difference
            // here is that the general lane's reply, once asked, names a
            // real tree person and must be rejected by the boundary.
            archiveAST: .event(.init(keywords: ["home", "videos"])),
            archiveResult: decline,
            generalReplyText: "Ask Hallie Mae Breen about it, she would remember it best.",
            graph: fixtureGraph(),
            composeCalls: composeCalls)

        let response = try await HallieAppTurnCoordinator.execute(
            question: "why do old home videos feel so emotional",
            records: [], referent: .init(recordID: nil, temporalDate: nil),
            hosts: ["fixture.invalid"], modelName: "fixture-model",
            dependencies: dependencies)

        #expect(composeCalls.values == [.generalKnowledge])
        #expect(response.result.prose == decline.prose)
        #expect(response.result.prose != HallieGeneralAnswerBoundary.replacement)
        #expect(response.result.outcome == .unsupported)
    }
}
