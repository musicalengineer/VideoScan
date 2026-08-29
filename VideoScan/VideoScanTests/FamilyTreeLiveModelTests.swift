import AppKit
import Foundation
import Testing
@testable import VideoScan

// Family Tree tab over the real GEDCOM graph (feature/family-tree-gedcom,
// 2026-08-22). Dimensions per the feature-test checklist:
//   Logic     — layout shape, generation caps, unknown parents, years text
//   Scale     — 5,000-person pedigree chain, 0.5 s budget
//   Isolation — the loader reads ONLY the injected directory
// No media is opened, so no media-matrix dimension.

// MARK: - Fixture

/// Three generations above Rick (I7), two below, one `2 PLAC` line, one
/// person with no recorded parents (I1, who also has two marriages), and
/// one generation on each end that must be capped off (I12 above, I18 below).
private let fixtureGedcom = """
0 HEAD
1 SOUR VideoScanTests
0 @I1@ INDI
1 NAME John /Breen/
1 SEX M
1 BIRT
2 DATE 1 JAN 1900
2 PLAC Cork, Ireland
1 DEAT
2 DATE 1970
1 FAMS @F1@
1 FAMS @F4@
0 @I2@ INDI
1 NAME Mary /Lamb/
1 SEX F
1 BIRT
2 DATE ABT 1902
1 FAMS @F1@
0 @I8@ INDI
1 NAME Anne /Hudson/
1 SEX F
1 FAMS @F4@
0 @I9@ INDI
1 NAME Kate /Breen/
1 SEX F
1 FAMC @F4@
0 @I3@ INDI
1 NAME Richard Hardin /Breen/
1 SEX M
1 BIRT
2 DATE 4 MAR 1929
1 DEAT
2 DATE 2008
1 FAMC @F1@
1 FAMS @F3@
0 @I4@ INDI
1 NAME Eileen /Latta/
1 SEX F
1 BIRT
2 DATE 1930
1 DEAT
2 DATE 2023
1 FAMC @F2@
1 FAMS @F3@
0 @I5@ INDI
1 NAME David McGill /Latta/
1 SEX M
1 BIRT
2 DATE 1902
1 FAMC @F5@
1 FAMS @F2@
0 @I6@ INDI
1 NAME Mary Catherine /O'Connor/
1 SEX F
1 BIRT
2 DATE 1904
1 FAMS @F2@
0 @I10@ INDI
1 NAME Samuel /Latta/
1 SEX M
1 BIRT
2 DATE 1870
1 FAMC @F6@
1 FAMS @F5@
0 @I11@ INDI
1 NAME Jane /Doe/
1 SEX F
1 FAMS @F5@
0 @I12@ INDI
1 NAME Old /Latta/
1 SEX M
1 BIRT
2 DATE 1840
1 FAMS @F6@
0 @I7@ INDI
1 NAME Richard /Breen/
1 SEX M
1 BIRT
2 DATE 1959
1 FAMC @F3@
1 FAMS @F7@
0 @I13@ INDI
1 NAME Jim /Breen/
1 SEX M
1 BIRT
2 DATE 1962
1 FAMC @F3@
0 @I14@ INDI
1 NAME Donna /Hudson/
1 SEX F
1 BIRT
2 DATE 1959
1 FAMS @F7@
0 @I15@ INDI
1 NAME Son /Breen/ One
1 SEX M
1 BIRT
2 DATE 1985
1 FAMC @F7@
1 FAMS @F8@
0 @I16@ INDI
1 NAME Son /Breen/ Two
1 SEX M
1 FAMC @F7@
0 @I17@ INDI
1 NAME Grandkid /Breen/
1 SEX M
1 BIRT
2 DATE 2010
1 FAMC @F8@
1 FAMS @F9@
0 @I18@ INDI
1 NAME Greatgrandkid /Breen/
1 SEX F
1 FAMC @F9@
0 @F1@ FAM
1 HUSB @I1@
1 WIFE @I2@
1 CHIL @I3@
1 MARR
2 DATE 1925
0 @F4@ FAM
1 HUSB @I1@
1 WIFE @I8@
1 CHIL @I9@
0 @F2@ FAM
1 HUSB @I5@
1 WIFE @I6@
1 CHIL @I4@
0 @F5@ FAM
1 HUSB @I10@
1 WIFE @I11@
1 CHIL @I5@
0 @F6@ FAM
1 HUSB @I12@
1 CHIL @I10@
0 @F3@ FAM
1 HUSB @I3@
1 WIFE @I4@
1 CHIL @I7@
1 CHIL @I13@
0 @F7@ FAM
1 HUSB @I7@
1 WIFE @I14@
1 CHIL @I15@
1 CHIL @I16@
0 @F8@ FAM
1 HUSB @I15@
1 CHIL @I17@
0 @F9@ FAM
1 HUSB @I17@
1 CHIL @I18@
0 TRLR
"""

private func fixtureGraph() -> GedcomFamilyGraph {
    GedcomFamilyGraph(gedcomText: fixtureGedcom)
}

private func node(_ result: FamilyTreeLayout.Result, _ id: String) -> FamilyTreeLayout.Node? {
    result.node(forPerson: id)
}

/// Outer suite so `-only-testing:VideoScanTests/FamilyTreeLiveModelTests`
/// selects everything in this file.
@Suite("Family tree (GEDCOM)")
enum FamilyTreeLiveModelTests {

// MARK: - Layout (pure)

@Suite("Family tree layout — shape")
struct FamilyTreeLayoutShapeTests {

    @Test func parentsAboveChildrenBelowTheRoot() throws {
        let result = FamilyTreeLayout.layout(graph: fixtureGraph(), rootID: "@I7@")
        let root = try #require(node(result, "@I7@"))
        let father = try #require(node(result, "@I3@"))
        let mother = try #require(node(result, "@I4@"))
        let sonOne = try #require(node(result, "@I15@"))
        let sonTwo = try #require(node(result, "@I16@"))
        let spouse = try #require(node(result, "@I14@"))

        #expect(root.isRoot)
        #expect(root.generation == 0)
        #expect(father.generation == -1 && mother.generation == -1)
        #expect(father.position.y < root.position.y)
        #expect(mother.position.y == father.position.y)
        // Father left, mother right.
        #expect(father.position.x < mother.position.x)
        // Root sits under the midpoint of its parents.
        #expect(abs((father.position.x + mother.position.x) / 2 - root.position.x) < 0.5)

        #expect(sonOne.generation == 1 && sonTwo.generation == 1)
        #expect(sonOne.position.y > root.position.y)
        // File order: I15 before I16, left to right.
        #expect(sonOne.position.x < sonTwo.position.x)

        #expect(spouse.generation == 0 && spouse.isSpouseOfRoot)
        #expect(spouse.position.y == root.position.y)
        #expect(spouse.position.x > root.position.x)
    }

    @Test func generationsAreCappedBothWays() throws {
        let result = FamilyTreeLayout.layout(graph: fixtureGraph(), rootID: "@I7@",
                                             ancestorGenerations: 3,
                                             descendantGenerations: 2)
        // Three up: Eileen(-1) → David(-2) → Samuel(-3) present …
        #expect(node(result, "@I10@")?.generation == -3)
        // … Old Latta (-4) is not.
        #expect(node(result, "@I12@") == nil)
        // Two down: Grandkid (+2) present, Greatgrandkid (+3) not.
        #expect(node(result, "@I17@")?.generation == 2)
        #expect(node(result, "@I18@") == nil)
        for n in result.nodes {
            #expect((-3...2).contains(n.generation))
        }

        // Tighter caps shrink the picture accordingly.
        let tight = FamilyTreeLayout.layout(graph: fixtureGraph(), rootID: "@I7@",
                                            ancestorGenerations: 1,
                                            descendantGenerations: 1)
        #expect(node(tight, "@I5@") == nil)
        #expect(node(tight, "@I17@") == nil)
        #expect(node(tight, "@I3@") != nil)
        #expect(node(tight, "@I15@") != nil)
    }

    @Test func personWithNoRecordedParentsStillLaysOut() throws {
        let result = FamilyTreeLayout.layout(graph: fixtureGraph(), rootID: "@I1@")
        let root = try #require(node(result, "@I1@"))
        #expect(root.isRoot)
        #expect(result.nodes.filter { $0.generation < 0 }.isEmpty)
        // Two marriages → two independent root/spouse lines. The spouses
        // are never connected to each other.
        let spouses = result.nodes.filter(\.isSpouseOfRoot)
        #expect(spouses.map(\.personID) == ["@I2@", "@I8@"])
        #expect(result.edges.filter { $0.kind == .spouse }.count == 2)
        #expect(Set(result.nodes(inGeneration: 1).map(\.personID)) == ["@I3@", "@I9@"])
        let first = try #require(node(result, "@I2@"))
        let second = try #require(node(result, "@I8@"))
        let spouseEdges = result.edges.filter { $0.kind == .spouse }
        #expect(spouseEdges.contains {
            abs($0.from.x - (root.position.x + 75)) < 0.5
                && abs($0.to.x - (first.position.x - 75)) < 0.5
        })
        #expect(spouseEdges.contains {
            abs($0.from.x - (second.position.x + 75)) < 0.5
                && abs($0.to.x - (root.position.x - 75)) < 0.5
        })

        let firstChild = try #require(node(result, "@I3@"))
        let secondChild = try #require(node(result, "@I9@"))
        let childEdges = result.edges.filter { $0.kind == .child }
        let firstAnchorX = (root.position.x + first.position.x) / 2
        let secondAnchorX = (root.position.x + second.position.x) / 2
        #expect(childEdges.contains {
            abs($0.to.x - firstChild.position.x) < 0.5
                && abs($0.from.x - firstAnchorX) < 0.5
        })
        #expect(childEdges.contains {
            abs($0.to.x - secondChild.position.x) < 0.5
                && abs($0.from.x - secondAnchorX) < 0.5
        })
        // Root is the top row: nothing above the margin.
        let minTop = result.nodes.map { $0.position.y - 97 }.min() ?? -1
        #expect(abs(minTop - 40) < 0.5)
    }

    @Test func loneParentGetsAnElbowFromTheirOwnCard() throws {
        // Samuel (I10) has a father (I12) but no mother on record.
        let result = FamilyTreeLayout.layout(graph: fixtureGraph(), rootID: "@I10@")
        let father = try #require(node(result, "@I12@"))
        let root = try #require(node(result, "@I10@"))
        let elbow = try #require(result.edges.first {
            $0.kind == .child && abs($0.to.x - root.position.x) < 0.5
        })
        #expect(abs(elbow.from.x - father.position.x) < 0.5)
        #expect(elbow.from.y < elbow.to.y)
        #expect(abs(elbow.to.y - (root.position.y - 97)) < 0.5)
    }

    @Test func everyChildEdgeEndsAtTheChildsTopEdge() {
        let result = FamilyTreeLayout.layout(graph: fixtureGraph(), rootID: "@I7@")
        let tops = Set(result.nodes.map { Int(($0.position.y - 97).rounded()) })
        for edge in result.edges where edge.kind == .child {
            #expect(edge.from.y < edge.to.y)
            #expect(tops.contains(Int(edge.to.y.rounded())))
        }
        // Everything sits inside the reported canvas.
        for n in result.nodes {
            #expect(n.position.x - 75 >= 39.5 && n.position.x + 75 <= result.size.width + 0.5)
            #expect(n.position.y - 97 >= 39.5 && n.position.y + 97 <= result.size.height + 0.5)
        }
    }

    @Test func unknownRootIsEmptyAndNodeIDsAreUnique() {
        #expect(FamilyTreeLayout.layout(graph: fixtureGraph(), rootID: "@NOPE@") == .empty)
        let result = FamilyTreeLayout.layout(graph: fixtureGraph(), rootID: "@I7@")
        #expect(Set(result.nodes.map(\.id)).count == result.nodes.count)
    }

    @Test func descendantCycleDoesNotRenderTheRootAsItsOwnGrandchild() {
        let graph = GedcomFamilyGraph(gedcomText: """
        0 @I1@ INDI
        1 NAME Root /Person/
        1 FAMS @F1@
        0 @I2@ INDI
        1 NAME Child /Person/
        1 FAMS @F2@
        0 @F1@ FAM
        1 HUSB @I1@
        1 CHIL @I2@
        0 @F2@ FAM
        1 HUSB @I2@
        1 CHIL @I1@
        0 TRLR
        """)
        let result = FamilyTreeLayout.layout(
            graph: graph, rootID: "@I1@", descendantGenerations: 2)
        #expect(result.nodes.map(\.personID) == ["@I1@", "@I2@"])
        #expect(result.nodes.filter { $0.personID == "@I1@" }.count == 1)
    }

    @Test func placLineDoesNotDisturbDates() throws {
        let john = try #require(fixtureGraph().people["@I1@"])
        #expect(john.birthDate == "1 JAN 1900")
        #expect(john.deathDate == "1970")
    }
}

// MARK: - Years / sorting (pure helpers on the model)

@Suite("Family tree model — text helpers")
struct FamilyTreeModelTextTests {

    @Test func lifeDatesNeverClaimLiving() {
        #expect(FamilyTreeLiveModel.years(birth: "4 MAR 1929", death: "2008") == "1929–2008")
        #expect(FamilyTreeLiveModel.years(birth: "1959", death: nil) == "b. 1959")
        #expect(FamilyTreeLiveModel.years(birth: nil, death: "12 DEC 2008") == "d. 2008")
        #expect(FamilyTreeLiveModel.years(birth: "ABT 1902", death: nil) == "b. 1902")
        // No year anywhere → raw text shown verbatim, prefixed.
        #expect(FamilyTreeLiveModel.years(birth: "BEF 1 MAY", death: nil) == "b. BEF 1 MAY")
        #expect(FamilyTreeLiveModel.years(birth: nil, death: nil) == nil)
    }

    @Test func sortedBySurnameThenGivenNameUnknownSurnameLast() {
        let graph = GedcomFamilyGraph(gedcomText: """
        0 @I1@ INDI
        1 NAME Zed /Breen/
        0 @I2@ INDI
        1 NAME Adam /Latta/
        0 @I3@ INDI
        1 NAME Amy /Breen/
        0 @I4@ INDI
        1 NAME NoSurname
        """)
        let names = FamilyTreeLiveModel.sorted(Array(graph.people.values)).map(\.name)
        #expect(names == ["Amy Breen", "Zed Breen", "Adam Latta", "NoSurname"])
    }
}

// MARK: - Model behaviour

@Suite("Family tree model — selection and search")
@MainActor
struct FamilyTreeModelBehaviourTests {

    private func liveModel() -> FamilyTreeLiveModel {
        let model = FamilyTreeLiveModel(
            originalsDirectory: URL(fileURLWithPath: "/nonexistent/never-read"))
        model.install(graph: fixtureGraph())
        return model
    }

    @Test func installingAGraphGoesLiveAndLaysOutTheFirstSortedPerson() {
        let model = liveModel()
        #expect(model.isLive)
        #expect(model.loadState == .loaded(live: true))
        #expect(model.peopleCount == 18)
        // Sorted list begins with the Breens; the selection does NOT follow
        // it any more (2026-08-28): with nothing remembered the tree opens
        // on its first root — no _VS_ROOT here, so the first INDI, John (I1).
        #expect(model.filteredPeople.first?.surname == "Breen")
        #expect(model.selectedID == "@I1@")
        #expect(!model.scene.cards.isEmpty)
        #expect(model.scene.cards.contains { $0.isRoot })
    }

    @Test func selectionRelayoutsAndListsRelatives() throws {
        let model = liveModel()
        model.select("@I7@")
        #expect(model.selectedPerson?.name == "Richard Breen")
        #expect(model.selectedPerson?.years == "b. 1959")
        #expect(model.selectedRelatives.parents.map(\.name) == ["Richard Hardin Breen", "Eileen Latta"])
        #expect(model.selectedRelatives.spouses.map(\.name) == ["Donna Hudson"])
        #expect(model.selectedRelatives.children.map(\.name) == ["Son Breen One", "Son Breen Two"])
        #expect(model.selectedRelatives.siblings.map(\.name) == ["Jim Breen"])
        let root = try #require(model.scene.cards.first { $0.isRoot })
        #expect(root.person.id == "@I7@")
        #expect(root.person.sex == .male)
        // I3,I4 (-1) + I1,I2,I5,I6 (-2) + I10,I11 (-3) = 8 ancestors,
        // + root + Donna + two sons + one grandchild = 13 cards.
        #expect(model.scene.cards.count == 13)
    }

    @Test func twoMarriagesShowBothSpouses() {
        let model = liveModel()
        model.select("@I1@")
        #expect(model.selectedRelatives.spouses.map(\.name) == ["Mary Lamb", "Anne Hudson"])
        #expect(model.scene.cards.filter { $0.person.id == "@I2@" || $0.person.id == "@I8@" }.count == 2)
    }

    @Test func unknownSelectionIsIgnored() {
        let model = liveModel()
        model.select("@I7@")
        model.select("@ZZZ@")
        #expect(model.selectedID == "@I7@")
    }

    @Test func focusMatchesExactNameThenSurname() {
        let model = liveModel()
        #expect(model.focus(onName: "donna hudson"))
        #expect(model.selectedID == "@I14@")
        // Surname fallback: "the Lattas" → first Latta in sort order.
        #expect(model.focus(onName: "the Lattas"))
        #expect(model.selectedPerson?.surname == "Latta")
        #expect(model.selectedPerson?.name == "David McGill Latta")
        // Nothing matches → false, and the miss is honest: no card selected
        // (never the previous or sorted-first person), name in the filter.
        #expect(!model.focus(onName: "Nobody Here"))
        #expect(model.selectedID == nil)
        #expect(model.selectedPerson == nil)
        #expect(model.scene.cards.isEmpty)
        #expect(!model.focus(onName: "   "))
    }

    /// 2026-08-27 live bug: People tab → "Show Rick in Family Tree" opened on
    /// Jane Allen (surname-alphabetical first) because the miss was silent.
    @Test func unmatchedFocusIsAnHonestMissNotTheDefaultPerson() {
        let model = liveModel()
        let sortedFirst = model.filteredPeople.first?.id
        model.select("@I7@")
        #expect(!model.focus(onName: "Rick"))
        // No card pretends to be the answer — not the previous, not the first.
        #expect(model.selectedID == nil)
        #expect(sortedFirst != nil)
        #expect(model.selectedPerson == nil)
        // The miss is visible: name in the filter, empty list, notice set.
        #expect(model.searchText == "Rick")
        #expect(model.filteredPeople.isEmpty)
        #expect(model.focusMissName == "Rick")
        #expect(model.focusMissNotice == "No one named \u{201C}Rick\u{201D} in the tree")
        // Next search edit clears the notice.
        model.searchText = "Breen"
        #expect(model.focusMissNotice == nil)
        #expect(!model.filteredPeople.isEmpty)
    }

    /// Codex #755: a hit after a miss must restore a consistent list — the
    /// filter WE set is cleared so the selected person is visible.
    @Test func hitAfterMissClearsTheMissFilterByNameAndByID() {
        let model = liveModel()
        #expect(!model.focus(onName: "Nobody Here"))
        #expect(model.searchText == "Nobody Here")
        #expect(model.focus(onName: "Donna Hudson"))
        #expect(model.selectedID == "@I14@")
        #expect(model.searchText.isEmpty)
        #expect(model.filteredPeople.contains { $0.id == "@I14@" })
        #expect(model.focusMissNotice == nil)

        #expect(!model.focus(onName: "Nobody Here"))
        #expect(model.focus(onID: "@I7@"))
        #expect(model.selectedID == "@I7@")
        #expect(model.searchText.isEmpty)
        #expect(model.filteredPeople.contains { $0.id == "@I7@" })
        #expect(model.focusMissNotice == nil)

        // A filter the USER typed survives a hit.
        model.searchText = "Breen"
        #expect(model.focus(onName: "Donna Hudson"))
        #expect(model.searchText == "Breen")
    }

    @Test func focusBridgesPeopleTabNicknameThroughProfileAliases() {
        let model = liveModel()
        let profiles = [POIProfile(name: "Rick", referencePath: "/synthetic",
                                   aliases: ["Richard Breen"])]
        // Fixture has Richard Breen (@I7@) AND Richard Hardin Breen (@I3@):
        // the alias is a complete canonical name, so exactly one resolves.
        #expect(model.focus(onName: "Rick", profiles: profiles))
        #expect(model.selectedID == "@I7@")
        #expect(model.focusMissNotice == nil)
        #expect(model.searchText.isEmpty)
        // Same profiles, a name they don't bridge → still an honest miss.
        #expect(!model.focus(onName: "Goldilocks", profiles: profiles))
        #expect(model.selectedID == nil)
        #expect(model.focusMissName == "Goldilocks")
    }

    /// Codex #756: the configured identity beats a literal GEDCOM "Rick".
    @Test func profileAliasBeatsConflictingLiteralGedcomName() {
        let model = liveModel()
        model.install(graph: GedcomFamilyGraph(gedcomText: """
        0 @I1@ INDI
        1 NAME Rick /Smith/
        0 @I2@ INDI
        1 NAME Richard /Breen/
        0 TRLR
        """))
        // Without profiles the literal is the only "Rick".
        #expect(model.focus(onName: "Rick"))
        #expect(model.selectedID == "@I1@")
        let profiles = [POIProfile(name: "Rick", referencePath: "/synthetic",
                                   aliases: ["Richard Breen"])]
        #expect(model.focus(onName: "Rick", profiles: profiles))
        #expect(model.selectedID == "@I2@")
    }

    /// Codex #756: profile ambiguity is terminal — never the first surname
    /// holder, even when the surname exists.
    @Test func ambiguousProfileAliasIsAnHonestMissNotASurnameGuess() {
        let model = liveModel()
        model.select("@I7@")
        let profiles = [
            POIProfile(name: "David McGill Latta", referencePath: "/synthetic", aliases: ["Latta"]),
            POIProfile(name: "Eileen Latta", referencePath: "/synthetic", aliases: ["Latta"]),
        ]
        // Sanity: without profiles the surname fallback picks a Latta.
        #expect(model.focus(onName: "Latta"))
        #expect(model.selectedPerson?.surname == "Latta")
        model.select("@I7@")
        #expect(!model.focus(onName: "Latta", profiles: profiles))
        #expect(model.selectedID == nil)
        #expect(model.searchText == "Latta")
        #expect(model.focusMissNotice?.hasPrefix("More than one \u{201C}Latta\u{201D}") == true)
        // Ambiguity through the bridge itself: one alias token-matches two
        // tree people (Son Breen One / Son Breen Two).
        let shared = [POIProfile(name: "Sons", referencePath: "/synthetic",
                                 aliases: ["Son Breen"])]
        #expect(!model.focus(onName: "Sons", profiles: shared))
        #expect(model.selectedID == nil)
        #expect(model.focusMissNotice?.hasPrefix("More than one") == true)
    }

    // Director ruling 2026-08-27 (deterministic acceptance contract):
    // bare "Dad" / "Dad Breen" / "Grampa Breen" / "Dick" = Richard Harding
    // Breen Sr; "Rick" / "Dicky" / "Rich" / "Richy" = Richard Harding Breen Jr.
    // "Dad" is never a global alias of Rick (speaker-relative kinship is
    // future scope). The live GEDCOM carries both men under the SAME name
    // with only a Jr/Sr suffix, which is the shape that escaped the
    // existing tests.
    private static let juniorSeniorGedcom = """
    0 HEAD
    0 @I1@ INDI
    1 NAME Richard Harding /Breen/ Jr
    1 _FSFTID GVQV-NW3
    0 @I2@ INDI
    1 NAME Richard Harding /Breen/ Sr
    1 _FSFTID G2S4-JF4
    0 @I3@ INDI
    1 NAME Donna /Breen/
    0 TRLR
    """

    /// The People-tab profiles AFTER the data fix: each carries its formal
    /// GEDCOM name (with suffix) as an alias, and "Dad" lives only on Dad.
    private static let correctedProfiles = [
        POIProfile(name: "Rick", referencePath: "/synthetic",
                   aliases: ["Dicky", "Rich", "Richy", "Richard Harding Breen Jr"]),
        POIProfile(name: "Dad", referencePath: "/synthetic",
                   aliases: ["Grampa Breen", "Dick", "Dad Breen", "Richard Harding Breen Sr"]),
    ]

    /// The profiles as they were LIVE on 2026-08-27: "Dad" is an alias of
    /// Rick, and neither profile carries a formal GEDCOM name.
    private static let uncorrectedProfiles = [
        POIProfile(name: "Rick", referencePath: "/synthetic",
                   aliases: ["Dicky", "Dad"]),
        POIProfile(name: "Dad", referencePath: "/synthetic",
                   aliases: ["Grampa Breen", "Dick", "Dad Breen"]),
    ]

    @Test func correctedProfilesBridgeRickToJuniorAndDadToSenior() {
        let model = liveModel()
        model.install(graph: GedcomFamilyGraph(gedcomText: Self.juniorSeniorGedcom))
        let profiles = Self.correctedProfiles

        // Jr side: canonical nickname and every informal alias.
        for spelling in ["Rick", "Dicky", "Rich", "Richy"] {
            model.select("@I3@")
            #expect(model.focus(onName: spelling, profiles: profiles),
                    "\(spelling) should bridge to Jr")
            #expect(model.selectedID == "@I1@", "\(spelling) selected \(model.selectedID ?? "nil"), wanted Jr @I1@")
            #expect(model.focusMissNotice == nil)
        }
        // Sr side.
        for spelling in ["Dad", "Dad Breen", "Grampa Breen", "Dick"] {
            model.select("@I3@")
            #expect(model.focus(onName: spelling, profiles: profiles),
                    "\(spelling) should bridge to Sr")
            #expect(model.selectedID == "@I2@", "\(spelling) selected \(model.selectedID ?? "nil"), wanted Sr @I2@")
            #expect(model.focusMissNotice == nil)
        }
        // The formal names themselves still resolve directly, suffix-exact.
        #expect(model.focus(onName: "Richard Harding Breen Jr", profiles: profiles))
        #expect(model.selectedID == "@I1@")
        #expect(model.focus(onName: "Richard Harding Breen Sr", profiles: profiles))
        #expect(model.selectedID == "@I2@")
    }

    /// Pins that the DATA fix is required and the code stays honest with the
    /// live (uncorrected) shape: "Dad" is an ambiguity, never silently Jr and
    /// never the default person; "Rick" with no formal alias and no literal
    /// "Rick" in the tree is an honest miss (two Richards, no guess).
    @Test func uncorrectedLiveProfilesAreAnHonestMissNotASilentRick() {
        let model = liveModel()
        model.install(graph: GedcomFamilyGraph(gedcomText: Self.juniorSeniorGedcom))
        let profiles = Self.uncorrectedProfiles
        let sortedFirst = model.filteredPeople.first?.id
        #expect(sortedFirst != nil)

        model.select("@I3@")
        #expect(!model.focus(onName: "Dad", profiles: profiles))
        #expect(model.selectedID == nil)          // not Jr, not Sr, not previous
        #expect(model.selectedPerson == nil)
        #expect(model.searchText == "Dad")
        #expect(model.focusMissNotice?.hasPrefix("More than one \u{201C}Dad\u{201D}") == true)

        model.select("@I3@")
        #expect(!model.focus(onName: "Rick", profiles: profiles))
        #expect(model.selectedID == nil)
        #expect(model.selectedPerson == nil)
        #expect(model.focusMissName == "Rick")
        #expect(model.focusMissNotice == "No one named \u{201C}Rick\u{201D} in the tree")

        // Sanity for the same GEDCOM without any profiles: "Rick" through
        // the diminutive table hits BOTH Richards and must still be a miss,
        // never a coin flip between Jr and Sr.
        model.select("@I3@")
        #expect(!model.focus(onName: "Rick"))
        #expect(model.selectedID == nil)
    }

    /// Codex #756: a stale GEDCOM pointer is the same honest miss.
    @Test func staleRecordIDIsAnHonestMiss() {
        let model = liveModel()
        model.select("@I7@")
        #expect(!model.focus(onID: "@I999@"))
        #expect(model.selectedID == "@I7@")   // focus(onID:) itself is a pure lookup
        model.reportMissingRecord(id: "@I999@", displayName: "Great Aunt Zelda")
        #expect(model.selectedID == nil)
        #expect(model.searchText == "Great Aunt Zelda")
        #expect(model.focusMissNotice == "That record for \u{201C}Great Aunt Zelda\u{201D} isn\u{2019}t in the current tree")
        model.reportMissingRecord(id: "@I999@", displayName: nil)
        #expect(model.focusMissNotice == "That record isn\u{2019}t in the current tree")
    }

    @Test func exactGEDCOMIDFocusDoesNotGuessByDuplicateName() {
        let model = liveModel()
        #expect(model.focus(onID: "@I14@"))
        #expect(model.selectedID == "@I14@")
        #expect(!model.focus(onID: "@MISSING@"))
        #expect(model.selectedID == "@I14@")
    }

    @Test func searchFiltersNameSurnameAndID() {
        let model = liveModel()
        model.searchText = "latta"
        #expect(model.filteredPeople.count == 4)
        #expect(model.filteredPeople.allSatisfy { $0.surname == "Latta" })
        model.searchText = "I14"
        #expect(model.filteredPeople.map(\.name) == ["Donna Hudson"])
        model.searchText = ""
        #expect(model.filteredPeople.count == 18)
    }

    @Test func alternateNameAndFamilySearchIDCanFindImportedPerson() {
        let graph = GedcomFamilyGraph(gedcomText: """
        0 @I42@ INDI
        1 NAME Margaret /Kelly/
        1 NAME Peggy /O'Kelly/
        1 _FSFTID ABCD-123
        """)
        let model = FamilyTreeLiveModel(
            originalsDirectory: URL(fileURLWithPath: "/nonexistent/never-read"))
        model.install(graph: graph)

        model.searchText = "Peggy"
        #expect(model.filteredPeople.map(\.name) == ["Margaret Kelly"])
        model.searchText = "O'Kelly"
        #expect(model.filteredPeople.map(\.name) == ["Margaret Kelly"])
        model.searchText = "ABCD-123"
        #expect(model.filteredPeople.map(\.name) == ["Margaret Kelly"])
        #expect(model.focus(onName: "Peggy O'Kelly"))
        #expect(model.selectedID == "@I42@")
    }

    @Test func photoOverrideWinsOverProviderAndProviderIsConsulted() {
        var asked: [String] = []
        let provided = NSImage(size: NSSize(width: 2, height: 2))
        let model = FamilyTreeLiveModel(
            originalsDirectory: URL(fileURLWithPath: "/nonexistent/never-read"),
            photoProvider: { person in
                asked.append(person.id)
                return person.id == "@I14@" ? provided : nil
            })
        model.install(graph: fixtureGraph())
        model.select("@I7@")
        #expect(asked.contains("@I14@"))
        #expect(model.scene.cards.first { $0.person.id == "@I14@" }?.photo === provided)
        #expect(model.scene.cards.first { $0.person.id == "@I7@" }?.photo == nil)

        let override = NSImage(size: NSSize(width: 3, height: 3))
        model.setPhotoOverride(override, for: "@I14@")
        #expect(model.scene.cards.first { $0.person.id == "@I14@" }?.photo === override)
    }

    @Test func reinstallKeepsSelectionWhenThePersonSurvives() {
        let model = liveModel()
        model.select("@I7@")
        model.install(graph: fixtureGraph())
        #expect(model.selectedID == "@I7@")
        model.install(graph: GedcomFamilyGraph(gedcomText: "0 @X@ INDI\n1 NAME Only /One/"))
        #expect(model.selectedID == "@X@")
    }
}

// MARK: - Profile snapshot (isolation)

/// `POIProfile.cachedSnapshot(root:)` feeds the hint path. Everything here
/// runs against an injected temp root — never the real POI store.
@Suite("Family tree model — profile snapshot isolation")
@MainActor
struct FamilyTreeProfileSnapshotTests {

    private func liveModel() -> FamilyTreeLiveModel {
        let model = FamilyTreeLiveModel(
            originalsDirectory: URL(fileURLWithPath: "/nonexistent/never-read"))
        model.install(graph: fixtureGraph())
        return model
    }

    private func writeProfile(_ profile: POIProfile, in root: URL) throws {
        let folder = root.appendingPathComponent(profile.name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(profile)
            .write(to: folder.appendingPathComponent("profile.json"))
    }

    private func sandbox() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ft-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func duplicateAliasesAcrossProfilesResolveToAmbiguityNotACrash() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeProfile(POIProfile(name: "Daniel Breen", referencePath: "", aliases: ["birthday boy"]), in: root)
        try writeProfile(POIProfile(name: "Matthew Breen", referencePath: "", aliases: ["birthday boy"]), in: root)
        let profiles = POIProfile.cachedSnapshot(root: root)
        #expect(profiles.map(\.name) == ["Daniel Breen", "Matthew Breen"])
        let model = liveModel()
        #expect(!model.focus(onName: "birthday boy", profiles: profiles))
        #expect(model.selectedID == nil)
        #expect(model.focusMissNotice?.hasPrefix("More than one") == true)
    }

    @Test func corruptProfileEntryIsSkipped() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeProfile(POIProfile(name: "Rick", referencePath: "", aliases: ["Richard Breen"]), in: root)
        let bad = root.appendingPathComponent("Broken", isDirectory: true)
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: bad.appendingPathComponent("profile.json"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("NoProfile"),
                                                withIntermediateDirectories: true)
        let profiles = POIProfile.cachedSnapshot(root: root)
        #expect(profiles.map(\.name) == ["Rick"])
        // referencePath is healed to the folder, as listAll does.
        #expect(profiles.first.map { URL(fileURLWithPath: $0.referencePath).resolvingSymlinksInPath() }
                == root.appendingPathComponent("Rick", isDirectory: true).resolvingSymlinksInPath())
        let model = liveModel()
        #expect(model.focus(onName: "Rick", profiles: profiles))
        #expect(model.selectedID == "@I7@")
    }

    /// Poisoned state: a perfectly good profile next door (a sibling
    /// directory, a nested folder, a missing root) must not be read, and a
    /// change on disk must invalidate the cache.
    @Test func snapshotReadsOnlyTheInjectedRootAndTracksChanges() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("store", isDirectory: true)
        let poison = root.appendingPathComponent("poison", isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try writeProfile(POIProfile(name: "Rick", referencePath: "", aliases: ["Richard Breen"]), in: poison)
        try writeProfile(POIProfile(name: "Rick", referencePath: "", aliases: ["Richard Breen"]),
                         in: store.appendingPathComponent("nested", isDirectory: true))
        #expect(POIProfile.cachedSnapshot(root: store).isEmpty)
        #expect(POIProfile.cachedSnapshot(root: root.appendingPathComponent("missing")).isEmpty)

        try writeProfile(POIProfile(name: "Donna", referencePath: "", aliases: ["Goldilocks"]), in: store)
        #expect(POIProfile.cachedSnapshot(root: store).map(\.name) == ["Donna"])
        // Edit in place (bump the modification date) → re-read.
        var edited = POIProfile(name: "Donna", referencePath: "", aliases: ["Goldilocks", "Mom"])
        edited.sortOrder = 1
        try writeProfile(edited, in: store)
        let url = store.appendingPathComponent("Donna/profile.json")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)],
                                              ofItemAtPath: url.path)
        #expect(POIProfile.cachedSnapshot(root: store).first?.aliases == ["Goldilocks", "Mom"])
        try FileManager.default.removeItem(at: store.appendingPathComponent("Donna"))
        #expect(POIProfile.cachedSnapshot(root: store).isEmpty)
    }
}

// MARK: - Scale

@Suite("Family tree model — scale")
@MainActor
struct FamilyTreeScaleTests {

    /// 5,000 people chained as a pedigree: person n's father is n+1, with
    /// a mother on every other generation so both slots get exercised.
    private static func chainGedcom(count: Int) -> String {
        var lines: [String] = ["0 HEAD"]
        lines.reserveCapacity(count * 8)
        for n in 1...count {
            lines.append("0 @I\(n)@ INDI")
            lines.append("1 NAME Person\(n) /Chain\(n % 97)/")
            lines.append("1 SEX \(n % 2 == 0 ? "F" : "M")")
            lines.append("1 BIRT")
            lines.append("2 DATE \(2020 - n)")
            if n > 1 { lines.append("1 FAMS @F\(n - 1)@") }
            if n < count { lines.append("1 FAMC @F\(n)@") }
        }
        for n in 1..<count {
            lines.append("0 @F\(n)@ FAM")
            lines.append("1 HUSB @I\(n + 1)@")
            if n % 2 == 0 { lines.append("1 WIFE @M\(n)@") }
            lines.append("1 CHIL @I\(n)@")
        }
        for n in stride(from: 2, to: count, by: 2) {
            lines.append("0 @M\(n)@ INDI")
            lines.append("1 NAME Mother\(n) /Maternal/")
            lines.append("1 SEX F")
            lines.append("1 FAMS @F\(n)@")
        }
        lines.append("0 TRLR")
        return lines.joined(separator: "\n")
    }

    @Test func fiveThousandPersonPedigreeLaysOutWithinBudget() {
        let graph = GedcomFamilyGraph(gedcomText: Self.chainGedcom(count: 5_000))
        #expect(graph.people.count >= 5_000)

        let clock = ContinuousClock()
        let elapsed = clock.measure {
            // Install = sort + filter + first layout; then walk 200 roots
            // up the chain, relaying out each time (the user clicking).
            let model = FamilyTreeLiveModel(
                originalsDirectory: URL(fileURLWithPath: "/nonexistent/never-read"))
            model.install(graph: graph)
            for n in stride(from: 1, through: 5_000, by: 25) {
                model.select("@I\(n)@")
                #expect(model.scene.cards.count >= 1)
            }
            model.searchText = "Person49"
            #expect(!model.filteredPeople.isEmpty)
        }
        #expect(elapsed < .milliseconds(500), "layout + install took \(elapsed)")

        // Deep in the chain every ancestor slot is filled on the paternal
        // side and the cap still holds.
        let mid = FamilyTreeLayout.layout(graph: graph, rootID: "@I2500@")
        #expect(mid.nodes.map(\.generation).min() == -3)
        #expect(mid.nodes.count <= 15)
    }

    // Rick 2026-08-28: "if navigating the tree hangs we need to know
    // where/when". The install total is ALWAYS logged with the people
    // count; individual steps only when they exceed 100 ms.
    @Test func fiveThousandPersonInstallLogsTheTotalLine() {
        let graph = GedcomFamilyGraph(gedcomText: Self.chainGedcom(count: 5_000))
        let sink = InMemoryLogSink()
        let model = FamilyTreeLiveModel(
            originalsDirectory: URL(fileURLWithPath: "/nonexistent/never-read"))
        withAppLog(sink) { model.install(graph: graph) }
        let totals = sink.lines.filter { $0.contains("[family-tree] install total took ") }
        #expect(totals.count == 1, "got: \(sink.joined)")
        #expect(totals.first?.hasSuffix(" ms (\(graph.people.count) people)") == true, "got: \(totals)")
        #expect(model.peopleCount == graph.people.count)
    }

    @Test func fastStepsLogNothingBesidesTheInstallTotal() {
        let sink = InMemoryLogSink()
        let model = FamilyTreeLiveModel(
            originalsDirectory: URL(fileURLWithPath: "/nonexistent/never-read"))
        withAppLog(sink) {
            model.install(graph: fixtureGraph())
            model.select("@I7@")
            model.searchText = "Breen"
            model.focusHome()
        }
        let timing = sink.lines.filter { $0.contains("[family-tree]") && $0.contains(" took ") }
        // Exactly the install total; select / search / Home on 18 people
        // are far under the 100 ms threshold and must stay silent.
        #expect(timing.count == 1, "got: \(timing)")
        #expect(timing.first?.hasPrefix("[family-tree] install total took ") == true)
        #expect(FamilyTreeLiveModel.slowStepThreshold == .milliseconds(100))
    }

    @Test func slowStepLineIsOnlyWrittenAboveTheThreshold() {
        let sink = InMemoryLogSink()
        withAppLog(sink) {
            FamilyTreeLiveModel.logStep("select: relayout", took: .milliseconds(99), people: 7)
            FamilyTreeLiveModel.logStep("select: relayout", took: .milliseconds(100), people: 7)
            FamilyTreeLiveModel.logStep("select: relayout", took: .milliseconds(1_234), people: 7)
            FamilyTreeLiveModel.logStep("install total", took: .milliseconds(3), people: 7, always: true)
        }
        #expect(sink.lines == ["[family-tree] select: relayout took 1234 ms (7 people)",
                               "[family-tree] install total took 3 ms (7 people)"], "got: \(sink.lines)")
    }
}

// MARK: - Isolation

@Suite("Family tree model — loader isolation")
@MainActor
struct FamilyTreeIsolationTests {

    @Test func emptyInjectedDirectoryFallsBackToDemoAndIgnoresNeighbours() throws {
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FamilyTreeLive-\(UUID().uuidString)")
        let originals = sandbox.appendingPathComponent("originals")
        let poison = sandbox.appendingPathComponent("poison")
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: poison, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        // A perfectly good GEDCOM right next door must not be found.
        try fixtureGedcom.write(to: poison.appendingPathComponent("family.ged"),
                                atomically: true, encoding: .utf8)

        let model = FamilyTreeLiveModel(originalsDirectory: originals)
        #expect(model.loadState == .idle)
        model.loadNow()

        #expect(model.loadState == .loaded(live: false))
        #expect(!model.isLive)
        #expect(model.peopleCount == FamilyTreeDemoData.people.count)
        #expect(model.selectedID == FamilyTreeDemoData.rootID)
        #expect(model.selectedPerson?.name == "Richard Breen")
        #expect(model.scene.cards.count == FamilyTreeDemoData.people.count)
        #expect(model.selectedRelatives.isEmpty)

        // Demo focus still works for the People-tab / Hallie hint path.
        #expect(model.focus(onName: "donna hudson"))
        #expect(model.selectedID == "demo-donna")
        #expect(!model.focus(onName: "Son Breen One"))

        // Dropping a file in and reloading flips to live.
        try fixtureGedcom.write(to: originals.appendingPathComponent("family.ged"),
                                atomically: true, encoding: .utf8)
        model.loadNow()
        #expect(model.loadState == .loaded(live: true))
        #expect(model.peopleCount == 18)
    }

    @Test func missingDirectoryIsDemoNotACrash() {
        let model = FamilyTreeLiveModel(
            originalsDirectory: URL(fileURLWithPath: "/nonexistent/FamilyTree-\(UUID().uuidString)"))
        model.loadNow()
        #expect(model.loadState == .loaded(live: false))
        #expect(model.scene.size == CGSize(width: 1200, height: 920))
    }
}

} // FamilyTreeLiveModelTests
