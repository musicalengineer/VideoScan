// ArchivistGraphExecutor+KinshipOverlay.swift
// The People-tab relationship overlay as an answer SOURCE for the two
// kinship-shaped graph operations (2026-08-27):
//   • kinship      — "who is Rick's brother?"        → overlay relatives
//   • relationship — "how is Timothy related to Rick?" → overlay path
// Consulted BEFORE the GEDCOM walk and only when the overlay actually
// knows something; otherwise the caller falls through to the tree, so
// ancestor questions are untouched. Every answer says where it came from
// ("Basis: People tab relationship …") and which profile stores the row.

import Foundation
import VideoScanCore

extension ArchivistGraphExecutor {

    static let overlayBasisPrefix = "Basis: People tab relationship"

    /// Single-anchor kinship from the overlay, or nil to fall through.
    /// `selection` (a chip choice or the owner pin) contributes its tree
    /// vertex alongside the typed spelling's profile vertex — both name the
    /// same person for THIS question, so their overlay edges are unioned.
    static func overlayKinshipResult(
        _ query: ArchivistGraphQuery,
        inputs: ArchivistGraphInputs,
        selection: ArchivistGraphSubjectSelection
    ) -> ArchivistGraphResult? {
        let overlay = inputs.kinshipOverlay
        guard !overlay.isEmpty, let relation = query.relation, query.side == nil,
              let wanted = KinshipRelation.parse(term: relation.rawValue),
              let typed = query.people.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              !typed.isEmpty else { return nil }

        var anchors: [FamilyKinshipOverlay.Node] = []
        for node in anchorNodes(typed, selection: selection, inputs: inputs) where !anchors.contains(node) {
            anchors.append(node)
        }
        // Several canonical claimants: let the normal route ask which one.
        let profileClaimants = anchors.filter { if case .profile = $0 { return true } else { return false } }
        guard !anchors.isEmpty, anchors.count <= 2, profileClaimants.count <= 1 else { return nil }

        var hits: [FamilyKinshipOverlay.Hit] = []
        var seen = Set<FamilyKinshipOverlay.Node>()
        for anchor in anchors {
            for hit in overlay.relatives(of: anchor, relation: wanted.relation, sex: wanted.sex)
            where seen.insert(hit.member.node).inserted {
                hits.append(hit)
            }
        }
        guard !hits.isEmpty else { return nil }

        let anchorMember = anchors.compactMap { overlay.member($0) }.first
        let anchorName = anchorMember?.name ?? typed
        let possessive = query.voices[0] == .owner ? "Your"
            : KinshipDisplay.possessive(anchorName)
        let noun = hits.count == 1 ? relation.rawValue : pluralNoun(relation.rawValue)
        var treeCited: [String] = []
        let names = hits.map { hit -> String in
            // One hop with a plain word: just the name. Derived (composed)
            // relations show the route so the inference is checkable.
            if hit.hops.count == 1 {
                // A relative bridged to a tree record (pin / certain
                // derivation) answers with the tree's name and vitals, and
                // the People-tab name as the alias (Rick 2026-08-29:
                // "Rick's father is known as Dad" said nothing).
                if let gedcomID = hit.member.gedcomID, let record = inputs.graph.people[gedcomID] {
                    treeCited.append("\(record.name) \(gedcomID)")
                    let alias = PersonResolver.normalize(record.name) == PersonResolver.normalize(hit.member.name)
                        ? "" : " (\(hit.member.name) in the People tab)"
                    return record.name + alias + HallieBiographyCard.vitalsAside(record)
                }
                return hit.member.displayName
            }
            return "\(hit.member.displayName) (\(overlay.route(for: hit.hops)))"
        }
        let storedOn = Array(Set(hits.flatMap { $0.hops.map(\.storedOn) })).sorted()
        let evidence = ArchivistGraphEvidence(
            subjectID: anchors[0].auditID,
            subjectName: anchorName,
            birthDate: nil, deathDate: nil,
            relationships: [],
            identityBridge: nil,
            kinshipPaths: hits.map { hit in
                .init(hops: hit.hops.map {
                    .init(label: $0.relation.term(sex: overlay.member($0.to)?.sex),
                          person: .init(id: $0.to.auditID,
                                        name: overlay.member($0.to)?.name ?? $0.to.auditID))
                })
            })
        return ArchivistGraphResult(
            conclusion: .answered,
            prose: "\(possessive) \(noun): " + names.joined(separator: ", ") + ".",
            basisLine: "\(overlayBasisPrefix) (stored on "
                + storedOn.map { "\($0)'s profile" }.joined(separator: ", ")
                + (treeCited.isEmpty
                    ? "); local only, not from the family tree."
                    : "); name and dates from the imported family tree (GEDCOM: "
                        + treeCited.joined(separator: ", ") + ")."),
            evidence: evidence,
            candidates: [], profileCandidates: [], ambiguityCandidates: [],
            catalogPersonName: nil)
    }

    /// Two-person relationship from the overlay, or nil to fall through.
    static func overlayRelationshipResult(
        _ query: ArchivistGraphQuery,
        inputs: ArchivistGraphInputs,
        subjects: [ArchivistGraphSubjectSelection]
    ) -> ArchivistGraphResult? {
        let overlay = inputs.kinshipOverlay
        guard !overlay.isEmpty, query.people.count == 2 else { return nil }
        var nodes: [FamilyKinshipOverlay.Node] = []
        for index in 0..<2 {
            let typed = query.people[index].trimmingCharacters(in: .whitespacesAndNewlines)
            let selection = subjects.indices.contains(index) ? subjects[index] : .unresolved
            let candidates = Array(Set(anchorNodes(typed, selection: selection, inputs: inputs)))
            // Ambiguity is the normal route's job (chips); we never guess.
            guard candidates.count == 1 || (candidates.count == 2
                    && candidates.contains { if case .tree = $0 { return true } else { return false } }
                    && candidates.contains { if case .profile = $0 { return true } else { return false } })
            else { return nil }
            // Prefer the vertex the overlay actually knows.
            nodes.append(candidates.first(where: { overlay.knows($0) }) ?? candidates[0])
        }
        let a = nodes[0], b = nodes[1]
        guard a != b, let hops = overlay.path(from: a, to: b), !hops.isEmpty,
              let memberA = overlay.member(a), let memberB = overlay.member(b) else { return nil }

        let voiceA = query.voices[0], voiceB = query.voices[1]
        let subjectB = voiceB == .archivist ? "I" : voiceB == .owner ? "You" : memberB.displayName
        let verb = voiceB == .archivist ? "am" : voiceB == .owner ? "are" : "is"
        let possessiveA = voiceA == .archivist ? "my" : voiceA == .owner ? "your"
            : KinshipDisplay.possessive(memberA.name)
        let route = possessiveA + " " + overlay.route(for: hops)
        let prose: String
        if let word = overlay.term(for: hops) {
            prose = hops.count == 1
                ? "\(subjectB) \(verb) \(possessiveA) \(word)."
                : "\(subjectB) \(verb) \(possessiveA) \(word) — \(route)."
        } else {
            let objectA = voiceA == .archivist ? "me" : voiceA == .owner ? "you" : memberA.name
            prose = "\(subjectB) \(verb) related to \(objectA) through \(route) — the People tab links them, but not in a way with a single name."
        }
        let storedOn = Array(Set(hops.map(\.storedOn))).sorted()
        let evidence = ArchivistGraphEvidence(
            subjectID: a.auditID, subjectName: memberA.name,
            birthDate: nil, deathDate: nil, relationships: [], identityBridge: nil,
            kinshipPaths: [.init(hops: hops.map {
                .init(label: $0.relation.term(sex: overlay.member($0.to)?.sex),
                      person: .init(id: $0.to.auditID, name: overlay.member($0.to)?.name ?? $0.to.auditID))
            })],
            counterpart: .init(id: b.auditID, name: memberB.name))
        return ArchivistGraphResult(
            conclusion: .answered,
            prose: prose,
            basisLine: "\(overlayBasisPrefix) (stored on "
                + storedOn.map { "\($0)'s profile" }.joined(separator: ", ")
                + "); path: \(memberA.name) → \(overlay.route(for: hops)); local only, not from the family tree.",
            evidence: evidence,
            candidates: [], profileCandidates: [], ambiguityCandidates: [],
            catalogPersonName: nil)
    }

    /// `pluralize` for the graph vocabulary, which already contains plural
    /// words ("children", "parents-in-law") that must not be pluralized twice.
    private static func pluralNoun(_ word: String) -> String {
        if word == "children" || word.hasSuffix("s-in-law") { return word }
        return pluralize(word)
    }

    /// Vertices a typed name may mean: the selection's tree/profile vertex
    /// plus whatever profile claims the spelling.
    private static func anchorNodes(
        _ typed: String,
        selection: ArchivistGraphSubjectSelection,
        inputs: ArchivistGraphInputs
    ) -> [FamilyKinshipOverlay.Node] {
        let overlay = inputs.kinshipOverlay
        var nodes: [FamilyKinshipOverlay.Node] = []
        switch selection {
        case .gedcomPersonID(let id):
            if inputs.graph.people[id] != nil { nodes.append(overlay.node(gedcomID: id)) }
        case .profileStableID(let id):
            if let node = overlay.node(profileStableID: id) { nodes.append(node) }
            return nodes   // an explicit profile choice is exact
        case .unresolved:
            break
        }
        nodes.append(contentsOf: overlay.nodes(claiming: typed, ownerName: inputs.ownerName))
        return nodes
    }
}
