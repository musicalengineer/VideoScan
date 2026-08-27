// GedcomLineageTests.swift
// Year-bounded ancestor walks on the core graph (codex #721): the gap
// analysis follows the SAME side as the walk, and GEDCOM qualifiers
// cannot invert at the cutoff. Pure.

import Testing
@testable import VideoScanCore

struct GedcomLineageTests {

    /// Rick 1959 ← father Richard 1929 ← father George 1898 (dated, before 1900)
    ///           ← mother Mary 1930   ← mother Ann (UNDATED)
    /// A maternal walk to 1900 stops at Mary (Ann has no date and Mary
    /// is dated, so Ann is kept — then Ann's parents are the frontier).
    /// The mirrored shape for the paternal side.
    private static let twoSided = """
    0 HEAD
    0 @I1@ INDI
    1 NAME Rick /Breen/
    1 SEX M
    1 BIRT
    2 DATE 1959
    1 FAMC @F1@
    0 @I2@ INDI
    1 NAME Richard /Breen/
    1 SEX M
    1 BIRT
    2 DATE 1929
    1 FAMC @F2@
    1 FAMS @F1@
    0 @I3@ INDI
    1 NAME Mary /Latta/
    1 SEX F
    1 BIRT
    2 DATE 1930
    1 FAMC @F3@
    1 FAMS @F1@
    0 @I4@ INDI
    1 NAME George /Breen/
    1 SEX M
    1 BIRT
    2 DATE 1898
    1 FAMS @F2@
    0 @I5@ INDI
    1 NAME Undated /Father/
    1 SEX M
    1 FAMS @F3@
    0 @I6@ INDI
    1 NAME Undated /Mother/
    1 SEX F
    1 FAMS @F2@
    0 @I7@ INDI
    1 NAME Old /Latta/
    1 SEX F
    1 BIRT
    2 DATE 1890
    1 FAMS @F3@
    0 @F1@ FAM
    1 HUSB @I2@
    1 WIFE @I3@
    1 CHIL @I1@
    0 @F2@ FAM
    1 HUSB @I4@
    1 WIFE @I6@
    1 CHIL @I2@
    0 @F3@ FAM
    1 HUSB @I5@
    1 WIFE @I7@
    1 CHIL @I3@
    0 TRLR
    """

    @Test func gapAnalysisFollowsTheWalkedSide() throws {
        let g = GedcomFamilyGraph(gedcomText: Self.twoSided)
        let rick = try #require(g.people["@I1@"])
        // Paternal to 1900: Richard walked; George (1898) is proven past the
        // bound. Richard's UNDATED mother must not be claimed as a gap.
        let paternal = g.ancestorLine(of: rick, line: .paternal, generations: 10, untilYear: 1900)
        #expect(paternal.map { $0.people.map(\.name) } == [["Richard Breen"]])
        #expect(paternal.first?.line == .paternal)
        let pGap = g.yearBoundGap(of: rick, generations: paternal, untilYear: 1900, line: .paternal)
        #expect(pGap.provenBeyond.map(\.name) == ["George Breen"])
        #expect(!pGap.hasDateGap, "the undated MOTHER is not on the paternal line")
        // Maternal to 1900: Mary walked; Old Latta (1890) proven past; Mary's
        // undated FATHER is not a maternal gap.
        let maternal = g.ancestorLine(of: rick, line: .maternal, generations: 10, untilYear: 1900)
        #expect(maternal.map { $0.people.map(\.name) } == [["Mary Latta"]])
        let mGap = g.yearBoundGap(of: rick, generations: maternal, untilYear: 1900, line: .maternal)
        #expect(mGap.provenBeyond.map(\.name) == ["Old Latta"])
        #expect(!mGap.hasDateGap, "the undated FATHER is not on the maternal line")
        // Without an explicit line the stamped generations decide — same answers.
        #expect(g.yearBoundGap(of: rick, generations: paternal, untilYear: 1900) == pGap)
        #expect(g.yearBoundGap(of: rick, generations: maternal, untilYear: 1900) == mGap)
        // A pedigree walk keeps both undated parents (each rides on a dated
        // child) and reports them as undated-walked; the dated ones are proven.
        let both = g.ancestorLine(of: rick, line: .both, generations: 10, untilYear: 1900)
        let bGap = g.yearBoundGap(of: rick, generations: both, untilYear: 1900)
        #expect(Set(bGap.undatedWalked.map(\.name)) == ["Undated Father", "Undated Mother"])
        #expect(bGap.undatedUnwalked.isEmpty)
        #expect(Set(bGap.provenBeyond.map(\.name)) == ["George Breen", "Old Latta"])
        #expect(pGap.undatedWalked.isEmpty && mGap.undatedWalked.isEmpty, "one-sided walks never touch the other parent")
        // Mirrored: the OLD behaviour (scan .parents) would have made these true.
        #expect(!pGap.undatedUnwalked.contains { $0.name == "Undated Mother" })
        #expect(!mGap.undatedUnwalked.contains { $0.name == "Undated Father" })
    }

    /// Rick 1959 ← Sr 1929 ← Aft (AFT 1590) ← Bef (BEF 1610) ← Abt (ABT 1600) ← Old 1500.
    private static let qualified = """
    0 HEAD
    0 @I1@ INDI
    1 NAME Rick /Breen/
    1 SEX M
    1 BIRT
    2 DATE 1959
    1 FAMC @F1@
    0 @I2@ INDI
    1 NAME Richard /Breen/ Sr
    1 SEX M
    1 BIRT
    2 DATE 1929
    1 FAMC @F2@
    1 FAMS @F1@
    0 @I3@ INDI
    1 NAME Aft /Breen/
    1 SEX M
    1 BIRT
    2 DATE AFT 1590
    1 FAMC @F3@
    1 FAMS @F2@
    0 @I4@ INDI
    1 NAME Bef /Breen/
    1 SEX M
    1 BIRT
    2 DATE BEF 1610
    1 FAMC @F4@
    1 FAMS @F3@
    0 @I5@ INDI
    1 NAME Abt /Breen/
    1 SEX M
    1 BIRT
    2 DATE ABT 1600
    1 FAMC @F5@
    1 FAMS @F4@
    0 @I6@ INDI
    1 NAME Old /Breen/
    1 SEX M
    1 BIRT
    2 DATE 1500
    1 FAMS @F5@
    0 @F1@ FAM
    1 HUSB @I2@
    1 CHIL @I1@
    0 @F2@ FAM
    1 HUSB @I3@
    1 CHIL @I2@
    0 @F3@ FAM
    1 HUSB @I4@
    1 CHIL @I3@
    0 @F4@ FAM
    1 HUSB @I5@
    1 CHIL @I4@
    0 @F5@ FAM
    1 HUSB @I6@
    1 CHIL @I5@
    0 TRLR
    """

    @Test func qualifiersDoNotInvertAtTheCutoff() throws {
        let g = GedcomFamilyGraph(gedcomText: Self.qualified)
        let rick = try #require(g.people["@I1@"])
        // Bound 1600: "AFT 1590" [1591, ∞) — not proven before 1600, walked.
        // "BEF 1610" (−∞, 1609] — not proven before 1600, walked. "ABT 1600"
        // [1598, 1602] — not proven, walked. 1500 — proven before, stopped.
        let walked = g.ancestorLine(of: rick, line: .paternal, generations: 10, untilYear: 1600)
        #expect(walked.map { $0.people.map(\.name) }
                == [["Richard Breen Sr"], ["Aft Breen"], ["Bef Breen"], ["Abt Breen"]])
        let gap = g.yearBoundGap(of: rick, generations: walked, untilYear: 1600, line: .paternal)
        #expect(gap.provenBeyond.map(\.name) == ["Old Breen"])
        #expect(!gap.hasDateGap)
        // The legacy integer rule would have stopped at "AFT 1590" (1590 < 1600).
        #expect(g.people["@I3@"]!.birthYear == 1590)
        // Bound 1620: "BEF 1610" is proven before it → the walk ends at Aft.
        let to1620 = g.ancestorLine(of: rick, line: .paternal, generations: 10, untilYear: 1620)
        #expect(to1620.last?.people.map(\.name) == ["Aft Breen"])
        let gap1620 = g.yearBoundGap(of: rick, generations: to1620, untilYear: 1620, line: .paternal)
        #expect(gap1620.provenBeyond.map(\.name) == ["Bef Breen"])
        // withinBound is the same rule, quoted.
        let abt = g.people["@I5@"]!, bef = g.people["@I4@"]!
        #expect(GedcomFamilyGraph.withinBound(abt, child: bef, year: 1602))
        #expect(!GedcomFamilyGraph.withinBound(abt, child: bef, year: 1603))
        #expect(!GedcomFamilyGraph.withinBound(bef, child: abt, year: 1610))
        #expect(GedcomFamilyGraph.withinBound(bef, child: abt, year: 1609))
    }
}
