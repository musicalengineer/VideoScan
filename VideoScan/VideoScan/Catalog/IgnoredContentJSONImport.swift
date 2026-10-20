// IgnoredContentJSONImport.swift
// The import of ignored-content.json into catalog.sqlite (2026-10-19). The
// cutover import carried the list as it was then (302 entries on Rick's
// catalog); the app kept writing the JSON afterwards (343 on 10/19), so ~41
// of Rick's ignore decisions lived ONLY in the file. The first launch of a
// build whose list lives in catalog.sqlite imports what the file holds then.
// After that the file is frozen history — left in place, never written
// again (like catalog.json and events-decisions.json).
//
// IDEMPOTENT by entry id: an entry whose id is already in `ignored_content`
// (live or put back, any writer) is never imported again, so the import can
// run at every launch and appends nothing the second time. F4 — A DUPLICATE
// IS A FINDING, NEVER A REPLACEMENT: an entry whose id is there with OTHER
// content (hash, size, name or reason) is not imported and is named; an
// imported row the file no longer carries (put back in the JSON after the
// cutover?) is NOT inferred as a put-back — it stays ignored and is named,
// so a person decides. Nothing is dropped or rewritten.
//
// After the write the table is read back and the counts are VERIFIED — every
// entry of the file is in the table, the table grew by exactly what was
// appended — and one line says them (console, catalog.log, videoscan.log).
//
// Memory: the file is ~130 KB (a few hundred entries); read whole, once.
//
// (For Rick: a migration script written as a pure plan — `Plan` — plus the
// two calls that run it and check it.)

import Foundation
import VideoScanCore

/// The import as a value: what the file holds, what the table already has,
/// and what one transaction appends. Pure.
struct IgnoredContentJSONImportPlan: Sendable, Equatable {

    /// Entries of the file the table does not have (by id), in file order.
    let newEntries: [IgnoredContentEntry]
    /// Entries of the file already in the table with the SAME content.
    let alreadyThere: Int
    /// Findings: the file's entry and the table's row share an id but not
    /// their content — not imported.
    let conflicts: [IgnoredContentEntry]
    /// Findings: imported, still-live rows the file no longer carries —
    /// kept ignored.
    let missingFromFile: [String]
    let fileEntries: Int

    init(file: IgnoredContentFile, rows: [CatalogRow.IgnoredReading]) {
        var byID: [String: CatalogRow.IgnoredEntry] = [:]
        for r in rows where byID[r.entry.entryID.uppercased()] == nil { byID[r.entry.entryID.uppercased()] = r.entry }
        var fresh: [IgnoredContentEntry] = [], conflicts: [IgnoredContentEntry] = []
        var same = 0
        var seen = Set<UUID>()
        for e in file.entries where seen.insert(e.id).inserted {
            guard let row = byID[e.id.uuidString] else { fresh.append(e); continue }
            if Self.sameContent(e, row) { same += 1 } else { conflicts.append(e) }
        }
        let fileIDs = Set(file.entries.map(\.id.uuidString))
        missingFromFile = rows.filter { $0.imported && !$0.putBack && !fileIDs.contains($0.entry.entryID.uppercased()) }
            .map(\.entry.filename)
        newEntries = fresh
        alreadyThere = same
        self.conflicts = conflicts
        fileEntries = file.entries.count
    }

    static func sameContent(_ e: IgnoredContentEntry, _ row: CatalogRow.IgnoredEntry) -> Bool {
        e.partialMD5 == row.partialMD5 && e.sizeBytes == row.sizeBytes && e.filename == row.filename && e.reason == row.reason
    }

    /// Counts in = counts out: every entry id of the file is in the table,
    /// and the table grew by exactly the entries appended.
    func verified(fileIDs: Set<UUID>, before: Int, after: [CatalogRow.IgnoredReading]) -> Bool {
        let ids = Set(after.compactMap { UUID(uuidString: $0.entry.entryID) })
        return fileIDs.isSubset(of: ids) && after.count == before + newEntries.count
    }
}

/// What the import did, for the one line and the tests.
enum IgnoredContentJSONImportOutcome: Sendable, Equatable {
    case noFile
    case notReadable
    case refused(String)
    /// Written (or nothing to write) and read back. `verified` false = a
    /// count did not match.
    case imported(fileEntries: Int, appended: Int, alreadyThere: Int, conflicts: Int, missingFromFile: Int,
                  rowsAfter: Int, verified: Bool)
}

extension IgnoredContentCatalogBacking {

    /// Import ignored-content.json (see the header); every outcome is said
    /// through `note`, every finding by filename.
    @discardableResult
    func importJSON(from url: URL, note: (String) -> Void) async -> IgnoredContentJSONImportOutcome {
        guard FileManager.default.fileExists(atPath: url.path) else {
            note(IgnoredContentJSONImportWords.line(.noFile, file: url.lastPathComponent))
            return .noFile
        }
        guard let file = await IgnoredContentStore.loadOffMain(url) else {
            note(IgnoredContentJSONImportWords.line(.notReadable, file: url.lastPathComponent))
            return .notReadable
        }
        let outcome = await importParsed(file)
        note(IgnoredContentJSONImportWords.line(outcome.result, file: url.lastPathComponent))
        for line in IgnoredContentJSONImportWords.findings(outcome.plan) { note(line) }
        return outcome.result
    }

    private func importParsed(_ file: IgnoredContentFile) async -> (result: IgnoredContentJSONImportOutcome, plan: IgnoredContentJSONImportPlan?) {
        guard case .success(let before) = await read() else {
            return (.refused("catalog.sqlite's ignore list could not be read"), nil)
        }
        let plan = IgnoredContentJSONImportPlan(file: file, rows: before)
        if !plan.newEntries.isEmpty {
            if let why = writeRefusal() { return (.refused(why), plan) }
            let rows = plan.newEntries.map(IgnoredContentCatalogRows.row)
            if let why = commitRaw("imported ignored-content.json (\(rows.count) entries)", { tx in
                for row in rows { try tx.appendIgnoredEntry(row) }
            }) {
                return (.refused(why), plan)
            }
        }
        guard case .success(let after) = await read() else {
            return (.refused("written, but the ignore list could not be read back"), plan)
        }
        let verified = plan.verified(fileIDs: Set(file.entries.map(\.id)), before: before.count, after: after)
        return (.imported(fileEntries: plan.fileEntries, appended: plan.newEntries.count, alreadyThere: plan.alreadyThere,
                          conflicts: plan.conflicts.count, missingFromFile: plan.missingFromFile.count,
                          rowsAfter: after.count, verified: verified), plan)
    }
}

// MARK: - Words (pure)

enum IgnoredContentJSONImportWords {

    static func line(_ outcome: IgnoredContentJSONImportOutcome, file: String) -> String {
        switch outcome {
        case .noFile:
            return "Ignored content: catalog.sqlite holds the ignore list (there is no \(file) to import)"
        case .notReadable:
            return "Ignored content: \(file) is not readable — NOT imported; the file is left as it is"
        case .refused(let why):
            return "Ignored content: \(file) NOT imported into catalog.sqlite — \(why). The file is left as it is; "
                + "its entries are honoured in memory this session and the next launch tries again"
        case .imported(let entries, let appended, let there, let conflicts, let missing, let rows, let verified):
            let counts = "\(entries) entr\(entries == 1 ? "y" : "ies") in the file: \(appended) appended, \(there) already there, "
                + "\(conflicts) conflicting (not imported), \(missing) in catalog.sqlite but not in the file (kept ignored); "
                + "\(rows) row(s) in catalog.sqlite now"
            if appended == 0 && conflicts == 0 && verified {
                return "Ignored content: catalog.sqlite holds the ignore list (\(file) is frozen history — \(counts))"
            }
            return verified
                ? "Ignored content: OUTCOME imported \(file) into catalog.sqlite — \(counts); verified (counts in = counts out). The file is frozen history from now on"
                : "Ignored content: 🔴 imported \(file) into catalog.sqlite but the read-back did NOT match — \(counts). Nothing was deleted"
        }
    }

    /// One line per finding (a person decides), never a silent change.
    static func findings(_ plan: IgnoredContentJSONImportPlan?) -> [String] {
        guard let plan else { return [] }
        let conflicting = plan.conflicts.map {
            "Ignored content: FINDING — \($0.filename) (entry \($0.id.uuidString.prefix(8))) is in catalog.sqlite with other content; the file's version was NOT imported (a duplicate is a finding, never a replacement)"
        }
        let missing = plan.missingFromFile.map {
            "Ignored content: FINDING — \($0) is ignored in catalog.sqlite but not in ignored-content.json; it stays ignored — put it back in Tidy ▸ Ignored content if that was meant"
        }
        return conflicting + missing
    }
}
