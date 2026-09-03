// LineageTrail.swift
// The birthplace TRAIL (Rick, 2026-09-02, for his brother's demo): walk a
// person's maternal or paternal line — or every ancestor, generation by
// generation — reporting each ancestor's birthplace, and stop at the first
// one that satisfies a rule ("outside the United States", "in Europe",
// "N generations", or simply the top of the tree).
//
// Built ONLY on `primaryMother(of:)` / `primaryFather(of:)`, so the trail
// follows exactly the parents every other walk follows. Missing
// birthplaces are reported, never filled in, and never stop the walk on
// their own — unless three generations in a row record nothing, in which
// case the trail is said to run out. Nothing walks past 20 generations.
//
// Ties (codex #1014 item 2): an all-ancestors walk stops at the FIRST
// generation holding a match and returns EVERY match at that generation
// (`matches`), ordered by line label (father-side hops before mother-side
// hops, so "father → father" sorts before "father → mother") and then by
// GEDCOM pointer. Full paths back down are materialised for the first
// `maxTiePaths` only (`matchPaths`) — a synthetic 17-generation pedigree
// ties 65,536 ways at its top, and the prose never names more than a few.
// `steps` is the first path; the prose must not call it "the" first
// ancestor when `matches` has more than one.
//
// Pure functions over an in-memory graph; no I/O. C++ readers: `enum
// LineageTrail` with no cases is a namespace; the nested `enum Line` /
// `enum Stop` ARE sum types (tagged unions with payloads).

import Foundation

public enum LineageTrail {

    /// Which parents the trail follows.
    public enum Line: String, Sendable, Equatable {
        /// Mother, her mother, her mother …
        case maternal
        /// Father, his father, his father …
        case paternal
        /// Both parents at every step, one generation at a time (a
        /// breadth-first pedigree); stops at the FIRST generation holding
        /// a match and reports every match there with its path back down.
        case allAncestors
    }

    /// What each step reports. One report today; the enum keeps the
    /// question ("report the birthplace") separate from the walk.
    public enum Report: String, Sendable, Equatable {
        case birthplace
    }

    /// When the walk stops early. `.top` means "where the tree ends".
    public enum Stop: Sendable, Equatable {
        case top
        case outsideCountry(String)
        case continent(BirthplaceClassifier.Continent)
        case generations(Int)
    }

    /// Why the walk ended.
    public enum Ending: Sendable, Equatable {
        /// A step satisfied the stop rule (`match` is set).
        case stopped
        /// No recorded parent to follow.
        case top
        /// The requested generation count (or the 20-generation cap).
        case generationCap
        /// Three consecutive generations with no recorded birthplace.
        case ranOut
    }

    /// One person on the trail. `generation` 0 is the person the walk
    /// started from; 1 = parent, 2 = grandparent …
    public struct Step: Sendable, Equatable {
        public let generation: Int
        public let person: GedcomFamilyGraph.Person
        /// The classified birthplace; nil when the record has no PLAC
        /// ("birthplace not recorded").
        public let birthplace: BirthplaceClassifier.Place?
        /// True for the step that satisfied the stop rule.
        public let matchesStop: Bool
        /// "father" / "mother" — which parent this step is of the step
        /// below it; nil for the anchor. Together the labels of a path
        /// name the line ("father → father → mother").
        public let hop: String?

        public init(generation: Int, person: GedcomFamilyGraph.Person,
                    birthplace: BirthplaceClassifier.Place?, matchesStop: Bool, hop: String? = nil) {
            self.generation = generation
            self.person = person
            self.birthplace = birthplace
            self.matchesStop = matchesStop
            self.hop = hop
        }

        public var birthYear: Int? { person.birthYear }
        public var placeText: String? { birthplace?.raw }
    }

    public struct Result: Sendable, Equatable {
        public let line: Line
        public let stop: Stop
        /// The trail, starting from the person walked from (generation
        /// 0). For `.allAncestors` this is the PATH from that person up to
        /// the first match — empty except for the anchor when nothing
        /// matched.
        public let steps: [Step]
        /// EVERY match at the nearest matching generation, in tie order
        /// (line label, then pointer). One on a single line; empty when
        /// nothing matched. Each step carries its own last hop.
        public let matches: [Step]
        /// The paths to the first `maxTiePaths` matches, the first being
        /// `steps`. `matches.count` says how many ties there are in all.
        public let matchPaths: [[Step]]
        public let ending: Ending
        /// Generations actually walked (the deepest generation reached).
        public let generationsWalked: Int
        /// The people at the deepest generation walked, for the prose
        /// ("the line ends at …"). One person on a single line.
        public let lastGeneration: [GedcomFamilyGraph.Person]

        /// The first match (tie order).
        public var match: Step? { steps.last(where: { $0.matchesStop }) }
        /// Steps above the anchor.
        public var ancestors: [Step] { Array(steps.dropFirst()) }
    }

    public static let generationCap = 20
    /// Consecutive generations with no birthplace anywhere before the
    /// trail is said to run out.
    public static let unknownRunLimit = 3
    /// Tie paths materialised in full; the rest are in `matches` only.
    public static let maxTiePaths = 8

    /// The line a path took, for ordering and prose: "father → mother".
    public static func lineLabel(of path: [Step]) -> String {
        path.compactMap(\.hop).joined(separator: " → ")
    }

    // MARK: - Walk

    public static func walk(line: Line,
                            from person: GedcomFamilyGraph.Person,
                            report: Report = .birthplace,
                            stop: Stop,
                            graph: GedcomFamilyGraph) -> Result {
        switch line {
        case .maternal, .paternal:
            return walkSingleLine(line, from: person, stop: stop, graph: graph)
        case .allAncestors:
            return walkAllAncestors(from: person, stop: stop, graph: graph)
        }
    }

    /// The generation bound for a walk: the asked-for count, never more
    /// than the cap.
    static func bound(for stop: Stop) -> Int {
        if case .generations(let n) = stop { return max(0, min(n, generationCap)) }
        return generationCap
    }

    /// Does this birthplace satisfy the stop rule? Unknown, unrecorded
    /// and ambiguous places never do.
    static func satisfies(_ stop: Stop, _ place: BirthplaceClassifier.Place?) -> Bool {
        guard let place else { return false }
        switch stop {
        case .top, .generations: return false
        case .outsideCountry(let country): return place.isOutside(country: country)
        case .continent(let continent): return place.isIn(continent)
        }
    }

    static func classify(_ person: GedcomFamilyGraph.Person) -> BirthplaceClassifier.Place? {
        person.birthPlace.map { BirthplaceClassifier.classify($0) }
    }

    private static func walkSingleLine(_ line: Line,
                                       from anchor: GedcomFamilyGraph.Person,
                                       stop: Stop,
                                       graph: GedcomFamilyGraph) -> Result {
        var steps = [Step(generation: 0, person: anchor, birthplace: classify(anchor), matchesStop: false)]
        var current = anchor
        var seen: Set<String> = [anchor.id]
        var unknownRun = 0
        let limit = bound(for: stop)
        var ending: Ending = .top
        var generation = 0
        let hop = line == .maternal ? "mother" : "father"
        while generation < limit {
            // Swift's `guard let` ≈ C++ early-exit after a null check.
            let parent = line == .maternal ? graph.primaryMother(of: current) : graph.primaryFather(of: current)
            guard let parent, !seen.contains(parent.id) else { ending = .top; break }
            seen.insert(parent.id)
            generation += 1
            let place = classify(parent)
            let hit = satisfies(stop, place)
            steps.append(Step(generation: generation, person: parent, birthplace: place, matchesStop: hit, hop: hop))
            current = parent
            if hit { ending = .stopped; break }
            unknownRun = place == nil ? unknownRun + 1 : 0
            if unknownRun >= unknownRunLimit { ending = .ranOut; break }
            if generation == limit { ending = .generationCap }
        }
        if generation == 0 { ending = .top }
        let stopped = ending == .stopped
        return Result(line: line, stop: stop, steps: steps,
                      matches: stopped ? [steps[steps.count - 1]] : [],
                      matchPaths: stopped ? [steps] : [],
                      ending: ending, generationsWalked: generation, lastGeneration: [current])
    }

    private static func walkAllAncestors(from anchor: GedcomFamilyGraph.Person,
                                         stop: Stop,
                                         graph: GedcomFamilyGraph) -> Result {
        // Breadth-first over primary parents. `reachedThrough[id]`
        // remembers the CHILD each ancestor was reached through (and which
        // parent of that child it is), so the path back to the anchor is a
        // chain of dictionary lookups, not a second search.
        // Memory: one entry per ancestor visited (a 20-generation full
        // pedigree is at most 2^21 entries; real trees collapse far below).
        var reachedThrough: [String: (child: String, hop: String)] = [:]
        var frontier: [GedcomFamilyGraph.Person] = [anchor]
        var seen: Set<String> = [anchor.id]
        let limit = bound(for: stop)
        var generation = 0
        var unknownRun = 0
        var ending: Ending = .top
        /// Every match at the stopping generation, with the place already
        /// classified during the walk (never classified twice).
        var matched: [(person: GedcomFamilyGraph.Person, place: BirthplaceClassifier.Place?)] = []
        var lastFrontier = frontier

        while generation < limit, matched.isEmpty {
            var next: [GedcomFamilyGraph.Person] = []
            var anyPlace = false
            // Father then mother, inline: this loop touches every person
            // of a 131k-record pedigree, so no per-child array or closure.
            for child in frontier {
                for side in 0..<2 {
                    let parent = side == 0 ? graph.primaryFather(of: child) : graph.primaryMother(of: child)
                    guard let parent, !seen.contains(parent.id) else { continue }
                    seen.insert(parent.id)
                    reachedThrough[parent.id] = (child.id, side == 0 ? "father" : "mother")
                    next.append(parent)
                    let place = classify(parent)
                    if place != nil { anyPlace = true }
                    if satisfies(stop, place) { matched.append((parent, place)) }
                }
            }
            if next.isEmpty { ending = .top; break }
            generation += 1
            frontier = next
            lastFrontier = next
            if !matched.isEmpty { ending = .stopped; break }
            unknownRun = anyPlace ? 0 : unknownRun + 1
            if unknownRun >= unknownRunLimit { ending = .ranOut; break }
            if generation == limit { ending = .generationCap }
        }

        // The hops from the anchor up to `id`, bottom-up order.
        func hops(to id: String) -> [String] {
            var out: [String] = []
            var cursor = id
            while let via = reachedThrough[cursor] {
                out.append(via.hop)
                cursor = via.child
            }
            return out.reversed()
        }
        // Tie order: line label, then pointer. Labels are computed once
        // per match, never inside the comparator.
        let ordered = matched.indices.map { i -> (label: String, id: String, index: Int) in
            (hops(to: matched[i].person.id).joined(separator: " → "), matched[i].person.id, i)
        }.sorted { a, b in a.label != b.label ? a.label < b.label : a.id < b.id }

        let matches: [Step] = ordered.map { entry in
            let m = matched[entry.index]
            return Step(generation: generation, person: m.person, birthplace: m.place, matchesStop: true,
                        hop: reachedThrough[m.person.id]?.hop)
        }
        // One full path per leading match: anchor first, then each
        // generation up to it (classified along the way, a handful only).
        func path(to match: GedcomFamilyGraph.Person) -> [Step] {
            var chain: [(GedcomFamilyGraph.Person, String?)] = []
            var cursor: GedcomFamilyGraph.Person? = match
            while let p = cursor {
                let via = reachedThrough[p.id]
                chain.append((p, via?.hop))
                cursor = via.flatMap { graph.people[$0.child] }
            }
            chain.reverse()
            return chain.enumerated().map { g, entry in
                Step(generation: g, person: entry.0, birthplace: classify(entry.0),
                     matchesStop: match.id == entry.0.id, hop: entry.1)
            }
        }
        let paths = matches.prefix(maxTiePaths).map { path(to: $0.person) }
        let steps = paths.first
            ?? [Step(generation: 0, person: anchor, birthplace: classify(anchor), matchesStop: false)]
        return Result(line: .allAncestors, stop: stop, steps: steps, matches: matches, matchPaths: paths,
                      ending: ending, generationsWalked: generation, lastGeneration: lastFrontier)
    }
}
