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
// Two entry points, one algorithm:
//   • `AncestorIndex(graph:descendantID:)` walks UP from one descendant
//     once (O(their ancestors)) and then answers "path from X down to
//     me?" in O(path length). The Family Tree model builds one per anchor
//     at install so every selection change is a handful of dictionary
//     hops — the 5,000-person pedigree sensor stays at ~0.2 s.
//   • `descentPath(from:to:)` = build + one query, for one-off callers
//     (Hallie) and the tests that pin the behaviour.

import Foundation

extension GedcomFamilyGraph {

    /// Every recorded ancestor of one descendant, each with the child
    /// through which they were first (= shortest, paternal-first) reached.
    ///
    /// Memory: one String pair per ancestor — a few hundred KB for the
    /// deepest tree in the archive.
    public struct AncestorIndex: Sendable {
        public let descendantID: String
        /// ancestor id → the child on the shortest line down to `descendantID`.
        private let childToward: [String: String]
        /// ancestor id → generations above the descendant (1 = parent).
        private let depthByID: [String: Int]
        private let people: [String: Person]

        public init(graph: GedcomFamilyGraph, descendantID: String) {
            self.descendantID = descendantID
            self.people = graph.people
            var cameFrom: [String: String] = [:]
            var depth: [String: Int] = [:]
            guard let start = graph.people[descendantID] else {
                childToward = [:]
                depthByID = [:]
                return
            }
            // `cameFrom[parent] = child` — plain BFS with a predecessor map
            // (C++: queue + unordered_map<string,string>).
            var visited: Set<String> = [descendantID]
            var frontier: [Person] = [start]
            var level = 0
            while !frontier.isEmpty {
                var next: [Person] = []
                level += 1
                for child in frontier {
                    // Father first, then mother: paternal-first tie-break.
                    for parent in graph.relatives(.father, of: child) + graph.relatives(.mother, of: child)
                    where visited.insert(parent.id).inserted {
                        cameFrom[parent.id] = child.id
                        depth[parent.id] = level
                        next.append(parent)
                    }
                }
                frontier = next
            }
            childToward = cameFrom
            depthByID = depth
        }

        /// Every recorded ancestor with its generation count (1 = parent).
        /// The common-ancestor search intersects two of these.
        public var depths: [String: Int] { depthByID }

        /// Generations between the ancestor and the descendant (1 = parent),
        /// or nil when `ancestorID` is not on any recorded line above.
        /// O(1): recorded during the walk.
        public func generations(from ancestorID: String) -> Int? {
            ancestorID == descendantID ? nil : depthByID[ancestorID]
        }

        /// `[ancestor, …, parent, descendant]`, or nil when not an ancestor.
        public func path(from ancestorID: String) -> [Person]? {
            guard ancestorID != descendantID, childToward[ancestorID] != nil else { return nil }
            var path: [Person] = []
            var current: String? = ancestorID
            while let id = current, let person = people[id] {
                path.append(person)
                current = id == descendantID ? nil : childToward[id]
            }
            return path.last?.id == descendantID ? path : nil
        }
    }

    /// The people from `ancestorID` DOWN to `descendantID`, inclusive
    /// (`[ancestor, …, parent, descendant]`). Nil when either id is
    /// unknown, when they are the same person, or when the ancestor is
    /// not on any recorded parent line above the descendant.
    ///
    /// Cost: O(ancestors of the descendant) — build an `AncestorIndex`
    /// yourself when you will ask about the same descendant repeatedly.
    public func descentPath(from ancestorID: String, to descendantID: String) -> [Person]? {
        guard people[ancestorID] != nil, people[descendantID] != nil else { return nil }
        return AncestorIndex(graph: self, descendantID: descendantID).path(from: ancestorID)
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
