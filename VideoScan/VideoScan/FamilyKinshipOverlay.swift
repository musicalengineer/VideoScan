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
        /// profiles whose stored parent rows were copied ("Rick"),
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
    /// Stored rows + their implied inverses ONLY. The inference engine and
    /// KinshipValidation read this (`edges(from:)`) and keep their own,
    /// stricter policy for unattested sibling rows (codex #830).
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
        deriveSharedParents()
    }

    /// FULL SIBLINGS SHARE PARENTS (Rick, Director, 2026-09-02). If P has
    /// stored parent rows and S is P's sibling, S is a child of those
    /// parents — transitively over the sibling set (siblings of siblings),
    /// as one pass over the sibling graph, never a stored row.
    ///
    /// Assumptions, stated once here and in every basis line:
    ///   • A sibling row with basis `.unspecified` or `.attestedFull` is
    ///     read as FULL (Rick has never recorded a half sibling; the
    ///     vocabulary's only half form is `.attestedHalf(sharedParent:)`).
    ///   • An `.attestedHalf` row shares ONLY its named parent, one hop —
    ///     it never joins the full-sibling set and nothing crosses it
    ///     transitively.
    ///   • A sibling with ANY stored parent row of its own keeps exactly
    ///     those parents: nothing is added, so a stored contradiction is
    ///     never papered over (conservative by design; the engine's
    ///     attested path merges per parent — this one does not).
    ///   • A sibling set whose stored parents add up to more than two
    ///     people is a data error; nothing is derived for it and a
    ///     warning names the problem.
    ///
    /// Cost: union-find over the sibling edges (near-linear in the number
    /// of sibling rows), then one visit per set member. Memory: one small
    /// dictionary per vertex that carries a sibling row.
    ///
    /// C++ readers: the nested `find` is a disjoint-set (union-find) with
    /// path halving over a dictionary — the same structure you would build
    /// with a `std::unordered_map<Node, Node>`.
    private mutating func deriveSharedParents() {
        var parentLink: [Node: Node] = [:]
        func find(_ node: Node) -> Node {
            var current = node
            while let up = parentLink[current], up != current {
                if let grand = parentLink[up] { parentLink[current] = grand }
                current = up
            }
            return current
        }
        func union(_ a: Node, _ b: Node) {
            let ra = find(a), rb = find(b)
            guard ra != rb else { return }
            // Deterministic root: the smaller identity key wins.
            if ra.identityKey < rb.identityKey { parentLink[rb] = ra } else { parentLink[ra] = rb }
        }
        var halfEdges: [Edge] = []
        var siblingRowsOn: [Node: Set<String>] = [:]
        for node in outgoing.keys.sorted(by: { $0.identityKey < $1.identityKey }) {
            for edge in outgoing[node] ?? [] where edge.relation == .sibling {
                switch edge.basis {
                case .unspecified, .attestedFull:
                    parentLink[edge.from] = parentLink[edge.from] ?? edge.from
                    parentLink[edge.to] = parentLink[edge.to] ?? edge.to
                    union(edge.from, edge.to)
                case .attestedHalf:
                    halfEdges.append(edge)
                }
            }
        }
        func explicitParents(of node: Node) -> [Node] {
            var out: [Node] = []
            for edge in outgoing[node] ?? [] where edge.relation == .parent && !out.contains(edge.to) {
                out.append(edge.to)
            }
            return out
        }
        // Group the full-sibling sets by root; remember whose profile each
        // sibling row sits on so the basis can cite it.
        var sets: [Node: [Node]] = [:]
        for node in parentLink.keys {
            sets[find(node), default: []].append(node)
        }
        for node in parentLink.keys {
            for edge in outgoing[node] ?? [] where edge.relation == .sibling {
                if case .attestedHalf = edge.basis { continue }
                siblingRowsOn[find(node), default: []].insert(edge.storedOn)
            }
        }
        var seenDerived = Set<Edge>()
        func addDerived(child: Node, parent: Node, storedOn: String, derivation: Derivation) {
            // Never duplicate a stored row or an earlier derivation.
            if outgoing[child]?.contains(where: { $0.relation == .parent && $0.to == parent }) ?? false { return }
            let identity = members[parent]?.identity ?? ""
            let up = Edge(from: child, to: parent, relation: .parent, storedOn: storedOn,
                          storedOnIdentity: identity, basis: .unspecified, derivation: derivation)
            let down = Edge(from: parent, to: child, relation: .child, storedOn: storedOn,
                            storedOnIdentity: identity, basis: .unspecified, derivation: derivation)
            for edge in [up, down] where seenDerived.insert(edge).inserted {
                derivedOutgoing[edge.from, default: []].append(edge)
            }
        }
        for root in sets.keys.sorted(by: { $0.identityKey < $1.identityKey }) {
            let siblings = (sets[root] ?? []).sorted { $0.identityKey < $1.identityKey }
            guard siblings.count > 1 else { continue }
            // parent vertex → the profiles whose stored rows name it.
            var sources: [Node: [String]] = [:]
            var orphans: [Node] = []
            for sibling in siblings {
                let parents = explicitParents(of: sibling)
                if parents.isEmpty { orphans.append(sibling); continue }
                let name = members[sibling]?.name ?? sibling.auditID
                for parent in parents where !(sources[parent]?.contains(name) ?? false) {
                    sources[parent, default: []].append(name)
                }
            }
            guard !sources.isEmpty, !orphans.isEmpty else { continue }
            if sources.count > 2 {
                let names = sources.keys.map { members[$0]?.name ?? $0.auditID }.sorted()
                let who = siblings.map { members[$0]?.name ?? $0.auditID }.sorted()
                note("Sibling rows on \(Self.englishList(who)) imply more than two parents (\(names.joined(separator: ", "))) — nothing derived until one is corrected")
                continue
            }
            let rowsOn = (siblingRowsOn[root] ?? []).sorted()
            for orphan in orphans {
                for parent in sources.keys.sorted(by: { $0.identityKey < $1.identityKey }) {
                    let from = (sources[parent] ?? []).sorted()
                    addDerived(child: orphan, parent: parent, storedOn: from[0],
                               derivation: .siblingsShareParents(
                                parentRowsOn: from, siblingRowsOn: rowsOn, half: false))
                }
            }
        }
        // Half rows: only the named shared parent, only across this one row.
        for edge in halfEdges {
            guard case .attestedHalf(let shared) = edge.basis, let parent = peekAnchor(shared),
                  explicitParents(of: edge.to).isEmpty,
                  explicitParents(of: edge.from).contains(parent) else { continue }
            let from = members[edge.from]?.name ?? edge.from.auditID
            addDerived(child: edge.to, parent: parent, storedOn: from,
                       derivation: .siblingsShareParents(
                        parentRowsOn: [from], siblingRowsOn: [edge.storedOn], half: true))
        }
        // Stable order per vertex: parents before children, then by name.
        for node in derivedOutgoing.keys {
            derivedOutgoing[node]?.sort { lhs, rhs in
                if lhs.relation != rhs.relation { return lhs.relation == .parent }
                return lhs.to.identityKey < rhs.to.identityKey
            }
        }
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

    /// Warnings mentioning this profile (for the card badge).
    func warnings(forProfileNamed name: String) -> [String] {
        warnings.filter {
            $0.hasSuffix(" on \(name) looks relational — use a Relationship row instead")
                || $0.hasPrefix("Relationship row on \(name) points at ")
                || $0.hasPrefix("\(name)'s family-tree pin")
                || ($0.contains(" are both pinned to ") && ($0.hasPrefix("\(name) and ") || $0.contains(" and \(name) are both")))
        }
    }

    /// Does this vertex have any overlay knowledge at all (stored or derived)?
    func knows(_ node: Node) -> Bool { !allEdges(from: node).isEmpty }

    /// Directed edges out of a vertex — stored rows + implied inverses
    /// ONLY, for FamilyKinshipInference / KinshipValidation, which apply
    /// their own policy to unattested sibling rows. Empty for unknown
    /// vertices. Derived edges: `derivedEdges(from:)`.
    func edges(from node: Node) -> [Edge] { outgoing[node] ?? [] }

    /// Edges that exist only by read-time inference (`Derivation`).
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
