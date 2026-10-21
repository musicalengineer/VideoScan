// CatalogPreflightReaderQAR1Tests.swift
// QA round 1 on bb49d543f: probes of the reader against a WAL catalog with a
// live DatabasePool writer — the shape the app actually has. The shipped
// fixtures are rollback-journal files, so none of this was exercised.

import Foundation
import GRDB
import Testing
@testable import VideoScanCore

extension CatalogPreflightReaderTests {

    private func walFixture(_ folder: URL) throws -> (URL, DatabasePool) {
        let url = folder.appendingPathComponent("catalog.sqlite")
        let pool = try DatabasePool(path: url.path)
        try pool.write { db in
            try db.execute(sql: "CREATE TABLE catalog_state (singleton INTEGER PRIMARY KEY, schema_version INTEGER NOT NULL)")
            try db.execute(sql: "INSERT INTO catalog_state VALUES (1, 12)")
            try db.execute(sql: "CREATE TABLE filler (id INTEGER PRIMARY KEY, body BLOB)")
            try db.execute(sql: """
                WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 20000)
                INSERT INTO filler SELECT i, randomblob(200) FROM n
                """)
        }
        return (url, pool)
    }

    @Test func qaR1_quickCheckBesideALiveWALWriterPassesAndNeverBlocksACommit() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("qa-pf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (url, pool) = try walFixture(folder)
        async let check = Task.detached { try CatalogPreflightReader.quickCheck(at: url, budget: .seconds(5)) }.value
        for i in 0..<200 {
            try await pool.write { try $0.execute(sql: "INSERT INTO filler(body) VALUES (randomblob(?))", arguments: [i + 1]) }
        }
        let outcome = try await check
        guard case .passed = outcome else { Issue.record("\(outcome)"); return }
        #expect(try CatalogPreflightReader.schemaVersion(at: url) == 12)
        try pool.close()
    }

    @Test func qaR1_readerOnAClosedWALCatalogLeavesNoSidecars() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("qa-pf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (url, pool) = try walFixture(folder)
        try pool.writeWithoutTransaction { try $0.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
        try pool.close()
        let before = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        _ = try CatalogPreflightReader.schemaVersion(at: url)
        _ = try CatalogPreflightReader.quickCheck(at: url, budget: .seconds(5))
        let after = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(after == before, "before \(before), after \(after)")
    }
}
