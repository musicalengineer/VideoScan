// LedgerRenameBackupProvenanceTests.swift
//
// Codex review of 3a4fc4f3 (GH #204, 2026-09-27): five P1 counterexamples,
// one root cause — pruning decided from folder NAMES and wall clocks, which
// nothing guarantees. Retention now decides only from a marker WE wrote
// last (`.videoscan-backup.json`, complete + a monotonic sequence), on real
// directories (lstat, never through a symlink). A folder without a
// complete marker — an in-progress writer, a failed write, a legacy
// backup, a user's own folder — is never counted and never pruned.
//
// One test per finding, each the pin codex named:
//   #1 a suspended writer's folder survives 20 later backups
//   #2 a failed backup write, then a success, leaves 20 complete backups
//   #3 a timestamp-named user folder and a folder symlink are neither
//      counted nor removed
//   #4 20 September renames then an August one: the latest 20 CONTENTS
//      survive (a clock rollback does not reorder)
//   #5 legacy folders mixed with new ones: no legacy folder is pruned
//
// Backup content is unique per step (step i renames f<i> → f<i+1>, so its
// backup holds "f<i>"), so the pins name survivors by CONTENT.
//
// C++ readers: `#expect` ≈ EXPECT_*, `#require` ≈ ASSERT_*.

import Foundation
import Testing
@testable import VideoScan

@Suite("Rename backups — pruned only by our own marker (codex review of GH #204)", .serialized)
struct LedgerRenameBackupProvenanceTests {

    private struct Fixture {
        let dir: URL
        let ledger: URL
        var backups: URL { dir.appendingPathComponent(ArchiveIndexRename.backupFolder) }
        func cleanup() { try? FileManager.default.removeItem(at: dir) }
    }

    private static func makeFixture(_ tag: String) throws -> Fixture {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_backup_prov_\(tag)_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ledger = dir.appendingPathComponent("media-ledger.jsonl")
        try Data(line(0).utf8).write(to: ledger)
        return Fixture(dir: dir, ledger: ledger)
    }

    private static func path(_ i: Int) -> String { "/Volumes/A/f\(i).mov" }
    private static func line(_ i: Int) -> String {
        #"{"fullPath":"\#(path(i))","filename":"f\#(i).mov"}"# + "\n"
    }

    private static func replacements(step i: Int) -> ArchiveIndexRename.Replacements {
        .init(values: [path(i): path(i + 1)], oldFilename: "f\(i).mov", newFilename: "f\(i + 1).mov")
    }

    private static func rename(_ f: Fixture, step i: Int, at when: Date) throws {
        let changed = try ArchiveIndexRename.rewriteLedgerFile(at: f.ledger, replacements: replacements(step: i), now: when)
        #expect(changed == 1)
    }

    private static func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    private static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil   // lstat: a symlink counts itself
    }

    /// Steps whose ledger backups are on disk, by CONTENT. Entries that
    /// are not real folders holding a ledger copy are skipped.
    private static func survivingSteps(_ f: Fixture) throws -> Set<Int> {
        var steps: Set<Int> = []
        for name in try FileManager.default.contentsOfDirectory(atPath: f.backups.path) {
            let folder = f.backups.appendingPathComponent(name)
            guard !isSymlink(folder) else { continue }
            let file = folder.appendingPathComponent("media-ledger.jsonl")
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  let match = text.firstMatch(of: /f(\d+)\.mov/),
                  let step = Int(match.1) else { continue }
            steps.insert(step)
        }
        return steps
    }

    private static func utc(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso) ?? .distantPast
    }

    private static var n: Int { ArchiveIndexRename.backupRetention }

    private struct InjectedFailure: Error {}

    // MARK: codex #1 — an in-progress writer's folder is never prunable

    @Test("codex #1: a suspended writer's folder survives 20 later backups, then completes")
    func suspendedWriterSurvives() throws {
        let f = try Self.makeFixture("suspended")
        defer { f.cleanup() }
        // A claims its folder first (oldest name, lowest sequence) and stalls.
        let a = try ArchiveIndexRename.claimBackupDirectory(in: f.backups, now: Self.utc("2027-01-01T00:00:00Z"))
        #expect(a.marker.sequence == 1 && !a.marker.complete)
        let start = Self.utc("2027-01-01T00:01:00Z")
        for i in 0..<(Self.n + 1) { try Self.rename(f, step: i, at: start.addingTimeInterval(Double(i))) }
        #expect(ArchiveIndexRename.isRealDirectory(a.dir), "a later backup's pruning deleted A's folder mid-write")
        #expect(try Self.survivingSteps(f) == Set(1...Self.n), "A was not counted: the newest \(Self.n) complete remain")
        // A resumes: its writes land in its own folder.
        let filled = try ArchiveIndexRename.writeBackupFiles(a, files: [("media-ledger.jsonl", Data(Self.line(700).utf8))])
        ArchiveIndexRename.markBackupComplete(filled)
        let marker = try #require(ArchiveIndexRename.readMarker(in: a.dir))
        #expect(marker.complete && marker.files == [.init(name: "media-ledger.jsonl", size: Self.line(700).utf8.count)])
    }

    // MARK: codex #2 — a failed backup never evicts a complete one

    @Test("codex #2: a failed backup write, then a success, leaves 20 complete backups")
    func failedWriteDoesNotEvict() throws {
        let f = try Self.makeFixture("failed")
        defer { f.cleanup() }
        let start = Self.utc("2027-02-01T00:00:00Z")
        for i in 0..<Self.n { try Self.rename(f, step: i, at: start.addingTimeInterval(Double(i))) }
        let before = try String(contentsOf: f.ledger, encoding: .utf8)
        #expect(throws: InjectedFailure.self) {
            try ArchiveIndexRename.rewriteLedgerFile(
                at: f.ledger, replacements: Self.replacements(step: Self.n),
                now: start.addingTimeInterval(1_000), backupWriter: { _, _ in throw InjectedFailure() })
        }
        #expect(try String(contentsOf: f.ledger, encoding: .utf8) == before, "no backup, no ledger change")
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.backups.path).count == Self.n,
                "the failed backup removed its own folder")
        try Self.rename(f, step: Self.n, at: start.addingTimeInterval(2_000))
        #expect(try Self.survivingSteps(f) == Set(1...Self.n), "exactly the newest \(Self.n) complete backups")
    }

    /// The archive-index writer's shape: several files, the SECOND fails.
    @Test("codex #2: failure on the second index file removes the partial folder; nothing counted")
    func failureOnSecondFileRemovesPartial() throws {
        let f = try Self.makeFixture("second_file")
        defer { f.cleanup() }
        let claim = try ArchiveIndexRename.claimBackupDirectory(in: f.backups, now: Self.utc("2027-02-02T00:00:00Z"))
        var calls = 0
        #expect(throws: InjectedFailure.self) {
            _ = try ArchiveIndexRename.writeBackupFiles(
                claim, files: [("manifest.csv", Data("a".utf8)), ("promote_journal.jsonl", Data("b".utf8))],
                write: { data, url in
                    calls += 1
                    if calls == 2 { throw InjectedFailure() }
                    try ArchiveIndexRename.livePublish(data, to: url)
                })
        }
        #expect(calls == 2)
        #expect(!ArchiveIndexRename.isRealDirectory(claim.dir), "the partial backup folder was removed")
        // The next claim still gets a fresh, higher sequence.
        let next = try ArchiveIndexRename.claimBackupDirectory(in: f.backups, now: Self.utc("2027-02-02T00:00:00Z"))
        #expect(next.marker.sequence == 1, "the removed claim left no marker behind")
    }

    // MARK: codex #3 — names do not authorize deletion; symlinks are not followed

    @Test("codex #3: a timestamp-named user folder and a folder symlink are neither counted nor removed")
    func userFolderAndSymlinkSurvive() throws {
        let f = try Self.makeFixture("user_dir")
        defer { f.cleanup() }
        let fm = FileManager.default
        try fm.createDirectory(at: f.backups, withIntermediateDirectories: true)
        // A user's folder that happens to look like a backup stamp.
        let userDir = f.backups.appendingPathComponent("2000-01-01T000000.000Z")
        try fm.createDirectory(at: userDir, withIntermediateDirectories: true)
        try Data("family notes".utf8).write(to: userDir.appendingPathComponent("notes.txt"))
        // A stamp-named symlink to a folder elsewhere — even one that
        // carries a complete-looking marker must not be followed.
        let target = f.dir.appendingPathComponent("elsewhere", isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("keep me".utf8).write(to: target.appendingPathComponent("keep.txt"))
        try Data(#"{"version":1,"sequence":0,"createdAt":"2000-01-01T00:00:00Z","complete":true,"files":[]}"#.utf8)
            .write(to: target.appendingPathComponent(".videoscan-backup.json"))
        let link = f.backups.appendingPathComponent("2000-01-01T000000.001Z")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)

        let start = Self.utc("2027-01-01T00:00:00Z")
        for i in 0..<(Self.n + 1) { try Self.rename(f, step: i, at: start.addingTimeInterval(Double(i))) }

        #expect(fm.fileExists(atPath: userDir.appendingPathComponent("notes.txt").path), "the user's folder was deleted")
        #expect(Self.exists(link) && Self.isSymlink(link), "the symlink was removed")
        #expect(fm.fileExists(atPath: target.appendingPathComponent("keep.txt").path))
        #expect(try Self.survivingSteps(f) == Set(1...Self.n),
                "neither was counted: exactly the newest \(Self.n) real backups remain")
    }

    // MARK: codex #4 — clock rollback

    @Test("codex #4: 20 September renames then an August one — the latest 20 contents survive")
    func clockRollbackKeepsTheLatest() throws {
        let f = try Self.makeFixture("rollback")
        defer { f.cleanup() }
        let september = Self.utc("2026-09-10T12:00:00Z")
        for i in 0..<Self.n { try Self.rename(f, step: i, at: september.addingTimeInterval(Double(i) * 60)) }
        try Self.rename(f, step: Self.n, at: Self.utc("2026-08-01T12:00:00Z"))   // the clock went back
        #expect(try Self.survivingSteps(f) == Set(1...Self.n),
                "the newest rename's backup (step \(Self.n)) must survive; the oldest (step 0) goes")
    }

    // MARK: codex #5 — legacy names carry no provenance

    @Test("codex #5: legacy folders mixed with new ones — no legacy folder is pruned")
    func legacyFoldersAreNeverPruned() throws {
        let f = try Self.makeFixture("legacy")
        defer { f.cleanup() }
        let fm = FileManager.default
        try fm.createDirectory(at: f.backups, withIntermediateDirectories: true)
        // Legacy local-time names, incl. a fall-back pair and one "newer"
        // than the 01:00Z backup only if read in New York.
        let legacy = ["2026-11-02T000000.000", "2026-11-01T013000.000", "2026-11-01T011000.000", "2000-01-01T000000.000-2"]
        for name in legacy {
            let d = f.backups.appendingPathComponent(name)
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
            try Data(Self.line(900).utf8).write(to: d.appendingPathComponent("media-ledger.jsonl"))
        }
        let start = Self.utc("2027-03-01T00:00:00Z")
        for i in 0..<(Self.n + 1) { try Self.rename(f, step: i, at: start.addingTimeInterval(Double(i))) }
        for name in legacy {
            #expect(fm.fileExists(atPath: f.backups.appendingPathComponent(name).path), "legacy \(name) was pruned")
        }
        #expect(try Self.survivingSteps(f) == Set(1...Self.n).union([900]))
    }
}
