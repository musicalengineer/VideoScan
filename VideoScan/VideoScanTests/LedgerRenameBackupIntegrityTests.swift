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

// MARK: - codex #2: listed files are verified

@Suite("Rename backups — a complete marker counts only if its files are there (codex re-review #2)", .serialized)
struct BackupMarkerIntegrityTests {

    private func twentyValidPlus(_ defect: (Fx.Fixture) throws -> URL) throws {
        let f = try Fx.make("defect")
        defer { f.cleanup() }
        for i in 0..<Fx.n { try Fx.rename(f, step: i, at: Fx.start.addingTimeInterval(Double(i))) }
        let bad = try defect(f)
        ArchiveIndexRename.pruneBackups(in: f.backups)
        #expect(try Fx.survivingSteps(f).isSuperset(of: Set(0..<Fx.n)),
                "a defective backup was counted and evicted a valid one")
        #expect(FileManager.default.fileExists(atPath: bad.path), "a defective folder is never deleted by pruning")
    }

    @Test("codex #2: a newer complete marker whose listed file is MISSING evicts nothing")
    func missingFileIsNotCounted() throws {
        try twentyValidPlus { f in
            try Fx.seedFolder(f, name: "2099-01-01T000000.000Z", sequence: "1000", complete: true,
                              listed: [("media-ledger.jsonl", 50)], present: [])
        }
    }

    @Test("codex #2: a newer complete marker whose listed file is TRUNCATED evicts nothing")
    func truncatedFileIsNotCounted() throws {
        try twentyValidPlus { f in
            try Fx.seedFolder(f, name: "2099-01-01T000000.001Z", sequence: "1001", complete: true,
                              listed: [("media-ledger.jsonl", 50)], present: [("media-ledger.jsonl", Data("short".utf8))])
        }
    }

    @Test("codex #2: a listed name that escapes the folder, or no files at all, is not a backup")
    func hostileListingsAreNotCounted() throws {
        try twentyValidPlus { f in
            try Fx.seedFolder(f, name: "2099-01-01T000000.002Z", sequence: "1002", complete: true,
                              listed: [("../media-ledger.jsonl", Fx.line(0).utf8.count)], present: [])
        }
        try twentyValidPlus { f in
            try Fx.seedFolder(f, name: "2099-01-01T000000.003Z", sequence: "1003", complete: true,
                              listed: [], present: [])
        }
    }
}

// MARK: - codex #3: sequence bounds

@Suite("Rename backups — a corrupt sequence never traps a claim (codex re-review #3)", .serialized)
struct BackupSequenceBoundTests {

    @Test("codex #3: a marker with sequence Int.max — the next claim does not trap; existing backups untouched")
    func intMaxSequenceDoesNotTrap() throws {
        let f = try Fx.make("intmax")
        defer { f.cleanup() }
        try Fx.rename(f, step: 0, at: Fx.start)
        let corrupt = try Fx.seedFolder(f, name: "2099-01-01T000000.000Z", sequence: "9223372036854775807",
                                        complete: false, listed: [], present: [])
        var outcome = "none"
        do {
            let claim = try ArchiveIndexRename.claimBackupDirectory(in: f.backups, now: Fx.start.addingTimeInterval(1))
            outcome = "claimed \(claim.marker.sequence)"
            #expect(claim.marker.sequence == 2, "the foreign Int.max marker is not ours: next after 1")
        } catch {
            outcome = "threw \(error)"
        }
        #expect(outcome.hasPrefix("claimed"), Comment(rawValue: outcome))
        #expect(try Fx.survivingSteps(f) == [0], "the existing backup is untouched")
        #expect(FileManager.default.fileExists(atPath: corrupt.path), "the foreign folder is untouched")
    }

    @Test("codex #3: at the sequence limit a claim THROWS (logged), never traps, and leaves nothing behind")
    func exhaustionThrows() throws {
        let f = try Fx.make("exhaust")
        defer { f.cleanup() }
        let last = ArchiveIndexRename.backupSequenceLimit - 1
        try Fx.seedFolder(f, name: "2099-01-01T000000.000Z", sequence: "\(last)", complete: false, listed: [], present: [])
        let before = try FileManager.default.contentsOfDirectory(atPath: f.backups.path)
        #expect(throws: ArchiveIndexRename.BackupSequenceExhausted.self) {
            _ = try ArchiveIndexRename.claimBackupDirectory(in: f.backups, now: Fx.start)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.backups.path) == before)
        // A ledger rename refuses rather than proceeding without a backup.
        let ledgerBefore = try Data(contentsOf: f.ledger)
        #expect(throws: (any Error).self) { try Fx.rename(f, step: 0, at: Fx.start) }
        #expect(try Data(contentsOf: f.ledger) == ledgerBefore)
    }

    @Test("codex #3: out-of-range sequences decode as foreign")
    func outOfRangeIsForeign() throws {
        let f = try Fx.make("range")
        defer { f.cleanup() }
        for (i, seq) in ["0", "-5", "\(ArchiveIndexRename.backupSequenceLimit)", "9223372036854775807"].enumerated() {
            let d = try Fx.seedFolder(f, name: "x\(i)", sequence: seq, complete: false, listed: [], present: [])
            #expect(ArchiveIndexRename.readMarker(in: d) == nil, "sequence \(seq)")
        }
        let ok = try Fx.seedFolder(f, name: "ok", sequence: "7", complete: false, listed: [], present: [])
        #expect(ArchiveIndexRename.readMarker(in: ok)?.sequence == 7)
    }
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
        let source = try SourceTree.appSource(named: "ArchiveIndexRename.swift")
        #expect(!source.contains("removeItem(at: parent)"), "the backups folder is the lock inode — permanent")
        #expect(source.contains("try withBackupsLock(parent) {\n                try FileManager.default.removeItem(at: dir)\n"),
                "the refused-rename cleanup removes only its own folder, under the lock")
    }
}
