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
///     {"shape":"record","payload":{"reference":{"kind":"file",
///       "name":"New Hampshire.mov"},"operations":["people","date"],
///       "people":["Rick","me"]}}
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
        /// "photos of X" (live 2026-08-27: the model's right reading was
        /// rejected as an unknown value). No catalog record is a photo; a
        /// photo ask about a family-tree person goes to the portrait /
        /// photography-floor path (HallieTurnExecutor+PhotoAsk), anyone
        /// else searches and finds nothing, honestly.
        case photo
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
            // `reference` is normally required (see astTemporalPayload's JSON
            // schema `required` list), but Homebrew ollama 0.33.2 returns
            // HTTP 501 for structured output (commit 88dceb2a) and the
            // fallback retry drops `format`, so the schema goes unenforced
            // and the model may omit this key. Missing -> default to
            // `.currentSelection` (identical to what a present
            // `{"kind":"currentSelection"}` already means); present-but-null
            // or present-but-malformed must still fail.
            reference = try c.decodeNonNullIfPresent(Reference.self, forKey: .reference)
                ?? .currentSelection
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
            /// "WHERE was Eileen Latta born / did she die / is she buried"
            /// (Rick, 2026-08-31). Until now the vocabulary had no place
            /// concept at all, so "when was X born" and "where was X born"
            /// both landed on `.birth` and both were answered with the
            /// DATE. ArchivistBiographyPolicy.lifePlace had existed and
            /// been tested since 2026-08-30 — added when Donna asked this
            /// on the web client — but it was reachable only through
            /// ArchivistChatWindow's legacy parser, never from the AST
            /// route the app actually uses. The answer existed; the
            /// question could not get to it.
            case birthPlace = "birth-place"
            case deathPlace = "death-place"
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
            /// "closest common ancestor of Rick and Donna" — the lineage
            /// shape (HallieLineageQuestion.commonAncestor) carried as an
            /// intent so a which-one clarification can resume it (Rick,
            /// live 2026-08-28: "donna 1959" after "Which Donna…?" became a
            /// catalog search because the answer had no continuation).
            /// Minted locally, never by the translator; `people` is the two
            /// names, "me" for the signed-in owner.
            case commonAncestor
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

            if operation == .relationship || operation == .commonAncestor, people.count != 2 {
                throw DecodingError.dataCorruptedError(
                    forKey: .people, in: c,
                    debugDescription: "\(operation.rawValue) requires exactly two people "
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

    /// ONE catalog record — the selected Catalog row or a file named in the
    /// question — and what to say about it (2026-09-02). Until this shape
    /// existed "who is in New Hampshire.mov" could only become a catalog-wide
    /// keyword sweep ("29 videos…") and "who else is in it" an aggregate whose
    /// anchor was the word "it". The executor resolves the reference to
    /// exactly one record and answers from that record's own fields; nothing
    /// here widens to a search. This payload is the future
    /// `catalog.record(id)` tool of docs/hallie_proposer_with_tools_design.md.
    struct Record: Codable, Equatable, Sendable {
        /// What to report. `about` is the whole dossier (metadata + date +
        /// people) and therefore stands alone; `people` and `date` combine.
        enum Operation: String, Codable, Equatable, Sendable, CaseIterable {
            case people, date, about
        }

        enum Reference: Codable, Equatable, Sendable {
            /// The one selected Catalog row ("this video", "it").
            case currentSelection
            /// A file named in the question: a filename, a filename without
            /// its extension, or a full path. Resolved by
            /// ArchivistRecordReferenceResolver; never a substring search.
            case file(name: String)

            private enum Kind: String, Codable { case currentSelection, file }
            private enum CodingKeys: String, CodingKey, CaseIterable { case kind, name }

            init(from decoder: Decoder) throws {
                let raw = try decoder.container(keyedBy: ArchivistAnyCodingKey.self)
                let c = try decoder.container(keyedBy: CodingKeys.self)
                let kind = try c.decode(Kind.self, forKey: .kind)
                let permitted: Set<String> = kind == .currentSelection
                    ? [CodingKeys.kind.rawValue]
                    : [CodingKeys.kind.rawValue, CodingKeys.name.rawValue]
                try decoder.rejectUnknownKeys(raw.allKeys.map(\.stringValue),
                                              permitted: permitted)
                switch kind {
                case .currentSelection:
                    self = .currentSelection
                case .file:
                    let name = try c.decode(String.self, forKey: .name)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else {
                        throw DecodingError.dataCorruptedError(
                            forKey: .name, in: c,
                            debugDescription: "file name must not be empty")
                    }
                    self = .file(name: name)
                }
            }

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                switch self {
                case .currentSelection:
                    try c.encode(Kind.currentSelection, forKey: .kind)
                case .file(let name):
                    try c.encode(Kind.file, forKey: .kind)
                    try c.encode(name, forKey: .name)
                }
            }
        }

        var reference: Reference
        /// 1–3 distinct operations; `about` only ever alone.
        var operations: [Operation]
        /// Names to give a verdict on (≤ maxListItems). Speaker pronouns
        /// are kept ("me", "my name") — the executor binds them to the
        /// owner, exactly as the graph route does.
        var people: [String]?

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case reference, operations, people
        }

        init(reference: Reference, operations: [Operation], people: [String]? = nil) {
            self.reference = reference
            self.operations = operations
            self.people = people
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.strictContainer(keyedBy: CodingKeys.self)
            reference = try c.decode(Reference.self, forKey: .reference)
            operations = try c.decode([Operation].self, forKey: .operations)
            guard !operations.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .operations, in: c,
                    debugDescription: "operations must not be empty")
            }
            guard Set(operations).count == operations.count else {
                throw DecodingError.dataCorruptedError(
                    forKey: .operations, in: c,
                    debugDescription: "operations must be distinct")
            }
            if operations.contains(.about), operations.count > 1 {
                throw DecodingError.dataCorruptedError(
                    forKey: .operations, in: c,
                    debugDescription: "about stands alone (it already covers people and date)")
            }
            people = try c.decodeBoundedListIfPresent(.people)
        }

        /// The media filename extensions a question may name (mirror of
        /// MEDIA_FILENAME_EXTENSIONS in scripts/hallie_eval.py — keep the
        /// two lists identical). Lowercase, no dot.
        static let mediaFilenameExtensions: Set<String> = [
            "mov", "mp4", "m4v", "avi", "mkv", "mxf", "mts", "m2ts", "ts", "mpg",
            "mpeg", "m2v", "vob", "wmv", "asf", "webm", "ogv", "ogg", "rm", "rmvb",
            "divx", "flv", "f4v", "3gp", "3g2", "dv", "dif", "braw", "r3d", "vro",
            "mod", "tod", "wav", "aif", "aiff", "mp3", "mp2", "m4a", "aac", "flac",
            "caf", "wma", "ac3", "oga", "opus", "alac", "amr", "au", "snd",
        ]

        /// True when `text` ends in ".<media extension>" (case-insensitive):
        /// "New Hampshire.mov", "/Volumes/X/tape.MXF". A bare word is not.
        static func endsWithMediaExtension(_ text: String) -> Bool {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let dot = trimmed.lastIndex(of: "."), dot != trimmed.startIndex else {
                return false
            }
            let ext = trimmed[trimmed.index(after: dot)...].lowercased()
            return !ext.isEmpty && mediaFilenameExtensions.contains(ext)
        }

        /// The spellings of "the selected video" a translator may put in a
        /// people list (see decodeTranslatorOutput rewrite (a)).
        static func isSelectionWord(_ value: String) -> Bool {
            let key = value.lowercased()
                .split(whereSeparator: { !$0.isLetter })
                .joined(separator: " ")
            return selectionWords.contains(key)
        }

        private static let selectionWords: Set<String> = [
            "currentselection", "current selection", "selection", "the selection",
            "it", "this", "that", "this one", "this video", "that video",
            "the video", "the selected video", "selected video", "this clip",
            "this tape", "this file", "the file", "this recording",
        ]
    }

    case presence(Presence)
    case temporal(Temporal)
    case aggregate(Aggregate)
    case event(Event)
    case graph(Graph)
    case cross(Cross)
    case record(Record)

    private enum Shape: String, Codable {
        case presence, temporal, aggregate, event, graph, cross, record
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
        case .record: self = .record(try c.decode(Record.self, forKey: .payload))
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
        case .record(let value):
            try c.encode(Shape.record, forKey: .shape)
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
