import Foundation

extension ArchivistGraphExecutor {
    /// Outcome of resolving ONE typed name: the unique GEDCOM person (with
    /// the profile bridge, if any), or the complete result to return as-is
    /// (ambiguity chips, not-found, profile conflict, surname roll-up).
    enum SubjectResolution {
        /// `profileStableID`: the People-tab profile the typed name went
        /// through (pin or name route), so the person card can add that
        /// profile's relationship rows. Nil for a direct tree lookup.
        case person(GedcomFamilyGraph.Person,
                    identityBridge: ArchivistGraphEvidence.IdentityBridge?,
                    spellingCorrection: String?,
                    profileStableID: String?)
        case result(ArchivistGraphResult)
    }

    /// Identity resolution shared by every graph operation, including the
    /// two-person `relationship` (which calls it once per slot). Same
    /// specificity rules as before; nothing about the answer is decided here.
    static func resolveSubject(
        _ typedName: String,
        selection: ArchivistGraphSubjectSelection,
        inputs: ArchivistGraphInputs,
        query: ArchivistGraphQuery
    ) -> SubjectResolution {
        switch resolve(typedName, selection: selection, inputs: inputs) {
        case .profileAmbiguous(let profiles):
            let nameCounts = Dictionary(grouping: profiles) {
                normalize($0.canonicalName)
            }.mapValues { $0.count }
            return .result(ArchivistGraphResult(
                conclusion: .profileAmbiguous,
                // The question has to carry the choice: chips exist only
                // in the UI, and voice / CLI / eval see the sentence alone
                // (2026-09-03). A shared name is separated by birth year.
                prose: HallieProfileWhichOne.prose(
                    typed: typedName,
                    choices: profiles.map {
                        .init(name: $0.canonicalName,
                              birthdate: $0.birthdate,
                              fallbackDetail: $0.stableID)
                    }),
                basisLine: "Checked: People profiles.",
                evidence: nil,
                candidates: [],
                profileCandidates: Array(Set(profiles.map(\.canonicalName)))
                    .sorted(by: nameOrder),
                ambiguityCandidates: profiles.map { profile in
                    let duplicate = nameCounts[
                        normalize(profile.canonicalName), default: 0] > 1
                    return ArchivistGraphAmbiguityCandidate(
                        id: .profileStableID(profile.stableID),
                        canonicalName: profile.canonicalName,
                        label: duplicate
                            ? "\(profile.canonicalName) (\(profile.stableID))"
                            : profile.canonicalName)
                },
                catalogPersonName: nil))

        case .profileConflict(let stableID):
            return .result(decline(
                .conflictingProfileStableID(stableID),
                prose: "The People profiles contain conflicting definitions for one identity.",
                basis: "Checked: People profiles; the family tree was not consulted."))

        case .people(let people, let profileRoute, let correction):
            guard people.count == 1 else {
                // A surname typed as a person ("the breens", "breens") for a
                // family-tree request is a roll-up, not an unknown person.
                if query.operation == .familyTree, people.isEmpty,
                   let summary = ArchivistFamilyTreePolicy.summary(
                       surname: typedName, in: inputs.graph) {
                    return .result(familyTreeSurnameResult(summary))
                }
                let answer = policyUnresolved(
                    typedName: typedName, candidates: people,
                    query: query, graph: inputs.graph)
                return .result(fromPolicy(
                    answer, evidence: nil, identityBridge: nil,
                    unresolvedProfileRoute: profileRoute))
            }
            let bridge = identityBridge(
                profileRoute, effectivePerson: people[0])
            return .person(
                people[0], identityBridge: bridge,
                spellingCorrection: correction,
                profileStableID: profileRoute?.profileStableID)
        }
    }

    private static func policyUnresolved(
        typedName: String,
        candidates: [GedcomFamilyGraph.Person],
        query: ArchivistGraphQuery,
        graph: GedcomFamilyGraph
    ) -> ArchivistBiographyAnswer {
        switch query.operation {
        case .birth:
            return ArchivistBiographyPolicy.lifeDate(
                for: typedName, birth: true,
                candidates: candidates, in: graph)
        case .death:
            return ArchivistBiographyPolicy.lifeDate(
                for: typedName, birth: false,
                candidates: candidates, in: graph)
        case .birthPlace:
            return ArchivistBiographyPolicy.lifePlace(
                for: typedName, birth: true,
                candidates: candidates, in: graph)
        case .deathPlace:
            return ArchivistBiographyPolicy.lifePlace(
                for: typedName, birth: false,
                candidates: candidates, in: graph)
        case .biography, .kinship, .familyTree, .relationship:
            // BiographyPolicy owns the canonical fail-closed not-found and
            // ambiguity wording; no relationship is evaluated until unique.
            return ArchivistBiographyPolicy.biography(
                for: typedName, candidates: candidates, in: graph)
        }
    }

    enum Resolution {
        case people(
            [GedcomFamilyGraph.Person],
            profileRoute: ProfileRoute?,
            spellingCorrection: String?)
        case profileAmbiguous([ArchivistGraphProfileSnapshot])
        case profileConflict(stableID: String)
    }

    struct ProfileRoute {
        let requestedName: String
        let profileCanonicalName: String
        let pinProblem: String?
        /// The profile's stable id (nil only for legacy callers).
        let profileStableID: String?
    }

    /// Same specificity rule as FamilyTreeIdentityResolver, expressed over a
    /// Sendable profile projection so detached execution cannot retain POIs.
    private static func resolve(
        _ typedName: String,
        selection: ArchivistGraphSubjectSelection,
        inputs: ArchivistGraphInputs
    ) -> Resolution {
        switch selection {
        case .unresolved:
            return resolveUnselected(typedName, inputs: inputs)
        case .gedcomPersonID(let rawID):
            guard !rawID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let person = inputs.graph.people[rawID] else {
                return .people([], profileRoute: nil, spellingCorrection: nil)
            }
            return .people(
                [person], profileRoute: nil, spellingCorrection: nil)
        case .profileStableID(let rawID):
            return resolveProfile(stableID: rawID, requestedName: typedName, inputs: inputs)
        }
    }

    private static func resolveUnselected(
        _ typedName: String,
        inputs: ArchivistGraphInputs
    ) -> Resolution {
        if let resolution = resolveProfileName(typedName, inputs: inputs) {
            return resolution
        }

        // A bare given name ("rick", live 2026-08-28 on a 16k tree) is a
        // GIVEN-name question: the primary NAME record's first token, exact
        // or through the diminutive table (Rick ↔ Richard). Neither
        // `people(matching:)` (which prefers a NAME record EQUAL to the
        // token — FamilySearch stubs like an alternate name "Rich") nor
        // `people(namedLike:)` (which expands RECORD tokens too, so the
        // surname "Rich"/"Dick" becomes "richard") is asked first: both
        // offered Catherine Auker (b. 1374) for "rick". Several namesakes
        // are RETURNED for the caller's capped which-one / owner chain.
        if let bare = bareGivenName(typedName) {
            let byGivenName = inputs.graph.people(givenName: bare, expandDiminutives: true)
            if !byGivenName.isEmpty {
                return .people(
                    byGivenName, profileRoute: nil, spellingCorrection: nil)
            }
        }
        let exactPeople = inputs.graph.people(matching: typedName)
        if !exactPeople.isEmpty {
            return .people(
                exactPeople, profileRoute: nil, spellingCorrection: nil)
        }
        // Diminutive- and suffix-tolerant ("rick breen" ~ "Richard Harding
        // Breen Jr", live 2026-08-26). Unlike `people(matching:)` this
        // RETURNS several candidates instead of collapsing them to
        // not-found — the caller's ambiguity chips (or the owner chain)
        // decide, never a silent pick. Never for a bare token: with no
        // given-name hit, its only extra reach is the record-side
        // diminutive collision above.
        if bareGivenName(typedName) == nil {
            let loosePeople = inputs.graph.people(namedLike: typedName)
            if !loosePeople.isEmpty {
                return .people(
                    loosePeople, profileRoute: nil, spellingCorrection: nil)
            }
        } else if typedName.count <= 4 {
            // "rick" is one edit from "rich": a four-letter bare token is
            // never spelling-recovered against 39k names.
            return .people([], profileRoute: nil, spellingCorrection: nil)
        }
        let fuzzyIDs = HallieSpellingRecovery.bestMatches(
            typed: typedName,
            candidates: inputs.graph.visiblePeople.map {
                (identity: $0.id, spellings: [$0.name])
            })
        let fuzzyPeople = fuzzyIDs.compactMap { inputs.graph.people[$0] }
            .sorted(by: personOrder)
        let correction = fuzzyPeople.count == 1 ? typedName : nil
        return .people(
            fuzzyPeople, profileRoute: nil, spellingCorrection: correction)
    }

    /// One typed token that is a name (not a generational suffix, not a
    /// FamilySearch ID): the token, lowercased and diacritic-free. Nil for
    /// anything longer, so multi-word names keep their record-containment
    /// rules.
    static func bareGivenName(_ typed: String) -> String? {
        let tokens = FamilyIdentityText.tokens(FamilyNameNormalizer.normalizeName(typed))
        guard tokens.count == 1, let token = tokens.first,
              !GedcomFamilyGraph.nameSuffixes.contains(token),
              !GedcomFamilyGraph.isFamilySearchID(
                  typed.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
        else { return nil }
        return token
    }
}
