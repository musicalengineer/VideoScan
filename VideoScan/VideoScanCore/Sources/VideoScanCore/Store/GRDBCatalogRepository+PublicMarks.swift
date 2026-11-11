// GRDBCatalogRepository+PublicMarks.swift (VideoScanCore/Store)
// `public_marks` (schema v1.15, CatalogPublicMarkRows.swift) on the GRDB
// handles. Raw SQL only (CatalogStoreSensorTests): one plain INSERT per
// decision; nothing here UPDATEs or DELETEs — the triggers would refuse it
// anyway.
//
// "Current" = the row with the highest mark_id for the digest, found
// through `public_marks_by_digest (digest, mark_id)`: one index probe per
// digest (`ORDER BY mark_id DESC LIMIT 1`), and for the whole table a
// GROUP BY the index already orders.
//
// Memory: the readings are cursors (one row at a time); the per-digest
// lookup returns one row per asked digest (the caller bounds k — a
// selection). The whole-table visit holds nothing.
//
// (For Rick: four small DAO reads and one INSERT; `?` placeholders are
// bound parameters, never string-spliced values.)

import Foundation
import GRDB

// MARK: - Readings (both handles)

extension GRDBRecordHandle {

    private static var publicMarkColumns: String { "m.mark_id, m.digest, m.is_public, m.decided_at" }

    private static func publicMarkReading(_ row: Row) -> CatalogRow.PublicMarkReading {
        CatalogRow.PublicMarkReading(markID: row[0], digest: row[1], storedFlag: row[2], decidedAt: row[3])
    }

    func currentPublicMarks(digests: [String]) throws -> [String: CatalogRow.PublicMarkReading] {
        var out: [String: CatalogRow.PublicMarkReading] = [:]
        let statement = try db.cachedStatement(sql: """
            SELECT \(Self.publicMarkColumns) FROM public_marks m
             WHERE m.digest = ? ORDER BY m.mark_id DESC LIMIT 1
            """)
        for digest in Set(digests.map { $0.lowercased() }) {
            if let row = try Row.fetchOne(statement, arguments: [digest]) {
                out[digest] = Self.publicMarkReading(row)
            }
        }
        return out
    }

    func currentPublicMarks(_ visit: (CatalogRow.PublicMarkReading) throws -> Void) throws {
        let cursor = try Row.fetchCursor(db, sql: """
            SELECT \(Self.publicMarkColumns) FROM public_marks m
              JOIN (SELECT digest, max(mark_id) AS newest FROM public_marks GROUP BY digest) n
                ON m.mark_id = n.newest
             ORDER BY m.digest
            """)
        while let row = try cursor.next() { try visit(Self.publicMarkReading(row)) }
    }

    func publicMarkHistory(digest: String) throws -> [CatalogRow.PublicMarkReading] {
        try Row.fetchAll(db, sql: """
            SELECT \(Self.publicMarkColumns) FROM public_marks m WHERE m.digest = ? ORDER BY m.mark_id
            """, arguments: [digest.lowercased()]).map(Self.publicMarkReading)
    }
}

extension GRDBRecordHandle {

    func publicMarkContentHeld(digests: [String]) throws -> Set<String> {
        var held: Set<String> = []
        let statement = try db.cachedStatement(sql: "SELECT 1 FROM content WHERE digest = ?")
        for digest in Set(digests.map { $0.lowercased() }) where try Row.fetchOne(statement, arguments: [digest]) != nil {
            held.insert(digest)
        }
        return held
    }
}

extension GRDBReader: CatalogPublicMarkReading {}

// MARK: - The door (the transaction)

extension GRDBTransaction: CatalogPublicMarkWriting {

    func appendPublicMark(_ decision: CatalogRow.PublicMarkDecision) throws -> CatalogRow.PublicMarkLanding {
        let present = try Int.fetchOne(db, sql: "SELECT count(*) FROM content WHERE digest = ?", arguments: [decision.digest]) ?? 0
        guard present == 1 else { return .contentMissing }
        try db.execute(sql: """
            INSERT INTO public_marks (digest, is_public, decided_at)
            VALUES (?, ?, ?)
            """, arguments: [decision.digest, decision.isPublic ? 1 : 0, decision.decidedAt])
        return .recorded
    }
}
