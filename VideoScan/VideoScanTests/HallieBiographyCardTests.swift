// HallieBiographyCardTests.swift
// LIVE MISS (Rick, 2026-08-29, merged 39,250-person tree): "tell me about
// Matthew Rice" → dates, parents, nothing else (no places, no marriage, no
// children, no depth), while "center the family tree on martha lamson"
// (graph .familyTree) gave the fuller card. Two templates, two cards for
// the same kind of ask. Both operations now draw ONE fact plan
// (HallieBiographyCard): this suite pins the Matthew Rice card shape for
// BOTH asks — same fact set, one claim per sentence, each cited — and a
// sparse person (a name and one parent) degrading gracefully. Pure:
// synthetic GEDCOM text, no files, no model.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private let treeText = """
0 HEAD
0 @I1@ INDI
1 NAME Matthew /Rice/
1 SEX M
1 BIRT
2 DATE 28 FEB 1629
2 PLAC Bury St Edmunds, Suffolk, England
1 DEAT
2 DATE BEF 29 NOV 1717
2 PLAC Sudbury, Middlesex, Massachusetts Bay Colony
1 FAMC @F1@
1 FAMS @F2@
0 @I2@ INDI
1 NAME Edmund /Rice/
1 SEX M
1 FAMS @F1@
0 @I3@ INDI
1 NAME Thomasine /Frost/
1 SEX F
1 FAMS @F1@
0 @I4@ INDI
1 NAME Martha /Lamson/
1 SEX F
1 BIRT
2 DATE BEF 1633
1 FAMS @F2@
0 @I5@ INDI
1 NAME Isaac /Rice/
1 SEX M
1 FAMC @F2@
1 FAMS @F3@
0 @I6@ INDI
1 NAME Patience /Rice/
1 SEX F
1 FAMC @F2@
0 @I7@ INDI
1 NAME Abigail /Rice/
1 SEX F
1 FAMC @F3@
0 @I8@ INDI
1 NAME Sparse /Person/
1 FAMC @F4@
0 @I9@ INDI
1 NAME Only /Parent/
1 SEX F
1 FAMS @F4@
0 @I10@ INDI
1 NAME Lone /Record/
0 @F1@ FAM
1 HUSB @I2@
1 WIFE @I3@
1 CHIL @I1@
0 @F2@ FAM
1 HUSB @I1@
1 WIFE @I4@
1 MARR
2 DATE 1654
1 CHIL @I5@
1 CHIL @I6@
0 @F3@ FAM
1 HUSB @I5@
1 CHIL @I7@
0 @F4@ FAM
1 WIFE @I9@
1 CHIL @I8@
0 TRLR
"""

private func graph() -> GedcomFamilyGraph { GedcomFamilyGraph(gedcomText: treeText) }

private func ask(_ name: String, _ operation: ArchivistQueryAST.Graph.Operation)
    async throws -> HallieTurnExecutor.Result {
    try await HallieTurnExecutor.execute(
        .graph(.init(people: [name], operation: operation)),
        context: HallieTurnExecutor.Context(graph: graph()))
}

/// The facts Rick expects on Matthew Rice's card, each a substring the
/// prose AND the plan's claims must carry, whichever ask produced them.
private let matthewFacts = [
    "Matthew Rice was born 28 February 1629 in Bury St Edmunds, Suffolk, England",
    "died before 29 November 1717 in Sudbury, Middlesex, Massachusetts Bay Colony",
    "child of Edmund Rice and Thomasine Frost",
    "married to Martha Lamson (married 1654)",
    "2 recorded children, Isaac Rice and Patience Rice",
    "2 recorded ancestors across 1 generation",
    "3 recorded descendants across 2 generations",
]

@Suite("Hallie biography card — one fact plan for both asks")
struct HallieBiographyCardTests {

    @Test func tellMeAboutCarriesTheWholeCard() async throws {
        let r = try await ask("Matthew Rice", .biography)
        #expect(r.outcome == .answered)
        #expect(r.prose
                == "Matthew Rice was born 28 February 1629 in Bury St Edmunds, Suffolk, England "
                    + "and died before 29 November 1717 in Sudbury, Middlesex, Massachusetts Bay Colony. "
                    + "He was the child of Edmund Rice and Thomasine Frost. "
                    + "He was married to Martha Lamson (married 1654). "
                    + "He had 2 recorded children, Isaac Rice and Patience Rice. "
                    + "His family tree includes 2 recorded ancestors across 1 generation "
                    + "and 3 recorded descendants across 2 generations.")
        #expect(r.basisLine == "Basis: imported family tree (GEDCOM).")
        #expect(!r.prose.lowercased().contains("living"))
        for fact in matthewFacts { #expect(r.prose.contains(fact), "missing: \(fact)") }
    }

    @Test func familyTreeAskCarriesTheSameFacts() async throws {
        let bio = try await ask("Matthew Rice", .biography)
        let tree = try await ask("Matthew Rice", .familyTree)
        #expect(tree.outcome == .answered)
        for fact in matthewFacts { #expect(tree.prose.contains(fact), "missing: \(fact)") }
        // Same fact set: the sentences of one are the sentences of the other.
        let split = HallieCompositionVerifier.splitSentences
        #expect(Set(split(bio.prose)) == Set(split(tree.prose)))
        // The tree ask still offers to open the tab; the biography does not.
        #expect(tree.offeredActions == [.openFamilyTree(personName: "Matthew Rice")])
        #expect(bio.offeredActions.isEmpty)
    }

    /// The composer gets one claim per fact, each cited to its GEDCOM
    /// pointers, with the biography sentence budget — not one blob claim
    /// it may summarise down to two sentences.
    @Test func bothAsksShareOneClaimPlan() async throws {
        let bio = try #require(try await ask("Matthew Rice", .biography).answerPlan)
        let tree = try #require(try await ask("Matthew Rice", .familyTree).answerPlan)
        #expect(bio.claims == tree.claims)
        #expect(bio.shape == .biography)
        #expect(bio.subject == "Matthew Rice")
        #expect(bio.claimIDs == ["c1", "c2", "c3", "c4", "c5"])
        #expect(bio.claims[0].evidenceIDs == ["@I1@"])
        #expect(bio.claims[1].evidenceIDs == ["@I1@", "@I2@", "@I3@"])
        #expect(bio.claims[2].evidenceIDs == ["@I1@", "@I4@"])
        #expect(bio.claims[3].evidenceIDs == ["@I1@", "@I5@", "@I6@"])
        #expect(bio.claims.allSatisfy { $0.attribution == nil })
        #expect(bio.lifeDatesClaims.map(\.id) == ["c1"], "the verifier restores the dates sentence from c1")
        #expect(bio.subjectLeadSentence?.claimIDs == ["c1"])
        #expect(HallieAnswerPlan.derive(from: try await ask("Matthew Rice", .biography)) == bio,
                "the executor's plan is the one the coordinator composes from")
    }

    @Test func sparsePersonDegradesGracefully() async throws {
        let r = try await ask("Sparse Person", .biography)
        #expect(r.outcome == .answered)
        #expect(r.prose
                == "Sparse Person was the child of Only Parent. "
                    + "Their family tree includes 1 recorded ancestor across 1 generation.")
        #expect(r.answerPlan?.claims.count == 2)
        #expect(r.answerPlan?.subjectLeadSentence?.text == "Sparse Person was the child of Only Parent.")
        #expect(!r.prose.contains("born") && !r.prose.contains("died") && !r.prose.contains("married"))
        #expect(try await ask("Sparse Person", .familyTree).prose == r.prose)
    }

    @Test func personWithNoFactsAtAllIsSaidHonestly() async throws {
        let r = try await ask("Lone Record", .biography)
        #expect(r.outcome == .declined)
        #expect(r.prose.hasPrefix("Lone Record is in the family tree, but it records no further details."))
        #expect(r.answerPlan == nil)
    }

    @Test func recordedDatesKeepTheirQualifierAndPrecision() {
        let d = HallieBiographyCard.spokenDate
        #expect(d("28 FEB 1629") == "28 February 1629")
        #expect(d("BEF 29 NOV 1717") == "before 29 November 1717")
        #expect(d("AFT 1717") == "after 1717")
        #expect(d("ABT 1633") == "about 1633")
        #expect(d("EST 1633") == "about 1633")
        #expect(d("BET 1700 AND 1710") == "between 1700 and 1710")
        #expect(d("MAY 1902") == "May 1902")
        #expect(d("1959") == "1959")
        #expect(d("unknown") == nil, "no year → no date claim")
        #expect(d(nil) == nil)
    }

    @Test func placeWithoutADateIsStillAFactAndNeverADate() {
        let g = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @X@ INDI
        1 NAME Place /Only/
        1 SEX F
        1 BIRT
        2 PLAC Boston
        1 DEAT
        2 DATE 1900
        0 @Y@ INDI
        1 NAME Nothing /Here/
        0 TRLR
        """)
        #expect(HallieBiographyCard.vitalsClause(g.people["@X@"]!) == "was born in Boston and died 1900")
        #expect(HallieBiographyCard.vitalsClause(g.people["@Y@"]!) == nil)
        #expect(HallieBiographyCard.card(for: g.people["@X@"]!, in: g).prose
                == "Place Only was born in Boston and died 1900.")
    }
}
