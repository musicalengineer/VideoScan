// GRDBCatalogRepository+Folders.swift (VideoScanCore/Store)
// The Catalog folder readings and doors (schema v1.10, CatalogFolderRows
// .swift) on the GRDB handles. Raw SQL only (CatalogStoreSensorTests): an
// upsert by `ON CONFLICT … DO UPDATE` (never REPLACE — it would delete the
// row in the way), a plain INSERT into the append-only stream, and a
// delete-then-insert of ONE folder's fold in `event_members` (a regenerable
// projection of the stream; nothing else references it).
//
// (For Rick: three small DAO methods and three cursors; `?` placeholders
// are bound parameters, never string-spliced values.)

import Foundation
import GRDB

// MARK: - Readings (both handles)

extension GRDBRecordHandle {

    func folderRows(_ visit: (CatalogRow.Folder) throws -> Void) throws {
        let cursor = try Row.fetchCursor(db, sql: """
            SELECT event_id, name, state, kind, categories, note, created_at, updated_at
              FROM events ORDER BY created_at, event_id
            """)
        while let row = try cursor.next() {
            let categoriesText: String = row[4]
            let categories = (try? JSONDecoder().decode([String].self, from: Data(categoriesText.utf8))) ?? []
            try visit(CatalogRow.Folder(eventID: row[0], name: row[1], state: row[2], kind: row[3], categories: categories,
                                        note: row[5], createdAt: row[6], updatedAt: row[7]))
        }
    }

    func folderDecisions(_ visit: (CatalogRow.FolderDecision) throws -> Void) throws {
        let cursor = try Row.fetchCursor(db, sql: "SELECT seq, kind, payload FROM event_decisions ORDER BY seq")
        while let row = try cursor.next() {
            try visit(CatalogRow.FolderDecision(seq: row[0], kind: row[1], payloadJSON: row[2]))
        }
    }

    func folderCounts() throws -> CatalogRow.FolderCounts {
        func count(_ table: String) throws -> Int { try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)") ?? 0 }
        return CatalogRow.FolderCounts(events: try count("events"), decisions: try count("event_decisions"),
                                       members: try count("event_members"))
    }
}

extension GRDBReader: CatalogFolderReading {}

// MARK: - Doors (the transaction)

extension GRDBTransaction: CatalogFolderWriting {

    func upsertFolder(_ folder: CatalogRow.Folder) throws {
        try db.execute(sql: """
            INSERT INTO events (event_id, name, state, kind, categories, note, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (event_id) DO UPDATE
               SET name = excluded.name, state = excluded.state, kind = excluded.kind,
                   categories = excluded.categories, note = excluded.note, updated_at = excluded.updated_at
            """, arguments: [folder.eventID, folder.name, folder.state, folder.kind, GRDBJSONText.strings(folder.categories),
                             folder.note, folder.createdAt, folder.updatedAt])
    }

    func appendFolderDecision(kind: String, payloadJSON: String) throws {
        try db.execute(sql: "INSERT INTO event_decisions (kind, payload) VALUES (?, ?)", arguments: [kind, payloadJSON])
    }

    @discardableResult
    func replaceFolderMembers(eventID: String, _ members: [CatalogRow.FolderMember]) throws -> Int {
        try db.execute(sql: "DELETE FROM event_members WHERE event_id = ?", arguments: [eventID])
        var landed = 0
        var seen = Set<CatalogRow.FolderMember>()
        for member in members {
            let digest = member.key.lowercased()
            let row = CatalogRow.FolderMember(key: digest, rangeStart: member.rangeStart, rangeEnd: member.rangeEnd)
            guard seen.insert(row).inserted else { continue }
            // Only a stored whole-file digest (the FK); anything else stays in the stream.
            try db.execute(sql: """
                INSERT INTO event_members (event_id, digest, range_start_s, range_end_s, imported_key)
                SELECT ?, digest, ?, ?, ? FROM content WHERE digest = ?
                """, arguments: [eventID, member.rangeStart, member.rangeEnd, member.key, digest])
            landed += db.changesCount
        }
        return landed
    }
}
