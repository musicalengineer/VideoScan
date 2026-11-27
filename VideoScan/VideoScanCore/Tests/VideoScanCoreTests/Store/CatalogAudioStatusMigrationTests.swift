// CatalogAudioStatusMigrationTests.swift
// Schema v1.16 = version 17, migration `v12_audio_status` (Rick 2026-11-27,
// GH #518 + orange rows): the stored audio verdict gains 'attention' and
// 'unverified'. The dimensions:
//   LOGIC      — a schema-16 file (built with the real earlier migrations,
//                so its media_checks is the v2 DDL with the narrow CHECK) and
//                every kind of media_checks row opens at 17: every row is
//                byte-for-byte the row it was, the new words are accepted for
//                audio only, an unknown word is still refused, nothing named
//                media_checks_v16 is left, integrity and foreign keys hold;
//   TRUTH /    — a catalog.json "ok" imported into derived_unverified, then
//   RELAUNCH     withdrawn to 'unverified' through the commit door's own
//                derived writer (`replaceDerived`), loads as 'unverified' on
//                every later open: the bound row outranks the imported value.
//                Clearing the row instead lets the imported "ok" come back —
//                the reason the value exists (pinned too);
//   ISOLATION  — poisoned schema-16 files: a media_checks row that breaks
//                its foreign key, or holds an audio word its CHECK refuses
//                (planted with checks off), is REFUSED by the open's checks
//                before any migration runs; a migration that fails PART-WAY
//                (a leftover media_checks_v16 makes the rename fail) rolls
//                back whole. Every case: still 16, still the narrow CHECK,
//                every row still there; never half-migrated;
//   SCALE      — 100k contents × (audio + video + reportCard) = 300k rows
//                migrate inside a time budget with the count proven.
// Synthetic digests only. Suite filter: CatalogAudioStatusMigrationTests.

import Foundation
import GRDB
import Testing
@testable import VideoScanCore

@Suite("CatalogAudioStatusMigration — v16 → v17 widens the audio CHECK, keeps every row, and 'unverified' outranks an imported ok", .serialized)
struct CatalogAudioStatusMigrationTests {

    private static func hex(_ n: Int) -> String { String(format: "%064x", n) }

    // MARK: - A schema-16 file, as the previous build left it

    /// Every migration before `v12_audio_status`, the real statements.
    private static func sixteenMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration(CatalogBookkeepingSchema.migrationID, foreignKeyChecks: .immediate) { db in
            for statement in CatalogBookkeepingSchema.statements { try db.execute(sql: statement) }
            try db.execute(sql: "PRAGMA user_version = 7")
            try db.execute(sql: "INSERT INTO catalog_state (singleton, schema_version) VALUES (1, 7)")
            try db.execute(sql: "INSERT INTO generations (id, generation, saved_at, saved_from_host) VALUES (1, 0, 1, 'v1.15')")
            try db.execute(sql: "INSERT INTO generation_history (generation, committed_at, host, writer, files_live, files_total) VALUES (0, 1, 'v1.15', 'create', 0, 0)")
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
            (CatalogPublicMarksSchema.migrationID, CatalogPublicMarksSchema.statements + CatalogPublicMarksSchema.versionBump),
        ]
        for (id, statements) in later {
            migrator.registerMigration(id, foreignKeyChecks: .immediate) { db in
                for statement in statements { try db.execute(sql: statement) }
            }
        }
        return migrator
    }

    /// A schema-16 file with `contents` contents; content n carries an audio
    /// verdict (ok / damaged alternating), a video verdict and a report card.
    private static func sixteenFixture(contents: Int) throws -> StoreFixture {
        let fixture = StoreFixture(kind: .grdb, directory: try StoreFixture.temporaryDirectory())
        let queue = try DatabaseQueue(path: fixture.url.path)
        try sixteenMigrator().migrate(queue)
        try queue.inDatabase { db in
            try db.inTransaction {
                for n in 1...contents {
                    let d = hex(n)
                    try db.execute(sql: "INSERT INTO content (digest, byte_count, first_seen_at, first_seen_how) VALUES (?, 100, 1700000000, 'rescan')",
                                   arguments: [d])
                    try db.execute(sql: "INSERT INTO media_checks (digest, kind, status, note, checked_at) VALUES (?, 'audio', ?, ?, ?)",
                                   arguments: [d, n % 2 == 0 ? "damaged" : "ok", n % 2 == 0 ? "Reference movie — note \(n)" : "", 1_790_000_000 + n])
                    try db.execute(sql: "INSERT INTO media_checks (digest, kind, status, note, checked_at) VALUES (?, 'video', 'warning', 'a dropped frame', NULL)",
                                   arguments: [d])
                    try db.execute(sql: "INSERT INTO media_checks (digest, kind, status, note, checked_at, card) VALUES (?, 'reportCard', 'full', '', ?, ?)",
                                   arguments: [d, 1_790_000_000 + n, "{\"tier\":\"full\",\"n\":\(n)}"])
                }
                return .commit
            }
        }
        try queue.close()
        try fixture.writeHighWater("0")
        return fixture
    }

    private static func rows(_ url: URL) throws -> [String] {
        try DatabaseQueue(path: url.path).inDatabase { db in
            try Row.fetchAll(db, sql: """
                SELECT digest, kind, status, note, quote(checked_at), quote(card), provenance FROM media_checks ORDER BY digest, kind
                """).map { r in (0..<7).map { "\(r[$0] as DatabaseValue)" }.joined(separator: "|") }
        }
    }

    private static func scalar(_ url: URL, _ sql: String) throws -> Int? {
        try DatabaseQueue(path: url.path).inDatabase { db in try Int.fetchOne(db, sql: sql) }
    }

    private static func tableSQL(_ url: URL) throws -> String? {
        try DatabaseQueue(path: url.path).inDatabase { db in
            try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'media_checks'")
        }
    }

    /// nil = accepted; else the engine's words.
    private static func refusal(_ url: URL, _ sql: String, _ arguments: StatementArguments = []) -> String? {
        do {
            try DatabaseQueue(path: url.path).inDatabase { db in try db.execute(sql: sql, arguments: arguments) }
            return nil
        } catch {
            return String(describing: error)
        }
    }

    private static func open(_ url: URL) async -> CatalogOpenOutcome {
        let repository = GRDBCatalogRepository(host: "audio-status", durability: .volatileForTests)
        let opened = await repository.open(at: url)
        await repository.close()
        return opened
    }

    // MARK: - Logic

    @Test("a schema-16 file opens at 17: every media_checks row is the row it was, the table is the document's widened one, nothing is left aside, integrity and foreign keys ok")
    func aSixteenFileMigratesWithEveryRowKept() async throws {
        let fixture = try Self.sixteenFixture(contents: 6)
        defer { fixture.remove() }
        let before = try Self.rows(fixture.url)
        try #require(before.count == 18)
        try #require(try Self.scalar(fixture.url, "SELECT schema_version FROM catalog_state") == 16)
        try #require(try Self.tableSQL(fixture.url)?.contains("'ok','damaged')") == true, "the fixture has the narrow CHECK")

        #expect(await Self.open(fixture.url) == .readWrite)

        #expect(try Self.rows(fixture.url) == before, "every row byte-for-byte")
        #expect(try Self.scalar(fixture.url, "SELECT schema_version FROM catalog_state") == 17)
        #expect(try Self.scalar(fixture.url, "PRAGMA user_version") == 17)
        #expect(try Self.tableSQL(fixture.url) == CatalogAudioStatusSchema.mediaChecks, "stored under its own name, the document's text, unquoted")
        #expect(try Self.scalar(fixture.url, "SELECT count(*) FROM sqlite_master WHERE name = '\(CatalogAudioStatusSchema.asideName)'") == 0)
        let checks = try DatabaseQueue(path: fixture.url.path).inDatabase { db in
            (try String.fetchAll(db, sql: "PRAGMA integrity_check"), try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").count)
        }
        #expect(checks.0 == ["ok"])
        #expect(checks.1 == 0)
        let recorded = try DatabaseQueue(path: fixture.url.path).inDatabase { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
        }
        #expect(recorded.last == CatalogAudioStatusSchema.migrationID)
    }

    @Test("the narrow v16 CHECK refuses 'attention' and 'unverified' (why the migration exists)")
    func theSixteenSchemaRefusesTheNewWords() throws {
        let fixture = try Self.sixteenFixture(contents: 2)
        defer { fixture.remove() }
        for word in ["attention", "unverified"] {
            let words = Self.refusal(fixture.url, "UPDATE media_checks SET status = ? WHERE kind = 'audio'", [word])
            #expect(words?.contains("CHECK constraint failed") == true, "\(word): \(words ?? "accepted")")
        }
    }

    @Test("after the migration: 'attention' and 'unverified' are accepted for audio; never for video; an unknown audio word is still refused")
    func theWidenedCheckTakesExactlyTheTwoNewAudioWords() async throws {
        let fixture = try Self.sixteenFixture(contents: 2)
        defer { fixture.remove() }
        #expect(await Self.open(fixture.url) == .readWrite)
        let d1 = Self.hex(1), d2 = Self.hex(2)
        #expect(Self.refusal(fixture.url, "UPDATE media_checks SET status = 'attention' WHERE kind = 'audio' AND digest = ?", [d1]) == nil)
        #expect(Self.refusal(fixture.url, "UPDATE media_checks SET status = 'unverified' WHERE kind = 'audio' AND digest = ?", [d2]) == nil)
        for word in ["attention", "unverified"] {
            let video = Self.refusal(fixture.url, "UPDATE media_checks SET status = ? WHERE kind = 'video' AND digest = ?", [word, d1])
            #expect(video?.contains("CHECK constraint failed") == true, "video \(word): \(video ?? "accepted")")
        }
        for poison in ["Attention", "withdrawn", "", "ok "] {
            let audio = Self.refusal(fixture.url, "UPDATE media_checks SET status = ? WHERE kind = 'audio' AND digest = ?", [poison, d1])
            #expect(audio?.contains("CHECK constraint failed") == true, "audio '\(poison)': \(audio ?? "accepted")")
        }
        #expect(CatalogDDL.AudioCheckStatus.allCases.map(\.rawValue) == ["ok", "damaged", "attention", "unverified"])
    }

    @Test("a fresh catalog is created at 17 with the widened table, and a second open runs nothing")
    func aFreshCatalogIsSeventeenAndReopensQuietly() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        #expect(try Self.tableSQL(fixture.url) == CatalogAudioStatusSchema.mediaChecks)
        #expect(try Self.scalar(fixture.url, "SELECT schema_version FROM catalog_state") == 17)
        let migrations = try Self.scalar(fixture.url, "SELECT count(*) FROM grdb_migrations")
        #expect(await Self.open(fixture.url) == .readWrite)
        #expect(try Self.scalar(fixture.url, "SELECT count(*) FROM grdb_migrations") == migrations)
    }

    @Test("a 17 file is refused in words by the gate a 16 build ran (an older build never misreads 'attention' / 'unverified')")
    func aSeventeenFileIsRefusedByASixteenBuild() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        let words: String? = try DatabaseQueue(path: fixture.url.path).inDatabase { db in
            do {
                try GRDBCatalogRepository.checkSchemaVersion(db, understands: CatalogPublicMarksSchema.schemaVersion)
                return nil
            } catch {
                return String(describing: error)
            }
        }
        #expect(words?.contains("schema version 17 is newer than this build understands (16) — open it with a newer VideoScan") == true, "\(words ?? "nil")")
    }

    // MARK: - Isolation (poisoned state)

    @Test("ISOLATION: a schema-16 file with a media_checks row whose content is missing (planted with foreign keys off) is refused before any migration runs — still 16, still the narrow CHECK, every row there")
    func aPoisonedSixteenFileIsRefusedAndLeftWhole() async throws {
        let fixture = try Self.sixteenFixture(contents: 3)
        defer { fixture.remove() }
        try DatabaseQueue(path: fixture.url.path).inDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.execute(sql: "INSERT INTO media_checks (digest, kind, status, note, checked_at) VALUES (?, 'audio', 'ok', '', 1)",
                           arguments: [Self.hex(999)])
        }
        let before = try Self.rows(fixture.url)
        let sqlBefore = try Self.tableSQL(fixture.url)

        let opened = await Self.open(fixture.url)
        print("[audio-status-migration] dangling-row open: \(opened)")
        #expect(opened != .readWrite, "a dangling row must not be carried into the new table silently: \(opened)")

        #expect(try Self.rows(fixture.url) == before, "every row still there")
        #expect(try Self.tableSQL(fixture.url) == sqlBefore, "the table is the old one")
        #expect(try Self.scalar(fixture.url, "SELECT schema_version FROM catalog_state") == 16)
        #expect(try Self.scalar(fixture.url, "PRAGMA user_version") == 16)
        #expect(try Self.scalar(fixture.url, "SELECT count(*) FROM sqlite_master WHERE name = '\(CatalogAudioStatusSchema.asideName)'") == 0)
    }

    @Test("ISOLATION: a schema-16 file holding an audio row its own CHECK refuses (planted with checks off) is refused before any migration runs — still 16, the old table, every row there, nothing aside")
    func aRowTheNewTableRefusesRollsTheMigrationBack() async throws {
        let fixture = try Self.sixteenFixture(contents: 3)
        defer { fixture.remove() }
        try DatabaseQueue(path: fixture.url.path).inDatabase { db in
            try db.execute(sql: "PRAGMA ignore_check_constraints = ON")
            try db.execute(sql: "UPDATE media_checks SET status = 'garbage' WHERE kind = 'audio' AND digest = ?", arguments: [Self.hex(2)])
        }
        let before = try Self.rows(fixture.url)
        let sqlBefore = try Self.tableSQL(fixture.url)

        let opened = await Self.open(fixture.url)
        print("[audio-status-migration] poisoned-status open: \(opened)")
        #expect(opened != .readWrite, "\(opened)")

        #expect(try Self.rows(fixture.url) == before, "every row still there, the poison included (refuse, never guess)")
        #expect(try Self.tableSQL(fixture.url) == sqlBefore, "the table is the old one")
        #expect(try Self.scalar(fixture.url, "SELECT schema_version FROM catalog_state") == 16)
        #expect(try Self.scalar(fixture.url, "PRAGMA user_version") == 16)
        #expect(try Self.scalar(fixture.url, "SELECT count(*) FROM sqlite_master WHERE name = '\(CatalogAudioStatusSchema.asideName)'") == 0)
        #expect(try Self.scalar(fixture.url, "SELECT count(*) FROM grdb_migrations WHERE identifier = '\(CatalogAudioStatusSchema.migrationID)'") == 0)
    }

    @Test("ISOLATION: a migration that fails PART-WAY (a leftover media_checks_v16 makes the rename fail) rolls back whole — still 16, the old table and every row, the leftover untouched, the step unrecorded")
    func aMigrationThatFailsPartWayRollsBackWhole() async throws {
        let fixture = try Self.sixteenFixture(contents: 3)
        defer { fixture.remove() }
        try DatabaseQueue(path: fixture.url.path).inDatabase { db in
            try db.execute(sql: "CREATE TABLE \(CatalogAudioStatusSchema.asideName) (x INTEGER) STRICT")
            try db.execute(sql: "INSERT INTO \(CatalogAudioStatusSchema.asideName) (x) VALUES (42)")
        }
        let before = try Self.rows(fixture.url)
        let sqlBefore = try Self.tableSQL(fixture.url)

        let opened = await Self.open(fixture.url)
        print("[audio-status-migration] part-way failure open: \(opened)")
        #expect(opened != .readWrite, "\(opened)")

        #expect(try Self.rows(fixture.url) == before, "every row still there")
        #expect(try Self.tableSQL(fixture.url) == sqlBefore, "the table is the old one")
        #expect(try Self.scalar(fixture.url, "SELECT schema_version FROM catalog_state") == 16)
        #expect(try Self.scalar(fixture.url, "PRAGMA user_version") == 16)
        #expect(try Self.scalar(fixture.url, "SELECT x FROM \(CatalogAudioStatusSchema.asideName)") == 42, "the leftover is untouched")
        #expect(try Self.scalar(fixture.url, "SELECT count(*) FROM grdb_migrations WHERE identifier = '\(CatalogAudioStatusSchema.migrationID)'") == 0)
    }

    // MARK: - Truth / relaunch: 'unverified' outranks the imported value

    private static let importedRowID = PoisonedCatalogFixture.bulkID(0)
    private static var importedDigest: String { PoisonedCatalogFixture.digest("bulk-0") }

    /// A committed import whose bulk row 0 carries catalog.json's "ok".
    private static func importedOK() async throws -> ImporterScene {
        let scene = try ImporterScene.make(healthyRows: 1)
        try scene.poisonCatalog { records in
            guard let i = records.firstIndex(where: { $0["id"]?.stringValue == importedRowID }) else { return }
            records[i]["audioVerifyStatus"] = .string("ok")
            records[i]["audioVerifyNote"] = .string("")
            records[i]["audioVerifyDate"] = .string(PoisonedCatalogFixture.iso(1_780_000_000))
        }
        let run = await scene.run()
        _ = try #require(run.outcome.reconciliation, Comment(rawValue: "\(run.outcome)"))
        return scene
    }

    /// The commit door's derived writer for the audio check, exactly.
    private static func writeAudioCheck(_ scene: ImporterScene, status: String?) async throws -> CatalogWriteOutcome {
        let repository = GRDBCatalogRepository(host: "withdraw", durability: .volatileForTests)
        try #require(await repository.open(at: scene.databaseURL) == .readWrite)
        let digest = importedDigest
        let rows: [CatalogRecordDTO.DerivedValueRow] = status.map { s in
            [CatalogRecordDTO.DerivedValueRow(kind: .audioCheck, seq: 0,
                                              valueJSON: .object(["audioVerifyStatus": .string(s),
                                                                  "audioVerifyNote": .string("withdrawn by a re-measure"),
                                                                  "audioVerifyDate": .string(PoisonedCatalogFixture.iso(1_795_000_000))]),
                                              stampJSON: .object([:]))]
        } ?? []
        let outcome = await repository.write(as: .ui) { tx in
            try #require(tx as? GRDBTransaction).replaceDerived(digest: digest, kind: .audioCheck, rows)
        }
        await repository.close()
        return outcome
    }

    @Test("TRUTH/RELAUNCH: an imported catalog.json 'ok', withdrawn to 'unverified' through the commit door's writer, loads as 'unverified' on this and every later open — the imported ok never comes back")
    func anUnverifiedRowOutranksTheImportedOKAtEveryRelaunch() async throws {
        let scene = try await Self.importedOK(); defer { scene.remove() }
        let first = try await LoadedCatalog.load(scene)
        try #require(first.records[Self.importedRowID]?.audioVerifyStatus == "ok", "the import shows catalog.json's ok")

        let outcome = try await Self.writeAudioCheck(scene, status: CatalogDDL.AudioCheckStatus.unverified.rawValue)
        guard case .committed = outcome else { Issue.record("the withdrawal was refused: \(outcome)"); return }

        for relaunch in 1...3 {
            let loaded = try await LoadedCatalog.load(scene)
            let record = try #require(loaded.records[Self.importedRowID])
            #expect(record.audioVerifyStatus == "unverified", "relaunch \(relaunch): \(record.audioVerifyStatus)")
            #expect(record.audioVerifyNote == "withdrawn by a re-measure", "relaunch \(relaunch)")
        }
        // The imported evidence is kept (never deleted), only outranked.
        let kept = try await scene.read { reader in
            try (reader as? GRDBReader).map { try Int.fetchOne($0.db, sql: "SELECT count(*) FROM derived_unverified WHERE kind = 'audioCheck'") ?? -1 }
        }
        #expect(kept == 1, "the imported row stays as evidence")
    }

    @Test("why the value exists: CLEARING the bound audio check lets the imported 'ok' come back at the next load")
    func clearingInsteadOfWithdrawingResurrectsTheImportedOK() async throws {
        let scene = try await Self.importedOK(); defer { scene.remove() }
        _ = try await Self.writeAudioCheck(scene, status: CatalogDDL.AudioCheckStatus.unverified.rawValue)
        let cleared = try await Self.writeAudioCheck(scene, status: nil)
        guard case .committed = cleared else { Issue.record("\(cleared)"); return }
        let loaded = try await LoadedCatalog.load(scene)
        #expect(loaded.records[Self.importedRowID]?.audioVerifyStatus == "ok")
    }

    @Test("'attention' round-trips through the commit door's writer and the load")
    func attentionRoundTrips() async throws {
        let scene = try await Self.importedOK(); defer { scene.remove() }
        let outcome = try await Self.writeAudioCheck(scene, status: CatalogDDL.AudioCheckStatus.attention.rawValue)
        guard case .committed = outcome else { Issue.record("\(outcome)"); return }
        let loaded = try await LoadedCatalog.load(scene)
        #expect(loaded.records[Self.importedRowID]?.audioVerifyStatus == "attention")
    }

    @Test("storedAudioCheck (#518 round 2): the content's BOUND audio row is read back as written (status, note, whole-second date); an imported value alone is no bound row (nil)")
    func storedAudioCheckReadsTheBoundRow() async throws {
        let scene = try await Self.importedOK(); defer { scene.remove() }
        let before = try await scene.read { try $0.storedAudioCheck(digest: Self.importedDigest) }
        #expect(before == nil, "only the imported (unverified) value exists: \(String(describing: before))")
        let outcome = try await Self.writeAudioCheck(scene, status: CatalogDDL.AudioCheckStatus.damaged.rawValue)
        guard case .committed = outcome else { Issue.record("\(outcome)"); return }
        let after = try await scene.read { try $0.storedAudioCheck(digest: Self.importedDigest.uppercased()) }
        #expect(after == StoredAudioCheck(status: "damaged", note: "withdrawn by a re-measure",
                                          checkedAt: Date(timeIntervalSince1970: 1_795_000_000)))
    }

    // MARK: - Scale

    @Test("SCALE: 100k contents × 3 media_checks rows (300k) migrate 16 → 17 inside 30 s, the count proven, a sample of rows identical",
          .tags(.quietMachine))
    func aHundredThousandContentsMigrateInsideTheBudget() async throws {
        let fixture = try Self.sixteenFixture(contents: 100_000)
        defer { fixture.remove() }
        let sample = "SELECT digest || kind || status || note || quote(checked_at) || quote(card) FROM media_checks WHERE digest IN (?, ?, ?) ORDER BY 1"
        let probe: StatementArguments = [Self.hex(1), Self.hex(50_000), Self.hex(100_000)]
        let before = try DatabaseQueue(path: fixture.url.path).inDatabase { db in try String.fetchAll(db, sql: sample, arguments: probe) }

        let loadBefore = TimingBudget.sampleLoad()
        let clock = ContinuousClock()
        let start = clock.now
        let opened = await Self.open(fixture.url)
        let elapsed = clock.now - start
        print("[audio-status-migration] 300k media_checks rows: v16 → v17 open in \(elapsed)")

        #expect(opened == .readWrite)
        expectWithinTimingBudget("v16 → v17 migration of 300k media_checks rows", measured: elapsed, budget: .seconds(30),
                                 loadBefore: loadBefore)
        #expect(try Self.scalar(fixture.url, "SELECT count(*) FROM media_checks") == 300_000)
        #expect(try Self.scalar(fixture.url, "SELECT schema_version FROM catalog_state") == 17)
        let after = try DatabaseQueue(path: fixture.url.path).inDatabase { db in try String.fetchAll(db, sql: sample, arguments: probe) }
        #expect(after == before)
    }
}
