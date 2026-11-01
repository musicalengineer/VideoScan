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
//   3. the same (subject, field, value, by, at) already stored → `.duplicate`
//      (provenance_assertions_by_subject's prefix, then a filter on by/at);
//   4. INSERT; `changes() == 0` means the veto trigger ignored it → `.vetoed`.
//
// Memory: one row per call; `provenanceAssertions(subjectKind:subjectID:)`
// returns one subject's rows (tens).

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
}

extension GRDBReader: CatalogProvenanceAssertionReading {}

extension GRDBTransaction: CatalogProvenanceAssertionWriting {

    func appendProvenanceAssertion(_ draft: CatalogRow.ProvenanceAssertionDraft) throws -> CatalogRow.ProvenanceAssertionLanding {
        if draft.subjectKind == ProvenanceAssertionSubject.content {
            let present = try Int.fetchOne(db, sql: "SELECT count(*) FROM content WHERE digest = ?", arguments: [draft.subjectID]) ?? 0
            guard present == 1 else { return .contentMissing }
            if ProvenanceAssertionFieldPolicy.isNameOrDate(draft.field) {
                let archived = try Bool.fetchOne(db, sql: """
                    SELECT EXISTS (SELECT 1 FROM files f
                                    WHERE f.content_digest = ?
                                      AND (f.lifecycle = 'Archived' OR f.archive_stage = 'Archived'
                                           OR EXISTS (SELECT 1 FROM archive_copies a WHERE a.file_id = f.id)))
                    """, arguments: [draft.subjectID]) ?? false
                if archived { return .archivedNameOrDate }
            }
        }
        let duplicate = try Bool.fetchOne(db, sql: """
            SELECT EXISTS (SELECT 1 FROM provenance_assertions
                            WHERE subject_kind = ? AND subject_id = ? AND field = ? AND value = ? AND by = ? AND at = ?)
            """, arguments: [draft.subjectKind, draft.subjectID, draft.field, draft.value, draft.by, draft.at]) ?? false
        if duplicate { return .duplicate }
        try db.execute(sql: """
            INSERT INTO provenance_assertions (subject_kind, subject_id, field, value, state, by, at, confidence, evidence_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [draft.subjectKind, draft.subjectID, draft.field, draft.value, draft.state, draft.by, draft.at,
                             draft.confidence, draft.evidenceJSON])
        guard db.changesCount == 1 else { return .vetoed }
        return .recorded(seq: db.lastInsertedRowID)
    }
}
