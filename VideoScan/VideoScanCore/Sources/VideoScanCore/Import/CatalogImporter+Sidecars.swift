// CatalogImporter+Sidecars.swift
// The sidecar pass of the import (contract §f, §c): every occurrence in
// every other input file lands in its table and in `import_items`:
//   * events-decisions.json → `events` (each record), `event_decisions`
//     (the stream verbatim, every kind), `event_members` (the fold, keys
//     resolved to digests through the row index); a key that does not
//     resolve stays in the stream and is listed against its row;
//   * ignored-content.json → `ignored_content`, `unbound` (F7: a sampled
//     key never binds);
//   * media-ledger.jsonl → `ledger`, the line verbatim, its digest through
//     the record id's JSON digest only (F7); a torn last line as an
//     `unparseable` row with its bytes (codex D′ #5);
//   * catalog-audit.json → one `job_markers` row (the file body without its
//     per-row results, which are `audit_results`, one per row, `accepted`
//     by the N1 rule, plus the hash of the whole file and the row count) and
//     fullhash-backfill.json → one `job_markers` row (body + file hash).
//
// Every row is built by the ONE mapping on its JSON mirror
// (`row(ordinal:run:)`, codex D′ #3) that the comparator also uses on its
// own re-decode, so the comparator compares whole rows.
//
// Source ordinals, one numbering per source file (the import_items key):
//   events-decisions.json: events 0..<E, then decisions E..<E+D;
//   catalog-audit.json:    the marker 0, then row i at 1 + i.
//
// (For Rick: four short loops over small files; the only logic is the
// member-key resolution, and that lives in ImportRowIndex.swift.)

import Foundation

struct ImportSidecarPass: Sendable {
    var membersListed = 0
}

extension ImportPlan {

    func sidecarPass(_ tx: any CatalogTransaction, _ rows: ImportRowPass) throws -> ImportSidecarPass {
        var pass = ImportSidecarPass()
        if let events = gate.events { pass.membersListed = try writeEvents(tx, events, rows.index) }
        if let ignored = gate.ignored { try writeIgnored(tx, ignored) }
        if let ledger = gate.ledger { try writeLedger(tx, ledger, rows.index) }
        try writeAuditMarker(tx, rows.index)
        if let backfill = gate.backfill { try writeBackfillMarker(tx, backfill) }
        sink("sidecars: events \(gate.events?.events.count ?? 0) (\(gate.events?.decisions.count ?? 0) decisions, "
             + "\(pass.membersListed) member keys listed) · ignored \(gate.ignored?.entries.count ?? 0) · "
             + "ledger lines \(gate.ledger?.lines.count ?? 0) (\(gate.ledger?.trailingPartialOrdinal == nil ? 0 : 1) torn at the end) · "
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
    private func writeEvents(_ tx: any CatalogTransaction, _ events: EventsDecisionsJSON, _ index: ImportRowIndex) throws -> Int {
        for (ordinal, event) in events.events.enumerated() {
            let row = event.row(ordinal: ordinal, run: runID)
            try tx.insertEvent(row)
            try tx.insertImportItem(item(.eventsDecisions, ordinal, .event, key: event.id, table: .events, ref: row.eventID))
        }
        for (i, decision) in events.decisions.enumerated() {
            let ordinal = events.decisionOrdinal(i)
            try tx.insertEventDecision(decision.row(ordinal: ordinal, run: runID))
            try tx.insertImportItem(item(.eventsDecisions, ordinal, .eventDecision, key: decision.kind, table: .eventDecisions))
        }
        let known = events.knownEventIDs
        var listed = 0
        for member in events.foldedMembers() {
            guard let resolved = MemberKeyResolution.resolve(member, index: index, knownEvents: known) else {
                listed += 1
                continue
            }
            for row in resolved {
                _ = try tx.insertRelation(.eventMembership(eventID: row.eventID, digest: row.digest, rangeStart: row.rangeStart,
                                                           rangeEnd: row.rangeEnd, importedKey: member.contentKey))
            }
        }
        return listed
    }

    // MARK: Ignored

    private func writeIgnored(_ tx: any CatalogTransaction, _ ignored: IgnoredContentJSON) throws {
        for (ordinal, entry) in ignored.entries.enumerated() {
            try tx.insertIgnored(entry.row(ordinal: ordinal, run: runID))
            try tx.insertImportItem(item(.ignoredContent, ordinal, .ignored, key: entry.id, table: .ignoredContent))
        }
    }

    // MARK: Ledger

    private func writeLedger(_ tx: any CatalogTransaction, _ ledger: LedgerLinesJSON, _ index: ImportRowIndex) throws {
        for line in ledger.lines {
            try tx.insertLedgerLine(line.row(run: runID, index: index))
            try tx.insertImportItem(item(.mediaLedger, line.ordinal, .ledgerLine, key: line.recordID, table: .ledger))
        }
    }

    // MARK: Markers and audit results

    private func writeAuditMarker(_ tx: any CatalogTransaction, _ index: ImportRowIndex) throws {
        try tx.insertJobMarker(CatalogRow.JobMarker(
            job: .audit, scope: "*", startedAt: audit.startedAt.unixSeconds, finishedAt: audit.finishedAt?.unixSeconds,
            outcome: CatalogDDL.JobOutcome(rawValue: audit.outcome), generation: audit.savedGeneration ?? gate.catalogGeneration,
            detail: audit.markerDetail(fileSHA256: gate.sidecarSHA256[.catalogAudit] ?? ""), importRun: runID,
            sourceFile: .catalogAudit, sourceOrdinal: 0))
        try tx.insertImportItem(item(.catalogAudit, 0, .marker, key: nil, table: .jobMarkers))
        for (i, row) in (audit.rows ?? []).enumerated() {
            let ordinal = AuditMarkerJSON.rowOrdinal(i)
            try tx.appendAuditResult(try row.auditResultRow(ordinal: ordinal, run: runID, index: index, window: audit.window))
            try tx.insertImportItem(item(.catalogAudit, ordinal, .auditResult, key: row.id, table: .auditResults))
        }
    }

    private func writeBackfillMarker(_ tx: any CatalogTransaction, _ backfill: BackfillMarkerJSON) throws {
        try tx.insertJobMarker(CatalogRow.JobMarker(
            job: .fullHash, scope: "*", startedAt: backfill.startedAt.unixSeconds, finishedAt: backfill.finishedAt?.unixSeconds,
            outcome: backfill.finishedAt == nil ? nil : .completed, generation: gate.catalogGeneration,
            detail: backfill.markerDetail(fileSHA256: gate.sidecarSHA256[.fullHashBackfill] ?? ""), importRun: runID,
            sourceFile: .fullHashBackfill, sourceOrdinal: 0))
        try tx.insertImportItem(item(.fullHashBackfill, 0, .marker, key: nil, table: .jobMarkers))
    }
}
