import XCTest
@testable import VideoScanCore

/// The indexed lookups (GedcomFamilyGraph+Index.swift, 2026-08-28) must
/// return EXACTLY what the linear scans returned. The scans below are the
/// pre-index implementations, copied verbatim and frozen; every query is
/// run both ways on the synthetic 100k tree, on a hand-built edge-case
/// tree, and — when the archive is mounted — on the real 16k export.
final class GedcomIndexEquivalenceTests: XCTestCase {
    static let bigTree = URL(fileURLWithPath:
        "/Volumes/FamilyArchive/Breen_Family_Archive/40_Family_Tree/GEDCOM/familysearch-tree-20generations.ged")

    // MARK: Frozen linear reference implementations (do not "fix")

    static func allNames(_ p: GedcomFamilyGraph.Person) -> [String] { [p.name] + p.alternateNames }

    static func linearWithSurname(_ graph: GedcomFamilyGraph, _ typed: String) -> [GedcomFamilyGraph.Person] {
        var key = FamilyIdentityText.normalized(FamilyNameNormalizer.normalizeSurname(typed))
        if key.hasPrefix("the ") { key.removeFirst(4) }
        key = key.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return [] }
        func matches(_ person: GedcomFamilyGraph.Person) -> Bool {
            ([person.surname].compactMap { $0 } + person.alternateSurnames).contains { surname in
                let normalized = FamilyIdentityText.normalized(surname)
                return normalized == key || normalized + "s" == key || normalized + "es" == key
            }
        }
        return graph.people.values.filter(matches).sorted {
            $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name
        }
    }

    static func linearMatching(_ graph: GedcomFamilyGraph, _ typed: String) -> [GedcomFamilyGraph.Person] {
        let familySearchKey = typed.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if GedcomFamilyGraph.isFamilySearchID(familySearchKey) {
            return graph.people.values.filter { $0.familySearchID == familySearchKey }.sorted { $0.id < $1.id }
        }
        let tokens = FamilyIdentityText.tokens(FamilyNameNormalizer.normalizeName(typed))
        guard !tokens.isEmpty else { return [] }
        let matches = graph.people.values.filter { person in
            allNames(person).contains { candidate in
                let nameTokens = Set(FamilyIdentityText.tokens(candidate))
                return tokens.allSatisfy { nameTokens.contains($0) }
            }
        }.sorted { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }
        let exact = matches.filter { person in
            allNames(person).contains { FamilyIdentityText.tokens($0) == tokens }
        }
        if !matches.isEmpty { return exact.isEmpty ? matches : exact }
        let expanded = tokens.map { GedcomFamilyGraph.diminutives[$0] ?? $0 }
        if expanded != tokens {
            let byNickname = graph.people.values.filter { person in
                allNames(person).contains { candidate in
                    let nameTokens = Set(FamilyIdentityText.tokens(candidate))
                    return expanded.allSatisfy { nameTokens.contains($0) }
                }
            }
            if byNickname.count == 1 { return byNickname }
            if byNickname.count > 1 { return [] }
        }
        guard tokens.allSatisfy({ $0.count >= 3 }) else { return [] }
        let byPrefix = graph.people.values.filter { person in
            allNames(person).contains { candidate in
                let nameTokens = FamilyIdentityText.tokens(candidate)
                return tokens.allSatisfy { asked in nameTokens.contains { $0.hasPrefix(asked) } }
            }
        }
        return byPrefix.count == 1 ? byPrefix : []
    }

    static func linearNamedLike(_ graph: GedcomFamilyGraph, _ typed: String) -> [GedcomFamilyGraph.Person] {
        guard let tokens = GedcomFamilyGraph.namedLikeTokens(typed) else { return [] }
        return graph.people.values.filter { graph.matches($0, namedLikeTokens: tokens) }
            .sorted { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }
    }

    /// Frozen sidebar filter (FamilyTreeLiveModel.refilter, pre-index).
    static func linearSidebar(_ sorted: [GedcomFamilyGraph.Person], _ needle: String) -> [String] {
        sorted.filter { person in
            person.name.localizedCaseInsensitiveContains(needle)
                || person.alternateNames.contains { $0.localizedCaseInsensitiveContains(needle) }
                || (person.surname?.localizedCaseInsensitiveContains(needle) ?? false)
                || person.alternateSurnames.contains { $0.localizedCaseInsensitiveContains(needle) }
                || person.id.localizedCaseInsensitiveContains(needle)
                || (person.familySearchID?.localizedCaseInsensitiveContains(needle) ?? false)
        }.map(\.id)
    }

    /// Frozen sidebar comparator (FamilyTreeLiveModel.sorted).
    static func linearSorted(_ people: [GedcomFamilyGraph.Person]) -> [GedcomFamilyGraph.Person] {
        people.sorted { lhs, rhs in
            let ls = lhs.surname?.lowercased() ?? "\u{FFFF}"
            let rs = rhs.surname?.lowercased() ?? "\u{FFFF}"
            if ls != rs { return ls < rs }
            let ln = lhs.name.lowercased(), rn = rhs.name.lowercased()
            if ln != rn { return ln < rn }
            return lhs.id < rhs.id
        }
    }

    // MARK: Query corpus

    static let queries: [String] = [
        "John", "john breen", "Elizabeth", "Mary Lamb", "fred lamb", "Rick Breen", "rick", "bill",
        "Muriel Lamb Breen", "Muriel Breen", "ann", "Ann", "Jo", "zzzq", "eliz", "will stone",
        "Richard Harding Breen Jr", "richard breen jr", "the Breens", "Mc Gill", "McGill",
        "  spaced   name ", "", "GVQV-NW3", "gvqv-nw3", "AAAA-000", "BAAA-001", "Nathaniel Mercy",
        "Jane Allen", "george", "geo", "Increase", "patience", "@I1@", "Person", "Sr", "Jr",
    ]
    static let surnames: [String] = [
        "Breen", "breens", "the Breens", "Lamb", "Lambs", "Hudson", "Jones", "Joneses", "Mc Gill",
        "McGill", "", "the ", "Stone", "stones", "Latta", "Adams", "Adamses", "Slot0", "N1",
    ]
    static let needles: [String] = ["a", "bre", "Breen", "@I", "@I1", "-", "AAAA", "mary", "Z", "eth", " ", "xqz"]

    func check(_ graph: GedcomFamilyGraph, label: String, file: StaticString = #filePath, line: UInt = #line) {
        for q in Self.queries {
            XCTAssertEqual(graph.people(matching: q).map(\.id), Self.linearMatching(graph, q).map(\.id),
                           "\(label) matching '\(q)'", file: file, line: line)
            XCTAssertEqual(graph.people(namedLike: q).map(\.id), Self.linearNamedLike(graph, q).map(\.id),
                           "\(label) namedLike '\(q)'", file: file, line: line)
        }
        for s in Self.surnames {
            XCTAssertEqual(graph.people(withSurname: s).map(\.id), Self.linearWithSurname(graph, s).map(\.id),
                           "\(label) withSurname '\(s)'", file: file, line: line)
        }
        // Sidebar order and filter.
        let index = graph.index
        let sorted = Self.linearSorted(Array(graph.people.values))
        XCTAssertEqual(index.sidebarOrder.map { index.ids[Int($0)] }, sorted.map(\.id), "\(label) sidebar order", file: file, line: line)
        for n in Self.needles {
            let rows = index.sidebarRows(containing: n.lowercased())
            XCTAssertEqual(rows.map { index.ids[Int(index.sidebarOrder[Int($0)])] },
                           Self.linearSidebar(sorted, n), "\(label) sidebar '\(n)'", file: file, line: line)
        }
        // Every person is reachable through their own exact name and pointer.
        for person in graph.people.values.prefix(500) {
            XCTAssertTrue(graph.people(matching: person.name).contains { $0.id == person.id } ||
                          Self.linearMatching(graph, person.name).isEmpty, "\(label) self-lookup \(person.name)")
        }
        // Given-name index agrees with a token-0 scan.
        for given in ["John", "mary", "Elizabeth", "zzz"] {
            let key = FamilyIdentityText.tokens(given).first ?? ""
            let expected = graph.people.values.filter { p in
                ([p.name] + p.alternateNames).contains { FamilyIdentityText.tokens($0).first == key }
            }.sorted { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }.map(\.id)
            XCTAssertEqual(graph.people(withGivenName: given).map(\.id), expected, "\(label) given '\(given)'")
        }
    }

    // MARK: Frozen walks

    /// Pre-CSR relationshipPath (BFS over Person values, ids sorted per edge).
    static func linearRelationshipPath(_ graph: GedcomFamilyGraph, from: GedcomFamilyGraph.Person, to: GedcomFamilyGraph.Person, maxDepth: Int = 12) -> [(GedcomFamilyGraph.KinEdge, String)]? {
        guard from.id != to.id, maxDepth > 0 else { return nil }
        struct Link { let previousID: String?; let edge: GedcomFamilyGraph.KinEdge? }
        func neighbours(_ person: GedcomFamilyGraph.Person) -> [(GedcomFamilyGraph.KinEdge, GedcomFamilyGraph.Person)] {
            var out: [(GedcomFamilyGraph.KinEdge, GedcomFamilyGraph.Person)] = []
            for p in graph.relatives(.parents, of: person).sorted(by: { $0.id < $1.id }) { out.append((.parent, p)) }
            for c in graph.relatives(.children, of: person).sorted(by: { $0.id < $1.id }) { out.append((.child, c)) }
            for s in graph.relatives(.spouse, of: person).sorted(by: { $0.id < $1.id }) { out.append((.spouse, s)) }
            return out
        }
        var previous: [String: Link] = [from.id: Link(previousID: nil, edge: nil)]
        var frontier = [from.id]
        var depth = 0
        func unwind() -> [(GedcomFamilyGraph.KinEdge, String)]? {
            var steps: [(GedcomFamilyGraph.KinEdge, String)] = []
            var cursor = to.id
            while cursor != from.id {
                guard let link = previous[cursor], let prev = link.previousID, let edge = link.edge else { return nil }
                steps.append((edge, cursor)); cursor = prev
            }
            return steps.reversed()
        }
        while !frontier.isEmpty, depth < maxDepth {
            var next: [String] = []
            for id in frontier {
                guard let person = graph.people[id] else { continue }
                for (edge, n) in neighbours(person) {
                    guard previous[n.id] == nil else { continue }
                    previous[n.id] = Link(previousID: id, edge: edge)
                    if n.id == to.id { return unwind() }
                    next.append(n.id)
                }
            }
            frontier = next; depth += 1
        }
        return nil
    }

    /// Pre-CSR ancestorLine.
    static func linearAncestorLine(_ graph: GedcomFamilyGraph, _ person: GedcomFamilyGraph.Person, line: GedcomFamilyGraph.Line, generations: Int, untilYear: Int?) -> [[String]] {
        guard generations > 0 else { return [] }
        let relation: GedcomFamilyGraph.Relation = line == .maternal ? .mother : line == .paternal ? .father : .parents
        var out: [[String]] = []
        var frontier = [person]
        var seen: Set<String> = [person.id]
        for _ in 1...generations {
            var next: [GedcomFamilyGraph.Person] = []
            for p in frontier {
                for parent in graph.relatives(relation, of: p) where !seen.contains(parent.id) {
                    if let untilYear, !GedcomFamilyGraph.withinBound(parent, child: p, year: untilYear) { continue }
                    seen.insert(parent.id); next.append(parent)
                }
            }
            if next.isEmpty { break }
            out.append(next.map(\.id)); frontier = next
        }
        return out
    }

    func checkWalks(_ graph: GedcomFamilyGraph, label: String, pairs: [(String, String)]) {
        for (a, b) in pairs {
            guard let pa = graph.people[a], let pb = graph.people[b] else { continue }
            let fast = graph.relationshipPath(from: pa, to: pb)?.steps.map { ($0.edge, $0.person.id) }
            let slow = Self.linearRelationshipPath(graph, from: pa, to: pb)
            XCTAssertEqual(fast?.map { "\($0.0.rawValue):\($0.1)" }, slow?.map { "\($0.0.rawValue):\($0.1)" }, "\(label) path \(a)→\(b)")
            for line in [GedcomFamilyGraph.Line.both, .maternal, .paternal] {
                for until in [nil, 1900, 1700] as [Int?] {
                    XCTAssertEqual(graph.ancestorLine(of: pa, line: line, generations: 30, untilYear: until).map { $0.people.map(\.id) },
                                   Self.linearAncestorLine(graph, pa, line: line, generations: 30, untilYear: until), "\(label) line \(a) \(line) \(String(describing: until))")
                }
            }
        }
    }

    func testEdgeCaseTree() {
        let text = """
        0 HEAD
        0 @I1@ INDI
        1 NAME Richard Harding /Breen/ Jr
        1 SEX M
        1 FAMC @F1@
        1 FAMS @F2@
        1 _FSFTID GVQV-NW3
        0 @I2@ INDI
        1 NAME Richard Harding /Breen/ Sr
        1 SEX M
        1 FAMS @F1@
        1 _FSFTID GVQV-NW3
        0 @I3@ INDI
        1 NAME Muriel /Lamb/
        1 NAME Muriel Burton /Lamb/
        1 SEX F
        1 FAMS @F1@
        0 @I4@ INDI
        1 NAME Ann Mc Gill
        1 SEX F
        1 FAMS @F2@
        0 @I5@ INDI
        1 NAME Joanne /Jones/
        1 SEX F
        0 @I6@ INDI
        1 NAME Frederick Burton /Lamb/
        1 SEX M
        0 @I7@ INDI
        1 NAME William /Stone/
        1 NAME Bill /Stone/
        1 SEX M
        0 @I8@ INDI
        1 NAME /De Hendour/
        1 SEX M
        0 @I9@ INDI
        1 NAME Zoë /Élan/
        1 SEX F
        0 @F1@ FAM
        1 HUSB @I2@
        1 WIFE @I3@
        1 CHIL @I1@
        0 @F2@ FAM
        1 HUSB @I1@
        1 WIFE @I4@
        0 TRLR
        """
        let graph = GedcomFamilyGraph(gedcomText: text)
        check(graph, label: "edge")
        XCTAssertEqual(graph.people(matching: "GVQV-NW3").count, 2, "duplicate FSIDs all returned")
        XCTAssertEqual(graph.people(matching: "zoe elan").map(\.id), ["@I9@"])
    }

    func testSynthetic100k() {
        let graph = GedcomFamilyGraph(gedcomText: GedcomSyntheticPedigree.gedcom(people: 100_000))
        check(graph, label: "100k")
        let ids = graph.people.keys.sorted()
        checkWalks(graph, label: "100k", pairs: [
            (graph.rootPersonID!, ids.last!), (ids[10], ids[50_000]), (ids[99_999], ids[0]),
            ("@I0_0@", "@I0_1@"), ("@I0_0@", "@I21_3@"), ("@I3_7@", "@I3_8@"),
        ])
    }

    /// Tie-break sensor (codex #792). The CSR keeps children and spouses in
    /// GEDCOM order; the frozen BFS sorts every neighbour list by pointer.
    /// This tree lists @I1@'s children as @I8@,@I5@ and spouses as @I9@,@I3@
    /// (both out of order) and gives each pair a shared 2-hop target:
    ///   @I6@ married both @I8@ and @I5@   → expected via child @I5@
    ///   @I2@ is a child of both @I9@ and @I3@ → expected via spouse @I3@
    /// An unsorted CSR walk picks @I8@ / @I9@ instead — a different but
    /// equally short path, which is exactly what Hallie must not do
    /// between two runs of the same question.
    func testTieBreakMatchesFrozenReferenceWhenCSRListsAreUnsorted() throws {
        let text = """
        0 HEAD
        0 @I1@ INDI
        1 NAME Start /Person/
        1 SEX M
        1 FAMS @F9@
        1 FAMS @F3@
        0 @I9@ INDI
        1 NAME Later /Wife/
        1 SEX F
        1 FAMS @F9@
        1 FAMS @F91@
        0 @I3@ INDI
        1 NAME Earlier /Wife/
        1 SEX F
        1 FAMS @F3@
        1 FAMS @F31@
        0 @I2@ INDI
        1 NAME Shared /Child/
        1 SEX F
        1 FAMC @F91@
        1 FAMC @F31@
        0 @I8@ INDI
        1 NAME Second /Son/
        1 SEX M
        1 FAMC @F3@
        1 FAMS @F81@
        0 @I5@ INDI
        1 NAME First /Son/
        1 SEX M
        1 FAMC @F3@
        1 FAMS @F51@
        0 @I6@ INDI
        1 NAME Twice /Married/
        1 SEX F
        1 FAMS @F81@
        1 FAMS @F51@
        0 @F9@ FAM
        1 HUSB @I1@
        1 WIFE @I9@
        0 @F3@ FAM
        1 HUSB @I1@
        1 WIFE @I3@
        1 CHIL @I8@
        1 CHIL @I5@
        0 @F91@ FAM
        1 WIFE @I9@
        1 CHIL @I2@
        0 @F31@ FAM
        1 WIFE @I3@
        1 CHIL @I2@
        0 @F81@ FAM
        1 HUSB @I8@
        1 WIFE @I6@
        0 @F51@ FAM
        1 HUSB @I5@
        1 WIFE @I6@
        0 TRLR
        """
        let graph = GedcomFamilyGraph(gedcomText: text)
        let index = graph.index
        let start = try XCTUnwrap(index.ordinal(of: "@I1@"))
        // The fixture must actually exercise the tie: CSR lists are NOT sorted.
        let children = Array(index.children(of: start)), spouses = Array(index.spouses(of: start))
        XCTAssertEqual(children.map { index.ids[Int($0)] }, ["@I8@", "@I5@"], "fixture children must be in GEDCOM (unsorted) order")
        XCTAssertEqual(spouses.map { index.ids[Int($0)] }, ["@I9@", "@I3@"], "fixture spouses must be in GEDCOM (unsorted) order")
        XCTAssertNotEqual(children, children.sorted())
        XCTAssertNotEqual(spouses, spouses.sorted())

        let i1 = try XCTUnwrap(graph.people["@I1@"])
        let viaChild = try XCTUnwrap(graph.relationshipPath(from: i1, to: graph.people["@I6@"]!))
        XCTAssertEqual(viaChild.steps.map { "\($0.edge.rawValue):\($0.person.id)" }, ["child:@I5@", "spouse:@I6@"])
        let viaSpouse = try XCTUnwrap(graph.relationshipPath(from: i1, to: graph.people["@I2@"]!))
        XCTAssertEqual(viaSpouse.steps.map { "\($0.edge.rawValue):\($0.person.id)" }, ["spouse:@I3@", "child:@I2@"])

        // Byte-identical to the frozen reference for every ordered pair.
        let ids = graph.people.keys.sorted()
        var pairs: [(String, String)] = []
        for a in ids { for b in ids where a != b { pairs.append((a, b)) } }
        checkWalks(graph, label: "tiebreak", pairs: pairs)
    }

    /// N random start pairs on the 100k synthetic pedigree: the CSR path
    /// must equal the frozen reference path (same edges, same ids).
    func testSynthetic100kRandomPairsMatchFrozenPath() {
        let graph = GedcomFamilyGraph(gedcomText: GedcomSyntheticPedigree.gedcom(people: 100_000))
        let ids = graph.people.keys.sorted()
        // Deterministic LCG so a failure reproduces (≈ srand(seed)).
        var state: UInt64 = 0x2545F4914F6CDD1D
        func next() -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(ids.count))
        }
        var mismatches: [String] = []
        var found = 0
        for _ in 0..<96 {
            let a = ids[next()], b = ids[next()]
            guard a != b, let pa = graph.people[a], let pb = graph.people[b] else { continue }
            let fast = graph.relationshipPath(from: pa, to: pb)?.steps.map { "\($0.edge.rawValue):\($0.person.id)" }
            let slow = Self.linearRelationshipPath(graph, from: pa, to: pb)?.map { "\($0.0.rawValue):\($0.1)" }
            if fast != slow { mismatches.append("\(a)→\(b): fast \(fast ?? []) slow \(slow ?? [])") }
            if fast != nil { found += 1 }
        }
        XCTAssertEqual(mismatches, [], "100k random pairs")
        XCTAssertGreaterThan(found, 0, "sensor must exercise real paths, not only nil results")
    }

    func testRealExport() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.bigTree.path))
        let graph = try XCTUnwrap(GedcomFamilyGraph(fileURL: Self.bigTree))
        check(graph, label: "real")
        let ids = graph.people.keys.sorted()
        checkWalks(graph, label: "real", pairs: [
            (graph.rootPersonID!, ids.last!), (ids[100], ids[9_000]), (ids[16_000], ids[1]), (ids[5], ids[6]),
        ])
        // Ancestor index over CSR must equal the old Person-walk: same
        // depths and same paths for every ancestor of the root.
        let root = try XCTUnwrap(graph.rootPersonID)
        let fast = GedcomFamilyGraph.AncestorIndex(graph: graph, descendantID: root)
        let slow = Self.linearAncestorIndex(graph, root)
        XCTAssertEqual(slow.depth.count, fast.path(from: root) == nil ? slow.depth.count : -1)
        for (ancestor, depth) in slow.depth {
            XCTAssertEqual(fast.generations(from: ancestor), depth)
            XCTAssertEqual(fast.path(from: ancestor)?.map(\.id), Self.unwind(slow.cameFrom, ancestor, root))
        }
    }

    /// Frozen pre-CSR AncestorIndex walk.
    static func linearAncestorIndex(_ graph: GedcomFamilyGraph, _ descendantID: String) -> (cameFrom: [String: String], depth: [String: Int]) {
        var cameFrom: [String: String] = [:]
        var depth: [String: Int] = [:]
        guard let start = graph.people[descendantID] else { return ([:], [:]) }
        var visited: Set<String> = [descendantID]
        var frontier: [GedcomFamilyGraph.Person] = [start]
        var level = 0
        while !frontier.isEmpty {
            var next: [GedcomFamilyGraph.Person] = []
            level += 1
            for child in frontier {
                for parent in graph.relatives(.father, of: child) + graph.relatives(.mother, of: child)
                where visited.insert(parent.id).inserted {
                    cameFrom[parent.id] = child.id
                    depth[parent.id] = level
                    next.append(parent)
                }
            }
            frontier = next
        }
        return (cameFrom, depth)
    }
    static func unwind(_ cameFrom: [String: String], _ from: String, _ to: String) -> [String] {
        var out = [from]
        var cur = from
        while cur != to, let next = cameFrom[cur] { out.append(next); cur = next }
        return out
    }
}
