import Testing
import Foundation
@testable import VideoScanCore

// GedcomFamilyGraph — happy-path contract (2026-08-07). A tiny
// synthetic three-generation tree (NO real family data in the repo —
// 2026-08-03 privacy policy). codex owns the adversarial matrix
// (malformed levels, dangling pointers, cycles, CONC/CONT names).
struct GedcomFamilyGraphTests {

    static let sample = """
    0 HEAD
    1 GEDC
    2 VERS 5.5.1
    0 @I1@ INDI
    1 NAME Arthur /Stone/ Sr
    1 SEX M
    1 BIRT
    2 DATE 4 Mar 1901
    1 DEAT
    2 DATE 12 Jun 1980
    1 FAMS @F1@
    0 @I2@ INDI
    1 NAME Betty /Stone/
    1 SEX F
    1 FAMS @F1@
    0 @I3@ INDI
    1 NAME Arthur /Stone/ Jr
    1 SEX M
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
    1 NAME Edwin /Stone/
    1 SEX M
    1 FAMC @F2@
    0 @F1@ FAM
    1 HUSB @I1@
    1 WIFE @I2@
    1 CHIL @I3@
    1 CHIL @I4@
    0 @F2@ FAM
    1 HUSB @I3@
    1 WIFE @I5@
    1 CHIL @I6@
    0 TRLR
    """

    private var graph: GedcomFamilyGraph { GedcomFamilyGraph(gedcomText: Self.sample) }

    @Test func parsesPeopleAndStripsNameSlashes() {
        let g = graph
        #expect(g.people.count == 6)
        #expect(g.people["@I1@"]?.name == "Arthur Stone Sr")
        #expect(g.people["@I5@"]?.sex == "F")
    }

    @Test func nameMatchingIsTokenAndCaseInsensitive() {
        let g = graph
        #expect(g.people(matching: "arthur").count == 2)          // Sr + Jr
        #expect(g.people(matching: "arthur jr").map(\.name) == ["Arthur Stone Jr"])
        #expect(g.people(matching: "zelda").isEmpty)
    }

    @Test func nameMatchingNeverTreatsSubstringAsIdentity() {
        let g = GedcomFamilyGraph(gedcomText: """
        0 @I1@ INDI
        1 NAME Joanne /River/
        0 @I2@ INDI
        1 NAME Ann /River/
        0 TRLR
        """)

        #expect(g.people(matching: "Ann").map(\.name) == ["Ann River"])
        #expect(g.people(matching: "Jo").isEmpty)
    }

    @Test func completeCanonicalNameWinsOverLongerTokenSubsetMatch() {
        let g = GedcomFamilyGraph(gedcomText: """
        0 @I1@ INDI
        1 NAME Zoe /River/
        0 @I2@ INDI
        1 NAME Zoe /River/ Jr
        0 TRLR
        """)

        let exactIDs = g.people(matching: "Zoe River").map(\.id)
        let broadIDs = g.people(matching: "Zoe").map(\.id)
        #expect(exactIDs == ["@I1@"]) // Exact name wins.
        #expect(broadIDs == ["@I1@", "@I2@"]) // Short name remains broad.
    }

    @Test func kinshipResolvesAcrossGenerations() throws {
        let g = graph
        let junior = try #require(g.people(matching: "arthur jr").first)
        #expect(g.relatives(.father, of: junior).map(\.name) == ["Arthur Stone Sr"])
        #expect(g.relatives(.mother, of: junior).map(\.name) == ["Betty Stone"])
        #expect(g.relatives(.sister, of: junior).map(\.name) == ["Clara Stone"])
        #expect(g.relatives(.wife, of: junior).map(\.name) == ["Dora Hill"])
        #expect(g.relatives(.son, of: junior).map(\.name) == ["Edwin Stone"])

        let edwin = try #require(g.people(matching: "edwin").first)
        #expect(g.relatives(.parents, of: edwin).map(\.name).sorted()
                == ["Arthur Stone Jr", "Dora Hill"])
        // Honest emptiness: Edwin has no recorded children.
        #expect(g.relatives(.children, of: edwin).isEmpty)
    }

    @Test func birthAndDeathDatesParse() {
        let g = graph
        let senior = g.people["@I1@"]
        #expect(senior?.birthDate == "4 Mar 1901")
        #expect(senior?.deathDate == "12 Jun 1980")
        // No recorded dates stays honestly nil.
        #expect(g.people["@I6@"]?.birthDate == nil)
    }

    @Test func colloquialRelationWords() {
        #expect(GedcomFamilyGraph.relation(fromWord: "dad") == .father)
        #expect(GedcomFamilyGraph.relation(fromWord: "Mom") == .mother)
        #expect(GedcomFamilyGraph.relation(fromWord: "kids") == .children)
        #expect(GedcomFamilyGraph.relation(fromWord: "cousin") == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func nameLookupHasExplicitHundredThousandPersonBudget() {
        var lines = ["0 HEAD"]
        lines.reserveCapacity(200_002)
        for index in 0..<100_000 {
            lines.append("0 @I\(index)@ INDI")
            lines.append(index == 99_999
                         ? "1 NAME Needle /Archivist/"
                         : "1 NAME Person\(index) /Synthetic/")
        }
        lines.append("0 TRLR")
        let largeGraph = GedcomFamilyGraph(
            gedcomText: lines.joined(separator: "\n"))

        let started = ContinuousClock.now
        let matches = largeGraph.people(matching: "Needle Archivist")
        let elapsed = started.duration(to: .now)

        #expect(matches.map(\.name) == ["Needle Archivist"])
        #expect(elapsed < .seconds(2),
                "100k GEDCOM lookup exceeded 2 seconds: \(elapsed)")
    }
}
