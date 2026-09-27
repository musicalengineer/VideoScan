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
//      cycles)
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

    public static func walk(_ graph: GedcomFamilyGraph,
                            options: Options,
                            now: Date = Date(),
                            isCancelled: () -> Bool = { false },
                            emit: (Event) -> Void = { _ in }) throws -> Result {
        let clock = ContinuousClock()
        let t0 = clock.now
        func ms(_ d: Duration) -> Double { Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000 }
        func checkpoint() throws { if isCancelled() { throw WalkError.cancelled } }

        // ---- 0. Start people.
        guard !options.starts.isEmpty else { throw WalkError.noStartPeople }
        guard options.starts.count <= 2 else { throw WalkError.tooManyStarts(options.starts.count) }
        var starts: [Start] = []
        for id in options.starts where !starts.contains(where: { $0.id == id }) {
            guard let p = graph.people[id], !graph.isHidden(id) else { throw WalkError.unknownStart(id) }
            starts.append(Start(id: id, name: p.name))
        }
        emit(.started(StartInfo(starts: starts, maxGenerations: options.maxGenerations,
                                peopleInTree: graph.people.count - graph.suppressedPersonIDs.count,
                                walkerVersion: walkerVersion)))

        // ---- 1. Snapshot + local attributes.
        emit(.phase("Reading the tree"))
        let s = TreeWalkSnapshot(graph: graph)
        let n = s.count
        let sourceKey = TreeWalkSnapshot.sourceKey(graph: graph)
        let startOrdinals = starts.map { s.ordinal(of: $0.id)! }
        let ages: [AgeAtDeath?] = TreeWalkParallel.map(count: n) { AgeAtDeath.between(birth: s.birth[$0], death: s.death[$0]) }
        try checkpoint()

        // ---- 2. Cycles.
        emit(.phase("Looking for cycles"))
        let comps = TreeWalkGraph.stronglyConnected(count: n, include: { s.visible[$0] },
                                                    successors: { s.parents(of: $0) })
        try checkpoint()

        // ---- 3. Generations from each start.
        let tWalk = clock.now
        let genA = TreeWalkGraph.generations(from: startOrdinals[0], maxGenerations: options.maxGenerations, snapshot: s)
        let genB: [Int32]? = startOrdinals.count > 1
            ? TreeWalkGraph.generations(from: startOrdinals[1], maxGenerations: options.maxGenerations, snapshot: s)
            : nil
        @inline(__always) func bfsBits(_ o: Int) -> UInt8 {
            (genA[o] >= 0 ? 1 : 0) | ((genB?[o] ?? -1) >= 0 ? 2 : 0)
        }
        var reachable = 0
        for o in 0..<n where bfsBits(o) != 0 { reachable += 1 }

        // ---- 4. The layered walk (the order the animation replays).
        emit(.phase("Walking"))
        let cadence = options.progressEvery
            ?? ((options.maxGenerations.map { $0 <= 5 } ?? false) || reachable < 5_000 ? 100 : 1_000)
        func sample(_ o: Int) -> Sample {
            Sample(id: s.ids[o], name: s.names[o], birthYear: s.birth[o]?.year,
                   line: Line(bits: bfsBits(o)),
                   generationFromFirst: genA[o] >= 0 ? Int(genA[o]) : nil,
                   generationFromSecond: genB.flatMap { $0[o] >= 0 ? Int($0[o]) : nil },
                   ageAtDeath: ages[o], birthRegion: s.region[o], childCount: Int(s.childCount[o]))
        }
        var layers: [[Visit]] = []
        var seen = [Bool](repeating: false, count: n)
        var frontier: [Visit] = []
        for (i, o) in startOrdinals.enumerated() where !seen[o] {
            seen[o] = true
            frontier.append(Visit(ordinal: Int32(o), generation: 0, from: -1, slot: UInt8(i),
                                  slots: UInt8(startOrdinals.count), line: Line(bits: bfsBits(o)), hasCheck: false))
        }
        var visited = frontier.count
        var generation = 0
        while !frontier.isEmpty {
            try checkpoint()
            layers.append(frontier)
            if let limit = options.maxGenerations, generation >= limit { break }
            var next: [Visit] = []
            for v in frontier {
                let ps = s.parents(of: Int(v.ordinal))
                for (slot, p) in ps.enumerated() where !seen[Int(p)] {
                    seen[Int(p)] = true
                    next.append(Visit(ordinal: p, generation: Int32(generation + 1), from: v.ordinal,
                                      slot: UInt8(min(slot, 255)), slots: UInt8(min(ps.count, 255)),
                                      line: Line(bits: bfsBits(Int(p))), hasCheck: false))
                    visited += 1
                    if visited % cadence == 0 {
                        emit(.progress(Progress(visited: visited, reachable: reachable, generation: generation + 1,
                                                frontier: next.count, sample: sample(Int(p)))))
                    }
                }
            }
            frontier = next
            generation += 1
        }

        // ---- 5. Inherited over the condensation, children first.
        var lineBits = [UInt8](repeating: 0, count: n)
        var pathsA = [Double](repeating: 0, count: n)
        var pathsB = [Double](repeating: 0, count: n)
        let walked: (Int) -> Bool = { bfsBits($0) != 0 }
        for comp in comps.members.indices.reversed() {
            let group = comps.members[comp]
            guard group.contains(where: { walked(Int($0)) }) else { continue }
            var bits: UInt8 = 0
            var pa = 0.0, pb = 0.0
            for m in group {
                let mi = Int(m)
                if mi == startOrdinals[0] { bits |= 1; pa += 1 }
                if startOrdinals.count > 1, mi == startOrdinals[1] { bits |= 2; pb += 1 }
                for c in s.kids(of: mi) where comps.component[Int(c)] != Int32(comp) && walked(Int(c)) {
                    bits |= lineBits[Int(c)]
                    pa += pathsA[Int(c)]
                    pb += pathsB[Int(c)]
                }
            }
            if comps.cyclic[comp] {
                // A cycle has infinitely many paths: poison, and NaN carries
                // the poison to every ancestor above it (NaN + x = NaN).
                if bits & 1 != 0 { pa = .nan }
                if bits & 2 != 0 { pb = .nan }
            }
            for m in group {
                // The DP bits agree with BFS reachability on an unlimited
                // walk; a depth limit is honoured by the AND.
                lineBits[Int(m)] = bits & bfsBits(Int(m))
                pathsA[Int(m)] = pa
                pathsB[Int(m)] = pb
            }
        }
        let walkMs = ms(clock.now - tWalk)
        try checkpoint()

        // ---- 6. Synthesized: ancestor and descendant sets.
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

        // ---- 7. Checks.
        emit(.phase("Checking"))
        let tChecks = clock.now
        var checks = TreeWalkChecks.perPerson(snapshot: s, graph: graph, ages: ages)
        checks += TreeWalkChecks.duplicates(snapshot: s)
        let cycleChecks = TreeWalkChecks.cycles(snapshot: s, components: comps)
        checks += cycleChecks
        let kindOrder = Dictionary(uniqueKeysWithValues: CheckKind.allCases.enumerated().map { ($1, $0) })
        checks.sort { a, b in
            if a.kind != b.kind { return kindOrder[a.kind]! < kindOrder[b.kind]! }
            return a.personIDs.lexicographicallyPrecedes(b.personIDs)
        }
        let checksMs = ms(clock.now - tChecks)
        var checksOf = [[Int]](repeating: [], count: n)
        for (i, check) in checks.enumerated() {
            for id in check.personIDs {
                if let o = s.ordinal(of: id), checksOf[o].last != i { checksOf[o].append(i) }
            }
        }
        for check in cycleChecks { emit(.cycle(check)) }
        for check in checks where check.severity == .warn && check.kind != .ancestorCycle { emit(.warnCheck(check)) }
        try checkpoint()

        // ---- 8. Assemble.
        let decorations: [Decoration] = TreeWalkParallel.map(count: n) { o in
            var d = Decoration()
            guard s.visible[o] else { return d }
            d.line = Line(bits: lineBits[o])
            d.generationFromFirst = genA[o] >= 0 ? Int(genA[o]) : nil
            d.generationFromSecond = genB.flatMap { $0[o] >= 0 ? Int($0[o]) : nil }
            d.pathsFromFirst = lineBits[o] & 1 != 0 ? pathsA[o] : nil
            d.pathsFromSecond = lineBits[o] & 2 != 0 ? pathsB[o] : nil
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
        // The start people are the ones read most: give them EXACT counts
        // (an unlimited BFS each — O(their ancestors)) instead of the sketch
        // estimate.
        var decorated = decorations
        for o in startOrdinals {
            let gen = TreeWalkGraph.generations(from: o, maxGenerations: nil, snapshot: s)
            var count = 0, datedCount = 0
            for x in 0..<n where x != o && gen[x] >= 0 {
                count += 1
                if dated[x] { datedCount += 1 }
            }
            decorated[o].ancestorCount = Count(value: count, isEstimate: false)
            decorated[o].documentedAncestorFraction = count == 0 ? nil : Double(datedCount) / Double(count)
        }
        let finalLayers = layers.map { layer in
            layer.map { v in
                Visit(ordinal: v.ordinal, generation: v.generation, from: v.from, slot: v.slot, slots: v.slots,
                      line: Line(bits: lineBits[Int(v.ordinal)]), hasCheck: !checksOf[Int(v.ordinal)].isEmpty)
            }
        }

        var summary = Summary()
        summary.peopleInTree = s.visible.filter { $0 }.count
        summary.peopleWalked = visited
        for layer in finalLayers {
            for v in layer {
                summary.byLine[v.line, default: 0] += 1
                summary.byRegion[s.region[Int(v.ordinal)], default: 0] += 1
            }
        }
        for c in checks {
            summary.checksByKind[c.kind, default: 0] += 1
            if c.severity == .warn { summary.warnCount += 1 } else { summary.infoCount += 1 }
        }
        summary.cycleCount = cycleChecks.count
        summary.generationsFromFirst = Int(genA.max() ?? 0)
        summary.generationsFromSecond = Int(genB?.max() ?? 0)
        summary.coverageWalked = coverage(s, ages: ages) { walked($0) }
        summary.coverageTree = coverage(s, ages: ages) { s.visible[$0] }
        summary.walkMilliseconds = walkMs
        summary.checksMilliseconds = checksMs
        summary.estimatedAncestorCounts = anc.estimated
        summary.totalMilliseconds = ms(clock.now - t0)

        return Result(walkerVersion: walkerVersion, sourceKey: sourceKey, generatedAt: now,
                      starts: starts, maxGenerations: options.maxGenerations,
                      ids: s.ids, names: s.names, decorations: decorated, visible: s.visible,
                      checks: checks, summary: summary, layers: finalLayers)
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
