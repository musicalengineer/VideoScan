// GRDBCatalogRepository+Reads.swift (VideoScanCore/Store)
// The readings of `CatalogRecordReading` on the GRDB handle (step C′ part
// 2b): what the import comparator asks the store, streamed row by row
// through a visitor closure from a cursor, so nothing here holds an
// O(records) array. Raw SQL throughout (CatalogStoreSensorTests). Shared by
// the reader handle and the transaction handle through `GRDBRecordHandle`,
// so the comparator can read inside the import's own transaction.
//
// fix 2026-10-17 (codex D′ #1, #3): the readings carry IDENTITY, not just
// presence — a landing is JOINED to the row it names (its id and digest), a
// knowledge row carries the digest it hangs on, an event member its digest
// and range — and the sidecar tables are read back WHOLE so the comparator
// compares payloads, not ordinals.
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

    /// Each landing JOINED to the row it names (codex D′ #1): a files landing
    /// to `files` by id, a quarantine landing to the `quarantine` row of the
    /// same (run, ordinal) AND qid. Both nil when the row is not there.
    func rowLandings(run: String, _ visit: (CatalogRow.RowLanding) throws -> Void) throws {
        let cursor = try Row.fetchCursor(db, sql: """
            SELECT i.source_ordinal, i.landed_table, i.landed_ref, f.id, f.content_digest, q.json_row_id, q.digest
              FROM import_items i
              LEFT JOIN files f ON i.landed_table = 'files' AND f.id = i.landed_ref
              LEFT JOIN quarantine q ON i.landed_table = 'quarantine' AND q.origin = 'import'
                   AND q.import_run = i.import_run AND q.source_ordinal = i.source_ordinal
                   AND q.qid = CAST(i.landed_ref AS INTEGER)
             WHERE i.import_run = ? AND i.item_kind = 'row' ORDER BY i.source_ordinal
            """, arguments: [run])
        while let row = try cursor.next() {
            guard let table = CatalogDDL.LandedTable.init(rawValue: row[1] as String) else { continue }
            let fileID: String? = row[3]
            let quarantineRowID: String? = row[5]
            let fileDigest: String? = row[4]
            let quarantineDigest: String? = row[6]
            try visit(CatalogRow.RowLanding(ordinal: row[0], landedTable: table, landedRef: row[2],
                                            rowID: fileID ?? quarantineRowID, digest: fileDigest ?? quarantineDigest))
        }
    }

    func quarantineRawRows(run: String, _ visit: (Int, [String: CatalogJSONValue]) throws -> Void) throws {
        let cursor = try Row.fetchCursor(db, sql: """
            SELECT source_ordinal, raw_row FROM quarantine WHERE origin = 'import' AND import_run = ? ORDER BY source_ordinal
            """, arguments: [run])
        while let row = try cursor.next() {
            let text: String? = row[1]
            guard let text, let object = Self.json(text)?.objectValue else { continue }
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
            SELECT source_ordinal, json_row_id, field, value_json, digest FROM knowledge_sources WHERE import_run = ? ORDER BY source_ordinal
            """, arguments: [run])
        while let row = try cursor.next() {
            guard let field = CatalogDDL.KnowledgeField.init(rawValue: row[2] as String),
                  let value = Self.json(row[3] as String) else { continue }
            try visit(CatalogRow.KnowledgeReading(ordinal: row[0], jsonRowID: row[1], field: field, value: value, digest: row[4]))
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

    // MARK: - Sidecar rows, whole (codex D′ #3)

    func events(run: String, _ visit: (CatalogRow.Event) throws -> Void) throws {
        let cursor = try Row.fetchCursor(db, sql: """
            SELECT event_id, name, state, categories, note, created_at, updated_at, source_ordinal
              FROM events WHERE import_run = ? ORDER BY source_ordinal
            """, arguments: [run])
        while let row = try cursor.next() {
            let categories = Self.json(row[3] as String)?.arrayValue?.compactMap(\.stringValue) ?? []
            try visit(CatalogRow.Event(eventID: row[0], name: row[1], state: row[2], categories: categories, note: row[4],
                                       createdAt: row[5], updatedAt: row[6], importRun: run, sourceOrdinal: row[7]))
        }
    }

    func eventDecisions(run: String, _ visit: (CatalogRow.EventDecision) throws -> Void) throws {
        let cursor = try Row.fetchCursor(db, sql: """
            SELECT kind, payload, source_ordinal FROM event_decisions WHERE import_run = ? ORDER BY source_ordinal
            """, arguments: [run])
        while let row = try cursor.next() {
            guard let payload = Self.json(row[1] as String) else { continue }
            try visit(CatalogRow.EventDecision(kind: row[0], payload: payload, importRun: run, sourceOrdinal: row[2]))
        }
    }

    func eventMembers(_ visit: (CatalogRow.EventMemberReading) throws -> Void) throws {
        let cursor = try Row.fetchCursor(db, sql: "SELECT event_id, digest, range_start_s, range_end_s, imported_key FROM event_members")
        while let row = try cursor.next() {
            try visit(CatalogRow.EventMemberReading(eventID: row[0], digest: row[1], rangeStart: row[2], rangeEnd: row[3],
                                                    importedKey: row[4]))
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
            guard let value = Self.json(payload) else { continue }
            for key in EventsDecisionsJSON.contentKeys(in: value) { try visit(key) }
        }
    }

    func ledgerLines(run: String, _ visit: (CatalogRow.Ledger) throws -> Void) throws {
        let cursor = try Row.fetchCursor(db, sql: """
            SELECT at, kind, actor, record_id, content_key, digest, path, payload, source_ordinal
              FROM ledger WHERE import_run = ? ORDER BY source_ordinal
            """, arguments: [run])
        while let row = try cursor.next() {
            guard let payload = Self.json(row[7] as String) else { continue }
            try visit(CatalogRow.Ledger(at: row[0], kind: row[1], actor: row[2], recordID: row[3], contentKey: row[4],
                                        digest: row[5], path: row[6], payload: payload, importRun: run, sourceOrdinal: row[8]))
        }
    }

    func ignoredEntries(run: String, _ visit: (CatalogRow.Ignored) throws -> Void) throws {
        let cursor = try Row.fetchCursor(db, sql: """
            SELECT entry_id, source_ordinal, partial_md5, size_bytes, filename, reason, added_at, sample_path, digest, binding
              FROM ignored_content WHERE import_run = ? ORDER BY source_ordinal
            """, arguments: [run])
        while let row = try cursor.next() {
            guard let binding = CatalogDDL.IgnoredBinding.init(rawValue: row[9] as String) else { continue }
            try visit(CatalogRow.Ignored(entryID: row[0], importRun: run, sourceOrdinal: row[1], partialMD5: row[2],
                                         sizeBytes: row[3], filename: row[4], reason: row[5], addedAt: row[6],
                                         samplePath: row[7], digest: row[8], binding: binding))
        }
    }

    func jobMarkers(run: String, _ visit: (CatalogRow.MarkerReading) throws -> Void) throws {
        let cursor = try Row.fetchCursor(db, sql: "SELECT source_file, source_ordinal, detail FROM job_markers WHERE import_run = ?",
                                         arguments: [run])
        while let row = try cursor.next() {
            guard let file = CatalogDDL.ImportSourceFile.init(rawValue: row[0] as String) else { continue }
            let hash = Self.json(row[2] as String)?[CatalogRow.JobMarker.fileSHA256Key]?.stringValue
            try visit(CatalogRow.MarkerReading(sourceFile: file, ordinal: row[1], fileSHA256: hash))
        }
    }

    func auditResults(run: String, _ visit: (CatalogRow.AuditResult) throws -> Void) throws {
        let cursor = try Row.fetchCursor(db, sql: """
            SELECT source_ordinal, json_row_id, result, detail, judged_path, row_full_path, row_audit_seen_at, accepted
              FROM audit_results WHERE import_run = ? ORDER BY source_ordinal
            """, arguments: [run])
        while let row = try cursor.next() {
            guard let result = CatalogDDL.AuditResult.init(rawValue: row[2] as String),
                  let detail = Self.json(row[3] as String) else { continue }
            try visit(CatalogRow.AuditResult(importRun: run, sourceOrdinal: row[0], jsonRowID: row[1], result: result,
                                             detail: detail, judgedPath: row[4], rowFullPath: row[5], rowAuditSeenAt: row[6],
                                             accepted: (row[7] as Int) == 1))
        }
    }

    func personSearchOrdinals(run: String, _ visit: (Int) throws -> Void) throws {
        let cursor = try Int.fetchCursor(db, sql: "SELECT source_ordinal FROM person_searches WHERE import_run = ?",
                                         arguments: [run])
        while let ordinal = try cursor.next() { try visit(ordinal) }
    }

    /// A JSON column back into the importer's value tree (nil when the text
    /// is not JSON — the DDL's CHECKs make that unreachable).
    private static func json(_ text: String) -> CatalogJSONValue? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CatalogJSONValue.self, from: data)
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
