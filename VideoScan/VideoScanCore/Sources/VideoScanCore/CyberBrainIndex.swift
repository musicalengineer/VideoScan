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
    private let sourcesByID: [String: CyberBrainSource]
    private let activeItemsByPersonID: [String: [CyberBrainItem]]

    public init(archive: CyberBrainArchive) throws {
        try CyberBrainValidator.validate(archive)
        self.archive = archive
        self.peopleByID = Dictionary(uniqueKeysWithValues:
            archive.people.map { ($0.id, $0) })
        self.sourcesByID = Dictionary(uniqueKeysWithValues:
            archive.sources.map { ($0.id, $0) })

        var names: [String: [String]] = [:]
        for person in archive.people {
            for value in [person.canonicalName] + person.aliases {
                let key = Self.normalized(value)
                if !names[key, default: []].contains(person.id) {
                    names[key, default: []].append(person.id)
                }
            }
        }
        self.peopleByLookupName = names.mapValues { $0.sorted() }

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

        // A deterministic revision token suitable for cache invalidation. It
        // deliberately tracks semantic IDs and update dates, not JSON layout.
        let personMaterial = archive.people.map {
            "person:\($0.id):\($0.canonicalName):\($0.aliases.sorted().joined(separator: ",")):"
                + "\($0.terminology.sorted().joined(separator: ",")):"
                + "\($0.gedcomPersonID ?? ""):\($0.profileStableID?.uuidString ?? "")"
        }
        let itemMaterial = allItems.map {
            "item:\($0.id):\($0.updatedAt.timeIntervalSince1970):\($0.status.rawValue):"
                + "\($0.confidence.rawValue):\($0.privacy.rawValue):\($0.text)"
        }
        let sourceMaterial = archive.sources.map {
            "source:\($0.id):\($0.type.rawValue):\($0.title):"
                + "\($0.attribution ?? ""):\($0.locator ?? "")"
        }
        let revisionMaterial = (personMaterial + itemMaterial + sourceMaterial)
            .sorted().joined(separator: "|")
        self.generation = "v\(archive.schemaVersion):\(archive.archiveID):"
            + String(revisionMaterial.utf8.reduce(UInt64(14_695_981_039_346_656_037)) {
                ($0 ^ UInt64($1)) &* 1_099_511_628_211
            }, radix: 16)
    }

    public func resolve(_ name: String) -> CyberBrainIdentityResolution {
        let ids = peopleByLookupName[Self.normalized(name)] ?? []
        let people = ids.compactMap { peopleByID[$0] }
            .sorted { lhs, rhs in
                let left = Self.normalized(lhs.canonicalName)
                let right = Self.normalized(rhs.canonicalName)
                return left == right ? lhs.id < rhs.id : left < right
            }
        if people.count == 1 { return .resolved(people[0]) }
        if people.isEmpty { return .notFound }
        return .ambiguous(people)
    }

    public func person(id: String) -> CyberBrainPerson? { peopleByID[id] }
    public func source(id: String) -> CyberBrainSource? { sourcesByID[id] }

    public func evidence(
        for personID: String,
        privacyCeiling: CyberBrainItem.Privacy,
        limit: Int = 12
    ) -> [CyberBrainItem] {
        let bounded = min(max(0, limit), 50)
        return (activeItemsByPersonID[personID] ?? [])
            .lazy
            .filter { $0.privacy.isVisible(at: privacyCeiling) }
            .prefix(bounded)
            .map { $0 }
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

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive],
                      locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .precomposedStringWithCanonicalMapping
    }
}

public enum CyberBrainBiographyPlanner {
    public static func plan(
        personName: String,
        index: CyberBrainIndex,
        graph: GedcomFamilyGraph? = nil,
        privacyCeiling: CyberBrainItem.Privacy = .private,
        itemLimit: Int = 8
    ) -> CyberBrainAnswerPlan {
        switch index.resolve(personName) {
        case .notFound:
            return CyberBrainAnswerPlan(
                subject: personName,
                answerState: .noEvidence,
                uncertaintyStatements: [
                    "I don't find that person in the CyberBrain identity index."
                ],
                forbiddenClaims: ["Do not infer an identity from a partial name."])
        case .ambiguous(let people):
            return CyberBrainAnswerPlan(
                subject: personName,
                answerState: .ambiguous,
                uncertaintyStatements: ["More than one person uses that name or alias."],
                permittedActions: ["narrow"],
                forbiddenClaims: ["Do not choose one ambiguous identity."],
                ambiguityCandidates: people.map {
                    .init(id: $0.id, canonicalName: $0.canonicalName)
                })
        case .resolved(let person):
            return resolvedPlan(person: person, index: index, graph: graph,
                                privacyCeiling: privacyCeiling,
                                itemLimit: itemLimit)
        }
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
        var forbidden = ["Do not add biographical facts absent from these claims."]

        if let gedcomID = person.gedcomPersonID,
           let gedcomPerson = graph?.people[gedcomID] {
            let sourceID = "gedcom:\(gedcomID)"
            citations[sourceID] = .init(
                id: sourceID,
                title: "Imported family tree (GEDCOM)",
                attribution: nil,
                locator: nil)
            if let birth = gedcomPerson.birthDate {
                claims.append(.init(
                    id: "gedcom:\(gedcomID):birth",
                    text: "The imported family tree records \(birth) as \(person.canonicalName)'s birth date.",
                    evidenceIDs: [sourceID],
                    confidence: .probable))
            }
            if let death = gedcomPerson.deathDate {
                claims.append(.init(
                    id: "gedcom:\(gedcomID):death",
                    text: "The imported family tree records \(death) as \(person.canonicalName)'s death date.",
                    evidenceIDs: [sourceID],
                    confidence: .probable))
            }
        } else if person.gedcomPersonID != nil {
            uncertainty.append("The person's GEDCOM bridge is not available in the current family tree.")
        }

        let evidence = index.evidence(for: person.id,
                                      privacyCeiling: privacyCeiling,
                                      limit: itemLimit)
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
        if evidence.contains(where: { $0.confidence == .disputed }) {
            state = .disputed
            forbidden.append("Do not resolve the disputed account without new evidence.")
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
            permittedActions: citations.isEmpty ? [] : ["showSource"],
            forbiddenClaims: forbidden)
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
            var paragraphs = plan.claims.map(\.text)
            paragraphs.append(contentsOf: plan.uncertaintyStatements)
            if !plan.sourceCitations.isEmpty {
                let count = plan.sourceCitations.count
                paragraphs.append("I can show \(count) supporting source\(count == 1 ? "" : "s").")
            }
            if let followup = plan.suggestedFollowups.first { paragraphs.append(followup) }
            return paragraphs.joined(separator: " ")
        }
    }
}
