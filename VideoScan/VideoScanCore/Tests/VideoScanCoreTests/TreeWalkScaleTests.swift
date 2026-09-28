// TreeWalkScaleTests.swift
// SCALE: the whole walk — snapshot, Tarjan, BFS, inherited, synthesized
// sketches, checks — over a 100k-person synthetic pedigree with heavy
// pedigree collapse (GedcomSyntheticPedigree: 22 generations, every person's
// parents drawn from the row above, so ancestor sets overlap massively —
// the shape that makes exact per-person distinct counts O(n²)).
//
// Run through the STREAMING entry point so the work provably happens off the
// caller's actor (a detached task), and budgeted load-aware (TimingBudget).
// The budget is ~3× the measured Debug time on the M4 (2026-09-27).

import Foundation
import Testing
@testable import VideoScanCore

@Suite("TreeWalkScale")
struct TreeWalkScaleTests {

    /// Measured 2026-09-27, M4 Max, Debug: 2.8 s for 100k (walk 51 ms,
    /// checks 0.7 s, the two sketch passes ~1.1 s, snapshot + source key
    /// ~0.8 s). Budget ≈ 3×.
    static let budget: Duration = .seconds(8)

    @Test func hundredThousandPeopleWalkAndCheckOffMain() async throws {
        let graph = GedcomFamilyGraph(gedcomText: GedcomSyntheticPedigree.gedcom(people: 100_000))
        _ = graph.index   // the compiled index arrives prebuilt in production
        let root = try #require(graph.rootPersonID)
        let second = try #require(graph.relatives(.spouse, of: graph.people[root]!).first?.id
                                  ?? graph.people.keys.sorted().dropFirst().first)
        let clock = ContinuousClock()
        let start = clock.now
        var result: TreeWalk.Result?
        var progress = 0
        for await event in TreeWalk.events(graph: graph, options: .init(starts: [root, second])) {
            switch event {
            case .progress:
                progress += 1
            case .finished(let r):
                result = r
            case .failed(let why):
                Issue.record("walk failed: \(why)")
            default:
                break
            }
        }
        let elapsed = clock.now - start
        let r = try #require(result)
        let ceiling = TimingBudget.loadAwareDebugCeiling(Self.budget)
        print("[walk-scale] 100k: \(elapsed) total; walk \(String(format: "%.0f", r.summary.walkMilliseconds)) ms, checks \(String(format: "%.0f", r.summary.checksMilliseconds)) ms; visited \(r.visitedCount), estimated counts \(r.summary.estimatedAncestorCounts), checks \(r.checks.count), progress events \(progress) (\(TimingBudget.loadDescription()))")
        #expect(elapsed < ceiling, "100k walk took \(elapsed), ceiling \(ceiling) (\(TimingBudget.loadDescription()))")
        #expect(r.decorations.count == graph.people.count)
        #expect(r.visitedCount > 10_000)
        #expect(progress == r.visitedCount / 1_000)
        // Sketch sanity: a start's exact ancestor count matches a plain walk.
        let exact = graph.ancestorLine(of: graph.people[root]!, line: .both, generations: 200).flatMap(\.people).count
        #expect(r.decoration(for: root)?.ancestorCount == TreeWalk.Count(value: exact, isEstimate: false))
    }

    @Test func sketchEstimatesAreWithinTolerance() throws {
        // A non-start person deep in collapse: the KMV estimate against the
        // exact BFS count, k = 64 → relative standard error ≈ 12.7%; allow 3σ.
        let graph = GedcomFamilyGraph(gedcomText: GedcomSyntheticPedigree.gedcom(people: 20_000))
        let root = try #require(graph.rootPersonID)
        let r = try TreeWalk.walk(graph, options: .init(starts: [root]))
        var checked = 0
        for id in graph.relatives(.parents, of: graph.people[root]!).map(\.id) {
            guard let d = r.decoration(for: id), d.ancestorCount.isEstimate else { continue }
            let exact = graph.ancestorLine(of: graph.people[id]!, line: .both, generations: 200).flatMap(\.people).count
            let error = abs(Double(d.ancestorCount.value - exact)) / Double(exact)
            #expect(error < 0.40, "\(id): estimate \(d.ancestorCount.value) vs exact \(exact)")
            checked += 1
        }
        #expect(checked > 0)
    }
}
