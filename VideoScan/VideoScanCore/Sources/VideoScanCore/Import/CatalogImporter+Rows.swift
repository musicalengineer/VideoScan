// CatalogImporter+Rows.swift
// The row pass of the import (contract §f "What every occurrence writes"):
// for every catalog.json occurrence in file order, the gate decides
// (ImportGate.decide), the preflight says whether the DDL can hold the row
// as-is (RowPreflight, codex D′ #6), the occurrence lands in `files`
// (+ `content`, `volumes`, archive copy, backups) or in `quarantine` (the
// whole row verbatim, its findings, its words), and in BOTH cases every
// curated value becomes a `knowledge_sources` row, every derived value a
// `derived_unverified` row when the row has a digest, plus `regen_context`
// and `legacy_pair_ids`, and one `import_items` row names the landing.
//
// An UNREPRESENTABLE occurrence (a row-local CHECK would refuse it) lands in
// quarantine with the check's words and writes only its knowledge rows
// (digest NULL — the DDL's finish trigger requires one per curated field
// listed, and §10b says curated values survive): no content, no derived,
// no relation, no pair group. The rest of the catalog imports.
//
// Relations whose other end may come LATER in the file (lineage,
// supersession, archive-copy source, footage decisions, duplicate groups)
// are deferred to `relationPass`, which runs after every row is in.
//
// What is kept per row after the pass (`ImportRowIndex`, ≈ 250 bytes): the
// digest, the files.id when it landed in files, the path and audit stamp
// (for the audit results), the pair group. The decoded catalog itself is
// released when `rowPass` returns.
//
// (For Rick: one loop, one `switch` on the gate's verdict, the rest is
// straight-line INSERTs through the transaction's doors.)

import Foundation

/// A relation the row pass found and the relation pass writes.
enum DeferredRelation: Sendable {
    case archiveCopy(fileID: String, copy: CatalogRecordDTO.ArchiveCopyRow)
    case duplicateCandidate(fileID: String, member: CatalogRecordDTO.DuplicateMemberRow)
    case lineage(ordinal: Int, childRowID: String, childDigest: String?, value: CatalogRecordDTO.LineageValue, coveredByArchiveCopy: Bool)
    case supersession(ordinal: Int, childRowID: String, childDigest: String?, byRowID: String, confirmedAt: Int64?)
    case footage(ordinal: Int, digest: String?, decisions: [CatalogRecordDTO.FootageDecisionRow])
}

/// The row pass's result: the index of facts by canonical row id, the
/// digests and volumes written, the deferred relations.
struct ImportRowPass: Sendable {
    var index = ImportRowIndex()
    var contentWritten: Set<String> = []
    var volumes: Set<String> = []
    var deferred: [DeferredRelation] = []
    var mainCount = 0
    var quarantineByReason: [String: Int] = [:]
    var derivedSkipped = 0
}

extension ImportPlan {

    /// Decode #1. The catalog is a local of this function: released on return.
    func rowPass(_ tx: any CatalogTransaction) throws -> ImportRowPass {
        let catalog = try decodeCatalog()
        var pass = ImportRowPass()
        let occurrences = Self.occurrences(of: catalog)
        let evidence = audit.evidenceByID()
        let findings = gate.report.findingsByRecord()
        let eventKeys = EventKeyIndex(gate.events)
        for (ordinal, record) in catalog.records.enumerated() {
            let dto = CatalogRecordDTO(record: record, migrationLoadedAt: startedAt)
            let input = ImportGate.Input(record: dto, occurrences: occurrences[dto.file.id] ?? 1, audit: evidence[dto.file.id],
                                         auditWindow: audit.window, findings: findings[dto.file.id] ?? [])
            let writer = OccurrenceWriter(plan: self, tx: tx, ordinal: ordinal, dto: dto, rawID: record.id,
                                          landing: ImportGate.decide(input), tier5: ImportGate.tier5Findings(input),
                                          eventKeys: eventKeys)
            do {
                try writer.write(into: &pass)
            } catch let abort as ImportAbort {
                throw abort
            } catch {
                throw ImportFailure(words: "catalog row \(ordinal) (\(dto.file.id)): \(CatalogImporter.words(error))")
            }
        }
        sink("rows \(catalog.records.count): main \(pass.mainCount) · quarantine \(pass.quarantineByReason.values.reduce(0, +)) "
             + "(\(pass.quarantineByReason.keys.sorted().map { "\($0) \(pass.quarantineByReason[$0] ?? 0)" }.joined(separator: ", ")))"
             + (pass.derivedSkipped > 0 ? " · derived values skipped as duplicate keys \(pass.derivedSkipped)" : ""))
        return pass
    }

    /// How many times each canonical id occurs (§f row 1).
    static func occurrences(of catalog: CatalogFileJSON) -> [String: Int] {
        var counts: [String: Int] = [:]
        for record in catalog.records { counts[CatalogRecordDTO.canonicalID(record.id), default: 0] += 1 }
        return counts
    }
}

// MARK: - One occurrence

/// The writes of one catalog.json occurrence, in §f order.
struct OccurrenceWriter {
    let plan: ImportPlan
    let tx: any CatalogTransaction
    let ordinal: Int
    let dto: CatalogRecordDTO
    let rawID: String?
    let landing: ImportGate.Landing
    /// Every tier-5 finding for the record (kept on any quarantine row, F5r3).
    let tier5: [ImportGate.Finding]
    let eventKeys: EventKeyIndex

    private var id: String { dto.file.id }
    private var digest: String? { dto.digestState.digest }

    func write(into pass: inout ImportRowPass) throws {
        if let floor = RowPreflight.quarantineFloor(dto) {
            throw ImportFailure(words: "catalog row \(ordinal): \(floor)")
        }
        let violations = RowPreflight.report(dto).violations(for: landing)     // codex D′ #6: before any insert
        if !violations.isEmpty {
            try writeUnrepresentable(violations, into: &pass)
            return
        }
        try writeContent(into: &pass)
        let landed: (table: CatalogDDL.LandedTable, ref: String, fileID: String?)
        switch landing {
        case .main:
            let fileID = try writeMain(into: &pass)
            pass.mainCount += 1
            landed = (.files, fileID, fileID)
        case .quarantine(let reason, let words, let findings):
            let qid = try writeQuarantine(reason: reason, words: words, findings: findings)
            pass.quarantineByReason[reason.rawValue, default: 0] += 1
            landed = (.quarantine, String(qid), nil)
        }
        try writeKnowledge(digest: digest)
        try writeDerived(into: &pass)
        try tx.insertImportItem(CatalogRow.ImportItem(importRun: plan.runID, sourceFile: .catalog, sourceOrdinal: ordinal,
                                                      itemKind: .row, sourceKey: rawID, curatedFields: dto.curatedFields,
                                                      landedTable: landed.table, landedRef: landed.ref))
        pass.index.record(id: id, digest: digest, fileID: landed.fileID, fullPath: dto.file.fullPath,
                          auditSeenAt: dto.auditStamp?.auditSeenAt, pairGroupID: dto.legacyPairIDs?.pairGroupID,
                          reason: landing.reason)
        deferRelations(fileID: landed.fileID, into: &pass)
    }

    /// codex D′ #6: a row the DDL cannot hold as-is. Quarantine (verbatim,
    /// the gate's tier-5 findings, the checks' words), its knowledge rows
    /// with no digest, the import_items row — nothing else.
    func writeUnrepresentable(_ violations: [String], into pass: inout ImportRowPass) throws {
        let words = RowPreflight.words(gate: landing, violations: violations)
        let qid = try writeQuarantine(reason: .unrepresentable, words: words, findings: tier5)
        pass.quarantineByReason[CatalogDDL.ReasonCode.unrepresentable.rawValue, default: 0] += 1
        try writeKnowledge(digest: nil)
        try tx.insertImportItem(CatalogRow.ImportItem(importRun: plan.runID, sourceFile: .catalog, sourceOrdinal: ordinal,
                                                      itemKind: .row, sourceKey: rawID, curatedFields: dto.curatedFields,
                                                      landedTable: .quarantine, landedRef: String(qid)))
        pass.index.record(id: id, digest: nil, fileID: nil, fullPath: dto.file.fullPath, auditSeenAt: dto.auditStamp?.auditSeenAt,
                          pairGroupID: nil, reason: .unrepresentable)
    }

    /// Every agreeing whole-file digest is a `content` row, whichever table
    /// the occurrence lands in (a quarantined row's knowledge hangs on it).
    private func writeContent(into pass: inout ImportRowPass) throws {
        guard let digest, let content = dto.content, pass.contentWritten.insert(digest).inserted else { return }
        try tx.insertContent(content)
    }

    private func writeMain(into pass: inout ImportRowPass) throws -> String {
        if pass.volumes.insert(dto.volume.volumeUUID).inserted {
            // F12: case sensitivity is read from the VOLUME at scan time; the
            // importer never touches a disk, so the conservative default holds.
            try tx.insertVolume(dto.volume, caseSensitive: false)
        }
        try tx.insertFile(Self.storable(dto.file), volumeCaseSensitive: false)
        for destination in dto.backupDestinations {
            try tx.insertBackupDestination(fileID: id, destination)
        }
        return id
    }

    /// `files` CHECK: an embedded creation date and its source come together.
    /// A row carrying only one keeps it in `probe_extra` under its own key
    /// (verbatim, nothing dropped) and leaves both columns NULL.
    static func storable(_ file: CatalogRecordDTO.FileRow) -> CatalogRecordDTO.FileRow {
        guard (file.embeddedCreatedAt == nil) != (file.embeddedCreatedSource == nil) else { return file }
        var fixed = file
        if let at = file.embeddedCreatedAt { fixed.probeExtra["embeddedCreationDate"] = .string(CatalogJSONDate.format(at)) }
        if let source = file.embeddedCreatedSource { fixed.probeExtra["embeddedCreationSource"] = .string(source) }
        fixed.embeddedCreatedAt = nil
        fixed.embeddedCreatedSource = nil
        return fixed
    }

    private func writeQuarantine(reason: CatalogDDL.ReasonCode, words: String, findings: [ImportGate.Finding]) throws -> Int64 {
        try tx.insertQuarantine(CatalogRow.Quarantine(
            importRun: plan.runID, sourceOrdinal: ordinal, jsonRowID: id, fullPath: dto.file.fullPath,
            sizeBytes: dto.file.sizeBytes, digest: digest, evidenceDigests: evidenceDigests, sampledHash: dto.file.sampledHash,
            reasonCode: reason, words: words, findings: findings, rawRow: dto.raw, quarantinedAt: plan.startedAt))
    }

    /// Every sha256 digest the row carried, agreeing or not (F10).
    private var evidenceDigests: [String] {
        var seen: [String] = []
        for candidate in [dto.contentFixity?.digest, dto.archiveFixity?.digest] {
            guard let hex = candidate?.lowercased(), CatalogRecordDTO.isWholeFileDigest(hex), !seen.contains(hex) else { continue }
            seen.append(hex)
        }
        return seen
    }

    private func writeKnowledge(digest: String?) throws {
        for value in dto.knowledgeSources {
            try tx.insertKnowledgeSource(CatalogRow.KnowledgeSource(importRun: plan.runID, sourceOrdinal: ordinal,
                                                                     jsonRowID: id, digest: digest, value: value))
        }
    }

    /// Derived values need a digest to hang on (§10b: without one they stay
    /// in `raw_row` and the cyclers redo them). A duplicated id's second
    /// occurrence shares every key with the first; the second is skipped
    /// and counted (its values are in its own raw_row).
    private func writeDerived(into pass: inout ImportRowPass) throws {
        for context in dto.regenContext {
            try tx.insertRegenContext(CatalogRow.RegenContext(importRun: plan.runID, sourceOrdinal: ordinal, jsonRowID: id,
                                                               digest: digest, value: context))
        }
        if let pair = dto.legacyPairIDs {
            try tx.insertLegacyPairIDs(CatalogRow.LegacyPairIDs(importRun: plan.runID, sourceOrdinal: ordinal, jsonRowID: id,
                                                                 digest: digest, value: pair,
                                                                 eventMemberKeys: eventKeys.keys(rowID: id, pairGroupID: pair.pairGroupID)))
        }
        guard let digest else { return }
        for value in dto.derivedUnverified {
            let inserted = try tx.insertDerivedUnverified(CatalogRow.DerivedUnverified(
                digest: digest, sourceJSONRowID: id, importRun: plan.runID, sourceOrdinal: ordinal, value: value))
            if !inserted { pass.derivedSkipped += 1 }
        }
        if let print = dto.soundPrint {
            _ = try tx.insertSoundPrint(print)
        }
    }

    private func deferRelations(fileID: String?, into pass: inout ImportRowPass) {
        if let fileID, let copy = dto.archiveCopy { pass.deferred.append(.archiveCopy(fileID: fileID, copy: copy)) }
        if let fileID, let member = dto.duplicateMember { pass.deferred.append(.duplicateCandidate(fileID: fileID, member: member)) }
        if let lineage = dto.curated.lineage {
            pass.deferred.append(.lineage(ordinal: ordinal, childRowID: id, childDigest: digest, value: lineage,
                                          coveredByArchiveCopy: fileID != nil && dto.archiveCopy != nil))
        }
        if let by = dto.curated.supersededByID {
            pass.deferred.append(.supersession(ordinal: ordinal, childRowID: id, childDigest: digest,
                                               byRowID: CatalogRecordDTO.canonicalID(by), confirmedAt: dto.curated.repairConfirmedDate))
        }
        if !dto.curated.footageDecisions.isEmpty {
            pass.deferred.append(.footage(ordinal: ordinal, digest: digest, decisions: dto.curated.footageDecisions))
        }
    }
}

// MARK: - The event member keys that cite a row (F9)

/// `pair:<pairGroupID>` and `id:<recordID>` keys from the decision stream,
/// indexed by the row they name, so `legacy_pair_ids.event_member_keys` can
/// list them at the row (a re-run of Correlate mints new pair ids).
struct EventKeyIndex: Sendable {
    private var byPairGroup: [String: [String]] = [:]
    private var byRowID: [String: [String]] = [:]

    init(_ events: EventsDecisionsJSON?) {
        for decision in events?.decisions ?? [] {
            for key in EventsDecisionsJSON.contentKeys(in: decision.payload) {
                if let group = EventMemberKey.pairGroupID(key) { byPairGroup[group, default: []].append(key) }
                if let row = EventMemberKey.rowID(key) { byRowID[row, default: []].append(key) }
            }
        }
    }

    func keys(rowID: String, pairGroupID: String?) -> [String] {
        var keys = byRowID[rowID] ?? []
        if let group = pairGroupID { keys += byPairGroup[CatalogRecordDTO.canonicalID(group)] ?? [] }
        return keys
    }
}

// MARK: - The relation pass (after every row is in)

extension ImportPlan {

    func relationPass(_ tx: any CatalogTransaction, _ rows: ImportRowPass) throws {
        for relation in rows.deferred {
            switch relation {
            case .archiveCopy(let fileID, let copy):
                let source = copy.sourceRowID.flatMap { rows.index.facts[CatalogRecordDTO.canonicalID($0)]?.fileID }
                try tx.insertArchiveCopy(fileID: fileID, copy, sourceFileID: source == fileID ? nil : source)
            case .duplicateCandidate(let fileID, let member):
                _ = try tx.insertRelation(.duplicateCandidate(fileID: fileID, member: member))   // rebuildable: a refusal is a skip
            case .lineage(let ordinal, let child, let childDigest, let value, let covered):
                try writeLineage(tx, rows, ordinal: ordinal, childRowID: child, childDigest: childDigest, value: value, covered: covered)
            case .supersession(let ordinal, let child, let childDigest, let by, let confirmedAt):
                try writeSupersession(tx, rows, ordinal: ordinal, childRowID: child, childDigest: childDigest, byRowID: by, confirmedAt: confirmedAt)
            case .footage(let ordinal, let digest, let decisions):
                for decision in decisions {
                    let other = rows.index.facts[decision.otherRowID]?.digest
                    _ = try tx.insertRelation(.footageDecision(importRun: runID, sourceOrdinal: ordinal, decision: decision,
                                                               digest: digest, otherDigest: other))
                }
            }
        }
    }

    /// §f: both ends with digests → `lineage`; otherwise `lineage_pending`
    /// by row ids, never dropped. An edge the DDL cannot hold (a refusal in
    /// words) goes to pending too, with the words and the withheld digest in
    /// its payload, so nothing is lost and a person can decide.
    private func writeLineage(_ tx: any CatalogTransaction, _ rows: ImportRowPass, ordinal: Int, childRowID: String,
                              childDigest: String?, value: CatalogRecordDTO.LineageValue, covered: Bool) throws {
        if covered && value.isArchivePromotion { return }            // archive_copies holds it (§e.5)
        let parentRowID = value.derivedFrom.map { CatalogRecordDTO.canonicalID($0) } ?? ""
        let parentDigest = rows.index.facts[parentRowID]?.digest
        var payload = (try? CatalogJSONValue.of(value).objectValue) ?? [:]
        var refusal: String?
        if let childDigest, let parentDigest, !value.isArchivePromotion {
            switch try tx.insertRelation(.lineage(childDigest: childDigest, parentDigest: parentDigest, value: value, recordedAt: nil)) {
            case .landed, .alreadyPresent: return
            case .refused(let words): refusal = words
            }
        } else if value.isArchivePromotion, childDigest != nil, parentDigest != nil {
            refusal = "an archive promotion without an archive fixity on the copy"
        }
        if let refusal {
            payload["refused"] = .string(refusal)
            if let parentDigest { payload["parentDigest"] = .string(parentDigest) }
        }
        _ = try tx.insertRelation(.lineagePending(importRun: runID, sourceOrdinal: ordinal, relation: .derivedFrom,
                                                  childRowID: childRowID, childDigest: childDigest, parentRowID: parentRowID,
                                                  parentDigest: refusal == nil ? parentDigest : nil, payload: .object(payload)))
    }

    private func writeSupersession(_ tx: any CatalogTransaction, _ rows: ImportRowPass, ordinal: Int, childRowID: String,
                                   childDigest: String?, byRowID: String, confirmedAt: Int64?) throws {
        let byDigest = rows.index.facts[byRowID]?.digest
        var payload: [String: CatalogJSONValue] = ["supersededByID": .string(byRowID)]
        if let confirmedAt { payload["repairConfirmedDate"] = .string(CatalogJSONDate.format(confirmedAt)) }
        var refusal: String?
        if let childDigest, let byDigest {
            switch try tx.insertRelation(.supersession(retiredDigest: childDigest, byDigest: byDigest, confirmedAt: confirmedAt)) {
            case .landed, .alreadyPresent: return
            case .refused(let words): refusal = words
            }
        }
        if let refusal {
            payload["refused"] = .string(refusal)
            if let byDigest { payload["parentDigest"] = .string(byDigest) }
        }
        _ = try tx.insertRelation(.lineagePending(importRun: runID, sourceOrdinal: ordinal, relation: .supersededBy,
                                                  childRowID: childRowID, childDigest: childDigest, parentRowID: byRowID,
                                                  parentDigest: refusal == nil ? byDigest : nil, payload: .object(payload)))
    }
}
