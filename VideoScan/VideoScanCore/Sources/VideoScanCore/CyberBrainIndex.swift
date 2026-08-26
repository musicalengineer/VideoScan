import Foundation

public enum CyberBrainIdentityResolution: Sendable, Equatable {
    case resolved(CyberBrainPerson)
    case ambiguous([CyberBrainPerson])
    case notFound
}

/// Immutable, disposable lookup index. The JSON archive remains the source of
/// truth; rebuilding this value after an archive revision is intentional.
public struct CyberBrainIndex: Sendable {
    public let archive: CyberBrainArchive
    public let generation: String

    private let peopleByID: [String: CyberBrainPerson]
    private let peopleByLookupName: [String: [String]]
    private let peopleByLookupToken: [String: [String]]
    private let sourcesByID: [String: CyberBrainSource]
    private let activeItemsByPersonID: [String: [CyberBrainItem]]
    /// GEDCOM pointer → CyberBrain person ids that declare it (normally one).
    private let peopleByGedcomID: [String: [String]]

    public init(archive: CyberBrainArchive) throws {
        try CyberBrainValidator.validate(archive)
        self.archive = archive
        self.peopleByID = Dictionary(uniqueKeysWithValues:
            archive.people.map { ($0.id, $0) })
        self.sourcesByID = Dictionary(uniqueKeysWithValues:
            archive.sources.map { ($0.id, $0) })
        var byGedcom: [String: [String]] = [:]
        for person in archive.people {
            if let gedcomID = person.gedcomPersonID, !gedcomID.isEmpty {
                byGedcom[gedcomID, default: []].append(person.id)
            }
        }
        self.peopleByGedcomID = byGedcom.mapValues { $0.sorted() }

        var names: [String: Set<String>] = [:]
        var tokens: [String: Set<String>] = [:]
        for person in archive.people {
            for value in [person.canonicalName] + person.aliases {
                let key = FamilyIdentityText.normalized(value)
                names[key, default: []].insert(person.id)
                for token in Set(FamilyIdentityText.tokens(value)) {
                    tokens[token, default: []].insert(person.id)
                }
            }
        }
        self.peopleByLookupName = names.mapValues { $0.sorted() }
        self.peopleByLookupToken = tokens.mapValues { $0.sorted() }

        let allItems = archive.people.flatMap(\.items)
        let superseded = Set(allItems.compactMap { item in
            item.status == .active ? item.supersedesItemID : nil
        })
        var items: [String: [CyberBrainItem]] = [:]
        for item in allItems
            where item.status == .active && !superseded.contains(item.id) {
            for personID in item.subjectPersonIDs {
                items[personID, default: []].append(item)
            }
        }
        self.activeItemsByPersonID = items.mapValues {
            $0.sorted(by: Self.itemPrecedes)
        }

        // The token covers every persisted field, including references and
        // source metadata. Cache invalidation does not rely on an editor
        // remembering to bump updatedAt.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let revisionMaterial = try encoder.encode(archive)
        self.generation = "v\(archive.schemaVersion):\(archive.archiveID):"
            + String(revisionMaterial.reduce(UInt64(14_695_981_039_346_656_037)) {
                ($0 ^ UInt64($1)) &* 1_099_511_628_211
            }, radix: 16)
    }

    public func resolve(_ name: String) -> CyberBrainIdentityResolution {
        let normalized = FamilyIdentityText.normalized(name)
        let queryTokens = FamilyIdentityText.tokens(name)
        guard !queryTokens.isEmpty else { return .notFound }

        let exact = peopleByLookupName[normalized] ?? []
        let ids: [String]
        if !exact.isEmpty {
            ids = exact
        } else {
            let tokenSets = queryTokens.compactMap {
                peopleByLookupToken[$0].map(Set.init)
            }
            guard tokenSets.count == queryTokens.count,
                  let first = tokenSets.first else { return .notFound }
            ids = tokenSets.dropFirst().reduce(first) { $0.intersection($1) }
                .sorted()
        }
        let people = ids.compactMap { peopleByID[$0] }
            .sorted { lhs, rhs in
                let left = FamilyIdentityText.normalized(lhs.canonicalName)
                let right = FamilyIdentityText.normalized(rhs.canonicalName)
                return left == right ? lhs.id < rhs.id : left < right
            }
        if people.count == 1 { return .resolved(people[0]) }
        if people.isEmpty { return .notFound }
        return .ambiguous(people)
    }

    public func person(id: String) -> CyberBrainPerson? { peopleByID[id] }

    /// People whose record carries this GEDCOM pointer (Family Tree notes,
    /// 2026-08-26). O(1); empty when nobody is linked.
    public func people(gedcomPersonID: String) -> [CyberBrainPerson] {
        (peopleByGedcomID[gedcomPersonID] ?? []).compactMap { peopleByID[$0] }
    }

    /// Every active, non-superseded item about a person, privacy included —
    /// for the owner's own inspector, where the privacy level is shown as
    /// a badge rather than used as a filter. Same order as `evidence`.
    public func allActiveItems(for personID: String) -> [CyberBrainItem] {
        activeItemsByPersonID[personID] ?? []
    }
    public func source(id: String) -> CyberBrainSource? { sourcesByID[id] }

    public func evidence(
        for personID: String,
        privacyCeiling: CyberBrainItem.Privacy,
        limit: Int = 12
    ) -> [CyberBrainItem] {
        let bounded = min(max(0, limit), 50)
        return visibleEvidence(for: personID, privacyCeiling: privacyCeiling)
            .prefix(bounded)
            .map { $0 }
    }

    /// The family's spoken/written accounts about one person, with the
    /// teller when the source records one — the raw material for
    /// "describe X" answers voiced as attributed testimony (Rick
    /// 2026-08-25: those answers must be deterministic, not left to a
    /// model's mood).
    public struct FamilyAccount: Sendable, Equatable {
        public let text: String
        public let attribution: String?
        public let confidence: CyberBrainItem.Confidence
        public let createdAt: Date?
    }

    public func familyAccounts(
        forPersonID personID: String,
        privacyCeiling: CyberBrainItem.Privacy
    ) -> [FamilyAccount] {
        visibleEvidence(for: personID, privacyCeiling: privacyCeiling)
            .filter { $0.confidence != .disputed }
            .map { item in
                FamilyAccount(
                    text: item.text,
                    attribution: item.sourceIDs
                        .compactMap { source(id: $0)?.attribution }.first,
                    confidence: item.confidence,
                    createdAt: item.createdAt)
            }
    }

    fileprivate func visibleEvidence(
        for personID: String,
        privacyCeiling: CyberBrainItem.Privacy
    ) -> [CyberBrainItem] {
        (activeItemsByPersonID[personID] ?? []).filter {
            $0.privacy.isVisible(at: privacyCeiling)
        }
    }

    private static func itemPrecedes(_ lhs: CyberBrainItem,
                                     _ rhs: CyberBrainItem) -> Bool {
        let kindRank: [CyberBrainItem.Kind: Int] = [
            .biography: 0, .event: 1, .anecdote: 2, .note: 3,
        ]
        let confidenceRank: [CyberBrainItem.Confidence: Int] = [
            .confirmed: 0, .probable: 1, .uncertain: 2, .disputed: 3,
        ]
        let left = (kindRank[lhs.kind] ?? 9, confidenceRank[lhs.confidence] ?? 9)
        let right = (kindRank[rhs.kind] ?? 9, confidenceRank[rhs.confidence] ?? 9)
        if left.0 != right.0 { return left.0 < right.0 }
        if left.1 != right.1 { return left.1 < right.1 }
        return lhs.id < rhs.id
    }
}

public enum CyberBrainBiographyPlanner {
    public static let gedcomFactPrivacy = CyberBrainItem.Privacy.private
    public static let gedcomFactConfidence = CyberBrainItem.Confidence.probable

    public static func plan(
        personName: String,
        index: CyberBrainIndex,
        graph: GedcomFamilyGraph? = nil,
        privacyCeiling: CyberBrainItem.Privacy = .private,
        itemLimit: Int = 8
    ) -> CyberBrainAnswerPlan {
        switch index.resolve(personName) {
        case .notFound:
            return graphFallbackPlan(
                personName: personName, graph: graph,
                privacyCeiling: privacyCeiling)
        case .ambiguous(let people):
            return CyberBrainAnswerPlan(
                subject: personName,
                answerState: .ambiguous,
                uncertaintyStatements: ["More than one person uses that name or alias."],
                permittedActions: [.narrow],
                constraints: [.doNotChooseAmbiguousIdentity],
                ambiguityCandidates: people.map {
                    .init(
                        id: $0.id,
                        canonicalName: $0.canonicalName,
                        source: .cyberBrain)
                })
        case .resolved(let person):
            return resolvedPlan(person: person, index: index, graph: graph,
                                privacyCeiling: privacyCeiling,
                                itemLimit: itemLimit)
        }
    }

    /// Continues a previously offered CyberBrain identity without resolving
    /// display text a second time. A missing ID fails closed instead of
    /// silently selecting a similarly named person.
    public static func plan(
        personID: String,
        index: CyberBrainIndex,
        graph: GedcomFamilyGraph? = nil,
        privacyCeiling: CyberBrainItem.Privacy = .private,
        itemLimit: Int = 8
    ) -> CyberBrainAnswerPlan {
        guard let person = index.person(id: personID) else {
            return CyberBrainAnswerPlan(
                subject: personID,
                answerState: .noEvidence,
                uncertaintyStatements: [
                    "That CyberBrain identity is no longer available."
                ],
                constraints: [.doNotInferIdentity])
        }
        return resolvedPlan(
            person: person,
            index: index,
            graph: graph,
            privacyCeiling: privacyCeiling,
            itemLimit: itemLimit)
    }

    /// Continues a previously offered imported-family-tree identity by its
    /// GEDCOM pointer. Display text is never re-resolved: two same-name
    /// people (Sr./Jr.) would otherwise stay ambiguous forever, and a GEDCOM
    /// name that also happens to be a CyberBrain alias would silently answer
    /// for a person the user did not select. Only that person's family-tree
    /// facts are planned; a missing pointer fails closed.
    public static func plan(
        gedcomPersonID: String,
        index: CyberBrainIndex,
        graph: GedcomFamilyGraph?,
        privacyCeiling: CyberBrainItem.Privacy = .private
    ) -> CyberBrainAnswerPlan {
        guard let graph, let person = graph.people[gedcomPersonID] else {
            return CyberBrainAnswerPlan(
                subject: gedcomPersonID,
                answerState: .noEvidence,
                uncertaintyStatements: [
                    "That family-tree person is no longer available."
                ],
                constraints: [.doNotInferIdentity])
        }
        return gedcomOnlyPlan(
            person: person, graph: graph, privacyCeiling: privacyCeiling)
    }

    private static func resolvedPlan(
        person: CyberBrainPerson,
        index: CyberBrainIndex,
        graph: GedcomFamilyGraph?,
        privacyCeiling: CyberBrainItem.Privacy,
        itemLimit: Int
    ) -> CyberBrainAnswerPlan {
        var claims: [CyberBrainAnswerPlan.Claim] = []
        var citations: [String: CyberBrainAnswerPlan.Citation] = [:]
        var uncertainty: [String] = []
        var constraints: [CyberBrainAnswerPlan.Constraint] = [
            .doNotAddUnsupportedFacts,
        ]

        if let gedcomID = person.gedcomPersonID,
           let graph,
           let gedcomPerson = graph.people[gedcomID],
           gedcomFactPrivacy.isVisible(at: privacyCeiling) {
            appendGEDCOMClaims(
                person: gedcomPerson, displayName: person.canonicalName,
                graph: graph, claims: &claims, citations: &citations)
        } else if person.gedcomPersonID != nil {
            if !gedcomFactPrivacy.isVisible(at: privacyCeiling) {
                uncertainty.append("Imported family-tree facts are above this privacy ceiling.")
            } else {
                uncertainty.append("The person's GEDCOM bridge is not available in the current family tree.")
            }
        }

        let allVisible = index.visibleEvidence(
            for: person.id, privacyCeiling: privacyCeiling)
        let selection = selectEvidence(allVisible, limit: itemLimit)
        let evidence = selection.items
        for item in evidence {
            claims.append(.init(id: item.id, text: item.text,
                                evidenceIDs: item.sourceIDs,
                                confidence: item.confidence))
            for sourceID in item.sourceIDs {
                if let source = index.source(id: sourceID) {
                    citations[sourceID] = .init(
                        id: source.id, title: source.title,
                        attribution: source.attribution,
                        locator: source.locator)
                }
            }
            switch item.confidence {
            case .uncertain:
                uncertainty.append("One included family account is marked uncertain.")
            case .disputed:
                uncertainty.append("The archive contains a disputed account about this person.")
            default: break
            }
        }

        let state: CyberBrainAnswerState
        if selection.hasDispute {
            state = .disputed
            constraints.append(.doNotResolveDispute)
            if !uncertainty.contains(where: { $0.contains("disputed") }) {
                uncertainty.append("The archive contains a disputed account about this person.")
            }
        } else {
            state = claims.isEmpty ? .noEvidence : .answered
        }

        return CyberBrainAnswerPlan(
            subject: person.canonicalName,
            answerState: state,
            claims: claims,
            uncertaintyStatements: Array(Set(uncertainty)).sorted(),
            sourceCitations: citations.values.sorted { $0.id < $1.id },
            suggestedFollowups: claims.isEmpty ? [] : [
                "Would you like to see the supporting sources?"
            ],
            permittedActions: citations.isEmpty ? [] : [.showSource],
            constraints: constraints)
    }

    private static func selectEvidence(
        _ allVisible: [CyberBrainItem],
        limit: Int
    ) -> (items: [CyberBrainItem], hasDispute: Bool) {
        let disputed = allVisible.filter { $0.confidence == .disputed }
        let bounded = min(max(0, limit), 50)
        guard bounded > 0, let representative = disputed.first else {
            return (Array(allVisible.prefix(bounded)), !disputed.isEmpty)
        }

        let visibleByID = Dictionary(uniqueKeysWithValues:
            allVisible.map { ($0.id, $0) })
        var disputeSet = [representative.id: representative]
        for counterID in representative.disputesItemIDs {
            if let counter = visibleByID[counterID] {
                disputeSet[counter.id] = counter
            }
        }
        // A dispute and its counter-claim are an indivisible evidence group.
        // It may exceed a small presentation limit, but remains bounded by
        // the validator's eight-counter cap.
        let completeDispute = allVisible.filter { disputeSet[$0.id] != nil }
        let ordinaryCapacity = max(0, bounded - completeDispute.count)
        let ordinary = allVisible.filter { disputeSet[$0.id] == nil }
            .prefix(ordinaryCapacity)
        let selectedByID = Dictionary(uniqueKeysWithValues:
            (Array(ordinary) + completeDispute).map { ($0.id, $0) })
        return (allVisible.filter { selectedByID[$0.id] != nil }, true)
    }

    private static func graphFallbackPlan(
        personName: String,
        graph: GedcomFamilyGraph?,
        privacyCeiling: CyberBrainItem.Privacy
    ) -> CyberBrainAnswerPlan {
        guard let graph else {
            return CyberBrainAnswerPlan(
                subject: personName,
                answerState: .noEvidence,
                uncertaintyStatements: [
                    "I don't find that person in CyberBrain, and no imported family tree is available."
                ],
                constraints: [.doNotInferIdentity])
        }
        let matches = graph.people(matching: personName)
        guard matches.count == 1 else {
            if matches.isEmpty {
                return CyberBrainAnswerPlan(
                    subject: personName,
                    answerState: .noEvidence,
                    uncertaintyStatements: [
                        "I don't find that person in CyberBrain or the imported family tree."
                    ],
                    constraints: [.doNotInferIdentity])
            }
            return CyberBrainAnswerPlan(
                subject: personName,
                answerState: .ambiguous,
                uncertaintyStatements: [
                    "More than one imported family-tree person matches that name."
                ],
                permittedActions: [.narrow],
                constraints: [.doNotChooseAmbiguousIdentity],
                ambiguityCandidates: matches.map {
                    .init(
                        id: $0.id,
                        canonicalName: $0.name,
                        source: .gedcom)
                })
        }
        return gedcomOnlyPlan(
            person: matches[0], graph: graph, privacyCeiling: privacyCeiling)
    }

    /// Family-tree facts for exactly one already-identified GEDCOM person.
    /// Shared by the name fallback and the pointer continuation so both
    /// produce identical claims, citations, and privacy behavior.
    private static func gedcomOnlyPlan(
        person: GedcomFamilyGraph.Person,
        graph: GedcomFamilyGraph,
        privacyCeiling: CyberBrainItem.Privacy
    ) -> CyberBrainAnswerPlan {
        guard gedcomFactPrivacy.isVisible(at: privacyCeiling) else {
            return CyberBrainAnswerPlan(
                subject: person.name,
                answerState: .noEvidence,
                uncertaintyStatements: [
                    "Imported family-tree facts are above this privacy ceiling."
                ],
                constraints: [.doNotAddUnsupportedFacts])
        }

        var claims: [CyberBrainAnswerPlan.Claim] = []
        var citations: [String: CyberBrainAnswerPlan.Citation] = [:]
        appendGEDCOMClaims(
            person: person, displayName: person.name,
            graph: graph, claims: &claims, citations: &citations)
        return CyberBrainAnswerPlan(
            subject: person.name,
            answerState: claims.isEmpty ? .noEvidence : .answered,
            claims: claims,
            uncertaintyStatements: claims.isEmpty
                ? ["The person is in the imported family tree, but it records no biographical facts."]
                : [],
            sourceCitations: citations.values.sorted { $0.id < $1.id },
            suggestedFollowups: claims.isEmpty ? [] : [
                "Would you like to see the supporting family-tree record?"
            ],
            permittedActions: claims.isEmpty ? [] : [.showSource],
            constraints: [.doNotAddUnsupportedFacts])
    }

    private static func appendGEDCOMClaims(
        person: GedcomFamilyGraph.Person,
        displayName: String,
        graph: GedcomFamilyGraph,
        claims: inout [CyberBrainAnswerPlan.Claim],
        citations: inout [String: CyberBrainAnswerPlan.Citation]
    ) {
        let sourceID = "gedcom:\(person.id)"
        func claim(_ id: String, _ text: String) -> CyberBrainAnswerPlan.Claim {
            .init(
                id: id, text: text, evidenceIDs: [sourceID],
                confidence: gedcomFactConfidence)
        }
        if let birth = person.birthDate {
            claims.append(claim(
                "\(sourceID):birth",
                "The imported family tree records \(birth) as \(displayName)'s birth date."))
        }
        if let death = person.deathDate {
            claims.append(claim(
                "\(sourceID):death",
                "The imported family tree records \(death) as \(displayName)'s death date."))
        }
        let relationships: [(GedcomFamilyGraph.Relation, String)] = [
            (.parents, "parents"), (.spouse, "spouse"), (.children, "children"),
        ]
        for (relation, label) in relationships {
            let names = ArchivistBiographyPolicy.orderedPeople(
                graph.relatives(relation, of: person)).map(\.name)
            if !names.isEmpty {
                claims.append(claim(
                    "\(sourceID):\(label)",
                    "The imported family tree records \(displayName)'s \(label) as \(names.joined(separator: ", "))."))
            }
        }
        if !claims.filter({ $0.evidenceIDs.contains(sourceID) }).isEmpty {
            citations[sourceID] = .init(
                id: sourceID, title: "Imported family tree (GEDCOM)",
                attribution: nil, locator: nil)
        }
    }
}

public enum CyberBrainDeterministicComposer {
    public static func compose(_ plan: CyberBrainAnswerPlan) -> String {
        switch plan.answerState {
        case .ambiguous:
            let names = plan.ambiguityCandidates.map(\.canonicalName)
            return "Which \(plan.subject) do you mean: \(names.joined(separator: ", "))?"
        case .noEvidence:
            return plan.uncertaintyStatements.first
                ?? "I don't have sourced biographical evidence for \(plan.subject)."
        case .answered, .disputed:
            let opening = plan.answerState == .disputed
                ? "The family archive preserves more than one account of \(plan.subject), so I won't collapse them into a single version."
                : "Here is what the family archive currently supports about \(plan.subject)."
            var paragraphs = [opening]
            paragraphs.append(contentsOf: plan.claims.map(\.text))
            paragraphs.append(contentsOf: plan.uncertaintyStatements)
            if !plan.sourceCitations.isEmpty {
                let count = plan.sourceCitations.count
                paragraphs.append(
                    "This account is supported by \(count) source\(count == 1 ? "" : "s"), which I can show you.")
            } else if let followup = plan.suggestedFollowups.first {
                paragraphs.append(followup)
            }
            return paragraphs.joined(separator: " ")
        }
    }
}
