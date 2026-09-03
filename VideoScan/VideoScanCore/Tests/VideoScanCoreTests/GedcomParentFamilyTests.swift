// GedcomParentFamilyTests.swift
// Rick's 2026-09-02 ruling: ONE primary parent family per person, chosen
// deterministically; never two mothers or two fathers in prose. Codex
// adversarial review #1011 tightened it: folding is by IDENTITY (never
// "they are sisters"), the FAMC pedigree (PEDI) ranks first, a missing
// primary parent never hides a secondary one, and full siblings share
// the PRIMARY family.
//
// Dimensions — LOGIC: the Eileen fixture (I3 with FAMC F3 + F4, the two
// Marys both daughters of F6), the ranking table rule by rule, PEDI
// birth-vs-adopted, real sisters near in age NOT folded, name
// compatibility, a genuine second family (adoption) that is not folded,
// the single-FAMC person unchanged, the same record listed twice,
// reversed FAMC order, siblings under the ruling, the codec / writer /
// merge carrying the FAM _FSFTID and the FAMC PEDI/STAT. SCALE: 100k
// synthetic people with 5% duplicated FAMC, parents-of and siblings-of
// for everyone under a stated budget. ISOLATION: the rule reads the graph
// and nothing else — two parses agree, and removing the duplicate family
// changes nothing the prose sees.

import Foundation
import Testing
@testable import VideoScanCore

// The real shape of Eileen's records (verified against the 20-generation
// pull on 2026-09-02): names, years and places as recorded; F3 carries
// FamilySearch's family id, F4 has a wife only and no id.
private let eileenTree = """
0 HEAD
0 @I1@ INDI
1 NAME Richard Harding /Breen/ Jr
1 SEX M
1 BIRT
2 DATE 4 MAR 1959
1 FAMC @F1@
0 @I3@ INDI
1 NAME Eileen /Latta/
1 SEX F
1 BIRT
2 DATE 31 AUG 1930
2 PLAC Chelsea, Suffolk, Massachusetts, United States
1 DEAT
2 DATE 2023
1 FAMS @F1@
1 FAMC @F3@
1 FAMC @F4@
1 _FSFTID G2CR-R4H
0 @I5@ INDI
1 NAME Mary /O'Connor/
1 SEX F
1 BIRT
2 DATE 1905
2 PLAC Ireland
1 FAMS @F4@
1 FAMC @F6@
1 _FSFTID GNZ5-428
0 @I6@ INDI
1 NAME David McGill /Latta/ Sr
1 SEX M
1 BIRT
2 DATE 1902
2 PLAC Wilmington, New Hanover, North Carolina, United States
1 DEAT
2 DATE 1983
1 FAMS @F3@
1 _FSFTID LX9M-WJG
0 @I7@ INDI
1 NAME Mary Catherine /O'Connor/
1 SEX F
1 BIRT
2 DATE 23 DEC 1904
2 PLAC Ireland
1 DEAT
2 DATE 16 JUL 1985
2 PLAC Brockton, Plymouth, Massachusetts, United States
1 FAMS @F3@
1 FAMC @F6@
1 _FSFTID G89Q-34N
0 @I14@ INDI
1 NAME Christopher Dennis /O'Connor/
1 SEX M
1 BIRT
2 DATE 1883
2 PLAC Ireland
1 FAMS @F6@
0 @I15@ INDI
1 NAME Ellen /Ronan/
1 SEX F
1 BIRT
2 DATE 1883
2 PLAC Ireland
1 FAMS @F6@
0 @F1@ FAM
1 WIFE @I3@
1 CHIL @I1@
0 @F3@ FAM
1 HUSB @I6@
1 WIFE @I7@
1 CHIL @I3@
1 _FSFTID MT64-4HP
0 @F4@ FAM
1 WIFE @I5@
1 CHIL @I3@
0 @F6@ FAM
1 HUSB @I14@
1 WIFE @I15@
1 CHIL @I5@
1 CHIL @I7@
0 TRLR
"""

/// Two complete parent families, no PEDI, no ids, no facts: only GEDCOM
/// order separates them. Each family has one more child.
private let adoptionTree = """
0 HEAD
0 @I1@ INDI
1 NAME Child /River/
1 SEX M
1 FAMC @F-BIRTH@
1 FAMC @F-ADOPT@
0 @I2@ INDI
1 NAME Birth /Father/
1 SEX M
1 FAMS @F-BIRTH@
0 @I3@ INDI
1 NAME Birth /Mother/
1 SEX F
1 FAMS @F-BIRTH@
0 @I4@ INDI
1 NAME Adoptive /Father/
1 SEX M
1 FAMS @F-ADOPT@
0 @I5@ INDI
1 NAME Adoptive /Mother/
1 SEX F
1 FAMS @F-ADOPT@
0 @I6@ INDI
1 NAME Birth /Sibling/
1 SEX F
1 FAMC @F-BIRTH@
0 @I7@ INDI
1 NAME Adoptive /Sibling/
1 SEX M
1 FAMC @F-ADOPT@
0 @F-BIRTH@ FAM
1 HUSB @I2@
1 WIFE @I3@
1 CHIL @I1@
1 CHIL @I6@
0 @F-ADOPT@ FAM
1 HUSB @I4@
1 WIFE @I5@
1 CHIL @I1@
1 CHIL @I7@
0 TRLR
"""

/// The codex #1011 shape: an explicit BIRTH family with ONE parent and
/// nothing else, listed AFTER a complete adoptive family that has a
/// FamilySearch id and full facts. Completeness must not beat pedigree.
private let pedigreeTree = """
0 HEAD
0 @I1@ INDI
1 NAME Child /Stone/
1 SEX F
1 FAMC @F-ADOPT@
2 PEDI adopted
2 STAT proven
1 FAMC @F-BIRTH@
2 PEDI birth
2 STAT proven
1 _FSFTID KID1-001
0 @I2@ INDI
1 NAME Birth /Mother/
1 SEX F
1 FAMS @F-BIRTH@
1 _FSFTID BMOM-001
0 @I4@ INDI
1 NAME Adoptive /Father/
1 SEX M
1 BIRT
2 DATE 1900
2 PLAC Boston
1 DEAT
2 DATE 1980
1 FAMS @F-ADOPT@
1 _FSFTID ADAD-001
0 @I5@ INDI
1 NAME Adoptive /Mother/
1 SEX F
1 BIRT
2 DATE 1902
2 PLAC Boston
1 DEAT
2 DATE 1990
1 FAMS @F-ADOPT@
1 _FSFTID AMOM-001
0 @F-BIRTH@ FAM
1 WIFE @I2@
1 CHIL @I1@
0 @F-ADOPT@ FAM
1 HUSB @I4@
1 WIFE @I5@
1 CHIL @I1@
1 _FSFTID FAMA-001
0 TRLR
"""

/// A one-sided file: @F1@ lists two children, but only the first links
/// back with a FAMC.
private let oneSidedTree = """
0 HEAD
0 @I1@ INDI
1 NAME Linked /Child/
1 SEX M
1 FAMC @F1@
0 @I2@ INDI
1 NAME Loose /Child/
1 SEX M
0 @I3@ INDI
1 NAME Father /Child/
1 SEX M
1 FAMS @F1@
0 @I4@ INDI
1 NAME Mother /Child/
1 SEX F
1 FAMS @F1@
0 @F1@ FAM
1 HUSB @I3@
1 WIFE @I4@
1 CHIL @I1@
1 CHIL @I2@
0 TRLR
"""

/// Duplicate reciprocal FAM records: the same couple as HUSB/WIFE of
/// @F3@ and @F3B@, one child linked to each.
private let duplicateFamTree = """
0 HEAD
0 @I1@ INDI
1 NAME First /Twin/
1 SEX F
1 FAMC @F3@
0 @I2@ INDI
1 NAME Second /Twin/
1 SEX M
1 FAMC @F3B@
0 @I3@ INDI
1 NAME Father /Twin/
1 SEX M
1 FAMS @F3@
1 FAMS @F3B@
0 @I4@ INDI
1 NAME Mother /Twin/
1 SEX F
1 FAMS @F3@
1 FAMS @F3B@
0 @F3@ FAM
1 HUSB @I3@
1 WIFE @I4@
1 CHIL @I1@
0 @F3B@ FAM
1 HUSB @I3@
1 WIFE @I4@
1 CHIL @I2@
0 TRLR
"""

private typealias Rank = GedcomFamilyGraph.ParentFamilyRank
private typealias Pedigree = GedcomFamilyGraph.ParentPedigree

/// Eileen's tree with the two FAMC lines on I3 in the other order.
private let eileenTreeReversed = eileenTree.replacingOccurrences(
    of: "1 FAMC @F3@\n1 FAMC @F4@\n", with: "1 FAMC @F4@\n1 FAMC @F3@\n")

@Suite("GEDCOM — one primary parent family (Rick's 2026-09-02 ruling)")
struct GedcomParentFamilyTests {

    // MARK: - Logic: Eileen

    @Test func eileenHasOneMotherAndOneFather() throws {
        let g = GedcomFamilyGraph(gedcomText: eileenTree)
        let eileen = try #require(g.people["@I3@"])
        #expect(g.relatives(.mother, of: eileen).map(\.name) == ["Mary Catherine O'Connor"])
        #expect(g.relatives(.father, of: eileen).map(\.name) == ["David McGill Latta Sr"])
        #expect(g.relatives(.parents, of: eileen).map(\.name) == ["David McGill Latta Sr", "Mary Catherine O'Connor"])
        // The audit view still sees all three.
        #expect(g.allRecordedParents(of: eileen).map(\.id) == ["@I6@", "@I7@", "@I5@"])

        let choice = try #require(g.parentFamilyChoice(of: eileen))
        #expect(choice.primaryFamilyID == "@F3@")
        #expect(choice.ranks.map(\.familyID) == ["@F3@", "@F4@"])
        #expect(choice.ranks[0] == Rank(familyID: "@F3@", hasBothParents: true, hasFamilySearchID: true, factCount: 7, order: 0))
        #expect(choice.ranks[1] == Rank(familyID: "@F4@", hasBothParents: false, hasFamilySearchID: false, factCount: 2, order: 1))
        #expect(choice.alternates.count == 1)
        #expect(choice.alternates[0].role == .mother)
        #expect(choice.alternates[0].person.id == "@I5@")
        // "Mary" is a prefix of "Mary Catherine", same surname, shared
        // FAMC @F6@ → the same woman.
        #expect(choice.alternates[0].fold == .sameParents)
        #expect(choice.unfoldedAlternates.isEmpty)
    }

    @Test func eileensBasisNoteIsTheOneShortFoldNote() throws {
        let g = GedcomFamilyGraph(gedcomText: eileenTree)
        let eileen = try #require(g.people["@I3@"])
        #expect(g.parentFamilyBasisNote(for: eileen)
                == "(another record for her mother, Mary O'Connor b. 1905, exists in the tree — same parents; treated as the same person)")
        // Her son's card is unaffected: one FAMC, no note.
        #expect(g.parentFamilyBasisNote(for: try #require(g.people["@I1@"])) == nil)
    }

    /// The compiled parent table is built from relatives(.father/.mother),
    /// so every walk follows the primary mother: a maternal line from
    /// Eileen's son reaches ONE grandmother, then Ellen Ronan.
    @Test func maternalLineDoesNotForkAtTheDuplicate() throws {
        let g = GedcomFamilyGraph(gedcomText: eileenTree)
        let rick = try #require(g.people["@I1@"])
        let line = g.ancestorLine(of: rick, line: .maternal, generations: 4)
        #expect(line.map { $0.people.map(\.name) } == [["Eileen Latta"], ["Mary Catherine O'Connor"], ["Ellen Ronan"]])
        let both = g.ancestorLine(of: rick, line: .both, generations: 2)
        #expect(both.map { $0.people.map(\.name) } == [["Eileen Latta"], ["David McGill Latta Sr", "Mary Catherine O'Connor"]])
    }

    /// `primaryMother/primaryFather` (the birthplace trail's accessor) and
    /// the kinship route read the SAME selection — there is no second
    /// FAMC-selection path.
    @Test func trailAccessorAndKinshipRouteAgree() throws {
        for text in [eileenTree, eileenTreeReversed, adoptionTree, pedigreeTree] {
            let g = GedcomFamilyGraph(gedcomText: text)
            for person in g.people.values {
                #expect(g.primaryMother(of: person)?.id == g.relatives(.mother, of: person).first?.id)
                #expect(g.primaryFather(of: person)?.id == g.relatives(.father, of: person).first?.id)
                #expect(g.primaryParentFamilyID(of: person) == g.parentFamilyChoice(of: person)?.primaryFamilyID)
            }
        }
    }

    // MARK: - Logic: reversed FAMC order

    @Test func reversedFAMCOrderPicksTheSamePrimaryForEileen() throws {
        let g = GedcomFamilyGraph(gedcomText: eileenTreeReversed)
        let eileen = try #require(g.people["@I3@"])
        #expect(eileen.childOfFamilies == ["@F4@", "@F3@"])
        let choice = try #require(g.parentFamilyChoice(of: eileen))
        #expect(choice.primaryFamilyID == "@F3@")
        #expect(choice.ranks.map(\.familyID) == ["@F3@", "@F4@"])
        #expect(g.relatives(.mother, of: eileen).map(\.id) == ["@I7@"])
        #expect(g.relatives(.father, of: eileen).map(\.id) == ["@I6@"])
        #expect(choice.alternates.map { ($0.person.id, $0.fold) }.map { "\($0.0) \($0.1?.rawValue ?? "-")" } == ["@I5@ sameParents"])
        #expect(g.parentFamilyBasisNote(for: eileen)
                == "(another record for her mother, Mary O'Connor b. 1905, exists in the tree — same parents; treated as the same person)")
    }

    @Test func reversedFAMCOrderPicksTheSamePrimaryWhenPedigreeDecides() throws {
        // pedigreeTree already lists the adoptive family FIRST; swapping
        // the two links must not move the primary.
        let swapped = pedigreeTree.replacingOccurrences(
            of: "1 FAMC @F-ADOPT@\n2 PEDI adopted\n2 STAT proven\n1 FAMC @F-BIRTH@\n2 PEDI birth\n2 STAT proven\n",
            with: "1 FAMC @F-BIRTH@\n2 PEDI birth\n2 STAT proven\n1 FAMC @F-ADOPT@\n2 PEDI adopted\n2 STAT proven\n")
        for text in [pedigreeTree, swapped] {
            let g = GedcomFamilyGraph(gedcomText: text)
            let child = try #require(g.people["@I1@"])
            #expect(g.parentFamilyChoice(of: child)?.primaryFamilyID == "@F-BIRTH@")
            #expect(g.relatives(.mother, of: child).map(\.id) == ["@I2@"])
        }
    }

    // MARK: - Logic: the ranking table, one rule at a time

    @Test("pedigree ranks first: an explicit birth family beats a complete adoptive one")
    func pedigreeOutranksEverything() {
        let adoptive = Rank(familyID: "A", hasBothParents: true, hasFamilySearchID: true, factCount: 8, order: 0, pedigree: .adopted)
        let birth = Rank(familyID: "B", hasBothParents: false, hasFamilySearchID: false, factCount: 0, order: 1, pedigree: .birth)
        let plain = Rank(familyID: "C", hasBothParents: true, hasFamilySearchID: true, factCount: 8, order: 2)
        let foster = Rank(familyID: "D", hasBothParents: true, hasFamilySearchID: true, factCount: 8, order: 3, pedigree: .foster)
        let sealing = Rank(familyID: "E", hasBothParents: true, hasFamilySearchID: true, factCount: 8, order: 4, pedigree: .sealing)
        #expect(Rank.outranks(birth, adoptive))
        #expect(!Rank.outranks(adoptive, birth))
        #expect(Rank.ranked([sealing, foster, adoptive, plain, birth]).map(\.familyID) == ["B", "C", "A", "D", "E"])
        #expect(Pedigree.birth < .unspecified && Pedigree.unspecified < .adopted
                && Pedigree.adopted < .foster && Pedigree.foster < .sealing)
        #expect(Pedigree(raw: "BIRTH") == .birth)
        #expect(Pedigree(raw: " Adopted ") == .adopted)
        #expect(Pedigree(raw: nil) == .unspecified)
        #expect(Pedigree(raw: "stepchild") == .unspecified)
    }

    @Test("both parents beats one, whatever else the other has")
    func bothParentsOutranksEverything() {
        let one = Rank(familyID: "A", hasBothParents: false, hasFamilySearchID: true, factCount: 8, order: 0)
        let both = Rank(familyID: "B", hasBothParents: true, hasFamilySearchID: false, factCount: 0, order: 1)
        #expect(Rank.outranks(both, one))
        #expect(!Rank.outranks(one, both))
        #expect(Rank.ranked([one, both]).map(\.familyID) == ["B", "A"])
    }

    @Test("a FamilySearch family id beats none when both have both parents")
    func familySearchIDOutranksFacts() {
        let facts = Rank(familyID: "A", hasBothParents: true, hasFamilySearchID: false, factCount: 8, order: 0)
        let fsid = Rank(familyID: "B", hasBothParents: true, hasFamilySearchID: true, factCount: 0, order: 1)
        #expect(Rank.ranked([facts, fsid]).map(\.familyID) == ["B", "A"])
    }

    @Test("more recorded facts beats fewer when (a) and (b) tie")
    func factCountOutranksOrder() {
        let few = Rank(familyID: "A", hasBothParents: true, hasFamilySearchID: true, factCount: 2, order: 0)
        let more = Rank(familyID: "B", hasBothParents: true, hasFamilySearchID: true, factCount: 5, order: 1)
        #expect(Rank.ranked([few, more]).map(\.familyID) == ["B", "A"])
    }

    @Test("GEDCOM order is the stable tie-break")
    func orderBreaksTies() {
        let first = Rank(familyID: "A", hasBothParents: true, hasFamilySearchID: true, factCount: 3, order: 0)
        let second = Rank(familyID: "B", hasBothParents: true, hasFamilySearchID: true, factCount: 3, order: 1)
        #expect(Rank.ranked([second, first]).map(\.familyID) == ["A", "B"])
        #expect(!Rank.outranks(first, first))
    }

    // MARK: - Logic: PEDI / STAT through parser, ranking and basis

    @Test func explicitBirthFamilyWithOneParentOutranksACompleteAdoptiveFamily() throws {
        let g = GedcomFamilyGraph(gedcomText: pedigreeTree)
        #expect(g.droppedLineCount == 0, "PEDI and STAT are retained, not counted lost")
        let child = try #require(g.people["@I1@"])
        #expect(child.parentLinks["@F-ADOPT@"] == .init(pedigree: "adopted", status: "proven"))
        #expect(child.parentLinks["@F-BIRTH@"] == .init(pedigree: "birth", status: "proven"))
        #expect(g.pedigree(of: child, in: "@F-BIRTH@") == .birth)
        #expect(g.linkStatus(of: child, in: "@F-BIRTH@") == .proven)
        #expect(g.pedigree(of: child, in: "@F-ADOPT@") == .adopted)
        #expect(g.pedigree(of: child, in: "@F-NONE@") == .unspecified)

        let choice = try #require(g.parentFamilyChoice(of: child))
        #expect(choice.primaryFamilyID == "@F-BIRTH@")
        #expect(choice.primaryPedigree == .birth)
        #expect(choice.ranks[0] == Rank(familyID: "@F-BIRTH@", hasBothParents: false, hasFamilySearchID: false, factCount: 0, order: 1, pedigree: .birth, status: .proven))
        #expect(choice.ranks[1] == Rank(familyID: "@F-ADOPT@", hasBothParents: true, hasFamilySearchID: true, factCount: 6, order: 0, pedigree: .adopted, status: .proven))
        #expect(g.relatives(.mother, of: child).map(\.id) == ["@I2@"])
        #expect(g.relatives(.father, of: child).isEmpty, "the birth family records no father; the adoptive one is not borrowed")
        #expect(choice.alternates.map { "\($0.role.rawValue) \($0.person.id) \($0.pedigree)" } == ["father @I4@ adopted", "mother @I5@ adopted"])
        #expect(choice.foldedAlternates.isEmpty)
        #expect(g.parentFamilyBasisNote(for: child)
                == "Also recorded: adoptive parents (father Adoptive Father, ADAD-001; mother Adoptive Mother, AMOM-001); ask about them by name.")
    }

    @Test func fosterAndSealingWordingAndSingularParent() throws {
        let foster = pedigreeTree
            .replacingOccurrences(of: "2 PEDI adopted", with: "2 PEDI foster")
            .replacingOccurrences(of: "1 HUSB @I4@\n", with: "")
        let g = GedcomFamilyGraph(gedcomText: foster)
        let child = try #require(g.people["@I1@"])
        #expect(g.parentFamilyBasisNote(for: child)
                == "Also recorded: foster parent (mother Adoptive Mother, AMOM-001); ask about them by name.")
        let sealing = GedcomFamilyGraph(gedcomText: pedigreeTree.replacingOccurrences(of: "2 PEDI adopted", with: "2 PEDI sealing"))
        #expect(sealing.parentFamilyBasisNote(for: try #require(sealing.people["@I1@"]))
                == "Also recorded: parents by sealing (father Adoptive Father, ADAD-001; mother Adoptive Mother, AMOM-001); ask about them by name.")
    }

    @Test func pediAndStatRoundTripTheCodecTheWriterAndAReparse() throws {
        let g = GedcomFamilyGraph(gedcomText: pedigreeTree)
        let decoded = try GedcomCompiledTree.decode(GedcomCompiledTree.encode(g))
        let child = try #require(decoded.people["@I1@"])
        #expect(child.parentLinks == g.people["@I1@"]?.parentLinks)
        #expect(decoded.parentFamilyChoice(of: child)?.primaryFamilyID == "@F-BIRTH@")
        #expect(GedcomCompiledTree.verify(decoded: decoded, against: g) == [])
        // A poisoned decode is caught by verify: the link is the first
        // difference it names.
        var poisoned = decoded.people["@I1@"]!
        poisoned.parentLinks["@F-BIRTH@"] = nil
        #expect(GedcomCompiledTree.firstDifference(child, poisoned) == "parentLinks")

        let written = g.gedcomText()
        #expect(written.contains("1 FAMC @F-ADOPT@\n2 PEDI adopted\n2 STAT proven\n1 FAMC @F-BIRTH@\n2 PEDI birth\n2 STAT proven\n"), Comment(rawValue: written))
        let reparsed = GedcomFamilyGraph(gedcomText: written)
        #expect(reparsed.people["@I1@"]?.parentLinks == g.people["@I1@"]?.parentLinks)
        #expect(reparsed.parentFamilyChoice(of: try #require(reparsed.people["@I1@"]))?.primaryFamilyID == "@F-BIRTH@")
        // The codec version moved (6 → 7): an old artifact is refused and
        // the store recompiles rather than reading a wrong layout.
        #expect(GedcomCompiledTree.codecVersion == 7)
    }

    @Test func mergeCarriesPediAndFillsStatFromTheSecondSource() throws {
        // Both pulls carry the couple's FSIDs, so the family matches; the
        // first has the pedigree, the second only the status.
        let first = pedigreeTree.replacingOccurrences(of: "2 PEDI adopted\n2 STAT proven\n", with: "2 PEDI adopted\n")
        let second = pedigreeTree
            .replacingOccurrences(of: "2 PEDI adopted\n2 STAT proven\n", with: "2 STAT proven\n")
            .replacingOccurrences(of: "@I1@", with: "@X1@").replacingOccurrences(of: "@I2@", with: "@X2@")
            .replacingOccurrences(of: "@I4@", with: "@X4@").replacingOccurrences(of: "@I5@", with: "@X5@")
            .replacingOccurrences(of: "@F-ADOPT@", with: "@FX-ADOPT@").replacingOccurrences(of: "@F-BIRTH@", with: "@FX-BIRTH@")
        let a = GedcomFamilyGraph(gedcomText: first), b = GedcomFamilyGraph(gedcomText: second)
        let outcome = a.merge(with: b)
        let child = try #require(outcome.graph.people["@I1@"])
        #expect(outcome.sharedPeopleCount == 4)
        #expect(child.parentLinks["@F-ADOPT@"] == .init(pedigree: "adopted", status: "proven"), Comment(rawValue: "\(child.parentLinks)"))
        #expect(child.parentLinks["@F-BIRTH@"] == .init(pedigree: "birth", status: "proven"))
        #expect(outcome.graph.parentFamilyChoice(of: child)?.primaryFamilyID == "@F-BIRTH@")
        // A second-file-only person keeps its links under the new pointers.
        let onlyB = GedcomFamilyGraph(gedcomText: pedigreeTree.replacingOccurrences(of: "1 _FSFTID KID1-001\n", with: ""))
        let merged = GedcomFamilyGraph(gedcomText: "0 HEAD\n0 TRLR\n").merge(with: onlyB)
        let added = try #require(merged.graph.people.values.first { $0.name == "Child Stone" })
        #expect(added.parentLinks.count == 2)
        #expect(added.childOfFamilies.allSatisfy { added.parentLinks[$0] != nil })
        #expect(merged.graph.parentFamilyChoice(of: added)?.primaryPedigree == .birth)
    }

    // MARK: - Logic: a genuine second family is not folded

    @Test func adoptionListsTheBirthParentsAndNotesTheSecondFamily() throws {
        let g = GedcomFamilyGraph(gedcomText: adoptionTree)
        let child = try #require(g.people["@I1@"])
        #expect(g.relatives(.father, of: child).map(\.id) == ["@I2@"])
        #expect(g.relatives(.mother, of: child).map(\.id) == ["@I3@"])
        let choice = try #require(g.parentFamilyChoice(of: child))
        #expect(choice.primaryFamilyID == "@F-BIRTH@")
        #expect(choice.alternates.map { ($0.role, $0.person.id, $0.fold) }.map { "\($0.0.rawValue) \($0.1) \($0.2.map(\.rawValue) ?? "-")" }
                == ["father @I4@ -", "mother @I5@ -"])
        #expect(choice.foldedAlternates.isEmpty)
        #expect(g.parentFamilyBasisNote(for: child)
                == "A second parent family is recorded (father Adoptive Father, @I4@; mother Adoptive Mother, @I5@); ask about it by name.")
    }

    // MARK: - Logic: fold on identity only

    /// codex #1011: two sisters — Mary b. 1904 and Bridget b. 1905, both
    /// daughters of @F6@, same surname, a year apart — must stay two
    /// people. The old rule folded them twice over.
    @Test func realSistersNearInAgeAreNotFolded() throws {
        let text = eileenTree.replacingOccurrences(of: "1 NAME Mary /O'Connor/", with: "1 NAME Bridget /O'Connor/")
        let g = GedcomFamilyGraph(gedcomText: text)
        let eileen = try #require(g.people["@I3@"])
        let choice = try #require(g.parentFamilyChoice(of: eileen))
        #expect(choice.primaryFamilyID == "@F3@")
        #expect(choice.alternates.map(\.fold) == [nil])
        #expect(g.relatives(.mother, of: eileen).map(\.id) == ["@I7@"])
        #expect(g.parentFamilyBasisNote(for: eileen)
                == "A second parent family is recorded (mother Bridget O'Connor, GNZ5-428); ask about it by name.")
        // Nor with reversed FAMC order.
        let reversed = GedcomFamilyGraph(gedcomText: text.replacingOccurrences(of: "1 FAMC @F3@\n1 FAMC @F4@\n", with: "1 FAMC @F4@\n1 FAMC @F3@\n"))
        #expect(reversed.parentFamilyChoice(of: try #require(reversed.people["@I3@"]))?.alternates.map(\.fold) == [nil])
        #expect(reversed.relatives(.mother, of: try #require(reversed.people["@I3@"])).map(\.id) == ["@I7@"])
    }

    @Test func sameNameWithinTwoYearsFoldsWithoutSharedParents() throws {
        // Mary b. 1905 no longer a daughter of F6 — the name + birth-year
        // corroboration has to carry the fold on its own.
        let text = eileenTree.replacingOccurrences(of: "1 FAMS @F4@\n1 FAMC @F6@\n", with: "1 FAMS @F4@\n")
        let g = GedcomFamilyGraph(gedcomText: text)
        let eileen = try #require(g.people["@I3@"])
        let choice = try #require(g.parentFamilyChoice(of: eileen))
        #expect(choice.alternates.map(\.fold) == [.sameNameCloseBirth])
        #expect(g.parentFamilyBasisNote(for: eileen)
                == "(another record for her mother, Mary O'Connor b. 1905, exists in the tree — same name, born within two years; treated as the same person)")
        #expect(g.relatives(.mother, of: eileen).map(\.id) == ["@I7@"])
    }

    @Test func farApartBirthYearsDoNotFold() throws {
        let text = eileenTree
            .replacingOccurrences(of: "1 FAMS @F4@\n1 FAMC @F6@\n", with: "1 FAMS @F4@\n")
            .replacingOccurrences(of: "2 DATE 1905\n2 PLAC Ireland\n1 FAMS @F4@", with: "2 DATE 1925\n2 PLAC Ireland\n1 FAMS @F4@")
        let g = GedcomFamilyGraph(gedcomText: text)
        let eileen = try #require(g.people["@I3@"])
        let choice = try #require(g.parentFamilyChoice(of: eileen))
        #expect(choice.alternates.map(\.fold) == [nil])
        #expect(g.parentFamilyBasisNote(for: eileen)
                == "A second parent family is recorded (mother Mary O'Connor, GNZ5-428); ask about it by name.")
        // Prose still lists one mother.
        #expect(g.relatives(.mother, of: eileen).map(\.id) == ["@I7@"])
    }

    @Test func sameFamilySearchIDFoldsWhateverTheName() throws {
        // The duplicate carries Mary Catherine's own FSID under a different
        // spelling: identity by id, no name test needed.
        let text = eileenTree
            .replacingOccurrences(of: "1 NAME Mary /O'Connor/", with: "1 NAME Molly /Connor/")
            .replacingOccurrences(of: "1 _FSFTID GNZ5-428", with: "1 _FSFTID G89Q-34N")
        let g = GedcomFamilyGraph(gedcomText: text)
        let eileen = try #require(g.people["@I3@"])
        #expect(g.parentFamilyChoice(of: eileen)?.alternates.map(\.fold) == [.sameFamilySearchID])
        #expect(g.parentFamilyBasisNote(for: eileen)
                == "(another record for her mother, Molly Connor b. 1905, exists in the tree — same FamilySearch record; treated as the same person)")
    }

    @Test func sameSpouseCorroboratesACompatibleName() throws {
        // Mary b. 1905: no shared FAMC, born 1925 (far apart), but married
        // to David Latta as well (F4 gains HUSB @I6@).
        let text = eileenTree
            .replacingOccurrences(of: "1 FAMS @F4@\n1 FAMC @F6@\n", with: "1 FAMS @F4@\n")
            .replacingOccurrences(of: "2 DATE 1905\n2 PLAC Ireland\n1 FAMS @F4@", with: "2 DATE 1925\n2 PLAC Ireland\n1 FAMS @F4@")
            .replacingOccurrences(of: "1 FAMS @F3@\n1 _FSFTID LX9M-WJG", with: "1 FAMS @F3@\n1 FAMS @F4@\n1 _FSFTID LX9M-WJG")
            .replacingOccurrences(of: "0 @F4@ FAM\n1 WIFE @I5@", with: "0 @F4@ FAM\n1 HUSB @I6@\n1 WIFE @I5@")
        let g = GedcomFamilyGraph(gedcomText: text)
        let eileen = try #require(g.people["@I3@"])
        let choice = try #require(g.parentFamilyChoice(of: eileen))
        #expect(choice.primaryFamilyID == "@F3@", "the FamilySearch id and the facts still pick F3")
        #expect(choice.alternates.map(\.fold) == [.sameSpouse])
        #expect(g.parentFamilyBasisNote(for: eileen)
                == "(another record for her mother, Mary O'Connor b. 1925, exists in the tree — same spouse; treated as the same person)")
    }

    @Test func nameCompatibilityTable() {
        func person(_ name: String, _ surname: String?) -> GedcomFamilyGraph.Person {
            var p = GedcomFamilyGraph.Person(id: "@\(name)@", name: name, sex: "F", childOfFamily: nil)
            p.surname = surname
            return p
        }
        typealias G = GedcomFamilyGraph
        #expect(G.namesCompatible(person("Mary O'Connor", "O'Connor"), person("Mary Catherine O'Connor", "O'Connor")))
        #expect(G.namesCompatible(person("Mary Catherine O'Connor", "O'Connor"), person("Mary O'Connor", "O'Connor")))
        #expect(G.namesCompatible(person("M O'Connor", "O'Connor"), person("Mary O'Connor", "O'Connor")), "an initial")
        #expect(G.namesCompatible(person("Mary C. O'Connor", "O'Connor"), person("Mary Catherine O'Connor", "O'Connor")))
        #expect(G.namesCompatible(person("mary o'connor", "o'connor"), person("MARY O'CONNOR", "O'Connor")), "case")
        #expect(G.namesCompatible(person("David McGill Latta Sr", "Latta"), person("David Latta", "Latta")), "suffix after the surname is ignored")
        #expect(!G.namesCompatible(person("Mary O'Connor", "O'Connor"), person("Bridget O'Connor", "O'Connor")), "sisters")
        #expect(!G.namesCompatible(person("Mary Catherine O'Connor", "O'Connor"), person("Mary Ellen O'Connor", "O'Connor")), "second given name differs")
        #expect(!G.namesCompatible(person("Mary O'Connor", "O'Connor"), person("Mary Connor", "Connor")), "surname differs")
        #expect(!G.namesCompatible(person("O'Connor", "O'Connor"), person("Mary O'Connor", "O'Connor")), "no given name recorded")
        #expect(!G.namesCompatible(person("Mary O'Connor", nil), person("Mary O'Connor", "O'Connor")), "no surname recorded")
        #expect(G.givenNameTokens(person("David McGill Latta Sr", "Latta")) == ["david", "mcgill"])
        #expect(G.givenNameTokens(person("Mary Catherine O'Connor", "O'Connor")) == ["mary", "catherine"])
    }

    @Test func aMissingBirthYearNeverFoldsByName() throws {
        // Two Marys in the same tree with no shared FAMC and no spouse:
        // only the birth years can corroborate.
        func graph(candidateBirth: String?) -> GedcomFamilyGraph {
            var text = eileenTree.replacingOccurrences(of: "1 FAMS @F4@\n1 FAMC @F6@\n", with: "1 FAMS @F4@\n")
            text = text.replacingOccurrences(of: "1 BIRT\n2 DATE 1905\n2 PLAC Ireland\n",
                                             with: candidateBirth.map { "1 BIRT\n2 DATE \($0)\n" } ?? "")
            return GedcomFamilyGraph(gedcomText: text)
        }
        func fold(_ g: GedcomFamilyGraph) -> GedcomFamilyGraph.ParentFold? {
            g.parentFamilyChoice(of: g.people["@I3@"]!)?.alternates.first?.fold
        }
        #expect(fold(graph(candidateBirth: nil)) == nil)
        #expect(fold(graph(candidateBirth: "1906")) == .sameNameCloseBirth)
        #expect(fold(graph(candidateBirth: "1907")) == nil)
    }

    // MARK: - Logic: siblings share the primary family

    @Test func fullSiblingsSharePrimaryFamilyAndAlternatesGoToTheBasis() throws {
        let g = GedcomFamilyGraph(gedcomText: adoptionTree)
        let child = try #require(g.people["@I1@"])
        let birthSibling = try #require(g.people["@I6@"]), adoptiveSibling = try #require(g.people["@I7@"])
        #expect(g.relatives(.siblings, of: child).map(\.id) == ["@I6@"])
        #expect(g.relatives(.sister, of: child).map(\.id) == ["@I6@"])
        #expect(g.relatives(.brother, of: child).isEmpty)
        #expect(g.alternateFamilySiblings(of: child).map(\.id) == ["@I7@"])
        #expect(g.alternateSiblingBasisNote(for: child) == "Also recorded as a sibling through a second family record: Adoptive Sibling, @I7@.")
        #expect(g.alternateSiblingBasisNote(for: child, sex: "F") == nil)
        #expect(g.alternateSiblingBasisNote(for: child, sex: "M") == "Also recorded as a sibling through a second family record: Adoptive Sibling, @I7@.")
        // Symmetric: the birth sibling lists the child; the adoptive
        // sibling has the child only through the second record.
        #expect(g.relatives(.siblings, of: birthSibling).map(\.id) == ["@I1@"])
        #expect(g.alternateFamilySiblings(of: birthSibling).isEmpty)
        #expect(g.relatives(.siblings, of: adoptiveSibling).isEmpty)
        #expect(g.alternateFamilySiblings(of: adoptiveSibling).map(\.id) == ["@I1@"])
        #expect(g.alternateSiblingBasisNote(for: adoptiveSibling) == "Also recorded as a sibling through a second family record: Child River, @I1@.")
        // The family-tree summary the biography reads agrees with the kinship route.
        #expect(ArchivistFamilyTreePolicy.summary(of: child, in: g).siblings.map(\.id) == g.relatives(.siblings, of: child).map(\.id))

        // directRelation: full, then alternate — never full for the adoptive sibling.
        #expect(g.directRelation(between: "@I1@", and: "@I6@")?.kind == .siblings)
        #expect(g.directRelation(between: "@I1@", and: "@I6@")?.term == "Birth Sibling is Child River’s sister")
        let alt = try #require(g.directRelation(between: "@I1@", and: "@I7@"))
        #expect(alt.kind == .alternateFamilySiblings)
        #expect(alt.term == "Adoptive Sibling is recorded as Child River’s brother through a second family record")
        #expect(alt.path.map(\.id) == ["@I1@", "@I7@"])
        #expect(g.directRelation(between: "@I7@", and: "@I1@")?.kind == .alternateFamilySiblings)
        // Eileen: one FAMC each on her son; nothing changes for the ordinary person.
        let e = GedcomFamilyGraph(gedcomText: eileenTree)
        #expect(e.alternateFamilySiblings(of: try #require(e.people["@I3@"])).isEmpty)
        #expect(e.alternateSiblingBasisNote(for: try #require(e.people["@I3@"])) == nil)
        #expect(e.relatives(.siblings, of: try #require(e.people["@I7@"])).map(\.id) == ["@I5@"], "the two Marys are full siblings of each other")
    }

    /// Sibling consistency sensor: for every person in every fixture,
    /// full siblings are symmetric, alternates are symmetric, the sets
    /// never overlap, and the THREE SURFACES agree — relatives(.siblings),
    /// the family-tree summary the biography reads, and directRelation —
    /// on every candidate pair, from both sides.
    @Test func siblingSetsAreSymmetricAndTheThreeSurfacesAgree() {
        for text in [eileenTree, eileenTreeReversed, adoptionTree, pedigreeTree, oneSidedTree, duplicateFamTree,
                     GedcomSyntheticPedigree.gedcom(people: 2_000)] {
            let g = GedcomFamilyGraph(gedcomText: text)
            for person in g.people.values {
                let full = g.relatives(.siblings, of: person), alt = g.alternateFamilySiblings(of: person)
                let oneSided = g.oneSidedSiblings(of: person)
                let fullIDs = Set(full.map(\.id))
                #expect(fullIDs.isDisjoint(with: Set(alt.map(\.id))))
                #expect(fullIDs.isDisjoint(with: Set(oneSided.map(\.id))))
                for s in full { #expect(g.relatives(.siblings, of: s).contains { $0.id == person.id }, "\(s.name) ↔ \(person.name)") }
                for s in alt { #expect(g.alternateFamilySiblings(of: s).contains { $0.id == person.id }, "\(s.name) ↔ \(person.name)") }
                #expect(ArchivistFamilyTreePolicy.summary(of: person, in: g).siblings.map(\.id).sorted() == full.map(\.id).sorted())
                for other in g.siblingCandidates(of: person) + full + alt + oneSided {
                    let verdict = g.siblingVerdict(person, other)
                    #expect(verdict == g.siblingVerdict(other, person), "\(person.name) ↔ \(other.name)")
                    let direct = g.directRelation(between: person.id, and: other.id)?.kind
                    // directRelation names spouses / parent-child / ancestors
                    // BEFORE the sibling verdict by design (the synthetic
                    // pedigree marries a few siblings); only the sibling
                    // kinds are compared.
                    if [.spouses, .parentChild, .ancestorDescendant].contains(direct) { continue }
                    #expect((direct == .siblings) == fullIDs.contains(other.id), "\(person.name) ↔ \(other.name): \(String(describing: direct))")
                    #expect((direct == .oneSidedSiblings) == oneSided.contains { $0.id == other.id }, "\(person.name) ↔ \(other.name)")
                    #expect((direct == .alternateFamilySiblings) == alt.contains { $0.id == other.id }, "\(person.name) ↔ \(other.name)")
                }
            }
        }
    }

    /// A CHIL line with no FAMC back-link (a one-sided file): not a full
    /// sibling on any surface, from either side; qualified in the basis
    /// from the side that carries the link.
    @Test func oneSidedChilIsQualifiedNotAFullSibling() throws {
        let g = GedcomFamilyGraph(gedcomText: oneSidedTree)
        let linked = try #require(g.people["@I1@"]), loose = try #require(g.people["@I2@"])
        #expect(g.relatives(.siblings, of: linked).isEmpty)
        #expect(g.relatives(.siblings, of: loose).isEmpty)
        #expect(g.oneSidedSiblings(of: linked).map(\.id) == ["@I2@"])
        #expect(g.oneSidedSiblings(of: loose).isEmpty, "the loose record carries nothing to see")
        #expect(g.siblingVerdict(linked, loose) == .oneSided(familyID: "@F1@"))
        #expect(g.siblingVerdict(loose, linked) == .oneSided(familyID: "@F1@"))
        #expect(g.directRelation(between: "@I1@", and: "@I2@")?.kind == .oneSidedSiblings)
        #expect(g.directRelation(between: "@I1@", and: "@I2@")?.term == "Loose Child is recorded as Linked Child’s brother on one side only")
        #expect(g.directRelation(between: "@I2@", and: "@I1@")?.kind == .oneSidedSiblings)
        #expect(ArchivistFamilyTreePolicy.summary(of: linked, in: g).siblings.isEmpty)
        #expect(g.alternateSiblingBasisNote(for: linked)
                == "Recorded as a sibling on one side only (no link back from that record): Loose Child, @I2@.")
        #expect(g.alternateSiblingBasisNote(for: loose) == nil)
    }

    /// Duplicate reciprocal FAM records — the same two parents as HUSB and
    /// WIFE of @F3@ and @F3B@, one child in each: full siblings on every
    /// surface, from both sides, not two families.
    @Test func duplicateReciprocalFamsAreFullSiblingsOnEverySurface() throws {
        let g = GedcomFamilyGraph(gedcomText: duplicateFamTree)
        let a = try #require(g.people["@I1@"]), b = try #require(g.people["@I2@"])
        #expect(g.primaryParentFamilyID(of: a) == "@F3@")
        #expect(g.primaryParentFamilyID(of: b) == "@F3B@")
        #expect(g.relatives(.siblings, of: a).map(\.id) == ["@I2@"])
        #expect(g.relatives(.siblings, of: b).map(\.id) == ["@I1@"])
        #expect(g.siblingVerdict(a, b) == .full)
        #expect(g.directRelation(between: "@I1@", and: "@I2@")?.kind == .siblings)
        #expect(g.directRelation(between: "@I2@", and: "@I1@")?.kind == .siblings)
        #expect(ArchivistFamilyTreePolicy.summary(of: a, in: g).siblings.map(\.id) == ["@I2@"])
        #expect(g.alternateFamilySiblings(of: a).isEmpty && g.oneSidedSiblings(of: a).isEmpty)
        #expect(g.alternateSiblingBasisNote(for: a) == nil)
        // Father-only duplicates share ONE primary parent: half, on every surface.
        let half = GedcomFamilyGraph(gedcomText: duplicateFamTree.replacingOccurrences(of: "1 WIFE @I4@\n", with: ""))
        let ha = try #require(half.people["@I1@"]), hb = try #require(half.people["@I2@"])
        #expect(half.siblingVerdict(ha, hb) == .half(through: "@I3@"))
        #expect(half.relatives(.siblings, of: ha).isEmpty)
        #expect(half.directRelation(between: "@I1@", and: "@I2@")?.kind == .halfSiblings)
    }

    // MARK: - Logic: STAT ranks first (fail closed) and merges deterministically

    @Test("status ranks before pedigree: birth + disproven loses to adopted + proven")
    func statusOutranksPedigree() {
        typealias Status = GedcomFamilyGraph.ParentLinkStatus
        let disprovenBirth = Rank(familyID: "A", hasBothParents: true, hasFamilySearchID: true, factCount: 8, order: 0, pedigree: .birth, status: .disproven)
        let provenAdopted = Rank(familyID: "B", hasBothParents: false, hasFamilySearchID: false, factCount: 0, order: 1, pedigree: .adopted, status: .proven)
        let plain = Rank(familyID: "C", hasBothParents: false, hasFamilySearchID: false, factCount: 0, order: 2)
        let challenged = Rank(familyID: "D", hasBothParents: true, hasFamilySearchID: true, factCount: 8, order: 3, pedigree: .birth, status: .challenged)
        #expect(Rank.outranks(provenAdopted, disprovenBirth))
        #expect(!Rank.outranks(disprovenBirth, provenAdopted))
        #expect(Rank.ranked([disprovenBirth, challenged, plain, provenAdopted]).map(\.familyID) == ["B", "C", "D", "A"])
        #expect(Status.proven < .unspecified && Status.unspecified < .challenged && Status.challenged < .disproven)
        #expect(Status(raw: "PROVEN") == .proven)
        #expect(Status(raw: " disproven ") == .disproven)
        #expect(Status(raw: nil) == .unspecified)
        #expect(Status(raw: "submitted") == .unspecified)
    }

    @Test func disprovenBirthLinkLosesToProvenAdoptiveFamilyAndIsQualified() throws {
        let text = pedigreeTree.replacingOccurrences(of: "1 FAMC @F-BIRTH@\n2 PEDI birth\n2 STAT proven\n", with: "1 FAMC @F-BIRTH@\n2 PEDI birth\n2 STAT disproven\n")
        for variant in [text, text.replacingOccurrences(
            of: "1 FAMC @F-ADOPT@\n2 PEDI adopted\n2 STAT proven\n1 FAMC @F-BIRTH@\n2 PEDI birth\n2 STAT disproven\n",
            with: "1 FAMC @F-BIRTH@\n2 PEDI birth\n2 STAT disproven\n1 FAMC @F-ADOPT@\n2 PEDI adopted\n2 STAT proven\n")] {
            let g = GedcomFamilyGraph(gedcomText: variant)
            let child = try #require(g.people["@I1@"])
            let choice = try #require(g.parentFamilyChoice(of: child))
            #expect(choice.primaryFamilyID == "@F-ADOPT@")
            #expect(choice.primaryStatus == .proven)
            #expect(choice.ranks.map(\.status) == [.proven, .disproven])
            #expect(g.relatives(.mother, of: child).map(\.id) == ["@I5@"])
            #expect(g.relatives(.father, of: child).map(\.id) == ["@I4@"])
            #expect(g.parentFamilyBasisNote(for: child)
                    == "A second parent family is recorded (mother Birth Mother, BMOM-001 — link disproven); ask about it by name.")
        }
        // Challenged alone (no PEDI anywhere): the unlabelled family wins.
        let challenged = GedcomFamilyGraph(gedcomText: adoptionTree.replacingOccurrences(of: "1 FAMC @F-BIRTH@\n", with: "1 FAMC @F-BIRTH@\n2 STAT challenged\n"))
        #expect(challenged.parentFamilyChoice(of: try #require(challenged.people["@I1@"]))?.primaryFamilyID == "@F-ADOPT@")
        #expect(challenged.parentFamilyBasisNote(for: try #require(challenged.people["@I1@"]))
                == "A second parent family is recorded (father Birth Father, @I2@; mother Birth Mother, @I3@ — link challenged); ask about it by name.")
    }

    /// Two sources disagree on the same FAMC's PEDI and STAT: the result
    /// is the same whichever source comes first (fail closed: disproven
    /// over proven, adopted over birth), the disagreement is written on
    /// the link, reported, round-trips the writer and the codec, and is
    /// said in the basis.
    @Test func conflictingLinkMetadataMergesDeterministicallyAndIsReported() throws {
        let first = pedigreeTree.replacingOccurrences(of: "2 PEDI adopted\n2 STAT proven\n", with: "2 PEDI birth\n2 STAT proven\n")
        let second = pedigreeTree
            .replacingOccurrences(of: "2 PEDI adopted\n2 STAT proven\n", with: "2 PEDI adopted\n2 STAT disproven\n")
            .replacingOccurrences(of: "@I1@", with: "@X1@").replacingOccurrences(of: "@I2@", with: "@X2@")
            .replacingOccurrences(of: "@I4@", with: "@X4@").replacingOccurrences(of: "@I5@", with: "@X5@")
            .replacingOccurrences(of: "@F-ADOPT@", with: "@FX-ADOPT@").replacingOccurrences(of: "@F-BIRTH@", with: "@FX-BIRTH@")
        let a = GedcomFamilyGraph(gedcomText: first), b = GedcomFamilyGraph(gedcomText: second)
        let ab = a.merge(with: b), ba = b.merge(with: a)
        let conflict = "PEDI birth vs adopted (kept adopted); STAT proven vs disproven (kept disproven)"
        for (outcome, pointer, adoptFamily) in [(ab, "@I1@", "@F-ADOPT@"), (ba, "@X1@", "@FX-ADOPT@")] {
            let child = try #require(outcome.graph.people[pointer])
            #expect(child.parentLinks[adoptFamily] == .init(pedigree: "adopted", status: "disproven", conflict: conflict),
                    Comment(rawValue: "\(child.parentLinks)"))
            // Both sources agree the birth family is "birth": no conflict there.
            #expect(child.parentLinks.values.filter { $0.conflict != nil }.count == 1)
            // The disproven adoptive link loses to the birth family either way.
            #expect(outcome.graph.parentFamilyChoice(of: child)?.primaryFamilyID.hasSuffix("BIRTH@") == true)
            #expect(outcome.conflicts.contains { $0.kind == .fieldDisagreement && $0.ids == [pointer] && $0.resolution == "KID1-001 FAMC \(adoptFamily): \(conflict)" },
                    Comment(rawValue: "\(outcome.conflicts)"))
            #expect(outcome.graph.parentFamilyBasisNote(for: child)?.contains(
                "The sources disagree on the link to family FAMA-001 (\(conflict)).") == true,
                    Comment(rawValue: outcome.graph.parentFamilyBasisNote(for: child) ?? "nil"))
            // The writer keeps it, a re-read keeps it, the codec keeps it.
            let written = outcome.graph.gedcomText()
            #expect(written.contains("1 FAMC \(adoptFamily)\n2 PEDI adopted\n2 STAT disproven\n2 _VS_CONFLICT \(conflict)\n"), Comment(rawValue: written))
            let reparsed = GedcomFamilyGraph(gedcomText: written)
            #expect(reparsed.droppedLineCount == 0)
            #expect(reparsed.people[pointer]?.parentLinks == child.parentLinks)
            let decoded = try GedcomCompiledTree.decode(GedcomCompiledTree.encode(outcome.graph))
            #expect(decoded.people[pointer]?.parentLinks == child.parentLinks)
            #expect(GedcomCompiledTree.verify(decoded: decoded, against: outcome.graph) == [])
        }
        // Agreement is not a conflict; a nil side is filled.
        let same = a.merge(with: a)
        #expect(same.graph.people["@I1@"]?.parentLinks.values.allSatisfy { $0.conflict == nil } == true)
        #expect(same.conflicts.filter { $0.resolution.contains("FAMC") }.isEmpty)
    }

    // MARK: - Logic: single FAMC unchanged; the same record twice

    @Test func singleParentFamilyIsUnchanged() throws {
        let g = GedcomFamilyGraph(gedcomText: eileenTree)
        for id in ["@I1@", "@I5@", "@I7@"] {
            let person = try #require(g.people[id])
            let choice = try #require(g.parentFamilyChoice(of: person))
            #expect(choice.alternates.isEmpty)
            #expect(choice.ranks.count == 1)
            #expect(g.relatives(.parents, of: person) == g.allRecordedParents(of: person))
            #expect(g.parentFamilyBasisNote(for: person) == nil)
        }
        // No parents at all → no choice, empty relatives, no note.
        let orphan = try #require(g.people["@I14@"])
        #expect(g.parentFamilyChoice(of: orphan) == nil)
        #expect(g.relatives(.parents, of: orphan).isEmpty)
        #expect(g.parentFamilyBasisNote(for: orphan) == nil)
    }

    @Test func theSameRecordInTwoFamiliesIsNotAnAlternate() throws {
        // F4's wife is I7 herself (FamilySearch sometimes lists a child under
        // the couple and again under the mother alone).
        let text = eileenTree.replacingOccurrences(of: "0 @F4@ FAM\n1 WIFE @I5@", with: "0 @F4@ FAM\n1 WIFE @I7@")
        let g = GedcomFamilyGraph(gedcomText: text)
        let eileen = try #require(g.people["@I3@"])
        let choice = try #require(g.parentFamilyChoice(of: eileen))
        #expect(choice.alternates.isEmpty)
        #expect(g.parentFamilyBasisNote(for: eileen) == nil)
        #expect(g.relatives(.mother, of: eileen).map(\.id) == ["@I7@"])
    }

    // MARK: - Logic: the FAM _FSFTID is kept, round-trips, and is written

    @Test func familyFamilySearchIDIsKeptEncodedAndWritten() throws {
        let g = GedcomFamilyGraph(gedcomText: eileenTree)
        #expect(g.droppedLineCount == 0, "the FAM _FSFTID line is retained, not counted lost")
        let decoded = try GedcomCompiledTree.decode(GedcomCompiledTree.encode(g))
        let eileen = try #require(decoded.people["@I3@"])
        let choice = try #require(decoded.parentFamilyChoice(of: eileen))
        #expect(choice.ranks[0].hasFamilySearchID)
        #expect(!choice.ranks[1].hasFamilySearchID)
        #expect(decoded.relatives(.mother, of: eileen).map(\.id) == ["@I7@"])
        #expect(GedcomCompiledTree.verify(decoded: decoded, against: g) == [])
        // The writer emits it under the family, and it reads back.
        let written = g.gedcomText()
        #expect(written.contains("0 @F3@ FAM\n1 HUSB @I6@\n1 WIFE @I7@\n1 CHIL @I3@\n1 _FSFTID MT64-4HP\n"), Comment(rawValue: written))
        let reparsed = GedcomFamilyGraph(gedcomText: written)
        #expect(reparsed.parentFamilyChoice(of: try #require(reparsed.people["@I3@"]))?.ranks[0].hasFamilySearchID == true)
    }

    // MARK: - Isolation: the rule reads the graph only

    @Test func twoParsesAgreeAndTheDuplicateFamilyIsInvisibleToProse() throws {
        let a = GedcomFamilyGraph(gedcomText: eileenTree)
        let b = GedcomFamilyGraph(gedcomText: eileenTree)
        let eileenA = try #require(a.people["@I3@"]), eileenB = try #require(b.people["@I3@"])
        #expect(a.parentFamilyChoice(of: eileenA) == b.parentFamilyChoice(of: eileenB))
        // Drop F4 and I5 entirely: everything the prose sees is identical.
        let without = eileenTree
            .replacingOccurrences(of: "1 FAMC @F4@\n", with: "")
            .replacingOccurrences(of: "0 @F4@ FAM\n1 WIFE @I5@\n1 CHIL @I3@\n", with: "")
        let c = GedcomFamilyGraph(gedcomText: without)
        let eileenC = try #require(c.people["@I3@"])
        #expect(a.relatives(.parents, of: eileenA).map(\.id) == c.relatives(.parents, of: eileenC).map(\.id))
        #expect(a.ancestorLine(of: try #require(a.people["@I1@"]), line: .both, generations: 3).map { $0.people.map(\.id) }
                == c.ancestorLine(of: try #require(c.people["@I1@"]), line: .both, generations: 3).map { $0.people.map(\.id) })
        #expect(c.parentFamilyBasisNote(for: eileenC) == nil)
    }

    // MARK: - Scale: 100k people, 5% with a duplicated parent record

    /// Budget (Debug, M4 Max, 2026-09-02): parents-of for all 100k people
    /// through the ruling in well under 2 s; siblings-of for everyone in
    /// under 3 s; the compiled parent table carries one mother per
    /// person; the fold note is produced for every duplicated child.
    /// Generation of the fixture is outside the clock.
    @Test func hundredThousandPeopleWithFivePercentDuplicateMothers() throws {
        let base = GedcomFamilyGraph(gedcomText: GedcomSyntheticPedigree.gedcom(people: 100_000))
        // Every 20th person who has a mother gets a second, wife-only
        // family whose wife is a fresh record of the same woman: same
        // name, born a year later, daughter of the same parents.
        var extraLines: [String] = []
        var duplicated: [String] = []
        var n = 0
        for id in base.people.keys.sorted() {
            let person = base.people[id]!
            guard let mother = base.relatives(.mother, of: person).first else { continue }
            n += 1
            guard n % 20 == 0 else { continue }
            let dupID = "@IDUP\(duplicated.count)@", famID = "@FDUP\(duplicated.count)@"
            let born = (mother.birthYear ?? 1800) + 1
            extraLines += ["0 \(dupID) INDI", "1 NAME \(mother.name.replacingOccurrences(of: " \(mother.surname ?? "")", with: "")) /\(mother.surname ?? "X")/",
                           "1 SEX F", "1 BIRT", "2 DATE \(born)", "1 FAMS \(famID)"]
            for famc in mother.childOfFamilies { extraLines.append("1 FAMC \(famc)") }
            extraLines += ["0 \(famID) FAM", "1 WIFE \(dupID)", "1 CHIL \(id)"]
            duplicated.append(id)
        }
        #expect(duplicated.count >= 4_000, "5% of the people with a mother: \(duplicated.count)")
        // Splice: the person's extra FAMC goes on their own record.
        var text = GedcomSyntheticPedigree.gedcom(people: 100_000)
        let dupSet = Set(duplicated)
        var out: [String] = []
        out.reserveCapacity(text.utf8.count / 20)
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("0 @"), line.hasSuffix(" INDI") {
                current = String(line.split(separator: " ")[1])
            } else if line.hasPrefix("0 ") {
                current = ""
            }
            if line.hasPrefix("1 FAMC "), dupSet.contains(current) {
                out.append(String(line))
                out.append("1 FAMC @FDUP\(duplicated.firstIndex(of: current)!)@")
                continue
            }
            if line == "0 TRLR" { out.append(contentsOf: extraLines) }
            out.append(String(line))
        }
        text = out.joined(separator: "\n")
        let graph = GedcomFamilyGraph(gedcomText: text)
        #expect(graph.people.count == 100_000 + duplicated.count)

        let clock = ContinuousClock()
        var parentTotal = 0, twoMothers = 0, notes = 0
        let elapsed = clock.measure {
            for id in graph.people.keys {
                let person = graph.people[id]!
                let parents = graph.relatives(.parents, of: person)
                parentTotal += parents.count
                if graph.relatives(.mother, of: person).count > 1 { twoMothers += 1 }
                if graph.parentFamilyBasisNote(for: person) != nil { notes += 1 }
            }
        }
        #expect(twoMothers == 0)
        #expect(notes == duplicated.count)
        #expect(parentTotal > 100_000)
        #expect(elapsed < .seconds(2), "parents-of for \(graph.people.count) people took \(elapsed)")

        // Siblings under the ruling for everyone, with the alternate note.
        var siblingTotal = 0, alternateNotes = 0
        let siblingElapsed = clock.measure {
            for id in graph.people.keys {
                let person = graph.people[id]!
                siblingTotal += graph.relatives(.siblings, of: person).count
                if graph.alternateSiblingBasisNote(for: person) != nil { alternateNotes += 1 }
            }
        }
        #expect(siblingTotal > 0)
        #expect(alternateNotes == 0, "a wife-only duplicate family adds no siblings")
        #expect(siblingElapsed < .seconds(3), "siblings-of for \(graph.people.count) people took \(siblingElapsed)")

        // The compiled table agrees: one mother per person, no fork.
        let index = graph.index
        var forks = 0
        for o in 0..<Int32(index.count) where index.mothers(of: o).count > 1 { forks += 1 }
        #expect(forks == 0)
        let sample = try #require(graph.people[duplicated[0]])
        let line = graph.ancestorLine(of: sample, line: .maternal, generations: 3)
        #expect(line.allSatisfy { $0.people.count == 1 }, "maternal line forked: \(line.map { $0.people.map(\.name) })")
    }
}
