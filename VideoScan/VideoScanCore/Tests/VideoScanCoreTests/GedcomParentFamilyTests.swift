// GedcomParentFamilyTests.swift
// Rick's 2026-09-02 ruling: ONE primary parent family per person, chosen
// deterministically; never two mothers or two fathers in prose.
//
// Dimensions — LOGIC: the Eileen fixture (I3 with FAMC F3 + F4, the two
// Marys both daughters of F6), the ranking table rule by rule, a genuine
// second family (adoption) that is not folded, the single-FAMC person
// unchanged, the same record listed twice, the codec and writer carrying
// the FAM _FSFTID. SCALE: 100k synthetic people with 5% duplicated FAMC,
// parents-of for everyone under a stated budget. ISOLATION: the rule
// reads the graph and nothing else — two parses agree, and removing the
// duplicate family changes nothing the prose sees.

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
0 @F-BIRTH@ FAM
1 HUSB @I2@
1 WIFE @I3@
1 CHIL @I1@
0 @F-ADOPT@ FAM
1 HUSB @I4@
1 WIFE @I5@
1 CHIL @I1@
0 TRLR
"""

private typealias Rank = GedcomFamilyGraph.ParentFamilyRank

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

    // MARK: - Logic: the ranking table, one rule at a time

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

    // MARK: - Logic: fold by surname + birth year, and its edges

    @Test func sameSurnameWithinTwoYearsFoldsWithoutSharedParents() throws {
        // Mary b. 1905 no longer a daughter of F6 — the surname/year rule
        // has to carry the fold on its own.
        let text = eileenTree.replacingOccurrences(of: "1 FAMS @F4@\n1 FAMC @F6@\n", with: "1 FAMS @F4@\n")
        let g = GedcomFamilyGraph(gedcomText: text)
        let eileen = try #require(g.people["@I3@"])
        let choice = try #require(g.parentFamilyChoice(of: eileen))
        #expect(choice.alternates.map(\.fold) == [.sameSurnameCloseBirth])
        #expect(g.parentFamilyBasisNote(for: eileen)
                == "(another record for her mother, Mary O'Connor b. 1905, exists in the tree — same surname, born within two years; treated as the same person)")
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

    @Test func aMissingBirthYearNeverFoldsBySurname() {
        let a = GedcomFamilyGraph.Person(id: "@A@", name: "Mary O'Connor", sex: "F", childOfFamily: nil)
        var b = GedcomFamilyGraph.Person(id: "@B@", name: "Mary Catherine O'Connor", sex: "F", childOfFamily: nil)
        b.birthDate = "1904"
        var aa = a; aa.surname = "O'Connor"
        var bb = b; bb.surname = "O'Connor"
        #expect(GedcomFamilyGraph.fold(aa, into: bb) == nil)
        aa.birthDate = "1906"
        #expect(GedcomFamilyGraph.fold(aa, into: bb) == .sameSurnameCloseBirth)
        aa.birthDate = "1907"
        #expect(GedcomFamilyGraph.fold(aa, into: bb) == nil)
        aa.childOfFamilies = ["@F6@"]; bb.childOfFamilies = ["@F6@"]
        #expect(GedcomFamilyGraph.fold(aa, into: bb) == .sameParents)
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
    /// through the ruling in well under 2 s; the compiled parent table
    /// carries one mother per person; the fold note is produced for every
    /// duplicated child. Generation of the fixture is outside the clock.
    @Test func hundredThousandPeopleWithFivePercentDuplicateMothers() throws {
        let base = GedcomFamilyGraph(gedcomText: GedcomSyntheticPedigree.gedcom(people: 100_000))
        // Every 20th person who has a mother gets a second, wife-only
        // family whose wife is a fresh record of the same woman: same
        // surname, born a year later, daughter of the same parents.
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
