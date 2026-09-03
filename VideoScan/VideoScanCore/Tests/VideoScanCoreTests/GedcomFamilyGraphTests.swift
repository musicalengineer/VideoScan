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
        // Both links are kept, but prose relations follow ONE primary
        // family (Rick's 2026-09-02 ruling — this test used to expect
        // both fathers and both mothers). Two complete families with no
        // FamilySearch id and no facts tie down to GEDCOM order: the
        // birth family. The adoptive parents stay reachable through
        // `parentFamilyChoice` / `allRecordedParents`, and siblings from
        // both families are still siblings.
        #expect(
            g.relatives(.father, of: child).map(\.id) == ["@I2@"]
        )
        #expect(
            g.relatives(.mother, of: child).map(\.id) == ["@I3@"]
        )
        #expect(
            g.allRecordedParents(of: child).map(\.id) == ["@I2@", "@I4@", "@I3@", "@I5@"]
        )
        #expect(
            g.parentFamilyChoice(of: child)?.alternates.map(\.person.id) == ["@I4@", "@I5@"]
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

    /// codex #794 (4): loss accounting covers EVERY line not retained —
    /// top-level SOUR/OBJE/NOTE/SUBM records with their sub-lines and
    /// unknown HEAD tags included — while the HEAD envelope (SOUR, GEDC,
    /// CHAR, DATE, SUBM…) that the writer regenerates is not counted.
    @Test func droppedLineCountIncludesTopLevelRecordsAndUnknownHeadLines() {
        let g = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        1 SOUR getmyancestors
        2 VERS 1.0
        2 NAME getmyancestors
        1 DATE 1 JAN 2026
        2 TIME 12:00:00
        1 GEDC
        2 VERS 5.5.1
        2 FORM LINEAGE-LINKED
        1 CHAR UTF-8
        1 SUBM @SUBM@
        1 _CUSTOM header thing
        2 CONT more of it
        0 @SUBM@ SUBM
        1 NAME getmyancestors
        0 @I1@ INDI
        1 NAME Ann /Shared/
        1 _FSFTID SHRD-001
        1 OBJE @O1@
        0 @S1@ SOUR
        1 TITL Census
        2 DATE 1900
        0 @O1@ OBJE
        1 FILE photo.jpg
        2 FORM jpg
        0 @N1@ NOTE Hello
        1 CONT world
        0 @R1@ REPO
        1 NAME Archive
        0 TRLR
        """)
        #expect(g.people.count == 1)
        // _CUSTOM + CONT (2) + SUBM record (2) + OBJE under INDI (1)
        // + SOUR record (3) + OBJE record (3) + NOTE record (2) + REPO (2)
        #expect(g.droppedLineCount == 15)
        // The written form of THIS graph loses nothing further.
        #expect(GedcomFamilyGraph(gedcomText: g.gedcomText(provenance: "x\ny")).droppedLineCount == 0)
        // A source-less HEAD NOTE is kept (headNote), so not counted.
        let noted = GedcomFamilyGraph(gedcomText: "0 HEAD\n1 NOTE a\n2 CONT b\n0 TRLR")
        #expect(noted.headNote == "a\nb")
        #expect(noted.droppedLineCount == 0)
        // Malformed (level-less) lines are not GEDCOM lines: not counted.
        #expect(GedcomFamilyGraph(gedcomText: "0 HEAD\ngarbage\n\n0 TRLR").droppedLineCount == 0)
    }

    @Test func colloquialRelationWords() {
        #expect(GedcomFamilyGraph.relation(fromWord: "dad") == .father)
        #expect(GedcomFamilyGraph.relation(fromWord: "Mom") == .mother)
        #expect(GedcomFamilyGraph.relation(fromWord: "kids") == .children)
        #expect(GedcomFamilyGraph.relation(fromWord: "cousin") == nil)
    }

    // MARK: - A gendered plural keeps its sex (Rick, 2026-08-31)
    //
    // Hallie answered "Rick's brothers" with "Beth, Ellen, Matt, Tim,
    // Timmy". Every plural gendered word had been mapped to the UNGENDERED
    // relation — "brothers"/"sisters" both to .siblings, "sons"/"daughters"
    // both to .children — so the sex filter was discarded at the door,
    // before any resolver or composer could be blamed for it.

    @Test func gendredPluralsKeepTheirSex() {
        #expect(GedcomFamilyGraph.relation(fromWord: "brothers") == .brother)
        #expect(GedcomFamilyGraph.relation(fromWord: "sisters") == .sister)
        #expect(GedcomFamilyGraph.relation(fromWord: "sons") == .son)
        #expect(GedcomFamilyGraph.relation(fromWord: "daughters") == .daughter)
        // Singulars unchanged.
        #expect(GedcomFamilyGraph.relation(fromWord: "brother") == .brother)
        #expect(GedcomFamilyGraph.relation(fromWord: "sister") == .sister)
        #expect(GedcomFamilyGraph.relation(fromWord: "son") == .son)
        #expect(GedcomFamilyGraph.relation(fromWord: "daughter") == .daughter)
    }

    @Test func theUngenderedWordMustBeAskedForByName() {
        // The only way to get everyone is to say so. This is the assertion
        // that would have failed before the fix.
        #expect(GedcomFamilyGraph.relation(fromWord: "siblings") == .siblings)
        #expect(GedcomFamilyGraph.relation(fromWord: "sibling") == .siblings)
        #expect(GedcomFamilyGraph.relation(fromWord: "children") == .children)
        #expect(GedcomFamilyGraph.relation(fromWord: "kids") == .children)
        #expect(GedcomFamilyGraph.relation(fromWord: "brothers") != .siblings)
        #expect(GedcomFamilyGraph.relation(fromWord: "sisters") != .siblings)
        #expect(GedcomFamilyGraph.relation(fromWord: "sons") != .children)
        #expect(GedcomFamilyGraph.relation(fromWord: "daughters") != .children)
    }

    /// Rick's actual shape: two sisters and three brothers. The end-to-end
    /// assertion, not just the lookup table — this is the sentence a reader
    /// would have seen.
    @Test func brothersResolvesToTheBrothersOnly() {
        let graph = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @P1@ INDI
        1 NAME Dad /Breen/
        1 SEX M
        1 FAMS @F1@
        0 @P2@ INDI
        1 NAME Mum /Breen/
        1 SEX F
        1 FAMS @F1@
        0 @I1@ INDI
        1 NAME Rick /Breen/
        1 SEX M
        1 FAMC @F1@
        0 @I2@ INDI
        1 NAME Beth /Breen/
        1 SEX F
        1 FAMC @F1@
        0 @I3@ INDI
        1 NAME Ellen /Breen/
        1 SEX F
        1 FAMC @F1@
        0 @I4@ INDI
        1 NAME Matt /Breen/
        1 SEX M
        1 FAMC @F1@
        0 @I5@ INDI
        1 NAME Tim /Breen/
        1 SEX M
        1 FAMC @F1@
        0 @F1@ FAM
        1 HUSB @P1@
        1 WIFE @P2@
        1 CHIL @I1@
        1 CHIL @I2@
        1 CHIL @I3@
        1 CHIL @I4@
        1 CHIL @I5@
        0 TRLR
        """)
        let rick = try! #require(graph.people["@I1@"])

        func names(_ word: String) -> [String] {
            let relation = GedcomFamilyGraph.relation(fromWord: word)!
            return graph.relatives(relation, of: rick).map(\.name).sorted()
        }

        #expect(names("brothers") == ["Matt Breen", "Tim Breen"],
                "Beth and Ellen are not Rick's brothers")
        #expect(names("sisters") == ["Beth Breen", "Ellen Breen"])
        #expect(names("siblings")
                == ["Beth Breen", "Ellen Breen", "Matt Breen", "Tim Breen"],
                "the ungendered word still returns everyone")
    }

    /// The same bug lived on the other side of the family: "sons" and
    /// "daughters" both mapped to .children, so asking Rick for his
    /// daughters would have listed his four sons.
    @Test func sonsAndDaughtersDoNotReturnEachOther() {
        let graph = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME Parent /Breen/
        1 SEX M
        1 FAMS @F1@
        0 @C1@ INDI
        1 NAME A Son /Breen/
        1 SEX M
        1 FAMC @F1@
        0 @C2@ INDI
        1 NAME A Daughter /Breen/
        1 SEX F
        1 FAMC @F1@
        0 @F1@ FAM
        1 HUSB @I1@
        1 CHIL @C1@
        1 CHIL @C2@
        0 TRLR
        """)
        let parent = try! #require(graph.people["@I1@"])
        func names(_ word: String) -> [String] {
            graph.relatives(GedcomFamilyGraph.relation(fromWord: word)!, of: parent)
                .map(\.name).sorted()
        }
        #expect(names("sons") == ["A Son Breen"])
        #expect(names("daughters") == ["A Daughter Breen"])
        #expect(names("children") == ["A Daughter Breen", "A Son Breen"])
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

        // The one-time index build (2026-08-28) is a compile-time cost —
        // the loader does it off the main thread and the compiled artifact
        // carries it — so it is budgeted separately from the lookup.
        let buildStarted = ContinuousClock.now
        _ = largeGraph.index
        let build = buildStarted.duration(to: .now)
        #expect(build < .seconds(5), "100k index build exceeded 5 seconds: \(build)")

        let started = ContinuousClock.now
        let matches = largeGraph.people(matching: "Needle Archivist")
        let elapsed = started.duration(to: .now)

        #expect(matches.map(\.name) == ["Needle Archivist"])
        #expect(elapsed < .milliseconds(50),
                "100k GEDCOM lookup exceeded 50 ms: \(elapsed)")
    }

    // MARK: Provenance canonical form + same-bytes fingerprint (codex #814/#817)

    static let lossy = """
    0 HEAD
    1 SOUR getmyancestors
    0 @I1@ INDI
    1 NAME Ann /Shared/
    1 OCCU Weaver
    1 NOTE Long story
    2 CONT more
    1 _FSFTID SHRD-001
    0 @S1@ SOUR
    1 TITL Census
    0 TRLR
    """

    /// A file parse carries SHA-256 of the bytes it was parsed from — the
    /// same digest `shasum -a 256` prints — and `init?(fileURL:)` is one
    /// read of the file delegating to `init?(data:fileURL:)`.
    @Test func fileParseFingerprintsTheBytesItParsed() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GedcomFingerprint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("lossy.ged")
        try Self.lossy.write(to: url, atomically: true, encoding: .utf8)
        let data = try Data(contentsOf: url)
        let expected = try GedcomCompiledTree.fullSHA256(of: url)

        let fromFile = try #require(GedcomFamilyGraph(fileURL: url))
        let fromData = try #require(GedcomFamilyGraph(data: data, fileURL: url))
        #expect(fromFile.sourceFingerprint == expected)
        #expect(fromData.sourceFingerprint == expected)
        #expect(expected.count == 64)
        #expect(fromFile.sourceFileName == "lossy.ged")
        #expect(fromFile.people == fromData.people)

        // The Data variant hashes what it was GIVEN, whatever the path holds now.
        try "0 HEAD\n0 @I1@ INDI\n1 NAME Someone /Else/\n0 TRLR\n".write(to: url, atomically: true, encoding: .utf8)
        let stale = try #require(GedcomFamilyGraph(data: data, fileURL: url))
        #expect(stale.sourceFingerprint == expected, "digest of the parsed bytes, not of the path")
        #expect(stale.sourceFingerprint != (try GedcomCompiledTree.fullSHA256(of: url)))
        #expect(GedcomFamilyGraph(data: Data([0xFF, 0xFE, 0x00]), fileURL: url) == nil, "not UTF-8 → nil, no trap")
    }

    /// PLAIN shape: empty list, local = D. CANONICAL: D moved into the one
    /// entry, local 0. The total is invariant and canonicalized() is
    /// idempotent; a nameless text graph keeps its loss local.
    @Test func canonicalizedMovesAPlainGraphsLossIntoItsOneEntryWithoutChangingTheTotal() throws {
        var plain = GedcomFamilyGraph(gedcomText: Self.lossy)
        #expect(plain.droppedLineCount == 5)
        #expect(plain.sourceProvenance.isEmpty)
        #expect(plain.totalDroppedLineCount == 5)
        // Nameless: cannot be listed, so canonical == plain.
        let nameless = plain.canonicalized()
        #expect(nameless.sourceProvenance.isEmpty)
        #expect(nameless.droppedLineCount == 5)
        #expect(nameless.effectiveProvenance.isEmpty)

        plain.sourceFileName = "lossy.ged"; plain.sourceFingerprint = "feed"
        let canonical = plain.canonicalized()
        #expect(canonical.sourceProvenance == [.init(name: "lossy.ged", sha256: "feed", droppedLineCount: 5)])
        #expect(canonical.droppedLineCount == 0)
        #expect(canonical.totalDroppedLineCount == 5)
        #expect(canonical.sourceFileNames == ["lossy.ged"])
        #expect(canonical.sourceFingerprint == "feed", "the graph's own digest is its own scalar")
        #expect(canonical.canonicalized().sourceProvenance == canonical.sourceProvenance, "idempotent")
        #expect(canonical.canonicalized().droppedLineCount == 0)
        #expect(plain.effectiveProvenance == canonical.sourceProvenance)
        #expect(plain.droppedLineCount == 5, "canonicalized() is pure")
    }

    /// `bindSources` is positional and fails closed: count, basename and
    /// carried hash must all agree; on refusal the graph is untouched.
    @Test func bindSourcesIsPositionalAndFailsClosed() throws {
        var a = GedcomFamilyGraph(gedcomText: Self.lossy); a.sourceFileName = "a.ged"; a.sourceFingerprint = "aa"
        var b = GedcomFamilyGraph(gedcomText: "0 HEAD\n0 @I2@ INDI\n1 NAME Bo /Bee/\n1 _FSFTID BBB-1\n0 TRLR"); b.sourceFileName = "b.ged"; b.sourceFingerprint = "bb"
        var merged = a.merged(with: b)
        let before = merged
        #expect(throws: GedcomFamilyGraph.SourceBindingError.countMismatch(graph: 2, sources: 1)) {
            try merged.bindSources([(name: "a.ged", sha256: "aa")])
        }
        #expect(throws: GedcomFamilyGraph.SourceBindingError.nameMismatch(index: 0, graph: "a.ged", source: "b.ged")) {
            try merged.bindSources([(name: "b.ged", sha256: "bb"), (name: "a.ged", sha256: "aa")])
        }
        #expect(throws: GedcomFamilyGraph.SourceBindingError.hashMismatch(index: 1, name: "b.ged", graph: "bb", source: "b2")) {
            try merged.bindSources([(name: "a.ged", sha256: "aa"), (name: "b.ged", sha256: "b2")])
        }
        #expect(merged.sourceProvenance == before.sourceProvenance, "refusal leaves the graph untouched")
        try merged.bindSources([(name: "a.ged", sha256: "aa"), (name: "b.ged", sha256: "bb")])
        #expect(merged.sourceProvenance.map(\.sha256) == ["aa", "bb"])
        #expect(merged.totalDroppedLineCount == 5)

        // A plain file graph binds as ONE source and comes out canonical;
        // a text graph given a name but no hash takes the store's.
        var plain = a
        try plain.bindSources([(name: "a.ged", sha256: "aa")])
        #expect(plain.sourceProvenance == [.init(name: "a.ged", sha256: "aa", droppedLineCount: 5)])
        #expect(plain.droppedLineCount == 0)
        var unhashed = GedcomFamilyGraph(gedcomText: Self.lossy); unhashed.sourceFileName = "a.ged"
        try unhashed.bindSources([(name: "a.ged", sha256: "fresh")])
        #expect(unhashed.sourceProvenance.first?.sha256 == "fresh")
        #expect(unhashed.sourceFingerprint == "fresh")
        // Nameless text graph: nothing to bind to → refused, never silently accepted.
        var nameless = GedcomFamilyGraph(gedcomText: Self.lossy)
        #expect(throws: GedcomFamilyGraph.SourceBindingError.countMismatch(graph: 0, sources: 1)) {
            try nameless.bindSources([(name: "a.ged", sha256: "aa")])
        }
    }
}
