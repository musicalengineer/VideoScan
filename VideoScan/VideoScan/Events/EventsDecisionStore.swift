// EventsDecisionStore.swift
// Triage ▸ Events v1 — Rick's decisions, kept apart from everything the
// planner derives (docs/design/events_design.md §3.F; plan §3) — and,
// since 2026-10-19, the Catalog's FOLDERS (a folder is a confirmed event:
// "Finder's handling, Photos albums' meaning" — a label, never a place on
// disk). The values live in EventsDecisionValues.swift.
//
// WHERE IT LIVES. Two backings, one store:
//   * catalog.sqlite — once it is the catalog's authority, the model hands
//     the store its committer (`attachCatalog`, EventsCatalogBacking.swift).
//     Every change is ONE synchronous write through the committer (the one
//     writer; a read-only or viewer session refuses with words) BEFORE it
//     lands in memory, so memory never runs ahead of the disk. The first
//     attach imports events-decisions.json once (idempotent); after that the
//     file is frozen history, never written again (like catalog.json).
//     Back Up Catalog carries the folders because they are in catalog.sqlite.
//   * events-decisions.json — before the switch to SQLite (and under a test
//     host): the IgnoredContentStore shape, loaded and saved off-main through
//     `AtomicFilePublish … .fullFsync`, the previous file kept as `.prev`.
//
// Either way a NEWER `storeVersion` file, or one only partly readable, makes
// the JSON store read-only — never empty — and the page says so. Writes are
// O(1) in memory plus one write (catalog) or one coalesced save (JSON).
//
// Every write goes through `commit(_:)`: the change as a value (the rows it
// upserts, the decisions it appends, the folders whose membership moved).
// (For Rick: a write-ahead step — build the delta, persist it, then apply
// it — the same order a database's own WAL keeps.)

import Combine
import Foundation
import os
import VideoScanCore

/// One change to Rick's decisions, as a value: what the catalog writes in
/// one transaction and what memory then applies.
struct EventsDecisionChange: Sendable, Equatable {
    /// Folder rows after the change (inserted or updated).
    var events: [EventRecord] = []
    /// Appended to the stream, in order.
    var decisions: [EventDecision] = []
    /// Folders whose membership fold must be rewritten.
    var touched: Set<UUID> = []
    /// What the change is, in a few words (the commit's log line).
    var what: String = "folders"
}

// MARK: - The store (main-actor façade)

/// Main-actor façade over Rick's decisions. Reads are O(1); see the header
/// for where they are kept. Directory injectable so tests never touch the
/// real App Support (under a test host the DEFAULT directory is a
/// per-process temp folder — the IgnoredContentStore discipline).
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
    /// Why saving is refused by the FILE — a newer build's, not fully
    /// readable — nil when it was read whole. The page says it.
    private(set) var readOnlyReason: String?
    /// The last save that failed ("not saved: …"), cleared by the next
    /// one that succeeds. Not a refusal — the next change tries again —
    /// but the page shows it (QA P2-a).
    private(set) var lastSaveFailure: String?
    /// catalog.sqlite once it is the authority; nil = the JSON file.
    private(set) var catalog: EventsCatalogBacking?
    /// The folded decisions, rebuilt once per change (O(decisions)) — never
    /// in a view body.
    private(set) var current = EventsDecisionSnapshot.empty

    /// Writes are refused until `load()` has run (a write before the load
    /// would publish an empty store over Rick's file — QA P1-b), while the
    /// file is read-only, and while the catalog cannot take a write (a
    /// viewer, a read-only launch, a held or blocked catalog).
    var isReadOnly: Bool { writeRefusal != nil }
    var isWritable: Bool { writeRefusal == nil }
    /// Why a write is refused right now, nil when writable.
    var writeRefusal: String? {
        guard hasLoaded else { return "decisions not loaded yet" }
        return readOnlyReason ?? catalog?.writeRefusal()
    }
    /// What the page should say: a refusal, else the last failed save.
    var problem: String? { writeRefusal ?? lastSaveFailure }

    /// Where a problem is said: the Events log sink once the page has one
    /// (`EventsStore.refresh` points it at `VideoScanModel.eventsNote`);
    /// the app log and the unified log until then.
    var note: (String) -> Void = { line in
        appLog.write("[events] " + line)
        eventsStoreLog.notice("\(line, privacy: .public)")
    }

    private let writer: EventsDecisionWriter
    private var pendingSave: Task<Bool, Never>?
    /// A change already has a save queued that has not started encoding:
    /// further changes before it runs fold into it (QA P2-c).
    private var saveScheduled = false
    /// The catalog's one-time import + first read, awaited by every load.
    private var catalogLoad: Task<EventsDecisionLoad, Never>?

    init(directory: URL = EventsDecisionStore.defaultDirectory, publisher: EventsDecisionPublisher = .atomic) {
        self.directory = directory
        writer = EventsDecisionWriter(publisher: publisher)
    }

    // MARK: Reads

    var eventCount: Int { events.count }
    var decisionCount: Int { decisions.count }
    func event(id: UUID) -> EventRecord? { events[id] }

    /// Rick's decisions as a value for the planner. O(1): the snapshot is
    /// rebuilt once per change.
    func snapshot() -> EventsDecisionSnapshot { current }

    /// The live folders holding this content, by name ("In folders: …").
    func folderNames(containing contentKey: String) -> [String] {
        current.folders(containing: contentKey).compactMap { events[$0].map { EventsNaming.folderTitle($0.name) } }
    }

    // MARK: Writes (one change → persisted → applied)

    /// A new confirmed event (folder) with these members. nil when refused.
    @discardableResult
    func confirm(name: String, categories: [String], members: [ContentRange], kind: FolderKind = .event,
                 now: Date = Date()) -> EventRecord? {
        let e = EventRecord(name: name, categories: categories, createdAt: now, kind: kind)
        let change = EventsDecisionChange(events: [e], decisions: members.map { .member(eventID: e.id, range: $0, verdict: .accepted) },
                                          touched: [e.id], what: "made a folder")
        return commit(change) ? e : nil
    }

    @discardableResult
    func renameEvent(_ id: UUID, to name: String, now: Date = Date()) -> Bool {
        guard var e = events[id] else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let edit = FolderEdit(eventID: id, change: .renamed, from: e.name, to: trimmed, at: now)
        e.name = trimmed
        e.updatedAt = now
        return commit(EventsDecisionChange(events: [e], decisions: [.folderEdited(edit)], what: "renamed a folder"))
    }

    /// Event / person / other. Unchanged kind: nothing to write (true).
    @discardableResult
    func setKind(_ id: UUID, _ kind: FolderKind, now: Date = Date()) -> Bool {
        guard var e = events[id] else { return false }
        guard e.kind != kind else { return isWritable }
        let edit = FolderEdit(eventID: id, change: .kindChanged, from: e.kind.rawValue, to: kind.rawValue, at: now)
        e.kind = kind
        e.updatedAt = now
        return commit(EventsDecisionChange(events: [e], decisions: [.folderEdited(edit)], what: "changed a folder's kind"))
    }

    @discardableResult
    func setState(_ id: UUID, _ state: EventRecord.State, now: Date = Date()) -> Bool {
        guard var e = events[id] else { return false }
        e.state = state
        e.updatedAt = now
        return commit(EventsDecisionChange(events: [e], what: "set a folder's state"))
    }

    /// Delete Folder: the LABEL goes (the event is dismissed); the files are
    /// untouched and the stream keeps the folder's whole history.
    @discardableResult
    func deleteFolder(_ id: UUID, now: Date = Date()) -> Bool {
        guard var e = events[id], e.isLive else { return false }
        let edit = FolderEdit(eventID: id, change: .deleted, from: e.name, to: nil, at: now)
        e.state = .dismissed
        e.updatedAt = now
        return commit(EventsDecisionChange(events: [e], decisions: [.folderEdited(edit)], what: "deleted a folder"))
    }

    /// Append one decision. false when refused.
    @discardableResult
    func record(_ decision: EventDecision) -> Bool {
        record([decision])
    }

    /// Append several decisions as ONE change — one revision, one write
    /// (the k·(k−1)/2 "different occasions" pairs, a batch of rejections).
    /// false when refused or empty.
    @discardableResult
    func record(_ batch: [EventDecision]) -> Bool {
        guard !batch.isEmpty else { return false }
        return commit(EventsDecisionChange(decisions: batch, touched: Self.eventsNamed(by: batch), what: "recorded decisions"))
    }

    @discardableResult
    func setMember(event id: UUID, range: ContentRange, verdict: EventDecision.Verdict, now: Date = Date()) -> Bool {
        guard var e = events[id] else { return false }
        e.updatedAt = now
        return commit(EventsDecisionChange(events: [e], decisions: [.member(eventID: id, range: range, verdict: verdict)],
                                           touched: [id], what: "changed a folder's members"))
    }

    /// `from` folds into `into`; `from` is marked dismissed with a note.
    @discardableResult
    func merge(_ from: UUID, into: UUID, now: Date = Date()) -> Bool {
        guard from != into, var a = events[from], events[into] != nil else { return false }
        a.state = .dismissed
        a.note = "merged into \(events[into]?.name ?? into.uuidString)"
        a.updatedAt = now
        return commit(EventsDecisionChange(events: [a], decisions: [.merged(from: from, into: into)],
                                           touched: [from, into], what: "merged folders"))
    }

    /// Move `ranges` out of `from` into a new event. nil when refused.
    @discardableResult
    func split(_ from: UUID, ranges: [ContentRange], name: String, now: Date = Date()) -> EventRecord? {
        guard let source = events[from], !ranges.isEmpty else { return nil }
        let e = EventRecord(name: name, categories: source.categories, createdAt: now, kind: source.kind)
        var batch: [EventDecision] = []
        for r in ranges {
            batch.append(.member(eventID: from, range: r, verdict: .rejected))
            batch.append(.member(eventID: e.id, range: r, verdict: .accepted))
        }
        return commit(EventsDecisionChange(events: [e], decisions: batch, touched: [from, e.id], what: "split a folder")) ? e : nil
    }

    /// Add `ranges` to event `id` (Add to Folder, a drag onto its folder —
    /// Catalog, 2026-10-19). `movingFrom` names, per OTHER event, the
    /// ranges that leave it (Move to Folder, a drag out of a folder). A
    /// recording may be in several folders: nothing leaves a folder unless
    /// `movingFrom` says so. The same `member` decisions as `split` and
    /// `setMember`, as ONE change. false when refused, when `id` is
    /// unknown, or when there is nothing to do.
    @discardableResult
    func addMembers(_ ranges: [ContentRange], to id: UUID, movingFrom: [UUID: [ContentRange]] = [:],
                    now: Date = Date()) -> Bool {
        guard events[id] != nil else { return false }
        // Sorted for a deterministic stream (a Dictionary has no order).
        let leaving = movingFrom.filter { $0.key != id && !$0.value.isEmpty }.sorted { $0.key.uuidString < $1.key.uuidString }
        guard !ranges.isEmpty || !leaving.isEmpty else { return false }
        var change = EventsDecisionChange(what: leaving.isEmpty ? "added files to a folder" : "moved files between folders")
        for (from, moved) in leaving {
            change.decisions += moved.map { .member(eventID: from, range: $0, verdict: .rejected) }
            if var e = events[from] { e.updatedAt = now; change.events.append(e) }
            change.touched.insert(from)
        }
        change.decisions += ranges.map { .member(eventID: id, range: $0, verdict: .accepted) }
        if var e = events[id] { e.updatedAt = now; change.events.append(e) }
        change.touched.insert(id)
        return commit(change)
    }

    /// Remove from Folder: these ranges leave `id` (the files are untouched).
    @discardableResult
    func removeMembers(_ ranges: [ContentRange], from id: UUID, now: Date = Date()) -> Bool {
        guard var e = events[id], !ranges.isEmpty else { return false }
        e.updatedAt = now
        return commit(EventsDecisionChange(events: [e], decisions: ranges.map { .member(eventID: id, range: $0, verdict: .rejected) },
                                           touched: [id], what: "removed files from a folder"))
    }

    /// Events whose fold a batch of decisions can move.
    private static func eventsNamed(by batch: [EventDecision]) -> Set<UUID> {
        var ids = Set<UUID>()
        for d in batch {
            switch d {
            case .member(let eventID, _, _): ids.insert(eventID)
            case .merged(let from, let into): ids.formUnion([from, into])
            default: break
            }
        }
        return ids
    }

    /// THE write. Refused → nothing changes (the words are said and kept
    /// for the page). Catalog: persisted first, then applied. JSON: applied,
    /// then one coalesced save.
    private func commit(_ change: EventsDecisionChange) -> Bool {
        guard isWritable else { return false }
        var nextEvents = events
        for e in change.events { nextEvents[e.id] = e }
        let nextDecisions = decisions + change.decisions
        let next = EventsDecisionSnapshot(events: Array(nextEvents.values), decisions: nextDecisions)
        if let catalog {
            if let why = catalog.write(change, folded: next) {
                lastSaveFailure = "not saved: \(why)"
                note("🔴 \(change.what) was NOT saved to catalog.sqlite: \(why) — nothing changed")
                revision &+= 1
                return false
            }
            if lastSaveFailure != nil { lastSaveFailure = nil }
        }
        events = nextEvents
        decisions = nextDecisions
        current = next
        revision &+= 1
        if catalog == nil { scheduleSave() }
        return true
    }

    private func adopt(events list: [EventRecord], decisions stream: [EventDecision]) {
        events = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        decisions = stream
        current = EventsDecisionSnapshot(events: list, decisions: stream)
    }

    // MARK: catalog.sqlite

    /// catalog.sqlite became the authority (the model's launch): from now
    /// on every change is written there. The first load imports
    /// events-decisions.json once, verifies the counts and says them; the
    /// file is never written again. Writes wait for that load.
    func attachCatalog(_ backing: EventsCatalogBacking) {
        catalog = backing
        hasLoaded = false
        saveScheduled = false
        pendingSave = nil
        let file = fileURL
        catalogLoad = Task { [weak self] in
            await backing.importJSONOnce(from: file) { self?.note($0) }
            guard let self else { return .missing }
            return await self.readCatalog(backing)
        }
    }

    private func readCatalog(_ backing: EventsCatalogBacking) async -> EventsDecisionLoad {
        switch await backing.read() {
        case .success(let read):
            adopt(events: read.events, decisions: read.decisions)
            readOnlyReason = nil
            if read.unreadableRows > 0 {
                note("\(read.unreadableRows) folder row(s) in catalog.sqlite could not be read — left as they are")
            }
        case .failure(let words):
            readOnlyReason = "the folders could not be read from catalog.sqlite (\(words)) — nothing will be written"
            note("🔴 " + (readOnlyReason ?? ""))
        }
        hasLoaded = true
        revision &+= 1
        return readOnlyReason.map { .readOnly($0) } ?? .loaded
    }

    // MARK: Disk (events-decisions.json, and the catalog's first read)

    /// Load and publish. Catalog: the attach's import + read (awaited).
    /// JSON, off-main: missing → empty and writable; a newer `storeVersion`,
    /// or a file only partly readable → what could be read, and READ-ONLY
    /// (never treated as empty: Rick's word is not overwritten).
    @discardableResult
    func load() async -> EventsDecisionLoad {
        if let catalogLoad { return await catalogLoad.value }
        let outcome = await Self.loadOffMain(fileURL)
        hasLoaded = true
        switch outcome {
        case .missing:
            readOnlyReason = nil
            return .missing
        case .read(let file, let reason):
            adopt(events: file.events, decisions: file.decisions)
            readOnlyReason = reason
            revision &+= 1
            return reason.map { .readOnly($0) } ?? .loaded
        }
    }

    /// Save now: the pending save (every change schedules one), awaited;
    /// a fresh one only when nothing is pending. false when read-only or
    /// the write failed. Catalog: every change is already written — true
    /// unless the last one failed.
    @discardableResult
    func save() async -> Bool {
        guard isWritable else { return false }
        if catalog != nil { return lastSaveFailure == nil }
        if pendingSave == nil { scheduleSave() }
        return await pendingSave?.value ?? false
    }

    /// The coalescing contract (QA P2-c): a change marks a save as
    /// scheduled and queues ONE task; every change before that task runs
    /// folds into it, because the task encodes the store's state when it
    /// STARTS (on the main actor, after the changes), not when queued. A
    /// change that lands after it started schedules the next one. The
    /// writer actor serialises the publishes, and each later publish
    /// carries a later state, so the file always ends at the newest.
    /// Never while catalog.sqlite is the authority: the file is frozen.
    private func scheduleSave() {
        guard catalog == nil, isWritable, !saveScheduled else { return }
        saveScheduled = true
        pendingSave = Task { [weak self] in
            guard let self, self.catalog == nil else { return false }
            self.saveScheduled = false
            let file = self.currentFile()
            let why = await self.writer.write(file, to: self.fileURL, previous: self.previousURL)
            self.noteSaveResult(why)
            return why == nil
        }
    }

    /// The file value, newest events last by creation.
    private func currentFile() -> EventsDecisionFile {
        EventsDecisionFile(events: events.values.sorted { $0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt : $0.id.uuidString < $1.id.uuidString },
                           decisions: decisions)
    }

    /// A failed save is said out loud and kept for the page; a later
    /// success clears it. Never swallowed (QA P2-a).
    private func noteSaveResult(_ failure: String?) {
        if let failure {
            lastSaveFailure = "not saved: \(failure)"
            note("🔴 decisions were not saved to \(fileURL.path): \(failure) — the decision is kept in memory and the next change tries again")
            revision &+= 1
        } else if lastSaveFailure != nil {
            lastSaveFailure = nil
            note("decisions saved again after an earlier failure")
            revision &+= 1
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
        if read.storeVersion == nil {
            return .read(file, readOnly: "the file has no store version — nothing will be written over it")
        }
        if read.skipped > 0 {
            return .read(file, readOnly: "\(read.skipped) entr\(read.skipped == 1 ? "y" : "ies") could not be read — nothing will be written over it")
        }
        return .read(file, readOnly: nil)
    }
}

private let eventsStoreLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "events")

/// How the bytes reach the disk. Production keeps the previous file as
/// `.prev` and publishes atomically with a full fsync; a test counts.
/// (For Rick: a function object — `std::function` — handed in at init.)
struct EventsDecisionPublisher: Sendable {
    let publish: @Sendable (_ data: Data, _ to: URL, _ previous: URL) throws -> Void

    static let atomic = EventsDecisionPublisher { data, url, previous in
        if let old = try? Data(contentsOf: url) {
            try AtomicFilePublish.write(old, to: previous)
        }
        try AtomicFilePublish.write(data, to: url, durability: .fullFsync)
    }
}

/// Serialises saves through the publisher. (For Rick: an `actor` ≈ a
/// class whose members are guarded by one implicit mutex — two saves
/// never interleave.) Returns nil on success, else why it failed.
actor EventsDecisionWriter {
    private let publisher: EventsDecisionPublisher

    init(publisher: EventsDecisionPublisher) {
        self.publisher = publisher
    }

    func write(_ file: EventsDecisionFile, to url: URL, previous: URL) -> String? {
        do {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            enc.outputFormatting = [.sortedKeys, .prettyPrinted]
            try publisher.publish(try enc.encode(file), url, previous)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
