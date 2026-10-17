// CatalogImporter+Comparator.swift
// The comparator pass (contract §f "Comparator"): still inside the import
// transaction, the JSON side is built by RE-READING AND RE-DECODING every
// input file by its own path (never from the DTOs the row pass built; the
// frozen catalog's hash is checked again before this decode, and — fix
// 2026-10-17, codex D′ #3 — so is every sidecar's), the SQLite side is read
// back through the transaction's readings, and `ImportComparator.compare`
// judges rows, not counters. `.ok` lets the run finish and commit; `.misses`
// throws `ImportAbort.rolledBack` with every miss named, and the store rolls
// everything back.
//
// Independence (codex D′ #1/#3): the JSON side's expected landings come from
// the gate's pure rules on the re-decoded rows; the expected sidecar ROWS
// come from the same pure mappings on the re-decoded sidecars; the row index
// behind member keys, ledger digests and audit stamps is rebuilt here by the
// one `record` rule. Nothing the row pass computed is reachable.
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
    /// gate's hash before it is decoded; every sidecar is re-read, re-hashed
    /// against the gate's hash and re-decoded (`rereadSidecars`).
    func jsonSide() throws -> ImportComparator.JSONSide {
        let catalog = try decodeCatalog()
        var rows = ImportComparator.JSONSide.occurrences(from: catalog)
        let files = try rereadSidecars()
        let marker = files.audit ?? audit
        ImportComparator.JSONSide.expectLandings(&rows, evidence: marker.evidenceByID(), window: marker.window,
                                                 findings: files.report.findingsByRecord())
        let index = Self.index(of: rows)
        var side = ImportComparator.JSONSide(rows: rows)
        if let events = files.events {
            side.events = events.events.enumerated().map { $1.row(ordinal: $0, run: runID) }
            side.eventDecisions = events.decisions.enumerated().map { $1.row(ordinal: events.decisionOrdinal($0), run: runID) }
            let known = events.knownEventIDs
            for member in events.foldedMembers() {
                if let resolved = MemberKeyResolution.resolve(member, index: index, knownEvents: known) {
                    side.resolvedMembers.formUnion(resolved)
                } else {
                    side.listedMembers.append(ImportComparator.EventMember(eventID: member.eventID, key: member.contentKey))
                }
            }
        }
        side.ledgerLines = (files.ledger?.lines ?? []).map { $0.row(run: runID, index: index) }
        side.ignoredEntries = (files.ignored?.entries ?? []).enumerated().map { $1.row(ordinal: $0, run: runID) }
        side.markers = [ImportComparator.MarkerKey(sourceFile: .catalogAudit, ordinal: 0, fileSHA256: files.hashes[.catalogAudit])]
        if files.backfill != nil {
            side.markers.append(ImportComparator.MarkerKey(sourceFile: .fullHashBackfill, ordinal: 0, fileSHA256: files.hashes[.fullHashBackfill]))
        }
        side.auditResults = try (marker.rows ?? []).enumerated().map {
            try $1.auditResultRow(ordinal: AuditMarkerJSON.rowOrdinal($0), run: runID, index: index, window: marker.window)
        }
        return side
    }

    /// Every sidecar read again from its own path and decoded again (codex D′ #3).
    struct SidecarReread {
        var report: IntegrityReportJSON
        var audit: AuditMarkerJSON?
        var events: EventsDecisionsJSON?
        var ignored: IgnoredContentJSON?
        var ledger: LedgerLinesJSON?
        var backfill: BackfillMarkerJSON?
        var hashes: [CatalogDDL.ImportSourceFile: String] = [:]
    }

    /// Each file's bytes must hash to what the gate saw (a sidecar that
    /// changes under the import, appears, or disappears is refused by name);
    /// then each is decoded afresh.
    func rereadSidecars() throws -> SidecarReread {
        var files = SidecarReread(report: try IntegrityReportJSON.decode(
            try frozenBytes(inputs.integrityURL, name: CatalogImporter.Inputs.integrityFileName, expected: gate.integritySHA256)))
        func reread<T>(_ url: URL?, _ file: CatalogDDL.ImportSourceFile, _ decode: (Data) throws -> T) throws -> T? {
            let expected = gate.sidecarSHA256[file]
            guard let url, FileManager.default.fileExists(atPath: url.path) else {
                if let expected { throw ImportAbort.refused([.fileChangedDuringImport(file: file.rawValue, before: expected, after: nil)]) }
                return nil
            }
            let data = try frozenBytes(url, name: file.rawValue, expected: expected ?? "absent")
            files.hashes[file] = ImportGateFiles.sha256(of: data)
            return try ImportGateFiles.GateReader.decode(data, file.rawValue, decode)
        }
        files.audit = try reread(inputs.auditURL, .catalogAudit, AuditMarkerJSON.decode)
        files.events = try reread(inputs.eventsURL, .eventsDecisions, EventsDecisionsJSON.decode)
        files.ignored = try reread(inputs.ignoredURL, .ignoredContent, IgnoredContentJSON.decode)
        files.ledger = try reread(inputs.ledgerURL, .mediaLedger) { LedgerLinesJSON.decode($0) }
        files.backfill = try reread(inputs.backfillURL, .fullHashBackfill, BackfillMarkerJSON.decode)
        return files
    }

    /// The file's bytes now, refused unless they hash to `expected`.
    private func frozenBytes(_ url: URL, name: String, expected: String) throws -> Data {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ImportFailure(words: "\(name) could not be read again: \(error.localizedDescription)")
        }
        let now = ImportGateFiles.sha256(of: data)
        guard now == expected else {
            throw ImportAbort.refused([.fileChangedDuringImport(file: name, before: expected, after: now)])
        }
        return data
    }

    /// The row index as the comparator derives it from ITS decode, by the
    /// same `record` rule the row pass used (ImportRowIndex.swift).
    static func index(of rows: [ImportComparator.RowOccurrence]) -> ImportRowIndex {
        var index = ImportRowIndex()
        for row in rows {
            index.record(id: row.jsonRowID, digest: row.boundDigest, fileID: row.expected?.table == .files ? row.jsonRowID : nil,
                         fullPath: row.gate?.fullPath ?? "", auditSeenAt: row.gate?.auditSeenAt,
                         pairGroupID: row.gate?.pairGroupID, reason: row.expected?.reason)
        }
        return index
    }

    // MARK: - SQLite side: the readings, through the transaction

    func sqliteSide(_ tx: any CatalogTransaction) throws -> ImportComparator.SQLiteSide {
        var side = ImportComparator.SQLiteSide(fileLandings: [], contentDigests: [])
        try tx.rowLandings(run: runID) { landing in
            switch landing.landedTable {
            case .files:
                side.fileLandings.append(ImportComparator.FileLanding(ordinal: landing.ordinal, fileID: landing.rowID ?? landing.landedRef,
                                                                      digest: landing.digest))
            case .quarantine:
                side.quarantineLandings.append(ImportComparator.QuarantineLanding(ordinal: landing.ordinal, jsonRowID: landing.rowID ?? "",
                                                                                  digest: landing.digest))
            case .events, .eventDecisions, .ignoredContent, .ledger, .jobMarkers, .auditResults, .personSearches: break
            }
        }
        try tx.quarantineRawRows(run: runID) { side.quarantineRawRows[$0] = $1 }
        try tx.contentDigests { side.contentDigests.insert($0) }
        try tx.knowledgeSources(run: runID) {
            side.knowledgeSources.append(ImportComparator.KnowledgeKey(ordinal: $0.ordinal, field: $0.field, valueJSON: $0.value,
                                                                       jsonRowID: $0.jsonRowID, digest: $0.digest))
        }
        try tx.derivedUnverifiedKeys(run: runID) {
            side.derivedUnverified.insert(ImportComparator.DerivedKey(digest: $0.digest, kind: $0.kind, seq: $0.seq,
                                                                      sourceJSONRowID: $0.sourceJSONRowID))
        }
        try tx.soundPrintDigests { side.soundPrintDigests.insert($0) }
        try tx.events(run: runID) { side.events.append($0) }
        try tx.eventDecisions(run: runID) { side.eventDecisions.append($0) }
        try tx.eventMembers {
            side.eventMembers.insert(ImportComparator.ResolvedMember(eventID: $0.eventID, digest: $0.digest,
                                                                     rangeStart: $0.rangeStart, rangeEnd: $0.rangeEnd))
        }
        try tx.listedMemberKeys(run: runID) { side.listedMemberKeys.insert($0) }
        try tx.ledgerLines(run: runID) { side.ledgerLines.append($0) }
        try tx.ignoredEntries(run: runID) { side.ignoredEntries.append($0) }
        try tx.jobMarkers(run: runID) {
            side.markers.insert(ImportComparator.MarkerKey(sourceFile: $0.sourceFile, ordinal: $0.ordinal, fileSHA256: $0.fileSHA256))
        }
        try tx.auditResults(run: runID) { side.auditResults.append($0) }
        try tx.personSearchOrdinals(run: runID) { side.personSearchOrdinals.insert($0) }
        return side
    }
}
