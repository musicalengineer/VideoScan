// GRDBCatalogRepository+Writes.swift (VideoScanCore/Store)
// The write doors of `CatalogTransaction` on the GRDB handle (step C′ part
// 2b). Every statement is raw SQL through `execute(sql:)` — Rick reviews
// SQL, not a query builder (CatalogStoreSensorTests pins the spelling) —
// and every one is a plain INSERT: a duplicate is a finding the DDL
// raises, never a replacement. One row per call.
//
// What the doors decide and what they leave to the DDL:
//   * a value's SHAPE (digest lowercase, JSON canonical text, enum raw
//     values) is the door's job, done the same way for every caller;
//   * a value's LEGALITY (CHECKs, FKs, UNIQUEs, the no-replace triggers) is
//     the DDL's job; a refusal throws the engine's words and the caller's
//     transaction rolls back;
//   * the few relations whose duplicate from a byte-identical copy is
//     legal (the same lineage edge, the same supersession, the same event
//     member) are looked up first and answered `.alreadyPresent`; the
//     supersession cycle rule is asked the same way the trigger asks it,
//     so the caller gets words instead of an abort.
//
// (For Rick: the body of a DAO — prepared statements with bound
// parameters. `arguments:` binds `?` by position; nil binds NULL.)

import Foundation
import GRDB

/// The shared handle: both the reader and the transaction own a `Database`.
protocol GRDBRecordHandle {
    var db: Database { get }
}

extension GRDBReader: GRDBRecordHandle {}
extension GRDBTransaction: GRDBRecordHandle {}

// MARK: - JSON text helpers (canonical, sorted keys)

enum GRDBJSONText {
    static func text(_ value: CatalogJSONValue) -> String { value.canonicalText() }

    static func text(_ object: [String: CatalogJSONValue]) -> String { CatalogJSONValue.object(object).canonicalText() }

    static func strings(_ values: [String]) -> String { CatalogJSONValue.array(values.map { .string($0) }).canonicalText() }

    static func findings(_ findings: [ImportGate.Finding]) throws -> String {
        try CatalogJSONValue.of(findings).canonicalText()
    }

    static func lineagePayload(_ value: CatalogRecordDTO.LineageValue) throws -> CatalogJSONValue {
        try CatalogJSONValue.of(value)
    }
}

// MARK: - The occurrence's own rows

extension GRDBTransaction {

    func insertVolume(_ volume: CatalogRecordDTO.VolumeRowDTO, caseSensitive: Bool) throws {
        try db.execute(sql: """
            INSERT INTO volumes (volume_uuid, last_name, mount_type, remote_server, case_sensitive)
            VALUES (?, ?, ?, ?, ?)
            """, arguments: [volume.volumeUUID, volume.lastName, volume.mountType, volume.remoteServer, caseSensitive ? 1 : 0])
    }

    func insertContent(_ content: CatalogRecordDTO.ContentRow) throws {
        try db.execute(sql: """
            INSERT INTO content (digest, algorithm, byte_count, first_seen_at, first_seen_how)
            VALUES (?, ?, ?, ?, ?)
            """, arguments: [content.digest.lowercased(), content.algorithm, content.byteCount, content.firstSeenAt,
                             content.firstSeenHow.rawValue])
    }

    func insertFile(_ file: CatalogRecordDTO.FileRow, volumeCaseSensitive: Bool) throws {
        try db.execute(sql: """
            INSERT INTO files (
              id, content_digest, volume_uuid, volume_case_sensitive, full_path, path_fold, filename, ext, directory,
              size_bytes, fs_created_at, fs_modified_at,
              stamp_device, stamp_inode, stamp_mtime_ns, stamp_ctime_ns, stamp_volume_uuid,
              digest_computed_at, digest_source, sampled_hash, sampled_hash_at, partial_md5,
              stream_type, duration_s, container, video_codec, audio_codec,
              embedded_created_at, embedded_created_source, probe_extra,
              scan_host, scanned_at, scan_root_label, bundle_container, source_host,
              original_full_path, origin_volume, machine_notes,
              lifecycle, archive_stage, master_location, set_aside_reason, needs_reformat, workspace_active,
              removal_state, removal_since, removal_reason, removal_trash_path, removal_trash_emptied_at,
              removal_last_seen, removal_revision,
              audit_seen_volume_uuid, audit_seen_mount_from, audit_seen_device_key, audit_seen_at, catalogued_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?,
                    ?, ?, ?,
                    ?, ?, ?, ?, ?,
                    ?, ?, ?, ?, ?,
                    ?, ?, ?, ?, ?,
                    ?, ?, ?,
                    ?, ?, ?, ?, ?,
                    ?, ?, ?,
                    ?, ?, ?, ?, ?, ?,
                    ?, ?, ?, ?, ?,
                    ?, ?,
                    ?, ?, ?, ?, ?)
            """, arguments: [
                file.id, file.contentDigest?.lowercased(), file.volumeUUID, volumeCaseSensitive ? 1 : 0, file.fullPath,
                file.pathFold, file.filename, file.ext, file.directory,
                file.sizeBytes, file.fsCreatedAt, file.fsModifiedAt,
                file.stampDevice, file.stampInode, file.stampMtimeNs, file.stampCtimeNs, file.stampVolumeUUID,
                file.digestComputedAt, file.digestSource?.rawValue, file.sampledHash, file.sampledHashAt, file.partialMD5,
                file.streamType, file.durationS, file.container, file.videoCodec, file.audioCodec,
                file.embeddedCreatedAt, file.embeddedCreatedSource, GRDBJSONText.text(file.probeExtra),
                file.scanHost, file.scannedAt, file.scanRootLabel, file.bundleContainer, file.sourceHost,
                file.originalFullPath, file.originVolume, file.machineNotes,
                file.lifecycle, file.archiveStage, file.masterLocation, file.setAsideReason,
                file.needsReformat ? 1 : 0, file.workspaceActive ? 1 : 0,
                file.removalState, file.removalSince, file.removalReason, file.removalTrashPath, file.removalTrashEmptiedAt,
                file.removalLastSeen, file.removalRevision,
                file.auditSeenVolumeUUID, file.auditSeenMountFrom, file.auditSeenDeviceKey, file.auditSeenAt, file.cataloguedAt,
            ])
    }

    func insertTombstone(_ tombstone: CatalogRow.Tombstone) throws {
        try db.execute(sql: """
            INSERT INTO tombstones (file_id, revision, state, since, reason, trash_path, trash_emptied_at, last_seen,
                                    written_at, door, generation)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [tombstone.fileID, tombstone.revision, tombstone.state?.rawValue, tombstone.since, tombstone.reason,
                             tombstone.trashPath, tombstone.trashEmptiedAt, tombstone.lastSeen, tombstone.writtenAt,
                             tombstone.door, generation])
    }

    func insertArchiveCopy(fileID: String, _ copy: CatalogRecordDTO.ArchiveCopyRow, sourceFileID: String?) throws {
        try db.execute(sql: """
            INSERT INTO archive_copies (file_id, source_file_id, source_row_id, archived_at, fixity_verified_at, promoted_by)
            VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [fileID, sourceFileID, copy.sourceRowID, copy.archivedAt, copy.fixityVerifiedAt, copy.promotedBy.rawValue])
    }

    func insertBackupDestination(fileID: String, _ destination: CatalogRecordDTO.BackupDestinationRow) throws {
        try db.execute(sql: """
            INSERT INTO backup_destinations (file_id, name, kind, recorded_at) VALUES (?, ?, ?, ?)
            """, arguments: [fileID, destination.name, destination.kind, destination.recordedAt])
    }
}

// MARK: - Knowledge and derived evidence

extension GRDBTransaction {

    func insertKnowledgeSource(_ source: CatalogRow.KnowledgeSource) throws {
        try db.execute(sql: """
            INSERT INTO knowledge_sources (import_run, source_ordinal, json_row_id, digest, field, value_json, set_at, source)
            VALUES (?, ?, ?, ?, ?, ?, ?, 'catalog.json')
            """, arguments: [source.importRun, source.sourceOrdinal, source.jsonRowID, source.digest?.lowercased(),
                             source.value.field.rawValue, GRDBJSONText.text(source.value.valueJSON), source.value.setAt])
    }

    func insertDerivedUnverified(_ derived: CatalogRow.DerivedUnverified) throws -> Bool {
        let digest = derived.digest.lowercased()
        let present = try Int.fetchOne(db, sql: """
            SELECT 1 FROM derived_unverified
             WHERE digest = ? AND kind = ? AND seq = ? AND source_json_row_id = ?
            """, arguments: [digest, derived.value.kind.rawValue, derived.value.seq, derived.sourceJSONRowID])
        if present != nil { return false }
        try db.execute(sql: """
            INSERT INTO derived_unverified (digest, kind, seq, source_json_row_id, value_json, stamp_json, import_run, source_ordinal)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [digest, derived.value.kind.rawValue, derived.value.seq, derived.sourceJSONRowID,
                             GRDBJSONText.text(derived.value.valueJSON), GRDBJSONText.text(derived.value.stampJSON),
                             derived.importRun, derived.sourceOrdinal])
        return true
    }

    func insertSoundPrint(_ print: CatalogRecordDTO.SoundPrintRow) throws -> Bool {
        let digest = print.digest.lowercased()
        let present = try Int.fetchOne(db, sql: "SELECT 1 FROM sound_prints WHERE digest = ?", arguments: [digest])
        if present != nil { return false }
        try db.execute(sql: """
            INSERT INTO sound_prints (digest, engine_version, outcome, analyzed_s, complete, landmarks, blob_bytes, computed_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [digest, print.engineVersion, print.outcome, print.analyzedS, print.complete ? 1 : 0,
                             print.landmarks, print.blobBytes, print.computedAt])
        return true
    }

    func insertRegenContext(_ context: CatalogRow.RegenContext) throws {
        try db.execute(sql: """
            INSERT INTO regen_context (import_run, source_ordinal, json_row_id, digest, kind, value_json, reason)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, arguments: [context.importRun, context.sourceOrdinal, context.jsonRowID, context.digest?.lowercased(),
                             context.value.kind.rawValue, GRDBJSONText.text(context.value.valueJSON), context.value.reason])
    }

    func insertLegacyPairIDs(_ pair: CatalogRow.LegacyPairIDs) throws {
        try db.execute(sql: """
            INSERT INTO legacy_pair_ids (import_run, source_ordinal, json_row_id, digest, paired_with_id, pair_group_id, event_member_keys)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, arguments: [pair.importRun, pair.sourceOrdinal, pair.jsonRowID, pair.digest?.lowercased(),
                             pair.value.pairedWithID, pair.value.pairGroupID, GRDBJSONText.strings(pair.eventMemberKeys)])
    }

    func insertRelation(_ relation: CatalogRow.Relation) throws -> CatalogRow.RelationLanding {
        switch relation {
        case .lineage(let child, let parent, let value, let recordedAt):
            return try insertLineage(child: child.lowercased(), parent: parent.lowercased(), value: value, recordedAt: recordedAt)
        case .lineagePending(let run, let ordinal, let kind, let childRowID, let childDigest, let parentRowID, let parentDigest, let payload):
            try db.execute(sql: """
                INSERT INTO lineage_pending (import_run, source_ordinal, relation, child_row_id, child_digest,
                                             parent_row_id, parent_digest, payload)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [run, ordinal, kind.rawValue, childRowID, childDigest?.lowercased(), parentRowID,
                                 parentDigest?.lowercased(), GRDBJSONText.text(payload)])
            return .landed
        case .supersession(let retired, let by, let confirmedAt):
            return try insertSupersession(retired: retired.lowercased(), by: by.lowercased(), confirmedAt: confirmedAt)
        case .duplicateCandidate(let fileID, let member):
            return try insertDuplicateCandidate(fileID: fileID, member: member)
        case .footageDecision(let run, let ordinal, let decision, let digest, let otherDigest):
            try db.execute(sql: """
                INSERT INTO footage_decisions (import_run, source_ordinal, row_id, other_row_id, digest, other_digest, verdict, decided_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [run, ordinal, decision.rowID, decision.otherRowID, digest?.lowercased(),
                                 otherDigest?.lowercased(), decision.verdict, decision.decidedAt])
            return .landed
        case .eventMembership(let eventID, let digest, let start, let end, let key):
            return try insertEventMember(eventID: eventID, digest: digest.lowercased(), start: start, end: end, key: key)
        }
    }

    /// `lineage` CHECKs, asked in Swift so the caller gets words (the DDL
    /// would abort the statement with the same verdict).
    private func lineageRefusal(child: String, parent: String, value: CatalogRecordDTO.LineageValue) -> String? {
        let kind = value.kind
        if child == parent { return "its source has the same bytes (archive promotion is archive_copies, not lineage)" }
        if (kind == .cleanup) != (value.cleanupRecipeID != nil) { return "a cleanup edge names its recipe, and only a cleanup edge does" }
        if (value.cleanupRecipeID == nil) != (value.cleanupRecipeVersion == nil) { return "a recipe id and version come together" }
        let hasTrim = value.trimInSeconds != nil && value.trimOutSeconds != nil
        if (kind == .trim) != hasTrim { return "a trim edge carries both trim bounds, and only a trim edge does" }
        if let inS = value.trimInSeconds, let outS = value.trimOutSeconds, inS >= outS { return "trim in must be before trim out" }
        return nil
    }

    private func insertLineage(child: String, parent: String, value: CatalogRecordDTO.LineageValue,
                               recordedAt: Int64?) throws -> CatalogRow.RelationLanding {
        if let words = lineageRefusal(child: child, parent: parent, value: value) { return .refused(words) }
        let present = try Int.fetchOne(db, sql: "SELECT 1 FROM lineage WHERE child_digest = ? AND parent_digest = ?",
                                       arguments: [child, parent])
        if present != nil { return .alreadyPresent }
        try db.execute(sql: """
            INSERT INTO lineage (child_digest, parent_digest, kind, cleanup_recipe_id, cleanup_recipe_version,
                                 trim_in_s, trim_out_s, recorded_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [child, parent, value.kind.rawValue, value.cleanupRecipeID, value.cleanupRecipeVersion,
                             value.trimInSeconds, value.trimOutSeconds, recordedAt])
        return .landed
    }

    private func insertSupersession(retired: String, by: String, confirmedAt: Int64?) throws -> CatalogRow.RelationLanding {
        if retired == by { return .refused("a repair cannot supersede its own bytes") }
        let existing = try String.fetchOne(db, sql: "SELECT by_digest FROM supersessions WHERE retired_digest = ?",
                                           arguments: [retired])
        if let existing {
            return existing == by ? .alreadyPresent : .refused("this content is already superseded by \(existing)")
        }
        // The same walk as the DDL's `supersessions_acyclic` trigger.
        let cycles = try Int.fetchOne(db, sql: """
            WITH RECURSIVE chain(d) AS (
              SELECT ? UNION SELECT s.by_digest FROM supersessions s JOIN chain ON s.retired_digest = chain.d)
            SELECT 1 FROM chain WHERE d = ?
            """, arguments: [by, retired])
        if cycles != nil { return .refused("supersession would run in a circle") }
        try db.execute(sql: "INSERT INTO supersessions (retired_digest, by_digest, confirmed_at) VALUES (?, ?, ?)",
                       arguments: [retired, by, confirmedAt])
        return .landed
    }

    private func insertDuplicateCandidate(fileID: String, member: CatalogRecordDTO.DuplicateMemberRow) throws -> CatalogRow.RelationLanding {
        guard let confidence = member.confidence, CatalogDDL.Confidence(rawValue: confidence) != nil else {
            return .refused("a duplicate candidate names its confidence (High, Medium or Low)")
        }
        guard CatalogDDL.DuplicateDisposition(rawValue: member.disposition) != nil else {
            return .refused("a duplicate candidate without an election has no member row")
        }
        guard let analyzedAt = member.analyzedAt else { return .refused("a duplicate group carries its analysis date") }
        let group = try Int.fetchOne(db, sql: "SELECT 1 FROM duplicate_groups WHERE group_id = ?", arguments: [member.groupID])
        if group == nil {
            try db.execute(sql: "INSERT INTO duplicate_groups (group_id, analyzed_at) VALUES (?, ?)",
                           arguments: [member.groupID, analyzedAt])
        }
        try db.execute(sql: """
            INSERT INTO duplicate_members (group_id, file_id, confidence, disposition, reasons, best_match)
            VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [member.groupID, fileID, confidence, member.disposition, member.reasons, member.bestMatch])
        return .landed
    }

    private func insertEventMember(eventID: String, digest: String, start: Double?, end: Double?,
                                   key: String) throws -> CatalogRow.RelationLanding {
        let present = try Int.fetchOne(db, sql: """
            SELECT 1 FROM event_members
             WHERE event_id = ? AND digest = ? AND ifnull(range_start_s, -1) = ifnull(?, -1) AND ifnull(range_end_s, -1) = ifnull(?, -1)
            """, arguments: [eventID, digest, start, end])
        if present != nil { return .alreadyPresent }
        try db.execute(sql: """
            INSERT INTO event_members (event_id, digest, range_start_s, range_end_s, imported_key) VALUES (?, ?, ?, ?, ?)
            """, arguments: [eventID, digest, start, end, key])
        return .landed
    }
}

// MARK: - Quarantine and the import map

extension GRDBTransaction {

    func insertQuarantine(_ row: CatalogRow.Quarantine) throws -> Int64 {
        try db.execute(sql: """
            INSERT INTO quarantine (origin, import_run, source_ordinal, json_row_id, full_path, size_bytes, digest,
                                    evidence_digests, sampled_hash, reason_code, words, findings, raw_row,
                                    quarantined_at, generation)
            VALUES ('import', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [row.importRun, row.sourceOrdinal, row.jsonRowID, row.fullPath, row.sizeBytes,
                             row.digest?.lowercased(), GRDBJSONText.strings(row.evidenceDigests.map { $0.lowercased() }),
                             row.sampledHash, row.reasonCode.rawValue, row.words, try GRDBJSONText.findings(row.findings),
                             GRDBJSONText.text(row.rawRow), row.quarantinedAt, generation])
        return db.lastInsertedRowID
    }

    func insertImportRun(_ run: CatalogRow.ImportRun) throws {
        try db.execute(sql: """
            INSERT INTO import_runs (run_id, started_at, source_sha256, source_generation, integrity_run_id,
                                     audit_run_started_at, audit_run_finished_at, audit_generation,
                                     integrity_started_at, integrity_generation)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [run.runID, run.startedAt, run.sourceSHA256.lowercased(), run.sourceGeneration, run.integrityRunID,
                             run.auditRunStartedAt, run.auditRunFinishedAt, run.auditGeneration,
                             run.integrityStartedAt, run.integrityGeneration])
    }

    func finishImportRun(_ runID: String, counters: CatalogRow.ImportCounters, finishedAt: Int64) throws {
        try db.execute(sql: """
            UPDATE import_runs
               SET finished_at = ?, rows_before = ?, rows_main = ?, rows_quarantine = ?, digests_seen = ?,
                   knowledge_rows = ?, comparator_ok = 1
             WHERE run_id = ?
            """, arguments: [finishedAt, counters.rowsBefore, counters.rowsMain, counters.rowsQuarantine,
                             counters.digestsSeen, counters.knowledgeRows, runID])
        guard db.changesCount == 1 else {
            throw DatabaseError(resultCode: .SQLITE_CONSTRAINT, message: "import run \(runID) is not open")
        }
    }

    func insertImportItem(_ item: CatalogRow.ImportItem) throws {
        try db.execute(sql: """
            INSERT INTO import_items (import_run, source_file, source_ordinal, item_kind, source_key, curated_fields,
                                      landed_table, landed_ref)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [item.importRun, item.sourceFile.rawValue, item.sourceOrdinal, item.itemKind.rawValue,
                             item.sourceKey, GRDBJSONText.strings(item.curatedFields.map(\.rawValue)),
                             item.landedTable.rawValue, item.landedRef])
    }
}

// MARK: - Sidecars

extension GRDBTransaction {

    func insertEvent(_ event: CatalogRow.Event) throws {
        try db.execute(sql: """
            INSERT INTO events (event_id, name, state, categories, note, created_at, updated_at, import_run, source_ordinal)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [event.eventID, event.name, event.state, GRDBJSONText.strings(event.categories), event.note,
                             event.createdAt, event.updatedAt, event.importRun, event.sourceOrdinal])
    }

    func insertEventDecision(_ decision: CatalogRow.EventDecision) throws {
        try db.execute(sql: """
            INSERT INTO event_decisions (kind, payload, import_run, source_ordinal) VALUES (?, ?, ?, ?)
            """, arguments: [decision.kind, GRDBJSONText.text(decision.payload), decision.importRun, decision.sourceOrdinal])
    }

    func insertIgnored(_ entry: CatalogRow.Ignored) throws {
        try db.execute(sql: """
            INSERT INTO ignored_content (entry_id, import_run, source_ordinal, partial_md5, size_bytes, filename, reason,
                                         added_at, sample_path, digest, binding)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [entry.entryID, entry.importRun, entry.sourceOrdinal, entry.partialMD5, entry.sizeBytes,
                             entry.filename, entry.reason, entry.addedAt, entry.samplePath, entry.digest?.lowercased(),
                             entry.binding.rawValue])
    }

    func insertLedgerLine(_ line: CatalogRow.Ledger) throws {
        try db.execute(sql: """
            INSERT INTO ledger (at, generation, kind, actor, record_id, content_key, digest, path, payload, imported,
                                import_run, source_ordinal)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
            """, arguments: [line.at, generation, line.kind, line.actor, line.recordID, line.contentKey,
                             line.digest?.lowercased(), line.path, GRDBJSONText.text(line.payload),
                             line.importRun, line.sourceOrdinal])
    }

    func insertJobMarker(_ marker: CatalogRow.JobMarker) throws {
        try db.execute(sql: """
            INSERT INTO job_markers (job, scope, started_at, finished_at, outcome, generation, detail,
                                     import_run, source_file, source_ordinal)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [marker.job.rawValue, marker.scope, marker.startedAt, marker.finishedAt, marker.outcome?.rawValue,
                             marker.generation, GRDBJSONText.text(marker.detail), marker.importRun,
                             marker.sourceFile.rawValue, marker.sourceOrdinal])
    }

    func appendAuditResult(_ result: CatalogRow.AuditResult) throws {
        try db.execute(sql: """
            INSERT INTO audit_results (import_run, source_ordinal, json_row_id, result, detail, judged_path,
                                       row_full_path, row_audit_seen_at, accepted)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [result.importRun, result.sourceOrdinal, result.jsonRowID, result.result.rawValue,
                             GRDBJSONText.text(result.detail), result.judgedPath, result.rowFullPath,
                             result.rowAuditSeenAt, result.accepted ? 1 : 0])
    }

    func insertPersonSearch(_ search: CatalogRow.PersonSearch) throws {
        try db.execute(sql: """
            INSERT INTO person_searches (digest, person_id, person_name, searched_at, engine, threshold, hits, outcome,
                                         source_json_row_id, provenance, source_key, import_run, source_ordinal)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [search.digest?.lowercased(), search.personID, search.personName, search.searchedAt, search.engine,
                             search.threshold, search.hits, search.outcome.rawValue, search.sourceJSONRowID,
                             search.provenance.rawValue, GRDBJSONText.text(search.sourceKey), search.importRun,
                             search.sourceOrdinal])
    }
}
