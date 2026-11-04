// ProductionShapeSoundAttemptsMigrationTests.swift
// Schema v15 (`v10_sound_attempts`, GH #416 part 2) at PRODUCTION SHAPE: a
// sqlite `.backup` copy of Rick's live catalog (read-only URI on the live
// file — LiveCatalogCopy), opened by this build's store in a temp folder.
// Before the open the copy is whatever version the live file is (14 today);
// after it, 15, with every pre-existing table's row count unchanged, the new
// table empty, integrity ok, and the app's loader reading every files row.
//
// ISOLATION / real global state: reads the live catalog, so it is NOT a
// sensor-lane test; anywhere without the live catalog + latch it is SKIPPED
// (`.enabled(if:)`). PRIVACY: counts only, never paths or names.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Production-shape v14 → v15 migration of the live catalog (GH #416 part 2) — ISOLATION: reads the real catalog",
       .serialized, .enabled(if: LiveCatalogCopy.present, LiveCatalogCopy.skipWords))
@MainActor
struct ProductionShapeSoundAttemptsMigrationTests {

    @Test("a .backup copy of the live catalog migrates to 15: every table keeps its rows, sound_attempts is empty, integrity ok, the loader reads every row")
    func theLiveCatalogMigratesWithEveryRowKept() async throws {
        let scene = CutoverScene(sandbox: try ShowAgainSandbox.make("prodshape_v15")); defer { scene.cleanup() }
        try FileManager.default.createDirectory(at: scene.folder, withIntermediateDirectories: true)
        try LiveCatalogCopy.backup(to: scene.databaseURL)
        let db = scene.databaseURL
        let before = try Int(try sqliteTable(db, "SELECT schema_version FROM catalog_state").first?.first ?? "") ?? -1
        try #require(before >= 14, "the copy is at schema \(before)")
        let tables = try sqliteTable(db, """
            SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '%_fts%'
             AND name NOT IN ('grdb_migrations')
            """).map { $0[0] }
        func counts() throws -> [String: Int] {
            var out: [String: Int] = [:]
            for t in tables { out[t] = Int(try sqliteTable(db, "SELECT count(*) FROM \"\(t)\"").first?.first ?? "") ?? -1 }
            return out
        }
        let rowsBefore = try counts()
        let generation = try #require(Int(try sqliteTable(db, "SELECT generation FROM generations WHERE id = 1").first?.first ?? ""))
        try Data("\(generation)\n".utf8).write(to: scene.folder.appendingPathComponent(CatalogHighWater.fileName))
        try Data("\(generation) 2026-11-03T00:00:00Z prodshape-v15\n".utf8)
            .write(to: scene.folder.appendingPathComponent(CatalogHighWaterLedger.fileName))

        let repository = GRDBCatalogRepository(host: "prodshape-v15")
        let opened = await repository.open(at: db)
        await repository.close()
        #expect(opened == .readWrite, "\(opened)")

        let after = try Int(try sqliteTable(db, "SELECT schema_version FROM catalog_state").first?.first ?? "") ?? -1
        let pragma = try Int(try sqliteTable(db, "PRAGMA user_version").first?.first ?? "") ?? -1
        #expect(after == 15 && pragma == 15, "schema \(after), user_version \(pragma)")
        let rowsAfter = try counts()
        let changed = rowsBefore.filter { rowsAfter[$0.key] != $0.value }.keys.sorted()
        #expect(changed.isEmpty, "row counts moved in: \(changed)")
        #expect(try sqliteTable(db, "SELECT count(*) FROM sound_attempts").first?.first == "0")
        #expect(try sqliteTable(db, "PRAGMA integrity_check").map { $0[0] } == ["ok"])
        #expect(try sqliteTable(db, "PRAGMA foreign_key_check").isEmpty)

        // The app's loader on the migrated copy reads every files row: each
        // is a record or a purge it skips (held rows come on top).
        let files = Int(try sqliteTable(db, "SELECT count(*) FROM files").first?.first ?? "") ?? -1
        let load = try await CutoverScene.load(db)
        #expect(load.records.count - load.heldIDs.count + load.purgedCount == files,
                "\(load.records.count) records (\(load.heldIDs.count) held) + \(load.purgedCount) purged vs \(files) files rows")
        print("v15 production shape: schema \(before) → \(after); \(tables.count) tables, \(rowsBefore.values.reduce(0, +)) rows unchanged; "
              + "\(load.records.count) records loaded")
    }
}
