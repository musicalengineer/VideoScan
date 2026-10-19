// EventsDecisionValues.swift
// Rick's event decisions as VALUES — what EventsDecisionStore holds, what it
// writes (to catalog.sqlite once that is the authority; to
// events-decisions.json before), and the folded snapshot the planner and
// the Catalog's folders read (docs/design/events_design.md §3.F; split out
// of EventsDecisionStore.swift 2026-10-19 when folders moved into
// catalog.sqlite — the store file keeps the store).
//
// A Catalog folder IS a confirmed event (Rick 2026-10-19: "Finder's
// handling, Photos albums' meaning" — a label, never a place on disk). Its
// KIND says what the label is about: an event (Thanksgiving 1990), a person
// (Dad) or anything else.
//
// Keys are CONTENT, not paths or record ids (`ContentRange`): a rescan, a
// moved drive or a regrouped suggestion cannot orphan a decision, and one
// content can be in several folders.
//
// Every decision is one `kind`-tagged object. A kind this build does not
// know (written by a newer build) is kept verbatim and written back
// unchanged (`.unknown`); a decision this build knows but cannot read is
// kept the same way.

import Foundation
import VideoScanCore

// MARK: - Values

/// A range of one recording's content: the whole file in v1.
struct ContentRange: Codable, Hashable, Sendable {
    /// The stored full SHA-256; "pair:<pairGroupID>" for A/V halves;
    /// "id:<recordID>" when neither is known.
    let contentKey: String
    let start: Double?
    let end: Double?

    init(contentKey: String, start: Double? = nil, end: Double? = nil) {
        self.contentKey = contentKey
        self.start = start
        self.end = end
    }
}

/// What a folder's label is about (schema v1.10 `events.kind`). Every
/// folder made before kinds existed is an event.
enum FolderKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case event, person, other

    var id: String { rawValue }

    /// "Event" / "Person" / "Other" — the menu and the inspector.
    var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    /// A word this build does not know reads as an event, never as a crash.
    init(word: String?) {
        self = word.flatMap(FolderKind.init(rawValue:)) ?? .event
    }
}

/// An event Rick confirmed (or later dismissed). Its identity is durable:
/// nothing the planner regroups can change it.
struct EventRecord: Codable, Sendable, Equatable, Identifiable {
    enum State: String, Codable, Sendable { case confirmed, dismissed }

    var id: UUID
    var name: String
    var categories: [String]
    var state: State
    var createdAt: Date
    var updatedAt: Date
    var note: String?
    /// Event / person / other (2026-10-19). Absent in older files → event.
    var kind: FolderKind

    init(id: UUID = UUID(), name: String, categories: [String], state: State = .confirmed,
         createdAt: Date = Date(), updatedAt: Date? = nil, note: String? = nil, kind: FolderKind = .event) {
        self.id = id
        self.name = name
        self.categories = categories
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.note = note
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey { case id, name, categories, state, createdAt, updatedAt, note, kind }

    // Hand-written only for `kind`: a file written before kinds has none.
    // (Synthesized Decodable would demand the key.)
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        categories = try c.decode([String].self, forKey: .categories)
        state = try c.decode(State.self, forKey: .state)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        kind = FolderKind(word: try c.decodeIfPresent(String.self, forKey: .kind))
    }

    var isLive: Bool { state == .confirmed }
}

/// A recording's content and a category, together (a category Rick said
/// no to FOR THAT recording — not a rejected membership, design §3.F).
struct EventsCategoryKey: Hashable, Sendable {
    let contentKey: String
    let category: String
    init(_ contentKey: String, _ category: String) {
        self.contentKey = contentKey
        self.category = category
    }
}

/// A change to a folder's LABEL — kept in the stream as history (the
/// folder row itself carries the current name / kind / state).
struct FolderEdit: Codable, Sendable, Hashable {
    enum Change: String, Codable, Sendable { case renamed, kindChanged, deleted }
    let eventID: UUID
    let change: Change
    let from: String?
    let to: String?
    let at: Date
}

/// The one-time import of events-decisions.json into catalog.sqlite
/// (2026-10-19), kept in the stream: its presence is what makes the import
/// idempotent; its numbers are what the import verified.
struct EventsJSONImport: Codable, Sendable, Hashable {
    let file: String
    let sha256: String
    let events: Int
    let decisions: Int
    /// Elements of the file that could not be read, kept verbatim in the
    /// stream as `unreadable` entries.
    let unreadable: Int
    let at: Date
}

/// One decision. (For Rick: an `enum` with associated values is Swift's
/// `std::variant` with names; `Codable` here reads and writes it as a
/// JSON object with a `kind` string.)
enum EventDecision: Sendable, Hashable {
    enum Verdict: String, Codable, Sendable { case accepted, rejected }

    case member(eventID: UUID, range: ContentRange, verdict: Verdict)
    case differentOccasions(a: ContentRange, b: ContentRange)
    case merged(from: UUID, into: UUID)
    case categoryRejected(range: ContentRange, category: String)
    case suggestionDismissed(key: String, facts: SuggestionFacts)
    /// A rename, kind change or delete of a folder — history only.
    case folderEdited(FolderEdit)
    /// events-decisions.json was imported into catalog.sqlite.
    case jsonImported(EventsJSONImport)
    /// A kind this build cannot read — kept verbatim, written back as is.
    case unknown(kind: String, payload: [String: JSONValue])

    var kind: String {
        switch self {
        case .member: return "member"
        case .differentOccasions: return "differentOccasions"
        case .merged: return "merged"
        case .categoryRejected: return "categoryRejected"
        case .suggestionDismissed: return "suggestionDismissed"
        case .folderEdited: return "folderEdited"
        case .jsonImported: return "jsonImported"
        case .unknown(let kind, _): return kind
        }
    }

    /// The kind word of an element of the JSON file that could not be read
    /// at all; its bytes ride along as `raw`.
    static let unreadableKind = "unreadable"
}

extension EventDecision: Codable {
    private struct Member: Codable { let kind: String; let eventID: UUID; let range: ContentRange; let verdict: Verdict }
    private struct Different: Codable { let kind: String; let a: ContentRange; let b: ContentRange }
    private struct Merged: Codable { let kind: String; let from: UUID; let into: UUID }
    private struct CategoryRejected: Codable { let kind: String; let range: ContentRange; let category: String }
    private struct Dismissed: Codable { let kind: String; let key: String; let facts: SuggestionFacts }
    private struct Edited: Codable { let kind: String; let edit: FolderEdit }
    private struct Imported: Codable { let kind: String; let json: EventsJSONImport }
    private struct Kind: Codable { let kind: String }

    init(from decoder: Decoder) throws {
        let kind = try Kind(from: decoder).kind
        let known: EventDecision?
        switch kind {
        case "member": known = (try? Member(from: decoder)).map { .member(eventID: $0.eventID, range: $0.range, verdict: $0.verdict) }
        case "differentOccasions": known = (try? Different(from: decoder)).map { .differentOccasions(a: $0.a, b: $0.b) }
        case "merged": known = (try? Merged(from: decoder)).map { .merged(from: $0.from, into: $0.into) }
        case "categoryRejected": known = (try? CategoryRejected(from: decoder)).map { .categoryRejected(range: $0.range, category: $0.category) }
        case "suggestionDismissed": known = (try? Dismissed(from: decoder)).map { .suggestionDismissed(key: $0.key, facts: $0.facts) }
        case "folderEdited": known = (try? Edited(from: decoder)).map { .folderEdited($0.edit) }
        case "jsonImported": known = (try? Imported(from: decoder)).map { .jsonImported($0.json) }
        default: known = nil
        }
        // Unknown kind, or a known kind this build cannot read: keep it whole.
        self = try known ?? .unknown(kind: kind, payload: [String: JSONValue](from: decoder))
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .member(let eventID, let range, let verdict):
            try Member(kind: kind, eventID: eventID, range: range, verdict: verdict).encode(to: encoder)
        case .differentOccasions(let a, let b):
            try Different(kind: kind, a: a, b: b).encode(to: encoder)
        case .merged(let from, let into):
            try Merged(kind: kind, from: from, into: into).encode(to: encoder)
        case .categoryRejected(let range, let category):
            try CategoryRejected(kind: kind, range: range, category: category).encode(to: encoder)
        case .suggestionDismissed(let key, let facts):
            try Dismissed(kind: kind, key: key, facts: facts).encode(to: encoder)
        case .folderEdited(let edit):
            try Edited(kind: kind, edit: edit).encode(to: encoder)
        case .jsonImported(let json):
            try Imported(kind: kind, json: json).encode(to: encoder)
        case .unknown(_, let payload):
            try payload.encode(to: encoder)
        }
    }
}

/// On-disk shape. Decisions are read one by one: a damaged element
/// becomes `.unknown` and is preserved, never dropped.
struct EventsDecisionFile: Codable, Sendable, Equatable {
    static let currentVersion = 1
    var storeVersion: Int = EventsDecisionFile.currentVersion
    var savedAt: Date
    var events: [EventRecord]
    var decisions: [EventDecision]

    init(savedAt: Date = Date(), events: [EventRecord] = [], decisions: [EventDecision] = []) {
        self.savedAt = savedAt
        self.events = events
        self.decisions = decisions
    }
}

// MARK: - Snapshot (Sendable; what the planner and the folders read)

/// Rick's decisions folded into O(1) lookups, built on the main actor and
/// handed to the planner as a value. Merges are followed to the surviving
/// event; a dismissed event frees its members.
struct EventsDecisionSnapshot: Sendable, Equatable {
    private(set) var events: [UUID: EventRecord] = [:]
    private(set) var mergedInto: [UUID: UUID] = [:]
    private(set) var accepted: [UUID: Set<ContentRange>] = [:]
    private(set) var rejected: [UUID: Set<ContentRange>] = [:]
    private(set) var differentOccasions: Set<EventsPair> = []
    private(set) var categoryRejected: Set<EventsCategoryKey> = []
    private(set) var dismissed: [String: SuggestionFacts] = [:]
    /// Content accepted into a live event — computed once, read per member.
    private(set) var settled: Set<String> = []
    /// Content key → the live events (folders) holding it, by name. One
    /// content can be in several folders (2026-10-19). Computed once.
    private(set) var foldersByKey: [String: [UUID]] = [:]

    static let empty = EventsDecisionSnapshot()

    init() {}

    init(events: [EventRecord], decisions: [EventDecision]) {
        for e in events { self.events[e.id] = e }
        for d in decisions { apply(d) }
        let live = liveEvents.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        for e in live {
            for r in members(of: e.id) {
                settled.insert(r.contentKey)
                foldersByKey[r.contentKey, default: []].append(e.id)
            }
        }
    }

    private mutating func apply(_ d: EventDecision) {
        switch d {
        case .merged(let from, let into) where from != into:
            mergedInto[from] = into
        case .member(let eventID, let range, let verdict):
            let e = effectiveEvent(eventID)
            if verdict == .accepted {
                accepted[e, default: []].insert(range)
                rejected[e]?.remove(range)
            } else {
                rejected[e, default: []].insert(range)
                accepted[e]?.remove(range)
            }
        case .differentOccasions(let a, let b):
            differentOccasions.insert(EventsPair(a.contentKey, b.contentKey))
        case .categoryRejected(let range, let category):
            categoryRejected.insert(EventsCategoryKey(range.contentKey, category))
        case .suggestionDismissed(let key, let facts):
            dismissed[key] = facts
        case .merged, .folderEdited, .jsonImported, .unknown:
            break
        }
    }

    /// The event an id stands for after merges (a chain is followed; a
    /// cycle stops at its first repeat).
    func effectiveEvent(_ id: UUID) -> UUID {
        var cur = id
        var seen: Set<UUID> = [id]
        while let next = mergedInto[cur], seen.insert(next).inserted { cur = next }
        return cur
    }

    /// Confirmed, not merged away.
    var liveEvents: [EventRecord] {
        events.values.filter { $0.state == .confirmed && mergedInto[$0.id] == nil }
    }

    /// The ranges accepted into `eventID` (after merges) and not rejected.
    func members(of eventID: UUID) -> Set<ContentRange> {
        let e = effectiveEvent(eventID)
        return (accepted[e] ?? []).subtracting(rejected[e] ?? [])
    }

    /// Accepted into a live event: settled, out of the queue. O(1).
    func isSettled(_ contentKey: String) -> Bool { settled.contains(contentKey) }

    /// The live folders holding `contentKey`, by name. O(1).
    func folders(containing contentKey: String) -> [UUID] { foldersByKey[contentKey] ?? [] }

    /// Every content key a membership decision names.
    var namedContentKeys: Set<String> {
        var keys = Set<String>()
        for set in accepted.values { for r in set { keys.insert(r.contentKey) } }
        for set in rejected.values { for r in set { keys.insert(r.contentKey) } }
        return keys
    }
}

// MARK: - Reading a file that may be damaged (what it can)

/// `[T]` decoded one element at a time: an element this build cannot read
/// is counted and skipped, never thrown over the whole file. (For Rick: a
/// per-element try/catch around the array decode.)
struct EventsLossyArray<Element: Decodable>: Decodable {
    var elements: [Element] = []
    var skipped = 0

    private struct Skip: Decodable {}

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        while !c.isAtEnd {
            if let e = try? c.decode(Element.self) {
                elements.append(e)
            } else {
                _ = try? c.decode(Skip.self)
                skipped += 1
            }
        }
    }
}

/// The file read leniently: every field optional, arrays lossy.
struct EventsDecisionFileRead: Decodable {
    var storeVersion: Int?
    var savedAt: Date?
    var events: EventsLossyArray<EventRecord>?
    var decisions: EventsLossyArray<EventDecision>?

    var skipped: Int { (events?.skipped ?? 0) + (decisions?.skipped ?? 0) }
}

/// What `load` found.
enum EventsDecisionLoad: Sendable, Equatable {
    case missing
    /// Fully read at this build's version: writable.
    case loaded
    /// Read as far as it could be; saving is refused for this reason.
    case readOnly(String)
}
