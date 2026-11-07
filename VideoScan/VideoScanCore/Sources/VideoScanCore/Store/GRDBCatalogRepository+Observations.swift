// GRDBCatalogRepository+Observations.swift (VideoScanCore/Store)
// The Observations window's reads (CatalogObservationsRows.swift) on the GRDB
// READ handle only — raw SQL, SELECT only; the transaction handle does not
// conform, so no writer can reach these.
//
// The scope is ONE common table expression prepended to every query
// (`s(digest, file_id)` = the files in scope, `sc(digest)` = their distinct
// contents), with the scope's one argument as `?1`; a query's own arguments
// start at `?2`. The era classification is the Results sheet's `verdicts`
// SQL (GRDBCatalogRepository+AnalysisResults.swift) joined to the scope —
// one engine for "what did this analyzer conclude" (rule 4).
//
// Machine observations only (Rick 11/06): no query here filters or matches
// on a file's name, path or folder, or on anything Rick typed (his notes,
// labels, ratings, places); his date is read once, for the agreement COMPARISON
// (ObservationsSensorTests pins this file's text).
//
// Cost (ObservationsReportTests.oneHundredThousandFilesMeasured, M5 Ultra,
// Debug, 100k DV contents with 6 captions, a transcript and an era each —
// DossierFixture.seedScale): the whole report 2.9 s (the two word histograms
// stream 600k captions), a text search 0.9 s, a technical search 0.9 s, an
// era search 1.1 s. No budget is asserted yet (streamlined, Rick 11/06);
// the scope CTE is re-evaluated per query, which is where a budget would
// start if one is set. Memory: each read returns at most a
// few hundred grouped rows, or `limit` hit rows (≈ 400 B each: a transcript
// hit is cut to 220 characters IN SQL, never the whole transcript).

import Foundation
import GRDB

extension GRDBReader: CatalogObservationsReading {

    // MARK: The scope

    private static func cte(_ scope: ObservationsScope) -> String {
        """
        WITH s(digest, file_id) AS (SELECT f.content_digest, f.id FROM files f WHERE \(scope.predicateSQL)),
             sc(digest) AS (SELECT DISTINCT digest FROM s)
        """
    }

    private static func arguments(_ scope: ObservationsScope, _ rest: [DatabaseValueConvertible?] = []) -> StatementArguments {
        StatementArguments([scope.argument as DatabaseValueConvertible?] + rest)
    }

    /// Per content in scope: its stream type and duration (one row per content; a content with
    /// several copies takes the greatest value, which is the same value for true copies).
    private static let perContent = """
        (SELECT f.content_digest AS digest, max(f.stream_type) AS stream_type, max(f.duration_s) AS dur
           FROM files f JOIN s ON s.file_id = f.id GROUP BY f.content_digest)
        """

    /// The content's standing file in the scope (by path) for a hit row aliased `h`.
    private static let standingFileJoin = """
        LEFT JOIN files f ON f.id = (SELECT s.file_id FROM s JOIN files x ON x.id = s.file_id
                                       WHERE s.digest = h.digest ORDER BY x.full_path LIMIT 1)
        """

    private static let machineSigner = "LIKE 'machine:_%'"

    // MARK: Totals and the technical tier

    func observationTotals(_ scope: ObservationsScope) throws -> CatalogRow.ObservationTotals {
        let row = try Row.fetchOne(db, sql: """
            \(Self.cte(scope))
            SELECT (SELECT count(*) FROM s), count(*),
                   coalesce(sum(stream_type IN ('Video+Audio', 'Video only')), 0),
                   coalesce(sum(stream_type IN ('Video+Audio', 'Audio only')), 0),
                   coalesce(sum(stream_type = ''), 0), coalesce(sum(stream_type = 'ffprobe failed'), 0), coalesce(sum(dur), 0)
              FROM \(Self.perContent)
            """, arguments: Self.arguments(scope))
        guard let row else { return CatalogRow.ObservationTotals(files: 0, contents: 0, videoContents: 0, audioContents: 0, unprobed: 0, probeFailed: 0, durationSeconds: 0) }
        return CatalogRow.ObservationTotals(files: row[0], contents: row[1], videoContents: row[2], audioContents: row[3],
                                            unprobed: row[4], probeFailed: row[5], durationSeconds: row[6])
    }

    /// The probe tuple's columns, in the order ObservationTechnicalTuple names them (shared by the GROUP BY and the hit query).
    private static let tupleColumns: [String] = [
        "f.container", "f.ext", "f.video_codec", "f.audio_codec", "f.stream_type",
        "coalesce(CAST(json_extract(f.probe_extra, '$.resolution') AS TEXT), '')",
        "coalesce(CAST(json_extract(f.probe_extra, '$.frameRate') AS TEXT), '')",
        "coalesce(CAST(json_extract(f.probe_extra, '$.scanType') AS TEXT), '')",
        "coalesce(CAST(json_extract(f.probe_extra, '$.audioSampleRate') AS TEXT), '')",
        "coalesce(CAST(json_extract(f.probe_extra, '$.audioChannels') AS TEXT), '')",
        "coalesce(CAST(json_extract(f.probe_extra, '$.originMake') AS TEXT), '')",
        "coalesce(CAST(json_extract(f.probe_extra, '$.originModel') AS TEXT), '')",
        "coalesce(CAST(json_extract(f.probe_extra, '$.originEncoder') AS TEXT), '')",
    ]

    private static func tuple(_ row: Row, contents: Int, duration: Double) -> CatalogRow.ObservationTechnicalTuple {
        CatalogRow.ObservationTechnicalTuple(container: row[0], ext: row[1], videoCodec: row[2], audioCodec: row[3], streamType: row[4],
                                             resolution: row[5], frameRate: row[6], scanType: row[7], audioSampleRate: row[8],
                                             audioChannels: row[9], make: row[10], model: row[11], encoder: row[12],
                                             contents: contents, durationSeconds: duration)
    }

    func observationTechnicalTuples(_ scope: ObservationsScope) throws -> [CatalogRow.ObservationTechnicalTuple] {
        let names = (0..<Self.tupleColumns.count).map { "c\($0)" }
        let selected = zip(Self.tupleColumns, names).map { "\($0) AS \($1)" }.joined(separator: ", ")
        let list = names.joined(separator: ", ")
        return try Row.fetchAll(db, sql: """
            \(Self.cte(scope))
            SELECT \(list), count(*), coalesce(sum(dur), 0)
              FROM (SELECT f.content_digest, \(selected), max(f.duration_s) AS dur
                      FROM files f JOIN s ON s.file_id = f.id GROUP BY f.content_digest, \(list))
             GROUP BY \(list) ORDER BY count(*) DESC, \(list)
            """, arguments: Self.arguments(scope)).map { Self.tuple($0, contents: $0[13], duration: $0[14]) }
    }

    func observationTechnicalHits(_ scope: ObservationsScope, tuple: CatalogRow.ObservationTechnicalTuple, limit: Int) throws
        -> [CatalogRow.ObservationHitRow] {
        let values: [DatabaseValueConvertible?] = [tuple.container, tuple.ext, tuple.videoCodec, tuple.audioCodec, tuple.streamType,
                                                   tuple.resolution, tuple.frameRate, tuple.scanType, tuple.audioSampleRate,
                                                   tuple.audioChannels, tuple.make, tuple.model, tuple.encoder]
        let predicate = Self.tupleColumns.enumerated().map { "\($0.element) = ?\($0.offset + 2)" }.joined(separator: " AND ")
        return try Row.fetchAll(db, sql: """
            \(Self.cte(scope))
            SELECT h.digest, f.id, f.filename, f.full_path, (f.removal_state IS NOT NULL), h.kind, h.at, h.text, h.by, h.seq
              FROM (SELECT DISTINCT f.content_digest AS digest, 'technical' AS kind, NULL AS at, '' AS text, 'ffprobe' AS by, 0 AS seq
                      FROM files f JOIN s ON s.file_id = f.id WHERE \(predicate) LIMIT ?15) h
              \(Self.standingFileJoin)
             ORDER BY f.filename COLLATE NOCASE, h.digest
            """, arguments: Self.arguments(scope, values + [limit])).map(Self.hit)
    }

    func observationEmbeddedDates(_ scope: ObservationsScope) throws -> [CatalogRow.ObservationEmbeddedDateGroup] {
        try Row.fetchAll(db, sql: """
            \(Self.cte(scope))
            SELECT decade, codec, dev, count(*)
              FROM (SELECT f.content_digest,
                           (CAST(strftime('%Y', f.embedded_created_at, 'unixepoch') AS INTEGER) / 10) * 10 AS decade,
                           max(f.video_codec) AS codec,
                           max(coalesce(CAST(json_extract(f.probe_extra, '$.originMake') AS TEXT), '') <> ''
                               OR coalesce(CAST(json_extract(f.probe_extra, '$.originModel') AS TEXT), '') <> ''
                               OR coalesce(f.embedded_created_source, '') LIKE '%com.apple.quicktime.creationdate%') AS dev
                      FROM files f JOIN s ON s.file_id = f.id
                     WHERE f.embedded_created_at IS NOT NULL
                     GROUP BY f.content_digest, decade)
             GROUP BY decade, codec, dev ORDER BY decade, codec, dev
            """, arguments: Self.arguments(scope)).map {
            CatalogRow.ObservationEmbeddedDateGroup(decade: $0[0], videoCodec: $0[1], deviceTag: ($0[2] as Int) == 1, contents: $0[3])
        }
    }

    // MARK: The patterns tier

    func observationEraVerdicts(_ scope: ObservationsScope) throws -> [CatalogRow.ObservationEraVerdict] {
        try Row.fetchAll(db, sql: """
            \(Self.cte(scope))
            SELECT p.by, CASE WHEN p.found OR p.rejected THEN p.fvalue END AS value, p.found, p.rejected,
                   (NOT p.found AND NOT p.rejected AND p.gave) AS gave,
                   (NOT p.found AND NOT p.rejected AND NOT p.gave AND p.none) AS none, count(*)
              FROM (\(Self.verdicts(signerFilter: ""))) p JOIN sc ON sc.digest = p.subject_id
             GROUP BY p.by, value, p.found, p.rejected, gave, none
             ORDER BY p.by, count(*) DESC, value
            """, arguments: Self.arguments(scope)).map {
            CatalogRow.ObservationEraVerdict(by: $0[0], value: $0[1], found: ($0[2] as Int) == 1, rejected: ($0[3] as Int) == 1,
                                             gaveUp: ($0[4] as Int) == 1, none: ($0[5] as Int) == 1, contents: $0[6])
        }
    }

    func observationEraHits(_ scope: ObservationsScope, values: [String], limit: Int) throws -> [CatalogRow.ObservationHitRow] {
        let json = (try? JSONSerialization.data(withJSONObject: values)).flatMap { String(bytes: $0, encoding: .utf8) } ?? "[]"
        return try Row.fetchAll(db, sql: """
            \(Self.cte(scope))
            SELECT h.digest, f.id, f.filename, f.full_path, (f.removal_state IS NOT NULL), h.kind, h.at, h.text, h.by, h.seq
              FROM (SELECT p.subject_id AS digest, 'era' AS kind, NULL AS at, p.fvalue AS text, p.by AS by, 0 AS seq
                      FROM (\(Self.verdicts(signerFilter: ""))) p JOIN sc ON sc.digest = p.subject_id
                     WHERE p.found AND p.fvalue IN (SELECT value FROM json_each(?2)) LIMIT ?3) h
              \(Self.standingFileJoin)
             ORDER BY f.filename COLLATE NOCASE, h.digest, h.by
            """, arguments: Self.arguments(scope, [json, limit])).map(Self.hit)
    }

    func observationBurnedInDates(_ scope: ObservationsScope, limit: Int) throws -> [CatalogRow.ObservationCount] {
        try Row.fetchAll(db, sql: """
            \(Self.cte(scope))
            SELECT a.value, count(DISTINCT a.subject_id)
              FROM provenance_assertions a JOIN sc ON sc.digest = a.subject_id
             WHERE a.subject_kind = 'content' AND a.field = 'ocr.date' AND a.state = 'inferred' AND a.by \(Self.machineSigner)
               AND NOT \(MachineEraResolver.rejectedLaterSQL("a"))
             GROUP BY a.value ORDER BY count(DISTINCT a.subject_id) DESC, a.value LIMIT ?2
            """, arguments: Self.arguments(scope, [limit])).map { CatalogRow.ObservationCount(key: $0[0], contents: $0[1]) }
    }

    func observationCaptions(_ scope: ObservationsScope) throws -> CatalogRow.ObservationCaptions {
        let row = try Row.fetchOne(db, sql: """
            \(Self.cte(scope))
            SELECT (SELECT count(DISTINCT c.digest) FROM captions c JOIN sc ON sc.digest = c.digest WHERE c.kind = 'scene'),
                   (SELECT count(*) FROM captions c JOIN sc ON sc.digest = c.digest WHERE c.kind = 'scene'),
                   (SELECT count(DISTINCT c.digest) FROM captions c JOIN sc ON sc.digest = c.digest WHERE c.kind = 'ocrText'),
                   (SELECT count(*) FROM captions c JOIN sc ON sc.digest = c.digest WHERE c.kind = 'ocrText'),
                   (SELECT count(DISTINCT c.digest) FROM captions c JOIN sc ON sc.digest = c.digest WHERE c.kind = 'ocrDate'),
                   (SELECT count(*) FROM captions c JOIN sc ON sc.digest = c.digest WHERE c.kind = 'ocrDate'),
                   (SELECT count(*) FROM caption_runs r JOIN sc ON sc.digest = r.digest
                     WHERE NOT EXISTS (SELECT 1 FROM captions c WHERE c.digest = r.digest AND c.kind = 'scene')),
                   (SELECT count(*) FROM caption_runs r JOIN sc ON sc.digest = r.digest JOIN dossiers d ON d.digest = r.digest
                     WHERE d.processed_at = r.made_at AND substr(d.processed_by, 1, length(r.model) + 1) = r.model || '+')
            """, arguments: Self.arguments(scope))
        let models = try Row.fetchAll(db, sql: """
            \(Self.cte(scope))
            SELECT r.model, count(*), min(r.made_at), max(r.made_at) FROM caption_runs r JOIN sc ON sc.digest = r.digest
             GROUP BY r.model ORDER BY count(*) DESC, r.model
            """, arguments: Self.arguments(scope)).map { CatalogRow.ObservationModelRun(model: $0[0], contents: $0[1], firstAt: $0[2], lastAt: $0[3]) }
        guard let row else {
            return CatalogRow.ObservationCaptions(sceneContents: 0, sceneRows: 0, ocrTextContents: 0, ocrTextRows: 0, ocrDateContents: 0,
                                                  ocrDateRows: 0, ranNoScenes: 0, ocrProvenRan: 0, models: models)
        }
        return CatalogRow.ObservationCaptions(sceneContents: row[0], sceneRows: row[1], ocrTextContents: row[2], ocrTextRows: row[3],
                                              ocrDateContents: row[4], ocrDateRows: row[5], ranNoScenes: row[6], ocrProvenRan: row[7], models: models)
    }

    private static let wordCount = "(length(t.text) - length(replace(t.text, ' ', '')) + 1)"

    func observationSpeech(_ scope: ObservationsScope) throws -> CatalogRow.ObservationSpeech {
        let row = try Row.fetchOne(db, sql: """
            \(Self.cte(scope))
            SELECT coalesce(sum(t.text <> ''), 0), coalesce(sum(t.text = ''), 0), coalesce(sum(length(t.text)), 0),
                   coalesce(sum(CASE WHEN t.text <> '' THEN \(Self.wordCount) ELSE 0 END), 0),
                   coalesce(max(CASE WHEN t.text <> '' THEN \(Self.wordCount) ELSE 0 END), 0)
              FROM transcripts t JOIN sc ON sc.digest = t.digest
            """, arguments: Self.arguments(scope))
        let models = try Row.fetchAll(db, sql: """
            \(Self.cte(scope))
            SELECT coalesce(t.model, '(model not recorded)'), count(*), min(t.made_at), max(t.made_at)
              FROM transcripts t JOIN sc ON sc.digest = t.digest GROUP BY 1 ORDER BY count(*) DESC, 1
            """, arguments: Self.arguments(scope)).map { CatalogRow.ObservationModelRun(model: $0[0], contents: $0[1], firstAt: $0[2], lastAt: $0[3]) }
        guard let row else { return CatalogRow.ObservationSpeech(withSpeech: 0, noSpeech: 0, characters: 0, words: 0, longestWords: 0, models: models) }
        return CatalogRow.ObservationSpeech(withSpeech: row[0], noSpeech: row[1], characters: row[2], words: row[3], longestWords: row[4], models: models)
    }

    func observationPeople(_ scope: ObservationsScope, limit: Int) throws -> [CatalogRow.ObservationPerson] {
        try Row.fetchAll(db, sql: """
            \(Self.cte(scope))
            SELECT p.name, p.kind, count(DISTINCT p.digest) FROM people_tags p JOIN sc ON sc.digest = p.digest
             WHERE p.kind IN ('detected', 'suspected', 'confirmed')
             GROUP BY p.name, p.kind ORDER BY count(DISTINCT p.digest) DESC, p.name, p.kind LIMIT ?2
            """, arguments: Self.arguments(scope, [limit])).map { CatalogRow.ObservationPerson(name: $0[0], kind: $0[1], contents: $0[2]) }
    }

    func observationInferredDates(_ scope: ObservationsScope) throws -> CatalogRow.ObservationInferredDates {
        let decades = try Row.fetchAll(db, sql: """
            \(Self.cte(scope))
            SELECT (CAST(strftime('%Y', i.date_at, 'unixepoch') AS INTEGER) / 10) * 10, count(*)
              FROM inferred_dates i JOIN sc ON sc.digest = i.digest WHERE i.date_at IS NOT NULL GROUP BY 1 ORDER BY 1
            """, arguments: Self.arguments(scope)).map { CatalogRow.ObservationCount(key: "\($0[0] as Int)s", contents: $0[1]) }
        let none = try Int.fetchOne(db, sql: """
            \(Self.cte(scope))
            SELECT count(*) FROM inferred_dates i JOIN sc ON sc.digest = i.digest WHERE i.date_at IS NULL
            """, arguments: Self.arguments(scope)) ?? 0
        return CatalogRow.ObservationInferredDates(decades: decades, noEvidence: none, dated: decades.reduce(0) { $0 + $1.contents })
    }

    func observationEvents(_ scope: ObservationsScope, limit: Int) throws -> [CatalogRow.ObservationEvent] {
        try Row.fetchAll(db, sql: """
            \(Self.cte(scope))
            SELECT e.name, e.state, count(DISTINCT m.digest)
              FROM events e JOIN event_members m ON m.event_id = e.event_id JOIN sc ON sc.digest = m.digest
             GROUP BY e.event_id ORDER BY count(DISTINCT m.digest) DESC, e.name LIMIT ?2
            """, arguments: Self.arguments(scope, [limit])).map { CatalogRow.ObservationEvent(name: $0[0], state: $0[1], members: $0[2]) }
    }

    // MARK: The collection tier

    func observationCoverage(_ scope: ObservationsScope, now: Int64) throws -> CatalogRow.ObservationCoverage {
        let machineRows = "SELECT 1 FROM provenance_assertions a WHERE a.subject_kind = 'content' AND a.subject_id = p.digest AND a.by \(Self.machineSigner)"
        let row = try Row.fetchOne(db, sql: """
            \(Self.cte(scope))
            SELECT coalesce(sum(EXISTS (SELECT 1 FROM caption_runs r WHERE r.digest = p.digest)
                                OR EXISTS (SELECT 1 FROM transcripts t WHERE t.digest = p.digest)
                                OR EXISTS (SELECT 1 FROM inferred_dates i WHERE i.digest = p.digest)
                                OR EXISTS (SELECT 1 FROM people_tags k WHERE k.digest = p.digest AND k.kind IN ('detected', 'suspected'))
                                OR EXISTS (\(machineRows))), 0),
                   coalesce(sum(p.stream_type IN ('Video+Audio', 'Video only')
                                AND NOT EXISTS (SELECT 1 FROM caption_runs r WHERE r.digest = p.digest)), 0),
                   coalesce(sum(p.stream_type IN ('Video+Audio', 'Audio only')
                                AND NOT EXISTS (SELECT 1 FROM transcripts t WHERE t.digest = p.digest)), 0),
                   coalesce(sum(p.stream_type IN ('Video+Audio', 'Video only') AND NOT EXISTS (\(machineRows))), 0),
                   coalesce(sum(EXISTS (SELECT 1 FROM caption_runs r WHERE r.digest = p.digest AND r.made_at >= ?2)
                                OR EXISTS (SELECT 1 FROM transcripts t WHERE t.digest = p.digest AND t.made_at >= ?2)
                                OR EXISTS (SELECT 1 FROM dossiers d WHERE d.digest = p.digest AND d.processed_at >= ?2)
                                OR EXISTS (\(machineRows) AND a.at >= ?2)), 0)
              FROM \(Self.perContent) p
            """, arguments: Self.arguments(scope, [now - 86_400]))
        let signers = try Row.fetchAll(db, sql: """
            \(Self.cte(scope))
            SELECT a.by, count(DISTINCT a.subject_id), min(a.at), max(a.at)
              FROM provenance_assertions a JOIN sc ON sc.digest = a.subject_id
             WHERE a.subject_kind = 'content' AND a.state = 'inferred' AND a.by \(Self.machineSigner)
             GROUP BY a.by ORDER BY count(DISTINCT a.subject_id) DESC, a.by
            """, arguments: Self.arguments(scope)).map { CatalogRow.ObservationModelRun(model: $0[0], contents: $0[1], firstAt: $0[2], lastAt: $0[3]) }
        guard let row else {
            return CatalogRow.ObservationCoverage(analyzedAny: 0, videoNotCaptioned: 0, audioNotTranscribed: 0, videoNoEra: 0, last24Hours: 0, eraSigners: signers)
        }
        return CatalogRow.ObservationCoverage(analyzedAny: row[0], videoNotCaptioned: row[1], audioNotTranscribed: row[2], videoNoEra: row[3],
                                              last24Hours: row[4], eraSigners: signers)
    }

    func observationEraRowsOfDatedContents(_ scope: ObservationsScope,
                                           _ body: (_ rickDate: String, _ rows: [CatalogRow.ProvenanceAssertionReading]) throws -> Void) throws {
        // `user_dates.value` is read here for the agreement COMPARISON only (the Results sheet's rule; CatalogAnalysisResultsRows.swift).
        let cursor = try Row.fetchCursor(db, sql: """
            \(Self.cte(scope))
            SELECT a.seq, a.subject_kind, a.subject_id, a.field, a.value, a.state, a.by, a.at, a.confidence, a.evidence_json, u.value
              FROM user_dates u JOIN sc ON sc.digest = u.digest
              JOIN provenance_assertions a ON a.subject_kind = 'content' AND a.subject_id = u.digest AND a.field = 'era.fused'
             WHERE u.value IS NOT NULL
             ORDER BY a.subject_id, a.seq
            """, arguments: Self.arguments(scope))
        var current: String?
        var date = ""
        var group: [CatalogRow.ProvenanceAssertionReading] = []
        while let row = try cursor.next() {
            let reading = CatalogRow.ProvenanceAssertionReading(seq: row[0], subjectKind: row[1], subjectID: row[2], field: row[3],
                                                                value: row[4], state: row[5], by: row[6], at: row[7],
                                                                confidence: row[8], evidenceJSON: row[9])
            if reading.subjectID != current {
                if current != nil, !group.isEmpty { try body(date, group) }
                group.removeAll(keepingCapacity: true)
                current = reading.subjectID
                date = row[10]
            }
            group.append(reading)
        }
        if current != nil, !group.isEmpty { try body(date, group) }
    }

    func observationTexts(_ scope: ObservationsScope, kind: String, _ visit: (String) throws -> Void) throws {
        let sql = kind == "transcript"
            ? "SELECT t.text FROM transcripts t JOIN sc ON sc.digest = t.digest WHERE t.text <> ''"
            : "SELECT c.text FROM captions c JOIN sc ON sc.digest = c.digest WHERE c.kind = 'scene'"
        let cursor = try String.fetchCursor(db, sql: "\(Self.cte(scope)) \(sql)", arguments: Self.arguments(scope))
        while let text = try cursor.next() { try visit(text) }
    }

    // MARK: Search (observations only — never a catalog field)

    func observationTextHits(_ scope: ObservationsScope, query: String, limitPerKind: Int) throws -> [CatalogRow.ObservationHitRow] {
        let like = "LIKE ?2 ESCAPE '\\'"
        // A transcript can be hundreds of KB: the hit carries a 220-character window around the match (ASCII lower()).
        let window = """
            CASE WHEN instr(lower(t.text), ?4) > 0 THEN substr(t.text, max(1, instr(lower(t.text), ?4) - 80), 220)
                 ELSE substr(t.text, 1, 220) END
            """
        return try Row.fetchAll(db, sql: """
            \(Self.cte(scope))
            SELECT h.digest, f.id, f.filename, f.full_path, (f.removal_state IS NOT NULL), h.kind, h.at, h.text, h.by, h.seq
              FROM (SELECT * FROM (SELECT c.digest, c.kind AS kind, c.at_s AS at, substr(c.text, 1, 400) AS text,
                                          coalesce((SELECT r.model FROM caption_runs r WHERE r.digest = c.digest), 'VLM') AS by, c.seq
                                     FROM captions c JOIN sc ON sc.digest = c.digest WHERE c.kind = 'scene' AND c.text \(like) LIMIT ?3)
                    UNION ALL
                    SELECT * FROM (SELECT c.digest, c.kind, c.at_s, substr(c.text, 1, 400),
                                          coalesce((SELECT r.model FROM caption_runs r WHERE r.digest = c.digest), 'VLM'), c.seq
                                     FROM captions c JOIN sc ON sc.digest = c.digest WHERE c.kind = 'ocrText' AND c.text \(like) LIMIT ?3)
                    UNION ALL
                    SELECT * FROM (SELECT c.digest, c.kind, c.at_s, substr(c.text, 1, 400),
                                          coalesce((SELECT r.model FROM caption_runs r WHERE r.digest = c.digest), 'VLM'), c.seq
                                     FROM captions c JOIN sc ON sc.digest = c.digest WHERE c.kind = 'ocrDate' AND c.text \(like) LIMIT ?3)
                    UNION ALL
                    SELECT * FROM (SELECT t.digest, 'speech', NULL, \(window), coalesce(t.model, 'Whisper'), 0
                                     FROM transcripts t JOIN sc ON sc.digest = t.digest WHERE t.text \(like) LIMIT ?3)
                    UNION ALL
                    SELECT * FROM (SELECT a.subject_id, 'burnedIn', CAST(json_extract(a.evidence_json, '$.atS') AS REAL), a.value, a.by, a.seq
                                     FROM provenance_assertions a JOIN sc ON sc.digest = a.subject_id
                                    WHERE a.subject_kind = 'content' AND a.field = 'ocr.date' AND a.state = 'inferred'
                                      AND a.by \(Self.machineSigner) AND NOT \(MachineEraResolver.rejectedLaterSQL("a"))
                                      AND a.value \(like) LIMIT ?3)
                    UNION ALL
                    SELECT * FROM (SELECT p.digest, 'person', NULL, p.name, p.kind, 0
                                     FROM people_tags p JOIN sc ON sc.digest = p.digest
                                    WHERE p.kind IN ('detected', 'suspected') AND p.name \(like) LIMIT ?3)
                    UNION ALL
                    SELECT * FROM (SELECT m.digest, 'event', m.range_start_s, e.name, e.state, 0
                                     FROM events e JOIN event_members m ON m.event_id = e.event_id JOIN sc ON sc.digest = m.digest
                                    WHERE e.name \(like) LIMIT ?3)) h
              \(Self.standingFileJoin)
             ORDER BY h.kind, f.filename COLLATE NOCASE, h.digest, h.at, h.seq
            """, arguments: Self.arguments(scope, ["%" + query + "%", limitPerKind, query.lowercased()])).map(Self.hit)
    }

    private static func hit(_ row: Row) -> CatalogRow.ObservationHitRow {
        CatalogRow.ObservationHitRow(digest: row[0], fileID: row[1], filename: row[2], path: row[3], removed: (row[4] as Int?) == 1,
                                     kind: row[5], at: row[6], text: row[7] ?? "", by: row[8] ?? "", seq: row[9] ?? 0)
    }
}
