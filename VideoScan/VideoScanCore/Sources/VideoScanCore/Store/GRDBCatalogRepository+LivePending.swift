// GRDBCatalogRepository+LivePending.swift (VideoScanCore/Store)
// The cutover B2.1 doors (schema v1.8): the `pending_rows` holding place,
// the purge marker, and people written as a DELTA. Raw SQL only
// (CatalogStoreSensorTests). Every refusal is still the DDL's: a pending row
// whose id is a `files` row, a tombstone that is not the next revision, a
// marker change without its tombstone.
//
//   putPendingRow / removePendingRow — a new record with no whole-file digest
//     is held (its payload verbatim) and dropped when it becomes a row;
//   purgeFile — a record that left the app's catalog array: its row gets
//     the purge marker (state removedFromCatalog, reason `purged`), the
//     tombstone FIRST; never a DELETE (files_no_delete forbids it);
//   writePeopleDelta — only the names a person changed (codex B2 P1-6): an
//     unrelated name's unresolved conflict is never rewritten as resolved.
//
// (For Rick: three small DAO methods; `ON CONFLICT … DO UPDATE` is SQLite's
// upsert, which never deletes the row in the way.)

import Foundation
import GRDB

// MARK: - Readings (both handles)

extension GRDBRecordHandle {

    func pendingRows(_ visit: (CatalogRow.PendingRow) throws -> Void) throws {
        let cursor = try Row.fetchCursor(db, sql: "SELECT id, json, queued_at FROM pending_rows ORDER BY id")
        while let row = try cursor.next() {
            try visit(CatalogRow.PendingRow(id: row[0], json: row[1], queuedAt: row[2]))
        }
    }

    func tombstoneRevisions(fileID: String) throws -> [Int] {
        try Int.fetchAll(db, sql: "SELECT revision FROM tombstones WHERE file_id = ? ORDER BY revision", arguments: [fileID])
    }
}

// MARK: - Doors (the transaction)

extension GRDBTransaction {

    func putPendingRow(_ row: CatalogRow.PendingRow) throws -> Bool {
        let held = try String.fetchOne(db, sql: "SELECT json FROM pending_rows WHERE id = ?", arguments: [row.id])
        guard held != row.json else { return false }
        try db.execute(sql: """
            INSERT INTO pending_rows (id, json, queued_at) VALUES (?, ?, ?)
            ON CONFLICT (id) DO UPDATE SET json = excluded.json, queued_at = excluded.queued_at
            """, arguments: [row.id, row.json, row.queuedAt])
        return true
    }

    func removePendingRow(id: String) throws -> Bool {
        try db.execute(sql: "DELETE FROM pending_rows WHERE id = ?", arguments: [id])
        return db.changesCount > 0
    }

    func purgeFile(id: String, since: Int64, writtenAt: Int64, door: String) throws -> CatalogRow.PurgeLanding {
        guard let row = try Row.fetchOne(db, sql: "SELECT removal_state, removal_reason, removal_revision FROM files WHERE id = ?",
                                         arguments: [id]) else {
            return try removePendingRow(id: id) ? .pendingDropped : .absent
        }
        let state: String? = row[0]
        let reason: String? = row[1]
        let revision: Int = row[2]
        if state == CatalogDDL.RemovalState.removedFromCatalog.rawValue, reason == CatalogRow.purgeReason {
            return .alreadyPurged
        }
        let next = revision + 1
        try insertTombstone(CatalogRow.Tombstone(fileID: id, revision: next, state: .removedFromCatalog, since: since,
                                                 reason: CatalogRow.purgeReason, trashPath: nil, trashEmptiedAt: nil,
                                                 lastSeen: nil, writtenAt: writtenAt, door: door))
        try db.execute(sql: """
            UPDATE files SET removal_state = ?, removal_since = ?, removal_reason = ?, removal_trash_path = NULL,
                             removal_trash_emptied_at = NULL, removal_last_seen = NULL, removal_revision = ?
             WHERE id = ?
            """, arguments: [CatalogDDL.RemovalState.removedFromCatalog.rawValue, since, CatalogRow.purgeReason, next, id])
        return .purged(revision: next)
    }

    func writePeopleDelta(digest: String, added: [CatalogRecordDTO.PeopleTagRow],
                          removed: [CatalogRecordDTO.PeopleTagRow]) throws {
        let digest = digest.lowercased()
        for person in removed {
            try db.execute(sql: "DELETE FROM people_tags WHERE digest = ? AND name = ? AND kind = ? AND conflict = 0",
                           arguments: [digest, person.name, person.kind.rawValue])
        }
        for person in added {
            // The person's word on this name resolves its conflict: the
            // other side's conflict row goes, this side is written settled.
            try db.execute(sql: """
                DELETE FROM people_tags WHERE digest = ? AND name = ? AND kind IN ('confirmed','rejected') AND kind <> ? AND conflict = 1
                """, arguments: [digest, person.name, person.kind.rawValue])
            try db.execute(sql: """
                INSERT INTO people_tags (digest, name, kind, confirmed_at, conflict) VALUES (?, ?, ?, ?, 0)
                ON CONFLICT (digest, name, kind) DO UPDATE SET confirmed_at = excluded.confirmed_at, conflict = 0
                """, arguments: [digest, person.name, person.kind.rawValue, person.confirmedAt])
        }
    }
}
