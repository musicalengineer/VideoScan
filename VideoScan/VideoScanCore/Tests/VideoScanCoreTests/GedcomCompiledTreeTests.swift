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
                 familySearchIndex: [String: String]? = nil,
                 provenance: [GedcomFamilyGraph.SourceProvenance]? = nil,
                 fingerprint: String?? = nil) -> GedcomFamilyGraph {
        var out = GedcomFamilyGraph(decodedPeople: people ?? graph.people,
                          families: families ?? graph.familyTable,
                          rootPersonIDs: graph.rootPersonIDs,
                          personIDByFamilySearchID: familySearchIndex ?? graph.familySearchIndexTable,
                          sourceFileName: graph.sourceFileName, sourceDirectory: graph.sourceDirectory,
                          sourceModifiedAt: graph.sourceModifiedAt, sourceFileNames: graph.sourceFileNames,
                          isMergedArtifact: graph.isMergedArtifact,
                          droppedLineCount: droppedLineCount ?? graph.droppedLineCount,
                          headNote: headNote ?? graph.headNote)
        out.sourceProvenance = provenance ?? graph.sourceProvenance
        out.sourceFingerprint = fingerprint ?? graph.sourceFingerprint
        return out
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
        XCTAssertEqual(badDropped, ["droppedLineCount (first: \(source.droppedLineCount + 7) ≠ \(source.droppedLineCount))",
                                    "totalDroppedLineCount (first: \(source.totalDroppedLineCount + 7) ≠ \(source.totalDroppedLineCount))"])
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

    // MARK: Store contract (codex #792 / #797) — headless, Core-only

    static let donnaPull = URL(fileURLWithPath:
        "/Volumes/FamilyArchive/Breen_Family_Archive/40_Family_Tree/GEDCOM/pulls/familysearch-donna-20generations.ged")

    /// The launch cost of full-hash invalidation on the two real pulls
    /// (read-only). Printed, and bounded loosely so a regression to
    /// per-byte hashing would show.
    func testFullHashCostOnRealPulls() throws {
        let pulls = [Self.bigTree, Self.donnaPull].filter { FileManager.default.fileExists(atPath: $0.path) }
        try XCTSkipUnless(!pulls.isEmpty)
        var total = 0.0
        for url in pulls {
            let size = try GedcomCompiledTree.sourceStat(url).size
            var key = ""
            let t = try ms { key = try GedcomCompiledTree.sourceKey(for: url) }
            total += t
            print("COMPILED[hash] \(url.lastPathComponent): \(size / 1_048_576) MB in \(Int(t)) ms → \(key.prefix(12))…")
            XCTAssertEqual(key.count, 64)
        }
        print("COMPILED[hash] both pulls: \(Int(total)) ms")
        XCTAssertLessThan(total, 5_000, "full SHA-256 of the real pulls should be well under a second on the M4")
    }

    struct StoreBox {
        let root: URL
        let compiled: URL
        let lines = LineSink()
        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("CoreStore-\(UUID().uuidString)")
            compiled = root.appendingPathComponent("compiled")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        func store() -> FamilyGraphCompiledStore {
            var s = FamilyGraphCompiledStore(root: compiled)
            s.log = { [lines] in lines.append($0) }
            return s
        }
        func write(_ text: String, as name: String, mtime: Date? = nil) throws -> URL {
            let url = root.appendingPathComponent(name)
            try text.write(to: url, atomically: true, encoding: .utf8)
            if let mtime { try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path) }
            return url
        }
        func tearDown() { try? FileManager.default.removeItem(at: root) }
    }
    final class LineSink: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ s: String) { lock.withLock { lines.append(s) } }
        var all: [String] { lock.withLock { lines } }
        func contains(_ needle: String) -> Bool { all.contains { $0.contains(needle) } }
    }

    /// #797-5: an artifact with one byte appended after the checksum is
    /// refused (the hash never covered that byte), with a distinct error.
    func testTrailingByteAfterChecksumIsRejected() throws {
        let graph = GedcomFamilyGraph(gedcomText: GedcomSyntheticPedigree.gedcom(people: 50, generations: 4))
        let data = GedcomCompiledTree.encode(graph)
        XCTAssertNoThrow(try GedcomCompiledTree.decode(data))
        var padded = data; padded.append(0)
        XCTAssertThrowsError(try GedcomCompiledTree.decode(padded)) { error in
            XCTAssertEqual(error as? GedcomCompiledTree.CodecError, .corrupt("trailing bytes after checksum"))
        }
        var padded64 = data; padded64.append(Data(repeating: 0x41, count: 64))
        XCTAssertThrowsError(try GedcomCompiledTree.decode(padded64))
        XCTAssertThrowsError(try GedcomCompiledTree.decode(data.dropLast())) { error in
            XCTAssertEqual(error as? GedcomCompiledTree.CodecError, .truncated)
        }
    }

    /// #792-1: an edit in the middle of a source that keeps its size AND
    /// its mtime is a miss — the key is the full SHA-256, nothing cheaper.
    func testMiddleEditWithSameSizeAndMtimeIsAMiss() throws {
        let box = try StoreBox(); defer { box.tearDown() }
        let text = GedcomSyntheticPedigree.gedcom(people: 200, generations: 5)
        let mtime = Date(timeIntervalSince1970: 1_700_000_000)
        let source = try box.write(text, as: "family.ged", mtime: mtime)
        let store = box.store()
        let graph = try XCTUnwrap(GedcomFamilyGraph(fileURL: source))
        XCTAssertNotNil(store.ingest(graph: graph, sources: [source]))
        let keyBefore = try GedcomCompiledTree.sourceKey(for: source)
        XCTAssertEqual(keyBefore, try GedcomCompiledTree.fullSHA256(of: source), "key IS the full hash")
        XCTAssertNotNil(store.load(sources: [source]), "unchanged → hit")
        XCTAssertTrue(box.lines.contains("hashed 1 source"), "cost is logged: \(box.lines.all)")

        // Flip one byte in the middle (a digit in a year), same length.
        let bytes = Array(text.utf8)
        var at = bytes.count / 2
        while !(bytes[at] >= 0x30 && bytes[at] <= 0x39) { at += 1 }      // find a digit
        let handle = try FileHandle(forWritingTo: source)
        try handle.seek(toOffset: UInt64(at))
        try handle.write(contentsOf: Data([bytes[at] == 0x39 ? 0x38 : bytes[at] + 1]))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: source.path)
        let stat = try GedcomCompiledTree.sourceStat(source)
        XCTAssertEqual(stat.size, bytes.count, "size preserved")
        XCTAssertEqual(stat.mtime, mtime.timeIntervalSince1970, accuracy: 0.001, "mtime preserved")

        XCTAssertNotEqual(try GedcomCompiledTree.sourceKey(for: source), keyBefore)
        XCTAssertNil(store.load(sources: [source]), "middle edit must be a miss")
        XCTAssertNil(store.loadCurrent(), "manifest-driven load must miss too")
        XCTAssertTrue(box.lines.contains("family.ged missing or changed"))
        // Same bytes back (via a different mtime) → hit again: mtime is not in the key.
        _ = try box.write(text, as: "family.ged", mtime: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertNotNil(store.load(sources: [source]))
    }

    /// #792-2: N concurrent ingests of different graphs into one root
    /// serialize on the store lock: afterwards exactly one current + one
    /// previous exist, both decode, no generation directory named by the
    /// pointer is missing, and every pointer read along the way decoded.
    func testConcurrentIngestsIntoOneRootSerialize() throws {
        let box = try StoreBox(); defer { box.tearDown() }
        let n = 4
        let sources = try (0..<n).map { i in
            try box.write(GedcomSyntheticPedigree.gedcom(people: 150 + i * 10, generations: 5), as: "pull-\(i).ged")
        }
        let graphs = try sources.map { try XCTUnwrap(GedcomFamilyGraph(fileURL: $0)) }
        let store = box.store()
        let results = ResultSink(n)
        let stop = ResultSink(1)
        // A reader hammering the pointer while the writers run.
        let reader = Thread {
            var reads = 0, torn = 0, unreadableCurrent = 0
            while stop.values.isEmpty {
                if FileManager.default.fileExists(atPath: store.pointerURL.path) {
                    reads += 1
                    if let p = store.readPointer() {
                        // The artifact current.json points at must ALWAYS decode
                        // (checksum included) — a prune or a half-written
                        // promote would show up here (codex #805).
                        if store.readManifest(p.current) == nil { unreadableCurrent += 1 }
                        else if let data = try? Data(contentsOf: store.artifactURL(p.current)),
                                (try? GedcomCompiledTree.decode(data)) != nil {}
                        else { unreadableCurrent += 1 }
                    } else { torn += 1 }
                }
            }
            results.set(n, torn == 0 && unreadableCurrent == 0 ? "reader ok (\(reads) reads)" : "torn \(torn), unreadable current \(unreadableCurrent) of \(reads)")
        }
        reader.start()
        DispatchQueue.concurrentPerform(iterations: n) { i in
            let promoted = store.ingest(graph: graphs[i], sources: [sources[i]])
            results.set(i, promoted == nil ? "FAILED" : "ok")
        }
        stop.set(0, "stop")
        while results.values.count < n + 1 { usleep(1_000) }
        XCTAssertEqual(results.values.filter { $0 == "ok" }.count, n, "\(results.values)")
        XCTAssertTrue(results.values.contains { $0.hasPrefix("reader ok") }, "\(results.values)")

        let pointer = try XCTUnwrap(store.readPointer())
        let previous = try XCTUnwrap(pointer.previous)
        XCTAssertNotEqual(pointer.current, previous)
        XCTAssertEqual(Set(store.generations()), [pointer.current, previous], "exactly current + previous on disk")
        for gen in [pointer.current, previous] {
            let manifest = try XCTUnwrap(store.readManifest(gen))
            XCTAssertTrue(manifest.verification.isEmpty)
            let decoded = try GedcomCompiledTree.decode(try Data(contentsOf: store.artifactURL(gen)))
            XCTAssertEqual(decoded.people.count, manifest.peopleCount)
            XCTAssertTrue(graphs.contains { $0.people.count == decoded.people.count })
        }
        // The current generation is the one whose sources the pointer names.
        XCTAssertEqual(store.readManifest(pointer.current)?.sources.map(\.key), pointer.sourceKeys)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.lockURL.path))
    }
    final class ResultSink: @unchecked Sendable {
        private let lock = NSLock()
        private var slots: [Int: String] = [:]
        init(_ n: Int) {}
        func set(_ i: Int, _ v: String) { lock.withLock { slots[i] = v } }
        var values: [String] { lock.withLock { slots.keys.sorted().map { slots[$0]! } } }
    }

    /// #797-6: rollback refuses a previous generation whose artifact no
    /// longer decodes; the pointer is untouched.
    func testRollbackRefusesCorruptPreviousArtifact() throws {
        let box = try StoreBox(); defer { box.tearDown() }
        let a = try box.write(GedcomSyntheticPedigree.gedcom(people: 120, generations: 5), as: "a.ged")
        let b = try box.write(GedcomSyntheticPedigree.gedcom(people: 130, generations: 5), as: "b.ged")
        let store = box.store()
        XCTAssertNotNil(store.ingest(graph: try XCTUnwrap(GedcomFamilyGraph(fileURL: a)), sources: [a]))
        XCTAssertNotNil(store.ingest(graph: try XCTUnwrap(GedcomFamilyGraph(fileURL: b)), sources: [b]))
        let before = try XCTUnwrap(store.readPointer())
        let previous = try XCTUnwrap(before.previous)
        // Sanity: an intact previous rolls back and forth.
        XCTAssertTrue(store.rollback())
        XCTAssertEqual(store.readPointer()?.current, previous)
        XCTAssertTrue(store.rollback())
        XCTAssertEqual(store.readPointer(), before)

        // Corrupt previous three ways; each refused, pointer untouched.
        let artifact = store.artifactURL(previous)
        let intact = try Data(contentsOf: artifact)
        for (label, bad) in [("garbage", Data("garbage".utf8)),
                             ("flipped", { var d = intact; d[d.count / 2] ^= 0xFF; return d }()),
                             ("trailing byte", intact + Data([0]))] {
            try bad.write(to: artifact)
            XCTAssertFalse(store.rollback(), label)
            XCTAssertEqual(store.readPointer(), before, "pointer untouched after \(label)")
        }
        XCTAssertTrue(box.lines.contains("rollback refused"))
        try FileManager.default.removeItem(at: artifact)
        XCTAssertFalse(store.rollback(), "missing artifact")
        XCTAssertEqual(store.readPointer(), before)
    }

    // codex #808: promoted artifacts must carry REAL source digests, for one
    // and two sources, without anyone assigning fingerprints by hand — and
    // (codex #817) the parse itself already carries them.
    func testPromotedArtifactCarriesComputedSourceSHAs() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("prov-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.ged"), b = dir.appendingPathComponent("b.ged")
        try GedcomSyntheticPedigree.gedcom(people: 60, generations: 4).write(to: a, atomically: true, encoding: .utf8)
        try GedcomSyntheticPedigree.gedcom(people: 40, generations: 3)
            .replacingOccurrences(of: "_FSFTID ", with: "_FSFTID D").write(to: b, atomically: true, encoding: .utf8)
        let shaA = try GedcomCompiledTree.fullSHA256(of: a), shaB = try GedcomCompiledTree.fullSHA256(of: b)
        let store = FamilyGraphCompiledStore(root: dir.appendingPathComponent("compiled"))

        // One source: the parse carries the digest of the bytes it read.
        let single = try XCTUnwrap(GedcomFamilyGraph(fileURL: a))
        XCTAssertEqual(single.sourceFingerprint, shaA)
        XCTAssertTrue(single.sourceProvenance.isEmpty, "plain shape as parsed")
        let promoted1 = try XCTUnwrap(store.ingest(graph: single, sources: [a]))
        XCTAssertEqual(promoted1.sourceFingerprint, shaA)
        XCTAssertEqual(promoted1.sourceProvenance.map(\.sha256), [shaA], "canonical shape after promote")
        let reread1 = try GedcomCompiledTree.decode(try Data(contentsOf: store.artifactURL(try XCTUnwrap(store.readPointer()).current)))
        XCTAssertEqual(reread1.sourceProvenance.map(\.sha256), [shaA])
        XCTAssertEqual(reread1.sourceFingerprint, shaA)

        // Two sources merged: both hashes came from the parses; the store checks them.
        let merged = try XCTUnwrap(GedcomFamilyGraph(fileURL: a)).merged(with: try XCTUnwrap(GedcomFamilyGraph(fileURL: b)))
        XCTAssertEqual(merged.sourceProvenance.map(\.sha256), [shaA, shaB])
        XCTAssertNil(merged.sourceFingerprint)
        let promoted2 = try XCTUnwrap(store.ingest(graph: merged, sources: [a, b]))
        XCTAssertEqual(promoted2.sourceProvenance.map(\.name), ["a.ged", "b.ged"])
        XCTAssertEqual(promoted2.sourceProvenance.map(\.sha256), [shaA, shaB])
        XCTAssertEqual(promoted2.totalDroppedLineCount, merged.totalDroppedLineCount)
        XCTAssertNil(promoted2.sourceFingerprint, "decode does not invent a fingerprint (#809)")
    }

    // MARK: Canonical provenance through the codec and the store (codex #809/#812/#814/#816/#817)

    /// One source with loss in BOTH places the parser counts: a top-level
    /// record it has no model for, and lines under INDI records.
    static func lossyOneSource(people: Int = 80) -> String {
        GedcomSyntheticPedigree.gedcom(people: people, generations: 4)
            .replacingOccurrences(of: "1 SEX M\n", with: "1 SEX M\n1 OCCU Farmer\n1 NOTE a line\n2 CONT another\n", options: [], range: nil)
            .replacingOccurrences(of: "0 TRLR", with: "0 @S1@ SOUR\n1 TITL Census\n2 DATE 1900\n0 @N1@ NOTE stray\n0 TRLR")
    }

    /// Every provenance figure — per-source, local, total, fingerprint —
    /// is identical before encode, after decode, on the promoted graph
    /// and in the manifest; the encoded shape is canonical (local 0 for
    /// a file parse) and the total is NOT doubled (#814).
    func testOneSourceWithLossRoundTripsProvenanceExactly() throws {
        let box = try StoreBox(); defer { box.tearDown() }
        let url = try box.write(Self.lossyOneSource(), as: "lossy.ged")
        let sha = try GedcomCompiledTree.fullSHA256(of: url)
        let graph = try XCTUnwrap(GedcomFamilyGraph(fileURL: url))
        let d = graph.droppedLineCount
        XCTAssertGreaterThan(d, 100, "top-level SOUR/NOTE records + OCCU/NOTE/CONT per man")
        XCTAssertEqual(graph.totalDroppedLineCount, d)
        XCTAssertTrue(graph.sourceProvenance.isEmpty)
        XCTAssertEqual(graph.sourceFingerprint, sha)

        // Codec: canonical out, canonical back, total unchanged.
        let decoded = try GedcomCompiledTree.decode(GedcomCompiledTree.encode(graph))
        XCTAssertEqual(decoded.sourceProvenance, [.init(name: "lossy.ged", sha256: sha, droppedLineCount: d)])
        XCTAssertEqual(decoded.droppedLineCount, 0, "local remainder of a file parse is 0")
        XCTAssertEqual(decoded.totalDroppedLineCount, d, "#814: not 2×D")
        XCTAssertEqual(decoded.sourceFingerprint, sha, "#809: decode leaves the fingerprint alone")
        XCTAssertEqual(GedcomCompiledTree.verify(decoded: decoded, against: graph), [])
        // Idempotent: encoding the decoded (already canonical) graph is byte-identical.
        XCTAssertEqual(GedcomCompiledTree.encode(decoded), GedcomCompiledTree.encode(graph))
        let again = try GedcomCompiledTree.decode(GedcomCompiledTree.encode(decoded))
        XCTAssertEqual(again.totalDroppedLineCount, d)

        // Store: promoted graph and manifest carry the same numbers.
        let store = box.store()
        let promoted = try XCTUnwrap(store.ingest(graph: graph, sources: [url]))
        XCTAssertEqual(promoted.sourceProvenance, decoded.sourceProvenance)
        XCTAssertEqual(promoted.droppedLineCount, 0)
        XCTAssertEqual(promoted.totalDroppedLineCount, d)
        let manifest = try XCTUnwrap(store.readManifest(try XCTUnwrap(store.readPointer()).current))
        XCTAssertEqual(manifest.sources.map(\.droppedLineCount), [d])
        XCTAssertEqual(manifest.sources.map(\.sha256), [sha])
        XCTAssertEqual(manifest.localDroppedLineCount, 0)
        XCTAssertEqual(manifest.totalDroppedLineCount, d)
        XCTAssertEqual(manifest.schema, 3)
        XCTAssertEqual(manifest.codec, GedcomCompiledTree.codecVersion)

        // Mutation: verify catches every provenance figure.
        var bad = promoted.sourceProvenance; bad[0].droppedLineCount += 1
        XCTAssertEqual(GedcomCompiledTree.verify(decoded: mutated(decoded, provenance: bad), against: graph).filter { $0.hasPrefix("sourceProvenance") || $0.hasPrefix("totalDropped") }.count, 2)
        XCTAssertEqual(GedcomCompiledTree.verify(decoded: mutated(decoded, droppedLineCount: 1), against: graph),
                       ["droppedLineCount (first: 1 ≠ 0)", "totalDroppedLineCount (first: \(d + 1) ≠ \(d))"])
        XCTAssertEqual(GedcomCompiledTree.verify(decoded: mutated(decoded, fingerprint: .some("0000")), against: graph),
                       ["sourceFingerprint (first: Optional(\"0000\") ≠ Optional(\"\(sha.prefix(50)))"])   // report clips each side at 60 chars
        var wrongSha = promoted.sourceProvenance; wrongSha[0].sha256 = "beef"
        XCTAssertEqual(GedcomCompiledTree.verify(decoded: mutated(decoded, provenance: wrongSha), against: graph).count, 1)
    }

    /// Two sources with different losses: per-source, local (0) and total
    /// equal at every stage; a mutation of either entry is caught.
    func testMultiSourceProvenanceRoundTripsExactly() throws {
        let box = try StoreBox(); defer { box.tearDown() }
        let a = try box.write(Self.lossyOneSource(people: 60), as: "a.ged")
        let b = try box.write(GedcomSyntheticPedigree.gedcom(people: 40, generations: 3)
            .replacingOccurrences(of: "_FSFTID ", with: "_FSFTID D")
            .replacingOccurrences(of: "0 TRLR", with: "0 @O1@ OBJE\n1 FILE p.jpg\n0 TRLR"), as: "b.ged")
        let ga = try XCTUnwrap(GedcomFamilyGraph(fileURL: a)), gb = try XCTUnwrap(GedcomFamilyGraph(fileURL: b))
        XCTAssertEqual(gb.droppedLineCount, 2)
        let merged = ga.merged(with: gb)
        let expected: [GedcomFamilyGraph.SourceProvenance] = [
            .init(name: "a.ged", sha256: try GedcomCompiledTree.fullSHA256(of: a), droppedLineCount: ga.droppedLineCount),
            .init(name: "b.ged", sha256: try GedcomCompiledTree.fullSHA256(of: b), droppedLineCount: 2),
        ]
        XCTAssertEqual(merged.sourceProvenance, expected)
        XCTAssertEqual(merged.droppedLineCount, 0)
        let total = ga.droppedLineCount + 2
        XCTAssertEqual(merged.totalDroppedLineCount, total)

        let decoded = try GedcomCompiledTree.decode(GedcomCompiledTree.encode(merged))
        XCTAssertEqual(decoded.sourceProvenance, expected)
        XCTAssertEqual(decoded.droppedLineCount, 0)
        XCTAssertEqual(decoded.totalDroppedLineCount, total)
        XCTAssertNil(decoded.sourceFingerprint)
        XCTAssertEqual(GedcomCompiledTree.verify(decoded: decoded, against: merged), [])

        let store = box.store()
        let promoted = try XCTUnwrap(store.ingest(graph: merged, sources: [a, b]))
        XCTAssertEqual(promoted.sourceProvenance, expected)
        XCTAssertEqual(promoted.totalDroppedLineCount, total)
        let manifest = try XCTUnwrap(store.readManifest(try XCTUnwrap(store.readPointer()).current))
        XCTAssertEqual(manifest.sources.map { GedcomFamilyGraph.SourceProvenance(name: $0.fileName, sha256: $0.sha256, droppedLineCount: $0.droppedLineCount) }, expected)
        XCTAssertEqual(manifest.localDroppedLineCount, 0)
        XCTAssertEqual(manifest.totalDroppedLineCount, total)

        var bad = expected; bad[1].droppedLineCount = 3
        XCTAssertFalse(GedcomCompiledTree.verify(decoded: mutated(decoded, provenance: bad), against: merged).isEmpty)
        XCTAssertFalse(GedcomCompiledTree.verify(decoded: mutated(decoded, provenance: Array(expected.reversed())), against: merged).isEmpty, "order is part of provenance")
        XCTAssertFalse(GedcomCompiledTree.verify(decoded: mutated(decoded, provenance: [expected[0]]), against: merged).isEmpty)
    }

    /// #812 (codec 3 → 4) and 2026-08-29 (codec 4 → 5, index 1 → 2): a
    /// blob with an older header version is refused with
    /// `versionMismatch` and the store's `versionsMatch` rejects an older
    /// pointer ("schema changed" → recompile).
    func testOlderCodecArtifactAndPointerAreRejected() throws {
        XCTAssertEqual(GedcomCompiledTree.codecVersion, 5)
        XCTAssertEqual(GedcomFamilyGraph.TreeIndex.formatVersion, 2)
        let graph = GedcomFamilyGraph(gedcomText: GedcomSyntheticPedigree.gedcom(people: 30, generations: 3))
        for older: UInt32 in [3, 4] {
            var blob = GedcomCompiledTree.encode(graph)
            // Header: "VSFT" | u32 codec | u32 index — patch the codec.
            blob.replaceSubrange(4..<8, with: GedcomCompiledTree.le(older))
            XCTAssertThrowsError(try GedcomCompiledTree.decode(blob)) { error in
                XCTAssertEqual(error as? GedcomCompiledTree.CodecError,
                               .versionMismatch(codec: older, index: GedcomFamilyGraph.TreeIndex.formatVersion))
            }
        }
        var oldIndex = GedcomCompiledTree.encode(graph)
        oldIndex.replaceSubrange(8..<12, with: GedcomCompiledTree.le(UInt32(1)))
        XCTAssertThrowsError(try GedcomCompiledTree.decode(oldIndex)) { error in
            XCTAssertEqual(error as? GedcomCompiledTree.CodecError,
                           .versionMismatch(codec: GedcomCompiledTree.codecVersion, index: 1))
        }
        let ok = FamilyGraphCompiledStore.Pointer(schema: FamilyGraphCompiledStore.schemaVersion, codec: 5,
                                                  index: GedcomFamilyGraph.TreeIndex.formatVersion,
                                                  current: "gen-x", previous: nil, sourceKeys: ["k"])
        XCTAssertTrue(FamilyGraphCompiledStore.versionsMatch(ok))
        for older: UInt32 in [3, 4] {
            var old = ok; old.codec = older
            XCTAssertFalse(FamilyGraphCompiledStore.versionsMatch(old))
        }
        var oldIndexPointer = ok; oldIndexPointer.index = 1
        XCTAssertFalse(FamilyGraphCompiledStore.versionsMatch(oldIndexPointer))

        // On disk: a codec-3 pointer makes load/loadCurrent a logged miss.
        let box = try StoreBox(); defer { box.tearDown() }
        let url = try box.write(GedcomSyntheticPedigree.gedcom(people: 30, generations: 3), as: "t.ged")
        let store = box.store()
        XCTAssertNotNil(store.ingest(graph: try XCTUnwrap(GedcomFamilyGraph(fileURL: url)), sources: [url]))
        var pointer = try XCTUnwrap(store.readPointer())
        pointer.codec = 4
        try JSONEncoder().encode(pointer).write(to: store.pointerURL)
        XCTAssertNil(store.load(sources: [url]))
        XCTAssertNil(store.loadCurrent())
        XCTAssertTrue(box.lines.contains("schema changed"), "\(box.lines.all)")
    }

    /// #816: sources bind to provenance by POSITION. Two pulls with the
    /// same basename in different directories work (bound by position);
    /// reordered URLs, a wrong URL, or a hash the graph did not carry are
    /// refused — nothing promoted, pointer untouched — and the promoted
    /// artifact's provenance equals the manifest's sources.
    func testStoreBindsSourcesPositionallyAndFailsClosed() throws {
        let box = try StoreBox(); defer { box.tearDown() }
        let dirX = box.root.appendingPathComponent("x"), dirY = box.root.appendingPathComponent("y")
        try FileManager.default.createDirectory(at: dirX, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirY, withIntermediateDirectories: true)
        let x = dirX.appendingPathComponent("pull.ged"), y = dirY.appendingPathComponent("pull.ged")
        try Self.lossyOneSource(people: 50).write(to: x, atomically: true, encoding: .utf8)
        try GedcomSyntheticPedigree.gedcom(people: 30, generations: 3)
            .replacingOccurrences(of: "_FSFTID ", with: "_FSFTID Y").write(to: y, atomically: true, encoding: .utf8)
        let other = try box.write(GedcomSyntheticPedigree.gedcom(people: 20, generations: 3), as: "other.ged")
        let gx = try XCTUnwrap(GedcomFamilyGraph(fileURL: x)), gy = try XCTUnwrap(GedcomFamilyGraph(fileURL: y))
        let merged = gx.merged(with: gy)
        XCTAssertEqual(merged.sourceProvenance.map(\.name), ["pull.ged", "pull.ged"], "duplicate basenames are legal")
        let store = box.store()

        // Refusals first (no pointer exists yet → still none afterwards).
        XCTAssertNil(store.ingest(graph: merged, sources: [y, x]), "reordered: names match but the hashes do not")
        XCTAssertTrue(box.lines.contains("REFUSED") && box.lines.contains("hashes to"), "\(box.lines.all)")
        XCTAssertNil(store.ingest(graph: merged, sources: [x, other]), "wrong URL: basename differs")
        XCTAssertTrue(box.lines.contains("is other.ged"), "\(box.lines.all)")
        XCTAssertNil(store.ingest(graph: merged, sources: [x]), "count differs")
        XCTAssertTrue(box.lines.contains("lists 2 sources but 1 was given"), "\(box.lines.all)")
        XCTAssertNil(store.readPointer(), "nothing promoted")
        XCTAssertEqual(store.generations(), [], "refused generations are removed")

        // The right binding: works, and artifact provenance == manifest sources.
        let promoted = try XCTUnwrap(store.ingest(graph: merged, sources: [x, y]))
        let pointer = try XCTUnwrap(store.readPointer())
        let manifest = try XCTUnwrap(store.readManifest(pointer.current))
        XCTAssertEqual(manifest.sources.map(\.path), [x.path, y.path])
        XCTAssertEqual(promoted.sourceProvenance.map(\.name), manifest.sources.map(\.fileName))
        XCTAssertEqual(promoted.sourceProvenance.map(\.sha256), manifest.sources.map(\.sha256))
        XCTAssertEqual(promoted.sourceProvenance.map(\.droppedLineCount), manifest.sources.map(\.droppedLineCount))
        XCTAssertEqual(pointer.sourceKeys, manifest.sources.map(\.key))
        XCTAssertEqual(manifest.totalDroppedLineCount, merged.totalDroppedLineCount)

        // A later refusal leaves the promoted pointer untouched.
        XCTAssertNil(store.ingest(graph: merged, sources: [y, x]))
        XCTAssertEqual(store.readPointer(), pointer)
        XCTAssertEqual(store.generations(), [pointer.current])
    }

    /// #817: parse, then rewrite the file's bytes before ingest. The graph
    /// carries the digest of what it parsed; the store hashes what is on
    /// disk now; they differ → refused, nothing promoted, pointer untouched.
    func testRewriteBetweenParseAndIngestIsRefused() throws {
        let box = try StoreBox(); defer { box.tearDown() }
        let url = try box.write(Self.lossyOneSource(people: 40), as: "pull.ged")
        let store = box.store()
        // A good generation first, so "pointer untouched" is observable.
        let first = try XCTUnwrap(store.ingest(graph: try XCTUnwrap(GedcomFamilyGraph(fileURL: url)), sources: [url]))
        let before = try XCTUnwrap(store.readPointer())

        let graph = try XCTUnwrap(GedcomFamilyGraph(fileURL: url))
        _ = try box.write(GedcomSyntheticPedigree.gedcom(people: 41, generations: 4), as: "pull.ged")   // mid-ingest rewrite
        XCTAssertNil(store.ingest(graph: graph, sources: [url]))
        XCTAssertTrue(box.lines.contains("file changed since it was read"), "\(box.lines.all)")
        XCTAssertEqual(store.readPointer(), before, "pointer untouched")
        XCTAssertEqual(store.generations(), [before.current])
        XCTAssertEqual(try GedcomCompiledTree.decode(try Data(contentsOf: store.artifactURL(before.current))).people.count, first.people.count)

        // Same for a two-source merge where only the second file moved.
        let b = try box.write(GedcomSyntheticPedigree.gedcom(people: 20, generations: 3)
            .replacingOccurrences(of: "_FSFTID ", with: "_FSFTID B"), as: "b.ged")
        let merged = try XCTUnwrap(GedcomFamilyGraph(fileURL: url)).merged(with: try XCTUnwrap(GedcomFamilyGraph(fileURL: b)))
        _ = try box.write(GedcomSyntheticPedigree.gedcom(people: 21, generations: 3), as: "b.ged")
        XCTAssertNil(store.ingest(graph: merged, sources: [url, b]))
        XCTAssertTrue(box.lines.contains("source #2 b.ged hashes to"), "\(box.lines.all)")
        XCTAssertEqual(store.readPointer(), before)
    }
}
