import Foundation

/// QueryAST v2 is a closed, typed wire protocol. Representative JSON:
///
///     {"shape":"presence","payload":{"people":["Donna"],"yearStart":1990}}
///     {"shape":"temporal","payload":{"subject":"Timmy","operation":"age",
///       "reference":{"kind":"currentSelection"}}}
///     {"shape":"aggregate","payload":{"operation":"coOccurrence",
///       "anchorPeople":["Donna"]}}
///     {"shape":"event","payload":{"keywords":["first birthday"],
///       "transcript":["birthday"]}}
///     {"shape":"graph","payload":{"people":["Ellen"],
///       "operation":"biography"}}
///     {"shape":"graph","payload":{"people":["me","you"],
///       "operation":"relationship"}}
///     {"shape":"cross","payload":{"people":["Dan"],
///       "keywords":["red bike"],"transcript":["opens"]}}
///
/// All catalog/text constraints are optional so sparse model output stays
/// sparse. Semantic fields for temporal, aggregate, and graph queries are
/// required because omitting them would change the meaning of the question.
///
/// Swift's associated-value enum is the equivalent of a C++ tagged union:
/// `shape` selects exactly one payload layout.
enum ArchivistQueryAST: Codable, Equatable, Sendable {
    static let maxListItems = 6
    static let resultLimitRange = 1...100
    static let yearRange = 1900...2099

    enum MediaKind: String, Codable, Equatable, Sendable {
        case video
        case videoOnly = "video-only"
        case audio
        case both
    }

    struct Presence: Codable, Equatable, Sendable {
        var people: [String]?
        var yearStart: Int?
        var yearEnd: Int?
        var mediaKind: MediaKind?
        var keywords: [String]?

        init(people: [String]? = nil, yearStart: Int? = nil,
             yearEnd: Int? = nil, mediaKind: MediaKind? = nil,
             keywords: [String]? = nil) {
            self.people = people
            self.yearStart = yearStart
            self.yearEnd = yearEnd
            self.mediaKind = mediaKind
            self.keywords = keywords
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case people, yearStart, yearEnd, mediaKind, keywords
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.strictContainer(keyedBy: CodingKeys.self)
            people = try c.decodeBoundedListIfPresent(.people)
            yearStart = try c.decodeNonNullIfPresent(Int.self, forKey: .yearStart)
            yearEnd = try c.decodeNonNullIfPresent(Int.self, forKey: .yearEnd)
            try ArchivistQueryAST.validateYear(yearStart, forKey: .yearStart, in: c)
            try ArchivistQueryAST.validateYear(yearEnd, forKey: .yearEnd, in: c)
            try ArchivistQueryAST.validateYearOrder(
                start: yearStart, end: yearEnd, in: c)
            mediaKind = try c.decodeNonNullIfPresent(MediaKind.self, forKey: .mediaKind)
            keywords = try c.decodeBoundedListIfPresent(.keywords)
        }
    }

    struct Temporal: Codable, Equatable, Sendable {
        enum Operation: String, Codable, Equatable, Sendable { case age }

        var subject: String
        var operation: Operation
        var reference: Reference

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case subject, operation, reference
        }

        init(subject: String, operation: Operation, reference: Reference) {
            self.subject = subject
            self.operation = operation
            self.reference = reference
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.strictContainer(keyedBy: CodingKeys.self)
            subject = try c.decode(String.self, forKey: .subject)
            guard !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .subject, in: c,
                    debugDescription: "subject must not be empty")
            }
            operation = try c.decode(Operation.self, forKey: .operation)
            reference = try c.decode(Reference.self, forKey: .reference)
        }

        enum Reference: Codable, Equatable, Sendable {
            case currentSelection
            case explicitYear(Int)

            private enum Kind: String, Codable { case currentSelection, explicitYear }
            private enum CodingKeys: String, CodingKey, CaseIterable { case kind, year }

            init(from decoder: Decoder) throws {
                let raw = try decoder.container(keyedBy: ArchivistAnyCodingKey.self)
                let c = try decoder.container(keyedBy: CodingKeys.self)
                let kind = try c.decode(Kind.self, forKey: .kind)
                let permitted: Set<String> = kind == .currentSelection
                    ? [CodingKeys.kind.rawValue]
                    : [CodingKeys.kind.rawValue, CodingKeys.year.rawValue]
                try decoder.rejectUnknownKeys(raw.allKeys.map(\.stringValue),
                                              permitted: permitted)

                switch kind {
                case .currentSelection:
                    self = .currentSelection
                case .explicitYear:
                    let year = try c.decode(Int.self, forKey: .year)
                    guard ArchivistQueryAST.yearRange.contains(year) else {
                        throw DecodingError.dataCorruptedError(
                            forKey: .year, in: c,
                            debugDescription: "year must be in "
                                + "\(ArchivistQueryAST.yearRange)")
                    }
                    self = .explicitYear(year)
                }
            }

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                switch self {
                case .currentSelection:
                    try c.encode(Kind.currentSelection, forKey: .kind)
                case .explicitYear(let year):
                    try c.encode(Kind.explicitYear, forKey: .kind)
                    try c.encode(year, forKey: .year)
                }
            }
        }
    }

    struct Aggregate: Codable, Equatable, Sendable {
        enum Operation: String, Codable, Equatable, Sendable { case coOccurrence }

        var operation: Operation
        var anchorPeople: [String]
        /// Present only when the user explicitly asks for a top-N result.
        /// Nil lets the deterministic executor apply the operation's visible
        /// default instead of forcing the translator to invent a number.
        var limit: Int?

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case operation, anchorPeople, limit
        }

        init(operation: Operation, anchorPeople: [String], limit: Int? = nil) {
            self.operation = operation
            self.anchorPeople = anchorPeople
            self.limit = limit
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.strictContainer(keyedBy: CodingKeys.self)
            operation = try c.decode(Operation.self, forKey: .operation)
            anchorPeople = try c.decodeBoundedList(.anchorPeople, requireNonempty: true)
            limit = try c.decodeNonNullIfPresent(Int.self, forKey: .limit)
            if let limit,
               !ArchivistQueryAST.resultLimitRange.contains(limit) {
                throw DecodingError.dataCorruptedError(
                    forKey: .limit, in: c,
                    debugDescription: "limit must be in "
                        + "\(ArchivistQueryAST.resultLimitRange)")
            }
        }
    }

    struct Event: Codable, Equatable, Sendable {
        var people: [String]?
        var yearStart: Int?
        var yearEnd: Int?
        var mediaKind: MediaKind?
        var keywords: [String]?
        var transcript: [String]?

        init(people: [String]? = nil, yearStart: Int? = nil,
             yearEnd: Int? = nil, mediaKind: MediaKind? = nil,
             keywords: [String]? = nil, transcript: [String]? = nil) {
            self.people = people
            self.yearStart = yearStart
            self.yearEnd = yearEnd
            self.mediaKind = mediaKind
            self.keywords = keywords
            self.transcript = transcript
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case people, yearStart, yearEnd, mediaKind, keywords, transcript
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.strictContainer(keyedBy: CodingKeys.self)
            people = try c.decodeBoundedListIfPresent(.people)
            yearStart = try c.decodeNonNullIfPresent(Int.self, forKey: .yearStart)
            yearEnd = try c.decodeNonNullIfPresent(Int.self, forKey: .yearEnd)
            try ArchivistQueryAST.validateYear(yearStart, forKey: .yearStart, in: c)
            try ArchivistQueryAST.validateYear(yearEnd, forKey: .yearEnd, in: c)
            try ArchivistQueryAST.validateYearOrder(
                start: yearStart, end: yearEnd, in: c)
            mediaKind = try c.decodeNonNullIfPresent(MediaKind.self, forKey: .mediaKind)
            keywords = try c.decodeBoundedListIfPresent(.keywords)
            transcript = try c.decodeBoundedListIfPresent(.transcript)
        }
    }

    struct Graph: Codable, Equatable, Sendable {
        enum Operation: String, Codable, Equatable, Sendable {
            case biography, birth, death, kinship
            /// "show Donna's family tree" — a neighbourhood summary (person)
            /// or a surname roll-up, plus an offer to open the Family Tree tab.
            case familyTree
            /// "how am I related to you?" / "how is Donna related to Thankful
            /// Pratt?" — the SYMMETRIC question: `people` is exactly the two
            /// names (pronouns allowed; the executor binds "I"/"you"), no
            /// `relation`. Added 2026-08-18 after Hallie's log showed the
            /// translator forcing this into one-directional kinship with a
            /// made-up relation ("sel…") that the strict decoder rejected.
            case relationship
        }

        /// Closed kinship vocabulary. One-hop relations are the original
        /// contract; the multi-hop ones (grandparents, great-grandparents,
        /// aunts/uncles, cousins, nieces/nephews, basic in-laws) map onto
        /// `GedcomFamilyGraph.ExtendedRelation` and may carry a `side`.
        enum Relation: String, Codable, Equatable, Sendable, CaseIterable {
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

            /// The one-hop relations answered by `GedcomFamilyGraph.relatives`.
            var isSingleHop: Bool {
                switch self {
                case .father, .mother, .parents, .brother, .sister, .siblings,
                     .son, .daughter, .children, .husband, .wife, .spouse:
                    return true
                default:
                    return false
                }
            }
        }

        /// Which parent the first hop goes through ("on her maternal side").
        enum Side: String, Codable, Equatable, Sendable {
            case maternal, paternal
        }

        /// Empty only for `familyTree` (surname or whole-tree forms);
        /// exactly two for `relationship`.
        var people: [String]
        var operation: Operation
        var relation: Relation?
        var side: Side?
        /// Surname roll-up for `familyTree` ("the Breens").
        var surname: String?

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case people, operation, relation, side, surname
        }

        init(people: [String], operation: Operation, relation: Relation? = nil,
             side: Side? = nil, surname: String? = nil) {
            self.people = people
            self.operation = operation
            self.relation = relation
            self.side = side
            self.surname = surname
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.strictContainer(keyedBy: CodingKeys.self)
            operation = try c.decode(Operation.self, forKey: .operation)
            if operation == .familyTree {
                people = try c.decodeBoundedListIfPresent(.people) ?? []
            } else {
                people = try c.decodeBoundedList(.people, requireNonempty: true)
            }
            relation = try c.decodeNonNullIfPresent(Relation.self, forKey: .relation)
            side = try c.decodeNonNullIfPresent(Side.self, forKey: .side)
            surname = try c.decodeNonNullIfPresent(String.self, forKey: .surname)
            if let surname,
               surname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw DecodingError.dataCorruptedError(
                    forKey: .surname, in: c,
                    debugDescription: "surname must not be empty")
            }

            if operation == .relationship, people.count != 2 {
                throw DecodingError.dataCorruptedError(
                    forKey: .people, in: c,
                    debugDescription: "relationship requires exactly two people "
                        + "(got \(people.count))")
            }
            if operation == .kinship {
                guard relation != nil else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .relation, in: c,
                        debugDescription: "kinship requires a relation")
                }
            } else if relation != nil {
                throw DecodingError.dataCorruptedError(
                    forKey: .relation, in: c,
                    debugDescription: "relation is valid only for kinship")
            }
            if side != nil, operation != .kinship {
                throw DecodingError.dataCorruptedError(
                    forKey: .side, in: c,
                    debugDescription: "side is valid only for kinship")
            }
            if surname != nil, operation != .familyTree {
                throw DecodingError.dataCorruptedError(
                    forKey: .surname, in: c,
                    debugDescription: "surname is valid only for familyTree")
            }
            if operation == .familyTree, !people.isEmpty, surname != nil {
                throw DecodingError.dataCorruptedError(
                    forKey: .surname, in: c,
                    debugDescription: "familyTree takes people or surname, not both")
            }
        }
    }

    struct Cross: Codable, Equatable, Sendable {
        var people: [String]?
        var yearStart: Int?
        var yearEnd: Int?
        var mediaKind: MediaKind?
        var keywords: [String]?
        var transcript: [String]?

        init(people: [String]? = nil, yearStart: Int? = nil,
             yearEnd: Int? = nil, mediaKind: MediaKind? = nil,
             keywords: [String]? = nil, transcript: [String]? = nil) {
            self.people = people
            self.yearStart = yearStart
            self.yearEnd = yearEnd
            self.mediaKind = mediaKind
            self.keywords = keywords
            self.transcript = transcript
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case people, yearStart, yearEnd, mediaKind, keywords, transcript
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.strictContainer(keyedBy: CodingKeys.self)
            people = try c.decodeBoundedListIfPresent(.people)
            yearStart = try c.decodeNonNullIfPresent(Int.self, forKey: .yearStart)
            yearEnd = try c.decodeNonNullIfPresent(Int.self, forKey: .yearEnd)
            try ArchivistQueryAST.validateYear(yearStart, forKey: .yearStart, in: c)
            try ArchivistQueryAST.validateYear(yearEnd, forKey: .yearEnd, in: c)
            try ArchivistQueryAST.validateYearOrder(
                start: yearStart, end: yearEnd, in: c)
            mediaKind = try c.decodeNonNullIfPresent(MediaKind.self, forKey: .mediaKind)
            keywords = try c.decodeBoundedListIfPresent(.keywords)
            transcript = try c.decodeBoundedListIfPresent(.transcript)
        }
    }

    case presence(Presence)
    case temporal(Temporal)
    case aggregate(Aggregate)
    case event(Event)
    case graph(Graph)
    case cross(Cross)

    private enum Shape: String, Codable {
        case presence, temporal, aggregate, event, graph, cross
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case shape, payload }

    init(from decoder: Decoder) throws {
        let c = try decoder.strictContainer(keyedBy: CodingKeys.self)
        switch try c.decode(Shape.self, forKey: .shape) {
        case .presence: self = .presence(try c.decode(Presence.self, forKey: .payload))
        case .temporal: self = .temporal(try c.decode(Temporal.self, forKey: .payload))
        case .aggregate: self = .aggregate(try c.decode(Aggregate.self, forKey: .payload))
        case .event: self = .event(try c.decode(Event.self, forKey: .payload))
        case .graph: self = .graph(try c.decode(Graph.self, forKey: .payload))
        case .cross: self = .cross(try c.decode(Cross.self, forKey: .payload))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .presence(let value):
            try c.encode(Shape.presence, forKey: .shape)
            try c.encode(value, forKey: .payload)
        case .temporal(let value):
            try c.encode(Shape.temporal, forKey: .shape)
            try c.encode(value, forKey: .payload)
        case .aggregate(let value):
            try c.encode(Shape.aggregate, forKey: .shape)
            try c.encode(value, forKey: .payload)
        case .event(let value):
            try c.encode(Shape.event, forKey: .shape)
            try c.encode(value, forKey: .payload)
        case .graph(let value):
            try c.encode(Shape.graph, forKey: .shape)
            try c.encode(value, forKey: .payload)
        case .cross(let value):
            try c.encode(Shape.cross, forKey: .shape)
            try c.encode(value, forKey: .payload)
        }
    }

    private static func validateYear<Key: CodingKey>(
        _ year: Int?,
        forKey key: Key,
        in container: KeyedDecodingContainer<Key>
    ) throws {
        guard let year else { return }
        guard yearRange.contains(year) else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: container,
                debugDescription: "\(key.stringValue) must be in \(yearRange)")
        }
    }

    private static func validateYearOrder<Key: CodingKey>(
        start: Int?,
        end: Int?,
        in container: KeyedDecodingContainer<Key>
    ) throws {
        guard let start, let end, start > end else { return }
        throw DecodingError.dataCorrupted(.init(
            codingPath: container.codingPath,
            debugDescription: "yearStart must not be after yearEnd"))
    }
}

private struct ArchivistAnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) { self.stringValue = stringValue; intValue = nil }
    init?(intValue: Int) { stringValue = String(intValue); self.intValue = intValue }
}

private extension Decoder {
    func strictContainer<Key>(
        keyedBy type: Key.Type
    ) throws -> KeyedDecodingContainer<Key> where Key: CodingKey & CaseIterable {
        let raw = try container(keyedBy: ArchivistAnyCodingKey.self)
        let permitted = Set(Key.allCases.map(\.stringValue))
        try rejectUnknownKeys(raw.allKeys.map(\.stringValue), permitted: permitted)
        return try container(keyedBy: type)
    }

    func rejectUnknownKeys(_ actual: [String], permitted: Set<String>) throws {
        let unknown = actual.filter { !permitted.contains($0) }.sorted()
        guard unknown.isEmpty else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: codingPath,
                debugDescription: "unknown field(s): \(unknown.joined(separator: ", "))"))
        }
    }
}

private extension KeyedDecodingContainer {
    func decodeNonNullIfPresent<T: Decodable>(
        _ type: T.Type,
        forKey key: Key
    ) throws -> T? {
        guard contains(key) else { return nil }
        return try decode(type, forKey: key)
    }

    func decodeBoundedList(_ key: Key, requireNonempty: Bool = false) throws -> [String] {
        let values = try decode([String].self, forKey: key)
        if requireNonempty && values.isEmpty {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: self,
                debugDescription: "\(key.stringValue) must not be empty")
        }
        guard values.allSatisfy({
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: self,
                debugDescription: "\(key.stringValue) contains an empty value")
        }
        guard values.count <= ArchivistQueryAST.maxListItems else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: self,
                debugDescription: "\(key.stringValue) exceeds "
                    + "\(ArchivistQueryAST.maxListItems) items")
        }
        return values
    }

    func decodeBoundedListIfPresent(_ key: Key) throws -> [String]? {
        guard contains(key) else { return nil }
        return try decodeBoundedList(key)
    }
}

// MARK: - Translator-output decoding (tolerant of benign model extras)

/// The strict Codable above is the wire CONTRACT and stays strict: unknown
/// keys, misplaced constraint fields, bad enum values, and empty required
/// lists are rejected. This entry point sits in front of it for text that
/// came from the translator model, which — schema or not — occasionally
/// decorates a correct answer with harmless extras (`"limit":1` on a
/// presence payload for "how many…", `"confidence"`, `"explanation"`, a
/// `null` for an optional field). Failing the whole turn on those threw
/// away good translations (Hallie log 2026-08-17, "how many videos of Donna
/// do we have?").
///
/// Rules, deliberately narrow:
///   * A key that is not any known constraint field is dropped and noted.
///     A dropped key cannot widen or narrow the evidence set because no
///     executor reads it, so the anti-hallucination contract is intact.
///   * EXCEPT keys that mean the model tried to answer instead of translate
///     ("answer", "sql", "response", …): those still fail the turn. A model
///     that is phrasing facts is not translating, and its other fields are
///     not to be trusted either.
///   * A KNOWN constraint field in the wrong place ("transcript" on a
///     presence payload, "yearStart" beside "shape") is NOT dropped — it
///     reaches the strict decoder and is rejected, because silently dropping
///     it would change the question's meaning.
///   * `limit` is presentation, not evidence: kept for aggregate (where the
///     contract defines it), dropped elsewhere.
///   * `null` for an optional field means absent; the key is dropped.
///   * List quirks are normalized: entries are trimmed, empty entries and
///     stopword-only people/keywords ("videos", "the") are dropped. A
///     required list that ends up empty is still rejected downstream.
///     Speaker pronouns in `people` ("me", "you", "myself") are KEPT even
///     though they are stopwords for keyword search — the executor binds
///     them to the owner / the archivist (2026-08-18).
///   * A graph `kinship` whose relation is a "how are we related" word
///     ("self", "related", "relationship", …) is rewritten to the
///     `relationship` operation and the relation dropped; the strict decoder
///     then still requires exactly two people, so a one-name payload fails
///     with a clear message rather than a guessed second party.
///   * A temporal `reference` written in the model's shorthand —
///     `{"explicitYear":1998}`, `{"currentSelection":true}`,
///     `"currentSelection"`, or a bare year — is rewritten to the contract's
///     `{"kind":…}` object. The meaning is unambiguous; only the spelling
///     differs (seen live from qwen3.6, 2026-08-16).
extension ArchivistQueryAST {
    struct TranslatorDecoding: Sendable {
        let ast: ArchivistQueryAST
        /// Human-readable notes about what was ignored or normalized; empty
        /// when the model output was already strict. Callers log these.
        let notes: [String]
    }

    /// Every field name the contract knows, at any level. Anything else on a
    /// known object is a benign extra.
    static let knownFieldNames: Set<String> = [
        "shape", "payload", "people", "yearStart", "yearEnd", "mediaKind",
        "keywords", "transcript", "subject", "operation", "reference", "kind",
        "year", "anchorPeople", "relation", "limit", "side", "surname",
    ]

    /// Keys whose presence means the model stopped translating and started
    /// answering. Never tolerated, at any level.
    static let hostileFieldNames: Set<String> = [
        "answer", "answers", "response", "reply", "prose", "text", "message",
        "sql", "sqlquery", "query", "result", "results", "fact", "facts",
    ]

    private static let listFieldNames: Set<String> = [
        "people", "keywords", "transcript", "anchorPeople",
    ]
    private static let requiredListFieldNames: Set<String> = [
        "anchorPeople",
    ]

    static func decodeTranslatorOutput(_ data: Data) throws -> TranslatorDecoding {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              var top = object as? [String: Any] else {
            // Not a JSON object at all: let the strict decoder produce the
            // canonical error.
            return TranslatorDecoding(
                ast: try JSONDecoder().decode(ArchivistQueryAST.self, from: data),
                notes: [])
        }

        var notes: [String] = []
        let shape = top["shape"] as? String
        top = try sanitize(top, path: "", shape: shape, notes: &notes)
        if var payload = top["payload"] as? [String: Any] {
            payload = try sanitize(payload, path: "payload.", shape: shape,
                                   notes: &notes)
            if shape == "temporal", let reference = payload["reference"],
               let rewritten = canonicalReference(reference) {
                payload["reference"] = rewritten
                notes.append("rewrote shorthand payload.reference")
            }
            if var reference = payload["reference"] as? [String: Any] {
                reference = try sanitize(reference, path: "payload.reference.",
                                         shape: shape, notes: &notes)
                payload["reference"] = reference
            }
            if shape == "graph" {
                payload = canonicalGraphPayload(payload, notes: &notes)
            }
            top["payload"] = payload
        }

        let cleaned = try JSONSerialization.data(withJSONObject: top)
        let ast = try JSONDecoder().decode(ArchivistQueryAST.self, from: cleaned)
        return TranslatorDecoding(ast: ast, notes: notes)
    }

    /// Graph-payload spellings the model uses for meanings the contract
    /// already has: "family tree"/"ancestors"/"lineage" → familyTree, and
    /// colloquial kinship words ("grandma", "great grandmother", "maternal
    /// great-grandmother" → relation + side, "mom" → mother). Only the
    /// spelling changes; an unknown word is left for the strict decoder to
    /// reject, never guessed.
    private static func canonicalGraphPayload(
        _ payload: [String: Any],
        notes: inout [String]
    ) -> [String: Any] {
        var result = payload
        if let operation = payload["operation"] as? String,
           Graph.Operation(rawValue: operation) == nil {
            let key = operation.lowercased()
                .replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: " ", with: "")
            let treeWords: Set<String> = [
                "familytree", "tree", "ancestors", "ancestry", "ancestor",
                "descendants", "descendant", "lineage", "pedigree",
                "genealogy", "family", "familyhistory", "relatives",
            ]
            if treeWords.contains(key) {
                result["operation"] = "familyTree"
                notes.append("rewrote payload.operation '\(operation)' to familyTree")
            } else if let known = Graph.Operation(rawValue: key)
                        ?? (key == "bio" ? .biography : nil) {
                result["operation"] = known.rawValue
                notes.append("rewrote payload.operation '\(operation)' to \(known.rawValue)")
            }
        }
        // "how am I related to you" → kinship + relation "self"/"related"
        // (seen live from qwen3.6, 2026-08-18: `"relation":"sel…"`). The
        // meaning is the symmetric relationship operation; only the spelling
        // is wrong. Rewrite the operation, drop the pseudo-relation.
        if result["operation"] as? String == "kinship",
           let relation = payload["relation"] as? String {
            let key = relation.lowercased()
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
                .trimmingCharacters(in: .whitespaces)
            let relationshipWords: Set<String> = [
                "self", "related", "relation", "relationship", "relative",
                "related to", "relatedto", "how related", "connection",
                "connected", "kin", "kinship", "any", "unknown",
            ]
            if relationshipWords.contains(key) {
                result["operation"] = "relationship"
                result["relation"] = nil
                notes.append("rewrote kinship relation '\(relation)' to the relationship operation")
            }
        }
        if let operation = payload["operation"] as? String,
           Graph.Operation(rawValue: operation) == nil,
           ["relationship", "related", "relation", "howrelated", "relatedto",
            "connection", "kin"].contains(
                operation.lowercased()
                    .replacingOccurrences(of: "_", with: "")
                    .replacingOccurrences(of: "-", with: "")
                    .replacingOccurrences(of: " ", with: "")),
           result["operation"] as? String != "relationship" {
            result["operation"] = "relationship"
            result["relation"] = nil
            notes.append("rewrote payload.operation '\(operation)' to relationship")
        }
        if result["operation"] as? String == "relationship",
           let people = result["people"] as? [String], people.count == 1,
           people[0].lowercased().hasPrefix("me and ") || people[0].lowercased().hasPrefix("me & ") {
            // "me and you" packed into ONE entry — split, never invent.
            let parts = people[0].components(separatedBy: " and ")
                .flatMap { $0.components(separatedBy: " & ") }
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if parts.count == 2 {
                result["people"] = parts
                notes.append("split payload.people '\(people[0])' into two entries")
            }
        }
        if let relation = result["relation"] as? String,
           Graph.Relation(rawValue: relation) == nil {
            var canonical: String?
            var impliedSide: String?
            if let single = GedcomFamilyGraph.relation(fromWord: relation) {
                canonical = single.rawValue
            } else if let extended = GedcomFamilyGraph.extendedRelation(
                fromPhrase: relation) {
                canonical = extended.relation.rawValue
                impliedSide = extended.side?.rawValue
            }
            if let canonical {
                result["relation"] = canonical
                notes.append("rewrote payload.relation '\(relation)' to '\(canonical)'")
            }
            if let impliedSide, payload["side"] == nil {
                result["side"] = impliedSide
                notes.append("derived payload.side '\(impliedSide)' from relation wording")
            }
        }
        if let side = payload["side"] as? String,
           Graph.Side(rawValue: side) == nil {
            let key = side.lowercased()
            let mapped: String? = key.contains("mother") || key.contains("maternal")
                ? "maternal"
                : key.contains("father") || key.contains("paternal")
                    ? "paternal" : nil
            if let mapped {
                result["side"] = mapped
                notes.append("rewrote payload.side '\(side)' to '\(mapped)'")
            }
        }
        // "the Breens" offered as a person is a surname roll-up in disguise.
        if result["operation"] as? String == "familyTree",
           result["surname"] == nil,
           let people = result["people"] as? [String], people.count == 1,
           let only = people.first {
            let lowered = only.lowercased().trimmingCharacters(in: .whitespaces)
            if lowered.hasPrefix("the "), lowered.hasSuffix("s") {
                result["surname"] = String(only.dropFirst(4))
                result["people"] = [String]()
                notes.append("rewrote payload.people '\(only)' to surname")
            }
        }
        return result
    }

    /// Contract form for a temporal reference the model wrote in shorthand;
    /// nil when it is already an object with "kind" (or unrecognizable, in
    /// which case the strict decoder reports it).
    private static func canonicalReference(_ value: Any) -> Any? {
        if let object = value as? [String: Any] {
            if let kind = object["kind"] as? String {
                // `{"kind":"explicitYear","value":1998}` — right kind, wrong
                // key for the number (seen live from qwen3.6, 2026-08-17).
                guard kind == "explicitYear", object["year"] == nil,
                      object.count == 2,
                      let year = (object["value"] ?? object["explicitYear"]) as? Int
                else { return nil }
                return ["kind": "explicitYear", "year": year]
            }
            let keys = Set(object.keys.map { $0.lowercased() })
            if keys == ["explicityear"],
               let year = object.values.first as? Int {
                return ["kind": "explicitYear", "year": year]
            }
            if keys == ["currentselection"] {
                return ["kind": "currentSelection"]
            }
            return nil
        }
        if let text = value as? String {
            let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.lowercased() == "currentselection" {
                return ["kind": "currentSelection"]
            }
            if let year = Int(key), yearRange.contains(year) {
                return ["kind": "explicitYear", "year": year]
            }
            return nil
        }
        if let year = value as? Int, yearRange.contains(year) {
            return ["kind": "explicitYear", "year": year]
        }
        return nil
    }

    private static func sanitize(
        _ object: [String: Any],
        path: String,
        shape: String?,
        notes: inout [String]
    ) throws -> [String: Any] {
        var result: [String: Any] = [:]
        for key in object.keys.sorted() {
            guard let value = object[key] else { continue }
            let isPayloadLevel = path == "payload."
            if hostileFieldNames.contains(key.lowercased()) {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: [],
                    debugDescription: "translator attempted to answer: field "
                        + "\(path)\(key) is not a translation"))
            }
            if !knownFieldNames.contains(key)
                || (key == "limit" && !(isPayloadLevel && shape == "aggregate")) {
                notes.append("ignored extra field \(path)\(key)")
                continue
            }
            if value is NSNull {
                notes.append("dropped null \(path)\(key)")
                continue
            }
            if isPayloadLevel, listFieldNames.contains(key),
               let list = value as? [Any] {
                let strings = list.compactMap { $0 as? String }
                guard strings.count == list.count else {
                    result[key] = value        // non-string entries: strict rejects
                    continue
                }
                let kept = normalizeList(strings, field: key, path: path,
                                         notes: &notes)
                if kept.isEmpty, !requiredListFieldNames.contains(key),
                   !(key == "people" && shape == "graph") {
                    if !strings.isEmpty {
                        notes.append("dropped now-empty list \(path)\(key)")
                    }
                    continue
                }
                result[key] = kept
                continue
            }
            result[key] = value
        }
        return result
    }

    private static func normalizeList(
        _ values: [String],
        field: String,
        path: String,
        notes: inout [String]
    ) -> [String] {
        var kept: [String] = []
        for raw in values {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty {
                notes.append("dropped empty entry in \(path)\(field)")
                continue
            }
            if field == "people", HallieTurnExecutor.isSpeakerPronoun(value) {
                // "you"/"me" are stopwords for keyword search but PEOPLE
                // here: the executor binds them (2026-08-18 log evidence:
                // people:["you"]). Kept verbatim.
                if kept.contains(value) {
                    notes.append("dropped duplicate \(field) entry '\(value)'")
                    continue
                }
                kept.append(value)
                continue
            }
            if field == "keywords" || field == "people" || field == "anchorPeople",
               ArchivistKeywordText.significantTokens(value).isEmpty,
               !ArchivistKeywordText.tokens(value).isEmpty {
                notes.append("dropped stopword-only \(field) entry '\(value)'")
                continue
            }
            if kept.contains(value) {
                notes.append("dropped duplicate \(field) entry '\(value)'")
                continue
            }
            kept.append(value)
        }
        return kept
    }
}
