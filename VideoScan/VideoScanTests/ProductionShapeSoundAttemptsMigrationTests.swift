// ProductionShapeSoundAttemptsMigrationTests.swift
// Schema v15 (`v10_sound_attempts`, GH #416 part 2) at PRODUCTION SHAPE: a
// sqlite `.backup` copy of Rick's live catalog (read-only URI on the live
// file — LiveCatalogCopy), opened by this build's store in a temp folder.
//
// Invariants, true of ANY real catalog (rewritten 2026-11-06: the first
// version asserted `sound_attempts` empty after the open, a one-time fact of
// the v14 catalog it was written against — the live catalog has been at 15
// with attempts recorded since, and the nightly went red on the Ultra):
//   (a) the catalog AS IT IS opens on this build: schema at this build's
//       version (16 since `v11_public_marks`, 2026-11-09), every table
//       keeps its row count, every `sound_attempts` row that was there is
//       there unchanged (a re-open never re-runs or rewrites the migration),
//       integrity and foreign keys ok, the loader reads every files row;
//   (b) the same copy REWOUND to 14 (sound_attempts and every later
//       migration's table dropped, those migrations unrecorded, both version
//       stamps 14) migrates to this build's version with every other table's
//       rows kept and `sound_attempts` new and empty — so the step itself
//       keeps production-shape teeth after every catalog is past it.
// The step after this one has its own file:
// ProductionShapePublicMarksMigrationTests.swift.
//
// ISOLATION / real global state: reads the live catalog, so it is NOT a
// sensor-lane test; anywhere without the live catalog + latch it is SKIPPED
// (`.enabled(if:)`, with the reason). PRIVACY: counts only, never paths or names.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Production-shape v14 → v15 migration of the live catalog (GH #416 part 2) — ISOLATION: reads the real catalog",
       .serialized, .enabled(if: LiveCatalogCopy.present, LiveCatalogCopy.skipWords))
@MainActor
struct ProductionShapeSoundAttemptsMigrationTests {

    /// The schema this build's store leaves a catalog at (Core's
    /// `GRDBCatalogRepository.currentSchemaVersion`, internal to Core).
    static let buildSchema = 16

    static let attemptsColumns = "digest, engine_version, outcome, attempts, last_at, coalesce(detail, '<null>')"

    /// Every user table but the migration ledger and FTS shadows.
    static func tables(_ db: URL) throws -> [String] {
        try sqliteTable(db, """
            SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '%_fts%'
             AND name NOT IN ('grdb_migrations')
            """).map { $0[0] }
    }

    static func counts(_ db: URL, _ tables: [String]) throws -> [String: Int] {
        var out: [String: Int] = [:]
        for t in tables { out[t] = Int(try sqliteTable(db, "SELECT count(*) FROM \"\(t)\"").first?.first ?? "") ?? -1 }
        return out
    }

    static func schema(_ db: URL) throws -> (state: Int, pragma: Int) {
        (Int(try sqliteTable(db, "SELECT schema_version FROM catalog_state").first?.first ?? "") ?? -1,
         Int(try sqliteTable(db, "PRAGMA user_version").first?.first ?? "") ?? -1)
    }

    /// The copy (a sqlite `.backup` of the live file) in a sandbox folder.
    static func copy(_ label: String) throws -> CutoverScene {
        let scene = CutoverScene(sandbox: try ShowAgainSandbox.make(label))
        try FileManager.default.createDirectory(at: scene.folder, withIntermediateDirectories: true)
        try LiveCatalogCopy.backup(to: scene.databaseURL)
        return scene
    }

    /// High-water witnesses at the copy's generation, so the open accepts it.
    static func witnessGeneration(_ scene: CutoverScene, host: String) throws {
        let generation = try #require(Int(try sqliteTable(scene.databaseURL, "SELECT generation FROM generations WHERE id = 1").first?.first ?? ""))
        try Data("\(generation)\n".utf8).write(to: scene.folder.appendingPathComponent(CatalogHighWater.fileName))
        try Data("\(generation) 2026-11-03T00:00:00Z \(host)\n".utf8)
            .write(to: scene.folder.appendingPathComponent(CatalogHighWaterLedger.fileName))
    }

    /// Open with this build's store (runs any pending migration) and close.
    static func open(_ db: URL, host: String) async -> CatalogOpenOutcome {
        let repository = GRDBCatalogRepository(host: host)
        let opened = await repository.open(at: db)
        await repository.close()
        return opened
    }

    /// Integrity, foreign keys, and the app's loader reading every files row
    /// (each a record or a purge it skips; held rows come on top).
    static func expectWhole(_ db: URL, _ label: String) async throws -> Int {
        #expect(try sqliteTable(db, "PRAGMA integrity_check").map { $0[0] } == ["ok"], "\(label): integrity")
        #expect(try sqliteTable(db, "PRAGMA foreign_key_check").isEmpty, "\(label): foreign keys")
        let files = Int(try sqliteTable(db, "SELECT count(*) FROM files").first?.first ?? "") ?? -1
        let load = try await CutoverScene.load(db)
        #expect(load.records.count - load.heldIDs.count + load.purgedCount == files,
                "\(label): \(load.records.count) records (\(load.heldIDs.count) held) + \(load.purgedCount) purged vs \(files) files rows")
        return load.records.count
    }

    @Test("a .backup copy of the live catalog AS IT IS opens at this build's schema: every table keeps its rows, every sound_attempts row is kept unchanged, integrity ok, the loader reads every row")
    func theLiveCatalogMigratesWithEveryRowKept() async throws {
        let scene = try Self.copy("prodshape_v15"); defer { scene.cleanup() }
        let db = scene.databaseURL
        let before = try Self.schema(db)
        try #require(before.state >= 14, "the copy is at schema \(before.state)")
        let tables = try Self.tables(db)
        let rowsBefore = try Self.counts(db, tables)
        let attemptsBefore = tables.contains("sound_attempts")
            ? Set(try sqliteTable(db, "SELECT \(Self.attemptsColumns) FROM sound_attempts").map { $0.joined(separator: "|") }) : []
        try Self.witnessGeneration(scene, host: "prodshape-v15")

        let opened = await Self.open(db, host: "prodshape-v15")
        #expect(opened == .readWrite, "\(opened)")

        let after = try Self.schema(db)
        #expect(after.state == Self.buildSchema && after.pragma == Self.buildSchema, "schema \(after.state), user_version \(after.pragma)")
        let rowsAfter = try Self.counts(db, tables)
        let changed = rowsBefore.filter { rowsAfter[$0.key] != $0.value }.keys.sorted()
        #expect(changed.isEmpty, "row counts moved in: \(changed)")
        let attemptsAfter = Set(try sqliteTable(db, "SELECT \(Self.attemptsColumns) FROM sound_attempts").map { $0.joined(separator: "|") })
        #expect(attemptsAfter == attemptsBefore,
                "sound_attempts: \(attemptsBefore.subtracting(attemptsAfter).count) row(s) lost or changed, \(attemptsAfter.subtracting(attemptsBefore).count) appeared")
        let loaded = try await Self.expectWhole(db, "as it is")
        // Never silent about which path ran: the step, or a re-open of a catalog already past it.
        print("v15 production shape (as it is): schema \(before.state) → \(after.state) "
              + (before.state < 15 ? "(the sound_attempts migration ran)" : "(already past 14: the sound_attempts migration did not run again)")
              + "; \(tables.count) tables, \(rowsBefore.values.reduce(0, +)) rows unchanged; \(attemptsBefore.count) sound_attempts row(s) kept; "
              + "\(loaded) records loaded")
    }

    @Test("the copy rewound to 14 (sound_attempts and every later table dropped, those steps unrecorded) migrates to this build's schema: every other table keeps its rows, sound_attempts is new and empty, integrity ok")
    func theRewoundCopyMigratesWithEveryRowKept() async throws {
        let scene = try Self.copy("prodshape_v15_rewound"); defer { scene.cleanup() }
        let db = scene.databaseURL
        let live = try Self.schema(db)
        try #require(live.state >= 14 && live.state <= Self.buildSchema,
                     "the copy is at schema \(live.state): this build understands 14…\(Self.buildSchema); a later schema means the rewind below is due for the new table")
        if live.state >= 15 {
            // Later steps first (schema 16, `public_marks`), then this one.
            // DROP TABLE takes the table's index and its append-only triggers with it.
            try sqliteExecute(db, [
                "DROP TABLE IF EXISTS public_marks",
                "DELETE FROM grdb_migrations WHERE identifier = 'v11_public_marks'",     // CatalogPublicMarksSchema.migrationID (Core-internal)
                "DROP TABLE sound_attempts",
                "DELETE FROM grdb_migrations WHERE identifier = 'v10_sound_attempts'",   // CatalogSoundAttemptsSchema.migrationID (Core-internal)
                "UPDATE catalog_state SET schema_version = 14 WHERE singleton = 1",
            ])
            try sqliteExecute(db, ["PRAGMA user_version = 14"])
        }
        let before = try Self.schema(db)
        try #require(before.state == 14 && before.pragma == 14, "rewound to \(before.state) / user_version \(before.pragma)")
        let tables = try Self.tables(db)
        try #require(!tables.contains("sound_attempts"), "the rewound copy still has sound_attempts")
        try #require(!tables.contains("public_marks"), "the rewound copy still has public_marks")
        let rowsBefore = try Self.counts(db, tables)
        try Self.witnessGeneration(scene, host: "prodshape-v15-rewound")

        let opened = await Self.open(db, host: "prodshape-v15-rewound")
        #expect(opened == .readWrite, "\(opened)")

        let after = try Self.schema(db)
        #expect(after.state == Self.buildSchema && after.pragma == Self.buildSchema, "schema \(after.state), user_version \(after.pragma)")
        let rowsAfter = try Self.counts(db, tables)
        let changed = rowsBefore.filter { rowsAfter[$0.key] != $0.value }.keys.sorted()
        #expect(changed.isEmpty, "row counts moved in: \(changed)")
        #expect(try sqliteTable(db, "SELECT count(*) FROM sound_attempts").first?.first == "0", "the new table starts empty")
        let loaded = try await Self.expectWhole(db, "rewound")
        print("v15 production shape (rewound): \(live.state) → 14 → \(after.state); \(tables.count) tables, "
              + "\(rowsBefore.values.reduce(0, +)) rows unchanged; \(loaded) records loaded")
    }
}
