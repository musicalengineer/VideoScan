// EventsCatalogBacking.swift
// Catalog folders live in catalog.sqlite (Rick 2026-10-19: protect the
// folders he is making now). EventsDecisionStore's backing once the catalog
// is SQLite: it reads the folder tables through the repository and writes
// every change through the ONE writer — the session's CatalogCommitter —
// in one synchronous transaction (`commitFolders`): the folder rows the
// change touched (`events`, upserted), the decisions it appends
// (`event_decisions`, append-only), and the membership fold of every folder
// it touched (`event_members`, by digest). A read-only or viewer session,
// a held, blocked or reopening catalog refuses with the committer's words
// and nothing changes.
//
// The values cross the seam as CatalogRow.Folder / FolderDecision /
// FolderMember (VideoScanCore) — mapped here by `EventsCatalogRows`, pure.
// The one-time import of events-decisions.json is EventsJSONImport.swift.
//
// Memory: a read holds every folder row and the whole stream (a few
// thousand small values at most); a write holds one change.
//
// (For Rick: the store's DAO adapter — the store speaks EventRecord /
// EventDecision, the catalog speaks rows; this file is the translation and
// the two calls.)

import Foundation
import VideoScanCore

@MainActor
final class EventsCatalogBacking {

    /// What a read of the folder tables gives back.
    struct Read: Sendable {
        var events: [EventRecord] = []
        var decisions: [EventDecision] = []
        /// `events` rows this build could not read (a bad id) — left as they are.
        var unreadableRows = 0
        var counts = CatalogRow.FolderCounts(events: 0, decisions: 0, members: 0)
    }

    enum ReadOutcome: Sendable {
        case success(Read)
        case failure(String)
    }

    /// One synchronous write of `body` under a few words; nil = committed.
    typealias Commit = (_ what: String, _ body: (any CatalogTransaction) throws -> Void) -> String?

    private let repository: any CatalogRepository
    private let commit: Commit
    /// Why a write cannot be taken right now (nil = it can).
    let writeRefusal: () -> String?

    init(repository: any CatalogRepository, writeRefusal: @escaping () -> String?, commit: @escaping Commit) {
        self.repository = repository
        self.writeRefusal = writeRefusal
        self.commit = commit
    }

    /// The session's committer: its repository, its refusal, its door.
    convenience init(committer: CatalogCommitter) {
        self.init(repository: committer.repository, writeRefusal: { [weak committer] in
            // Not `committer?.folderWriteRefusal ?? …`: a writable committer's nil would read as "closed".
            guard let committer else { return "the catalog is closed" }
            return committer.folderWriteRefusal
        }, commit: { [weak committer] what, body in
            guard let committer else { return "the catalog is closed" }
            return committer.commitFolders(what, body)
        })
    }

    // MARK: - Write one change

    /// The change and the fold after it → one transaction. nil = written.
    func write(_ change: EventsDecisionChange, folded next: EventsDecisionSnapshot) -> String? {
        let rows = change.events.map(EventsCatalogRows.folder)
        let decisions: [(kind: String, json: String)]
        do { decisions = try change.decisions.map { ($0.kind, try EventsCatalogRows.json($0)) } } catch {
            return "a decision could not be encoded: \(error.localizedDescription)"
        }
        let folds = EventsCatalogRows.folds(of: change.touched, in: next)
        return commit(change.what) { tx in
            try Self.apply(tx, rows: rows, decisions: decisions, folds: folds)
        }
    }

    /// Rows, then the stream, then the folds (a member's folder row first —
    /// the foreign key).
    nonisolated static func apply(_ tx: any CatalogTransaction, rows: [CatalogRow.Folder],
                                  decisions: [(kind: String, json: String)],
                                  folds: [(eventID: String, members: [CatalogRow.FolderMember])]) throws {
        for row in rows { try tx.upsertFolder(row) }
        for d in decisions { try tx.appendFolderDecision(kind: d.kind, payloadJSON: d.json) }
        for fold in folds { try tx.replaceFolderMembers(eventID: fold.eventID, fold.members) }
    }

    /// The commit door, for the import (EventsJSONImport.swift).
    func commitRaw(_ what: String, _ body: (any CatalogTransaction) throws -> Void) -> String? {
        commit(what, body)
    }

    // MARK: - Read

    /// Every folder and the whole stream, off the main actor.
    func read() async -> ReadOutcome {
        do {
            let raw = try await repository.read { reader -> ([CatalogRow.Folder], [CatalogRow.FolderDecision], CatalogRow.FolderCounts) in
                var rows: [CatalogRow.Folder] = []
                var decisions: [CatalogRow.FolderDecision] = []
                try reader.folderRows { rows.append($0) }
                try reader.folderDecisions { decisions.append($0) }
                return (rows, decisions, try reader.folderCounts())
            }
            var read = Read(counts: raw.2)
            for row in raw.0 {
                if let e = EventsCatalogRows.record(row) { read.events.append(e) } else { read.unreadableRows += 1 }
            }
            read.decisions = raw.1.map(EventsCatalogRows.decision)
            return .success(read)
        } catch {
            return .failure(String(describing: error))
        }
    }
}

// MARK: - Rows ⇄ values (pure)

enum EventsCatalogRows {

    static func seconds(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970.rounded(.down)) }

    static func folder(_ e: EventRecord) -> CatalogRow.Folder {
        CatalogRow.Folder(eventID: e.id.uuidString, name: e.name, state: e.state.rawValue, kind: e.kind.rawValue,
                          categories: e.categories, note: e.note, createdAt: seconds(e.createdAt), updatedAt: seconds(e.updatedAt))
    }

    /// nil when the row's id is not a UUID (left as it is, counted).
    static func record(_ row: CatalogRow.Folder) -> EventRecord? {
        guard let id = UUID(uuidString: row.eventID) else { return nil }
        return EventRecord(id: id, name: row.name, categories: row.categories,
                           state: EventRecord.State(rawValue: row.state) ?? .dismissed,
                           createdAt: Date(timeIntervalSince1970: TimeInterval(row.createdAt)),
                           updatedAt: Date(timeIntervalSince1970: TimeInterval(row.updatedAt)),
                           note: row.note, kind: FolderKind(word: row.kind))
    }

    static func json(_ d: EventDecision) throws -> String {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        return String(decoding: try enc.encode(d), as: UTF8.self)
    }

    /// A payload this build cannot read at all is kept as `.unknown` with
    /// its text (the stream is never rewritten, so nothing is lost).
    static func decision(_ row: CatalogRow.FolderDecision) -> EventDecision {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let d = try? dec.decode(EventDecision.self, from: Data(row.payloadJSON.utf8)) { return d }
        return .unknown(kind: row.kind, payload: ["raw": .string(row.payloadJSON)])
    }

    /// Each touched folder's fold after the change — empty for a folder
    /// merged away (its members live under the survivor); every key, the
    /// store keeps only stored digests.
    static func folds(of touched: Set<UUID>, in next: EventsDecisionSnapshot) -> [(eventID: String, members: [CatalogRow.FolderMember])] {
        touched.filter { next.events[$0] != nil }
            .sorted { $0.uuidString < $1.uuidString }
            .map { id in
                let members = next.effectiveEvent(id) == id ? next.members(of: id) : []
                return (id.uuidString, members.sorted { $0.contentKey < $1.contentKey }
                    .map { CatalogRow.FolderMember(key: $0.contentKey, rangeStart: $0.start, rangeEnd: $0.end) })
            }
    }
}
