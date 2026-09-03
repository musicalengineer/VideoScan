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
        /// a match and reports that person with the path back down.
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

        public var birthYear: Int? { person.birthYear }
        public var placeText: String? { birthplace?.raw }
    }

    public struct Result: Sendable, Equatable {
        public let line: Line
        public let stop: Stop
        /// The trail, starting from the person walked from (generation
        /// 0). For `.allAncestors` this is the PATH from that person up to
        /// the match — empty except for the anchor when nothing matched.
        public let steps: [Step]
        public let ending: Ending
        /// Generations actually walked (the deepest generation reached).
        public let generationsWalked: Int
        /// The people at the deepest generation walked, for the prose
        /// ("the line ends at …"). One person on a single line.
        public let lastGeneration: [GedcomFamilyGraph.Person]

        public var match: Step? { steps.last(where: { $0.matchesStop }) }
        /// Steps above the anchor.
        public var ancestors: [Step] { Array(steps.dropFirst()) }
    }

    public static let generationCap = 20
    /// Consecutive generations with no birthplace anywhere before the
    /// trail is said to run out.
    public static let unknownRunLimit = 3

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

    /// Does this birthplace satisfy the stop rule? Unknown / unrecorded
    /// places never do.
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
        while generation < limit {
            // Swift's `guard let` ≈ C++ early-exit after a null check.
            let parent = line == .maternal ? graph.primaryMother(of: current) : graph.primaryFather(of: current)
            guard let parent, !seen.contains(parent.id) else { ending = .top; break }
            seen.insert(parent.id)
            generation += 1
            let place = classify(parent)
            let hit = satisfies(stop, place)
            steps.append(Step(generation: generation, person: parent, birthplace: place, matchesStop: hit))
            current = parent
            if hit { ending = .stopped; break }
            unknownRun = place == nil ? unknownRun + 1 : 0
            if unknownRun >= unknownRunLimit { ending = .ranOut; break }
            if generation == limit { ending = .generationCap }
        }
        if generation == 0 { ending = .top }
        return Result(line: line, stop: stop, steps: steps, ending: ending,
                      generationsWalked: generation, lastGeneration: [current])
    }

    private static func walkAllAncestors(from anchor: GedcomFamilyGraph.Person,
                                         stop: Stop,
                                         graph: GedcomFamilyGraph) -> Result {
        // Breadth-first over primary parents. `parentOf[id]` remembers the
        // CHILD each ancestor was reached through, so the path back to the
        // anchor is a chain of dictionary lookups, not a second search.
        // Memory: one entry per ancestor visited (a 20-generation full
        // pedigree is at most 2^21 entries; real trees collapse far below).
        var reachedThrough: [String: String] = [:]
        var frontier: [GedcomFamilyGraph.Person] = [anchor]
        var seen: Set<String> = [anchor.id]
        let limit = bound(for: stop)
        var generation = 0
        var unknownRun = 0
        var ending: Ending = .top
        var match: GedcomFamilyGraph.Person? = nil
        var lastFrontier = frontier

        while generation < limit, match == nil {
            var next: [GedcomFamilyGraph.Person] = []
            var anyPlace = false
            for child in frontier {
                for parent in [graph.primaryFather(of: child), graph.primaryMother(of: child)].compactMap({ $0 })
                where !seen.contains(parent.id) {
                    seen.insert(parent.id)
                    reachedThrough[parent.id] = child.id
                    next.append(parent)
                    let place = classify(parent)
                    if place != nil { anyPlace = true }
                    if match == nil, satisfies(stop, place) { match = parent }
                }
            }
            if next.isEmpty { ending = .top; break }
            generation += 1
            frontier = next
            lastFrontier = next
            if match != nil { ending = .stopped; break }
            unknownRun = anyPlace ? 0 : unknownRun + 1
            if unknownRun >= unknownRunLimit { ending = .ranOut; break }
            if generation == limit { ending = .generationCap }
        }

        // The path: anchor first, then each generation up to the match.
        var chain: [GedcomFamilyGraph.Person] = []
        if let match {
            var cursor: GedcomFamilyGraph.Person? = match
            while let p = cursor {
                chain.append(p)
                cursor = reachedThrough[p.id].flatMap { graph.people[$0] }
            }
            chain.reverse()
        } else {
            chain = [anchor]
        }
        let steps = chain.enumerated().map { g, p in
            Step(generation: g, person: p, birthplace: classify(p), matchesStop: match?.id == p.id)
        }
        return Result(line: .allAncestors, stop: stop, steps: steps, ending: ending,
                      generationsWalked: generation, lastGeneration: lastFrontier)
    }
}
