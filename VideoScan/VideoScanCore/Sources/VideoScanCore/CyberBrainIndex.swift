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
    /// Everything NOT current about a person — retracted, superseded, or
    /// active-but-replaced — for the Family Tree's "Show corrections".
    /// Hallie never reads this (every answer path goes through
    /// `activeItemsByPersonID`).
    private let hiddenItemsByPersonID: [String: [CyberBrainItem]]
    private let itemsByID: [String: CyberBrainItem]
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
                // "Rick's dad" names the father by RICK's name; split into
                // words it filed the father under "rick" and every "rick"
                // question asked which one (2026-09-18). Whole match only.
                if Self.isPossessiveAlias(key) { continue }
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
        var hidden: [String: [CyberBrainItem]] = [:]
        for item in allItems {
            let current = item.status == .active && !superseded.contains(item.id)
            for personID in item.subjectPersonIDs {
                if current {
                    items[personID, default: []].append(item)
                } else {
                    hidden[personID, default: []].append(item)
                }
            }
        }
        self.activeItemsByPersonID = items.mapValues {
            $0.sorted(by: Self.itemPrecedes)
        }
        self.hiddenItemsByPersonID = hidden
        // The validator already proved ids are unique across the archive.
        self.itemsByID = Dictionary(uniqueKeysWithValues: allItems.map { ($0.id, $0) })

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

    /// An alias like "Rick's dad" or "Rick’s father": it describes a person
    /// relative to someone else, so none of its words are this person's name.
    public static func isPossessiveAlias(_ normalized: String) -> Bool {
        normalized.contains("'s ") || normalized.contains("\u{2019}s ")
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

    /// Any item by id, whatever its status. O(1).
    public func item(id: String) -> CyberBrainItem? { itemsByID[id] }

    /// The items about a person that are NOT current — taken back, moved
    /// away, or replaced by a newer wording — in file order. For the
    /// owner's "Show corrections" view only; never evidence.
    public func hiddenItems(for personID: String) -> [CyberBrainItem] {
        hiddenItemsByPersonID[personID] ?? []
    }

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

    /// The person's structured military-service stories (2026-09-23),
    /// active and visible at the ceiling, in evidence order. At most a
    /// handful per person, so no limit parameter.
    public func serviceItems(
        for personID: String,
        privacyCeiling: CyberBrainItem.Privacy
    ) -> [CyberBrainItem] {
        visibleEvidence(for: personID, privacyCeiling: privacyCeiling)
            .filter { $0.service != nil && $0.confidence != .disputed }
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

        // A structured service story (2026-09-23) is told when asked for —
        // Hallie OFFERS it after the biography ("Would you like to hear how
        // … served?") — so it is not one of the biography's claims. Unless
        // it is ALL the family has: then the story is the biography, and
        // there is nothing left to offer.
        let visible = index.visibleEvidence(
            for: person.id, privacyCeiling: privacyCeiling)
        let withoutService = visible.filter { $0.service == nil }
        let allVisible = claims.isEmpty && withoutService.isEmpty ? visible : withoutService
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
        func claim(_ id: String, _ text: String,
                   _ fact: CyberBrainAnswerPlan.TreeFact) -> CyberBrainAnswerPlan.Claim {
            .init(
                id: id, text: text, evidenceIDs: [sourceID],
                confidence: gedcomFactConfidence, treeFact: fact)
        }
        if let birth = person.birthDate {
            claims.append(claim(
                "\(sourceID):birth",
                "The imported family tree records \(birth) as \(displayName)'s birth date.",
                .init(kind: .birth, date: birth, subjectSex: person.sex)))
        }
        if let death = person.deathDate {
            claims.append(claim(
                "\(sourceID):death",
                "The imported family tree records \(death) as \(displayName)'s death date.",
                .init(kind: .death, date: death, subjectSex: person.sex)))
        }
        let relationships: [(GedcomFamilyGraph.Relation, String, CyberBrainAnswerPlan.TreeFact.Kind)] = [
            (.parents, "parents", .parents), (.spouse, "spouse", .spouse), (.children, "children", .children),
        ]
        for (relation, label, kind) in relationships {
            let names = ArchivistBiographyPolicy.orderedPeople(
                graph.relatives(relation, of: person)).map(\.name)
            if !names.isEmpty {
                claims.append(claim(
                    "\(sourceID):\(label)",
                    "The imported family tree records \(displayName)'s \(label) as \(names.joined(separator: ", ")).",
                    .init(kind: kind, names: names, subjectSex: person.sex)))
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
            // Family-tree facts are told together, with the source named
            // once; everything else (family notes, testimony) follows in
            // its own words.
            let treeFacts = plan.claims.compactMap(\.treeFact)
            let others = plan.claims.filter { $0.treeFact == nil }.map(\.text)
            if !treeFacts.isEmpty {
                paragraphs.append(CyberBrainTreeTelling.sentences(treeFacts, subject: plan.subject))
                if let first = others.first {
                    paragraphs.append("The family's notes add: " + first)
                    paragraphs.append(contentsOf: others.dropFirst())
                }
            } else {
                paragraphs.append(contentsOf: others)
            }
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

/// The spoken telling of a person's family-tree facts: one attribution,
/// grouped facts, pronouns from the recorded sex (the name when unknown).
/// "According to the family tree, John Robert Latta was born on 11
/// September 1835 and died on 30 June 1898. His parents were John C. Latta
/// and Priscilla Eldridge Shaw. He married Cathrine Black Ralston. His
/// children were …" Pure; nothing is added that the facts do not say.
public enum CyberBrainTreeTelling {
    public static func sentences(_ facts: [CyberBrainAnswerPlan.TreeFact], subject: String) -> String {
        guard let sex = facts.first?.subjectSex else { return "" }
        let (he, his) = pronouns(sex, subject: subject)
        func fact(_ kind: CyberBrainAnswerPlan.TreeFact.Kind) -> CyberBrainAnswerPlan.TreeFact? {
            facts.first { $0.kind == kind }
        }
        var out: [String] = []
        var life: [String] = []
        if let born = fact(.birth)?.date { life.append("was born \(onOrIn(born))") }
        if let died = fact(.death)?.date { life.append("died \(onOrIn(died))") }
        let lead = "According to the family tree, \(subject)"
        if !life.isEmpty {
            out.append("\(lead) \(life.joined(separator: " and ")).")
        }
        let opener: (String) -> String = { sentence in
            // The first sentence carries the attribution when no dates did.
            out.isEmpty ? "According to the family tree, " + lowercasedFirst(sentence) : sentence
        }
        if let parents = fact(.parents)?.names, !parents.isEmpty {
            out.append(opener(parents.count == 1
                ? "\(his) recorded parent was \(parents[0])."
                : "\(his) parents were \(list(parents))."))
        }
        if let spouses = fact(.spouse)?.names, !spouses.isEmpty {
            out.append(opener("\(he) married \(list(spouses))."))
        }
        if let children = fact(.children)?.names, !children.isEmpty {
            out.append(opener(children.count == 1
                ? "\(his) child was \(children[0])."
                : "\(his) children were \(list(children))."))
        }
        return out.joined(separator: " ")
    }

    static func pronouns(_ sex: String, subject: String) -> (String, String) {
        switch sex.uppercased() {
        case "M": return ("He", "His")
        case "F": return ("She", "Her")
        default: return (subject, subject + "'s")
        }
    }

    /// "on 11 September 1835" for a day, "in 1835" / "in MAR 1835" for a
    /// month or year. A qualified date ("ABT 1944", "BEF 1900", "BET 1830
    /// AND 1835") is told VERBATIM with no preposition — the telling never
    /// re-interprets a recorded value (CyberBrainTests pins exact evidence),
    /// and a year is never read as a day.
    static func onOrIn(_ date: String) -> String {
        let trimmed = date.trimmingCharacters(in: .whitespaces)
        let firstToken = trimmed.split(separator: " ").first.map(String.init) ?? ""
        if firstToken.contains(where: \.isLetter) {
            let months = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
            let isMonth = months.contains { firstToken.uppercased().hasPrefix($0) }
            return isMonth ? "in " + trimmed : trimmed
        }
        let startsWithDay = Int(firstToken).map { (1...31).contains($0) && firstToken.count <= 2 } ?? false
        return (startsWithDay ? "on " : "in ") + trimmed
    }

    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }

    static func lowercasedFirst(_ s: String) -> String {
        // "His parents…" → "his parents…" after the attribution; a name
        // (no pronoun) keeps its capital.
        for p in ["His ", "Her ", "He ", "She "] where s.hasPrefix(p) {
            return p.lowercased() + s.dropFirst(p.count)
        }
        return s
    }
}
