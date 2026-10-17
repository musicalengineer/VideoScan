// ImportSidecarsJSON+Decisions.swift
// The importer's own readings of the remaining §f sidecars (contract §c):
//   * events-decisions.json — `EventsDecisionFile` (A/Events/EventsDecisionStore
//     .swift:154): the event records typed, every decision kept as a verbatim
//     JSON object with its `kind` word (an unknown kind is still a decision);
//   * ignored-content.json — `IgnoredContentFile` (A/Catalog/IgnoredContentStore
//     .swift:109);
//   * ledger/media-ledger.jsonl — one `MediaLedgerEvent` per line
//     (C/MediaLedgerEvent.swift), read leniently: a line that is a JSON object
//     is a ledger line whatever its keys; a line that is not JSON is counted,
//     never guessed at;
//   * fullhash-backfill.json — `FullHashBackfillRunRecord` (A/MediaOps/
//     FullHashBackfillResume.swift:26).
// Plus the fold of the decision stream into event membership
// (`EventsDecisionSnapshot`, EventsDecisionStore.swift:173), reproduced here
// as a pure function so the importer writes `event_members` the way the
// app computes them. Pure: callers pass Data.
//
// (For Rick: POD mirrors plus one fold — a reduce over the decision list.)

import Foundation

// MARK: - events-decisions.json

public struct EventsDecisionsJSON: Decodable, Sendable, Equatable {

    public struct Event: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var categories: [String]?
        public var state: String?
        public var createdAt: CatalogJSONDate?
        public var updatedAt: CatalogJSONDate?
        public var note: String?

        public init(id: String, name: String, categories: [String]?, state: String?, createdAt: CatalogJSONDate?,
                    updatedAt: CatalogJSONDate?, note: String?) {
            self.id = id
            self.name = name
            self.categories = categories
            self.state = state
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.note = note
        }
    }

    /// One decision, verbatim, with its kind word ("" when the object has none).
    public struct Decision: Sendable, Equatable {
        public var kind: String
        public var payload: CatalogJSONValue

        public init(payload: CatalogJSONValue) {
            self.payload = payload
            self.kind = payload["kind"]?.stringValue ?? ""
        }
    }

    public var storeVersion: Int?
    public var savedAt: CatalogJSONValue?
    public var events: [Event]
    public var decisions: [Decision]

    private enum Keys: String, CodingKey { case storeVersion, savedAt, events, decisions }

    public init(events: [Event], decisions: [Decision]) {
        self.events = events
        self.decisions = decisions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        storeVersion = try c.decodeIfPresent(Int.self, forKey: .storeVersion)
        savedAt = try c.decodeIfPresent(CatalogJSONValue.self, forKey: .savedAt)
        events = try c.decodeIfPresent([Event].self, forKey: .events) ?? []
        let raw = try c.decodeIfPresent([CatalogJSONValue].self, forKey: .decisions) ?? []
        decisions = raw.map { Decision(payload: $0) }
    }

    public static func decode(_ data: Data) throws -> EventsDecisionsJSON {
        try JSONDecoder().decode(EventsDecisionsJSON.self, from: data)
    }

    /// Event ids that occur more than once (F4: a run-level refusal).
    public var duplicateEventIDs: [String] {
        var seen: [String: Int] = [:]
        for e in events { seen[CatalogRecordDTO.canonicalID(e.id), default: 0] += 1 }
        return seen.keys.sorted().filter { (seen[$0] ?? 0) > 1 }
    }

    /// Every `contentKey` a decision payload names (member ranges, both
    /// halves of a different-occasions pair, a category rejection's range).
    public static func contentKeys(in payload: CatalogJSONValue) -> [String] {
        var keys: [String] = []
        for member in ["range", "a", "b"] {
            if let key = payload[member]?["contentKey"]?.stringValue { keys.append(key) }
        }
        return keys
    }

    // MARK: The fold (EventsDecisionSnapshot, verbatim rules)

    /// One accepted range after the fold: the EFFECTIVE event (merges
    /// followed), the key and the optional in-file range.
    public struct Member: Sendable, Equatable, Hashable {
        public var eventID: String
        public var contentKey: String
        public var start: Double?
        public var end: Double?
    }

    /// accepted − rejected per effective event, merges followed (a chain is
    /// followed; a cycle stops at its first repeat). Decision order matters,
    /// as it does in the app.
    public func foldedMembers() -> [Member] {
        var mergedInto: [String: String] = [:]
        for d in decisions where d.kind == "merged" {
            guard let from = d.payload["from"]?.stringValue, let into = d.payload["into"]?.stringValue, from != into else { continue }
            mergedInto[CatalogRecordDTO.canonicalID(from)] = CatalogRecordDTO.canonicalID(into)
        }
        func effective(_ id: String) -> String {
            var current = id
            var seen: Set<String> = [id]
            while let next = mergedInto[current], seen.insert(next).inserted { current = next }
            return current
        }
        var accepted: [String: [Member]] = [:]   // event → ordered members
        for d in decisions where d.kind == "member" {
            guard let event = d.payload["eventID"]?.stringValue, let range = d.payload["range"],
                  let key = range["contentKey"]?.stringValue else { continue }
            let e = effective(CatalogRecordDTO.canonicalID(event))
            let member = Member(eventID: e, contentKey: key, start: range["start"]?.doubleValue, end: range["end"]?.doubleValue)
            var list = accepted[e] ?? []
            list.removeAll { $0 == member }
            if d.payload["verdict"]?.stringValue == "accepted" { list.append(member) }
            accepted[e] = list
        }
        return accepted.keys.sorted().flatMap { accepted[$0] ?? [] }
    }
}

// MARK: - ignored-content.json

public struct IgnoredContentJSON: Decodable, Sendable, Equatable {

    public struct Entry: Codable, Sendable, Equatable {
        public var id: String
        public var partialMD5: String?
        public var sizeBytes: Int64?
        public var filename: String?
        public var reason: String?
        public var addedAt: CatalogJSONDate?
        public var samplePath: String?

        public init(id: String, partialMD5: String?, sizeBytes: Int64?, filename: String?, reason: String?,
                    addedAt: CatalogJSONDate?, samplePath: String?) {
            self.id = id
            self.partialMD5 = partialMD5
            self.sizeBytes = sizeBytes
            self.filename = filename
            self.reason = reason
            self.addedAt = addedAt
            self.samplePath = samplePath
        }
    }

    public var storeVersion: Int?
    public var entries: [Entry]

    private enum Keys: String, CodingKey { case storeVersion, entries }

    public init(entries: [Entry]) {
        self.entries = entries
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        storeVersion = try c.decodeIfPresent(Int.self, forKey: .storeVersion)
        entries = try c.decodeIfPresent([Entry].self, forKey: .entries) ?? []
    }

    public static func decode(_ data: Data) throws -> IgnoredContentJSON {
        try JSONDecoder().decode(IgnoredContentJSON.self, from: data)
    }
}

// MARK: - ledger/media-ledger.jsonl

/// The ledger read line by line. A non-blank line that is a JSON object is
/// one `Line` (ordinal = its index among the non-blank lines); a non-blank
/// line that is not one is listed in `unparseable` by that same ordinal and
/// never guessed at.
public struct LedgerLinesJSON: Sendable, Equatable {

    public struct Line: Sendable, Equatable {
        public var ordinal: Int
        public var payload: [String: CatalogJSONValue]

        public var at: Int64? { payload["at"]?.stringValue.flatMap { CatalogJSONDate.parse($0) } }
        public var event: String { payload["event"]?.stringValue ?? "" }
        public var actor: String { payload["by"]?.stringValue ?? "" }
        public var recordID: String { CatalogRecordDTO.canonicalID(payload["recordID"]?.stringValue) }
        public var contentKey: String { payload["contentKey"]?.stringValue ?? "" }
        public var fullPath: String { payload["fullPath"]?.stringValue ?? "" }
    }

    public var lines: [Line]
    public var unparseable: [Int]

    public static func decode(_ data: Data) -> LedgerLinesJSON {
        var lines: [Line] = []
        var unparseable: [Int] = []
        var ordinal = 0
        for raw in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            let trimmed = raw.drop(while: { $0 == 0x20 || $0 == 0x0D || $0 == 0x09 })
            guard !trimmed.isEmpty else { continue }
            if let value = try? JSONDecoder().decode(CatalogJSONValue.self, from: Data(trimmed)), let object = value.objectValue {
                lines.append(Line(ordinal: ordinal, payload: object))
            } else {
                unparseable.append(ordinal)
            }
            ordinal += 1
        }
        return LedgerLinesJSON(lines: lines, unparseable: unparseable)
    }
}

// MARK: - fullhash-backfill.json

public struct BackfillMarkerJSON: Codable, Sendable, Equatable {
    public var startedAt: CatalogJSONDate
    public var finishedAt: CatalogJSONDate?
    public var hashedSoFar: Int?

    public init(startedAt: CatalogJSONDate, finishedAt: CatalogJSONDate?, hashedSoFar: Int?) {
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.hashedSoFar = hashedSoFar
    }

    public static func decode(_ data: Data) throws -> BackfillMarkerJSON {
        try JSONDecoder().decode(BackfillMarkerJSON.self, from: data)
    }
}
