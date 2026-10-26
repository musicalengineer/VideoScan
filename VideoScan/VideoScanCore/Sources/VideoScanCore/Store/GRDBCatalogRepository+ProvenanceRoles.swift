// GRDBCatalogRepository+ProvenanceRoles.swift (VideoScanCore/Store)
// `provenance_roles` (schema v1.12, CatalogProvenanceRoleRows.swift) on the
// GRDB handles. Raw SQL only (CatalogStoreSensorTests): one plain INSERT
// per decision; nothing here UPDATEs or DELETEs — the triggers would
// refuse it anyway.
//
// "Current" = the row with the highest role_id for the digest, found
// through `provenance_roles_by_digest (digest, role_id)`: one index probe
// per digest (`ORDER BY role_id DESC LIMIT 1`), and for the whole table a
// GROUP BY the index already orders.
//
// Memory: the readings are cursors (one row at a time); the per-digest
// lookup returns one row per asked digest (the caller bounds k — a
// selection). The whole-table visit holds nothing.
//
// (For Rick: three small DAO reads and one INSERT; `?` placeholders are
// bound parameters, never string-spliced values.)

import Foundation
import GRDB

// MARK: - Readings (both handles)

extension GRDBRecordHandle {

    private static var provenanceColumns: String {
        "r.role_id, r.digest, r.role, r.decided_at, r.source_missing, r.note"
    }

    private static func provenanceReading(_ row: Row) -> CatalogRow.ProvenanceRoleReading {
        let flag: Int64 = row[4]
        return CatalogRow.ProvenanceRoleReading(roleID: row[0], digest: row[1], storedRole: row[2], decidedAt: row[3],
                                                storedSourceMissing: flag != 0, note: row[5])
    }

    func currentProvenanceRoles(digests: [String]) throws -> [String: CatalogRow.ProvenanceRoleReading] {
        var out: [String: CatalogRow.ProvenanceRoleReading] = [:]
        let statement = try db.cachedStatement(sql: """
            SELECT \(Self.provenanceColumns) FROM provenance_roles r
             WHERE r.digest = ? ORDER BY r.role_id DESC LIMIT 1
            """)
        for digest in Set(digests.map { $0.lowercased() }) {
            if let row = try Row.fetchOne(statement, arguments: [digest]) {
                out[digest] = Self.provenanceReading(row)
            }
        }
        return out
    }

    func currentProvenanceRoles(_ visit: (CatalogRow.ProvenanceRoleReading) throws -> Void) throws {
        let cursor = try Row.fetchCursor(db, sql: """
            SELECT \(Self.provenanceColumns) FROM provenance_roles r
              JOIN (SELECT digest, max(role_id) AS newest FROM provenance_roles GROUP BY digest) n
                ON r.role_id = n.newest
             ORDER BY r.digest
            """)
        while let row = try cursor.next() { try visit(Self.provenanceReading(row)) }
    }

    func provenanceRoleHistory(digest: String) throws -> [CatalogRow.ProvenanceRoleReading] {
        try Row.fetchAll(db, sql: """
            SELECT \(Self.provenanceColumns) FROM provenance_roles r WHERE r.digest = ? ORDER BY r.role_id
            """, arguments: [digest.lowercased()]).map(Self.provenanceReading)
    }
}

extension GRDBReader: CatalogProvenanceRoleReading {}

// MARK: - The door (the transaction)

extension GRDBTransaction: CatalogProvenanceRoleWriting {

    func appendProvenanceRole(_ decision: CatalogRow.ProvenanceRoleDecision) throws -> CatalogRow.ProvenanceRoleLanding {
        let present = try Int.fetchOne(db, sql: "SELECT count(*) FROM content WHERE digest = ?", arguments: [decision.digest]) ?? 0
        guard present == 1 else { return .contentMissing }
        try db.execute(sql: """
            INSERT INTO provenance_roles (digest, role, decided_at, source_missing, note)
            VALUES (?, ?, ?, ?, ?)
            """, arguments: [decision.digest, decision.role.rawValue, decision.decidedAt, decision.sourceMissing ? 1 : 0,
                             decision.note])
        return .recorded
    }
}
