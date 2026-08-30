import Testing
import Foundation
import VideoScanCore

// MARK: - GedcomLookupConcurrencyTests
//
// Rick, 2026-08-30: "if you can write some tests that test 1000 random IDs
// that are in the tree, it's nice to know it is covered, then make sure we
// can have parallel searches."
//
// Two questions, deliberately separated:
//
//   COVERAGE  — does every ID in the tree resolve, and do IDs that are not
//               in it resolve to nothing? Correctness, always asserted.
//   CONCURRENCY — do parallel lookups return the SAME answers as serial
//               ones? This is the one that matters as the web client grows
//               past one visitor, and it is about data integrity, not
//               speed.
//
// TIMING is measured and printed but only loosely asserted. Today's nightly
// failed because a Release perf budget was judged in a Debug+coverage run
// (scroll p95 0.073 s against 0.050 s), so tight budgets here are gated
// behind PerformanceLane like the other perf suites. A loose ceiling stays
// on always: it catches an accidental O(n) scan, which is the failure worth
// guarding, without flaking under load.

struct GedcomLookupConcurrencyTests {

    static let performanceOptIn = "VIDEOSCAN_LOOKUP_PERF"

    /// Big enough to be honest about scale — Rick's real export is 16,383
    /// people — while still parsing fast enough for an ordinary test run.
    static let peopleCount = 8_000
    static let probeCount = 1_000

    private static func makeGraph() -> GedcomFamilyGraph {
        GedcomFamilyGraph(gedcomText:
            GedcomSyntheticPedigree.gedcom(people: peopleCount))
    }

    private func ms(_ seconds: Double) -> String {
        String(format: "%.2f ms", seconds * 1000)
    }

    // MARK: 1. Coverage

    @Test func aThousandRandomIDsAllResolve() throws {
        let graph = Self.makeGraph()
        let ids = Array(graph.people.keys)
        try #require(ids.count > Self.probeCount,
                     Comment(rawValue: "fixture only produced \(ids.count) people"))

        var rng = SystemRandomNumberGenerator()
        let probes = (0..<Self.probeCount).map { _ in ids.randomElement(using: &rng)! }  // swiftlint:disable:this force_unwrapping

        let started = ContinuousClock().now
        var found = 0
        for id in probes where graph.people[id] != nil { found += 1 }
        let elapsed = ContinuousClock().now - started

        #expect(found == Self.probeCount,
                Comment(rawValue: "\(Self.probeCount - found) of \(Self.probeCount) known IDs did not resolve"))

        let seconds = Double(elapsed.components.attoseconds) / 1e18
            + Double(elapsed.components.seconds)
        print("[lookup] \(Self.probeCount) IDs over \(ids.count) people: "
              + "\(ms(seconds)) total, \(ms(seconds / Double(Self.probeCount))) each")

        // Loose, always-on ceiling. A dictionary lookup is nanoseconds; this
        // only fires if someone replaces it with a scan over all people.
        #expect(seconds < 1.0,
                Comment(rawValue: "1,000 lookups took \(ms(seconds)) — that is scan-shaped, not index-shaped"))

        if PerformanceLane.isAuthoritative(optInKey: Self.performanceOptIn) {
            #expect(seconds < 0.010, Comment(rawValue: "Release budget: \(ms(seconds)) for 1,000 lookups"))
        }
    }

    /// The negative half. A lookup test that only ever asks for IDs that
    /// exist cannot tell a working index from one that returns the same
    /// person for everything.
    @Test func idsThatAreNotInTheTreeResolveToNothing() {
        let graph = Self.makeGraph()
        for absent in ["@INOPE@", "@I999999999@", "", "not-an-id", "@I1@ "] {
            #expect(graph.people[absent] == nil,
                    Comment(rawValue: "\(absent) should not resolve"))
        }
    }

    // MARK: 2. Concurrency

    /// The question behind this: the web client is one visitor today and
    /// several soon. Concurrent readers must see exactly what a serial
    /// reader sees — same person, same vitals, every time.
    @Test func parallelLookupsAgreeWithSerialOnes() async throws {
        let graph = Self.makeGraph()
        let ids = Array(graph.people.keys).prefix(Self.probeCount).map { $0 }
        try #require(ids.count == Self.probeCount)

        // Serial baseline: id -> a fingerprint of what the record says.
        func fingerprint(_ id: String) -> String {
            guard let p = graph.people[id] else { return "<missing>" }
            return [p.id, p.name, p.birthDate ?? "-", p.birthPlace ?? "-",
                    p.deathDate ?? "-", p.sex].joined(separator: "|")
        }
        let expected = ids.map(fingerprint)

        let started = ContinuousClock().now
        let actual = await withTaskGroup(of: (Int, String).self) { group in
            for (index, id) in ids.enumerated() {
                group.addTask { (index, fingerprint(id)) }
            }
            var out = [String](repeating: "", count: ids.count)
            for await (index, value) in group { out[index] = value }
            return out
        }
        let elapsed = ContinuousClock().now - started
        let seconds = Double(elapsed.components.attoseconds) / 1e18
            + Double(elapsed.components.seconds)
        print("[lookup] \(ids.count) concurrent lookups: \(ms(seconds))")

        let differing = zip(actual, expected).filter { $0 != $1 }.count
        #expect(actual == expected,
                Comment(rawValue: "concurrent readers disagreed with serial ones — "
                        + "\(differing) of \(ids.count) differed"))
    }

    /// Hammer one hot record from many tasks at once. A shared cache with a
    /// torn read shows up here and not in the spread-out case above.
    @Test func oneHotRecordUnderContentionIsAlwaysIdentical() async throws {
        let graph = Self.makeGraph()
        let id = try #require(Array(graph.people.keys).sorted().first)
        let truth = try #require(graph.people[id]).name

        let names = await withTaskGroup(of: String?.self) { group in
            for _ in 0..<500 { group.addTask { graph.people[id]?.name } }
            var out: [String?] = []
            for await n in group { out.append(n) }
            return out
        }
        let disagreed = names.filter { $0 != truth }.count
        #expect(names.allSatisfy { $0 == truth },
                Comment(rawValue: "\(disagreed) of 500 concurrent reads of one record disagreed"))
    }
}
