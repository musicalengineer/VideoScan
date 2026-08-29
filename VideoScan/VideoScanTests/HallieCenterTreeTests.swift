// HallieCenterTreeTests.swift
// "can you center on marhta lamson" (Rick, live 2026-08-29, 39,250-person
// merged tree): the sentence fell to the translator, which searched the
// catalog for "martha lamson"; "center the family tree on martha lamson"
// drew a biography and left the focus as a chip. LOGIC: the detector
// (Rick's two exact sentences, the short forms, the pronoun form, the
// negatives) and the answer (one line, the focus action marked to be
// performed, which-one chips, People-tab honesty, spelling recovery,
// never a catalog search). Pure: synthetic GEDCOM text, no files, no model.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private let treeText = """
0 HEAD
0 @I1@ INDI
1 NAME Richard Harding /Breen/ Jr
1 SEX M
1 BIRT
2 DATE 1959
1 _FSFTID GVQV-NW3
0 @I2@ INDI
1 NAME Martha /Lamson/
1 SEX F
1 BIRT
2 DATE BEF 1633
2 PLAC Ridgewell, Essex, England
1 DEAT
2 DATE AFT 1717
2 PLAC Sudbury, Middlesex, Massachusetts Bay Colony
1 FAMS @F1@
1 _FSFTID KN45-D5S
0 @I3@ INDI
1 NAME Isaac /Rice/
1 SEX M
1 BIRT
2 DATE 1660
1 FAMC @F1@
0 @I4@ INDI
1 NAME John /Smith/
1 SEX M
1 BIRT
2 DATE 1700
0 @I5@ INDI
1 NAME John /Smith/
1 SEX M
1 BIRT
2 DATE 1750
0 @F1@ FAM
1 WIFE @I2@
1 CHIL @I3@
0 TRLR
"""

private func graph() -> GedcomFamilyGraph {
    var g = GedcomFamilyGraph(gedcomText: treeText)
    g.sourceFileName = "familysearch-tree-20generations.ged"
    return g
}

private func context(_ graph: GedcomFamilyGraph?,
                     profiles: [HallieTurnExecutor.ProfileSnapshot] = []) -> HallieTurnExecutor.Context {
    HallieTurnExecutor.Context(profiles: profiles, graph: graph,
                               speakers: .init(ownerName: "Rick Breen", archivistName: nil, archivistPersonName: nil))
}

@Suite("Center the tree — detector")
struct HallieCenterTreeDetectTests {
    typealias Q = HallieLineageQuestion

    @Test func ricksTwoLiveSentences() {
        // The typo survives detection as typed; recovery is the answer's job.
        #expect(Q.detect("can you center on marhta lamson") == .centerTree(person: "Marhta Lamson"))
        #expect(Q.detect("can you center the family tree on martha lamson") == .centerTree(person: "Martha Lamson"))
    }

    @Test func shortAndLongForms() {
        #expect(Q.detect("center on Martha Lamson.") == .centerTree(person: "Martha Lamson"))
        #expect(Q.detect("centre the tree on martha lamson") == .centerTree(person: "Martha Lamson"))
        #expect(Q.detect("please focus the tree on isaac rice") == .centerTree(person: "Isaac Rice"))
        #expect(Q.detect("focus on isaac rice") == .centerTree(person: "Isaac Rice"))
        #expect(Q.detect("zoom in on isaac rice") == .centerTree(person: "Isaac Rice"))
        #expect(Q.detect("show me martha lamson in the family tree") == .centerTree(person: "Martha Lamson"))
        #expect(Q.detect("show martha lamson in the tree") == .centerTree(person: "Martha Lamson"))
        #expect(Q.detect("open martha lamson in the family tree") == .centerTree(person: "Martha Lamson"))
        #expect(Q.detect("go to isaac rice in the tree") == .centerTree(person: "Isaac Rice"))
        #expect(Q.detect("take me to martha lamson") == .centerTree(person: "Martha Lamson"))
        #expect(Q.detect("Hallie, take me to Martha Lamson in the family tree?") == .centerTree(person: "Martha Lamson"))
        // The owner.
        #expect(Q.detect("center the tree on me") == .centerTree(person: nil))
    }

    @Test func pronounFormIsCarriedForMemoryResolution() {
        let her = Q.detect("center on her")
        #expect(her == .centerTree(person: "Her"))
        #expect(her?.mediaAskPerson == "Her")
        #expect(her?.replacingMediaAskPerson(with: "Martha Lamson") == .centerTree(person: "Martha Lamson"))
        #expect(Q.detect("center the family tree on him") == .centerTree(person: "Him"))
    }

    @Test func negatives() {
        // The verb phrase must be there, and the object must be a person.
        #expect(Q.centerTreeQuestion(in: "center the video") == nil)
        #expect(Q.centerTreeQuestion(in: "center of the family") == nil)
        #expect(Q.centerTreeQuestion(in: "who is at the center of the family") == nil)
        #expect(Q.centerTreeQuestion(in: "focus on the video") == nil)
        #expect(Q.centerTreeQuestion(in: "go to sleep") == nil)
        #expect(Q.centerTreeQuestion(in: "go to the catalog") == nil)
        #expect(Q.centerTreeQuestion(in: "center on 1985") == nil)
        #expect(Q.centerTreeQuestion(in: "center on donna's wedding") == nil)
        #expect(Q.centerTreeQuestion(in: "show me photos of donna in the tree") == nil)
        #expect(Q.centerTreeQuestion(in: "show me the family tree") == nil)
        // Whole-detector negatives: nothing else claims these either.
        #expect(Q.detect("center the video") == nil)
        #expect(Q.detect("center of the family") == nil)
        // Existing shapes keep their owners.
        #expect(Q.detect("show the family tree for the latta family") == .surnameTree(surname: "latta"))
        #expect(Q.detect("show me a photo of martha lamson") == .personPhoto(person: "Martha Lamson"))
    }
}

@Suite("Center the tree — answers")
struct HallieCenterTreeAnswerTests {
    let tree = graph()

    @Test func exactNameCentersWithBirthLineAndPerformsTheAction() throws {
        let r = try #require(HallieLineageAnswer.answer(.centerTree(person: "Martha Lamson"), context: context(tree)))
        #expect(r.route == .graph)
        #expect(r.outcome == .answered)
        #expect(r.prose == "Centering the Family Tree on Martha Lamson (b. before 1633, Ridgewell, Essex, England).")
        #expect(r.basisLine.hasPrefix(ArchivistBiographyPolicy.gedcomBasis))
        #expect(r.offeredActions == [.openFamilyTreePerson(personID: "@I2@", personName: "Martha Lamson")])
        #expect(r.performsFirstOfferedAction)
        #expect(r.catalogPersonName == "Martha Lamson")
        // Never a catalog search, and the composer may not re-say it.
        #expect(r.citations.isEmpty)
        #expect(r.queryDescription == "lineage: center tree on Martha Lamson")
        #expect(HallieAnswerPlan.derive(from: r).isComposable == false)
    }

    @Test func ricksTypoIsRecoveredAndSaid() throws {
        let r = try #require(HallieLineageAnswer.answer(.centerTree(person: "Marhta Lamson"), context: context(tree)))
        #expect(r.outcome == .answered)
        #expect(r.prose == "I took “Marhta Lamson” to mean Martha Lamson. Centering the Family Tree on Martha Lamson (b. before 1633, Ridgewell, Essex, England).")
        #expect(r.offeredActions == [.openFamilyTreePerson(personID: "@I2@", personName: "Martha Lamson")])
        #expect(r.performsFirstOfferedAction)
        #expect(r.basisLine.contains("“Marhta Lamson” taken as Martha Lamson"))
    }

    @Test func ownerCentersOnTheRoot() throws {
        let r = try #require(HallieLineageAnswer.answer(.centerTree(person: nil), context: context(tree)))
        #expect(r.outcome == .answered, "got: \(r.prose)")
        #expect(r.offeredActions == [.openFamilyTreePerson(personID: "@I1@", personName: "Richard Harding Breen Jr")])
        #expect(r.performsFirstOfferedAction)
    }

    @Test func namesakesAskWhichOneWithAChipEach() throws {
        let r = try #require(HallieLineageAnswer.answer(.centerTree(person: "John Smith"), context: context(tree)))
        #expect(r.outcome == .needsClarification)
        #expect(r.prose.hasPrefix("Which John Smith do you mean — John Smith (b. 1700) or John Smith (b. 1750)?"), "got: \(r.prose)")
        #expect(r.offeredActions == [
            .openFamilyTreePerson(personID: "@I4@", personName: "John Smith"),
            .openFamilyTreePerson(personID: "@I5@", personName: "John Smith"),
        ])
        #expect(!r.performsFirstOfferedAction)
    }

    @Test func peopleTabOnlyPersonIsSaidHonestly() throws {
        let profiles = [HallieTurnExecutor.ProfileSnapshot(stableID: "p-timmy", canonicalName: "Timmy Breen", aliases: ["Timmy"])]
        let r = try #require(HallieLineageAnswer.answer(.centerTree(person: "Timmy Breen"), context: context(tree, profiles: profiles)))
        #expect(r.outcome == .declined)
        #expect(r.prose == "Timmy Breen is in the People tab but not in the family tree, so there's nothing to center on — you'll find Timmy Breen in the People tab.")
        #expect(r.offeredActions.isEmpty)
        #expect(!r.performsFirstOfferedAction)
        #expect(r.citations.isEmpty)
    }

    @Test func unknownNameIsAnHonestTreeMissNotASearch() throws {
        let r = try #require(HallieLineageAnswer.answer(.centerTree(person: "Zebulon Quackenbush"), context: context(tree)))
        #expect(r.route == .graph)
        #expect(r.outcome == .declined)
        #expect(r.prose.contains("Zebulon Quackenbush"), "got: \(r.prose)")
        #expect(r.offeredActions.isEmpty)
        #expect(!r.performsFirstOfferedAction)
        #expect(r.citations.isEmpty)
    }

    @Test func noTreeLoaded() throws {
        let r = try #require(HallieLineageAnswer.answer(.centerTree(person: "Martha Lamson"), context: context(nil)))
        #expect(r.outcome == .declined)
        #expect(r.prose.contains("family tree loaded"))
    }

    @Test func performFlagSurvivesResultCopies() throws {
        let r = try #require(HallieLineageAnswer.answer(.centerTree(person: "Martha Lamson"), context: context(tree)))
        #expect(r.prefixingBasis("note").performsFirstOfferedAction)
        #expect(HallieLineageAnswer.prefixing("Lead.", to: r).performsFirstOfferedAction)
        let extra = HallieAttachment.photoRequest(personName: "x", folderURL: URL(fileURLWithPath: "/tmp"))
        #expect(r.adding(attachments: [extra]).performsFirstOfferedAction)
    }
}
