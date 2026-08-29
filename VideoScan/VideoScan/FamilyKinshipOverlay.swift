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
//
// Bridging a profile to a tree person (design amendment 1, 2026-08-29:
// identity ≠ relationship) has two modes:
//   • `.pinsOnly`      — ONLY an explicit `treeIdentity` pin bridges; a
//                        stale pin (not in this tree) or a colliding pin
//                        (two profiles → one tree person) fails CLOSED:
//                        unbridged + a pin problem the editor shows. This
//                        is what FamilyKinshipInference uses.
//   • `.pinsThenNames` — pins first, then the historical unique-name /
//                        alias match (Hallie's existing routes; unchanged
//                        behaviour for profiles without a pin).
// `suggestedTreeMatches` exposes the name candidates for the review sheet
// as suggestions — never as graph identity.
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
import OSLog
import VideoScanCore

private let kinshipLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "kinship")

struct FamilyKinshipOverlay: Sendable {

    /// How profiles become tree vertices (see file comment).
    enum Bridging: Sendable {
        case pinsOnly
        case pinsThenNames
    }

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
        /// The bridged tree record's name when it differs from `name`
        /// ("Dad" → "Richard Harding Breen Sr"), so answers can show both.
        var treeName: String? = nil

        init(node: Node, name: String, sex: PersonSex?, birthdate: Date?,
             birthYears: GedcomYearInterval? = nil,
             profileStableID: String?, gedcomID: String?, treeName: String? = nil) {
            self.node = node
            self.name = name
            self.sex = sex
            self.birthdate = birthdate
            self.birthYears = birthYears
            self.profileStableID = profileStableID
            self.gedcomID = gedcomID
            self.treeName = treeName
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
        /// What a sibling row asserts about shared parents (both directions
        /// carry the row's basis).
        var basis: SiblingBasis = .unspecified
    }

    /// One relative reached from an anchor with the hops that got there.
    struct Hit: Sendable, Equatable {
        let member: Member
        let hops: [Edge]
    }

    private var members: [Node: Member] = [:]
    private var outgoing: [Node: [Edge]] = [:]
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
    let bridging: Bridging
    /// Non-blocking data-hygiene nudges found while building (2026-08-28,
    /// codex #772): an alias that is a relational WORD ("Dad" on Rick) is
    /// the old way of saying a relationship and collides with the profile
    /// that IS Dad. Never migrated silently — Rick edits his data — only
    /// surfaced here (and in videoscan.log) for the People-tab badge.
    private(set) var warnings: [String] = []
    /// profile stableID → why its `treeIdentity` pin did not bridge
    /// (stale or colliding). Validation turns this into an error.
    private(set) var pinProblems: [String: String] = [:]
    /// Normalized spellings that are relational words (dad, mom, …).
    static let relationalWords: Set<String> = [
        "dad", "daddy", "mom", "mommy", "mother", "father", "grampa", "grandpa",
        "grandma", "gramma", "nana", "papa", "gran", "granny", "pop", "pops",
    ]

    var isEmpty: Bool { outgoing.isEmpty }
    var edgeCount: Int { outgoing.values.reduce(0) { $0 + $1.count } }

    // MARK: Build

    init(profiles: [POIProfile], graph: GedcomFamilyGraph? = nil, bridging: Bridging = .pinsThenNames) {
        self.init(snapshots: profiles.map {
            ArchivistGraphProfileSnapshot(
                stableID: $0.id, canonicalName: $0.name, aliases: $0.aliases,
                kinships: $0.kinships, sex: $0.sex, birthdate: $0.birthdate, uuid: $0.uuid,
                treeIdentity: $0.treeIdentity)
        }, graph: graph, bridging: bridging)
    }

    init(snapshots: [ArchivistGraphProfileSnapshot], graph: GedcomFamilyGraph? = nil,
         bridging: Bridging = .pinsThenNames) {
        self.graph = graph
        self.bridging = bridging
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
        // pin resolves; otherwise (pinsThenNames only) the unique, token-
        // exact name match the graph executor's profile route also uses; no
        // diminutive pass, so "Timmy" never bridges to a tree "Tim".
        for snapshot in snapshots {
            let bridged: GedcomFamilyGraph.Person?
            if let pinned = pins[snapshot.stableID] {
                bridged = pinned
            } else if snapshot.treeIdentity == nil, bridging == .pinsThenNames {
                bridged = Self.uniqueNameMatch(snapshot, graph: graph)
            } else {
                bridged = nil
            }
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
                    gedcomID: bridged?.id, treeName: bridged?.name)
            }
            let canonicalWord = PersonResolver.normalize(snapshot.canonicalName)
            for alias in snapshot.aliases {
                let word = PersonResolver.normalize(alias)
                guard Self.relationalWords.contains(word), word != canonicalWord else { continue }
                let line = "Alias '\(alias)' on \(snapshot.canonicalName) looks relational — use a Relationship row instead"
                warnings.append(line)
                kinshipLog.warning("\(line, privacy: .public)")
            }
            for spelling in [snapshot.canonicalName] + snapshot.aliases {
                let key = PersonResolver.normalize(spelling)
                guard !key.isEmpty else { continue }
                if !(nodesBySpelling[key]?.contains(node) ?? false) {
                    nodesBySpelling[key, default: []].append(node)
                }
            }
            let canonicalKey = PersonResolver.normalize(snapshot.canonicalName)
            if !(canonicalNodesBySpelling[canonicalKey]?.contains(node) ?? false) {
                canonicalNodesBySpelling[canonicalKey, default: []].append(node)
            }
            if !(nodesByCanonicalName[snapshot.canonicalName]?.contains(node) ?? false) {
                nodesByCanonicalName[snapshot.canonicalName, default: []].append(node)
            }
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
                let forward = Edge(from: anchor, to: subject,
                                   relation: kinship.relation, storedOn: snapshot.canonicalName, basis: basis)
                let backward = Edge(from: subject, to: anchor,
                                    relation: kinship.relation.inverse, storedOn: snapshot.canonicalName, basis: basis)
                for edge in [forward, backward] where seen.insert(edge).inserted {
                    outgoing[edge.from, default: []].append(edge)
                }
            }
        }
    }

    /// Resolve every `treeIdentity` pin, failing closed: a pin the tree
    /// does not carry, or two profiles pinned to one tree person, bridge
    /// NOBODY and leave a pin problem for the editor / validation.
    private mutating func resolvePins(_ snapshots: [ArchivistGraphProfileSnapshot]) -> [String: GedcomFamilyGraph.Person] {
        var resolved: [String: GedcomFamilyGraph.Person] = [:]
        var claimants: [String: [String]] = [:]
        for snapshot in snapshots {
            guard let pin = snapshot.treeIdentity else { continue }
            let person: GedcomFamilyGraph.Person?
            switch pin {
            case .familySearchID(let fsid):
                person = graph?.person(familySearchID: fsid)
            case .pointer(let pointer, let sourceFingerprint):
                person = (sourceFingerprint == fingerprint) ? graph?.people[pointer] : nil
            }
            guard let person else {
                let why = graph == nil
                    ? "\(snapshot.canonicalName)'s family-tree pin can't be checked — no tree is installed"
                    : "\(snapshot.canonicalName)'s family-tree pin points at a person this tree doesn't carry — pin them again"
                pinProblems[snapshot.stableID] = why
                note(why)
                continue
            }
            resolved[snapshot.stableID] = person
            claimants[person.id, default: []].append(snapshot.stableID)
        }
        for (personID, ids) in claimants where ids.count > 1 {
            let names = ids.compactMap { id in snapshots.first { $0.stableID == id }?.canonicalName }.sorted()
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
                                   profileStableID: nil, gedcomID: person.id)
        }
        return node
    }

    private mutating func note(_ line: String) {
        warnings.append(line)
        kinshipLog.warning("\(line, privacy: .public)")
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

    /// The historical name bridge (`.pinsThenNames` only): the first
    /// spelling with exactly one tree match; an ambiguous spelling stops
    /// the search (never guess).
    private static func uniqueNameMatch(
        _ snapshot: ArchivistGraphProfileSnapshot, graph: GedcomFamilyGraph?
    ) -> GedcomFamilyGraph.Person? {
        guard let graph else { return nil }
        for term in spellingsMostSpecificFirst(canonicalName: snapshot.canonicalName, aliases: snapshot.aliases) {
            let matches = graph.people(matching: term)
            if matches.count == 1 { return matches[0] }
            if matches.count > 1 { return nil }   // ambiguous: never guess
        }
        return nil
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

    /// Does this vertex have any overlay knowledge at all?
    func knows(_ node: Node) -> Bool { !(outgoing[node] ?? []).isEmpty }

    /// Directed edges out of a vertex (stored rows + implied inverses), for
    /// FamilyKinshipInference / KinshipValidation. Empty for unknown vertices.
    func edges(from node: Node) -> [Edge] { outgoing[node] ?? [] }

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
            if let sex, let memberSex = member.sex, memberSex != sex { return nil }
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
            for edge in outgoing[node] ?? [] where !visited.contains(edge.to) {
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
        for edge in outgoing[node] ?? [] where !onPath.contains(edge.to) {
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
