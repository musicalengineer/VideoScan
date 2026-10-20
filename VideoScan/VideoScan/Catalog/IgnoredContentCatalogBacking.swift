// IgnoredContentCatalogBacking.swift
// The ignore list lives in catalog.sqlite (2026-10-19: "every decision Rick
// makes lives in catalog.sqlite"). IgnoredContentStore's backing once the
// catalog is SQLite — the same shape as Catalog folders'
// (EventsCatalogBacking.swift): it reads `ignored_content` through the
// repository and writes every change through the ONE writer — the session's
// CatalogCommitter — in one synchronous transaction
// (`commitSideTables(via: .ignoredContent)`):
//   an entry Rick ignores   → a NEW `ignored_content` row (import_run NULL);
//   an entry put back       → a row in `ignored_content_put_back` naming it
//                             (an ignored row is never deleted or rewritten).
// A read-only or viewer session, a held, blocked or reopening catalog
// refuses with the committer's words and nothing changes. The one-time
// import of ignored-content.json is IgnoredContentJSONImport.swift.
//
// Memory: a read holds every row (a few hundred today; ~250 B each); a write
// holds one batch.
//
// (For Rick: the store's DAO adapter — the store speaks
// IgnoredContentEntry, the catalog speaks rows; this file is the
// translation and the two calls.)

import Foundation
import VideoScanCore

@MainActor
final class IgnoredContentCatalogBacking {

    enum ReadOutcome: Sendable {
        case success([CatalogRow.IgnoredReading])
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
            guard let committer else { return "the catalog is closed" }
            return committer.sideTableWriteRefusal
        }, commit: { [weak committer] what, body in
            guard let committer else { return "the catalog is closed" }
            return committer.commitSideTables(what, via: .ignoredContent, body)
        })
    }

    // MARK: Write

    /// New entries and put-backs → one transaction. nil = written.
    func write(adding added: [IgnoredContentEntry], puttingBack putBack: [UUID], at now: Date = Date()) -> String? {
        guard !added.isEmpty || !putBack.isEmpty else { return nil }
        let rows = added.map(IgnoredContentCatalogRows.row)
        let at = IgnoredContentCatalogRows.seconds(now)
        let what = "\(added.count) ignored, \(putBack.count) put back"
        return commit(what) { tx in
            for row in rows { try tx.appendIgnoredEntry(row) }
            for id in putBack { try tx.putBackIgnored(entryID: id.uuidString, at: at) }
        }
    }

    /// The commit door, for the import (IgnoredContentJSONImport.swift).
    func commitRaw(_ what: String, _ body: (any CatalogTransaction) throws -> Void) -> String? {
        commit(what, body)
    }

    // MARK: Read

    /// Every row (live and put back), off the main actor.
    func read() async -> ReadOutcome {
        do {
            return .success(try await repository.read { reader -> [CatalogRow.IgnoredReading] in
                var rows: [CatalogRow.IgnoredReading] = []
                try reader.ignoredRows { rows.append($0) }
                return rows
            })
        } catch {
            return .failure(String(describing: error))
        }
    }

    func counts() async -> CatalogRow.IgnoredCounts? {
        try? await repository.read { try $0.ignoredCounts() }
    }
}

// MARK: - Rows ⇄ values (pure)

enum IgnoredContentCatalogRows {

    static func seconds(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970.rounded(.down)) }

    static func row(_ e: IgnoredContentEntry) -> CatalogRow.IgnoredEntry {
        CatalogRow.IgnoredEntry(entryID: e.id.uuidString, partialMD5: e.partialMD5, sizeBytes: e.sizeBytes, filename: e.filename,
                                reason: e.reason, addedAt: seconds(e.addedAt), samplePath: e.samplePath)
    }

    /// nil when the row's entry_id is not a UUID (left as it is, counted).
    static func entry(_ row: CatalogRow.IgnoredEntry) -> IgnoredContentEntry? {
        guard let id = UUID(uuidString: row.entryID) else { return nil }
        return IgnoredContentEntry(id: id, partialMD5: row.partialMD5, sizeBytes: row.sizeBytes, filename: row.filename,
                                   reason: row.reason, addedAt: Date(timeIntervalSince1970: TimeInterval(row.addedAt)),
                                   samplePath: row.samplePath)
    }

    /// The live list: rows not put back, by entry id (F4: an entry_id may
    /// repeat — the first row is the entry; the others are counted).
    static func live(_ rows: [CatalogRow.IgnoredReading]) -> (entries: [IgnoredContentEntry], unreadable: Int, repeated: Int) {
        var seen = Set<UUID>()
        var entries: [IgnoredContentEntry] = []
        var unreadable = 0, repeated = 0
        for r in rows where !r.putBack {
            guard let e = entry(r.entry) else { unreadable += 1; continue }
            guard seen.insert(e.id).inserted else { repeated += 1; continue }
            entries.append(e)
        }
        return (entries, unreadable, repeated)
    }
}
