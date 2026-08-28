// FamilyKinshipOverlay.swift
// Builds a small relationship graph from every People-tab profile's typed
// `kinships` and lays it OVER the identity space Hallie already uses
// (profiles bridged to GEDCOM people where the names match). Kinship and
// relationship answers consult this overlay before / alongside the GEDCOM
// walk, because the contemporary family (Rick's brother, the four sons,
// in-laws) is deliberately absent from the FamilySearch tree
// (director decision 2026-08-27).
//
// Everything beyond the stored rows is derived here at read time:
//   • inverses      — "Tim is Rick's sibling" also answers "Rick's sibling"
//   • composition   — spouse-of-sibling = sibling-in-law, child-of-child =
//                     grandchild, sibling's child = niece/nephew, parent's
//                     sibling's child = cousin (KinshipRelation.compose)
//   • gendered word — from the related person's sex (profile or tree record)
//   • older/younger — from birthdates only; omitted when either is unknown
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

import Foundation
import OSLog
import VideoScanCore

private let kinshipLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "kinship")

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
    }

    struct Member: Sendable, Equatable {
        let node: Node
        let name: String
        let sex: PersonSex?
        let birthdate: Date?
        let profileStableID: String?
        let gedcomID: String?
        /// The bridged tree record's name when it differs from `name`
        /// ("Dad" → "Richard Harding Breen Sr"), so answers can show both.
        var treeName: String? = nil

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
    }

    /// One relative reached from an anchor with the hops that got there.
    struct Hit: Sendable, Equatable {
        let member: Member
        let hops: [Edge]
    }

    private var members: [Node: Member] = [:]
    private var outgoing: [Node: [Edge]] = [:]
    private var nodeByProfileStableID: [String: Node] = [:]
    /// Normalized spelling → profile nodes claiming it (canonical + aliases).
    private var nodesBySpelling: [String: [Node]] = [:]
    private var canonicalNodesBySpelling: [String: [Node]] = [:]
    private let graph: GedcomFamilyGraph?
    /// Non-blocking data-hygiene nudges found while building (2026-08-28,
    /// codex #772): an alias that is a relational WORD ("Dad" on Rick) is
    /// the old way of saying a relationship and collides with the profile
    /// that IS Dad. Never migrated silently — Rick edits his data — only
    /// surfaced here (and in videoscan.log) for the People-tab badge.
    private(set) var warnings: [String] = []
    /// Normalized spellings that are relational words (dad, mom, …).
    static let relationalWords: Set<String> = [
        "dad", "daddy", "mom", "mommy", "mother", "father", "grampa", "grandpa",
        "grandma", "gramma", "nana", "papa", "gran", "granny", "pop", "pops",
    ]

    var isEmpty: Bool { outgoing.isEmpty }
    var edgeCount: Int { outgoing.values.reduce(0) { $0 + $1.count } }

    // MARK: Build

    init(profiles: [POIProfile], graph: GedcomFamilyGraph? = nil) {
        self.init(snapshots: profiles.map {
            ArchivistGraphProfileSnapshot(
                stableID: $0.id, canonicalName: $0.name, aliases: $0.aliases,
                kinships: $0.kinships, sex: $0.sex, birthdate: $0.birthdate)
        }, graph: graph)
    }

    init(snapshots: [ArchivistGraphProfileSnapshot], graph: GedcomFamilyGraph? = nil) {
        self.graph = graph
        // Pass 1: one vertex per profile (bridged to the tree when the
        // canonical name or an alias is a unique, token-exact tree match —
        // the same rule the graph executor's profile route uses; no
        // diminutive pass, so "Timmy" never bridges to a tree "Tim").
        for snapshot in snapshots {
            let bridged = Self.bridge(snapshot, graph: graph)
            let node: Node = bridged.map { .tree(gedcomID: $0.id) }
                ?? .profile(stableID: snapshot.stableID)
            nodeByProfileStableID[snapshot.stableID] = node
            let sex = snapshot.sex ?? bridged.flatMap { Self.sex(of: $0) }
            let birth = snapshot.birthdate ?? bridged.flatMap { Self.birthdate(of: $0) }
            if members[node] == nil {
                members[node] = Member(
                    node: node, name: snapshot.canonicalName, sex: sex,
                    birthdate: birth, profileStableID: snapshot.stableID,
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
        }
        // Pass 2: edges + inverses. `snapshot is relation of anchor` ⇒
        // anchor → relation → snapshot, and snapshot → inverse → anchor.
        var seen = Set<Edge>()
        for snapshot in snapshots {
            guard let subject = nodeByProfileStableID[snapshot.stableID] else { continue }
            for kinship in snapshot.kinships {
                let anchor = resolveAnchor(kinship.relativeTo)
                guard anchor != subject else { continue }
                let forward = Edge(from: anchor, to: subject,
                                   relation: kinship.relation, storedOn: snapshot.canonicalName)
                let backward = Edge(from: subject, to: anchor,
                                    relation: kinship.relation.inverse, storedOn: snapshot.canonicalName)
                for edge in [forward, backward] where seen.insert(edge).inserted {
                    outgoing[edge.from, default: []].append(edge)
                }
            }
        }
    }

    /// The vertex an anchor points at, creating a placeholder member when the
    /// profile / tree person is unknown so the stored row still displays.
    private mutating func resolveAnchor(_ anchor: KinshipAnchor) -> Node {
        switch anchor {
        case .profile(let name):
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
                let node = Node.tree(gedcomID: person.id)
                if members[node] == nil {
                    members[node] = Member(node: node, name: person.name, sex: Self.sex(of: person),
                                           birthdate: Self.birthdate(of: person),
                                           profileStableID: nil, gedcomID: person.id)
                }
                return node
            }
            let node = Node.treeUnresolved(familySearchID: fsid)
            if members[node] == nil {
                members[node] = Member(node: node, name: "FamilySearch \(fsid)", sex: nil,
                                       birthdate: nil, profileStableID: nil, gedcomID: nil)
            }
            return node
        }
    }

    private static func bridge(
        _ snapshot: ArchivistGraphProfileSnapshot, graph: GedcomFamilyGraph?
    ) -> GedcomFamilyGraph.Person? {
        guard let graph else { return nil }
        // Most specific spelling first (more words, then longer) — a formal
        // "Richard Breen" alias beats the one-word canonical "Rick".
        let terms = ([snapshot.canonicalName] + snapshot.aliases)
            .enumerated()
            .sorted { lhs, rhs in
                let lw = lhs.element.split(whereSeparator: \.isWhitespace).count
                let rw = rhs.element.split(whereSeparator: \.isWhitespace).count
                if lw != rw { return lw > rw }
                if lhs.element.count != rhs.element.count { return lhs.element.count > rhs.element.count }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
        for term in terms {
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

    private static func birthdate(of person: GedcomFamilyGraph.Person) -> Date? {
        guard let year = person.birthYear else { return nil }
        var dc = DateComponents()
        dc.year = year; dc.month = 1; dc.day = 1
        dc.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: dc)
    }

    // MARK: Lookup

    func member(_ node: Node) -> Member? { members[node] }

    func node(profileStableID: String) -> Node? { nodeByProfileStableID[profileStableID] }

    /// The vertex for a tree record — the bridged profile's vertex when one
    /// exists (they are the same vertex by construction).
    func node(gedcomID: String) -> Node { .tree(gedcomID: gedcomID) }

    /// Profile vertices claiming a typed spelling. A profile whose CANONICAL
    /// name is the spelling wins outright over alias-only claimants (the
    /// Tim/Timmy cross-alias rule, 2026-08-22). Several canonical claimants
    /// remain ambiguous and return all — the caller must not guess.
    /// `ownerName` lets the owner's fuller spellings ("Rick Breen", bound
    /// from "me") reach the owner's one-word profile ("Rick").
    func nodes(claiming typed: String, ownerName: String? = nil) -> [Node] {
        let key = PersonResolver.normalize(typed)
        guard !key.isEmpty else { return [] }
        // A relational WORD claimed by several profiles ("Dad" on both Rick
        // and Dad, live 2026-08-27) is a data smell, not a nickname: report
        // every claimant (ambiguous) instead of letting the canonical one
        // win — the caller must ask, never silently pick Rick.
        if Self.relationalWords.contains(key), let any = nodesBySpelling[key], any.count > 1 { return any }
        if let exact = canonicalNodesBySpelling[key], exact.count == 1 { return exact }
        if let any = nodesBySpelling[key], !any.isEmpty { return any }
        // Owner spellings: try the owner's first token as a canonical name.
        if HallieOwnerResolver.isOwnerSpelling(typed, owner: ownerName),
           let first = FamilyIdentityText.tokens(typed).first,
           let exact = canonicalNodesBySpelling[first], exact.count == 1 {
            return exact
        }
        // A tree spelling with no profile — unique token-exact match only.
        if let graph {
            let people = graph.people(matching: typed)
            if people.count == 1 { return [.tree(gedcomID: people[0].id)] }
        }
        return []
    }

    /// Warnings mentioning this profile (for the card badge).
    func warnings(forProfileNamed name: String) -> [String] {
        warnings.filter { $0.hasSuffix(" on \(name) looks relational — use a Relationship row instead") }
    }

    /// Does this vertex have any overlay knowledge at all?
    func knows(_ node: Node) -> Bool { !(outgoing[node] ?? []).isEmpty }

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

    /// The single word for a chain, gendered by the END person's sex, with
    /// "older"/"younger" for siblings when both birthdates are known.
    func term(for hops: [Edge]) -> String? {
        guard let relation = KinshipRelation.compose(hops.map(\.relation)),
              let start = hops.first?.from, let end = hops.last?.to,
              let subject = members[end] else { return nil }
        let anchor = members[start]
        let age = KinshipDisplay.ageWord(
            relation, subjectBirth: subject.birthdate, anchorBirth: anchor?.birthdate)
        return (age.map { $0 + " " } ?? "") + relation.term(sex: subject.sex)
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
            var phrase = KinshipDisplay.phrase(
                relation: kinship.relation, anchorName: anchorName,
                subjectSex: subjectMember?.sex,
                subjectBirth: subjectMember?.birthdate, anchorBirth: anchorMember?.birthdate)
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
        case .profile(let name):
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
        }
    }

    static func fallbackName(_ anchor: KinshipAnchor) -> String {
        switch anchor {
        case .profile(let name): return name
        case .treePerson(let fsid): return "FamilySearch \(fsid.uppercased())"
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
