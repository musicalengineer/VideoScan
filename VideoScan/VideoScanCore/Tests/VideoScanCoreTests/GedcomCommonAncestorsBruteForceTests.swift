// GedcomCommonAncestorsBruteForceTests.swift
// Sensor (2026-08-29): `commonAncestors(of:and:)` must return every shared
// ancestor with its TRUE minimum depth on each side, nearest (smallest
// depthA + depthB, then depthA, then name, then id) first — checked
// against a brute-force Person-level BFS that never touches the CSR index
// or AncestorIndex. Pedigree collapse (an ancestor reachable at several
// depths) is exactly where a first-visited depth would go wrong.
//
// Origin: the kinship engine's Release gate (feature/kinship-inference-
// engine) found a 15-hop lineal route where commonAncestors' nearest hit
// summed to 17. Brute force showed no depth error: the pair
// (@I15_0@, @I0_0@) is ancestor/descendant, and a person is not their own
// ancestor, so commonAncestors offers the ancestor's PARENT (1 + 16). The
// engine seeds its depth map with self at 0 and meets at the ancestor
// (15). Both are right; they answer different questions. The lineal
// contract is pinned below so the two can never silently disagree again:
// callers wanting "how are they related" check directRelation /
// descentPath first (Hallie does — HallieLineageQuestion, codex #776).

import XCTest
@testable import VideoScanCore

final class GedcomCommonAncestorsBruteForceTests: XCTestCase {
    #if DEBUG
    static let slack = 8.0
    #else
    static let slack = 1.0
    #endif

    static func ms(_ body: () -> Void) -> Double {
        let t0 = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
    }

    /// Deterministic RNG so the random pairs are the same every run.
    struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    // MARK: Brute force (Person walk; no index)

    /// True minimum generations of every ancestor of `id` (1 = parent).
    static func trueDepths(_ g: GedcomFamilyGraph, _ id: String) -> [String: Int] {
        var depth: [String: Int] = [:]
        guard let start = g.people[id] else { return [:] }
        var frontier = [start]
        var level = 0
        while !frontier.isEmpty {
            level += 1
            var next: [GedcomFamilyGraph.Person] = []
            for child in frontier {
                for parent in g.relatives(.parents, of: child) where parent.id != id && depth[parent.id] == nil {
                    depth[parent.id] = level
                    next.append(parent)
                }
            }
            frontier = next
        }
        return depth
    }

    struct Report {
        var pairs = 0
        var shared = 0
        var lineal = 0
        var mismatches: [String] = []
    }

    /// Compares `commonAncestors` with brute force for one pair and, when
    /// the pair is lineal, pins the contract explained in the header.
    static func compare(_ g: GedcomFamilyGraph, _ a: String, _ b: String, into r: inout Report) {
        r.pairs += 1
        let da = trueDepths(g, a), db = trueDepths(g, b)
        let hits = g.commonAncestors(of: a, and: b)
        var truth: [String: (Int, Int)] = [:]
        for (id, x) in da { if let y = db[id] { truth[id] = (x, y) } }
        guard !truth.isEmpty else {
            if !hits.isEmpty { r.mismatches.append("\(a)/\(b): \(hits.count) hits but brute force finds none") }
            return
        }
        r.shared += 1
        if hits.count != truth.count { r.mismatches.append("\(a)/\(b): \(hits.count) hits vs \(truth.count) true") }
        for h in hits {
            guard let t = truth[h.person.id] else { r.mismatches.append("\(a)/\(b): \(h.person.id) is not a shared ancestor"); continue }
            if (h.depthA, h.depthB) != t {
                r.mismatches.append("\(a)/\(b): \(h.person.id) claimed \(h.depthA)+\(h.depthB), true \(t.0)+\(t.1)")
            }
            if h.pathA.count - 1 != h.depthA || h.pathB.count - 1 != h.depthB
                || h.pathA.first?.id != h.person.id || h.pathA.last?.id != a
                || h.pathB.first?.id != h.person.id || h.pathB.last?.id != b {
                r.mismatches.append("\(a)/\(b): \(h.person.id) paths do not match depths/ends")
            }
        }
        let minSum = truth.values.map { $0.0 + $0.1 }.min()!
        if let f = hits.first, f.depthA + f.depthB != minSum {
            r.mismatches.append("\(a)/\(b): first \(f.person.id) sums \(f.depthA + f.depthB), minimum is \(minSum)")
        }
        for i in stride(from: 1, to: hits.count, by: 1) {
            let x = hits[i - 1], y = hits[i]
            let sx = x.depthA + x.depthB, sy = y.depthA + y.depthB
            let ordered = sx < sy || (sx == sy && (x.depthA < y.depthA || (x.depthA == y.depthA
                && (x.person.name < y.person.name || (x.person.name == y.person.name && x.person.id < y.person.id)))))
            if !ordered { r.mismatches.append("\(a)/\(b): order breaks at hit \(i)"); break }
        }
        // Lineal contract: the ancestor is never its own hit (the engine
        // would meet there at 0 + d); its parent is a hit at 1 + (d + 1),
        // so the nearest sums at most d + 2 — less only through pedigree
        // collapse (a nearer shared line), never below 2; directRelation
        // names the pair as lineal.
        for (anc, desc, d) in [(a, b, db[a]), (b, a, da[b])] {
            guard let d else { continue }
            r.lineal += 1
            if hits.contains(where: { $0.person.id == anc }) { r.mismatches.append("\(anc)/\(desc): ancestor listed as own common ancestor") }
            if let f = hits.first, !(2...(d + 2)).contains(f.depthA + f.depthB) {
                r.mismatches.append("\(anc)/\(desc): lineal at \(d) but nearest sums \(f.depthA + f.depthB), expected 2...\(d + 2)")
            }
            if hits.isEmpty && !trueDepths(g, anc).isEmpty {
                r.mismatches.append("\(anc)/\(desc): ancestor has parents but no common ancestor was found")
            }
            if g.descentPath(from: anc, to: desc)?.count != d + 1 {
                r.mismatches.append("\(anc)/\(desc): descentPath length \(g.descentPath(from: anc, to: desc)?.count ?? -1) vs \(d + 1)")
            }
            let kind = g.directRelation(between: anc, and: desc)?.kind
            if kind != (d == 1 ? .parentChild : .ancestorDescendant) {
                r.mismatches.append("\(anc)/\(desc): directRelation \(String(describing: kind)) for lineal depth \(d)")
            }
        }
    }

    static func randomPairs(_ g: GedcomFamilyGraph, count: Int, seed: UInt64) -> [(String, String)] {
        let ids = g.people.keys.sorted()
        var rng = SplitMix(state: seed)
        return (0..<count).map { _ in (ids[Int(rng.next() % UInt64(ids.count))], ids[Int(rng.next() % UInt64(ids.count))]) }
            .filter { $0.0 != $0.1 }
    }

    // MARK: The kinship gate's 39k fixture, its exact pins, and the 15-vs-17 pair

    func testGateFixture39kMatchesBruteForceAndLinealPairsExplainTheGap() throws {
        let g = GedcomFamilyGraph(gedcomText: GedcomSyntheticPedigree.gedcom(people: 39_250, generations: 20))
        _ = g.index
        // Same pin selection as KinshipPerformanceGateTests.profiles.
        let pinnable = g.people.values.filter { !($0.familySearchID ?? "").isEmpty }.sorted { $0.id < $1.id }
        let stride = max(1, pinnable.count / 20)
        let pins = (0..<20).map { pinnable[$0 * stride].id }
        var pairs: [(String, String)] = []
        for a in 0..<20 { for b in 0..<20 where a != b && pairs.count < 100 { pairs.append((pins[a], pins[b])) } }
        pairs += Self.randomPairs(g, count: 200, seed: 0x39_250)

        var r = Report()
        let elapsed = Self.ms { for (a, b) in pairs { Self.compare(g, a, b, into: &r) } }
        XCTAssertEqual(r.mismatches, [])
        XCTAssertGreaterThan(r.shared, 200)
        XCTAssertGreaterThan(r.lineal, 0, "the gate's pins include lineal pairs — that is the whole point")
        XCTAssertLessThan(elapsed, 3_000 * Self.slack, "300 pairs, brute force + indexed (measured ~1.1 s Release, M4 Max, 2026-08-29)")

        // The reported case, exactly: @I15_0@ is 15 generations above @I0_0@.
        XCTAssertTrue(pins.contains("@I15_0@") && pins.contains("@I0_0@"))
        XCTAssertEqual(g.descentPath(from: "@I15_0@", to: "@I0_0@")?.count, 16)
        let nearest = try XCTUnwrap(g.commonAncestors(of: "@I0_0@", and: "@I15_0@", limit: 1).first)
        XCTAssertEqual(nearest.depthA + nearest.depthB, 17, "ancestor's parent: 16 + 1, never the ancestor at 15 + 0")
        XCTAssertEqual(nearest.depthB, 1)
        XCTAssertEqual(GedcomFamilyGraph.AncestorIndex(graph: g, descendantID: "@I0_0@").generations(from: "@I15_0@"), 15)
        XCTAssertNil(GedcomFamilyGraph.AncestorIndex(graph: g, descendantID: "@I0_0@").generations(from: "@I0_0@"),
                     "a person is not their own ancestor — the definitional root of the 15-vs-17 gap")
        XCTAssertEqual(g.directRelation(between: "@I0_0@", and: "@I15_0@")?.kind, .ancestorDescendant)
        XCTAssertEqual(GedcomFamilyGraph.kinshipTerm(depthA: 15, depthB: 0), "the same person or a direct ancestor")
    }

    // MARK: Pedigree collapse in miniature (multi-FAMC, cousin marriage)

    func testPedigreeCollapseTreeAllPairs() {
        // @I1@ has two FAMC: F1 (parents @I2@ × @I3@, themselves full
        // siblings — children of @I4@ × @I5@) and F3 (father @I4@ alone).
        // Before Rick's 2026-09-02 one-primary-parent-family ruling this
        // test expected @I4@ at depth 1 (a parent through F3) AND 2. Now
        // F1 is the primary family (both parents beat one), F3's father is
        // a non-primary, unfoldable second family (basis note only), and
        // every walk — brute force and index alike — puts @I4@ at depth 2
        // beside @I5@. The two still agree pair for pair.
        let text = """
        0 HEAD
        0 @I1@ INDI
        1 NAME One
        1 FAMC @F1@
        1 FAMC @F3@
        0 @I2@ INDI
        1 NAME Two
        1 SEX M
        1 FAMS @F1@
        1 FAMC @F2@
        0 @I3@ INDI
        1 NAME Three
        1 SEX F
        1 FAMS @F1@
        1 FAMC @F2@
        0 @I4@ INDI
        1 NAME Four
        1 SEX M
        1 FAMS @F2@
        1 FAMS @F3@
        0 @I5@ INDI
        1 NAME Five
        1 SEX F
        1 FAMS @F2@
        0 @I6@ INDI
        1 NAME Six
        1 FAMC @F2@
        0 @F1@ FAM
        1 HUSB @I2@
        1 WIFE @I3@
        1 CHIL @I1@
        0 @F2@ FAM
        1 HUSB @I4@
        1 WIFE @I5@
        1 CHIL @I2@
        1 CHIL @I3@
        1 CHIL @I6@
        0 @F3@ FAM
        1 HUSB @I4@
        1 CHIL @I1@
        0 TRLR
        """
        let g = GedcomFamilyGraph(gedcomText: text)
        var r = Report()
        let ids = g.people.keys.sorted()
        for a in ids { for b in ids where a != b { Self.compare(g, a, b, into: &r) } }
        XCTAssertEqual(r.mismatches, [])
        XCTAssertEqual(r.pairs, 30)
        XCTAssertEqual(g.commonAncestors(of: "@I1@", and: "@I6@").map { "\($0.person.id) \($0.depthA)+\($0.depthB)" },
                       ["@I5@ 2+1", "@I4@ 2+1"])
        // The second family is still recorded — for the basis, not the walk.
        XCTAssertEqual(g.parentFamilyChoice(of: g.people["@I1@"]!)?.unfoldedAlternates.map(\.person.id), ["@I4@"])
        XCTAssertEqual(g.allRecordedParents(of: g.people["@I1@"]!).map(\.id), ["@I2@", "@I4@", "@I3@"])
        XCTAssertEqual(g.commonAncestors(of: "@I2@", and: "@I3@").first?.kinshipTerm, "siblings")
    }

    // MARK: Scale

    func testSynthetic100kSeededPairsMatchBruteForce() {
        let g = GedcomFamilyGraph(gedcomText: GedcomSyntheticPedigree.gedcom(people: 100_000))
        _ = g.index
        var pairs = Self.randomPairs(g, count: 100, seed: 100_000)
        pairs.append((g.rootPersonID!, g.people.keys.sorted().last!))
        var r = Report()
        let elapsed = Self.ms { for (a, b) in pairs { Self.compare(g, a, b, into: &r) } }
        XCTAssertEqual(r.mismatches, [])
        XCTAssertGreaterThan(r.shared, 50)
        XCTAssertLessThan(elapsed, 4_000 * Self.slack, "101 pairs on 100k (measured ~2.5 s Release, M4 Max, 2026-08-29)")
        // The indexed answer alone stays interactive at 100k.
        let indexed = Self.ms { for (a, b) in pairs { _ = g.commonAncestors(of: a, and: b, limit: 1) } }
        XCTAssertLessThan(indexed / Double(pairs.count), 20 * Self.slack, "per-pair commonAncestors ms at 100k")
    }

    // MARK: The real compiled tree (skips when not installed)

    static var newestArtifact: URL? {
        let dir = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/VideoScan/family-tree/compiled")
        guard let gens = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        return gens.filter { $0.hasPrefix("gen-") }.sorted().last.map { dir.appendingPathComponent($0).appendingPathComponent("tree.vsft") }
    }

    func testRealArtifactRickAndDonnaMatchBruteForce() throws {
        guard let url = Self.newestArtifact, FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("no compiled family tree installed")
        }
        let g: GedcomFamilyGraph
        do {
            g = try GedcomCompiledTree.decode(Data(contentsOf: url))
        } catch let error as GedcomCompiledTree.CodecError {
            // An artifact compiled by an older build is not "installed"
            // for this one — the app recompiles it on next launch.
            guard case .versionMismatch = error else { throw error }
            throw XCTSkip("installed family tree was compiled with an older codec (\(error)); recompile in the app")
        }
        let rick = g.people(matching: "GVQV-NW3").map(\.id), donna = g.people(matching: "G2CL-86B").map(\.id)
        try XCTSkipUnless(!rick.isEmpty && !donna.isEmpty, "artifact is not the two-root Rick/Donna tree")
        var r = Report()
        for a in rick { for b in donna { Self.compare(g, a, b, into: &r) } }
        for (a, b) in Self.randomPairs(g, count: 200, seed: 0xD0_44A) { Self.compare(g, a, b, into: &r) }
        XCTAssertEqual(r.mismatches, [])
        // Hallie's demo answer, pinned (39,250-person merge of 2026-08-29).
        if g.people.count == 39_250 {
            let nearest = try XCTUnwrap(g.commonAncestors(of: rick[0], and: donna[0], limit: 1).first)
            XCTAssertEqual(nearest.person.name, "Martha Lamson")
            XCTAssertEqual([nearest.depthA, nearest.depthB], [10, 11])
            XCTAssertEqual(nearest.kinshipTerm, "9th cousins once removed")
        }
    }
}
