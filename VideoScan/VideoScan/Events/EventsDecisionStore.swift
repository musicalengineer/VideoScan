// EventsDecisionStore.swift
// Triage ▸ Events v1 — Rick's decisions, kept apart from everything the
// planner derives (docs/design/events_design.md §3.F; plan §3).
//
// `events-decisions.json` under App Support/VideoScan is Rick's word and
// the only authority: which suggestions he confirmed (and what he named
// them), which recordings he accepted or rejected as members, which pairs
// are different occasions, which events he merged, which categories he
// said no to, which suggestions he dismissed. Model output is never in it.
//
// Keys are CONTENT, not paths or record ids (`ContentRange`): a rescan,
// a moved drive or a regrouped suggestion cannot orphan a decision. The
// range carries an optional (start, end) so in-file ranges can arrive in
// v1.1 without a migration.
//
// Every decision is one `kind`-tagged object. A kind this build does not
// know (written by a newer build) is kept verbatim and written back
// unchanged (`.unknown`); a decision this build knows but cannot read is
// kept the same way. A NEWER `storeVersion` makes the store read-only —
// never empty — and the page says so.
//
// The store class (below the values) is the IgnoredContentStore shape: a
// main-actor façade over a Sendable file value, loaded and saved off-main
// through `AtomicFilePublish … .fullFsync`, the previous file kept as
// `.prev`. Writes are O(1) in memory plus one save.

import Combine
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

    init(id: UUID = UUID(), name: String, categories: [String], state: State = .confirmed,
         createdAt: Date = Date(), updatedAt: Date? = nil, note: String? = nil) {
        self.id = id
        self.name = name
        self.categories = categories
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.note = note
    }
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

/// One decision. (For Rick: an `enum` with associated values is Swift's
/// `std::variant` with names; `Codable` here reads and writes it as a
/// JSON object with a `kind` string.)
enum EventDecision: Sendable, Equatable {
    enum Verdict: String, Codable, Sendable { case accepted, rejected }

    case member(eventID: UUID, range: ContentRange, verdict: Verdict)
    case differentOccasions(a: ContentRange, b: ContentRange)
    case merged(from: UUID, into: UUID)
    case categoryRejected(range: ContentRange, category: String)
    case suggestionDismissed(key: String, facts: SuggestionFacts)
    /// A kind this build cannot read — kept verbatim, written back as is.
    case unknown(kind: String, payload: [String: JSONValue])

    var kind: String {
        switch self {
        case .member: return "member"
        case .differentOccasions: return "differentOccasions"
        case .merged: return "merged"
        case .categoryRejected: return "categoryRejected"
        case .suggestionDismissed: return "suggestionDismissed"
        case .unknown(let kind, _): return kind
        }
    }
}

extension EventDecision: Codable {
    private struct Member: Codable { let kind: String; let eventID: UUID; let range: ContentRange; let verdict: Verdict }
    private struct Different: Codable { let kind: String; let a: ContentRange; let b: ContentRange }
    private struct Merged: Codable { let kind: String; let from: UUID; let into: UUID }
    private struct CategoryRejected: Codable { let kind: String; let range: ContentRange; let category: String }
    private struct Dismissed: Codable { let kind: String; let key: String; let facts: SuggestionFacts }
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

// MARK: - Snapshot (Sendable; what the planner reads)

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

    static let empty = EventsDecisionSnapshot()

    init() {}

    init(events: [EventRecord], decisions: [EventDecision]) {
        for e in events { self.events[e.id] = e }
        for d in decisions { apply(d) }
        for e in liveEvents { for r in members(of: e.id) { settled.insert(r.contentKey) } }
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
        case .merged, .unknown:
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

// MARK: - The store (main-actor façade)

/// Main-actor façade over `events-decisions.json`. Reads are O(1); the
/// file is loaded and saved off-main. Directory injectable so tests never
/// touch the real App Support (under a test host the DEFAULT directory is
/// a per-process temp folder — the IgnoredContentStore discipline).
@MainActor
final class EventsDecisionStore: ObservableObject {

    /// The app's one store (one catalog, one Triage tab).
    static let shared = EventsDecisionStore()

    nonisolated static let filename = "events-decisions.json"
    /// The counts-only metrics object, beside the decisions.
    nonisolated static let statsFilename = "events_latest.json"

    nonisolated static var defaultDirectory: URL {
        if TestEnvironment.isTestHost {
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("VideoScan-tests/events-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("VideoScan", isDirectory: true)
    }

    let directory: URL
    nonisolated var fileURL: URL { directory.appendingPathComponent(Self.filename) }
    nonisolated var previousURL: URL { directory.appendingPathComponent(Self.filename + ".prev") }
    nonisolated var statsURL: URL { directory.appendingPathComponent(Self.statsFilename) }

    /// Bumped on every mutation and load — the ONE published signal.
    @Published private(set) var revision = 0
    private(set) var events: [UUID: EventRecord] = [:]
    private(set) var decisions: [EventDecision] = []
    private(set) var hasLoaded = false
    /// Why saving is refused — a newer build's file, a file not fully
    /// readable — nil when writable. The page says it.
    private(set) var readOnlyReason: String?
    var isReadOnly: Bool { readOnlyReason != nil }

    private let writer = EventsDecisionWriter()
    private var pendingSave: Task<Bool, Never>?

    init(directory: URL = EventsDecisionStore.defaultDirectory) {
        self.directory = directory
    }

    // MARK: Reads

    var eventCount: Int { events.count }
    var decisionCount: Int { decisions.count }
    func event(id: UUID) -> EventRecord? { events[id] }

    /// Rick's decisions as a value for the planner. O(decisions).
    func snapshot() -> EventsDecisionSnapshot {
        EventsDecisionSnapshot(events: Array(events.values), decisions: decisions)
    }

    // MARK: Writes (in memory, then one save)

    /// A new confirmed event with these members. nil when read-only.
    @discardableResult
    func confirm(name: String, categories: [String], members: [ContentRange], now: Date = Date()) -> EventRecord? {
        guard !isReadOnly else { return nil }
        let e = EventRecord(name: name, categories: categories, createdAt: now)
        events[e.id] = e
        decisions += members.map { .member(eventID: e.id, range: $0, verdict: .accepted) }
        changed()
        return e
    }

    @discardableResult
    func rename(_ id: UUID, to name: String, now: Date = Date()) -> Bool {
        guard !isReadOnly, var e = events[id] else { return false }
        e.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        e.updatedAt = now
        events[id] = e
        changed()
        return true
    }

    @discardableResult
    func setState(_ id: UUID, _ state: EventRecord.State, now: Date = Date()) -> Bool {
        guard !isReadOnly, var e = events[id] else { return false }
        e.state = state
        e.updatedAt = now
        events[id] = e
        changed()
        return true
    }

    /// Append one decision. false when read-only.
    @discardableResult
    func record(_ decision: EventDecision) -> Bool {
        guard !isReadOnly else { return false }
        decisions.append(decision)
        changed()
        return true
    }

    @discardableResult
    func setMember(event id: UUID, range: ContentRange, verdict: EventDecision.Verdict, now: Date = Date()) -> Bool {
        guard !isReadOnly, var e = events[id] else { return false }
        e.updatedAt = now
        events[id] = e
        return record(.member(eventID: id, range: range, verdict: verdict))
    }

    /// `from` folds into `into`; `from` is marked dismissed with a note.
    @discardableResult
    func merge(_ from: UUID, into: UUID, now: Date = Date()) -> Bool {
        guard !isReadOnly, from != into, var a = events[from], events[into] != nil else { return false }
        a.state = .dismissed
        a.note = "merged into \(events[into]?.name ?? into.uuidString)"
        a.updatedAt = now
        events[from] = a
        return record(.merged(from: from, into: into))
    }

    /// Move `ranges` out of `from` into a new event. nil when read-only.
    @discardableResult
    func split(_ from: UUID, ranges: [ContentRange], name: String, now: Date = Date()) -> EventRecord? {
        guard !isReadOnly, let source = events[from], !ranges.isEmpty else { return nil }
        let e = EventRecord(name: name, categories: source.categories, createdAt: now)
        events[e.id] = e
        for r in ranges {
            decisions.append(.member(eventID: from, range: r, verdict: .rejected))
            decisions.append(.member(eventID: e.id, range: r, verdict: .accepted))
        }
        changed()
        return e
    }

    private func changed() {
        revision &+= 1
        scheduleSave()
    }

    // MARK: Disk

    /// Load off-main and publish. Missing → empty and writable. A newer
    /// `storeVersion`, or a file only partly readable → what could be read,
    /// and READ-ONLY (never treated as empty: Rick's word is not overwritten).
    @discardableResult
    func load() async -> EventsDecisionLoad {
        let outcome = await Self.loadOffMain(fileURL)
        hasLoaded = true
        switch outcome {
        case .missing:
            readOnlyReason = nil
            return .missing
        case .read(let file, let reason):
            events = Dictionary(uniqueKeysWithValues: file.events.map { ($0.id, $0) })
            decisions = file.decisions
            readOnlyReason = reason
            revision &+= 1
            return reason.map { .readOnly($0) } ?? .loaded
        }
    }

    /// Save now (the pending coalesced save, awaited). false when read-only
    /// or the write failed.
    @discardableResult
    func save() async -> Bool {
        guard !isReadOnly else { return false }
        scheduleSave()
        return await pendingSave?.value ?? false
    }

    /// One save in flight at a time, the newest content wins: the file
    /// value is encoded here (cheap) and the bytes handed to the writer.
    private func scheduleSave() {
        guard !isReadOnly else { return }
        let file = EventsDecisionFile(events: events.values.sorted { $0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt : $0.id.uuidString < $1.id.uuidString },
                                      decisions: decisions)
        let target = fileURL
        let previous = previousURL
        let writer = writer
        pendingSave = Task {
            await writer.write(file, to: target, previous: previous)
        }
    }

    enum Loaded: Sendable {
        case missing
        /// The file as far as it could be read; `readOnly` says why saving
        /// is refused, nil when it was fully read at this version.
        case read(EventsDecisionFile, readOnly: String?)
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func loadOffMain(_ url: URL) async -> Loaded {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url) else { return .read(EventsDecisionFile(), readOnly: "the file could not be read") }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let read = try? dec.decode(EventsDecisionFileRead.self, from: data) else {
            return .read(EventsDecisionFile(), readOnly: "the file is not readable as JSON — nothing will be written over it")
        }
        let file = EventsDecisionFile(savedAt: read.savedAt ?? Date(), events: read.events?.elements ?? [],
                                      decisions: read.decisions?.elements ?? [])
        let version = read.storeVersion ?? 0
        if version > EventsDecisionFile.currentVersion {
            return .read(file, readOnly: "written by a newer VideoScan (store version \(version)) — read, never rewritten by this one")
        }
        if read.skipped > 0 || read.storeVersion == nil {
            return .read(file, readOnly: "\(read.skipped) entr\(read.skipped == 1 ? "y" : "ies") could not be read — nothing will be written over it")
        }
        return .read(file, readOnly: nil)
    }
}

/// Serialises saves: the previous file is kept as `.prev`, then the new
/// bytes are published atomically with a full fsync. (For Rick: an
/// `actor` ≈ a class whose members are guarded by one implicit mutex —
/// two saves never interleave.)
actor EventsDecisionWriter {
    func write(_ file: EventsDecisionFile, to url: URL, previous: URL) -> Bool {
        do {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            enc.outputFormatting = [.sortedKeys, .prettyPrinted]
            let data = try enc.encode(file)
            if let old = try? Data(contentsOf: url) {
                try AtomicFilePublish.write(old, to: previous)
            }
            try AtomicFilePublish.write(data, to: url, durability: .fullFsync)
            return true
        } catch {
            return false
        }
    }
}
