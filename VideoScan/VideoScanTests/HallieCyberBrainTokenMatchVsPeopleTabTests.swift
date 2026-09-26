// HallieCyberBrainTokenMatchVsPeopleTabTests.swift
// Live 2026-09-21 22:56, and still on main 2026-09-25 (headless probe):
//
//   Rick:   tell me about ellen
//   Hallie: Which ellen do you mean: Ellen Ronan, Ellen Ronan?
//   Rick:   ellen engelhardt my sister
//   Hallie: declined — "couldn't tell who it is about"
//
// Ellen is Rick's younger sister; her People profile is named "Ellen". The
// CyberBrain holds two "Ellen Ronan" records (his great-grandmother, linked
// to two tree pointers). CyberBrain answers a biography whenever it
// "knows" the name, and it matched "ellen" by a single TOKEN of each Ronan's
// name — so the CyberBrain ambiguity pre-empted the People tab, which
// EXACTLY owns the spelling (PeopleTabPrecedenceTests: the People tab is the
// source of truth for the inner circle; exact name wins).
//
// Pinned: a token-only CyberBrain match yields to an exact People-tab claim;
// an exact CyberBrain name still answers from CyberBrain; with no People-tab
// claim the CyberBrain token match speaks as before.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private let tree = """
0 HEAD
0 @I1@ INDI
1 NAME Richard Harding /Breen/ Jr
1 SEX M
0 @I10@ INDI
1 NAME Ellen /Ronan/
1 SEX F
1 BIRT
2 DATE 1883
0 TRLR
"""

@Suite("Hallie — a CyberBrain token match yields to an exact People-tab name")
struct HallieCyberBrainTokenMatchVsPeopleTabTests {
    typealias Exec = HallieTurnExecutor

    private static let ellen = Exec.ProfileSnapshot(
        stableID: "ellen", canonicalName: "Ellen", aliases: ["Ellen"],
        note: "Ellen is Rick’s younger sister.", sex: .female, notInFamilyTree: true)

    private static let rick = Exec.ProfileSnapshot(
        stableID: "rick", canonicalName: "Rick", aliases: ["Richard"], sex: .male)

    private static func cyberBrain() throws -> CyberBrainIndex {
        try CyberBrainIndex(archive: .init(
            archiveID: "ellen-fixture",
            displayName: "Ellen fixture CyberBrain",
            people: [
                CyberBrainPerson(id: "person.ellen-ronan.i342486919798",
                                 gedcomPersonID: "@I342486919798@",
                                 canonicalName: "Ellen Ronan",
                                 aliases: ["Ellen O'Connor", "Ellen Ronan O'Connor"]),
                CyberBrainPerson(id: "person.ellen-ronan.i10", gedcomPersonID: "@I10@",
                                 canonicalName: "Ellen Ronan", aliases: []),
            ],
            sources: []))
    }

    private func context(profiles: [Exec.ProfileSnapshot]) throws -> Exec.Context {
        Exec.Context(profiles: profiles, graph: GedcomFamilyGraph(gedcomText: tree),
                     cyberBrain: try Self.cyberBrain(),
                     speakers: .init(ownerName: "Rick Breen", archivistName: "Hallie Mae",
                                     archivistPersonName: nil))
    }

    private func ask(_ typed: String, in context: Exec.Context) async throws -> Exec.Result {
        try await Exec.execute(
            .init(intent: .init(originalQuestion: "tell me about \(typed)",
                                ast: .graph(.init(people: [typed], operation: .biography)))),
            context: context)
    }

    /// The live turn: the sister, from the People tab — never "which Ellen
    /// Ronan".
    @Test func tellMeAboutEllenIsTheSister() async throws {
        let result = try await ask("ellen", in: try context(profiles: [Self.rick, Self.ellen]))
        #expect(result.outcome != .needsClarification, Comment(rawValue: result.prose))
        #expect(result.clarification == nil)
        #expect(!result.prose.contains("Ronan"), Comment(rawValue: result.prose))
        #expect(result.prose.contains("Ellen"), Comment(rawValue: result.prose))
    }

    /// An exact CyberBrain name is still CyberBrain's to answer.
    @Test func anExactCyberBrainNameStillAnswersFromCyberBrain() async throws {
        let result = try await ask("ellen ronan", in: try context(profiles: [Self.rick, Self.ellen]))
        #expect(result.prose.contains("Ronan"), Comment(rawValue: result.prose))
        #expect(!result.prose.contains("sister"), Comment(rawValue: result.prose))
    }

    /// No People-tab claim: the CyberBrain token match speaks, as before.
    @Test func withoutAPeopleTabClaimTheTokenMatchStands() async throws {
        let result = try await ask("ellen", in: try context(profiles: [Self.rick]))
        #expect(result.prose.contains("Ronan"), Comment(rawValue: result.prose))
    }
}
