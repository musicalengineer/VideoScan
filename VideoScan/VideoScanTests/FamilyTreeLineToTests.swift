import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

// "Line to Rick / Line to Donna" (feature/family-tree-notes-and-nav,
// 2026-08-26). Dimensions per the feature-test checklist:
//   Logic — descentPath found / not-an-ancestor / pedigree collapse picks
//           the shortest (paternal-first); relationshipLabel 1…6 both
//           sexes; anchors from root + spouse; model options + chain
//   Scale — 4,000-person single line: descentPath over the compiled topology
//           from the top < 50 ms (index construction has separate sensors)

// MARK: - Fixture: five generations above Rick (I1), with a collapse.
//
// Pedigree collapse: Edith (I50) is BOTH
//   • Rick's 4th-gen ancestor via mother's side: I1 ← I3(mother) ← I20(her
//     mother) ← I40 ← I50   (4 steps)
//   • Rick's 3rd-gen ancestor via father's side: I1 ← I2(father) ← I10(his
//     mother) ← I50            (3 steps)  ← shortest, and paternal.
private let fixtureGedcom = """
0 HEAD
1 SOUR VideoScanTests
0 @I1@ INDI
1 NAME Richard Harding /Breen/ Jr
1 SEX M
1 FAMC @F1@
1 FAMS @F0@
0 @I9@ INDI
1 NAME Donna Marie /Hudson/
1 SEX F
1 FAMC @F9@
1 FAMS @F0@
0 @I2@ INDI
1 NAME Richard Harding /Breen/ Sr
1 SEX M
1 FAMC @F2@
1 FAMS @F1@
0 @I3@ INDI
1 NAME Eileen /Latta/
1 SEX F
1 FAMC @F3@
1 FAMS @F1@
0 @I10@ INDI
1 NAME Muriel /Lamb/
1 SEX F
1 FAMC @F5@
1 FAMS @F2@
0 @I11@ INDI
1 NAME George /Breen/
1 SEX M
1 FAMS @F2@
0 @I20@ INDI
1 NAME Mary /O'Connor/
1 SEX F
1 FAMC @F4@
1 FAMS @F3@
0 @I21@ INDI
1 NAME David /Latta/
1 SEX M
1 FAMS @F3@
0 @I40@ INDI
1 NAME Ann /Parker/
1 SEX F
1 FAMC @F5@
1 FAMS @F4@
0 @I50@ INDI
1 NAME Edith Lucy /Parker/
1 SEX F
1 FAMS @F5@
0 @I51@ INDI
1 NAME Thomas /Parker/
1 SEX M
1 FAMS @F5@
0 @I90@ INDI
1 NAME Walter /Hudson/
1 SEX M
1 FAMS @F9@
0 @I99@ INDI
1 NAME Stranger /Nobody/
1 SEX M
0 @F0@ FAM
1 HUSB @I1@
1 WIFE @I9@
0 @F1@ FAM
1 HUSB @I2@
1 WIFE @I3@
1 CHIL @I1@
0 @F2@ FAM
1 HUSB @I11@
1 WIFE @I10@
1 CHIL @I2@
0 @F3@ FAM
1 HUSB @I21@
1 WIFE @I20@
1 CHIL @I3@
0 @F4@ FAM
1 WIFE @I40@
1 CHIL @I20@
0 @F5@ FAM
1 HUSB @I51@
1 WIFE @I50@
1 CHIL @I10@
1 CHIL @I40@
0 @F9@ FAM
1 HUSB @I90@
1 CHIL @I9@
0 TRLR
"""

private func graph() -> GedcomFamilyGraph { GedcomFamilyGraph(gedcomText: fixtureGedcom) }

@Suite("Line to — descent path (pure)")
struct DescentPathTests {

    @Test func directLineIsFoundTopDown() throws {
        let g = graph()
        let path = try #require(g.descentPath(from: "@I20@", to: "@I1@"))
        #expect(path.map(\.id) == ["@I20@", "@I3@", "@I1@"])
        let parent = try #require(g.descentPath(from: "@I2@", to: "@I1@"))
        #expect(parent.map(\.id) == ["@I2@", "@I1@"])
    }

    @Test func notAnAncestorSelfAndUnknownAreNil() {
        let g = graph()
        #expect(g.descentPath(from: "@I99@", to: "@I1@") == nil)   // unrelated
        #expect(g.descentPath(from: "@I9@", to: "@I1@") == nil)    // spouse, not ancestor
        #expect(g.descentPath(from: "@I1@", to: "@I2@") == nil)    // wrong direction
        #expect(g.descentPath(from: "@I1@", to: "@I1@") == nil)    // self
        #expect(g.descentPath(from: "@I404@", to: "@I1@") == nil)
        #expect(g.descentPath(from: "@I2@", to: "@I404@") == nil)
    }

    @Test func pedigreeCollapsePicksTheShortestPaternalFirstPath() throws {
        let g = graph()
        // Edith reaches Rick in 3 steps via his father, 4 via his mother.
        let path = try #require(g.descentPath(from: "@I50@", to: "@I1@"))
        #expect(path.map(\.id) == ["@I50@", "@I10@", "@I2@", "@I1@"])
        #expect(g.relationshipLabel(from: "@I50@", to: "@I1@") == "your great-grandmother")
        // Thomas (Edith's husband) shares the same shortest line.
        #expect(g.descentPath(from: "@I51@", to: "@I1@")?.map(\.id) == ["@I51@", "@I10@", "@I2@", "@I1@"])
        // Ann is only reachable on the maternal side: 3 generations.
        #expect(g.descentPath(from: "@I40@", to: "@I1@")?.map(\.id) == ["@I40@", "@I20@", "@I3@", "@I1@"])
        #expect(g.relationshipLabel(from: "@I40@", to: "@I1@", possessive: "Rick's") == "Rick's great-grandmother")
    }

    @Test func equalLengthPedigreeCollapsePicksThePaternalRoute() throws {
        // I50 is grandparent to I1 through both parents. Both routes are two
        // hops, so only the documented father-first tie break chooses I2.
        let g = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME Child /Diamond/
        1 FAMC @F1@
        0 @I2@ INDI
        1 NAME Father /Diamond/
        1 SEX M
        1 FAMC @F2@
        1 FAMS @F1@
        0 @I3@ INDI
        1 NAME Mother /Diamond/
        1 SEX F
        1 FAMC @F3@
        1 FAMS @F1@
        0 @I50@ INDI
        1 NAME Shared /Ancestor/
        1 SEX M
        1 FAMS @F2@
        1 FAMS @F3@
        0 @F1@ FAM
        1 HUSB @I2@
        1 WIFE @I3@
        1 CHIL @I1@
        0 @F2@ FAM
        1 HUSB @I50@
        1 CHIL @I2@
        0 @F3@ FAM
        1 HUSB @I50@
        1 CHIL @I3@
        0 TRLR
        """)

        let path = try #require(g.descentPath(from: "@I50@", to: "@I1@"))
        #expect(path.map(\.id) == ["@I50@", "@I2@", "@I1@"])
    }

    @Test func relationshipWordsForOneToSixGenerationsBothSexes() {
        let m = (1...6).map { GedcomFamilyGraph.generationLabel(generations: $0, sex: "M") }
        #expect(m == ["father", "grandfather", "great-grandfather", "great-great-grandfather",
                      "3rd-great-grandfather", "4th-great-grandfather"])
        let f = (1...6).map { GedcomFamilyGraph.generationLabel(generations: $0, sex: "F") }
        #expect(f == ["mother", "grandmother", "great-grandmother", "great-great-grandmother",
                      "3rd-great-grandmother", "4th-great-grandmother"])
        #expect(GedcomFamilyGraph.generationLabel(generations: 8, sex: "F") == "6th-great-grandmother")
        #expect(GedcomFamilyGraph.generationLabel(generations: 2, sex: "") == "grandparent")
        #expect(GedcomFamilyGraph.generationLabel(generations: 1, sex: "U") == "parent")
        #expect(GedcomFamilyGraph.numericOrdinal(1) == "1st" && GedcomFamilyGraph.numericOrdinal(2) == "2nd"
                && GedcomFamilyGraph.numericOrdinal(3) == "3rd" && GedcomFamilyGraph.numericOrdinal(11) == "11th"
                && GedcomFamilyGraph.numericOrdinal(12) == "12th" && GedcomFamilyGraph.numericOrdinal(13) == "13th"
                && GedcomFamilyGraph.numericOrdinal(21) == "21st" && GedcomFamilyGraph.numericOrdinal(22) == "22nd"
                && GedcomFamilyGraph.numericOrdinal(23) == "23rd" && GedcomFamilyGraph.numericOrdinal(111) == "111th")
    }

    @Test func fourThousandGenerationsResolveFast() {
        // A straight paternal line, root first (so I1 is the tree root).
        var text = "0 HEAD\n"
        let n = 4_000
        for i in 1...n {
            text += "0 @I\(i)@ INDI\n1 NAME P\(i) /Line/\n1 SEX M\n"
            if i < n { text += "1 FAMC @F\(i)@\n" }
            if i > 1 { text += "1 FAMS @F\(i - 1)@\n" }
        }
        for i in 1..<n { text += "0 @F\(i)@ FAM\n1 HUSB @I\(i + 1)@\n1 CHIL @I\(i)@\n" }
        text += "0 TRLR\n"
        let g = GedcomFamilyGraph(gedcomText: text)
        // The index is lazy for a text-parsed graph. Production's compiled
        // artifact already carries it, and GedcomScaleSensorTests budgets
        // index construction separately. This sensor owns the two walks.
        _ = g.index
        let start = ContinuousClock.now
        let path = g.descentPath(from: "@I\(n)@", to: "@I1@")
        let missing = g.descentPath(from: "@I1@", to: "@I\(n)@")
        let elapsed = ContinuousClock.now - start
        #expect(path?.count == n)
        #expect(missing == nil)
        #expect(elapsed < .milliseconds(50), "two 4k-deep walks took \(elapsed)")
        #expect(GedcomFamilyGraph.generationLabel(generations: n - 1, sex: "M") == "3997th-great-grandfather")
    }
}

@Suite("Line to — model anchors, options and chain")
@MainActor
struct LineToModelTests {

    /// Settings with NO owner pin.
    ///
    /// Without this the inline bundle reads UserDefaults.standard, and a
    /// real owner pin — Rick has one — names nobody in a synthetic fixture,
    /// which `anchors(in:ownerFamilySearchID:)` treats as a stale pin and
    /// answers with an empty array. The tests then fail on a machine that
    /// has been used and pass on one that has not, which is the worst way
    /// for a test to behave.
    static let noOwnerPin = FamilyTreeLaunchBundle.Settings(
        speakers: HallieTurnExecutor.Speakers(ownerName: "Rick", archivistName: "Hallie",
                                              archivistPersonName: nil, ownerFamilySearchID: nil),
        ownerFamilySearchID: nil)

    private func model() -> FamilyTreeLiveModel {
        let model = FamilyTreeLiveModel(
            originalsDirectory: URL(fileURLWithPath: "/nonexistent/never-read"))
        model.install(graph: graph(), settings: Self.noOwnerPin)
        return model
    }

    @Test func anchorsAreRootThenSpouseLabelledByFirstGivenName() {
        let anchors = FamilyTreeLiveModel.anchors(in: graph())
        #expect(anchors.map(\.id) == ["@I1@", "@I9@"])
        #expect(anchors.map(\.label) == ["Richard", "Donna"])
        #expect(anchors.map(\.isRoot) == [true, false])
        // No root → no anchors; a root with no spouse → just the root.
        #expect(FamilyTreeLiveModel.anchors(in: GedcomFamilyGraph(gedcomText: "0 HEAD\n0 TRLR")).isEmpty)
        let lone = GedcomFamilyGraph(gedcomText: "0 HEAD\n0 @I1@ INDI\n1 NAME Only /One/\n0 TRLR")
        #expect(FamilyTreeLiveModel.anchors(in: lone).map(\.label) == ["Only"])
    }

    @Test func optionsFollowTheSelectionAndDisableWhenNotAnAncestor() throws {
        let m = model()
        #expect(m.anchors.count == 2)

        m.select("@I50@")   // Edith: ancestor of Rick, not of Donna
        #expect(m.lineOptions.map(\.isAvailable) == [true, false])
        #expect(m.lineOptions[0].relation == "your great-grandmother")
        #expect(m.lineOptions[0].generations == 3)
        #expect(m.lineOptions[1].relation == nil)

        m.select("@I90@")   // Walter: Donna's father, nothing to Rick
        #expect(m.lineOptions.map(\.isAvailable) == [false, true])
        #expect(m.lineOptions[1].relation == "Donna's father")

        m.select("@I1@")    // the root himself: no line to anyone
        #expect(m.lineOptions.map(\.isAvailable) == [false, false])
        // Cached: same object back for a revisit.
        m.select("@I50@")
        #expect(m.lineOptions[0].generations == 3)
    }

    @Test func chainIsBuiltFromTheOptionAndClearsWhenSelectionLeavesIt() throws {
        let m = model()
        m.select("@I40@")
        #expect(m.lineChain == nil)
        m.showLine(to: "@I9@")           // unavailable → no chain
        #expect(m.lineChain == nil)

        m.showLine(to: "@I1@")
        let chain = try #require(m.lineChain)
        #expect(chain.title == "Ann Parker → Richard: your great-grandmother (3 generations)")
        #expect(chain.cards.map(\.id) == ["@I40@", "@I20@", "@I3@", "@I1@"])
        #expect(chain.cards.map(\.generation) == [0, 1, 2, 3])
        #expect(chain.cards[2].spouseNames == ["Richard Harding Breen Sr"])
        #expect(chain.cards[3].spouseNames == ["Donna Marie Hudson"])
        #expect(chain.cards[0].spouseNames.isEmpty)

        // Selecting a card in the chain keeps it …
        m.select("@I3@")
        #expect(m.lineChain != nil)
        #expect(m.selectedPerson?.name == "Eileen Latta")
        // … selecting someone outside returns to the tree.
        m.select("@I99@")
        #expect(m.lineChain == nil)

        m.select("@I2@")
        m.showLine(to: "@I1@")
        #expect(m.lineChain?.title == "Richard Harding Breen Sr → Richard: your father (1 generation)")
        m.showFullTree()
        #expect(m.lineChain == nil)
        // A reinstall drops the chain and the cache.
        m.install(graph: graph())
        #expect(m.lineChain == nil)
    }
}
