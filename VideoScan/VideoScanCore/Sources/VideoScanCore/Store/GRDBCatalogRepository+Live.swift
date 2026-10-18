// GRDBCatalogRepository+Live.swift (VideoScanCore/Store)
// The live write doors of `CatalogTransaction` (cutover B2, docs/design/
// catalog_cutover_f_prime_2026_10_17.md §3 "The door"). Raw SQL only
// (CatalogStoreSensorTests). Where the import doors INSERT one occurrence,
// these REPLACE what one row or one content owns with the record's current
// state — delete-then-insert for the sets, UPDATE for the `files` row — and
// leave every refusal to the DDL: a digest change, a live-path collision, a
// trashed archive copy, a marker change without its tombstone, a value a
// CHECK will not hold. The thrown error carries the engine's words; the
// caller's savepoint undoes only that row.
//
// What is never touched here: `knowledge_sources`, `derived_unverified`,
// `legacy_pair_ids`, `tombstones` already written, `generation_history` —
// the evidence. A commit appends to `row_knowledge` and `tombstones` and
// replaces display / bound / relation rows.
//
// (For Rick: the DAO's update half. `ON CONFLICT … DO NOTHING / DO UPDATE`
// is SQLite's upsert — it never deletes the row in the way, unlike
// REPLACE, which the DDL's guards refuse.)

import Foundation
import GRDB

extension GRDBTransaction {

    func inSavepoint(_ body: () throws -> Void) throws {
        try db.inSavepoint {
            try body()
            return .commit
        }
    }

    func upsertVolume(_ volume: CatalogRecordDTO.VolumeRowDTO) throws {
        try db.execute(sql: """
            INSERT INTO volumes (volume_uuid, last_name, mount_type, remote_server, case_sensitive)
            VALUES (?, ?, ?, ?, 0)
            ON CONFLICT (volume_uuid) DO UPDATE
               SET last_name = excluded.last_name, mount_type = excluded.mount_type, remote_server = excluded.remote_server
            """, arguments: [volume.volumeUUID, volume.lastName, volume.mountType, volume.remoteServer])
    }

    func ensureContent(_ content: CatalogRecordDTO.ContentRow) throws {
        try db.execute(sql: """
            INSERT INTO content (digest, algorithm, byte_count, first_seen_at, first_seen_how)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT (digest) DO NOTHING
            """, arguments: [content.digest.lowercased(), content.algorithm, content.byteCount, content.firstSeenAt,
                             content.firstSeenHow.rawValue])
    }

    func updateFile(_ file: CatalogRecordDTO.FileRow, markerChanged: Bool) throws {
        try db.execute(sql: """
            UPDATE files SET
              content_digest = ?, volume_uuid = ?,
              volume_case_sensitive = (SELECT case_sensitive FROM volumes WHERE volume_uuid = ?),
              full_path = ?, path_fold = ?, filename = ?, ext = ?, directory = ?,
              size_bytes = ?, fs_created_at = ?, fs_modified_at = ?,
              stamp_device = ?, stamp_inode = ?, stamp_mtime_ns = ?, stamp_ctime_ns = ?, stamp_volume_uuid = ?,
              digest_computed_at = ?, digest_source = ?, sampled_hash = ?, sampled_hash_at = ?, partial_md5 = ?,
              stream_type = ?, duration_s = ?, container = ?, video_codec = ?, audio_codec = ?,
              embedded_created_at = ?, embedded_created_source = ?, probe_extra = ?,
              scan_host = ?, scanned_at = ?, scan_root_label = ?, bundle_container = ?, source_host = ?,
              original_full_path = ?, origin_volume = ?, machine_notes = ?,
              lifecycle = ?, archive_stage = ?, master_location = ?, set_aside_reason = ?,
              needs_reformat = ?, workspace_active = ?
            WHERE id = ?
            """, arguments: [
                file.contentDigest?.lowercased(), file.volumeUUID, file.volumeUUID,
                file.fullPath, file.pathFold, file.filename, file.ext, file.directory,
                file.sizeBytes, file.fsCreatedAt, file.fsModifiedAt,
                file.stampDevice, file.stampInode, file.stampMtimeNs, file.stampCtimeNs, file.stampVolumeUUID,
                file.digestComputedAt, file.digestSource?.rawValue, file.sampledHash, file.sampledHashAt, file.partialMD5,
                file.streamType, file.durationS, file.container, file.videoCodec, file.audioCodec,
                file.embeddedCreatedAt, file.embeddedCreatedSource, GRDBJSONText.text(file.probeExtra),
                file.scanHost, file.scannedAt, file.scanRootLabel, file.bundleContainer, file.sourceHost,
                file.originalFullPath, file.originVolume, file.machineNotes,
                file.lifecycle, file.archiveStage, file.masterLocation, file.setAsideReason,
                file.needsReformat ? 1 : 0, file.workspaceActive ? 1 : 0,
                file.id,
            ])
        guard db.changesCount == 1 else {
            throw DatabaseError(resultCode: .SQLITE_CONSTRAINT, message: "files row \(file.id) is not there to update")
        }
        // The marker only when it changed (its tombstone is already in):
        // `archive_copy_never_trashed` fires on ANY update of removal_state.
        if markerChanged {
            try db.execute(sql: """
                UPDATE files SET removal_state = ?, removal_since = ?, removal_reason = ?, removal_trash_path = ?,
                                 removal_trash_emptied_at = ?, removal_last_seen = ?, removal_revision = ?
                 WHERE id = ?
                """, arguments: [file.removalState, file.removalSince, file.removalReason, file.removalTrashPath,
                                 file.removalTrashEmptiedAt, file.removalLastSeen, file.removalRevision, file.id])
        }
        // After the path trigger has cleared a stale stamp: the record's own.
        try db.execute(sql: """
            UPDATE files SET audit_seen_volume_uuid = ?, audit_seen_mount_from = ?, audit_seen_device_key = ?, audit_seen_at = ?
             WHERE id = ?
            """, arguments: [file.auditSeenVolumeUUID, file.auditSeenMountFrom, file.auditSeenDeviceKey, file.auditSeenAt, file.id])
    }

    func replaceArchiveCopy(fileID: String, _ copy: CatalogRecordDTO.ArchiveCopyRow?) throws {
        guard let copy else {
            try db.execute(sql: "DELETE FROM archive_copies WHERE file_id = ?", arguments: [fileID])
            return
        }
        try db.execute(sql: """
            UPDATE archive_copies SET source_row_id = ?, archived_at = ?, fixity_verified_at = ? WHERE file_id = ?
            """, arguments: [copy.sourceRowID, copy.archivedAt, copy.fixityVerifiedAt, fileID])
        guard db.changesCount == 0 else { return }
        // A new copy is Promote's: it names its source row (the DDL refuses one that does not).
        try db.execute(sql: """
            INSERT INTO archive_copies (file_id, source_file_id, source_row_id, archived_at, fixity_verified_at, promoted_by)
            VALUES (?, (SELECT id FROM files WHERE id = ?), ?, ?, ?, 'promote')
            """, arguments: [fileID, copy.sourceRowID, copy.sourceRowID, copy.archivedAt, copy.fixityVerifiedAt])
    }

    func replaceBackupDestinations(fileID: String, _ rows: [CatalogRecordDTO.BackupDestinationRow]) throws {
        try db.execute(sql: "DELETE FROM backup_destinations WHERE file_id = ?", arguments: [fileID])
        for row in rows {
            try db.execute(sql: """
                INSERT INTO backup_destinations (file_id, name, kind, recorded_at) VALUES (?, ?, ?, ?)
                ON CONFLICT DO NOTHING
                """, arguments: [fileID, row.name, row.kind, row.recordedAt])
        }
    }

    func replaceFootageDecisions(rowID: String, digest: String, _ rows: [CatalogRecordDTO.FootageDecisionRow]) throws {
        try db.execute(sql: "DELETE FROM footage_decisions WHERE row_id = ?", arguments: [rowID])
        for row in rows {
            try db.execute(sql: """
                INSERT INTO footage_decisions (import_run, source_ordinal, row_id, other_row_id, digest, other_digest, verdict, decided_at)
                VALUES (NULL, NULL, ?, ?, ?, (SELECT content_digest FROM files WHERE id = ?), ?, ?)
                """, arguments: [rowID, row.otherRowID, digest.lowercased(), row.otherRowID, row.verdict, row.decidedAt])
        }
    }

    func replaceDuplicateMember(fileID: String, _ member: CatalogRecordDTO.DuplicateMemberRow?) throws -> String? {
        try db.execute(sql: "DELETE FROM duplicate_members WHERE file_id = ?", arguments: [fileID])
        guard let member else { return nil }
        if case .refused(let words) = try insertRelation(.duplicateCandidate(fileID: fileID, member: member)) {
            return "duplicate analysis not stored: \(words)"
        }
        return nil
    }

    func replaceSoundPrint(digest: String, _ print: CatalogRecordDTO.SoundPrintRow?) throws {
        let digest = digest.lowercased()
        try db.execute(sql: "DELETE FROM sound_prints WHERE digest = ?", arguments: [digest])
        guard let print, print.digest.lowercased() == digest else { return }
        _ = try insertSoundPrint(print)
    }

    func appendRowKnowledge(_ row: CatalogRow.RowKnowledge) throws {
        try db.execute(sql: """
            INSERT INTO row_knowledge (file_id, digest, field, value_json, set_at, source, import_run, generation)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [row.fileID, row.digest?.lowercased(), row.field, GRDBJSONText.text(row.value), row.setAt,
                             row.source, row.importRun, generation])
    }

    func setMasterArchive(json: String?) throws {
        try db.execute(sql: "UPDATE catalog_state SET master_archive = ? WHERE singleton = 1", arguments: [json])
    }
}

// MARK: - The display rows of one content (conflict = 0)

extension GRDBTransaction {

    func writeDisplayValue(digest: String, field: CatalogDDL.KnowledgeField,
                           _ curated: CatalogRecordDTO.CuratedKnowledge, setAt: Int64) throws {
        let digest = digest.lowercased()
        switch field {
        case .starRating:
            try replaceScalar("stars", digest: digest, columns: "rating", values: curated.starRating.map { [$0] })
        case .userNotes:
            try replaceScalar("user_notes", digest: digest, columns: "text", values: curated.userNotes.map { [$0] })
        case .mediaDisposition:
            try replaceScalar("dispositions", digest: digest, columns: "disposition", values: curated.mediaDisposition.map { [$0] })
        case .userDate, .userDateConfidence:
            try replaceScalar("user_dates", digest: digest, columns: "value, confidence, set_at",
                              values: curated.userDate.map { [$0.value, $0.confidence, setAt] })
        case .userPlace, .userPlaceConfidence:
            try replaceScalar("user_places", digest: digest, columns: "place, confidence, set_at",
                              values: curated.userPlace.map { [$0.place, $0.confidence, setAt] })
        case .familyMusic:
            try replaceScalar("family_music", digest: digest, columns: "performer, title, marked_at",
                              values: curated.familyMusic.map { [$0.performer, $0.title, $0.markedAt] })
        case .tags, .confirmedByUserPeople, .rejectedPeople, .backupAttestations:
            try writeDisplaySet(digest: digest, field: field, curated)
        case .repairConfirmedDate, .footageDecisions, .setAsideReason, .archivedAt, .archiveFixity, .lineage,
             .supersededByID, .mediaReportCard:
            return   // row-scoped or column-backed: no display table
        }
    }

    /// DELETE the content's row, then INSERT the shown value (nil = no row).
    private func replaceScalar(_ table: String, digest: String, columns: String, values: [DatabaseValueConvertible?]?) throws {
        try db.execute(sql: "DELETE FROM \(table) WHERE digest = ?", arguments: [digest])
        guard let values else { return }
        let marks = Array(repeating: "?", count: values.count).joined(separator: ", ")
        try db.execute(sql: "INSERT INTO \(table) (digest, \(columns), conflict) VALUES (?, \(marks), 0)",
                       arguments: StatementArguments([digest] + values))
    }

    private func writeDisplaySet(digest: String, field: CatalogDDL.KnowledgeField, _ curated: CatalogRecordDTO.CuratedKnowledge) throws {
        switch field {
        case .tags:
            try db.execute(sql: "DELETE FROM workflow_tags WHERE digest = ?", arguments: [digest])
            for tag in curated.tags {
                try db.execute(sql: "INSERT INTO workflow_tags (digest, tag) VALUES (?, ?) ON CONFLICT DO NOTHING",
                               arguments: [digest, tag])
            }
        case .backupAttestations:
            try db.execute(sql: "DELETE FROM backup_attestations WHERE digest = ?", arguments: [digest])
            for a in curated.backupAttestations {
                try db.execute(sql: """
                    INSERT INTO backup_attestations (digest, kind, answer, label, attested_at, by_whom, conflict)
                    VALUES (?, ?, ?, ?, ?, ?, 0) ON CONFLICT DO NOTHING
                    """, arguments: [digest, a.kind, a.answer, a.label, a.attestedAt, a.byWhom])
            }
        default:
            // Confirmed and rejected people are written together: a name on
            // both sides was a conflict pair, and the person's list resolves both.
            try db.execute(sql: "DELETE FROM people_tags WHERE digest = ? AND kind IN ('confirmed','rejected')", arguments: [digest])
            for p in curated.people {
                try db.execute(sql: """
                    INSERT INTO people_tags (digest, name, kind, confirmed_at, conflict) VALUES (?, ?, ?, ?, 0)
                    ON CONFLICT DO NOTHING
                    """, arguments: [digest, p.name, p.kind.rawValue, p.confirmedAt])
            }
        }
    }
}
