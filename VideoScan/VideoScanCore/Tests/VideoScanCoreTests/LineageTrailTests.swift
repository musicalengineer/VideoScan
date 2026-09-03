// LineageTrailTests.swift
// LOGIC + SCALE for the birthplace trail (2026-09-02): single-line walks
// to the top, the outside-the-US and Europe stops, the breadth-first
// all-ancestors walk (first generation with a match wins, path returned),
// missing birthplaces reported, three unknown generations running out,
// the 20-generation cap, and a 131k-person pedigree under a budget.
// Pure: synthetic GEDCOM text, no files.

import Foundation
import Testing
@testable import VideoScanCore

struct LineageTrailTests {

    typealias T = LineageTrail

    /// Donna's pedigree, four generations, with one unrecorded birthplace
    /// on the maternal line and a colonial-era name on the paternal one.
    ///
    ///   gen 0  Donna Hudson              Brockton, Massachusetts, USA
    ///   gen 1  Bill Hudson (father)      Wilmington, New Hanover, North Carolina
    ///          Elaine Bowser (mother)    Stoughton, Massachusetts, USA
    ///   gen 2  Sam Hudson                Shrewsbury, Worcester, Massachusetts Bay Colony, British Colonial America
    ///          Ida Hudson                (no PLAC)
    ///          Fred Bowser               KY
    ///          Ethel Cote                Stukley, Shefford, Quebec, Canada
    ///   gen 3  Old Hudson (Sam's father) County Antrim, Ireland
    ///          Jean Cote (Ethel's father)(no PLAC)
    ///          Marie Cote (Ethel's mother)(no PLAC)
    ///   gen 4  Anne Cote (Marie's mother) Normandy, France
    static let donna = GedcomFamilyGraph(gedcomText: """
    0 HEAD
    0 @I1@ INDI
    1 NAME Donna /Hudson/
    1 SEX F
    1 BIRT
    2 DATE 4 APR 1958
    2 PLAC Brockton, Massachusetts, USA
    1 FAMC @F1@
    0 @I2@ INDI
    1 NAME Bill /Hudson/
    1 SEX M
    1 BIRT
    2 DATE 1930
    2 PLAC Wilmington, New Hanover, North Carolina
    1 FAMC @F2@
    1 FAMS @F1@
    0 @I3@ INDI
    1 NAME Elaine /Bowser/
    1 SEX F
    1 BIRT
    2 DATE 1934
    2 PLAC Stoughton, Massachusetts, USA
    1 FAMC @F3@
    1 FAMS @F1@
    0 @I4@ INDI
    1 NAME Sam /Hudson/
    1 SEX M
    1 BIRT
    2 DATE 1900
    2 PLAC Shrewsbury, Worcester, Massachusetts Bay Colony, British Colonial America
    1 FAMC @F4@
    1 FAMS @F2@
    0 @I5@ INDI
    1 NAME Ida /Hudson/
    1 SEX F
    1 BIRT
    2 DATE 1902
    1 FAMS @F2@
    0 @I6@ INDI
    1 NAME Fred /Bowser/
    1 SEX M
    1 BIRT
    2 DATE 1905
    2 PLAC KY
    1 FAMS @F3@
    0 @I7@ INDI
    1 NAME Ethel /Cote/
    1 SEX F
    1 BIRT
    2 DATE 1908
    2 PLAC Stukley, Shefford, Quebec, Canada
    1 FAMC @F5@
    1 FAMS @F3@
    0 @I8@ INDI
    1 NAME Old /Hudson/
    1 SEX M
    1 BIRT
    2 DATE 1870
    2 PLAC County Antrim, Ireland
    1 FAMS @F4@
    0 @I9@ INDI
    1 NAME Jean /Cote/
    1 SEX M
    1 BIRT
    2 DATE 1878
    1 FAMS @F5@
    0 @I10@ INDI
    1 NAME Marie /Cote/
    1 SEX F
    1 BIRT
    2 DATE 1880
    1 FAMC @F6@
    1 FAMS @F5@
    0 @I11@ INDI
    1 NAME Anne /Cote/
    1 SEX F
    1 BIRT
    2 DATE 1850
    2 PLAC Normandy, France
    1 FAMS @F6@
    0 @F1@ FAM
    1 HUSB @I2@
    1 WIFE @I3@
    1 CHIL @I1@
    0 @F2@ FAM
    1 HUSB @I4@
    1 WIFE @I5@
    1 CHIL @I2@
    0 @F3@ FAM
    1 HUSB @I6@
    1 WIFE @I7@
    1 CHIL @I3@
    0 @F4@ FAM
    1 HUSB @I8@
    1 CHIL @I4@
    0 @F5@ FAM
    1 HUSB @I9@
    1 WIFE @I10@
    1 CHIL @I7@
    0 @F6@ FAM
    1 WIFE @I11@
    1 CHIL @I10@
    0 TRLR
    """)

    static var donnaPerson: GedcomFamilyGraph.Person { donna.people["@I1@"]! }

    @Test func maternalLineToTheTopReportsEveryGenerationAndTheMissingPlace() {
        let r = T.walk(line: .maternal, from: Self.donnaPerson, stop: .top, graph: Self.donna)
        #expect(r.steps.map(\.person.name) == ["Donna Hudson", "Elaine Bowser", "Ethel Cote", "Marie Cote", "Anne Cote"])
        #expect(r.steps.map(\.generation) == [0, 1, 2, 3, 4])
        #expect(r.ending == .top)
        #expect(r.generationsWalked == 4)
        #expect(r.lastGeneration.map(\.name) == ["Anne Cote"])
        #expect(r.match == nil)
        // Marie has no PLAC: reported as nil, the walk went on past her.
        #expect(r.steps[3].birthplace == nil)
        #expect(r.steps[4].placeText == "Normandy, France")
        #expect(r.steps.allSatisfy { !$0.matchesStop })
    }

    @Test func maternalLineStopsAtTheFirstBirthOutsideTheUnitedStates() {
        let r = T.walk(line: .maternal, from: Self.donnaPerson,
                       stop: .outsideCountry(BirthplaceClassifier.unitedStates), graph: Self.donna)
        #expect(r.ending == .stopped)
        #expect(r.steps.map(\.person.name) == ["Donna Hudson", "Elaine Bowser", "Ethel Cote"])
        #expect(r.match?.person.name == "Ethel Cote")
        #expect(r.match?.generation == 2)
        #expect(r.generationsWalked == 2)
    }

    @Test func maternalLineStopsInEuropePastCanadaAndAnUnknownPlace() {
        let r = T.walk(line: .maternal, from: Self.donnaPerson, stop: .continent(.europe), graph: Self.donna)
        #expect(r.ending == .stopped)
        #expect(r.match?.person.name == "Anne Cote")
        #expect(r.match?.generation == 4)
        #expect(r.steps.count == 5)
    }

    @Test func paternalLineMapsTheColonialNameHomeAndStopsInIreland() {
        let r = T.walk(line: .paternal, from: Self.donnaPerson, stop: .continent(.europe), graph: Self.donna)
        #expect(r.steps.map(\.person.name) == ["Donna Hudson", "Bill Hudson", "Sam Hudson", "Old Hudson"])
        #expect(r.steps[2].birthplace?.country == "United States")
        #expect(r.steps[2].birthplace?.mappedFromHistoricalName == true)
        #expect(r.match?.person.name == "Old Hudson")
        #expect(r.ending == .stopped)

        // Outside the US on the paternal line is the same person: the
        // colonial birth is at home.
        let outside = T.walk(line: .paternal, from: Self.donnaPerson,
                             stop: .outsideCountry(BirthplaceClassifier.unitedStates), graph: Self.donna)
        #expect(outside.match?.person.name == "Old Hudson")
    }

    @Test func allAncestorsReturnsTheFirstGenerationWithAEuropeanBirthAndThePath() {
        // Old Hudson (gen 3, Ireland) is nearer than Anne Cote (gen 4, France).
        let r = T.walk(line: .allAncestors, from: Self.donnaPerson, stop: .continent(.europe), graph: Self.donna)
        #expect(r.ending == .stopped)
        #expect(r.match?.person.name == "Old Hudson")
        #expect(r.match?.generation == 3)
        #expect(r.generationsWalked == 3)
        #expect(r.steps.map(\.person.name) == ["Donna Hudson", "Bill Hudson", "Sam Hudson", "Old Hudson"])
        #expect(r.steps.map(\.generation) == [0, 1, 2, 3])
    }

    @Test func allAncestorsOutsideTheUnitedStatesFindsTheCanadianGrandmotherFirst() {
        let r = T.walk(line: .allAncestors, from: Self.donnaPerson,
                       stop: .outsideCountry(BirthplaceClassifier.unitedStates), graph: Self.donna)
        #expect(r.match?.person.name == "Ethel Cote")
        #expect(r.match?.generation == 2)
        #expect(r.steps.map(\.person.name) == ["Donna Hudson", "Elaine Bowser", "Ethel Cote"])
    }

    @Test func allAncestorsWithNoMatchEndsAtTheTopWithOnlyTheAnchor() {
        let r = T.walk(line: .allAncestors, from: Self.donnaPerson, stop: .continent(.asia), graph: Self.donna)
        #expect(r.ending == .top)
        #expect(r.match == nil)
        #expect(r.steps.map(\.person.name) == ["Donna Hudson"])
        #expect(r.generationsWalked == 4)
        #expect(r.lastGeneration.map(\.name) == ["Anne Cote"])
    }

    @Test func aPersonWithNoRecordedParentEndsAtOnce() {
        let anne = Self.donna.people["@I11@"]!
        let r = T.walk(line: .maternal, from: anne, stop: .top, graph: Self.donna)
        #expect(r.steps.count == 1)
        #expect(r.ending == .top)
        #expect(r.generationsWalked == 0)
        let all = T.walk(line: .allAncestors, from: anne, stop: .continent(.europe), graph: Self.donna)
        #expect(all.ending == .top)
        #expect(all.steps.count == 1)
    }

    // MARK: Unknown runs, caps

    /// A straight maternal chain `count` deep. `place(g)` gives generation
    /// g's PLAC (nil = none). Person @I0@ is the anchor.
    static func chain(_ count: Int, place: (Int) -> String?) -> GedcomFamilyGraph {
        var lines = ["0 HEAD"]
        for g in 0...count {
            lines.append("0 @I\(g)@ INDI")
            lines.append("1 NAME Gen\(g) /Chain/")
            lines.append("1 SEX F")
            lines.append("1 BIRT")
            lines.append("2 DATE \(2000 - 25 * g)")
            if let p = place(g) { lines.append("2 PLAC \(p)") }
            if g < count { lines.append("1 FAMC @F\(g)@") }
            if g > 0 { lines.append("1 FAMS @F\(g - 1)@") }
        }
        for g in 0..<count {
            lines.append("0 @F\(g)@ FAM")
            lines.append("1 WIFE @I\(g + 1)@")
            lines.append("1 CHIL @I\(g)@")
        }
        lines.append("0 TRLR")
        return GedcomFamilyGraph(gedcomText: lines.joined(separator: "\n"))
    }

    @Test func threeUnknownGenerationsInARowRunTheTrailOut() {
        // gens 1–3 unrecorded, gen 4 Ireland: never reached.
        let g = Self.chain(5) { gen in
            switch gen {
            case 0: return "Boston, Massachusetts, USA"
            case 1, 2, 3: return nil
            default: return "Cork, Ireland"
            }
        }
        let anchor = g.people["@I0@"]!
        let r = T.walk(line: .maternal, from: anchor, stop: .continent(.europe), graph: g)
        #expect(r.ending == .ranOut)
        #expect(r.generationsWalked == 3)
        #expect(r.steps.count == 4)
        #expect(r.match == nil)
        let all = T.walk(line: .allAncestors, from: anchor, stop: .continent(.europe), graph: g)
        #expect(all.ending == .ranOut)
        #expect(all.generationsWalked == 3)
    }

    @Test func twoUnknownGenerationsDoNotRunTheTrailOut() {
        let g = Self.chain(4) { gen in
            switch gen {
            case 1, 2: return nil
            case 3: return "Boston, Massachusetts, USA"
            default: return "Cork, Ireland"
            }
        }
        let r = T.walk(line: .maternal, from: g.people["@I0@"]!, stop: .continent(.europe), graph: g)
        #expect(r.ending == .stopped)
        #expect(r.match?.generation == 4)
    }

    @Test func twentyGenerationCapAndExplicitGenerationStop() {
        let g = Self.chain(25) { _ in "Boston, Massachusetts, USA" }
        let anchor = g.people["@I0@"]!
        let capped = T.walk(line: .maternal, from: anchor, stop: .top, graph: g)
        #expect(capped.ending == .generationCap)
        #expect(capped.generationsWalked == T.generationCap)
        #expect(capped.steps.count == T.generationCap + 1)

        let three = T.walk(line: .maternal, from: anchor, stop: .generations(3), graph: g)
        #expect(three.ending == .generationCap)
        #expect(three.steps.map(\.person.name) == ["Gen0 Chain", "Gen1 Chain", "Gen2 Chain", "Gen3 Chain"])

        let all = T.walk(line: .allAncestors, from: anchor, stop: .continent(.europe), graph: g)
        #expect(all.ending == .generationCap)
        #expect(all.generationsWalked == T.generationCap)

        // Asking for more than the cap is the cap.
        let fifty = T.walk(line: .maternal, from: anchor, stop: .generations(50), graph: g)
        #expect(fifty.generationsWalked == T.generationCap)
    }

    @Test func shorterThanTheStopEndsAtTheTopNotTheCap() {
        let g = Self.chain(2) { _ in "Boston, Massachusetts, USA" }
        let r = T.walk(line: .maternal, from: g.people["@I0@"]!, stop: .generations(5), graph: g)
        #expect(r.ending == .top)
        #expect(r.generationsWalked == 2)
    }

    // MARK: SCALE

    /// A full binary pedigree 17 generations deep (2^17 − 1 = 131,071
    /// people, i's parents are 2i and 2i+1). Only the top generation is
    /// born in Ireland, so an all-ancestors Europe walk from the root
    /// visits every record. Budget: 5 s Debug (measured well under 1 s on
    /// the M4 Max, 2026-09-02); the GEDCOM parse is outside the clock.
    @Test func allAncestorsWalksA131kPersonPedigreeUnderBudget() {
        let generations = 17
        let n = (1 << generations) - 1
        let topStart = 1 << (generations - 1)
        var lines = ["0 HEAD"]
        lines.reserveCapacity(n * 8)
        for i in 1...n {
            lines.append("0 @I\(i)@ INDI")
            lines.append("1 NAME Given\(i) /Person\(i % 97)/")
            lines.append("1 SEX \(i % 2 == 0 ? "M" : "F")")
            lines.append("1 BIRT")
            lines.append("2 DATE \(2000 - 25 * Int(log2(Double(i))))")
            lines.append("2 PLAC \(i >= topStart ? "Cork, Ireland" : "Boston, Massachusetts, USA")")
            if 2 * i + 1 <= n { lines.append("1 FAMC @F\(i)@") }
            if i > 1 { lines.append("1 FAMS @F\(i / 2)@") }
        }
        for i in 1...n where 2 * i + 1 <= n {
            lines.append("0 @F\(i)@ FAM")
            lines.append("1 HUSB @I\(2 * i)@")
            lines.append("1 WIFE @I\(2 * i + 1)@")
            lines.append("1 CHIL @I\(i)@")
        }
        lines.append("0 TRLR")
        let big = GedcomFamilyGraph(gedcomText: lines.joined(separator: "\n"))
        #expect(big.people.count == n)

        let root = big.people["@I1@"]!
        let t0 = Date()
        let r = T.walk(line: .allAncestors, from: root, stop: .continent(.europe), graph: big)
        let elapsed = Date().timeIntervalSince(t0)
        #expect(r.ending == .stopped)
        #expect(r.match?.generation == generations - 1)
        #expect(r.steps.count == generations)
        #expect(r.lastGeneration.count == topStart)
        #expect(elapsed < 5.0, Comment(rawValue: "all-ancestors walk over \(n) people took \(elapsed) s"))

        // The single line is O(depth) regardless of tree size.
        let t1 = Date()
        let single = T.walk(line: .paternal, from: root, stop: .continent(.europe), graph: big)
        #expect(single.match?.generation == generations - 1)
        #expect(Date().timeIntervalSince(t1) < 0.5)
    }
}
