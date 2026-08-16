import Foundation

/// One stable identity used by aggregate queries. Profile identities come
/// from the People gallery. `explicitConfirmedTag` lets an otherwise unknown
/// human-entered tag participate without pretending it is a resolved profile.
struct ArchivistAggregateIdentity: Sendable, Equatable, Hashable {
    enum Source: String, Sendable, Equatable, Hashable {
        case profile
        case explicitConfirmedTag
    }

    let stableID: String
    let canonicalName: String
    let aliases: [String]
    let source: Source

    init(
        stableID: String,
        canonicalName: String,
        aliases: [String] = [],
        source: Source = .profile
    ) {
        self.stableID = stableID
        self.canonicalName = canonicalName
        self.aliases = aliases
        self.source = source
    }
}

/// Immutable alias index injected into detached aggregate execution.
/// A normalized spelling may resolve only when it names exactly one stable
/// identity. Shared aliases are surfaced and excluded instead of guessed.
struct ArchivistAggregateIdentityCatalog: Sendable, Equatable {
    enum Resolution: Sendable, Equatable {
        case resolved(ArchivistAggregateIdentity)
        case ambiguous(normalizedAlias: String, candidates: [String])
        case unknown
    }

    private let identitiesByID: [String: ArchivistAggregateIdentity]
    private let identityIDsByAlias: [String: [String]]

    init(identities: [ArchivistAggregateIdentity]) {
        // Sorting first makes duplicate input IDs deterministic. A stable ID
        // is one identity; repeated definitions never create two people.
        let ordered = identities.sorted(by: Self.identityOrder)
        var byID: [String: ArchivistAggregateIdentity] = [:]
        for identity in ordered where byID[identity.stableID] == nil {
            byID[identity.stableID] = identity
        }

        var aliases: [String: Set<String>] = [:]
        for identity in byID.values {
            for spelling in [identity.canonicalName] + identity.aliases {
                let key = Self.normalize(spelling)
                guard !key.isEmpty else { continue }
                aliases[key, default: []].insert(identity.stableID)
            }
        }
        identitiesByID = byID
        identityIDsByAlias = aliases.mapValues { $0.sorted() }
    }

    func resolve(_ spelling: String) -> Resolution {
        let key = Self.normalize(spelling)
        guard !key.isEmpty, let ids = identityIDsByAlias[key] else {
            return .unknown
        }
        guard ids.count == 1, let identity = identitiesByID[ids[0]] else {
            let names = ids.compactMap { identitiesByID[$0]?.canonicalName }
                .sorted(by: Self.canonicalNameOrder)
            return .ambiguous(normalizedAlias: key, candidates: names)
        }
        return .resolved(identity)
    }

    private static func identityOrder(
        _ lhs: ArchivistAggregateIdentity,
        _ rhs: ArchivistAggregateIdentity
    ) -> Bool {
        if canonicalNameOrder(lhs.canonicalName, rhs.canonicalName) {
            return true
        }
        if canonicalNameOrder(rhs.canonicalName, lhs.canonicalName) {
            return false
        }
        return lhs.stableID < rhs.stableID
    }

    fileprivate static func canonicalNameOrder(_ lhs: String, _ rhs: String) -> Bool {
        let left = normalize(lhs)
        let right = normalize(rhs)
        if left != right { return left < right }
        return lhs < rhs
    }

    fileprivate static func normalize(_ value: String) -> String {
        value.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .precomposedStringWithCanonicalMapping
    }
}

/// Immutable QueryAST projection. Array elements remain separate identity
/// groups; aliases resolving to the same person are not collapsed.
struct ArchivistAggregateQuery: Sendable, Equatable {
    let anchorPeople: [String]
    let requestedLimit: Int?

    init(_ payload: ArchivistQueryAST.Aggregate) {
        anchorPeople = payload.anchorPeople
        requestedLimit = payload.limit
    }
}

/// Purpose-built immutable record view for detached aggregate execution.
/// It intentionally excludes detected/suspected people: those fields do not
/// persist the score required to make an identity claim.
struct ArchivistAggregateRecordSnapshot: Sendable, Equatable {
    static let maxCaptureBatchSize = 512

    let id: UUID
    let fullPath: String
    let filename: String
    let isPlayable: Bool
    let confirmedPeople: [ConfirmedTag]

    init(
        id: UUID = UUID(),
        fullPath: String,
        filename: String? = nil,
        isPlayable: Bool = true,
        confirmedPeople: [ConfirmedTag]
    ) {
        self.id = id
        self.fullPath = fullPath
        self.filename = filename ?? (fullPath as NSString).lastPathComponent
        self.isPlayable = isPlayable
        self.confirmedPeople = confirmedPeople
    }

    // `@MainActor` ≈ "read this UI-owned object on the UI thread"; the
    // resulting value is immutable and safe to pass to Task.detached.
    @MainActor
    init(record: VideoRecord) {
        self.init(
            id: record.id,
            fullPath: record.fullPath,
            filename: record.filename,
            isPlayable: record.isPlayable == "Yes",
            confirmedPeople: record.confirmedByUserPeople)
    }

    @MainActor
    static func capture(
        _ records: [VideoRecord],
        batchSize requestedBatchSize: Int = maxCaptureBatchSize
    ) async -> [ArchivistAggregateRecordSnapshot] {
        let batchSize = min(max(1, requestedBatchSize), maxCaptureBatchSize)
        var result: [ArchivistAggregateRecordSnapshot] = []
        result.reserveCapacity(records.count)
        var start = 0
        while start < records.count {
            // Poll at the existing bounded batch boundary so cancellation
            // does not add work to each snapshot allocation.
            if Task.isCancelled { return result }
            let end = min(start + batchSize, records.count)
            for index in start..<end {
                result.append(.init(record: records[index]))
            }
            start = end
            if start < records.count { await Task.yield() }
        }
        return result
    }
}

struct ArchivistAggregateSampleCitation: Sendable, Equatable, Identifiable {
    let recordID: UUID
    let fullPath: String
    let filename: String
    let isPlayable: Bool
    /// Co-occurrence has record-level tags rather than frame-level evidence.
    /// This is nil until a timestamped human person annotation exists.
    let playbackSeconds: Double?
    let bases: [ArchivistEvidenceBasis]

    var id: UUID { recordID }
}

struct ArchivistAggregateRank: Sendable, Equatable, Identifiable {
    let identity: ArchivistAggregateIdentity
    /// Exact number of records, not the number of tag occurrences.
    let recordCount: Int
    let sampleCitations: [ArchivistAggregateSampleCitation]

    var id: String { identity.stableID }
}

enum ArchivistAggregateConclusion: Sendable, Equatable {
    case ranked
    case noEvidence
    case emptyAnchors
    case tooManyAnchors(count: Int, limit: Int)
    case unresolvedAnchors([String])
    case ambiguousAnchors([ArchivistAggregateAnchorAmbiguity])
    case incompleteIdentityEvidence(
        ambiguousAliases: [String], unknownTagSamples: [String])
    case invalidLimit(Int)
}

struct ArchivistAggregateAnchorAmbiguity: Sendable, Equatable {
    let queriedName: String
    let candidates: [String]
}

struct ArchivistAggregateResult: Sendable, Equatable {
    let conclusion: ArchivistAggregateConclusion
    let interpretedQuery: String
    let anchorIdentities: [ArchivistAggregateIdentity]
    let rankings: [ArchivistAggregateRank]
    let appliedLimit: Int
    let usedDefaultLimit: Bool
    /// Normalized shared aliases encountered in confirmed tags. The list is
    /// finite and bounded by the injected identity catalog's alias universe.
    let excludedAmbiguousAliases: [String]
    /// Deterministic bounded sample. The conclusion records that unknown tags
    /// exist even when the archive contains more distinct spellings.
    let excludedUnknownTagSamples: [String]

    var factualAnswer: ArchivistAggregateFactualAnswer {
        ArchivistAggregateAnswerComposer.compose(self)
    }
}

struct ArchivistAggregateFactualAnswer: Sendable, Equatable {
    let prose: String
    let basisLine: String
    let rankings: [ArchivistAggregateRank]
}

/// Pure, deterministic `.coOccurrence` execution over immutable values.
enum ArchivistAggregateExecutor {
    /// Visible product default when QueryAST omits an explicit top-N.
    static let defaultLimit = 10
    static let maxSampleCitationsPerPerson = 3
    static let maxUnknownTagSamples = 10
    private static let cancellationPollStride = 256

    private struct Accumulator {
        var recordCount = 0
        var citations: [ArchivistAggregateSampleCitation] = []
    }

    /// One streaming pass. Worst-case retained working memory is one counter
    /// and three small citations per injected identity, independent of archive
    /// record count. Media bytes and transcripts are never retained.
    static func execute(
        _ query: ArchivistAggregateQuery,
        records: [ArchivistAggregateRecordSnapshot],
        identities: ArchivistAggregateIdentityCatalog
    ) -> ArchivistAggregateResult {
        let usedDefault = query.requestedLimit == nil
        let limit = query.requestedLimit ?? defaultLimit
        guard ArchivistQueryAST.resultLimitRange.contains(limit) else {
            return emptyResult(
                conclusion: .invalidLimit(limit), query: query,
                anchors: [], limit: limit, usedDefault: usedDefault)
        }
        guard !query.anchorPeople.isEmpty else {
            return emptyResult(
                conclusion: .emptyAnchors, query: query, anchors: [],
                limit: limit, usedDefault: usedDefault)
        }
        guard query.anchorPeople.count <= ArchivistQueryAST.maxListItems else {
            return emptyResult(
                conclusion: .tooManyAnchors(
                    count: query.anchorPeople.count,
                    limit: ArchivistQueryAST.maxListItems),
                query: query, anchors: [], limit: limit,
                usedDefault: usedDefault)
        }

        var anchors: [ArchivistAggregateIdentity] = []
        var unknown: [String] = []
        var ambiguous: [ArchivistAggregateAnchorAmbiguity] = []
        for spelling in query.anchorPeople {
            switch identities.resolve(spelling) {
            case .resolved(let identity):
                anchors.append(identity)
            case .unknown:
                unknown.append(spelling)
            case .ambiguous(_, let candidates):
                ambiguous.append(.init(
                    queriedName: spelling, candidates: candidates))
            }
        }
        if !ambiguous.isEmpty {
            return emptyResult(
                conclusion: .ambiguousAnchors(ambiguous),
                query: query, anchors: anchors, limit: limit,
                usedDefault: usedDefault)
        }
        if !unknown.isEmpty {
            return emptyResult(
                conclusion: .unresolvedAnchors(unknown), query: query,
                anchors: anchors, limit: limit, usedDefault: usedDefault)
        }

        // One record cannot provide two independently assigned anchors using
        // one stable identity, even if two aliases for that identity are tags.
        let anchorIDs = anchors.map(\.stableID)
        guard !anchorIDs.isEmpty, Set(anchorIDs).count == anchorIDs.count else {
            return emptyResult(
                conclusion: .noEvidence, query: query, anchors: anchors,
                limit: limit, usedDefault: usedDefault)
        }
        let excludedIDs = Set(anchorIDs)
        var accumulated: [String: Accumulator] = [:]
        var identityByID: [String: ArchivistAggregateIdentity] = [:]
        var ambiguousAliases: Set<String> = []
        var unknownTagSamples: [String] = []
        var hasUnknownTag = false

        for (index, record) in records.enumerated() {
            if index.isMultiple(of: cancellationPollStride),
               Task.isCancelled {
                return emptyResult(
                    conclusion: .noEvidence,
                    query: query,
                    anchors: anchors,
                    limit: limit,
                    usedDefault: usedDefault)
            }
            var tagByIdentityID: [String: ConfirmedTag] = [:]
            var recordAmbiguousAliases: Set<String> = []
            var recordUnknownTags: [String] = []
            for tag in record.confirmedPeople {
                switch identities.resolve(tag.name) {
                case .resolved(let identity):
                    if let current = tagByIdentityID[identity.stableID] {
                        if tagOrder(tag, current) {
                            tagByIdentityID[identity.stableID] = tag
                        }
                    } else {
                        tagByIdentityID[identity.stableID] = tag
                    }
                    identityByID[identity.stableID] = identity
                case .ambiguous(let alias, _):
                    recordAmbiguousAliases.insert(alias)
                case .unknown:
                    recordUnknownTags.append(tag.name)
                }
            }

            guard anchorIDs.allSatisfy({ tagByIdentityID[$0] != nil }) else {
                continue
            }
            ambiguousAliases.formUnion(recordAmbiguousAliases)
            if !recordUnknownTags.isEmpty { hasUnknownTag = true }
            for name in recordUnknownTags {
                retainUnknownTagSample(name, in: &unknownTagSamples)
            }
            let anchorBases = zip(query.anchorPeople, anchorIDs).compactMap {
                spelling, id -> ArchivistEvidenceBasis? in
                guard let tag = tagByIdentityID[id] else { return nil }
                return .humanPersonTag(
                    queryIdentity: spelling, taggedName: tag.name,
                    confirmedAt: tag.confirmedAt)
            }

            for (identityID, tag) in tagByIdentityID {
                guard !excludedIDs.contains(identityID),
                      let identity = identityByID[identityID],
                      !isGenericFamily(identity) else { continue }

                let coPersonBasis = ArchivistEvidenceBasis.humanPersonTag(
                    queryIdentity: identity.canonicalName,
                    taggedName: tag.name,
                    confirmedAt: tag.confirmedAt)
                let citation = ArchivistAggregateSampleCitation(
                    recordID: record.id,
                    fullPath: record.fullPath,
                    filename: record.filename,
                    isPlayable: record.isPlayable,
                    playbackSeconds: nil,
                    bases: anchorBases + [coPersonBasis])
                var value = accumulated[identityID] ?? Accumulator()
                value.recordCount += 1
                retain(citation, in: &value.citations)
                accumulated[identityID] = value
            }
        }

        if !ambiguousAliases.isEmpty || hasUnknownTag {
            return ArchivistAggregateResult(
                conclusion: .incompleteIdentityEvidence(
                    ambiguousAliases: ambiguousAliases.sorted(),
                    unknownTagSamples: unknownTagSamples),
                interpretedQuery: description(
                    query, limit: limit, usedDefault: usedDefault),
                anchorIdentities: anchors,
                rankings: [],
                appliedLimit: limit,
                usedDefaultLimit: usedDefault,
                excludedAmbiguousAliases: ambiguousAliases.sorted(),
                excludedUnknownTagSamples: unknownTagSamples)
        }
        let ordered = accumulated.compactMap { identityID, value
            -> ArchivistAggregateRank? in
            guard let identity = identityByID[identityID] else { return nil }
            return ArchivistAggregateRank(
                identity: identity,
                recordCount: value.recordCount,
                sampleCitations: value.citations)
        }.sorted(by: rankOrder)
        let rankings = Array(ordered.prefix(limit))
        let conclusion: ArchivistAggregateConclusion = rankings.isEmpty
            ? .noEvidence : .ranked
        return ArchivistAggregateResult(
            conclusion: conclusion,
            interpretedQuery: description(query, limit: limit,
                                          usedDefault: usedDefault),
            anchorIdentities: anchors,
            rankings: rankings,
            appliedLimit: limit,
            usedDefaultLimit: usedDefault,
            excludedAmbiguousAliases: [],
            excludedUnknownTagSamples: [])
    }

    private static func emptyResult(
        conclusion: ArchivistAggregateConclusion,
        query: ArchivistAggregateQuery,
        anchors: [ArchivistAggregateIdentity],
        limit: Int,
        usedDefault: Bool
    ) -> ArchivistAggregateResult {
        ArchivistAggregateResult(
            conclusion: conclusion,
            interpretedQuery: description(query, limit: limit,
                                          usedDefault: usedDefault),
            anchorIdentities: anchors,
            rankings: [],
            appliedLimit: limit,
            usedDefaultLimit: usedDefault,
            excludedAmbiguousAliases: [],
            excludedUnknownTagSamples: [])
    }

    private static func description(
        _ query: ArchivistAggregateQuery,
        limit: Int,
        usedDefault: Bool
    ) -> String {
        // Keep failure descriptions bounded too: an in-process caller can
        // bypass QueryAST decoding and supply an arbitrarily large array.
        let people = query.anchorPeople.prefix(ArchivistQueryAST.maxListItems)
            .map { "anchor=\($0)" }
            .joined(separator: " ")
        let overflow = query.anchorPeople.count > ArchivistQueryAST.maxListItems
            ? " anchorCount=\(query.anchorPeople.count)" : ""
        return "shape=aggregate operation=coOccurrence \(people)\(overflow) limit=\(limit)"
            + (usedDefault ? " (default)" : "")
    }

    private static func isGenericFamily(
        _ identity: ArchivistAggregateIdentity
    ) -> Bool {
        ArchivistAggregateIdentityCatalog.normalize(identity.canonicalName)
            == "family"
    }

    private static func tagOrder(_ lhs: ConfirmedTag, _ rhs: ConfirmedTag) -> Bool {
        let left = ArchivistAggregateIdentityCatalog.normalize(lhs.name)
        let right = ArchivistAggregateIdentityCatalog.normalize(rhs.name)
        if left != right { return left < right }
        if lhs.name != rhs.name { return lhs.name < rhs.name }
        return lhs.confirmedAt < rhs.confirmedAt
    }

    /// Retain the lexicographically smallest distinct normalized spellings.
    /// This is deterministic across record order and caps memory even when an
    /// archive contains an unbounded number of one-off unknown tags.
    private static func retainUnknownTagSample(
        _ name: String,
        in samples: inout [String]
    ) {
        let normalized = ArchivistAggregateIdentityCatalog.normalize(name)
        guard !normalized.isEmpty, !samples.contains(normalized) else { return }
        samples.append(normalized)
        samples.sort()
        if samples.count > maxUnknownTagSamples {
            samples.removeLast(samples.count - maxUnknownTagSamples)
        }
    }

    private static func rankOrder(
        _ lhs: ArchivistAggregateRank,
        _ rhs: ArchivistAggregateRank
    ) -> Bool {
        if lhs.recordCount != rhs.recordCount {
            return lhs.recordCount > rhs.recordCount
        }
        if ArchivistAggregateIdentityCatalog.canonicalNameOrder(
            lhs.identity.canonicalName, rhs.identity.canonicalName) {
            return true
        }
        if ArchivistAggregateIdentityCatalog.canonicalNameOrder(
            rhs.identity.canonicalName, lhs.identity.canonicalName) {
            return false
        }
        return lhs.identity.stableID < rhs.identity.stableID
    }

    private static func retain(
        _ citation: ArchivistAggregateSampleCitation,
        in citations: inout [ArchivistAggregateSampleCitation]
    ) {
        citations.append(citation)
        citations.sort(by: citationOrder)
        if citations.count > maxSampleCitationsPerPerson {
            citations.removeLast(citations.count - maxSampleCitationsPerPerson)
        }
    }

    private static func citationOrder(
        _ lhs: ArchivistAggregateSampleCitation,
        _ rhs: ArchivistAggregateSampleCitation
    ) -> Bool {
        if lhs.isPlayable != rhs.isPlayable { return lhs.isPlayable }
        let left = lhs.fullPath.precomposedStringWithCanonicalMapping
        let right = rhs.fullPath.precomposedStringWithCanonicalMapping
        if left != right { return left < right }
        return lhs.recordID.uuidString < rhs.recordID.uuidString
    }
}

enum ArchivistAggregateAnswerComposer {
    static let noEvidenceProse = "I don't have evidence for that."

    static func compose(
        _ result: ArchivistAggregateResult
    ) -> ArchivistAggregateFactualAnswer {
        guard result.conclusion == .ranked else {
            let prose: String
            let basis: String
            switch result.conclusion {
            case .ranked:
                preconditionFailure("guard excludes ranked")
            case .noEvidence:
                prose = noEvidenceProse
                basis = "Basis: no human-confirmed co-occurrence evidence."
            case .emptyAnchors:
                prose = "I need at least one person to compare co-appearances."
                basis = "Basis: the aggregate query has no anchor person."
            case .tooManyAnchors(_, let limit):
                prose = "I can compare at most \(limit) anchor people at once."
                basis = "Basis: the aggregate query exceeds the identity limit."
            case .unresolvedAnchors(let names):
                prose = "I couldn't resolve the anchor "
                    + names.joined(separator: ", ") + "."
                basis = "Basis: every anchor must resolve to a known identity."
            case .ambiguousAnchors(let issues):
                prose = issues.map { issue in
                    "Which person did you mean by \(issue.queriedName): "
                        + issue.candidates.joined(separator: " or ") + "?"
                }.joined(separator: " ")
                basis = "Basis: shared aliases require identity clarification."
            case .incompleteIdentityEvidence(
                let ambiguousAliases, let unknownTagSamples):
                prose = "I can't rank co-appearances until the confirmed person "
                    + "tags with unresolved identities are clarified."
                let ambiguous = ambiguousAliases.isEmpty
                    ? "none" : ambiguousAliases.joined(separator: ", ")
                let unknown = unknownTagSamples.isEmpty
                    ? "none" : unknownTagSamples.joined(separator: ", ")
                basis = "Basis: ambiguous aliases: \(ambiguous); unknown tag "
                    + "samples: \(unknown)."
            case .invalidLimit:
                prose = "The requested result limit must be between 1 and 100."
                basis = "Basis: the aggregate result limit is invalid."
            }
            return ArchivistAggregateFactualAnswer(
                prose: prose,
                basisLine: basis,
                rankings: [])
        }
        let anchorNames = result.anchorIdentities.map(\.canonicalName)
            .joined(separator: " and ")
        let ranked = result.rankings.map { rank in
            let noun = rank.recordCount == 1 ? "record" : "records"
            return "\(rank.identity.canonicalName) (\(rank.recordCount) \(noun))"
        }.joined(separator: ", ")
        let limitLabel = result.usedDefaultLimit
            ? "default top \(result.appliedLimit)"
            : "requested top \(result.appliedLimit)"
        return ArchivistAggregateFactualAnswer(
            prose: "With \(anchorNames), I found: \(ranked).",
            basisLine: "Basis: authoritative human-confirmed tags; counts are "
                + "catalog records, not tag occurrences; \(limitLabel).",
            rankings: result.rankings)
    }
}
