// GRDBCatalogRepository+FrameIndex.swift (VideoScanCore/Store)
// CatalogFrameIndexReading on the GRDB READ handle only — SELECT only; the
// transaction handle does not conform, so no writer can reach it. The scope
// is the Observations window's own predicate (ObservationsScope.predicateSQL,
// `?1`), so "Frames" sees exactly the files "Words" sees.
//
// Cost: one pass over `files` in scope plus one indexed lookup per content
// (files_by_digest) for its standing file; ~20k files reads in well under a
// second. Memory: CatalogFrameIndexRows.swift.

import Foundation
import GRDB

extension GRDBReader: CatalogFrameIndexReading {

    func frameIndexFiles(_ scope: ObservationsScope) throws -> [CatalogRow.FrameIndexFile] {
        try Row.fetchAll(db, sql: """
            WITH s(digest, file_id) AS (SELECT f.content_digest, f.id FROM files f WHERE \(scope.predicateSQL)),
                 sc(digest) AS (SELECT DISTINCT digest FROM s)
            SELECT sc.digest, f.id, f.filename, f.full_path, (f.removal_state IS NOT NULL), f.duration_s, f.stream_type
              FROM sc
              JOIN files f ON f.id = (SELECT s.file_id FROM s JOIN files x ON x.id = s.file_id
                                       WHERE s.digest = sc.digest
                                       ORDER BY (x.removal_state IS NOT NULL), x.full_path LIMIT 1)
             ORDER BY f.full_path
            """, arguments: StatementArguments([scope.argument as DatabaseValueConvertible?])).map { row in
            CatalogRow.FrameIndexFile(digest: row[0], fileID: row[1], filename: row[2], path: row[3], removed: (row[4] as Int?) == 1,
                                      durationSeconds: row[5] ?? 0, streamType: row[6] ?? "")
        }
    }
}
