// LedgerRenameBackupOrderingTests.swift
//
// GH #204 (night hardening 2026-09-27, D3, DATA-RISK): rename backups of
// the archive index / App Support ledger were named with a LOCAL-time
// stamp with no offset ("2026-11-01T013000.000") and pruned by LEXICAL
// sort. Two failures on the one path that keeps the only copy of the
// pre-rename index:
//
//   • DST fall-back: 01:30 EDT (older) and 01:10 EST (newer) — the newer
//     stamp sorts first, so retention prunes the NEWEST backup.
//   • Same millisecond: two renames share one folder; the ledger path's
//     createDirectory(withIntermediateDirectories: true) succeeds on the
//     existing folder and the second backup overwrites the first.
//
// Fix: UTC stamps with the "Z" offset designator and a folder created
// exclusively (an existing name gets -2, -3 …). After the codex review
// (2026-09-27) retention reads no names at all: it orders by the
// sequence in our own completion marker — see
// LedgerRenameBackupProvenanceTests for the five counterexamples.
//
// Each backup's content is unique (step i renames f<i> → f<i+1>, so the
// backup written at step i holds "f<i>"), which lets the pins say WHICH
// backups survived without trusting any folder name.
//
// C++ readers: `#expect` ≈ EXPECT_*, `#require` ≈ ASSERT_*.

import Foundation
import Testing
@testable import VideoScan

@Suite("Rename backups — ordered by real time, never overwritten (GH #204)", .serialized)
struct LedgerRenameBackupOrderingTests {

    private struct Fixture {
        let dir: URL
        let ledger: URL
        var backups: URL { dir.appendingPathComponent(ArchiveIndexRename.backupFolder) }
        func cleanup() { try? FileManager.default.removeItem(at: dir) }
    }

    private static func makeFixture(_ tag: String) throws -> Fixture {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_backup_order_\(tag)_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ledger = dir.appendingPathComponent("media-ledger.jsonl")
        try Data(line(0).utf8).write(to: ledger)
        return Fixture(dir: dir, ledger: ledger)
    }

    private static func path(_ i: Int) -> String { "/Volumes/A/f\(i).mov" }
    private static func line(_ i: Int) -> String {
        #"{"fullPath":"\#(path(i))","filename":"f\#(i).mov"}"# + "\n"
    }

    /// Step i: rename f<i> → f<i+1> at `when`. The backup it writes holds f<i>.
    private static func rename(_ f: Fixture, step i: Int, at when: Date) throws {
        let r = ArchiveIndexRename.Replacements(
            values: [path(i): path(i + 1)], oldFilename: "f\(i).mov", newFilename: "f\(i + 1).mov")
        let changed = try ArchiveIndexRename.rewriteLedgerFile(at: f.ledger, replacements: r, now: when)
        #expect(changed == 1)
    }

    /// Which steps' backups are on disk, read from the backups' CONTENT.
    private static func survivingSteps(_ f: Fixture) throws -> Set<Int> {
        let fm = FileManager.default
        var steps: Set<Int> = []
        for name in try fm.contentsOfDirectory(atPath: f.backups.path) {
            let file = f.backups.appendingPathComponent(name).appendingPathComponent("media-ledger.jsonl")
            let text = try String(contentsOf: file, encoding: .utf8)
            let match = try #require(text.firstMatch(of: /f(\d+)\.mov/), "\(name): \(text)")
            steps.insert(try #require(Int(match.1)))
        }
        return steps
    }

    private static func utc(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso) ?? .distantPast
    }

    // MARK: Pins against the real ledger path

    /// 2026-11-01, US fall-back. Step 0 at 05:30Z (01:30 EDT), step 1 at
    /// 06:10Z (01:10 EST — later, but a smaller local clock reading), then
    /// 19 more from 07:00Z. Retention is 20 of 21: exactly step 0 — the
    /// OLDEST — must go. With local-time names sorted lexically (on a
    /// machine in US Eastern) step 1 was pruned instead.
    @Test("#204: the DST fall-back pair — the older backup is pruned, the newer kept")
    func dstFallBackPairPrunesTheOlder() throws {
        let f = try Self.makeFixture("dst")
        defer { f.cleanup() }
        let times = [Self.utc("2026-11-01T05:30:00Z"), Self.utc("2026-11-01T06:10:00Z")]
            + (0..<(ArchiveIndexRename.backupRetention - 1)).map {
                Self.utc("2026-11-01T07:00:00Z").addingTimeInterval(Double($0) * 60)
            }
        #expect(times.count == ArchiveIndexRename.backupRetention + 1)
        for (i, when) in times.enumerated() { try Self.rename(f, step: i, at: when) }
        let kept = try Self.survivingSteps(f)
        #expect(kept == Set(1...ArchiveIndexRename.backupRetention),
                "pruned the wrong backup (TZ \(TimeZone.current.identifier)): kept \(kept.sorted())")
    }

    @Test("#204: two renames in the same millisecond keep BOTH backups")
    func sameMillisecondPairBothSurvive() throws {
        let f = try Self.makeFixture("same_ms")
        defer { f.cleanup() }
        let when = Date(timeIntervalSince1970: 1_800_000_000.123)
        try Self.rename(f, step: 0, at: when)
        try Self.rename(f, step: 1, at: when)
        let names = try FileManager.default.contentsOfDirectory(atPath: f.backups.path)
        #expect(names.count == 2, "\(names)")
        #expect(try Self.survivingSteps(f) == [0, 1], "the second backup overwrote the first")
    }

    @Test("#204: retention keeps the newest N across many renames")
    func retentionKeepsTheNewest() throws {
        let f = try Self.makeFixture("retention")
        defer { f.cleanup() }
        let n = ArchiveIndexRename.backupRetention
        let start = Self.utc("2026-03-08T06:30:00Z")   // spans the spring-forward gap
        for i in 0..<(n + 7) { try Self.rename(f, step: i, at: start.addingTimeInterval(Double(i) * 600)) }
        #expect(try Self.survivingSteps(f) == Set(7..<(n + 7)))
    }

    // MARK: The name format and the exclusive folder (host-independent)

    @Test("#204: stamps are UTC with the Z offset")
    func stampsAreUTC() {
        #expect(ArchiveIndexRename.backupStamp(Self.utc("2026-11-01T05:30:00Z")) == "2026-11-01T053000.000Z")
        #expect(ArchiveIndexRename.backupStamp(Self.utc("2026-11-01T06:10:00Z")) == "2026-11-01T061000.000Z")
    }

    @Test("#204: makeBackupDirectory never hands out a folder twice")
    func backupDirectoriesAreExclusive() throws {
        let f = try Self.makeFixture("exclusive")
        defer { f.cleanup() }
        let when = Date(timeIntervalSince1970: 1_800_000_000.5)
        let dirs = try (0..<3).map { _ in try ArchiveIndexRename.makeBackupDirectory(in: f.backups, now: when) }
        let stamp = ArchiveIndexRename.backupStamp(when)
        #expect(dirs.map(\.lastPathComponent) == [stamp, stamp + "-2", stamp + "-3"])
        #expect(Set(dirs.map(\.path)).count == 3)
    }

    /// SENSOR: both backup writers claim through the one exclusive, marked
    /// path, and retention orders by marker sequence — never by name.
    @Test("#204 sensor: both writers claim via claimBackupDirectory; prune orders by marker sequence")
    func sourceUsesTheClaimAndMarkerOrder() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VideoScan/ArchiveIndexRename.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.components(separatedBy: "claimBackupDirectory(in: parent, now: now)").count - 1 == 2,
                "the archive-index writer and the ledger writer")
        #expect(source.components(separatedBy: "try makeBackupDirectory(").count - 1 == 1, "only inside the claim")
        #expect(source.components(separatedBy: "markBackupComplete(backup)").count - 1 == 2,
                "complete only after each writer's publish")
        #expect(source.contains(".filter(\\.marker.complete).sorted { $0.marker.sequence < $1.marker.sequence }"))
        #expect(!source.contains("backupSortKey"), "no name parsing decides retention")
    }
}
