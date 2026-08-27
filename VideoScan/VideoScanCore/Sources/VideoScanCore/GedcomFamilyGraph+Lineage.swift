// GedcomFamilyGraph+Lineage.swift
// Multi-generation walks over the family graph (2026-08-22, Rick: "show
// Rick's maternal line back 5 generations", "the family tree for the
// Latta family", "trace the family back to Ireland").
//
// Everything here is built ONLY from the single-hop relations the graph
// already records. A walk stops the moment the GEDCOM stops — a missing
// parent is reported as a gap, never filled in. Pure functions; no I/O.

import Foundation

extension GedcomFamilyGraph {

    /// Which parent(s) an ancestor walk follows.
    public enum Line: String, Sendable, Equatable {
        /// Mother, her mother, … (the matrilineal line).
        case maternal
        /// Father, his father, … (the patrilineal line).
        case paternal
        /// Every ancestor: both parents at each step (a pedigree).
        case both
    }

    /// One generation of an ancestor walk. `generation` 1 = parents.
    public struct AncestorGeneration: Sendable, Equatable {
        public let generation: Int
        public let people: [Person]
    }

    /// Walk UP from `person` for at most `generations` steps. The result
    /// lists the generations actually found — fewer than asked for when
    /// the tree runs out, which the caller must say out loud.
    ///
    /// `untilYear` ("… back to 1600", 2026-08-26) is a stop: an ancestor
    /// is kept when born in or after that year, or when their birth year
    /// is unknown but the child they were reached through was born in or
    /// after it. Nobody past the bound is walked through, so the line
    /// ends at the year rather than where the tree ends.
    public func ancestorLine(of person: Person,
                             line: Line,
                             generations: Int,
                             untilYear: Int? = nil) -> [AncestorGeneration] {
        guard generations > 0 else { return [] }
        var out: [AncestorGeneration] = []
        var frontier = [person]
        var seen: Set<String> = [person.id]
        for g in 1...generations {
            var next: [Person] = []
            for p in frontier {
                let parents: [Person]
                switch line {
                case .maternal: parents = relatives(.mother, of: p)
                case .paternal: parents = relatives(.father, of: p)
                case .both:     parents = relatives(.parents, of: p)
                }
                for parent in parents where !seen.contains(parent.id) {
                    if let untilYear, !Self.withinBound(parent, child: p, year: untilYear) { continue }
                    seen.insert(parent.id)
                    next.append(parent)
                }
            }
            if next.isEmpty { break }
            out.append(AncestorGeneration(generation: g, people: next))
            frontier = next
        }
        return out
    }

    /// The `untilYear` rule, in one place so the prose can quote it.
    public static func withinBound(_ parent: Person, child: Person, year: Int) -> Bool {
        if let born = parent.birthYear { return born >= year }
        if let childBorn = child.birthYear { return childBorn >= year }
        return false
    }

    /// What a year-bounded walk could and could not PROVE (codex #707
    /// major 7): "I stopped at 1600" is only true when a parent DATED
    /// before the bound was left unwalked. Parents skipped because neither
    /// they nor their child carries a birth year are a date gap — the line
    /// may reach further, and the prose must say so instead of asserting
    /// the bound was reached.
    public struct YearBoundGap: Sendable, Equatable {
        /// Unwalked parents born BEFORE the bound — proof the tree goes on.
        public let provenBeyond: [Person]
        /// Unwalked parents with no birth year (their child is undated too).
        public let undatedUnwalked: [Person]
        /// Walked ancestors with an undated parent left unwalked — where
        /// the dates run out.
        public let undatedFrontier: [Person]
        /// Walked ancestors with no birth year (kept under a dated child).
        public let undatedWalked: [Person]

        public var hasDateGap: Bool { !undatedUnwalked.isEmpty }
    }

    public func yearBoundGap(of person: Person,
                             generations: [AncestorGeneration],
                             untilYear: Int) -> YearBoundGap {
        let walked = generations.flatMap(\.people)
        let walkedIDs = Set(walked.map(\.id))
        var proven: [Person] = []
        var undated: [Person] = []
        var frontier: [Person] = []
        var seen: Set<String> = []
        for p in (generations.isEmpty ? [person] : walked) {
            var gapHere = false
            for parent in relatives(.parents, of: p) where !walkedIDs.contains(parent.id) {
                guard seen.insert(parent.id).inserted else { continue }
                if let born = parent.birthYear {
                    if born < untilYear { proven.append(parent) }
                } else {
                    undated.append(parent)
                    gapHere = true
                }
            }
            if gapHere { frontier.append(p) }
        }
        return YearBoundGap(provenBeyond: proven, undatedUnwalked: undated,
                            undatedFrontier: frontier,
                            undatedWalked: walked.filter { $0.birthYear == nil })
    }

    /// The pedigree generations PRUNED to the people who lie on a path
    /// from `person` up to any of `targets` — the chain you would trace
    /// with a finger, not the whole fan. Generations with nobody on a
    /// path are dropped. Used for "trace the family back to Ireland" so
    /// the card shows ~a dozen people instead of a hundred.
    public func ancestorPaths(from person: Person,
                              to targets: [Person],
                              maxGenerations: Int = 12) -> [AncestorGeneration] {
        let full = ancestorLine(of: person, line: .both, generations: maxGenerations)
        guard !full.isEmpty, !targets.isEmpty else { return [] }
        let targetIDs = Set(targets.map(\.id))
        // Pass 1, nearest generation first: a person is a candidate when
        // they are a target or a parent of a candidate one generation
        // nearer (so the chain is connected to the root).
        var candidates: [Int: Set<String>] = [:]
        var nearer: Set<String> = [person.id]
        for gen in full {
            let keep = gen.people.filter { p in
                targetIDs.contains(p.id)
                    || relatives(.children, of: p).contains { nearer.contains($0.id) }
            }
            nearer = Set(keep.map(\.id))
            candidates[gen.generation] = nearer
            if nearer.isEmpty { break }
        }
        // Pass 2, farthest generation first: drop candidates whose line
        // dead-ends without reaching a target (a parent kept only because
        // they are *some* ancestor, not one on the way to a target).
        var kept: [AncestorGeneration] = []
        var above: Set<String> = []
        for gen in full.reversed() {
            guard let ids = candidates[gen.generation] else { continue }
            let stay = gen.people.filter { p in
                ids.contains(p.id)
                    && (targetIDs.contains(p.id)
                        || relatives(.parents, of: p).contains { above.contains($0.id) })
            }
            above = Set(stay.map(\.id))
            if !stay.isEmpty { kept.append(AncestorGeneration(generation: gen.generation, people: stay)) }
        }
        return kept.reversed()
    }

    /// One node of a descendant outline: the person, their recorded
    /// spouses, and their children (already expanded to `depth`).
    public struct DescendantNode: Sendable, Equatable {
        public let person: Person
        public let spouses: [Person]
        public let children: [DescendantNode]

        /// Every person in this subtree (root first, depth-first).
        public var allPeople: [Person] {
            [person] + children.flatMap(\.allPeople)
        }
    }

    /// Walk DOWN from `person` for at most `depth` generations of
    /// children. `depth` 0 = just the root and their spouses.
    public func descendants(of person: Person, depth: Int) -> DescendantNode {
        var seen: Set<String> = []
        return descend(person, depth: max(0, depth), seen: &seen)
    }

    private func descend(_ person: Person, depth: Int, seen: inout Set<String>) -> DescendantNode {
        seen.insert(person.id)
        let spouses = relatives(.spouse, of: person)
        guard depth > 0 else { return DescendantNode(person: person, spouses: spouses, children: []) }
        var kids: [DescendantNode] = []
        for child in relatives(.children, of: person) where !seen.contains(child.id) {
            kids.append(descend(child, depth: depth - 1, seen: &seen))
        }
        return DescendantNode(person: person, spouses: spouses, children: kids)
    }

    /// The earliest recorded people of a surname: everyone who carries the
    /// surname and has NO recorded parent in the tree. These are the
    /// natural roots for "the family tree for the Latta family". Sorted
    /// by birth year (unknown years last), then name, so the output is
    /// stable.
    public func rootAncestors(surname: String) -> [Person] {
        people(withSurname: surname)
            .filter { relatives(.parents, of: $0).isEmpty }
            .sorted { a, b in
                switch (a.birthYear, b.birthYear) {
                case let (x?, y?) where x != y: return x < y
                case (nil, .some): return false
                case (.some, nil): return true
                default: return a.name < b.name
                }
            }
    }

    /// One stop on an origin trail: an ancestor and their recorded birth
    /// place. A death place is not evidence that the person came from there.
    public struct OriginStop: Sendable, Equatable {
        public let generation: Int
        public let person: Person
        public let place: String
    }

    /// Walk every ancestor line up from `person` and collect the people
    /// whose record names a place. `country` (optional, e.g. "Ireland")
    /// keeps only stops whose place ends in — or contains — that country.
    /// Generation order, so the first match is the nearest ancestor born
    /// there. Deliberately does not infer a country from a town name.
    public func originTrail(of person: Person,
                            country: String? = nil,
                            line: Line = .both,
                            maxGenerations: Int = 12) -> [OriginStop] {
        let wanted = country.map { Self.normalizedPlaceToken($0) }
        var out: [OriginStop] = []
        for gen in ancestorLine(of: person, line: line, generations: maxGenerations) {
            for p in gen.people {
                guard let place = p.birthPlace else { continue }
                if let wanted, !Self.place(place, mentions: wanted) { continue }
                out.append(OriginStop(generation: gen.generation, person: p, place: place))
            }
        }
        return out
    }

    /// Country/region words a place string may end with. Matching is on
    /// whole comma-separated components so "Cork, Ireland" matches
    /// "Ireland" and "New England, USA" does not.
    public static func place(_ place: String, mentions token: String) -> Bool {
        let components = place.split(separator: ",").map { normalizedPlaceToken(String($0)) }
        if components.contains(token) { return true }
        // Multi-word asks match loosely: "old puritan boston" reaches the
        // "Boston" component; whole-word only, so "england" still cannot
        // reach "New England" (that guard is the single-word rule above).
        let words = token.split(separator: " ").map(String.init)
        guard words.count > 1 else { return false }
        return components.contains { component in
            words.contains { $0.count >= 3 && component == $0 }
        }
    }

    public static func normalizedPlaceToken(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    /// "Ireland" / "England" / … as people say them, with the spellings
    /// a GEDCOM is likely to carry. Used by the question parser to spot a
    /// "trace back to X" ask; the trail itself matches whatever word was
    /// asked for, so an unlisted country still works.
    public static let knownCountries: [String] = [
        "Ireland", "England", "Scotland", "Wales", "Germany", "Italy", "France",
        "Poland", "Canada", "Sweden", "Norway", "Netherlands", "Portugal", "Spain",
        "Hungary", "Austria", "Russia", "Lithuania", "Greece", "Nova Scotia",
    ]
}
