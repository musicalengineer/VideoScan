// CatalogSoundAttemptsTests.swift
// Sound attempts in catalog.sqlite (schema v1.14 = version 15, migration
// `v10_sound_attempts`; GH #416 part 2, Rick approved option B 2026-11-03):
//   MIGRATION  — a schema-14 database opens as 15 with every content row and
//                sound print intact; a v15 file is refused IN WORDS by the
//                gate a v14 build ran.
//   ISOLATION  — the CHECKs refuse a poisoned row (attempts 0, an unknown
//                outcome, engine version 0, a digest that is not content).
//   LOGIC      — the upsert never lowers a count at the same engine; a newer
//                engine replaces; an older one is ignored; a try no newer
//                than the content's stored print is stale and not written;
//                writing the content's sound print deletes its row.
//   ROUND TRIP — a record's note → DTO (sha256 only, this row's digest,
//                known words) → commit → load gives the same note back.
// Synthetic digests only.

import Foundation
import GRDB
import Testing
@testable import VideoScanCore

@Suite("CatalogSoundAttempts")
struct CatalogSoundAttemptsTests {

    private static func hex(_ n: Int) -> String { String(format: "%064x", n) }

    private func open(_ fixture: StoreFixture) async throws -> GRDBCatalogRepository {
        let repository = GRDBCatalogRepository(host: "test-host", durability: .volatileForTests)
        let opened = await repository.open(at: fixture.url)
        try #require(opened == .readWrite)
        return repository
    }

    private func seedContent(_ fixture: StoreFixture, count: Int) throws {
        try DatabaseQueue(path: fixture.url.path).inDatabase { db in
            for n in 1...count {
                try db.execute(sql: "INSERT INTO content (digest, byte_count, first_seen_at, first_seen_how) VALUES (?, 100, 1700000000, 'rescan')",
                               arguments: [Self.hex(n)])
            }
        }
    }

    static func row(_ n: Int, engine: Int = 4, outcome: String = "heardTooLittle", attempts: Int, at: Int64 = 1_762_000_000)
        -> CatalogRecordDTO.SoundAttemptRow {
        CatalogRecordDTO.SoundAttemptRow(digest: hex(n), engineVersion: engine, outcome: outcome, attempts: attempts,
                                         lastAt: at, detail: "2 audible seconds")
    }

    private func write(_ repository: GRDBCatalogRepository, _ body: @escaping @Sendable (any CatalogTransaction) throws -> Void) async {
        let outcome = await repository.write(as: .ui) { tx in try body(tx) }
        if case .committed = outcome { return }
        Issue.record("write: \(outcome)")
    }

    private func stored(_ fixture: StoreFixture, _ n: Int) throws -> (engine: Int, attempts: Int, outcome: String)? {
        try DatabaseQueue(path: fixture.url.path).inDatabase { db in
            try Row.fetchOne(db, sql: "SELECT engine_version, attempts, outcome FROM sound_attempts WHERE digest = ?",
                             arguments: [Self.hex(n)]).map { ($0[0], $0[1], $0[2]) }
        }
    }

    private func refusal(_ fixture: StoreFixture, _ sql: String) -> String? {
        do {
            try DatabaseQueue(path: fixture.url.path).inDatabase { db in try db.execute(sql: sql) }
            return nil
        } catch {
            return String(describing: error)
        }
    }

    // MARK: - ISOLATION: the CHECKs

    @Test("a poisoned row is refused by the DDL: attempts 0, an unknown outcome, engine 0, a digest that is not content")
    func poisonedRowsAreRefusedByTheChecks() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        try seedContent(fixture, count: 1)
        let d = Self.hex(1)
        let cols = "INSERT INTO sound_attempts (digest, engine_version, outcome, attempts, last_at, detail) VALUES"
        #expect(refusal(fixture, "\(cols) ('\(d)', 4, 'heardTooLittle', 0, 1, NULL)") != nil, "attempts ≥ 1")
        #expect(refusal(fixture, "\(cols) ('\(d)', 4, 'silence', 1, 1, NULL)") != nil, "outcome is heardTooLittle or failed")
        #expect(refusal(fixture, "\(cols) ('\(d)', 0, 'failed', 1, 1, NULL)") != nil, "engine version ≥ 1")
        #expect(refusal(fixture, "\(cols) ('\(Self.hex(99))', 4, 'failed', 1, 1, NULL)") != nil, "the digest must be content")
        #expect(refusal(fixture, "\(cols) ('\(d)', 4, 'failed', 'two', 1, NULL)") != nil, "STRICT: attempts is an INTEGER")
        #expect(refusal(fixture, "\(cols) ('\(d)', 4, 'failed', 1, 1, NULL)") == nil, "a well-formed row lands")
    }

    // MARK: - LOGIC: the upsert

    @Test("the upsert never lowers a count at the same engine; a newer engine replaces; an older one is ignored")
    func upsertIsMonotone() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        try seedContent(fixture, count: 1)
        let repository = try await open(fixture)
        await write(repository) { try $0.upsertSoundAttempt(Self.row(1, attempts: 2)) }
        await write(repository) { try $0.upsertSoundAttempt(Self.row(1, attempts: 1)) }    // a stale copy
        await repository.close()
        #expect(try stored(fixture, 1)?.attempts == 2, "a stale copy's lower count does not undo a sibling's tries")
        let again = try await open(fixture)
        await write(again) { try $0.upsertSoundAttempt(Self.row(1, engine: 3, attempts: 3)) }   // an older engine
        await write(again) { try $0.upsertSoundAttempt(Self.row(1, outcome: "failed", attempts: 3)) }
        await again.close()
        #expect(try stored(fixture, 1)?.attempts == 3)
        #expect(try stored(fixture, 1)?.outcome == "failed")
        #expect(try stored(fixture, 1)?.engine == 4, "an older engine's row never replaces a newer one")
        let newer = try await open(fixture)
        await write(newer) { try $0.upsertSoundAttempt(Self.row(1, engine: 5, attempts: 1)) }
        await newer.close()
        #expect(try stored(fixture, 1)?.engine == 5)
        #expect(try stored(fixture, 1)?.attempts == 1, "a newer engine starts again")
    }

    @Test("writing the content's sound print deletes its tries; a try beside a print by this engine, or no newer than it, is stale; the redo of an older engine's print is recorded")
    func aPrintEndsTheTries() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        try seedContent(fixture, count: 2)
        let repository = try await open(fixture)
        await write(repository) { try $0.upsertSoundAttempt(Self.row(1, attempts: 2, at: 1_762_000_000)) }
        let print = CatalogRecordDTO.SoundPrintRow(digest: Self.hex(1), engineVersion: 4, outcome: "fingerprinted", analyzedS: 60,
                                                   complete: true, landmarks: 40, blobBytes: 200, computedAt: 1_762_000_100)
        await write(repository) { try $0.replaceSoundPrint(digest: Self.hex(1), print) }
        await repository.close()
        #expect(try stored(fixture, 1) == nil, "the print ended the tries")
        let again = try await open(fixture)
        await write(again) { try $0.upsertSoundAttempt(Self.row(1, attempts: 3, at: 1_762_000_050)) }   // a copy loaded before the print
        await again.close()
        #expect(try stored(fixture, 1) == nil, "a try older than the content's print is stale")
        let later = try await open(fixture)
        await write(later) { try $0.upsertSoundAttempt(Self.row(1, attempts: 1, at: 1_762_000_200)) }   // newer, same engine as the print
        await later.close()
        #expect(try stored(fixture, 1) == nil, "beside a print by this engine a try is a stale copy's (Codex #217 F1)")
        // The redo of an OBSOLETE print (an older engine's) is a real try.
        let old = CatalogRecordDTO.SoundPrintRow(digest: Self.hex(2), engineVersion: 3, outcome: "fingerprinted", analyzedS: 60,
                                                 complete: true, landmarks: 0, blobBytes: 0, computedAt: 1_762_000_300)
        let redo = try await open(fixture)
        await write(redo) { try $0.replaceSoundPrint(digest: Self.hex(2), old) }
        await write(redo) { try $0.upsertSoundAttempt(Self.row(2, attempts: 1, at: 1_762_000_400)) }
        // Codex #218 F1: an OLDER print never replaces a newer one.
        await write(redo) { try $0.replaceSoundPrint(digest: Self.hex(1), old.withDigest(Self.hex(1))) }
        await redo.close()
        #expect(try stored(fixture, 2)?.attempts == 1, "a try newer than an older engine's print is recorded")
        let kept = try DatabaseQueue(path: fixture.url.path).inDatabase { db in
            try Int.fetchOne(db, sql: "SELECT engine_version FROM sound_prints WHERE digest = ?", arguments: [Self.hex(1)])
        }
        #expect(kept == 4, "the engine-4 print stands against an engine-3 copy's")
    }

    @Test("Codex #217 F1: a copy WITHOUT a print or a note never differs from the store's print or note (never a delete); one WITH a new print does")
    func aCopyWithoutAPrintNeverErasesIt() throws {
        let digest = Self.hex(5)
        func record(print: Bool, note: Bool) throws -> CatalogRecordDTO {
            let r = VideoRecord()
            r.fullPath = "/Volumes/X/b.mov"
            r.sizeBytes = 100
            r.contentFixity = ContentFixity(digest: digest, byteCount: 100, stamp: FileIdentityStamp(device: 1, inode: 2, size: 100, mtimeNs: 3))
            if print {
                r.audioFingerprint = AudioFingerprintStamp(computedAt: Date(timeIntervalSince1970: 1_762_000_100), contentDigest: "sha256:" + digest,
                                                           sizeBytes: 100, outcome: .fingerprinted, analyzedSeconds: 3, complete: true,
                                                           landmarks: 40, bytes: 200)
            }
            if note {
                r.audioFingerprintAttempt = AudioFingerprintAttempt(contentDigest: "sha256:" + digest, outcome: .failed, attempts: 2,
                                                                    lastAt: Date(timeIntervalSince1970: 1_762_000_000))
            }
            return try CatalogRecordDTO(record: r, migrationLoadedAt: 0)
        }
        let stored = try record(print: true, note: true)
        let bare = CatalogRecordDiff(stored: stored, current: try record(print: false, note: false))
        #expect(!bare.soundPrint, "a copy loaded before its sibling printed must not erase the print")
        #expect(!bare.soundAttempt)
        var newer = try record(print: true, note: false)
        newer.soundPrint?.computedAt += 50
        #expect(CatalogRecordDiff(stored: stored, current: newer).soundPrint, "a new print replaces the old one")
    }

    // MARK: - ROUND TRIP: record → DTO → load

    @Test("the DTO binds a note only for THIS row's sha256 digest with words this build knows")
    func dtoBindsOnlyAFullDigestNote() throws {
        let r = VideoRecord()
        r.fullPath = "/Volumes/X/a.mov"
        r.sizeBytes = 100
        let digest = Self.hex(7)
        r.contentFixity = ContentFixity(digest: digest, byteCount: 100, stamp: FileIdentityStamp(device: 1, inode: 2, size: 100, mtimeNs: 3))
        r.audioFingerprintAttempt = AudioFingerprintAttempt(contentDigest: "sha256:" + digest, outcome: .failed, attempts: 2,
                                                            lastAt: Date(timeIntervalSince1970: 1_762_000_000), detail: "exit 1")
        let dto = try CatalogRecordDTO(record: r, migrationLoadedAt: 0)
        #expect(dto.soundAttempt == CatalogRecordDTO.SoundAttemptRow(digest: digest, engineVersion: AudioFingerprintStamp.currentEngineVersion,
                                                                     outcome: "failed", attempts: 2, lastAt: 1_762_000_000, detail: "exit 1"))
        r.audioFingerprintAttempt?.contentDigest = "v1:abc"
        #expect(try CatalogRecordDTO(record: r, migrationLoadedAt: 0).soundAttempt == nil, "a sampled key is never bound")
        r.audioFingerprintAttempt?.contentDigest = "sha256:" + Self.hex(8)
        #expect(try CatalogRecordDTO(record: r, migrationLoadedAt: 0).soundAttempt == nil, "another content's note is not this row's")
    }

    @Test("pure: 3 tries at this engine give up; an older engine's tries count 0; a sampled key never records")
    func theAttemptRule() {
        let d = "sha256:" + Self.hex(9)
        var a = AudioFingerprintAttempt.after(nil, contentDigest: d, outcome: .heardTooLittle, detail: nil)
        #expect(a?.attempts == 1)
        a = AudioFingerprintAttempt.after(a, contentDigest: d, outcome: .failed, detail: nil)
        a = AudioFingerprintAttempt.after(a, contentDigest: d, outcome: .heardTooLittle, detail: nil)
        #expect(a?.attempts == 3 && a?.outcome == .heardTooLittle)
        #expect(a?.gaveUp(digests: [d, "v1:x"]) == true)
        #expect(a?.gaveUp(digests: ["v1:x"]) == false, "a record whose preferred key is sampled is never skipped by a full-key note")
        #expect(a?.gaveUp(digests: [d], engineVersion: AudioFingerprintStamp.currentEngineVersion + 1) == false, "a new engine retries")
        let old = AudioFingerprintAttempt(contentDigest: d, engineVersion: AudioFingerprintStamp.currentEngineVersion - 1,
                                          outcome: .failed, attempts: 3)
        #expect(old.gaveUp(digests: [d]) == false, "an older engine's tries count 0")
        #expect(AudioFingerprintAttempt.after(old, contentDigest: d, outcome: .failed, detail: nil)?.attempts == 1, "and the count restarts")
        #expect(AudioFingerprintAttempt.after(nil, contentDigest: "v1:x", outcome: .failed, detail: nil) == nil)
        let long = String(repeating: "x", count: 5_000)
        #expect(AudioFingerprintAttempt.after(nil, contentDigest: d, outcome: .failed, detail: long)?.detail?.count == AudioFingerprintAttempt.detailCap)
    }

    // MARK: - MIGRATION

    @Test("a schema-14 database opens as 15 with every content row and sound print intact, and takes a try")
    func aSchemaFourteenDatabaseOpensAsFifteen() async throws {
        let fixture = StoreFixture(kind: .grdb, directory: try StoreFixture.temporaryDirectory())
        defer { fixture.remove() }
        var v113 = DatabaseMigrator()
        v113.registerMigration(CatalogBookkeepingSchema.migrationID, foreignKeyChecks: .immediate) { db in
            for statement in CatalogBookkeepingSchema.statements { try db.execute(sql: statement) }
            try db.execute(sql: "PRAGMA user_version = 7")
            try db.execute(sql: "INSERT INTO catalog_state (singleton, schema_version) VALUES (1, 7)")
            try db.execute(sql: "INSERT INTO generations (id, generation, saved_at, saved_from_host) VALUES (1, 0, 1, 'v1.13')")
            try db.execute(sql: "INSERT INTO generation_history (generation, committed_at, host, writer, files_live, files_total) VALUES (0, 1, 'v1.13', 'create', 0, 0)")
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
        ]
        for (id, statements) in later {
            v113.registerMigration(id, foreignKeyChecks: .immediate) { db in
                for statement in statements { try db.execute(sql: statement) }
            }
        }
        let queue = try DatabaseQueue(path: fixture.url.path)
        try v113.migrate(queue)
        try queue.inDatabase { db in
            for n in 1...3 {
                try db.execute(sql: "INSERT INTO content (digest, byte_count, first_seen_at, first_seen_how) VALUES (?, 100, 1700000000, 'rescan')",
                               arguments: [Self.hex(n)])
            }
            try db.execute(sql: """
                INSERT INTO sound_prints (digest, engine_version, outcome, analyzed_s, complete, landmarks, blob_bytes, computed_at)
                VALUES (?, 4, 'fingerprinted', 60, 1, 40, 200, 1700000000)
                """, arguments: [Self.hex(1)])
        }
        #expect(try queue.inDatabase { db in try Int.fetchOne(db, sql: "SELECT schema_version FROM catalog_state") } == 14)
        #expect(try queue.inDatabase { db in try db.tableExists("sound_attempts") } == false)
        try queue.close()
        try fixture.writeHighWater("0")

        let repository = try await open(fixture)
        await write(repository) { try $0.upsertSoundAttempt(Self.row(2, attempts: 1)) }
        await repository.close()
        let after = try DatabaseQueue(path: fixture.url.path).inDatabase { db in
            (try Int.fetchOne(db, sql: "SELECT schema_version FROM catalog_state"),
             try Int.fetchOne(db, sql: "PRAGMA user_version"),
             try Int.fetchOne(db, sql: "SELECT count(*) FROM content"),
             try Int.fetchOne(db, sql: "SELECT count(*) FROM sound_prints"),
             try Int.fetchOne(db, sql: "SELECT count(*) FROM sound_attempts"),
             try String.fetchAll(db, sql: "PRAGMA integrity_check"))
        }
        #expect(after.0 == GRDBCatalogRepository.currentSchemaVersion)   // 15, then v11_public_marks → 16
        #expect(after.1 == GRDBCatalogRepository.currentSchemaVersion)
        #expect(after.2 == 3)
        #expect(after.3 == 1, "the sound print is untouched")
        #expect(after.4 == 1)
        #expect(after.5 == ["ok"])
    }

    @Test("a v15 file is refused in words by the gate a v14 build ran")
    func aFifteenFileIsRefusedInWordsByTheGateAFourteenBuildRan() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        let words: String? = try DatabaseQueue(path: fixture.url.path).inDatabase { db in
            do {
                try GRDBCatalogRepository.checkSchemaVersion(db, understands: CatalogProvenanceAssertionsSchema.schemaVersion)
                return nil
            } catch {
                return String(describing: error)
            }
        }
        #expect(words?.contains("schema version \(GRDBCatalogRepository.currentSchemaVersion) is newer than this build understands (14) — open it with a newer VideoScan") == true, "\(words ?? "nil")")
    }
}

private extension CatalogRecordDTO.SoundPrintRow {
    func withDigest(_ d: String) -> Self { var c = self; c.digest = d; return c }
}
