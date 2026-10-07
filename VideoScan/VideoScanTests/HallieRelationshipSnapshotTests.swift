// HallieRelationshipSnapshotTests.swift
// GH #281 R3 (2026-10-06): characterization snapshots for
// HallieTurnExecutor.executeRelationship, recorded from the pre-refactor
// code (main@ebcd2f09) BEFORE the extract-function split. Every branch the
// executor takes is visited at least once: the people-count guard, the
// recompile decline, the People-tab overlay (with and without a tree, with
// an assumed bridge), the no-tree decline, the owner chain, the archivist
// name ladder (match and every-spelling-failed), CyberBrain resolved and
// ambiguous (+ chip continuation), GEDCOM ambiguity (+ chip continuation),
// not found, and the answered / no-path graph results.
// Synthetic tree only (2026-08-03 privacy policy).

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@MainActor
@Suite("Relationship executor: characterization snapshots", .serialized)
struct HallieRelationshipSnapshotTests {

    // Rick Breen → father Al → mother Grace → mother Hallie May McGill;
    // wife Dawn, son Tim; uncle Bob → cousin Cara; Zed unrelated.
    static let familyTree = """
    0 HEAD
    0 @I1@ INDI
    1 NAME Hallie May /McGill/
    1 SEX F
    1 BIRT
    2 DATE 1876
    1 DEAT
    2 DATE 1908
    1 FAMS @F1@
    0 @I2@ INDI
    1 NAME John /Latta/
    1 SEX M
    1 FAMS @F1@
    0 @I3@ INDI
    1 NAME Grace /Latta/
    1 SEX F
    1 FAMC @F1@
    1 FAMS @F2@
    0 @I4@ INDI
    1 NAME Peter /Breen/
    1 SEX M
    1 FAMS @F2@
    0 @I5@ INDI
    1 NAME Al /Breen/
    1 SEX M
    1 FAMC @F2@
    1 FAMS @F3@
    0 @I6@ INDI
    1 NAME Bob /Breen/
    1 SEX M
    1 FAMC @F2@
    1 FAMS @F4@
    0 @I7@ INDI
    1 NAME Mae /Lake/
    1 SEX F
    1 FAMS @F3@
    0 @I8@ INDI
    1 NAME Rick /Breen/
    1 SEX M
    1 FAMC @F3@
    1 FAMS @F5@
    0 @I9@ INDI
    1 NAME Dawn /Field/
    1 SEX F
    1 FAMS @F5@
    0 @I10@ INDI
    1 NAME Tim /Breen/
    1 SEX M
    1 FAMC @F5@
    0 @I11@ INDI
    1 NAME Cara /Breen/
    1 SEX F
    1 FAMC @F4@
    0 @I12@ INDI
    1 NAME Zed /Solo/
    1 SEX M
    0 @F1@ FAM
    1 HUSB @I2@
    1 WIFE @I1@
    1 CHIL @I3@
    0 @F2@ FAM
    1 HUSB @I4@
    1 WIFE @I3@
    1 CHIL @I5@
    1 CHIL @I6@
    0 @F3@ FAM
    1 HUSB @I5@
    1 WIFE @I7@
    1 CHIL @I8@
    0 @F4@ FAM
    1 HUSB @I6@
    1 CHIL @I11@
    0 @F5@ FAM
    1 HUSB @I8@
    1 WIFE @I9@
    1 CHIL @I10@
    0 TRLR
    """

    static var tree: GedcomFamilyGraph { GedcomFamilyGraph(gedcomText: familyTree) }
    /// Two GEDCOM people answer to "Rick" (Sr. and Jr.).
    static var srJrTree: GedcomFamilyGraph {
        GedcomFamilyGraph(gedcomText: familyTree.replacingOccurrences(
            of: "1 NAME Al /Breen/", with: "1 NAME Rick /Breen/ Sr"))
    }
    static let speakers = HallieTurnExecutor.Speakers(ownerName: "Rick Breen", archivistName: "Hallie Mae")

    static func cyberBrain() throws -> CyberBrainIndex {
        try CyberBrainIndex(archive: .init(
            archiveID: "r3-fixture", displayName: "R3 fixture CyberBrain",
            people: [
                CyberBrainPerson(id: "person.al", gedcomPersonID: "@I5@",
                                 canonicalName: "Albert Breen", aliases: ["Big Al"]),
                CyberBrainPerson(id: "person.tim", gedcomPersonID: "@I10@",
                                 canonicalName: "Timothy Breen", aliases: ["Skip"]),
                CyberBrainPerson(id: "person.cara", gedcomPersonID: "@I11@",
                                 canonicalName: "Cara Breen", aliases: ["Skip"]),
                CyberBrainPerson(id: "person.ghost", gedcomPersonID: "@I99@",
                                 canonicalName: "Ghost Person", aliases: ["Ghost"]),
            ],
            sources: []))
    }

    /// People-tab cards: Tim is Rick's son, Rick is Dawn's husband.
    static let profiles: [HallieTurnExecutor.ProfileSnapshot] = [
        .init(stableID: "rick", canonicalName: "Rick Breen",
              kinships: [
                  .init(relation: .parent, relativeTo: .profile(name: "Timothy")),
                  .init(relation: .spouse, relativeTo: .profile(name: "Dawn")),
              ], sex: .male),
        .init(stableID: "timothy", canonicalName: "Timothy", sex: .male),
        .init(stableID: "dawn", canonicalName: "Dawn", sex: .female),
        .init(stableID: "zelda", canonicalName: "Zelda", sex: .female),
    ]

    static func intent(_ a: String, _ b: String) -> HallieTurnExecutor.Intent {
        .init(originalQuestion: "how is \(a) related to \(b)?",
              ast: .graph(.init(people: [a, b], operation: .relationship)))
    }

    static func context(graph: GedcomFamilyGraph?, profiles: [HallieTurnExecutor.ProfileSnapshot] = [],
                        cyberBrain: CyberBrainIndex? = nil,
                        speakers: HallieTurnExecutor.Speakers = speakers,
                        needsRecompile: [URL] = [],
                        bridges: [String: String] = [:]) -> HallieTurnExecutor.Context {
        .init(profiles: profiles, graph: graph, needsRecompile: needsRecompile,
              cyberBrain: cyberBrain, speakers: speakers, assumedTreeBridges: bridges)
    }

    @Test func everyRelationshipBranchMatchesItsRecordedSnapshot() async throws {
        var out: [String: String] = [:]
        func run(_ name: String, _ a: String, _ b: String,
                 _ context: HallieTurnExecutor.Context) async throws -> HallieTurnExecutor.Result {
            let result = try await HallieTurnExecutor.execute(.init(intent: Self.intent(a, b)), context: context)
            out[name] = HallieGoldenSnapshot.render(result)
            return result
        }
        let tree = Self.context(graph: Self.tree)
        _ = try await run("01 me-you", "me", "you", tree)
        _ = try await run("02 you-me", "you", "me", tree)
        _ = try await run("03 cara-tim", "cara", "tim", tree)
        _ = try await run("04 dawn-al", "dawn", "al", tree)
        _ = try await run("05 me-dawn", "me", "dawn", tree)
        _ = try await run("06 me-zed no path", "me", "zed", tree)
        _ = try await run("07 nobody-tim not found", "nobody", "tim", tree)
        _ = try await run("08 rick-hallie typed owner and archivist", "rick", "hallie mae", tree)
        _ = try await run("09 rick breen-tim owner spelling", "Rick Breen", "tim", tree)
        _ = try await run("10 unknown owner", "me", "you",
                          Self.context(graph: Self.tree, speakers: .init(ownerName: "Nobody Here", archivistName: "Hallie Mae")))
        _ = try await run("11 no speakers", "me", "you", Self.context(graph: Self.tree, speakers: .none))
        _ = try await run("12 archivist not in tree, every spelling fails", "me", "you",
                          Self.context(graph: Self.tree, speakers: .init(ownerName: "Rick Breen", archivistName: "Wilhelmina Quux")))

        // GEDCOM ambiguity: the chip, then both continuations.
        let srJr = Self.context(graph: Self.srJrTree)
        let ambiguous = try await run("13 you-rick ambiguous", "you", "rick", srJr)
        if let pending = ambiguous.clarification {
            for candidate in pending.candidates {
                let continued = try await HallieTurnExecutor.continue(
                    pending: pending, selecting: candidate.id, context: srJr)
                out["14 you-rick continue \(String(reflecting: candidate.id))"] = HallieGoldenSnapshot.render(continued)
            }
        }
        _ = try await run("15 me-rick owner pinned, other ambiguous", "me", "rick", srJr)
        _ = try await run("16 rick-dawn owner spelling, two ricks", "rick", "dawn", srJr)
        _ = try await run("17 me-you two ricks", "me", "you", srJr)

        // CyberBrain: resolved, ambiguous (+ continuation), unlinked.
        let brain = Self.context(graph: Self.tree, cyberBrain: try Self.cyberBrain())
        _ = try await run("18 big al-tim cyberbrain resolved", "big al", "tim", brain)
        let skip = try await run("19 skip-al cyberbrain ambiguous", "skip", "al", brain)
        if let pending = skip.clarification {
            for candidate in pending.candidates {
                let continued = try await HallieTurnExecutor.continue(
                    pending: pending, selecting: candidate.id, context: brain)
                out["20 skip continue \(String(reflecting: candidate.id))"] = HallieGoldenSnapshot.render(continued)
            }
        }
        _ = try await run("21 ghost-al cyberbrain unlinked", "ghost", "al", brain)

        // People-tab overlay: no tree, with a tree, with an assumed bridge; no-tree decline.
        let overlayOnly = Self.context(graph: nil, profiles: Self.profiles)
        _ = try await run("22 timothy-rick overlay without tree", "timothy", "rick", overlayOnly)
        _ = try await run("23 me-dawn overlay without tree", "me", "dawn", overlayOnly)
        _ = try await run("24 zelda-rick no tree decline", "zelda", "rick", overlayOnly)
        _ = try await run("25 timothy-rick overlay with tree", "timothy", "rick",
                          Self.context(graph: Self.tree, profiles: Self.profiles))
        _ = try await run("26 timothy-rick overlay with assumed bridge", "timothy", "rick",
                          Self.context(graph: nil, profiles: Self.profiles,
                                       bridges: ["rick": "Rick as Richard Breen", "timothy": "Timothy as Tim Breen"]))
        _ = try await run("27 needs recompile", "tim", "rick",
                          Self.context(graph: nil, profiles: Self.profiles,
                                       needsRecompile: [URL(fileURLWithPath: "/nonexistent/r3/pull1.ged")]))
        _ = try await run("28 zelda-zed tree with profiles, no overlay link", "zelda", "zed",
                          Self.context(graph: Self.tree, profiles: Self.profiles))

        // The executor-level people-count guard (the strict decoder never
        // lets these through; called directly).
        for people in [["rick"], ["rick", "tim", "dawn"]] {
            let payload = ArchivistQueryAST.Graph(people: people, operation: .relationship)
            let result = try await HallieTurnExecutor.executeRelationship(
                payload: payload,
                request: .init(intent: .init(originalQuestion: "x", ast: .graph(payload))),
                context: tree, dependencies: .production)
            out["29 people count \(people.count)"] = HallieGoldenSnapshot.render(result)
        }

        #expect(out.count >= 30)
        try HallieGoldenSnapshot.verify("relationship", out)
    }
}
