// GedcomFamilyGraph+CommonAncestry.swift
// "How are Rick and Donna related by blood?" told the way a family reads it
// (Rick, 2026-09-18 — "people in our family will like these kinds of
// queries … the info must be taken with a grain of salt").
//
// `commonAncestors` lists EVERY shared ancestor: 6,409 for Rick and Donna,
// nearest first, one person at a time — so the answer named Martha Lamson
// alone and put her own husband under "also shared", and the only count it
// had was the raw 6,409. A family wants three different things:
//   • the nearest shared COUPLE (Matthew Rice and Martha Lamson),
//   • how many separate lines connect the two families (a shared ancestor
//     whose child is also shared is the same line, one generation further
//     up — only the lowest meeting points count),
//   • what to take with a grain of salt on the nearest lines: people with
//     no recorded birth date, and people the tree gives more than one set
//     of parents.
//
// Pure; no I/O. Cost: the two AncestorIndex walks plus one pass over the
// ordinals — the same order as `commonAncestors`.

import Foundation

extension GedcomFamilyGraph {

    /// One place where the two family lines meet: a couple (or a single
    /// person when the tree records no partner there), with the lines
    /// down to both people.
    public struct AncestralMeeting: Sendable, Equatable {
        /// One person, or a couple — husband first, then wife.
        public let ancestors: [Person]
        /// Generations above the first person (1 = parent).
        public let depthA: Int
        public let depthB: Int
        /// `[ancestor, …, parent, a]` and `[ancestor, …, parent, b]`,
        /// starting from `ancestors[0]`.
        public let pathA: [Person]
        public let pathB: [Person]

        public var kinshipTerm: String { GedcomFamilyGraph.kinshipTerm(depthA: depthA, depthB: depthB) }
    }

    public struct CommonAncestry: Sendable, Equatable {
        /// Every recorded ancestor the two share (what `commonAncestors`
        /// lists) — including the parents of every meeting couple.
        public let sharedAncestorCount: Int
        /// The lowest meeting points, one per separate line, nearest first.
        public let meetings: [AncestralMeeting]
        /// People on the nearest meeting's two lines (not the two asked
        /// about) with no recorded birth date, in line order.
        public let undatedLinks: [Person]
        /// People on the nearest meeting's two lines whose record carries
        /// more than one parent family — the tree is unsure who their
        /// parents were.
        public let disputedParentLinks: [Person]

        public var nearest: AncestralMeeting? { meetings.first }
    }

    /// The blood connection between two people, grouped for telling.
    /// Nil when either id is unknown, they are the same person, or they
    /// share no recorded ancestor. Ordering of meetings matches
    /// `commonAncestors`: smallest depthA + depthB, then depthA, then name,
    /// then pointer of the couple's first person.
    public func commonAncestry(of a: String, and b: String) -> CommonAncestry? {
        guard a != b, people[a] != nil, people[b] != nil else { return nil }
        let indexA = AncestorIndex(graph: self, descendantID: a)
        let indexB = AncestorIndex(graph: self, descendantID: b)
        let index = self.index
        let count = index.count

        var shared = [Bool](repeating: false, count: count)
        var sharedCount = 0
        for o in 0..<Int32(count) where indexA.depth(ofOrdinal: o) != nil && indexB.depth(ofOrdinal: o) != nil {
            shared[Int(o)] = true
            sharedCount += 1
        }
        guard sharedCount > 0 else { return nil }

        // Lowest = shared, and no child of theirs is shared: everyone above
        // a lowest point is the same line, further up.
        var lowest: [(o: Int32, dA: Int, dB: Int)] = []
        var isLowest = [Bool](repeating: false, count: count)
        for o in 0..<Int32(count) where shared[Int(o)] {
            if index.children(of: o).contains(where: { shared[Int($0)] }) { continue }
            guard let dA = indexA.depth(ofOrdinal: o), let dB = indexB.depth(ofOrdinal: o) else { continue }
            isLowest[Int(o)] = true
            lowest.append((o, dA, dB))
        }
        func name(_ o: Int32) -> String { people[index.ids[Int(o)]]?.name ?? "" }
        lowest.sort { x, y in
            if x.dA + x.dB != y.dA + y.dB { return x.dA + x.dB < y.dA + y.dB }
            if x.dA != y.dA { return x.dA < y.dA }
            let nx = name(x.o), ny = name(y.o)
            return nx == ny ? index.ids[Int(x.o)] < index.ids[Int(y.o)] : nx < ny
        }

        // Pair each lowest point with a spouse who is a lowest point at the
        // same two depths — the couple both lines descend from.
        var grouped = [Bool](repeating: false, count: count)
        var meetings: [AncestralMeeting] = []
        for hit in lowest where !grouped[Int(hit.o)] {
            grouped[Int(hit.o)] = true
            var members = [hit.o]
            if let partner = index.spouses(of: hit.o).sorted().first(where: {
                isLowest[Int($0)] && !grouped[Int($0)]
                    && indexA.depth(ofOrdinal: $0) == hit.dA && indexB.depth(ofOrdinal: $0) == hit.dB
            }) {
                grouped[Int(partner)] = true
                members.append(partner)
            }
            // Explicit comparison keeps the Swift 6.2 constraint solver from
            // timing out on nested ternaries inside an inferred tuple sort.
            let persons: [Person] = members.compactMap { people[index.ids[Int($0)]] }
                .sorted { left, right in
                    let leftRank: Int = left.sex == "M" ? 0 : (left.sex == "F" ? 1 : 2)
                    let rightRank: Int = right.sex == "M" ? 0 : (right.sex == "F" ? 1 : 2)
                    if leftRank != rightRank { return leftRank < rightRank }
                    if left.name != right.name { return left.name < right.name }
                    return left.id < right.id
                }
            guard let first = persons.first, let o = index.ordinal(of: first.id),
                  let pathA = indexA.path(fromOrdinal: o),
                  let pathB = indexB.path(fromOrdinal: o) else { continue }
            meetings.append(AncestralMeeting(ancestors: persons, depthA: hit.dA, depthB: hit.dB,
                                             pathA: pathA, pathB: pathB))
        }
        guard let nearest = meetings.first else { return nil }

        // Grain of salt: the links between the meeting couple and the two
        // people asked about (both ends excluded — they are not in doubt
        // here), each person once.
        var seen = Set<String>()
        var links: [Person] = []
        for person in nearest.pathA.dropLast() + nearest.pathB.dropLast()
            where !nearest.ancestors.contains(where: { $0.id == person.id }) && seen.insert(person.id).inserted {
            links.append(person)
        }
        let undated = links.filter { ($0.birthDate ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        let disputed = links.filter { Set($0.childOfFamilies).count > 1 }
        return CommonAncestry(sharedAncestorCount: sharedCount, meetings: meetings,
                              undatedLinks: undated, disputedParentLinks: disputed)
    }
}
