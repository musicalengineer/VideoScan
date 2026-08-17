import Testing
import Foundation
@testable import VideoScanCore

// Multi-hop kinship over a synthetic four-generation tree (no real family
// data). Pins: the maternal/paternal side applies at the FIRST hop, every
// answer carries its route, and a missing hop is named exactly.
struct GedcomKinshipPathTests {

    /// Zoe's maternal line goes three generations up (Mom → Nana → Great);
    /// her paternal line stops at Dad. Dad has a brother (Uncle Ted) with a
    /// daughter (cousin Cara); Mom has a sister (Aunt Sue). Zoe has a brother
    /// (Ben) whose son is Nate; Zoe's husband Owen has parents Hal and Ivy and
    /// a sister Fay.
    static let tree = """
    0 HEAD
    0 @I1@ INDI
    1 NAME Zoe /River/
    1 SEX F
    1 FAMC @F1@
    1 FAMS @F6@
    0 @I2@ INDI
    1 NAME Ben /River/
    1 SEX M
    1 FAMC @F1@
    1 FAMS @F7@
    0 @I3@ INDI
    1 NAME Dad /River/
    1 SEX M
    1 FAMC @F4@
    1 FAMS @F1@
    0 @I4@ INDI
    1 NAME Mom /Lake/
    1 SEX F
    1 FAMC @F2@
    1 FAMS @F1@
    0 @I5@ INDI
    1 NAME Nana /Brook/
    1 SEX F
    1 FAMC @F3@
    1 FAMS @F2@
    0 @I6@ INDI
    1 NAME Great /Spring/
    1 SEX F
    1 FAMS @F3@
    0 @I7@ INDI
    1 NAME Ted /River/
    1 SEX M
    1 FAMC @F4@
    1 FAMS @F5@
    0 @I8@ INDI
    1 NAME Cara /River/
    1 SEX F
    1 FAMC @F5@
    0 @I9@ INDI
    1 NAME Sue /Lake/
    1 SEX F
    1 FAMC @F2@
    0 @I10@ INDI
    1 NAME Owen /Field/
    1 SEX M
    1 FAMC @F8@
    1 FAMS @F6@
    0 @I11@ INDI
    1 NAME Hal /Field/
    1 SEX M
    1 FAMS @F8@
    0 @I12@ INDI
    1 NAME Ivy /Field/
    1 SEX F
    1 FAMS @F8@
    0 @I13@ INDI
    1 NAME Fay /Field/
    1 SEX F
    1 FAMC @F8@
    0 @I14@ INDI
    1 NAME Nate /River/
    1 SEX M
    1 FAMC @F7@
    0 @I15@ INDI
    1 NAME Gramps /River/
    1 SEX M
    1 FAMS @F4@
    0 @F1@ FAM
    1 HUSB @I3@
    1 WIFE @I4@
    1 CHIL @I1@
    1 CHIL @I2@
    0 @F2@ FAM
    1 WIFE @I5@
    1 CHIL @I4@
    1 CHIL @I9@
    0 @F3@ FAM
    1 WIFE @I6@
    1 CHIL @I5@
    0 @F4@ FAM
    1 HUSB @I15@
    1 CHIL @I3@
    1 CHIL @I7@
    0 @F5@ FAM
    1 HUSB @I7@
    1 CHIL @I8@
    0 @F6@ FAM
    1 HUSB @I10@
    1 WIFE @I1@
    0 @F7@ FAM
    1 HUSB @I2@
    1 CHIL @I14@
    0 @F8@ FAM
    1 HUSB @I11@
    1 WIFE @I12@
    1 CHIL @I10@
    1 CHIL @I13@
    0 TRLR
    """

    let graph = GedcomFamilyGraph(gedcomText: tree)
    var zoe: GedcomFamilyGraph.Person { graph.people["@I1@"]! }

    private func names(_ resolution: GedcomFamilyGraph.KinshipResolution) -> [String] {
        guard case .found(let paths) = resolution else { return [] }
        return paths.map(\.relative.name)
    }

    @Test func maternalGreatGrandmotherFollowsTheMotherFirst() {
        let resolution = graph.relatives(.greatGrandmother, side: .maternal, of: zoe)
        guard case .found(let paths) = resolution, paths.count == 1 else {
            Issue.record("expected one path, got \(resolution)"); return
        }
        #expect(paths[0].relative.name == "Great Spring")
        #expect(paths[0].describe(from: zoe)
                == "Zoe River → mother Mom Lake → her mother Nana Brook → her mother Great Spring")
    }

    @Test func paternalSideStopsWhereTheTreeStopsAndNamesTheHop() {
        // Dad's father Gramps is recorded, Gramps' parents are not.
        let resolution = graph.relatives(.greatGrandmother, side: .paternal, of: zoe)
        guard case .missingHop(let reached, let missing) = resolution else {
            Issue.record("expected missing hop, got \(resolution)"); return
        }
        #expect(reached.map(\.person.name) == ["Dad River", "Gramps River"])
        #expect(reached.map(\.label) == ["father", "his father"])
        #expect(missing == "her father's father's mother")

        // One hop shorter: Dad's mother is not recorded at all.
        let grandmother = graph.relatives(.grandmother, side: .paternal, of: zoe)
        guard case .missingHop(let reachedGM, let missingGM) = grandmother else {
            Issue.record("expected missing hop, got \(grandmother)"); return
        }
        #expect(reachedGM.map(\.person.name) == ["Dad River"])
        #expect(missingGM == "a female grandmother on the paternal side")
    }

    @Test func noSideMeansBothParentsAndEveryRouteIsListed() {
        let grandparents = names(graph.relatives(.grandparents, side: nil, of: zoe))
        #expect(grandparents == ["Gramps River", "Nana Brook"])
        let grandmothers = names(graph.relatives(.grandmother, side: nil, of: zoe))
        #expect(grandmothers == ["Nana Brook"])
    }

    @Test func auntsUnclesCousinsNiecesNephewsAndInLaws() {
        #expect(names(graph.relatives(.uncle, side: nil, of: zoe)) == ["Ted River"])
        #expect(names(graph.relatives(.uncle, side: .maternal, of: zoe)) == [])
        #expect(names(graph.relatives(.aunt, side: nil, of: zoe)) == ["Sue Lake"])
        #expect(names(graph.relatives(.aunt, side: .maternal, of: zoe)) == ["Sue Lake"])
        #expect(names(graph.relatives(.auntsAndUncles, side: nil, of: zoe)) == ["Sue Lake", "Ted River"])
        #expect(names(graph.relatives(.cousins, side: nil, of: zoe)) == ["Cara River"])
        #expect(names(graph.relatives(.cousin, side: .paternal, of: zoe)) == ["Cara River"])
        #expect(names(graph.relatives(.nephew, side: nil, of: zoe)) == ["Nate River"])
        #expect(names(graph.relatives(.niece, side: nil, of: zoe)) == [])
        #expect(names(graph.relatives(.parentsInLaw, side: nil, of: zoe)) == ["Hal Field", "Ivy Field"])
        #expect(names(graph.relatives(.motherInLaw, side: nil, of: zoe)) == ["Ivy Field"])
        #expect(names(graph.relatives(.sisterInLaw, side: nil, of: zoe)) == ["Fay Field"])
        #expect(names(graph.relatives(.brotherInLaw, side: nil, of: zoe)) == [])
        let owen = graph.people["@I10@"]!
        #expect(names(graph.relatives(.brotherInLaw, side: nil, of: owen)) == ["Ben River"])
        let mom = graph.people["@I4@"]!
        #expect(names(graph.relatives(.sonInLaw, side: nil, of: mom)) == ["Owen Field"])
    }

    @Test func missingUncleIsReportedAsMissingNotAsSomeoneElse() {
        // Zoe's mother has only a sister; asking for a maternal uncle must
        // not return Sue.
        let resolution = graph.relatives(.uncle, side: .maternal, of: zoe)
        guard case .missingHop(let reached, let missing) = resolution else {
            Issue.record("expected missing hop, got \(resolution)"); return
        }
        #expect(reached.map(\.person.name) == ["Mom Lake"])
        #expect(missing == "a male uncle on the maternal side")
    }

    @Test func colloquialPhrasesMapToTheClosedVocabulary() {
        func map(_ phrase: String) -> String? {
            GedcomFamilyGraph.extendedRelation(fromPhrase: phrase).map {
                ($0.side.map { "\($0.rawValue) " } ?? "") + $0.relation.rawValue
            }
        }
        #expect(map("great grandmother") == "great-grandmother")
        #expect(map("great-grandma") == "great-grandmother")
        #expect(map("maternal great grandmother") == "maternal great-grandmother")
        #expect(map("mother's side great grandmother") == "maternal great-grandmother")
        #expect(map("paternal grandfather") == "paternal grandfather")
        #expect(map("Grandpa") == "grandfather")
        #expect(map("nana") == "grandmother")
        #expect(map("great great grandfather") == "great-great-grandfather")
        #expect(map("mother in law") == "mother-in-law")
        #expect(map("in-laws") == "parents-in-law")
        #expect(map("first cousins") == "cousins")
        #expect(map("nieces and nephews") == "nieces-and-nephews")
        #expect(map("great-great-great-grandfather") == nil)
        #expect(map("godmother") == nil)
        #expect(map("father") == nil, "one-hop words belong to Relation, not the extended vocabulary")
    }

    @Test func surnamesAndBirthYearsAreReadFromTheGedcom() {
        #expect(zoe.surname == "River")
        #expect(graph.people(withSurname: "river").map(\.name)
                == ["Ben River", "Cara River", "Dad River", "Gramps River", "Nate River",
                    "Ted River", "Zoe River"])
        #expect(graph.people(withSurname: "the Rivers").count == 7)
        #expect(graph.people(withSurname: "Fields").count == 4)
        #expect(graph.people(withSurname: "nobody").isEmpty)
        #expect(GedcomFamilyGraph.year(in: "4 JUL 1962") == 1962)
        #expect(GedcomFamilyGraph.year(in: "ABT 1944") == 1944)
        #expect(GedcomFamilyGraph.year(in: "BET 1930 AND 1931") == 1930)
        #expect(GedcomFamilyGraph.year(in: "12 MAR") == nil)
        #expect(GedcomFamilyGraph.year(in: nil) == nil)
    }
}
