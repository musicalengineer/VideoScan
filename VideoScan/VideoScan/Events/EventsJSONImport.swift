// EventsJSONImport.swift
// The ONE-TIME import of events-decisions.json into catalog.sqlite
// (2026-10-19). Rick keeps making folders in the build he runs today, so
// the first launch of a build whose folders live in catalog.sqlite imports
// whatever the file holds then. After that the file is frozen history —
// left in place, never written again (like catalog.json).
//
// Idempotent, twice over:
//   * the import appends a `jsonImported` decision (file, SHA-256, counts)
//     to the stream; a stream that has one is never imported into again —
//     a later launch only says so (and says if the file changed since);
//   * a folder already in the catalog is not rewritten, and a decision
//     already in the stream (the cutover importer may have carried some) is
//     not appended twice (multiset difference on the decoded values).
// Nothing in the file is dropped: an element this build cannot read (a
// damaged folder, a damaged decision) rides into the stream verbatim as an
// `unreadable` entry with its index.
//
// After the write the catalog is read back and the counts are VERIFIED —
// every folder of the file is there, the stream grew by exactly what was
// appended, the members are the fold — and one line says them (console,
// catalog.log, videoscan.log through the store's note).
//
// Memory: the file is a few KB to a few MB (thousands of decisions); it is
// read whole, once.
//
// (For Rick: a migration script, written as a pure plan — `Plan` — plus the
// two calls that run it and check it.)

import Foundation
import VideoScanCore

/// The import as a value: what the file holds, what the catalog already
/// has, and what one transaction appends. Pure.
struct EventsJSONImportPlan: Sendable {

    /// The file read element by element.
    struct Parsed: Sendable, Equatable {
        var storeVersion: Int?
        var events: [EventRecord] = []
        var decisions: [EventDecision] = []
        /// Elements no reader could take, as `unreadable` stream entries.
        var unreadable: [EventDecision] = []
    }

    let parsed: Parsed
    /// Folders of the file the catalog does not have yet.
    let newEvents: [EventRecord]
    /// The file's decisions the stream does not hold yet, in file order;
    /// then the unreadable elements; then the marker.
    let appended: [EventDecision]
    let marker: EventsJSONImport
    /// The catalog's folders ∪ the file's, folded with the whole stream.
    let folded: EventsDecisionSnapshot

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
        let have = Set(existingEvents.map(\.id))
        var seenNew = Set<UUID>()
        newEvents = parsed.events.filter { !have.contains($0.id) && seenNew.insert($0.id).inserted }
        // Multiset difference: a decision the stream already holds n times
        // is skipped n times, in file order.
        var held: [EventDecision: Int] = [:]
        for d in existingDecisions { held[d, default: 0] += 1 }
        var fresh: [EventDecision] = []
        for d in parsed.decisions {
            if let n = held[d], n > 0 { held[d] = n - 1 } else { fresh.append(d) }
        }
        marker = EventsJSONImport(file: file, sha256: sha256, events: parsed.events.count, decisions: parsed.decisions.count,
                                  unreadable: parsed.unreadable.count, at: at)
        appended = fresh + parsed.unreadable + [.jsonImported(marker)]
        folded = EventsDecisionSnapshot(events: existingEvents + newEvents, decisions: existingDecisions + appended)
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
    case alreadyImported(changedSince: Bool)
    case notJSON
    case refused(String)
    /// Written and read back. `verified` false = a count did not match.
    case imported(events: Int, newEvents: Int, decisions: Int, unreadable: Int, members: Int, verified: Bool)
}

extension EventsCatalogBacking {

    /// Import events-decisions.json once (see the header); every outcome is
    /// said through `note`.
    @discardableResult
    func importJSONOnce(from url: URL, note: (String) -> Void) async -> EventsJSONImportOutcome {
        let outcome = await importJSON(from: url)
        note(EventsJSONImportWords.line(outcome, file: url.lastPathComponent))
        return outcome
    }

    private func importJSON(from url: URL) async -> EventsJSONImportOutcome {
        guard case .success(let before) = await read() else { return .refused("catalog.sqlite's folders could not be read") }
        let file = await Self.fileFacts(url)
        if let marker = before.decisions.lazy.compactMap(Self.marker).last {
            return .alreadyImported(changedSince: file.map { $0.sha256 != marker.sha256 } ?? false)
        }
        guard let file else { return .noFile }
        if let why = writeRefusal() { return .refused(why) }
        guard let parsed = EventsJSONImportPlan.parse(file.data) else { return .notJSON }
        let plan = EventsJSONImportPlan(parsed: parsed, existingEvents: before.events, existingDecisions: before.decisions,
                                        file: url.lastPathComponent, sha256: file.sha256, at: Date())
        if let why = write(plan) { return .refused(why) }
        guard case .success(let after) = await read() else { return .refused("written, but the folders could not be read back") }
        let verified = Self.verify(plan, before: before, after: after)
        return .imported(events: parsed.events.count, newEvents: plan.newEvents.count, decisions: plan.appended.count,
                         unreadable: parsed.unreadable.count, members: after.counts.members, verified: verified)
    }

    private func write(_ plan: EventsJSONImportPlan) -> String? {
        let rows = plan.newEvents.map(EventsCatalogRows.folder)
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
    /// the stream grew by exactly what was appended, and the members the
    /// catalog holds are no more than the fold names (a "pair:" key stays
    /// in the stream only).
    static func verify(_ plan: EventsJSONImportPlan, before: Read, after: Read) -> Bool {
        let ids = Set(after.events.map(\.id))
        let everyFolder = plan.parsed.events.allSatisfy { ids.contains($0.id) }
        let streamGrew = after.counts.decisions == before.counts.decisions + plan.appended.count
        let folders = after.counts.events == before.counts.events + plan.newEvents.count
        let members = after.counts.members <= plan.foldedMemberKeys
        return everyFolder && streamGrew && folders && members
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
                ? "Folders: \(file) CHANGED after it was imported into catalog.sqlite — it is not imported again; catalog.sqlite holds the folders (the file is kept as it is)"
                : "Folders: catalog.sqlite holds the folders (\(file) was imported earlier and is kept as frozen history)"
        case .notJSON:
            return "Folders: \(file) is not readable JSON — NOT imported; the file is left as it is"
        case .refused(let why):
            return "Folders: \(file) NOT imported into catalog.sqlite — \(why). The file is left as it is; the next launch tries again"
        case .imported(let events, let new, let decisions, let unreadable, let members, let verified):
            let counts = "\(events) folder\(events == 1 ? "" : "s") (\(new) new), \(decisions) decision\(decisions == 1 ? "" : "s") appended "
                + "(\(unreadable) unreadable kept verbatim), \(members) member\(members == 1 ? "" : "s") in the catalog"
            return verified
                ? "Folders: OUTCOME imported \(file) into catalog.sqlite — \(counts); verified (counts in = counts out). The file is frozen history from now on"
                : "Folders: 🔴 imported \(file) into catalog.sqlite but the read-back did NOT match — \(counts). Nothing was deleted; check Catalog Status"
        }
    }
}
