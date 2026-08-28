// GedcomDirectRelationTests.swift
// Direct kin precedence before cousin math (codex #776): every case in
// GedcomFamilyGraph+DirectRelation, plus the guard that a grandparent is
// a grandparent — never "aunt/uncle" through the shared great-grandparent.

import Testing
@testable import VideoScanCore

/// Gramps (I1) + Granny (I2) → Dad (I3) [+ Mom (I4)] → Rick (I5) + Donna (I6)
/// → Tim (I7). Dad's brother Uncle (I8). Dad's half-sister Half (I9) via
/// Gramps + Other (I10). Donna's sister Sis (I11) via F6; Sis's husband
/// Bro-in-law (I12). Mom's parents: F7 (I13 Mom's dad).
private let tree = """
0 HEAD
0 @I1@ INDI
1 NAME Gramps /Breen/
1 SEX M
1 FAMS @F1@
1 FAMS @F4@
0 @I2@ INDI
1 NAME Granny /Breen/
1 SEX F
1 FAMS @F1@
0 @I3@ INDI
1 NAME Dad /Breen/
1 SEX M
1 FAMC @F1@
1 FAMS @F2@
0 @I4@ INDI
1 NAME Mom /Latta/
1 SEX F
1 FAMC @F7@
1 FAMS @F2@
0 @I5@ INDI
1 NAME Rick /Breen/
1 SEX M
1 FAMC @F2@
1 FAMS @F3@
0 @I6@ INDI
1 NAME Donna /Hudson/
1 SEX F
1 FAMC @F6@
1 FAMS @F3@
0 @I7@ INDI
1 NAME Tim /Breen/
1 SEX M
1 FAMC @F3@
0 @I8@ INDI
1 NAME Uncle /Breen/
1 SEX M
1 FAMC @F1@
0 @I9@ INDI
1 NAME Half /Breen/
1 SEX F
1 FAMC @F4@
0 @I10@ INDI
1 NAME Other /Woman/
1 SEX F
1 FAMS @F4@
0 @I11@ INDI
1 NAME Sis /Hudson/
1 SEX F
1 FAMC @F6@
1 FAMS @F5@
0 @I12@ INDI
1 NAME Brolaw /Jones/
1 SEX M
1 FAMS @F5@
0 @I13@ INDI
1 NAME Momsdad /Latta/
1 SEX M
1 FAMS @F7@
0 @F1@ FAM
1 HUSB @I1@
1 WIFE @I2@
1 CHIL @I3@
1 CHIL @I8@
0 @F2@ FAM
1 HUSB @I3@
1 WIFE @I4@
1 CHIL @I5@
0 @F3@ FAM
1 HUSB @I5@
1 WIFE @I6@
1 CHIL @I7@
0 @F4@ FAM
1 HUSB @I1@
1 WIFE @I10@
1 CHIL @I9@
0 @F5@ FAM
1 HUSB @I12@
1 WIFE @I11@
0 @F6@ FAM
1 CHIL @I6@
1 CHIL @I11@
0 @F7@ FAM
1 HUSB @I13@
1 CHIL @I4@
0 TRLR
"""

@Suite("Direct relations before cousin math")
struct GedcomDirectRelationTests {
    let g = GedcomFamilyGraph(gedcomText: tree)
    func rel(_ a: String, _ b: String) -> GedcomFamilyGraph.DirectRelation? { g.directRelation(between: a, and: b) }

    @Test func samePersonAndSpouses() {
        #expect(rel("@I5@", "@I5@")?.kind == .samePerson)
        #expect(rel("@I5@", "@I6@")?.term == "Donna Hudson is Rick Breen’s wife")
        #expect(rel("@I6@", "@I5@")?.term == "Rick Breen is Donna Hudson’s husband")
    }

    @Test func parentChildBothDirections() {
        #expect(rel("@I5@", "@I3@")?.term == "Dad Breen is Rick Breen’s father")
        #expect(rel("@I3@", "@I5@")?.term == "Rick Breen is Dad Breen’s son")
        #expect(rel("@I5@", "@I4@")?.term == "Mom Latta is Rick Breen’s mother")
        #expect(rel("@I5@", "@I3@")?.kind == .parentChild)
    }

    @Test func grandparentIsAGrandparentNotAnAunt() {
        let r = rel("@I5@", "@I1@")
        #expect(r?.kind == .ancestorDescendant)
        #expect(r?.term == "Gramps Breen is Rick Breen’s grandfather")
        #expect(rel("@I5@", "@I2@")?.term == "Granny Breen is Rick Breen’s grandmother")
        #expect(rel("@I1@", "@I5@")?.term == "Rick Breen is Gramps Breen’s grandson")
        #expect(rel("@I7@", "@I1@")?.term == "Gramps Breen is Tim Breen’s great-grandfather")
        #expect(rel("@I1@", "@I7@")?.term == "Rick Breen is Gramps Breen’s grandson" || rel("@I1@", "@I7@")?.term == "Tim Breen is Gramps Breen’s great-grandson")
        #expect(rel("@I5@", "@I1@")?.path.map(\.name) == ["Rick Breen", "Dad Breen", "Gramps Breen"])
        // The old cousin math would have said aunt/uncle here (Rick↔Gramps
        // meet at Gramps's parents, which the tree lacks → nothing). Pin
        // the ancestor-set view for the record.
        #expect(g.commonAncestors(of: "@I5@", and: "@I1@").isEmpty)
    }

    @Test func siblingsAndHalfSiblings() {
        #expect(rel("@I3@", "@I8@")?.term == "Uncle Breen is Dad Breen’s brother")
        #expect(rel("@I3@", "@I8@")?.kind == .siblings)
        #expect(rel("@I3@", "@I9@")?.kind == .halfSiblings)
        #expect(rel("@I3@", "@I9@")?.term == "Half Breen is Dad Breen’s half-sister (through Gramps Breen)")
        #expect(rel("@I6@", "@I11@")?.term == "Sis Hudson is Donna Hudson’s sister", "shared FAMC with no recorded parents still counts")
    }

    @Test func inLaws() {
        #expect(rel("@I6@", "@I3@")?.term == "Dad Breen is Donna Hudson’s father-in-law (Rick Breen’s father)")
        #expect(rel("@I3@", "@I6@")?.term == "Donna Hudson is Dad Breen’s daughter-in-law (married to Rick Breen)")
        #expect(rel("@I5@", "@I11@")?.term == "Sis Hudson is Rick Breen’s sister-in-law (Donna Hudson’s sister)")
        #expect(rel("@I5@", "@I12@")?.kind == nil, "spouse's sibling's spouse is not direct kin here")
        #expect(rel("@I6@", "@I12@")?.term == "Brolaw Jones is Donna Hudson’s brother-in-law (married to Sis Hudson)")
        #expect(rel("@I12@", "@I6@")?.term == "Donna Hudson is Brolaw Jones’ sister-in-law (Sis Hudson’s sister)")
    }

    @Test func uncleFallsToCousinMathAsAuntUncle() {
        // Rick ↔ Uncle: no direct kind; common ancestor Gramps at 2/1 →
        // "aunt/uncle and niece/nephew" — the one case where that label
        // is right.
        #expect(rel("@I5@", "@I8@") == nil)
        let hit = g.commonAncestors(of: "@I5@", and: "@I8@").first
        #expect(hit?.depthA == 2 && hit?.depthB == 1)
        #expect(hit?.kinshipTerm == "aunt/uncle and niece/nephew")
        #expect(GedcomFamilyGraph.descendantLabel(generations: 5, sex: "F") == "3rd-great-granddaughter")
    }
}
