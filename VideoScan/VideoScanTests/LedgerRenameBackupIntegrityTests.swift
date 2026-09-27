// LedgerRenameBackupIntegrityTests.swift
//
// Codex re-review of acfd9f6e (GH #204, 2026-09-27): #1–#5 closed, three
// new gaps, each pinned here as codex described it.
//
//   #2 (P1) A complete marker whose listed files are missing or truncated
//      counted toward retention and evicted a VALID backup. A backup now
//      counts only when every listed file is a regular file of the listed
//      size (lstat); a defective one is neither counted nor deleted.
//   #3 (P2) A marker with sequence Int.max made `max + 1` trap on every
//      later claim. Sequences outside 1..<backupSequenceLimit are foreign
//      (not counted, not deleted), and exhaustion is a thrown error.
//   #1 (P1) The refused-rename cleanup removed an empty `.rename_backups/`
//      without the lock — deleting a folder another process had just
//      claimed and filled, and invalidating the lock inode. The backups
//      folder is now permanent; cleanup removes only its own folder,
//      under the lock.
//
// Each concern is its own suite so a trap in one (the #3 red) cannot hide
// the others' results. C++ readers: `#expect` ≈ EXPECT_*.

import Foundation
import Testing
@testable import VideoScan

private enum Fx {
    struct Fixture {
        let dir: URL
        let ledger: URL
        var backups: URL { dir.appendingPathComponent(ArchiveIndexRename.backupFolder) }
        func cleanup() { try? FileManager.default.removeItem(at: dir) }
    }

    static func make(_ tag: String) throws -> Fixture {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_backup_integrity_\(tag)_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ledger = dir.appendingPathComponent("media-ledger.jsonl")
        try Data(line(0).utf8).write(to: ledger)
        return Fixture(dir: dir, ledger: ledger)
    }

    static func path(_ i: Int) -> String { "/Volumes/A/f\(i).mov" }
    static func line(_ i: Int) -> String { #"{"fullPath":"\#(path(i))","filename":"f\#(i).mov"}"# + "\n" }

    static func rename(_ f: Fixture, step i: Int, at when: Date) throws {
        let r = ArchiveIndexRename.Replacements(values: [path(i): path(i + 1)],
                                                oldFilename: "f\(i).mov", newFilename: "f\(i + 1).mov")
        _ = try ArchiveIndexRename.rewriteLedgerFile(at: f.ledger, replacements: r, now: when)
    }

    static func survivingSteps(_ f: Fixture) throws -> Set<Int> {
        var steps: Set<Int> = []
        for name in try FileManager.default.contentsOfDirectory(atPath: f.backups.path) {
            let file = f.backups.appendingPathComponent(name).appendingPathComponent("media-ledger.jsonl")
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  let m = text.firstMatch(of: /f(\d+)\.mov/), let step = Int(m.1) else { continue }
            steps.insert(step)
        }
        return steps
    }

    /// A hand-written marker folder (what a foreign or damaged writer left).
    @discardableResult
    static func seedFolder(_ f: Fixture, name: String, sequence: String, complete: Bool,
                           listed: [(String, Int)], present: [(String, Data)]) throws -> URL {
        let d = f.backups.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        for (n, data) in present { try data.write(to: d.appendingPathComponent(n)) }
        let files = listed.map { #"{"name":"\#($0.0)","size":\#($0.1)}"# }.joined(separator: ",")
        let json = #"{"version":1,"sequence":\#(sequence),"createdAt":"2099-01-01T00:00:00Z","complete":\#(complete),"files":[\#(files)]}"#
        try Data(json.utf8).write(to: d.appendingPathComponent(ArchiveIndexRename.backupMarkerName))
        return d
    }

    static let start = ISO8601DateFormatter().date(from: "2027-04-01T00:00:00Z") ?? .distantPast
    static var n: Int { ArchiveIndexRename.backupRetention }
}

// MARK: - codex #1: the backups folder is permanent; cleanup is locked

@Suite("Rename backups — cleanup never removes another writer's folder (codex re-review #1)", .serialized)
struct BackupParentLockTests {

    /// A's refused rename removes its own folder; in the gap before A
    /// finishes, B claims and fills a backup. B's folder survives, and the
    /// `.rename_backups/` lock folder is still there.
    @Test("codex #1: pause A after its own removal, B claims+fills, resume A — B's folder survives")
    func concurrentClaimSurvivesRefusedCleanup() throws {
        let f = try Fx.make("parent")
        defer { f.cleanup() }
        let a = try ArchiveIndexRename.claimBackupDirectory(in: f.backups, now: Fx.start)
        var b: ArchiveIndexRename.BackupClaim?
        ArchiveIndexRename.removeRefusedBackup(a.dir, afterOwnRemoval: {
            // "B" — would run in another process; here, in A's gap.
            let claimB = try? ArchiveIndexRename.claimBackupDirectory(in: f.backups, now: Fx.start.addingTimeInterval(1))
            b = try? claimB.map { try ArchiveIndexRename.writeBackupFiles($0, files: [("media-ledger.jsonl", Data(Fx.line(5).utf8))]) }
        })
        let claimB = try #require(b)
        #expect(!ArchiveIndexRename.isRealDirectory(a.dir), "A removed its own folder")
        #expect(ArchiveIndexRename.isRealDirectory(f.backups), "the lock folder is permanent")
        #expect(FileManager.default.fileExists(atPath: claimB.dir.appendingPathComponent("media-ledger.jsonl").path),
                "B's backup was deleted by A's cleanup")
    }

    @Test("codex #1 sensor: nothing removes the .rename_backups folder itself")
    func parentIsNeverRemoved() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VideoScan/ArchiveIndexRename.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(!source.contains("removeItem(at: parent)"), "the backups folder is the lock inode — permanent")
        #expect(source.contains("try withBackupsLock(parent) {\n                try FileManager.default.removeItem(at: dir)\n"),
                "the refused-rename cleanup removes only its own folder, under the lock")
    }
}
