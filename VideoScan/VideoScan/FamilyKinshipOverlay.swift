// FamilyKinshipOverlay.swift
// Builds a small relationship graph from every People-tab profile's typed
// `kinships` and lays it OVER the identity space Hallie already uses
// (profiles bridged to GEDCOM people). Kinship and relationship answers
// consult this overlay before / alongside the GEDCOM walk, because the
// contemporary family (Rick's brother, the four sons, in-laws) is
// deliberately absent from the FamilySearch tree (director decision
// 2026-08-27).
//
// Everything beyond the stored rows is derived here at read time:
//   • inverses      — "Tim is Rick's sibling" also answers "Rick's sibling"
//   • composition   — spouse-of-sibling = sibling-in-law, child-of-child =
//                     grandchild, sibling's child = niece/nephew, parent's
//                     sibling's child = cousin (KinshipChainNamer)
//   • gendered word — from the related person's sex (profile or tree record)
//   • older/younger — from birth knowledge at its native precision; omitted
//                     unless the order is provable
//   • shared parents — FULL SIBLINGS SHARE PARENTS (Rick, Director,
//                     2026-09-02: "we can do the 'children of' inference as
//                     part of Biography. No need to edit gedcom."). Rick's
//                     card says child of Ma and Dad and sibling of Tim, Ellen
//                     and Beth; their cards carry no rows. So Tim, Ellen and
//                     Beth become Ma's and Dad's children — DERIVED edges,
//                     marked as such, never stored (`deriveSharedParents`).
//                     ONE policy for every reader (codex #984): unspecified
//                     = full; half dominates for its pair; conflicts fail
//                     closed with a warning on every involved profile.
//
// Bridging a profile to a tree person (design amendment 1, 2026-08-29:
// identity ≠ relationship): ONLY an explicit `treeIdentity` pin bridges. A
// stale pin (not in this tree), an unreadable pin (written by a newer
// build) or a colliding pin (two profiles → one tree person) fails CLOSED:
// unbridged + a pin problem the editor and validation show. Name / alias
// matching is NOT identity anywhere in production; `suggestedTreeMatches`
// exposes the name candidates for the review sheet as suggestions only.
//
// Pure and injected: built from an array of profile snapshots plus an
// optional graph, so tests never touch App Support. Worst-case memory: a
// few hundred bytes per edge; 500 profiles × 5 kinships ≈ 5,000 directed
// edges ≈ well under 1 MB. Query fan-out is bounded (≤ 3 hops, ≤ 4 for the
// two-person path search) so a pathological profile set cannot explode.
//
// C++ readers: `struct` here is a value type (copied on assignment); the
// dictionaries inside are copy-on-write, so passing the overlay into a
// detached task is a cheap logical copy, not a deep clone.

import CryptoKit
import Foundation
import VideoScanCore

struct FamilyKinshipOverlay: Sendable {

    // MARK: Identity space

    /// One vertex. A profile that bridges to a tree record becomes that
    /// record's `.tree` node, so `.profile("Rick")` and `.treePerson(FSID)`
    /// anchors meet on one vertex.
    enum Node: Hashable, Sendable {
        case profile(stableID: String)
        case tree(gedcomID: String)
        /// A FamilySearch ID anchor the installed tree does not carry (or no
        /// tree is loaded). Still a vertex so the stored row is not lost.
        case treeUnresolved(familySearchID: String)

        /// Opaque, auditable id for evidence lines.
        var auditID: String {
            switch self {
            case .profile(let id):          return "profile:\(id)"
            case .tree(let id):             return id
            case .treeUnresolved(let fsid): return "fsid:\(fsid)"
            }
        }

        /// Normalized identity key for deterministic ordering.
        var identityKey: String { auditID.lowercased() }
    }

    struct Member: Sendable, Equatable {
        let node: Node
        let name: String
        let sex: PersonSex?
        /// The profile's full birthdate, when the profile carries one.
        let birthdate: Date?
        /// The tree record's birth year interval (native GEDCOM precision).
        var birthYears: GedcomYearInterval? = nil
        let profileStableID: String?
        let gedcomID: String?
        /// Durable identity for provenance / confirmation keys: "uuid:…" for a
        /// profile, "fsid:…" for a tree person (never a display name, never an
        /// @I pointer unless the export has no FSIDs — then pointer@fingerprint).
        var identity: String = ""
        /// The bridged tree record's name when it differs from `name`
        /// ("Dad" → "Richard Harding Breen Sr"), so answers can show both.
        var treeName: String? = nil

        init(node: Node, name: String, sex: PersonSex?, birthdate: Date?,
             birthYears: GedcomYearInterval? = nil,
             profileStableID: String?, gedcomID: String?, treeName: String? = nil,
             identity: String = "") {
            self.node = node
            self.name = name
            self.sex = sex
            self.birthdate = birthdate
            self.birthYears = birthYears
            self.profileStableID = profileStableID
            self.gedcomID = gedcomID
            self.treeName = treeName
            self.identity = identity
        }

        /// Birth knowledge at its native precision: a full date beats a
        /// year interval; nil when neither is known. No Jan 1 is invented.
        var birth: BirthKnowledge? {
            if let birthdate { return .date(birthdate) }
            if let birthYears { return .years(birthYears) }
            return nil
        }

        /// "Dad (Richard Harding Breen Sr)" / "Tim".
        var displayName: String {
            guard let treeName, PersonResolver.normalize(treeName) != PersonResolver.normalize(name)
            else { return name }
            return "\(name) (\(treeName))"
        }
    }

    struct Edge: Hashable, Sendable {
        let from: Node
        let to: Node
        /// `to` is `relation` of `from`  ("Rick → sibling → Tim").
        let relation: KinshipRelation
        /// Canonical name of the profile whose row produced this edge.
        let storedOn: String
        /// That profile's durable identity ("uuid:…"), for provenance.
        var storedOnIdentity: String = ""
        /// What a sibling row asserts about shared parents (both directions
        /// carry the row's basis).
        var basis: SiblingBasis = .unspecified
        /// nil for a stored row (or its implied inverse); set when the edge
        /// exists only by read-time inference (`Derivation`).
        var derivation: Derivation? = nil

        var isDerived: Bool { derivation != nil }
    }

    /// Why an edge exists when no stored row says so. One rule today
    /// (Rick, 2026-09-02); the basis prose names the rule and the profiles
    /// whose rows it rests on, so a wrong inference is one edit away.
    enum Derivation: Hashable, Sendable {
        /// A parent copied across sibling rows: `parentRowsOn` are the
        /// profiles whose stored parent rows were copied — the card the
        /// row actually sits on ("Rick", or "Ma" when Ma's card says
        /// "parent of Rick"), never the child or parent the row points at;
        /// `siblingRowsOn` the profiles whose sibling rows link the two
        /// ("Ellen", "Beth" in the transitive case), `half` when the row
        /// was attested HALF and only its named shared parent crossed.
        case siblingsShareParents(parentRowsOn: [String], siblingRowsOn: [String], half: Bool)

        /// The rule, as the basis line states it.
        var rule: String {
            switch self {
            case .siblingsShareParents(_, _, let half):
                return half ? Self.halfSiblingRule : Self.fullSiblingRule
            }
        }

        static let fullSiblingRule = "full siblings share parents"
        static let halfSiblingRule = "half siblings share the named parent"

        /// "derived from Rick's rows: full siblings share parents (sibling
        /// rows on Beth and Ellen)" — the parenthesis only when a sibling
        /// row lives on a profile other than the one the parents came from.
        var note: String {
            switch self {
            case .siblingsShareParents(let parentRowsOn, let siblingRowsOn, _):
                var text = "derived from "
                    + FamilyKinshipOverlay.englishList(parentRowsOn.map(KinshipDisplay.possessive))
                    + " rows: " + rule
                let others = siblingRowsOn.filter { !parentRowsOn.contains($0) }
                if !others.isEmpty {
                    text += " (sibling rows on " + FamilyKinshipOverlay.englishList(others) + ")"
                }
                return text
            }
        }
    }

    /// One relative reached from an anchor with the hops that got there.
    struct Hit: Sendable, Equatable {
        let member: Member
        let hops: [Edge]
    }

    private var members: [Node: Member] = [:]
    /// Stored rows + their implied inverses ONLY (`edges(from:)`). The
    /// inference engine reads these AND `derivedEdges(from:)`, so the
    /// derivation policy lives in exactly one place (codex #984).
    private var outgoing: [Node: [Edge]] = [:]
    /// Read-time derived edges (`Derivation`), kept apart so a consumer can
    /// tell a stored fact from an inference; the walks union the two.
    private var derivedOutgoing: [Node: [Edge]] = [:]
    private var nodeByProfileStableID: [String: Node] = [:]
    /// POIProfile.uuid (lowercased) → vertex, for durable `.profile(id:)` anchors.
    private var nodeByUUID: [String: Node] = [:]
    /// The ONE spelling verdict shared with every other route (codex #778):
    /// PersonResolver decides resolved / ambiguous / unknown; the overlay
    /// never applies a precedence rule of its own.
    private let resolver: PersonResolver
    /// Content fingerprint of `graph`, computed only when some row or pin
    /// uses an export-local pointer (SHA-256 over sorted id+name).
    private let fingerprint: String?
    /// Normalized spelling → profile nodes claiming it (canonical + aliases).
    private var nodesBySpelling: [String: [Node]] = [:]
    private var canonicalNodesBySpelling: [String: [Node]] = [:]
    /// VERBATIM canonical name → vertices, for PersonResolver's verdicts
    /// (which return the canonical spelling as stored). Keyed as-is, not by
    /// stableID, because a stableID may be an arbitrary slug and
    /// POIProfile.id keeps diacritics ("renée") that `normalize` folds
    /// ("renee") — codex #795 B.
    private var nodesByCanonicalName: [String: [Node]] = [:]
    private let graph: GedcomFamilyGraph?
    /// Non-blocking data-hygiene nudges found while building (2026-08-28,
    /// codex #772): an alias that is a relational WORD ("Dad" on Rick) is
    /// the old way of saying a relationship and collides with the profile
    /// that IS Dad. Never migrated silently — Rick edits his data — only
    /// surfaced here for the People-tab badge. Overlay construction is a
    /// pure operation: it never writes names or aliases to a process or
    /// persistent log. Callers may summarize warning RULES at an
    /// orchestration boundary, but the user-facing prose stays in memory.
    private(set) var warnings: [String] = []
    /// One warning per distinct condition even when duplicate profile input
    /// reaches the builder. This also prevents repeated UI badges when an
    /// overlay is reconstructed for several Hallie turns.
    private var warningKeys: Set<String> = []
    /// profile stableID → why its `treeIdentity` pin did not bridge
    /// (stale or colliding). Validation turns this into an error.
    private(set) var pinProblems: [String: String] = [:]
    /// Vertex → the derivation conflicts it is involved in (its sibling
    /// set failed closed: full-vs-half rows, > 2 parents, two mothers, a
    /// cycle). Every member of the set AND every parent they record is
    /// keyed, so the engine, the card badge and Hallie's basis can all
    /// find the same warning from any side of it.
    private(set) var derivationProblems: [Node: [String]] = [:]
    /// Warning → the profiles it involves, for `warnings(forProfileNamed:)`
    /// (derivation warnings name several people; a text filter on one
    /// prefix could not find them — codex #984 item 5).
    private var warningsByProfileName: [String: [String]] = [:]
    /// Wall time of the shared-parent derivation pass alone (the scale
    /// sensor budgets this, not the resolver / pass-1 cost of the names).
    private(set) var derivationDuration: Duration = .zero
    /// Normalized spellings that are relational words (dad, mom, …).
    static let relationalWords: Set<String> = [
        "dad", "daddy", "mom", "mommy", "mother", "father", "grampa", "grandpa",
        "grandma", "gramma", "nana", "papa", "gran", "granny", "pop", "pops",
    ]

    var isEmpty: Bool { outgoing.isEmpty }
    /// Stored rows + inverses (derived edges are counted separately).
    var edgeCount: Int { outgoing.values.reduce(0) { $0 + $1.count } }
    var derivedEdgeCount: Int { derivedOutgoing.values.reduce(0) { $0 + $1.count } }

    // MARK: Build

    init(profiles: [POIProfile], graph: GedcomFamilyGraph? = nil) {
        self.init(snapshots: profiles.map(ArchivistGraphProfileSnapshot.init(profile:)), graph: graph)
    }

    init(snapshots: [ArchivistGraphProfileSnapshot], graph: GedcomFamilyGraph? = nil) {
        self.graph = graph
        self.resolver = PersonResolver(people: snapshots.map {
            ResolvablePerson(canonicalName: $0.canonicalName, aliases: $0.aliases)
        })
        let usesPointers = snapshots.contains { snapshot in
            if case .pointer = snapshot.treeIdentity { return true }
            return snapshot.kinships.contains { if case .treePointer = $0.relativeTo { return true } else { return false } }
        }
        self.fingerprint = usesPointers ? graph.map(Self.fingerprint(of:)) : nil
        let pins = resolvePins(snapshots)
        // Pass 1: one vertex per profile — the pinned tree person when the
        // pin resolves, else the profile itself. Never a name match.
        for snapshot in snapshots {
            let bridged: GedcomFamilyGraph.Person? = pins[snapshot.stableID]
            let node: Node = bridged.map { .tree(gedcomID: $0.id) }
                ?? .profile(stableID: snapshot.stableID)
            nodeByProfileStableID[snapshot.stableID] = node
            if let uuid = snapshot.uuid { nodeByUUID[uuid.uuidString.lowercased()] = node }
            let sex = snapshot.sex ?? bridged.flatMap { Self.sex(of: $0) }
            if members[node] == nil {
                members[node] = Member(
                    node: node, name: snapshot.canonicalName, sex: sex,
                    birthdate: snapshot.birthdate,
                    birthYears: bridged?.birthYearInterval,
                    profileStableID: snapshot.stableID,
                    gedcomID: bridged?.id, treeName: bridged?.name,
                    identity: Self.identity(
                        snapshot: snapshot, bridged: bridged,
                        fingerprint: fingerprint))
            }
            registerSpellings(of: snapshot, node: node)
        }
        // Pass 2: edges + inverses. `snapshot is relation of anchor` ⇒
        // anchor → relation → snapshot, and snapshot → inverse → anchor.
        var seen = Set<Edge>()
        for snapshot in snapshots {
            guard let subject = nodeByProfileStableID[snapshot.stableID] else { continue }
            for kinship in snapshot.kinships {
                let anchor = resolveAnchor(kinship.relativeTo, storedOn: snapshot.canonicalName)
                guard anchor != subject else { continue }
                let basis = kinship.relation == .sibling ? kinship.basis : .unspecified
                let identity = members[subject]?.identity ?? Self.profileIdentity(snapshot)
                let forward = Edge(from: anchor, to: subject,
                                   relation: kinship.relation, storedOn: snapshot.canonicalName,
                                   storedOnIdentity: identity, basis: basis)
                let backward = Edge(from: subject, to: anchor,
                                    relation: kinship.relation.inverse, storedOn: snapshot.canonicalName,
                                    storedOnIdentity: identity, basis: basis)
                for edge in [forward, backward] where seen.insert(edge).inserted {
                    outgoing[edge.from, default: []].append(edge)
                }
            }
        }
        // Pass 3: parents shared across sibling rows (derived, never stored).
        // Timed on its own: the scale sensor budgets this pass, not the
        // resolver and vertex cost of 100k names.
        derivationDuration = ContinuousClock().measure { deriveSharedParents() }
    }

    /// FULL SIBLINGS SHARE PARENTS (Rick, Director, 2026-09-02). ONE policy,
    /// shared with FamilyKinshipInference, KinshipValidation, the
    /// Relationships overview and Hallie (codex #984, 2026-09-02 — before
    /// this the engine read an `.unspecified` row as a proposal while the
    /// overlay read it as full, and one data row gave two answers):
    ///   • An `.unspecified` sibling row is a FULL sibling: both parents are
    ///     shared and propagate through the whole sibling set (siblings of
    ///     siblings). Rick has never recorded a half sibling; the
    ///     vocabulary's only half form is `.attestedHalf(sharedParent:)`.
    ///   • `.attestedFull` is full, the same way.
    ///   • `.attestedHalf(sharedParent:)` shares ONLY its named parent, one
    ///     hop, and DOMINATES any unspecified / reciprocal row for the same
    ///     unordered pair — a legacy "Rick: sibling Tim" beside "Tim: half
    ///     sibling of Rick through Dad" is HALF, never full.
    ///   • Rows are coalesced per UNORDERED pair before anything is unioned.
    ///     An explicit full row against an explicit half row for one pair
    ///     CONFLICTS; a set whose stored parents add up to more than two
    ///     people, or to two of the same recorded sex (two mothers), or that
    ///     contains one of its own parents (a cycle) CONFLICTS. A conflict
    ///     FAILS CLOSED: nothing is derived for that set, and one warning is
    ///     delivered to EVERY involved profile (`warnings(forProfileNamed:)`)
    ///     and to Hallie's basis (`derivationWarnings(touching:)`). The
    ///     checks run for every set, whether or not anyone is missing a
    ///     parent — a fully recorded but contradictory set is still reported.
    ///   • Per-parent merge: a sibling with ONE stored parent receives the
    ///     set's other parent; a stored parent is never replaced.
    ///   • Every derived edge carries the SOURCE row's identity — the profile
    ///     whose parent row was copied (`storedOn` / `storedOnIdentity`) —
    ///     never the child's or the parent's own identity, so a basis line
    ///     names the card Rick would actually edit.
    ///
    /// The work is a `SharedParentDerivation` pass over a copy of the
    /// stored graph (one method per step, so each stays small enough to
    /// read); this method only applies its outputs. Cost: union-find over
    /// the sibling pairs (near-linear in the number of sibling rows), then
    /// one visit per set member. Memory: a few small dictionaries keyed by
    /// the vertices that carry a sibling row — kilobytes for Rick's People
    /// tab, ~1 MB for a 100k-profile stress fixture. `derivationDuration`
    /// times this pass alone.
    private mutating func deriveSharedParents() {
        var pass = SharedParentDerivation(host: self)
        pass.run()
        for (line, profiles) in pass.warningsInOrder { note(line, profiles: profiles) }
        derivationProblems = pass.problems
        // Stable order per vertex: parents before children, then by name.
        derivedOutgoing = pass.derived.mapValues { edges in
            edges.sorted { lhs, rhs in
                if lhs.relation != rhs.relation { return lhs.relation == .parent }
                return lhs.to.identityKey < rhs.to.identityKey
            }
        }
    }

    /// Pass 3 as a value: reads the finished stored graph (`host` — a
    /// copy-on-write copy, so no dictionary is duplicated), produces the
    /// derived edges, the per-vertex conflicts and the warnings to deliver.
    ///
    /// C++ readers: `find` is a disjoint-set (union-find) with path halving
    /// over a dictionary — the same structure you would build with a
    /// `std::unordered_map<Node, Node>`.
    private struct SharedParentDerivation {
        /// The profile a row sits on, by name and durable identity.
        struct Source: Hashable { let storedOn: String; let identity: String }
        /// One unordered sibling pair; `a` sorts before `b`.
        struct Pair: Hashable {
            let a: Node
            let b: Node
            init(_ x: Node, _ y: Node) {
                if x.identityKey <= y.identityKey { a = x; b = y } else { a = y; b = x }
            }
        }
        struct PairRows {
            var full = false            // an explicit `.attestedFull` row
            var unspecified = false     // a legacy `.unspecified` row
            var halfParents: [Node] = []
            var unresolvedHalf = false  // a half row whose parent can't be found
            var rows: [Source] = []
        }
        struct HalfPair { let pair: Pair; let parent: Node; let rows: [Source] }

        let host: FamilyKinshipOverlay

        // Working state.
        private var pairs: [Pair: PairRows] = [:]
        private var pairOrder: [Pair] = []
        private var parentLink: [Node: Node] = [:]
        private var fullRows: [Pair: [Source]] = [:]
        private var halfPairs: [HalfPair] = []
        private var validHalf: [HalfPair] = []
        private var sets: [Node: [Node]] = [:]
        private var siblingRowsOn: [Node: [String]] = [:]
        private var setParents: [Node: [Node]] = [:]
        private var setSources: [Node: [Node: [Source]]] = [:]
        private var failedRoots: Set<Node> = []
        private var failedNodes: Set<Node> = []
        private var seenDerived = Set<Edge>()

        // Outputs.
        private(set) var derived: [Node: [Edge]] = [:]
        private(set) var problems: [Node: [String]] = [:]
        private(set) var warningsInOrder: [(line: String, profiles: [String])] = []

        init(host: FamilyKinshipOverlay) { self.host = host }

        mutating func run() {
            coalescePairs()
            judgePairs()
            groupSets()
            validateSets()
            validateHalfPairs()
            deriveFullSets()
            deriveHalfPairs()
        }

        // MARK: Lookups over the stored graph

        private func name(_ node: Node) -> String { host.members[node]?.name ?? node.auditID }

        private func parentRows(of node: Node) -> [(parent: Node, source: Source)] {
            (host.outgoing[node] ?? []).filter { $0.relation == .parent }
                .map { ($0.to, Source(storedOn: $0.storedOn, identity: $0.storedOnIdentity)) }
        }

        private func explicitParents(of node: Node) -> [Node] {
            var out: [Node] = []
            for row in parentRows(of: node) where !out.contains(row.parent) { out.append(row.parent) }
            return out
        }

        private func sameKnownSex(_ a: Node, _ b: Node) -> Bool {
            guard let sa = host.members[a]?.sex, let sb = host.members[b]?.sex else { return false }
            return sa == sb
        }

        private mutating func find(_ node: Node) -> Node {
            var current = node
            while let up = parentLink[current], up != current {
                if let grand = parentLink[up] { parentLink[current] = grand }
                current = up
            }
            return current
        }

        private mutating func union(_ a: Node, _ b: Node) {
            let ra = find(a), rb = find(b)
            guard ra != rb else { return }
            // Deterministic root: the smaller identity key wins.
            if ra.identityKey < rb.identityKey { parentLink[rb] = ra } else { parentLink[ra] = rb }
        }

        // MARK: 1. Coalesce every sibling row per unordered pair

        private mutating func coalescePairs() {
            for node in host.outgoing.keys.sorted(by: { $0.identityKey < $1.identityKey }) {
                for edge in host.outgoing[node] ?? [] where edge.relation == .sibling && edge.from != edge.to {
                    let key = Pair(edge.from, edge.to)
                    if pairs[key] == nil { pairOrder.append(key) }
                    var rows = pairs[key] ?? PairRows()
                    switch edge.basis {
                    case .unspecified:  rows.unspecified = true
                    case .attestedFull: rows.full = true
                    case .attestedHalf(let shared):
                        if let parent = host.peekAnchor(shared), !host.isPlaceholder(parent) {
                            if !rows.halfParents.contains(parent) { rows.halfParents.append(parent) }
                        } else {
                            rows.unresolvedHalf = true
                        }
                    }
                    let source = Source(storedOn: edge.storedOn, identity: edge.storedOnIdentity)
                    if !rows.rows.contains(source) { rows.rows.append(source) }
                    pairs[key] = rows
                }
            }
        }

        // MARK: 2. Verdict per pair; union the FULL ones

        /// (vertices, reason) for every pair-level contradiction; their
        /// whole sibling sets fail closed once the sets are known.
        private var poisoned: [(nodes: [Node], reason: String)] = []

        private mutating func judgePairs() {
            for key in pairOrder {
                guard let rows = pairs[key] else { continue }
                let a = name(key.a), b = name(key.b)
                if rows.full, let half = rows.halfParents.first {
                    poisoned.append(([key.a, key.b], "Sibling rows between \(a) and \(b) disagree — one says full sibling, one says half sibling through \(name(half)) — nothing derived for their sibling set until one is corrected"))
                    continue
                }
                if rows.halfParents.count > 1 {
                    let names = rows.halfParents.map(name).sorted().joined(separator: ", ")
                    poisoned.append(([key.a, key.b], "Half-sibling rows between \(a) and \(b) name different shared parents (\(names)) — nothing derived for their sibling set until one is corrected"))
                    continue
                }
                if let half = rows.halfParents.first {
                    // Half dominates a reciprocal unspecified row: no union.
                    halfPairs.append(HalfPair(pair: key, parent: half, rows: rows.rows))
                    continue
                }
                if rows.unresolvedHalf {
                    // Still half (it dominates), but the named parent is gone:
                    // nothing crosses this row in either direction.
                    warningsInOrder.append((
                        "The shared parent named on the half-sibling row between \(a) and \(b) could not be found — nothing derived across that row until they are picked again",
                        [a, b]))
                    continue
                }
                // `.unspecified` and/or `.attestedFull`: FULL.
                parentLink[key.a] = parentLink[key.a] ?? key.a
                parentLink[key.b] = parentLink[key.b] ?? key.b
                union(key.a, key.b)
                fullRows[key] = rows.rows
            }
        }

        // MARK: 3. The full sets, and whose profile each sibling row sits on

        private mutating func groupSets() {
            for node in parentLink.keys { sets[find(node), default: []].append(node) }
            for (pair, rows) in fullRows {
                let root = find(pair.a)
                for source in rows where !(siblingRowsOn[root]?.contains(source.storedOn) ?? false) {
                    siblingRowsOn[root, default: []].append(source.storedOn)
                }
            }
            // A half pair whose two people ALSO meet through full rows (Rick ~
            // Ellen ~ Tim, with Rick / Tim half) contradicts itself.
            for entry in halfPairs
            where parentLink[entry.pair.a] != nil && parentLink[entry.pair.b] != nil
                && find(entry.pair.a) == find(entry.pair.b) {
                poisoned.append(([entry.pair.a, entry.pair.b], "\(name(entry.pair.a)) and \(name(entry.pair.b)) are recorded as half siblings through \(name(entry.parent)), but full-sibling rows link them through other siblings — nothing derived for that sibling set until one is corrected"))
            }
            for entry in poisoned { fail(entry.nodes, reason: entry.reason) }
        }

        /// Fail closed: the vertices named, everyone in their sets, and the
        /// parents those people record all hear about it. Set-backed
        /// membership and one expansion per root: a 500-member ring
        /// (FamilyKinshipTests' scale fixture) fails in microseconds.
        private mutating func fail(_ nodes: [Node], reason: String) {
            var involved: [Node] = []
            var seen = Set<Node>()
            func add(_ node: Node) { if seen.insert(node).inserted { involved.append(node) } }
            nodes.forEach(add)
            var expanded = Set<Node>()
            for node in nodes where parentLink[node] != nil {
                let root = find(node)
                failedRoots.insert(root)
                guard expanded.insert(root).inserted else { continue }
                (sets[root] ?? []).forEach(add)
            }
            // `for … in involved` walks a snapshot (value semantics), so the
            // parents added here are not themselves expanded.
            for node in involved { explicitParents(of: node).forEach(add) }
            for node in involved {
                failedNodes.insert(node)
                if !(problems[node]?.contains(reason) ?? false) { problems[node, default: []].append(reason) }
            }
            warningsInOrder.append((reason, involved.map(name)))
        }

        // MARK: 4. Validate every set independently of who is missing a parent

        private mutating func validateSets() {
            for root in sets.keys.sorted(by: { $0.identityKey < $1.identityKey }) {
                let siblings = (sets[root] ?? []).sorted { $0.identityKey < $1.identityKey }
                guard siblings.count > 1 else { continue }
                let siblingSet = Set(siblings)
                var parents: [Node] = []
                var parentSet = Set<Node>()
                var sources: [Node: [Source]] = [:]
                for sibling in siblings {
                    for (parent, source) in parentRows(of: sibling) {
                        if parentSet.insert(parent).inserted { parents.append(parent) }
                        if !(sources[parent]?.contains(source) ?? false) { sources[parent, default: []].append(source) }
                    }
                }
                if let reason = setConflict(siblings: siblings, siblingSet: siblingSet, parents: parents) {
                    fail(siblings + parents, reason: reason)
                    continue
                }
                setParents[root] = parents
                setSources[root] = sources
            }
        }

        /// The one reason a set cannot derive, or nil when it can.
        private func setConflict(siblings: [Node], siblingSet: Set<Node>, parents: [Node]) -> String? {
            let who = FamilyKinshipOverlay.englishList(siblings.map(name).sorted())
            let names = parents.map(name).sorted().joined(separator: ", ")
            if let cyclic = parents.first(where: { siblingSet.contains($0) }) {
                return "\(name(cyclic)) is recorded both as a sibling and as a parent among \(who) — a person can't be their own sibling's parent; nothing derived until one row is corrected"
            }
            if parents.count > 2 {
                return "Sibling rows on \(who) imply more than two parents (\(names)) — nothing derived until one is corrected"
            }
            if parents.count == 2, sameKnownSex(parents[0], parents[1]) {
                let role = host.members[parents[0]]?.sex == .female ? "mothers" : "fathers"
                return "Sibling rows on \(who) imply two \(role) (\(names)) — nothing derived until one is corrected"
            }
            return nil
        }

        /// Half pairs against what the two people already have (rows plus
        /// their own full set): the named parent must fit as a second parent.
        private mutating func validateHalfPairs() {
            for entry in halfPairs {
                let (pair, parent) = (entry.pair, entry.parent)
                guard !failedNodes.contains(pair.a), !failedNodes.contains(pair.b) else { continue }
                if parent == pair.a || parent == pair.b {
                    fail([pair.a, pair.b], reason: "The half-sibling row between \(name(pair.a)) and \(name(pair.b)) names \(name(parent)) as the shared parent — a person can't be their own sibling's parent; nothing derived until it is corrected")
                    continue
                }
                if halfFits(entry) { validHalf.append(entry) }
            }
        }

        /// Does the named parent fit both people (≤ 2 parents, no second
        /// parent of the same sex)? Fails the trio closed when not.
        private mutating func halfFits(_ entry: HalfPair) -> Bool {
            for (person, other) in [(entry.pair.a, entry.pair.b), (entry.pair.b, entry.pair.a)] {
                var mine = explicitParents(of: person)
                if parentLink[person] != nil {
                    for p in setParents[find(person)] ?? [] where !mine.contains(p) { mine.append(p) }
                }
                guard !mine.contains(entry.parent) else { continue }
                if mine.count >= 2 || mine.contains(where: { sameKnownSex($0, entry.parent) }) {
                    let list = FamilyKinshipOverlay.englishList(mine.map(name).sorted())
                    fail([person, other, entry.parent], reason: "\(name(person))'s half-sibling row to \(name(other)) names \(name(entry.parent)) as a shared parent, but \(name(person))'s parents are already \(list) — nothing derived until one is corrected")
                    return false
                }
            }
            return true
        }

        // MARK: 5. Derive, per parent, for every set and half pair that stands

        private mutating func deriveFullSets() {
            for root in setParents.keys.sorted(by: { $0.identityKey < $1.identityKey }) {
                guard !failedRoots.contains(root), let parents = setParents[root], !parents.isEmpty,
                      let sources = setSources[root] else { continue }
                let siblings = (sets[root] ?? []).sorted { $0.identityKey < $1.identityKey }
                let siblingRows = (siblingRowsOn[root] ?? []).sorted()
                for sibling in siblings {
                    let mine = explicitParents(of: sibling)
                    for parent in parents.sorted(by: { $0.identityKey < $1.identityKey }) where !mine.contains(parent) {
                        let from = sources[parent] ?? []
                        addDerived(child: sibling, parent: parent, sources: from,
                                   derivation: .siblingsShareParents(
                                    parentRowsOn: Self.rowsOn(from), siblingRowsOn: siblingRows, half: false))
                    }
                }
            }
        }

        private mutating func deriveHalfPairs() {
            for entry in validHalf where !failedNodes.contains(entry.pair.a) && !failedNodes.contains(entry.pair.b) {
                for (person, other) in [(entry.pair.a, entry.pair.b), (entry.pair.b, entry.pair.a)] {
                    guard !explicitParents(of: person).contains(entry.parent) else { continue }
                    // The parent rows that name this parent on the other
                    // sibling; failing those, the half row itself is the source.
                    let named = parentRows(of: other).filter { $0.parent == entry.parent }.map(\.source)
                    let from = named.isEmpty ? entry.rows : named
                    addDerived(child: person, parent: entry.parent, sources: from,
                               derivation: .siblingsShareParents(
                                parentRowsOn: Self.rowsOn(from), siblingRowsOn: Self.rowsOn(entry.rows), half: true))
                }
            }
        }

        private mutating func addDerived(child: Node, parent: Node, sources: [Source], derivation: Derivation) {
            guard child != parent else { return }   // never P child-of P
            if host.outgoing[child]?.contains(where: { $0.relation == .parent && $0.to == parent }) ?? false { return }
            // Cite the source row's profile — the card Rick would edit.
            let cite = sources.min { $0.storedOn < $1.storedOn } ?? Source(storedOn: "", identity: "")
            let up = Edge(from: child, to: parent, relation: .parent, storedOn: cite.storedOn,
                          storedOnIdentity: cite.identity, basis: .unspecified, derivation: derivation)
            let down = Edge(from: parent, to: child, relation: .child, storedOn: cite.storedOn,
                            storedOnIdentity: cite.identity, basis: .unspecified, derivation: derivation)
            for edge in [up, down] where seenDerived.insert(edge).inserted {
                derived[edge.from, default: []].append(edge)
            }
        }

        private static func rowsOn(_ sources: [Source]) -> [String] { Array(Set(sources.map(\.storedOn))).sorted() }
    }

    /// "Beth", "Beth and Ellen", "Beth, Ellen and Matt".
    static func englishList(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + " and " + (items.last ?? "")
        }
    }

    /// Spelling → vertex maps for PersonResolver verdicts, plus the
    /// relational-alias hygiene nudge (codex #772).
    private mutating func registerSpellings(of snapshot: ArchivistGraphProfileSnapshot, node: Node) {
        let canonicalWord = PersonResolver.normalize(snapshot.canonicalName)
        for alias in snapshot.aliases {
            let word = PersonResolver.normalize(alias)
            guard Self.relationalWords.contains(word), word != canonicalWord else { continue }
            note("Alias '\(alias)' on \(snapshot.canonicalName) looks relational — use a Relationship row instead")
        }
        for spelling in [snapshot.canonicalName] + snapshot.aliases {
            let key = PersonResolver.normalize(spelling)
            guard !key.isEmpty else { continue }
            if !(nodesBySpelling[key]?.contains(node) ?? false) {
                nodesBySpelling[key, default: []].append(node)
            }
        }
        if !(canonicalNodesBySpelling[canonicalWord]?.contains(node) ?? false) {
            canonicalNodesBySpelling[canonicalWord, default: []].append(node)
        }
        if !(nodesByCanonicalName[snapshot.canonicalName]?.contains(node) ?? false) {
            nodesByCanonicalName[snapshot.canonicalName, default: []].append(node)
        }
    }

    /// Resolve every `treeIdentity` pin, failing closed: a pin the tree
    /// does not carry, or two profiles pinned to one tree person, bridge
    /// NOBODY and leave a pin problem for the editor / validation.
    private struct PinDefinition: Hashable {
        let identity: TreeIdentity?
        let unreadable: Bool
    }

    private mutating func resolvePins(_ snapshots: [ArchivistGraphProfileSnapshot]) -> [String: GedcomFamilyGraph.Person] {
        var resolved: [String: GedcomFamilyGraph.Person] = [:]
        var claimants: [String: Set<String>] = [:]
        let definitionsByStableID = Dictionary(
            grouping: snapshots, by: \.stableID)
        for stableID in definitionsByStableID.keys.sorted() {
            guard let definitions = definitionsByStableID[stableID] else { continue }
            let displayName = definitions.map(\.canonicalName).sorted().first ?? stableID
            let meanings = Set(definitions.map {
                PinDefinition(
                    identity: $0.treeIdentity,
                    unreadable: $0.treeIdentityUnreadable)
            })
            guard meanings.count == 1, let meaning = meanings.first else {
                let why = "\(displayName)'s duplicate profile definitions disagree about the family-tree pin — pin the profile again"
                pinProblems[stableID] = why
                note(why)
                continue
            }
            if meaning.unreadable {
                let why = "\(displayName)'s family-tree pin could not be read (written by a newer app version?) — kept as is, not used"
                pinProblems[stableID] = why
                note(why)
                continue
            }
            guard let pin = meaning.identity else { continue }
            let person: GedcomFamilyGraph.Person?
            switch pin {
            case .familySearchID(let fsid):
                person = graph?.person(familySearchID: fsid)
            case .pointer(let pointer, let sourceFingerprint):
                person = (sourceFingerprint == fingerprint) ? graph?.people[pointer] : nil
            }
            guard let person else {
                let why = graph == nil
                    ? "\(displayName)'s family-tree pin can't be checked — no tree is installed"
                    : "\(displayName)'s family-tree pin points at a person this tree doesn't carry — pin them again"
                pinProblems[stableID] = why
                note(why)
                continue
            }
            resolved[stableID] = person
            claimants[person.id, default: []].insert(stableID)
        }
        for (personID, ids) in claimants where ids.count > 1 {
            let names = ids.compactMap { id in
                definitionsByStableID[id]?.map(\.canonicalName).sorted().first
            }.sorted()
            let treeName = graph?.people[personID]?.name ?? personID
            let why = "\(names.joined(separator: " and ")) are both pinned to \(treeName) in the family tree — only one profile can be that person"
            for id in ids {
                resolved[id] = nil
                pinProblems[id] = why
            }
            note(why)
        }
        return resolved
    }

    /// The vertex an anchor points at, creating a placeholder member when the
    /// profile / tree person is unknown so the stored row is not lost.
    private mutating func resolveAnchor(_ anchor: KinshipAnchor, storedOn: String) -> Node {
        switch anchor {
        case .profile(let id):
            if let node = nodeByUUID[id.uuidString.lowercased()] { return node }
            let node = Node.profile(stableID: "uuid:" + id.uuidString.lowercased())
            if members[node] == nil {
                members[node] = Member(node: node, name: "a removed profile", sex: nil, birthdate: nil,
                                       profileStableID: nil, gedcomID: nil)
                note("Relationship row on \(storedOn) points at a profile that no longer exists — remove or re-pick it")
            }
            return node
        case .profileName(let name):
            let key = PersonResolver.normalize(name)
            if let node = nodeByProfileStableID[key] { return node }
            if let node = canonicalNodesBySpelling[key]?.first { return node }
            let node = Node.profile(stableID: key)
            if members[node] == nil {
                members[node] = Member(node: node, name: name, sex: nil, birthdate: nil,
                                       profileStableID: key, gedcomID: nil)
            }
            return node
        case .treePerson(let familySearchID):
            let fsid = familySearchID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if let person = graph?.person(familySearchID: fsid) {
                return treeNode(for: person)
            }
            let node = Node.treeUnresolved(familySearchID: fsid)
            if members[node] == nil {
                members[node] = Member(node: node, name: "FamilySearch \(fsid)", sex: nil,
                                       birthdate: nil, profileStableID: nil, gedcomID: nil)
            }
            return node
        case .treePointer(let pointer, let sourceFingerprint):
            if let graph, sourceFingerprint == fingerprint, let person = graph.people[pointer] {
                return treeNode(for: person)
            }
            // The export this pointer came from is not the installed tree:
            // keep the row, name it honestly, and say so.
            let node = Node.treeUnresolved(familySearchID: "pointer:" + pointer)
            if members[node] == nil {
                members[node] = Member(node: node, name: "tree person \(pointer) (export changed)", sex: nil,
                                       birthdate: nil, profileStableID: nil, gedcomID: nil)
                note("Relationship row on \(storedOn) points at \(pointer) in an older tree export — pick them again")
            }
            return node
        }
    }

    private mutating func treeNode(for person: GedcomFamilyGraph.Person) -> Node {
        let node = Node.tree(gedcomID: person.id)
        if members[node] == nil {
            members[node] = Member(node: node, name: person.name, sex: Self.sex(of: person),
                                   birthdate: nil, birthYears: person.birthYearInterval,
                                   profileStableID: nil, gedcomID: person.id,
                                   identity: Self.treeIdentity(
                                    person, fingerprint: fingerprint))
        }
        return node
    }

    private mutating func note(_ line: String) {
        guard warningKeys.insert(line).inserted else { return }
        warnings.append(line)
    }

    /// A warning that involves several profiles by name: each of them
    /// finds it through `warnings(forProfileNamed:)`.
    private mutating func note(_ line: String, profiles: [String]) {
        note(line)
        for name in profiles where !(warningsByProfileName[name]?.contains(line) ?? false) {
            warningsByProfileName[name, default: []].append(line)
        }
    }

    /// Stable content fingerprint of a tree: SHA-256 over every person's
    /// pointer + name in pointer order (16 hex chars). Same export content ⇒
    /// same fingerprint, so `.treePointer` anchors survive a re-copy of the
    /// identical file but go stale on any different export.
    static func fingerprint(of graph: GedcomFamilyGraph) -> String {
        var hasher = SHA256()
        for id in graph.people.keys.sorted() {
            hasher.update(data: Data((id + "\t" + (graph.people[id]?.name ?? "") + "\n").utf8))
        }
        return hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// "uuid:<uuid>" — or "profile:<stableID>" for snapshots without one.
    static func profileIdentity(_ snapshot: ArchivistGraphProfileSnapshot) -> String {
        snapshot.uuid.map { "uuid:" + $0.uuidString.lowercased() } ?? "profile:" + snapshot.stableID
    }

    /// "fsid:<FamilySearch ID>", or pointer@fingerprint for exports without.
    static func treeIdentity(_ person: GedcomFamilyGraph.Person, graph: GedcomFamilyGraph?) -> String {
        if let fsid = person.familySearchID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !fsid.isEmpty {
            return "fsid:" + fsid.uppercased()
        }
        return treeIdentity(person, fingerprint: graph.map(fingerprint(of:)))
    }

    /// Variant for an overlay that has already paid for the export
    /// fingerprint. Pointer-pinned profiles must never re-hash the complete
    /// tree once per profile.
    private static func treeIdentity(
        _ person: GedcomFamilyGraph.Person,
        fingerprint: String?
    ) -> String {
        if let fsid = person.familySearchID?.trimmingCharacters(in: .whitespacesAndNewlines), !fsid.isEmpty {
            return "fsid:" + fsid.uppercased()
        }
        return "tree-pointer:" + person.id + "@" + (fingerprint ?? "")
    }

    private static func identity(snapshot: ArchivistGraphProfileSnapshot, bridged: GedcomFamilyGraph.Person?,
                                 fingerprint: String?) -> String {
        bridged.map { treeIdentity($0, fingerprint: fingerprint) }
            ?? profileIdentity(snapshot)
    }

    /// Tree people whose name matches the profile's canonical name or an
    /// alias — most specific spelling first — as REVIEW SUGGESTIONS for a
    /// pin. Never used as graph identity by the inference engine.
    static func suggestedTreeMatches(canonicalName: String, aliases: [String],
                                     graph: GedcomFamilyGraph?) -> [GedcomFamilyGraph.Person] {
        guard let graph else { return [] }
        var out: [GedcomFamilyGraph.Person] = []
        for term in Self.spellingsMostSpecificFirst(canonicalName: canonicalName, aliases: aliases) {
            for person in graph.people(matching: term) where !out.contains(person) {
                out.append(person)
            }
        }
        return out
    }

    /// Most specific spelling first (more words, then longer) — a formal
    /// "Richard Breen" alias beats the one-word canonical "Rick".
    private static func spellingsMostSpecificFirst(canonicalName: String, aliases: [String]) -> [String] {
        ([canonicalName] + aliases)
            .enumerated()
            .sorted { lhs, rhs in
                let lw = lhs.element.split(whereSeparator: \.isWhitespace).count
                let rw = rhs.element.split(whereSeparator: \.isWhitespace).count
                if lw != rw { return lw > rw }
                if lhs.element.count != rhs.element.count { return lhs.element.count > rhs.element.count }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private static func sex(of person: GedcomFamilyGraph.Person) -> PersonSex? {
        switch person.sex.uppercased() {
        case "M": return .male
        case "F": return .female
        default:  return nil
        }
    }

    // MARK: Lookup

    func member(_ node: Node) -> Member? { members[node] }

    func node(profileStableID: String) -> Node? { nodeByProfileStableID[profileStableID] }

    /// The vertex for a tree record — the bridged profile's vertex when one
    /// exists (they are the same vertex by construction).
    func node(gedcomID: String) -> Node { .tree(gedcomID: gedcomID) }

    /// Why a profile's tree pin did not bridge, nil when it did (or none).
    func pinProblem(forProfileStableID stableID: String) -> String? { pinProblems[stableID] }

    /// Vertices a typed spelling may mean, by PersonResolver's verdict —
    /// the same verdict the presence/aggregate routes get, so "Dad" claimed
    /// by both Rick (alias) and Dad (canonical) is AMBIGUOUS here too, never
    /// silently one of them. `ownerName` lets the owner's fuller spellings
    /// ("Rick Breen", bound from "me") reach the owner's one-word profile.
    /// A spelling no profile knows falls back to a unique tree match.
    func nodes(claiming typed: String, ownerName: String? = nil) -> [Node] {
        switch resolver.resolve(typed) {
        case .resolved(let canonical):
            return nodes(canonicalName: canonical)
        case .ambiguous(let candidates):
            return candidates.flatMap(nodes(canonicalName:))
        case .unknown:
            break
        }
        if HallieOwnerResolver.isOwnerSpelling(typed, owner: ownerName),
           let first = FamilyIdentityText.tokens(typed).first,
           case .resolved(let canonical) = resolver.resolve(first) {
            return nodes(canonicalName: canonical)
        }
        if let graph {
            let people = graph.people(matching: typed)
            if people.count == 1 { return [.tree(gedcomID: people[0].id)] }
        }
        return []
    }

    /// The vertices behind a resolver verdict: the verbatim canonical
    /// spelling first (exact), then the normalized canonical (a resolver
    /// built from the same profiles always hits the first; the second is
    /// defence against a caller passing a re-cased name).
    private func nodes(canonicalName canonical: String) -> [Node] {
        if let exact = nodesByCanonicalName[canonical] { return exact }
        return canonicalNodesBySpelling[PersonResolver.normalize(canonical)] ?? []
    }

    /// Warnings involving this profile (for the card badge): the hygiene
    /// and pin lines that name it, plus every derivation conflict its
    /// sibling set or parent rows are part of — in `warnings` order.
    func warnings(forProfileNamed name: String) -> [String] {
        let involved = warningsByProfileName[name] ?? []
        return warnings.filter {
            $0.hasSuffix(" on \(name) looks relational — use a Relationship row instead")
                || $0.hasPrefix("Relationship row on \(name) points at ")
                || $0.hasPrefix("\(name)'s family-tree pin")
                || ($0.contains(" are both pinned to ") && ($0.hasPrefix("\(name) and ") || $0.contains(" and \(name) are both")))
                || involved.contains($0)
        }
    }

    /// The derivation conflicts any of these vertices is involved in, in
    /// `warnings` order and without repeats — for Hallie's basis line when
    /// a question touches a sibling set that failed closed.
    func derivationWarnings(touching nodes: [Node]) -> [String] {
        var lines = Set<String>()
        for node in nodes { for line in derivationProblems[node] ?? [] { lines.insert(line) } }
        return warnings.filter(lines.contains)
    }

    /// Does this vertex have any overlay knowledge at all (stored or derived)?
    func knows(_ node: Node) -> Bool { !allEdges(from: node).isEmpty }

    /// Directed edges out of a vertex — stored rows + implied inverses
    /// ONLY (what validation counts as "recorded"). Empty for unknown
    /// vertices. Derived edges: `derivedEdges(from:)`.
    func edges(from node: Node) -> [Edge] { outgoing[node] ?? [] }

    /// Edges that exist only by read-time inference (`Derivation`) — the
    /// ONE derivation policy, consumed by the inference engine as well.
    func derivedEdges(from node: Node) -> [Edge] { derivedOutgoing[node] ?? [] }

    /// Stored first, then derived — the order the walks visit them, so an
    /// explicit hop always wins a tie on chain length.
    private func allEdges(from node: Node) -> [Edge] {
        guard let derived = derivedOutgoing[node] else { return outgoing[node] ?? [] }
        return (outgoing[node] ?? []) + derived
    }

    /// The inference behind the derived hops in `hops`, as basis prose
    /// ("derived from Rick's rows: full siblings share parents"); nil when
    /// every hop is a stored row. Distinct derivations joined with "; ".
    func derivationNote(for hops: [Edge]) -> String? {
        Self.derivationNote(for: hops.compactMap(\.derivation))
    }

    static func derivationNote(for derivations: [Derivation]) -> String? {
        var seen = Set<Derivation>()
        let notes = derivations.filter { seen.insert($0).inserted }.map(\.note)
        return notes.isEmpty ? nil : notes.joined(separator: "; ")
    }

    /// The installed tree this overlay was built against, so the inference
    /// engine walks the SAME graph the vertices were bridged to.
    var treeGraph: GedcomFamilyGraph? { graph }

    /// Every vertex the overlay knows (profiles, bridged tree people,
    /// placeholders for dangling anchors).
    var allNodes: [Node] { Array(members.keys) }

    /// The vertex a stored anchor points at, without creating placeholders
    /// (read-only view for validation of a not-yet-saved row).
    func node(for anchor: KinshipAnchor) -> Node? { peekAnchor(anchor) }

    /// True for the placeholder vertices a dangling row leaves behind
    /// ("a removed profile", an FSID the tree lacks, a stale pointer).
    func isPlaceholder(_ node: Node) -> Bool {
        switch node {
        case .treeUnresolved: return true
        case .tree: return false
        case .profile: return members[node]?.profileStableID == nil
        }
    }

    // MARK: Queries

    /// Every relative reachable from `anchor` whose hop chain folds to
    /// `relation`, optionally narrowed by the word's implied sex (a relative
    /// with UNKNOWN sex is kept — hiding a brother because his profile has
    /// no sex set would be a silent miss). Shortest chain per relative;
    /// stable name order.
    func relatives(of anchor: Node, relation: KinshipRelation, sex: PersonSex? = nil) -> [Hit] {
        var best: [Node: [Edge]] = [:]
        walk(from: anchor, path: [], maxHops: 3) { path in
            guard let end = path.last?.to, end != anchor,
                  KinshipRelation.compose(path.map(\.relation)) == relation else { return }
            if let existing = best[end], existing.count <= path.count { return }
            best[end] = path
        }
        return best.compactMap { node, hops -> Hit? in
            guard let member = members[node] else { return nil }
            // FAIL CLOSED on an unrecorded sex (Rick, 2026-08-31: "Rick's
            // brothers: Beth, Ellen, Matt, Tim, Timmy"). The old form was
            // `let memberSex = member.sex, memberSex != sex`, whose second
            // binding quietly let a profile with NO recorded sex satisfy
            // every gendered relation — so Rick's sisters were offered as
            // his brothers.
            //
            // Deliberately the opposite choice from the Verify window's era
            // filter, which shows undated findings under every era. There,
            // hiding a finding hides fixable work and showing one costs a
            // glance. Here, including an unknown-sex person states something
            // false about a named member of the family, to the one reader
            // who knows for certain that it is false.
            if let sex, member.sex != sex { return nil }
            return Hit(member: member, hops: hops)
        }
        .sorted { lhs, rhs in
            if lhs.hops.count != rhs.hops.count { return lhs.hops.count < rhs.hops.count }
            return PersonResolver.normalize(lhs.member.name) < PersonResolver.normalize(rhs.member.name)
        }
    }

    /// Shortest overlay chain from `a` to `b` (≤ 4 hops), nil when none.
    func path(from a: Node, to b: Node) -> [Edge]? {
        guard a != b else { return [] }
        var queue: [(Node, [Edge])] = [(a, [])]
        var visited: Set<Node> = [a]
        var index = 0
        while index < queue.count {
            let (node, path) = queue[index]
            index += 1
            guard path.count < 4 else { continue }
            for edge in allEdges(from: node) where !visited.contains(edge.to) {
                let next = path + [edge]
                if edge.to == b { return next }
                visited.insert(edge.to)
                queue.append((edge.to, next))
            }
        }
        return nil
    }

    private func walk(from node: Node, path: [Edge], maxHops: Int, visit: ([Edge]) -> Void) {
        guard path.count < maxHops else { return }
        let onPath = Set(path.map(\.to)).union([path.first?.from ?? node])
        for edge in allEdges(from: node) where !onPath.contains(edge.to) {
            let next = path + [edge]
            visit(next)
            walk(from: edge.to, path: next, maxHops: maxHops, visit: visit)
        }
    }

    // MARK: Description (derived, never stored)

    /// One composer for the whole app (design §2): the fold table plus the
    /// lineal / collateral shapes live in `KinshipChainNamer`, so "great-
    /// grandmother" reads the same here, in Hallie, and in the review sheet.
    /// "older"/"younger" only for siblings and only when provable at the
    /// available date precision.
    func term(for hops: [Edge]) -> String? {
        guard let named = KinshipChainNamer.name(hops.map(\.relation)),
              let start = hops.first?.from, let end = hops.last?.to,
              let subject = members[end] else { return nil }
        let age = named.isSibling
            ? BirthKnowledge.ageWord(subject: subject.birth, anchor: members[start]?.birth)
            : nil
        return named.term(sex: subject.sex, age: age)
    }

    /// "brother Tim → wife Sue" — every hop named, so a wrong stored row is
    /// visible in the answer instead of laundered into a bare word.
    func route(for hops: [Edge]) -> String {
        hops.map { edge in
            let name = members[edge.to]?.name ?? edge.to.auditID
            let word = edge.relation.term(sex: members[edge.to]?.sex)
            return "\(word) \(name)"
        }.joined(separator: " → ")
    }

    /// "Rick's younger brother; Donna's brother-in-law" — one phrase per
    /// stored row on the profile, plus (when `defaultAnchor` is given and no
    /// stored row already names it) the derived relation to that anchor in
    /// parentheses, e.g. "Matt's wife (Rick's daughter-in-law)". nil when the
    /// profile has no relationships.
    func relationshipsLine(forProfileStableID stableID: String,
                           kinships: [Kinship],
                           defaultAnchor: Node? = nil) -> String? {
        guard let subject = nodeByProfileStableID[stableID], !kinships.isEmpty else { return nil }
        var phrases: [String] = []
        var namedAnchors: Set<Node> = []
        for kinship in kinships {
            // Read-only view: resolve the anchor without mutating.
            let anchorNode = peekAnchor(kinship.relativeTo)
            let anchorName = anchorNode.flatMap { members[$0]?.name } ?? Self.fallbackName(kinship.relativeTo)
            let subjectMember = members[subject]
            let anchorMember = anchorNode.flatMap { members[$0] }
            let age = kinship.relation.supportsAgeOrder
                ? BirthKnowledge.ageWord(subject: subjectMember?.birth, anchor: anchorMember?.birth)
                : nil
            var phrase = KinshipDisplay.phrase(
                relation: kinship.relation, anchorName: anchorName,
                subjectSex: subjectMember?.sex, ageWord: age)
            if let note = kinship.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                phrase += " (\(note))"
            }
            phrases.append(phrase)
            if let anchorNode { namedAnchors.insert(anchorNode) }
        }
        if let defaultAnchor, defaultAnchor != subject, !namedAnchors.contains(defaultAnchor),
           let hops = path(from: defaultAnchor, to: subject), !hops.isEmpty,
           let word = term(for: hops), let anchorName = members[defaultAnchor]?.name,
           var last = phrases.popLast() {
            last += " (\(KinshipDisplay.possessive(anchorName)) \(word))"
            phrases.append(last)
        }
        return phrases.joined(separator: "; ")
    }

    private func peekAnchor(_ anchor: KinshipAnchor) -> Node? {
        switch anchor {
        case .profile(let id):
            let key = id.uuidString.lowercased()
            if let node = nodeByUUID[key] { return node }
            let placeholder = Node.profile(stableID: "uuid:" + key)
            return members[placeholder] != nil ? placeholder : nil
        case .profileName(let name):
            let key = PersonResolver.normalize(name)
            if let node = nodeByProfileStableID[key] { return node }
            if let node = canonicalNodesBySpelling[key]?.first { return node }
            let placeholder = Node.profile(stableID: key)
            return members[placeholder] != nil ? placeholder : nil
        case .treePerson(let fsid):
            let key = fsid.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if let person = graph?.person(familySearchID: key) { return .tree(gedcomID: person.id) }
            let placeholder = Node.treeUnresolved(familySearchID: key)
            return members[placeholder] != nil ? placeholder : nil
        case .treePointer(let pointer, let sourceFingerprint):
            if let graph, sourceFingerprint == fingerprint, graph.people[pointer] != nil {
                return .tree(gedcomID: pointer)
            }
            let placeholder = Node.treeUnresolved(familySearchID: "pointer:" + pointer)
            return members[placeholder] != nil ? placeholder : nil
        }
    }

    static func fallbackName(_ anchor: KinshipAnchor) -> String {
        switch anchor {
        case .profile: return "a removed profile"
        case .profileName(let name): return name
        case .treePerson(let fsid): return "FamilySearch \(fsid.uppercased())"
        case .treePointer(let pointer, _): return "tree person \(pointer) (export changed)"
        }
    }

    /// The default anchor for display: the pinned owner (FamilySearch ID or
    /// owner name) when that resolves to a vertex, else the first profile.
    func defaultAnchor(ownerName: String?, ownerFamilySearchID: String?,
                       firstProfileStableID: String?) -> Node? {
        if let fsid = ownerFamilySearchID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !fsid.isEmpty, let person = graph?.person(familySearchID: fsid) {
            let node = Node.tree(gedcomID: person.id)
            if members[node] != nil { return node }
        }
        if let ownerName {
            let claimed = nodes(claiming: ownerName, ownerName: ownerName)
            if claimed.count == 1 { return claimed[0] }
            if let first = FamilyIdentityText.tokens(ownerName).first {
                let byFirst = nodes(claiming: first, ownerName: ownerName)
                if byFirst.count == 1 { return byFirst[0] }
            }
        }
        return firstProfileStableID.flatMap { nodeByProfileStableID[$0] }
    }
}
