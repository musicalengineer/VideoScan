import Testing
import Foundation
@testable import VideoScanCore

// Refactor R4 (GH #281): `GedcomFamilyGraph.init(gedcomText:)` (CCN 43) had
// its HEAD reader and its level-0 record opener moved out into helpers.
// Before the move this pinned what the parse produces for a synthetic file
// that walks every branch of the line loop: HEAD, VideoScan's own
// provenance tags (valid and invalid), NOTE + CONT/CONC with edge spaces,
// envelope boilerplate, an unknown HEAD tag with sub-lines, unmodelled
// records with and without a pointer, people with kept / unkept tags,
// military blocks (kept and not), families, a duplicated FamilySearch id,
// malformed lines and TRLR. The golden was captured from the unsplit init
// (`ebcd2f09`) and not edited after the move. Synthetic names only
// (2026-08-03 privacy policy).
struct GedcomInitCharacterizationTests {

    static let text = "0 HEAD\n" + """
    1 SOUR synthetic
    2 VERS 1.0
    1 GEDC
    2 VERS 5.5.1
    1 CHAR UTF-8
    1 _VS_ROOT @I2@
    1 _VS_ROOT notapointer
    1 _VS_ROOT @I99@
    1 _VS_SOURCE first.ged
    2 _VS_SHA256 abc123
    2 _VS_DROPPED 4
    2 _VS_OTHER x
    1 _VS_SOURCE second.ged
    2 _VS_DROPPED -1
    2 _VS_SHA256
    1 _VS_SOURCE
    1 _VS_MERGED yes
    1 NOTE A note with  edge\u{20}
    2 CONT second line
    2 CONC  continued
    2 TYPE odd
    1 _CUSTOM header
    2 _SUB line
    0 @S1@ SOUR
    1 TITL A source
    2 CONT more
    0 SUBM
    1 NAME Nobody
    garbage line
    X NAME bad level
    1
    0 @I1@ INDI
    1 NAME Alfa /Test/
    2 GIVN Alfa
    1 SEX M
    1 BIRT
    2 DATE 1 JAN 1900
    2 PLAC Testville
    1 DEAT
    2 DATE 1970
    1 FAMS @F1@
    1 _FSFTID AAAA-111
    1 OCCU Tester
    2 DATE 1930
    1 MILI
    2 DATE 1918
    2 PLAC France
    1 EVEN Army
    2 TYPE Military Service
    2 DATE 1917
    1 EVEN Picnic
    2 TYPE Family Gathering
    2 DATE 1950
    1 NOTE @N1@
    0 @I2@ INDI
    1 NAME Bravo /Test/
    1 SEX F
    1 FAMS @F1@
    1 _FSFTID AAAA-111
    0 @I3@ INDI
    1 NAME Charlie /Test/
    1 FAMC @F1@
    1 BIRT
    2 DATE ABT 1925
    0 @F1@ FAM
    1 HUSB @I1@
    1 WIFE @I2@
    1 CHIL @I3@
    1 MARR
    2 DATE 2 FEB 1922
    2 PLAC Testville
    1 _FSFTID FFFF-222
    1 DIV Y
    2 DATE 1960
    0 @N1@ NOTE a shared note
    1 CONT more
    0 TRLR
    """

    static func snapshot(_ g: GedcomFamilyGraph) -> String {
        var out: [String] = []
        out.append("roots=\(g.rootPersonIDs)")
        out.append("dropped=\(g.droppedLineCount)")
        out.append("headNote=\(g.headNote.map { "«\($0)»" } ?? "nil")")
        out.append("merged=\(g.isMergedArtifact)")
        out.append("sourceFileNames=\(g.sourceFileNames)")
        for p in g.sourceProvenance {
            out.append("provenance name=\(p.name) sha=\(p.sha256 ?? "nil") dropped=\(p.droppedLineCount)")
        }
        out.append("fsid=\(g.personIDByFamilySearchID.sorted { $0.key < $1.key }.map { "\($0.key)→\($0.value)" })")
        for id in g.people.keys.sorted() {
            var text = ""
            dump(g.people[id], to: &text)
            out.append(text)
        }
        for id in g.families.keys.sorted() {
            var text = ""
            dump(g.families[id], to: &text)
            out.append("family \(id):\n" + text)
        }
        var joined = out.joined(separator: "\n")
        while joined.hasSuffix("\n") { joined.removeLast() }   // dump's last newline
        return joined
    }

    @Test func everyLineLoopBranchParsesAsBefore() {
        let snap = Self.snapshot(GedcomFamilyGraph(gedcomText: Self.text))
        #expect(snap == Self.golden, Comment(rawValue: "ACTUAL:\n" + snap))
    }

    /// No HEAD roots that name a person → the first INDI is the root.
    @Test func firstIndividualIsTheRootWithoutHeadRoots() {
        let g = GedcomFamilyGraph(gedcomText: "0 HEAD\n1 _VS_ROOT @I9@\n0 @I5@ INDI\n1 NAME E /T/\n0 @I6@ INDI\n0 TRLR")
        #expect(g.rootPersonIDs == ["@I5@"])
        #expect(GedcomFamilyGraph(gedcomText: "0 HEAD\n0 TRLR").rootPersonIDs.isEmpty)
    }

    /// Pinned AS IS, not endorsed: a byte-order mark glued to the first line
    /// ("\u{feff}0 HEAD") makes the level unparseable, so that line is
    /// skipped and the HEAD's own tags are read as if outside any record
    /// (reported to the Manager as a lead; behaviour unchanged here).
    @Test func aBOMBeforeTheHeadLevelIsReadAsBefore() {
        let g = GedcomFamilyGraph(gedcomText: "\u{feff}0 HEAD\n1 _VS_ROOT @I2@\n1 NOTE n\n0 @I1@ INDI\n0 @I2@ INDI\n0 TRLR")
        #expect(g.rootPersonIDs == ["@I1@"])
        #expect(g.headNote == nil)
        #expect(g.droppedLineCount == 0)
    }

    static let golden = """
    roots=["@I2@"]
    dropped=25
    headNote=«A note with  edge\u{20}
    second line continued»
    merged=true
    sourceFileNames=["first.ged", "second.ged"]
    provenance name=first.ged sha=abc123 dropped=4
    provenance name=second.ged sha=nil dropped=0
    fsid=["AAAA-111→@I1@"]
    ▿ Optional(VideoScanCore.GedcomFamilyGraph.Person(id: "@I1@", name: "Alfa Test", alternateNames: [], sex: "M", childOfFamily: nil, childOfFamilies: [], spouseOfFamilies: ["@F1@"], birthDate: Optional("1 JAN 1900"), deathDate: Optional("1970"), birthPlace: Optional("Testville"), deathPlace: nil, surname: Optional("Test"), alternateSurnames: [], familySearchID: Optional("AAAA-111"), militaryFacts: [VideoScanCore.GedcomFamilyGraph.MilitaryFact(tag: "MILI", value: nil, type: nil, date: Optional("1918"), place: Optional("France"), note: nil), VideoScanCore.GedcomFamilyGraph.MilitaryFact(tag: "EVEN", value: Optional("Army"), type: Optional("Military Service"), date: Optional("1917"), place: nil, note: nil)]))
      ▿ some: VideoScanCore.GedcomFamilyGraph.Person
        - id: "@I1@"
        - name: "Alfa Test"
        - alternateNames: 0 elements
        - sex: "M"
        - childOfFamily: nil
        - childOfFamilies: 0 elements
        ▿ spouseOfFamilies: 1 element
          - "@F1@"
        ▿ birthDate: Optional("1 JAN 1900")
          - some: "1 JAN 1900"
        ▿ deathDate: Optional("1970")
          - some: "1970"
        ▿ birthPlace: Optional("Testville")
          - some: "Testville"
        - deathPlace: nil
        ▿ surname: Optional("Test")
          - some: "Test"
        - alternateSurnames: 0 elements
        ▿ familySearchID: Optional("AAAA-111")
          - some: "AAAA-111"
        ▿ militaryFacts: 2 elements
          ▿ VideoScanCore.GedcomFamilyGraph.MilitaryFact
            - tag: "MILI"
            - value: nil
            - type: nil
            ▿ date: Optional("1918")
              - some: "1918"
            ▿ place: Optional("France")
              - some: "France"
            - note: nil
          ▿ VideoScanCore.GedcomFamilyGraph.MilitaryFact
            - tag: "EVEN"
            ▿ value: Optional("Army")
              - some: "Army"
            ▿ type: Optional("Military Service")
              - some: "Military Service"
            ▿ date: Optional("1917")
              - some: "1917"
            - place: nil
            - note: nil

    ▿ Optional(VideoScanCore.GedcomFamilyGraph.Person(id: "@I2@", name: "Bravo Test", alternateNames: [], sex: "F", childOfFamily: nil, childOfFamilies: [], spouseOfFamilies: ["@F1@"], birthDate: nil, deathDate: nil, birthPlace: nil, deathPlace: nil, surname: Optional("Test"), alternateSurnames: [], familySearchID: Optional("AAAA-111"), militaryFacts: []))
      ▿ some: VideoScanCore.GedcomFamilyGraph.Person
        - id: "@I2@"
        - name: "Bravo Test"
        - alternateNames: 0 elements
        - sex: "F"
        - childOfFamily: nil
        - childOfFamilies: 0 elements
        ▿ spouseOfFamilies: 1 element
          - "@F1@"
        - birthDate: nil
        - deathDate: nil
        - birthPlace: nil
        - deathPlace: nil
        ▿ surname: Optional("Test")
          - some: "Test"
        - alternateSurnames: 0 elements
        ▿ familySearchID: Optional("AAAA-111")
          - some: "AAAA-111"
        - militaryFacts: 0 elements

    ▿ Optional(VideoScanCore.GedcomFamilyGraph.Person(id: "@I3@", name: "Charlie Test", alternateNames: [], sex: "", childOfFamily: Optional("@F1@"), childOfFamilies: ["@F1@"], spouseOfFamilies: [], birthDate: Optional("ABT 1925"), deathDate: nil, birthPlace: nil, deathPlace: nil, surname: Optional("Test"), alternateSurnames: [], familySearchID: nil, militaryFacts: []))
      ▿ some: VideoScanCore.GedcomFamilyGraph.Person
        - id: "@I3@"
        - name: "Charlie Test"
        - alternateNames: 0 elements
        - sex: ""
        ▿ childOfFamily: Optional("@F1@")
          - some: "@F1@"
        ▿ childOfFamilies: 1 element
          - "@F1@"
        - spouseOfFamilies: 0 elements
        ▿ birthDate: Optional("ABT 1925")
          - some: "ABT 1925"
        - deathDate: nil
        - birthPlace: nil
        - deathPlace: nil
        ▿ surname: Optional("Test")
          - some: "Test"
        - alternateSurnames: 0 elements
        - familySearchID: nil
        - militaryFacts: 0 elements

    family @F1@:
    ▿ Optional(VideoScanCore.GedcomFamilyGraph.Family(husband: Optional("@I1@"), wife: Optional("@I2@"), children: ["@I3@"], marriageDate: Optional("2 FEB 1922"), familySearchID: Optional("FFFF-222")))
      ▿ some: VideoScanCore.GedcomFamilyGraph.Family
        ▿ husband: Optional("@I1@")
          - some: "@I1@"
        ▿ wife: Optional("@I2@")
          - some: "@I2@"
        ▿ children: 1 element
          - "@I3@"
        ▿ marriageDate: Optional("2 FEB 1922")
          - some: "2 FEB 1922"
        ▿ familySearchID: Optional("FFFF-222")
          - some: "FFFF-222"
    """
}
