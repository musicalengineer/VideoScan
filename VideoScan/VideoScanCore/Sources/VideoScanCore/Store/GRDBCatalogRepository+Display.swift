// GRDBCatalogRepository+Display.swift (VideoScanCore/Store)
// The display pass's store half (cutover B1, docs/design/
// catalog_cutover_f_prime_2026_10_17.md §2): read the curated evidence
// (`knowledge_sources` by digest), say whether the display tables are still
// empty, and fill them from `DisplayValueDerivation.Rows` — plain INSERTs,
// one row per call, raw SQL (CatalogStoreSensorTests). The decision of WHAT
// to show is the pure Core function's; this file only stores it.
//
// "Empty" means the curated display tables: stars, user_dates, user_places,
// user_notes, dispositions, family_music, workflow_tags, backup_attestations
// and the confirmed / rejected people_tags (detected / suspected are bound
// derived values a cycler writes, not display choices).
//
// (For Rick: the DAO for the pass — SELECT the evidence, INSERT the verdict.)

import Foundation
import GRDB

extension GRDBRecordHandle {

    func displayTablesEmpty() throws -> Bool {
        let rows = try Int.fetchOne(db, sql: """
            SELECT (SELECT count(*) FROM stars) + (SELECT count(*) FROM user_dates) + (SELECT count(*) FROM user_places)
                 + (SELECT count(*) FROM user_notes) + (SELECT count(*) FROM dispositions) + (SELECT count(*) FROM family_music)
                 + (SELECT count(*) FROM workflow_tags) + (SELECT count(*) FROM backup_attestations)
                 + (SELECT count(*) FROM people_tags WHERE kind IN ('confirmed','rejected'))
            """) ?? 0
        return rows == 0
    }

    func displaySources(_ visit: (DisplayValueDerivation.Source) throws -> Void) throws {
        let fields = DisplayValueDerivation.fields.map { "'\($0.rawValue)'" }.joined(separator: ",")
        let cursor = try Row.fetchCursor(db, sql: """
            SELECT digest, import_run || '#' || printf('%012d', source_ordinal), field, value_json
              FROM knowledge_sources
             WHERE digest IS NOT NULL AND field IN (\(fields))
             ORDER BY digest, import_run, source_ordinal
            """)
        while let row = try cursor.next() {
            guard let field = CatalogDDL.KnowledgeField(rawValue: row[2]), let value = CatalogJSONValue.parse(row[3]) else { continue }
            try visit(DisplayValueDerivation.Source(digest: row[0], occurrence: row[1], field: field, value: value))
        }
    }
}

extension GRDBTransaction {

    func insertDisplayRows(_ rows: DisplayValueDerivation.Rows) throws {
        for s in rows.stars {
            try db.execute(sql: "INSERT INTO stars (digest, rating, conflict) VALUES (?, ?, ?)",
                           arguments: [s.digest, s.value, s.conflict ? 1 : 0])
        }
        for s in rows.userNotes {
            try db.execute(sql: "INSERT INTO user_notes (digest, text, conflict) VALUES (?, ?, ?)",
                           arguments: [s.digest, s.value, s.conflict ? 1 : 0])
        }
        for s in rows.dispositions {
            try db.execute(sql: "INSERT INTO dispositions (digest, disposition, conflict) VALUES (?, ?, ?)",
                           arguments: [s.digest, s.value, s.conflict ? 1 : 0])
        }
        for s in rows.userDates {
            try db.execute(sql: "INSERT INTO user_dates (digest, value, confidence, set_at, conflict) VALUES (?, ?, ?, NULL, ?)",
                           arguments: [s.digest, s.value?.value, s.value?.confidence, s.conflict ? 1 : 0])
        }
        for s in rows.userPlaces {
            try db.execute(sql: "INSERT INTO user_places (digest, place, confidence, set_at, conflict) VALUES (?, ?, ?, NULL, ?)",
                           arguments: [s.digest, s.value?.place, s.value?.confidence, s.conflict ? 1 : 0])
        }
        for s in rows.familyMusic {
            try db.execute(sql: "INSERT INTO family_music (digest, performer, title, marked_at, conflict) VALUES (?, ?, ?, ?, ?)",
                           arguments: [s.digest, s.value?.performer, s.value?.title, s.value?.markedAt, s.conflict ? 1 : 0])
        }
        try insertDisplaySets(rows)
    }

    private func insertDisplaySets(_ rows: DisplayValueDerivation.Rows) throws {
        for t in rows.workflowTags {
            try db.execute(sql: "INSERT INTO workflow_tags (digest, tag) VALUES (?, ?)", arguments: [t.digest, t.tag])
        }
        for p in rows.people {
            try db.execute(sql: "INSERT INTO people_tags (digest, name, kind, confirmed_at, conflict) VALUES (?, ?, ?, ?, ?)",
                           arguments: [p.digest, p.name, p.kind.rawValue, p.confirmedAt, p.conflict ? 1 : 0])
        }
        for a in rows.backupAttestations {
            try db.execute(sql: """
                INSERT INTO backup_attestations (digest, kind, answer, label, attested_at, by_whom, conflict)
                VALUES (?, ?, ?, ?, ?, ?, 0)
                """, arguments: [a.digest, a.row.kind, a.row.answer, a.row.label, a.row.attestedAt, a.row.byWhom])
        }
    }
}
