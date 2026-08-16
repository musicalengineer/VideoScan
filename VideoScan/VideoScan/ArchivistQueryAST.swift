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
        }

        enum Relation: String, Codable, Equatable, Sendable {
            case father, mother, parents
            case brother, sister, siblings
            case son, daughter, children
            case husband, wife, spouse
        }

        var people: [String]
        var operation: Operation
        var relation: Relation?

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case people, operation, relation
        }

        init(people: [String], operation: Operation, relation: Relation? = nil) {
            self.people = people
            self.operation = operation
            self.relation = relation
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.strictContainer(keyedBy: CodingKeys.self)
            people = try c.decodeBoundedList(.people, requireNonempty: true)
            operation = try c.decode(Operation.self, forKey: .operation)
            relation = try c.decodeNonNullIfPresent(Relation.self, forKey: .relation)

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
