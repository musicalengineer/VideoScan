// ImportSidecarsJSON+Decisions.swift
// The importer's own readings of the remaining §f sidecars (contract §c):
//   * events-decisions.json — `EventsDecisionFile` (A/Events/EventsDecisionStore
//     .swift:154): the event records typed, every decision kept as a verbatim
//     JSON object with its `kind` word (an unknown kind is still a decision);
//   * ignored-content.json — `IgnoredContentFile` (A/Catalog/IgnoredContentStore
//     .swift:109);
//   * ledger/media-ledger.jsonl — one `MediaLedgerEvent` per line
//     (C/MediaLedgerEvent.swift), read line by line: a line that is a JSON
//     object is a ledger line whatever its keys; only an UNTERMINATED last
//     line may be anything else (a torn append) and it is kept with its bytes;
//     any other malformed line refuses the run (fix 2026-10-17, codex D′ #5);
//   * fullhash-backfill.json — `FullHashBackfillRunRecord` (A/MediaOps/
//     FullHashBackfillResume.swift:26).
// Plus the fold of the decision stream into event membership
// (`EventsDecisionSnapshot`, EventsDecisionStore.swift:173), reproduced here
// as a pure function so the importer writes `event_members` the way the
// app computes them. Pure: callers pass Data.
//
// fix 2026-10-17 (codex D′ #3): the mapping from each entry to its table row
// (`row(ordinal:run:)`) lives here, once; the row pass writes it from the
// gate's decode and the comparator rebuilds it from its own re-decode and
// compares whole rows.
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

        /// The `events` row. `created_at` / `updated_at` are NOT NULL; the app
        /// always writes them. 0 marks a record that arrived without one — never "now".
        public func row(ordinal: Int, run: String) -> CatalogRow.Event {
            CatalogRow.Event(eventID: CatalogRecordDTO.canonicalID(id), name: name,
                             state: state ?? CatalogDDL.EventState.confirmed.rawValue, categories: categories ?? [],
                             note: note, createdAt: createdAt?.unixSeconds ?? 0,
                             updatedAt: updatedAt?.unixSeconds ?? createdAt?.unixSeconds ?? 0,
                             importRun: run, sourceOrdinal: ordinal)
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

        public func row(ordinal: Int, run: String) -> CatalogRow.EventDecision {
            CatalogRow.EventDecision(kind: kind, payload: payload, importRun: run, sourceOrdinal: ordinal)
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

    /// Source ordinals: events 0..<E, then decisions E..<E+D.
    public func decisionOrdinal(_ index: Int) -> Int { events.count + index }

    /// Canonical ids of every event record.
    public var knownEventIDs: Set<String> { Set(events.map { CatalogRecordDTO.canonicalID($0.id) }) }

    /// Event ids that occur more than once (F4: a run-level refusal).
    public var duplicateEventIDs: [String] {
        var seen: [String: Int] = [:]
        for e in events { seen[CatalogRecordDTO.canonicalID(e.id), default: 0] += 1 }
        return seen.keys.sorted().filter { (seen[$0] ?? 0) > 1 }
    }

    /// Entries the `events` / `event_members` tables would refuse (codex D′ #6).
    public var faults: [RowPreflight.SidecarFault] {
        var out: [RowPreflight.SidecarFault] = []
        for (ordinal, event) in events.enumerated() {
            out += RowPreflight.violations(event: event).map { .init(file: .eventsDecisions, ordinal: ordinal, words: $0) }
        }
        for (index, member) in foldedMembers().enumerated() {
            out += RowPreflight.violations(member: member).map { .init(file: .eventsDecisions, ordinal: decisionOrdinal(index), words: $0) }
        }
        return out
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

        /// The `ignored_content` row: `unbound` (F7: a sampled key never binds).
        public func row(ordinal: Int, run: String) -> CatalogRow.Ignored {
            CatalogRow.Ignored(entryID: CatalogRecordDTO.canonicalID(id), importRun: run, sourceOrdinal: ordinal,
                               partialMD5: partialMD5 ?? "", sizeBytes: sizeBytes ?? 0, filename: filename ?? "",
                               reason: reason ?? "", addedAt: addedAt?.unixSeconds ?? 0, samplePath: samplePath ?? "")
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

    /// Entries the `ignored_content` table would refuse (codex D′ #6).
    public var faults: [RowPreflight.SidecarFault] {
        entries.enumerated().flatMap { ordinal, entry in
            RowPreflight.violations(ignored: entry).map { .init(file: .ignoredContent, ordinal: ordinal, words: $0) }
        }
    }
}

// MARK: - ledger/media-ledger.jsonl

/// The ledger read line by line. A non-blank line that is a JSON object is
/// one `Line` (ordinal = its index among the non-blank lines). A non-blank
/// line that is not one is a CORRUPT line (listed in `corruptLines`, a
/// run-level refusal) — unless it is the LAST line and the file does not end
/// with a newline: that is a torn append, kept as a `Line` whose payload
/// carries its raw bytes (`isTrailingPartial`), never guessed at.
public struct LedgerLinesJSON: Sendable, Equatable {

    public struct Line: Sendable, Equatable {
        public var ordinal: Int
        public var payload: [String: CatalogJSONValue]
        /// The unterminated last line, kept as bytes (codex D′ #5).
        public var isTrailingPartial: Bool = false

        public var at: Int64? { payload["at"]?.stringValue.flatMap { CatalogJSONDate.parse($0) } }
        public var event: String { isTrailingPartial ? Self.unparseableKind : (payload["event"]?.stringValue ?? "") }
        public var actor: String { payload["by"]?.stringValue ?? "" }
        public var recordID: String { CatalogRecordDTO.canonicalID(payload["recordID"]?.stringValue) }
        public var contentKey: String { payload["contentKey"]?.stringValue ?? "" }
        public var fullPath: String { payload["fullPath"]?.stringValue ?? "" }

        /// `ledger.kind` of a torn last line.
        public static let unparseableKind = "unparseable"

        /// The torn line's payload: its bytes as text when they are UTF-8, and
        /// as base64 always (exact).
        public static func partialPayload(_ bytes: Data) -> [String: CatalogJSONValue] {
            ["unparseable": .bool(true), "rawText": .string(String(data: bytes, encoding: .utf8) ?? "(not UTF-8; see rawBase64)"),
             "rawBase64": .string(bytes.base64EncodedString())]
        }

        /// The `ledger` row: the line verbatim, its digest through the record
        /// id's JSON digest only (F7).
        func row(run: String, index: ImportRowIndex) -> CatalogRow.Ledger {
            CatalogRow.Ledger(at: at ?? 0, kind: event, actor: actor, recordID: recordID, contentKey: contentKey,
                              digest: index.facts[recordID]?.digest, path: fullPath, payload: .object(payload),
                              importRun: run, sourceOrdinal: ordinal)
        }
    }

    public var lines: [Line]
    /// Ordinals of malformed lines before the end (a run-level refusal, codex D′ #5).
    public var corruptLines: [Int]

    /// The torn last line's ordinal, when there is one.
    public var trailingPartialOrdinal: Int? { lines.first { $0.isTrailingPartial }?.ordinal }

    public static func decode(_ data: Data) -> LedgerLinesJSON {
        var lines: [Line] = []
        var corrupt: [Int] = []
        var ordinal = 0
        let segments = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        let terminated = data.last == 0x0A
        for (index, raw) in segments.enumerated() {
            let trimmed = raw.drop(while: { $0 == 0x20 || $0 == 0x0D || $0 == 0x09 })
            guard !trimmed.isEmpty else { continue }
            if let object = (try? JSONDecoder().decode(CatalogJSONValue.self, from: Data(trimmed)))?.objectValue {
                lines.append(Line(ordinal: ordinal, payload: object))
            } else if index == segments.count - 1 && !terminated {
                lines.append(Line(ordinal: ordinal, payload: Line.partialPayload(Data(raw)), isTrailingPartial: true))
            } else {
                corrupt.append(ordinal)
            }
            ordinal += 1
        }
        return LedgerLinesJSON(lines: lines, corruptLines: corrupt)
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

    /// `job_markers.detail`: the file body plus the hash of the file (codex D′ #3).
    public func markerDetail(fileSHA256: String) -> CatalogJSONValue {
        var body = (try? CatalogJSONValue.of(self).objectValue) ?? [:]
        body[CatalogRow.JobMarker.fileSHA256Key] = .string(fileSHA256)
        return .object(body)
    }
}
