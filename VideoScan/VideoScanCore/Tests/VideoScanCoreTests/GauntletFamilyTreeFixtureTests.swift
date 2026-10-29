// GauntletFamilyTreeFixtureTests.swift
//
// The synthetic tree Gauntlet flow 7 hands the app (GauntletFamilyTreeFixture)
// must parse to the shape the flow relies on: eleven people, one root that
// Walk Tree… starts from, three generations, a birthplace for everyone. A
// broken fixture fails HERE in a second, not minutes into a UI run on the M4.

import Testing
import Foundation
import VideoScanCore

@Suite("GauntletFamilyTreeFixture — the synthetic tree for flow 7")
struct GauntletFamilyTreeFixtureTests {

    private let graph = GedcomFamilyGraph(gedcomText: GauntletFamilyTreeFixture.gedcom)

    @Test func parsesToElevenNamedPeopleWithOneRoot() {
        #expect(graph.people.count == GauntletFamilyTreeFixture.peopleCount)
        #expect(graph.rootPersonIDs == [GauntletFamilyTreeFixture.rootID],
                "Walk Tree…'s default start is the tree's root — the first INDI")
        let parsed = Set(graph.people.values.map(\.name))
        #expect(parsed == Set(GauntletFamilyTreeFixture.names))
    }

    @Test func everyoneHasABirthplaceForTheMapToShade() {
        let missing = graph.people.values.filter { ($0.birthPlace ?? "").isEmpty }.map(\.name)
        #expect(missing.isEmpty, "no birthplace: \(missing)")
    }

    @Test func aWalkFromTheRootReachesTheGrandparents() throws {
        let result = try TreeWalk.walk(graph, options: .init(starts: [GauntletFamilyTreeFixture.rootID],
                                                             maxGenerations: 7))
        #expect(result.summary.generationsFromFirst == 2, "three generations: root, parents, grandparents")
        #expect(result.visitedCount >= 7, "the root, two parents and four grandparents at least")
    }

    @Test func fileNameFollowsTheFixtureConvention() {
        #expect(GauntletFamilyTreeFixture.fileName.hasPrefix("test_"))
        #expect(GauntletFamilyTreeFixture.fileName.hasSuffix(".ged"))
    }
}
