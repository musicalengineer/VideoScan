import Testing
import Foundation
@testable import VideoScanCore

// "show X's family tree" summaries: person neighbourhood + walks, surname
// roll-up, whole-tree overview. Synthetic tree, deterministic prose.
struct ArchivistFamilyTreePolicyTests {

    static let tree = """
    0 HEAD
    0 @I1@ INDI
    1 NAME Arthur /Stone/ Sr
    1 SEX M
    1 BIRT
    2 DATE 4 Mar 1901
    1 FAMS @F1@
    0 @I2@ INDI
    1 NAME Betty /Stone/
    1 SEX F
    1 FAMS @F1@
    0 @I3@ INDI
    1 NAME Arthur /Stone/ Jr
    1 SEX M
    1 BIRT
    2 DATE 1930
    1 FAMC @F1@
    1 FAMS @F2@
    0 @I4@ INDI
    1 NAME Clara /Stone/
    1 SEX F
    1 FAMC @F1@
    0 @I5@ INDI
    1 NAME Dora /Hill/
    1 SEX F
    1 FAMS @F2@
    0 @I6@ INDI
    1 NAME Eve /Stone/
    1 SEX F
    1 BIRT
    2 DATE ABT 1960
    1 FAMC @F2@
    1 FAMS @F3@
    0 @I7@ INDI
    1 NAME Finn /Stone/
    1 SEX M
    1 BIRT
    2 DATE 1990
    1 FAMC @F3@
    0 @I8@ INDI
    1 NAME Loner /Moss/
    1 SEX M
    0 @F1@ FAM
    1 HUSB @I1@
    1 WIFE @I2@
    1 CHIL @I3@
    1 CHIL @I4@
    0 @F2@ FAM
    1 HUSB @I3@
    1 WIFE @I5@
    1 CHIL @I6@
    0 @F3@ FAM
    1 WIFE @I6@
    1 CHIL @I7@
    0 TRLR
    """

    let graph = GedcomFamilyGraph(gedcomText: tree)

    @Test func personSummaryListsNeighbourhoodAndWalksBothWays() {
        let summary = ArchivistFamilyTreePolicy.summary(of: graph.people["@I6@"]!, in: graph)
        #expect(summary.parents.map(\.name) == ["Arthur Stone Jr", "Dora Hill"])
        #expect(summary.grandparents.map(\.name) == ["Arthur Stone Sr", "Betty Stone"])
        #expect(summary.spouses.isEmpty)
        #expect(summary.children.map(\.name) == ["Finn Stone"])
        #expect(summary.siblings.isEmpty)
        #expect(summary.ancestorCount == 4)
        #expect(summary.ancestorGenerations == 2)
        #expect(summary.descendantCount == 1)
        #expect(summary.descendantGenerations == 1)

        let answer = ArchivistFamilyTreePolicy.answer(for: summary)
        #expect(answer.state == .answered)
        #expect(answer.text == "Eve Stone's family tree — parents: Arthur Stone Jr and Dora Hill; "
                + "grandparents: Arthur Stone Sr, Betty Stone; 1 child: Finn Stone; "
                + "4 recorded ancestors across 2 generations and 1 recorded descendant across 1 generation.")
        #expect(answer.basis == ArchivistBiographyPolicy.gedcomBasis)
        #expect(answer.catalogPersonName == "Eve Stone")

        let jr = ArchivistFamilyTreePolicy.summary(personID: "@I3@", in: graph)
        #expect(jr.text.contains("1 sibling: Clara Stone"))
        #expect(jr.text.contains("married to Dora Hill"))
        #expect(jr.text.contains("2 recorded ancestors across 1 generation and 2 recorded descendants across 2 generations"))
    }

    @Test func personWithNoLinksIsHonestAndUnknownPointerFailsClosed() {
        let loner = ArchivistFamilyTreePolicy.summary(personID: "@I8@", in: graph)
        #expect(loner.state == .missingFact)
        #expect(loner.text == "Loner Moss is in the family tree, but it records no parents, spouse, children, or siblings for them.")

        let gone = ArchivistFamilyTreePolicy.summary(personID: "@I99@", in: graph)
        #expect(gone.state == .notFound)
    }

    @Test func surnameRollUpCountsGenerationsAndBirthSpan() throws {
        let summary = try #require(ArchivistFamilyTreePolicy.summary(surname: "the Stones", in: graph))
        #expect(summary.surname == "Stone")
        #expect(summary.people.count == 6)
        #expect(summary.earliestBorn?.name == "Arthur Stone Sr")
        #expect(summary.latestBorn?.name == "Finn Stone")
        #expect(summary.generations == 4)
        let answer = ArchivistFamilyTreePolicy.answer(for: summary)
        #expect(answer.text == "The family tree records 6 people with the surname Stone — spanning 4 generations; "
                + "earliest born 1901 (Arthur Stone Sr); latest born 1990 (Finn Stone). "
                + "They are: Arthur Stone Jr, Arthur Stone Sr, Betty Stone, Clara Stone, Eve Stone, Finn Stone.")
        #expect(ArchivistFamilyTreePolicy.summary(surname: "Nobody", in: graph) == nil)
    }

    @Test func overviewNeverPicksAPerson() {
        let overview = ArchivistFamilyTreePolicy.overview(in: graph)
        #expect(overview.state == .answered)
        #expect(overview.text.hasPrefix(
            "The family tree records 8 people, with birth years from 1901 to 1990; "
            + "most common surnames: Stone (6), Hill (1), Moss (1)."))
        #expect(overview.text.contains("Tell me whose tree you want"))
        #expect(overview.catalogPersonName == nil)

        let empty = ArchivistFamilyTreePolicy.overview(in: GedcomFamilyGraph(gedcomText: "0 HEAD\n0 TRLR"))
        #expect(empty.state == .missingFact)
    }
}
