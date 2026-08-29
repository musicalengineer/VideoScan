import Foundation
import Testing
@testable import VideoScan

/// Regression sensors for two CyberBrain wiring defects in the shared turn
/// executor:
///
/// 1. A GEDCOM ambiguity chip was continued BY NAME, so same-name people
///    (Sr./Jr.) stayed ambiguous forever and a GEDCOM name that collided with
///    a CyberBrain alias could answer for the wrong person.
/// 2. Installing any cyberbrain.json rerouted EVERY biography through the
///    planner, which never consulted People profiles and hard-rejected
///    `.profileStableID` continuations. "Who is Rick?" (profile alias →
///    canonical name → GEDCOM) worked without a CyberBrain and stopped once
///    one was installed.
@MainActor
@Suite("Hallie executor CyberBrain regressions", .serialized)
struct HallieTurnExecutorCyberBrainRegressionTests {
    private static let familyTree = """
    0 HEAD
    0 @I1@ INDI
    1 NAME Richard /Breen/
    1 SEX M
    1 BIRT
    2 DATE 12 MAR 1931
    1 FAMS @F1@
    0 @I2@ INDI
    1 NAME Richard /Breen/
    1 SEX M
    1 BIRT
    2 DATE 4 JUL 1962
    1 FAMC @F1@
    0 @I3@ INDI
    1 NAME Mary /Breen/
    1 SEX F
    1 FAMS @F1@
    0 @I4@ INDI
    1 NAME Rick /Jones/
    1 SEX M
    1 BIRT
    2 DATE 9 SEP 1970
    0 @I5@ INDI
    1 NAME Ellen /Stone/
    1 SEX F
    1 BIRT
    2 DATE 1 JAN 1940
    0 @F1@ FAM
    1 HUSB @I1@
    1 WIFE @I3@
    1 CHIL @I2@
    0 TRLR
    """

    private var graph: GedcomFamilyGraph {
        GedcomFamilyGraph(gedcomText: Self.familyTree)
    }

    /// A CyberBrain that knows nobody named in the tree above except through
    /// an unrelated alias collision used by one test.
    private func cyberBrain(
        aliasCollision: Bool = false
    ) throws -> CyberBrainIndex {
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        let source = CyberBrainSource(
            id: "source.other",
            type: .familyWitness,
            title: "Synthetic interview",
            attribution: nil,
            locator: nil)
        let passage = CyberBrainItem(
            id: "bio.other",
            kind: .biography,
            text: "Jordan Other restored radios.",
            subjectPersonIDs: ["person.other"],
            sourceIDs: [source.id],
            confidence: .confirmed,
            privacy: .family,
            createdAt: instant,
            updatedAt: instant)
        return try CyberBrainIndex(archive: .init(
            archiveID: "regression-fixture",
            displayName: "Regression fixture CyberBrain",
            people: [
                CyberBrainPerson(
                    id: "person.other",
                    canonicalName: "Jordan Other",
                    aliases: aliasCollision ? ["Jordy", "Richard Breen"] : ["Jordy"],
                    biographyPassages: [passage]),
            ],
            sources: [source]))
    }

    private func biography(_ name: String) -> HallieTurnExecutor.Intent {
        HallieTurnExecutor.Intent(
            originalQuestion: "Who is \(name)?",
            ast: .graph(.init(people: [name], operation: .biography)))
    }

    private let rickProfile = HallieTurnExecutor.ProfileSnapshot(
        stableID: "profile-rick",
        canonicalName: "Richard Breen",
        aliases: ["Rick"])

    // MARK: MAJOR-1 — GEDCOM ambiguity continues by pointer, not by name

    @Test func sameNameGedcomPeopleGetDistinctLabelsAndContinueByPointer() async throws {
        let context = HallieTurnExecutor.Context(
            profiles: [], graph: graph, cyberBrain: try cyberBrain())
        let first = try await HallieTurnExecutor.execute(
            .init(intent: biography("Richard Breen")), context: context)
        let pending = try #require(first.clarification)

        #expect(first.outcome == .needsClarification)
        #expect(pending.stage == .gedcomPerson)
        #expect(pending.candidates.map(\.id) == [
            .gedcomPersonID("@I1@"), .gedcomPersonID("@I2@"),
        ])
        let labels = pending.candidates.map(\.label)
        #expect(Set(labels).count == labels.count)
        #expect(labels[0].contains("1931"))
        #expect(labels[1].contains("1962"))

        let junior = try await HallieTurnExecutor.continue(
            pending: pending,
            selecting: .gedcomPersonID("@I2@"),
            context: context)
        #expect(junior.outcome == .answered)
        #expect(junior.clarification == nil)
        #expect(junior.prose.contains("4 July 1962"))
        #expect(junior.prose.contains("child of Mary Breen and Richard Breen"))
        #expect(!junior.prose.contains("12 March 1931"))
        #expect(junior.catalogPersonName == "Richard Breen")

        let senior = try await HallieTurnExecutor.continue(
            pending: pending,
            selecting: .gedcomPersonID("@I1@"),
            context: context)
        #expect(senior.outcome == .answered)
        #expect(senior.clarification == nil)
        #expect(senior.prose.contains("12 March 1931"))
        #expect(senior.prose.contains("married to Mary Breen"))
        #expect(!senior.prose.contains("4 July 1962"))
    }

    /// The same two turns must produce the same answer with and without a
    /// CyberBrain installed: the planner must not shadow the GEDCOM path.
    @Test func gedcomPointerContinuationMatchesNoCyberBrainBehavior() async throws {
        let withBrain = HallieTurnExecutor.Context(
            profiles: [], graph: graph, cyberBrain: try cyberBrain())
        let without = HallieTurnExecutor.Context(
            profiles: [], graph: graph, cyberBrain: nil)

        var answers: [HallieTurnExecutor.Result] = []
        for context in [withBrain, without] {
            let first = try await HallieTurnExecutor.execute(
                .init(intent: biography("Richard Breen")), context: context)
            let pending = try #require(first.clarification)
            answers.append(try await HallieTurnExecutor.continue(
                pending: pending,
                selecting: .gedcomPersonID("@I2@"),
                context: context))
        }
        #expect(answers[0].outcome == .answered)
        #expect(answers[0].prose == answers[1].prose)
        #expect(answers[0].basisLine == answers[1].basisLine)
        #expect(answers[0].catalogPersonName == answers[1].catalogPersonName)
    }

    /// Alias collision sensor: when the typed name IS a CyberBrain alias, the
    /// CyberBrain person answers (by design), and no GEDCOM chip is offered
    /// that a name-based continuation could later misroute. The
    /// pointer-typed planner entry (`plan(gedcomPersonID:)`) is pinned in
    /// Core's CyberBrainPlannerGedcomIDTests.
    @Test func cyberBrainAliasCollisionAnswersForCyberBrainPersonOnly() async throws {
        let context = HallieTurnExecutor.Context(
            profiles: [], graph: graph, cyberBrain: try cyberBrain(aliasCollision: true))
        let result = try await HallieTurnExecutor.execute(
            .init(intent: biography("Richard Breen")), context: context)

        #expect(result.outcome == .answered)
        #expect(result.clarification == nil)
        #expect(result.catalogPersonName == "Jordan Other")
        #expect(result.prose.contains("restored radios"))
        #expect(!result.prose.contains("1931"))
        #expect(!result.prose.contains("1962"))
    }

    // MARK: MAJOR-2 — installed CyberBrain must not regress profile → GEDCOM

    @Test func profileAliasBridgesToGedcomWithCyberBrainInstalled() async throws {
        let withBrain = HallieTurnExecutor.Context(
            profiles: [rickProfile], graph: graph, cyberBrain: try cyberBrain())
        let without = HallieTurnExecutor.Context(
            profiles: [rickProfile], graph: graph, cyberBrain: nil)

        let brainResult = try await HallieTurnExecutor.execute(
            .init(intent: biography("Rick")), context: withBrain)
        let plainResult = try await HallieTurnExecutor.execute(
            .init(intent: biography("Rick")), context: without)

        // "Rick" → profile "Richard Breen" → two GEDCOM Richard Breens: the
        // pre-existing path asks which one; the CyberBrain path must not
        // instead say it doesn't know Rick.
        #expect(plainResult.outcome == .needsClarification)
        #expect(brainResult.outcome == plainResult.outcome)
        #expect(brainResult.prose == plainResult.prose)
        #expect(brainResult.basisLine == plainResult.basisLine)
        #expect(brainResult.clarification?.stage == .gedcomPerson)
        #expect(brainResult.clarification?.candidates.map(\.id)
                == plainResult.clarification?.candidates.map(\.id))
        #expect(!brainResult.prose.contains("don't find"))
    }

    @Test func profileAliasToUniqueGedcomPersonAnswersWithGedcomBasis() async throws {
        let ellen = HallieTurnExecutor.ProfileSnapshot(
            stableID: "profile-ellen",
            canonicalName: "Ellen Stone",
            aliases: ["Nana"])
        let withBrain = HallieTurnExecutor.Context(
            profiles: [ellen], graph: graph, cyberBrain: try cyberBrain())
        let without = HallieTurnExecutor.Context(
            profiles: [ellen], graph: graph, cyberBrain: nil)

        let brainResult = try await HallieTurnExecutor.execute(
            .init(intent: biography("Nana")), context: withBrain)
        let plainResult = try await HallieTurnExecutor.execute(
            .init(intent: biography("Nana")), context: without)

        #expect(plainResult.outcome == .answered)
        #expect(brainResult.outcome == .answered)
        #expect(brainResult.prose == plainResult.prose)
        #expect(brainResult.basisLine == plainResult.basisLine)
        #expect(brainResult.basisLine.contains("GEDCOM"))
        #expect(brainResult.prose.contains("1 January 1940"))
        #expect(brainResult.catalogPersonName == "Ellen Stone")
        #expect(brainResult.knowledgeCitations.isEmpty)
    }

    @Test func profileStableIDContinuationIsHonoredWithCyberBrainInstalled() async throws {
        let profiles = [
            rickProfile,
            HallieTurnExecutor.ProfileSnapshot(
                stableID: "profile-jones",
                canonicalName: "Rick Jones",
                aliases: ["Rick"]),
        ]
        let context = HallieTurnExecutor.Context(
            profiles: profiles, graph: graph, cyberBrain: try cyberBrain())
        let first = try await HallieTurnExecutor.execute(
            .init(intent: biography("Rick")), context: context)
        let pending = try #require(first.clarification)

        #expect(first.outcome == .needsClarification)
        #expect(pending.stage == .profileIdentity)
        #expect(pending.candidates.map(\.id) == [
            .profileStableID("profile-rick"),
            .profileStableID("profile-jones"),
        ])

        let continued = try await HallieTurnExecutor.continue(
            pending: pending,
            selecting: .profileStableID("profile-jones"),
            context: context)
        #expect(continued.outcome == .answered)
        #expect(continued.clarification == nil)
        #expect(continued.prose.contains("Rick Jones"))
        #expect(continued.prose.contains("9 September 1970"))
        #expect(!continued.prose.contains("no longer available"))
        #expect(continued.catalogPersonName == "Rick Jones")
    }

    /// Explicit sensor: with no CyberBrain the executor still takes the
    /// profiles + GEDCOM path and never mentions CyberBrain.
    @Test func noCyberBrainKeepsProfileAndGedcomPath() async throws {
        let context = HallieTurnExecutor.Context(
            profiles: [rickProfile], graph: graph, cyberBrain: nil)
        let result = try await HallieTurnExecutor.execute(
            .init(intent: biography("Rick")), context: context)

        #expect(result.outcome == .needsClarification)
        #expect(result.clarification?.stage == .gedcomPerson)
        #expect(!result.basisLine.contains("CyberBrain"))
        #expect(!result.prose.contains("CyberBrain"))
        #expect(result.knowledgeCitations.isEmpty)
    }

    /// When CyberBrain does know the name it still answers first, even with
    /// profiles and a GEDCOM present — the fallthrough is only for `.notFound`.
    @Test func cyberBrainStillAnswersWhenItKnowsTheName() async throws {
        let context = HallieTurnExecutor.Context(
            profiles: [rickProfile], graph: graph, cyberBrain: try cyberBrain())
        let result = try await HallieTurnExecutor.execute(
            .init(intent: biography("Jordy")), context: context)

        #expect(result.outcome == .answered)
        #expect(result.catalogPersonName == "Jordan Other")
        #expect(result.basisLine.contains("CyberBrain"))
        #expect(result.knowledgeCitations.map(\.id) == ["source.other"])
    }
}
