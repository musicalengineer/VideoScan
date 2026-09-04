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
//        search." (an unsupported-event decline)
//   "what questions could I ask my grandmother about her childhood"
//     -> a tree lookup on the bare kinship word "grandmother" declining with
//        "I don't find … in the family tree." (a no-referent decline)
// Both now retry once through the general-knowledge lane instead — but ONLY
// because both questions are reflective/advisory in shape. Independent
// review 2026-09-04 caught that the qualification rule, checked on outcome
// alone, was far too wide: it would also swap an honest `.capability`
// answer, a real retrieval that happened to translate into an
// unsupported-event AST, and an unknown-name lookup for generic chat. The
// rule now requires BOTH the decline shape AND the question shape.

import Foundation
import Testing
@testable import VideoScan

// MARK: - Logic: the pure qualification rule

@Suite("Hallie capability/no-referent decline fallback — logic")
struct HallieCapabilityDeclineFallbackLogicTests {

    private func result(
        route: HallieTurnExecutor.Route = .graph,
        outcome: HallieTurnExecutor.Outcome,
        noReferentDecline: Bool = false
    ) -> HallieTurnExecutor.Result {
        HallieTurnExecutor.Result(
            route: route, outcome: outcome, prose: "fixture", basisLine: "fixture",
            queryDescription: nil, citations: [], catalogPersonName: nil,
            noReferentDecline: noReferentDecline)
    }

    private static let reflective = "why do old home videos feel so emotional"
    private static let retrieval = "find birthday parties"

    @Test func unsupportedEventWithReflectiveQuestionQualifies() {
        #expect(HallieCapabilityDeclineFallback.qualifies(
            result(route: .unsupportedEvent, outcome: .unsupported),
            question: Self.reflective))
    }

    /// The exact bug caught in review: `.capability` also returns
    /// `.unsupported` for a perfectly good, offer-bearing answer
    /// ("I can't edit biographies yet…", "I'm read-only") and must never be
    /// swapped for free chat, whatever the question's shape.
    @Test func capabilityRouteNeverQualifiesEvenForAReflectiveQuestion() {
        #expect(!HallieCapabilityDeclineFallback.qualifies(
            result(route: .capability, outcome: .unsupported),
            question: Self.reflective))
    }

    @Test func declinedWithNoReferentFlagAndReflectiveQuestionQualifies() {
        #expect(HallieCapabilityDeclineFallback.qualifies(
            result(outcome: .declined, noReferentDecline: true),
            question: "what questions could I ask my grandmother about her childhood"))
    }

    /// A no-referent decline on a plain RETRIEVAL question ("who is Jonathan
    /// Smith") must not qualify — the question shape gate, not just the
    /// decline shape, is required.
    @Test func declinedWithNoReferentFlagButRetrievalQuestionNeverQualifies() {
        #expect(!HallieCapabilityDeclineFallback.qualifies(
            result(outcome: .declined, noReferentDecline: true),
            question: "who is Jonathan Smith"))
    }

    /// An unsupported-event decline on a retrieval question ("find birthday
    /// parties") must not qualify either — the decline shape alone is not
    /// enough when the question itself was a lookup, not a reflection.
    @Test func unsupportedEventWithRetrievalQuestionNeverQualifies() {
        #expect(!HallieCapabilityDeclineFallback.qualifies(
            result(route: .unsupportedEvent, outcome: .unsupported),
            question: Self.retrieval))
    }

    @Test(arguments: [
        HallieTurnExecutor.Outcome.answered,
        .needsClarification,
        .failed,
        .repaired,
    ])
    func everyOtherOutcomeNeverQualifies(outcome: HallieTurnExecutor.Outcome) {
        #expect(!HallieCapabilityDeclineFallback.qualifies(
            result(route: .unsupportedEvent, outcome: outcome), question: Self.reflective))
    }

    /// NEGATIVE — the shape that matters most: a real archive fact declined
    /// plainly ("nothing from 1950-1959", "I don't find Frank among his
    /// three siblings") never sets the flag and must never fall through,
    /// whatever the question's shape.
    @Test func plainDeclineWithoutTheFlagNeverQualifies() {
        #expect(!HallieCapabilityDeclineFallback.qualifies(
            result(outcome: .declined), question: Self.reflective))
    }

    // MARK: isReflectiveOrAdvisoryQuestion

    @Test(arguments: [
        "why do old home videos feel so emotional",
        "what questions could I ask my grandmother about her childhood",
        "how do I start a family history project",
        "give me advice on preserving family memories",
        "what makes home movies feel nostalgic",
    ])
    func reflectiveOrAdvisoryQuestionsAreRecognised(question: String) {
        #expect(HallieCapabilityDeclineFallback.isReflectiveOrAdvisoryQuestion(question))
    }

    @Test(arguments: [
        "find birthday parties",
        "who is Jonathan Smith",
        "show me videos from 1953",
        "can you edit my biography",
        "play Donna at Christmas",
    ])
    func retrievalAndCapabilityQuestionsAreNotReflective(question: String) {
        #expect(!HallieCapabilityDeclineFallback.isReflectiveOrAdvisoryQuestion(question))
    }

    /// Defense in depth: a reflective OPENING with a concrete referent
    /// (a catalog-range year) is a retrieval in disguise and must not
    /// qualify, even though it starts with "why".
    @Test func reflectiveOpeningWithACatalogYearIsNotReflective() {
        #expect(!HallieCapabilityDeclineFallback.isReflectiveOrAdvisoryQuestion(
            "why did we visit the Cape in 1994"))
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
        #expect(HallieCapabilityDeclineFallback.qualifies(
            offered, question: "what questions could I ask my grandmother about her childhood"))
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
        #expect(!HallieCapabilityDeclineFallback.qualifies(
            real, question: "why do old home videos feel so emotional"))
    }
}

// MARK: - Sensor: end-to-end through the app coordinator

/// Pins the exact behaviour that failed live on 2026-09-03 eve, AND the
/// three near-miss shapes an independent review caught on 2026-09-04 (an
/// honest capability answer, a retrieval mistranslated as an unsupported
/// event, and an unknown-name lookup) that must never be swapped for free
/// chat. If any of these ever goes red, either a real visitor's reflective
/// question is dead-ending again, or a real answer/decline is being
/// replaced by generic chat — see HallieCapabilityDeclineFallback.swift.
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

    /// NEGATIVE (independent review, 2026-09-04): an honest `.capability`
    /// answer — "I can't edit biographies or family facts yet…" — carries
    /// its own offered action and must never be swapped for free chat, even
    /// though it shares the `.unsupported` outcome with the event decline.
    ///
    /// This question is caught by the DETERMINISTIC capability detector
    /// before any translation runs at all (`ArchivistCapabilityQuestion` /
    /// `HallieTurnExecutor.preTranslation`'s `.answer` case) — a stronger
    /// guarantee than the fallback rule alone, and exactly why it must
    /// never reach `composeConversation`. The mocked `archiveResult` below
    /// is never consulted; this asserts against the REAL, production
    /// capability text.
    @Test func aCapabilityAnswerIsNeverRetried() async throws {
        let composeCalls = Recorder<HallieConversationKind>()
        let dependencies = dependencies(
            archiveAST: .event(.init(keywords: ["edit"])),
            archiveResult: HallieTurnExecutor.Result(
                route: .capability, outcome: .unsupported,
                prose: "SENTINEL: mocked archive result must never be reached",
                basisLine: "fixture", queryDescription: nil, citations: [], catalogPersonName: nil),
            generalReplyText: "should never be called",
            composeCalls: composeCalls)

        let response = try await HallieAppTurnCoordinator.execute(
            question: "can you edit my biography",
            records: [], referent: .init(recordID: nil, temporalDate: nil),
            hosts: ["fixture.invalid"], modelName: "fixture-model",
            dependencies: dependencies)

        #expect(composeCalls.values.isEmpty)
        #expect(response.result.outcome == .unsupported)
        #expect(response.result.prose.contains("I can't edit biographies"))
    }

    /// NEGATIVE (independent review, 2026-09-04): a read-only media-action
    /// decline is also `.capability`/`.unsupported` and must keep its own
    /// answer. Also caught before translation by the deterministic
    /// capability detector; asserts against the REAL production text.
    @Test func aReadOnlyMediaActionCapabilityAnswerIsNeverRetried() async throws {
        let composeCalls = Recorder<HallieConversationKind>()
        let dependencies = dependencies(
            archiveAST: .event(.init(keywords: ["delete"])),
            archiveResult: HallieTurnExecutor.Result(
                route: .capability, outcome: .unsupported,
                prose: "SENTINEL: mocked archive result must never be reached",
                basisLine: "fixture", queryDescription: nil, citations: [], catalogPersonName: nil),
            generalReplyText: "should never be called",
            composeCalls: composeCalls)

        let response = try await HallieAppTurnCoordinator.execute(
            question: "please delete this video",
            records: [], referent: .init(recordID: nil, temporalDate: nil),
            hosts: ["fixture.invalid"], modelName: "fixture-model",
            dependencies: dependencies)

        #expect(composeCalls.values.isEmpty)
        #expect(response.result.outcome == .unsupported)
        #expect(response.result.prose.contains("read-only"))
    }

    /// NEGATIVE (independent review, 2026-09-04): a real retrieval that
    /// happens to translate into an unsupported-event AST ("find birthday
    /// parties") must keep its honest "not supported yet" decline, never
    /// generic prose about parties in general.
    @Test func aRetrievalThatTranslatesToUnsupportedEventIsNeverRetried() async throws {
        let decline = HallieTurnExecutor.Result(
            route: .unsupportedEvent, outcome: .unsupported,
            prose: "Event queries are not supported yet; I did not run a broader search.",
            basisLine: "Basis: no event-shaped query is implemented.",
            queryDescription: "event", citations: [], catalogPersonName: nil)
        let composeCalls = Recorder<HallieConversationKind>()
        let dependencies = dependencies(
            archiveAST: .event(.init(keywords: ["birthday", "parties"])),
            archiveResult: decline,
            generalReplyText: "Birthday parties are often full of cake, games, and balloons.",
            composeCalls: composeCalls)

        let response = try await HallieAppTurnCoordinator.execute(
            question: "find birthday parties",
            records: [], referent: .init(recordID: nil, temporalDate: nil),
            hosts: ["fixture.invalid"], modelName: "fixture-model",
            dependencies: dependencies)

        #expect(composeCalls.values.isEmpty)
        #expect(response.result.prose == decline.prose)
        #expect(response.result.outcome == .unsupported)
    }

    /// NEGATIVE (independent review, 2026-09-04): a lookup on an unknown but
    /// real-shaped proper name must keep its decline — the family boundary
    /// only recognises names it knows, so uncited prose about an unknown
    /// name would slip past it uncaught.
    @Test func anUnknownProperNameLookupIsNeverRetried() async throws {
        let base = HallieTurnExecutor.Result(
            route: .graph, outcome: .declined,
            prose: "I don't find \u{201C}Jonathan Smith\u{201D} in the family tree.",
            basisLine: "Basis: checked the family tree.",
            queryDescription: "graph", citations: [], catalogPersonName: nil)
        let decline = HallieTurnExecutor.FamilyKnowledgeSupplement.notFoundOffer(
            base, typed: "Jonathan Smith", graph: nil)
        let composeCalls = Recorder<HallieConversationKind>()
        let dependencies = dependencies(
            archiveAST: .graph(.init(people: ["Jonathan Smith"], operation: .biography)),
            archiveResult: decline,
            generalReplyText: "Jonathan Smith is a common name with no single notable bearer.",
            composeCalls: composeCalls)

        let response = try await HallieAppTurnCoordinator.execute(
            question: "who is Jonathan Smith",
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
