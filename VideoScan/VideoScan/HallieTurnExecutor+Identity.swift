// HallieTurnExecutor+Identity.swift
// Identity helpers shared by the executor's routes: profile resolution for
// temporal subjects, deterministic profile ordering, chip labels for
// CyberBrain candidates, staleness checks for continuations, and the small
// value adapters. Split from HallieTurnExecutor.swift for file length; the
// behaviour is unchanged.

import Foundation
import VideoScanCore

extension HallieTurnExecutor {

    /// Chip label for a CyberBrain candidate. Same-name people (Sr./Jr.)
    /// get the linked GEDCOM birth/death detail, mirroring the graph path's
    /// disambiguation labels; without a family-tree link the stable ID is
    /// appended. Shared by the biography and kinship/birth/death routes so
    /// the two clarifications read identically.
    static func bridgedLabel(
        _ candidate: CyberBrainPerson,
        among candidates: [CyberBrainPerson],
        graph: GedcomFamilyGraph?
    ) -> String {
        let key = PersonResolver.normalize(candidate.canonicalName)
        let duplicates = candidates.filter {
            PersonResolver.normalize($0.canonicalName) == key
        }.count
        guard duplicates > 1 else { return candidate.canonicalName }
        if let gedcomID = candidate.gedcomPersonID,
           let person = graph?.people[gedcomID] {
            let detail = ArchivistBiographyPolicy
                .disambiguationCandidate(for: person).label
            // Keep the CyberBrain canonical name in front so the chip still
            // reads as the person the archive knows.
            if detail.hasPrefix(person.name), detail.count > person.name.count {
                return candidate.canonicalName
                    + String(detail.dropFirst(person.name.count))
            }
            return detail
        }
        return "\(candidate.canonicalName) (\(candidate.id))"
    }

    /// Biography-route wrapper over `bridgedLabel` for planner candidates.
    static func cyberBrainLabel(
        _ candidate: CyberBrainAnswerPlan.Candidate,
        plan: CyberBrainAnswerPlan,
        index: CyberBrainIndex,
        graph: GedcomFamilyGraph?
    ) -> String {
        let people = plan.ambiguityCandidates
            .filter { $0.source == .cyberBrain }
            .compactMap { index.person(id: $0.id) }
        guard let person = index.person(id: candidate.id) else {
            return "\(candidate.canonicalName) (\(candidate.id))"
        }
        return bridgedLabel(person, among: people, graph: graph)
    }

    static func unavailableProfilesResult(route: Route) -> Result {
        let shape = route == .temporal ? "temporal" : "aggregate"
        return Result(
            route: route,
            outcome: .declined,
            prose: "I can't answer that reliably because People profiles are unavailable.",
            basisLine: "Basis: profile evidence could not be read.",
            queryDescription: "shape=\(shape)",
            citations: [],
            catalogPersonName: nil)
    }

    static func invalidContinuationResult(
        for ast: ArchivistQueryAST
    ) -> Result {
        Result(
            route: route(ast),
            outcome: .declined,
            prose: "That identity choice is no longer available.",
            basisLine: "Basis: the clarification selection was stale or did not belong to this question.",
            queryDescription: description(of: ast),
            citations: [],
            catalogPersonName: nil)
    }

    /// Re-check the opaque identity against the new immutable capture. A chip
    /// may outlive a profile edit or GEDCOM reload; an ID whose meaning changed
    /// is stale even if the raw string still exists.
    static func selectionIsCurrent(
        _ candidate: Candidate,
        context: Context
    ) -> Bool {
        switch candidate.id {
        case .profileStableID(let stableID):
            guard let profiles = context.profiles else { return false }
            let definitions = profiles.filter { $0.stableID == stableID }
            guard let first = definitions.first,
                  definitions.allSatisfy({ sameProfileMeaning($0, first) })
            else { return false }
            return PersonResolver.normalize(
                deterministicProfile(definitions).canonicalName)
                == PersonResolver.normalize(candidate.canonicalName)

        case .gedcomPersonID(let personID):
            guard let person = context.graph?.people[personID] else {
                return false
            }
            return PersonResolver.normalize(person.name)
                == PersonResolver.normalize(candidate.canonicalName)

        case .cyberBrainPersonID(let personID):
            guard let person = context.cyberBrain?.person(id: personID) else {
                return false
            }
            return PersonResolver.normalize(person.canonicalName)
                == PersonResolver.normalize(candidate.canonicalName)
        }
    }

    static func detached<Value: Sendable>(
        _ operation: @escaping @Sendable () -> Value
    ) async throws -> Value {
        let task = Task.detached { () throws -> Value in
            try Task.checkCancellation()
            let value = operation()
            try Task.checkCancellation()
            return value
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    static func temporalResolution(
        _ requested: String,
        profiles: [ProfileSnapshot],
        selectedIdentity: CandidateID?
    ) -> ArchivistTemporalSubjectResolution {
        if let selectedIdentity {
            guard case .profileStableID(let rawID) = selectedIdentity else {
                return .missing(requested: requested)
            }
            guard !rawID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return .missing(requested: requested) }
            let definitions = profiles.filter { $0.stableID == rawID }
            guard let first = definitions.first,
                  definitions.allSatisfy({ sameProfileMeaning($0, first) }) else {
                return .missing(requested: requested)
            }
            let profile = deterministicProfile(definitions)
            return .resolved(
                requested: requested,
                subject: .init(
                    stableID: profile.stableID,
                    canonicalName: profile.canonicalName,
                    birthdate: profile.birthdate,
                    deathdate: profile.deathdate,
                    sex: profile.sex))
        }

        let key = PersonResolver.normalize(requested)
        let grouped = Dictionary(grouping: profiles, by: \.stableID)
        var matches: [ProfileSnapshot] = []
        for stableID in grouped.keys.sorted() {
            guard let definitions = grouped[stableID],
                  let first = definitions.first else { continue }
            let participates = definitions.contains(where: {
                      ([$0.canonicalName] + $0.aliases).contains {
                          PersonResolver.normalize($0) == key
                      }
                  })
            guard participates else { continue }
            guard definitions.allSatisfy({ sameProfileMeaning($0, first) })
            else { return .missing(requested: requested) }
            matches.append(deterministicProfile(definitions))
        }
        matches.sort(by: profileOrder)
        if matches.isEmpty { return .missing(requested: requested) }
        if matches.count > 1 {
            return .ambiguous(
                requested: requested,
                candidates: matches.map {
                    .init(stableID: $0.stableID,
                          canonicalName: $0.canonicalName)
                })
        }
        let profile = matches[0]
        return .resolved(
            requested: requested,
            subject: .init(
                stableID: profile.stableID,
                canonicalName: profile.canonicalName,
                birthdate: profile.birthdate,
                deathdate: profile.deathdate,
                    sex: profile.sex))
    }

    static func profileCandidates(
        _ candidates: [ArchivistTemporalSubjectResolution.Candidate]
    ) -> [Candidate] {
        let nameCounts = Dictionary(grouping: candidates) {
            PersonResolver.normalize($0.canonicalName)
        }.mapValues { $0.count }
        return candidates.sorted {
            let lhs = PersonResolver.normalize($0.canonicalName)
            let rhs = PersonResolver.normalize($1.canonicalName)
            return lhs == rhs ? $0.stableID < $1.stableID : lhs < rhs
        }.map { candidate in
            let duplicate = nameCounts[PersonResolver.normalize(
                candidate.canonicalName), default: 0] > 1
            return Candidate(
                id: .profileStableID(candidate.stableID),
                canonicalName: candidate.canonicalName,
                label: duplicate
                    ? "\(candidate.canonicalName) (\(candidate.stableID))"
                    : candidate.canonicalName)
        }
    }

    static func sameProfileMeaning(
        _ lhs: ProfileSnapshot,
        _ rhs: ProfileSnapshot
    ) -> Bool {
        PersonResolver.normalize(lhs.canonicalName)
            == PersonResolver.normalize(rhs.canonicalName)
            && Set(lhs.aliases.map { PersonResolver.normalize($0) })
                == Set(rhs.aliases.map { PersonResolver.normalize($0) })
            && lhs.birthdate == rhs.birthdate
    }

    static func deterministicProfile(
        _ definitions: [ProfileSnapshot]
    ) -> ProfileSnapshot {
        definitions.sorted(by: profileOrder)[0]
    }

    static func profileOrder(
        _ lhs: ProfileSnapshot,
        _ rhs: ProfileSnapshot
    ) -> Bool {
        let left = PersonResolver.normalize(lhs.canonicalName)
        let right = PersonResolver.normalize(rhs.canonicalName)
        if left != right { return left < right }
        if lhs.canonicalName != rhs.canonicalName {
            return lhs.canonicalName < rhs.canonicalName
        }
        return lhs.stableID < rhs.stableID
    }

    static func aggregateIdentities(
        profiles: [ProfileSnapshot]
    ) -> ArchivistAggregateIdentityCatalog {
        // Only POI-backed stable identities are admitted. Unknown confirmed
        // tag spellings remain unresolved rather than becoming identities.
        ArchivistAggregateIdentityCatalog(identities: profiles.map {
            ArchivistAggregateIdentity(
                stableID: $0.stableID,
                canonicalName: $0.canonicalName,
                aliases: $0.aliases)
        })
    }

    static func normalize(
        _ citations: [ArchivistEvidenceCitation]
    ) -> [Citation] {
        citations.map {
            Citation(
                recordID: $0.recordID,
                fullPath: $0.fullPath,
                filename: $0.filename,
                playbackSeconds: $0.playbackSeconds,
                bases: $0.bases)
        }
    }

    static func normalize(
        _ citation: ArchivistAggregateSampleCitation
    ) -> Citation {
        Citation(
            recordID: citation.recordID,
            fullPath: citation.fullPath,
            filename: citation.filename,
            playbackSeconds: citation.playbackSeconds,
            bases: citation.bases)
    }
}
