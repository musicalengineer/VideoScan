// DeletionAuditTests.swift
// G2 (Rick, 2026-10-09): auditor-grade logging for every path that moves
// files to the Trash — a START line, ONE line per requested file with its
// outcome (moved | held | failed | missing | offline | cancelled), the
// original path, size, reason, the keeper and its proof (duplicates), the
// ACTUAL Trash location for a moved file — and an OUTCOME line naming the
// per-run receipt: ~/Library/Logs/VideoScan/deletions/<stamp>_<junk|
// duplicates>.csv, one row per requested file, appended as the run goes and
// rewritten atomically at the end. "Where did my file go."

import Foundation
import Testing
@testable import VideoScan

@Suite("Deletion audit — every Trash path writes the audit and the receipt (G2)")
struct DeletionAuditSensorTests {

    @Test("sensor: the junk lanes and Delete Duplicates go through DeletionAudit")
    func everyTrashPathIsAudited() throws {
        for file in ["VideoScanModel+JunkTrashSnapshot.swift", "VideoScanModel+TrashSelection.swift", "DeleteDuplicatesAudit.swift"] {
            let code = try SourceTree.appCode(named: file)
            #expect(code.contains("DeletionAudit("), "\(file) moves files to the Trash without the audit")
        }
        // Delete Duplicates: the audit starts with the run, every settled row
        // is written where rows settle (`mutatePlan`), and the end writes the rest.
        let job = try SourceTree.appCode(named: "DeleteDuplicatesJob.swift")
        #expect(job.contains("startAudit(prepared, model: model)"))
        #expect(job.contains("plan = p\n        // G2: every row that settled here gets its audit line + receipt row.\n        auditNewlySettledRows()")
                || job.contains("plan = p\n        auditNewlySettledRows()"))
        #expect(job.components(separatedBy: "auditRemainingAndFinish(finalPlan)").count - 1 == 2, "both ends of a run")
        // The junk engine keeps the Trash's resulting location.
        let engine = try SourceTree.appCode(named: "VideoScanModel+JunkDelete.swift")
        #expect(engine.contains("resultingItemURL: &resultURL") && engine.contains("return resultURL?.path"))
        // Every caller of the junk engine is an audited lane, or named here.
        let audited: Set<String> = ["VideoScanModel+JunkTrashSnapshot.swift", "VideoScanModel+TrashSelection.swift",
                                    "VideoScanModel+JunkDelete.swift"]
        // Per-copy callers with their own ledger + console lines; the run-level
        // receipt for them is a follow-up (they call the engine once per copy).
        let pending: Set<String> = ["VideoScanModel+PruneApply.swift"]
        var unaudited: [String] = []
        for entry in SourceTree.appSources {
            let name = (entry.relative as NSString).lastPathComponent
            let text = try String(contentsOf: entry.url, encoding: .utf8)
            // A file the code-only reader cannot strip is read line by line, comments dropped.
            let code = SourceTree.scan(text).unsupported.isEmpty ? try SourceTree.code(of: text, named: name)
                : text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            if code.contains("deleteConfirmedJunk("), !audited.contains(name), !pending.contains(name) { unaudited.append(name) }
        }
        #expect(unaudited.isEmpty, "unaudited callers of the Trash routine: \(unaudited)")
    }
}

/// Minimal RFC 4180 reader for the receipt (quoted fields, "" escapes).
private func csvRows(_ url: URL) throws -> [[String]] {
    let text = try String(contentsOf: url, encoding: .utf8)
    var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
    var chars = Array(text)[...]
    while let c = chars.popFirst() {
        if quoted {
            if c == "\"" { if chars.first == "\"" { field.append("\""); chars.removeFirst() } else { quoted = false } }
            else { field.append(c) }
        } else if c == "\"" { quoted = true }
        else if c == "," { row.append(field); field = "" }
        else if c == "\n" { row.append(field); rows.append(row); row = []; field = "" }
        else { field.append(c) }
    }
    return rows
}

@Suite("Deletion audit — the receipt is one row per requested file (G2)", .serialized)
@MainActor
struct DeletionAuditReceiptTests {

    @Test func theCatalogMoveToTrashReceiptHasOneRowPerRequestedFile() async throws {
        let sb = try JunkTrashSandbox("g2_sel"); defer { sb.cleanup() }
        let model = sb.model()
        let moved = sb.junk(try sb.write("test_moved.mov"))
        let paired = sb.junk(try sb.write("test_paired.mov", fill: 0x22))
        paired.pairGroupID = UUID()
        let gone = sb.junk(try sb.write("test_gone.mov", fill: 0x33))
        try FileManager.default.removeItem(atPath: gone.fullPath)
        model.records = [moved, paired, gone]

        let result = await model.trashSelectedRecords([moved, paired, gone], fileOperation: sb.trash.operation)
        let receipt = try #require(result.receipt)
        defer { try? FileManager.default.removeItem(at: receipt) }
        let rows = try csvRows(receipt)
        #expect(rows.first == DeletionAuditRow.csvHeader.components(separatedBy: ","))
        let body = Array(rows.dropFirst())
        #expect(body.count == 3, "one row per requested file: \(body)")
        let byPath = Dictionary(uniqueKeysWithValues: body.map { ($0[1], $0) })
        #expect(byPath[moved.fullPath]?[0] == "moved")
        #expect(byPath[paired.fullPath]?[0] == "held" && byPath[paired.fullPath]?[6].contains("audio/video pair") == true)
        #expect(byPath[gone.fullPath]?[0] == "missing")
        // The receipt's outcomes are the result's.
        let kinds = result.items.map { item -> String in
            DeletionAuditRow.csvField(VideoScanModel.JunkDeletionResult.auditRow(item.record, item.outcome).outcome.rawValue)
        }
        #expect(Set(body.map { $0[0] }) == Set(kinds))
    }

    /// No seam: the real routine. The moved row names where the Trash put
    /// the file (the fixture is then removed from the Trash, as
    /// JunkTrashOnlyTests does).
    @Test func aMovedFilesRowNamesItsTrashLocation() async throws {
        let sb = try JunkTrashSandbox("g2_real"); defer { sb.cleanup() }
        let model = sb.model()
        let rec = sb.junk(try sb.write("test_g2_receipt_\(UUID().uuidString.prefix(8)).mov"))
        model.records = [rec]
        let result = await model.trashSelectedRecords([rec])
        let receipt = try #require(result.receipt)
        defer { try? FileManager.default.removeItem(at: receipt) }
        let row = try #require(try csvRows(receipt).dropFirst().first)
        #expect(row[0] == "moved")
        let trashPath = row[2]
        #expect(!trashPath.isEmpty && FileManager.default.fileExists(atPath: trashPath), "trash_path = \(trashPath)")
        #expect(trashPath.contains(".Trash"), Comment(rawValue: trashPath))
        try? FileManager.default.removeItem(atPath: trashPath)   // our own synthetic fixture
    }

    @Test func aDuplicatesRunWritesEveryCopyWithTrashLocationAndKeeperProof() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test_g2_dup_\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: dir.appendingPathComponent("catalog", isDirectory: true))
        model.mediaLedger = MediaLedger(directory: dir.appendingPathComponent("ledger", isDirectory: true))
        let bytes = Data((0..<(FileHasher.segmentSize * 2)).map { UInt8($0 % 167) })
        let group = UUID()
        func rec(_ name: String, _ d: DuplicateDisposition, _ content: Data) -> VideoRecord {
            let url = dir.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: content)
            let r = VideoRecord()
            r.fullPath = url.path; r.filename = name; r.directory = dir.path
            r.sizeBytes = Int64(content.count); r.partialMD5 = "same"; r.durationSeconds = 61
            r.duplicateGroupID = group; r.duplicateDisposition = d; r.duplicateConfidence = .high
            return r
        }
        let keeper = rec("keeper.mov", .keep, bytes)
        let same = rec("same.mov", .extraCopy, bytes)
        var other = bytes; other[7] ^= 0xFF
        let different = rec("different.mov", .extraCopy, other)
        model.records = [keeper, same, different]

        let job = DeleteDuplicatesJob(model: model, volumePath: dir.path,
                                      hooks: SignatureVerification.Hooks.live.withScratchTrash(in: dir),
                                      planRoot: dir.appendingPathComponent("plans", isDirectory: true))
        job.start(); await job.task?.value

        let receipt = try #require(job.receiptURL)
        defer { try? FileManager.default.removeItem(at: receipt) }
        let body = Array(try csvRows(receipt).dropFirst())
        let entries = try #require(job.plan?.entries)
        #expect(body.count == entries.count, "one row per requested copy")
        let movedRow = try #require(body.first { $0[1] == same.fullPath })
        #expect(movedRow[0] == "moved")
        #expect(FileManager.default.fileExists(atPath: movedRow[2]), "trash_path = \(movedRow[2])")
        #expect(movedRow[4] == keeper.fullPath && movedRow[5].hasPrefix("sha256:"), "\(movedRow)")
        let heldRow = try #require(body.first { $0[1] == different.fullPath })
        #expect(heldRow[0] == "held" && heldRow[2].isEmpty && !heldRow[6].isEmpty, "\(heldRow)")
    }
}
