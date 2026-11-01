// GRDBCatalogRepository+ProvenanceAssertions.swift (VideoScanCore/Store)
// `provenance_assertions` (schema v1.13, CatalogProvenanceAssertionRows.swift)
// on the GRDB handles. Raw SQL only (CatalogStoreSensorTests): one plain
// INSERT per assertion; nothing here UPDATEs or DELETEs — the triggers would
// refuse it anyway.
//
// The door's order, per draft (every probe uses an index):
//   1. content subject → the digest must be a stored `content` row
//      (PRIMARY KEY probe), else `.contentMissing`;
//   2. a name or date field on an archived content → `.archivedNameOrDate`
//      (files_by_digest, then archive_copies' primary key);
//   3. the same WHOLE payload already stored → `.duplicate`
//      (provenance_assertions_by_subject's prefix, then a filter on the rest);
//   4. INSERT; a CHECK failure → `.storeRefused` (this row only);
//      `changes() == 0` means the veto trigger ignored it → `.vetoed`.
//
// Memory: one row per call; `provenanceAssertions(subjectKind:subjectID:)`
// returns one subject's rows (tens); `forEachProvenanceAssertionSubject`
// holds one subject's rows at a time (a cursor, not the table).

import Foundation
import GRDB

extension GRDBRecordHandle {

    private static var assertionColumns: String {
        "seq, subject_kind, subject_id, field, value, state, by, at, confidence, evidence_json"
    }

    func provenanceAssertionCount() throws -> Int {
        try Int.fetchOne(db, sql: "SELECT count(*) FROM provenance_assertions") ?? 0
    }

    func provenanceAssertions(subjectKind: String, subjectID: String) throws -> [CatalogRow.ProvenanceAssertionReading] {
        try Row.fetchAll(db, sql: """
            SELECT \(Self.assertionColumns) FROM provenance_assertions
             WHERE subject_kind = ? AND subject_id = ? ORDER BY seq
            """, arguments: [subjectKind, subjectID]).map { row in
            CatalogRow.ProvenanceAssertionReading(seq: row[0], subjectKind: row[1], subjectID: row[2], field: row[3], value: row[4],
                                                  state: row[5], by: row[6], at: row[7], confidence: row[8], evidenceJSON: row[9])
        }
    }

    /// One statement, a cursor (never the whole result in memory): the
    /// subject-ordered scan rides `provenance_assertions_by_subject`'s
    /// (subject_kind, subject_id) prefix; rows are grouped as the cursor
    /// moves and each group is sorted by seq (tens of rows).
    func forEachProvenanceAssertionSubject(subjectKind: String, fields: [String],
                                           _ body: (_ subjectID: String, _ rows: [CatalogRow.ProvenanceAssertionReading]) throws -> Void) throws {
        guard !fields.isEmpty else { return }
        let marks = Array(repeating: "?", count: fields.count).joined(separator: ", ")
        let cursor = try Row.fetchCursor(db, sql: """
            SELECT \(Self.assertionColumns) FROM provenance_assertions
             WHERE subject_kind = ? AND field IN (\(marks)) ORDER BY subject_id
            """, arguments: StatementArguments([subjectKind] + fields))
        var current: String?
        var group: [CatalogRow.ProvenanceAssertionReading] = []
        func flush() throws {
            if let current, !group.isEmpty { try body(current, group.sorted { $0.seq < $1.seq }) }
            group.removeAll(keepingCapacity: true)
        }
        while let row = try cursor.next() {
            let reading = CatalogRow.ProvenanceAssertionReading(seq: row[0], subjectKind: row[1], subjectID: row[2], field: row[3],
                                                                value: row[4], state: row[5], by: row[6], at: row[7],
                                                                confidence: row[8], evidenceJSON: row[9])
            if reading.subjectID != current {
                try flush()
                current = reading.subjectID
            }
            group.append(reading)
        }
        try flush()
    }
}

extension GRDBReader: CatalogProvenanceAssertionReading {}

extension GRDBTransaction: CatalogProvenanceAssertionWriting {

    func appendProvenanceAssertion(_ draft: CatalogRow.ProvenanceAssertionDraft) throws -> CatalogRow.ProvenanceAssertionLanding {
        if draft.subjectKind == ProvenanceAssertionSubject.content {
            let present = try Int.fetchOne(db, sql: "SELECT count(*) FROM content WHERE digest = ?", arguments: [draft.subjectID]) ?? 0
            guard present == 1 else { return .contentMissing }
            if ProvenanceAssertionFieldPolicy.isNameOrDate(draft.field), try isArchived(draft.subjectID) { return .archivedNameOrDate }
        }
        // Codex #187 F4: a duplicate is the WHOLE payload again (the journal
        // line's id covers all of it) — the same (subject, field, value, by,
        // at) with other evidence or confidence is another observation.
        let duplicate = try Bool.fetchOne(db, sql: """
            SELECT EXISTS (SELECT 1 FROM provenance_assertions
                            WHERE subject_kind = ? AND subject_id = ? AND field = ? AND value = ? AND state = ? AND by = ? AND at = ?
                              AND confidence IS ? AND evidence_json = ?)
            """, arguments: [draft.subjectKind, draft.subjectID, draft.field, draft.value, draft.state, draft.by, draft.at,
                             draft.confidence, draft.evidenceJSON]) ?? false
        if duplicate { return .duplicate }
        do {
            try db.execute(sql: """
                INSERT INTO provenance_assertions (subject_kind, subject_id, field, value, state, by, at, confidence, evidence_json)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [draft.subjectKind, draft.subjectID, draft.field, draft.value, draft.state, draft.by, draft.at,
                                 draft.confidence, draft.evidenceJSON])
        } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
            // Codex #187 F7: a CHECK failure is this row's refusal, not the
            // batch's — SQLite rolled back only this statement.
            return .storeRefused(error.message ?? "\(error)")
        }
        guard db.changesCount == 1 else { return .vetoed }
        return .recorded(seq: db.lastInsertedRowID)
    }

    /// Archived = any file of the content promoted (lifecycle / stage
    /// Archived, an archive copy) OR at or under the designated Master
    /// Archive root (Codex #187 F6: a file scanned inside the archive with
    /// Cataloged / None flags is still the archive's).
    private func isArchived(_ digest: String) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS (SELECT 1 FROM files f
                            WHERE f.content_digest = ?1
                              AND (f.lifecycle = 'Archived' OR f.archive_stage = 'Archived'
                                   OR EXISTS (SELECT 1 FROM archive_copies a WHERE a.file_id = f.id)
                                   OR EXISTS (SELECT 1 FROM catalog_state s
                                               WHERE s.singleton = 1 AND json_valid(s.master_archive)
                                                 AND length(json_extract(s.master_archive, '$.rootPath')) > 1
                                                 AND (f.full_path = json_extract(s.master_archive, '$.rootPath')
                                                      OR (f.full_path >= json_extract(s.master_archive, '$.rootPath') || '/'
                                                          AND f.full_path < json_extract(s.master_archive, '$.rootPath') || '0')))))
            """, arguments: [digest]) ?? false
    }
}
