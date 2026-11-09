// ProductionShapePublicMarksMigrationTests.swift
// Schema v16 (`v11_public_marks`, Make Public, Rick 2026-11-09) at PRODUCTION
// SHAPE: a sqlite `.backup` copy of Rick's live catalog (read-only URI on the
// live file — LiveCatalogCopy), opened by this build's store in a temp folder.
// The live catalog itself is never opened for writing here.
//
// Invariants, true of ANY real catalog (before and after Rick's own catalog
// has taken the step):
//   (a) the catalog AS IT IS opens on this build at 16: every table keeps its
//       row count, every `public_marks` row that was there is there unchanged
//       (a re-open never re-runs or rewrites the migration), integrity and
//       foreign keys ok, the loader reads every files row;
//   (b) the same copy REWOUND to 15 (public_marks dropped, the migration
//       unrecorded, both version stamps 15) migrates to 16 with every other
//       table's rows kept and `public_marks` new and EMPTY — after the step
//       every video is private;
//   (c) on the migrated copy the door flips one real content's bit and flips
//       it back: the current bit follows, both rows are appended after its
//       earlier history, no other table's row count moves.
//
// ISOLATION / real global state: reads the live catalog, so it is NOT a
// sensor-lane test; anywhere without the live catalog + latch it is SKIPPED
// (`.enabled(if:)`, with the reason). PRIVACY: counts only, never paths,
// names or digests.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Production-shape v15 → v16 migration of the live catalog (Make Public) — ISOLATION: reads the real catalog",
       .serialized, .enabled(if: LiveCatalogCopy.present, LiveCatalogCopy.skipWords))
@MainActor
struct ProductionShapePublicMarksMigrationTests {

    private typealias Shape = ProductionShapeSoundAttemptsMigrationTests

    static let markColumns = "mark_id, digest, is_public, decided_at"

    static func marks(_ db: URL) throws -> Set<String> {
        Set(try sqliteTable(db, "SELECT \(markColumns) FROM public_marks").map { $0.joined(separator: "|") })
    }

    /// Rewind a copy at 16 to 15: the table (with its index and triggers),
    /// the migration's record and both version stamps.
    static func rewindToFifteen(_ db: URL) throws {
        try sqliteExecute(db, [
            "DROP TABLE public_marks",
            "DELETE FROM grdb_migrations WHERE identifier = 'v11_public_marks'",   // CatalogPublicMarksSchema.migrationID (Core-internal)
            "UPDATE catalog_state SET schema_version = 15 WHERE singleton = 1",
        ])
        try sqliteExecute(db, ["PRAGMA user_version = 15"])
    }

    @Test("a .backup copy of the live catalog AS IT IS opens at 16: every table keeps its rows, every public_marks row is kept unchanged, integrity ok, the loader reads every row")
    func theLiveCatalogOpensWithEveryRowKept() async throws {
        let scene = try Shape.copy("prodshape_v16"); defer { scene.cleanup() }
        let db = scene.databaseURL
        let before = try Shape.schema(db)
        try #require(before.state >= 14 && before.state <= 16, "the copy is at schema \(before.state)")
        let tables = try Shape.tables(db)
        let rowsBefore = try Shape.counts(db, tables)
        let marksBefore = tables.contains("public_marks") ? try Self.marks(db) : []
        try Shape.witnessGeneration(scene, host: "prodshape-v16")

        let opened = await Shape.open(db, host: "prodshape-v16")
        #expect(opened == .readWrite, "\(opened)")

        let after = try Shape.schema(db)
        #expect(after.state == 16 && after.pragma == 16, "schema \(after.state), user_version \(after.pragma)")
        let rowsAfter = try Shape.counts(db, tables)
        let changed = rowsBefore.filter { rowsAfter[$0.key] != $0.value }.keys.sorted()
        #expect(changed.isEmpty, "row counts moved in: \(changed)")
        let marksAfter = try Self.marks(db)
        #expect(marksAfter == marksBefore,
                "public_marks: \(marksBefore.subtracting(marksAfter).count) row(s) lost or changed, \(marksAfter.subtracting(marksBefore).count) appeared")
        let loaded = try await Shape.expectWhole(db, "as it is")
        // Never silent about which path ran: the step, or a re-open of a catalog already past it.
        print("v16 production shape (as it is): schema \(before.state) → \(after.state) "
              + (before.state < 16 ? "(the migration ran)" : "(already 16: re-open, the migration did not run again)")
              + "; \(tables.count) tables, \(rowsBefore.values.reduce(0, +)) rows unchanged; \(marksBefore.count) public_marks row(s) kept; "
              + "\(loaded) records loaded")
    }

    @Test("the copy rewound to 15 (public_marks dropped, the step unrecorded) migrates to 16: every other table keeps its rows, public_marks is new and empty — everything private — integrity ok")
    func theRewoundCopyMigratesWithEveryRowKeptAndEverythingPrivate() async throws {
        let scene = try Shape.copy("prodshape_v16_rewound"); defer { scene.cleanup() }
        let db = scene.databaseURL
        let live = try Shape.schema(db)
        try #require(live.state == 15 || live.state == 16,
                     "the copy is at schema \(live.state): this build migrates 15 → 16; a later schema means this test is due for its successor")
        if live.state == 16 { try Self.rewindToFifteen(db) }
        let before = try Shape.schema(db)
        try #require(before.state == 15 && before.pragma == 15, "rewound to \(before.state) / user_version \(before.pragma)")
        let tables = try Shape.tables(db)
        try #require(!tables.contains("public_marks"), "the rewound copy still has public_marks")
        let rowsBefore = try Shape.counts(db, tables)
        try Shape.witnessGeneration(scene, host: "prodshape-v16-rewound")

        let opened = await Shape.open(db, host: "prodshape-v16-rewound")
        #expect(opened == .readWrite, "\(opened)")

        let after = try Shape.schema(db)
        #expect(after.state == 16 && after.pragma == 16, "schema \(after.state), user_version \(after.pragma)")
        let rowsAfter = try Shape.counts(db, tables)
        let changed = rowsBefore.filter { rowsAfter[$0.key] != $0.value }.keys.sorted()
        #expect(changed.isEmpty, "row counts moved in: \(changed)")
        #expect(try sqliteTable(db, "SELECT count(*) FROM public_marks").first?.first == "0", "the new table starts empty: every video is private")
        let loaded = try await Shape.expectWhole(db, "rewound")
        print("v16 production shape (rewound): \(live.state) → 15 → \(after.state); \(tables.count) tables, "
              + "\(rowsBefore.values.reduce(0, +)) rows unchanged; \(loaded) records loaded")
    }

    @Test("on the migrated copy the door flips one real content's bit and flips it back: the current bit follows, both rows are appended after its earlier history, no other table's row count moves")
    func theDoorMarksARealContentOnTheMigratedCopy() async throws {
        let scene = try Shape.copy("prodshape_v16_mark"); defer { scene.cleanup() }
        let db = scene.databaseURL
        try Shape.witnessGeneration(scene, host: "prodshape-v16-mark")
        #expect(await Shape.open(db, host: "prodshape-v16-mark") == .readWrite)
        // ANY stored content (Codex #273 F3: a catalog where every content
        // already has mark history is valid too). The test flips its bit
        // and flips it back, so the copy ends where it began.
        let digest = try #require(try sqliteTable(db, "SELECT digest FROM content ORDER BY digest LIMIT 1").first?.first,
                                  "the copy has no content")
        let tables = try Shape.tables(db).filter { $0 != "public_marks" && $0 != "generation_history" && $0 != "generations" }
        let rowsBefore = try Shape.counts(db, tables)
        let marksBefore = try Self.marks(db).count

        let repository = GRDBCatalogRepository(host: "prodshape-v16-mark")
        try #require(await repository.open(at: db) == .readWrite)
        let historyBefore = try await repository.read { try $0.publicMarkHistory(digest: digest) }
        let was = historyBefore.last?.isPublic ?? false
        let flip = await repository.write(as: .ui) { tx in
            _ = try tx.appendPublicMark(CatalogRow.PublicMarkDecision(digest: digest, isPublic: !was, decidedAt: 1_794_200_000))
        }
        guard case .committed = flip else { Issue.record("flip: \(flip)"); await repository.close(); return }
        let flipped = try await repository.read { try $0.currentPublicMarks(digests: [digest]) }
        #expect(flipped[digest]?.isPublic == !was)
        let flipBack = await repository.write(as: .ui) { tx in
            _ = try tx.appendPublicMark(CatalogRow.PublicMarkDecision(digest: digest, isPublic: was, decidedAt: 1_794_200_001))
        }
        guard case .committed = flipBack else { Issue.record("flip back: \(flipBack)"); await repository.close(); return }
        let restored = try await repository.read { try $0.currentPublicMarks(digests: [digest]) }
        #expect(restored[digest]?.isPublic == was)
        let history = try await repository.read { try $0.publicMarkHistory(digest: digest) }
        #expect(Array(history.prefix(historyBefore.count)) == historyBefore, "the earlier history is untouched")
        #expect(history.dropFirst(historyBefore.count).map(\.isPublic) == [!was, was])
        await repository.close()

        #expect(try Self.marks(db).count == marksBefore + 2, "two rows appended, none rewritten")
        let rowsAfter = try Shape.counts(db, tables)
        let changed = rowsBefore.filter { rowsAfter[$0.key] != $0.value }.keys.sorted()
        #expect(changed.isEmpty, "row counts moved in: \(changed)")
        #expect(try sqliteTable(db, "PRAGMA integrity_check").map { $0[0] } == ["ok"])
        #expect(try sqliteTable(db, "PRAGMA foreign_key_check").isEmpty)
        print("v16 production shape (mark): one content's bit flipped and flipped back on the copy; \(tables.count) other tables, "
              + "\(rowsBefore.values.reduce(0, +)) rows unchanged")
    }
}
