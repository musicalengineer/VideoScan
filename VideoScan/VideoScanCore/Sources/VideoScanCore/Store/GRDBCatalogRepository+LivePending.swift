// GRDBCatalogRepository+LivePending.swift (VideoScanCore/Store)
// The cutover B2.1 doors (schema v1.8): the `pending_rows` holding place,
// the purge marker, and people written as a DELTA. Raw SQL only
// (CatalogStoreSensorTests). Every refusal is still the DDL's: a pending row
// whose id is a `files` row, a tombstone that is not the next revision, a
// marker change without its tombstone.
//
//   putPendingRow / removePendingRow — a new record with no whole-file digest
//     is held (its payload verbatim; putting it again clears a purge
//     tombstone — it came back) and removed only when it becomes a row;
//   purgeFile — a record that left the app's catalog array: its row gets
//     the purge marker (state removedFromCatalog, reason `purged`), the
//     tombstone FIRST; never a DELETE (files_no_delete forbids it). A held
//     record's payload is KEPT and tombstoned in `pending_purges` (B2.2,
//     schema v1.9); the load skips it. Nothing is deleted;
//   writePeopleDelta — only the names a person changed (codex B2 P1-6): an
//     unrelated name's unresolved conflict is never rewritten as resolved;
//   writeTagsDelta / writeAttestationsDelta — the same for the other two
//     shared sets (B2.4, codex B2.3 F2): two copies edited differently in
//     one commit both land, in either order.
//     An attestation is a FULL row (key + label): a removal deletes only
//     the exact row the copy saw; a relabel is remove-old-row + add-new-row
//     (B2.5, codex B2.4 F2) — so a removal never takes another copy's
//     relabel of the same key. A person row is FULL the same way (name +
//     kind + confirmed_at, B2.6): a re-dated confirmation is remove-old-row
//     + add-new-row, so an un-confirm never takes another copy's re-date.
//
// (For Rick: three small DAO methods; `ON CONFLICT … DO UPDATE` is SQLite's
// upsert, which never deletes the row in the way.)

import Foundation
import GRDB

// MARK: - Readings (both handles)

extension GRDBRecordHandle {

    func pendingRows(_ visit: (CatalogRow.PendingRow) throws -> Void) throws {
        // A tombstoned payload (B2.2) is kept as evidence, never loaded.
        let cursor = try Row.fetchCursor(db, sql: """
            SELECT id, json, queued_at FROM pending_rows p
             WHERE NOT EXISTS (SELECT 1 FROM pending_purges q WHERE q.id = p.id) ORDER BY id
            """)
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
        // The record is in the app's array again: its purge tombstone goes.
        try db.execute(sql: "DELETE FROM pending_purges WHERE id = ?", arguments: [row.id])
        let cameBack = db.changesCount > 0
        guard held != row.json else { return cameBack }
        try db.execute(sql: """
            INSERT INTO pending_rows (id, json, queued_at) VALUES (?, ?, ?)
            ON CONFLICT (id) DO UPDATE SET json = excluded.json, queued_at = excluded.queued_at
            """, arguments: [row.id, row.json, row.queuedAt])
        return true
    }

    /// The record became a `files` row: its pending row (and any purge
    /// tombstone of it) goes — the payload now lives on as the row itself.
    func removePendingRow(id: String) throws -> Bool {
        try db.execute(sql: "DELETE FROM pending_purges WHERE id = ?", arguments: [id])
        try db.execute(sql: "DELETE FROM pending_rows WHERE id = ?", arguments: [id])
        return db.changesCount > 0
    }

    /// A held record left the app's array: its payload is tombstoned, KEPT.
    private func purgePending(id: String, since: Int64, door: String) throws -> CatalogRow.PurgeLanding {
        let held = try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM pending_rows WHERE id = ?)", arguments: [id]) ?? false
        guard held else { return .absent }
        let tombstoned = try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM pending_purges WHERE id = ?)", arguments: [id]) ?? false
        guard !tombstoned else { return .alreadyPurged }
        try db.execute(sql: "INSERT INTO pending_purges (id, purged_at, door) VALUES (?, ?, ?)", arguments: [id, since, door])
        return .pendingPurged
    }

    func storedLivePath(id: String) throws -> String? {
        try String.fetchOne(db, sql: "SELECT full_path FROM files WHERE id = ? AND removal_state IS NULL", arguments: [id])
    }

    func purgeFile(id: String, since: Int64, writtenAt: Int64, door: String) throws -> CatalogRow.PurgeLanding {
        guard let row = try Row.fetchOne(db, sql: "SELECT removal_state, removal_reason, removal_revision FROM files WHERE id = ?",
                                         arguments: [id]) else {
            return try purgePending(id: id, since: since, door: door)
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
            // The EXACT row this copy's baseline held — name, kind AND date
            // (B2.6, the class of codex B2.4 F2). Matching (name, kind) alone
            // let an un-confirm take another copy's re-dated confirmation, so
            // the result depended on commit order. `confirmed_at IS ?`:
            // NULL-safe equality (a rejection has no date).
            try db.execute(sql: """
                DELETE FROM people_tags
                 WHERE digest = ? AND name = ? AND kind = ? AND confirmed_at IS ? AND conflict = 0
                """, arguments: [digest, person.name, person.kind.rawValue, person.confirmedAt])
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

    func writeTagsDelta(digest: String, added: [String], removed: [String]) throws {
        let digest = digest.lowercased()
        for tag in removed {
            try db.execute(sql: "DELETE FROM workflow_tags WHERE digest = ? AND tag = ?", arguments: [digest, tag])
        }
        for tag in added {
            try db.execute(sql: "INSERT INTO workflow_tags (digest, tag) VALUES (?, ?) ON CONFLICT DO NOTHING",
                           arguments: [digest, tag])
        }
    }

    func writeAttestationsDelta(digest: String, added: [CatalogRecordDTO.BackupAttestationRow],
                                removed: [CatalogRecordDTO.BackupAttestationRow]) throws {
        let digest = digest.lowercased()
        for a in removed {
            // The EXACT row this copy's baseline held — key AND label (B2.5,
            // codex B2.4 F2). Matching the key alone let a removal take
            // another copy's relabel of the same key, so A-removes vs
            // B-relabels ended differently by commit order. `label IS ?`:
            // NULL-safe equality (a label may be absent).
            try db.execute(sql: """
                DELETE FROM backup_attestations
                 WHERE digest = ? AND kind = ? AND attested_at = ? AND answer = ? AND by_whom = ? AND label IS ?
                """, arguments: [digest, a.kind, a.attestedAt, a.answer, a.byWhom, a.label])
        }
        for a in added {
            // The person's word on this attestation settles it (conflict = 0).
            try db.execute(sql: """
                INSERT INTO backup_attestations (digest, kind, answer, label, attested_at, by_whom, conflict)
                VALUES (?, ?, ?, ?, ?, ?, 0)
                ON CONFLICT (digest, kind, attested_at, answer, by_whom) DO UPDATE SET label = excluded.label, conflict = 0
                """, arguments: [digest, a.kind, a.answer, a.label, a.attestedAt, a.byWhom])
        }
    }
}
