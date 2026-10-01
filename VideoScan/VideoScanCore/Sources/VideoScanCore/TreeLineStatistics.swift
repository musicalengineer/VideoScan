// TreeLineStatistics.swift (VideoScanCore)
// Statistics over a family's ANCESTOR LINES, one or two sides at a time
// (GH #214, #200; Rick approved 2026-10-01):
//
//   "how many of our ancestors were born in New England vs Old England?"
//   "what was the average age at death of our ancestors?"
//   "how deep does our deepest line go?"   "who is our earliest ancestor?"
//
// "Our" is the owner AND the owner's partner — Rick's line and Donna's line,
// the two start people of the Family Tree walk — so every figure is reported
// for the union AND per side. A person on both lines (pedigree overlap
// between the two families) is counted ONCE in the union and once on each
// side, and the shared count is reported so the per-side numbers never seem
// to add up wrong.
//
// SAME FACTS AS THE TREE WALK'S DECORATIONS. The population is the walk's
// own edge set (the compiled parent topology, hidden records left out) and
// the per-person facts are the walk's own pure functions — TreeWalkDate,
// AgeAtDeath.between, BirthplaceClassifier.region — so a figure here equals
// the one computed from decorations.json for the same tree. When a caller
// HAS decorations it may pass them and they are used as-is (no re-parsing);
// TreeLineStatisticsTests pins the equivalence.
//
// THE RULE THAT MATTERS (as in TreeStatistics): every figure carries its
// denominator. A result says how many people it was asked of, how many had
// the field, and how many were set aside and why — the prose layer cannot
// omit what it never received.
//
// Pure; no I/O, no model. Cost: one BFS per side over the compiled index
// (O(ancestors)) plus one pass over the members. Worst-case memory: two
// Int32 columns per side over the whole index (8 bytes × people × sides —
// 1.6 MB at 100k) and one Member per ancestor (~150 bytes) — freed with the
// result.
//
// C++ readers: `enum TreeLineStatistics` with no cases is a namespace; the
// structs are plain values.

import Foundation

public enum TreeLineStatistics {

    // MARK: - Population

    /// One side of the family: the start person whose ancestors it is.
    public struct Side: Sendable, Equatable {
        public let id: String
        public let name: String
        public let sex: String
    }

    /// One ancestor, with the facts every statistic here reads.
    public struct Member: Sendable, Equatable {
        public let id: String
        public let name: String
        public let sex: String
        /// Generations above each side's start (index-aligned with
        /// `Population.sides`; 1 = parent); nil = not on that side.
        public let generations: [Int?]
        public let birthYear: Int?
        public let birthPrecision: DatePrecision?
        public let deathYear: Int?
        public let ageAtDeath: AgeAtDeath?
        public let birthRegion: BirthplaceClassifier.BirthRegion
        public let birthPlace: String?

        public func isOn(side i: Int) -> Bool {
            generations.indices.contains(i) && generations[i] != nil
        }
        /// Nearest generation on any side.
        public var nearestGeneration: Int { generations.compactMap { $0 }.min() ?? 0 }
    }

    /// The ancestors of one or two start people, each once, in id order.
    public struct Population: Sendable {
        public let sides: [Side]
        public let members: [Member]
        /// Per side: ordinal → the child on the shortest line toward that
        /// side's start (−1 = not an ancestor). Lets a statistic show the
        /// line it is talking about without another walk.
        let childToward: [[Int32]]
        /// The graph's compiled index (shared, copy-on-write — not a copy).
        let index: GedcomFamilyGraph.TreeIndex

        /// Members on side `i`.
        public func count(onSide i: Int) -> Int { members.reduce(0) { $0 + ($1.isOn(side: i) ? 1 : 0) } }
        /// Members on every side (pedigree overlap between the families).
        public var sharedCount: Int {
            guard sides.count > 1 else { return 0 }
            return members.reduce(0) { n, m in n + (sides.indices.allSatisfy { m.isOn(side: $0) } ? 1 : 0) }
        }

        /// The ids from `memberID` down to side `i`'s start, ancestor first:
        /// `[ancestor, child, …, start]`. Empty when not on that side.
        public func line(from memberID: String, side i: Int) -> [String] {
            guard childToward.indices.contains(i), var o = index.ordinal(of: memberID),
                  childToward[i][Int(o)] >= 0 else { return [] }
            var out = [index.ids[Int(o)]]
            var guardSteps = 0
            while childToward[i][Int(o)] >= 0, guardSteps < 10_000 {
                o = childToward[i][Int(o)]
                out.append(index.ids[Int(o)])
                guardSteps += 1
            }
            return out
        }
    }

    /// The recorded ancestors of `startIDs` (one or two people), from the
    /// graph's compiled parent topology with hidden records left out — the
    /// tree walk's edges. Nil when a start is unknown or hidden.
    ///
    /// `decorations` (optional): the walk's per-person facts, used instead
    /// of re-parsing dates and places when present (decorations.json).
    public static func ancestors(of startIDs: [String],
                                 in graph: GedcomFamilyGraph,
                                 decorations: [String: TreeWalk.Decoration]? = nil) -> Population? {
        var unique: [String] = []
        for id in startIDs where !unique.contains(id) { unique.append(id) }
        guard !unique.isEmpty else { return nil }
        let index = graph.index
        var sides: [Side] = []
        var depths: [[Int32]] = []
        var toward: [[Int32]] = []
        for id in unique {
            guard let p = graph.people[id], !graph.isHidden(id), let start = index.ordinal(of: id) else { return nil }
            sides.append(Side(id: id, name: p.name, sex: p.sex.uppercased()))
            let walk = bfs(from: start, index: index, graph: graph)
            depths.append(walk.depth)
            toward.append(walk.toward)
        }
        // A start is not their own ancestor; the other start may be (a
        // parent and child asked about together) — kept, it is a real line.
        var members: [Member] = []
        for o in 0..<index.count {
            let gens: [Int?] = depths.map { $0[o] > 0 ? Int($0[o]) : nil }
            guard gens.contains(where: { $0 != nil }) else { continue }
            let id = index.ids[o]
            guard let p = graph.people[id] else { continue }
            members.append(member(p, generations: gens, decoration: decorations?[id]))
        }
        members.sort { $0.id < $1.id }
        return Population(sides: sides, members: members, childToward: toward, index: index)
    }

    /// Level-order BFS up the parent edges (fathers first, so ties break
    /// paternal-first like every ancestor walk in the app), skipping hidden
    /// records. depth: −1 = not reached, 0 = the start. A corrupt self-
    /// ancestor loop stops because a visited node is never re-queued.
    private static func bfs(from start: Int32, index: GedcomFamilyGraph.TreeIndex,
                            graph: GedcomFamilyGraph) -> (depth: [Int32], toward: [Int32]) {
        var depth = [Int32](repeating: -1, count: index.count)
        var toward = [Int32](repeating: -1, count: index.count)
        depth[Int(start)] = 0
        var queue: [Int32] = [start]
        var head = 0
        while head < queue.count {
            let child = queue[head]
            head += 1
            for parent in index.parents(of: child) where depth[Int(parent)] < 0 {
                if graph.isHidden(index.ids[Int(parent)]) { continue }
                depth[Int(parent)] = depth[Int(child)] + 1
                toward[Int(parent)] = child
                queue.append(parent)
            }
        }
        return (depth, toward)
    }

    private static func member(_ p: GedcomFamilyGraph.Person, generations: [Int?],
                               decoration d: TreeWalk.Decoration?) -> Member {
        if let d {
            return Member(id: p.id, name: p.name, sex: d.sex, generations: generations,
                          birthYear: d.birthYear, birthPrecision: d.birthPrecision, deathYear: d.deathYear,
                          ageAtDeath: d.ageAtDeath, birthRegion: d.birthRegion, birthPlace: p.birthPlace)
        }
        // The walk's own local attributes (TreeWalkSnapshot.init), one person.
        let birth = TreeWalkDate.parse(p.birthDate)
        let death = TreeWalkDate.parse(p.deathDate)
        return Member(id: p.id, name: p.name, sex: p.sex.uppercased(), generations: generations,
                      birthYear: birth?.year, birthPrecision: birth?.precision, deathYear: death?.year,
                      ageAtDeath: AgeAtDeath.between(birth: birth, death: death),
                      birthRegion: BirthplaceClassifier.region(p.birthPlace), birthPlace: p.birthPlace)
    }

    // MARK: - Birthplaces

    /// A place a question names. Regions are the walk's birth regions
    /// (New England, England = "Old England", Ireland …); a set, so "the
    /// United States" is every American region together. A country outside
    /// the region list (France, Germany) is judged by the classifier over
    /// the recorded string, exactly as TreeStatistics does.
    public enum Place: Sendable, Hashable {
        case regions(Set<BirthplaceClassifier.BirthRegion>)
        case country(String)
    }

    public struct PlaceRow: Sendable, Equatable {
        public let place: Place
        public let total: Int
        /// Index-aligned with `Population.sides`.
        public let perSide: [Int]
    }

    /// Birthplace counts with their coverage.
    ///   considered  every ancestor asked about
    ///   placed      ancestors whose recorded birthplace resolves to a region
    ///               (anything but `.unknown`) — the denominator the rows
    ///               are read against
    ///   unplaced    considered − placed: no birthplace, or one that cannot
    ///               be placed (an unknown name, or a historical name that
    ///               spans today's borders)
    public struct PlaceReport: Sendable, Equatable {
        public let considered: Int
        public let placed: Int
        public let consideredPerSide: [Int]
        public let placedPerSide: [Int]
        public let shared: Int
        public let rows: [PlaceRow]
        /// Placed births in none of the asked places.
        public let elsewhere: Int
        public var unplaced: Int { considered - placed }
    }

    public static func birthplaces(_ population: Population, places: [Place]) -> PlaceReport {
        let n = population.sides.count
        var placed = 0
        var placedPerSide = [Int](repeating: 0, count: n)
        var consideredPerSide = [Int](repeating: 0, count: n)
        var totals = [Int](repeating: 0, count: places.count)
        var perSide = [[Int]](repeating: [Int](repeating: 0, count: n), count: places.count)
        var elsewhere = 0
        for m in population.members {
            for s in 0..<n where m.isOn(side: s) { consideredPerSide[s] += 1 }
            guard m.birthRegion != .unknown else { continue }
            placed += 1
            for s in 0..<n where m.isOn(side: s) { placedPerSide[s] += 1 }
            var hit = false
            for (i, place) in places.enumerated() where matches(place, m) {
                hit = true
                totals[i] += 1
                for s in 0..<n where m.isOn(side: s) { perSide[i][s] += 1 }
            }
            if !hit { elsewhere += 1 }
        }
        let rows = places.indices.map { PlaceRow(place: places[$0], total: totals[$0], perSide: perSide[$0]) }
        return PlaceReport(considered: population.members.count, placed: placed,
                           consideredPerSide: consideredPerSide, placedPerSide: placedPerSide,
                           shared: population.sharedCount, rows: rows, elsewhere: elsewhere)
    }

    static func matches(_ place: Place, _ m: Member) -> Bool {
        switch place {
        case .regions(let set):
            return set.contains(m.birthRegion)
        case .country(let name):
            guard let raw = m.birthPlace, !raw.isEmpty else { return false }
            let c = BirthplaceClassifier.classify(raw)
            guard !c.isAmbiguous, let country = c.country else { return false }
            return country.compare(name, options: .caseInsensitive) == .orderedSame
        }
    }

    // MARK: - Age at death

    /// An age is USABLE when the two dates pin it within `maxAgeSpread`
    /// years (a year-only birth and death give a one-year spread) and it is
    /// at most `maxPlausibleAge`. The usable value is the midpoint.
    public static let maxAgeSpread = 2
    public static let maxPlausibleAge = 110

    public struct AgeReport: Sendable, Equatable {
        public let considered: Int
        public let usable: Int
        public let mean: Double
        public let median: Double
        /// Index-aligned with sides: (usable, mean); mean is 0 when usable is 0.
        public let perSide: [SideAge]
        /// Ancestors with both dates whose age could only be bracketed
        /// more widely than `maxAgeSpread` ("ABT 1700" to "1760").
        public let tooVague: Int
        /// Ages over `maxPlausibleAge` or below zero — likely transcription
        /// errors, left out and counted.
        public let implausible: Int
        /// The longest PROVEN life (largest minimum age), ties by name, up to 3.
        public let oldest: [Member]
        public let oldestTies: Int
        public var missingDates: Int { considered - usable - tooVague - implausible }
    }

    public struct SideAge: Sendable, Equatable {
        public let usable: Int
        public let mean: Double
    }

    public static func ageAtDeath(_ population: Population) -> AgeReport? {
        let n = population.sides.count
        var values: [Double] = []
        var sideSum = [Double](repeating: 0, count: n), sideCount = [Int](repeating: 0, count: n)
        var vague = 0, implausible = 0
        var usableMembers: [Member] = []
        for m in population.members {
            guard let age = m.ageAtDeath else { continue }
            if age.minYears < 0 || age.maxYears > maxPlausibleAge { implausible += 1; continue }
            if age.maxYears - age.minYears > maxAgeSpread { vague += 1; continue }
            let v = Double(age.minYears + age.maxYears) / 2
            values.append(v)
            usableMembers.append(m)
            for s in 0..<n where m.isOn(side: s) { sideSum[s] += v; sideCount[s] += 1 }
        }
        guard !values.isEmpty else {
            return population.members.isEmpty ? nil : AgeReport(
                considered: population.members.count, usable: 0, mean: 0, median: 0,
                perSide: (0..<n).map { _ in SideAge(usable: 0, mean: 0) },
                tooVague: vague, implausible: implausible, oldest: [], oldestTies: 0)
        }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        let median = sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
        let best = usableMembers.map { $0.ageAtDeath!.minYears }.max()!
        let ties = usableMembers.filter { $0.ageAtDeath!.minYears == best }
            .sorted { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }
        return AgeReport(
            considered: population.members.count, usable: values.count,
            mean: values.reduce(0, +) / Double(values.count), median: median,
            perSide: (0..<n).map { SideAge(usable: sideCount[$0], mean: sideCount[$0] == 0 ? 0 : sideSum[$0] / Double(sideCount[$0])) },
            tooVague: vague, implausible: implausible,
            oldest: Array(ties.prefix(3)), oldestTies: ties.count)
    }

    // MARK: - Deepest line

    public struct DeepestLine: Sendable, Equatable {
        public let side: Int
        /// Generations above the side's start (1 = parent).
        public let generations: Int
        /// How many ancestors sit at that depth.
        public let atDepth: Int
        /// The one shown: the earliest-born at that depth, else by name.
        public let ancestor: Member
        /// Ids from `ancestor` down to the start, ancestor first.
        public let line: [String]
    }

    /// The deepest recorded generation on each side (nil for a side with
    /// no recorded parents). Depth is the SHORTEST line to each person, so
    /// pedigree collapse never lengthens it.
    public static func deepestLines(_ population: Population) -> [DeepestLine?] {
        population.sides.indices.map { s in
            var best = 0
            var at: [Member] = []
            for m in population.members {
                guard let g = m.generations[s] else { continue }
                if g > best { best = g; at = [m] } else if g == best { at.append(m) }
            }
            guard best > 0 else { return nil }
            let pick = at.min { a, b in
                switch (a.birthYear, b.birthYear) {
                case let (x?, y?) where x != y: return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a.name == b.name ? a.id < b.id : a.name < b.name
                }
            }!
            return DeepestLine(side: s, generations: best, atDepth: at.count, ancestor: pick,
                               line: population.line(from: pick.id, side: s))
        }
    }

    // MARK: - Earliest ancestor

    public struct Earliest: Sendable, Equatable {
        public let considered: Int
        /// Ancestors with a birth year — the ones that could be ranked.
        public let dated: Int
        /// Nil when nobody has a birth year.
        public let year: Int?
        /// The earliest-born, ties by name, up to 3.
        public let people: [Member]
        public let ties: Int
    }

    /// The earliest recorded birth year over the union, and over each side
    /// (`side` nil = the union).
    public static func earliest(_ population: Population, side: Int? = nil) -> Earliest {
        let pool = side.map { s in population.members.filter { $0.isOn(side: s) } } ?? population.members
        let dated = pool.filter { $0.birthYear != nil }
        guard let year = dated.map({ $0.birthYear! }).min() else {
            return Earliest(considered: pool.count, dated: 0, year: nil, people: [], ties: 0)
        }
        let ties = dated.filter { $0.birthYear == year }
            .sorted { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }
        return Earliest(considered: pool.count, dated: dated.count, year: year,
                        people: Array(ties.prefix(3)), ties: ties.count)
    }
}
