// CatalogDatabaseRestoreTests.swift
// GH #343 — the store half of Restore from Backup…: a sealed copy written
// INTO the open catalog.sqlite with SQLite's backup API, this Mac's
// high-water witnesses left alone (CatalogDatabaseRestore.swift).
//
// Dimensions (CLAUDE.md rule 8):
//   LOGIC      back up at generation a, commit past it, restore → the store
//              closes; the reopen is read-only "restoredBelowHighWater" at a,
//              every record reads the backup's values, integrity ok; Adopt
//              raises it to the high-water and the next write commits.
//   ISOLATION  every refusal leaves the live catalog byte-identical (db +
//              -wal) and the store open and writable: a source that is not
//              sealed (a -wal beside it, garbage bytes), the wrong generation,
//              a backup AT the high-water (it would open writable unasked),
//              another page size, a read-only session, a poisoned high-water
//              witness; a failure in the middle of the copy (the step seam)
//              rolls back — the live values, the store still writable.
//   WAL TRAP   the file at the path is never replaced: same inode before and
//              after, the folder lists the same names, the -wal is folded in
//              (empty) after the close, the header still says WAL — an old
//              database can never meet a newer -wal.
//   TRUTH      the poisoned fixture rows (quarantine) come back exactly: the
//              restored table counts equal the backup's own.
//   SCALE      a 100k-row backup restored inside a budget (load-aware).
//   MEDIA      N/A — no media is opened.
// The real-crash proof (SIGKILL mid-restore) is CatalogRestoreHardKillTests.
//
// Suites (filter by SUITE): CatalogDatabaseRestore · CatalogDatabaseRestoreScale

import CryptoKit
import Foundation
import GRDB
import Testing
@testable import VideoScanCore

// MARK: - Scene

/// An imported poisoned-fixture catalog, plus the helpers the restore cases share.
struct RestoreScene {
    let importer: ImporterScene
    var databaseURL: URL { importer.databaseURL }
    var folder: URL { importer.databaseFolder }

    static func make(healthyRows: Int = 20) async throws -> RestoreScene {
        let importer = try ImporterScene.make(healthyRows: healthyRows)
        let imported = await importer.run()
        _ = try #require(imported.outcome.reconciliation, Comment(rawValue: "\(imported.outcome)"))
        return RestoreScene(importer: importer)
    }

    func remove() { importer.remove() }

    func open() async throws -> GRDBCatalogRepository {
        let repository = GRDBCatalogRepository(host: "restore-test", durability: .volatileForTests)
        try #require(await repository.open(at: databaseURL) == .readWrite)
        return repository
    }

    /// Every record's notes set to `note`, in ONE commit through the app's
    /// commit path (CatalogCommit). Returns the generation it committed.
    @discardableResult
    static func setNotes(_ note: String, on repository: GRDBCatalogRepository) async throws -> Int {
        let snapshot = try await CatalogLoad.read(repository)
        let records = try snapshot.rows.map { try VideoRecord(loaded: $0) }
        let items = records.map { record -> CatalogCommit.Item in
            record.userNotes = note
            let dto = VideoRecordDTO(record)
            return CatalogCommit.Item(id: record.id, snapshot: dto, fingerprint: CatalogChangeDetector.fingerprint(dto))
        }
        let outcome = await CatalogCommit.run(CatalogCommit.Plan(door: .save, items: items), on: repository)
        guard case .committed(let generation, _) = outcome else { throw FixtureFailure(words: "notes commit: \(outcome)") }
        return generation
    }

    /// The distinct notes of every record in the file at `url`, read
    /// through a reading-only open (no reconcile, nothing written).
    static func notes(at url: URL) async throws -> Set<String> {
        let reader = GRDBCatalogRepository(host: "restore-reader", durability: .volatileForTests)
        let opened = await reader.openForReading(at: url)
        guard case .readOnly = opened else { throw FixtureFailure(words: "reader: \(opened)") }
        do {
            let snapshot = try await CatalogLoad.read(reader)
            await reader.close()
            return Set(try snapshot.rows.map { try VideoRecord(loaded: $0).userNotes })
        } catch {
            await reader.close()
            throw error
        }
    }

    /// A sealed copy (VACUUM INTO) of the open store, beside the scene.
    func seal(_ repository: GRDBCatalogRepository, _ name: String) throws -> URL {
        let target = importer.directory.appendingPathComponent(name)
        if let why = repository.sealedCopyBlocking(to: target) { throw FixtureFailure(words: why) }
        return target
    }

    /// SHA-256 of catalog.sqlite and (when present) its -wal.
    func fingerprint() throws -> String {
        func hash(_ url: URL) throws -> String {
            SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        }
        let wal = URL(fileURLWithPath: databaseURL.path + "-wal")
        let walHash = FileManager.default.fileExists(atPath: wal.path) ? try hash(wal) : "no-wal"
        return try hash(databaseURL) + "/" + walHash
    }

    func inode() throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: databaseURL.path)
        return (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }

    func names() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
    }
}

/// The store is open and writable: one more write commits.
private func expectStillWritable(_ repository: GRDBCatalogRepository, _ comment: String) async {
    let before = await repository.generation
    let outcome = await repository.write(as: .ui) { _ in }
    #expect(outcome == .committed(generation: before + 1), Comment(rawValue: "\(comment): \(outcome)"))
}

// MARK: - Logic, WAL trap, truth

@Suite("CatalogDatabaseRestore", .serialized)
struct CatalogDatabaseRestoreTests {

    @Test("restore: the store closes, the reopen is read-only below high-water with the backup's values, Adopt makes it writable")
    func restoreThenRelaunchThenAdopt() async throws {
        let scene = try await RestoreScene.make(); defer { scene.remove() }
        let repository = try await scene.open()
        let backedUp = try await RestoreScene.setNotes("as backed up", on: repository)
        let backup = try scene.seal(repository, "backup.sqlite")
        let facts = try await CatalogDatabaseRestore.inspectSealedCopy(backup)
        #expect(facts.generation == backedUp)
        #expect(facts.savedFromHost == "restore-test")
        #expect(facts.savedAt > 0 && facts.pageSize > 0)
        let later = try await RestoreScene.setNotes("typed after the backup", on: repository)
        #expect(later == backedUp + 1)
        let inodeBefore = try scene.inode()
        let namesBefore = try scene.names()

        let outcome = await repository.restore(fromSealedCopy: backup, expectedGeneration: backedUp)
        guard case .restored(let generation, let replaced, let pages) = outcome else {
            Issue.record("expected restored, got \(outcome)"); return
        }
        #expect(generation == backedUp && replaced == later && pages > 0)
        // The store closed itself: its session described the file as it was.
        await #expect(throws: CatalogRepositoryError.self) { _ = try await repository.read { $0.generation } }

        // WAL trap: the same file, the same folder, the -wal folded in.
        #expect(try scene.inode() == inodeBefore, "catalog.sqlite was replaced, not restored into")
        #expect(try scene.names().subtracting(["catalog.sqlite-wal", "catalog.sqlite-shm"])
                == namesBefore.subtracting(["catalog.sqlite-wal", "catalog.sqlite-shm"]))
        let wal = URL(fileURLWithPath: scene.databaseURL.path + "-wal")
        let walBytes = (try? FileManager.default.attributesOfItem(atPath: wal.path)[.size] as? NSNumber)?.intValue ?? 0
        #expect(walBytes == 0, "the close checkpointed the restored pages into catalog.sqlite (TRUNCATE)")
        let header = try FileHandle(forReadingFrom: scene.databaseURL).read(upToCount: 20) ?? Data()
        #expect(header.count == 20 && header[18] == 2 && header[19] == 2, "still a WAL database")
        // The witnesses were not touched.
        #expect(CatalogHighWater.read(besideDatabaseAt: scene.databaseURL) == .value(later))
        #expect(CatalogHighWaterLedger.read(besideDatabaseAt: scene.databaseURL) == .value(later))
        #expect(try CatalogHardKillTests.integrityCheck(scene.databaseURL) == ["ok"])
        #expect(try await RestoreScene.notes(at: scene.databaseURL) == ["as backed up"])

        // Relaunch: read-only below the high-water, then Adopt.
        let relaunched = GRDBCatalogRepository(host: "restore-test", durability: .volatileForTests)
        let opened = await relaunched.open(at: scene.databaseURL)
        guard case .readOnly(let reason) = opened else { Issue.record("expected read-only, got \(opened)"); return }
        #expect(reason.hasPrefix("restoredBelowHighWater"))
        #expect(await relaunched.generation == backedUp)
        #expect(await relaunched.adopt(toHighWater: later) == .adopted(from: backedUp, to: later))
        await expectStillWritable(relaunched, "after adopt")
        await relaunched.close()
    }

    @Test("TRUTH: the poisoned fixture's quarantine and every table count come back exactly as the backup holds them")
    func countsComeBackExactly() async throws {
        let scene = try await RestoreScene.make(); defer { scene.remove() }
        let repository = try await scene.open()
        let backup = try scene.seal(repository, "backup.sqlite")
        let sealed = try await CatalogDatabaseRestore.inspectSealedCopy(backup)
        #expect(sealed.counts.quarantine > 0, "the fixture has quarantine rows: \(sealed.counts)")
        // One commit past the backup, so it is below the high-water.
        _ = await repository.write(as: .ui) { _ in }
        let outcome = await repository.restore(fromSealedCopy: backup, expectedGeneration: sealed.generation)
        guard case .restored = outcome else { Issue.record("\(outcome)"); return }
        let restored = try await CatalogDatabaseRestore.inspectSealedCopyAfterClose(scene.databaseURL)
        #expect(restored == sealed.counts)
    }

    // MARK: Refusals: nothing changed, the store still writable

    private func expectRefused(_ scene: RestoreScene, _ repository: GRDBCatalogRepository, source: URL, generation: Int,
                               saying words: String) async throws {
        let before = try scene.fingerprint()
        let outcome = await repository.restore(fromSealedCopy: source, expectedGeneration: generation)
        guard case .refused(let reason) = outcome else { Issue.record("expected refused, got \(outcome)"); return }
        #expect(reason.contains(words), Comment(rawValue: reason))
        #expect(try scene.fingerprint() == before, "a refusal changed catalog.sqlite or its -wal")
        await expectStillWritable(repository, "after the refusal '\(words)'")
    }

    @Test("ISOLATION: a source that is not a sealed copy is refused (a -wal beside it; garbage bytes) — nothing changed")
    func unsealedSourceRefused() async throws {
        let scene = try await RestoreScene.make(); defer { scene.remove() }
        let repository = try await scene.open()
        let backedUp = try await RestoreScene.setNotes("as backed up", on: repository)
        let backup = try scene.seal(repository, "backup.sqlite")
        _ = try await RestoreScene.setNotes("later", on: repository)
        try Data().write(to: URL(fileURLWithPath: backup.path + "-wal"))
        try await expectRefused(scene, repository, source: backup, generation: backedUp, saying: "-wal is beside it")
        let garbage = scene.importer.directory.appendingPathComponent("garbage.sqlite")
        try Data(repeating: 0x5a, count: 8192).write(to: garbage)
        try await expectRefused(scene, repository, source: garbage, generation: backedUp, saying: "not an SQLite database")
        await repository.close()
    }

    @Test("ISOLATION: the wrong generation, and a backup AT the high-water (it would open writable unasked), are refused")
    func generationRefusals() async throws {
        let scene = try await RestoreScene.make(); defer { scene.remove() }
        let repository = try await scene.open()
        let atHighWater = try await RestoreScene.setNotes("current", on: repository)
        let backup = try scene.seal(repository, "backup.sqlite")
        try await expectRefused(scene, repository, source: backup, generation: atHighWater, saying: "not below this Mac's high-water")
        // expectRefused's own write moved the store past the backup: now it is
        // restorable, but only at the generation it really holds.
        try await expectRefused(scene, repository, source: backup, generation: atHighWater - 1, saying: "not the \(atHighWater - 1)")
        await repository.close()
    }

    @Test("ISOLATION: a backup with another page size is refused in words before any page is written")
    func pageSizeRefused() async throws {
        let scene = try await RestoreScene.make(); defer { scene.remove() }
        let repository = try await scene.open()
        let backedUp = try await RestoreScene.setNotes("as backed up", on: repository)
        let backup = try scene.seal(repository, "backup.sqlite")
        _ = try await RestoreScene.setNotes("later", on: repository)
        let queue = try DatabaseQueue(path: backup.path)
        try await queue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA page_size = 8192")
            try db.execute(sql: "VACUUM")
        }
        try queue.close()
        try await expectRefused(scene, repository, source: backup, generation: backedUp, saying: "page size is 8192")
        await repository.close()
    }

    @Test("ISOLATION: poisoned state — an unreadable high-water witness refuses the restore; a read-only session refuses it")
    func poisonedAndReadOnlyRefused() async throws {
        let scene = try await RestoreScene.make(); defer { scene.remove() }
        let repository = try await scene.open()
        let backedUp = try await RestoreScene.setNotes("as backed up", on: repository)
        let backup = try scene.seal(repository, "backup.sqlite")
        let later = try await RestoreScene.setNotes("later", on: repository)
        let sidecar = CatalogHighWater.url(besideDatabaseAt: scene.databaseURL)
        let good = try Data(contentsOf: sidecar)
        try Data("not a number\n".utf8).write(to: sidecar)
        let before = try scene.fingerprint()
        let poisoned = await repository.restore(fromSealedCopy: backup, expectedGeneration: backedUp)
        guard case .refused = poisoned else { Issue.record("expected refused, got \(poisoned)"); return }
        #expect(try scene.fingerprint() == before)
        try good.write(to: sidecar)
        await repository.close()

        // A session that opened read-only (here: below the high-water) cannot restore.
        try Data("\(later + 5)\n".utf8).write(to: sidecar)
        let readOnly = GRDBCatalogRepository(host: "restore-test", durability: .volatileForTests)
        guard case .readOnly = await readOnly.open(at: scene.databaseURL) else { Issue.record("expected a read-only open"); return }
        let refused = await readOnly.restore(fromSealedCopy: backup, expectedGeneration: backedUp)
        guard case .refused(let reason) = refused else { Issue.record("expected refused, got \(refused)"); return }
        #expect(reason.contains("read-only in this session"))
        await readOnly.close()
    }

    @Test("FAILURE MID-COPY: a throw after the first step rolls the restore back — the live values, the store still writable")
    func failureMidCopyRollsBack() async throws {
        let scene = try await RestoreScene.make(healthyRows: 200); defer { scene.remove() }
        let repository = try await scene.open()
        let backedUp = try await RestoreScene.setNotes("as backed up", on: repository)
        let backup = try scene.seal(repository, "backup.sqlite")
        let later = try await RestoreScene.setNotes("typed after the backup", on: repository)
        struct Died: Error {}
        let steps = StepCounter()
        await repository.injectRestoreStepHook { if steps.next() == 2 { throw Died() } }
        let outcome = await repository.restore(fromSealedCopy: backup, expectedGeneration: backedUp, pagesPerStep: 4)
        guard case .refused(let reason) = outcome else { Issue.record("expected refused, got \(outcome)"); return }
        #expect(reason.contains("rolled back"), Comment(rawValue: reason))
        #expect(steps.count >= 2, "the seam ran inside the copy")
        await repository.injectRestoreStepHook(nil)
        #expect(await repository.generation == later)
        let read = try await repository.read { $0.generation }
        #expect(read == later, "the database still reads the live generation")
        await expectStillWritable(repository, "after a rolled-back restore")
        await repository.close()
        #expect(try CatalogHardKillTests.integrityCheck(scene.databaseURL) == ["ok"])
        #expect(try await RestoreScene.notes(at: scene.databaseURL) == ["typed after the backup"])
    }

    @Test("FILE STOP: catalog.sqlite moved away under the session — the restore is refused, nothing written to either file")
    func fileStopRefuses() async throws {
        let scene = try await RestoreScene.make(); defer { scene.remove() }
        let repository = try await scene.open()
        let backedUp = try await RestoreScene.setNotes("as backed up", on: repository)
        let backup = try scene.seal(repository, "backup.sqlite")
        _ = try await RestoreScene.setNotes("later", on: repository)
        let aside = scene.folder.appendingPathComponent("moved-aside.sqlite")
        try FileManager.default.moveItem(at: scene.databaseURL, to: aside)
        try FileManager.default.copyItem(at: aside, to: scene.databaseURL)
        let outcome = await repository.restore(fromSealedCopy: backup, expectedGeneration: backedUp)
        guard case .refused = outcome else { Issue.record("expected refused, got \(outcome)"); return }
        await repository.close()
    }
}

/// A thread-safe step count for the seam (it runs on GRDB's writer queue).
final class StepCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func next() -> Int { lock.withLock { value += 1; return value } }
}

extension CatalogDatabaseRestore {
    /// Test helper: the table counts of a CLOSED catalog.sqlite, read with a
    /// plain read-only connection.
    static func inspectSealedCopyAfterClose(_ url: URL) async throws -> CatalogRow.TableCounts {
        let reader = GRDBCatalogRepository(host: "restore-reader", durability: .volatileForTests)
        guard case .readOnly = await reader.openForReading(at: url) else { throw FixtureFailure(words: "reader") }
        do {
            let counts = try await reader.read { try $0.recordCounts() }
            await reader.close()
            return counts
        } catch {
            await reader.close()
            throw error
        }
    }
}

// MARK: - Scale

@Suite("CatalogDatabaseRestoreScale", .serialized)
struct CatalogDatabaseRestoreScaleTests {

    /// Budget for restoring a 100k-row backup (the source's open checks are
    /// the app's step; this is the store's: the copy, the read-back and the
    /// close's checkpoint). Measured 2026-11-25, M5 Ultra, Debug, load 30 on
    /// 30 cores: 19,579 pages in 0.146 s. Budget ≈ 20× that, load-aware
    /// (TimingBudget) — volatile durability, so it measures the copy, not fsync.
    static let hundredThousandBudget: Duration = .seconds(3)

    @Test(.tags(.quietMachine)) func hundredThousandRowBackupRestoresWithinBudget() async throws {
        let fixture = StoreFixture(kind: .grdb, directory: try StoreFixture.temporaryDirectory())
        defer { fixture.remove() }
        let repository = GRDBCatalogRepository(host: "scale-host", durability: .volatileForTests)
        try #require(await repository.open(at: fixture.url) == .readWrite)
        let rows = 100_000
        let filled = await repository.write(as: .importRun) { transaction in
            guard let grdb = transaction as? GRDBTransaction else { throw FixtureFailure(words: "not a GRDB transaction") }
            let db = grdb.db
            try db.execute(sql: SchemaSeed.volumeInsert)
            let content = try db.cachedStatement(sql: "INSERT INTO content (digest, byte_count, first_seen_at, first_seen_how) VALUES (?, ?, 1700000000, 'import')")
            let live = try db.cachedStatement(sql: """
                INSERT INTO files (id, content_digest, volume_uuid, volume_case_sensitive, full_path, path_fold, filename, ext, directory,
                                   size_bytes, digest_computed_at, digest_source, stream_type, lifecycle, archive_stage)
                VALUES (?, ?, ?, 0, ?, ?, 'c.mov', 'mov', '/Volumes/A', 100, 1700000000, 'rescan', 'Video+Audio', 'Cataloged', 'None')
                """)
            for index in 0..<rows {
                let hex = String(index, radix: 16)
                let digest = String(repeating: "0", count: 64 - hex.count) + hex
                let idHex = String(index, radix: 16, uppercase: true)
                let id = "00000000-0000-0000-0000-" + String(repeating: "0", count: 12 - idHex.count) + idHex
                let path = "/Volumes/A/d\(index / 100)/Clip\(index).mov"
                try content.execute(arguments: [digest, 100])
                try live.execute(arguments: [id, digest, SchemaSeed.volume, path, path.lowercased()])
            }
        }
        #expect(filled == .committed(generation: 1))
        let backup = fixture.directory.appendingPathComponent("backup.sqlite")
        #expect(repository.sealedCopyBlocking(to: backup) == nil)
        #expect(await repository.write(as: .ui) { _ in } == .committed(generation: 2))

        let loadBefore = TimingBudget.sampleLoad()
        let clock = ContinuousClock()
        let start = clock.now
        let outcome = await repository.restore(fromSealedCopy: backup, expectedGeneration: 1)
        let elapsed = clock.now - start
        guard case .restored(let generation, _, let pages) = outcome else { Issue.record("\(outcome)"); return }
        print("[restore-scale] 100k-row backup (\(pages) pages) restored in \(elapsed) (\(TimingBudget.loadDescription()))")
        expectWithinTimingBudget("restore of a 100k-row backup", measured: elapsed,
                                 budget: Self.hundredThousandBudget, loadBefore: loadBefore)
        #expect(generation == 1)
        let counts = try await CatalogDatabaseRestore.inspectSealedCopyAfterClose(fixture.url)
        #expect(counts.files == rows && counts.content == rows)
    }
}
