// GRDBCatalogRepository+HeldBack.swift (VideoScanCore/Store)
// `quarantine` for GH #339 (CatalogHeldBackRows.swift) on the GRDB handles.
// Raw SQL only (CatalogStoreSensorTests). Two reads and one UPDATE of the
// resolution columns — nothing here touches the row's evidence (the
// `quarantine_resolve_once` trigger refuses that anyway) and nothing
// DELETEs (`quarantine_never_deleted`).
//
// Memory: the row visit is a cursor (one row at a time, ≈ 1–4 KB with its
// raw JSON text); the count is one integer.
//
// (For Rick: two prepared SELECTs and one bound UPDATE, `?` placeholders.)

import Foundation
import GRDB

extension GRDBRecordHandle {

    func heldBackRows(_ visit: (CatalogRow.HeldBackRow) throws -> Void) throws {
        let cursor = try Row.fetchCursor(db, sql: """
            SELECT qid, reason_code, words, full_path, size_bytes, digest, sampled_hash,
                   json_array_length(findings), raw_row, quarantined_at,
                   resolved_file_id, resolved_at, resolution, resolution_note
              FROM quarantine ORDER BY qid
            """)
        while let row = try cursor.next() {
            try visit(CatalogRow.HeldBackRow(
                qid: row[0], reasonCode: row[1], words: row[2], fullPath: row[3], sizeBytes: row[4], digest: row[5],
                sampledHash: row[6], findingsCount: row[7], rawRowText: row[8], quarantinedAt: row[9],
                resolvedFileID: row[10], resolvedAt: row[11], resolution: row[12], resolutionNote: row[13]))
        }
    }

    func heldBackOpenCount() throws -> Int {
        try Int.fetchOne(db, sql: "SELECT count(*) FROM quarantine WHERE resolved_at IS NULL") ?? 0
    }
}

extension GRDBReader: CatalogHeldBackReading {}

extension GRDBTransaction: CatalogHeldBackWriting {

    func resolveHeldBack(_ r: CatalogRow.HeldBackResolution) throws -> CatalogRow.HeldBackLanding {
        guard let open = try Row.fetchOne(db, sql: "SELECT resolved_at IS NULL FROM quarantine WHERE qid = ?", arguments: [r.qid])
        else { return .missing }
        guard (open[0] as Bool) else { return .alreadyResolved }
        let file = try Int.fetchOne(db, sql: "SELECT count(*) FROM files WHERE id = ?", arguments: [r.fileID]) ?? 0
        guard file == 1 else { return .fileMissing }
        try db.execute(sql: """
            UPDATE quarantine
               SET resolved_file_id = ?, resolved_at = ?, resolution = 'personDecided', resolution_note = ?
             WHERE qid = ? AND resolved_at IS NULL
            """, arguments: [r.fileID, r.resolvedAt, r.note, r.qid])
        return db.changesCount == 1 ? .resolved : .alreadyResolved
    }
}
