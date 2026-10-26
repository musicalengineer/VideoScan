// CatalogProvenanceRolesTests.swift
// Provenance roles in catalog.sqlite (schema v1.12, migration
// `v8_provenance_roles`; CatalogProvenanceRoleRows.swift,
// GRDBCatalogRepository+ProvenanceRoles.swift):
//   LOGIC      — every choice is a new row (history kept); the newest row
//                (highest role_id) is current even when its decided_at is
//                older; setting Unknown appends an `unknown` row and resets;
//                source_missing is kept only on a Master; a digest that is
//                not stored content writes nothing (`contentMissing`); the
//                whole-table reading returns one current row per digest.
//   GUARDS     — UPDATE / DELETE refused with the trigger's words; a role
//                key outside the nine, a source_missing of 2 and a digest
//                that is not content are refused by the CHECKs / foreign key;
//                the CHECK's list IS ProvenanceRole.allCases.
//   ISOLATION  — a poisoned row (a key this build does not know, smuggled
//                in with CHECKs off) reads back verbatim as UNREADABLE —
//                `role` is Unknown, `known` is nil — and nothing throws.
//   MIGRATION  — a schema-12 database with content opens as 13, the table
//                empty, every content row intact.
//   READ-ONLY  — a read-only open refuses a role write: nothing lands.
//   SCALE      — 100k contents with a role (some with history): the whole
//                current-role reading and 1,000 single lookups inside budgets.
// One condition per #expect. Synthetic digests only.

import Foundation
import GRDB
import Testing
@testable import VideoScanCore

@Suite("CatalogProvenanceRoles")
struct CatalogProvenanceRolesTests {

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

    private static func decision(_ n: Int, _ role: ProvenanceRole, at: Int64 = 1_761_480_000,
                                 sourceMissing: Bool = false, note: String? = nil) -> CatalogRow.ProvenanceRoleDecision {
        CatalogRow.ProvenanceRoleDecision(digest: hex(n), role: role, decidedAt: at, sourceMissing: sourceMissing, note: note)
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

    private func current(_ repository: GRDBCatalogRepository, _ digests: [Int]) async throws -> [String: CatalogRow.ProvenanceRoleReading] {
        let keys = digests.map(Self.hex)
        return try await repository.read { try $0.currentProvenanceRoles(digests: keys) }
    }

    // MARK: - Logic

    @Test func everyChoiceIsANewRowAndTheNewestIsCurrent() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        try seedContent(fixture, count: 2)
        let repository = try await open(fixture)
        let landings = RoleLandingBox()
        // decided_at deliberately runs BACKWARDS: insertion order decides, never the clock.
        _ = await repository.write(as: .ui) { tx in
            landings.values.append(try tx.appendProvenanceRole(Self.decision(1, .viewCopy, at: 300)))
        }
        _ = await repository.write(as: .ui) { tx in
            landings.values.append(try tx.appendProvenanceRole(Self.decision(1, .master, at: 200, sourceMissing: true)))
        }
        #expect(landings.values == [.recorded, .recorded])
        let now = try await current(repository, [1, 2])
        #expect(now[Self.hex(1)]?.role == .master)
        #expect(now[Self.hex(1)]?.sourceNotInCatalog == true)
        #expect(now[Self.hex(1)]?.decidedAt == 200)
        #expect(now[Self.hex(2)] == nil, "no row = Unknown, absent")
        let history = try await repository.read { try $0.provenanceRoleHistory(digest: Self.hex(1)) }
        #expect(history.map(\.role) == [.viewCopy, .master], "the history is kept, oldest first")
        await repository.close()
    }

    @Test func settingUnknownAppendsAnUnknownRowAndResets() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        try seedContent(fixture, count: 1)
        let repository = try await open(fixture)
        _ = await repository.write(as: .ui) { tx in _ = try tx.appendProvenanceRole(Self.decision(1, .excerpt)) }
        _ = await repository.write(as: .ui) { tx in _ = try tx.appendProvenanceRole(Self.decision(1, .unknown)) }
        let now = try await current(repository, [1])
        #expect(now[Self.hex(1)]?.role == .unknown)
        #expect(now[Self.hex(1)]?.storedRole == "unknown")
        let history = try await repository.read { try $0.provenanceRoleHistory(digest: Self.hex(1)) }
        #expect(history.count == 2, "Unknown is a row, never a DELETE")
        await repository.close()
    }

    @Test func sourceMissingIsKeptOnlyOnAMaster() {
        #expect(Self.decision(1, .excerpt, sourceMissing: true).sourceMissing == false)
        #expect(Self.decision(1, .master, sourceMissing: true).sourceMissing == true)
        let stray = CatalogRow.ProvenanceRoleReading(roleID: 1, digest: Self.hex(1), storedRole: "excerpt", decidedAt: 1,
                                                     storedSourceMissing: true, note: nil)
        #expect(stray.sourceNotInCatalog == false, "a stored flag on a non-Master means nothing")
    }

    @Test func aDigestThatIsNotContentWritesNothing() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        try seedContent(fixture, count: 1)
        let repository = try await open(fixture)
        let landings = RoleLandingBox()
        _ = await repository.write(as: .ui) { tx in
            landings.values.append(try tx.appendProvenanceRole(Self.decision(99, .master)))
        }
        #expect(landings.values == [.contentMissing])
        let rows = try await repository.read { try $0.provenanceRoleHistory(digest: Self.hex(99)) }
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
            _ = try tx.appendProvenanceRole(CatalogRow.ProvenanceRoleDecision(digest: upper, role: .editCopy, decidedAt: 1))
        }
        let now = try await repository.read { try $0.currentProvenanceRoles(digests: [upper]) }
        #expect(now[Self.hex(0xabc)]?.role == .editCopy)
        await repository.close()
    }

    @Test func theWholeTableReadingGivesOneCurrentRowPerDigest() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        try seedContent(fixture, count: 3)
        let repository = try await open(fixture)
        _ = await repository.write(as: .ui) { tx in
            _ = try tx.appendProvenanceRole(Self.decision(2, .testCopy))
            _ = try tx.appendProvenanceRole(Self.decision(1, .viewCopy))
            _ = try tx.appendProvenanceRole(Self.decision(2, .alternateCapture))
            _ = try tx.appendProvenanceRole(Self.decision(1, .cameraOriginal))
        }
        let all = try await repository.read { reader -> [CatalogRow.ProvenanceRoleReading] in
            var out: [CatalogRow.ProvenanceRoleReading] = []
            try reader.currentProvenanceRoles { out.append($0) }
            return out
        }
        #expect(all.map(\.digest) == [Self.hex(1), Self.hex(2)])
        #expect(all.map(\.role) == [.cameraOriginal, .alternateCapture])
        await repository.close()
    }

    // MARK: - Guards

    @Test func theTableIsAppendOnlyAndItsChecksHold() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        try seedContent(fixture, count: 1)
        let repository = try await open(fixture)
        _ = await repository.write(as: .ui) { tx in _ = try tx.appendProvenanceRole(Self.decision(1, .master)) }
        await repository.close()
        #expect(refusal(fixture, "UPDATE provenance_roles SET role = 'viewCopy'") == "provenance_roles is append-only history")
        #expect(refusal(fixture, "DELETE FROM provenance_roles") == "provenance_roles is append-only history")
        let badRole = refusal(fixture, "INSERT INTO provenance_roles (digest, role, decided_at) VALUES ('\(Self.hex(1))', 'original', 1)")
        #expect(badRole?.contains("CHECK constraint failed") == true, "'original' names a carrier, not a stored role")
        let titleNotKey = refusal(fixture, "INSERT INTO provenance_roles (digest, role, decided_at) VALUES ('\(Self.hex(1))', 'Master', 1)")
        #expect(titleNotKey?.contains("CHECK constraint failed") == true, "the words are never stored, only the keys")
        let flag = refusal(fixture, "INSERT INTO provenance_roles (digest, role, decided_at, source_missing) VALUES ('\(Self.hex(1))', 'master', 1, 2)")
        #expect(flag?.contains("CHECK constraint failed") == true)
        let orphan = refusal(fixture, "INSERT INTO provenance_roles (digest, role, decided_at) VALUES ('\(Self.hex(7))', 'master', 1)")
        #expect(orphan == "FOREIGN KEY constraint failed")
        #expect(refusal(fixture, "DELETE FROM content") == "FOREIGN KEY constraint failed", "a role pins its content")
    }

    @Test func theCheckListIsExactlyTheNineRoleKeys() throws {
        let create = try #require(CatalogProvenanceRolesSchema.statements.first)
        let list = try #require(create.firstMatch(of: #/role\s+TEXT\s+NOT NULL CHECK \(role IN \(([^)]*)\)\)/#))
        let keys = list.1.split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "' ")) }
        #expect(keys == ProvenanceRole.allCases.map(\.rawValue))
        #expect(ProvenanceRole.allCases.map(\.title) == ["Master", "Camera Original", "Alternate Capture", "Remastered Copy", "Edit Copy",
                                                        "Excerpt", "View Copy", "Test Copy", "Unknown"])
    }

    // MARK: - Isolation: a poisoned row

    /// The poison arrives WHILE the store is open (a foreign writer with
    /// CHECKs off): the open's integrity check already passed, so the reader
    /// itself must cope.
    @Test func aPoisonedRoleKeyReadsAsUnreadableUnknownAndNeverThrows() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        try seedContent(fixture, count: 1)
        let repository = try await open(fixture)
        let smuggled = refusal(fixture, "INSERT INTO provenance_roles (digest, role, decided_at, source_missing) VALUES ('\(Self.hex(1))', 'grandMaster', 5, 1)",
                               checksOff: true)
        try #require(smuggled == nil, "the poison landed with CHECKs off: \(smuggled ?? "")")
        let now = try await current(repository, [1])
        let row = try #require(now[Self.hex(1)])
        #expect(row.storedRole == "grandMaster", "read back verbatim")
        #expect(row.known == nil)
        #expect(row.role == .unknown, "shown as Unknown, never guessed")
        #expect(row.sourceNotInCatalog == false)
        await repository.close()
    }

    /// The same poison found at OPEN: the store's integrity check refuses
    /// the file with words (never a crash, never a silent read-write open).
    @Test func aFileHoldingAPoisonedRoleKeyIsRefusedAtOpenWithWords() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        try seedContent(fixture, count: 1)
        let smuggled = refusal(fixture, "INSERT INTO provenance_roles (digest, role, decided_at) VALUES ('\(Self.hex(1))', 'grandMaster', 5)",
                               checksOff: true)
        try #require(smuggled == nil)
        let repository = GRDBCatalogRepository(host: "test-host", durability: .volatileForTests)
        let outcome = await repository.open(at: fixture.url)
        guard case .refused(let words) = outcome else {
            Issue.record("expected .refused, got \(outcome)")
            await repository.close()
            return
        }
        #expect(words.contains("provenance_roles"), "the words name the table: \(words)")
        await repository.close()
    }

    // MARK: - Migration from a schema-12 database

    @Test func aSchemaTwelveDatabaseOpensAsThirteenWithEveryContentRowIntact() async throws {
        let fixture = StoreFixture(kind: .grdb, directory: try StoreFixture.temporaryDirectory())
        defer { fixture.remove() }
        var v111 = DatabaseMigrator()
        v111.registerMigration(CatalogBookkeepingSchema.migrationID, foreignKeyChecks: .immediate) { db in
            for statement in CatalogBookkeepingSchema.statements { try db.execute(sql: statement) }
            try db.execute(sql: "PRAGMA user_version = 7")
            try db.execute(sql: "INSERT INTO catalog_state (singleton, schema_version) VALUES (1, 7)")
            try db.execute(sql: "INSERT INTO generations (id, generation, saved_at, saved_from_host) VALUES (1, 0, 1, 'v1.11')")
            try db.execute(sql: "INSERT INTO generation_history (generation, committed_at, host, writer, files_live, files_total) VALUES (0, 1, 'v1.11', 'create', 0, 0)")
        }
        let later: [(String, [String])] = [
            (CatalogDataSchema.migrationID, CatalogDataSchema.statements),
            (CatalogLiveWritesSchema.migrationID, CatalogLiveWritesSchema.statements + CatalogLiveWritesSchema.versionBump),
            (CatalogPendingRowsSchema.migrationID, CatalogPendingRowsSchema.statements + CatalogPendingRowsSchema.versionBump),
            (CatalogCommitB22Schema.migrationID, CatalogCommitB22Schema.statements + CatalogCommitB22Schema.versionBump),
            (CatalogFolderKindSchema.migrationID, CatalogFolderKindSchema.statements + CatalogFolderKindSchema.versionBump),
            (CatalogDecisionTablesSchema.migrationID, CatalogDecisionTablesSchema.statements + CatalogDecisionTablesSchema.versionBump),
        ]
        for (id, statements) in later {
            v111.registerMigration(id, foreignKeyChecks: .immediate) { db in
                for statement in statements { try db.execute(sql: statement) }
            }
        }
        let queue = try DatabaseQueue(path: fixture.url.path)
        try v111.migrate(queue)
        try queue.inDatabase { db in
            for n in 1...3 {
                try db.execute(sql: "INSERT INTO content (digest, byte_count, first_seen_at, first_seen_how) VALUES (?, 100, 1700000000, 'rescan')",
                               arguments: [Self.hex(n)])
            }
        }
        let before = try queue.inDatabase { db in try Int.fetchOne(db, sql: "SELECT schema_version FROM catalog_state") }
        #expect(before == 12)
        try queue.close()
        try fixture.writeHighWater("0")

        let repository = try await open(fixture)
        let roles = try await current(repository, [1, 2, 3])
        #expect(roles.isEmpty, "every content is Unknown after the migration")
        _ = await repository.write(as: .ui) { tx in _ = try tx.appendProvenanceRole(Self.decision(2, .master)) }
        #expect(try await current(repository, [2])[Self.hex(2)]?.role == .master)
        await repository.close()
        let after = try DatabaseQueue(path: fixture.url.path).inDatabase { db in
            (try Int.fetchOne(db, sql: "SELECT schema_version FROM catalog_state"),
             try Int.fetchOne(db, sql: "PRAGMA user_version"),
             try Int.fetchOne(db, sql: "SELECT count(*) FROM content"))
        }
        #expect(after.0 == 13)
        #expect(after.1 == 13)
        #expect(after.2 == 3)
    }

    // MARK: - Read-only

    @Test func aReadOnlyOpenRefusesARoleWrite() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        try seedContent(fixture, count: 1)
        let repository = GRDBCatalogRepository(host: "test-host", durability: .volatileForTests)
        let opened = await repository.openReadOnly(at: fixture.url, reason: "test: a viewer")
        guard case .readOnly = opened else {
            Issue.record("expected .readOnly, got \(opened)")
            return
        }
        let outcome = await repository.write(as: .ui) { tx in _ = try tx.appendProvenanceRole(Self.decision(1, .master)) }
        guard case .refused = outcome else {
            Issue.record("expected .refused, got \(outcome)")
            return
        }
        #expect(try await current(repository, [1]).isEmpty)
        await repository.close()
    }

    // MARK: - Scale

    /// 100k contents each with a role, 10k of them with a second (newer)
    /// row. Budgets (Debug, M4 Max): write 30 s; the whole current-role
    /// reading 5 s; 1,000 single-digest lookups 2 s — a scan per lookup
    /// (no `(digest, role_id)` index) would be minutes. Load-aware (GH #208).
    @Test(.timeLimit(.minutes(3)))
    func oneHundredThousandContentsCurrentRoleInsideBudgets() async throws {
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
                for i in 1...n { _ = try tx.appendProvenanceRole(Self.decision(i, .viewCopy)) }
                for i in stride(from: 1, through: n, by: 10) { _ = try tx.appendProvenanceRole(Self.decision(i, .master)) }
            }
        }
        #expect(outcome == .committed(generation: 1))
        var count = 0, masters = 0
        let loadBeforeRead = TimingBudget.sampleLoad()
        let reading = try await clock.measure {
            (count, masters) = try await repository.read { reader -> (Int, Int) in
                var c = 0, m = 0
                try reader.currentProvenanceRoles { row in
                    c += 1
                    if row.role == .master { m += 1 }
                }
                return (c, m)
            }
        }
        #expect(count == n)
        #expect(masters == n / 10)
        let probe = (0..<1_000).map { Self.hex(1 + $0 * 97) }
        var found: [String: CatalogRow.ProvenanceRoleReading] = [:]
        let loadBeforeLookup = TimingBudget.sampleLoad()
        let lookup = try await clock.measure {
            found = try await repository.read { try $0.currentProvenanceRoles(digests: probe) }
        }
        print("[provenance-roles] 100k: write \(write), current-role read \(reading), 1,000 lookups \(lookup) (\(TimingBudget.loadDescription()))")
        #expect(found.count == 1_000)
        expectWithinTimingBudget("100k provenance roles written", measured: write, budget: .seconds(30), loadBefore: loadBeforeWrite)
        expectWithinTimingBudget("100k current roles read", measured: reading, budget: .seconds(5), loadBefore: loadBeforeRead)
        expectWithinTimingBudget("1,000 current-role lookups", measured: lookup, budget: .seconds(2), loadBefore: loadBeforeLookup)
        await repository.close()
    }
}

/// Collects what a write body returns (the body is `@Sendable`; the test
/// reads it only after the awaited write returns).
private final class RoleLandingBox: @unchecked Sendable {
    var values: [CatalogRow.ProvenanceRoleLanding] = []
}
