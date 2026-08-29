// GedcomFamilyGraph+Descent.swift
// "When the tree goes way back, show a direct line to Rick or Donna"
// (Rick 2026-08-26). One ancestor → one descendant, as the chain of
// people you would trace with a finger, plus the word for it
// ("your great-great-grandmother").
//
// Built only from the FAMC → parent links the GEDCOM records. Pedigree
// collapse (cousins marrying) means an ancestor can be reached by more
// than one path; the SHORTEST is returned, ties broken paternal-first,
// because the search is a breadth-first walk that visits the father
// before the mother at every step. Pure functions, no I/O.
//
// Two entry points, sharing the compiled parent topology:
//   • `AncestorIndex(graph:descendantID:)` walks UP from one descendant
//     once (O(their ancestors)) and then answers "path from X down to
//     me?" in O(path length). The Family Tree model builds one per anchor
//     at install so every selection change is a handful of dictionary
//     hops — the 5,000-person pedigree sensor stays at ~0.2 s.
//   • `descentPath(from:to:)` walks only until its requested ancestor is
//     found, for one-off callers (Hallie) and tests. It keeps predecessor
//     ordinals in a dense array rather than building the full String-keyed
//     index. Initializing that array is O(all indexed people); the BFS after
//     that visits only the ancestry needed to find (or rule out) the target.

import Foundation

extension GedcomFamilyGraph {

    /// Every recorded ancestor of one descendant, each with the child
    /// through which they were first (= shortest, paternal-first) reached.
    ///
    /// Ordinal-dense (2026-08-29): two `Int32` arrays over the compiled
    /// index — `childToward[o]` and `depth[o]` (−1 = not an ancestor) —
    /// so building one is a BFS over the CSR parent lists with NO string
    /// hashing, and intersecting two is a linear pass over integers.
    /// Memory: 8 bytes × people (~300 KB for the 39k merged tree).
    public struct AncestorIndex: Sendable {
        public let descendantID: String
        private let index: TreeIndex
        private let people: [String: Person]
        private let descendant: Int32
        /// ordinal → the child on the shortest line down to `descendantID`; −1 = not an ancestor.
        private let childToward: [Int32]
        /// ordinal → generations above the descendant (1 = parent); −1 = not an ancestor.
        private let depth: [Int32]
        /// Ancestors in discovery (BFS) order — the walk's own order, so
        /// callers that iterate get a deterministic sequence.
        private let ancestors: [Int32]

        public init(graph: GedcomFamilyGraph, descendantID: String) {
            self.descendantID = descendantID
            self.people = graph.people
            let index = graph.index
            self.index = index
            var childToward = [Int32](repeating: -1, count: index.count)
            var depth = [Int32](repeating: -1, count: index.count)
            var ancestors: [Int32] = []
            guard graph.people[descendantID] != nil, let start = index.ordinal(of: descendantID) else {
                self.descendant = -1
                self.childToward = childToward
                self.depth = depth
                self.ancestors = ancestors
                return
            }
            self.descendant = start
            // Plain BFS with a predecessor array (C++: queue +
            // vector<int32_t>). Father first then mother per person — see
            // TreeIndex.parents — so ties break paternal-first; FIFO order
            // keeps the shortest path. The descendant is marked visited
            // by its own depth so a corrupt self-ancestor loop stops.
            var visited = [Bool](repeating: false, count: index.count)
            visited[Int(start)] = true
            var queue: [Int32] = [start]
            var head = 0
            var levelEnd = 1
            var level: Int32 = 0
            while head < queue.count {
                if head == levelEnd { level += 1; levelEnd = queue.count }
                if head == 0 { level = 1 }
                let child = queue[head]
                head += 1
                for parent in index.parents(of: child) where !visited[Int(parent)] {
                    visited[Int(parent)] = true
                    childToward[Int(parent)] = child
                    depth[Int(parent)] = level
                    ancestors.append(parent)
                    queue.append(parent)
                }
            }
            self.childToward = childToward
            self.depth = depth
            self.ancestors = ancestors
        }

        /// Every recorded ancestor with its generation count (1 = parent),
        /// keyed by GEDCOM pointer. Materialized on demand (the walk itself
        /// keeps ordinals); the common-ancestor search uses `depth(of:)`.
        public var depths: [String: Int] {
            var out: [String: Int] = [:]
            out.reserveCapacity(ancestors.count)
            for o in ancestors { out[index.ids[Int(o)]] = Int(depth[Int(o)]) }
            return out
        }

        /// Number of recorded ancestors.
        public var ancestorCount: Int { ancestors.count }

        /// Deepest generation reached (0 = no parents attached).
        public var maxDepth: Int { ancestors.isEmpty ? 0 : Int(depth[Int(ancestors.last!)]) }

        /// Generations above the descendant for an ORDINAL, or nil.
        @inlinable public func depth(ofOrdinal o: Int32) -> Int? {
            let d = depthValue(o)
            return d < 0 ? nil : Int(d)
        }
        @usableFromInline func depthValue(_ o: Int32) -> Int32 { o == descendant ? -1 : depth[Int(o)] }

        /// Generations between the ancestor and the descendant (1 = parent),
        /// or nil when `ancestorID` is not on any recorded line above.
        /// O(log people): one binary search on the id table.
        public func generations(from ancestorID: String) -> Int? {
            guard ancestorID != descendantID, let o = index.ordinal(of: ancestorID) else { return nil }
            return depth(ofOrdinal: o)
        }

        /// `[ancestor, …, parent, descendant]`, or nil when not an ancestor.
        public func path(from ancestorID: String) -> [Person]? {
            guard ancestorID != descendantID, let o = index.ordinal(of: ancestorID) else { return nil }
            return path(fromOrdinal: o)
        }

        /// Same, by ordinal.
        public func path(fromOrdinal o: Int32) -> [Person]? {
            guard o != descendant, depth[Int(o)] >= 0 else { return nil }
            var path: [Person] = []
            var current = o
            while true {
                guard let person = people[index.ids[Int(current)]] else { return nil }
                path.append(person)
                if current == descendant { return path }
                let child = childToward[Int(current)]
                guard child >= 0 else { return nil }
                current = child
            }
        }
    }

    /// The people from `ancestorID` DOWN to `descendantID`, inclusive
    /// (`[ancestor, …, parent, descendant]`). Nil when either id is
    /// unknown, when they are the same person, or when the ancestor is
    /// not on any recorded parent line above the descendant.
    ///
    /// Cost: O(all indexed people + visited ancestors + returned path): the
    /// dense predecessor vector is initialized for every indexed person,
    /// then the BFS stops as soon as `ancestorID` is found. Build an
    /// `AncestorIndex` yourself for repeated queries to one descendant.
    public func descentPath(from ancestorID: String, to descendantID: String) -> [Person]? {
        guard ancestorID != descendantID else { return nil }
        let index = self.index
        guard let ancestor = index.ordinal(of: ancestorID),
              let descendant = index.ordinal(of: descendantID) else { return nil }

        // One-off BFS. `childToward[parent] = child` is the ordinal version
        // of AncestorIndex's predecessor map (C++: vector<int32_t>). Parent
        // slices are father-first, and FIFO traversal preserves that tie
        // break while still choosing the shortest path.
        let unseen: Int32 = -1
        var childToward = [Int32](repeating: unseen, count: index.count)
        childToward[Int(descendant)] = descendant
        var queue: [Int32] = [descendant]
        queue.reserveCapacity(min(index.count, 256))
        var head = 0

        while head < queue.count && childToward[Int(ancestor)] == unseen {
            let child = queue[head]
            head += 1
            for parent in index.parents(of: child) where childToward[Int(parent)] == unseen {
                childToward[Int(parent)] = child
                queue.append(parent)
                if parent == ancestor { break }
            }
        }
        guard childToward[Int(ancestor)] != unseen else { return nil }

        var path: [Person] = []
        var current = ancestor
        while true {
            guard let person = people[index.ids[Int(current)]] else { return nil }
            path.append(person)
            if current == descendant { return path }
            let child = childToward[Int(current)]
            guard child != unseen else { return nil }
            current = child
        }
    }

    /// "your great-great-grandmother" / "Donna's 3rd-great-grandfather".
    /// Nil when there is no recorded line. `possessive` is the word before
    /// the relation ("your", "Donna's").
    public func relationshipLabel(from ancestorID: String, to descendantID: String,
                                  possessive: String = "your") -> String? {
        guard let path = descentPath(from: ancestorID, to: descendantID),
              let ancestor = path.first else { return nil }
        return possessive + " " + Self.generationLabel(generations: path.count - 1, sex: ancestor.sex)
    }

    /// The kinship word for an ancestor `generations` above someone:
    /// 1 parent, 2 grandparent, 3 great-grandparent, 4 great-great-
    /// grandparent, then "3rd-great-grandparent" and up (5 generations =
    /// 3rd-great). Sex picks father/mother; unknown sex says "parent".
    public static func generationLabel(generations: Int, sex: String) -> String {
        let base: String
        switch sex.uppercased() {
        case "M": base = generations == 1 ? "father" : "grandfather"
        case "F": base = generations == 1 ? "mother" : "grandmother"
        default:  base = generations == 1 ? "parent" : "grandparent"
        }
        switch generations {
        case ...2: return base
        case 3: return "great-" + base
        case 4: return "great-great-" + base
        default: return numericOrdinal(generations - 2) + "-great-" + base
        }
    }

    /// 1st, 2nd, 3rd, 4th … 11th, 12th, 13th … 21st.
    public static func numericOrdinal(_ n: Int) -> String {
        let tens = n % 100
        if (11...13).contains(tens) { return "\(n)th" }
        switch n % 10 {
        case 1: return "\(n)st"
        case 2: return "\(n)nd"
        case 3: return "\(n)rd"
        default: return "\(n)th"
        }
    }
}
