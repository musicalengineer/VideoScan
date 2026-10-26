// CatalogCornerCases2026_10_25Tests.swift
// Rick's Charter: "SQLite must be rock solid with corner-case tests in the
// overnight run." The 2026-10-25 audit of Store/ coverage (gap matrix in the
// commit message) found these corners of OUR store unpinned. Each test here
// is about what the store does — its outcome, its words, what it leaves on
// disk — never about SQLite's internals; where the engine's behaviour is the
// point (a torn WAL replays a committed prefix) the assertion is still about
// the store's reaction (it opens, the witnesses make it read-only, adopt
// restores writing).
//
// Every test was shown RED under one deliberate mutation of the production
// code, then the mutation was reverted (red/green table):
//
//   test                                                      | mutation that makes it red
//   ----------------------------------------------------------+---------------------------------------------------------------
//   tornWALOpensAtACommittedPrefixAndTheWitnessesSpeak        | OpenPlan.mode: `witnesses.highest > generation` returns .readWrite (header-only and mid-frame cases)
//   closeWaitsForAReaderAndStillLeavesOneFile                 | makePool: `PRAGMA busy_timeout = 0` (the -wal keeps its frames after close)
//   everyOlderSchemaVersionMigratesToCurrent…                 | CatalogDecisionTablesSchema.versionBump: `PRAGMA user_version` dropped
//   reopeningACurrentFileRunsNoMigration…                     | migrator: the v7 identifier made non-permanent (+ UUID) — every open re-runs the DDL, open is refused
//                                                             |   (a plain rename is NOT red: the fixture is built by the same mutated code)
//   anOrphanRowThroughTheStoresDoorsIsRefusedWhole            | makePool: `configuration.foreignKeysEnabled = false`
//   aDigestIsOneContentWhateverItsCase                        | insertContent: `.lowercased()` removed
//   anEmptyDigestIsRefused…                                   | CatalogDataSchema.content: the digest CHECK removed
//   aCommitWaitsOutAShortLockAndLands                         | makePool: `PRAGMA busy_timeout = 0` (refused at once: database is locked)
//   aSealedCopyTakenBetweenQueuedWritesIsOneWholeGeneration   | sealedCopyBlocking: `VACUUM INTO` replaced by FileManager.copyItem
//   aZeroByteCatalogBesideItsWitnessesNeverOpensReadWrite     | OpenPlan.mode: `witnesses.highest > generation` returns .readWrite
//   aFileThatIsNotADatabaseIsRefusedAndNeverWritten           | open: the makePool catch returns .readWrite instead of refusing
//   aCounterTableWithTheWrongRowCountIsRefusedAtOpen          | loadGeneration: the `states == 1, counters == 1` guard removed
//   theReadOnlyDoorReadsFollowsTheWriterAndNeverWrites        | settle: the `opened.readOnlyReason` early return removed
//   theReadOnlyDoorRefusesAnOlderSchemaInsteadOfMigratingIt   | prepare: the `migrationsComplete` refusal removed
//   theReadOnlyDoorNeedsTheWALSidecarOnAppleSQLite            | (no mutation: RED by nature until #386 — the door now restores the -wal; see its doc comment)
//
// Five dimensions: LOGIC (every test) · SCALE (N/A here — CatalogDataSchemaScaleTests
// and CatalogRepositoryScaleTests hold the 100k budgets) · MEDIA N/A (no media
// opened) · ISOLATION (one temp folder per test; raw connections poison copies
// only) · SENSOR (byte-identity pins: SHA-256 before == after wherever "nothing
// written" is claimed).
//
// This file imports GRDB and SQLite3 to open the SAME file with a plain
// connection — the stand-in for another process — which Tests/…/Store/ may do.
// For Rick: `sqlite3_*` is the C API; `DatabaseQueue` ≈ one sqlite3* behind a
// serial queue; `DatabasePool` ≈ one writer + N readers over one WAL file.

import CryptoKit
import Foundation
import GRDB
import SQLite3
import Testing
@testable import VideoScanCore

@Suite("Catalog corner cases 2026-10-25 — torn WAL, close under a reader, every migration path, FK and digest doors, locks, sealed copies, bad files", .serialized)
struct CatalogCornerCases2026_10_25Tests {

    // MARK: - Helpers

    private static func repository(_ host: String = "corner-2026-10-25") -> GRDBCatalogRepository {
        GRDBCatalogRepository(host: host, durability: .volatileForTests)
    }

    private static func sha256(_ url: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { return "-" }
        return SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    private static func size(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.intValue ?? 0
    }

    private static func wal(_ database: URL) -> URL { URL(fileURLWithPath: database.path + "-wal") }
    private static func shm(_ database: URL) -> URL { URL(fileURLWithPath: database.path + "-shm") }

    /// A plain connection (never the store's pool) for the verdict, used
    /// only to READ and only after the store has closed. Not SQLITE_OPEN_READONLY:
    /// Apple's libsqlite3 (3.54.0, measured 2026-10-25 — see
    /// `theReadOnlyDoorNeedsTheWALSidecarOnAppleSQLite`) refuses a read-only
    /// open of a WAL file that has no -wal beside it, and several verdicts
    /// here read a bare copy. A read-write connection that only reads changes
    /// no byte of the main file (the byte pins below hold).
    private static func readOnly<T>(_ url: URL, _ body: (Database) throws -> T) throws -> T {
        let queue = try DatabaseQueue(path: url.path)
        defer { try? queue.close() }
        return try queue.read(body)
    }

    private static func storedGeneration(_ url: URL) throws -> Int {
        try readOnly(url) { try Int.fetchOne($0, sql: "SELECT generation FROM generations WHERE id = 1") ?? -1 }
    }

    private static func historyNewest(_ url: URL) throws -> Int {
        try readOnly(url) { try Int.fetchOne($0, sql: "SELECT max(generation) FROM generation_history") ?? -1 }
    }

    private static func count(_ url: URL, _ sql: String) throws -> Int {
        try readOnly(url) { try Int.fetchOne($0, sql: sql) ?? -1 }
    }

    // MARK: - 1. Power loss: a torn -wal, a missing -shm

    enum PowerLoss: String, CaseIterable, Sendable, CustomStringConvertible {
        /// The -wal cut back to its 32-byte header: every frame after the last checkpoint is gone.
        case walHeaderOnly
        /// The -wal cut inside its third frame: a committed prefix survives, the tail is torn.
        case walTornMidFrame
        /// The -wal whole, the -shm (the wal-index) missing: SQLite rebuilds it.
        case shmMissing
        var description: String { rawValue }
    }

    /// The state at the moment of a power loss: catalog.sqlite, its -wal with
    /// three commits' frames, its -shm and both witnesses, copied while the
    /// writer still has them open — then damaged as the case says.
    private static func powerLossScene(_ loss: PowerLoss) async throws -> (scene: StoreFixture, before: Int, after: Int) {
        let live = try await StoreFixture.make(.grdb, generation: 5)
        defer { live.remove() }
        let writer = repository()
        try #require(await writer.open(at: live.url) == .readWrite)
        for expected in 6...8 { try #require(await writer.write(as: .ui) { _ in } == .committed(generation: expected)) }
        try #require(size(wal(live.url)) > 32, "precondition: the three commits sit in the -wal, not yet checkpointed")
        let scene = StoreFixture(kind: .grdb, directory: try StoreFixture.temporaryDirectory())
        for name in try FileManager.default.contentsOfDirectory(atPath: live.directory.path) {
            try FileManager.default.copyItem(at: live.directory.appendingPathComponent(name), to: scene.directory.appendingPathComponent(name))
        }
        await writer.close()
        let walCopy = wal(scene.url)
        switch loss {
        case .walHeaderOnly:
            try FileHandle(forWritingTo: walCopy).truncate(atOffset: 32)
        case .walTornMidFrame:
            // WAL layout: a 32-byte header, then frames of 24 + page_size
            // bytes; frame-header bytes 4…7 (big-endian) are non-zero on the
            // LAST frame of a commit. The FIRST commit in this -wal is GRDB's
            // open probe (`CREATE TABLE grdb_issue_102; DROP TABLE …`, see
            // reopeningACurrentFileRunsNoMigrationAndChangesNothingLogical);
            // the SECOND is generation 6. Keep it whole and cut 100 bytes
            // into the frame after it. The page size
            // is read from the database HEADER (offset 16, big-endian; 1 =
            // 65536), never through a connection: a read-write connection
            // closing last would checkpoint the -wal into the file and delete
            // it — the power loss would then have nothing left to tear.
            let header = try Data(contentsOf: scene.url).prefix(100)
            var pageSize = Int(header[16]) << 8 | Int(header[17])
            if pageSize == 1 { pageSize = 65_536 }
            let bytes = try Data(contentsOf: walCopy)
            let frameSize = 24 + pageSize
            var commitEnds: [Int] = []
            var offset = 32
            while offset + frameSize <= bytes.count {
                let commit = bytes[offset + 4..<offset + 8].reduce(0) { $0 << 8 | Int($1) }
                if commit != 0 { commitEnds.append(offset + frameSize) }
                offset += frameSize
            }
            try #require(commitEnds.count == 4, "expected GRDB's probe + three commits in the -wal, found \(commitEnds.count) commit frames in \(bytes.count) bytes")
            let end = commitEnds[1]
            try #require(end + 100 < bytes.count)
            try FileHandle(forWritingTo: walCopy).truncate(atOffset: UInt64(end + 100))
        case .shmMissing:
            try? FileManager.default.removeItem(at: shm(scene.url))
        }
        return (scene, 5, 8)
    }

    @Test("power loss: a torn -wal or a missing -shm — the store opens (never refuses), integrity is ok, the generation is a committed prefix with its history, and the witnesses make a lost tail read-only until adopted",
          arguments: PowerLoss.allCases)
    func tornWALOpensAtACommittedPrefixAndTheWitnessesSpeak(_ loss: PowerLoss) async throws {
        let (scene, before, after) = try await Self.powerLossScene(loss)
        defer { scene.remove() }
        let reopened = Self.repository()
        let outcome = await reopened.open(at: scene.url)
        let generation = await reopened.generation
        print("[corner-2026-10-25] \(loss): \(outcome) at generation \(generation)")
        if case .refused(let words) = outcome {
            Issue.record("\(loss): the catalog REFUSED to open after a power loss: \(words)")
            return
        }
        #expect((before...after).contains(generation), "\(loss): generation \(generation) is not a committed prefix of 5…8")
        switch loss {
        case .walHeaderOnly: #expect(generation == before, "\(loss): nothing after the checkpoint should survive")
        case .walTornMidFrame: #expect(generation == before + 1, "\(loss): exactly the first commit should survive")
        case .shmMissing: #expect(generation == after, "\(loss): every commit should survive; the -shm is rebuilt")
        }
        #expect(try Self.historyNewest(scene.url) == generation, "\(loss): generation_history does not end at the counter")
        #expect(scene.highWaterText() == "\(after)", "\(loss): the witness copied at the power loss should still read \(after)")
        switch outcome {
        case .readWrite:
            #expect(generation == after, "\(loss): opened read-write below the mark \(after)")
        case .readOnly(let reason):
            #expect(generation < after, "\(loss): read-only although every commit survived")
            #expect(reason.hasPrefix("restoredBelowHighWater"), Comment(rawValue: reason))
            #expect(reason.contains("generation \(generation)"), Comment(rawValue: reason))
            let refused = await reopened.write(as: .ui) { _ in }
            #expect(!refused.isCommitted, "\(loss): a write landed below the high-water: \(refused)")
            #expect(await reopened.adopt(toHighWater: after) == .adopted(from: generation, to: after))
            #expect(await reopened.write(as: .ui) { _ in } == .committed(generation: after + 1), "\(loss): adopting the mark did not restore writing")
        case .refused:
            break   // recorded above
        }
        await reopened.close()
        #expect(try CatalogHardKillTests.integrityCheck(scene.url) == ["ok"], "\(loss)")
    }

    // MARK: - 2. Close while another connection reads

    @Test("close while a reader holds a WAL snapshot — close waits for it (the busy timeout, not a skipped checkpoint), then leaves one self-contained file with every commit",
          .timeLimit(.minutes(1)))
    func closeWaitsForAReaderAndStillLeavesOneFile() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 5)
        defer { fixture.remove() }
        let repository = Self.repository()
        try #require(await repository.open(at: fixture.url) == .readWrite)
        for expected in 6...8 { try #require(await repository.write(as: .ui) { _ in } == .committed(generation: expected)) }
        try #require(Self.size(Self.wal(fixture.url)) > 32, "precondition: the commits sit in the -wal")
        let reader = try SnapshotReader(fixture.url)
        let holdMilliseconds = 400
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(holdMilliseconds)) { reader.release() }
        let clock = ContinuousClock()
        let start = clock.now
        await repository.close()
        let waited = clock.now - start
        print("[corner-2026-10-25] close under a reader waited \(waited)")
        #expect(waited >= .milliseconds(holdMilliseconds - 50), "close did not wait for the reader — it skipped or failed its checkpoint")
        #expect(waited < .seconds(GRDBCatalogRepository.busyTimeoutSeconds), "close waited the whole busy timeout although the reader let go")
        #expect(Self.size(Self.wal(fixture.url)) == 0, "the -wal still holds frames after close: a copy of catalog.sqlite alone would lose commits")
        let copy = fixture.directory.appendingPathComponent("alone.sqlite")
        try FileManager.default.copyItem(at: fixture.url, to: copy)
        #expect(try Self.storedGeneration(copy) == 8, "catalog.sqlite alone does not carry every commit")
        #expect(try Self.storedGeneration(fixture.url) == 8)
    }

    // MARK: - 3. Every migration path lands at the current version with both versions agreeing

    @Test("a file as an older build left it (schema 7, 7+data, 8, 9, 10, 11, 12) opens read-write, lands at 13, and PRAGMA user_version == catalog_state.schema_version == 13 with all eight migrations recorded",
          arguments: [1, 2, 3, 4, 5, 6, 7])
    func everyOlderSchemaVersionMigratesToCurrentWithBothVersionsAgreeing(_ migrations: Int) async throws {
        let fixture = try Self.olderBuildFixture(migrations: migrations)
        defer { fixture.remove() }
        let startVersion = Self.schemaVersion(afterMigrations: migrations)
        let startUserVersion = try Self.readOnly(fixture.url) { try Int.fetchOne($0, sql: "PRAGMA user_version") ?? -1 }
        try #require(try Self.count(fixture.url, "SELECT schema_version FROM catalog_state") == startVersion, "fixture at schema \(startVersion)")
        try #require(startUserVersion == startVersion, "fixture user_version \(startUserVersion) ≠ schema_version \(startVersion)")

        let repository = Self.repository()
        let outcome = await repository.open(at: fixture.url)
        #expect(outcome == .readWrite, "\(migrations) migrations: \(outcome)")
        let pragmas = try await repository.pragmas()
        #expect(pragmas["user_version"] == "\(GRDBCatalogRepository.currentSchemaVersion)", "from \(startVersion): user_version \(pragmas["user_version"] ?? "?")")
        let verdict = await repository.verify()
        #expect(verdict == .ok(generation: 0, highWater: 0), "from \(startVersion): \(verdict)")
        #expect(await repository.write(as: .ui) { _ in } == .committed(generation: 1), "from \(startVersion): the migrated file does not take a write")
        await repository.close()

        #expect(try Self.count(fixture.url, "SELECT schema_version FROM catalog_state WHERE singleton = 1") == GRDBCatalogRepository.currentSchemaVersion)
        #expect(try Self.readOnly(fixture.url) { try Int.fetchOne($0, sql: "PRAGMA user_version") } == GRDBCatalogRepository.currentSchemaVersion)
        let recorded = try Self.readOnly(fixture.url) { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid") }
        #expect(recorded == [CatalogBookkeepingSchema.migrationID, CatalogDataSchema.migrationID, CatalogLiveWritesSchema.migrationID,
                             CatalogPendingRowsSchema.migrationID, CatalogCommitB22Schema.migrationID,
                             CatalogFolderKindSchema.migrationID, CatalogDecisionTablesSchema.migrationID,
                             CatalogProvenanceRolesSchema.migrationID], "from \(startVersion): \(recorded)")
        #expect(try Self.count(fixture.url, "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name IN ('files', 'row_knowledge', 'pending_rows', 'pending_purges', 'footage_likeness', 'ignored_content_put_back', 'provenance_roles')") == 7)
        #expect(try CatalogHardKillTests.integrityCheck(fixture.url) == ["ok"])
    }

    /// What a plain reopen writes, measured 2026-10-25 by tracing the
    /// statements: GRDB's `DatabasePool` init runs `BEGIN IMMEDIATE; CREATE
    /// TABLE grdb_issue_102 (id INTEGER PRIMARY KEY); DROP TABLE grdb_issue_102;
    /// COMMIT` on EVERY open (its WAL-activation probe) — one schema-cookie
    /// bump, one sqlite_schema leaf rewritten, a page allocated and freed.
    /// So catalog.sqlite is NOT byte-identical across an open; what must be
    /// identical is everything logical: no migration runs, every schema row
    /// (type, name, tbl_name, rootpage, sql) is the same, both versions and
    /// the generation are unchanged, and integrity holds.
    @Test("a file already at the current schema (13) — a second open and close runs no migration: grdb_migrations, every sqlite_master row, user_version, schema_version and the generation are unchanged (GRDB's own open probe is the only write)")
    func reopeningACurrentFileRunsNoMigrationAndChangesNothingLogical() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 3)
        defer { fixture.remove() }
        try CatalogOpenCornerTests.removeSidecars(fixture.url)
        let schemaRows = "SELECT type, name, tbl_name, rootpage, sql FROM sqlite_master ORDER BY type, name"
        func logicalState() throws -> (migrations: [String], schema: [String], versions: [Int], generation: Int) {
            try Self.readOnly(fixture.url) { db in
                (try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid"),
                 try Row.fetchAll(db, sql: schemaRows).map { "\($0[0] as String):\($0[1] as String):\($0[2] as String)@\($0[3] as Int) \($0[4] as String? ?? "")" },
                 [try Int.fetchOne(db, sql: "PRAGMA user_version") ?? -1, try Int.fetchOne(db, sql: "SELECT schema_version FROM catalog_state") ?? -1],
                 try Int.fetchOne(db, sql: "SELECT generation FROM generations WHERE id = 1") ?? -1)
            }
        }
        let before = try logicalState()
        try #require(before.migrations.count == 8)
        try #require(before.versions == [GRDBCatalogRepository.currentSchemaVersion, GRDBCatalogRepository.currentSchemaVersion])

        let repository = Self.repository()
        let outcome = await repository.open(at: fixture.url)
        #expect(outcome == .readWrite, "\(outcome)")
        #expect(await repository.generation == 3)
        await repository.close()

        let after = try logicalState()
        #expect(after.migrations == before.migrations, "a reopen re-ran a migration: \(after.migrations)")
        #expect(after.schema == before.schema, "a reopen changed the schema: \(Set(after.schema).symmetricDifference(before.schema).sorted())")
        #expect(after.versions == before.versions)
        #expect(after.generation == 3)
        #expect(Self.size(Self.wal(fixture.url)) == 0, "close left frames in the -wal")
        #expect(try CatalogHardKillTests.integrityCheck(fixture.url) == ["ok"])
    }

    // MARK: - 4. Foreign keys through the store's own doors

    enum Orphan: String, CaseIterable, Sendable, CustomStringConvertible {
        /// knowledge_sources.digest → content(digest): the content was never recorded.
        case knowledgeSourceWithoutItsContent
        /// lineage.child_digest / parent_digest → content(digest): neither end exists.
        case lineageBetweenUnknownContents
        /// row_knowledge.file_id → files(id): the row was never stored.
        case rowKnowledgeWithoutItsFile
        var description: String { rawValue }
        var table: String {
            switch self {
            case .knowledgeSourceWithoutItsContent: return "knowledge_sources"
            case .lineageBetweenUnknownContents: return "lineage"
            case .rowKnowledgeWithoutItsFile: return "row_knowledge"
            }
        }
    }

    @Test("an orphan row through the store's own doors (knowledge → content, lineage → content, row_knowledge → files) — the write is refused whole with the engine's FOREIGN KEY words; the table stays empty; the generation does not move",
          arguments: Orphan.allCases)
    func anOrphanRowThroughTheStoresDoorsIsRefusedWhole(_ orphan: Orphan) async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 2)
        defer { fixture.remove() }
        let repository = Self.repository()
        try #require(await repository.open(at: fixture.url) == .readWrite)
        let outcome = await repository.write(as: .importRun) { tx in
            switch orphan {
            case .knowledgeSourceWithoutItsContent:
                try tx.insertImportRun(Self.importRun())
                try tx.insertKnowledgeSource(Self.knowledge(digest: Self.digestB))
            case .lineageBetweenUnknownContents:
                let trim = CatalogRecordDTO.LineageValue(derivedFrom: "X", derivationKind: "trim", cleanupRecipeID: nil,
                                                         cleanupRecipeVersion: nil, trimInSeconds: 1, trimOutSeconds: 2)
                _ = try tx.insertRelation(.lineage(childDigest: Self.digestA, parentDigest: Self.digestB, value: trim, recordedAt: nil))
            case .rowKnowledgeWithoutItsFile:
                try tx.appendRowKnowledge(CatalogRow.RowKnowledge(fileID: Self.fileOne, digest: nil, field: "userNotes",
                                                                 value: .string("orphan"), setAt: 1, source: "app:ui"))
            }
        }
        let generation = await repository.generation
        await repository.close()
        guard case .refused(let words) = outcome else {
            Issue.record("\(orphan): an orphan row was not refused: \(outcome)")
            return
        }
        #expect(words.contains("FOREIGN KEY constraint failed"), "\(orphan): \(words)")
        #expect(generation == 2, "\(orphan): the generation moved on a refused write")
        #expect(try Self.storedGeneration(fixture.url) == 2)
        #expect(try Self.count(fixture.url, "SELECT count(*) FROM \(orphan.table)") == 0, "\(orphan): the orphan landed")
        #expect(try Self.count(fixture.url, "SELECT count(*) FROM import_runs") == 0, "\(orphan): part of the refused write stayed")
    }

    // MARK: - 5. Digest identity: case, NULL, empty

    @Test("one SHA-256 spelled in upper case and in lower case is ONE content row; the second insert is refused as a duplicate (never a second content), and what is stored is lower case")
    func aDigestIsOneContentWhateverItsCase() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        let repository = Self.repository()
        try #require(await repository.open(at: fixture.url) == .readWrite)
        let upper = Self.digestA.uppercased()
        let first = await repository.write(as: .importRun) { tx in try tx.insertContent(Self.content(upper)) }
        #expect(first == .committed(generation: 1), "the upper-case spelling was not folded: \(first)")
        let second = await repository.write(as: .importRun) { tx in try tx.insertContent(Self.content(Self.digestA)) }
        await repository.close()
        guard case .refused(let words) = second else {
            Issue.record("the same digest in lower case made a second content row: \(second)")
            return
        }
        #expect(words.contains("UNIQUE constraint failed: content.digest"), Comment(rawValue: words))
        #expect(try Self.count(fixture.url, "SELECT count(*) FROM content") == 1)
        let stored = try Self.readOnly(fixture.url) { try String.fetchOne($0, sql: "SELECT digest FROM content") }
        #expect(stored == Self.digestA)
    }

    @Test("an empty-string digest is refused at every door (content, files, knowledge_sources); a NULL digest lands only where the DDL allows it (knowledge_sources: 'the row had no agreeing whole-file digest')")
    func anEmptyDigestIsRefusedAndANullDigestLandsOnlyWhereTheDDLAllowsIt() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        let repository = Self.repository()
        try #require(await repository.open(at: fixture.url) == .readWrite)

        let emptyContent = await repository.write(as: .importRun) { tx in try tx.insertContent(Self.content("")) }
        guard case .refused(let contentWords) = emptyContent else {
            Issue.record("content with an empty digest landed: \(emptyContent)"); await repository.close(); return
        }
        #expect(contentWords.contains("CHECK constraint failed"), Comment(rawValue: contentWords))

        let emptyFile = await repository.write(as: .importRun) { tx in
            try tx.insertVolume(Self.volumeRow, caseSensitive: false)
            try tx.insertContent(Self.content(Self.digestA))
            try tx.insertFile(Self.file(Self.fileOne, digest: "", path: "/Volumes/A/one.mov"), volumeCaseSensitive: false)
        }
        guard case .refused = emptyFile else {
            Issue.record("a files row with an empty digest landed: \(emptyFile)"); await repository.close(); return
        }

        let emptyKnowledge = await repository.write(as: .importRun) { tx in
            try tx.insertImportRun(Self.importRun())
            try tx.insertKnowledgeSource(Self.knowledge(digest: ""))
        }
        guard case .refused(let knowledgeWords) = emptyKnowledge else {
            Issue.record("a knowledge row with an empty digest landed: \(emptyKnowledge)"); await repository.close(); return
        }
        #expect(knowledgeWords.contains("FOREIGN KEY constraint failed"), Comment(rawValue: knowledgeWords))

        let nullKnowledge = await repository.write(as: .importRun) { tx in
            try tx.insertImportRun(Self.importRun())
            try tx.insertKnowledgeSource(Self.knowledge(digest: nil))
        }
        #expect(nullKnowledge == .committed(generation: 1), "a NULL digest on knowledge_sources is the documented 'no digest': \(nullKnowledge)")
        let generation = await repository.generation
        await repository.close()
        #expect(generation == 1, "three refusals and one commit: generation \(generation)")
        #expect(try Self.count(fixture.url, "SELECT count(*) FROM content") == 0, "a refused write left content behind")
        #expect(try Self.count(fixture.url, "SELECT count(*) FROM files") == 0)
        #expect(try Self.count(fixture.url, "SELECT count(*) FROM knowledge_sources WHERE digest IS NULL") == 1)
        #expect(try Self.count(fixture.url, "SELECT count(*) FROM knowledge_sources") == 1)
    }

    // MARK: - 6. Another writer holds the lock while a commit runs

    @Test("another connection holds the write lock for 300 ms while our commit starts — the commit waits it out (busy timeout honoured) and lands; nothing is refused, nothing lost",
          .timeLimit(.minutes(1)))
    func aCommitWaitsOutAShortLockAndLands() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 2)
        defer { fixture.remove() }
        let repository = Self.repository()
        try #require(await repository.open(at: fixture.url) == .readWrite)
        let other = try OtherWriter(fixture.url)                      // BEGIN IMMEDIATE from "another process"
        let holdMilliseconds = 300
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(holdMilliseconds)) { other.release() }
        let clock = ContinuousClock()
        let start = clock.now
        let outcome = await repository.write(as: .ui) { _ in }
        let waited = clock.now - start
        print("[corner-2026-10-25] commit under a 300 ms lock: \(outcome) after \(waited)")
        #expect(outcome == .committed(generation: 3), "the commit did not wait for the lock: \(outcome)")
        #expect(waited >= .milliseconds(holdMilliseconds - 50), "the commit landed while the other writer held the lock")
        #expect(waited < .seconds(GRDBCatalogRepository.busyTimeoutSeconds), "the commit waited the whole busy timeout although the lock was released")
        #expect(await repository.write(as: .ui) { _ in } == .committed(generation: 4))
        await repository.close()
        #expect(try Self.storedGeneration(fixture.url) == 4)
        #expect(try Self.historyNewest(fixture.url) == 4)
    }

    // MARK: - 7. A sealed copy between queued writes

    @Test("a sealed copy taken while 40 writes are queued is one whole generation — a rollback-journal file the viewer door accepts, integrity ok, history ending at its counter, never half a commit",
          .timeLimit(.minutes(1)))
    func aSealedCopyTakenBetweenQueuedWritesIsOneWholeGeneration() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 1)
        defer { fixture.remove() }
        let repository = Self.repository()
        try #require(await repository.open(at: fixture.url) == .readWrite)
        let writes = Task {
            var last = 1
            for _ in 0..<40 {
                let outcome = await repository.write(as: .ui) { _ in }
                if case .committed(let generation) = outcome { last = generation }
            }
            return last
        }
        var copies: [(url: URL, generation: Int)] = []
        for index in 0..<3 {
            try await Task.sleep(for: .milliseconds(15))
            let copy = fixture.directory.appendingPathComponent("sealed-\(index).sqlite")
            let sealed = repository.sealedCopyBlocking(to: copy)
            #expect(sealed == nil, "copy \(index): \(sealed ?? "")")
            guard sealed == nil else { continue }
            #expect(GRDBCatalogRepository.sealedSnapshotRefusal(copy) == nil, "copy \(index) is not a sealed snapshot: \(GRDBCatalogRepository.sealedSnapshotRefusal(copy) ?? "")")
            let generation = try Self.storedGeneration(copy)
            let newest = try Self.historyNewest(copy)
            #expect(newest == generation, "copy \(index): history ends at \(newest), the counter reads \(generation)")
            #expect(try CatalogHardKillTests.integrityCheck(copy) == ["ok"], "copy \(index)")
            copies.append((copy, generation))
        }
        let last = await writes.value
        await repository.close()
        print("[corner-2026-10-25] sealed copies at generations \(copies.map(\.generation)), writes ended at \(last)")
        #expect(last == 41)
        #expect(copies.map(\.generation) == copies.map(\.generation).sorted(), "a later copy is older than an earlier one")
        for (copy, generation) in copies {
            #expect((1...41).contains(generation))
            let viewer = Self.repository()
            let opened = await viewer.openSealedSnapshot(at: copy)
            #expect(opened == .readOnly(reason: GRDBCatalogRepository.sealedSnapshotWords), "\(copy.lastPathComponent): \(opened)")
            #expect(await viewer.generation == generation)
            await viewer.close()
        }
    }

    // MARK: - 8. Bad files at the catalog path

    @Test("a zero-byte catalog.sqlite (a truncated restore) beside witnesses at generation 5 — never opened read-write: the store opens it read-only in the restoredBelowHighWater words, every write is refused, the witnesses are untouched")
    func aZeroByteCatalogBesideItsWitnessesNeverOpensReadWrite() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 5)
        defer { fixture.remove() }
        try CatalogOpenCornerTests.removeSidecars(fixture.url)
        try Data().write(to: fixture.url)                            // SQLite reads an empty file as a NEW database
        let witnessesBefore = [try Self.sha256(fixture.highWaterURL), try Self.sha256(fixture.highWaterLogURL)]
        let repository = Self.repository()
        let outcome = await repository.open(at: fixture.url)
        let wrote = await repository.write(as: .ui) { _ in }
        let generation = await repository.generation
        await repository.close()
        print("[corner-2026-10-25] zero-byte catalog: \(outcome)")
        switch outcome {
        case .readWrite:
            Issue.record("a zero-byte catalog.sqlite beside witnesses at 5 opened read-write as a fresh catalog")
        case .readOnly(let reason):
            #expect(reason.hasPrefix("restoredBelowHighWater"), Comment(rawValue: reason))
            #expect(reason.contains("at generation 0"), Comment(rawValue: reason))
            #expect(reason.contains("already wrote generation 5"), Comment(rawValue: reason))
        case .refused(let reason):
            // Also acceptable: refusing is never wrong here. Today it opens read-only.
            #expect(!reason.isEmpty)
        }
        #expect(!wrote.isCommitted, "a write landed in a zero-byte catalog: \(wrote)")
        #expect(generation == 0)
        #expect([try Self.sha256(fixture.highWaterURL), try Self.sha256(fixture.highWaterLogURL)] == witnessesBefore, "a witness moved")
        #expect(fixture.highWaterText() == "5")
    }

    @Test("a file that is not an SQLite database at the catalog path (catalog.json renamed) — both doors refuse with words; not one byte changes; the repository stays shut")
    func aFileThatIsNotADatabaseIsRefusedAndNeverWritten() async throws {
        let fixture = StoreFixture(kind: .grdb, directory: try StoreFixture.temporaryDirectory())
        defer { fixture.remove() }
        let json = "{\"schemaVersion\": 6, \"records\": [" + String(repeating: "{\"id\": \"not a database\"},", count: 200) + "{}]}\n"
        try Data(json.utf8).write(to: fixture.url)
        try fixture.writeHighWater("5")
        let before = try [fixture.url, fixture.highWaterURL].map(Self.sha256)
        let listing = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).sorted()

        let repository = Self.repository()
        let opened = await repository.open(at: fixture.url)
        let wrote = await repository.write(as: .ui) { _ in }
        await repository.close()
        print("[corner-2026-10-25] not a database: \(opened)")
        guard case .refused(let words) = opened else {
            Issue.record("a file that is not a database was opened: \(opened)")
            return
        }
        #expect(words.lowercased().contains("not a database") || words.lowercased().contains("could not open"), Comment(rawValue: words))
        #expect(wrote == .refused(reason: "not open"), "a refused open left something writable: \(wrote)")

        let reader = Self.repository()
        let readerOpened = await reader.openForReading(at: fixture.url)
        await reader.close()
        guard case .refused = readerOpened else {
            Issue.record("the read-only door opened a file that is not a database: \(readerOpened)")
            return
        }
        #expect(try [fixture.url, fixture.highWaterURL].map(Self.sha256) == before, "a refused open wrote")
        let after = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).sorted()
        #expect(after.filter { !$0.hasSuffix("-wal") && !$0.hasSuffix("-shm") } == listing, "a refused open left new files: \(after)")
    }

    enum CounterTable: String, CaseIterable, Sendable, CustomStringConvertible {
        case catalogStateEmptied = "catalog_state"
        case generationsEmptied = "generations"
        var description: String { rawValue }
        var trigger: String { self == .catalogStateEmptied ? "catalog_state_no_delete" : "generations_no_delete" }
        var words: String { self == .catalogStateEmptied ? "found 0 and 1" : "found 1 and 0" }
    }

    @Test("catalog_state or generations emptied by a raw connection (its guard trigger dropped first) — open is refused with words counting the rows; nothing is written; the file is byte-identical",
          arguments: CounterTable.allCases)
    func aCounterTableWithTheWrongRowCountIsRefusedAtOpen(_ table: CounterTable) async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 3)
        defer { fixture.remove() }
        let shell = try DatabaseQueue(path: fixture.url.path)       // the sqlite3 shell's hand
        try shell.inDatabase { db in
            try db.execute(sql: "DROP TRIGGER \(table.trigger)")
            try db.execute(sql: "DELETE FROM \(table.rawValue)")
        }
        try shell.inDatabase { try $0.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
        try shell.close()
        try CatalogOpenCornerTests.removeSidecars(fixture.url)
        let before = try Self.sha256(fixture.url)

        let repository = Self.repository()
        let opened = await repository.open(at: fixture.url)
        let wrote = await repository.write(as: .ui) { _ in }
        await repository.close()
        print("[corner-2026-10-25] \(table): \(opened)")
        guard case .refused(let words) = opened else {
            Issue.record("\(table): a catalog with the wrong number of \(table.rawValue) rows was opened: \(opened)")
            return
        }
        #expect(words.contains("expected one catalog_state row and one generations row"), "\(table): \(words)")
        #expect(words.contains(table.words), "\(table): \(words)")
        #expect(wrote == .refused(reason: "not open"), "\(table): \(wrote)")
        #expect(try Self.sha256(fixture.url) == before, "\(table): a refused open wrote into catalog.sqlite")
    }

    // MARK: - 9. The read-only door

    @Test("the read-only door (openForReading) on a catalog as the app's quit leaves it: reads work, every write is refused in the read-only words, no witness is raised, and a writer's later commit is visible to the reader")
    func theReadOnlyDoorReadsFollowsTheWriterAndNeverWrites() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 5)
        defer { fixture.remove() }
        // As the app's close leaves it: a 0-byte -wal (TRUNCATE) and the -shm.
        try #require(FileManager.default.fileExists(atPath: Self.wal(fixture.url).path), "precondition: the store's close leaves the -wal beside the catalog")
        let witnessesBefore = [try Self.sha256(fixture.highWaterURL), try Self.sha256(fixture.highWaterLogURL)]

        let reader = Self.repository("viewer")
        let opened = await reader.openForReading(at: fixture.url)
        #expect(opened == .readOnly(reason: GRDBCatalogRepository.readerOnlyWords), "\(opened)")
        #expect(try await reader.read { $0.generation } == 5)
        let refused = await reader.write(as: .ui) { _ in }
        guard case .refused(let why) = refused else {
            Issue.record("the read-only door took a write: \(refused)"); await reader.close(); return
        }
        #expect(why.hasPrefix("read-only:"), Comment(rawValue: why))
        #expect(why.contains(GRDBCatalogRepository.readerOnlyWords), Comment(rawValue: why))
        #expect(reader.writeBlocking(as: .ui) { _ in }.isCommitted == false)
        #expect(await reader.adopt(toHighWater: 9).isAdopted == false, "the read-only door adopted")
        #expect([try Self.sha256(fixture.highWaterURL), try Self.sha256(fixture.highWaterLogURL)] == witnessesBefore, "the read-only door raised a witness")

        let writer = Self.repository("writer")
        #expect(await writer.open(at: fixture.url) == .readWrite, "the reader kept the writer out")
        #expect(await writer.write(as: .ui) { _ in } == .committed(generation: 6))
        #expect(try await reader.read { $0.generation } == 6, "the reader does not see the writer's commit")
        await writer.close()
        await reader.close()
        #expect(try Self.storedGeneration(fixture.url) == 6)
        #expect(fixture.highWaterText() == "6")
    }

    @Test("the read-only door on a file an older build left (schema 11) refuses in words — it never migrates a file it may not write; not one byte changes")
    func theReadOnlyDoorRefusesAnOlderSchemaInsteadOfMigratingIt() async throws {
        let fixture = try Self.olderBuildFixture(migrations: 6)      // schema 11, -wal beside it
        defer { fixture.remove() }
        let before = try Self.sha256(fixture.url)
        let reader = Self.repository("viewer")
        let opened = await reader.openForReading(at: fixture.url)
        let wrote = await reader.write(as: .ui) { _ in }
        await reader.close()
        print("[corner-2026-10-25] read-only door on schema 11: \(opened)")
        guard case .refused(let words) = opened else {
            Issue.record("the read-only door opened (and so migrated?) a schema-11 file: \(opened)")
            return
        }
        #expect(words.contains("schema is not current"), Comment(rawValue: words))
        #expect(wrote == .refused(reason: "not open"))
        #expect(try Self.sha256(fixture.url) == before, "the read-only door changed catalog.sqlite")
        #expect(try Self.count(fixture.url, "SELECT schema_version FROM catalog_state") == 11)
        #expect(try Self.count(fixture.url, "SELECT count(*) FROM grdb_migrations") == 6)
    }

    /// FOUND 2026-10-25 by this audit. Apple's libsqlite3 (3.54.0 "aapl",
    /// macOS 27) refuses SQLITE_OPEN_READONLY on a WAL-mode database that has
    /// no `-wal` beside it: SQLITE_CANTOPEN (14) "unable to open database
    /// file". Upstream SQLite (Homebrew Python's 3.54.1) opens it and creates
    /// the sidecars; `/usr/bin/sqlite3 -readonly` fails exactly like GRDB.
    /// A 0-byte `-wal` is enough (the engine then creates its own `-shm`).
    ///
    /// When the -wal is missing: the LAST connection to close was read-write
    /// — a `sqlite3 catalog.sqlite` shell session, a `.backup` copy, `cp`. The
    /// app's own close leaves a 0-byte -wal (GRDB closes its read-only
    /// readers last), so launch → preview helper → Hallie shell are fine; the
    /// catalog Rick last touched with the sqlite3 shell is not. Fail-closed,
    /// never a data risk — but the read-only doors (`openForReading`,
    /// `openReadOnly`) and `CatalogPreflightReader` answer with the engine's
    /// words, not with what happened or what to do.
    ///
    /// #386 (Rick 2026-10-26): the read-only doors restore the empty -wal
    /// when the folder is writable (SQLiteWALSidecar, create-only) and
    /// otherwise refuse in words that say why (SQLiteWALSidecarTests). This
    /// was the pin; it is now the green half of #386's red/green.
    @Test("#386: on Apple SQLite the read-only door restores the -wal a read-write last closer (sqlite3 shell, .backup, cp) removed, and opens the catalog")
    func theReadOnlyDoorNeedsTheWALSidecarOnAppleSQLite() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 5)
        defer { fixture.remove() }
        // What a `sqlite3 catalog.sqlite` session leaves on exit: the -wal and -shm gone.
        try CatalogOpenCornerTests.removeSidecars(fixture.url)
        let before = try Self.sha256(fixture.url)
        let reader = Self.repository("viewer")
        let opened = await reader.openForReading(at: fixture.url)
        await reader.close()
        print("[corner-2026-10-25] read-only door without a -wal beside the catalog: \(opened)")
        #expect(opened == .readOnly(reason: GRDBCatalogRepository.readerOnlyWords), "\(opened)")
        #expect(FileManager.default.fileExists(atPath: Self.wal(fixture.url).path), "the door did not restore the -wal")
        #expect(Self.size(Self.wal(fixture.url)) == 0, "the restored -wal must be empty")
        #expect(try Self.sha256(fixture.url) == before, "the read-only door changed catalog.sqlite")
        // The same catalog with the 0-byte -wal the app's close leaves opens read-only.
        try Data().write(to: Self.wal(fixture.url))
        let again = Self.repository("viewer")
        #expect(await again.openForReading(at: fixture.url) == .readOnly(reason: GRDBCatalogRepository.readerOnlyWords))
        #expect(try await again.read { $0.generation } == 5)
        await again.close()
    }
}

// MARK: - Fixtures, rows and the snapshot reader (an extension keeps the
// suite's own body under SwiftLint's 600 lines; `Self.` still reaches them)

extension CatalogCornerCases2026_10_25Tests {

    /// The eight production migrations in registration order, so a fixture
    /// "as an older build left it" is the real DDL cut off after `count`
    /// migrations. (Mirrors `GRDBCatalogRepository.migrator`; a drift there
    /// shows up as a migration this prefix cannot complete.)
    private static func olderBuildMigrator(migrations count: Int) -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        let steps: [(String, [String])] = [
            (CatalogBookkeepingSchema.migrationID, CatalogBookkeepingSchema.statements + [
                "PRAGMA user_version = 7",
                "INSERT INTO catalog_state (singleton, schema_version) VALUES (1, 7)",
                "INSERT INTO generations (id, generation, saved_at, saved_from_host) VALUES (1, 0, 1, 'older-build')",
                "INSERT INTO generation_history (generation, committed_at, host, writer, files_live, files_total) VALUES (0, 1, 'older-build', 'create', 0, 0)",
            ]),
            (CatalogDataSchema.migrationID, CatalogDataSchema.statements),
            (CatalogLiveWritesSchema.migrationID, CatalogLiveWritesSchema.statements + CatalogLiveWritesSchema.versionBump),
            (CatalogPendingRowsSchema.migrationID, CatalogPendingRowsSchema.statements + CatalogPendingRowsSchema.versionBump),
            (CatalogCommitB22Schema.migrationID, CatalogCommitB22Schema.statements + CatalogCommitB22Schema.versionBump),
            (CatalogFolderKindSchema.migrationID, CatalogFolderKindSchema.statements + CatalogFolderKindSchema.versionBump),
            (CatalogDecisionTablesSchema.migrationID, CatalogDecisionTablesSchema.statements + CatalogDecisionTablesSchema.versionBump),
            (CatalogProvenanceRolesSchema.migrationID, CatalogProvenanceRolesSchema.statements + CatalogProvenanceRolesSchema.versionBump),
        ]
        for (identifier, statements) in steps.prefix(count) {
            migrator.registerMigration(identifier, foreignKeyChecks: .immediate) { db in
                for statement in statements { try db.execute(sql: statement) }
            }
        }
        return migrator
    }

    /// A WAL-mode catalog.sqlite as a build with `migrations` of the eight
    /// would have left it after a quit: closed, checkpointed, and — as the
    /// store's own close leaves it — a 0-byte -wal beside it (GRDB closes
    /// the writer before its read-only readers, so SQLite never deletes the
    /// sidecars; here the writer IS the last connection, so they are put
    /// back by hand). No witnesses: the store's first open raises both.
    private static func olderBuildFixture(migrations count: Int) throws -> StoreFixture {
        let fixture = StoreFixture(kind: .grdb, directory: try StoreFixture.temporaryDirectory())
        let pool = try DatabasePool(path: fixture.url.path)          // WAL, like every real catalog
        try olderBuildMigrator(migrations: count).migrate(pool)
        try pool.writeWithoutTransaction { try $0.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
        try pool.close()
        if !FileManager.default.fileExists(atPath: wal(fixture.url).path) { try Data().write(to: wal(fixture.url)) }
        return fixture
    }

    /// The schema_version a prefix of `count` migrations leaves (7, 7, 8, 9, 10, 11, 12, 13).
    private static func schemaVersion(afterMigrations count: Int) -> Int {
        [0, 7, 7, 8, 9, 10, 11, 12, 13][count]
    }

    // MARK: - The rows the door tests write

    private static let volume = SchemaSeed.volume
    private static let digestA = String(repeating: "a", count: 64)
    private static let digestB = String(repeating: "b", count: 64)
    private static let fileOne = "00000000-0000-4000-8000-000000000001"
    private static let runID = "R-corners"

    private static func importRun() -> CatalogRow.ImportRun {
        CatalogRow.ImportRun(runID: runID, startedAt: 1_700_000_000, sourceSHA256: String(repeating: "d", count: 64),
                             sourceGeneration: 5, integrityRunID: "IR-1", auditRunStartedAt: 1_699_990_000,
                             auditRunFinishedAt: 1_699_990_500, auditGeneration: 5, integrityStartedAt: 1_699_995_000,
                             integrityGeneration: 5)
    }

    private static func content(_ digest: String) -> CatalogRecordDTO.ContentRow {
        CatalogRecordDTO.ContentRow(digest: digest, algorithm: "sha256", byteCount: 100, firstSeenAt: 1_700_000_000, firstSeenHow: .import)
    }

    private static func knowledge(digest: String?) -> CatalogRow.KnowledgeSource {
        CatalogRow.KnowledgeSource(importRun: runID, sourceOrdinal: 0, jsonRowID: fileOne, digest: digest,
                                   value: .init(field: .starRating, valueJSON: .int(3), setAt: nil))
    }

    private static func file(_ id: String, digest: String, path: String) -> CatalogRecordDTO.FileRow {
        CatalogRecordDTO.FileRow(
            id: id, contentDigest: digest, volumeUUID: volume, fullPath: path, pathFold: CatalogRecordDTO.pathFold(path),
            filename: (path as NSString).lastPathComponent, ext: "mov", directory: (path as NSString).deletingLastPathComponent,
            sizeBytes: 100, fsCreatedAt: nil, fsModifiedAt: nil, stampDevice: nil, stampInode: nil, stampMtimeNs: nil,
            stampCtimeNs: nil, stampVolumeUUID: nil, digestComputedAt: 1_700_000_000, digestSource: .archiveFixity,
            sampledHash: nil, sampledHashAt: nil, partialMD5: nil, streamType: "Video+Audio", durationS: 1, container: "mov",
            videoCodec: "", audioCodec: "", embeddedCreatedAt: nil, embeddedCreatedSource: nil, probeExtra: [:],
            scanHost: "", scannedAt: nil, scanRootLabel: "", bundleContainer: "", sourceHost: "", originalFullPath: nil,
            originVolume: nil, machineNotes: "", lifecycle: "Cataloged", archiveStage: "None",
            masterLocation: "", setAsideReason: nil, needsReformat: false, workspaceActive: false,
            removalState: nil, removalSince: nil, removalReason: nil, removalTrashPath: nil,
            removalTrashEmptiedAt: nil, removalLastSeen: nil, removalRevision: 0,
            auditSeenVolumeUUID: nil, auditSeenMountFrom: nil, auditSeenDeviceKey: nil, auditSeenAt: nil, cataloguedAt: nil)
    }

    private static let volumeRow = CatalogRecordDTO.VolumeRowDTO(volumeUUID: volume, lastName: "A", mountType: "local", remoteServer: "")

    /// A read-only connection holding a WAL snapshot across the store's
    /// close, the way a preflight, a script's `?mode=ro` or a viewer would.
    /// `sqlite3_exec("BEGIN; SELECT …")` leaves the read transaction open —
    /// the read-mark stays taken until END — so a TRUNCATE checkpoint must
    /// wait for it.
    final class SnapshotReader: @unchecked Sendable {
        private var handle: OpaquePointer?
        init(_ url: URL) throws {
            guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
                  sqlite3_exec(handle, "BEGIN; SELECT generation FROM generations WHERE id = 1;", nil, nil, nil) == SQLITE_OK else {
                let words = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
                sqlite3_close_v2(handle)
                throw FixtureFailure(words: "the snapshot reader could not start: \(words)")
            }
        }
        func release() {
            guard let handle else { return }
            sqlite3_exec(handle, "END", nil, nil, nil)
            sqlite3_close_v2(handle)
            self.handle = nil
        }
        deinit { release() }
    }

}

extension CatalogAdoptOutcome {
    /// True only for `.adopted` (tests).
    var isAdopted: Bool {
        if case .adopted = self { return true }
        return false
    }
}
