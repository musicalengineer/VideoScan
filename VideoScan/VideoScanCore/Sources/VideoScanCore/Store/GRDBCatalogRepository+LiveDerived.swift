// GRDBCatalogRepository+LiveDerived.swift (VideoScanCore/Store)
// `replaceDerived(digest:kind:_:)` — a commit's derived values of one kind
// written as the content's BOUND rows (cutover B2, catalog_cutover_f_prime
// §3: "derived is regenerable, so replacement is honest"). The exact
// inverse of LoadBoundSQL's rendering in GRDBCatalogRepository+Load.swift:
// each kind's `(value_json, stamp_json)` — the importer's descriptor-table
// shape — is taken apart IN SQL with json_extract, so the two directions
// read side by side. Raw SQL only (CatalogStoreSensorTests).
//
// Called only for a kind whose value CHANGED against what the store shows
// (CatalogCommitBody): an unverified value that nobody touched stays
// unverified — no upgrade by being near an edit.
//
// What it cannot do (named in the report): clearing a kind deletes its
// bound rows, and the row's own `derived_unverified` value of that kind
// (imported evidence, never deleted) shows again at the next load.
//
// (For Rick: one DELETE + INSERT pair per kind, chosen from a table — the
// `switch` is the jump table; the SQL is the data.)

import Foundation
import GRDB

/// One derived kind's bound table, as SQL. `insert` binds :digest, :seq,
/// :value and :stamp (each statement names the ones it uses).
struct LiveDerivedSQL {
    let delete: String
    let insert: String

    private static func seconds(_ path: String) -> String {
        "CAST(strftime('%s', json_extract(\(path))) AS INTEGER)"
    }

    static func of(_ kind: CatalogDDL.DerivedKind) -> LiveDerivedSQL {
        switch kind {
        case .scene, .ocrDate, .ocrText:
            return LiveDerivedSQL(
                delete: "DELETE FROM captions WHERE digest = :digest AND kind = '\(kind.rawValue)'",
                insert: """
                    INSERT INTO captions (digest, kind, seq, at_s, text)
                    VALUES (:digest, '\(kind.rawValue)', :seq, json_extract(:value, '$.timestamp'), json_extract(:value, '$.text'))
                    """)
        case .captionRun:
            return LiveDerivedSQL(
                delete: "DELETE FROM caption_runs WHERE digest = :digest",
                insert: """
                    INSERT INTO caption_runs (digest, model, made_at)
                    VALUES (:digest, json_extract(:value, '$.sceneCaptionModel'), \(seconds(":value, '$.sceneCaptionDate'")))
                    """)
        case .transcript:
            return LiveDerivedSQL(
                delete: "DELETE FROM transcripts WHERE digest = :digest",
                insert: """
                    INSERT INTO transcripts (digest, text, model, made_at)
                    VALUES (:digest, json_extract(:value, '$'), json_extract(:stamp, '$.audioTranscriptModel'),
                            \(seconds(":stamp, '$.audioTranscriptDate'")))
                    """)
        case .dossier:
            return LiveDerivedSQL(
                delete: "DELETE FROM dossiers WHERE digest = :digest",
                insert: """
                    INSERT INTO dossiers (digest, processed_at, processed_by)
                    VALUES (:digest, \(seconds(":value, '$.dossierProcessedAt'")), json_extract(:value, '$.dossierProcessedBy'))
                    """)
        case .inferredDate:
            return LiveDerivedSQL(
                delete: "DELETE FROM inferred_dates WHERE digest = :digest",
                insert: """
                    INSERT INTO inferred_dates (digest, date_at, confidence, source, range_start, range_end, reason)
                    VALUES (:digest, \(seconds(":value, '$.inferredRecordDate'")), json_extract(:value, '$.inferredDateConfidence'),
                            json_extract(:value, '$.inferredDateSource'), json_extract(:value, '$.inferredDateRange.startYear'),
                            json_extract(:value, '$.inferredDateRange.endYear'), json_extract(:value, '$.inferredDateReason'))
                    """)
        case .audioCheck, .videoCheck:
            let side = kind == .audioCheck ? "audio" : "video"
            return LiveDerivedSQL(
                delete: "DELETE FROM media_checks WHERE digest = :digest AND kind = '\(side)'",
                insert: """
                    INSERT INTO media_checks (digest, kind, status, note, checked_at)
                    VALUES (:digest, '\(side)', json_extract(:value, '$.\(side)VerifyStatus'),
                            coalesce(json_extract(:value, '$.\(side)VerifyNote'), ''), \(seconds(":value, '$.\(side)VerifyDate'")))
                    """)
        default:
            return wholeValue(kind)
        }
    }

    /// The kinds stored as one value per content.
    private static func wholeValue(_ kind: CatalogDDL.DerivedKind) -> LiveDerivedSQL {
        switch kind {
        case .reportCard:
            return LiveDerivedSQL(
                delete: "DELETE FROM media_checks WHERE digest = :digest AND kind = 'reportCard'",
                insert: """
                    INSERT INTO media_checks (digest, kind, status, note, checked_at, card)
                    VALUES (:digest, 'reportCard', json_extract(:value, '$.tier'), '', \(seconds(":value, '$.checkedAt'")), json(:value))
                    """)
        case .perceptualPrint:
            return LiveDerivedSQL(
                delete: "DELETE FROM perceptual_prints WHERE digest = :digest",
                insert: """
                    INSERT INTO perceptual_prints (digest, algorithm_version, hashes_b64, duration_s, computed_at)
                    VALUES (:digest, json_extract(:value, '$.algorithmVersion'), json_extract(:value, '$.hashesBase64'),
                            json_extract(:value, '$.durationSeconds'), \(seconds(":value, '$.computedAt'")))
                    """)
        case .footageMembership:
            return LiveDerivedSQL(
                delete: "DELETE FROM footage_membership WHERE digest = :digest",
                insert: """
                    INSERT INTO footage_membership (digest, group_id, membership, scanned_at)
                    VALUES (:digest, json_extract(:value, '$.groupID'), json(:value), \(seconds(":value, '$.scannedAt'")))
                    """)
        default:
            let tag = kind == .detectedPerson ? "detected" : "suspected"
            return LiveDerivedSQL(
                delete: "DELETE FROM people_tags WHERE digest = :digest AND kind = '\(tag)'",
                insert: """
                    INSERT INTO people_tags (digest, name, kind, provenance)
                    VALUES (:digest, json_extract(:value, '$'), '\(tag)', 'bound') ON CONFLICT DO NOTHING
                    """)
        }
    }
}

extension GRDBTransaction {

    func replaceDerived(digest: String, kind: CatalogDDL.DerivedKind, _ rows: [CatalogRecordDTO.DerivedValueRow]) throws {
        let sql = LiveDerivedSQL.of(kind)
        let digest = digest.lowercased()
        try db.execute(sql: sql.delete, arguments: ["digest": digest])
        for row in rows where row.kind == kind {
            var arguments: [String: DatabaseValueConvertible?] = ["digest": digest]
            if sql.insert.contains(":seq") { arguments["seq"] = row.seq }
            if sql.insert.contains(":value") { arguments["value"] = GRDBJSONText.text(row.valueJSON) }
            if sql.insert.contains(":stamp") { arguments["stamp"] = GRDBJSONText.text(row.stampJSON) }
            try db.execute(sql: sql.insert, arguments: StatementArguments(arguments))
        }
    }
}
