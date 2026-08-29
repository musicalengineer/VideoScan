import XCTest
@testable import VideoScanCore

/// The launch tables (TreeIndex formatVersion 2, 2026-08-29) and the
/// ordinal AncestorIndex must reproduce EXACTLY what the code they
/// replace computed. The reference implementations below are the
/// pre-change versions, copied verbatim and frozen (do not "fix").
final class GedcomLaunchTablesEquivalenceTests: XCTestCase {
    static let bigTree = URL(fileURLWithPath:
        "/Volumes/FamilyArchive/Breen_Family_Archive/40_Family_Tree/GEDCOM/familysearch-tree-20generations.ged")

    // MARK: Frozen: FamilyAssetIdentityDirectory pass 1 (2026-08-26 builder)

    struct FrozenDraft: Equatable {
        let id: String
        let given: Set<String>
        let surnames: Set<String>
        let suffix: String?
    }

    static func frozenDrafts(_ graph: GedcomFamilyGraph) -> [FrozenDraft] {
        let suffixes = GedcomFamilyGraph.nameSuffixes
        var drafts: [FrozenDraft] = []
        for person in graph.people.values {
            let surname = FamilyIdentityText.tokens(person.surname ?? "")
            var surnames = Set(surname)
            for unit in graph.familyUnits(of: person) {
                if let spouse = unit.spouse { surnames.formUnion(FamilyIdentityText.tokens(spouse.surname ?? "")) }
            }
            let nameTokens = FamilyIdentityText.tokens(person.name)
            let suffix = nameTokens.last(where: { suffixes.contains($0) })
            let given = Set(nameTokens.filter { !suffixes.contains($0) && !surnames.contains($0) })
            drafts.append(FrozenDraft(id: person.id, given: given, surnames: surnames, suffix: suffix))
        }
        return drafts.sorted { $0.id < $1.id }
    }

    /// What the index says, in the same shape.
    static func indexedDrafts(_ graph: GedcomFamilyGraph) -> [FrozenDraft] {
        let index = graph.index
        return (0..<index.count).map { i in
            let o = Int32(i)
            return FrozenDraft(
                id: index.ids[i],
                given: Set(index.givenIDs(of: o).map { index.identityKeys[Int($0)] }),
                surnames: Set(index.surnameTokenIDs(of: o).map { index.identityKeys[Int($0)] }),
                suffix: index.suffixIDs[i] < 0 ? nil : index.identityKeys[Int(index.suffixIDs[i])])
        }
    }

    // MARK: Frozen: FamilyTreeLiveModel.years (2026-08-22)

    static func frozenYear(in raw: String?) -> Int? {
        guard let raw else { return nil }
        var digits = ""
        for character in raw {
            if character.isNumber {
                digits.append(character)
            } else {
                if digits.count == 4, let year = Int(digits) { return year }
                digits.removeAll(keepingCapacity: true)
            }
        }
        return digits.count == 4 ? Int(digits) : nil
    }

    static func frozenYears(birth: String?, death: String?) -> String? {
        let birthYear = frozenYear(in: birth)
        let deathYear = frozenYear(in: death)
        switch (birthYear, deathYear) {
        case let (b?, d?):
            return "\(b)–\(d)"
        case let (b?, nil):
            if let death, !death.isEmpty { return "\(b) – d. \(death)" }
            return "b. \(b)"
        case let (nil, d?):
            if let birth, !birth.isEmpty { return "b. \(birth) – \(d)" }
            return "d. \(d)"
        case (nil, nil):
            let parts = [birth.map { "b. \($0)" }, death.map { "d. \($0)" }]
                .compactMap { $0 }
                .filter { $0.count > 3 }
            return parts.isEmpty ? nil : parts.joined(separator: " – ")
        }
    }

    // MARK: Frozen: string-keyed AncestorIndex + commonAncestors (2026-08-28)

    struct FrozenAncestorIndex {
        let descendantID: String
        let childToward: [String: String]
        let depths: [String: Int]
        let people: [String: GedcomFamilyGraph.Person]

        init(graph: GedcomFamilyGraph, descendantID: String) {
            self.descendantID = descendantID
            self.people = graph.people
            var cameFrom: [String: String] = [:]
            var depth: [String: Int] = [:]
            let index = graph.index
            guard graph.people[descendantID] != nil, let startOrdinal = index.ordinal(of: descendantID) else {
                childToward = [:]; depths = [:]; return
            }
            var visited = [Bool](repeating: false, count: index.count)
            visited[Int(startOrdinal)] = true
            var cameFromOrdinal: [(parent: Int32, child: Int32, level: Int)] = []
            var frontier: [Int32] = [startOrdinal]
            var level = 0
            while !frontier.isEmpty {
                var next: [Int32] = []
                level += 1
                for child in frontier {
                    for parent in index.parents(of: child) where !visited[Int(parent)] {
                        visited[Int(parent)] = true
                        cameFromOrdinal.append((parent, child, level))
                        next.append(parent)
                    }
                }
                frontier = next
            }
            for entry in cameFromOrdinal {
                let parentID = index.ids[Int(entry.parent)]
                cameFrom[parentID] = index.ids[Int(entry.child)]
                depth[parentID] = entry.level
            }
            childToward = cameFrom
            depths = depth
        }

        func generations(from ancestorID: String) -> Int? {
            ancestorID == descendantID ? nil : depths[ancestorID]
        }

        func path(from ancestorID: String) -> [GedcomFamilyGraph.Person]? {
            guard ancestorID != descendantID, childToward[ancestorID] != nil else { return nil }
            var path: [GedcomFamilyGraph.Person] = []
            var current: String? = ancestorID
            while let id = current, let person = people[id] {
                path.append(person)
                current = id == descendantID ? nil : childToward[id]
            }
            return path.last?.id == descendantID ? path : nil
        }
    }

    static func frozenCommonAncestors(_ graph: GedcomFamilyGraph, _ a: String, _ b: String, limit: Int? = nil)
        -> [GedcomFamilyGraph.CommonAncestor] {
        guard a != b, graph.people[a] != nil, graph.people[b] != nil else { return [] }
        let indexA = FrozenAncestorIndex(graph: graph, descendantID: a)
        let indexB = FrozenAncestorIndex(graph: graph, descendantID: b)
        let depthsA = indexA.depths, depthsB = indexB.depths
        let small = depthsA.count <= depthsB.count ? depthsA : depthsB
        var hits: [(id: String, dA: Int, dB: Int)] = []
        for (id, _) in small {
            guard let dA = depthsA[id], let dB = depthsB[id] else { continue }
            hits.append((id, dA, dB))
        }
        hits.sort { x, y in
            if x.dA + x.dB != y.dA + y.dB { return x.dA + x.dB < y.dA + y.dB }
            if x.dA != y.dA { return x.dA < y.dA }
            let nx = graph.people[x.id]?.name ?? "", ny = graph.people[y.id]?.name ?? ""
            return nx == ny ? x.id < y.id : nx < ny
        }
        let kept = limit.map { Array(hits.prefix($0)) } ?? hits
        return kept.compactMap { hit in
            guard let person = graph.people[hit.id],
                  let pathA = indexA.path(from: hit.id), let pathB = indexB.path(from: hit.id) else { return nil }
            return GedcomFamilyGraph.CommonAncestor(person: person, depthA: hit.dA, depthB: hit.dB, pathA: pathA, pathB: pathB)
        }
    }

    // MARK: The checks

    func check(_ graph: GedcomFamilyGraph, label: String, pairs: Int = 40) {
        let index = graph.index
        // Identity drafts: every person, every token set, the suffix.
        XCTAssertEqual(Self.indexedDrafts(graph), Self.frozenDrafts(graph), "\(label): identity tables differ")
        // Life-years label, every person.
        for (i, id) in index.ids.enumerated() {
            let p = graph.people[id]!
            XCTAssertEqual(index.lifeYears[i], Self.frozenYears(birth: p.birthDate, death: p.deathDate) ?? "",
                           "\(label): lifeYears differs for \(id)")
            XCTAssertEqual(GedcomFamilyGraph.lifeYearsLabel(birth: p.birthDate, death: p.deathDate),
                           Self.frozenYears(birth: p.birthDate, death: p.deathDate))
        }
        // Ancestor index + common ancestors on deterministic pairs: the
        // roots, the last id, and a stride of ids.
        var probes = graph.rootPersonIDs
        let sortedIDs = index.ids
        let stride = max(1, sortedIDs.count / pairs)
        for i in Swift.stride(from: 0, to: sortedIDs.count, by: stride) { probes.append(sortedIDs[i]) }
        probes.append(sortedIDs.last!)
        for id in probes {
            let fresh = GedcomFamilyGraph.AncestorIndex(graph: graph, descendantID: id)
            let frozen = FrozenAncestorIndex(graph: graph, descendantID: id)
            XCTAssertEqual(fresh.depths, frozen.depths, "\(label): depths differ for \(id)")
            XCTAssertEqual(fresh.maxDepth, frozen.depths.values.max() ?? 0)
            XCTAssertEqual(fresh.ancestorCount, frozen.depths.count)
            for ancestor in frozen.depths.keys.sorted().prefix(50) {
                XCTAssertEqual(fresh.generations(from: ancestor), frozen.generations(from: ancestor))
                XCTAssertEqual(fresh.path(from: ancestor), frozen.path(from: ancestor), "\(label): path differs \(ancestor) → \(id)")
            }
            XCTAssertNil(fresh.generations(from: id))
            XCTAssertNil(fresh.path(from: id))
        }
        for (a, b) in zip(probes, probes.dropFirst()) {
            XCTAssertEqual(graph.commonAncestors(of: a, and: b), Self.frozenCommonAncestors(graph, a, b), "\(label): common \(a)/\(b)")
            XCTAssertEqual(graph.commonAncestors(of: a, and: b, limit: 3), Self.frozenCommonAncestors(graph, a, b, limit: 3))
            XCTAssertEqual(graph.ancestorDepth(of: a), FrozenAncestorIndex(graph: graph, descendantID: a).depths.values.max() ?? 0)
        }
        XCTAssertEqual(graph.commonAncestors(of: "@NOPE@", and: probes[0]), [])
        XCTAssertEqual(graph.commonAncestors(of: probes[0], and: probes[0]), [])
    }

    func testEdgeCases() {
        // Suffix in the middle, surname tokens inside the given name, a
        // dangling FAMS, a self-spouse family, a woman with two marriages,
        // a two-token surname, an undated and a partially dated person.
        let gedcom = """
        0 HEAD
        0 @I1@ INDI
        1 NAME Richard Harding /Breen/ Jr
        1 SEX M
        1 BIRT
        2 DATE 4 MAR 1959
        1 FAMS @F1@
        1 FAMS @F9@
        1 FAMC @F2@
        0 @I2@ INDI
        1 NAME Donna Marie /Hudson/
        1 SEX F
        1 BIRT
        2 DATE ABT 1960
        1 FAMS @F1@
        1 FAMS @F3@
        0 @I3@ INDI
        1 NAME Van Buren /Van Buren/ III
        1 SEX M
        1 DEAT
        2 DATE BEF 1 MAY
        1 FAMS @F3@
        0 @I4@ INDI
        1 NAME Richard Harding /Breen/ Sr
        1 SEX M
        1 BIRT
        2 DATE 1929
        1 DEAT
        2 DATE 12 DEC 2008
        1 FAMS @F2@
        0 @I5@ INDI
        1 NAME Édith /Mc Gill/
        1 SEX F
        1 FAMS @F2@
        1 FAMS @F4@
        0 @I6@ INDI
        1 NAME
        1 SEX U
        1 FAMS @F4@
        1 FAMC @F1@
        0 @F1@ FAM
        1 HUSB @I1@
        1 WIFE @I2@
        1 CHIL @I6@
        0 @F2@ FAM
        1 HUSB @I4@
        1 WIFE @I5@
        1 CHIL @I1@
        0 @F3@ FAM
        1 HUSB @I3@
        1 WIFE @I2@
        0 @F4@ FAM
        1 HUSB @I5@
        1 WIFE @I5@
        1 CHIL @I6@
        0 TRLR
        """
        let graph = GedcomFamilyGraph(gedcomText: gedcom)
        XCTAssertEqual(graph.people.count, 6)
        check(graph, label: "edge", pairs: 6)
        // And through the artifact.
        let decoded = try! GedcomCompiledTree.decode(GedcomCompiledTree.encode(graph))
        XCTAssertEqual(decoded.index, graph.index)
        check(decoded, label: "edge-decoded", pairs: 6)
    }

    func testSynthetic39kMatchesFrozenReference() throws {
        let graph = GedcomFamilyGraph(gedcomText: GedcomSyntheticPedigree.gedcom(people: 39_250))
        check(graph, label: "39k")
        let decoded = try GedcomCompiledTree.decode(GedcomCompiledTree.encode(graph))
        XCTAssertEqual(decoded.index, graph.index)
        XCTAssertEqual(decoded.people, graph.people)
    }

    func testRealExportMatchesFrozenReference() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.bigTree.path), "archive not mounted")
        let graph = try XCTUnwrap(GedcomFamilyGraph(fileURL: Self.bigTree))
        check(graph, label: "real")
    }

    /// Chunk boundaries are invisible: a tree whose people count is not a
    /// multiple of the chunk size, one that is, and one under a chunk.
    func testChunkBoundariesRoundTrip() throws {
        for n in [1, 2, GedcomCompiledTree.chunkSize - 1, GedcomCompiledTree.chunkSize,
                  GedcomCompiledTree.chunkSize + 1, 3 * GedcomCompiledTree.chunkSize + 7] {
            let graph = GedcomFamilyGraph(gedcomText: GedcomSyntheticPedigree.gedcom(people: n, generations: 12))
            let data = GedcomCompiledTree.encode(graph)
            let decoded = try GedcomCompiledTree.decode(data)
            XCTAssertEqual(decoded.people, graph.people, "n=\(n)")
            XCTAssertEqual(decoded.familyCount, graph.familyCount, "n=\(n)")
            XCTAssertEqual(decoded.index, graph.index, "n=\(n)")
            XCTAssertEqual(GedcomCompiledTree.verify(decoded: decoded, against: graph), [], "n=\(n)")
        }
    }

    /// A corrupt chunk table throws (never traps): a chunk offset pointing
    /// outside its section, offsets out of order, a chunk that does not
    /// consume exactly its range, and a bad chunk size.
    func testCorruptChunkTablesThrow() throws {
        let graph = GedcomFamilyGraph(gedcomText: GedcomSyntheticPedigree.gedcom(people: 5_000, generations: 12))
        let data = GedcomCompiledTree.encode(graph)
        // Locate the people section: header(20) | u32 count | u32 blob | blob | offsets | u32 personCount | u32 chunkSize | u32 recordsLength | records | chunk offsets
        let stringCount: UInt32 = data.readLE(at: 20), blobLength: UInt32 = data.readLE(at: 24)
        let people = 28 + Int(blobLength) + (Int(stringCount) + 1) * 4 + 4  // after the i32s length prefix
        let personCount: UInt32 = data.readLE(at: people)
        XCTAssertEqual(personCount, 5_000)
        let recordsLength: UInt32 = data.readLE(at: people + 8)
        let chunkTable = people + 12 + Int(recordsLength)
        func patched(_ at: Int, _ value: UInt32) -> Data {
            var d = data
            d.replaceSubrange(at..<at + 4, with: GedcomCompiledTree.le(value))
            // Re-seal so only the structural check can refuse it.
            let payload = d.subdata(in: 20..<(d.count - 32))
            d.replaceSubrange((d.count - 32)..<d.count, with: Array(SHA256Bridge.hash(payload)))
            return d
        }
        XCTAssertThrowsError(try GedcomCompiledTree.decode(patched(people + 4, 999)))          // chunk size
        XCTAssertThrowsError(try GedcomCompiledTree.decode(patched(chunkTable + 4, recordsLength + 50))) // offset past section
        XCTAssertThrowsError(try GedcomCompiledTree.decode(patched(chunkTable + 4, 0)))       // out of order / short chunk
        XCTAssertThrowsError(try GedcomCompiledTree.decode(patched(chunkTable + 4, 3)))       // mid-record
        XCTAssertThrowsError(try GedcomCompiledTree.decode(patched(chunkTable, 8)))           // first chunk not at start
        // Unpatched still decodes.
        XCTAssertEqual(try GedcomCompiledTree.decode(data).people.count, 5_000)
    }
}

import CryptoKit
enum SHA256Bridge {
    static func hash(_ data: Data) -> [UInt8] { Array(SHA256.hash(data: data)) }
}
