// FamilyKinshipInference.swift
// Derivation engine for People-tab relationships (design:
// docs/kinship_inference_design.md §2, 2026-08-29). Rick stores only the
// four PRIMITIVES — parent, child, spouse, sibling — and everything else
// ("Tim is uncle of Matt", "Bob is Rick's brother-in-law", "Martha Lamson
// is Tim's 8th-great-grandmother") is derived here at read time from:
//
//   • the FamilyKinshipOverlay's primitive edges (profile rows + inverses,
//     profiles bridged to tree people sharing that vertex),
//   • the GEDCOM graph's parent / child / spouse links for tree vertices,
//   • one deliberate assumption (Director 2026-08-29: siblings default to
//     FULL): a person with a sibling row but NO parent rows inherits the
//     sibling's parents, flagged `.assumedFullSibling` so the review sheet
//     and Hallie can say "assumed".
//
// Two tiers per query:
//   Tier A — breadth-first search over the unified adjacency, ≤ `maxHops`
//            (4) hops, shortest chain wins; the chain is named by
//            `KinshipChainNamer` (fold table + lineal/collateral shapes).
//   Tier B — when A finds nothing and a tree is installed: climb each
//            endpoint's parent hops to its nearest tree vertices, then let
//            `GedcomFamilyGraph.AncestorIndex` find the nearest common
//            ancestor, so a 10-generation line is one query, not a
//            10-hop BFS. This is where the design's "N = 4 default" did not
//            survive contact: lineal depth is unbounded by construction.
//
// Never invented: spouse∘spouse, sibling∘sibling, parent∘spouse (step),
// spouse∘child — those fall to route text (codex #778 / #795 D), and no
// chain is named through two spouse hops except the pinned whole chain
// [spouse, sibling, spouse].
//
// Pure and injected (an overlay, itself built from snapshots + an optional
// graph). Worst-case memory: the BFS frontier is bounded by 4 hops over a
// fan-out of a few dozen (contemporaries) — kilobytes; the ancestor-index
// memo holds at most `AncestorMemo.limit` indexes (≈ 200 KB each on the
// deepest tree) and is cleared, not grown, when full.
//
// C++ readers: `struct` = value type; `final class … : @unchecked Sendable`
// with an `NSLock` is the idiom for a shared mutable cache — "I promise the
// lock makes this thread-safe" (the compiler can't prove it).

import Foundation
import VideoScanCore

struct FamilyKinshipInference: Sendable {

    typealias Node = FamilyKinshipOverlay.Node

    /// Where one hop came from, so every derived sentence can cite it.
    enum Provenance: Hashable, Sendable {
        /// A stored row on that profile (or its implied inverse).
        case profileRow(storedOn: String)
        /// A FAM link in the installed GEDCOM.
        case tree
        /// The only assumption this engine makes: parents copied from a
        /// sibling because the person has a sibling row and no parent rows.
        case assumedFullSibling(via: String)
    }

    struct Hop: Hashable, Sendable {
        let relation: KinshipRelation
        let from: Node
        let to: Node
        let provenance: Provenance
    }

    /// One answer to "how is `to` related to `from`". `term` is the word
    /// for `to` seen from `from` ("uncle", "8th-great-grandmother",
    /// "older brother"); nil when no single English word fits, in which
    /// case `routeText` is the answer ("wife Donna → sister Ann → …").
    struct Derived: Sendable, Equatable {
        let from: Node
        let to: Node
        let term: String?
        let route: [Hop]
        /// Named hop by hop, with in-law prefixes folded when that leaves at
        /// least two segments: "sister-in-law Ann → husband Bob".
        let routeText: String
        /// Human caveats: "Tim's parents are assumed from Rick's …".
        let caveats: [String]
        /// Every source the route touched.
        let provenance: Set<Provenance>

        var isAssumed: Bool {
            provenance.contains { if case .assumedFullSibling = $0 { return true } else { return false } }
        }
        var usesTree: Bool { provenance.contains(.tree) }
    }

    let overlay: FamilyKinshipOverlay
    /// Tier A bound. Long lineal / collateral lines are Tier B's job.
    let maxHops: Int

    private let ancestorMemo = AncestorMemo()
    /// The assumed-full-sibling parents, computed once per engine for every
    /// vertex (and inverted, so the parent sees the assumed child too).
    private let assumedParents: [Node: [Hop]]
    private let assumedChildren: [Node: [Hop]]

    init(overlay: FamilyKinshipOverlay, maxHops: Int = 4) {
        self.overlay = overlay
        self.maxHops = maxHops
        var parents: [Node: [Hop]] = [:]
        var children: [Node: [Hop]] = [:]
        for node in overlay.allNodes {
            let stored = Self.storedHops(from: node, overlay: overlay)
            guard !stored.contains(where: { $0.relation == .parent }) else { continue }
            var mine: [Hop] = []
            for sibling in stored where sibling.relation == .sibling {
                let siblingParents = Self.storedHops(from: sibling.to, overlay: overlay)
                    .filter { $0.relation == .parent }.map(\.to)
                for parent in siblingParents where parent != node && !mine.contains(where: { $0.to == parent }) {
                    let via = overlay.member(sibling.to)?.name
                        ?? Self.treeName(sibling.to, overlay: overlay) ?? sibling.to.auditID
                    let hop = Hop(relation: .parent, from: node, to: parent,
                                  provenance: .assumedFullSibling(via: via))
                    mine.append(hop)
                    children[parent, default: []].append(
                        Hop(relation: .child, from: parent, to: node, provenance: hop.provenance))
                }
            }
            if !mine.isEmpty { parents[node] = mine }
        }
        self.assumedParents = parents
        self.assumedChildren = children
    }

    private static func treeName(_ node: Node, overlay: FamilyKinshipOverlay) -> String? {
        if case .tree(let id) = node { return overlay.treeGraph?.people[id]?.name }
        return nil
    }

    init(profiles: [POIProfile], graph: GedcomFamilyGraph? = nil, maxHops: Int = 4) {
        self.init(overlay: FamilyKinshipOverlay(profiles: profiles, graph: graph), maxHops: maxHops)
    }

    private var graph: GedcomFamilyGraph? { overlay.treeGraph }

    // MARK: Node facts

    func name(of node: Node) -> String {
        if let member = overlay.member(node) { return member.name }
        if case .tree(let id) = node, let person = graph?.people[id] { return person.name }
        return node.auditID
    }

    func sex(of node: Node) -> PersonSex? {
        if let member = overlay.member(node), let sex = member.sex { return sex }
        if case .tree(let id) = node, let person = graph?.people[id] {
            switch person.sex.uppercased() {
            case "M": return .male
            case "F": return .female
            default:  return nil
            }
        }
        return nil
    }

    func birthdate(of node: Node) -> Date? {
        if let member = overlay.member(node), let birth = member.birthdate { return birth }
        if case .tree(let id) = node, let year = graph?.people[id]?.birthYear {
            var dc = DateComponents()
            dc.year = year; dc.month = 1; dc.day = 1
            dc.timeZone = TimeZone(identifier: "UTC")
            return Calendar(identifier: .gregorian).date(from: dc)
        }
        return nil
    }

    func birthYear(of node: Node) -> Int? {
        guard let date = birthdate(of: node) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        return cal.component(.year, from: date)
    }

    // MARK: Adjacency

    /// Parents the data actually records: profile rows + tree FAM links.
    /// (No assumption — this is what validation counts.)
    func explicitParents(of node: Node) -> [Node] {
        var out: [Node] = []
        for hop in storedHops(from: node) where hop.relation == .parent && !out.contains(hop.to) {
            out.append(hop.to)
        }
        return out
    }

    /// Parents including the assumed-full-sibling fallback, each with its
    /// provenance. Order: explicit first, assumed after.
    func parents(of node: Node) -> [(node: Node, provenance: Provenance)] {
        hops(from: node).filter { $0.relation == .parent }.map { ($0.to, $0.provenance) }
    }

    func children(of node: Node) -> [Node] { hops(from: node).filter { $0.relation == .child }.map(\.to) }
    func spouses(of node: Node) -> [Node] { hops(from: node).filter { $0.relation == .spouse }.map(\.to) }

    /// Is `ancestor` above `node` on any recorded parent line (profile rows
    /// AND tree)? Depth-first with a visited set, so an already-corrupt
    /// cycle in the data terminates instead of recursing forever.
    func isAncestor(_ ancestor: Node, of node: Node, includeAssumed: Bool = false) -> Bool {
        var visited: Set<Node> = [node]
        var stack: [Node] = [node]
        while let current = stack.popLast() {
            let ups = includeAssumed ? parents(of: current).map(\.node) : explicitParents(of: current)
            for up in ups {
                if up == ancestor { return true }
                if visited.insert(up).inserted { stack.append(up) }
            }
        }
        return false
    }

    /// Every primitive hop out of a vertex: profile rows, then tree links
    /// (deduplicated against the rows), then assumed parents.
    func hops(from node: Node) -> [Hop] {
        storedHops(from: node) + (assumedParents[node] ?? []) + (assumedChildren[node] ?? [])
    }

    private func storedHops(from node: Node) -> [Hop] { Self.storedHops(from: node, overlay: overlay) }

    private static func storedHops(from node: Node, overlay: FamilyKinshipOverlay) -> [Hop] {
        let graph = overlay.treeGraph
        var out: [Hop] = []
        var seen = Set<HopKey>()
        for edge in overlay.edges(from: node) where Self.primitives.contains(edge.relation) {
            let key = HopKey(relation: edge.relation, to: edge.to)
            guard seen.insert(key).inserted else { continue }
            out.append(Hop(relation: edge.relation, from: node, to: edge.to,
                           provenance: .profileRow(storedOn: edge.storedOn)))
        }
        if case .tree(let id) = node, let graph, let person = graph.people[id] {
            func add(_ relation: KinshipRelation, _ people: [GedcomFamilyGraph.Person]) {
                for other in people {
                    let to = Node.tree(gedcomID: other.id)
                    guard to != node, seen.insert(HopKey(relation: relation, to: to)).inserted else { continue }
                    out.append(Hop(relation: relation, from: node, to: to, provenance: .tree))
                }
            }
            add(.parent, graph.relatives(.parents, of: person))
            add(.child, graph.relatives(.children, of: person))
            add(.spouse, graph.relatives(.spouse, of: person))
            // Tree siblings are NOT added as sibling hops: they surface as
            // parent∘child so the half-sibling check sees the parents.
        }
        return out
    }

    private struct HopKey: Hashable { let relation: KinshipRelation; let to: Node }
    static let primitives: Set<KinshipRelation> = [.parent, .child, .spouse, .sibling]

    // MARK: Queries

    /// How `to` is related to `from`. nil when the two are the same vertex
    /// or nothing links them within reach.
    func relation(from: Node, to: Node) -> Derived? {
        guard from != to else { return nil }
        if let route = shortestRoute(from: from, to: to) {
            return describe(route, from: from, to: to)
        }
        if let route = treeRoute(from: from, to: to) {
            return describe(route, from: from, to: to)
        }
        return nil
    }

    /// Everyone reachable from `node` within `maxHops` (Tier A only —
    /// the review sheet lists contemporaries, not 39k ancestors).
    func derivedRelatives(of node: Node) -> [Derived] {
        var best: [Node: [Hop]] = [:]
        var queue: [(Node, [Hop])] = [(node, [])]
        var visited: Set<Node> = [node]
        var index = 0
        while index < queue.count {
            let (current, path) = queue[index]
            index += 1
            guard path.count < maxHops else { continue }
            for hop in hops(from: current) where !visited.contains(hop.to) {
                visited.insert(hop.to)
                let next = path + [hop]
                best[hop.to] = next
                queue.append((hop.to, next))
            }
        }
        return best.map { describe($0.value, from: node, to: $0.key) }
            .sorted { lhs, rhs in
                if lhs.route.count != rhs.route.count { return lhs.route.count < rhs.route.count }
                return name(of: lhs.to) < name(of: rhs.to)
            }
    }

    /// Tier A: breadth-first shortest chain, ≤ maxHops.
    private func shortestRoute(from a: Node, to b: Node) -> [Hop]? {
        var queue: [(Node, [Hop])] = [(a, [])]
        var visited: Set<Node> = [a]
        var index = 0
        while index < queue.count {
            let (node, path) = queue[index]
            index += 1
            guard path.count < maxHops else { continue }
            for hop in hops(from: node) where !visited.contains(hop.to) {
                let next = path + [hop]
                if hop.to == b { return next }
                visited.insert(hop.to)
                queue.append((hop.to, next))
            }
        }
        return nil
    }

    // MARK: Tier B — through the tree

    /// A tree vertex reached from an endpoint by parent hops only.
    private struct Entry {
        let treeID: String
        let hops: [Hop]          // endpoint → … → tree vertex (all .parent)
    }

    /// Climb parent hops from `node` until tree vertices are reached (the
    /// tree's own ancestry is the AncestorIndex's job). Bounded by maxHops
    /// of contemporary hops.
    private func treeEntries(from node: Node) -> [Entry] {
        var out: [Entry] = []
        var queue: [(Node, [Hop])] = [(node, [])]
        var visited: Set<Node> = [node]
        var index = 0
        while index < queue.count {
            let (current, path) = queue[index]
            index += 1
            if case .tree(let id) = current {
                out.append(Entry(treeID: id, hops: path))
                continue
            }
            guard path.count < maxHops else { continue }
            for hop in hops(from: current) where hop.relation == .parent && !visited.contains(hop.to) {
                visited.insert(hop.to)
                queue.append((hop.to, path + [hop]))
            }
        }
        return out
    }

    private func treeRoute(from a: Node, to b: Node) -> [Hop]? {
        guard let graph else { return nil }
        let entriesA = treeEntries(from: a)
        guard !entriesA.isEmpty else { return nil }
        let entriesB = treeEntries(from: b)
        guard !entriesB.isEmpty else { return nil }

        // Best = smallest total generations to the common ancestor.
        var best: (route: [Hop], cost: Int)?
        for ea in entriesA {
            let indexA = ancestorMemo.index(for: ea.treeID, in: graph)
            for eb in entriesB {
                let indexB = ancestorMemo.index(for: eb.treeID, in: graph)
                // Candidate common ancestors: one entry above the other, or a
                // shared ancestor found by intersection.
                var candidates: [(id: String, upA: Int, upB: Int)] = []
                if ea.treeID == eb.treeID {
                    candidates.append((ea.treeID, 0, 0))
                } else {
                    if let g = indexA.generations(from: eb.treeID) { candidates.append((eb.treeID, g, 0)) }
                    if let g = indexB.generations(from: ea.treeID) { candidates.append((ea.treeID, 0, g)) }
                    if candidates.isEmpty {
                        // Nearest shared ancestor by intersecting the two
                        // memoized depth maps (same reckoning as
                        // GedcomFamilyGraph.commonAncestors, without
                        // rebuilding both indexes per query). Probe the
                        // smaller map.
                        let dA = indexA.depths, dB = indexB.depths
                        let (small, large) = dA.count <= dB.count ? (dA, dB) : (dB, dA)
                        var nearest: (id: String, upA: Int, upB: Int)?
                        for (id, _) in small {
                            guard large[id] != nil, let a = dA[id], let b = dB[id] else { continue }
                            if let n = nearest, n.upA + n.upB < a + b { continue }
                            if let n = nearest, n.upA + n.upB == a + b, n.id < id { continue }
                            nearest = (id, a, b)
                        }
                        if let nearest { candidates.append(nearest) }
                    }
                }
                for c in candidates {
                    let cost = ea.hops.count + c.upA + eb.hops.count + c.upB
                    if let best, best.cost <= cost { continue }
                    // upA = [ancestor, …, ea] (just [ea] when ea IS the
                    // ancestor — AncestorIndex.path is nil for self); walk
                    // it upward as parent hops, then upB downward as child hops.
                    guard let upA = c.id == ea.treeID ? graph.people[ea.treeID].map { [$0] } : indexA.path(from: c.id),
                          let upB = c.id == eb.treeID ? graph.people[eb.treeID].map { [$0] } : indexB.path(from: c.id)
                    else { continue }
                    var route = ea.hops
                    for i in stride(from: upA.count - 1, to: 0, by: -1) {
                        route.append(Hop(relation: .parent, from: .tree(gedcomID: upA[i].id),
                                         to: .tree(gedcomID: upA[i - 1].id), provenance: .tree))
                    }
                    for i in 0..<(max(upB.count - 1, 0)) {
                        route.append(Hop(relation: .child, from: .tree(gedcomID: upB[i].id),
                                         to: .tree(gedcomID: upB[i + 1].id), provenance: .tree))
                    }
                    for hop in eb.hops.reversed() {
                        route.append(Hop(relation: .child, from: hop.to, to: hop.from, provenance: hop.provenance))
                    }
                    guard route.last?.to == b, !route.isEmpty else { continue }
                    best = (route, cost)
                }
            }
        }
        return best?.route
    }

    // MARK: Description

    private func describe(_ route: [Hop], from: Node, to: Node) -> Derived {
        let relations = route.map(\.relation)
        var term: String?
        if let named = KinshipChainNamer.name(relations) {
            var half = false
            var age: String?
            if named.isSibling {
                half = isHalfSibling(from, to)
                age = KinshipDisplay.ageWord(.sibling, subjectBirth: birthdate(of: to), anchorBirth: birthdate(of: from))
            }
            term = named.term(sex: sex(of: to), half: half, age: age)
        }
        var caveats: [String] = []
        var assumedNoted = Set<String>()
        for hop in route {
            if case .assumedFullSibling(let via) = hop.provenance {
                let line = "\(name(of: hop.from))'s parents are assumed from \(via)'s (sibling entered without shared parents — assumed full)"
                if assumedNoted.insert(line).inserted { caveats.append(line) }
            }
        }
        return Derived(from: from, to: to, term: term, route: route,
                       routeText: routeText(route), caveats: caveats,
                       provenance: Set(route.map(\.provenance)))
    }

    /// Exactly one shared parent while BOTH have two recorded → half.
    /// Anything less certain stays "full" (Director: siblings default full).
    private func isHalfSibling(_ a: Node, _ b: Node) -> Bool {
        let pa = Set(parents(of: a).map(\.node)), pb = Set(parents(of: b).map(\.node))
        guard pa.count >= 2, pb.count >= 2 else { return false }
        return pa.intersection(pb).count == 1
    }

    /// "wife Donna → sister Ann → husband Bob", with a named in-law prefix
    /// folded ("sister-in-law Ann → husband Bob") when the fold still leaves
    /// two or more segments; lineal runs are never folded so a long line
    /// stays auditable hop by hop.
    func routeText(_ route: [Hop]) -> String {
        var segments: [String] = []
        var i = 0
        while i < route.count {
            var end = i + 1
            let lineal = route[i].relation == .parent || route[i].relation == .child
            if !lineal {
                // Longest prefix from i that the fold table names, leaving ≥ 2 segments overall.
                var j = min(route.count, i + 3)
                while j > i + 1 {
                    let chain = route[i..<j].map(\.relation)
                    if KinshipRelation.compose(chain) != nil, !(i == 0 && j == route.count) {
                        end = j
                        break
                    }
                    j -= 1
                }
            }
            let last = route[end - 1]
            let word: String
            if end - i == 1 {
                word = last.relation.term(sex: sex(of: last.to))
            } else if let folded = KinshipRelation.compose(route[i..<end].map(\.relation)) {
                word = folded.term(sex: sex(of: last.to))
            } else {
                word = last.relation.term(sex: sex(of: last.to))
            }
            segments.append("\(word) \(name(of: last.to))")
            i = end
        }
        return segments.joined(separator: " → ")
    }

    // MARK: Ancestor-index memo

    /// Small LRU-less memo: an AncestorIndex per tree entry. Cleared when
    /// it reaches `limit` so memory is bounded (≈ limit × ancestors × 2
    /// strings). Keyed by GEDCOM pointer; the graph is immutable per
    /// overlay, so no generation key is needed here — a new overlay gets a
    /// new engine and a new memo.
    private final class AncestorMemo: @unchecked Sendable {
        private let lock = NSLock()
        private var indexes: [String: GedcomFamilyGraph.AncestorIndex] = [:]
        static let limit = 256

        func index(for id: String, in graph: GedcomFamilyGraph) -> GedcomFamilyGraph.AncestorIndex {
            lock.lock(); defer { lock.unlock() }
            if let hit = indexes[id] { return hit }
            if indexes.count >= Self.limit { indexes.removeAll(keepingCapacity: true) }
            let built = GedcomFamilyGraph.AncestorIndex(graph: graph, descendantID: id)
            indexes[id] = built
            return built
        }
    }
}

// MARK: - The one chain composer

/// Names a chain of primitive hops. The ONLY place a hop chain becomes a
/// word: the fold table (`KinshipRelation.compose`) for the in-law
/// vocabulary, then lineal / collateral shapes for the open-ended words
/// (great-grand…, great-aunt, Nth cousin M times removed) via the Core
/// tree's reckoning (`generationLabel`, `kinshipTerm`).
enum KinshipChainNamer {

    enum Named: Equatable {
        /// A word from the closed vocabulary (brother, uncle, mother-in-law…).
        case relation(KinshipRelation)
        /// `generations` parents straight up (1 = parent, 3 = great-grandparent).
        case ancestor(generations: Int)
        /// `generations` children straight down.
        case descendant(generations: Int)
        /// Common ancestor `up` above the anchor and `down` above the subject
        /// (never 1/1 — that is `.relation(.sibling)`).
        case collateral(up: Int, down: Int)

        var isSibling: Bool { self == .relation(.sibling) }

        /// The word for the SUBJECT (the far end), gendered by their sex.
        func term(sex: PersonSex?, half: Bool = false, age: String? = nil) -> String {
            let prefix = (age.map { $0 + " " } ?? "") + (half ? "half-" : "")
            switch self {
            case .relation(let relation):
                return prefix + relation.term(sex: sex)
            case .ancestor(let g):
                return GedcomFamilyGraph.generationLabel(generations: g, sex: Self.sexCode(sex))
            case .descendant(let g):
                let base: String
                switch sex {
                case .male?:   base = g == 1 ? "son" : "grandson"
                case .female?: base = g == 1 ? "daughter" : "granddaughter"
                case nil:      base = g == 1 ? "child" : "grandchild"
                }
                return Self.greats(g - 2) + base
            case .collateral(let up, let down):
                if up == 1 {
                    // Anchor's sibling's descendant: niece/nephew, great- per extra step.
                    return Self.greats(down - 2) + KinshipRelation.nieceNephew.term(sex: sex)
                }
                if down == 1 {
                    return Self.greats(up - 2) + KinshipRelation.auntUncle.term(sex: sex)
                }
                // "2nd cousins once removed" → singular.
                return GedcomFamilyGraph.kinshipTerm(depthA: up, depthB: down)
                    .replacingOccurrences(of: "cousins", with: "cousin")
            }
        }

        private static func greats(_ n: Int) -> String {
            switch n {
            case ...0: return ""
            case 1:    return "great-"
            case 2:    return "great-great-"
            default:   return GedcomFamilyGraph.numericOrdinal(n) + "-great-"
            }
        }

        private static func sexCode(_ sex: PersonSex?) -> String {
            switch sex {
            case .male?:   return "M"
            case .female?: return "F"
            case nil:      return ""
            }
        }
    }

    /// nil ⇒ no single English word (show the route).
    static func name(_ hops: [KinshipRelation]) -> Named? {
        guard !hops.isEmpty else { return nil }
        if let folded = KinshipRelation.compose(hops) { return .relation(folded) }
        // Shape rule: parents^k · [sibling] · children^m, nothing else. A
        // sibling hop in the middle counts as one more generation on each
        // side (my sibling = my parent's child). No spouse hop anywhere.
        var k = 0, m = 0, i = 0
        while i < hops.count, hops[i] == .parent { k += 1; i += 1 }
        // A sibling hop is allowed first ("my sibling's grandchild") or after
        // parents ("my grandparent's sibling"); never after a child hop —
        // "my child's sibling" is my child only if full, and that assumption
        // is made once, in the engine's assumed-parent edges, not here.
        if i < hops.count, hops[i] == .sibling, i == k { k += 1; m += 1; i += 1 }
        while i < hops.count, hops[i] == .child { m += 1; i += 1 }
        guard i == hops.count else { return nil }
        switch (k, m) {
        case (0, 0): return nil
        case (_, 0): return .ancestor(generations: k)
        case (0, _): return .descendant(generations: m)
        case (1, 1): return .relation(.sibling)
        default:     return .collateral(up: k, down: m)
        }
    }
}
