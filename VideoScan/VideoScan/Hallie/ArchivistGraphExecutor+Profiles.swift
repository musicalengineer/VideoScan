import Foundation

extension ArchivistGraphExecutor {
    /// A selected stable ID never gets captured by another profile's alias.
    static func resolveProfile(stableID rawID: String, requestedName typedName: String,
                               inputs: ArchivistGraphInputs) -> Resolution {
        guard !rawID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return .people([], profileRoute: nil, spellingCorrection: nil)
        }
        let definitions = inputs.profiles.filter { $0.stableID == rawID }
        guard let first = definitions.first else {
            return .people([], profileRoute: nil, spellingCorrection: nil)
        }
        let meaning = profileMeaning(first)
        guard definitions.allSatisfy({ profileMeaning($0) == meaning }) else {
            return .profileConflict(stableID: rawID)
        }
        let profile = deterministicProfileSnapshot(
            stableID: rawID, definitions: definitions)
        return resolveSelectedProfile(
            profile, requestedName: typedName, inputs: inputs)
    }

    static func resolveProfileName(_ typedName: String, inputs: ArchivistGraphInputs) -> Resolution? {
        let groupedProfiles = Dictionary(grouping: inputs.profiles, by: \.stableID)
        let identities: [ArchivistGraphProfileSnapshot]
        switch profileClaims(matching: typedName, groupedProfiles: groupedProfiles) {
        case .conflict(let stableID):
            return .profileConflict(stableID: stableID)
        case .matching(let profiles):
            identities = profiles
        }
        guard identities.count <= 1 else { return .profileAmbiguous(identities) }
        if let profile = identities.first {
            return resolveSelectedProfile(profile, requestedName: typedName, inputs: inputs)
        }

        // Exact identity lookup failed. Recover only the unique nearest
        // People profile; a tied spelling remains an explicit clarification.
        let fuzzyProfiles = spellingRecoveredProfiles(typedName, groupedProfiles: groupedProfiles)
        if fuzzyProfiles.count > 1 { return .profileAmbiguous(fuzzyProfiles) }
        if let recovered = fuzzyProfiles.first {
            let resolution = resolveSelectedProfile(recovered, requestedName: typedName, inputs: inputs)
            switch resolution {
            case .people(let people, let route, _):
                return .people(people, profileRoute: route, spellingCorrection: typedName)
            case .profileAmbiguous, .profileConflict:
                return resolution
            }
        }
        return nil
    }

    private enum ProfileClaims {
        case matching([ArchivistGraphProfileSnapshot])
        case conflict(stableID: String)
    }

    private static func profileClaims(matching typedName: String,
                                      groupedProfiles: [String: [ArchivistGraphProfileSnapshot]]) -> ProfileClaims {
        let key = normalize(typedName)
        var matchingProfiles: [ArchivistGraphProfileSnapshot] = []
        for stableID in groupedProfiles.keys.sorted() {
            guard let definitions = groupedProfiles[stableID],
                  let first = definitions.first else { continue }

            // A poisoned profile elsewhere in the gallery must not prevent a
            // direct GEDCOM lookup or a query for another person. A stable-ID
            // group participates only when one of its definitions claims the
            // requested spelling.
            guard definitions.contains(where: { profile in
                ([profile.canonicalName] + profile.aliases).contains {
                    normalize($0) == key
                }
            }) else { continue }

            let meaning = profileMeaning(first)
            guard definitions.allSatisfy({ profileMeaning($0) == meaning }) else {
                return .conflict(stableID: stableID)
            }
            matchingProfiles.append(deterministicProfileSnapshot(
                stableID: stableID, definitions: definitions))
        }

        // ONE spelling verdict, PersonResolver's (codex #778 / #795), now
        // under the exact-name-wins rule (Director, 2026-09-03): a spelling
        // claimed by one profile's NAME and another's ALIAS belongs to the
        // named profile ("Tim" is the brother's name and the son's alias).
        // Only a spelling that two profiles both NAME is ambiguous, and
        // that still asks. PersonNameClaim holds the rule so this route,
        // PersonResolver and the temporal route cannot drift apart —
        // drifting apart is exactly what #778 was filed about.
        let claimants = matchingProfiles.sorted(by: profileOrder)
        let narrowed = PersonNameClaim.narrow(
            claimants,
            typed: typedName,
            name: { $0.canonicalName },
            aliases: { $0.aliases })
        // A group qualified on a definition whose merged snapshot no longer
        // shows the spelling would narrow to nothing; keep every claimant
        // rather than silently falling through to spelling recovery.
        let identities = narrowed.isEmpty ? claimants : narrowed
        return .matching(identities)
    }

    private static func spellingRecoveredProfiles(_ typedName: String,
                                                   groupedProfiles: [String: [ArchivistGraphProfileSnapshot]])
        -> [ArchivistGraphProfileSnapshot] {
        let fuzzyProfileIDs = HallieSpellingRecovery.bestMatches(
            typed: typedName,
            candidates: groupedProfiles.compactMap { stableID, definitions in
                guard let first = definitions.first,
                      definitions.allSatisfy({
                          profileMeaning($0) == profileMeaning(first)
                      }) else { return nil }
                return (
                    identity: stableID,
                    spellings: definitions.flatMap {
                        [$0.canonicalName] + $0.aliases
                    })
            })
        return fuzzyProfileIDs.compactMap { stableID in
            groupedProfiles[stableID].map {
                deterministicProfileSnapshot(
                    stableID: stableID, definitions: $0)
            }
        }.sorted(by: profileOrder)
    }

    private struct ProfileMeaning: Equatable {
        let canonicalName: String
        let aliases: [String]
        /// A tree pin is identity, not display metadata. Two definitions of
        /// one stable profile that disagree here are conflicting identities,
        /// even when their names happen to match.
        let treeIdentity: TreeIdentity?
        let treeIdentityUnreadable: Bool
    }

    /// The People-profile bridge's exact lookup. A one-word canonical name
    /// or alias ("Rick", "Rich", "Richard") means a GIVEN name, matched
    /// exactly on the primary NAME record — never a NAME record that merely
    /// EQUALS the word (Catherine Auker's alternate name "Rich", live
    /// 2026-08-28) and, as before, never through the diminutive table on
    /// this side (the son "Timmy" must not bridge to the brother "Tim").
    private static func exactPeople(
        _ term: String, graph: GedcomFamilyGraph
    ) -> [GedcomFamilyGraph.Person] {
        if let bare = bareGivenName(term) {
            return graph.people(givenName: bare, expandDiminutives: false)
        }
        return graph.people(matching: term)
    }

    /// The profile is already selected by stable ID. Its durable tree pin is
    /// authoritative when present. Legacy unpinned profiles retain their
    /// exact canonical/alias route; no other profile can capture the
    /// continuation through a reciprocal/shared alias.
    private static func resolveSelectedProfile(
        _ profile: ArchivistGraphProfileSnapshot,
        requestedName: String,
        inputs: ArchivistGraphInputs
    ) -> Resolution {
        let profileRoute = ProfileRoute(
            requestedName: requestedName,
            profileCanonicalName: profile.canonicalName,
            pinProblem: nil,
            profileStableID: profile.stableID)

        // Identity != spelling. Once a profile carries a durable tree pin,
        // the already-built overlay is the sole authority for crossing into
        // GEDCOM. It resolves FSIDs/pointers and deliberately rejects stale,
        // unreadable, and colliding pins. Never fall through to canonical or
        // alias matching after a rejected pin: that would turn a visible
        // identity error into a convincing answer about the wrong person.
        if profile.treeIdentity != nil || profile.treeIdentityUnreadable {
            let pinProblem = inputs.kinshipOverlay.pinProblem(
                forProfileStableID: profile.stableID)
            guard pinProblem == nil,
                  case .tree(let gedcomID)? = inputs.kinshipOverlay.node(
                    profileStableID: profile.stableID),
                  let person = inputs.graph.people[gedcomID]
            else {
                return .people(
                    [], profileRoute: ProfileRoute(
                        requestedName: requestedName,
                        profileCanonicalName: profile.canonicalName,
                        pinProblem: pinProblem
                            ?? "the saved family-tree pin did not resolve",
                        profileStableID: profile.stableID),
                    spellingCorrection: nil)
            }
            return .people(
                [person], profileRoute: profileRoute,
                spellingCorrection: nil)
        }

        let graph = inputs.graph

        let canonicalMatches = exactPeople(
            profile.canonicalName, graph: graph)
        if !canonicalMatches.isEmpty {
            return .people(
                canonicalMatches, profileRoute: profileRoute,
                spellingCorrection: nil)
        }

        let fallbackTerms = ([requestedName] + profile.aliases).filter {
            normalize($0) != normalize(profile.canonicalName)
        }
        let tiers = Dictionary(grouping: fallbackTerms) {
            $0.split(whereSeparator: \.isWhitespace).count
        }
        for wordCount in tiers.keys.sorted(by: >) {
            var matchesByID: [String: GedcomFamilyGraph.Person] = [:]
            for term in (tiers[wordCount] ?? []).sorted(by: nameOrder) {
                for person in exactPeople(term, graph: graph) {
                    matchesByID[person.id] = person
                }
            }
            if !matchesByID.isEmpty {
                return .people(
                    matchesByID.values.sorted(by: personOrder),
                    profileRoute: profileRoute,
                    spellingCorrection: nil)
            }
        }
        // Deliberately NO diminutive-tolerant pass here (2026-08-26): a
        // profile's aliases would bridge the son "Timmy" to the brother
        // "Tim /Breen/" and "Dad" (alias Dick) to Rick. The owner's own
        // spelling gets its chain in the executor instead.
        return .people(
            [], profileRoute: profileRoute, spellingCorrection: nil)
    }

    static func normalize(_ value: String) -> String {
        PersonResolver.normalize(value)
    }

    private static func profileOrder(
        _ lhs: ArchivistGraphProfileSnapshot,
        _ rhs: ArchivistGraphProfileSnapshot
    ) -> Bool {
        if nameOrder(lhs.canonicalName, rhs.canonicalName) { return true }
        if nameOrder(rhs.canonicalName, lhs.canonicalName) { return false }
        return lhs.stableID < rhs.stableID
    }

    private static func profileMeaning(
        _ profile: ArchivistGraphProfileSnapshot
    ) -> ProfileMeaning {
        let canonicalName = normalize(profile.canonicalName)
        return ProfileMeaning(
            canonicalName: canonicalName,
            aliases: Array(Set(profile.aliases.map { normalize($0) }))
                .filter { !$0.isEmpty && $0 != canonicalName }
                .sorted(),
            treeIdentity: profile.treeIdentity,
            treeIdentityUnreadable: profile.treeIdentityUnreadable)
    }

    private static func deterministicProfileSnapshot(
        stableID: String,
        definitions: [ArchivistGraphProfileSnapshot]
    ) -> ArchivistGraphProfileSnapshot {
        let canonicalName = definitions.map(\.canonicalName)
            .sorted(by: nameOrder)[0]
        let canonicalMeaning = normalize(canonicalName)
        let aliasesByMeaning = Dictionary(
            grouping: definitions.flatMap(\.aliases),
            by: { normalize($0) })
        let aliases = aliasesByMeaning.keys.filter {
            !$0.isEmpty && $0 != canonicalMeaning
        }.sorted()
            .compactMap { aliasesByMeaning[$0]?.sorted(by: nameOrder).first }
        // `profileMeaning` already proved every definition agrees on these
        // identity fields, so any representative is deterministic in value.
        let representative = definitions.sorted(by: profileOrder)[0]
        return ArchivistGraphProfileSnapshot(
            stableID: stableID,
            canonicalName: canonicalName,
            aliases: aliases,
            // Birth/death are carried from 2026-09-03 so a which-one about
            // two people of the SAME name can separate them by year
            // ("John (born 1931) or John (born 1967)?"). `profileMeaning`
            // does not compare dates, so the representative — picked by
            // `profileOrder` — is the deterministic choice, not "any".
            birthdate: representative.birthdate,
            deathdate: representative.deathdate,
            treeIdentity: representative.treeIdentity,
            treeIdentityUnreadable: representative.treeIdentityUnreadable)
    }

    static func personOrder(
        _ lhs: GedcomFamilyGraph.Person,
        _ rhs: GedcomFamilyGraph.Person
    ) -> Bool {
        if nameOrder(lhs.name, rhs.name) { return true }
        if nameOrder(rhs.name, lhs.name) { return false }
        return lhs.id < rhs.id
    }

    static func nameOrder(_ lhs: String, _ rhs: String) -> Bool {
        let left = normalize(lhs)
        let right = normalize(rhs)
        if left != right { return left < right }
        return lhs < rhs
    }
}
