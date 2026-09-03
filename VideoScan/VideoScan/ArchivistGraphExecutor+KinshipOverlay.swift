// ArchivistGraphExecutor+KinshipOverlay.swift
// The People-tab relationship overlay as an answer SOURCE for the two
// kinship-shaped graph operations (2026-08-27):
//   • kinship      — "who is Rick's brother?"        → overlay relatives
//   • relationship — "how is Timothy related to Rick?" → overlay path
// Consulted BEFORE the GEDCOM walk and only when the overlay actually
// knows something; otherwise the caller falls through to the tree, so
// ancestor questions are untouched. Every answer says where it came from
// ("Basis: People tab relationship …") and which profile stores the row.
//
// Derived hops (2026-09-02, "full siblings share parents"): "who are
// Eileen's children" now lists Tim, Ellen and Beth from Rick's rows. The
// prose stays plain; the basis carries the marker — "derived from Rick's
// rows: full siblings share parents" — so the inference is checkable.

import Foundation
import VideoScanCore

extension ArchivistGraphExecutor {

    static let overlayBasisPrefix = "Basis: People tab relationship"

    /// "Beth", "Beth and Ellen", "Beth, Ellen and Matt" — Hallie reads
    /// aloud, so a bare comma list is wrong in the ear.
    static func englishList(_ items: [String]) -> String {
        FamilyKinshipOverlay.englishList(items)
    }

    /// "(stored on Rick's profile; Tim, Ellen and Beth derived from Rick's
    /// rows: full siblings share parents)" — the stored-on clause plus, when
    /// any hit rests on a derived hop, who was derived and by which rule.
    /// `namesByNote` groups the People-tab names under their derivation note.
    static func overlayStoredOnClause(storedOn: [String], namesByNote: [(note: String, names: [String])]) -> String {
        var clause = "(stored on " + storedOn.map { "\($0)'s profile" }.joined(separator: ", ")
        for entry in namesByNote where !entry.names.isEmpty {
            clause += "; " + englishList(entry.names) + " " + entry.note
        }
        return clause + ")"
    }

    /// " Relationship warning: Sibling rows on … imply more than two
    /// parents (…) — nothing derived until one is corrected." — one clause
    /// per conflict the question touched (codex #984 item 5: a set that
    /// failed closed must be visible from every side, Hallie included).
    static func overlayWarningClause(_ warnings: [String]) -> String {
        guard !warnings.isEmpty else { return "" }
        return " Relationship warning: " + warnings.joined(separator: " · ") + "."
    }

    /// Group hits by their derivation note, in first-seen order; hits
    /// without a derived hop are skipped.
    static func derivedNamesByNote(
        _ hits: [FamilyKinshipOverlay.Hit], overlay: FamilyKinshipOverlay
    ) -> [(note: String, names: [String])] {
        var order: [String] = []
        var names: [String: [String]] = [:]
        for hit in hits {
            guard let note = overlay.derivationNote(for: hit.hops) else { continue }
            if names[note] == nil { order.append(note) }
            names[note, default: []].append(hit.member.name)
        }
        return order.map { (note: $0, names: names[$0] ?? []) }
    }

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
        // A GENDERED question with no hits is not the same as "no such
        // relative". Since the sex filter fails closed (FamilyKinshipOverlay,
        // 2026-08-31), a sibling whose sex was never recorded is excluded
        // from both "brothers" and "sisters" — and falling through here made
        // Hallie answer "the family tree doesn't record a sister", which
        // tells Rick something false about Beth and Ellen.
        //
        // Say what is actually missing, and name the people, so the gap is
        // one edit away from closed instead of invisible.
        // Conflicts touching the anchor or anyone answered: the basis
        // carries them (nothing was derived for that set).
        let conflicts = overlay.derivationWarnings(touching: anchors + hits.map(\.member.node))
        guard !hits.isEmpty else {
            guard let wantedSex = wanted.sex else { return nil }
            var unknown: [String] = []
            var seenUnknown = Set<FamilyKinshipOverlay.Node>()
            for anchor in anchors {
                for hit in overlay.relatives(of: anchor, relation: wanted.relation, sex: nil)
                where hit.member.sex == nil && seenUnknown.insert(hit.member.node).inserted {
                    unknown.append(hit.member.displayName)
                }
            }
            guard !unknown.isEmpty else { return nil }
            _ = wantedSex
            let anchorName = anchors.compactMap { overlay.member($0) }.first?.name ?? typed
            // Only "your" is lowercased; a name keeps its capital.
            let possessive = query.voices[0] == .owner
                ? "your" : KinshipDisplay.possessive(anchorName)
            let neutral = pluralNoun(wanted.relation.term(sex: nil))
            let list = englishList(unknown)
            return ArchivistGraphResult(
                conclusion: .missingFact,
                prose: "I can't tell. \(list) \(unknown.count == 1 ? "is" : "are") "
                    + "\(possessive) \(unknown.count == 1 ? wanted.relation.term(sex: nil) : neutral), "
                    + "but I don't have a recorded sex for "
                    + "\(unknown.count == 1 ? "that person" : "them"), so I can't say "
                    + "which of \(possessive) \(neutral) are \(relation.rawValue)s. "
                    + "Recording it in the People tab would answer this.",
                basisLine: "\(overlayBasisPrefix): the relationship is stored, the sex is not."
                    + overlayWarningClause(conflicts),
                evidence: nil,
                candidates: [], profileCandidates: [], ambiguityCandidates: [],
                catalogPersonName: nil)
        }

        let anchorMember = anchors.compactMap { overlay.member($0) }.first
        let anchorName = anchorMember?.name ?? typed
        let possessive = query.voices[0] == .owner ? "Your"
            : KinshipDisplay.possessive(anchorName)
        let noun = hits.count == 1 ? relation.rawValue : pluralNoun(relation.rawValue)
        var treeCited: [String] = []
        var requiredPersonNames: [String] = []
        let names = hits.map { hit -> String in
            // One hop with a plain word: just the name. Derived (composed)
            // relations show the route so the inference is checkable.
            if hit.hops.count == 1 {
                // A stored sibling row: the pair's ONE verdict (codex #1019
                // item 2) — "Tim (half-brother)"; a conflict says so
                // instead of picking a word.
                let aside = siblingAside(hit, overlay: overlay)
                // A relative bridged to a tree record (pin / certain
                // derivation) answers with the tree's name and vitals, and
                // the People-tab name as the alias (Rick 2026-08-29:
                // "Rick's father is known as Dad" said nothing).
                if let gedcomID = hit.member.gedcomID, let record = inputs.graph.people[gedcomID] {
                    treeCited.append("\(record.name) \(gedcomID)")
                    requiredPersonNames.append(record.name)
                    let alias = PersonResolver.normalize(record.name) == PersonResolver.normalize(hit.member.name)
                        ? "" : " (\(hit.member.name) in the People tab)"
                    return record.name + alias + HallieBiographyCard.vitalsAside(record) + aside
                }
                requiredPersonNames.append(hit.member.name)
                return hit.member.displayName + aside
            }
            requiredPersonNames.append(hit.member.name)
            return "\(hit.member.displayName) (\(overlay.route(for: hit.hops)))"
        }
        let storedOn = Array(Set(hits.flatMap { $0.hops.map(\.storedOn) })).sorted()
        let derived = derivedNamesByNote(hits, overlay: overlay)
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
        let prose = "\(possessive) \(noun): " + names.joined(separator: ", ") + "."
        let plan = HallieAnswerPlan(
            route: .graph, shape: .fact,
            claims: [.init(
                id: "c1", text: prose,
                evidenceIDs: [anchors[0].auditID]
                    + hits.flatMap { $0.hops.map { $0.to.auditID } },
                requiredPersonNames: requiredPersonNames,
                requiresCoverage: true)],
            fallbackText: prose,
            subjectLifeStatus: subjectLifeStatus(
                treePerson: anchorMember?.gedcomID.flatMap { inputs.graph.people[$0] },
                profileStableID: anchorMember?.profileStableID,
                inputs: inputs))
        return ArchivistGraphResult(
            conclusion: .answered,
            prose: prose,
            basisLine: "\(overlayBasisPrefix) "
                + overlayStoredOnClause(storedOn: storedOn, namesByNote: derived)
                + (treeCited.isEmpty
                    ? "; local only, not from the family tree."
                    : "; name and dates from the imported family tree (GEDCOM: "
                        + treeCited.joined(separator: ", ") + ").")
                + overlayWarningClause(conflicts),
            evidence: evidence,
            candidates: [], profileCandidates: [], ambiguityCandidates: [],
            catalogPersonName: nil,
            answerPlan: plan,
            // The anchor's own status (LifeStatus, 2026-09-01), so the
            // composer never turns "Rick's brothers: Tim" into "Rick had a
            // brother" for a living Rick.
            subjectLifeStatus: plan.subjectLifeStatus)
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
        let derived = overlay.derivationNote(for: hops).map { [(note: $0, names: [memberB.name])] } ?? []
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
            basisLine: "\(overlayBasisPrefix) "
                + overlayStoredOnClause(storedOn: storedOn, namesByNote: derived)
                + "; path: \(memberA.name) → \(overlay.route(for: hops)); local only, not from the family tree."
                + overlayWarningClause(overlay.derivationWarnings(touching: [a, b])),
            evidence: evidence,
            candidates: [], profileCandidates: [], ambiguityCandidates: [],
            catalogPersonName: nil)
    }

    /// " (half-brother)" for a one-hop stored sibling row whose pair
    /// verdict is half; " (sibling rows disagree — full or half unknown)"
    /// for a conflict; empty for full and for every other relation.
    static func siblingAside(_ hit: FamilyKinshipOverlay.Hit, overlay: FamilyKinshipOverlay) -> String {
        guard hit.hops.count == 1, hit.hops[0].relation == .sibling, !hit.hops[0].isDerived,
              let verdict = overlay.siblingVerdict(hit.hops[0].from, hit.hops[0].to) else { return "" }
        switch verdict {
        case .full:              return ""
        case .half, .unresolved: return " (" + FamilyKinshipOverlay.siblingTerm(verdict, sex: hit.member.sex) + ")"
        case .conflict:          return " (sibling rows disagree — full or half unknown)"
        }
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
