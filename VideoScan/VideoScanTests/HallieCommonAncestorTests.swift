// HallieCommonAncestorTests.swift
// "How are Rick and Donna related?" over a merged two-root tree
// (2026-08-27). LOGIC: detector positives/negatives, the answer template
// (count, nearest, both labels, cousin term, both lines), the honest
// declines (one side has no parents → Get Family Tree; nothing shared →
// depths walked), two-root provenance wording, and the Family Tree
// anchors for two roots. Pure: synthetic GEDCOM text, no files, no model.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

/// Rick's pull (Donna as spouse only) and Donna's pull, merged in-test
/// exactly as the sheet's "Add to current tree" does. Z Common is Rick's
/// great-grandfather (depth 3) and Donna's great-great-grandfather
/// (depth 4) → 2nd cousins once removed.
private let rickPull = """
0 HEAD
0 @I1@ INDI
1 NAME Richard Harding /Breen/ Jr
1 SEX M
1 BIRT
2 DATE 1959
1 FAMC @F1@
1 FAMS @F2@
1 _FSFTID GVQV-NW3
0 @I2@ INDI
1 NAME Donna /Hudson/
1 SEX F
1 FAMS @F2@
1 _FSFTID G2CL-86B
0 @I3@ INDI
1 NAME Richard Harding /Breen/ Sr
1 SEX M
1 FAMC @F3@
1 FAMS @F1@
1 _FSFTID RICK-DAD
0 @I4@ INDI
1 NAME George /Breen/
1 SEX M
1 FAMC @F4@
1 FAMS @F3@
1 _FSFTID RICK-GF1
0 @I5@ INDI
1 NAME Z /Common/
1 SEX M
1 BIRT
2 DATE 1840
1 FAMS @F4@
1 _FSFTID ZCOM-MON
0 @F1@ FAM
1 HUSB @I3@
1 CHIL @I1@
0 @F2@ FAM
1 HUSB @I1@
1 WIFE @I2@
0 @F3@ FAM
1 HUSB @I4@
1 CHIL @I3@
0 @F4@ FAM
1 HUSB @I5@
1 CHIL @I4@
0 TRLR
"""

private let donnaPull = """
0 HEAD
0 @I1@ INDI
1 NAME Donna /Hudson/
1 SEX F
1 BIRT
2 DATE 1959
1 FAMC @F1@
1 _FSFTID G2CL-86B
0 @I2@ INDI
1 NAME Walter /Hudson/
1 SEX M
1 FAMC @F2@
1 FAMS @F1@
1 _FSFTID DON1-DAD
0 @I3@ INDI
1 NAME Harold /Hudson/
1 SEX M
1 FAMC @F3@
1 FAMS @F2@
1 _FSFTID DON1-GF0
0 @I4@ INDI
1 NAME Mabel /Common/
1 SEX F
1 FAMC @F4@
1 FAMS @F3@
1 _FSFTID DON1-GGM
0 @I5@ INDI
1 NAME Z /Common/
1 SEX M
1 BIRT
2 DATE 1840
1 DEAT
2 DATE 1910
1 FAMS @F4@
1 _FSFTID ZCOM-MON
0 @F1@ FAM
1 HUSB @I2@
1 CHIL @I1@
0 @F2@ FAM
1 HUSB @I3@
1 CHIL @I2@
0 @F3@ FAM
1 WIFE @I4@
1 CHIL @I3@
0 @F4@ FAM
1 HUSB @I5@
1 CHIL @I4@
0 TRLR
"""

private func mergedGraph() -> GedcomFamilyGraph {
    var a = GedcomFamilyGraph(gedcomText: rickPull); a.sourceFileName = "familysearch-tree-20generations.ged"
    var b = GedcomFamilyGraph(gedcomText: donnaPull); b.sourceFileName = "familysearch-donna-20generations.ged"
    var g = a.merged(with: b)
    g.sourceFileName = "familysearch-merged-20260827.ged"
    return g
}

private func context(_ graph: GedcomFamilyGraph) -> HallieTurnExecutor.Context {
    HallieTurnExecutor.Context(profiles: [], graph: graph,
                               speakers: .init(ownerName: "Rick Breen", archivistName: nil, archivistPersonName: nil))
}

@Suite("Common ancestor — detector")
struct HallieCommonAncestorDetectTests {
    typealias Q = HallieLineageQuestion

    @Test func positives() {
        #expect(Q.detect("how are rick and donna related") == .commonAncestor(a: "Rick", b: "Donna"))
        #expect(Q.detect("How are Rick and Donna related?") == .commonAncestor(a: "Rick", b: "Donna"))
        #expect(Q.detect("are rick and donna related") == .commonAncestor(a: "Rick", b: "Donna"))
        #expect(Q.detect("is rick related to donna hudson?") == .commonAncestor(a: "Rick", b: "Donna Hudson"))
        #expect(Q.detect("common ancestor of rick and donna") == .commonAncestor(a: "Rick", b: "Donna"))
        #expect(Q.detect("what is the nearest common ancestor of rick breen and donna hudson") == .commonAncestor(a: "Rick Breen", b: "Donna Hudson"))
        #expect(Q.detect("what do rick and donna have in common ancestrally") == .commonAncestor(a: "Rick", b: "Donna"))
        #expect(Q.detect("do rick and donna share an ancestor?") == .commonAncestor(a: "Rick", b: "Donna"))
        #expect(Q.detect("rick and donna's common ancestor") == .commonAncestor(a: "Rick", b: "Donna"))
        #expect(Q.detect("who was the common ancestor between rick and donna") == .commonAncestor(a: "Rick", b: "Donna"))
        #expect(Q.detect("where do rick's and donna's lines meet") == .commonAncestor(a: "Rick", b: "Donna"))
        // The owner: "me and Donna".
        #expect(Q.detect("how am i related to donna") == nil, "\"am i\" is not a shape we claim (yet)")
        #expect(Q.detect("are me and donna related") == .commonAncestor(a: nil, b: "Donna"))
        #expect(Q.detect("how are donna and i related") == .commonAncestor(a: "Donna", b: nil))
    }

    /// True when the detector claimed the sentence as a pair question.
    private func isPair(_ text: String) -> Bool {
        if case .commonAncestor? = Q.detect(text) { return true }
        return false
    }

    @Test func negatives() {
        // Media asks keep their existing shapes (".personVideos" answers nil
        // for anyone filmable, so the catalog route still runs) — never ours.
        #expect(!isPair("videos of rick and donna"))
        #expect(Q.detect("videos of rick and donna") == .personVideos(person: "Rick And Donna"), "unchanged pre-existing shape")
        #expect(!isPair("show me photos of rick and donna"))
        #expect(!isPair("are there videos where rick and donna are related"))
        #expect(Q.detect("how are the breens related to the hudsons") == nil, "surnames, not two people")
        #expect(Q.detect("are they related") == nil)
        #expect(Q.detect("how are rick and donna") == nil)
        #expect(Q.detect("are me and myself related") == nil)
        #expect(Q.detect("rick's maternal line back 5 generations") == .ancestorLine(person: "Rick", line: .maternal, generations: 5))
    }
}

@Suite("Common ancestor — answers")
struct HallieCommonAncestorAnswerTests {
    let graph = mergedGraph()

    @Test func mergedTreeHasBothRootsAndDonnaHasParents() throws {
        #expect(graph.roots.map(\.name) == ["Richard Harding Breen Jr", "Donna Hudson"])
        let donna = try #require(graph.person(familySearchID: "G2CL-86B"))
        #expect(graph.relatives(.father, of: donna).map(\.name) == ["Walter Hudson"])
        #expect(graph.people.values.filter { $0.name == "Z Common" }.count == 1)
    }

    @Test func nearestCommonAncestorWithBothLinesAndCousinTerm() throws {
        let r = try #require(HallieLineageAnswer.answer(.commonAncestor(a: "Richard Breen Jr", b: "Donna Hudson"), context: context(graph)))
        #expect(r.outcome == .answered)
        #expect(r.prose.contains("Richard Harding Breen Jr and Donna Hudson share 1 recorded ancestor; the nearest is Z Common (b. 1840) — Richard Harding Breen Jr’s great-grandfather and Donna Hudson’s great-great-grandfather, making them 2nd cousins once removed."), "got: \(r.prose)")
        #expect(r.prose.contains("Richard Harding Breen Jr’s line: Z Common → George Breen → Richard Harding Breen Sr → Richard Harding Breen Jr."))
        #expect(r.prose.contains("Donna Hudson’s line: Z Common → Mabel Common → Harold Hudson → Walter Hudson → Donna Hudson."))
        #expect(r.catalogPersonName == "Z Common")
        #expect(r.offeredActions.first == .openFamilyTreePerson(personID: "@I5@", personName: "Z Common"))
        #expect(r.basisLine.hasPrefix(ArchivistBiographyPolicy.gedcomBasis))
    }

    @Test func ownerResolvesThroughTheSameChain() throws {
        // "me and Donna": nil = the owner; "Rick Breen" ~ "Richard Harding Breen Jr".
        let r = try #require(HallieLineageAnswer.answer(.commonAncestor(a: nil, b: "Donna"), context: context(graph)))
        #expect(r.outcome == .answered)
        #expect(r.prose.contains("making them 2nd cousins once removed"))
    }

    @Test func aSideWithNoParentsIsSaidHonestlyAndOffersGetFamilyTree() throws {
        // Rick's pull alone: Donna has no parents attached.
        let rickOnly = GedcomFamilyGraph(gedcomText: rickPull)
        let r = try #require(HallieLineageAnswer.answer(.commonAncestor(a: "Richard Breen Jr", b: "Donna"), context: context(rickOnly)))
        #expect(r.outcome == .declined)
        #expect(r.prose.hasPrefix("Donna Hudson’s side isn’t in the tree yet — it records no parents for Donna Hudson"), "got: \(r.prose)")
        #expect(r.prose.contains("add it to the current tree by FamilySearch ID"))
        #expect(r.offeredActions.contains(.getFamilyTree))
    }

    @Test func nothingSharedReportsBothDepths() throws {
        let unrelated = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME Rick /Breen/
        1 FAMC @F1@
        0 @I2@ INDI
        1 NAME Donna /Hudson/
        1 FAMC @F2@
        0 @I3@ INDI
        1 NAME Dad /Breen/
        1 FAMS @F1@
        0 @I4@ INDI
        1 NAME Mom /Hudson/
        1 FAMC @F3@
        1 FAMS @F2@
        0 @I5@ INDI
        1 NAME Gran /Hudson/
        1 FAMS @F3@
        0 @F1@ FAM
        1 HUSB @I3@
        1 CHIL @I1@
        0 @F2@ FAM
        1 WIFE @I4@
        1 CHIL @I2@
        0 @F3@ FAM
        1 WIFE @I5@
        1 CHIL @I4@
        0 TRLR
        """)
        let r = try #require(HallieLineageAnswer.answer(.commonAncestor(a: "Rick Breen", b: "Donna Hudson"), context: context(unrelated)))
        #expect(r.outcome == .declined)
        #expect(r.prose.contains("share no recorded ancestor: I walked 1 generation above Rick Breen and 2 above Donna Hudson"), "got: \(r.prose)")
        #expect(!r.offeredActions.contains(.getFamilyTree))
    }

    @Test func unknownNameDeclinesWithoutLookingUp() throws {
        let r = try #require(HallieLineageAnswer.answer(.commonAncestor(a: "Zebulon Nobody", b: "Donna"), context: context(graph)))
        #expect(r.outcome != .answered)
    }

    @Test func noTreeDeclines() throws {
        let r = try #require(HallieLineageAnswer.answer(.commonAncestor(a: "Rick", b: "Donna"),
                                                        context: HallieTurnExecutor.Context(profiles: [], graph: nil, speakers: .none)))
        #expect(r.outcome == .declined)
    }
}

@Suite("Two roots — provenance wording and anchors")
struct HallieTwoRootProvenanceTests {
    let graph = mergedGraph()

    @Test func provenanceNamesBothRootsAndBothFiles() throws {
        let r = try #require(HallieLineageAnswer.answer(.gedcomProvenance(person: "Donna", surname: "hudson"), context: context(graph)))
        #expect(r.prose.contains("It was merged by VideoScan from “familysearch-tree-20generations.ged” and “familysearch-donna-20generations.ged” by FamilySearch ID; its roots are Richard Harding Breen Jr (b. 1959) and Donna Hudson (b. 1959), so I take it to have been pulled for Richard Harding Breen Jr and Donna Hudson."), "got: \(r.prose)")
        #expect(!r.prose.contains("Its first record is"))
        #expect(r.prose.contains("I can trace 4 generations back from Donna"))
    }

    @Test func singleRootKeepsTheFirstRecordAssumption() throws {
        let single = GedcomFamilyGraph(gedcomText: rickPull)
        let r = try #require(HallieLineageAnswer.answer(.gedcomProvenance(person: "Donna", surname: nil), context: context(single)))
        #expect(r.prose.contains("Its first record is Richard Harding Breen Jr (b. 1959)"))
        #expect(r.prose.contains("add it to the current tree by FamilySearch ID"))
    }

    @Test func gedcomAwarenessMentionsTheMerge() {
        let r = HallieLineageAnswer.gedcomAwareness(graph)
        #expect(r.prose.contains("its roots are Richard Harding Breen Jr (b. 1959) and Donna Hudson (b. 1959)"))
        #expect(HallieLineageAnswer.mergedProvenanceSentence(GedcomFamilyGraph(gedcomText: rickPull)) == nil)
    }

    @Test @MainActor func familyTreeAnchorsIncludeEveryRoot() {
        let anchors = FamilyTreeLiveModel.anchors(in: graph)
        #expect(anchors.map(\.label) == ["Richard", "Donna"])
        #expect(anchors.map(\.isRoot) == [true, true], "Donna is a root in her own right, not just Rick's spouse")
        // A pinned owner still comes first.
        let pinned = FamilyTreeLiveModel.anchors(in: graph, ownerFamilySearchID: "G2CL-86B")
        #expect(pinned.map(\.label) == ["Donna", "Richard"])
    }
}
