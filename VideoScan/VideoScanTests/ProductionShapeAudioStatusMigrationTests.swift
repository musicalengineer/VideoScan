// ProductionShapeAudioStatusMigrationTests.swift
// Schema v17 (`v12_audio_status`, DECISIONS 2026-11-27 item 2) at PRODUCTION
// SHAPE: a sqlite `.backup` copy of Rick's live catalog (read-only URI on the
// live file — LiveCatalogCopy), opened by this build's store in a temp folder.
// The live catalog itself is never opened for writing here.
//
// The step REBUILDS media_checks (SQLite widens a CHECK only that way), so the
// proof is row-for-row:
//   (a) the catalog AS IT IS opens on this build at 17: every table keeps its
//       row count; every media_checks row (all columns) is the row it was;
//       integrity and foreign keys ok; the loader reads every files row;
//   (b) the same copy REWOUND to 16 (media_checks rebuilt with the v16 narrow
//       CHECK, the step unrecorded, both stamps 16) migrates to 17 with the
//       same guarantees, and the table is the widened one. A copy that already
//       holds a v1.16 word ('attention' / 'unverified') cannot be narrowed; the
//       test says so and checks (a) only.
//
// ISOLATION / real global state: reads the live catalog, so it is NOT a
// sensor-lane test; anywhere without the live catalog + latch it is SKIPPED.
// PRIVACY: counts only, never paths, names or digests.

import Foundation
import Testing
@testable import VideoScan
@testable import VideoScanCore

@Suite("Production-shape v16 → v17 migration of the live catalog (stored audio status) — ISOLATION: reads the real catalog",
       .serialized, .enabled(if: LiveCatalogCopy.present, LiveCatalogCopy.skipWords))
@MainActor
struct ProductionShapeAudioStatusMigrationTests {

    private typealias Shape = ProductionShapeSoundAttemptsMigrationTests

    static let columns = "digest, kind, status, note, quote(checked_at), quote(card), provenance"

    /// Every media_checks row, every column, as one comparable set.
    static func mediaChecks(_ db: URL) throws -> Set<String> {
        Set(try sqliteTable(db, "SELECT \(columns) FROM media_checks").map { $0.joined(separator: "|") })
    }

    /// Rewind a copy at 17 to 16: media_checks rebuilt with the v2 (narrow)
    /// DDL, the step unrecorded, both stamps 16. Throws if a row holds a
    /// v1.16 word (the narrow CHECK refuses it — nothing is changed).
    static func rewindToSixteen(_ db: URL) throws {
        try sqliteExecute(db, [
            "ALTER TABLE media_checks RENAME TO media_checks_wide",
            CatalogDataSchema.mediaChecks[0],
            "INSERT INTO media_checks (digest, kind, status, note, checked_at, card, provenance) SELECT digest, kind, status, note, checked_at, card, provenance FROM media_checks_wide",
            "DROP TABLE media_checks_wide",
            "DELETE FROM grdb_migrations WHERE identifier = '\(CatalogAudioStatusSchema.migrationID)'",
            "UPDATE catalog_state SET schema_version = 16 WHERE singleton = 1",
        ])
        try sqliteExecute(db, ["PRAGMA user_version = 16"])
    }

    @Test("a .backup copy of the live catalog AS IT IS opens at 17: every table keeps its rows, every media_checks row is unchanged, integrity ok, the loader reads every row")
    func theLiveCatalogOpensWithEveryRowKept() async throws {
        let scene = try Shape.copy("prodshape_v17"); defer { scene.cleanup() }
        let db = scene.databaseURL
        let before = try Shape.schema(db)
        try #require(before.state >= 14 && before.state <= 17, "the copy is at schema \(before.state)")
        let tables = try Shape.tables(db)
        let rowsBefore = try Shape.counts(db, tables)
        let checksBefore = try Self.mediaChecks(db)
        try Shape.witnessGeneration(scene, host: "prodshape-v17")

        let opened = await Shape.open(db, host: "prodshape-v17")
        #expect(opened == .readWrite, "\(opened)")

        let after = try Shape.schema(db)
        #expect(after.state == 17 && after.pragma == 17, "schema \(after.state), user_version \(after.pragma)")
        let rowsAfter = try Shape.counts(db, tables)
        let changed = rowsBefore.filter { rowsAfter[$0.key] != $0.value }.keys.sorted()
        #expect(changed.isEmpty, "row counts moved in: \(changed)")
        let checksAfter = try Self.mediaChecks(db)
        #expect(checksAfter == checksBefore,
                "media_checks: \(checksBefore.subtracting(checksAfter).count) row(s) lost or changed, \(checksAfter.subtracting(checksBefore).count) appeared")
        let loaded = try await Shape.expectWhole(db, "as it is")
        print("v17 production shape (as it is): schema \(before.state) → \(after.state); \(tables.count) tables, "
              + "\(checksBefore.count) media_checks rows kept; \(loaded) records loaded")
    }

    @Test("the copy rewound to 16 (media_checks narrowed, the step unrecorded) migrates to 17: every media_checks row is the row it was, every table keeps its rows, the table is the widened one")
    func theRewoundCopyMigratesRowForRow() async throws {
        let scene = try Shape.copy("prodshape_v17_rewound"); defer { scene.cleanup() }
        let db = scene.databaseURL
        let live = try Shape.schema(db)
        try #require(live.state >= 14 && live.state <= 17,
                     "the copy is at schema \(live.state): this build understands 14…17; a later schema means this test is due for its successor")
        if live.state < 17 {
            try Shape.witnessGeneration(scene, host: "prodshape-v17-rewound")
            let forward = await Shape.open(db, host: "prodshape-v17-rewound")
            try #require(forward == .readWrite, "the copy at \(live.state) did not open on this build: \(forward)")
        }
        let newWords = try sqliteTable(db, "SELECT count(*) FROM media_checks WHERE kind = 'audio' AND status IN ('attention','unverified')")
            .first?.first ?? "?"
        guard newWords == "0" else {
            print("v17 production shape (rewound): the copy holds \(newWords) v1.16 audio word(s); the narrow v16 table cannot hold them — (a) covers this copy")
            return
        }
        try Self.rewindToSixteen(db)
        let before = try Shape.schema(db)
        try #require(before.state == 16 && before.pragma == 16, "rewound to \(before.state) / user_version \(before.pragma)")
        let tables = try Shape.tables(db)
        let rowsBefore = try Shape.counts(db, tables)
        let checksBefore = try Self.mediaChecks(db)
        try Shape.witnessGeneration(scene, host: "prodshape-v17-rewound")

        let opened = await Shape.open(db, host: "prodshape-v17-rewound")
        #expect(opened == .readWrite, "\(opened)")

        let after = try Shape.schema(db)
        #expect(after.state == 17 && after.pragma == 17, "schema \(after.state), user_version \(after.pragma)")
        let rowsAfter = try Shape.counts(db, tables)
        let changed = rowsBefore.filter { rowsAfter[$0.key] != $0.value }.keys.sorted()
        #expect(changed.isEmpty, "row counts moved in: \(changed)")
        #expect(try Self.mediaChecks(db) == checksBefore, "every media_checks row, every column")
        let sql = try sqliteTable(db, "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'media_checks'").first?.first
        #expect(sql == CatalogAudioStatusSchema.mediaChecks, "the widened table, under its own name")
        let loaded = try await Shape.expectWhole(db, "rewound")
        print("v17 production shape (rewound): \(live.state) → 16 → \(after.state); \(tables.count) tables, "
              + "\(checksBefore.count) media_checks rows kept row-for-row; \(loaded) records loaded")
    }
}
