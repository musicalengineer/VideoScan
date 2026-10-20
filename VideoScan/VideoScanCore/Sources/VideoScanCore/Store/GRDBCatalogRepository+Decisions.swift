// GRDBCatalogRepository+Decisions.swift (VideoScanCore/Store)
// The decision-table readings and doors (schema v1.11, CatalogDecisionRows
// .swift) on the GRDB handles. Raw SQL only (CatalogStoreSensorTests):
// `INSERT … ON CONFLICT DO NOTHING` for a pair (a duplicate is left as it is,
// never REPLACE), plain INSERTs for an ignore entry and its put-back.
// Nothing here UPDATEs or DELETEs — the triggers would refuse it anyway.
//
// Memory: the readings are cursors (one row at a time); a few thousand rows
// at most today.
//
// (For Rick: three small DAO methods and four cursors; `?` placeholders are
// bound parameters, never string-spliced values.)

import Foundation
import GRDB

// MARK: - Readings (both handles)

extension GRDBRecordHandle {

    /// The latest verdict between any two files of the pair's contents,
    /// either direction (index `footage_decisions_by_digest`).
    func footageLikenessReviews(_ visit: (CatalogRow.FootageLikenessReview) throws -> Void) throws {
        let cursor = try Row.fetchCursor(db, sql: """
            SELECT l.digest_a, l.digest_b, l.reasons, l.strength, l.source, l.recorded_at,
                   (SELECT d.verdict FROM footage_decisions d
                     WHERE (d.digest = l.digest_a AND d.other_digest = l.digest_b)
                        OR (d.digest = l.digest_b AND d.other_digest = l.digest_a)
                     ORDER BY d.decided_at DESC, d.decision_id DESC LIMIT 1)
              FROM footage_likeness l ORDER BY l.digest_a, l.digest_b
            """)
        while let row = try cursor.next() {
            let likeness = CatalogRow.FootageLikeness(row[0], row[1], reasons: row[2], strength: row[3], source: row[4],
                                                      recordedAt: row[5])
            try visit(CatalogRow.FootageLikenessReview(likeness: likeness, verdict: row[6]))
        }
    }

    func footageLikenessCount() throws -> Int {
        try Int.fetchOne(db, sql: "SELECT count(*) FROM footage_likeness") ?? 0
    }

    func ignoredRows(_ visit: (CatalogRow.IgnoredReading) throws -> Void) throws {
        let cursor = try Row.fetchCursor(db, sql: """
            SELECT g.ignored_seq, g.entry_id, g.partial_md5, g.size_bytes, g.filename, g.reason, g.added_at, g.sample_path,
                   g.import_run IS NOT NULL,
                   EXISTS (SELECT 1 FROM ignored_content_put_back p WHERE p.ignored_seq = g.ignored_seq)
              FROM ignored_content g ORDER BY g.ignored_seq
            """)
        while let row = try cursor.next() {
            let entry = CatalogRow.IgnoredEntry(entryID: row[1], partialMD5: row[2], sizeBytes: row[3], filename: row[4],
                                                reason: row[5], addedAt: row[6], samplePath: row[7])
            try visit(CatalogRow.IgnoredReading(seq: row[0], entry: entry, imported: row[8], putBack: row[9]))
        }
    }

    func ignoredCounts() throws -> CatalogRow.IgnoredCounts {
        CatalogRow.IgnoredCounts(rows: try Int.fetchOne(db, sql: "SELECT count(*) FROM ignored_content") ?? 0,
                                 putBack: try Int.fetchOne(db, sql: "SELECT count(*) FROM ignored_content_put_back") ?? 0)
    }
}

extension GRDBReader: CatalogDecisionReading {}

// MARK: - Doors (the transaction)

extension GRDBTransaction: CatalogDecisionWriting {

    func recordFootageLikeness(_ likeness: CatalogRow.FootageLikeness) throws -> CatalogRow.FootageLikenessLanding {
        let present = try Int.fetchOne(db, sql: "SELECT count(*) FROM content WHERE digest IN (?, ?)",
                                       arguments: [likeness.digestA, likeness.digestB]) ?? 0
        guard present == 2 else { return .contentMissing }
        try db.execute(sql: """
            INSERT INTO footage_likeness (digest_a, digest_b, reasons, strength, source, recorded_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT (digest_a, digest_b) DO NOTHING
            """, arguments: [likeness.digestA, likeness.digestB, likeness.reasons, likeness.strength, likeness.source,
                             likeness.recordedAt])
        return db.changesCount == 1 ? .recorded : .alreadyRecorded
    }

    func appendIgnoredEntry(_ entry: CatalogRow.IgnoredEntry) throws {
        try db.execute(sql: """
            INSERT INTO ignored_content (entry_id, import_run, source_ordinal, partial_md5, size_bytes, filename, reason,
                                         added_at, sample_path, digest, binding)
            VALUES (?, NULL, NULL, ?, ?, ?, ?, ?, ?, NULL, 'unbound')
            """, arguments: [entry.entryID, entry.partialMD5, entry.sizeBytes, entry.filename, entry.reason, entry.addedAt,
                             entry.samplePath])
    }

    @discardableResult
    func putBackIgnored(entryID: String, at: Int64) throws -> Int {
        try db.execute(sql: """
            INSERT INTO ignored_content_put_back (ignored_seq, put_back_at)
            SELECT g.ignored_seq, ? FROM ignored_content g
             WHERE g.entry_id = ?
               AND NOT EXISTS (SELECT 1 FROM ignored_content_put_back p WHERE p.ignored_seq = g.ignored_seq)
            """, arguments: [at, entryID])
        return db.changesCount
    }
}
