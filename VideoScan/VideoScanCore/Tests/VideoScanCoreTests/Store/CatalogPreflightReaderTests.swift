// CatalogPreflightReaderTests.swift
// The launch preflight's catalog questions on REAL SQLite files, generated
// here (no family data): schema version, quick_check passing, quick_check
// finding damage, quick_check interrupted at its budget, and a missing file.
// In Store/ because only Store/ folders may import GRDB (CatalogStoreSensorTests).

import Foundation
import GRDB
import Testing
@testable import VideoScanCore

@Suite("CatalogPreflightReader")
struct CatalogPreflightReaderTests {

    /// A scratch folder that removes itself.
    private final class Scratch {
        let folder: URL
        init() throws {
            folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("preflight-reader-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: folder) }
        func url(_ name: String) -> URL { folder.appendingPathComponent(name) }
    }

    /// A tiny catalog-shaped file: catalog_state with a schema version, plus
    /// `rows` rows of filler in an indexed table (so quick_check has pages to walk).
    private func makeFixture(at url: URL, schemaVersion: Int?, rows: Int = 200) throws {
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            if let schemaVersion {
                try db.execute(sql: "CREATE TABLE catalog_state (singleton INTEGER PRIMARY KEY CHECK (singleton = 1), schema_version INTEGER NOT NULL)")
                try db.execute(sql: "INSERT INTO catalog_state VALUES (1, ?)", arguments: [schemaVersion])
            }
            try db.execute(sql: "CREATE TABLE filler (id INTEGER PRIMARY KEY, name TEXT, body BLOB)")
            try db.execute(sql: "CREATE INDEX filler_name ON filler(name)")
            try db.execute(sql: """
                WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < ?)
                INSERT INTO filler SELECT i, 'row-' || i, randomblob(200) FROM n
                """, arguments: [rows])
        }
        try queue.close()
    }

    @Test func readsTheSchemaVersion() throws {
        let scratch = try Scratch()
        let url = scratch.url("catalog.sqlite")
        try makeFixture(at: url, schemaVersion: 12)
        #expect(try CatalogPreflightReader.schemaVersion(at: url) == 12)
    }

    @Test func noCatalogStateTableIsNil() throws {
        let scratch = try Scratch()
        let url = scratch.url("catalog.sqlite")
        try makeFixture(at: url, schemaVersion: nil)
        #expect(try CatalogPreflightReader.schemaVersion(at: url) == nil)
    }

    @Test func expectedVersionIsTheStoresCurrentVersion() {
        #expect(CatalogPreflightReader.expectedSchemaVersion == GRDBCatalogRepository.currentSchemaVersion)
    }

    @Test func quickCheckPassesOnAHealthyFile() throws {
        let scratch = try Scratch()
        let url = scratch.url("catalog.sqlite")
        try makeFixture(at: url, schemaVersion: 12)
        let outcome = try CatalogPreflightReader.quickCheck(at: url, budget: .seconds(5))
        guard case .passed = outcome else {
            Issue.record("expected passed, got \(outcome)")
            return
        }
    }

    @Test func quickCheckLeavesTheFileUnchanged() throws {
        let scratch = try Scratch()
        let url = scratch.url("catalog.sqlite")
        try makeFixture(at: url, schemaVersion: 12)
        let before = try Data(contentsOf: url)
        _ = try CatalogPreflightReader.quickCheck(at: url, budget: .seconds(5))
        _ = try CatalogPreflightReader.schemaVersion(at: url)
        #expect(try Data(contentsOf: url) == before, "read-only: not a byte changed")
    }

    @Test func damagedFileIsNeverAPass() throws {
        // Zero out the middle of the file (index and table pages), keep the header.
        let scratch = try Scratch()
        let url = scratch.url("catalog.sqlite")
        try makeFixture(at: url, schemaVersion: 12, rows: 2_000)
        var bytes = try Data(contentsOf: url)
        let page = 4_096
        let start = page * 3
        let end = min(bytes.count - page, start + page * 20)
        try #require(end > start, "fixture has enough pages to damage")
        bytes.replaceSubrange(start..<end, with: Data(repeating: 0xA5, count: end - start))
        try bytes.write(to: url)
        // The engine may list problems, or refuse outright; either way it is
        // not a pass, and the preflight rule turns both into a non-green check.
        do {
            let outcome = try CatalogPreflightReader.quickCheck(at: url, budget: .seconds(5))
            guard case .problems(let lines, _) = outcome else {
                Issue.record("damaged file read as \(outcome)")
                return
            }
            #expect(!lines.isEmpty)
            #expect(lines.count <= CatalogPreflightReader.maxProblemLines)
        } catch {
            // "database disk image is malformed" — the rule maps this to "Couldn't check" (warn).
        }
    }

    @Test func quickCheckIsInterruptedAtItsBudget() throws {
        // ~60 MB of filler: quick_check takes tens of ms; a 1 ms budget interrupts it.
        let scratch = try Scratch()
        let url = scratch.url("catalog.sqlite")
        try makeFixture(at: url, schemaVersion: 12, rows: 250_000)
        let outcome = try CatalogPreflightReader.quickCheck(at: url, budget: .milliseconds(1))
        #expect(outcome == .ranOutOfTime(budget: .milliseconds(1)), "\(outcome)")
    }

    @Test func missingFileThrows() throws {
        let scratch = try Scratch()
        let url = scratch.url("no-such.sqlite")
        #expect(throws: (any Error).self) { try CatalogPreflightReader.quickCheck(at: url, budget: .seconds(1)) }
        #expect(throws: (any Error).self) { try CatalogPreflightReader.schemaVersion(at: url) }
        #expect(!FileManager.default.fileExists(atPath: url.path), "a read-only open never creates the file")
    }

    @Test func cancelledBeforeStartNeverOpensTheFile() throws {
        let scratch = try Scratch()
        let url = scratch.url("catalog.sqlite")
        try makeFixture(at: url, schemaVersion: 12)
        let token = PreflightCancellation()
        token.cancel()
        #expect(try CatalogPreflightReader.quickCheck(at: url, budget: .seconds(5), cancellation: token) == .cancelled)
    }

    @Test func cancelDuringQuickCheckInterruptsItAndSaysCancelled() throws {
        // ~60 MB of filler: quick_check takes tens of ms; the cancel lands mid-walk.
        let scratch = try Scratch()
        let url = scratch.url("catalog.sqlite")
        try makeFixture(at: url, schemaVersion: 12, rows: 250_000)
        let token = PreflightCancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(2)) { token.cancel() }
        let outcome = try CatalogPreflightReader.quickCheck(at: url, budget: .seconds(30), cancellation: token)
        #expect(outcome == .cancelled, "\(outcome)")
    }

    @Test func lateWatchdogsAndCancelsAfterCloseAreHarmless() throws {
        // QA r1 minor 3: an interrupt racing close. Budgets of 0–2 ms on a
        // small file make the watchdog fire around the end of the check; a
        // cancel lands after return. Nothing may crash or hang.
        let scratch = try Scratch()
        let url = scratch.url("catalog.sqlite")
        try makeFixture(at: url, schemaVersion: 12, rows: 2_000)
        for round in 0..<60 {
            let token = PreflightCancellation()
            let outcome = try CatalogPreflightReader.quickCheck(at: url, budget: .milliseconds(round % 3), cancellation: token)
            token.cancel()
            switch outcome {
            case .passed, .ranOutOfTime: break
            case .problems, .cancelled: Issue.record("round \(round): \(outcome)")
            }
        }
    }

    @Test func theRealProbeRunsQuickCheckThroughThisReader() async throws {
        // End to end: a generated catalog + marker, the real probe, the whole run.
        let scratch = try Scratch()
        let url = scratch.url("catalog.sqlite")
        try makeFixture(at: url, schemaVersion: CatalogPreflightReader.expectedSchemaVersion)
        try Data("test".utf8).write(to: scratch.url(SQLiteCatalogReader.latchFileName))
        let context = PreflightContext(supportFolder: scratch.folder, databaseURL: url,
                                       temporaryFolder: scratch.folder, logFolder: scratch.folder,
                                       masterArchiveVolume: nil,
                                       expectedSchemaVersion: CatalogPreflightReader.expectedSchemaVersion)
        let report = try await LaunchPreflight.run(context, probe: SystemPreflightProbe())
        let byID = Dictionary(uniqueKeysWithValues: report.checks.map { ($0.id, $0) })
        #expect(byID[.catalogSwitched]?.level == .ok)
        #expect(byID[.catalogSchema]?.level == .ok, "\(byID[.catalogSchema]?.logLine ?? "")")
        #expect(byID[.catalogJournal]?.level == .ok)
        #expect(byID[.catalogQuickCheck]?.level == .ok, "\(byID[.catalogQuickCheck]?.logLine ?? "")")
        #expect(report.quickCheckElapsed != nil)
        #expect(report.hold == .none)
    }
}
