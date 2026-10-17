// CatalogDataSchemaScaleTests.swift
// SCALE: 100k `files` + 100k `content` + 300k `knowledge_sources` rows, raw
// SQL, ONE transaction through the store's own write door (body, CAS,
// high-water, history row, commit) — every BEFORE INSERT trigger of the
// DDL runs for every row. Load-aware budget (TimingBudget, GH #208). Then
// `integrity_check`, and the two queries the app runs — the path-prefix
// range and the digest lookup — each under 10 ms with its EXPLAIN QUERY
// PLAN pinned to the index (no SCAN of files).
//
// Why this test exists: the DDL's `files_no_replace` trigger as first
// written could use neither partial index and walked the volume's rows on
// every insert — 20k rows took 23.6 s and 100k would have taken ten
// minutes. The v1.4 rewrite (two EXISTS terms) is what this test pins.
//
// Memory: rows are generated and bound one at a time through cached
// prepared statements; nothing is buffered. Worst case is SQLite's own
// page cache (default 2 MB) plus the WAL on disk (~120 MB for this
// transaction), not process memory.

import Foundation
import GRDB
import SQLite3
import Testing
@testable import VideoScanCore

@Suite("CatalogDataSchemaScale", .serialized)   // one measurement at a time
struct CatalogDataSchemaScaleTests {

    static let rows = 100_000
    static let fieldsPerRow = ["starRating", "userNotes", "tags"]
    static let volume = SchemaSeed.volume

    /// Measured 2026-10-17, M4 Max, Debug, load 5.4 on 16 cores: the 500k-row
    /// transaction in 13.3 s (~26 µs per row through the triggers); the
    /// prefix range 24 µs and the digest lookup 17 µs, best of five. Budgets
    /// ≈ 4.5× the import, and the brief's 10 ms for each lookup (400× the
    /// measurement: an index either answers or it does not).
    static let importBudget: Duration = .seconds(60)
    static let lookupBudget: Duration = .milliseconds(10)

    private static func digest(_ index: Int) -> String {
        let hex = String(index, radix: 16)
        return String(repeating: "0", count: 64 - hex.count) + hex
    }

    private static func fileID(_ index: Int) -> String {
        let hex = String(index, radix: 16, uppercase: true)
        return "00000000-0000-0000-0000-" + String(repeating: "0", count: 12 - hex.count) + hex
    }

    /// 1,000 folders of 100 files, so a folder prefix is a real range.
    private static func path(_ index: Int) -> String {
        "/Volumes/A/d\(String(format: "%04d", index / 100))/Clip\(String(format: "%06d", index)).mov"
    }

    /// The import, inside the store's one transaction. Cached statements:
    /// one compile per shape, one bind per row.
    private static func importRows(_ db: Database) throws {
        try db.execute(sql: SchemaSeed.volumeInsert)
        try db.execute(sql: "INSERT INTO import_runs (run_id, started_at, source_sha256, source_generation, integrity_run_id, audit_run_started_at, audit_run_finished_at, audit_generation, integrity_started_at, integrity_generation) VALUES ('R-scale', 1, ?, 0, 'IR-scale', 1, 2, 0, 3, 0)",
                       arguments: [String(repeating: "d", count: 64)])
        let content = try db.cachedStatement(sql: "INSERT INTO content (digest, byte_count, first_seen_at, first_seen_how) VALUES (?, ?, 1700000000, 'import')")
        let file = try db.cachedStatement(sql: """
            INSERT INTO files (id, content_digest, volume_uuid, volume_case_sensitive, full_path, path_fold, filename, ext, directory,
                               size_bytes, digest_computed_at, digest_source, stream_type, lifecycle, archive_stage)
            VALUES (?, ?, ?, 0, ?, ?, ?, 'mov', ?, ?, 1700000000, 'archiveFixity', 'Video+Audio', 'Cataloged', 'None')
            """)
        let knowledge = try db.cachedStatement(sql: "INSERT INTO knowledge_sources (import_run, source_ordinal, json_row_id, digest, field, value_json) VALUES ('R-scale', ?, ?, ?, ?, ?)")
        for index in 0..<rows {
            let digest = digest(index)
            let id = fileID(index)
            let path = path(index)
            let size = 1_000 + index
            try content.execute(arguments: [digest, size])
            try file.execute(arguments: [id, digest, volume, path, path.lowercased(), "Clip\(index).mov", "/Volumes/A/d\(index / 100)", size])
            try knowledge.execute(arguments: [index, id, digest, "starRating", "3"])
            try knowledge.execute(arguments: [index, id, digest, "userNotes", "\"note \(index)\""])
            try knowledge.execute(arguments: [index, id, digest, "tags", "[\"family\"]"])
        }
    }

    private struct Lookup {
        let label: String
        let sql: String
        let arguments: StatementArguments
        let index: String
    }

    private static let lookups = [
        Lookup(label: "path-prefix range (one folder of 100)",
               sql: "SELECT count(*) FROM files WHERE volume_uuid = ? AND full_path >= ? AND full_path < ? || X'FF'",
               arguments: [volume, "/Volumes/A/d0500/", "/Volumes/A/d0500/"], index: "files_by_path_prefix"),
        Lookup(label: "digest lookup",
               sql: "SELECT id FROM files WHERE content_digest = ?",
               arguments: [digest(73_421)], index: "files_by_digest"),
    ]

    /// Best of five on a reader connection: the index either answers in
    /// microseconds or it does not; the minimum removes scheduling noise.
    private static func bestOfFive(_ lookup: Lookup, _ db: Database) throws -> Duration {
        let clock = ContinuousClock()
        var best: Duration = .seconds(1)
        for _ in 0..<5 {
            let start = clock.now
            _ = try Row.fetchAll(db, sql: lookup.sql, arguments: lookup.arguments)
            best = min(best, clock.now - start)
        }
        return best
    }

    private static func plan(_ lookup: Lookup, _ db: Database) throws -> String {
        try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + lookup.sql, arguments: lookup.arguments)
            .map { $0[3] as String }.joined(separator: " | ")
    }

    @Test func hundredThousandFilesInOneImportTransaction() async throws {
        let fixture = StoreFixture(kind: .grdb, directory: try StoreFixture.temporaryDirectory())
        defer { fixture.remove() }
        let repository = GRDBCatalogRepository(host: "scale-host", durability: .volatileForTests)
        let opened = await repository.open(at: fixture.url)
        try #require(opened == .readWrite)

        let loadBefore = TimingBudget.sampleLoad()
        let clock = ContinuousClock()
        let start = clock.now
        let outcome = await repository.write(as: .importRun) { transaction in
            guard let grdb = transaction as? GRDBTransaction else { throw FixtureFailure(words: "not a GRDB transaction") }
            try Self.importRows(grdb.db)
        }
        let elapsed = clock.now - start
        #expect(outcome == .committed(generation: 1))
        print("[schema-scale] 100k files + 100k content + 300k knowledge rows in one transaction: \(elapsed) (\(TimingBudget.loadDescription()))")
        expectWithinTimingBudget("100k-row import transaction", measured: elapsed,
                                 budget: Self.importBudget, loadBefore: loadBefore)

        let counts = try await repository.read { reader -> [Int] in
            guard let grdb = reader as? GRDBReader else { throw FixtureFailure(words: "not a GRDB reader") }
            return try ["files", "content", "knowledge_sources"].map { table in
                try Int.fetchOne(grdb.db, sql: "SELECT count(*) FROM \(table)") ?? -1
            }
        }
        #expect(counts == [Self.rows, Self.rows, Self.rows * Self.fieldsPerRow.count])

        let integrity = try await repository.read { reader -> [String] in
            guard let grdb = reader as? GRDBReader else { throw FixtureFailure(words: "not a GRDB reader") }
            return try String.fetchAll(grdb.db, sql: "PRAGMA integrity_check")
        }
        #expect(integrity == ["ok"])

        for lookup in Self.lookups {
            let loadBeforeLookup = TimingBudget.sampleLoad()
            let (best, plan) = try await repository.read { reader -> (Duration, String) in
                guard let grdb = reader as? GRDBReader else { throw FixtureFailure(words: "not a GRDB reader") }
                return (try Self.bestOfFive(lookup, grdb.db), try Self.plan(lookup, grdb.db))
            }
            print("[schema-scale] \(lookup.label): best of 5 = \(best); plan: \(plan)")
            // "USING INDEX …" or "USING COVERING INDEX …" (the range needs no table row at all).
            #expect(plan.contains("INDEX \(lookup.index) "), Comment(rawValue: plan))
            #expect(!plan.contains("SCAN files"), Comment(rawValue: plan))
            expectWithinTimingBudget(lookup.label, measured: best, budget: Self.lookupBudget, loadBefore: loadBeforeLookup)
        }
        await repository.close()
    }

    // MARK: - Codex C′ #7: the N2 conflict trigger must not be quadratic

    /// Codex measured ~56k / 192k / 704k VM steps for 100 / 200 / 400
    /// identical-value sources: `derived_unverified_flags_conflict` walked
    /// every row sharing (digest, kind, seq) on each insert. VM steps are
    /// SQLite's own count of work done (`sqlite3_stmt_status`, the trigger's
    /// steps included), so the growth ratio is deterministic; wall time is
    /// budgeted load-aware beside it.
    @Test func identicalDerivedValuesFlagConflictsInLinearWork() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        let queue = try DatabaseQueue(path: fixture.url.path)
        let sizes = [100, 400, 1_600]
        var steps: [Int: Int] = [:]
        var elapsed: [Int: Duration] = [:]
        let clock = ContinuousClock()
        let loadBefore = TimingBudget.sampleLoad()
        try queue.inDatabase { db in
            for (group, size) in sizes.enumerated() {
                let digest = Self.digest(0xC7_0000 + group)
                try db.execute(sql: "INSERT INTO content (digest, byte_count, first_seen_at, first_seen_how) VALUES (?, 1, 1, 'job')", arguments: [digest])
                let insert = try db.cachedStatement(sql: "INSERT INTO derived_unverified (digest, kind, seq, source_json_row_id, value_json) VALUES (?, 'scene', 0, ?, '{\"text\":\"the same caption\"}')")
                var total = 0
                let start = clock.now
                try db.inTransaction {
                    for row in 0..<size {
                        try insert.execute(arguments: [digest, Self.fileID(row)])
                        total += Int(sqlite3_stmt_status(insert.sqliteStatement, SQLITE_STMTSTATUS_VM_STEP, 1))
                    }
                    return .commit
                }
                steps[size] = total
                elapsed[size] = clock.now - start
                // The verdict is unchanged: identical values, no conflict; one different value flags them all.
                let flagged = try Int.fetchOne(db, sql: "SELECT count(*) FROM derived_unverified WHERE digest = ? AND conflict = 1", arguments: [digest]) ?? -1
                #expect(flagged == 0)
                try db.execute(sql: "INSERT INTO derived_unverified (digest, kind, seq, source_json_row_id, value_json) VALUES (?, 'scene', 0, ?, '{\"text\":\"a different caption\"}')",
                               arguments: [digest, Self.fileID(size)])
                let flaggedAfter = try Int.fetchOne(db, sql: "SELECT count(*) FROM derived_unverified WHERE digest = ? AND conflict = 1", arguments: [digest]) ?? -1
                #expect(flaggedAfter == size + 1)
            }
        }
        for size in sizes {
            print("[schema-scale] \(size) identical derived values: \(steps[size] ?? 0) VM steps (\((steps[size] ?? 0) / size) per row), \(elapsed[size] ?? .zero)")
        }
        let growth = Double(steps[1_600] ?? 0) / Double(max(steps[400] ?? 1, 1))
        #expect(growth < 6, "4× the rows cost \(growth)× the work (linear ≈ 4, the quadratic trigger measured ≈ 16)")
        expectWithinTimingBudget("1,600 identical derived values through the conflict trigger",
                                 measured: elapsed[1_600] ?? .zero, budget: Self.conflictBudget, loadBefore: loadBefore)
    }

    /// 1,600 inserts through two indexed probes each: a few ms. Budgeted at
    /// 1 s so a return of the quadratic walk (hundreds of ms) is a miss.
    static let conflictBudget: Duration = .seconds(1)
}
