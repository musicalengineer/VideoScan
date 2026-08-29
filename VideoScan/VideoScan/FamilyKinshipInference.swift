// FamilyKinshipInference.swift
// Derivation engine for People-tab relationships (design:
// docs/kinship_inference_design.md §2 + amendments after codex review
// #830/#831/#833/#835/#845, 2026-08-29). Rick stores only the four
// PRIMITIVES — parent, child, spouse, sibling — and everything else ("Tim
// is uncle of Matt", "Bob is Rick's brother-in-law", "Martha Lamson is
// Tim's 8th-great-grandmother") is derived here at read time from:
//
//   • the FamilyKinshipOverlay's primitive edges (profile rows + inverses);
//     a profile is a tree vertex ONLY through its explicit `treeIdentity`
//     pin (identity ≠ relationship — no name matching anywhere in here);
//   • the GEDCOM's parent / child / spouse links, read through the
//     compiled `TreeIndex` (integer CSR) — never `Person` copies;
//   • ATTESTED sibling rows: `.attestedFull` lets the sibling's recorded
//     parents flow through the row (merged per parent with whatever is
//     already recorded); `.attestedHalf(sharedParent:)` lets only that
//     parent through. An `.unspecified` sibling row supports sibling /
//     uncle / niece / in-law composition only — it never copies parents;
//     the engine PROPOSES them (`proposals(for:)`) for the review sheet,
//     and a lineal question through such a row answers honestly with a
//     "not attested" note instead of a word.
//
// Query = two tiers, both bounded:
//   Tier A — breadth-first over the canonical adjacency (built and sorted
//            ONCE per engine: hop kind parent < child < spouse < sibling,
//            explicit before attested, then identity key), ≤ maxHops (4)
//            and ≤ `expansionBudget` vertex expansions. Only HELD vertices
//            (profiles, pinned people, tree people carrying rows) and the
//            start vertex are expanded; a pure-tree vertex met on the way
//            is a destination, never a springboard — blood relations
//            through the tree are Tier B's job, so a tree with heavy
//            intermarriage cannot make one question cost seconds.
//   Tier B — climb PARENT hops (blood only) to each endpoint's pinned tree
//            vertices, then a level-synchronous bidirectional ancestor
//            search on ordinals finds the nearest common ancestor: cost is
//            the explored ancestry up to the meeting depth, not the whole
//            tree, and nothing is materialised or sorted.
//
// Results are memoised per ordered pair (bounded by entries AND bytes,
// oldest-first eviction, single-flight for concurrent identical queries);
// the display center drops the whole engine on a tree or kinship-relevant
// profile change, so no generation key lives in here.
//
// Never invented: spouse∘spouse, sibling∘sibling, parent∘spouse (step),
// spouse∘child — those fall to route text (codex #778 / #795 D), and no
// chain is named through two spouse hops except the pinned whole chain
// [spouse, sibling, spouse]. "older/younger" only when the order is
// provable at the available date precision (no manufactured Jan 1).
//
// Memory, worst case: adjacency ≈ (profiles + pinned) × hops × ~120 B —
// kilobytes; a Tier B search holds two ordinal→(depth, via) maps sized by
// the explored ancestry (≤ 39k × 24 B ≈ 1 MB transient); the pair memo is
// capped at `KinshipQueryCache.entryLimit` entries / `KinshipQueryCache.byteBudget`.
//
// C++ readers: `struct` = value type; `final class … : @unchecked Sendable`
// with an `NSCondition` is the idiom for a shared mutable cache — "I
// promise the lock makes this thread-safe" (the compiler can't prove it).

import CryptoKit
import Foundation
import VideoScanCore

struct FamilyKinshipInference: Sendable {

    typealias Node = FamilyKinshipOverlay.Node

    /// Where one hop came from, so every derived sentence can cite it.
    enum Provenance: Hashable, Sendable {
        /// A stored row on that profile (or its implied inverse), cited by the
        /// profile's durable identity ("uuid:…") — never a display name.
        case profileRow(profileIdentity: String)
        /// A FAM link in the installed GEDCOM.
        case tree
        /// A parent inherited through a sibling row Rick ATTESTED (full, or
        /// half with that shared parent named), cited by the sibling's
        /// durable identity ("uuid:…" / "fsid:…").
        case attestedSibling(viaIdentity: String)

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
        /// SHA-256 (16 hex) over the route as durable identities + hop kinds —
        /// the confirmation-ledger key for "this derivation, along this path".
        let pathHash: String

        var usesTree: Bool { provenance.contains(.tree) }
        var usesAttestation: Bool {
            provenance.contains { if case .attestedSibling = $0 { return true } else { return false } }
        }

        /// Rough footprint for the memo's byte budget.
        fileprivate var estimatedBytes: Int {
            96 + route.count * 160 + routeText.utf8.count + caveats.reduce(0) { $0 + $1.utf8.count + 16 }
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

    /// Locked instrumentation for the performance gate.
    struct Counters: Equatable, Sendable {
        var pairHits = 0
        var pairMisses = 0
        var pairComputes = 0
        var pairEvictions = 0
        var singleFlightWaits = 0
        /// Tier B bidirectional ancestor searches run.
        var ancestorSearches = 0
        /// Vertices expanded (Tier A) + ordinals examined (Tier B / isAncestor).
        var expansions = 0
        /// Adjacency lists sorted — happens at build only.
        var adjacencySorts = 0
        var cachedEntries = 0
        var cachedBytes = 0
    }

    let overlay: FamilyKinshipOverlay
    /// Tier A bound in hops. Long lineal / collateral lines are Tier B's job.
    let maxHops: Int
    /// Tier A bound in vertex expansions per query.
    let expansionBudget: Int
    /// Tier B bound in generations climbed per side.
    static let generationCap = 60

    private let treeIndex: GedcomFamilyGraph.TreeIndex?
    /// Canonical adjacency for every overlay vertex (profiles, pinned tree
    /// people, placeholders) including attested inheritance — built once.
    private let adjacency: [Node: [Hop]]
    /// Ordinals of tree vertices that carry People-tab rows or attested
    /// inheritance — the only tree vertices a row-climb can continue from.
    private let rowBearingTreeOrdinals: Set<Int32>
    /// Attestations that contradict each other (attested-full sibling rows
    /// implying > 2 parents): NOTHING is inherited for that vertex.
    private(set) var attestationProblems: [Node: String] = [:]
    private let cache = KinshipQueryCache()

    init(profiles: [POIProfile], graph: GedcomFamilyGraph? = nil, maxHops: Int = 4, expansionBudget: Int = 4_000) {
        self.init(overlay: FamilyKinshipOverlay(profiles: profiles, graph: graph),
                  maxHops: maxHops, expansionBudget: expansionBudget)
    }

    init(snapshots: [ArchivistGraphProfileSnapshot], graph: GedcomFamilyGraph? = nil,
         maxHops: Int = 4, expansionBudget: Int = 4_000) {
        self.init(overlay: FamilyKinshipOverlay(snapshots: snapshots, graph: graph),
                  maxHops: maxHops, expansionBudget: expansionBudget)
    }

    private init(overlay: FamilyKinshipOverlay, maxHops: Int, expansionBudget: Int) {
        self.overlay = overlay
        self.maxHops = maxHops
        self.expansionBudget = expansionBudget
        let index = overlay.treeGraph?.index
        self.treeIndex = index
        let built = Self.buildAdjacency(overlay: overlay, index: index)
        var rowBearing = Set<Int32>()
        for node in built.adjacency.keys {
            if case .tree(let id) = node, let index, let o = index.ordinal(of: id),
               built.adjacency[node]?.contains(where: { $0.provenance != .tree }) == true {
                rowBearing.insert(o)
            }
        }
        self.rowBearingTreeOrdinals = rowBearing
        self.attestationProblems = built.problems
        self.adjacency = built.adjacency
        cache.recordSorts(built.sorts)
    }

    // MARK: Build

    private struct Built {
        var adjacency: [Node: [Hop]]
        var problems: [Node: String]
        var sorts: Int
    }

    private static func buildAdjacency(overlay: FamilyKinshipOverlay, index: GedcomFamilyGraph.TreeIndex?) -> Built {
        var rows: [Node: [Hop]] = [:]
        for node in overlay.allNodes {
            rows[node] = rowHops(from: node, overlay: overlay)
        }
        // Attested inheritance, merged PER PARENT with what is recorded.
        var inherited: [Node: [Hop]] = [:]
        var problems: [Node: String] = [:]
        for (node, mine) in rows {
            let explicit = explicitParents(mine, node: node, index: index)
            var extra: [Hop] = []
            for sibling in mine where sibling.relation == .sibling {
                let candidates: [Node]
                switch sibling.basis {
                case .unspecified:
                    continue
                case .attestedFull:
                    candidates = explicitParents(rows[sibling.to] ?? [], node: sibling.to, index: index)
                case .attestedHalf(let shared):
                    guard let parent = overlay.node(for: shared), !overlay.isPlaceholder(parent) else { continue }
                    candidates = [parent]
                }
                let via = identity(of: sibling.to, overlay: overlay)
                for parent in candidates where parent != node && !explicit.contains(parent)
                    && !extra.contains(where: { $0.to == parent }) {
                    extra.append(Hop(relation: .parent, from: node, to: parent,
                                     provenance: .attestedSibling(viaIdentity: via)))
                }
            }
            guard !extra.isEmpty else { continue }
            if explicit.count + extra.count > 2 {
                let names = (explicit + extra.map(\.to))
                    .map { name(of: $0, overlay: overlay) }.joined(separator: ", ")
                problems[node] = "\(name(of: node, overlay: overlay))'s attested sibling rows imply more than two parents (\(names)) — nothing inherited until one is corrected"
                continue
            }
            inherited[node] = extra
        }
        var adjacency: [Node: [Hop]] = [:]
        for (node, mine) in rows {
            adjacency[node] = mine + (inherited[node] ?? [])
        }
        for (child, hops) in inherited {
            for hop in hops {
                adjacency[hop.to, default: rows[hop.to] ?? []].append(
                    Hop(relation: .child, from: hop.to, to: child, provenance: hop.provenance))
            }
        }
        // Tree links for every tree vertex we hold, then ONE canonical sort.
        var sorts = 0
        for node in adjacency.keys {
            if case .tree(let id) = node, let index, let o = index.ordinal(of: id) {
                adjacency[node, default: []] += treeHops(ordinal: o, node: node, index: index,
                                                         excluding: adjacency[node] ?? [])
            }
            adjacency[node]?.sort(by: canonicalOrder)
            sorts += 1
        }
        return Built(adjacency: adjacency, problems: problems, sorts: sorts)
    }

    /// Row-derived hops (profile rows + inverses). Duplicate legacy rows for
    /// one (relation, person) merge to the STRONGEST basis, so the answer
    /// does not depend on row order: attested beats unspecified; two
    /// different attestations keep the first and are reported by
    /// validation.
    private static func rowHops(from node: Node, overlay: FamilyKinshipOverlay) -> [Hop] {
        var out: [Hop] = []
        var position: [HopKey: Int] = [:]
        for edge in overlay.edges(from: node) where primitives.contains(edge.relation) {
            let key = HopKey(relation: edge.relation, to: edge.to)
            let hop = Hop(relation: edge.relation, from: node, to: edge.to,
                          provenance: .profileRow(profileIdentity: edge.storedOnIdentity), basis: edge.basis)
            if let i = position[key] {
                if out[i].basis == .unspecified, edge.basis != .unspecified { out[i] = hop }
            } else {
                position[key] = out.count
                out.append(hop)
            }
        }
        return out
    }

    /// Parents the data records for a vertex: row parents + (tree vertex)
    /// tree parents, deduplicated by vertex.
    private static func explicitParents(_ rows: [Hop], node: Node, index: GedcomFamilyGraph.TreeIndex?) -> [Node] {
        var out: [Node] = []
        for hop in rows where hop.relation == .parent && hop.provenance.isExplicit && !out.contains(hop.to) {
            out.append(hop.to)
        }
        if case .tree(let id) = node, let index, let o = index.ordinal(of: id) {
            for p in index.parents(of: o) {
                let parent = Node.tree(gedcomID: index.ids[Int(p)])
                if !out.contains(parent) { out.append(parent) }
            }
        }
        return out
    }

    /// Tree parents (fathers first), children, spouses of an ordinal in the
    /// index's own deterministic order — no sort, no Person copies.
    private static func treeHops(ordinal o: Int32, node: Node, index: GedcomFamilyGraph.TreeIndex,
                                 excluding existing: [Hop]) -> [Hop] {
        var out: [Hop] = []
        func add(_ relation: KinshipRelation, _ slice: ArraySlice<Int32>) {
            for p in slice {
                let to = Node.tree(gedcomID: index.ids[Int(p)])
                guard to != node,
                      !existing.contains(where: { $0.relation == relation && $0.to == to }),
                      !out.contains(where: { $0.relation == relation && $0.to == to }) else { continue }
                out.append(Hop(relation: relation, from: node, to: to, provenance: .tree))
            }
        }
        add(.parent, index.parents(of: o))
        add(.child, index.children(of: o))
        add(.spouse, index.spouses(of: o))
        return out
    }

    private static func canonicalOrder(_ lhs: Hop, _ rhs: Hop) -> Bool {
        let lk = kindRank(lhs.relation), rk = kindRank(rhs.relation)
        if lk != rk { return lk < rk }
        if lhs.provenance.isExplicit != rhs.provenance.isExplicit { return lhs.provenance.isExplicit }
        return lhs.to.identityKey < rhs.to.identityKey
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

    private struct HopKey: Hashable { let relation: KinshipRelation; let to: Node }
    static let primitives: Set<KinshipRelation> = [.parent, .child, .spouse, .sibling]

    // MARK: Node facts

    func name(of node: Node) -> String { Self.name(of: node, overlay: overlay) }

    private static func name(of node: Node, overlay: FamilyKinshipOverlay) -> String {
        if let member = overlay.member(node) { return member.name }
        if case .tree(let id) = node, let person = overlay.treeGraph?.people[id] { return person.name }
        return node.auditID
    }

    /// Durable identity of a vertex ("uuid:…" / "fsid:…"), for provenance
    /// and confirmation keys. Never a display name, never an @I pointer
    /// unless the export carries no FSIDs.
    func identity(of node: Node) -> String { Self.identity(of: node, overlay: overlay) }

    private static func identity(of node: Node, overlay: FamilyKinshipOverlay) -> String {
        if let member = overlay.member(node), !member.identity.isEmpty { return member.identity }
        if case .tree(let id) = node, let graph = overlay.treeGraph, let person = graph.people[id] {
            return FamilyKinshipOverlay.treeIdentity(person, graph: graph)
        }
        return node.auditID
    }

    func sex(of node: Node) -> PersonSex? {
        if let member = overlay.member(node), let sex = member.sex { return sex }
        if case .tree(let id) = node, let person = overlay.treeGraph?.people[id] {
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
        if case .tree(let id) = node, let years = overlay.treeGraph?.people[id]?.birthYearInterval { return .years(years) }
        return nil
    }

    // MARK: Adjacency

    /// Every primitive hop out of a vertex, canonical order. Vertices the
    /// overlay does not hold (pure tree people met during a walk) come
    /// straight from the index.
    func hops(from node: Node) -> [Hop] {
        if let held = adjacency[node] { return held }
        if case .tree(let id) = node, let treeIndex, let o = treeIndex.ordinal(of: id) {
            return Self.treeHops(ordinal: o, node: node, index: treeIndex, excluding: [])
        }
        return []
    }

    /// Parents the data actually records: profile rows + tree FAM links,
    /// deduplicated by vertex (a row to "Dad" and the tree's father are the
    /// same vertex when Dad is pinned). What validation counts.
    func explicitParents(of node: Node) -> [Node] {
        var out: [Node] = []
        for hop in hops(from: node) where hop.relation == .parent && hop.provenance.isExplicit && !out.contains(hop.to) {
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
    /// attested siblings, AND tree ancestry through pins)? Rows are walked
    /// hop by hop; a tree vertex's ancestry is one upward walk on ordinals
    /// with early exit, continuing through tree ancestors that carry rows.
    /// Nothing is materialised or sorted; a corrupt cycle terminates.
    func isAncestor(_ ancestor: Node, of node: Node) -> Bool {
        var visited: Set<Node> = [node]
        var stack: [Node] = [node]
        var visitedOrdinals = Set<Int32>()
        var target: Int32?
        if case .tree(let id) = ancestor { target = treeIndex?.ordinal(of: id) }
        while let current = stack.popLast() {
            for hop in hops(from: current) where hop.relation == .parent && hop.provenance != .tree {
                if hop.to == ancestor { return true }
                if visited.insert(hop.to).inserted { stack.append(hop.to) }
            }
            guard case .tree(let id) = current, let treeIndex, let start = treeIndex.ordinal(of: id) else { continue }
            var frontier: [Int32] = [start]
            var examined = 0
            while !frontier.isEmpty {
                var next: [Int32] = []
                for o in frontier {
                    for p in treeIndex.parents(of: o) where visitedOrdinals.insert(p).inserted {
                        examined += 1
                        if p == target { cache.recordExpansions(examined); return true }
                        if rowBearingTreeOrdinals.contains(p) {
                            let up = Node.tree(gedcomID: treeIndex.ids[Int(p)])
                            if visited.insert(up).inserted { stack.append(up) }
                        }
                        next.append(p)
                    }
                }
                frontier = next
            }
            cache.recordExpansions(examined)
        }
        return false
    }

    // MARK: Queries

    /// How `to` is related to `from`. nil when the two are the same vertex
    /// or nothing links them within reach. Memoised per ordered pair.
    func relation(from: Node, to: Node) -> Derived? {
        guard from != to else { return nil }
        return cache.result(for: KinshipQueryCache.Key(from: from, to: to)) {
            if let route = shortestRoute(from: from, to: to) { return describe(route, from: from, to: to) }
            if let route = treeRoute(from: from, to: to) { return describe(route, from: from, to: to) }
            if let honest = unattestedSiblingRoute(from: from, to: to) { return honest }
            return nil
        }
    }

    /// Everyone reachable from `node` within `maxHops` (Tier A only —
    /// the review sheet lists contemporaries, not 39k ancestors).
    func derivedRelatives(of node: Node) -> [Derived] {
        var best: [Node: [Hop]] = [:]
        var queue: [(Node, [Hop])] = [(node, [])]
        var visited: Set<Node> = [node]
        var index = 0
        while index < queue.count, index < expansionBudget {
            let (current, path) = queue[index]
            index += 1
            guard path.count < maxHops, path.isEmpty || adjacency[current] != nil else { continue }
            for hop in hops(from: current) where !visited.contains(hop.to) {
                visited.insert(hop.to)
                let next = path + [hop]
                best[hop.to] = next
                queue.append((hop.to, next))
            }
        }
        cache.recordExpansions(index)
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

    /// Locked instrumentation (see `Counters`).
    var counters: Counters { cache.counters }

    /// Forget memoised answers (the engine itself is immutable).
    func dropCaches() { cache.drop() }

    /// Tier A: breadth-first shortest chain, ≤ maxHops and ≤ expansionBudget.
    private func shortestRoute(from a: Node, to b: Node) -> [Hop]? {
        var queue: [(Node, [Hop])] = [(a, [])]
        var visited: Set<Node> = [a]
        var index = 0
        defer { cache.recordExpansions(index) }
        while index < queue.count {
            guard index < expansionBudget else { return nil }
            let (node, path) = queue[index]
            index += 1
            // Expand held vertices and the start only (see file comment).
            guard path.count < maxHops, path.isEmpty || adjacency[node] != nil else { continue }
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
        let ordinal: Int32
        let hops: [Hop]          // endpoint → … → tree vertex (all .parent)
    }

    /// Climb parent hops (blood only) from `node` until tree vertices are
    /// reached; the tree's own ancestry is the ordinal search's job.
    private func treeEntries(from node: Node) -> [Entry] {
        guard let treeIndex else { return [] }
        var out: [Entry] = []
        var queue: [(Node, [Hop])] = [(node, [])]
        var visited: Set<Node> = [node]
        var index = 0
        while index < queue.count {
            let (current, path) = queue[index]
            index += 1
            if case .tree(let id) = current, let o = treeIndex.ordinal(of: id) {
                out.append(Entry(ordinal: o, hops: path))
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

    private struct Meeting {
        let ordinal: Int32
        let upA: [Int32]   // ordinals from entry A up to (excluding) the ancestor
        let upB: [Int32]
    }

    private func treeRoute(from a: Node, to b: Node) -> [Hop]? {
        guard let treeIndex else { return nil }
        let entriesA = treeEntries(from: a)
        guard !entriesA.isEmpty else { return nil }
        let entriesB = treeEntries(from: b)
        guard !entriesB.isEmpty else { return nil }
        var best: (route: [Hop], cost: Int)?
        for ea in entriesA {
            for eb in entriesB {
                guard let meeting = nearestCommonAncestor(ea.ordinal, eb.ordinal, index: treeIndex) else { continue }
                let cost = ea.hops.count + meeting.upA.count + eb.hops.count + meeting.upB.count
                if let best, best.cost <= cost { continue }
                var route = ea.hops
                var current = ea.ordinal
                for up in meeting.upA + [meeting.ordinal] where up != current {
                    route.append(Hop(relation: .parent, from: .tree(gedcomID: treeIndex.ids[Int(current)]),
                                     to: .tree(gedcomID: treeIndex.ids[Int(up)]), provenance: .tree))
                    current = up
                }
                for down in meeting.upB.reversed() + [eb.ordinal] where down != current {
                    route.append(Hop(relation: .child, from: .tree(gedcomID: treeIndex.ids[Int(current)]),
                                     to: .tree(gedcomID: treeIndex.ids[Int(down)]), provenance: .tree))
                    current = down
                }
                for hop in eb.hops.reversed() {
                    route.append(Hop(relation: .child, from: hop.to, to: hop.from, provenance: hop.provenance))
                }
                guard !route.isEmpty, route.last?.to == b else { continue }
                best = (route, cost)
            }
        }
        return best?.route
    }

    /// Level-synchronous bidirectional search up the parent links from two
    /// ordinals; the first meeting with the smallest depth sum wins (ties
    /// by the deterministic expansion order). Explores only the ancestry
    /// up to the meeting depth. `a == b` ⇒ the trivial meeting.
    private func nearestCommonAncestor(_ a: Int32, _ b: Int32, index: GedcomFamilyGraph.TreeIndex) -> Meeting? {
        cache.recordAncestorSearch()
        if a == b { return Meeting(ordinal: a, upA: [], upB: []) }
        var seenA: [Int32: (depth: Int, via: Int32)] = [a: (0, -1)]
        var seenB: [Int32: (depth: Int, via: Int32)] = [b: (0, -1)]
        var frontierA: [Int32] = [a], frontierB: [Int32] = [b]
        var levelA = 0, levelB = 0
        var best: (ordinal: Int32, sum: Int)?
        var examined = 0
        defer { cache.recordExpansions(examined) }
        while !frontierA.isEmpty || !frontierB.isEmpty {
            if let best, best.sum <= levelA + levelB + 1 { break }
            if levelA + levelB >= Self.generationCap * 2 { break }
            let expandA = !frontierA.isEmpty && (frontierB.isEmpty || frontierA.count <= frontierB.count)
            var next: [Int32] = []
            let frontier = expandA ? frontierA : frontierB
            let level = (expandA ? levelA : levelB) + 1
            for o in frontier {
                for p in index.parents(of: o) {
                    examined += 1
                    if expandA {
                        guard seenA[p] == nil else { continue }
                        seenA[p] = (level, o)
                        if let other = seenB[p] { consider(p, level + other.depth, &best) }
                    } else {
                        guard seenB[p] == nil else { continue }
                        seenB[p] = (level, o)
                        if let other = seenA[p] { consider(p, other.depth + level, &best) }
                    }
                    next.append(p)
                }
            }
            if expandA { frontierA = next; levelA = level } else { frontierB = next; levelB = level }
        }
        guard let best else { return nil }
        func climb(_ seen: [Int32: (depth: Int, via: Int32)], from start: Int32) -> [Int32] {
            // ancestor → … → start, returned as start-side chain EXCLUDING both ends.
            var chain: [Int32] = []
            var current = best.ordinal
            while let entry = seen[current], entry.via >= 0 {
                if entry.via != start { chain.append(entry.via) }
                current = entry.via
            }
            return chain.reversed()
        }
        return Meeting(ordinal: best.ordinal, upA: climb(seenA, from: a), upB: climb(seenB, from: b))
    }

    private func consider(_ ordinal: Int32, _ sum: Int, _ best: inout (ordinal: Int32, sum: Int)?) {
        if let b = best, b.sum < sum || (b.sum == sum && b.ordinal <= ordinal) { return }
        best = (ordinal, sum)
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
                       caveats: [caveat], provenance: Set(route.map(\.provenance)), pathHash: pathHash(route))
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
                       provenance: Set(route.map(\.provenance)), pathHash: pathHash(route))
    }

    /// 16 hex chars of SHA-256 over "identity(from) >kind> identity(to)" per hop.
    func pathHash(_ route: [Hop]) -> String {
        var hasher = SHA256()
        for hop in route {
            hasher.update(data: Data((identity(of: hop.from) + " >" + hop.relation.rawValue + "> " + identity(of: hop.to) + "\n").utf8))
        }
        return hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Half only with complete evidence: an `.attestedHalf` row whose named
    /// shared parent RESOLVES, or both people having two recorded parents
    /// of which exactly one is shared. One shared parent + one unknown is
    /// NOT half — it is "full assumed", with a caveat when the word came
    /// from parent∘child rather than a row.
    private func siblingVerdict(_ a: Node, _ b: Node, route: [Hop]) -> (half: Bool, caveat: String?) {
        if route.count == 1, case .attestedHalf(let shared) = route[0].basis {
            if let parent = overlay.node(for: shared), !overlay.isPlaceholder(parent) { return (true, nil) }
            return (false, "the shared parent named on the half-sibling row could not be found — treated as unspecified")
        }
        let pa = Set(parents(of: a).map(\.node)), pb = Set(parents(of: b).map(\.node))
        if pa.count >= 2, pb.count >= 2 {
            let shared = pa.intersection(pb).count
            if shared == 0 {
                return (false, "recorded parents don't overlap (\(pa.map(name(of:)).sorted().joined(separator: " and ")) vs \(pb.map(name(of:)).sorted().joined(separator: " and "))) — check the rows")
            }
            return (shared == 1, nil)
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
}

// MARK: - Pair memo

/// Per-ordered-pair result memo. Bounded by entries and bytes (oldest
/// quarter evicted when either is exceeded); identical concurrent
/// queries are single-flight: the second waits for the first's result
/// instead of computing again. All counters live here.
private final class KinshipQueryCache: @unchecked Sendable {
    typealias Node = FamilyKinshipOverlay.Node
    typealias Derived = FamilyKinshipInference.Derived
    typealias Counters = FamilyKinshipInference.Counters
    struct Key: Hashable { let from: Node; let to: Node }
    static let entryLimit = 4_096
    static let byteBudget = 8 * 1_024 * 1_024

    private let condition = NSCondition()
    private var results: [Key: Derived?] = [:]
    private var order: [Key] = []
    private var bytes = 0
    private var inFlight = Set<Key>()
    private var stats = Counters()

    var counters: Counters {
        condition.lock(); defer { condition.unlock() }
        var c = stats
        c.cachedEntries = results.count
        c.cachedBytes = bytes
        return c
    }

    func recordSorts(_ n: Int) { condition.lock(); stats.adjacencySorts += n; condition.unlock() }
    func recordExpansions(_ n: Int) { condition.lock(); stats.expansions += n; condition.unlock() }
    func recordAncestorSearch() { condition.lock(); stats.ancestorSearches += 1; condition.unlock() }

    func drop() {
        condition.lock()
        results.removeAll(keepingCapacity: false)
        order.removeAll(keepingCapacity: false)
        bytes = 0
        condition.unlock()
    }

    func result(for key: Key, compute: () -> Derived?) -> Derived? {
        condition.lock()
        while true {
            if let hit = results[key] {
                stats.pairHits += 1
                condition.unlock()
                return hit
            }
            if inFlight.contains(key) {
                stats.singleFlightWaits += 1
                condition.wait()
                continue
            }
            break
        }
        stats.pairMisses += 1
        inFlight.insert(key)
        condition.unlock()
        let value = compute()
        condition.lock()
        stats.pairComputes += 1
        inFlight.remove(key)
        results[key] = .some(value)
        order.append(key)
        bytes += 64 + (value?.estimatedBytes ?? 0)
        if results.count > Self.entryLimit || bytes > Self.byteBudget { evictOldestQuarter() }
        condition.broadcast()
        condition.unlock()
        return value
    }

    private func evictOldestQuarter() {
        let drop = max(1, order.count / 4)
        for key in order.prefix(drop) {
            if let removed = results.removeValue(forKey: key) {
                bytes -= 64 + (removed?.estimatedBytes ?? 0)
                stats.pairEvictions += 1
            }
        }
        order.removeFirst(drop)
        if results.isEmpty { bytes = 0 }
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
