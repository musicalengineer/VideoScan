// GedcomCompiledTree+Decoding.swift (VideoScanCore)
import Foundation

extension GedcomCompiledTree {
    /// Payload = string table | people | families | roots | FS index |
    /// provenance | index arrays. Trusts nothing: every length and every
    /// reference is checked before use.
    static func parsePayload(_ raw: UnsafeRawBufferPointer) throws -> GedcomFamilyGraph {
        var clock = PhaseClock()
        var reader = Reader(bytes: raw)
        let strings = try readStrings(from: &reader)
        reader.strings = strings
        clock.lap("strings")

        // People (chunked section, parallel), then the id → record map.
        let peopleInOrder = try reader.chunkedSection { try readPerson(from: &$0) }
        clock.lap("people parse")
        let (people, ids) = mapPeople(peopleInOrder)
        clock.lap("people map")

        let familiesInOrder = try reader.chunkedSection { try readFamily(from: &$0) }
        clock.lap("families parse")
        let families = mapFamilies(familiesInOrder)
        clock.lap("families map")
        let roots = try reader.stringArray()
        let metadata = try GraphMetadata(from: &reader)
        clock.lap("fs index + provenance")

        let index = try readIndex(from: &reader, ids: ids, clock: &clock)
        let graph = metadata.graph(people: people, families: families, roots: roots)
        graph.indexBox.install(index)
        clock.lap("sanity + assemble")
        return graph
    }

    private static func readStrings(from r: inout Reader) throws -> [String] {
        let stringCount = Int(try r.u32())
        let blobLength = Int(try r.u32())
        // Read-only for the life of this function; shared by the parallel
        // String build below (see its race-free note).
        nonisolated(unsafe) let blob = try r.slice(blobLength)
        let offsets = try r.i32s(expected: stringCount + 1)
        // String table: offsets must be monotonic within the blob (one
        // sequential pass of integer compares), then the Strings are made
        // in parallel chunks — each slot written exactly once.
        guard offsets.first == 0 || stringCount == 0 else { throw CodecError.corrupt("string table") }
        for i in 0..<stringCount where !(offsets[i] >= 0 && offsets[i] <= offsets[i + 1] && Int(offsets[i + 1]) <= blobLength) {
            throw CodecError.corrupt("string table")
        }
        let strings = [String](unsafeUninitializedCapacity: stringCount) { buffer, initialized in
            let chunks = Self.chunkCount(stringCount)
            // Race-free: chunk c initializes slots [c*chunkSize, …) only —
            // disjoint ranges, each slot written exactly once — and
            // concurrentPerform returns only after every iteration finishes,
            // so `initialized` is set after all writes. Copying the pointer
            // (not the inout binding) into the closure is what strict
            // concurrency needs; the pointee is unchanged.
            nonisolated(unsafe) let slots = buffer
            DispatchQueue.concurrentPerform(iterations: chunks) { c in
                let lo = c * chunkSize, hi = min(stringCount, lo + chunkSize)
                for i in lo..<hi {
                    let a = Int(offsets[i]), b = Int(offsets[i + 1])
                    (slots.baseAddress! + i).initialize(
                        to: String(decoding: UnsafeRawBufferPointer(rebasing: blob[a..<b]), as: UTF8.self))
                }
            }
            initialized = stringCount
        }
        return strings
    }

    private static func readPerson(from r: inout Reader) throws -> GedcomFamilyGraph.Person {
        let id = try r.string()
        var p = GedcomFamilyGraph.Person(id: id, name: try r.string(), sex: try r.string(),
                                         childOfFamily: try r.optionalString())
        p.birthDate = try r.optionalString()
        p.deathDate = try r.optionalString()
        p.birthPlace = try r.optionalString()
        p.deathPlace = try r.optionalString()
        p.surname = try r.optionalString()
        p.familySearchID = try r.optionalString()
        p.alternateNames = try r.stringArray()
        p.alternateSurnames = try r.stringArray()
        p.childOfFamilies = try r.stringArray()
        p.spouseOfFamilies = try r.stringArray()
        let military = try r.stringArray()   // codec 7
        guard military.count % militaryFactWidth == 0 else { throw CodecError.corrupt("military facts") }
        if !military.isEmpty {
            func field(_ s: String) -> String? { s.isEmpty ? nil : s }
            p.militaryFacts = stride(from: 0, to: military.count, by: militaryFactWidth).map { i in
                GedcomFamilyGraph.MilitaryFact(
                    tag: military[i], value: field(military[i + 1]), type: field(military[i + 2]),
                    date: field(military[i + 3]), place: field(military[i + 4]), note: field(military[i + 5]))
            }
        }
        return p
    }

    private static func mapPeople(_ peopleInOrder: [GedcomFamilyGraph.Person])
        -> (people: [String: GedcomFamilyGraph.Person], ids: [String]) {
        let personCount = peopleInOrder.count
        var people: [String: GedcomFamilyGraph.Person] = [:]
        people.reserveCapacity(personCount)
        var ids: [String] = []
        ids.reserveCapacity(personCount)
        for p in peopleInOrder {
            people[p.id] = p
            ids.append(p.id)
        }
        return (people, ids)
    }

    private static func readFamily(from r: inout Reader) throws -> (String, GedcomFamilyGraph.Family) {
        let id = try r.string()
        var f = GedcomFamilyGraph.Family()
        f.husband = try r.optionalString()
        f.wife = try r.optionalString()
        f.marriageDate = try r.optionalString()
        f.children = try r.stringArray()
        f.familySearchID = try r.optionalString()   // codec 6
        return (id, f)
    }

    private static func mapFamilies(_ familiesInOrder: [(String, GedcomFamilyGraph.Family)])
        -> [String: GedcomFamilyGraph.Family] {
        var families: [String: GedcomFamilyGraph.Family] = [:]
        families.reserveCapacity(familiesInOrder.count)
        for (id, f) in familiesInOrder { families[id] = f }
        return families
    }

    private static func readIndex(from r: inout Reader, ids: [String], clock: inout PhaseClock)
        throws -> GedcomFamilyGraph.TreeIndex {
        let personCount = ids.count
        let nameRank = try r.i32s(expected: personCount)
        let parentStart = try r.i32s(expected: personCount + 1)
        let parents = try r.i32s()
        let motherOffset = try r.i32s(expected: personCount)
        let childStart = try r.i32s(expected: personCount + 1)
        let children = try r.i32s()
        let spouseStart = try r.i32s(expected: personCount + 1)
        let spouses = try r.i32s()
        let tables = try readPostingTables(from: &r)
        let recordStart = try r.i32s(expected: personCount + 1)
        let recordTokenStart = try r.i32s()
        let recordTokenIDs = try r.i32s()
        let recordLikeIDs = try r.i32s(expected: recordTokenIDs.count)
        let marriedStart = try r.i32s(expected: personCount + 1)
        let marriedIDs = try r.i32s()
        let surnameStart = try r.i32s(expected: personCount + 1)
        let surnameIDs = try r.i32s()
        let sidebarOrder = try r.i32s(expected: personCount)
        let haystack = try r.byteArray()
        let sidebarStart = try r.i32s(expected: personCount + 1)
        // Launch tables (TreeIndex formatVersion 2)
        let identityKeys = try r.stringArray()
        let givenStart = try r.i32s(expected: personCount + 1)
        let givenIDs = try r.i32s()
        let surnameTokenStart = try r.i32s(expected: personCount + 1)
        let surnameTokenIDs = try r.i32s()
        let suffixIDs = try r.i32s(expected: personCount)
        let lifeYears = try r.stringArray()
        guard lifeYears.count == personCount else { throw CodecError.corrupt("lifeYears length") }
        guard r.atEnd else { throw CodecError.corrupt("trailing bytes") }
        clock.lap("index arrays")
        try validateOrdinals([parents, children, spouses, sidebarOrder], personCount: personCount)
        try validateIdentityTable(keys: identityKeys, givenIDs: givenIDs, surnameTokenIDs: surnameTokenIDs,
                                  suffixIDs: suffixIDs, givenStart: givenStart, surnameTokenStart: surnameTokenStart)

        return GedcomFamilyGraph.TreeIndex(
            ids: ids, nameRank: nameRank,
            parentStart: parentStart, parents: parents, motherOffset: motherOffset,
            childStart: childStart, children: children,
            spouseStart: spouseStart, spouses: spouses,
            tokens: tables[0], likeTokens: tables[1], surnames: tables[2],
            givenNames: tables[3], familySearchIDs: tables[4],
            recordStart: recordStart, recordTokenStart: recordTokenStart,
            recordTokenIDs: recordTokenIDs, recordLikeIDs: recordLikeIDs,
            marriedStart: marriedStart, marriedIDs: marriedIDs,
            surnameStart: surnameStart, surnameIDs: surnameIDs,
            sidebarOrder: sidebarOrder, sidebarHaystack: haystack, sidebarStart: sidebarStart,
            identityKeys: identityKeys, givenStart: givenStart, givenIDs: givenIDs,
            surnameTokenStart: surnameTokenStart, surnameTokenIDs: surnameTokenIDs,
            suffixIDs: suffixIDs, lifeYears: lifeYears)
    }

    private static func readPostingTables(from r: inout Reader) throws -> [GedcomFamilyGraph.PostingTable] {
        var tables: [GedcomFamilyGraph.PostingTable] = []
        for _ in 0..<5 {
            let keys = try r.stringArray()
            let start = try r.i32s(expected: keys.count + 1)
            let postings = try r.i32s()
            guard start.last.map(Int.init) == postings.count else { throw CodecError.corrupt("postings") }
            tables.append(.init(keys: keys, start: start, postings: postings))
        }
        return tables
    }

    // Cheap structural sanity: every ordinal / key position in range.
    private static func validateOrdinals(_ lists: [[Int32]], personCount: Int) throws {
        for list in lists {
            guard list.allSatisfy({ $0 >= 0 && Int($0) < personCount }) else { throw CodecError.corrupt("ordinal") }
        }
    }

    private static func validateIdentityTable(keys: [String], givenIDs: [Int32], surnameTokenIDs: [Int32],
                                              suffixIDs: [Int32], givenStart: [Int32], surnameTokenStart: [Int32]) throws {
        let keyCount = Int32(keys.count)
        guard givenIDs.allSatisfy({ $0 >= 0 && $0 < keyCount }),
              surnameTokenIDs.allSatisfy({ $0 >= 0 && $0 < keyCount }),
              suffixIDs.allSatisfy({ $0 >= -1 && $0 < keyCount }),
              givenStart.last.map(Int.init) == givenIDs.count,
              surnameTokenStart.last.map(Int.init) == surnameTokenIDs.count
        else { throw CodecError.corrupt("identity table") }
    }

    /// Values read before the index; graph assembly waits until index validation succeeds.
    private struct GraphMetadata {
        let fsIndex: [String: String]
        let sourceFileName: String?
        let sourceDirectory: String?
        let modified: Double
        let sourceFileNames: [String]
        let isMerged: Bool
        let droppedLines: Int
        let headNote: String?
        let provenance: [GedcomFamilyGraph.SourceProvenance]
        let sourceFingerprint: String?

        init(from r: inout Reader) throws {
            let fsCount = Int(try r.u32())
            var fsIndex: [String: String] = [:]
            fsIndex.reserveCapacity(fsCount)
            for _ in 0..<fsCount { fsIndex[try r.string()] = try r.string() }
            sourceFileName = try r.optionalString()
            sourceDirectory = try r.optionalString()
            modified = try r.f64()
            sourceFileNames = try r.stringArray()
            isMerged = try r.u32() != 0
            droppedLines = Int(try r.u32())
            headNote = try r.optionalString()
            let provenanceCount = Int(try r.u32())
            var provenance: [GedcomFamilyGraph.SourceProvenance] = []
            provenance.reserveCapacity(provenanceCount)
            for _ in 0..<provenanceCount {
                provenance.append(.init(name: try r.string(), sha256: try r.optionalString(), droppedLineCount: Int(try r.u32())))
            }
            sourceFingerprint = try r.optionalString()
            self.fsIndex = fsIndex
            self.provenance = provenance
        }

        func graph(people: [String: GedcomFamilyGraph.Person], families: [String: GedcomFamilyGraph.Family],
                   roots: [String]) -> GedcomFamilyGraph {
            var graph = GedcomFamilyGraph(
                decodedPeople: people, families: families, rootPersonIDs: roots,
                personIDByFamilySearchID: fsIndex,
                sourceFileName: sourceFileName, sourceDirectory: sourceDirectory,
                sourceModifiedAt: modified.isNaN ? nil : Date(timeIntervalSince1970: modified),
                sourceFileNames: sourceFileNames, isMergedArtifact: isMerged,
                droppedLineCount: droppedLines, headNote: headNote)
            graph.sourceProvenance = provenance
            graph.sourceFingerprint = sourceFingerprint
            return graph
        }
    }
}
