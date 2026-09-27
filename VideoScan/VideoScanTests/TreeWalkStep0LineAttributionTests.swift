// TreeWalkStep0LineAttributionTests.swift
// STEP 0 of the Family Tree Walk (Rick 2026-09-27): "the joined trees can
// sometimes think someone is my ancestor even though we're walking Donna's
// tree."
//
// What was found:
//   • The graph walks (ancestorLine, AncestorIndex, TreeStatistics'
//     ancestor scope) never cross a spouse edge — pinned below.
//   • The Family Tree tab's "Line to …" row DID say "your" for BOTH home
//     people of a merged tree when no owner FamilySearch ID is pinned:
//     `anchors(in:)` marks every root `isRoot`, and the relation phrase
//     read `isRoot` as "this is you". Selecting Donna's grandmother said
//     "your grandmother" in Donna's row. Fixed: only the anchor that IS the
//     reader (the pinned owner, or the root of a single-root tree) reads
//     "your"; in a two-root tree with no pin every line is named.
//   • On Rick's real tree the rest is TRUE pedigree collapse, not a bug:
//     6,409 people are ancestors of both Rick and Donna (nearest: Martha
//     Lamson b. 1633, Rick's 8th-great-grandmother and Donna's 9th). The
//     walk labels them `both`.

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

/// Rick and Donna married; each with their own parents and grandparents,
/// no one shared. A merge artifact with both roots recorded.
private let marriedRoots = """
0 HEAD
1 _VS_MERGED Y
1 _VS_ROOT @I1@
1 _VS_ROOT @I2@
0 @I1@ INDI
1 NAME Richard Harding /Breen/ Jr
1 SEX M
1 _FSFTID GVQV-NW3
1 FAMC @F1@
1 FAMS @F0@
0 @I2@ INDI
1 NAME Donna /Hudson/
1 SEX F
1 _FSFTID G2CL-86B
1 FAMC @F2@
1 FAMS @F0@
0 @I3@ INDI
1 NAME Richard Harding /Breen/ Sr
1 SEX M
1 FAMC @F3@
1 FAMS @F1@
0 @I4@ INDI
1 NAME Eileen /Latta/
1 SEX F
1 FAMS @F1@
0 @I5@ INDI
1 NAME George /Breen/
1 SEX M
1 FAMS @F3@
0 @I6@ INDI
1 NAME Muriel /Lamb/
1 SEX F
1 FAMS @F3@
0 @I7@ INDI
1 NAME Richard C /Hudson/
1 SEX M
1 FAMC @F4@
1 FAMS @F2@
0 @I8@ INDI
1 NAME Elaine /Bowser/
1 SEX F
1 FAMS @F2@
0 @I9@ INDI
1 NAME Grace Edith /Wyatt/
1 SEX F
1 FAMS @F4@
0 @I10@ INDI
1 NAME William /Hudson/
1 SEX M
1 FAMS @F4@
0 @F0@ FAM
1 HUSB @I1@
1 WIFE @I2@
0 @F1@ FAM
1 HUSB @I3@
1 WIFE @I4@
1 CHIL @I1@
0 @F2@ FAM
1 HUSB @I7@
1 WIFE @I8@
1 CHIL @I2@
0 @F3@ FAM
1 HUSB @I5@
1 WIFE @I6@
1 CHIL @I3@
0 @F4@ FAM
1 HUSB @I10@
1 WIFE @I9@
1 CHIL @I7@
0 TRLR
"""

private let rickOnly: Set<String> = ["@I3@", "@I4@", "@I5@", "@I6@"]
private let donnaOnly: Set<String> = ["@I7@", "@I8@", "@I9@", "@I10@"]

@Suite("TreeWalkStep0LineAttribution")
@MainActor
struct TreeWalkStep0LineAttributionTests {

    static let noOwnerPin = FamilyTreeLaunchBundle.Settings(
        speakers: HallieTurnExecutor.Speakers(ownerName: "Rick", archivistName: "Hallie",
                                              archivistPersonName: nil, ownerFamilySearchID: nil),
        ownerFamilySearchID: nil)
    static let rickPinned = FamilyTreeLaunchBundle.Settings(
        speakers: HallieTurnExecutor.Speakers(ownerName: "Rick", archivistName: "Hallie",
                                              archivistPersonName: nil, ownerFamilySearchID: "GVQV-NW3"),
        ownerFamilySearchID: "GVQV-NW3")

    private func model(_ settings: FamilyTreeLaunchBundle.Settings) -> FamilyTreeLiveModel {
        let model = FamilyTreeLiveModel(originalsDirectory: URL(fileURLWithPath: "/nonexistent/never-read"))
        model.install(graph: GedcomFamilyGraph(gedcomText: marriedRoots), settings: settings)
        return model
    }

    // MARK: The bug (red before the fix)

    @Test func donnasGrandmotherIsNeverCalledYourGrandmotherWithoutAPin() {
        let m = model(Self.noOwnerPin)
        #expect(m.anchors.map(\.label) == ["Richard", "Donna"])
        m.select("@I9@")   // Grace Wyatt: Donna's grandmother, nothing to Rick
        #expect(m.lineOptions.map(\.isAvailable) == [false, true])
        let donnaRow = m.lineOptions[1].relation ?? ""
        #expect(!donnaRow.hasPrefix("your"), "Donna's line must not say 'your': \(donnaRow)")
        #expect(donnaRow == "Donna's grandmother")
    }

    @Test func rickIsNotAssumedToBeTheReaderInATwoRootTreeWithoutAPin() {
        // Two home people and no pin: nobody is "you" — each line is named.
        let m = model(Self.noOwnerPin)
        m.select("@I5@")   // George Breen, Rick's grandfather
        #expect(m.lineOptions.first?.relation == "Richard's grandfather")
    }

    @Test func thePinnedOwnerReadsAsYouAndTheSpouseIsNamed() {
        let m = model(Self.rickPinned)
        m.select("@I5@")
        #expect(m.lineOptions.first?.relation == "your grandfather")
        m.select("@I9@")
        #expect(m.lineOptions.map(\.relation) == [nil, "Donna's grandmother"])
    }

    @Test func aSingleRootTreeStillReadsAsYou() {
        // The long-standing first-INDI assumption for a plain export.
        let single = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME Richard /Breen/
        1 FAMC @F1@
        0 @I2@ INDI
        1 NAME George /Breen/
        1 SEX M
        1 FAMS @F1@
        0 @F1@ FAM
        1 HUSB @I2@
        1 CHIL @I1@
        0 TRLR
        """)
        let anchors = FamilyTreeLiveModel.anchors(in: single)
        #expect(anchors.map(\.readsAsYou) == [true])
        #expect(FamilyTreeLiveModel.relationPhrase(anchor: anchors[0], generations: 1, sex: "M") == "your father")
    }

    // MARK: The graph walks never cross the spouse edge (pins)

    @Test func ancestorWalksOfRickNeverReturnDonnaOnlyAncestors() throws {
        let g = GedcomFamilyGraph(gedcomText: marriedRoots)
        let rick = try #require(g.people["@I1@"])
        let donna = try #require(g.people["@I2@"])
        let rickLine = Set(g.ancestorLine(of: rick, line: .both, generations: 50).flatMap(\.people).map(\.id))
        #expect(rickLine == rickOnly)
        #expect(Set(g.ancestorLine(of: donna, line: .both, generations: 50).flatMap(\.people).map(\.id)) == donnaOnly)
        let index = GedcomFamilyGraph.AncestorIndex(graph: g, descendantID: rick.id)
        for id in donnaOnly { #expect(index.generations(from: id) == nil, "\(id) is not Rick's ancestor") }
        #expect(index.generations(from: donna.id) == nil, "a spouse is not an ancestor")
        let stats = TreeStatistics.people(matching: .init(scope: .ancestors(of: rick.id, maxGenerations: 50)), in: g)
        #expect(Set(stats.map(\.id)) == rickOnly)
    }
}
