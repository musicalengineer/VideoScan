// GRDBCatalogRepository+AnalysisResults.swift (VideoScanCore/Store)
// The Results sheet's reads (CatalogAnalysisResultsRows.swift) on the GRDB
// READ handle only — raw SQL, SELECT only; the transaction handle does not
// conform, so no writer can reach these.
//
// One classification, used by the counts and by the lists (so a list can
// never disagree with its count): per (by, content) over inferred rows,
//   found  = an `era.fused` row whose value is "YYYY-YYYY";
//   gaveUp = not found, and an `era.none` row with evidence.gaveUp = true;
//   none   = not found, an `era.none` row, not gaveUp.
// A content with rows by the signer but none of the three (only ocr.date, or
// a malformed fused value) is "analyzed" and in no list; the report shows it
// as "other" so the numbers add up.
//
// Cost: the counts GROUP BY over provenance_assertions once (≈ 6 rows per
// analyzed content); "still to do" probes provenance_assertions_by_subject's
// (subject_kind, subject_id) prefix per planned content and returns the
// digests (the journal half of the planner's rule is subtracted in Swift,
// EraPlanner.answeredInJournal); the file of a
// content rides files_by_digest. Measured (AnalysisResultsReportTests'
// scale test, M5 Ultra, Debug): 100k contents (≈ 200k rows, 20k dated) —
// the whole report plus one 10k list ≈ 0.8 s; the budget is 2 s.
//
// Memory: the counts are one row per signer; a list holds at most `limit`
// rows (≈ 250 B each); the dated stream holds one content's fused rows.

import Foundation
import GRDB

extension GRDBReader: CatalogAnalysisResultsReading {

    /// The per-(by, content) classification; `signerFilter` narrows it ("AND by = ?1") or is empty.
    private static func verdicts(signerFilter: String) -> String {
        """
        SELECT by, subject_id,
               max(field = 'era.fused' AND \(MachineEraResolver.eraValueSQL("value"))) AS found,
               max(CASE WHEN field = 'era.none' THEN coalesce(json_extract(evidence_json, '$.gaveUp'), 0) = 1 ELSE 0 END) AS gave,
               max(field = 'era.none') AS none
          FROM provenance_assertions
         WHERE subject_kind = 'content' AND state = 'inferred' \(signerFilter)
         GROUP BY by, subject_id
        """
    }

    /// The content's standing file: first live file by path, else first file.
    private static let standingFile = """
        SELECT f2.id FROM files f2 WHERE f2.content_digest = p.subject_id
         ORDER BY (f2.removal_state IS NOT NULL), f2.full_path LIMIT 1
        """

    func analyzerOutcomeCounts() throws -> [CatalogRow.AnalyzerOutcomeCounts] {
        try Row.fetchAll(db, sql: """
            SELECT by, count(*), sum(found), sum(NOT found AND gave), sum(NOT found AND NOT gave AND none)
              FROM (\(Self.verdicts(signerFilter: "")))
             GROUP BY by ORDER BY by
            """).map { row in
            CatalogRow.AnalyzerOutcomeCounts(signer: row[0], analyzed: row[1], eraFound: row[2], eraNone: row[4], gaveUp: row[3])
        }
    }

    func eraUnansweredInCatalog(signer: String) throws -> [String] {
        try String.fetchAll(db, sql: """
            SELECT DISTINCT f.content_digest FROM files f
             WHERE \(EraPlanner.plannedFilesPredicate)
               AND NOT EXISTS (SELECT 1 FROM provenance_assertions a
                                WHERE a.subject_kind = 'content' AND a.subject_id = f.content_digest AND a.by = ?)
            """, arguments: [signer])
    }

    func analyzerAnswered(signer: String, digests: [String]) throws -> Set<String> {
        var out = Set<String>()
        var start = 0
        while start < digests.count {
            let chunk = Array(digests[start..<min(start + 500, digests.count)])
            start += chunk.count
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            out.formUnion(try String.fetchAll(db, sql: """
                SELECT DISTINCT subject_id FROM provenance_assertions
                 WHERE subject_kind = 'content' AND by = ? AND subject_id IN (\(marks))
                """, arguments: StatementArguments([signer] + chunk)))
        }
        return out
    }

    func analyzerFirstVerdicts(signer: String, since: Int64) throws -> Int {
        try Int.fetchOne(db, sql: """
            SELECT count(*) FROM (SELECT min(at) AS first FROM provenance_assertions
                                   WHERE subject_kind = 'content' AND by = ? GROUP BY subject_id)
             WHERE first >= ?
            """, arguments: [signer, since]) ?? 0
    }

    func eraFusedRowsOfDatedContents(_ body: (_ subjectID: String, _ rickDate: String,
                                              _ rows: [CatalogRow.ProvenanceAssertionReading]) throws -> Void) throws {
        let cursor = try Row.fetchCursor(db, sql: """
            SELECT a.seq, a.subject_kind, a.subject_id, a.field, a.value, a.state, a.by, a.at, a.confidence, a.evidence_json, u.value
              FROM user_dates u
              JOIN provenance_assertions a ON a.subject_kind = 'content' AND a.subject_id = u.digest AND a.field = 'era.fused'
             WHERE u.value IS NOT NULL
               AND EXISTS (SELECT 1 FROM files f WHERE f.content_digest = u.digest AND f.removal_state IS NULL)
             ORDER BY a.subject_id, a.seq
            """)
        var current: String?
        var date = ""
        var group: [CatalogRow.ProvenanceAssertionReading] = []
        while let row = try cursor.next() {
            let reading = CatalogRow.ProvenanceAssertionReading(seq: row[0], subjectKind: row[1], subjectID: row[2], field: row[3],
                                                                value: row[4], state: row[5], by: row[6], at: row[7],
                                                                confidence: row[8], evidenceJSON: row[9])
            if reading.subjectID != current {
                if let current, !group.isEmpty { try body(current, date, group) }
                group.removeAll(keepingCapacity: true)
                current = reading.subjectID
                date = row[10]
            }
            group.append(reading)
        }
        if let current, !group.isEmpty { try body(current, date, group) }
    }

    func analyzerOutcomeFiles(signer: String, kind: CatalogRow.AnalyzerVerdictKind, limit: Int) throws -> [CatalogRow.AnalyzerOutcomeFile] {
        let which: String
        let detail: String
        switch kind {
        case .eraFound:
            which = "p.found"
            detail = """
                (SELECT a.value FROM provenance_assertions a
                  WHERE a.subject_kind = 'content' AND a.subject_id = p.subject_id AND a.by = ?1 AND a.state = 'inferred'
                    AND a.field = 'era.fused' AND \(MachineEraResolver.eraValueSQL("a.value"))
                  ORDER BY a.seq DESC LIMIT 1), NULL
                """
        case .eraNone, .gaveUp:
            which = kind == .gaveUp ? "NOT p.found AND p.gave" : "NOT p.found AND NOT p.gave AND p.none"
            detail = """
                NULL, (SELECT json_extract(a.evidence_json, '$.reason') FROM provenance_assertions a
                        WHERE a.subject_kind = 'content' AND a.subject_id = p.subject_id AND a.by = ?1 AND a.state = 'inferred'
                          AND a.field = 'era.none' ORDER BY a.seq DESC LIMIT 1)
                """
        }
        return try Row.fetchAll(db, sql: """
            SELECT p.subject_id, f.id, f.full_path, f.filename,
                   NOT EXISTS (SELECT 1 FROM files l WHERE l.content_digest = p.subject_id AND l.removal_state IS NULL),
                   \(detail)
              FROM (\(Self.verdicts(signerFilter: "AND by = ?1"))) p
              LEFT JOIN files f ON f.id = (\(Self.standingFile))
             WHERE \(which)
             ORDER BY f.filename IS NULL, f.filename COLLATE NOCASE, f.full_path, p.subject_id
             LIMIT ?2
            """, arguments: [signer, limit]).map(Self.file)
    }

    func analyzerFiles(digests: [String]) throws -> [CatalogRow.AnalyzerOutcomeFile] {
        var out: [CatalogRow.AnalyzerOutcomeFile] = []
        // SQLite's bound-parameter limit is generous; 500 per statement keeps each small.
        var start = 0
        while start < digests.count {
            let chunk = Array(digests[start..<min(start + 500, digests.count)])
            start += chunk.count
            let marks = Array(repeating: "(?)", count: chunk.count).joined(separator: ", ")
            out += try Row.fetchAll(db, sql: """
                WITH p(subject_id) AS (VALUES \(marks))
                SELECT p.subject_id, f.id, f.full_path, f.filename,
                       NOT EXISTS (SELECT 1 FROM files l WHERE l.content_digest = p.subject_id AND l.removal_state IS NULL),
                       NULL, NULL
                  FROM p LEFT JOIN files f ON f.id = (\(Self.standingFile))
                """, arguments: StatementArguments(chunk)).map(Self.file)
        }
        return out
    }

    private static func file(_ row: Row) -> CatalogRow.AnalyzerOutcomeFile {
        CatalogRow.AnalyzerOutcomeFile(digest: row[0], fileID: row[1], path: row[2], filename: row[3],
                                       removed: (row[4] as Int?) == 1, value: row[5], reason: row[6])
    }
}
