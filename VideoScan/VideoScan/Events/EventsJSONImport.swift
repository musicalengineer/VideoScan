// EventsJSONImport.swift
// The import of events-decisions.json into catalog.sqlite (2026-10-19).
// Rick keeps making folders in the build he runs today, so the first launch
// of a build whose folders live in catalog.sqlite imports whatever the file
// holds then. After that this build never writes the file (like
// catalog.json).
//
// Idempotent, and a later change is never hidden (codex #113 P1-1):
//   * the import appends a `jsonImported` decision (file, SHA-256, counts)
//     to the stream. While the file's SHA-256 is the one the LATEST marker
//     recorded, a later launch only says so. When the file CHANGED after an
//     import — an older build kept writing it — it is reconciled AGAIN and
//     a new marker is appended;
//   * a decision already in the stream (the cutover importer may have
//     carried some, or an earlier import) is not appended twice (multiset
//     difference on the decoded values);
//   * a folder already in the catalog is compared field by field (name,
//     state, kind, categories, note): the NEWER `updatedAt` wins — the
//     file's row is written over the catalog's and said by name — and a tie
//     or an older file row keeps the catalog's, said as a FINDING. Never a
//     silent keep of stale values, never a silent overwrite.
// Nothing in the file is dropped: an element this build cannot read (a
// damaged folder, a damaged decision) rides into the stream verbatim as an
// `unreadable` entry with its index.
//
// After the write the catalog is read back and the counts are VERIFIED —
// every folder of the file is there, the stream grew by exactly what was
// appended, the members are the fold, every reconciled row reads back with
// the file's values — and one line says them (console, catalog.log,
// videoscan.log through the store's note), plus one line per reconciled or
// conflicting folder.
//
// Memory: the file is a few KB to a few MB (thousands of decisions); it is
// read whole, once.
//
// (For Rick: a migration script, written as a pure plan — `Plan` — plus the
// two calls that run it and check it.)

import Foundation
import VideoScanCore

/// The import as a value: what the file holds, what the catalog already
/// has, and what one transaction writes. Pure.
struct EventsJSONImportPlan: Sendable {

    /// The file read element by element.
    struct Parsed: Sendable, Equatable {
        var storeVersion: Int?
        var events: [EventRecord] = []
        var decisions: [EventDecision] = []
        /// Elements no reader could take, as `unreadable` stream entries.
        var unreadable: [EventDecision] = []
    }

    /// One folder the catalog and the file hold with other values.
    struct FolderDifference: Sendable, Equatable {
        var catalog: EventRecord
        var file: EventRecord
        /// The file's row is newer (`updatedAt`) — it is written.
        var fileWins: Bool { file.updatedAt > catalog.updatedAt }

        /// nil when the two agree on every field a person sets.
        static func of(_ catalog: EventRecord, _ file: EventRecord) -> FolderDifference? {
            let same = catalog.name == file.name && catalog.state == file.state && catalog.kind == file.kind
                && catalog.categories == file.categories && catalog.note == file.note
            return same ? nil : FolderDifference(catalog: catalog, file: file)
        }
    }

    let parsed: Parsed
    /// Folders of the file the catalog does not have yet.
    let newEvents: [EventRecord]
    /// Folders both hold with other values — the reconciliation.
    let differing: [FolderDifference]
    /// The file's decisions the stream does not hold yet, in file order;
    /// then the unreadable elements; then the marker.
    let appended: [EventDecision]
    let marker: EventsJSONImport
    /// The catalog's folders (reconciled) ∪ the file's new ones, folded
    /// with the whole stream.
    let folded: EventsDecisionSnapshot

    /// The file's rows that win the reconciliation (written).
    var updatedEvents: [EventRecord] { differing.filter(\.fileWins).map(\.file) }
    /// Rows whose catalog values are kept (findings).
    var conflicts: [FolderDifference] { differing.filter { !$0.fileWins } }

    // MARK: Parse

    /// nil when the file is not a JSON object at all (nothing is imported;
    /// the file is left as it is).
    static func parse(_ data: Data) -> Parsed? {
        guard let top = try? JSONDecoder().decode([String: JSONValue].self, from: data) else { return nil }
        var out = Parsed()
        if case .number(let v)? = top["storeVersion"] { out.storeVersion = Int(v) }
        for (i, value) in elements(top["events"]).enumerated() {
            if let e = decode(EventRecord.self, value) { out.events.append(e) } else { out.unreadable.append(unreadable("events", i, value)) }
        }
        for (i, value) in elements(top["decisions"]).enumerated() {
            if case .object = value, let d = decode(EventDecision.self, value) { out.decisions.append(d) }
            else { out.unreadable.append(unreadable("decisions", i, value)) }
        }
        return out
    }

    private static func elements(_ value: JSONValue?) -> [JSONValue] {
        if case .array(let list)? = value { return list }
        return []
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ value: JSONValue) -> T? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(type, from: data)
    }

    private static func unreadable(_ list: String, _ index: Int, _ value: JSONValue) -> EventDecision {
        .unknown(kind: EventDecision.unreadableKind,
                 payload: ["kind": .string(EventDecision.unreadableKind), "from": .string(list),
                           "index": .number(Double(index)), "raw": value])
    }

    // MARK: Plan

    init(parsed: Parsed, existingEvents: [EventRecord], existingDecisions: [EventDecision],
         file: String, sha256: String, at: Date) {
        self.parsed = parsed
        let have = Dictionary(existingEvents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seenNew = Set<UUID>(), seenOld = Set<UUID>()
        newEvents = parsed.events.filter { have[$0.id] == nil && seenNew.insert($0.id).inserted }
        differing = parsed.events.compactMap { e in
            guard let mine = have[e.id], seenOld.insert(e.id).inserted else { return nil }
            return FolderDifference.of(mine, e)
        }
        // Multiset difference: a decision (or an unreadable element, kept
        // verbatim by an earlier import) the stream already holds n times is
        // skipped n times, in file order — so a re-import appends only what
        // is new.
        var held: [EventDecision: Int] = [:]
        for d in existingDecisions { held[d, default: 0] += 1 }
        var fresh: [EventDecision] = []
        for d in parsed.decisions + parsed.unreadable {
            if let n = held[d], n > 0 { held[d] = n - 1 } else { fresh.append(d) }
        }
        marker = EventsJSONImport(file: file, sha256: sha256, events: parsed.events.count, decisions: parsed.decisions.count,
                                  unreadable: parsed.unreadable.count, at: at)
        appended = fresh + [.jsonImported(marker)]
        let winners = Dictionary(differing.filter(\.fileWins).map { ($0.file.id, $0.file) }, uniquingKeysWith: { first, _ in first })
        folded = EventsDecisionSnapshot(events: existingEvents.map { winners[$0.id] ?? $0 } + newEvents,
                                        decisions: existingDecisions + appended)
    }

    /// Every folder the import must leave with its fold written.
    var allFolders: Set<UUID> { Set(folded.events.keys) }

    /// Members the fold names across every folder (keys, before the
    /// catalog keeps only its stored digests).
    var foldedMemberKeys: Int {
        allFolders.reduce(0) { $0 + (folded.effectiveEvent($1) == $1 ? folded.members(of: $1).count : 0) }
    }
}

/// What the import did, for the one line and the tests.
enum EventsJSONImportOutcome: Sendable, Equatable {
    case noFile
    /// The file is the one the latest marker recorded (`changedSince` is
    /// kept for the words; a changed file is reconciled, never just said).
    case alreadyImported(changedSince: Bool)
    case notJSON
    case refused(String)
    /// Written and read back. `verified` false = a count did not match.
    /// `updated` = folders reconciled from the file; `conflicts` = folders
    /// whose catalog values were kept (findings).
    case imported(events: Int, newEvents: Int, decisions: Int, unreadable: Int, members: Int, verified: Bool,
                  updated: Int = 0, conflicts: Int = 0)
}

extension EventsCatalogBacking {

    /// Import events-decisions.json (see the header); every outcome is said
    /// through `note`, and every reconciled or conflicting folder by name.
    @discardableResult
    func importJSONOnce(from url: URL, note: (String) -> Void) async -> EventsJSONImportOutcome {
        let (outcome, plan) = await importJSON(from: url)
        note(EventsJSONImportWords.line(outcome, file: url.lastPathComponent))
        for line in EventsJSONImportWords.reconciliation(plan) { note(line) }
        return outcome
    }

    private func importJSON(from url: URL) async -> (EventsJSONImportOutcome, EventsJSONImportPlan?) {
        guard case .success(let before) = await read() else { return (.refused("catalog.sqlite's folders could not be read"), nil) }
        let file = await Self.fileFacts(url)
        // The LATEST marker decides: an unchanged file is done; a changed
        // one (or one never imported) is reconciled.
        if let marker = before.decisions.lazy.compactMap(Self.marker).last, file.map({ $0.sha256 == marker.sha256 }) ?? true {
            return (.alreadyImported(changedSince: false), nil)
        }
        guard let file else { return (.noFile, nil) }
        if let why = writeRefusal() { return (.refused(why), nil) }
        guard let parsed = EventsJSONImportPlan.parse(file.data) else { return (.notJSON, nil) }
        let plan = EventsJSONImportPlan(parsed: parsed, existingEvents: before.events, existingDecisions: before.decisions,
                                        file: url.lastPathComponent, sha256: file.sha256, at: Date())
        if let why = write(plan) { return (.refused(why), plan) }
        guard case .success(let after) = await read() else { return (.refused("written, but the folders could not be read back"), plan) }
        let verified = Self.verify(plan, before: before, after: after)
        return (.imported(events: parsed.events.count, newEvents: plan.newEvents.count, decisions: plan.appended.count,
                          unreadable: parsed.unreadable.count, members: after.counts.members, verified: verified,
                          updated: plan.updatedEvents.count, conflicts: plan.conflicts.count), plan)
    }

    private func write(_ plan: EventsJSONImportPlan) -> String? {
        let rows = (plan.newEvents + plan.updatedEvents).map(EventsCatalogRows.folder)
        let decisions: [(kind: String, json: String)]
        do { decisions = try plan.appended.map { ($0.kind, try EventsCatalogRows.json($0)) } } catch {
            return "a decision could not be encoded: \(error.localizedDescription)"
        }
        let folds = EventsCatalogRows.folds(of: plan.allFolders, in: plan.folded)
        return commitRaw("imported events-decisions.json") { tx in
            try Self.apply(tx, rows: rows, decisions: decisions, folds: folds)
        }
    }

    /// Counts in = counts out: every folder of the file is in the catalog,
    /// the stream grew by exactly what was appended, the members the
    /// catalog holds are no more than the fold names (a "pair:" key stays
    /// in the stream only), and every reconciled row reads back with the
    /// file's values.
    static func verify(_ plan: EventsJSONImportPlan, before: Read, after: Read) -> Bool {
        let byID = Dictionary(after.events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let everyFolder = plan.parsed.events.allSatisfy { byID[$0.id] != nil }
        let streamGrew = after.counts.decisions == before.counts.decisions + plan.appended.count
        let folders = after.counts.events == before.counts.events + plan.newEvents.count
        let members = after.counts.members <= plan.foldedMemberKeys
        let reconciled = plan.updatedEvents.allSatisfy { want in
            byID[want.id].map { EventsJSONImportPlan.FolderDifference.of($0, want) == nil } ?? false
        }
        return everyFolder && streamGrew && folders && members && reconciled
    }

    private static func marker(_ d: EventDecision) -> EventsJSONImport? {
        if case .jsonImported(let m) = d { return m }
        return nil
    }

    struct FileFacts: Sendable {
        let data: Data
        let sha256: String
    }

    /// The file's bytes and SHA-256, off the main actor; nil when absent.
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func fileFacts(_ url: URL) async -> FileFacts? {
        guard FileManager.default.fileExists(atPath: url.path), let data = try? Data(contentsOf: url),
              let sha = try? CatalogStore.sha256HexStreaming(fileURL: url) else { return nil }
        return FileFacts(data: data, sha256: sha)
    }
}

// MARK: - Words (pure)

enum EventsJSONImportWords {
    static func line(_ outcome: EventsJSONImportOutcome, file: String) -> String {
        switch outcome {
        case .noFile:
            return "Folders: catalog.sqlite holds the folders (there is no \(file) to import)"
        case .alreadyImported(let changed):
            return changed
                ? "Folders: \(file) CHANGED after it was imported into catalog.sqlite — catalog.sqlite holds the folders (the file is kept as it is)"
                : "Folders: catalog.sqlite holds the folders (\(file) was imported earlier and has not changed since)"
        case .notJSON:
            return "Folders: \(file) is not readable JSON — NOT imported; the file is left as it is"
        case .refused(let why):
            return "Folders: \(file) NOT imported into catalog.sqlite — \(why). The file is left as it is; the next launch tries again"
        case .imported(let events, let new, let decisions, let unreadable, let members, let verified, let updated, let conflicts):
            let counts = "\(events) folder\(events == 1 ? "" : "s") (\(new) new, \(updated) reconciled from the file, "
                + "\(conflicts) kept as catalog.sqlite has them), \(decisions) decision\(decisions == 1 ? "" : "s") appended "
                + "(\(unreadable) unreadable kept verbatim), \(members) member\(members == 1 ? "" : "s") in the catalog"
            return verified
                ? "Folders: OUTCOME imported \(file) into catalog.sqlite — \(counts); verified (counts in = counts out). The file is frozen history from now on"
                : "Folders: 🔴 imported \(file) into catalog.sqlite but the read-back did NOT match — \(counts). Nothing was deleted; check Catalog Status"
        }
    }

    /// One line per folder the reconciliation touched: written (the file's
    /// row was newer) or a FINDING (catalog.sqlite's newer or same-time
    /// values kept). A person can always see which.
    static func reconciliation(_ plan: EventsJSONImportPlan?) -> [String] {
        guard let plan else { return [] }
        let written = plan.differing.filter(\.fileWins).map {
            "Folders: reconciled “\($0.catalog.name)” from events-decisions.json — its row there is newer (\(fields($0))); written to catalog.sqlite"
        }
        let kept = plan.conflicts.map {
            "Folders: FINDING — “\($0.catalog.name)” differs in events-decisions.json (\(fields($0))) but catalog.sqlite's row is as new or newer; catalog.sqlite's is kept — change it by hand if the file's was meant"
        }
        return written + kept
    }

    private static func fields(_ d: EventsJSONImportPlan.FolderDifference) -> String {
        var out: [String] = []
        if d.catalog.name != d.file.name { out.append("name “\(d.catalog.name)” → “\(d.file.name)”") }
        if d.catalog.state != d.file.state { out.append("state \(d.catalog.state.rawValue) → \(d.file.state.rawValue)") }
        if d.catalog.kind != d.file.kind { out.append("kind \(d.catalog.kind.rawValue) → \(d.file.kind.rawValue)") }
        if d.catalog.categories != d.file.categories { out.append("categories") }
        if d.catalog.note != d.file.note { out.append("note") }
        return out.joined(separator: ", ")
    }
}
