// GedcomRelationshipPath.swift (VideoScanCore)
// "How is A related to B?" — the SYMMETRIC question the one-directional
// kinship resolver cannot answer.
//
// Rick (Hallie log 2026-08-18): the softball "how am I related to you?"
// failed twice. The translator produced `{"people":["you"],"operation":
// "kinship","relation":"sel…"}` because the closed kinship vocabulary is
// person + relation → people; there was no "what is the relationship
// between A and B" operation. This file supplies the pure graph half:
// shortest path over parent/child/spouse edges (BFS, depth-capped) plus a
// deterministic English description of the shape ("great-grandmother —
// your father's mother's mother"). No LLM anywhere near it: the family
// fact is computed from the GEDCOM and rendered by Swift.
//
// Privacy: no real family data here; tests use a synthetic tree.

import Foundation

extension GedcomFamilyGraph {

    /// One edge type in the family graph. `parent` climbs a generation,
    /// `child` descends one, `spouse` stays level (an affinal hop).
    public enum KinEdge: String, Sendable, Equatable {
        case parent, child, spouse
    }

    /// One step along a relationship path: the edge taken and the person
    /// reached. `noun` is the sex-aware word for the person reached along
    /// that edge ("father", "daughter", "wife", …) so a spoken route can be
    /// composed by joining nouns with "'s".
    public struct KinStep: Sendable, Equatable {
        public let edge: KinEdge
        public let person: Person

        public init(edge: KinEdge, person: Person) {
            self.edge = edge
            self.person = person
        }

        public var noun: String {
            switch (edge, person.sex) {
            case (.parent, "M"): return "father"
            case (.parent, "F"): return "mother"
            case (.parent, _): return "parent"
            case (.child, "M"): return "son"
            case (.child, "F"): return "daughter"
            case (.child, _): return "child"
            case (.spouse, "M"): return "husband"
            case (.spouse, "F"): return "wife"
            case (.spouse, _): return "spouse"
            }
        }
    }

    /// A complete shortest route from `from` to `to`. `steps.last?.person`
    /// is `to` (the path is never empty — same-person questions are refused
    /// before search).
    public struct KinPath: Sendable, Equatable {
        public let from: Person
        public let steps: [KinStep]

        public init(from: Person, steps: [KinStep]) {
            self.from = from
            self.steps = steps
        }

        public var to: Person { steps.last?.person ?? from }
        public var hopCount: Int { steps.count }

        /// The spoken route from `from`'s point of view, without the leading
        /// possessive: "father's mother's mother". The caller supplies "your"
        /// / "my" / "Donna's" because only it knows who is speaking.
        public var route: String {
            steps.map(\.noun).joined(separator: "'s ")
        }

        /// Audit form with GEDCOM ids so a wrong tree link is visible:
        /// "Rick Breen (@I1@) → father Al Breen (@I2@) → mother …".
        public var auditTrail: String {
            ([from.name + " (" + from.id + ")"]
             + steps.map { "\($0.noun) \($0.person.name) (\($0.person.id))" })
                .joined(separator: " → ")
        }
    }

    /// The English shape of a path. `relation` is what `to` is to `from`
    /// ("great-grandmother", "first cousin once removed", "brother-in-law");
    /// nil when the shape is not one the vocabulary names, in which case the
    /// caller falls back to "related through <route>".
    public struct KinDescription: Sendable, Equatable {
        public let relation: String?
        public let route: String

        public init(relation: String?, route: String) {
            self.relation = relation
            self.route = route
        }
    }

    /// Family trees are shallow but wide; twelve hops reaches a fifth cousin
    /// (2×6). Beyond that "related through …" would be a paragraph nobody
    /// reads, and the search stays bounded on a 10k-person GEDCOM.
    public static let relationshipSearchDepthLimit = 12

    /// Shortest path from `from` to `to` over parent/child/spouse edges, or
    /// nil when none exists within `maxDepth` hops (or the two are the same
    /// person). Breadth-first, so the first path found is a shortest one;
    /// neighbours are enumerated parents → children → spouses, ids sorted,
    /// so ties resolve the same way every run (blood before marriage).
    ///
    /// Memory: O(people) for the visited map — every person appears at most
    /// once. Worst case on a 10k-person tree ≈ a few hundred KB.
    public func relationshipPath(
        from: Person,
        to: Person,
        maxDepth: Int = GedcomFamilyGraph.relationshipSearchDepthLimit
    ) -> KinPath? {
        guard from.id != to.id, maxDepth > 0 else { return nil }
        // Predecessor map: person id → how we got there. The root has no
        // link. Swift dictionary here ≈ std::unordered_map. (Note: a
        // dictionary of Optional values would DROP a key on `= nil`, so the
        // root is stored as a link with nil fields, not as nil.)
        var previous: [String: Link] = [from.id: Link(previousID: nil, edge: nil)]
        var frontier = [from.id]
        var depth = 0
        while !frontier.isEmpty, depth < maxDepth {
            var next: [String] = []
            for id in frontier {
                guard let person = people[id] else { continue }
                for (edge, neighbour) in neighbours(of: person) {
                    guard previous[neighbour.id] == nil else { continue }
                    previous[neighbour.id] = Link(previousID: id, edge: edge)
                    if neighbour.id == to.id {
                        return unwind(previous, from: from, to: to)
                    }
                    next.append(neighbour.id)
                }
            }
            frontier = next
            depth += 1
        }
        return nil
    }

    /// Name the shape of a path. Recognised shapes: direct ancestor /
    /// descendant with generation count, sibling, aunt/uncle and
    /// niece/nephew (with "great-" prefixes), cousins with degree and
    /// removal, spouse, and one affinal hop at either end (in-laws, step-).
    /// Anything else returns `relation == nil` and the caller says "related
    /// through …" with the route — never a guessed word.
    public func describe(_ path: KinPath) -> KinDescription {
        let route = path.route
        let steps = path.steps
        guard !steps.isEmpty else { return KinDescription(relation: nil, route: route) }
        let sex = path.to.sex

        // Spouse only.
        if steps.count == 1, steps[0].edge == .spouse {
            return KinDescription(relation: steps[0].noun, route: route)
        }

        // Peel at most one affinal hop from each end; a spouse edge in the
        // middle of a blood run is a shape English has no single word for.
        var core = steps.map(\.edge)
        let leadingSpouse = core.first == .spouse
        if leadingSpouse { core.removeFirst() }
        let trailingSpouse = core.last == .spouse
        if trailingSpouse { core.removeLast() }
        guard !core.contains(.spouse), !core.isEmpty else {
            return KinDescription(relation: nil, route: route)
        }
        // A blood path is "up u generations, then down d": parents first,
        // then children. Down-then-up (child's other parent) or any other
        // interleaving is not a named relation.
        let up = core.prefix { $0 == .parent }.count
        let down = core.count - up
        guard core.dropFirst(up).allSatisfy({ $0 == .child }) else {
            return KinDescription(relation: nil, route: route)
        }

        let blood = Self.bloodRelation(up: up, down: down, sex: sex)
        switch (leadingSpouse, trailingSpouse) {
        case (false, false):
            return KinDescription(relation: blood, route: route)
        case (true, false):
            // B is A's spouse's <blood>: in-laws and step-children.
            return KinDescription(
                relation: Self.spouseSideRelation(up: up, down: down, sex: sex),
                route: route)
        case (false, true):
            // B is the spouse of A's <blood>.
            return KinDescription(
                relation: Self.marriedInRelation(up: up, down: down, sex: sex),
                route: route)
        case (true, true):
            return KinDescription(relation: nil, route: route)
        }
    }

    // MARK: - Private

    private func neighbours(of person: Person) -> [(KinEdge, Person)] {
        var out: [(KinEdge, Person)] = []
        for parent in relatives(.parents, of: person).sorted(by: { $0.id < $1.id }) {
            out.append((.parent, parent))
        }
        for child in relatives(.children, of: person).sorted(by: { $0.id < $1.id }) {
            out.append((.child, child))
        }
        for spouse in relatives(.spouse, of: person).sorted(by: { $0.id < $1.id }) {
            out.append((.spouse, spouse))
        }
        return out
    }

    private struct Link {
        let previousID: String?
        let edge: KinEdge?
    }

    private func unwind(
        _ previous: [String: Link],
        from: Person,
        to: Person
    ) -> KinPath? {
        var steps: [KinStep] = []
        var cursor = to.id
        while cursor != from.id {
            guard let link = previous[cursor], let previousID = link.previousID,
                  let edge = link.edge, let person = people[cursor] else { return nil }
            steps.append(KinStep(edge: edge, person: person))
            cursor = previousID
        }
        return KinPath(from: from, steps: steps.reversed())
    }

    /// "great-" × n prefix.
    private static func greats(_ n: Int) -> String {
        String(repeating: "great-", count: max(0, n))
    }

    private static func ordinal(_ n: Int) -> String {
        switch n {
        case 1: return "first"
        case 2: return "second"
        case 3: return "third"
        case 4: return "fourth"
        case 5: return "fifth"
        case 6: return "sixth"
        default: return "\(n)th"
        }
    }

    private static func removed(_ n: Int) -> String {
        switch n {
        case 0: return ""
        case 1: return " once removed"
        case 2: return " twice removed"
        default: return " \(n) times removed"
        }
    }

    /// Word for "up u, down d" from A's point of view, sex-aware for B.
    private static func bloodRelation(up: Int, down: Int, sex: String) -> String? {
        func pick(_ m: String, _ f: String, _ n: String) -> String {
            sex == "M" ? m : sex == "F" ? f : n
        }
        switch (up, down) {
        case (0, 0):
            return nil
        case (let u, 0):
            // Direct ancestor: parent, grandparent, great-grandparent, …
            let base = pick("father", "mother", "parent")
            if u == 1 { return base }
            return greats(u - 2) + "grand" + base
        case (0, let d):
            let base = pick("son", "daughter", "child")
            if d == 1 { return base }
            return greats(d - 2) + "grand" + base
        case (1, 1):
            return pick("brother", "sister", "sibling")
        case (let u, 1) where u >= 2:
            // Parent's sibling and their ancestors' siblings.
            return greats(u - 2) + pick("uncle", "aunt", "aunt or uncle")
        case (1, let d) where d >= 2:
            return greats(d - 2) + pick("nephew", "niece", "niece or nephew")
        case (let u, let d) where u >= 2 && d >= 2:
            let degree = min(u, d) - 1
            return ordinal(degree) + " cousin" + removed(abs(u - d))
        default:
            return nil
        }
    }

    /// B reached through A's SPOUSE then blood: parent → parent-in-law,
    /// sibling → sibling-in-law, child → step-child. Others fall back.
    private static func spouseSideRelation(up: Int, down: Int, sex: String) -> String? {
        func pick(_ m: String, _ f: String, _ n: String) -> String {
            sex == "M" ? m : sex == "F" ? f : n
        }
        switch (up, down) {
        case (1, 0): return pick("father-in-law", "mother-in-law", "parent-in-law")
        case (1, 1): return pick("brother-in-law", "sister-in-law", "sibling-in-law")
        case (0, 1): return pick("stepson", "stepdaughter", "stepchild")
        case (2, 0): return pick("grandfather-in-law", "grandmother-in-law", "grandparent-in-law")
        default: return nil
        }
    }

    /// B is the SPOUSE of A's blood relative: child's spouse → child-in-law,
    /// sibling's spouse → sibling-in-law, parent's spouse → step-parent,
    /// aunt/uncle's spouse → aunt/uncle by marriage.
    private static func marriedInRelation(up: Int, down: Int, sex: String) -> String? {
        func pick(_ m: String, _ f: String, _ n: String) -> String {
            sex == "M" ? m : sex == "F" ? f : n
        }
        switch (up, down) {
        case (0, 1): return pick("son-in-law", "daughter-in-law", "child-in-law")
        case (1, 1): return pick("brother-in-law", "sister-in-law", "sibling-in-law")
        case (1, 0): return pick("stepfather", "stepmother", "stepparent")
        case (2, 1): return pick("uncle by marriage", "aunt by marriage", "aunt or uncle by marriage")
        case (0, 2): return pick("grandson-in-law", "granddaughter-in-law", "grandchild-in-law")
        default: return nil
        }
    }
}
