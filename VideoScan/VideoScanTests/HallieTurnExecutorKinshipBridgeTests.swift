import Foundation
import Testing
@testable import VideoScan

/// Sensors for the kinship / birth / death identity bridge.
///
/// Rick (Hallie log 2026-08-17): "who is rick?" answered through CyberBrain,
/// but "who is rick's dad?" said "I don't find 'rick' in the family tree —
/// try a fuller name". Only the biography route consulted CyberBrain's
/// nickname → GEDCOM pointer bridge; kinship went straight to the profiles +
/// GEDCOM path, whose profile ("Rick") had no bridge of its own. The two
/// routes now share the bridge, the ambiguity chips (distinct labels for the
/// two Richard Harding Breens), and the typed continuation.
@MainActor
@Suite("Hallie executor kinship identity bridge", .serialized)
struct HallieTurnExecutorKinshipBridgeTests {
    private static let familyTree = """
    0 HEAD
    0 @I1@ INDI
    1 NAME Richard Harding /Breen/ Sr
    1 SEX M
    1 BIRT
    2 DATE 12 MAR 1931
    1 FAMS @F1@
    0 @I2@ INDI
    1 NAME Richard Harding /Breen/ Jr
    1 SEX M
    1 BIRT
    2 DATE 4 JUL 1962
    1 FAMC @F1@
    1 FAMS @F2@
    0 @I3@ INDI
    1 NAME Mary /Breen/
    1 SEX F
    1 FAMS @F1@
    0 @I4@ INDI
    1 NAME Donna /Breen/
    1 SEX F
    1 FAMS @F2@
    0 @I5@ INDI
    1 NAME Timothy /Breen/
    1 SEX M
    1 FAMC @F2@
    0 @F1@ FAM
    1 HUSB @I1@
    1 WIFE @I3@
    1 CHIL @I2@
    0 @F2@ FAM
    1 HUSB @I2@
    1 WIFE @I4@
    1 CHIL @I5@
    0 TRLR
    """

    private var graph: GedcomFamilyGraph {
        GedcomFamilyGraph(gedcomText: Self.familyTree)
    }

    private func person(
        _ id: String, _ name: String, aliases: [String], gedcom: String?
    ) -> CyberBrainPerson {
        CyberBrainPerson(
            id: id, gedcomPersonID: gedcom, canonicalName: name, aliases: aliases)
    }

    /// One "Rick" who is linked to the Jr. pointer.
    private func brainWithOneRick() throws -> CyberBrainIndex {
        try CyberBrainIndex(archive: .init(
            archiveID: "kinship-fixture",
            displayName: "Kinship fixture",
            people: [
                person("person.rick.jr", "Richard Harding Breen Jr.",
                       aliases: ["Rick", "Ricky"], gedcom: "@I2@"),
                person("person.donna", "Donna Breen",
                       aliases: ["Donna", "Mom"], gedcom: "@I4@"),
            ],
            sources: []))
    }

    /// Two people answer to "Rick": Sr. and Jr., both linked.
    private func brainWithTwoRicks() throws -> CyberBrainIndex {
        try CyberBrainIndex(archive: .init(
            archiveID: "kinship-fixture-2",
            displayName: "Kinship fixture (two Ricks)",
            people: [
                person("person.rick.sr", "Richard Harding Breen",
                       aliases: ["Rick", "Big Rick"], gedcom: "@I1@"),
                person("person.rick.jr", "Richard Harding Breen",
                       aliases: ["Rick", "Ricky"], gedcom: "@I2@"),
            ],
            sources: []))
    }

    private func kinship(
        _ name: String, _ relation: ArchivistQueryAST.Graph.Relation
    ) -> HallieTurnExecutor.Intent {
        HallieTurnExecutor.Intent(
            originalQuestion: "who is \(name)'s \(relation.rawValue)?",
            ast: .graph(.init(people: [name], operation: .kinship,
                              relation: relation)))
    }

    private func biography(_ name: String) -> HallieTurnExecutor.Intent {
        HallieTurnExecutor.Intent(
            originalQuestion: "who is \(name)?",
            ast: .graph(.init(people: [name], operation: .biography)))
    }

    private let rickProfile = HallieTurnExecutor.ProfileSnapshot(
        stableID: "profile-rick", canonicalName: "Rick", aliases: [])

    // MARK: The reported turn

    @Test func nicknameKinshipResolvesThroughCyberBrainToGedcomPointer() async throws {
        let context = HallieTurnExecutor.Context(
            profiles: [rickProfile], graph: graph,
            cyberBrain: try brainWithOneRick())
        let result = try await HallieTurnExecutor.execute(
            .init(intent: kinship("rick", .father)), context: context)

        #expect(result.outcome == .answered)
        #expect(result.clarification == nil)
        #expect(result.prose == "Richard Harding Breen Jr's father: Richard Harding Breen Sr.")
        #expect(result.basisLine.contains("CyberBrain identity “rick” → “Richard Harding Breen Jr.” → GEDCOM “Richard Harding Breen Jr”"))
        #expect(result.basisLine.contains("GEDCOM"))
        #expect(!result.prose.contains("don't find"))
    }

    @Test func withoutCyberBrainTheSameTurnStillDeclinesHonestly() async throws {
        let context = HallieTurnExecutor.Context(
            profiles: [rickProfile], graph: graph, cyberBrain: nil)
        let result = try await HallieTurnExecutor.execute(
            .init(intent: kinship("rick", .father)), context: context)
        #expect(result.outcome == .declined)
        // The People tab knows "Rick" even though the tree can't bridge the
        // nickname (2026-08-22): decline by name, not "I don't find rick".
        #expect(result.prose.hasPrefix("Rick is in the People tab, so I know the name — but I can't trace father for Rick yet."))
        #expect(!result.prose.contains("don't find"))
    }

    @Test func birthAndDeathUseTheSameBridge() async throws {
        let context = HallieTurnExecutor.Context(
            profiles: [], graph: graph, cyberBrain: try brainWithOneRick())
        let birth = try await HallieTurnExecutor.execute(
            .graph(.init(people: ["ricky"], operation: .birth)), context: context)
        #expect(birth.outcome == .answered)
        #expect(birth.prose.contains("4 JUL 1962"))
        #expect(birth.basisLine.contains("CyberBrain identity “ricky”"))

        let death = try await HallieTurnExecutor.execute(
            .graph(.init(people: ["Mom"], operation: .death)), context: context)
        #expect(death.outcome == .declined)
        #expect(death.basisLine.contains("CyberBrain identity “Mom” → “Donna Breen”"))
    }

    // MARK: Ambiguity parity with biography

    @Test func twoRicksClarifyWithDistinctLabelsAndContinueByPointer() async throws {
        let context = HallieTurnExecutor.Context(
            profiles: [rickProfile], graph: graph,
            cyberBrain: try brainWithTwoRicks())
        let first = try await HallieTurnExecutor.execute(
            .init(intent: kinship("rick", .father)), context: context)
        let pending = try #require(first.clarification)

        #expect(first.outcome == .needsClarification)
        // The sentence carries the choice — chips are UI-only, and voice,
        // the CLI and the eval transcripts see nothing else (2026-09-03).
        // The typed "rick" is echoed in the casing a person would write.
        #expect(first.prose == "Which Rick do you mean — "
                + "Richard Harding Breen (b. 4 JUL 1962) or "
                + "Richard Harding Breen (b. 12 MAR 1931)?")
        #expect(pending.stage == .cyberBrainPerson)
        #expect(pending.candidates.map(\.id) == [
            .cyberBrainPersonID("person.rick.jr"),
            .cyberBrainPersonID("person.rick.sr"),
        ])
        let labels = pending.candidates.map(\.label)
        #expect(Set(labels).count == labels.count)
        #expect(labels[0] == "Richard Harding Breen (b. 4 JUL 1962)")
        #expect(labels[1] == "Richard Harding Breen (b. 12 MAR 1931)")

        let junior = try await HallieTurnExecutor.continue(
            pending: pending,
            selecting: .cyberBrainPersonID("person.rick.jr"),
            context: context)
        #expect(junior.outcome == .answered)
        #expect(junior.clarification == nil)
        #expect(junior.prose == "Richard Harding Breen Jr's father: Richard Harding Breen Sr.")

        let senior = try await HallieTurnExecutor.continue(
            pending: pending,
            selecting: .cyberBrainPersonID("person.rick.sr"),
            context: context)
        #expect(senior.outcome == .declined)
        #expect(senior.prose.contains("doesn't record a father"))
        #expect(senior.prose.contains("Richard Harding Breen Sr"))
    }

    @Test func biographyAndKinshipOfferTheSameChips() async throws {
        let context = HallieTurnExecutor.Context(
            profiles: [rickProfile], graph: graph,
            cyberBrain: try brainWithTwoRicks())
        let bio = try await HallieTurnExecutor.execute(
            .init(intent: biography("rick")), context: context)
        let kin = try await HallieTurnExecutor.execute(
            .init(intent: kinship("rick", .children)), context: context)

        #expect(bio.outcome == .needsClarification)
        #expect(kin.outcome == .needsClarification)
        #expect(bio.clarification?.stage == kin.clarification?.stage)
        #expect(bio.clarification?.candidates.map(\.id)
                == kin.clarification?.candidates.map(\.id))
        #expect(bio.clarification?.candidates.map(\.label)
                == kin.clarification?.candidates.map(\.label))

        let pending = try #require(kin.clarification)
        let children = try await HallieTurnExecutor.continue(
            pending: pending,
            selecting: .cyberBrainPersonID("person.rick.jr"),
            context: context)
        #expect(children.outcome == .answered)
        #expect(children.prose.contains("Timothy Breen"))
    }

    // MARK: Fail-closed edges

    @Test func staleCyberBrainContinuationIsRejected() async throws {
        let context = HallieTurnExecutor.Context(
            profiles: [], graph: graph, cyberBrain: try brainWithTwoRicks())
        let first = try await HallieTurnExecutor.execute(
            .init(intent: kinship("rick", .father)), context: context)
        let pending = try #require(first.clarification)

        // A fresh capture (new continuation token) must not honor the chip.
        let fresh = HallieTurnExecutor.Context(
            profiles: [], graph: graph, cyberBrain: try brainWithTwoRicks())
        let stale = try await HallieTurnExecutor.continue(
            pending: pending,
            selecting: .cyberBrainPersonID("person.rick.jr"),
            context: fresh)
        #expect(stale.outcome == .declined)
        #expect(stale.prose.contains("no longer available"))
    }

    @Test func cyberBrainPersonWithoutGedcomLinkFallsThroughToProfilePath() async throws {
        let unlinked = try CyberBrainIndex(archive: .init(
            archiveID: "kinship-fixture-3",
            displayName: "Unlinked",
            people: [person("person.rick", "Rick Breen",
                            aliases: ["Rick"], gedcom: nil)],
            sources: []))
        let bridgingProfile = HallieTurnExecutor.ProfileSnapshot(
            stableID: "profile-rick", canonicalName: "Richard Harding Breen Jr",
            aliases: ["Rick"])
        let context = HallieTurnExecutor.Context(
            profiles: [bridgingProfile], graph: graph, cyberBrain: unlinked)
        let result = try await HallieTurnExecutor.execute(
            .init(intent: kinship("rick", .mother)), context: context)

        // The profiles + GEDCOM path still answers; CyberBrain did not shadow it.
        #expect(result.outcome == .answered)
        #expect(result.prose.contains("Mary Breen"))
        #expect(!result.basisLine.contains("CyberBrain"))
    }

    @Test func profileAliasAmbiguityStillContinuesByGedcomPointer() async throws {
        // No CyberBrain: profile "Rick" → canonical "Richard Harding Breen"
        // → two GEDCOM matches → GEDCOM chips → kinship by pointer.
        let profile = HallieTurnExecutor.ProfileSnapshot(
            stableID: "profile-rick", canonicalName: "Richard Harding Breen",
            aliases: ["Rick"])
        let context = HallieTurnExecutor.Context(
            profiles: [profile], graph: graph, cyberBrain: nil)
        let first = try await HallieTurnExecutor.execute(
            .init(intent: kinship("Rick", .father)), context: context)
        let pending = try #require(first.clarification)
        #expect(pending.stage == .gedcomPerson)
        // Since 739a77f0 (miss #2) which-one chips list tree roots first
        // (HallieWhichOne.arrange): @I1@ is the fixture's root.
        #expect(pending.candidates.map(\.id) == [
            .gedcomPersonID("@I1@"), .gedcomPersonID("@I2@"),
        ])
        let labels = pending.candidates.map(\.label)
        #expect(Set(labels).count == 2)

        let answer = try await HallieTurnExecutor.continue(
            pending: pending, selecting: .gedcomPersonID("@I2@"),
            context: context)
        #expect(answer.outcome == .answered)
        #expect(answer.prose == "Richard Harding Breen Jr's father: Richard Harding Breen Sr.")
    }
}
