// CatalogImporter+Sidecars.swift
// The sidecar pass of the import (contract §f, §c): every occurrence in
// every other input file lands in its table and in `import_items`:
//   * events-decisions.json → `events` (each record), `event_decisions`
//     (the stream verbatim, every kind), `event_members` (the fold, keys
//     resolved to digests through the row facts); a key that does not
//     resolve stays in the stream and is listed against its row;
//   * ignored-content.json → `ignored_content`, `unbound` (F7: a sampled
//     key never binds);
//   * media-ledger.jsonl → `ledger`, the line verbatim, its digest through
//     the record id's JSON digest only (F7);
//   * catalog-audit.json → one `job_markers` row (the file body without its
//     per-row results, which are `audit_results`, one per row, `accepted`
//     by the N1 rule) and fullhash-backfill.json → one `job_markers` row.
//
// Source ordinals, one numbering per source file (the import_items key):
//   events-decisions.json: events 0..<E, then decisions E..<E+D;
//   catalog-audit.json:    the marker 0, then row i at 1 + i.
//
// (For Rick: four short loops over small files; the only logic is the
// member-key resolution.)

import Foundation

struct ImportSidecarPass: Sendable {
    var membersListed = 0
}

extension ImportPlan {

    func sidecarPass(_ tx: any CatalogTransaction, _ rows: ImportRowPass) throws -> ImportSidecarPass {
        var pass = ImportSidecarPass()
        if let events = gate.events { pass.membersListed = try writeEvents(tx, events, rows) }
        if let ignored = gate.ignored { try writeIgnored(tx, ignored) }
        if let ledger = gate.ledger { try writeLedger(tx, ledger, rows) }
        try writeAuditMarker(tx, rows)
        if let backfill = gate.backfill { try writeBackfillMarker(tx, backfill) }
        sink("sidecars: events \(gate.events?.events.count ?? 0) (\(gate.events?.decisions.count ?? 0) decisions, "
             + "\(pass.membersListed) member keys listed) · ignored \(gate.ignored?.entries.count ?? 0) · "
             + "ledger lines \(gate.ledger?.lines.count ?? 0) (\(gate.ledger?.unparseable.count ?? 0) unparseable) · "
             + "audit results \(audit.rows?.count ?? 0) · backfill marker \(gate.backfill == nil ? "absent" : "present")")
        return pass
    }

    private func item(_ file: CatalogDDL.ImportSourceFile, _ ordinal: Int, _ kind: CatalogDDL.ImportItemKind,
                      key: String?, table: CatalogDDL.LandedTable, ref: String = "") -> CatalogRow.ImportItem {
        CatalogRow.ImportItem(importRun: runID, sourceFile: file, sourceOrdinal: ordinal, itemKind: kind, sourceKey: key,
                              landedTable: table, landedRef: ref)
    }

    // MARK: Events

    /// Returns how many member keys were listed rather than resolved.
    private func writeEvents(_ tx: any CatalogTransaction, _ events: EventsDecisionsJSON, _ rows: ImportRowPass) throws -> Int {
        var known: Set<String> = []
        for (ordinal, event) in events.events.enumerated() {
            let id = CatalogRecordDTO.canonicalID(event.id)
            known.insert(id)
            // `created_at` / `updated_at` are NOT NULL; the app always writes
            // them. 0 marks a record that arrived without one — never "now".
            try tx.insertEvent(CatalogRow.Event(
                eventID: id, name: event.name, state: event.state ?? "confirmed", categories: event.categories ?? [],
                note: event.note, createdAt: event.createdAt?.unixSeconds ?? 0,
                updatedAt: event.updatedAt?.unixSeconds ?? event.createdAt?.unixSeconds ?? 0,
                importRun: runID, sourceOrdinal: ordinal))
            try tx.insertImportItem(item(.eventsDecisions, ordinal, .event, key: event.id, table: .events, ref: id))
        }
        let offset = events.events.count
        for (index, decision) in events.decisions.enumerated() {
            try tx.insertEventDecision(CatalogRow.EventDecision(kind: decision.kind, payload: decision.payload,
                                                                 importRun: runID, sourceOrdinal: offset + index))
            try tx.insertImportItem(item(.eventsDecisions, offset + index, .eventDecision, key: decision.kind, table: .eventDecisions))
        }
        var listed = 0
        for member in events.foldedMembers() {
            let resolved = try writeMember(tx, member, rows, known: known)
            if !resolved { listed += 1 }
        }
        return listed
    }

    /// A member key resolves to the digests of the rows it names (§f: a
    /// digest, both halves of a pair, one row). Resolved = every digest it
    /// names is known and its event exists; otherwise it is listed.
    private func writeMember(_ tx: any CatalogTransaction, _ member: EventsDecisionsJSON.Member, _ rows: ImportRowPass,
                             known: Set<String>) throws -> Bool {
        let digests = MemberKeyResolution.digests(for: member.contentKey, rows: rows)
        guard known.contains(member.eventID), digests.complete, !digests.found.isEmpty else { return false }
        for digest in digests.found {
            _ = try tx.insertRelation(.eventMembership(eventID: member.eventID, digest: digest, rangeStart: member.start,
                                                       rangeEnd: member.end, importedKey: member.contentKey))
        }
        return true
    }

    // MARK: Ignored

    private func writeIgnored(_ tx: any CatalogTransaction, _ ignored: IgnoredContentJSON) throws {
        for (ordinal, entry) in ignored.entries.enumerated() {
            try tx.insertIgnored(CatalogRow.Ignored(
                entryID: CatalogRecordDTO.canonicalID(entry.id), importRun: runID, sourceOrdinal: ordinal,
                partialMD5: entry.partialMD5 ?? "", sizeBytes: entry.sizeBytes ?? 0, filename: entry.filename ?? "",
                reason: entry.reason ?? "", addedAt: entry.addedAt?.unixSeconds ?? 0, samplePath: entry.samplePath ?? ""))
            try tx.insertImportItem(item(.ignoredContent, ordinal, .ignored, key: entry.id, table: .ignoredContent))
        }
    }

    // MARK: Ledger

    private func writeLedger(_ tx: any CatalogTransaction, _ ledger: LedgerLinesJSON, _ rows: ImportRowPass) throws {
        for line in ledger.lines {
            try tx.insertLedgerLine(CatalogRow.Ledger(
                at: line.at ?? 0, kind: line.event, actor: line.actor, recordID: line.recordID, contentKey: line.contentKey,
                digest: rows.facts[line.recordID]?.digest, path: line.fullPath, payload: .object(line.payload),
                importRun: runID, sourceOrdinal: line.ordinal))
            try tx.insertImportItem(item(.mediaLedger, line.ordinal, .ledgerLine, key: line.recordID, table: .ledger))
        }
    }

    // MARK: Markers and audit results

    private func writeAuditMarker(_ tx: any CatalogTransaction, _ rows: ImportRowPass) throws {
        var body = (try? CatalogJSONValue.of(audit).objectValue) ?? [:]
        body.removeValue(forKey: "rows")                        // the rows are audit_results
        try tx.insertJobMarker(CatalogRow.JobMarker(
            job: .audit, scope: "*", startedAt: audit.startedAt.unixSeconds, finishedAt: audit.finishedAt?.unixSeconds,
            outcome: CatalogDDL.JobOutcome(rawValue: audit.outcome), generation: audit.savedGeneration ?? gate.catalogGeneration,
            detail: .object(body), importRun: runID, sourceFile: .catalogAudit, sourceOrdinal: 0))
        try tx.insertImportItem(item(.catalogAudit, 0, .marker, key: nil, table: .jobMarkers))
        for (index, row) in (audit.rows ?? []).enumerated() {
            guard let result = CatalogDDL.AuditResult(rawValue: row.result) else { continue }   // a word outside the six: no result
            let ordinal = 1 + index
            let id = CatalogRecordDTO.canonicalID(row.id)
            let facts = rows.facts[id]
            let evidence = ImportGate.AuditEvidence(result: result, judgedPath: row.judgedPath)
            try tx.appendAuditResult(CatalogRow.AuditResult(
                importRun: runID, sourceOrdinal: ordinal, jsonRowID: id, result: result,
                detail: .object(row.detail.map { ["detail": .string($0)] } ?? [:]), judgedPath: row.judgedPath,
                rowFullPath: facts?.fullPath ?? "", rowAuditSeenAt: facts?.auditSeenAt,
                accepted: ImportGate.accepts(evidence, rowFullPath: facts?.fullPath ?? "", rowAuditSeenAt: facts?.auditSeenAt,
                                             window: audit.window)))
            try tx.insertImportItem(item(.catalogAudit, ordinal, .auditResult, key: row.id, table: .auditResults))
        }
    }

    private func writeBackfillMarker(_ tx: any CatalogTransaction, _ backfill: BackfillMarkerJSON) throws {
        try tx.insertJobMarker(CatalogRow.JobMarker(
            job: .fullHash, scope: "*", startedAt: backfill.startedAt.unixSeconds, finishedAt: backfill.finishedAt?.unixSeconds,
            outcome: backfill.finishedAt == nil ? nil : .completed, generation: gate.catalogGeneration,
            detail: (try? CatalogJSONValue.of(backfill)) ?? .object([:]), importRun: runID, sourceFile: .fullHashBackfill,
            sourceOrdinal: 0))
        try tx.insertImportItem(item(.fullHashBackfill, 0, .marker, key: nil, table: .jobMarkers))
    }
}

// MARK: - Member key → digests

enum MemberKeyResolution {
    struct Digests: Equatable {
        var found: [String]
        /// False when the key names a row (or a half) whose digest is unknown.
        var complete: Bool
    }

    static func digests(for key: String, rows: ImportRowPass) -> Digests {
        if let group = EventMemberKey.pairGroupID(key) {
            let halves = rows.pairGroups[group] ?? []
            let found = halves.compactMap { rows.facts[$0]?.digest }
            return Digests(found: found, complete: !halves.isEmpty && found.count == halves.count)
        }
        if let rowID = EventMemberKey.rowID(key) {
            let digest = rows.facts[rowID]?.digest
            return Digests(found: digest.map { [$0] } ?? [], complete: digest != nil)
        }
        if let digest = EventMemberKey.digest(key), rows.contentDigests.contains(digest) {
            return Digests(found: [digest], complete: true)
        }
        return Digests(found: [], complete: false)
    }
}
