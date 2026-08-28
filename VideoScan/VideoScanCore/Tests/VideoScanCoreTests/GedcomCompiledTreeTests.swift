import XCTest
@testable import VideoScanCore

/// Codec round-trip + corruption handling + Release timings for the
/// compiled artifact (GedcomCompiledTree). Timings print as COMPILED[…].
final class GedcomCompiledTreeTests: XCTestCase {
    static let bigTree = URL(fileURLWithPath:
        "/Volumes/FamilyArchive/Breen_Family_Archive/40_Family_Tree/GEDCOM/familysearch-tree-20generations.ged")

    /// Exhaustive-verify budget (Debug `swift test`; Release is several×
    /// faster). 100k people + ~50k families + index compare.
    static let verifyBudgetMS = 1_000.0

    func ms(_ body: () throws -> Void) rethrows -> Double {
        let t0 = DispatchTime.now().uptimeNanoseconds
        try body()
        return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
    }

    /// A Codable mirror of the graph records only (no index), for the
    /// "would binary plist have been enough?" measurement.
    struct CodablePerson: Codable {
        let id, name, sex: String
        let childOfFamily, birthDate, deathDate, birthPlace, deathPlace, surname, familySearchID: String?
        let alternateNames, alternateSurnames, childOfFamilies, spouseOfFamilies: [String]
    }
    struct CodableGraph: Codable { let people: [CodablePerson] }

    func roundTrip(_ graph: GedcomFamilyGraph, label: String) throws {
        var data = Data()
        print("COMPILED[\(label)] index build: \(ms { _ = graph.index }) ms")
        print("COMPILED[\(label)] encode: \(ms { data = GedcomCompiledTree.encode(graph) }) ms, \(data.count / 1024) KB")
        var decoded: GedcomFamilyGraph?
        print("COMPILED[\(label)] decode: \(try ms { decoded = try GedcomCompiledTree.decode(data) }) ms")
        let d = try XCTUnwrap(decoded)
        XCTAssertTrue(d.hasBuiltIndex)
        XCTAssertEqual(d.people, graph.people)
        XCTAssertEqual(d.familyCount, graph.familyCount)
        XCTAssertEqual(d.rootPersonID, graph.rootPersonID)
        XCTAssertEqual(d.index, graph.index)
        XCTAssertEqual(d.sourceFileName, graph.sourceFileName)
        XCTAssertEqual(d.sourceModifiedAt, graph.sourceModifiedAt)
        var problems: [String] = []
        let verifyMS = ms { problems = GedcomCompiledTree.verify(decoded: d, against: graph) }
        print("COMPILED[\(label)] exhaustive verify: \(verifyMS) ms")
        XCTAssertEqual(problems, [])
        // Scale sanity (codex #789): exhaustive verify stays cheap. Measured
        // 2026-08-28 Debug on the 100k synthetic pedigree: see budget below.
        XCTAssertLessThan(verifyMS, Self.verifyBudgetMS, "exhaustive verify over budget for \(label)")
        // Family links survive: same family units for the root.
        if let root = graph.rootPerson {
            XCTAssertEqual(d.familyUnits(of: root), graph.familyUnits(of: root))
            XCTAssertEqual(d.relatives(.parents, of: root), graph.relatives(.parents, of: root))
        }
        // Codable/plist comparison (records only).
        let mirror = CodableGraph(people: graph.people.values.map {
            CodablePerson(id: $0.id, name: $0.name, sex: $0.sex, childOfFamily: $0.childOfFamily,
                          birthDate: $0.birthDate, deathDate: $0.deathDate, birthPlace: $0.birthPlace,
                          deathPlace: $0.deathPlace, surname: $0.surname, familySearchID: $0.familySearchID,
                          alternateNames: $0.alternateNames, alternateSurnames: $0.alternateSurnames,
                          childOfFamilies: $0.childOfFamilies, spouseOfFamilies: $0.spouseOfFamilies)
        })
        let enc = PropertyListEncoder(); enc.outputFormat = .binary
        var plist = Data()
        print("COMPILED[\(label)] plist encode (records only): \(try ms { plist = try enc.encode(mirror) }) ms, \(plist.count / 1024) KB")
        print("COMPILED[\(label)] plist decode (records only): \(try ms { _ = try PropertyListDecoder().decode(CodableGraph.self, from: plist) }) ms")
        // Corruption: flipped byte, truncation, wrong version → throw, never trap.
        var flipped = data; flipped[data.count / 2] ^= 0xFF
        XCTAssertThrowsError(try GedcomCompiledTree.decode(flipped))
        XCTAssertThrowsError(try GedcomCompiledTree.decode(data.prefix(data.count - 40)))
        XCTAssertThrowsError(try GedcomCompiledTree.decode(data.prefix(10)))
        var wrongVersion = data; wrongVersion[4] = 0xEE
        XCTAssertThrowsError(try GedcomCompiledTree.decode(wrongVersion))
        XCTAssertThrowsError(try GedcomCompiledTree.decode(Data("not a tree".utf8)))
    }

    func testSmallRoundTrip() throws {
        let text = """
        0 HEAD
        0 @I1@ INDI
        1 NAME Richard Harding /Breen/ Jr
        1 SEX M
        1 FAMC @F1@
        1 BIRT
        2 DATE 4 MAR 1959
        2 PLAC Boston, Massachusetts
        1 _FSFTID GVQV-NW3
        0 @I2@ INDI
        1 NAME Richard Harding /Breen/ Sr
        1 NAME Dick /Breen/
        1 SEX M
        1 FAMS @F1@
        0 @I3@ INDI
        1 NAME Muriel /Lamb/
        1 SEX F
        1 FAMS @F1@
        1 DEAT
        2 DATE 1999
        0 @F1@ FAM
        1 HUSB @I2@
        1 WIFE @I3@
        1 CHIL @I1@
        1 MARR
        2 DATE 1950
        0 TRLR
        """
        var graph = GedcomFamilyGraph(gedcomText: text)
        graph.sourceFileName = "family.ged"
        graph.sourceModifiedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try roundTrip(graph, label: "small")
        let d = try GedcomCompiledTree.decode(GedcomCompiledTree.encode(graph))
        XCTAssertEqual(d.marriages(of: d.people["@I2@"]!).first?.date, "1950")
        XCTAssertEqual(d.people(matching: "GVQV-NW3").map(\.id), ["@I1@"])
        XCTAssertEqual(d.person(familySearchID: "gvqv-nw3")?.id, "@I1@")
        XCTAssertEqual(d.people(namedLike: "Dick Breen").map(\.id), ["@I1@", "@I2@"])
    }

    func testEmptyGraphRoundTrip() throws {
        let graph = GedcomFamilyGraph(gedcomText: "0 HEAD\n0 TRLR")
        let d = try GedcomCompiledTree.decode(GedcomCompiledTree.encode(graph))
        XCTAssertTrue(d.people.isEmpty)
        XCTAssertNil(d.rootPersonID)
        XCTAssertEqual(d.people(matching: "anyone"), [])
    }

    func testVerifyCatchesADifferentTree() throws {
        let a = GedcomFamilyGraph(gedcomText: GedcomSyntheticPedigree.gedcom(people: 300, generations: 5))
        let b = GedcomFamilyGraph(gedcomText: GedcomSyntheticPedigree.gedcom(people: 301, generations: 5))
        XCTAssertFalse(GedcomCompiledTree.verify(decoded: a, against: b).isEmpty)
        XCTAssertEqual(GedcomCompiledTree.verify(decoded: a, against: a), [])
    }

    /// A copy of `graph` with the given records swapped in (index rebuilt
    /// lazily from the modified records).
    func mutated(_ graph: GedcomFamilyGraph,
                 people: [String: GedcomFamilyGraph.Person]? = nil,
                 families: [String: GedcomFamilyGraph.Family]? = nil,
                 droppedLineCount: Int? = nil,
                 headNote: String?? = nil,
                 familySearchIndex: [String: String]? = nil) -> GedcomFamilyGraph {
        GedcomFamilyGraph(decodedPeople: people ?? graph.people,
                          families: families ?? graph.familyTable,
                          rootPersonIDs: graph.rootPersonIDs,
                          personIDByFamilySearchID: familySearchIndex ?? graph.familySearchIndexTable,
                          sourceFileName: graph.sourceFileName, sourceDirectory: graph.sourceDirectory,
                          sourceModifiedAt: graph.sourceModifiedAt, sourceFileNames: graph.sourceFileNames,
                          isMergedArtifact: graph.isMergedArtifact,
                          droppedLineCount: droppedLineCount ?? graph.droppedLineCount,
                          headNote: headNote ?? graph.headNote)
    }

    /// Verification is exhaustive (codex #789): a corrupt record anywhere,
    /// not only in the first 64 people, and every codec-2 field, is reported
    /// as a mismatch class with a count and a first example.
    func testVerifyIsExhaustive() throws {
        let text = GedcomSyntheticPedigree.gedcom(people: 500, generations: 6)
            .replacingOccurrences(of: "0 HEAD\n", with: "0 HEAD\n1 NOTE compiled from two pulls\n")
        let source = GedcomFamilyGraph(gedcomText: text)
        XCTAssertEqual(source.headNote, "compiled from two pulls")
        let clean = try GedcomCompiledTree.decode(GedcomCompiledTree.encode(source))
        XCTAssertEqual(GedcomCompiledTree.verify(decoded: clean, against: source), [])

        // Person well past the 64th (ordinal order), one field changed.
        let ids = source.index.ids
        XCTAssertGreaterThan(ids.count, 200)
        var people = clean.people
        people[ids[200]]!.birthDate = "1 JAN 1800"
        people[ids[300]]!.alternateNames.append("Nobody /Else/")
        people[ids[400]]!.name += " X"
        let badPeople = GedcomCompiledTree.verify(decoded: mutated(clean, people: people), against: source)
        XCTAssertTrue(badPeople.contains { $0.hasPrefix("person differs ×3 (first: \(ids[200]): birthDate)") }, "\(badPeople)")

        // Family marriageDate, deep in the table.
        let familyIDs = source.familyTable.keys.sorted()
        XCTAssertGreaterThan(familyIDs.count, 100)
        var families = clean.familyTable
        families[familyIDs[100]]!.marriageDate = "1 JAN 1800"
        let badFamily = GedcomCompiledTree.verify(decoded: mutated(clean, families: families), against: source)
        XCTAssertEqual(badFamily, ["family marriageDate differs (first: \(familyIDs[100]))"])

        // Family children + a missing family.
        families = clean.familyTable
        families[familyIDs[50]]!.children.removeAll()
        families[familyIDs[60]] = nil
        let badFamilies = GedcomCompiledTree.verify(decoded: mutated(clean, families: families), against: source)
        XCTAssertTrue(badFamilies.contains("family count (first: \(familyIDs.count - 1) ≠ \(familyIDs.count))"), "\(badFamilies)")
        XCTAssertTrue(badFamilies.contains("family missing in decoded (first: \(familyIDs[60]))"), "\(badFamilies)")
        XCTAssertTrue(badFamilies.contains("family children differ (first: \(familyIDs[50]))"), "\(badFamilies)")

        // Codec-2 provenance fields.
        let badDropped = GedcomCompiledTree.verify(decoded: mutated(clean, droppedLineCount: source.droppedLineCount + 7), against: source)
        XCTAssertEqual(badDropped, ["droppedLineCount (first: \(source.droppedLineCount + 7) ≠ \(source.droppedLineCount))"])
        let badNote = GedcomCompiledTree.verify(decoded: mutated(clean, headNote: .some(nil)), against: source)
        XCTAssertEqual(badNote, ["headNote (first: nil ≠ Optional(\"compiled from two pulls\"))"])

        // FamilySearch index table.
        var fs = clean.familySearchIndexTable
        let fsKey = try XCTUnwrap(fs.keys.sorted().last)
        fs[fsKey] = "@I1@"
        fs["ZZZZ-999"] = "@I2@"
        let badFS = GedcomCompiledTree.verify(decoded: mutated(clean, familySearchIndex: fs), against: source)
        XCTAssertTrue(badFS.contains { $0.hasPrefix("familySearch entry differs (first: \(fsKey):") }, "\(badFS)")
        XCTAssertTrue(badFS.contains("familySearch entry extra in decoded (first: ZZZZ-999)"), "\(badFS)")

        // Report is bounded: many broken people → one line for the class.
        for id in ids.prefix(400) { people[id]!.sex = "X" }
        let many = GedcomCompiledTree.verify(decoded: mutated(clean, people: people), against: source)
        XCTAssertLessThan(many.count, 8, "\(many)")
        XCTAssertTrue(many.allSatisfy { $0.count < 400 }, "\(many)")
    }

    func testSynthetic100k() throws {
        let graph = GedcomFamilyGraph(gedcomText: GedcomSyntheticPedigree.gedcom(people: 100_000))
        try roundTrip(graph, label: "100k")
    }

    func testRealExport() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.bigTree.path))
        var graph: GedcomFamilyGraph?
        print("COMPILED[real] parse: \(ms { graph = GedcomFamilyGraph(fileURL: Self.bigTree) }) ms")
        try roundTrip(try XCTUnwrap(graph), label: "real")
        print("COMPILED[real] sourceKey: \(try ms { _ = try GedcomCompiledTree.sourceKey(for: Self.bigTree) }) ms")
        print("COMPILED[real] fullSHA256: \(try ms { _ = try GedcomCompiledTree.fullSHA256(of: Self.bigTree) }) ms")
    }
}
