// KinshipPerformanceGateTests.swift
// Release gate for FamilyKinshipInference (codex #845 / Rick: "melt
// silicon"). 39,250-person synthetic pedigree (GedcomSyntheticPedigree, 20
// generations, compiled index prebuilt) + 100 profiles, 20 of them pinned.
// Every budget below is the Release number; in Debug the same tests run
// with `slack` × the budget so the suite stays green on a dev box while
// the numbers that matter are measured with `-configuration Release`.
// Counters are locked, not just timings: builds, hits, misses, ancestor
// searches, sorts, evictions.
//
// Isolation: everything in memory (GEDCOM text → graph); the only shared
// state is one KinshipDisplayCenter instance created here.

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@Suite(.serialized)
struct KinshipPerformanceGateTests {

    #if DEBUG
    static let slack: Double = 12
    #else
    static let slack: Double = 1
    #endif
    static func budget(_ milliseconds: Double) -> Duration { .milliseconds(milliseconds * slack) }

    /// Built once per process: parse + compiled index (the "compiled fixture").
    static let graph: GedcomFamilyGraph = {
        let g = GedcomFamilyGraph(gedcomText: GedcomSyntheticPedigree.gedcom(people: 39_250, generations: 20))
        _ = g.index
        return g
    }()

    /// 20 pinned (spread across the id order) + 80 contemporaries hanging
    /// off earlier profiles by primitive rows (half the sibling rows attested).
    static let profiles: [POIProfile] = {
        let pinnable = graph.people.values.filter { !($0.familySearchID ?? "").isEmpty }.sorted { $0.id < $1.id }
        var rng = KinshipInferenceTests.SplitMix(seed: 0x39_250)
        var out: [POIProfile] = []
        let stride = max(1, pinnable.count / 20)
        for k in 0..<20 {
            let person = pinnable[k * stride]
            out.append(KinshipFixture.profile("C\(k)", sex: person.sex == "F" ? .female : .male, born: 1900 + k,
                                              pin: person.familySearchID ?? ""))
        }
        for k in 20..<100 {
            let target = "C\(Int(rng.next() % UInt64(k)))"
            let relation: KinshipRelation = [.child, .spouse, .sibling, .child][Int(rng.next() % 4)]
            let basis: SiblingBasis = rng.next() % 2 == 0 ? .attestedFull : .unspecified
            out.append(KinshipFixture.profile("C\(k)", sex: k % 2 == 0 ? .male : .female, born: 1920 + k % 60,
                                              kinships: [KinshipFixture.row(relation, of: target, basis: basis)]))
        }
        return out
    }()

    private func node(_ k: Int, in inf: FamilyKinshipInference) -> FamilyKinshipInference.Node {
        KinshipFixture.node("C\(k)", in: inf)
    }

    /// 100 distinct pinned↔pinned pairs (deep: both ends in the tree).
    private var deepPairs: [(Int, Int)] {
        var out: [(Int, Int)] = []
        for a in 0..<20 { for b in 0..<20 where a != b && out.count < 100 { out.append((a, b)) } }
        return out
    }

    /// The static fixtures are lazy: touch them so no test times the parse.
    private func warmFixtures() { _ = Self.graph.people.count; _ = Self.profiles.count }

    @Test func engineBuildsUnder20ms() {
        warmFixtures()
        let clock = ContinuousClock()
        var built: FamilyKinshipInference?
        let elapsed = clock.measure { built = FamilyKinshipInference(profiles: Self.profiles, graph: Self.graph) }
        #expect(elapsed < Self.budget(20), "engine build \(elapsed)")
        let c = built!.counters
        #expect(c.adjacencySorts >= 100 && c.adjacencySorts < 200, "sorts at build \(c.adjacencySorts)")
        #expect(c.expansions == 0 && c.ancestorSearches == 0 && c.pairMisses == 0)
        #expect(node(0, in: built!) != .profile(stableID: "c0"), "pins must resolve on the compiled fixture")
    }

    @Test func firstDeepQueryUnder50msThenWarmRepeatsAreFree() {
        warmFixtures()
        let inf = FamilyKinshipInference(profiles: Self.profiles, graph: Self.graph)
        let clock = ContinuousClock()
        let cold = clock.measure { _ = inf.relation(from: node(0, in: inf), to: node(19, in: inf)) }
        let afterCold = inf.counters
        #expect(cold < Self.budget(50), "first deep query \(cold)")
        #expect(afterCold.pairMisses == 1 && afterCold.ancestorSearches <= 1, "\(afterCold)")

        // 100 distinct deep queries: exact answers, then 1,000 warm repeats.
        var durations: [Duration] = []
        var answers: [Int: FamilyKinshipInference.Derived?] = [:]
        for (i, (a, b)) in deepPairs.enumerated() {
            durations.append(clock.measure { answers[i] = inf.relation(from: node(a, in: inf), to: node(b, in: inf)) })
        }
        let distinctTotal = durations.reduce(Duration.zero, +)
        durations.sort()
        #expect(distinctTotal < Self.budget(1_000), "100 distinct deep queries \(distinctTotal)")
        #expect(durations[94] < Self.budget(20), "deep p95 \(durations[94])")
        #expect(durations[99] < Self.budget(50), "deep max \(durations[99])")
        let afterDistinct = inf.counters
        // The cold pair (0, 19) is one of the 100: 100 misses + 1 hit.
        #expect(afterDistinct.pairMisses == 100 && afterDistinct.pairHits == 1, "\(afterDistinct)")

        // Exactness: every tree hop is a real parent/child link in the compiled
        // index, and the route is never longer than the graph's own nearest
        // common ancestor reckoning.
        let index = Self.graph.index
        var checked = 0
        for (i, (a, b)) in deepPairs.enumerated() {
            guard let d = answers[i] ?? nil,
                  case .tree(let ida) = node(a, in: inf), case .tree(let idb) = node(b, in: inf) else { continue }
            for hop in d.route where hop.provenance == .tree {
                guard case .tree(let f) = hop.from, case .tree(let t) = hop.to,
                      let fo = index.ordinal(of: f), let to = index.ordinal(of: t) else { Issue.record("non-tree hop"); continue }
                let linked = hop.relation == .parent ? index.parents(of: fo).contains(to) : index.children(of: fo).contains(to)
                #expect(linked, "\(a)→\(b): \(hop.relation) \(f) → \(t) is not a FAM link")
            }
            let treeHops = d.route.filter { $0.provenance == .tree }.count
            if let nearest = Self.graph.commonAncestors(of: ida, and: idb, limit: 1).first {
                #expect(treeHops <= nearest.depthA + nearest.depthB, "\(a)→\(b): route \(treeHops) vs tree \(nearest.depthA)+\(nearest.depthB)")
            } else if Self.graph.descentPath(from: ida, to: idb) == nil, Self.graph.descentPath(from: idb, to: ida) == nil {
                Issue.record("\(a)→\(b): engine found a route the graph does not")
            }
            checked += 1
        }
        #expect(checked > 0)

        var warm: [Duration] = []
        for _ in 0..<10 {
            for (a, b) in deepPairs { warm.append(clock.measure { _ = inf.relation(from: node(a, in: inf), to: node(b, in: inf)) }) }
        }
        let warmTotal = warm.reduce(Duration.zero, +)
        warm.sort()
        let afterWarm = inf.counters
        #expect(warmTotal < Self.budget(250), "1,000 warm queries \(warmTotal)")
        #expect(warm[949] < Self.budget(1), "warm p95 \(warm[949])")
        #expect(afterWarm.pairHits == 1_001 && afterWarm.pairMisses == afterDistinct.pairMisses, "\(afterWarm)")
        #expect(afterWarm.ancestorSearches == afterDistinct.ancestorSearches, "zero extra ancestor scans")
        #expect(afterWarm.adjacencySorts == afterDistinct.adjacencySorts, "no per-query sorts")
    }

    @Test func tenThousandLocalOnlyQueriesUnder250ms() {
        warmFixtures()
        let inf = FamilyKinshipInference(profiles: Self.profiles, graph: nil)
        var rng = KinshipInferenceTests.SplitMix(seed: 7)
        let nodes = (0..<100).map { node($0, in: inf) }
        var pairs: [(FamilyKinshipInference.Node, FamilyKinshipInference.Node)] = []
        for _ in 0..<10_000 { pairs.append((nodes[Int(rng.next() % 100)], nodes[Int(rng.next() % 100)])) }
        var answered = 0
        let elapsed = ContinuousClock().measure {
            for (a, b) in pairs where inf.relation(from: a, to: b) != nil { answered += 1 }
        }
        #expect(elapsed < Self.budget(250), "10k graph == nil queries \(elapsed) (\(answered) answered)")
        #expect(inf.counters.ancestorSearches == 0)
        #expect(answered > 0)
    }

    @Test func cacheStaysUnderBudgetAndRSSSettlesOnSecondChurn() {
        warmFixtures()
        let inf = FamilyKinshipInference(profiles: Self.profiles, graph: Self.graph)
        var rng = KinshipInferenceTests.SplitMix(seed: 11)
        let nodes = (0..<100).map { node($0, in: inf) }
        func churn() {
            for _ in 0..<10_000 {
                _ = inf.relation(from: nodes[Int(rng.next() % 100)], to: nodes[Int(rng.next() % 100)])
            }
        }
        let before = Self.residentBytes()
        churn()
        let afterFirst = Self.residentBytes()
        let c1 = inf.counters
        #expect(c1.cachedBytes <= 8 * 1_024 * 1_024 && c1.cachedEntries <= 4_096, "\(c1)")
        #expect(afterFirst - before < 64 * 1_024 * 1_024, "first churn grew RSS by \(afterFirst - before) B")
        inf.dropCaches()
        let c2 = inf.counters
        #expect(c2.cachedEntries == 0 && c2.cachedBytes == 0)
        let beforeSecond = Self.residentBytes()
        churn()
        let afterSecond = Self.residentBytes()
        #expect(afterSecond - beforeSecond < 8 * 1_024 * 1_024, "second churn grew RSS by \(afterSecond - beforeSecond) B")
    }

    @Test func thirtyTwoConcurrentIdenticalQueriesAreSingleFlight() {
        warmFixtures()
        let inf = FamilyKinshipInference(profiles: Self.profiles, graph: Self.graph)
        let a = node(0, in: inf), b = node(19, in: inf)
        DispatchQueue.concurrentPerform(iterations: 32) { _ in _ = inf.relation(from: a, to: b) }
        let c = inf.counters
        #expect(c.pairComputes == 1, "computed \(c.pairComputes) times")
        #expect(c.pairHits + c.pairMisses == 32 && c.pairMisses == 1, "\(c)")
        #expect(c.ancestorSearches <= 1)
    }

    @Test func saveValidationDoesNoFullAncestorSort() {
        warmFixtures()
        let inf = FamilyKinshipInference(profiles: Self.profiles, graph: Self.graph)
        let before = inf.counters
        let clock = ContinuousClock()
        var findings: [KinshipValidation.Finding] = []
        let elapsed = clock.measure {
            findings = KinshipValidation.validate(
                candidate: KinshipFixture.row(.child, of: "C19"),
                subjectProfileStableID: "c0", existingRows: [], inference: inf)
        }
        let after = inf.counters
        #expect(elapsed < Self.budget(50), "save validation \(elapsed)")
        #expect(after.adjacencySorts == before.adjacencySorts, "no sorts during validation")
        #expect(after.expansions - before.expansions < 2 * Self.graph.people.count, "bounded ancestor walk")
        _ = findings
    }

    @Test @MainActor func centerInvalidatesOnGraphReplacementAndKinshipEditsOnly() {
        warmFixtures()
        let center = KinshipDisplayCenter()
        center.install(graph: Self.graph)
        _ = center.inference(for: Self.profiles)
        _ = center.inference(for: Self.profiles)
        #expect(center.inferenceBuildCount == 1, "repeated turns reuse the engine")
        var notes = Self.profiles
        notes[5].notes = "unrelated edit"
        notes[6].visionThreshold = 0.6
        _ = center.inference(for: notes)
        #expect(center.inferenceBuildCount == 1, "unrelated profile edits do not rebuild")
        var kin = Self.profiles
        kin[30].kinships.append(KinshipFixture.row(.spouse, of: "C31"))
        _ = center.inference(for: kin)
        #expect(center.inferenceBuildCount == 2, "kinship edit rebuilds")
        let replacement = GedcomFamilyGraph(gedcomText: GedcomSyntheticPedigree.gedcom(people: 39_250, generations: 20, seed: 42))
        #expect(replacement.people.count == Self.graph.people.count)
        center.install(graph: replacement)
        _ = center.inference(for: kin)
        #expect(center.inferenceBuildCount == 3, "same-count graph replacement rebuilds")

    }

    /// Resident set size via Mach task info (bytes).
    static func residentBytes() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int(info.resident_size) : 0
    }
}
