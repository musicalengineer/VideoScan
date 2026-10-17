// GRDBCatalogRepository+Reads.swift (VideoScanCore/Store)
// The readings of `CatalogRecordReading` on the GRDB handle (step C′ part
// 2b): what the import comparator asks the store, streamed row by row
// through a visitor closure from a cursor, so nothing here holds an
// O(records) array. Raw SQL throughout (CatalogStoreSensorTests). Shared by
// the reader handle and the transaction handle through `GRDBRecordHandle`,
// so the comparator can read inside the import's own transaction.
//
// (For Rick: each function is one prepared SELECT stepped to the end with a
// callback per row — `sqlite3_step` in a loop, no result vector.)

import Foundation
import GRDB

extension GRDBRecordHandle {

    func recordCounts() throws -> CatalogRow.TableCounts {
        func count(_ table: String) throws -> Int {
            try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)") ?? 0
        }
        return CatalogRow.TableCounts(files: try count("files"), quarantine: try count("quarantine"),
                                      content: try count("content"), importRuns: try count("import_runs"))
    }

    func rowLandings(run: String, _ visit: (CatalogRow.RowLanding) throws -> Void) throws {
        let cursor = try Row.fetchCursor(db, sql: """
            SELECT source_ordinal, landed_table, landed_ref FROM import_items
             WHERE import_run = ? AND item_kind = 'row' ORDER BY source_ordinal
            """, arguments: [run])
        while let row = try cursor.next() {
            guard let table = CatalogDDL.LandedTable.init(rawValue: row[1] as String) else { continue }
            try visit(CatalogRow.RowLanding(ordinal: row[0], landedTable: table, landedRef: row[2]))
        }
    }

    func quarantineRawRows(run: String, _ visit: (Int, [String: CatalogJSONValue]) throws -> Void) throws {
        let cursor = try Row.fetchCursor(db, sql: """
            SELECT source_ordinal, raw_row FROM quarantine WHERE origin = 'import' AND import_run = ? ORDER BY source_ordinal
            """, arguments: [run])
        while let row = try cursor.next() {
            let text: String? = row[1]
            guard let text, let data = text.data(using: .utf8),
                  let value = try? JSONDecoder().decode(CatalogJSONValue.self, from: data),
                  let object = value.objectValue else { continue }
            try visit(row[0], object)
        }
    }

    func quarantineEntries(run: String, _ visit: (CatalogRow.QuarantineReading) throws -> Void) throws {
        let cursor = try Row.fetchCursor(db, sql: """
            SELECT source_ordinal, json_row_id, digest, reason_code, words, json_array_length(findings)
              FROM quarantine WHERE origin = 'import' AND import_run = ? ORDER BY source_ordinal
            """, arguments: [run])
        while let row = try cursor.next() {
            guard let reason = CatalogDDL.ReasonCode.init(rawValue: row[3] as String) else { continue }
            try visit(CatalogRow.QuarantineReading(ordinal: row[0], jsonRowID: row[1], digest: row[2], reasonCode: reason,
                                                   words: row[4], findingsCount: row[5]))
        }
    }

    func contentDigests(_ visit: (String) throws -> Void) throws {
        let cursor = try String.fetchCursor(db, sql: "SELECT digest FROM content")
        while let digest = try cursor.next() { try visit(digest) }
    }

    func knowledgeSources(run: String, _ visit: (CatalogRow.KnowledgeReading) throws -> Void) throws {
        let cursor = try Row.fetchCursor(db, sql: """
            SELECT source_ordinal, json_row_id, field, value_json FROM knowledge_sources WHERE import_run = ? ORDER BY source_ordinal
            """, arguments: [run])
        while let row = try cursor.next() {
            guard let field = CatalogDDL.KnowledgeField.init(rawValue: row[2] as String),
                  let data = (row[3] as String).data(using: .utf8),
                  let value = try? JSONDecoder().decode(CatalogJSONValue.self, from: data) else { continue }
            try visit(CatalogRow.KnowledgeReading(ordinal: row[0], jsonRowID: row[1], field: field, value: value))
        }
    }

    func derivedUnverifiedKeys(run: String, _ visit: (CatalogRow.DerivedKeyReading) throws -> Void) throws {
        let cursor = try Row.fetchCursor(db, sql: """
            SELECT digest, kind, seq, source_json_row_id FROM derived_unverified WHERE import_run = ?
            """, arguments: [run])
        while let row = try cursor.next() {
            guard let kind = CatalogDDL.DerivedKind.init(rawValue: row[1] as String) else { continue }
            try visit(CatalogRow.DerivedKeyReading(digest: row[0], kind: kind, seq: row[2], sourceJSONRowID: row[3]))
        }
    }

    func soundPrintDigests(_ visit: (String) throws -> Void) throws {
        let cursor = try String.fetchCursor(db, sql: "SELECT digest FROM sound_prints")
        while let digest = try cursor.next() { try visit(digest) }
    }

    func eventDecisionOrdinals(run: String, _ visit: (Int) throws -> Void) throws {
        let cursor = try Int.fetchCursor(db, sql: "SELECT source_ordinal FROM event_decisions WHERE import_run = ?",
                                         arguments: [run])
        while let ordinal = try cursor.next() { try visit(ordinal) }
    }

    func eventMembers(_ visit: (CatalogRow.EventMemberReading) throws -> Void) throws {
        let cursor = try Row.fetchCursor(db, sql: "SELECT event_id, imported_key FROM event_members")
        while let row = try cursor.next() {
            try visit(CatalogRow.EventMemberReading(eventID: row[0], importedKey: row[1]))
        }
    }

    /// The stream's keys (every `contentKey` inside a decision payload) and
    /// the keys listed on `legacy_pair_ids`.
    func listedMemberKeys(run: String, _ visit: (String) throws -> Void) throws {
        let keys = try Row.fetchCursor(db, sql: """
            SELECT j.value FROM legacy_pair_ids p, json_each(p.event_member_keys) j WHERE p.import_run = ?
            """, arguments: [run])
        while let row = try keys.next() { try visit(row[0]) }
        let payloads = try String.fetchCursor(db, sql: "SELECT payload FROM event_decisions WHERE import_run = ?",
                                              arguments: [run])
        while let payload = try payloads.next() {
            guard let data = payload.data(using: .utf8),
                  let value = try? JSONDecoder().decode(CatalogJSONValue.self, from: data) else { continue }
            for key in EventsDecisionsJSON.contentKeys(in: value) { try visit(key) }
        }
    }

    func ledgerOrdinals(run: String, _ visit: (Int) throws -> Void) throws {
        let cursor = try Int.fetchCursor(db, sql: "SELECT source_ordinal FROM ledger WHERE import_run = ?", arguments: [run])
        while let ordinal = try cursor.next() { try visit(ordinal) }
    }

    func ignoredOrdinals(run: String, _ visit: (Int) throws -> Void) throws {
        let cursor = try Int.fetchCursor(db, sql: "SELECT source_ordinal FROM ignored_content WHERE import_run = ?",
                                         arguments: [run])
        while let ordinal = try cursor.next() { try visit(ordinal) }
    }

    func jobMarkers(run: String, _ visit: (CatalogRow.MarkerReading) throws -> Void) throws {
        let cursor = try Row.fetchCursor(db, sql: "SELECT source_file, source_ordinal FROM job_markers WHERE import_run = ?",
                                         arguments: [run])
        while let row = try cursor.next() {
            guard let file = CatalogDDL.ImportSourceFile.init(rawValue: row[0] as String) else { continue }
            try visit(CatalogRow.MarkerReading(sourceFile: file, ordinal: row[1]))
        }
    }

    func auditResults(run: String, _ visit: (CatalogRow.AuditResultReading) throws -> Void) throws {
        let cursor = try Row.fetchCursor(db, sql: "SELECT source_ordinal, accepted FROM audit_results WHERE import_run = ?",
                                         arguments: [run])
        while let row = try cursor.next() {
            try visit(CatalogRow.AuditResultReading(ordinal: row[0], accepted: (row[1] as Int) == 1))
        }
    }

    func personSearchOrdinals(run: String, _ visit: (Int) throws -> Void) throws {
        let cursor = try Int.fetchCursor(db, sql: "SELECT source_ordinal FROM person_searches WHERE import_run = ?",
                                         arguments: [run])
        while let ordinal = try cursor.next() { try visit(ordinal) }
    }

    // MARK: - The reconciliation line's counts (contract §f), from the rows

    func importReconciliation(run: String) throws -> ImportReconciliation {
        var r = ImportReconciliation()
        r.rowsBefore = try one("SELECT count(*) FROM import_items WHERE import_run = ? AND item_kind = 'row'", run)
        r.rowsMain = try one("SELECT count(*) FROM import_items WHERE import_run = ? AND item_kind = 'row' AND landed_table = 'files'", run)
        r.rowsTombstoned = try one("""
            SELECT count(*) FROM import_items i JOIN files f ON f.id = i.landed_ref
             WHERE i.import_run = ? AND i.landed_table = 'files' AND f.removal_state IS NOT NULL
            """, run)
        r.rowsQuarantine = try one("SELECT count(*) FROM quarantine WHERE origin = 'import' AND import_run = ?", run)
        r.quarantineByReason = try counts("SELECT reason_code, count(*) FROM quarantine WHERE origin = 'import' AND import_run = ? GROUP BY reason_code", run)
        r.digests = try one("SELECT count(*) FROM content", nil)
        r.knowledgeRows = try one("SELECT count(*) FROM knowledge_sources WHERE import_run = ?", run)
        r.knowledgeByField = try counts("SELECT field, count(*) FROM knowledge_sources WHERE import_run = ? GROUP BY field", run)
        r.conflictsByField = try counts("""
            SELECT field, count(*) FROM (
              SELECT digest, field FROM knowledge_sources WHERE import_run = ? AND digest IS NOT NULL
               GROUP BY digest, field HAVING count(DISTINCT value_json) > 1) GROUP BY field
            """, run)
        r.unverified = try one("SELECT count(*) FROM derived_unverified WHERE import_run = ?", run)
        r.unverifiedConflicts = try one("SELECT count(*) FROM derived_unverified WHERE import_run = ? AND conflict = 1", run)
        r.pendingLineage = try one("SELECT count(*) FROM lineage_pending WHERE import_run = ?", run)
        r.events = try one("SELECT count(*) FROM events WHERE import_run = ?", run)
        r.eventDecisions = try one("SELECT count(*) FROM event_decisions WHERE import_run = ?", run)
        r.membersResolved = try one("SELECT count(*) FROM event_members", nil)
        r.ignored = try one("SELECT count(*) FROM ignored_content WHERE import_run = ?", run)
        r.ignoredBound = try one("SELECT count(*) FROM ignored_content WHERE import_run = ? AND binding <> 'unbound'", run)
        r.ledgerLines = try one("SELECT count(*) FROM ledger WHERE import_run = ?", run)
        r.searches = try one("SELECT count(*) FROM person_searches WHERE import_run = ?", run)
        r.searchesZeroHit = try one("SELECT count(*) FROM person_searches WHERE import_run = ? AND outcome = 'searched' AND hits = 0", run)
        r.searchesUnreadable = try one("SELECT count(*) FROM person_searches WHERE import_run = ? AND outcome = 'unreadable'", run)
        r.auditResults = try one("SELECT count(*) FROM audit_results WHERE import_run = ?", run)
        r.auditAccepted = try one("SELECT count(*) FROM audit_results WHERE import_run = ? AND accepted = 1", run)
        r.markers = try one("SELECT count(*) FROM job_markers WHERE import_run = ?", run)
        return r
    }

    private func one(_ sql: String, _ run: String?) throws -> Int {
        let arguments: StatementArguments = run.map { [$0] } ?? []
        return try Int.fetchOne(db, sql: sql, arguments: arguments) ?? 0
    }

    private func counts(_ sql: String, _ run: String) throws -> [String: Int] {
        var out: [String: Int] = [:]
        let cursor = try Row.fetchCursor(db, sql: sql, arguments: [run])
        while let row = try cursor.next() { out[row[0] as String] = row[1] }
        return out
    }
}
