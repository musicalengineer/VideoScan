// HallieAssumedBridgeProvenanceTests.swift
// REGRESSION SENSOR (2026-09-03). "who is Rick's dad?" with Dad's tree
// identity only ASSUMED must say so out loud:
//
//   "Rick's father: Richard Harding Breen Sr (Dad in the People tab),
//    born 22 February 1929 … (taking Rick as Richard Harding Breen Jr;
//    Dad as Richard Harding Breen Sr)"
//
// The aside went silent on 2026-09-02 (35336f98) — not because anything
// about assumed bridges changed, but because the overlay kinship route
// gained a claim plan, and the executor had been moving the aside out of
// the prose and into the basis whenever a plan was present. The assumption
// is PROVENANCE (how Hallie read the question), not a claim about the
// family, so it now rides on the plan's `provenanceNote`: Swift appends it
// to the template wording and re-appends it after verification, and the
// verifier is never asked to prove it.
//
// Dimensions: LOGIC (the aside is carried, and is not a claim) + SENSOR
// (the composed path — the one that regressed — is pinned end to end).
// ISOLATION: synthetic GEDCOM text and profile snapshots, no files, no
// UserDefaults, no model.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private let treeText = """
0 HEAD
1 _VS_MERGED Y
1 _VS_ROOT @I1@
0 @I1@ INDI
1 NAME Richard Harding /Breen/ Jr
1 SEX M
1 BIRT
2 DATE 4 MAR 1959
1 FAMC @F1@
1 _FSFTID GVQV-NW3
0 @I2@ INDI
1 NAME Richard Harding /Breen/ Sr
1 SEX M
1 BIRT
2 DATE 22 FEB 1929
2 PLAC Albany, New York
1 DEAT
2 DATE 1 JUL 2008
1 FAMS @F1@
1 _FSFTID G2S4-JF4
0 @F1@ FAM
1 HUSB @I2@
1 CHIL @I1@
0 TRLR
"""

private let graph = GedcomFamilyGraph(gedcomText: treeText)

private typealias Profile = HallieTurnExecutor.ProfileSnapshot
private typealias Executor = HallieTurnExecutor

/// The aside the deriver produces for this fixture, in evidence order:
/// the subject first, then the relative reached.
private let expectedAside =
    " (taking Rick as Richard Harding Breen Jr; Dad as Richard Harding Breen Sr)"

private let assumedBridges = [
    "@I1@": "Rick as Richard Harding Breen Jr",
    "@I2@": "Dad as Richard Harding Breen Sr",
]

private func row(_ relation: KinshipRelation, _ name: String) -> Kinship {
    Kinship(relation: relation, relativeTo: .profile(name: name))
}

/// Rick's People-tab rows: Rick is the child of Dad. Both profiles carry
/// the tree identity the deriver would have ASSUMED for the turn — that is
/// exactly the state `TreeIdentityDeriver.assumingCertainPins` hands over.
private func profiles() -> [Profile] {
    [
        Profile(stableID: "rick", canonicalName: "Rick",
                kinships: [row(.child, "Dad")],
                sex: .male, uuid: UUID(),
                treeIdentity: .familySearchID("GVQV-NW3")),
        Profile(stableID: "dad", canonicalName: "Dad", aliases: ["Dick"],
                sex: .male, uuid: UUID(),
                treeIdentity: .familySearchID("G2S4-JF4")),
    ]
}

private func context(assumed: [String: String]) -> Executor.Context {
    Executor.Context(
        profiles: profiles(), graph: graph,
        speakers: .init(ownerName: "Rick Breen", archivistName: "Hallie Mae",
                        ownerFamilySearchID: "GVQV-NW3"),
        assumedTreeBridges: assumed)
}

private func askFather(assumed: [String: String]) async throws -> Executor.Result {
    try await Executor.execute(
        .graph(.init(people: ["Rick"], operation: .kinship, relation: .father)),
        context: context(assumed: assumed))
}

/// A model that says nothing, so the template answer ships.
private func silentComposer() -> HallieGroundedComposer {
    HallieGroundedComposer(personaName: "Hallie", timeoutSeconds: 30) { _, _ in "" }
}

/// A model that echoes each claim back verbatim with its tag — the best
/// case for the verifier, so anything missing from the answer is missing
/// because the pipeline dropped it, not because the wording failed.
private func composer(echoing plan: HallieAnswerPlan) -> HallieGroundedComposer {
    HallieGroundedComposer(personaName: "Hallie", timeoutSeconds: 30) { _, _ in
        plan.claims.map { "\($0.text) [\($0.id)]" }.joined(separator: " ")
    }
}

@Suite("Assumed tree bridge — provenance, not a claim")
struct HallieAssumedBridgeProvenanceTests {

    /// The template answer says the assumption out loud, at the end.
    @Test func theTemplateAnswerCarriesTheAside() async throws {
        let r = try await askFather(assumed: assumedBridges)
        #expect(r.outcome == .answered, Comment(rawValue: r.prose))
        #expect(r.prose.hasSuffix(expectedAside), Comment(rawValue: r.prose))
        // Said once, in the answer — not doubled into the basis line.
        #expect(r.prose.components(separatedBy: " (taking ").count == 2,
                Comment(rawValue: r.prose))
        #expect(!r.basisLine.contains("aking "), Comment(rawValue: r.basisLine))
    }

    /// The regression itself: a route that carries a claim plan must not
    /// lose the aside. This is the shape that broke on 2026-09-02 — the
    /// overlay kinship answer gained a plan and the aside went silent.
    @Test func aPlanCarryingRouteStillSaysIt() async throws {
        let r = try await askFather(assumed: assumedBridges)
        let plan = try #require(r.answerPlan, "the kinship route must carry its claim plan")
        #expect(plan.provenanceNote == expectedAside)
        #expect(plan.fallbackText.hasSuffix(expectedAside), Comment(rawValue: plan.fallbackText))
    }

    /// Provenance is NOT a claim: nothing the verifier must prove, nothing
    /// the model is asked to say, nobody added to the required names.
    @Test func theAsideIsNeverAClaim() async throws {
        let r = try await askFather(assumed: assumedBridges)
        let plan = try #require(r.answerPlan)
        for claim in plan.claims {
            #expect(!claim.text.contains("taking "), Comment(rawValue: claim.text))
        }
        let prompt = HallieGroundedComposer.userPrompt(plan: plan, history: [])
        #expect(!prompt.contains("(taking "), Comment(rawValue: prompt))
        // The tree name is still owed; the assumption adds nobody.
        #expect(plan.requiredPersonNames == ["Richard Harding Breen Sr"])
    }

    /// SENSOR: the composed path. A model phrases the plan, the verifier
    /// runs, and the assumption is still there — appended by Swift after
    /// verification, exactly once, at the end.
    @Test func theAsideSurvivesModelComposition() async throws {
        let r = try await askFather(assumed: assumedBridges)
        let plan = try #require(r.answerPlan)
        let outcome = await composer(echoing: plan).compose(plan: plan, history: [])
        #expect(outcome.composedBy == .model, Comment(rawValue: outcome.note))
        #expect(outcome.displayText.hasSuffix(expectedAside),
                Comment(rawValue: outcome.displayText))
        #expect(outcome.transcriptText.hasSuffix(expectedAside),
                Comment(rawValue: outcome.transcriptText))
        #expect(outcome.displayText.components(separatedBy: " (taking ").count == 2,
                Comment(rawValue: outcome.displayText))
        // And the applied answer — what the bubble shows — keeps it.
        #expect(r.applying(outcome).prose.hasSuffix(expectedAside))
    }

    /// SENSOR: the fallback path. The model fails, the template ships, and
    /// the assumption is still there exactly once.
    @Test func theAsideSurvivesAModelFailure() async throws {
        let r = try await askFather(assumed: assumedBridges)
        let plan = try #require(r.answerPlan)
        let outcome = await silentComposer().compose(plan: plan, history: [])
        #expect(outcome.composedBy == .template, Comment(rawValue: outcome.note))
        #expect(outcome.displayText.hasSuffix(expectedAside),
                Comment(rawValue: outcome.displayText))
        #expect(outcome.displayText.components(separatedBy: " (taking ").count == 2,
                Comment(rawValue: outcome.displayText))
    }

    /// Nothing assumed → nothing said, and the plan is untouched. The
    /// aside must never become boilerplate on a pinned answer.
    @Test func nothingIsSaidWhenNothingWasAssumed() async throws {
        let r = try await askFather(assumed: [:])
        #expect(!r.prose.contains("(taking "), Comment(rawValue: r.prose))
        let plan = try #require(r.answerPlan)
        #expect(plan.provenanceNote == nil)
        let outcome = await composer(echoing: plan).compose(plan: plan, history: [])
        #expect(!outcome.displayText.contains("(taking "),
                Comment(rawValue: outcome.displayText))
    }

    /// A two-question turn ("who is Rick's dad? and who is his father's
    /// father?") flattens both plans into one. Provenance carries no claim
    /// ID, so it must ride along rather than be renumbered away — and the
    /// same bridge assumed by both halves is said once.
    @Test func provenanceSurvivesATwoQuestionJoin() async throws {
        let a = try await askFather(assumed: assumedBridges)
        let b = try await askFather(assumed: assumedBridges)
        let joined = Executor.joinedTwoQuestionAnswer(a, b)
        let plan = try #require(joined.answerPlan)
        #expect(plan.provenanceNote == expectedAside)
        // Both halves' prose already ends with the aside; the join must not
        // append a third copy to the template wording.
        #expect(plan.fallbackText == joined.prose, Comment(rawValue: plan.fallbackText))
        let outcome = await composer(echoing: plan).compose(plan: plan, history: [])
        #expect(outcome.displayText.hasSuffix(expectedAside),
                Comment(rawValue: outcome.displayText))
    }

    /// `carrying(provenance:)` is idempotent: an answer that passes through
    /// two wrappers never says the assumption twice.
    @Test func carryingTheSameProvenanceTwiceIsIdempotent() async throws {
        let r = try await askFather(assumed: assumedBridges)
        let twice = r.carryingProvenance(expectedAside)
        #expect(twice.prose == r.prose, Comment(rawValue: twice.prose))
        #expect(twice.answerPlan?.fallbackText == r.answerPlan?.fallbackText)
    }
}
