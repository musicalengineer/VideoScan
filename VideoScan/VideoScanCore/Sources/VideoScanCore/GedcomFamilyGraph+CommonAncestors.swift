// GedcomFamilyGraph+CommonAncestors.swift
// "How are Rick and Donna related?" (2026-08-27: Rick found a common
// ancestor by hand across the two FamilySearch pulls and wants the app
// to find it). The ancestor sets of two people, intersected, ranked by
// the sum of the two depths — nearest first — each with the two descent
// paths the tree records.
//
// Built on `AncestorIndex` (one upward BFS per person, shortest path,
// paternal-first tie-break), so the cost is O(ancestors of A + ancestors
// of B) and a 16k-person tree answers in milliseconds. Pure; no I/O.

import Foundation

extension GedcomFamilyGraph {

    public struct CommonAncestor: Sendable, Equatable {
        public let person: Person
        /// Generations above the first person (1 = parent).
        public let depthA: Int
        public let depthB: Int
        /// `[ancestor, …, parent, a]` and `[ancestor, …, parent, b]`.
        public let pathA: [Person]
        public let pathB: [Person]

        /// "8th cousins once removed" — see `kinshipTerm(depthA:depthB:)`.
        public var kinshipTerm: String { GedcomFamilyGraph.kinshipTerm(depthA: depthA, depthB: depthB) }
    }

    /// Every recorded ancestor both people share, nearest first (smallest
    /// depthA + depthB, then depthA, then name). Empty when either id is
    /// unknown, when they are the same person, or when nothing is shared.
    /// `limit` caps the list (pedigree collapse can make it long); nil =
    /// all of them.
    public func commonAncestors(of a: String, and b: String, limit: Int? = nil) -> [CommonAncestor] {
        guard a != b, people[a] != nil, people[b] != nil else { return [] }
        let indexA = AncestorIndex(graph: self, descendantID: a)
        let indexB = AncestorIndex(graph: self, descendantID: b)
        let index = self.index
        // One linear pass over ordinals (two Int32 loads each) — no
        // string hashing; the sort below fixes the order exactly as
        // before (total depth, depth above A, name, id).
        var hits: [(o: Int32, dA: Int, dB: Int)] = []
        for o in 0..<Int32(index.count) {
            guard let dA = indexA.depth(ofOrdinal: o), let dB = indexB.depth(ofOrdinal: o) else { continue }
            hits.append((o, dA, dB))
        }
        hits.sort { x, y in
            if x.dA + x.dB != y.dA + y.dB { return x.dA + x.dB < y.dA + y.dB }
            if x.dA != y.dA { return x.dA < y.dA }
            let nx = people[index.ids[Int(x.o)]]?.name ?? "", ny = people[index.ids[Int(y.o)]]?.name ?? ""
            return nx == ny ? index.ids[Int(x.o)] < index.ids[Int(y.o)] : nx < ny
        }
        let kept = limit.map { Array(hits.prefix($0)) } ?? hits
        return kept.compactMap { hit in
            guard let person = people[index.ids[Int(hit.o)]],
                  let pathA = indexA.path(fromOrdinal: hit.o),
                  let pathB = indexB.path(fromOrdinal: hit.o) else { return nil }
            return CommonAncestor(person: person, depthA: hit.dA, depthB: hit.dB,
                                  pathA: pathA, pathB: pathB)
        }
    }

    /// How many generations of ancestors the tree records above someone
    /// (0 = no parents attached). Used to say "I walked N generations".
    public func ancestorDepth(of id: String) -> Int {
        AncestorIndex(graph: self, descendantID: id).maxDepth
    }

    /// The English kinship term for two people whose nearest common
    /// ancestor sits `depthA` generations above one and `depthB` above the
    /// other (1 = parent). Standard reckoning:
    ///   depth 1/1 → siblings; 1/2 → aunt/uncle and niece/nephew (great-
    ///   for each further step); otherwise cousin degree = min − 1 and
    ///   "removed" = |depthA − depthB|: 3/4 → 2nd cousins once removed.
    public static func kinshipTerm(depthA: Int, depthB: Int) -> String {
        let lo = min(depthA, depthB), hi = max(depthA, depthB)
        guard lo >= 1 else { return "the same person or a direct ancestor" }
        let removed = hi - lo
        if lo == 1 {
            if removed == 0 { return "siblings" }
            let greats = removed - 1
            let prefix: String
            switch greats {
            case 0: prefix = ""
            case 1: prefix = "great-"
            case 2: prefix = "great-great-"
            default: prefix = numericOrdinal(greats) + "-great-"
            }
            return "\(prefix)aunt/uncle and \(prefix)niece/nephew"
        }
        let degree = lo - 1
        var term = numericOrdinal(degree) + " cousins"
        switch removed {
        case 0: break
        case 1: term += " once removed"
        case 2: term += " twice removed"
        case 3: term += " three times removed"
        default: term += " \(removed) times removed"
        }
        return term
    }
}
