// ArchivistGraphExecutor+Relationship.swift
// "How is A related to B?" — the two-person graph operation.
//
// Rick (Hallie log 2026-08-18): "how am I related to you?" failed because
// the graph vocabulary only knew person + relation → people. This route
// resolves BOTH names through the same identity path as every other graph
// operation, asks VideoScanCore for the shortest GEDCOM path, and composes
// the answer in Hallie's voice: "I'm your great-grandmother — your father's
// mother's mother." The route with GEDCOM ids goes in the basis line so a
// wrong tree link is visible instead of laundered into a bare word.

import Foundation
import VideoScanCore

extension ArchivistGraphExecutor {

    /// Resolve `people[0]` and `people[1]` and describe the path between
    /// them. `subjects` are per-slot selections from a continuation;
    /// `floatingSelection` (the single-selection API) is applied to the
    /// first slot that is ambiguous when unresolved. Results about one slot
    /// carry `subjectIndex` so callers can pin the right chip.
    static func executeRelationship(
        _ query: ArchivistGraphQuery,
        inputs: ArchivistGraphInputs,
        subjects: [ArchivistGraphSubjectSelection],
        floatingSelection: ArchivistGraphSubjectSelection = .unresolved
    ) -> ArchivistGraphResult {
        guard query.relation == nil, query.side == nil, query.surname == nil else {
            return decline(
                .unexpectedRelation,
                prose: "A relationship question names two people and nothing else.",
                basis: queryValidationBasis)
        }
        guard query.people.count == 2 else {
            return decline(
                .unsupportedPeopleCount(query.people.count),
                prose: "A relationship question needs exactly two people.",
                basis: queryValidationBasis)
        }
        let names = query.people.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard names.allSatisfy({ !$0.isEmpty }) else {
            return decline(
                .invalidPerson,
                prose: "A relationship question needs both people's names.",
                basis: queryValidationBasis)
        }

        var floating = floatingSelection
        var resolved: [(
            GedcomFamilyGraph.Person,
            ArchivistGraphEvidence.IdentityBridge?,
            String?
        )] = []
        for index in 0..<2 {
            var selection = subjects.indices.contains(index) ? subjects[index] : .unresolved
            var outcome = resolveSubject(names[index], selection: selection,
                                         inputs: inputs, query: query)
            if case .result(let result) = outcome,
               !result.ambiguityCandidates.isEmpty,
               floating != .unresolved {
                // The one selection we were handed belongs to the first
                // ambiguous slot; consume it and try again with it.
                selection = floating
                floating = .unresolved
                outcome = resolveSubject(names[index], selection: selection,
                                         inputs: inputs, query: query)
            }
            switch outcome {
            case .result(let result):
                return result.taggingSubject(index)
            case .person(let person, let bridge, let correction):
                resolved.append((person, bridge, correction))
            }
        }
        var result = describeRelationship(
            from: resolved[0].0, to: resolved[1].0,
            bridges: [resolved[0].1, resolved[1].1],
            voices: query.voices, graph: inputs.graph)
        for item in resolved {
            result = applyingSpellingCorrection(
                item.2, canonicalName: item.0.name, to: result)
        }
        return result
    }

    /// Compose the answer for two resolved people. Pure: same tree, same
    /// words. `voices` turns "Rick Breen" into "you" and the archivist into
    /// "I" when the caller bound pronouns.
    static func describeRelationship(
        from a: GedcomFamilyGraph.Person,
        to b: GedcomFamilyGraph.Person,
        bridges: [ArchivistGraphEvidence.IdentityBridge?],
        voices: [Int: ArchivistGraphQuery.Voice],
        graph: GedcomFamilyGraph
    ) -> ArchivistGraphResult {
        let voiceA = voices[0]
        let voiceB = voices[1]
        let basisPrefix = relationshipBasis(bridges)

        if a.id == b.id {
            let who = voiceA == .owner ? "you" : voiceA == .archivist ? "me" : a.name
            let same = voiceB == .owner ? "you" : voiceB == .archivist ? "me" : b.name
            return ArchivistGraphResult(
                conclusion: .missingFact,
                prose: "Those are the same person in the family tree — \(who) and \(same) both resolve to \(a.name) (\(a.id)).",
                basisLine: basisPrefix + "both names resolved to GEDCOM \(a.id).",
                evidence: ArchivistGraphEvidence(
                    subjectID: a.id, subjectName: a.name, birthDate: nil,
                    deathDate: nil, relationships: [], identityBridge: bridges[0],
                    counterpart: .init(id: b.id, name: b.name)),
                candidates: [], profileCandidates: [], ambiguityCandidates: [],
                catalogPersonName: nil)
        }

        guard let path = graph.relationshipPath(from: a, to: b) else {
            let aPhrase = objectPhrase(a, voice: voiceA)
            let bPhrase = objectPhrase(b, voice: voiceB)
            return ArchivistGraphResult(
                conclusion: .missingFact,
                prose: "I couldn't find a family-tree link between \(aPhrase) and \(bPhrase) in the GEDCOM I have — no chain of parents, children, or marriages joins them within \(GedcomFamilyGraph.relationshipSearchDepthLimit) steps.",
                basisLine: basisPrefix + "searched parent/child/spouse links from \(a.name) (\(a.id)) to \(b.name) (\(b.id)); no path found.",
                evidence: ArchivistGraphEvidence(
                    subjectID: a.id, subjectName: a.name, birthDate: nil,
                    deathDate: nil, relationships: [], identityBridge: bridges[0],
                    counterpart: .init(id: b.id, name: b.name)),
                candidates: [], profileCandidates: [], ambiguityCandidates: [],
                catalogPersonName: nil,
                familyTreeFocus: .person(name: a.name))
        }

        let described = graph.describe(path)
        let subjectB = subjectPhrase(b, voice: voiceB)     // "I" / "You" / "Hallie May McGill"
        let verb = voiceB == .archivist ? "am" : voiceB == .owner ? "are" : "is"
        let possessiveA = possessivePhrase(a, voice: voiceA)  // "your" / "my" / "Donna Breen's"
        let route = possessiveA + " " + described.route
        let prose: String
        if let relation = described.relation {
            prose = path.hopCount == 1
                ? "\(subjectB) \(verb) \(possessiveA) \(relation)."
                : "\(subjectB) \(verb) \(possessiveA) \(relation) — \(route)."
        } else {
            let objectA = objectPhrase(a, voice: voiceA)
            let linked = (voiceA == .owner || voiceB == .owner) ? "you two" : "them"
            prose = "\(subjectB) \(verb) related to \(objectA) through \(route) — the family tree links \(linked), but not in a way with a single name."
        }
        let evidence = ArchivistGraphEvidence(
            subjectID: a.id, subjectName: a.name, birthDate: nil, deathDate: nil,
            relationships: [], identityBridge: bridges[0],
            kinshipPaths: [.init(hops: path.steps.map {
                .init(label: $0.noun, person: .init(id: $0.person.id, name: $0.person.name))
            })],
            counterpart: .init(id: b.id, name: b.name))
        return ArchivistGraphResult(
            conclusion: .answered,
            prose: prose,
            basisLine: basisPrefix + "path (GEDCOM): " + path.auditTrail + ".",
            evidence: evidence,
            candidates: [], profileCandidates: [], ambiguityCandidates: [],
            catalogPersonName: nil,
            familyTreeFocus: .person(name: a.name))
    }

    // MARK: - Voice helpers

    /// Sentence subject: the archivist speaks of herself as "I", of the
    /// owner as "You"; anyone else by name.
    private static func subjectPhrase(
        _ person: GedcomFamilyGraph.Person,
        voice: ArchivistGraphQuery.Voice?
    ) -> String {
        switch voice {
        case .archivist?: return "I"
        case .owner?: return "You"
        case nil: return person.name
        }
    }

    private static func objectPhrase(
        _ person: GedcomFamilyGraph.Person,
        voice: ArchivistGraphQuery.Voice?
    ) -> String {
        switch voice {
        case .archivist?: return "me"
        case .owner?: return "you"
        case nil: return person.name
        }
    }

    private static func possessivePhrase(
        _ person: GedcomFamilyGraph.Person,
        voice: ArchivistGraphQuery.Voice?
    ) -> String {
        switch voice {
        case .archivist?: return "my"
        case .owner?: return "your"
        case nil: return person.name.hasSuffix("s") ? person.name + "'" : person.name + "'s"
        }
    }

    /// "Basis: family facts from imported family tree (GEDCOM); " with any
    /// profile identity bridges spelled out first, mirroring the single-
    /// subject routes.
    private static func relationshipBasis(
        _ bridges: [ArchivistGraphEvidence.IdentityBridge?]
    ) -> String {
        var parts: [String] = []
        for bridge in bridges.compactMap({ $0 }) {
            parts.append("People profile identity bridge “\(bridge.requestedName)” → “\(bridge.profileCanonicalName)” → GEDCOM “\(bridge.effectiveGEDCOMName)”")
        }
        parts.append("family facts from imported family tree (GEDCOM)")
        return "Basis: " + parts.joined(separator: "; ") + "; "
    }
}
