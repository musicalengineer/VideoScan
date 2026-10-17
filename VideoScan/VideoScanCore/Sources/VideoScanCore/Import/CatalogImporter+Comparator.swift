// CatalogImporter+Comparator.swift
// The comparator pass (contract §f "Comparator"): still inside the import
// transaction, the JSON side is built by RE-READING AND RE-DECODING every
// input file by its own path (never from the DTOs the row pass built; the
// frozen catalog's hash is checked again before this decode), the SQLite
// side is read back through the transaction's readings, and
// `ImportComparator.compare` judges rows, not counters. `.ok` lets the
// run finish and commit; `.misses` throws `ImportAbort.rolledBack` with
// every miss named, and the store rolls everything back.
//
// CatalogImporterSensorTests pins that `jsonSide` reads `inputs.catalogURL`
// and that the row pass's DTOs are not reachable from here.
//
// (For Rick: two snapshots built from scratch and diffed; the first decode
// is long gone by the time this runs.)

import Foundation

extension ImportPlan {

    func comparatorPass(_ tx: any CatalogTransaction) throws {
        let json = try jsonSide()
        var sqlite = try sqliteSide(tx)
        seam?(&sqlite)
        if case .misses(let misses) = ImportComparator.compare(json: json, sqlite: sqlite) {
            throw ImportAbort.rolledBack(misses)
        }
    }

    // MARK: - JSON side: decode #2, from the files

    /// The catalog is read from `inputs.catalogURL` and hashed against the
    /// gate's hash before it is decoded; the sidecars were decoded once at
    /// the gate from their own bytes and are reused as values (they are not
    /// mapped into DTOs anywhere, so there is nothing to be independent of).
    func jsonSide() throws -> ImportComparator.JSONSide {
        let catalog = try decodeCatalog()
        let rows = ImportComparator.JSONSide.occurrences(from: catalog)
        var pathsByID: [String: (path: String, seenAt: Int64?)] = [:]
        for record in catalog.records {
            let id = CatalogRecordDTO.canonicalID(record.id)
            if pathsByID[id] == nil { pathsByID[id] = (record.fullPath ?? "", record.auditSeenOn?.seenAt.unixSeconds) }
        }
        let eventCount = gate.events?.events.count ?? 0
        let members = (gate.events?.foldedMembers() ?? []).map { ImportComparator.EventMember(eventID: $0.eventID, key: $0.contentKey) }
        var markers = [ImportComparator.MarkerKey(sourceFile: .catalogAudit, ordinal: 0)]
        if gate.backfill != nil { markers.append(ImportComparator.MarkerKey(sourceFile: .fullHashBackfill, ordinal: 0)) }
        var auditResults: [ImportComparator.AuditResultOccurrence] = []
        for (index, row) in (audit.rows ?? []).enumerated() {
            guard let result = CatalogDDL.AuditResult(rawValue: row.result) else { continue }
            let facts = pathsByID[CatalogRecordDTO.canonicalID(row.id)]
            auditResults.append(ImportComparator.AuditResultOccurrence(
                ordinal: 1 + index, evidence: ImportGate.AuditEvidence(result: result, judgedPath: row.judgedPath),
                rowFullPath: facts?.path ?? "", rowAuditSeenAt: facts?.seenAt))
        }
        return ImportComparator.JSONSide(
            rows: rows,
            eventDecisionOrdinals: (gate.events?.decisions ?? []).indices.map { eventCount + $0 },
            eventMembers: members,
            ledgerOrdinals: (gate.ledger?.lines ?? []).map(\.ordinal),
            ignoredOrdinals: Array((gate.ignored?.entries ?? []).indices),
            markers: markers, auditResults: auditResults, auditWindow: audit.window, personSearchOrdinals: [])
    }

    // MARK: - SQLite side: the readings, through the transaction

    func sqliteSide(_ tx: any CatalogTransaction) throws -> ImportComparator.SQLiteSide {
        var side = ImportComparator.SQLiteSide(fileLandings: [], quarantineOrdinals: [], contentDigests: [])
        try tx.rowLandings(run: runID) { landing in
            switch landing.landedTable {
            case .files: side.fileLandings.append(ImportComparator.FileLanding(ordinal: landing.ordinal, fileID: landing.landedRef))
            case .quarantine: side.quarantineOrdinals.append(landing.ordinal)
            case .events, .eventDecisions, .ignoredContent, .ledger, .jobMarkers, .auditResults, .personSearches: break
            }
        }
        try tx.quarantineRawRows(run: runID) { side.quarantineRawRows[$0] = $1 }
        try tx.contentDigests { side.contentDigests.insert($0) }
        try tx.knowledgeSources(run: runID) {
            side.knowledgeSources.append(ImportComparator.KnowledgeKey(ordinal: $0.ordinal, field: $0.field, valueJSON: $0.value))
        }
        try tx.derivedUnverifiedKeys(run: runID) {
            side.derivedUnverified.insert(ImportComparator.DerivedKey(digest: $0.digest, kind: $0.kind, seq: $0.seq,
                                                                      sourceJSONRowID: $0.sourceJSONRowID))
        }
        try tx.soundPrintDigests { side.soundPrintDigests.insert($0) }
        try tx.eventDecisionOrdinals(run: runID) { side.eventDecisionOrdinals.insert($0) }
        try tx.eventMembers { side.eventMembers.insert(ImportComparator.EventMember(eventID: $0.eventID, key: $0.importedKey)) }
        try tx.listedMemberKeys(run: runID) { side.listedMemberKeys.insert($0) }
        try tx.ledgerOrdinals(run: runID) { side.ledgerOrdinals.insert($0) }
        try tx.ignoredOrdinals(run: runID) { side.ignoredOrdinals.insert($0) }
        try tx.jobMarkers(run: runID) { side.markers.insert(ImportComparator.MarkerKey(sourceFile: $0.sourceFile, ordinal: $0.ordinal)) }
        try tx.auditResults(run: runID) { side.auditResults[$0.ordinal] = $0.accepted }
        try tx.personSearchOrdinals(run: runID) { side.personSearchOrdinals.insert($0) }
        return side
    }
}
