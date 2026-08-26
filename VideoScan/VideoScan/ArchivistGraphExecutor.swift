import Foundation

/// Immutable People-gallery identity used only to bridge a typed nickname to
/// a GEDCOM person. Profile notes, photos, and recognition settings never enter
/// graph execution, so they cannot leak into factual answers or an LLM prompt.
struct ArchivistGraphProfileSnapshot: Sendable, Equatable {
    let stableID: String
    let canonicalName: String
    let aliases: [String]

    init(stableID: String, canonicalName: String, aliases: [String] = []) {
        self.stableID = stableID
        self.canonicalName = canonicalName
        self.aliases = aliases
    }

    // `@MainActor` ≈ "copy UI-owned state while on the UI thread"; the
    // resulting value has no actor affinity and contains no private POI media.
    @MainActor
    init(profile: POIProfile) {
        self.init(
            stableID: profile.id,
            canonicalName: profile.name,
            aliases: profile.aliases)
    }
}

/// Complete immutable input to deterministic graph execution. Callers create
/// this value before detached work; the executor performs no I/O or mutation.
struct ArchivistGraphInputs: Sendable {
    let graph: GedcomFamilyGraph
    let profiles: [ArchivistGraphProfileSnapshot]

    init(
        graph: GedcomFamilyGraph,
        profiles: [ArchivistGraphProfileSnapshot] = []
    ) {
        self.graph = graph
        self.profiles = profiles
    }

    @MainActor
    init(graph: GedcomFamilyGraph, profiles: [POIProfile]) {
        self.init(
            graph: graph,
            profiles: profiles.map {
                ArchivistGraphProfileSnapshot(profile: $0)
            })
    }
}

/// A continuation selects identity by an opaque stable ID, never by feeding a
/// displayed name back through the alias resolver.
enum ArchivistGraphSubjectSelection: Sendable, Equatable {
    case unresolved
    case profileStableID(String)
    case gedcomPersonID(String)
}

struct ArchivistGraphAmbiguityCandidate: Sendable, Equatable {
    enum ID: Sendable, Equatable {
        case profileStableID(String)
        case gedcomPersonID(String)
    }

    let id: ID
    let canonicalName: String
    let label: String
}

/// Immutable projection copied from the decoded wire AST before execution.
/// The executor deliberately cannot receive the translator-owned AST itself;
/// only these bounded value fields cross into the factual graph layer.
struct ArchivistGraphQuery: Sendable, Equatable {
    enum Operation: String, Sendable, Equatable {
        case biography, birth, death, kinship, familyTree
        /// "how is A related to B" — `people` is exactly two (2026-08-18).
        case relationship
    }

    /// Who a people-list slot is in Hallie's voice, when the caller bound a
    /// pronoun: the owner is "you"/"your", the archivist herself is "I"/"my".
    /// Presentation only — identity still resolves through the same path.
    enum Voice: String, Sendable, Equatable {
        case owner
        case archivist
    }

    /// Mirrors the wire vocabulary by raw value. One-hop relations answer
    /// through `GedcomFamilyGraph.relatives`; the rest through the multi-hop
    /// path resolver (`ExtendedRelation`).
    enum Relation: String, Sendable, Equatable, CaseIterable {
        case father, mother, parents
        case brother, sister, siblings
        case son, daughter, children
        case husband, wife, spouse
        case grandfather, grandmother, grandparents
        case greatGrandfather = "great-grandfather"
        case greatGrandmother = "great-grandmother"
        case greatGrandparents = "great-grandparents"
        case greatGreatGrandfather = "great-great-grandfather"
        case greatGreatGrandmother = "great-great-grandmother"
        case greatGreatGrandparents = "great-great-grandparents"
        case uncle, aunt
        case auntsAndUncles = "aunts-and-uncles"
        case cousin, cousins
        case nephew, niece
        case niecesAndNephews = "nieces-and-nephews"
        case fatherInLaw = "father-in-law"
        case motherInLaw = "mother-in-law"
        case parentsInLaw = "parents-in-law"
        case brotherInLaw = "brother-in-law"
        case sisterInLaw = "sister-in-law"
        case sonInLaw = "son-in-law"
        case daughterInLaw = "daughter-in-law"

        var singleHop: GedcomFamilyGraph.Relation? {
            GedcomFamilyGraph.Relation(rawValue: rawValue)
        }

        var extended: GedcomFamilyGraph.ExtendedRelation? {
            GedcomFamilyGraph.ExtendedRelation(rawValue: rawValue)
        }
    }

    enum Side: String, Sendable, Equatable {
        case maternal, paternal

        var graphSide: GedcomFamilyGraph.KinshipSide {
            self == .maternal ? .maternal : .paternal
        }
    }

    let people: [String]
    let operation: Operation
    let relation: Relation?
    let side: Side?
    let surname: String?
    /// People-list index → voice, for slots that were bound pronouns.
    let voices: [Int: Voice]

    init(
        people: [String],
        operation: Operation,
        relation: Relation? = nil,
        side: Side? = nil,
        surname: String? = nil,
        voices: [Int: Voice] = [:]
    ) {
        self.people = people
        self.operation = operation
        self.relation = relation
        self.side = side
        self.surname = surname
        self.voices = voices
    }

    init(_ payload: ArchivistQueryAST.Graph, voices: [Int: Voice] = [:]) {
        people = payload.people
        switch payload.operation {
        case .biography: operation = .biography
        case .birth: operation = .birth
        case .death: operation = .death
        case .kinship: operation = .kinship
        case .familyTree: operation = .familyTree
        case .relationship: operation = .relationship
        }
        self.voices = voices
        // Raw values are the shared closed vocabulary; a wire relation that
        // has no executor twin becomes nil and fails closed as "missing".
        relation = payload.relation.flatMap { Relation(rawValue: $0.rawValue) }
        switch payload.side {
        case .some(.maternal): side = .maternal
        case .some(.paternal): side = .paternal
        case nil: side = nil
        }
        surname = payload.surname
    }
}

enum ArchivistGraphConclusion: Sendable, Equatable {
    case answered
    case missingFact
    case personNotFound
    case personAmbiguous
    case profileAmbiguous
    case conflictingProfileStableID(String)
    case invalidPerson
    case unsupportedPeopleCount(Int)
    case missingRelation
    case unexpectedRelation
}

/// Where the Family Tree tab should land if the user takes the offered
/// action. Presentation hint only; it carries a display name, never a claim.
enum ArchivistFamilyTreeFocus: Sendable, Equatable {
    case person(name: String)
    case surname(String)
}

/// Exact GEDCOM values used to compose an answer. This value stays on the
/// deterministic side of the translator boundary and must never be sent to an
/// LLM. IDs make each displayed fact auditable even when names are repeated.
struct ArchivistGraphEvidence: Sendable, Equatable {
    struct IdentityBridge: Sendable, Equatable {
        let requestedName: String
        let profileCanonicalName: String
        let effectiveGEDCOMPersonID: String
        let effectiveGEDCOMName: String
    }

    struct RelatedPerson: Sendable, Equatable {
        let id: String
        let name: String
    }

    struct Relationship: Sendable, Equatable {
        let relation: GedcomFamilyGraph.Relation
        let people: [RelatedPerson]
    }

    /// One multi-hop route ("Donna → mother Elaine → her mother Ann").
    struct KinshipPath: Sendable, Equatable {
        struct Hop: Sendable, Equatable {
            let label: String
            let person: RelatedPerson
        }
        let hops: [Hop]
    }

    let subjectID: String
    let subjectName: String
    let birthDate: String?
    let deathDate: String?
    let relationships: [Relationship]
    let identityBridge: IdentityBridge?
    let kinshipPaths: [KinshipPath]
    /// The second person of a `relationship` answer (B), also when no path
    /// was found — so offered actions can still name both people.
    let counterpart: RelatedPerson?

    init(
        subjectID: String,
        subjectName: String,
        birthDate: String?,
        deathDate: String?,
        relationships: [Relationship],
        identityBridge: IdentityBridge?,
        kinshipPaths: [KinshipPath] = [],
        counterpart: RelatedPerson? = nil
    ) {
        self.subjectID = subjectID
        self.subjectName = subjectName
        self.birthDate = birthDate
        self.deathDate = deathDate
        self.relationships = relationships
        self.identityBridge = identityBridge
        self.kinshipPaths = kinshipPaths
        self.counterpart = counterpart
    }
}

struct ArchivistGraphResult: Sendable, Equatable {
    let conclusion: ArchivistGraphConclusion
    let prose: String
    let basisLine: String
    let evidence: ArchivistGraphEvidence?
    let candidates: [ArchivistBiographyAnswer.Candidate]
    let profileCandidates: [String]
    let ambiguityCandidates: [ArchivistGraphAmbiguityCandidate]
    let catalogPersonName: String?
    let familyTreeFocus: ArchivistFamilyTreeFocus?
    /// For a two-person `relationship` query: which people-list slot the
    /// ambiguity / not-found conclusion is about (0 or 1). Nil otherwise.
    let subjectIndex: Int?

    init(
        conclusion: ArchivistGraphConclusion,
        prose: String,
        basisLine: String,
        evidence: ArchivistGraphEvidence?,
        candidates: [ArchivistBiographyAnswer.Candidate],
        profileCandidates: [String],
        ambiguityCandidates: [ArchivistGraphAmbiguityCandidate],
        catalogPersonName: String?,
        familyTreeFocus: ArchivistFamilyTreeFocus? = nil,
        subjectIndex: Int? = nil
    ) {
        self.conclusion = conclusion
        self.prose = prose
        self.basisLine = basisLine
        self.evidence = evidence
        self.candidates = candidates
        self.profileCandidates = profileCandidates
        self.ambiguityCandidates = ambiguityCandidates
        self.catalogPersonName = catalogPersonName
        self.familyTreeFocus = familyTreeFocus
        self.subjectIndex = subjectIndex
    }

    /// The same result tagged with the people-list slot it concerns.
    func taggingSubject(_ index: Int) -> ArchivistGraphResult {
        ArchivistGraphResult(
            conclusion: conclusion, prose: prose, basisLine: basisLine,
            evidence: evidence, candidates: candidates,
            profileCandidates: profileCandidates,
            ambiguityCandidates: ambiguityCandidates,
            catalogPersonName: catalogPersonName,
            familyTreeFocus: familyTreeFocus, subjectIndex: index)
    }
}

/// Pure executor for QueryAST's family-graph shape. The LLM supplies only the
/// validated AST; family evidence and factual prose never cross back through
/// the model. Multi-subject semantics are intentionally not invented: the
/// current wire format permits a list but does not define conjunction or
/// per-person output, so anything except one subject fails closed (the
/// `familyTree` surname / whole-tree forms are the one defined exception).
enum ArchivistGraphExecutor {
    static let queryValidationBasis =
        "Checked: graph-query validation only; no family source was consulted."

    static func execute(
        _ query: ArchivistGraphQuery,
        inputs: ArchivistGraphInputs
    ) -> ArchivistGraphResult {
        execute(query, inputs: inputs, subject: .unresolved)
    }

    static func execute(
        _ query: ArchivistGraphQuery,
        inputs: ArchivistGraphInputs,
        subject selection: ArchivistGraphSubjectSelection
    ) -> ArchivistGraphResult {
        if query.operation == .familyTree, query.people.isEmpty {
            guard query.relation == nil, query.side == nil else {
                return declineUnexpectedRelation()
            }
            return executeFamilyTreeWithoutPerson(query, graph: inputs.graph)
        }
        if query.operation == .relationship {
            // Two people; a single selection floats to whichever of them
            // turns out ambiguous (see executeRelationship).
            return executeRelationship(
                query, inputs: inputs, subjects: [.unresolved, .unresolved],
                floatingSelection: selection)
        }
        guard query.people.count == 1 else {
            // Honest, user-facing (live 2026-08-26: the old "must identify
            // exactly one person" guard sentence reached the chat).
            let names = query.people.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let prose = names.count >= 2
                ? "I wasn't sure which person you meant — " + names.joined(separator: " or ") + "? Ask about one of them and I'll look them up."
                : "Who would you like to know about? Give me one name and I'll look in the family tree."
            return decline(
                .unsupportedPeopleCount(query.people.count),
                prose: prose,
                basis: queryValidationBasis)
        }

        let typedName = query.people[0].trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !typedName.isEmpty else {
            return decline(
                .invalidPerson,
                prose: "Who would you like to know about? Give me a name and I'll look in the family tree.",
                basis: queryValidationBasis)
        }

        if query.operation == .kinship, query.relation == nil {
            return decline(
                .missingRelation,
                prose: "Which relationship do you mean — for example Rick's mother, or Donna's grandfather?",
                basis: queryValidationBasis)
        }
        if query.operation != .kinship, query.relation != nil || query.side != nil {
            return declineUnexpectedRelation()
        }

        switch resolveSubject(typedName, selection: selection,
                              inputs: inputs, query: query) {
        case .result(let result):
            return result
        case .person(let person, let bridge, let correction):
            let result = executeResolved(
                query, person: person, graph: inputs.graph,
                identityBridge: bridge)
            return applyingMarriedName(
                typed: typedName, person: person, graph: inputs.graph,
                to: applyingSpellingCorrection(
                    correction, canonicalName: person.name, to: result))
        }
    }

    /// "muriel lamb breen" / "muriel breen" found Muriel /Lamb/ through her
    /// husband's surname (FamilySearch records women under the maiden name
    /// only, live 2026-08-26). Say so: the prose names her "Muriel Lamb
    /// (Breen)" and the basis line says which marriage supplied the name.
    static func applyingMarriedName(
        typed: String,
        person: GedcomFamilyGraph.Person,
        graph: GedcomFamilyGraph,
        to result: ArchivistGraphResult
    ) -> ArchivistGraphResult {
        guard let tokens = GedcomFamilyGraph.namedLikeTokens(typed),
              let married = graph.marriedSurname(of: person, satisfying: tokens),
              let range = result.prose.range(of: person.name) else { return result }
        let shown = "\(person.name) (\(married))"
        let husbands = graph.relatives(.husband, of: person)
            .filter { ($0.surname.map(FamilyIdentityText.normalized) == married.lowercased())
                || $0.alternateSurnames.contains { FamilyIdentityText.normalized($0) == married.lowercased() } }
            .map(\.name)
        let note = "“\(typed)” is \(person.name) by her married name"
            + (husbands.isEmpty ? "." : " (married \(husbands.joined(separator: ", "))).")
        return ArchivistGraphResult(
            conclusion: result.conclusion,
            prose: result.prose.replacingCharacters(in: range, with: shown),
            basisLine: note + " " + result.basisLine,
            evidence: result.evidence,
            candidates: result.candidates,
            profileCandidates: result.profileCandidates,
            ambiguityCandidates: result.ambiguityCandidates,
            catalogPersonName: result.catalogPersonName,
            familyTreeFocus: result.familyTreeFocus,
            subjectIndex: result.subjectIndex)
    }

    /// Outcome of resolving ONE typed name: the unique GEDCOM person (with
    /// the profile bridge, if any), or the complete result to return as-is
    /// (ambiguity chips, not-found, profile conflict, surname roll-up).
    enum SubjectResolution {
        case person(GedcomFamilyGraph.Person,
                    identityBridge: ArchivistGraphEvidence.IdentityBridge?,
                    spellingCorrection: String?)
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
                prose: "Which \(typedName) do you mean?",
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
                spellingCorrection: correction)
        }
    }

    private enum Resolution {
        case people(
            [GedcomFamilyGraph.Person],
            profileRoute: ProfileRoute?,
            spellingCorrection: String?)
        case profileAmbiguous([ArchivistGraphProfileSnapshot])
        case profileConflict(stableID: String)
    }

    private struct ProfileMeaning: Equatable {
        let canonicalName: String
        let aliases: [String]
    }

    private struct ProfileRoute {
        let requestedName: String
        let profileCanonicalName: String
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
                profile, requestedName: typedName, graph: inputs.graph)
        }
    }

    private static func resolveUnselected(
        _ typedName: String,
        inputs: ArchivistGraphInputs
    ) -> Resolution {
        let key = normalize(typedName)
        let groupedProfiles = Dictionary(
            grouping: inputs.profiles, by: \.stableID)
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
                return .profileConflict(stableID: stableID)
            }
            matchingProfiles.append(deterministicProfileSnapshot(
                stableID: stableID, definitions: definitions))
        }

        var identities = matchingProfiles.sorted(by: profileOrder)
        // Cross-claimed spellings (Rick 2026-08-22: the gallery's "Tim" lists
        // "Timmy" as an alias and "Timmy" lists "Tim" — brother and son): the
        // profile whose CANONICAL name is the typed spelling wins outright;
        // alias-only claims still tie and ask.
        if identities.count > 1 {
            let exact = identities.filter { normalize($0.canonicalName) == key }
            if exact.count == 1 { identities = exact }
        }
        guard identities.count <= 1 else {
            return .profileAmbiguous(identities)
        }

        if let profile = identities.first {
            return resolveSelectedProfile(
                profile, requestedName: typedName, graph: inputs.graph)
        }

        // Exact identity lookup failed. Recover only the unique nearest
        // People profile; a tied spelling remains an explicit clarification.
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
        if !fuzzyProfileIDs.isEmpty {
            let fuzzyProfiles = fuzzyProfileIDs.compactMap { stableID in
                groupedProfiles[stableID].map {
                    deterministicProfileSnapshot(
                        stableID: stableID, definitions: $0)
                }
            }.sorted(by: profileOrder)
            if fuzzyProfiles.count > 1 {
                return .profileAmbiguous(fuzzyProfiles)
            }
            if let recovered = fuzzyProfiles.first {
                let resolution = resolveSelectedProfile(
                    recovered, requestedName: typedName, graph: inputs.graph)
                switch resolution {
                case .people(let people, let route, _):
                    return .people(
                        people, profileRoute: route,
                        spellingCorrection: typedName)
                case .profileAmbiguous, .profileConflict:
                    return resolution
                }
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
        // decide, never a silent pick.
        let loosePeople = inputs.graph.people(namedLike: typedName)
        if !loosePeople.isEmpty {
            return .people(
                loosePeople, profileRoute: nil, spellingCorrection: nil)
        }
        let fuzzyIDs = HallieSpellingRecovery.bestMatches(
            typed: typedName,
            candidates: inputs.graph.people.values.map {
                (identity: $0.id, spellings: [$0.name])
            })
        let fuzzyPeople = fuzzyIDs.compactMap { inputs.graph.people[$0] }
            .sorted(by: personOrder)
        let correction = fuzzyPeople.count == 1 ? typedName : nil
        return .people(
            fuzzyPeople, profileRoute: nil, spellingCorrection: correction)
    }

    /// The profile is already selected by stable ID. Only that profile's
    /// canonical name and aliases may bridge to GEDCOM; no other profile can
    /// capture the continuation through a reciprocal/shared alias.
    private static func resolveSelectedProfile(
        _ profile: ArchivistGraphProfileSnapshot,
        requestedName: String,
        graph: GedcomFamilyGraph
    ) -> Resolution {
        let profileRoute = ProfileRoute(
            requestedName: requestedName,
            profileCanonicalName: profile.canonicalName)

        let canonicalMatches = graph.people(
            matching: profile.canonicalName)
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
                for person in graph.people(matching: term) {
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

    private static func executeResolved(
        _ query: ArchivistGraphQuery,
        person: GedcomFamilyGraph.Person,
        graph: GedcomFamilyGraph,
        identityBridge: ArchivistGraphEvidence.IdentityBridge?
    ) -> ArchivistGraphResult {
        switch query.operation {
        case .biography:
            guard query.relation == nil else {
                return declineUnexpectedRelation()
            }
            let answer = ArchivistBiographyPolicy.biography(
                personID: person.id, in: graph)
            return fromPolicy(
                answer,
                evidence: biographyEvidence(
                    for: person, in: graph, identityBridge: identityBridge),
                identityBridge: identityBridge,
                unresolvedProfileRoute: nil)

        case .familyTree:
            let answer = ArchivistFamilyTreePolicy.summary(
                personID: person.id, in: graph)
            let result = fromPolicy(
                answer,
                evidence: biographyEvidence(
                    for: person, in: graph, identityBridge: identityBridge),
                identityBridge: identityBridge,
                unresolvedProfileRoute: nil)
            return ArchivistGraphResult(
                conclusion: result.conclusion,
                prose: result.prose,
                basisLine: result.basisLine,
                evidence: result.evidence,
                candidates: result.candidates,
                profileCandidates: result.profileCandidates,
                ambiguityCandidates: result.ambiguityCandidates,
                catalogPersonName: result.catalogPersonName,
                familyTreeFocus: .person(name: person.name))

        case .birth, .death:
            guard query.relation == nil else {
                return declineUnexpectedRelation()
            }
            let answer = ArchivistBiographyPolicy.lifeDate(
                personID: person.id,
                birth: query.operation == .birth,
                in: graph)
            return fromPolicy(
                answer,
                evidence: lifeDateEvidence(
                    for: person, birth: query.operation == .birth,
                    identityBridge: identityBridge),
                identityBridge: identityBridge,
                unresolvedProfileRoute: nil)

        case .relationship:
            // Two-person operation; dispatched before single-subject
            // resolution. Reaching here means a caller misrouted it.
            return decline(
                .unsupportedPeopleCount(1),
                prose: "To work out how two people are related I need both names — for example, how is Donna related to Thankful Pratt?",
                basis: queryValidationBasis)

        case .kinship:
            guard let relation = query.relation else {
                return decline(
                    .missingRelation,
                    prose: "Which relationship do you mean — for example Rick's mother, or Donna's grandfather?",
                    basis: queryValidationBasis)
            }
            if let graphRelation = relation.singleHop {
                if query.side != nil {
                    // "maternal father" has no meaning; refuse rather than
                    // silently drop the side.
                    return declineUnexpectedRelation()
                }
                return executeSingleHop(
                    graphRelation, person: person, graph: graph,
                    identityBridge: identityBridge)
            }
            guard let extended = relation.extended else {
                return decline(
                    .missingRelation,
                    prose: "Which relationship do you mean — for example Rick's mother, or Donna's grandfather?",
                    basis: queryValidationBasis)
            }
            return executeExtended(
                extended, side: query.side?.graphSide, person: person,
                graph: graph, identityBridge: identityBridge)
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
        case .biography, .kinship, .familyTree, .relationship:
            // BiographyPolicy owns the canonical fail-closed not-found and
            // ambiguity wording; no relationship is evaluated until unique.
            return ArchivistBiographyPolicy.biography(
                for: typedName, candidates: candidates, in: graph)
        }
    }

    private static func fromPolicy(
        _ answer: ArchivistBiographyAnswer,
        evidence: ArchivistGraphEvidence?,
        identityBridge: ArchivistGraphEvidence.IdentityBridge?,
        unresolvedProfileRoute: ProfileRoute?
    ) -> ArchivistGraphResult {
        let conclusion: ArchivistGraphConclusion
        switch answer.state {
        case .answered: conclusion = .answered
        case .missingFact: conclusion = .missingFact
        case .notFound: conclusion = .personNotFound
        case .ambiguous: conclusion = .personAmbiguous
        }
        return ArchivistGraphResult(
            conclusion: conclusion,
            prose: answer.text,
            basisLine: identityBridgeBasis(
                identityBridge, answered: answer.state == .answered
                    || answer.state == .missingFact)
                ?? unresolvedProfileRouteBasis(unresolvedProfileRoute)
                ?? answer.basis,
            evidence: answer.state == .answered || answer.state == .missingFact
                ? evidence : nil,
            candidates: answer.candidates,
            profileCandidates: [],
            ambiguityCandidates: answer.candidates.map {
                ArchivistGraphAmbiguityCandidate(
                    id: .gedcomPersonID($0.id),
                    canonicalName: $0.name,
                    label: $0.label)
            },
            catalogPersonName: answer.catalogPersonName)
    }

    private static func biographyEvidence(
        for person: GedcomFamilyGraph.Person,
        in graph: GedcomFamilyGraph,
        identityBridge: ArchivistGraphEvidence.IdentityBridge?
    ) -> ArchivistGraphEvidence {
        // Relation groups and their members use the policy's exact order so
        // evidence stays aligned with its deterministic biography prose.
        let relationships: [ArchivistGraphEvidence.Relationship] = [
            relationship(
                .parents,
                people: ArchivistBiographyPolicy.orderedPeople(
                    graph.relatives(.parents, of: person))),
            relationship(
                .spouse,
                people: ArchivistBiographyPolicy.orderedPeople(
                    graph.relatives(.spouse, of: person))),
            relationship(
                .children,
                people: ArchivistBiographyPolicy.orderedPeople(
                    graph.relatives(.children, of: person))),
        ].filter { !$0.people.isEmpty }
        return ArchivistGraphEvidence(
            subjectID: person.id,
            subjectName: person.name,
            birthDate: person.birthDate,
            deathDate: person.deathDate,
            relationships: relationships,
            identityBridge: identityBridge)
    }

    private static func lifeDateEvidence(
        for person: GedcomFamilyGraph.Person,
        birth: Bool,
        identityBridge: ArchivistGraphEvidence.IdentityBridge?
    ) -> ArchivistGraphEvidence {
        ArchivistGraphEvidence(
            subjectID: person.id,
            subjectName: person.name,
            birthDate: birth ? person.birthDate : nil,
            deathDate: birth ? nil : person.deathDate,
            relationships: [],
            identityBridge: identityBridge)
    }

    static func kinshipEvidence(
        for person: GedcomFamilyGraph.Person,
        relation: GedcomFamilyGraph.Relation,
        relatives: [GedcomFamilyGraph.Person],
        identityBridge: ArchivistGraphEvidence.IdentityBridge?
    ) -> ArchivistGraphEvidence {
        ArchivistGraphEvidence(
            subjectID: person.id,
            subjectName: person.name,
            birthDate: nil,
            deathDate: nil,
            relationships: [relationship(relation, people: relatives)],
            identityBridge: identityBridge)
    }

    private static func relationship(
        _ relation: GedcomFamilyGraph.Relation,
        people: [GedcomFamilyGraph.Person]
    ) -> ArchivistGraphEvidence.Relationship {
        ArchivistGraphEvidence.Relationship(
            relation: relation,
            people: people.map {
                .init(id: $0.id, name: $0.name)
            })
    }

    private static func declineUnexpectedRelation() -> ArchivistGraphResult {
        decline(
            .unexpectedRelation,
            prose: "Let me do that one person at a time — try \u{201C}show my paternal line back 5 generations\u{201D}, \u{201C}trace the family back to Ireland\u{201D}, or name the person you're curious about.",
            basis: queryValidationBasis)
    }

    static func factualBasis(
        _ bridge: ArchivistGraphEvidence.IdentityBridge?
    ) -> String {
        identityBridgeBasis(bridge, answered: true)
            ?? ArchivistBiographyPolicy.gedcomBasis
    }

    private static func identityBridgeBasis(
        _ bridge: ArchivistGraphEvidence.IdentityBridge?,
        answered: Bool
    ) -> String? {
        guard let bridge else { return nil }
        let prefix = answered ? "Basis" : "Checked"
        return "\(prefix): People profile identity bridge “"
            + bridge.requestedName + "” → “"
            + bridge.profileCanonicalName
            + "” → GEDCOM “" + bridge.effectiveGEDCOMName
            + "”; family facts from imported family tree (GEDCOM)."
    }

    private static func unresolvedProfileRouteBasis(
        _ route: ProfileRoute?
    ) -> String? {
        guard let route else { return nil }
        return "Checked: People profile identity route “"
            + route.requestedName + "” → “"
            + route.profileCanonicalName
            + "”; imported family tree (GEDCOM), but no unique GEDCOM "
            + "identity was resolved."
    }

    private static func identityBridge(
        _ route: ProfileRoute?,
        effectivePerson: GedcomFamilyGraph.Person
    ) -> ArchivistGraphEvidence.IdentityBridge? {
        guard let route else { return nil }
        let requested = normalize(route.requestedName)
        let profile = normalize(route.profileCanonicalName)
        let effective = normalize(effectivePerson.name)
        guard requested != profile || profile != effective else { return nil }
        return ArchivistGraphEvidence.IdentityBridge(
            requestedName: route.requestedName,
            profileCanonicalName: route.profileCanonicalName,
            effectiveGEDCOMPersonID: effectivePerson.id,
            effectiveGEDCOMName: effectivePerson.name)
    }

    static func decline(
        _ conclusion: ArchivistGraphConclusion,
        prose: String,
        basis: String
    ) -> ArchivistGraphResult {
        ArchivistGraphResult(
            conclusion: conclusion,
            prose: prose,
            basisLine: basis,
            evidence: nil,
            candidates: [],
            profileCandidates: [],
            ambiguityCandidates: [],
            catalogPersonName: nil)
    }

    static func applyingSpellingCorrection(
        _ correction: String?,
        canonicalName: String,
        to result: ArchivistGraphResult
    ) -> ArchivistGraphResult {
        guard let correction else { return result }
        return ArchivistGraphResult(
            conclusion: result.conclusion,
            prose: "I took that spelling to mean \(canonicalName). "
                + result.prose,
            basisLine: "Spelling recovery: uniquely matched “\(correction)” "
                + "to GEDCOM “\(canonicalName)”. " + result.basisLine,
            evidence: result.evidence,
            candidates: result.candidates,
            profileCandidates: result.profileCandidates,
            ambiguityCandidates: result.ambiguityCandidates,
            catalogPersonName: result.catalogPersonName,
            familyTreeFocus: result.familyTreeFocus,
            subjectIndex: result.subjectIndex)
    }

    private static func normalize(_ value: String) -> String {
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
                .sorted())
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
        return ArchivistGraphProfileSnapshot(
            stableID: stableID,
            canonicalName: canonicalName,
            aliases: aliases)
    }

    static func personOrder(
        _ lhs: GedcomFamilyGraph.Person,
        _ rhs: GedcomFamilyGraph.Person
    ) -> Bool {
        if nameOrder(lhs.name, rhs.name) { return true }
        if nameOrder(rhs.name, lhs.name) { return false }
        return lhs.id < rhs.id
    }

    private static func nameOrder(_ lhs: String, _ rhs: String) -> Bool {
        let left = normalize(lhs)
        let right = normalize(rhs)
        if left != right { return left < right }
        return lhs < rhs
    }

}
