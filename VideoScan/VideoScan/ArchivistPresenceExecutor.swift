import Foundation

/// Exact, inspectable reason a record supports a factual presence answer.
/// Machine-only identity arrays are deliberately absent: production records
/// do not persist their numeric score, so they cannot satisfy the contract's
/// required machine tier+score citation.
enum ArchivistEvidenceBasis: Sendable, Equatable {
    case humanPersonTag(queryIdentity: String, taggedName: String,
                        confirmedAt: Date)
    case catalogField(field: String, queryTerm: String, matchedValue: String)
    case inferredDate(year: Int, confidence: Float?)
    case fileDate(field: String, year: Int, date: Date)
    case pathYear(year: Int, fullPath: String)
    case mediaKind(requested: String, streamType: String)
    case transcriptMention(queryTerm: String, model: String?)
    case caption(queryTerm: String, timestamp: Double, text: String,
                 model: String?)
    /// Token-tier keyword evidence: every significant token of `queryTerm`
    /// (or of `alias`, when non-nil) is a token of `matchedValue`. Cited
    /// distinctly from a whole-phrase hit so the basis line says exactly what
    /// matched ("filename token 'cape' for 'down the cape'").
    case keywordTokens(field: String, queryTerm: String,
                       matchedTokens: [String], alias: String?,
                       matchedValue: String, timestamp: Double?)

    /// One human-readable summary shared by the chat window, the shell, and
    /// the conversation log so evidence wording cannot drift between clients.
    var summary: String {
        switch self {
        case .humanPersonTag(let query, let tag, _):
            return "confirmed person tag \(tag) proves \(query)"
        case .catalogField(let field, let query, let value):
            return "\(field) contains \(query) (\(value))"
        case .inferredDate(let year, let confidence):
            let confidenceText = confidence.map {
                String(format: "%.2f", $0)
            } ?? "unrecorded"
            return "inferred year \(year), confidence \(confidenceText)"
        case .fileDate(let field, let year, _):
            return "\(field) year \(year)"
        case .pathYear(let year, _):
            return "path year \(year)"
        case .mediaKind(let requested, let stream):
            return "media \(requested) (\(stream))"
        case .transcriptMention(let term, let model):
            return "transcript mentions \(term) (\(model ?? "model unrecorded"))"
        case .caption(let term, let time, _, let model):
            return "caption mentions \(term) at "
                + String(format: "%.1fs", time)
                + " (\(model ?? "model unrecorded"))"
        case .keywordTokens(let field, let query, let tokens, let alias,
                            let value, let timestamp):
            let noun = tokens.count == 1 ? "token" : "tokens"
            let quoted = "'" + tokens.joined(separator: " ") + "'"
            let at = timestamp.map { String(format: " at %.1fs", $0) } ?? ""
            if let alias {
                return "\(field) \(noun) \(quoted) via alias '\(alias)' of "
                    + "'\(query)'\(at) (\(value))"
            }
            return "\(field) \(noun) \(quoted) for '\(query)'\(at) (\(value))"
        }
    }
}

struct ArchivistEvidenceCitation: Sendable, Equatable, Identifiable {
    let recordID: UUID
    let fullPath: String
    let filename: String
    let playbackSeconds: Double?
    let bases: [ArchivistEvidenceBasis]

    var id: UUID { recordID }
}

struct ArchivistEvidenceSet: Sendable, Equatable {
    let citations: [ArchivistEvidenceCitation]
    /// Exact proven count, independent of the bounded citation list.
    let totalMatchCount: Int
    let isCitationListTruncated: Bool
}

enum ArchivistPresenceConclusion: Sendable, Equatable {
    case present
    case noEvidence
    case insufficientConstraints
    /// Nothing matched every facet, but dropping ONE named facet does match.
    /// The evidence set belongs to the relaxed query — labelled as such, never
    /// presented as an answer to what was asked (Rick 2026-08-21).
    case noEvidenceButRelaxed(dropped: RelaxedFacet)
}

/// The facet a relaxed retry gave up, in the order the ladder tries them.
///
/// PEOPLE ARE NEVER RELAXED. Dropping the person answers a different question
/// and would let a machine-detected or untagged record stand in for someone
/// the user named — exactly what
/// `familySearchConvenienceDoesNotBecomePresenceEvidence` has always
/// forbidden. Every relaxed answer therefore still carries that person's
/// confirmed tag; only the circumstances around them widen.
enum RelaxedFacet: String, Sendable, Equatable, CaseIterable {
    case years
    case keywords
    case mediaKind

    /// How the answer names what it set aside.
    var phrase: String {
        switch self {
        case .years:     return "the years you asked for"
        case .keywords:  return "that wording"
        case .mediaKind: return "that kind of media"
        }
    }
}

struct ArchivistPresenceResult: Sendable, Equatable {
    let conclusion: ArchivistPresenceConclusion
    let interpretedQuery: String
    let evidence: ArchivistEvidenceSet
}

struct ArchivistFactualAnswer: Sendable, Equatable {
    let prose: String
    let basisLine: String
    let evidence: ArchivistEvidenceSet
}

/// Immutable query value copied from QueryAST before detached execution.
/// `people` preserves the AST's identity grouping: one array element is one
/// identity, even when that identity contains multiple words.
struct ArchivistPresenceQuery: Sendable, Equatable {
    struct Identity: Sendable, Equatable {
        let original: String
        let tokens: [String]

        init(_ value: String) {
            original = value
            tokens = value.folding(
                options: [.diacriticInsensitive, .caseInsensitive],
                locale: Locale(identifier: "en_US"))
                .lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
        }
    }

    let people: [Identity]
    let years: ClosedRange<Int>?
    let mediaKind: String?
    let keywords: [String]
    /// Pre-computed once per query: normalized phrase, significant tokens,
    /// and alias token lists for each keyword.
    let keywordQueries: [ArchivistKeywordQuery]
    let hasInvalidYearRange: Bool
    /// Paging: how many proven matches to skip before collecting citations
    /// ("show more" re-runs the same query with the offset advanced). The
    /// exact count is still computed over every record.
    let citationOffset: Int

    /// Copy of this query with one facet removed — the relax-and-explain
    /// ladder (Rick 2026-08-21: a dead-end "I don't have evidence for that"
    /// is the worst answer she gives; "nothing with all three, but I do have
    /// 34 of Donna at the Cape" is the useful one).
    func dropping(_ facet: RelaxedFacet) -> ArchivistPresenceQuery {
        ArchivistPresenceQuery(
            people: people,
            years: facet == .years ? nil : years,
            mediaKind: facet == .mediaKind ? nil : mediaKind,
            keywords: facet == .keywords ? [] : keywords,
            keywordQueries: facet == .keywords ? [] : keywordQueries,
            citationOffset: 0)
    }

    private init(people: [Identity], years: ClosedRange<Int>?, mediaKind: String?,
                 keywords: [String], keywordQueries: [ArchivistKeywordQuery],
                 citationOffset: Int) {
        self.people = people
        self.years = years
        self.mediaKind = mediaKind
        self.keywords = keywords
        self.keywordQueries = keywordQueries
        self.citationOffset = citationOffset
        self.hasInvalidYearRange = false
    }

    init(_ payload: ArchivistQueryAST.Presence, citationOffset: Int = 0) {
        self.citationOffset = max(0, citationOffset)
        people = (payload.people ?? []).map(Identity.init)
        if let start = payload.yearStart ?? payload.yearEnd,
           let end = payload.yearEnd ?? payload.yearStart {
            if start <= end {
                years = start...end
                hasInvalidYearRange = false
            } else {
                years = nil
                hasInvalidYearRange = true
            }
        } else {
            years = nil
            hasInvalidYearRange = false
        }
        mediaKind = payload.mediaKind?.rawValue
        keywords = payload.keywords ?? []
        keywordQueries = keywords.map(ArchivistKeywordQuery.init)
    }

    var isEmpty: Bool {
        people.isEmpty && years == nil && mediaKind == nil && keywords.isEmpty
    }

    /// How many facets this query constrains on (the relax ladder only runs
    /// when there are at least two).
    var facetCount: Int {
        (people.isEmpty ? 0 : 1) + (years == nil ? 0 : 1)
            + (mediaKind == nil ? 0 : 1) + (keywords.isEmpty ? 0 : 1)
    }

    func has(_ facet: RelaxedFacet) -> Bool {
        switch facet {
        case .years:     return years != nil
        case .keywords:  return !keywords.isEmpty
        case .mediaKind: return mediaKind != nil
        }
    }

    var description: String {
        var parts = ["shape=presence"]
        parts.append(contentsOf: people.map { "person=\($0.original)" })
        if let years {
            parts.append(years.lowerBound == years.upperBound
                         ? "year=\(years.lowerBound)"
                         : "years=\(years.lowerBound)...\(years.upperBound)")
        }
        if let mediaKind { parts.append("mediaKind=\(mediaKind)") }
        parts.append(contentsOf: keywords.map { "keyword=\($0)" })
        return parts.joined(separator: " ")
    }
}

/// Sendable, purpose-built record view for off-main presence evaluation.
/// Snapshot extraction is the only operation that touches `VideoRecord`.
/// At 100k records the fixed value storage is roughly 25–35 MB; Swift's
/// String/Array copy-on-write buffers share the catalog's existing text and
/// annotation storage, so transcripts, captions, and media bytes are not
/// duplicated. The executor streams this array and retains only 25 citations.
/// Production should cache these snapshots and refresh them when the catalog
/// changes; never rebuild a 100k-record snapshot array inside a SwiftUI body.
struct ArchivistPresenceRecordSnapshot: Sendable, Equatable {
    static let maxCaptureBatchSize = 512
    let id: UUID
    let fullPath: String
    let filename: String
    let directory: String
    let volumeName: String
    let streamTypeRaw: String
    let dateCreated: Date?
    let dateModified: Date?
    let inferredDate: Date?
    let inferredDateConfidence: Float?
    let confirmedPeople: [ConfirmedTag]
    let tags: [String]
    let userNotes: String
    let captions: [SceneCaption]
    let captionModel: String?
    let transcript: String?
    let transcriptModel: String?
    let ocrDateCandidates: [SceneCaption]
    let ocrText: [SceneCaption]

    init(
        id: UUID = UUID(),
        fullPath: String,
        filename: String? = nil,
        directory: String = "",
        volumeName: String = "",
        streamTypeRaw: String = StreamType.videoAndAudio.rawValue,
        dateCreated: Date? = nil,
        dateModified: Date? = nil,
        inferredDate: Date? = nil,
        inferredDateConfidence: Float? = nil,
        confirmedPeople: [ConfirmedTag] = [],
        tags: [String] = [],
        userNotes: String = "",
        captions: [SceneCaption] = [],
        captionModel: String? = nil,
        transcript: String? = nil,
        transcriptModel: String? = nil,
        ocrDateCandidates: [SceneCaption] = [],
        ocrText: [SceneCaption] = []
    ) {
        self.id = id
        self.fullPath = fullPath
        self.filename = filename ?? (fullPath as NSString).lastPathComponent
        self.directory = directory
        self.volumeName = volumeName
        self.streamTypeRaw = streamTypeRaw
        self.dateCreated = dateCreated
        self.dateModified = dateModified
        self.inferredDate = inferredDate
        self.inferredDateConfidence = inferredDateConfidence
        self.confirmedPeople = confirmedPeople
        self.tags = tags
        self.userNotes = userNotes
        self.captions = captions
        self.captionModel = captionModel
        self.transcript = transcript
        self.transcriptModel = transcriptModel
        self.ocrDateCandidates = ocrDateCandidates
        self.ocrText = ocrText
    }

    // `@MainActor` is Swift's equivalent of "read this UI-owned object only
    // on the UI thread"; the resulting value has no actor affinity.
    @MainActor
    init(record: VideoRecord) {
        self.init(
            id: record.id,
            fullPath: record.fullPath,
            filename: record.filename,
            directory: record.directory,
            volumeName: record.volumeName,
            streamTypeRaw: record.streamTypeRaw,
            dateCreated: record.dateCreatedRaw,
            dateModified: record.dateModifiedRaw,
            inferredDate: record.inferredRecordDate,
            inferredDateConfidence: record.inferredDateConfidence,
            confirmedPeople: record.confirmedByUserPeople,
            tags: record.tags,
            userNotes: record.userNotes,
            captions: record.sceneCaptions,
            captionModel: record.sceneCaptionModel,
            transcript: record.audioTranscript,
            transcriptModel: record.audioTranscriptModel,
            ocrDateCandidates: record.ocrDateCandidates,
            ocrText: record.ocrText)
    }

    /// Bulk bridge yields between bounded batches so snapshot refresh cannot
    /// monopolize the UI actor. Batch size is clamped even for test callers.
    @MainActor
    static func capture(
        _ records: [VideoRecord],
        batchSize requestedBatchSize: Int = maxCaptureBatchSize
    ) async -> [ArchivistPresenceRecordSnapshot] {
        let batchSize = min(max(1, requestedBatchSize), maxCaptureBatchSize)
        var snapshots: [ArchivistPresenceRecordSnapshot] = []
        snapshots.reserveCapacity(records.count)
        var start = 0
        while start < records.count {
            // Cancellation is sampled once per bounded batch. Returning the
            // partial snapshot preserves this nonthrowing bridge's API; the
            // turn executor's cancellation checkpoint prevents its use.
            if Task.isCancelled { return snapshots }
            let end = min(start + batchSize, records.count)
            for index in start..<end {
                snapshots.append(ArchivistPresenceRecordSnapshot(
                    record: records[index]))
            }
            start = end
            if start < records.count { await Task.yield() }
        }
        return snapshots
    }
}

/// Pure, nonisolated presence evaluation over immutable values. Callers may
/// run this from `Task.detached` or another worker after snapshot extraction.
enum ArchivistPresenceExecutor {
    /// Worst-case retained answer memory is 25 citations and their bounded
    /// evidence payloads. All records are still evaluated for the exact count.
    static let maxCitations = 25
    private static let cancellationPollStride = 256

    static func execute(
        _ query: ArchivistPresenceQuery,
        records: [ArchivistPresenceRecordSnapshot]
    ) -> ArchivistPresenceResult {
        guard !query.hasInvalidYearRange, !query.isEmpty else {
            return emptyResult(.insufficientConstraints, query: query)
        }

        var citations: [ArchivistEvidenceCitation] = []
        citations.reserveCapacity(maxCitations)
        var provenMatchCount = 0
        for (index, record) in records.enumerated() {
            if index.isMultiple(of: cancellationPollStride),
               Task.isCancelled {
                return emptyResult(.noEvidence, query: query)
            }
            guard let citation = citation(for: record, query: query) else {
                continue
            }
            provenMatchCount += 1
            if provenMatchCount > query.citationOffset,
               citations.count < maxCitations {
                citations.append(citation)
            }
        }

        guard provenMatchCount > 0 else {
            return relaxedResult(for: query, records: records)
        }
        return ArchivistPresenceResult(
            conclusion: .present,
            interpretedQuery: query.description,
            evidence: ArchivistEvidenceSet(
                citations: citations,
                totalMatchCount: provenMatchCount,
                isCitationListTruncated:
                    query.citationOffset + citations.count < provenMatchCount))
    }

    /// The relax-and-explain ladder: when the full AND finds nothing, retry
    /// once per facet in a fixed order and keep the FIRST that matches, so
    /// the answer can say what it set aside and offer what it does have.
    /// Only queries with two or more facets relax — dropping the only facet
    /// would "answer" a different question entirely.
    static func relaxedResult(
        for query: ArchivistPresenceQuery,
        records: [ArchivistPresenceRecordSnapshot]
    ) -> ArchivistPresenceResult {
        guard query.facetCount >= 2 else { return emptyResult(.noEvidence, query: query) }
        for facet in RelaxedFacet.allCases where query.has(facet) {
            let relaxed = query.dropping(facet)
            guard !relaxed.isEmpty else { continue }
            var citations: [ArchivistEvidenceCitation] = []
            var count = 0
            for record in records {
                guard let citation = citation(for: record, query: relaxed) else { continue }
                count += 1
                if citations.count < maxCitations { citations.append(citation) }
            }
            guard count > 0, isUsefulNearMiss(count: count, of: records.count) else { continue }
            return ArchivistPresenceResult(
                conclusion: .noEvidenceButRelaxed(dropped: facet),
                interpretedQuery: query.description,
                evidence: ArchivistEvidenceSet(
                    citations: citations,
                    totalMatchCount: count,
                    isCitationListTruncated: count > citations.count))
        }
        return emptyResult(.noEvidence, query: query)
    }

    /// The largest relaxed offer worth making at all.
    static let relaxedOfferLimit = 200

    /// A relaxed answer is only worth offering when it is a NEAR miss. Eval
    /// 2026-08-21: "find videos shot on the old camcorder" dropped the only
    /// keyword and cheerfully offered "5877 items" — the entire catalog,
    /// which answers nothing and reads as a non-sequitur. An offer must be
    /// bounded absolutely AND be a small share of what was searched.
    /// A handful is always worth offering, whatever share of the corpus it
    /// happens to be — "I do have 2" is helpful even in a tiny catalog. The
    /// share test only guards against offering a large slab of everything.
    static let alwaysUsefulOfferCount = 25

    static func isUsefulNearMiss(count: Int, of searched: Int) -> Bool {
        guard count <= relaxedOfferLimit else { return false }
        if count <= alwaysUsefulOfferCount { return true }
        guard searched > 0 else { return true }
        return count * 4 < searched
    }

    private static func emptyResult(
        _ conclusion: ArchivistPresenceConclusion,
        query: ArchivistPresenceQuery
    ) -> ArchivistPresenceResult {
        ArchivistPresenceResult(
            conclusion: conclusion,
            interpretedQuery: query.isEmpty ? "" : query.description,
            evidence: ArchivistEvidenceSet(
                citations: [], totalMatchCount: 0,
                isCitationListTruncated: false))
    }

    private static func citation(
        for record: ArchivistPresenceRecordSnapshot,
        query: ArchivistPresenceQuery
    ) -> ArchivistEvidenceCitation? {
        var bases: [ArchivistEvidenceBasis] = []

        // Preserve identity groups and enforce a one-to-one assignment.
        // Augmenting paths avoid the greedy trap where a broad identity
        // consumes the only tag capable of proving a later specific one.
        guard let personBases = assignedPersonBases(
            identities: query.people, tags: record.confirmedPeople) else {
            return nil
        }
        bases.append(contentsOf: personBases)
        if let years = query.years {
            guard let basis = yearBasis(years, in: record) else { return nil }
            bases.append(basis)
        }
        if let mediaKind = query.mediaKind {
            guard mediaKindMatches(mediaKind, streamTypeRaw: record.streamTypeRaw)
            else { return nil }
            bases.append(.mediaKind(
                requested: mediaKind, streamType: record.streamTypeRaw))
        }
        for keyword in query.keywordQueries {
            guard let basis = keywordBasis(keyword, in: record) else { return nil }
            bases.append(basis)
        }

        let playback = bases.compactMap { basis -> Double? in
            switch basis {
            case .caption(_, let timestamp, _, _): return timestamp
            case .keywordTokens(_, _, _, _, _, let timestamp): return timestamp
            default: return nil
            }
        }.min()
        return ArchivistEvidenceCitation(
            recordID: record.id,
            fullPath: record.fullPath,
            filename: record.filename,
            playbackSeconds: playback,
            bases: bases)
    }

    private static func oneTag(
        _ tagName: String,
        provesIdentity identity: ArchivistPresenceQuery.Identity
    ) -> Bool {
        guard !identity.tokens.isEmpty else { return false }
        let available = Set(identityTokens(tagName))
        return identity.tokens.allSatisfy(available.contains)
    }

    /// Small bipartite maximum matching. Family queries are capped at six
    /// identities, so this is bounded and allocation remains negligible.
    private static func assignedPersonBases(
        identities: [ArchivistPresenceQuery.Identity],
        tags: [ConfirmedTag]
    ) -> [ArchivistEvidenceBasis]? {
        guard !identities.isEmpty else { return [] }
        var tagToIdentity = Array<Int?>(repeating: nil, count: tags.count)

        func assign(_ identityIndex: Int, visited: inout Set<Int>) -> Bool {
            for tagIndex in tags.indices
                where oneTag(tags[tagIndex].name,
                             provesIdentity: identities[identityIndex]) {
                guard visited.insert(tagIndex).inserted else { continue }
                if tagToIdentity[tagIndex] == nil {
                    tagToIdentity[tagIndex] = identityIndex
                    return true
                }
                if let displaced = tagToIdentity[tagIndex],
                   assign(displaced, visited: &visited) {
                    tagToIdentity[tagIndex] = identityIndex
                    return true
                }
            }
            return false
        }

        for identityIndex in identities.indices {
            var visited: Set<Int> = []
            guard assign(identityIndex, visited: &visited) else { return nil }
        }

        var identityToTag = Array<Int?>(repeating: nil, count: identities.count)
        for (tagIndex, identityIndex) in tagToIdentity.enumerated() {
            if let identityIndex { identityToTag[identityIndex] = tagIndex }
        }
        var bases: [ArchivistEvidenceBasis] = []
        bases.reserveCapacity(identities.count)
        for identityIndex in identities.indices {
            guard let tagIndex = identityToTag[identityIndex] else { return nil }
            let identity = identities[identityIndex]
            let tag = tags[tagIndex]
            bases.append(.humanPersonTag(
                queryIdentity: identity.original, taggedName: tag.name,
                confirmedAt: tag.confirmedAt))
        }
        return bases
    }

    private static func identityTokens(_ value: String) -> [String] {
        identityNormalized(value)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    private static func yearBasis(
        _ range: ClosedRange<Int>,
        in record: ArchivistPresenceRecordSnapshot
    ) -> ArchivistEvidenceBasis? {
        if let date = record.inferredDate {
            let year = pfGregorianCalendar.component(.year, from: date)
            if range.contains(year) {
                return .inferredDate(
                    year: year, confidence: record.inferredDateConfidence)
            }
        }
        if let year = standalonePathYear(in: record.fullPath, matching: range) {
            return .pathYear(year: year, fullPath: record.fullPath)
        }
        if let date = record.dateModified {
            let year = pfGregorianCalendar.component(.year, from: date)
            if range.contains(year) {
                return .fileDate(field: "dateModified", year: year, date: date)
            }
        }
        if let date = record.dateCreated {
            let year = pfGregorianCalendar.component(.year, from: date)
            if range.contains(year) {
                return .fileDate(field: "dateCreated", year: year, date: date)
            }
        }
        return nil
    }

    /// Tier 1: whole-phrase substring (strongest, cited as "contains").
    /// Tier 2: every significant token of the keyword is a token of a value.
    /// Tier 3: the same token test for each alias in ArchivistKeywordAliases.
    /// A keyword with no significant tokens ("the video") only gets tier 1.
    private static func keywordBasis(
        _ keyword: ArchivistKeywordQuery,
        in record: ArchivistPresenceRecordSnapshot
    ) -> ArchivistEvidenceBasis? {
        if let basis = phraseKeywordBasis(keyword, in: record) {
            return basis
        }
        guard !keyword.significantTokens.isEmpty else { return nil }
        // List 0 is the keyword's own tokens (tier 2); the rest are aliases
        // (tier 3). One field scan serves all of them.
        guard let hit = ArchivistKeywordFieldScan.firstValue(
            in: record, containingAnyOf: keyword.tokenListBytes) else {
            return nil
        }
        let matched = keyword.tokenLists[hit.listIndex]
        return .keywordTokens(
            field: hit.field, queryTerm: keyword.original,
            matchedTokens: matched,
            alias: hit.listIndex == 0 ? nil : matched.joined(separator: " "),
            matchedValue: hit.value, timestamp: hit.timestamp)
    }

    private static func phraseKeywordBasis(
        _ keyword: ArchivistKeywordQuery,
        in record: ArchivistPresenceRecordSnapshot
    ) -> ArchivistEvidenceBasis? {
        let queryTerm = keyword.original
        let phrase = keyword.phrase
        guard !phrase.isEmpty else { return nil }
        let phraseBytes = keyword.phraseBytes
        func contains(_ value: String) -> Bool {
            ArchivistKeywordText.withFoldedBytes(value) {
                ArchivistKeywordText.containsPhrase(phraseBytes, in: $0)
            }
        }
        func catalog(_ field: String, _ values: [String]) -> ArchivistEvidenceBasis? {
            guard let value = values.first(where: { contains($0) }) else {
                return nil
            }
            return .catalogField(
                field: field, queryTerm: queryTerm, matchedValue: value)
        }

        // Note: the former camelCase-spaced path variant ("cape cod" vs
        // "CapeCod") is subsumed by the token tier, which cites it honestly
        // as a token hit instead of a literal "contains".
        if let basis = catalog("tag", record.tags) { return basis }
        if let basis = catalog("userNotes", [record.userNotes]) { return basis }
        if let basis = catalog("filename", [record.filename]) { return basis }
        if let basis = catalog("directory", [record.directory]) { return basis }
        if let basis = catalog("volumeName", [record.volumeName]) { return basis }
        if let tag = record.confirmedPeople.first(where: {
            contains($0.name)
        }) {
            return .humanPersonTag(
                queryIdentity: queryTerm, taggedName: tag.name,
                confirmedAt: tag.confirmedAt)
        }
        if let transcript = record.transcript, contains(transcript) {
            return .transcriptMention(
                queryTerm: queryTerm, model: record.transcriptModel)
        }
        if let caption = record.captions.first(where: {
            contains($0.text)
        }) {
            return .caption(
                queryTerm: queryTerm, timestamp: caption.timestamp,
                text: caption.text, model: record.captionModel)
        }
        if let basis = catalog("ocrDate", record.ocrDateCandidates.map(\.text)) {
            return basis
        }
        return catalog("ocrText", record.ocrText.map(\.text))
    }

    private static func mediaKindMatches(
        _ requested: String,
        streamTypeRaw: String
    ) -> Bool {
        switch requested {
        case "video":
            return streamTypeRaw == StreamType.videoAndAudio.rawValue
                || streamTypeRaw == StreamType.videoOnly.rawValue
        case "video-only": return streamTypeRaw == StreamType.videoOnly.rawValue
        case "audio": return streamTypeRaw == StreamType.audioOnly.rawValue
        case "both": return streamTypeRaw == StreamType.videoAndAudio.rawValue
        default: return false
        }
    }

    private static func identityNormalized(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive],
                      locale: Locale(identifier: "en_US"))
            .lowercased().precomposedStringWithCanonicalMapping
    }

    /// One O(path length) scan, independent of the requested range width.
    private static func standalonePathYear(
        in path: String,
        matching range: ClosedRange<Int>
    ) -> Int? {
        var digits = ""
        func matchingRun() -> Int? {
            guard digits.count == 4, let year = Int(digits),
                  (1900...2099).contains(year), range.contains(year) else {
                return nil
            }
            return year
        }
        for character in path {
            if character.isNumber {
                digits.append(character)
            } else {
                if let year = matchingRun() { return year }
                digits.removeAll(keepingCapacity: true)
            }
        }
        return matchingRun()
    }

}

enum ArchivistPresenceAnswerComposer {
    static let noEvidenceProse = "I didn't find a match for that in the archive. "
        + "Try removing a name, place, or year, and I'll look again."

    /// A no-evidence answer that says what was looked for and offers a next
    /// step (Rick 2026-08-21: a bare "I don't have evidence for that" is
    /// the worst answer she gives — it reads as a shrug). Built only from
    /// the executed query's own description, so it can never name a fact.
    static func noEvidenceAnswer(for interpretedQuery: String) -> String {
        var people: [String] = []
        var years: String?
        var mediaKind: String?
        var keywords: [String] = []
        // "person=Richard Harding Breen Sr year=1995": a value runs until the
        // next key, so multi-word names survive.
        let pattern = #"(person|year|years|mediaKind|keyword)=(.*?)(?=\s+(?:person|year|years|mediaKind|keyword)=|$)"#
        let regex = try? NSRegularExpression(pattern: pattern)
        let whole = NSRange(interpretedQuery.startIndex..., in: interpretedQuery)
        for match in regex?.matches(in: interpretedQuery, range: whole) ?? [] {
            guard let keyRange = Range(match.range(at: 1), in: interpretedQuery),
                  let valueRange = Range(match.range(at: 2), in: interpretedQuery) else { continue }
            let pair = [String(interpretedQuery[keyRange]),
                        String(interpretedQuery[valueRange]).trimmingCharacters(in: .whitespaces)]
            switch pair[0] {
            case "person": people.append(pair[1])
            case "year": years = "from \(pair[1])"
            case "years": years = "from " + pair[1].replacingOccurrences(of: "...", with: "–")
            case "mediaKind": mediaKind = pair[1]
            case "keyword": keywords.append(pair[1])
            default: break
            }
        }
        var phrase = people.isEmpty
            ? (mediaKind.map { "\($0)s" } ?? "videos")
            : (mediaKind.map { "\($0)s" } ?? "videos") + " of " + joinNames(people)
        if let years { phrase += " " + years }
        if !keywords.isEmpty {
            phrase += " with “" + keywords.joined(separator: "”, “") + "”"
        }
        guard !(people.isEmpty && years == nil && keywords.isEmpty && mediaKind == nil) else {
            return "I need something to look for — a person, a year, a place, or a word. Try “show me Donna in the 90s”."
        }
        let offer: String
        if people.isEmpty {
            offer = "I search by the people tagged in each video, by year, and by words in file names and transcripts — try a name or a year, or a different word."
        } else if years == nil && keywords.isEmpty {
            // Person only: the useful sentence IS the offer.
            return "I don't have any videos tagged with \(joinNames(people)) yet. Try another spelling or a nickname — or tell me about \(joinNames(people)) and I'll remember it."
        } else {
            offer = "Want me to try without the \(keywords.isEmpty ? "year" : "words"), or with a different name?"
        }
        return "I looked for \(phrase) and found nothing in the catalog. " + offer
    }

    private static func joinNames(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return names[0] + " and " + names[1]
        default: return names.dropLast().joined(separator: ", ") + ", and " + names[names.count - 1]
        }
    }

    static func compose(_ result: ArchivistPresenceResult) -> ArchivistFactualAnswer {
        switch result.conclusion {
        case .present:
            let count = result.evidence.totalMatchCount
            return ArchivistFactualAnswer(
                prose: count == 1
                    ? "I found 1 catalog item matching that."
                    : "I found \(count) catalog items matching that.",
                basisLine: "Basis: \(result.evidence.citations.count) cited of "
                    + "\(count) matching catalog items.",
                evidence: result.evidence)
        case .noEvidence:
            return ArchivistFactualAnswer(
                prose: noEvidenceAnswer(for: result.interpretedQuery),
                basisLine: "Basis: no matching catalog evidence.",
                evidence: result.evidence)
        case .insufficientConstraints:
            return ArchivistFactualAnswer(
                prose: "I need something to look for — a person, a year, a place, or a word. Try “show me Donna in the 90s”.",
                basisLine: "Basis: no executable presence constraints.",
                evidence: result.evidence)
        case .noEvidenceButRelaxed(let dropped):
            // Honest shape: nothing for what was ASKED, here is the nearest
            // thing I do have, and it is clearly labelled as the near miss.
            let count = result.evidence.totalMatchCount
            let items = count == 1 ? "1 item" : "\(count) items"
            return ArchivistFactualAnswer(
                prose: "Nothing matches all of that. Setting aside \(dropped.phrase), "
                    + "I do have \(items). Want those?",
                basisLine: "Basis: no evidence for the full request; "
                    + "\(result.evidence.citations.count) cited of \(count) "
                    + "after setting aside \(dropped.rawValue).",
                evidence: result.evidence)
        }
    }
}
