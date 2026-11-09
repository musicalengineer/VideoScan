// CatalogPublicMarksTests.swift
// The public bit in catalog.sqlite (schema v1.15 = version 16, migration
// `v11_public_marks`; CatalogPublicMarkRows.swift,
// GRDBCatalogRepository+PublicMarks.swift). Rick 2026-11-09: "if the bit is
// off, it is presumed private."
//   LOGIC      — no row is private (absent); every choice is a new row
//                (history kept); the newest row (highest mark_id) is current
//                even when its decided_at is older; Make Private appends a 0
//                row, never a DELETE; a digest that is not stored content
//                writes nothing (`contentMissing`); the whole-table reading
//                returns one current row per digest; a digest in any case is
//                the same content.
//   GUARDS     — UPDATE / DELETE refused with the trigger's words; a flag
//                outside 0/1, a non-integer flag and a digest that is not
//                content are refused by the CHECK / STRICT / foreign key.
//   ISOLATION  — a poisoned row (flag 2, smuggled in with CHECKs off) reads
//                back verbatim as UNREADABLE and PRIVATE — the bit fails
//                closed — and nothing throws; found at open, the file is
//                refused in words.
//   MIGRATION  — a schema-15 database with content opens as 16, the table
//                empty (everything private), every content row intact; a v16
//                file is refused in words by the gate a v15 build ran.
//   READ-ONLY  — a read-only open refuses a mark: nothing lands.
//   SCALE      — 100k contents with a mark (some with history): the whole
//                current reading and 1,000 single lookups inside budgets.
// One condition per #expect. Synthetic digests only.

import Foundation
import GRDB
import Testing
@testable import VideoScanCore

@Suite("CatalogPublicMarks")
struct CatalogPublicMarksTests {

    private static func hex(_ n: Int) -> String { String(format: "%064x", n) }

    private func open(_ fixture: StoreFixture) async throws -> GRDBCatalogRepository {
        let repository = GRDBCatalogRepository(host: "test-host", durability: .volatileForTests)
        let opened = await repository.open(at: fixture.url)
        try #require(opened == .readWrite)
        return repository
    }

    /// `count` content rows hex(1)…hex(count), raw (one transaction).
    private func seedContent(_ fixture: StoreFixture, count: Int) throws {
        try DatabaseQueue(path: fixture.url.path).inDatabase { db in
            try db.inTransaction {
                for n in 1...count {
                    try db.execute(sql: "INSERT INTO content (digest, byte_count, first_seen_at, first_seen_how) VALUES (?, 100, 1700000000, 'rescan')",
                                   arguments: [Self.hex(n)])
                }
                return .commit
            }
        }
    }

    private static func decision(_ n: Int, _ isPublic: Bool, at: Int64 = 1_794_000_000) -> CatalogRow.PublicMarkDecision {
        CatalogRow.PublicMarkDecision(digest: hex(n), isPublic: isPublic, decidedAt: at)
    }

    private func refusal(_ fixture: StoreFixture, _ sql: String, checksOff: Bool = false) -> String? {
        do {
            try DatabaseQueue(path: fixture.url.path).inDatabase { db in
                if checksOff { try db.execute(sql: "PRAGMA ignore_check_constraints = ON") }
                try db.execute(sql: sql)
            }
            return nil
        } catch {
            return ChecksRun.words(error)
        }
    }

    private func current(_ repository: GRDBCatalogRepository, _ digests: [Int]) async throws -> [String: CatalogRow.PublicMarkReading] {
        let keys = digests.map(Self.hex)
        return try await repository.read { try $0.currentPublicMarks(digests: keys) }
    }

    // MARK: - Logic

    @Test func noRowIsPrivateAndTheNewestRowIsCurrent() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        try seedContent(fixture, count: 2)
        let repository = try await open(fixture)
        let landings = MarkLandingBox()
        // decided_at deliberately runs BACKWARDS: insertion order decides, never the clock.
        _ = await repository.write(as: .ui) { tx in
            landings.values.append(try tx.appendPublicMark(Self.decision(1, false, at: 300)))
        }
        _ = await repository.write(as: .ui) { tx in
            landings.values.append(try tx.appendPublicMark(Self.decision(1, true, at: 200)))
        }
        #expect(landings.values == [.recorded, .recorded])
        let now = try await current(repository, [1, 2])
        #expect(now[Self.hex(1)]?.isPublic == true)
        #expect(now[Self.hex(1)]?.decidedAt == 200)
        #expect(now[Self.hex(2)] == nil, "no row = private, absent")
        let history = try await repository.read { try $0.publicMarkHistory(digest: Self.hex(1)) }
        #expect(history.map(\.isPublic) == [false, true], "the history is kept, oldest first")
        await repository.close()
    }

    @Test func makePrivateAppendsAZeroRowAndNeverDeletes() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        try seedContent(fixture, count: 1)
        let repository = try await open(fixture)
        _ = await repository.write(as: .ui) { tx in _ = try tx.appendPublicMark(Self.decision(1, true)) }
        _ = await repository.write(as: .ui) { tx in _ = try tx.appendPublicMark(Self.decision(1, false)) }
        let now = try await current(repository, [1])
        #expect(now[Self.hex(1)]?.isPublic == false)
        #expect(now[Self.hex(1)]?.storedFlag == 0)
        let history = try await repository.read { try $0.publicMarkHistory(digest: Self.hex(1)) }
        #expect(history.count == 2, "private again is a row, never a DELETE")
        await repository.close()
    }

    @Test func onlyAnExactOneIsPublic() {
        func reading(_ flag: Int64) -> CatalogRow.PublicMarkReading {
            CatalogRow.PublicMarkReading(markID: 1, digest: Self.hex(1), storedFlag: flag, decidedAt: 1)
        }
        #expect(reading(1).isPublic)
        #expect(!reading(0).isPublic)
        #expect(!reading(2).isPublic, "an unreadable flag is private")
        #expect(!reading(-1).isPublic)
        #expect(reading(0).readable)
        #expect(reading(1).readable)
        #expect(!reading(2).readable)
    }

    @Test func aDigestThatIsNotContentWritesNothing() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        try seedContent(fixture, count: 1)
        let repository = try await open(fixture)
        let landings = MarkLandingBox()
        _ = await repository.write(as: .ui) { tx in
            landings.values.append(try tx.appendPublicMark(Self.decision(99, true)))
        }
        #expect(landings.values == [.contentMissing])
        let rows = try await repository.read { try $0.publicMarkHistory(digest: Self.hex(99)) }
        #expect(rows.isEmpty)
        await repository.close()
    }

    @Test func aDigestInAnyCaseIsTheSameContent() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        try seedContent(fixture, count: 0xabc)
        let repository = try await open(fixture)
        let upper = Self.hex(0xabc).uppercased()
        _ = await repository.write(as: .ui) { tx in
            _ = try tx.appendPublicMark(CatalogRow.PublicMarkDecision(digest: upper, isPublic: true, decidedAt: 1))
        }
        let now = try await repository.read { try $0.currentPublicMarks(digests: [upper]) }
        #expect(now[Self.hex(0xabc)]?.isPublic == true)
        await repository.close()
    }

    @Test func theWholeTableReadingGivesOneCurrentRowPerDigest() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        try seedContent(fixture, count: 3)
        let repository = try await open(fixture)
        _ = await repository.write(as: .ui) { tx in
            _ = try tx.appendPublicMark(Self.decision(2, true))
            _ = try tx.appendPublicMark(Self.decision(1, true))
            _ = try tx.appendPublicMark(Self.decision(2, false))
        }
        let all = try await repository.read { reader -> [CatalogRow.PublicMarkReading] in
            var out: [CatalogRow.PublicMarkReading] = []
            try reader.currentPublicMarks { out.append($0) }
            return out
        }
        #expect(all.map(\.digest) == [Self.hex(1), Self.hex(2)])
        #expect(all.map(\.isPublic) == [true, false])
        await repository.close()
    }

    // MARK: - Guards

    @Test func theTableIsAppendOnlyAndItsChecksHold() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        try seedContent(fixture, count: 1)
        let repository = try await open(fixture)
        _ = await repository.write(as: .ui) { tx in _ = try tx.appendPublicMark(Self.decision(1, true)) }
        await repository.close()
        #expect(refusal(fixture, "UPDATE public_marks SET is_public = 0") == "public_marks is append-only history")
        #expect(refusal(fixture, "DELETE FROM public_marks") == "public_marks is append-only history")
        let badFlag = refusal(fixture, "INSERT INTO public_marks (digest, is_public, decided_at) VALUES ('\(Self.hex(1))', 2, 1)")
        #expect(badFlag?.contains("CHECK constraint failed") == true, "the bit is 0 or 1")
        let words = refusal(fixture, "INSERT INTO public_marks (digest, is_public, decided_at) VALUES ('\(Self.hex(1))', 'yes', 1)")
        #expect(words != nil, "STRICT: is_public is an INTEGER")
        let orphan = refusal(fixture, "INSERT INTO public_marks (digest, is_public, decided_at) VALUES ('\(Self.hex(7))', 1, 1)")
        #expect(orphan == "FOREIGN KEY constraint failed")
        #expect(refusal(fixture, "DELETE FROM content") == "FOREIGN KEY constraint failed", "a mark pins its content")
    }

    // MARK: - Isolation: a poisoned row

    /// The poison arrives WHILE the store is open (a foreign writer with
    /// CHECKs off): the open's integrity check already passed, so the reader
    /// itself must cope — and must say PRIVATE.
    @Test func aPoisonedFlagReadsAsUnreadableAndPrivateAndNeverThrows() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        try seedContent(fixture, count: 1)
        let repository = try await open(fixture)
        let smuggled = refusal(fixture, "INSERT INTO public_marks (digest, is_public, decided_at) VALUES ('\(Self.hex(1))', 2, 5)",
                               checksOff: true)
        try #require(smuggled == nil, "the poison landed with CHECKs off: \(smuggled ?? "")")
        let now = try await current(repository, [1])
        let row = try #require(now[Self.hex(1)])
        #expect(row.storedFlag == 2, "read back verbatim")
        #expect(!row.readable)
        #expect(!row.isPublic, "fail closed: an unreadable bit is private")
        await repository.close()
    }

    /// The same poison found at OPEN: the store's integrity check refuses
    /// the file with words (never a crash, never a silent read-write open).
    @Test func aFileHoldingAPoisonedFlagIsRefusedAtOpenWithWords() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        try seedContent(fixture, count: 1)
        let smuggled = refusal(fixture, "INSERT INTO public_marks (digest, is_public, decided_at) VALUES ('\(Self.hex(1))', 2, 5)",
                               checksOff: true)
        try #require(smuggled == nil)
        let repository = GRDBCatalogRepository(host: "test-host", durability: .volatileForTests)
        let outcome = await repository.open(at: fixture.url)
        guard case .refused(let words) = outcome else {
            Issue.record("expected .refused, got \(outcome)")
            await repository.close()
            return
        }
        #expect(words.contains("public_marks"), "the words name the table: \(words)")
        await repository.close()
    }

    // MARK: - Migration from a schema-15 database

    @Test func aSchemaFifteenDatabaseOpensAsSixteenWithEveryContentRowIntactAndEverythingPrivate() async throws {
        let fixture = StoreFixture(kind: .grdb, directory: try StoreFixture.temporaryDirectory())
        defer { fixture.remove() }
        var v114 = DatabaseMigrator()
        v114.registerMigration(CatalogBookkeepingSchema.migrationID, foreignKeyChecks: .immediate) { db in
            for statement in CatalogBookkeepingSchema.statements { try db.execute(sql: statement) }
            try db.execute(sql: "PRAGMA user_version = 7")
            try db.execute(sql: "INSERT INTO catalog_state (singleton, schema_version) VALUES (1, 7)")
            try db.execute(sql: "INSERT INTO generations (id, generation, saved_at, saved_from_host) VALUES (1, 0, 1, 'v1.14')")
            try db.execute(sql: "INSERT INTO generation_history (generation, committed_at, host, writer, files_live, files_total) VALUES (0, 1, 'v1.14', 'create', 0, 0)")
        }
        let later: [(String, [String])] = [
            (CatalogDataSchema.migrationID, CatalogDataSchema.statements),
            (CatalogLiveWritesSchema.migrationID, CatalogLiveWritesSchema.statements + CatalogLiveWritesSchema.versionBump),
            (CatalogPendingRowsSchema.migrationID, CatalogPendingRowsSchema.statements + CatalogPendingRowsSchema.versionBump),
            (CatalogCommitB22Schema.migrationID, CatalogCommitB22Schema.statements + CatalogCommitB22Schema.versionBump),
            (CatalogFolderKindSchema.migrationID, CatalogFolderKindSchema.statements + CatalogFolderKindSchema.versionBump),
            (CatalogDecisionTablesSchema.migrationID, CatalogDecisionTablesSchema.statements + CatalogDecisionTablesSchema.versionBump),
            (CatalogProvenanceRolesSchema.migrationID, CatalogProvenanceRolesSchema.statements + CatalogProvenanceRolesSchema.versionBump),
            (CatalogProvenanceAssertionsSchema.migrationID,
             CatalogProvenanceAssertionsSchema.statements + CatalogProvenanceAssertionsSchema.versionBump),
            (CatalogSoundAttemptsSchema.migrationID, CatalogSoundAttemptsSchema.statements + CatalogSoundAttemptsSchema.versionBump),
        ]
        for (id, statements) in later {
            v114.registerMigration(id, foreignKeyChecks: .immediate) { db in
                for statement in statements { try db.execute(sql: statement) }
            }
        }
        let queue = try DatabaseQueue(path: fixture.url.path)
        try v114.migrate(queue)
        try queue.inDatabase { db in
            for n in 1...3 {
                try db.execute(sql: "INSERT INTO content (digest, byte_count, first_seen_at, first_seen_how) VALUES (?, 100, 1700000000, 'rescan')",
                               arguments: [Self.hex(n)])
            }
            try db.execute(sql: "INSERT INTO provenance_roles (digest, role, decided_at) VALUES (?, 'master', 1700000000)", arguments: [Self.hex(1)])
        }
        #expect(try queue.inDatabase { db in try Int.fetchOne(db, sql: "SELECT schema_version FROM catalog_state") } == 15)
        #expect(try queue.inDatabase { db in try db.tableExists("public_marks") } == false)
        try queue.close()
        try fixture.writeHighWater("0")

        let repository = try await open(fixture)
        #expect(try await current(repository, [1, 2, 3]).isEmpty, "every content is private after the migration")
        _ = await repository.write(as: .ui) { tx in _ = try tx.appendPublicMark(Self.decision(2, true)) }
        #expect(try await current(repository, [2])[Self.hex(2)]?.isPublic == true)
        await repository.close()
        let after = try DatabaseQueue(path: fixture.url.path).inDatabase { db in
            (try Int.fetchOne(db, sql: "SELECT schema_version FROM catalog_state"),
             try Int.fetchOne(db, sql: "PRAGMA user_version"),
             try Int.fetchOne(db, sql: "SELECT count(*) FROM content"),
             try Int.fetchOne(db, sql: "SELECT count(*) FROM provenance_roles"),
             try String.fetchAll(db, sql: "PRAGMA integrity_check"))
        }
        #expect(after.0 == 16)
        #expect(after.1 == 16)
        #expect(after.2 == 3)
        #expect(after.3 == 1, "the role Rick set is untouched")
        #expect(after.4 == ["ok"])
    }

    @Test func aSixteenFileIsRefusedInWordsByTheGateAFifteenBuildRan() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        let words: String? = try DatabaseQueue(path: fixture.url.path).inDatabase { db in
            do {
                try GRDBCatalogRepository.checkSchemaVersion(db, understands: CatalogSoundAttemptsSchema.schemaVersion)
                return nil
            } catch {
                return String(describing: error)
            }
        }
        #expect(words?.contains("schema version 16 is newer than this build understands (15) — open it with a newer VideoScan") == true, "\(words ?? "nil")")
    }

    // MARK: - Read-only

    @Test func aReadOnlyOpenRefusesAMark() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        try seedContent(fixture, count: 1)
        let repository = GRDBCatalogRepository(host: "test-host", durability: .volatileForTests)
        let opened = await repository.openReadOnly(at: fixture.url, reason: "test: a viewer")
        guard case .readOnly = opened else {
            Issue.record("expected .readOnly, got \(opened)")
            return
        }
        let outcome = await repository.write(as: .ui) { tx in _ = try tx.appendPublicMark(Self.decision(1, true)) }
        guard case .refused = outcome else {
            Issue.record("expected .refused, got \(outcome)")
            return
        }
        #expect(try await current(repository, [1]).isEmpty)
        await repository.close()
    }

    // MARK: - Scale

    /// 100k contents each marked public, 10k of them made private again (a
    /// second, newer row). Budgets (Debug, M4 Max): write 30 s; the whole
    /// current reading 5 s; 1,000 single-digest lookups 2 s — a scan per
    /// lookup (no `(digest, mark_id)` index) would be minutes. Load-aware.
    @Test(.timeLimit(.minutes(3)))
    func oneHundredThousandContentsCurrentBitInsideBudgets() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        let n = 100_000
        try seedContent(fixture, count: n)
        let repository = try await open(fixture)
        let clock = ContinuousClock()
        var outcome: CatalogWriteOutcome?
        let loadBeforeWrite = TimingBudget.sampleLoad()
        let write = await clock.measure {
            outcome = await repository.write(as: .ui) { tx in
                for i in 1...n { _ = try tx.appendPublicMark(Self.decision(i, true)) }
                for i in stride(from: 1, through: n, by: 10) { _ = try tx.appendPublicMark(Self.decision(i, false)) }
            }
        }
        #expect(outcome == .committed(generation: 1))
        var count = 0, publicCount = 0
        let loadBeforeRead = TimingBudget.sampleLoad()
        let reading = try await clock.measure {
            (count, publicCount) = try await repository.read { reader -> (Int, Int) in
                var c = 0, p = 0
                try reader.currentPublicMarks { row in
                    c += 1
                    if row.isPublic { p += 1 }
                }
                return (c, p)
            }
        }
        #expect(count == n)
        #expect(publicCount == n - n / 10)
        let probe = (0..<1_000).map { Self.hex(1 + $0 * 97) }
        var found: [String: CatalogRow.PublicMarkReading] = [:]
        let loadBeforeLookup = TimingBudget.sampleLoad()
        let lookup = try await clock.measure {
            found = try await repository.read { try $0.currentPublicMarks(digests: probe) }
        }
        print("[public-marks] 100k: write \(write), current read \(reading), 1,000 lookups \(lookup) (\(TimingBudget.loadDescription()))")
        #expect(found.count == 1_000)
        expectWithinTimingBudget("100k public marks written", measured: write, budget: .seconds(30), loadBefore: loadBeforeWrite)
        expectWithinTimingBudget("100k current public marks read", measured: reading, budget: .seconds(5), loadBefore: loadBeforeRead)
        expectWithinTimingBudget("1,000 current public-mark lookups", measured: lookup, budget: .seconds(2), loadBefore: loadBeforeLookup)
        await repository.close()
    }
}

/// Collects what a write body returns (the body is `@Sendable`; the test
/// reads it only after the awaited write returns).
private final class MarkLandingBox: @unchecked Sendable {
    var values: [CatalogRow.PublicMarkLanding] = []
}
