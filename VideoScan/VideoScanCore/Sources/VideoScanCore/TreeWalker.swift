// TreeWalker.swift (VideoScanCore)
// The walk itself: phases in order, each a pure function of the frozen
// snapshot and the columns before it (see TreeWalk.swift for the design).
//
//   1. snapshot + LOCAL attributes (parallel)          TreeWalkSnapshot
//   2. Tarjan SCC over child → parent edges            TreeWalkGraph
//   3. BFS generations from each start (depth-limited)
//   4. the layered WALK — generation by generation, the order the UI
//      animates, with a progress event every N people
//   5. INHERITED over the condensation, children first: line bits and
//      distinct path counts (NaN through a cycle)
//   6. SYNTHESIZED over the condensation: ancestor / descendant sketches
//   7. CHECKS, parallel per person, plus the grouped ones (duplicates,
//      cycles) — over the WHOLE tree (every decoration carries its own);
//      the events and the summary report only the checks ON THE WALK
//      (involving a visited person), with whole-tree totals kept apart
//   8. assemble decorations, coverage and the summary
//
// Deterministic: every loop runs in ordinal order or in chunk order, keys
// are a fixed bijection of the ordinal, and the checks are sorted. Two
// walks of the same graph give equal results (except `generatedAt`).
//
// Cost on Rick's 39k merged tree: see the report in the commit — the whole
// walk is milliseconds-to-a-second in Debug. Worst-case memory is the
// sketch table (n × k × 8 bytes: 51 MB at 100k people), freed at the end.

import Foundation

extension TreeWalk {

    public struct Result: Sendable {
        public let walkerVersion: Int
        public let sourceKey: String
        public let generatedAt: Date
        public let starts: [Start]
        public let maxGenerations: Int?
        /// Every person of the tree, ordinal order (ascending GEDCOM pointer).
        public let ids: [String]
        public let names: [String]
        /// Parallel to `ids`. A hidden record keeps the default decoration.
        public let decorations: [Decoration]
        public let visible: [Bool]
        public let checks: [Check]
        public let summary: Summary
        /// The walk, generation by generation — what the animation replays.
        public let layers: [[Visit]]

        public func ordinal(of id: String) -> Int? {
            var lo = 0, hi = ids.count
            while lo < hi {
                let mid = (lo + hi) >> 1
                if ids[mid] < id { lo = mid + 1 } else { hi = mid }
            }
            return lo < ids.count && ids[lo] == id ? lo : nil
        }

        public func decoration(for id: String) -> Decoration? {
            ordinal(of: id).flatMap { visible[$0] ? decorations[$0] : nil }
        }

        public var visitedCount: Int { layers.reduce(0) { $0 + $1.count } }
    }

    // MARK: - Streaming entry point

    /// Runs the walk on a detached task (never the caller's actor) and
    /// streams its events. Cancelling the consumer cancels the walk at the
    /// next phase or generation boundary.
    public static func events(graph: GedcomFamilyGraph, options: Options) -> AsyncStream<Event> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    let result = try walk(graph, options: options,
                                          isCancelled: { Task.isCancelled },
                                          emit: { continuation.yield($0) })
                    continuation.yield(.finished(result))
                } catch WalkError.cancelled {
                    continuation.yield(.cancelled)
                } catch {
                    continuation.yield(.failed(String(describing: error)))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - The walk

    /// The whole walk, synchronously, on the calling thread (tests; the
    /// app goes through `events`). `emit` receives the events in order;
    /// `isCancelled` is polled at phase and generation boundaries.
    public static func walk(_ graph: GedcomFamilyGraph,
                            options: Options,
                            now: Date = Date(),
                            isCancelled: () -> Bool = { false },
                            emit: (Event) -> Void = { _ in }) throws -> Result {
        let clock = ContinuousClock()
        let t0 = clock.now
        func checkpoint() throws { if isCancelled() { throw WalkError.cancelled } }

        let starts = try resolveStarts(graph, options)
        emit(.started(StartInfo(starts: starts, maxGenerations: options.maxGenerations,
                                peopleInTree: graph.people.count - graph.suppressedPersonIDs.count,
                                walkerVersion: walkerVersion)))

        emit(.phase("Reading the tree"))
        let s = TreeWalkSnapshot(graph: graph)
        let sourceKey = TreeWalkSnapshot.sourceKey(graph: graph)
        let startOrdinals = try starts.map { start -> Int in
            guard let o = s.ordinal(of: start.id) else { throw WalkError.unknownStart(start.id) }
            return o
        }
        let ages: [AgeAtDeath?] = TreeWalkParallel.map(count: s.count) {
            AgeAtDeath.between(birth: s.birth[$0], death: s.death[$0])
        }
        try checkpoint()

        emit(.phase("Looking for cycles"))
        let comps = TreeWalkGraph.stronglyConnected(count: s.count, include: { s.visible[$0] },
                                                    successors: { s.parents(of: $0) })
        try checkpoint()

        emit(.phase("Walking"))
        let tWalk = clock.now
        let reach = Reach(snapshot: s, starts: startOrdinals, maxGenerations: options.maxGenerations)
        let layers = try layeredWalk(s, reach: reach, starts: startOrdinals, options: options, ages: ages,
                                     isCancelled: isCancelled, emit: emit)
        let inherited = inheritedPass(s, components: comps, reach: reach, starts: startOrdinals)
        let walkMs = milliseconds(clock.now - tWalk)
        try checkpoint()

        emit(.phase("Counting ancestors and descendants"))
        let dated = s.birth.map { $0 != nil }
        let ancestorsFirst = Array(comps.members.indices)
        let anc = TreeWalkGraph.reachableSetCounts(snapshot: s, components: comps, order: ancestorsFirst,
                                                   k: options.sketchSize, dated: dated,
                                                   neighbours: { s.parents(of: $0) })
        try checkpoint()
        let desc = TreeWalkGraph.reachableSetCounts(snapshot: s, components: comps, order: ancestorsFirst.reversed(),
                                                    k: options.sketchSize, dated: dated,
                                                    neighbours: { s.kids(of: $0) })
        try checkpoint()

        emit(.phase("Checking"))
        let tChecks = clock.now
        let found = runChecks(s, graph: graph, ages: ages, components: comps)
        let checksMs = milliseconds(clock.now - tChecks)
        let onWalk = onWalkPredicate(s, layers: layers)
        for check in found.cycles where onWalk(check) { emit(.cycle(check)) }
        for check in found.all where check.severity == .warn && check.kind != .ancestorCycle && onWalk(check) {
            emit(.warnCheck(check))
        }
        try checkpoint()

        var decorations = assemble(s, reach: reach, inherited: inherited, components: comps, ages: ages,
                                   ancestors: anc, descendants: desc, checksOf: found.byPerson)
        // The start people are the ones read most: EXACT counts for them
        // (one unlimited BFS each) instead of the sketch estimate.
        for o in startOrdinals {
            let gen = TreeWalkGraph.generations(from: o, maxGenerations: nil, snapshot: s)
            var count = 0, datedCount = 0
            for x in 0..<s.count where x != o && gen[x] >= 0 {
                count += 1
                if dated[x] { datedCount += 1 }
            }
            decorations[o].ancestorCount = Count(value: count, isEstimate: false)
            decorations[o].documentedAncestorFraction = count == 0 ? nil : Double(datedCount) / Double(count)
        }
        let finalLayers = layers.map { layer in
            layer.map { v in
                Visit(ordinal: v.ordinal, generation: v.generation, from: v.from, slot: v.slot, slots: v.slots,
                      line: Line(bits: inherited.lineBits[Int(v.ordinal)]),
                      hasCheck: !found.byPerson[Int(v.ordinal)].isEmpty)
            }
        }
        var summary = summarize(s, layers: finalLayers, checks: found.all, onWalk: onWalk, reach: reach, ages: ages)
        summary.maxGenerations = options.maxGenerations
        summary.startNames = starts.map(\.shortName)
        summary.walkMilliseconds = walkMs
        summary.checksMilliseconds = checksMs
        summary.estimatedAncestorCounts = anc.estimated
        summary.totalMilliseconds = milliseconds(clock.now - t0)

        return Result(walkerVersion: walkerVersion, sourceKey: sourceKey, generatedAt: now,
                      starts: starts, maxGenerations: options.maxGenerations,
                      ids: s.ids, names: s.names, decorations: decorations, visible: s.visible,
                      checks: found.all, summary: summary, layers: finalLayers)
    }

    // MARK: - Phases

    static func milliseconds(_ d: Duration) -> Double {
        Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000
    }

    static func resolveStarts(_ graph: GedcomFamilyGraph, _ options: Options) throws -> [Start] {
        guard !options.starts.isEmpty else { throw WalkError.noStartPeople }
        guard options.starts.count <= 2 else { throw WalkError.tooManyStarts(options.starts.count) }
        var starts: [Start] = []
        for id in options.starts where !starts.contains(where: { $0.id == id }) {
            guard let p = graph.people[id], !graph.isHidden(id) else { throw WalkError.unknownStart(id) }
            starts.append(Start(id: id, name: p.name))
        }
        return starts
    }

    /// BFS generations from each start, and the bits they imply.
    struct Reach {
        let first: [Int32]
        let second: [Int32]?
        let reachable: Int

        init(snapshot s: TreeWalkSnapshot, starts: [Int], maxGenerations: Int?) {
            first = TreeWalkGraph.generations(from: starts[0], maxGenerations: maxGenerations, snapshot: s)
            second = starts.count > 1
                ? TreeWalkGraph.generations(from: starts[1], maxGenerations: maxGenerations, snapshot: s) : nil
            var n = 0
            for o in 0..<s.count where first[o] >= 0 || (second?[o] ?? -1) >= 0 { n += 1 }
            reachable = n
        }

        @inline(__always) func bits(_ o: Int) -> UInt8 {
            (first[o] >= 0 ? 1 : 0) | ((second?[o] ?? -1) >= 0 ? 2 : 0)
        }
        func generationFromFirst(_ o: Int) -> Int? { first[o] >= 0 ? Int(first[o]) : nil }
        func generationFromSecond(_ o: Int) -> Int? { second.flatMap { $0[o] >= 0 ? Int($0[o]) : nil } }
    }

    /// Generation by generation from the starts — the animation's order —
    /// with a progress event every `cadence` people.
    static func layeredWalk(_ s: TreeWalkSnapshot, reach: Reach, starts: [Int], options: Options,
                            ages: [AgeAtDeath?], isCancelled: () -> Bool,
                            emit: (Event) -> Void) throws -> [[Visit]] {
        let limitedToFive = options.maxGenerations.map { $0 <= 5 } ?? false
        let cadence = max(1, options.progressEvery ?? (limitedToFive || reach.reachable < 5_000 ? 100 : 1_000))
        func sample(_ o: Int) -> Sample {
            Sample(id: s.ids[o], name: s.names[o], birthYear: s.birth[o]?.year, line: Line(bits: reach.bits(o)),
                   generationFromFirst: reach.generationFromFirst(o), generationFromSecond: reach.generationFromSecond(o),
                   ageAtDeath: ages[o], birthRegion: s.region[o], childCount: Int(s.childCount[o]))
        }
        var layers: [[Visit]] = []
        var seen = [Bool](repeating: false, count: s.count)
        var frontier: [Visit] = []
        for (i, o) in starts.enumerated() where !seen[o] {
            seen[o] = true
            frontier.append(Visit(ordinal: Int32(o), generation: 0, from: -1, slot: UInt8(i),
                                  slots: UInt8(starts.count), line: Line(bits: reach.bits(o)), hasCheck: false))
        }
        var visited = frontier.count
        var generation = 0
        while !frontier.isEmpty {
            if isCancelled() { throw WalkError.cancelled }
            layers.append(frontier)
            if let limit = options.maxGenerations, generation >= limit { break }
            var next: [Visit] = []
            for v in frontier {
                let ps = s.parents(of: Int(v.ordinal))
                for (slot, p) in ps.enumerated() where !seen[Int(p)] {
                    seen[Int(p)] = true
                    next.append(Visit(ordinal: p, generation: Int32(generation + 1), from: v.ordinal,
                                      slot: UInt8(min(slot, 255)), slots: UInt8(min(ps.count, 255)),
                                      line: Line(bits: reach.bits(Int(p))), hasCheck: false))
                    visited += 1
                    if visited % cadence == 0 {
                        emit(.progress(Progress(visited: visited, reachable: reach.reachable,
                                                generation: generation + 1, frontier: next.count,
                                                sample: sample(Int(p)))))
                    }
                }
            }
            frontier = next
            generation += 1
        }
        return layers
    }

    struct Inherited {
        var lineBits: [UInt8]
        var pathsA: [Double]
        var pathsB: [Double]
    }

    /// INHERITED attributes over the condensation, children first (reverse
    /// Tarjan order): line bits (OR) and distinct path counts (Σ, NaN
    /// through a cycle — NaN + x = NaN carries the poison upward).
    static func inheritedPass(_ s: TreeWalkSnapshot, components comps: TreeWalkGraph.Components,
                              reach: Reach, starts: [Int]) -> Inherited {
        var out = Inherited(lineBits: [UInt8](repeating: 0, count: s.count),
                            pathsA: [Double](repeating: 0, count: s.count),
                            pathsB: [Double](repeating: 0, count: s.count))
        let a = starts[0], b = starts.count > 1 ? starts[1] : -1
        for comp in comps.members.indices.reversed() {
            let group = comps.members[comp]
            guard group.contains(where: { reach.bits(Int($0)) != 0 }) else { continue }
            var bits: UInt8 = 0
            var pa = 0.0, pb = 0.0
            for m in group {
                let mi = Int(m)
                if mi == a { bits |= 1; pa += 1 }
                if mi == b { bits |= 2; pb += 1 }
                for c in s.kids(of: mi) where comps.component[Int(c)] != Int32(comp) && reach.bits(Int(c)) != 0 {
                    bits |= out.lineBits[Int(c)]
                    pa += out.pathsA[Int(c)]
                    pb += out.pathsB[Int(c)]
                }
            }
            if comps.cyclic[comp] {
                if bits & 1 != 0 { pa = .nan }
                if bits & 2 != 0 { pb = .nan }
            }
            for m in group {
                // Equal to BFS reachability on an unlimited walk; the AND
                // honours a depth limit.
                out.lineBits[Int(m)] = bits & reach.bits(Int(m))
                out.pathsA[Int(m)] = pa
                out.pathsB[Int(m)] = pb
            }
        }
        return out
    }

    /// Scope: does a check involve a person this walk VISITED? A
    /// depth-limited walk visits a sliver of the tree; its log and summary
    /// must count only that sliver's checks. O(visited) to build, O(log n)
    /// per person on the check.
    static func onWalkPredicate(_ s: TreeWalkSnapshot, layers: [[Visit]]) -> (Check) -> Bool {
        var walked = [Bool](repeating: false, count: s.count)
        for layer in layers { for v in layer { walked[Int(v.ordinal)] = true } }
        return { [walked] check in
            check.personIDs.contains { id in s.ordinal(of: id).map { walked[$0] } ?? false }
        }
    }

    struct FoundChecks {
        let all: [Check]
        let cycles: [Check]
        /// ordinal → indexes into `all`.
        let byPerson: [[Int]]
    }

    static func runChecks(_ s: TreeWalkSnapshot, graph: GedcomFamilyGraph, ages: [AgeAtDeath?],
                          components comps: TreeWalkGraph.Components) -> FoundChecks {
        var checks = TreeWalkChecks.perPerson(snapshot: s, graph: graph, ages: ages)
        checks += TreeWalkChecks.duplicates(snapshot: s)
        let cycles = TreeWalkChecks.cycles(snapshot: s, components: comps)
        checks += cycles
        let kindOrder = Dictionary(uniqueKeysWithValues: CheckKind.allCases.enumerated().map { ($1, $0) })
        checks.sort { x, y in
            let kx = kindOrder[x.kind] ?? 0, ky = kindOrder[y.kind] ?? 0
            return kx != ky ? kx < ky : x.personIDs.lexicographicallyPrecedes(y.personIDs)
        }
        var byPerson = [[Int]](repeating: [], count: s.count)
        for (i, check) in checks.enumerated() {
            for id in check.personIDs {
                if let o = s.ordinal(of: id), byPerson[o].last != i { byPerson[o].append(i) }
            }
        }
        return FoundChecks(all: checks, cycles: cycles, byPerson: byPerson)
    }

    static func assemble(_ s: TreeWalkSnapshot, reach: Reach, inherited: Inherited,
                         components comps: TreeWalkGraph.Components, ages: [AgeAtDeath?],
                         ancestors anc: TreeWalkGraph.SetCounts, descendants desc: TreeWalkGraph.SetCounts,
                         checksOf: [[Int]]) -> [Decoration] {
        TreeWalkParallel.map(count: s.count) { o in
            var d = Decoration()
            guard s.visible[o] else { return d }
            let bits = inherited.lineBits[o]
            d.line = Line(bits: bits)
            d.generationFromFirst = reach.generationFromFirst(o)
            d.generationFromSecond = reach.generationFromSecond(o)
            d.pathsFromFirst = bits & 1 != 0 ? inherited.pathsA[o] : nil
            d.pathsFromSecond = bits & 2 != 0 ? inherited.pathsB[o] : nil
            d.inCycle = comps.component[o] >= 0 && comps.cyclic[Int(comps.component[o])]
            d.sex = s.sex[o]
            d.birthYear = s.birth[o]?.year
            d.birthPrecision = s.birth[o]?.precision
            d.deathYear = s.death[o]?.year
            d.deathPrecision = s.death[o]?.precision
            d.ageAtDeath = ages[o]
            d.childCount = Int(s.childCount[o])
            d.birthRegion = s.region[o]
            d.ancestorCount = anc.counts[o]
            d.documentedAncestorFraction = anc.datedFraction[o]
            d.descendantCount = desc.counts[o]
            d.checks = checksOf[o]
            return d
        }
    }

    /// `onWalk` says whether a check involves a visited person: those
    /// are the summary's counts; every check lands in the `tree…` totals.
    static func summarize(_ s: TreeWalkSnapshot, layers: [[Visit]], checks: [Check],
                          onWalk: (Check) -> Bool, reach: Reach, ages: [AgeAtDeath?]) -> Summary {
        var summary = Summary()
        summary.peopleInTree = s.visible.filter { $0 }.count
        for layer in layers {
            summary.peopleWalked += layer.count
            for v in layer {
                summary.byLine[v.line, default: 0] += 1
                summary.byRegion[s.region[Int(v.ordinal)], default: 0] += 1
            }
        }
        for c in checks {
            summary.treeChecksByKind[c.kind, default: 0] += 1
            if c.severity == .warn { summary.treeWarnCount += 1 } else { summary.treeInfoCount += 1 }
            if c.kind == .ancestorCycle { summary.treeCycleCount += 1 }
            guard onWalk(c) else { continue }
            summary.checksByKind[c.kind, default: 0] += 1
            if c.severity == .warn { summary.warnCount += 1 } else { summary.infoCount += 1 }
            if c.kind == .ancestorCycle { summary.cycleCount += 1 }
        }
        summary.generationsFromFirst = Int(reach.first.max() ?? 0)
        summary.generationsFromSecond = Int(reach.second?.max() ?? 0)
        summary.coverageWalked = coverage(s, ages: ages) { reach.bits($0) != 0 }
        summary.coverageTree = coverage(s, ages: ages) { s.visible[$0] }
        return summary
    }

    /// "N of M have <field>" over the people `include` admits.
    static func coverage(_ s: TreeWalkSnapshot, ages: [AgeAtDeath?], include: (Int) -> Bool) -> [CoverageRow] {
        var of = 0
        var have = [Int](repeating: 0, count: 7)
        for o in 0..<s.count where include(o) {
            of += 1
            if s.birth[o] != nil { have[0] += 1 }
            if s.death[o] != nil { have[1] += 1 }
            if s.birthPlaceRecorded[o] { have[2] += 1 }
            if s.region[o] != .unknown { have[3] += 1 }
            if ages[o] != nil { have[4] += 1 }
            if s.sex[o] == "M" || s.sex[o] == "F" { have[5] += 1 }
            if !s.fathers(of: o).isEmpty && !s.mothers(of: o).isEmpty { have[6] += 1 }
        }
        let fields = ["a birth year", "a death year", "a birthplace", "a known birth region",
                      "an age at death", "a recorded sex", "both parents recorded"]
        return zip(fields, have).map { CoverageRow(field: $0, have: $1, of: of) }
    }
}
