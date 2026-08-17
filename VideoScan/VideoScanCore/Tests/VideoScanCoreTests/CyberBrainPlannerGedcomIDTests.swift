import Foundation
import Testing
@testable import VideoScanCore

/// Regression sensors for the GEDCOM-pointer continuation of the CyberBrain
/// biography planner. Before this entry point existed the app re-resolved a
/// selected family-tree person BY NAME, which (a) looped forever on same-name
/// people and (b) could answer for a CyberBrain person the user never chose.
struct CyberBrainPlannerGedcomIDTests {
    /// Two same-name family-tree people plus a CyberBrain person whose alias
    /// collides with that GEDCOM display name.
    private static let sameNameTree = """
    0 @I1@ INDI
    1 NAME Richard /Breen/
    1 BIRT
    2 DATE 12 Mar 1931
    1 FAMS @F1@
    0 @I2@ INDI
    1 NAME Richard /Breen/
    1 BIRT
    2 DATE 4 Jul 1962
    1 FAMC @F1@
    0 @I3@ INDI
    1 NAME Mary /Breen/
    1 FAMS @F1@
    0 @F1@ FAM
    1 HUSB @I1@
    1 WIFE @I3@
    1 CHIL @I2@
    0 TRLR
    """

    private func index() throws -> CyberBrainIndex {
        try CyberBrainIndex(archive: .init(
            archiveID: "collision-fixture",
            displayName: "Collision fixture",
            people: [
                CyberBrainPerson(
                    id: "person.other-richard",
                    canonicalName: "Richard Other",
                    aliases: ["Richard Breen"],
                    biographyPassages: [
                        CyberBrainItem(
                            id: "bio.other",
                            kind: .biography,
                            text: "Richard Other restored radios.",
                            subjectPersonIDs: ["person.other-richard"],
                            sourceIDs: ["source.other"],
                            confidence: .confirmed,
                            privacy: .family,
                            createdAt: Date(timeIntervalSince1970: 0),
                            updatedAt: Date(timeIntervalSince1970: 0)),
                    ]),
            ],
            sources: [
                CyberBrainSource(
                    id: "source.other",
                    type: .familyWitness,
                    title: "Synthetic interview",
                    attribution: nil,
                    locator: nil),
            ]))
    }

    @Test func gedcomPointerContinuationPlansExactlyThatPerson() throws {
        let graph = GedcomFamilyGraph(gedcomText: Self.sameNameTree)
        let index = try index()

        let junior = CyberBrainBiographyPlanner.plan(
            gedcomPersonID: "@I2@", index: index, graph: graph,
            privacyCeiling: .private)
        #expect(junior.answerState == .answered)
        #expect(junior.subject == "Richard Breen")
        #expect(junior.ambiguityCandidates.isEmpty)
        #expect(junior.claims.map(\.id) == [
            "gedcom:@I2@:birth", "gedcom:@I2@:parents",
        ])
        #expect(junior.claims.allSatisfy { $0.evidenceIDs == ["gedcom:@I2@"] })
        #expect(junior.sourceCitations.map(\.id) == ["gedcom:@I2@"])
        #expect(!junior.claims.contains { $0.text.contains("1931") })

        let senior = CyberBrainBiographyPlanner.plan(
            gedcomPersonID: "@I1@", index: index, graph: graph,
            privacyCeiling: .private)
        #expect(senior.answerState == .answered)
        #expect(senior.claims.map(\.id) == [
            "gedcom:@I1@:birth", "gedcom:@I1@:spouse", "gedcom:@I1@:children",
        ])
        #expect(!senior.claims.contains { $0.text.contains("1962") })
    }

    /// The GEDCOM display name equals a CyberBrain alias. Name resolution
    /// would hand the turn to "Richard Other"; the pointer must not.
    @Test func gedcomPointerNeverDefersToCyberBrainAliasCollision() throws {
        let graph = GedcomFamilyGraph(gedcomText: Self.sameNameTree)
        let index = try index()

        // Sensor for the collision itself: by name, CyberBrain wins.
        let byName = CyberBrainBiographyPlanner.plan(
            personName: "Richard Breen", index: index, graph: graph,
            privacyCeiling: .private)
        #expect(byName.subject == "Richard Other")

        let byPointer = CyberBrainBiographyPlanner.plan(
            gedcomPersonID: "@I2@", index: index, graph: graph,
            privacyCeiling: .private)
        #expect(byPointer.subject == "Richard Breen")
        #expect(byPointer.answerState == .answered)
        #expect(!byPointer.claims.contains { $0.text.contains("restored radios") })
        #expect(!byPointer.sourceCitations.contains { $0.id == "source.other" })
        #expect(byPointer.claims.allSatisfy { $0.evidenceIDs == ["gedcom:@I2@"] })
    }

    @Test func gedcomPointerFailsClosedWhenPersonOrGraphIsMissing() throws {
        let graph = GedcomFamilyGraph(gedcomText: Self.sameNameTree)
        let index = try index()

        let missingPerson = CyberBrainBiographyPlanner.plan(
            gedcomPersonID: "@I99@", index: index, graph: graph,
            privacyCeiling: .private)
        #expect(missingPerson.answerState == .noEvidence)
        #expect(missingPerson.claims.isEmpty)
        #expect(missingPerson.constraints.contains(.doNotInferIdentity))

        let missingGraph = CyberBrainBiographyPlanner.plan(
            gedcomPersonID: "@I2@", index: index, graph: nil,
            privacyCeiling: .private)
        #expect(missingGraph.answerState == .noEvidence)
        #expect(missingGraph.claims.isEmpty)
        #expect(missingGraph.constraints.contains(.doNotInferIdentity))
    }

    @Test func gedcomPointerRespectsPrivacyCeilingLikeNameFallback() throws {
        let graph = GedcomFamilyGraph(gedcomText: Self.sameNameTree)
        let index = try index()

        let plan = CyberBrainBiographyPlanner.plan(
            gedcomPersonID: "@I2@", index: index, graph: graph,
            privacyCeiling: .family)
        #expect(plan.answerState == .noEvidence)
        #expect(plan.claims.isEmpty)
        #expect(plan.uncertaintyStatements == [
            "Imported family-tree facts are above this privacy ceiling."
        ])
    }

    /// The pointer path and the name fallback share one GEDCOM claim builder;
    /// an unambiguous name and its pointer must produce identical plans.
    @Test func gedcomPointerMatchesNameFallbackForUnambiguousPerson() throws {
        let graph = GedcomFamilyGraph(gedcomText: Self.sameNameTree)
        let index = try index()

        let byName = CyberBrainBiographyPlanner.plan(
            personName: "Mary Breen", index: index, graph: graph,
            privacyCeiling: .private)
        let byPointer = CyberBrainBiographyPlanner.plan(
            gedcomPersonID: "@I3@", index: index, graph: graph,
            privacyCeiling: .private)
        #expect(byName == byPointer)
        #expect(byPointer.answerState == .answered)
    }
}
