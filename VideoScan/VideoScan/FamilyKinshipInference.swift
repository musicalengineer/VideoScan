// FamilyKinshipInference.swift
// Derivation engine for People-tab relationships (design:
// docs/kinship_inference_design.md §2 + amendments 1, 2, 5, 6, 7 after
// codex review #830/#831/#833, 2026-08-29). Rick stores only the four
// PRIMITIVES — parent, child, spouse, sibling — and everything else ("Tim
// is uncle of Matt", "Bob is Rick's brother-in-law", "Martha Lamson is
// Tim's 8th-great-grandmother") is derived here at read time from:
//
//   • the FamilyKinshipOverlay's primitive edges (profile rows + inverses),
//     built in `.pinsOnly` mode: a profile is a tree vertex ONLY through
//     its explicit `treeIdentity` pin (identity ≠ relationship);
//   • the GEDCOM graph's parent / child / spouse links for tree vertices;
//   • ATTESTED sibling rows: `.attestedFull` lets the sibling's recorded
//     parents flow through the row (`.attestedSibling` provenance);
//     `.attestedHalf(sharedParent:)` lets only that parent through. An
//     `.unspecified` sibling row supports sibling / uncle / niece /
//     in-law composition only — it never copies parents as facts; the
//     engine PROPOSES them (`proposals(for:)`) for the review sheet, and a
//     lineal question through such a row answers honestly with a
//     "not attested" note instead of a word.
//
// Two tiers per query (the hybrid boundary, amendment 5):
//   Tier A — breadth-first search over the unified adjacency, ≤ `maxHops`
//            (4), shortest chain wins with a stable tie-break (hop kind
//            parent < child < spouse < sibling, explicit before attested,
//            then the normalized identity key of the far vertex); the chain
//            is named by `KinshipChainNamer` (fold table + shapes).
//   Tier B — when A finds nothing and a tree is installed: climb each
//            endpoint's PARENT hops (blood only) to its pinned tree
//            vertices, then intersect memoised `AncestorIndex` depth maps
//            for the nearest common ancestor — one ancestor walk per tree
//            entry, never a per-pair expansion of the tree.
//
// Never invented: spouse∘spouse, sibling∘sibling, parent∘spouse (step),
// spouse∘child — those fall to route text (codex #778 / #795 D), and no
// chain is named through two spouse hops except the pinned whole chain
// [spouse, sibling, spouse]. "older/younger" only when the order is
// provable at the available date precision (no manufactured Jan 1).
//
// Pure and injected. Worst-case memory: the BFS frontier is bounded by 4
// hops over a fan-out of a few dozen (contemporaries) — kilobytes; the
// ancestor-index memo holds at most `AncestorMemo.limit` indexes (≈ 200 KB
// each on the deepest tree) and is cleared, not grown, when full.
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
        /// A parent inherited through a sibling row Rick ATTESTED
        /// (full, or half with that shared parent named).
        case attestedSibling(via: String)

        var isExplicit: Bool {
            if case .attestedSibling = self { return false }
            return true
        }
    }

    struct Hop: Hashable, Sendable {
        let relation: KinshipRelation
        let from: Node
        let to: Node
        let provenance: Provenance
        /// The sibling row's basis when `relation == .sibling`.
        var basis: SiblingBasis = .unspecified
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
        /// Human caveats: "Tim's sibling link to Rick is not attested …".
        let caveats: [String]
        /// Every source the route touched.
        let provenance: Set<Provenance>

        var usesTree: Bool { provenance.contains(.tree) }
        var usesAttestation: Bool {
            provenance.contains { if case .attestedSibling = $0 { return true } else { return false } }
        }
    }

    /// Something the review sheet should ask Rick to confirm — never a fact.
    struct Proposal: Sendable, Equatable {
        enum Kind: Sendable, Equatable {
            /// "Tim shares Rick's parents" (assumed full) — accepting sets the
            /// sibling row's basis to `.attestedFull`.
            case sharedParents(via: Node, parents: [Node])
        }
        let subject: Node
        let kind: Kind
        let text: String
    }

    let overlay: FamilyKinshipOverlay
    /// Tier A bound. Long lineal / collateral lines are Tier B's job.
    let maxHops: Int

    private let ancestorMemo = AncestorMemo()
    /// Parents inherited through ATTESTED sibling rows, computed once per
    /// engine for every vertex, and inverted so the parent sees the child.
    private let attestedParents: [Node: [Hop]]
    private let attestedChildren: [Node: [Hop]]

    init(profiles: [POIProfile], graph: GedcomFamilyGraph? = nil, maxHops: Int = 4) {
        self.init(overlay: FamilyKinshipOverlay(profiles: profiles, graph: graph, bridging: .pinsOnly),
                  maxHops: maxHops)
    }

    init(snapshots: [ArchivistGraphProfileSnapshot], graph: GedcomFamilyGraph? = nil, maxHops: Int = 4) {
        self.init(overlay: FamilyKinshipOverlay(snapshots: snapshots, graph: graph, bridging: .pinsOnly),
                  maxHops: maxHops)
    }

    /// The overlay must be `.pinsOnly` (the two public inits guarantee it);
    /// private so no caller can hand in a name-bridged identity space.
    private init(overlay: FamilyKinshipOverlay, maxHops: Int) {
        self.overlay = overlay
        self.maxHops = maxHops
        var parents: [Node: [Hop]] = [:]
        var children: [Node: [Hop]] = [:]
        for node in overlay.allNodes {
            let stored = Self.storedHops(from: node, overlay: overlay)
            guard !stored.contains(where: { $0.relation == .parent }) else { continue }
            var mine: [Hop] = []
            for sibling in stored where sibling.relation == .sibling {
                let inherited: [Node]
                switch sibling.basis {
                case .unspecified:
                    continue
                case .attestedFull:
                    inherited = Self.storedHops(from: sibling.to, overlay: overlay)
                        .filter { $0.relation == .parent }.map(\.to)
                case .attestedHalf(let shared):
                    inherited = overlay.node(for: shared).map { [$0] } ?? []
                }
                let via = Self.name(of: sibling.to, overlay: overlay)
                for parent in inherited where parent != node && !mine.contains(where: { $0.to == parent }) {
                    let hop = Hop(relation: .parent, from: node, to: parent, provenance: .attestedSibling(via: via))
                    mine.append(hop)
                    children[parent, default: []].append(
                        Hop(relation: .child, from: parent, to: node, provenance: hop.provenance))
                }
            }
            if !mine.isEmpty { parents[node] = mine }
        }
        self.attestedParents = parents
        self.attestedChildren = children
    }

    private var graph: GedcomFamilyGraph? { overlay.treeGraph }

    // MARK: Node facts

    func name(of node: Node) -> String { Self.name(of: node, overlay: overlay) }

    private static func name(of node: Node, overlay: FamilyKinshipOverlay) -> String {
        if let member = overlay.member(node) { return member.name }
        if case .tree(let id) = node, let person = overlay.treeGraph?.people[id] { return person.name }
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

    /// Birth knowledge at native precision (profile date, or tree year
    /// interval); nil when unknown. Never a manufactured January 1.
    func birth(of node: Node) -> BirthKnowledge? {
        if let member = overlay.member(node), let birth = member.birth { return birth }
        if case .tree(let id) = node, let years = graph?.people[id]?.birthYearInterval { return .years(years) }
        return nil
    }

    // MARK: Adjacency

    /// Parents the data actually records: profile rows + tree FAM links,
    /// deduplicated by vertex (a row to "Dad" and the tree's father are the
    /// same vertex when Dad is pinned). What validation counts.
    func explicitParents(of node: Node) -> [Node] {
        var out: [Node] = []
        for hop in storedHops(from: node) where hop.relation == .parent && !out.contains(hop.to) {
            out.append(hop.to)
        }
        return out
    }

    /// Explicit parents plus those inherited through attested sibling rows.
    func parents(of node: Node) -> [(node: Node, provenance: Provenance)] {
        hops(from: node).filter { $0.relation == .parent }.map { ($0.to, $0.provenance) }
    }

    func children(of node: Node) -> [Node] { hops(from: node).filter { $0.relation == .child }.map(\.to) }
    func spouses(of node: Node) -> [Node] { hops(from: node).filter { $0.relation == .spouse }.map(\.to) }

    /// Is `ancestor` above `node` on any recorded parent line (rows,
    /// attested siblings, AND tree ancestry through pins)? Row-based
    /// parents are walked hop by hop; a tree vertex's own ancestry comes
    /// from one memoised ancestor index (O(ancestors of that person), no
    /// per-hop tree calls, no whole-tree expansion). Visited set, so an
    /// already-corrupt cycle terminates.
    func isAncestor(_ ancestor: Node, of node: Node) -> Bool {
        var visited: Set<Node> = [node]
        var stack: [Node] = [node]
        while let current = stack.popLast() {
            for up in rowParents(of: current) {
                if up == ancestor { return true }
                if visited.insert(up).inserted { stack.append(up) }
            }
            if case .tree(let id) = current, let graph {
                let index = ancestorMemo.index(for: id, in: graph)
                if case .tree(let target) = ancestor, index.generations(from: target) != nil { return true }
                // Tree ancestors that ALSO carry People-tab rows can climb
                // further through those rows.
                for treeAncestor in index.depths.keys.sorted() {
                    let up = Node.tree(gedcomID: treeAncestor)
                    guard overlay.knows(up) || attestedParents[up] != nil else { continue }
                    if visited.insert(up).inserted { stack.append(up) }
                }
            }
        }
        return false
    }

    /// Parent hops that come from rows / attestations (not tree FAM links).
    private func rowParents(of node: Node) -> [Node] {
        hops(from: node).filter { $0.relation == .parent && $0.provenance != .tree }.map(\.to)
    }

    /// Every primitive hop out of a vertex in DETERMINISTIC order: hop kind
    /// (parent < child < spouse < sibling), explicit before attested, then
    /// the far vertex's normalized identity key. The BFS inherits this
    /// order, so a reversed profile list yields the same route.
    func hops(from node: Node) -> [Hop] {
        let all = storedHops(from: node) + (attestedParents[node] ?? []) + (attestedChildren[node] ?? [])
        return all.sorted { lhs, rhs in
            let lk = Self.kindRank(lhs.relation), rk = Self.kindRank(rhs.relation)
            if lk != rk { return lk < rk }
            if lhs.provenance.isExplicit != rhs.provenance.isExplicit { return lhs.provenance.isExplicit }
            return lhs.to.identityKey < rhs.to.identityKey
        }
    }

    private static func kindRank(_ relation: KinshipRelation) -> Int {
        switch relation {
        case .parent:  return 0
        case .child:   return 1
        case .spouse:  return 2
        case .sibling: return 3
        default:       return 4
        }
    }

    private func storedHops(from node: Node) -> [Hop] { Self.storedHops(from: node, overlay: overlay) }

    private static func storedHops(from node: Node, overlay: FamilyKinshipOverlay) -> [Hop] {
        let graph = overlay.treeGraph
        var out: [Hop] = []
        var seen = Set<HopKey>()
        for edge in overlay.edges(from: node) where primitives.contains(edge.relation) {
            let key = HopKey(relation: edge.relation, to: edge.to)
            guard seen.insert(key).inserted else { continue }
            out.append(Hop(relation: edge.relation, from: node, to: edge.to,
                           provenance: .profileRow(storedOn: edge.storedOn), basis: edge.basis))
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
        if let route = shortestRoute(from: from, to: to) { return describe(route, from: from, to: to) }
        if let route = treeRoute(from: from, to: to) { return describe(route, from: from, to: to) }
        if let honest = unattestedSiblingRoute(from: from, to: to) { return honest }
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
                return lhs.to.identityKey < rhs.to.identityKey
            }
    }

    /// What the review sheet should ask about `node`: for every
    /// `.unspecified` sibling row where `node` has no recorded parents and
    /// the sibling does — "Tim shares Rick's parents (Dad and Eileen)".
    func proposals(for node: Node) -> [Proposal] {
        guard parents(of: node).isEmpty else { return [] }
        var out: [Proposal] = []
        for hop in hops(from: node) where hop.relation == .sibling && hop.basis == .unspecified {
            let theirs = explicitParents(of: hop.to)
            guard !theirs.isEmpty else { continue }
            let list = theirs.map(name(of:)).joined(separator: " and ")
            out.append(Proposal(
                subject: node,
                kind: .sharedParents(via: hop.to, parents: theirs),
                text: "\(name(of: node)) shares \(name(of: hop.to))'s parents (\(list)) — assumed full; confirm to inherit \(name(of: hop.to))'s ancestry"))
        }
        return out
    }

    /// Tier A: breadth-first shortest chain, ≤ maxHops, deterministic.
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

    /// Climb parent hops (blood only) from `node` until tree vertices are
    /// reached; the tree's own ancestry is the AncestorIndex's job.
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

    private struct CommonAncestor { let id: String; let upA: Int; let upB: Int }

    private func treeRoute(from a: Node, to b: Node) -> [Hop]? {
        guard let graph else { return nil }
        let entriesA = treeEntries(from: a)
        guard !entriesA.isEmpty else { return nil }
        let entriesB = treeEntries(from: b)
        guard !entriesB.isEmpty else { return nil }
        var best: (route: [Hop], cost: Int)?
        for ea in entriesA {
            let indexA = ancestorMemo.index(for: ea.treeID, in: graph)
            for eb in entriesB {
                let indexB = ancestorMemo.index(for: eb.treeID, in: graph)
                for common in commonAncestors(ea.treeID, indexA, eb.treeID, indexB) {
                    let cost = ea.hops.count + common.upA + eb.hops.count + common.upB
                    if let best, best.cost <= cost { continue }
                    guard let route = assemble(ea, indexA, eb, indexB, common, graph: graph),
                          route.last?.to == b else { continue }
                    best = (route, cost)
                }
            }
        }
        return best?.route
    }

    /// Candidate common ancestors of two tree entries: one above the
    /// other, or the nearest shared ancestor by intersecting the two
    /// memoised depth maps (same reckoning as
    /// GedcomFamilyGraph.commonAncestors, without rebuilding indexes).
    private func commonAncestors(_ idA: String, _ indexA: GedcomFamilyGraph.AncestorIndex,
                                 _ idB: String, _ indexB: GedcomFamilyGraph.AncestorIndex) -> [CommonAncestor] {
        if idA == idB { return [CommonAncestor(id: idA, upA: 0, upB: 0)] }
        var out: [CommonAncestor] = []
        if let g = indexA.generations(from: idB) { out.append(CommonAncestor(id: idB, upA: g, upB: 0)) }
        if let g = indexB.generations(from: idA) { out.append(CommonAncestor(id: idA, upA: 0, upB: g)) }
        guard out.isEmpty else { return out }
        let dA = indexA.depths, dB = indexB.depths
        let small = dA.count <= dB.count ? dA : dB
        var nearest: CommonAncestor?
        for (id, _) in small {
            guard let a = dA[id], let b = dB[id] else { continue }
            if let n = nearest, n.upA + n.upB < a + b { continue }
            if let n = nearest, n.upA + n.upB == a + b, n.id < id { continue }
            nearest = CommonAncestor(id: id, upA: a, upB: b)
        }
        return nearest.map { [$0] } ?? []
    }

    /// endpoint-A hops, up the tree to the common ancestor, down to entry
    /// B, then endpoint-B hops reversed as child hops.
    private func assemble(_ ea: Entry, _ indexA: GedcomFamilyGraph.AncestorIndex,
                          _ eb: Entry, _ indexB: GedcomFamilyGraph.AncestorIndex,
                          _ common: CommonAncestor, graph: GedcomFamilyGraph) -> [Hop]? {
        // AncestorIndex.path is nil for the descendant itself: [self] then.
        guard let upA = common.id == ea.treeID ? graph.people[ea.treeID].map({ [$0] }) : indexA.path(from: common.id),
              let upB = common.id == eb.treeID ? graph.people[eb.treeID].map({ [$0] }) : indexB.path(from: common.id)
        else { return nil }
        var route = ea.hops
        for i in stride(from: upA.count - 1, to: 0, by: -1) {
            route.append(Hop(relation: .parent, from: .tree(gedcomID: upA[i].id),
                             to: .tree(gedcomID: upA[i - 1].id), provenance: .tree))
        }
        for i in 0..<max(upB.count - 1, 0) {
            route.append(Hop(relation: .child, from: .tree(gedcomID: upB[i].id),
                             to: .tree(gedcomID: upB[i + 1].id), provenance: .tree))
        }
        for hop in eb.hops.reversed() {
            route.append(Hop(relation: .child, from: hop.to, to: hop.from, provenance: hop.provenance))
        }
        return route.isEmpty ? nil : route
    }

    // MARK: Honest answer through an unattested sibling row

    /// Tim (sibling of Rick, basis unspecified, no parents of his own) →
    /// Martha Lamson: no fact links them, so the route stops at Rick and
    /// says why — never a word, never a silent nil.
    private func unattestedSiblingRoute(from a: Node, to b: Node) -> Derived? {
        if parents(of: a).isEmpty {
            for hop in hops(from: a) where hop.relation == .sibling && hop.basis == .unspecified {
                guard let inner = shortestRoute(from: hop.to, to: b) ?? treeRoute(from: hop.to, to: b),
                      inner.first?.relation == .parent else { continue }
                return honest(route: [hop] + inner, lineal: inner, linealFrom: hop.to, linealTo: b,
                              unattested: a, sibling: hop.to, from: a, to: b)
            }
        }
        if parents(of: b).isEmpty {
            for hop in hops(from: b) where hop.relation == .sibling && hop.basis == .unspecified {
                guard let inner = shortestRoute(from: a, to: hop.to) ?? treeRoute(from: a, to: hop.to),
                      inner.last?.relation == .child else { continue }
                let back = Hop(relation: .sibling, from: hop.to, to: b,
                               provenance: hop.provenance, basis: hop.basis)
                return honest(route: inner + [back], lineal: inner, linealFrom: a, linealTo: hop.to,
                              unattested: b, sibling: hop.to, from: a, to: b)
            }
        }
        return nil
    }

    /// `lineal` is the factual part of the route (sibling → target, or
    /// source → sibling); its own word goes into the note so Rick sees
    /// what WOULD follow from attesting.
    private func honest(route: [Hop], lineal: [Hop], linealFrom: Node, linealTo: Node,
                        unattested: Node, sibling: Node, from: Node, to: Node) -> Derived {
        let viaWord = describe(lineal, from: linealFrom, to: linealTo).term
        var caveat = "\(name(of: unattested))'s sibling link to \(name(of: sibling)) is not attested as full, so \(name(of: sibling))'s parents are not treated as \(name(of: unattested))'s"
        if let viaWord {
            caveat += " — \(name(of: linealTo)) is \(KinshipDisplay.possessive(name(of: linealFrom))) \(viaWord)"
        }
        caveat += " (confirm the shared parents to inherit this)"
        return Derived(from: from, to: to, term: nil, route: route, routeText: routeText(route),
                       caveats: [caveat], provenance: Set(route.map(\.provenance)))
    }

    // MARK: Description

    private func describe(_ route: [Hop], from: Node, to: Node) -> Derived {
        var term: String?
        var caveats: [String] = []
        if let named = KinshipChainNamer.name(route.map(\.relation)) {
            var half = false
            var age: String?
            if named.isSibling {
                let verdict = siblingVerdict(from, to, route: route)
                half = verdict.half
                if let caveat = verdict.caveat { caveats.append(caveat) }
                age = BirthKnowledge.ageWord(subject: birth(of: to), anchor: birth(of: from))
            }
            term = named.term(sex: sex(of: to), half: half, age: age)
        }
        // A lineal step taken right after an unattested sibling hop is a
        // route, not a fact — say so (Tier A can reach "brother Rick →
        // father Dad" within 4 hops).
        for (i, hop) in route.enumerated().dropLast()
            where hop.relation == .sibling && hop.basis == .unspecified && route[i + 1].relation == .parent {
            caveats.append("\(name(of: hop.from))'s sibling link to \(name(of: hop.to)) is not attested as full, so \(name(of: hop.to))'s parents are not treated as \(name(of: hop.from))'s")
        }
        return Derived(from: from, to: to, term: term, route: route,
                       routeText: routeText(route), caveats: caveats,
                       provenance: Set(route.map(\.provenance)))
    }

    /// Half only with complete evidence: an `.attestedHalf` row, or both
    /// people having two recorded parents of which exactly one is shared.
    /// One shared parent + one unknown is NOT half — it is "full assumed",
    /// with a caveat when the word came from parent∘child rather than a row.
    private func siblingVerdict(_ a: Node, _ b: Node, route: [Hop]) -> (half: Bool, caveat: String?) {
        if route.count == 1, case .attestedHalf = route[0].basis { return (true, nil) }
        let pa = Set(parents(of: a).map(\.node)), pb = Set(parents(of: b).map(\.node))
        if pa.count >= 2, pb.count >= 2 {
            return (pa.intersection(pb).count == 1, nil)
        }
        guard route.count > 1 else { return (false, nil) }   // Rick's own row: his word stands
        let short = pa.count < 2 ? a : b
        return (false, "full or half not established — \(name(of: short))'s second parent is not recorded (full assumed)")
    }

    /// "wife Donna → sister Ann → husband Bob", with a named in-law prefix
    /// folded ("sister-in-law Ann → husband Bob") when the fold still leaves
    /// two or more segments; lineal runs are never folded so a long line
    /// stays auditable hop by hop.
    func routeText(_ route: [Hop]) -> String {
        var segments: [String] = []
        var i = 0
        while i < route.count {
            let end = foldEnd(route, from: i)
            let last = route[end - 1]
            let word = (end - i > 1 ? KinshipRelation.compose(route[i..<end].map(\.relation)) : nil)
                .map { $0.term(sex: sex(of: last.to)) } ?? last.relation.term(sex: sex(of: last.to))
            segments.append("\(word) \(name(of: last.to))")
            i = end
        }
        return segments.joined(separator: " → ")
    }

    /// Longest prefix from `i` the fold table names, never a lineal hop and
    /// never the whole chain; else `i + 1`.
    private func foldEnd(_ route: [Hop], from i: Int) -> Int {
        guard route[i].relation != .parent, route[i].relation != .child else { return i + 1 }
        var j = min(route.count, i + 3)
        while j > i + 1 {
            if KinshipRelation.compose(route[i..<j].map(\.relation)) != nil, !(i == 0 && j == route.count) {
                return j
            }
            j -= 1
        }
        return i + 1
    }

    // MARK: Ancestor-index memo

    /// Small memo: an AncestorIndex per tree entry. Cleared when it reaches
    /// `limit` so memory is bounded (≈ limit × ancestors × 2 strings).
    /// Keyed by GEDCOM pointer; the graph is immutable per overlay, so no
    /// generation key is needed — a new overlay gets a new engine and memo.
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
        // sibling hop is allowed first ("my sibling's grandchild") or after
        // parents ("my grandparent's sibling"), counting as one more
        // generation on each side; never after a child hop — "my child's
        // sibling" is my child only if full, and that is a stored fact
        // (attested basis), not a naming rule. No spouse hop anywhere.
        var k = 0, m = 0, i = 0
        while i < hops.count, hops[i] == .parent { k += 1; i += 1 }
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
