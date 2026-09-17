// FamilyTreeDuplicatesTests.swift
// The detector that lets Rick say "this is the right Mary" (2026-09-17).
//
// The first case is his real one, from the live tree: Mary Christina
// O'Connor exists twice under the same parents, once with her vitals and
// once with her siblings. The rest are the ways this could hurt him — a
// brother hidden because he shares a name and parents with the boy who died
// before him is a far worse outcome than a duplicate left on screen.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("Family tree duplicates")
struct FamilyTreeDuplicatesTests {

    /// Builds a graph from GEDCOM text, which is the only honest way to get
    /// one — the parser owns the invariants.
    private func graph(_ lines: [String]) throws -> GedcomFamilyGraph {
        let text = (["0 HEAD"] + lines + ["0 TRLR"]).joined(separator: "\n")
        return try #require(GedcomFamilyGraph(gedcomText: text) as GedcomFamilyGraph?)
    }

    // MARK: Rick's case

    @Test func theSameGrandmotherRecordedTwiceUnderOneSetOfParentsIsOneGroup() throws {
        let g = try graph([
            "0 @F6@ FAM", "1 HUSB @P1@", "1 WIFE @P2@", "1 CHIL @I5@", "1 CHIL @I7@",
            "0 @P1@ INDI", "1 NAME Patrick /O'Connor/", "1 SEX M",
            "0 @P2@ INDI", "1 NAME Bridget /Ronan/", "1 SEX F",
            // Her vitals and married line.
            "0 @I7@ INDI", "1 NAME Mary Christina /O'Connor/", "1 SEX F",
            "1 BIRT", "2 DATE 23 December 1904", "1 DEAT", "2 DATE 16 July 1985",
            "1 FAMC @F6@", "1 _FSFTID G89Q-34N",
            // Her parents and siblings, sloppier dates, no death.
            "0 @I5@ INDI", "1 NAME Mary /O'Connor/", "1 SEX F",
            "1 BIRT", "2 DATE 1905",
            "1 FAMC @F6@", "1 _FSFTID GNZ5-428",
        ])
        let groups = FamilyTreeDuplicates.groups(in: g, rootIDs: ["@I7@"], generations: 3)
        #expect(groups.count == 1, "the two Marys were not recognised as one person")
        let group = try #require(groups.first)
        #expect(Set(group.personIDs) == ["@I5@", "@I7@"])
        #expect(group.id == "G89Q-34N+GNZ5-428", "the group id must be the sorted FamilySearch IDs, so a re-pull keeps the decision")
        #expect(group.evidence.contains("the same parents"))
        #expect(group.evidence.contains("birth years a year or two apart"))
    }

    // MARK: The ways this could hurt him

    /// A son named for the brother who died before him. Same name, same
    /// parents, a decade apart — two boys, and neither may be hidden.
    @Test func aBrotherNamedForTheBrotherWhoDiedIsNotADuplicate() throws {
        let g = try graph([
            "0 @F1@ FAM", "1 HUSB @P1@", "1 CHIL @A@", "1 CHIL @B@",
            "0 @P1@ INDI", "1 NAME Richard /Breen/", "1 SEX M",
            "0 @A@ INDI", "1 NAME John /Breen/", "1 SEX M",
            "1 BIRT", "2 DATE 1898", "1 DEAT", "2 DATE 1899",
            "1 FAMC @F1@", "1 _FSFTID AAAA-111",
            "0 @B@ INDI", "1 NAME John /Breen/", "1 SEX M",
            "1 BIRT", "2 DATE 1908",
            "1 FAMC @F1@", "1 _FSFTID BBBB-222",
        ])
        #expect(FamilyTreeDuplicates.groups(in: g, rootIDs: ["@B@"], generations: 3).isEmpty,
                "a brother was about to be hidden from his own family")
    }

    /// Two people who merely share a name are never grouped: a coincidence
    /// is not evidence.
    @Test func aBareNameMatchIsNeverEnough() throws {
        let g = try graph([
            "0 @F1@ FAM", "1 HUSB @A@", "1 CHIL @K@",
            "0 @A@ INDI", "1 NAME Mary /Smith/", "1 SEX F", "1 FAMS @F1@", "1 _FSFTID AAAA-111",
            "0 @K@ INDI", "1 NAME Kid /Smith/", "1 SEX M", "1 FAMC @F1@", "1 _FSFTID KKKK-999",
            "0 @B@ INDI", "1 NAME Mary /Smith/", "1 SEX F", "1 _FSFTID BBBB-222",
        ])
        // @B@ is not even connected, but assert the rule directly too.
        #expect(FamilyTreeDuplicates.corroboration(
            between: try #require(g.people["@A@"]),
            and: try #require(g.people["@B@"])).isEmpty)
    }

    /// Records that disagree about sex are not one person, whatever else
    /// lines up.
    @Test func aRecordedSexDisagreementVetoesTheMatch() throws {
        let g = try graph([
            "0 @F1@ FAM", "1 CHIL @A@", "1 CHIL @B@",
            "0 @A@ INDI", "1 NAME Frances /Latta/", "1 SEX F", "1 BIRT", "2 DATE 1910",
            "1 FAMC @F1@", "1 _FSFTID AAAA-111",
            "0 @B@ INDI", "1 NAME Frances /Latta/", "1 SEX M", "1 BIRT", "2 DATE 1910",
            "1 FAMC @F1@", "1 _FSFTID BBBB-222",
        ])
        #expect(FamilyTreeDuplicates.corroboration(
            between: try #require(g.people["@A@"]),
            and: try #require(g.people["@B@"])).isEmpty)
    }

    /// Distance is the whole point of the feature: Rick can judge his
    /// grandmother, not a 17th-century namesake.
    @Test func recordsBeyondTheGenerationReachAreLeftAlone() throws {
        let g = try graph([
            "0 @F6@ FAM", "1 CHIL @I5@", "1 CHIL @I7@",
            "0 @I7@ INDI", "1 NAME Mary /O'Connor/", "1 SEX F", "1 BIRT", "2 DATE 1904",
            "1 FAMC @F6@", "1 _FSFTID G89Q-34N",
            "0 @I5@ INDI", "1 NAME Mary /O'Connor/", "1 SEX F", "1 BIRT", "2 DATE 1905",
            "1 FAMC @F6@", "1 _FSFTID GNZ5-428",
            "0 @FAR@ INDI", "1 NAME Distant /Person/", "1 SEX M", "1 _FSFTID ZZZZ-999",
        ])
        #expect(FamilyTreeDuplicates.groups(in: g, rootIDs: ["@FAR@"], generations: 4).isEmpty,
                "an unreachable pair was judged anyway")
        #expect(FamilyTreeDuplicates.groups(in: g, rootIDs: ["@I7@"], generations: 2).count == 1)
    }

    /// A record with no FamilySearch ID cannot carry a decision across a
    /// re-pull, so it is never offered as one.
    @Test func recordsWithoutAFamilySearchIDAreNotOffered() throws {
        let g = try graph([
            "0 @F6@ FAM", "1 CHIL @A@", "1 CHIL @B@",
            "0 @A@ INDI", "1 NAME Mary /O'Connor/", "1 SEX F", "1 BIRT", "2 DATE 1904", "1 FAMC @F6@",
            "0 @B@ INDI", "1 NAME Mary /O'Connor/", "1 SEX F", "1 BIRT", "2 DATE 1905", "1 FAMC @F6@",
        ])
        #expect(FamilyTreeDuplicates.groups(in: g, rootIDs: ["@A@"], generations: 3).isEmpty)
    }

    /// Three records for one person are ONE group of three, not three
    /// pairs the reader has to reconcile by hand.
    @Test func threeRecordsForOnePersonAreASingleGroup() throws {
        let g = try graph([
            "0 @F6@ FAM", "1 CHIL @A@", "1 CHIL @B@", "1 CHIL @C@",
            "0 @A@ INDI", "1 NAME Mary /O'Connor/", "1 SEX F", "1 BIRT", "2 DATE 1904",
            "1 FAMC @F6@", "1 _FSFTID AAAA-111",
            "0 @B@ INDI", "1 NAME Mary /O'Connor/", "1 SEX F", "1 BIRT", "2 DATE 1905",
            "1 FAMC @F6@", "1 _FSFTID BBBB-222",
            "0 @C@ INDI", "1 NAME Mary /O'Connor/", "1 SEX F", "1 BIRT", "2 DATE 1904",
            "1 FAMC @F6@", "1 _FSFTID CCCC-333",
        ])
        let groups = FamilyTreeDuplicates.groups(in: g, rootIDs: ["@A@"], generations: 3)
        #expect(groups.count == 1)
        #expect(groups.first?.personIDs.count == 3)
        #expect(groups.first?.id == "AAAA-111+BBBB-222+CCCC-333")
    }

    // MARK: Pieces

    @Test func theBirthYearReaderHandlesTheDateShapesTheTreeActuallyCarries() throws {
        let g = try graph([
            "0 @A@ INDI", "1 NAME A /X/", "1 BIRT", "2 DATE 23 December 1904",
            "0 @B@ INDI", "1 NAME B /X/", "1 BIRT", "2 DATE about 1905",
            "0 @C@ INDI", "1 NAME C /X/", "1 BIRT", "2 DATE before 13 January 1633",
            "0 @D@ INDI", "1 NAME D /X/",
        ])
        #expect(FamilyTreeDuplicates.birthYear(try #require(g.people["@A@"])) == 1904)
        #expect(FamilyTreeDuplicates.birthYear(try #require(g.people["@B@"])) == 1905)
        #expect(FamilyTreeDuplicates.birthYear(try #require(g.people["@C@"])) == 1633)
        #expect(FamilyTreeDuplicates.birthYear(try #require(g.people["@D@"])) == nil)
    }
}
