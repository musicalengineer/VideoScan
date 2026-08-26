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

    @Test func rootPersonIsTheFirstINDIInFileOrder() {
        let graph = GedcomFamilyGraph(gedcomText: Self.sample)
        #expect(graph.rootPersonID == "@I1@")
        #expect(graph.rootPerson?.name == "Arthur Stone Sr")
        #expect(GedcomFamilyGraph(gedcomText: "0 HEAD\n0 TRLR").rootPersonID == nil)
    }

    @Test func namedLikeIsDiminutiveAndSuffixTolerantAndReturnsAmbiguity() {
        let graph = GedcomFamilyGraph(gedcomText: Self.sample)
        // "art stone" is not a diminutive we vouch for; "arthur stone" hits
        // both Sr and Jr (suffixes ignored) and BOTH come back, name order.
        #expect(graph.people(namedLike: "Arthur Stone").map(\.name) == ["Arthur Stone Jr", "Arthur Stone Sr"])
        #expect(graph.people(namedLike: "arthur stone jr").map(\.name) == ["Arthur Stone Jr"])
        #expect(graph.people(namedLike: "Betty Stone").map(\.name) == ["Betty Stone"])
        // Diminutive expansion on the typed side; middle names tolerated.
        let fs = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME Richard Harding /Breen/ Jr
        0 @I2@ INDI
        1 NAME Richard Harding /Breen/ Sr
        0 @I3@ INDI
        1 NAME Joanne /Breen/
        0 TRLR
        """)
        #expect(fs.people(namedLike: "Rick Breen").map(\.id) == ["@I1@", "@I2@"])
        #expect(fs.people(namedLike: "Ann Breen").isEmpty)   // never substring
        #expect(fs.people(namedLike: "").isEmpty)
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

    @Test func familySearchAlternateNamesAndStableIDRemainSearchable() throws {
        let g = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME Alice Mae /Stone/
        1 NAME Alice /River/
        1 NAME Alice /River/
        1 _FSFTID gvqv-nw3
        0 TRLR
        """)

        let person = try #require(g.people["@I1@"])
        #expect(person.name == "Alice Mae Stone")
        #expect(person.surname == "Stone")
        #expect(person.alternateNames == ["Alice River"])
        #expect(person.alternateSurnames == ["River"])
        #expect(person.familySearchID == "GVQV-NW3")
        #expect(
            g.people(matching: "Alice River").map(\.id) == ["@I1@"]
        )
        #expect(
            g.people(matching: "gvqv-nw3").map(\.id) == ["@I1@"]
        )
        #expect(
            g.people(withSurname: "Rivers").map(\.id) == ["@I1@"]
        )
    }

    @Test func multipleParentFamiliesArePreservedInsteadOfLastOneWinning() throws {
        let g = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME Child /River/
        1 FAMC
        1 FAMC @F-BIRTH@
        1 FAMC @F-ADOPT@
        0 @I2@ INDI
        1 NAME Birth /Father/
        0 @I3@ INDI
        1 NAME Birth /Mother/
        0 @I4@ INDI
        1 NAME Adoptive /Father/
        0 @I5@ INDI
        1 NAME Adoptive /Mother/
        0 @I6@ INDI
        1 NAME Birth /Sibling/
        0 @I7@ INDI
        1 NAME Adoptive /Sibling/
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
        """)

        let child = try #require(g.people["@I1@"])
        #expect(child.childOfFamily == "@F-BIRTH@")
        #expect(
            child.childOfFamilies == ["@F-BIRTH@", "@F-ADOPT@"]
        )
        #expect(
            g.relatives(.father, of: child).map(\.id) == ["@I2@", "@I4@"]
        )
        #expect(
            g.relatives(.mother, of: child).map(\.id) == ["@I3@", "@I5@"]
        )
        #expect(
            g.relatives(.siblings, of: child).map(\.id) == ["@I6@", "@I7@"]
        )
    }

    @Test func fileImportRequiresACompleteGEDCOMEnvelope() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GedcomEnvelope-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let complete = directory.appendingPathComponent("complete.ged")
        let missingTrailer = directory.appendingPathComponent("missing-trailer.ged")
        let missingHeader = directory.appendingPathComponent("missing-header.ged")
        try "\u{feff}0 HEAD\n0 @I1@ INDI\n1 NAME Complete /Person/\n0 TRLR\n"
            .write(to: complete, atomically: true, encoding: .utf8)
        try "0 HEAD\n0 @I1@ INDI\n1 NAME Partial /Person/\n"
            .write(to: missingTrailer, atomically: true, encoding: .utf8)
        try "0 @I1@ INDI\n1 NAME Headerless /Person/\n0 TRLR\n"
            .write(to: missingHeader, atomically: true, encoding: .utf8)

        #expect(GedcomFamilyGraph(fileURL: complete)?.people.count == 1)
        #expect(GedcomFamilyGraph(fileURL: missingTrailer) == nil)
        #expect(GedcomFamilyGraph(fileURL: missingHeader) == nil)
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

    @Test func levelZeroBoundaryClearsPendingEventState() {
        let g = GedcomFamilyGraph(gedcomText: """
        0 @I1@ INDI
        1 NAME First /Person/
        1 BIRT
        2 PLAC Albany, New York
        0 @I2@ INDI
        1 NAME Second /Person/
        2 PLAC Must Not Leak
        0 TRLR
        """)
        #expect(g.people["@I1@"]?.birthPlace == "Albany, New York")
        #expect(g.people["@I2@"]?.birthPlace == nil)
        #expect(g.people["@I2@"]?.deathPlace == nil)
    }

    @Test func familyUnitsKeepChildrenWithTheirRecordedMarriage() throws {
        let g = GedcomFamilyGraph(gedcomText: """
        0 @I1@ INDI
        1 NAME Root /Person/
        1 FAMS @F1@
        1 FAMS @F2@
        0 @I2@ INDI
        1 NAME First /Spouse/
        0 @I3@ INDI
        1 NAME Second /Spouse/
        0 @I4@ INDI
        1 NAME First /Child/
        0 @I5@ INDI
        1 NAME Second /Child/
        0 @F1@ FAM
        1 HUSB @I1@
        1 WIFE @I2@
        1 CHIL @I4@
        0 @F2@ FAM
        1 HUSB @I1@
        1 WIFE @I3@
        1 CHIL @I5@
        0 TRLR
        """)
        let root = try #require(g.people["@I1@"])
        let units = g.familyUnits(of: root)
        #expect(units.map { $0.spouse?.id } == ["@I2@", "@I3@"])
        #expect(units.map { $0.children.map(\.id) } == [["@I4@"], ["@I5@"]])
    }

    @Test func familyUnitsRejectDanglingAndSelfReferentialPointers() throws {
        let g = GedcomFamilyGraph(gedcomText: """
        0 @I1@ INDI
        1 NAME Root /Person/
        1 FAMS @F-DANGLING@
        1 FAMS @F-SELF-SPOUSE@
        1 FAMS @F-VALID@
        0 @I2@ INDI
        1 NAME Other /Spouse/
        0 @I3@ INDI
        1 NAME Valid /Child/
        0 @I4@ INDI
        1 NAME Invented /Child/
        0 @F-DANGLING@ FAM
        1 HUSB @I2@
        1 CHIL @I4@
        0 @F-SELF-SPOUSE@ FAM
        1 HUSB @I1@
        1 WIFE @I1@
        1 CHIL @I4@
        0 @F-VALID@ FAM
        1 HUSB @I1@
        1 WIFE @I2@
        1 CHIL @I1@
        1 CHIL @I3@
        0 TRLR
        """)
        let root = try #require(g.people["@I1@"])
        let units = g.familyUnits(of: root)
        #expect(units.map(\.id) == ["@F-VALID@"])
        #expect(units.first?.spouse?.id == "@I2@")
        #expect(units.first?.children.map(\.id) == ["@I3@"])
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
