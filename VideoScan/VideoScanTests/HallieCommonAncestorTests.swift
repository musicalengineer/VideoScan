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
2 PLAC Boston, Suffolk, Massachusetts
1 DEAT
2 DATE AFT 1910
2 PLAC Sudbury, Middlesex, Massachusetts
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
        // Rick's exact live phrasings, 2026-08-28 spot test.
        #expect(Q.detect("show me the closest common ancestor between rick and donna") == .commonAncestor(a: "Rick", b: "Donna"))
        #expect(Q.detect("closest common ancestor of rick and donna") == .commonAncestor(a: "Rick", b: "Donna"))
        #expect(Q.detect("can you find the closest common ancestor between richard harding breen Jr and Donna Hudson?") == .commonAncestor(a: "Richard Harding Breen Jr", b: "Donna Hudson"))
        #expect(Q.detect("Find the most recent common ancestor between rick and donna") == .commonAncestor(a: "Rick", b: "Donna"))
        #expect(Q.detect("Find the most recent common ancestor between rick and donna hudson born 1959") == .commonAncestor(a: "Rick", b: "Donna Hudson"))
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
        // Rick and Donna themselves are spouses (direct kin, see below);
        // their fathers are the cousin pair: Sr 2 up, Walter 3 up.
        let r = try #require(HallieLineageAnswer.answer(.commonAncestor(a: "Richard Breen Sr", b: "Walter Hudson"), context: context(graph)))
        #expect(r.outcome == .answered)
        #expect(r.prose.contains("Richard Harding Breen Sr and Walter Hudson share 1 recorded ancestor; the nearest is Z Common (b. 1840, Boston, Suffolk, Massachusetts – d. after 1910, Sudbury, Middlesex, Massachusetts) — Richard Harding Breen Sr’s grandfather and Walter Hudson’s great-grandfather, making them 1st cousins once removed."), "got: \(r.prose)")
        #expect(r.prose.contains("Richard Harding Breen Sr’s line: Z Common → George Breen → Richard Harding Breen Sr."))
        #expect(r.prose.contains("Walter Hudson’s line: Z Common → Mabel Common → Harold Hudson → Walter Hudson."))
        #expect(r.catalogPersonName == "Z Common")
        #expect(r.offeredActions.first == .openFamilyTreePerson(personID: "@I5@", personName: "Z Common"))
        #expect(r.basisLine.hasPrefix(ArchivistBiographyPolicy.gedcomBasis))
    }

    /// Two first cousins (Abel, Beth) under one grandfather Z (the
    /// `zLines` record) whose mother W (approximate year + a place that
    /// must stay out of the prose) is the second, farther shared ancestor.
    private func cousinGraph(zLines: String) -> GedcomFamilyGraph {
        GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME Z /Common/
        1 SEX M
        \(zLines)
        1 FAMC @F9@
        1 FAMS @F0@
        0 @I2@ INDI
        1 NAME W /Common/
        1 SEX F
        1 BIRT
        2 DATE ABT 1602
        2 PLAC Must Not Appear
        1 FAMS @F9@
        0 @I3@ INDI
        1 NAME Pa /Common/
        1 SEX M
        1 FAMC @F0@
        1 FAMS @F1@
        0 @I4@ INDI
        1 NAME Ma /Common/
        1 SEX F
        1 FAMC @F0@
        1 FAMS @F2@
        0 @I5@ INDI
        1 NAME Abel /Common/
        1 SEX M
        1 FAMC @F1@
        0 @I6@ INDI
        1 NAME Beth /Common/
        1 SEX F
        1 FAMC @F2@
        0 @F9@ FAM
        1 WIFE @I2@
        1 CHIL @I1@
        0 @F0@ FAM
        1 HUSB @I1@
        1 CHIL @I3@
        1 CHIL @I4@
        0 @F1@ FAM
        1 HUSB @I3@
        1 CHIL @I5@
        0 @F2@ FAM
        1 WIFE @I4@
        1 CHIL @I6@
        0 TRLR
        """)
    }

    private func nearestSentence(zLines: String) throws -> String {
        let g = cousinGraph(zLines: zLines)
        let r = try #require(HallieLineageAnswer.answer(.commonAncestor(a: "Abel Common", b: "Beth Common"), context: context(g)))
        #expect(r.outcome == .answered)
        return r.prose
    }

    // Rick 2026-08-28: the nearest ancestor carries the record's critical
    // info — "Martha Lamson (b. 1633 – d. after 1717, Sudbury, Middlesex,
    // Massachusetts Bay Colony)". Qualifiers as recorded, places when
    // recorded, nothing invented, never "living".
    @Test func nearestCarriesBothVitalsWithPlaces() throws {
        let prose = try nearestSentence(zLines: """
        1 BIRT
        2 DATE ABT 1633
        2 PLAC Boston, Suffolk, Massachusetts Bay Colony
        1 DEAT
        2 DATE AFT 1717
        2 PLAC Sudbury, Middlesex, Massachusetts Bay Colony
        """)
        #expect(prose.hasPrefix("Abel Common and Beth Common share 2 recorded ancestors; the nearest is Z Common (b. about 1633, Boston, Suffolk, Massachusetts Bay Colony – d. after 1717, Sudbury, Middlesex, Massachusetts Bay Colony) — Abel Common’s grandfather and Beth Common’s grandfather, making them 1st cousins."), "got: \(prose)")
        // "Also shared:" stays readable — years (with qualifier) only, no places.
        #expect(prose.contains("Also shared: W Common (b. about 1602) (3/3 generations up)."), "got: \(prose)")
        #expect(!prose.contains("Must Not Appear"))
    }

    @Test func nearestWithOnlyADeathPlaceOmitsTheBirthPlaceGracefully() throws {
        let prose = try nearestSentence(zLines: """
        1 BIRT
        2 DATE 1633
        1 DEAT
        2 DATE AFT 1717
        2 PLAC Sudbury, Middlesex, Massachusetts Bay Colony
        """)
        #expect(prose.contains("the nearest is Z Common (b. 1633 – d. after 1717, Sudbury, Middlesex, Massachusetts Bay Colony) — "), "got: \(prose)")
    }

    @Test func nearestWithOnlyABirthYearSaysJustThat() throws {
        let prose = try nearestSentence(zLines: """
        1 BIRT
        2 DATE 12 MAR 1633
        """)
        #expect(prose.contains("the nearest is Z Common (b. 1633) — "), "got: \(prose)")
        #expect(!prose.lowercased().contains("living"))
    }

    @Test func nearestWithNoVitalsHasNoParenthetical() throws {
        let prose = try nearestSentence(zLines: "1 BIRT\n2 PLAC Somewhere Without A Year")
        #expect(prose.contains("the nearest is Z Common — "), "got: \(prose)")
        #expect(!prose.contains("Somewhere Without A Year"), "a place without a year is not a date claim")
    }

    @Test func ownerResolvesThroughTheSameChain() throws {
        // "me and Walter": nil = the owner; "Rick Breen" ~ "Richard Harding Breen Jr"
        // (the one root matching the owner's name in a two-root tree).
        let r = try #require(HallieLineageAnswer.answer(.commonAncestor(a: nil, b: "Walter Hudson"), context: context(graph)))
        #expect(r.outcome == .answered)
        // Rick 2026-08-28: in-law is the aside, the blood link is the answer.
        #expect(r.prose.contains("share 1 recorded ancestor"), "got: \(r.prose)")
        #expect(r.prose.contains("Walter Hudson is Richard Harding Breen Jr’s father-in-law"), "got: \(r.prose)")
        #expect(!r.prose.hasPrefix("Walter Hudson is"))
    }

    @Test func aSideWithNoParentsIsSaidHonestlyAndOffersGetFamilyTree() throws {
        // Rick's pull alone: Donna has no parents attached. (Rick himself is
        // her husband — direct kin — so ask about his grandfather George.)
        let rickOnly = GedcomFamilyGraph(gedcomText: rickPull)
        let r = try #require(HallieLineageAnswer.answer(.commonAncestor(a: "George Breen", b: "Donna"), context: context(rickOnly)))
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

    /// codex #776: neither side is a person → not ours; the question
    /// continues as typed (nil), never a graph decline.
    @Test func twoNonPeopleFallThrough() {
        #expect(HallieLineageQuestion.detect("how are astronomy and philosophy related") == .commonAncestor(a: "Astronomy", b: "Philosophy"))
        #expect(HallieLineageAnswer.answer(.commonAncestor(a: "Astronomy", b: "Philosophy"), context: context(graph)) == nil)
        #expect(HallieLineageAnswer.answer(.commonAncestor(a: "Music", b: "Math"), context: context(graph)) == nil)
        #expect(HallieLineageQuestion.detect("how are music and math related") == .commonAncestor(a: "Music", b: "Math"))
    }

    /// codex #776: direct kin are named as such before any cousin math.
    @Test func directKinBeforeCousinMath() throws {
        let father = try #require(HallieLineageAnswer.answer(.commonAncestor(a: "Richard Breen Jr", b: "Richard Breen Sr"), context: context(graph)))
        #expect(father.prose == "Richard Harding Breen Sr is Richard Harding Breen Jr’s father.")
        let grand = try #require(HallieLineageAnswer.answer(.commonAncestor(a: "Richard Breen Jr", b: "George Breen"), context: context(graph)))
        #expect(grand.prose == "George Breen is Richard Harding Breen Jr’s grandfather. Line: Richard Harding Breen Jr → Richard Harding Breen Sr → George Breen.", "got: \(grand.prose)")
        #expect(!grand.prose.contains("aunt"))
        let spouse = try #require(HallieLineageAnswer.answer(.commonAncestor(a: "Richard Breen Jr", b: "Donna Hudson"), context: context(graph)))
        // Rick 2026-08-28 overrides codex #776 for affinal kinds: a marriage
        // is an aside, the blood link is the answer to "common ancestor".
        #expect(spouse.prose.contains("share"), "blood answer first: \(spouse.prose)")
        #expect(spouse.prose.contains("Donna Hudson is Richard Harding Breen Jr’s wife"), "marriage kept as an aside: \(spouse.prose)")
        #expect(!spouse.prose.hasPrefix("Donna Hudson is"))
        let great = try #require(HallieLineageAnswer.answer(.commonAncestor(a: "Donna Hudson", b: "Z Common"), context: context(graph)))
        #expect(great.prose.hasPrefix("Z Common is Donna Hudson’s great-great-grandfather."))
        #expect(great.basisLine.contains("Direct relation"))
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
        #expect(r.prose.contains("It is a VideoScan merge artifact derived from “familysearch-tree-20generations.ged” and “familysearch-donna-20generations.ged” by FamilySearch ID — lossy: names, vitals, links and FamilySearch IDs only; the source files remain the record. its roots are Richard Harding Breen Jr (b. 1959) and Donna Hudson (b. 1959), so I take it to have been pulled for Richard Harding Breen Jr and Donna Hudson."), "got: \(r.prose)")
        #expect(!r.prose.contains("Its first record is"))
        #expect(r.prose.contains("I can trace 4 generations back from Donna"))
    }

    @Test func singleRootKeepsTheFirstRecordAssumption() throws {
        let single = GedcomFamilyGraph(gedcomText: rickPull)
        let r = try #require(HallieLineageAnswer.answer(.gedcomProvenance(person: "Donna", surname: nil), context: context(single)))
        #expect(r.prose.contains("Its first record is Richard Harding Breen Jr (b. 1959)"))
        #expect(r.prose.contains("add it to the current tree by FamilySearch ID"))
    }

    /// codex #780: a same-root re-pull merged into the old tree has ONE
    /// root and (here) one file name — still called an artifact, by flag.
    @Test func sameRootMergeIsStillRecognisedAsAnArtifact() throws {
        var old = GedcomFamilyGraph(gedcomText: rickPull); old.sourceFileName = "familysearch-tree.ged"
        var again = GedcomFamilyGraph(gedcomText: rickPull); again.sourceFileName = "familysearch-tree.ged"
        let merged = old.merged(with: again)
        #expect(merged.roots.count == 1)
        #expect(merged.sourceFileNames == ["familysearch-tree.ged"])
        #expect(merged.isMergedArtifact)
        let line = try #require(HallieLineageAnswer.mergedProvenanceSentence(merged))
        #expect(line.hasPrefix("It is a VideoScan merge artifact derived from “familysearch-tree.ged” by FamilySearch ID — lossy"))
        #expect(line.hasSuffix("Its root is Richard Harding Breen Jr (b. 1959), so I take it to have been pulled for Richard Harding Breen Jr."), "got: \(line)")
        // Round trip through the writer keeps the flag; a plain export has none.
        #expect(GedcomFamilyGraph(gedcomText: merged.gedcomText()).isMergedArtifact)
        #expect(HallieLineageAnswer.mergedProvenanceSentence(GedcomFamilyGraph(gedcomText: rickPull)) == nil)
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


@Suite("Two roots — owner resolution is evidence, not file order")
struct HallieTwoRootOwnerTests {
    /// Donna FIRST, then Rick Jr, then Rick Sr (not a root).
    private static let donnaFirst = """
    0 HEAD
    1 _VS_ROOT @I1@
    1 _VS_ROOT @I2@
    0 @I1@ INDI
    1 NAME Donna /Hudson/
    1 SEX F
    1 _FSFTID G2CL-86B
    0 @I2@ INDI
    1 NAME Richard Harding /Breen/ Jr
    1 SEX M
    1 _FSFTID GVQV-NW3
    0 @I3@ INDI
    1 NAME Richard Harding /Breen/ Sr
    1 SEX M
    1 _FSFTID RICK-DAD
    0 TRLR
    """
    /// Two roots that BOTH match "Rick Breen".
    private static let twoRichards = """
    0 HEAD
    1 _VS_ROOT @I1@
    1 _VS_ROOT @I2@
    0 @I1@ INDI
    1 NAME Richard Harding /Breen/ Sr
    1 SEX M
    1 _FSFTID RICK-DAD
    0 @I2@ INDI
    1 NAME Richard Harding /Breen/ Jr
    1 SEX M
    1 _FSFTID GVQV-NW3
    0 TRLR
    """

    @Test func ownerIsTheSecondRoot() {
        let g = GedcomFamilyGraph(gedcomText: Self.donnaFirst)
        #expect(g.roots.map(\.name) == ["Donna Hudson", "Richard Harding Breen Jr"])
        guard case .one(let p, let note) = HallieOwnerResolver.resolve("Rick Breen", graph: g) else {
            Issue.record("expected .one"); return
        }
        #expect(p.id == "@I2@", "the one ROOT matching the name — never the first root, never Sr")
        #expect(note.contains("the one tree root matching Rick Breen"))
    }

    @Test func ambiguousTwoRootCaseFailsClosed() {
        let g = GedcomFamilyGraph(gedcomText: Self.twoRichards)
        guard case .none(let reason?) = HallieOwnerResolver.resolve("Rick Breen", graph: g) else {
            Issue.record("expected .none(reason:)"); return
        }
        #expect(reason.contains("2 home people"))
        #expect(reason.contains("set your FamilySearch ID"))
        // Reversed root order: same answer (no file-order dependence).
        let reversed = GedcomFamilyGraph(gedcomText: Self.twoRichards.replacingOccurrences(of: "1 _VS_ROOT @I1@\n1 _VS_ROOT @I2@", with: "1 _VS_ROOT @I2@\n1 _VS_ROOT @I1@"))
        #expect(reversed.roots.map(\.id) == ["@I2@", "@I1@"])
        guard case .none = HallieOwnerResolver.resolve("Rick Breen", graph: reversed) else {
            Issue.record("expected .none for reversed order"); return
        }
    }

    @Test func pinnedFamilySearchIDWinsRegardlessOfOrder() {
        for text in [Self.twoRichards, Self.donnaFirst] {
            let g = GedcomFamilyGraph(gedcomText: text)
            guard case .one(let p, _) = HallieOwnerResolver.resolve("Rick Breen", graph: g, familySearchID: "GVQV-NW3") else {
                Issue.record("expected .one"); return
            }
            #expect(p.familySearchID == "GVQV-NW3")
        }
        // A pin the tree lacks still fails closed.
        guard case .none(let reason?) = HallieOwnerResolver.resolve("Rick Breen", graph: GedcomFamilyGraph(gedcomText: Self.donnaFirst), familySearchID: "NOPE-000") else {
            Issue.record("expected stale-pin .none"); return
        }
        #expect(reason.contains("NOPE-000"))
    }

    @Test func singleRootTreeKeepsTheOldFallback() {
        let g = GedcomFamilyGraph(gedcomText: Self.donnaFirst.replacingOccurrences(of: "1 _VS_ROOT @I1@\n1 _VS_ROOT @I2@\n", with: ""))
        #expect(g.roots.count == 1)
        guard case .many(let like) = HallieOwnerResolver.resolve("Rick Breen", graph: g) else {
            Issue.record("expected .many (root Donna is not among the Richards)"); return
        }
        #expect(like.count == 2)
    }

    // Rick 2026-08-28 live miss: "closest common ancestor of rick and donna"
    // answered "Donna Hudson is Richard Harding Breen Jr's wife." A marriage
    // is not a common ancestor; the blood answer must win and mention the
    // marriage as an aside.
    @Test func spouseEdgeDoesNotPreemptAnExplicitCommonAncestorAsk() throws {
        let graph = mergedGraph()
        let ctx = context(graph)
        let rick = try #require(graph.roots.first), donna = try #require(graph.roots.dropFirst().first)
        #expect(graph.directRelation(between: rick.id, and: donna.id)?.kind == .spouses)
        let r = try #require(HallieLineageAnswer.answer(.commonAncestor(a: rick.name, b: donna.name), context: ctx))
        #expect(r.outcome == .answered)
        #expect(r.prose.contains("share"))
        #expect(r.prose.contains("cousin"))
        #expect(r.prose.contains("wife"))          // the marriage is an aside…
        #expect(!r.prose.hasPrefix("Donna Hudson is")) // …not the answer
    }

    // Rick 2026-08-28 live: "most recent common ancestor between rick and
    // donna" → "Which Donna — Agatha Donna Knauss (b. 1520) … or Donna
    // Hudson (b. 1959)?" A bare name shared with a namesake resolves to the
    // ROOT when exactly one candidate is a root.
    @Test func bareNameSharedWithANamesakeResolvesToTheRoot() throws {
        var text = mergedGraph().gedcomText()
        // Add a 16th-century namesake on Donna's side, no FSID, no parents.
        // (2026-08-29: a bare name is a GIVEN name — "Agatha Donna Knauss"
        // is no longer a namesake for "Donna"; "Donna Agatha Knauss" is.)
        text = text.replacingOccurrences(of: "0 TRLR", with: "0 @I900@ INDI\n1 NAME Donna Agatha /Knauss/\n1 SEX F\n1 BIRT\n2 DATE ABT 1520\n0 TRLR")
        let graph = GedcomFamilyGraph(gedcomText: text)
        #expect(graph.people(namedLike: "Donna").count >= 2)
        let r = try #require(HallieLineageAnswer.answer(.commonAncestor(a: "Rick", b: "Donna"), context: context(graph)))
        #expect(r.outcome == .answered, "got: \(r.prose)")
        #expect(!r.prose.hasPrefix("Which Donna"))
        #expect(r.basisLine.contains("a root of this tree"))
    }
}
