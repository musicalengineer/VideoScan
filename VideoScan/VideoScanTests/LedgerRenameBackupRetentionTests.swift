import Testing
import Foundation
@testable import VideoScan

// MARK: - Ledger rename backups are bounded (night QA 2026-09-25, m2)
//
// rewriteLedgerFile writes a full copy of the App Support ledger per rename
// into `.rename_backups/<stamp>/`. Before the fix it never called
// pruneBackups (the archive index's own backups did), so the folder grew by
// one whole-ledger copy per rename, forever.

@Suite struct LedgerRenameBackupRetentionTests {
    @Test("the App Support ledger's rename backups keep at most backupRetention folders, newest kept")
    func ledgerBackups_areBounded() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledger-retention-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ledger = dir.appendingPathComponent("media-ledger.jsonl")
        try Data((#"{"fullPath":"/Volumes/A/a.mov","filename":"a.mov"}"# + "\n").utf8).write(to: ledger)
        let a = "/Volumes/A/a.mov", b = "/Volumes/A/b.mov"
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let renames = ArchiveIndexRename.backupRetention + 5
        var stamps: [String] = []
        for i in 0..<renames {
            let (old, new) = i % 2 == 0 ? (a, b) : (b, a)
            let r = ArchiveIndexRename.Replacements(values: [old: new],
                                                    oldFilename: (old as NSString).lastPathComponent,
                                                    newFilename: (new as NSString).lastPathComponent)
            let when = start.addingTimeInterval(Double(i))
            stamps.append(ArchiveIndexRename.backupStamp(when))
            let changed = try ArchiveIndexRename.rewriteLedgerFile(at: ledger, replacements: r, now: when)
            #expect(changed == 1)
        }
        let backups = try FileManager.default.contentsOfDirectory(
            atPath: dir.appendingPathComponent(ArchiveIndexRename.backupFolder).path)
        #expect(backups.count <= ArchiveIndexRename.backupRetention,
                "each rename copies the whole ledger; \(backups.count) copies after \(renames) renames")
        #expect(Set(backups) == Set(stamps.suffix(ArchiveIndexRename.backupRetention)),
                "the NEWEST backups are the ones kept")
    }
}
