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

// MARK: - Codex #384 round 1: committed means committed; a foreign encoding refused first

@Suite("CatalogDatabaseRestoreCommitted", .serialized)
struct CatalogDatabaseRestoreCommittedTests {

    @Test("P1: a UTF-16 backup is refused BEFORE the copy (SQLite would commit it, then fail the read-back) — live byte-identical, still writable")
    func utf16BackupRefusedUpFront() async throws {
        let scene = try await RestoreScene.make(); defer { scene.remove() }
        let repository = try await scene.open()
        let backedUp = try await RestoreScene.setNotes("as backed up", on: repository)
        let backup = try scene.seal(repository, "backup.sqlite")
        _ = try await RestoreScene.setNotes("typed after the backup", on: repository)
        let utf16 = scene.importer.directory.appendingPathComponent("backup-utf16.sqlite")
        try RestoreScene.utf16Clone(of: backup, to: utf16)
        // The clone is a valid sealed catalog at the same generation: only the encoding differs.
        let facts = try await CatalogDatabaseRestore.inspectSealedCopy(utf16)
        #expect(facts.generation == backedUp)
        let before = try scene.fingerprint()
        let outcome = await repository.restore(fromSealedCopy: utf16, expectedGeneration: backedUp)
        guard case .refused(let reason) = outcome else { Issue.record("expected refused, got \(outcome)"); return }
        #expect(reason.contains("text encoding"), Comment(rawValue: reason))
        #expect(try scene.fingerprint() == before, "the refusal came after pages were written")
        await expectStillWritable(repository, "after the encoding refusal")
        await repository.close()
        #expect(try await RestoreScene.notes(at: scene.databaseURL) == ["typed after the backup"])
    }

    @Test("P1: an error after SQLITE_DONE is restoredUnverified (never refused) and the store is closed")
    func errorAfterCommitIsRestoredUnverified() async throws {
        let scene = try await RestoreScene.make(); defer { scene.remove() }
        let repository = try await scene.open()
        let backedUp = try await RestoreScene.setNotes("as backed up", on: repository)
        let backup = try scene.seal(repository, "backup.sqlite")
        _ = try await RestoreScene.setNotes("typed after the backup", on: repository)
        struct ReadBackFailed: Error {}
        await repository.injectRestoreAfterCommitHook { throw ReadBackFailed() }
        let outcome = await repository.restore(fromSealedCopy: backup, expectedGeneration: backedUp)
        guard case .restoredUnverified(let reason) = outcome else { Issue.record("expected restoredUnverified, got \(outcome)"); return }
        #expect(reason.contains("ReadBackFailed"), Comment(rawValue: reason))
        await #expect(throws: CatalogRepositoryError.self) { _ = try await repository.read { $0.generation } }
        // It did commit: the file holds the backup.
        #expect(try await RestoreScene.notes(at: scene.databaseURL) == ["as backed up"])
        #expect(try CatalogHardKillTests.integrityCheck(scene.databaseURL) == ["ok"])
    }
}

@Suite("CatalogDatabaseRestorePinned", .serialized)
struct CatalogDatabaseRestorePinnedTests {

    private func expectChangedRefused(_ change: (URL, RestoreScene) throws -> Void) async throws {
        let scene = try await RestoreScene.make(); defer { scene.remove() }
        let repository = try await scene.open()
        let backedUp = try await RestoreScene.setNotes("as backed up", on: repository)
        let backup = try scene.seal(repository, "backup.sqlite")
        _ = try await RestoreScene.setNotes("typed after the backup", on: repository)
        let pinned = try CatalogPinnedSource.pin(backup)
        try change(backup, scene)
        // Still a valid sealed catalog at the same generation: only the pin can tell.
        #expect(try await CatalogDatabaseRestore.inspectSealedCopy(backup).generation == backedUp)
        let before = try scene.fingerprint()
        let outcome = await repository.restore(fromSealedCopy: pinned, expectedGeneration: backedUp)
        guard case .refused(let reason) = outcome else { Issue.record("expected refused, got \(outcome)"); return }
        #expect(reason.contains("changed after it was checked"), Comment(rawValue: reason))
        #expect(try scene.fingerprint() == before)
        await expectStillWritable(repository, "after the pinned refusal")
        await repository.close()
        #expect(try await RestoreScene.notes(at: scene.databaseURL) == ["typed after the backup"])
    }

    private static func tamper(_ url: URL, _ sql: String) throws {
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { try $0.execute(sql: sql) }
        try queue.close()
    }

    @Test("P1: a valid same-generation change after the pin (UPDATE notes) is refused — live untouched, still writable")
    func modifiedAfterPinRefused() async throws {
        try await expectChangedRefused { url, _ in
            try Self.tamper(url, "UPDATE user_notes SET text = 'tampered'; UPDATE generations SET saved_from_host = 'tampered' WHERE id = 1")
        }
    }

    @Test("P1: the pinned file replaced by another valid catalog at the same generation is refused — live untouched")
    func replacedAfterPinRefused() async throws {
        try await expectChangedRefused { url, scene in
            let other = scene.importer.directory.appendingPathComponent("other.sqlite")
            try FileManager.default.copyItem(at: url, to: other)
            try Self.tamper(other, "UPDATE generations SET saved_from_host = 'another catalog' WHERE id = 1")
            _ = try FileManager.default.replaceItemAt(url, withItemAt: other)
        }
    }

    @Test("P1: a same-size in-place change with the mtime put back is still refused (ctime and the re-read SHA-256)")
    func sameSizeMtimeRestoredChangeRefused() async throws {
        try await expectChangedRefused { url, _ in
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value
            try Self.tamper(url, "UPDATE generations SET saved_from_host = 'x' || substr(saved_from_host, 2) WHERE id = 1")
            #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value == size)
            if let modified = attributes[.modificationDate] as? Date {
                try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
            }
        }
    }

    @Test("P1: inside the restore, under the source's SHARED lock — an SQLite writer is locked out, and a raw same-size write is caught by the re-read SHA-256")
    func changeUnderTheLockRefused() async throws {
        let scene = try await RestoreScene.make(); defer { scene.remove() }
        let repository = try await scene.open()
        let backedUp = try await RestoreScene.setNotes("as backed up", on: repository)
        let backup = try scene.seal(repository, "backup.sqlite")
        _ = try await RestoreScene.setNotes("typed after the backup", on: repository)
        let pinned = try CatalogPinnedSource.pin(backup)
        let sqliteWriteRefused = StepCounter()
        await repository.injectRestoreSourceLockedHook {
            // 1. SQLite's lock: a writer cannot commit to the source now.
            var configuration = Configuration()
            configuration.busyMode = .immediateError
            let writer = try DatabaseQueue(path: backup.path, configuration: configuration)
            do {
                try writer.write { try $0.execute(sql: "UPDATE generations SET saved_from_host = 'tampered' WHERE id = 1") }
            } catch {
                _ = sqliteWriteRefused.next()
            }
            try writer.close()
            // 2. A raw write, no lock asked: one byte of the header's reserved area.
            let handle = try FileHandle(forUpdating: backup)
            try handle.seek(toOffset: 72)
            try handle.write(contentsOf: Data([0x01]))
            try handle.close()
        }
        let before = try scene.fingerprint()
        let outcome = await repository.restore(fromSealedCopy: pinned, expectedGeneration: backedUp)
        await repository.injectRestoreSourceLockedHook(nil)
        #expect(sqliteWriteRefused.count == 1, "the source's SHARED lock keeps SQLite writers out for the whole restore")
        guard case .refused(let reason) = outcome else { Issue.record("expected refused, got \(outcome)"); return }
        #expect(reason.contains("changed after it was checked"), Comment(rawValue: reason))
        #expect(try scene.fingerprint() == before)
        await expectStillWritable(repository, "after the under-lock refusal")
        await repository.close()
    }

    @Test("provenMoved: a rename keeps the proof; the same length with one byte changed does not")
    func provenMovedNeedsTheSameBytes() throws {
        let folder = try StoreFixture.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("a.bin")
        try Data(repeating: 7, count: 300_000).write(to: file)
        let pinned = try CatalogPinnedSource.pin(file)
        #expect(pinned.changeSincePinned() == nil)
        let moved = folder.appendingPathComponent("b.bin")
        try FileManager.default.moveItem(at: file, to: moved)
        #expect(pinned.provenMoved(to: moved) == nil)
        let handle = try FileHandle(forUpdating: moved)
        try handle.seek(toOffset: 150_000)
        try handle.write(contentsOf: Data([8]))
        try handle.close()
        let words = pinned.provenMoved(to: moved)
        #expect(words != nil, "a same-length change must not pass")
        let copied = folder.appendingPathComponent("c.bin")
        try Data(repeating: 7, count: 300_000).write(to: copied)
        #expect(pinned.provenMoved(to: copied) == "another file is at its path", "identity, not only the bytes")
    }
}

extension GRDBCatalogRepository {
    /// Test convenience: pin `url` now, then restore it.
    func restore(fromSealedCopy url: URL, expectedGeneration: Int,
                 pagesPerStep: Int32 = CatalogDatabaseRestore.defaultPagesPerStep) async -> CatalogRestoreOutcome {
        let source: CatalogPinnedSource
        do { source = try .pin(url) } catch { return .refused(reason: "\(error)") }
        return await restore(fromSealedCopy: source, expectedGeneration: expectedGeneration, pagesPerStep: pagesPerStep)
    }
}

extension RestoreScene {
    /// A UTF-16le copy of the sealed catalog at `source`: the same schema,
    /// rows and user_version, built table by table (SQLite fixes a file's
    /// encoding at creation; VACUUM INTO and the backup API both keep it).
    static func utf16Clone(of source: URL, to target: URL) throws {
        var readOnly = Configuration()
        readOnly.readonly = true
        let src = try DatabaseQueue(path: source.path, configuration: readOnly)
        defer { try? src.close() }
        var plain = Configuration()
        plain.foreignKeysEnabled = false
        let dst = try DatabaseQueue(path: target.path, configuration: plain)
        defer { try? dst.close() }
        try dst.writeWithoutTransaction { try $0.execute(sql: "PRAGMA encoding = 'UTF-16le'") }
        let schema = try src.read { db in
            try Row.fetchAll(db, sql: "SELECT type, name, sql FROM sqlite_master WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%' ORDER BY rowid")
        }
        let userVersion = try src.read { try Int.fetchOne($0, sql: "PRAGMA user_version") ?? 0 }
        // FTS5: create the virtual table (it makes its own shadow tables);
        // copy its rows through itself, never through the shadows.
        let virtual: [String] = schema.filter { ($0["sql"] as String).hasPrefix("CREATE VIRTUAL TABLE") }.map { $0["name"] }
        func isShadow(_ name: String) -> Bool { virtual.contains { name.hasPrefix($0 + "_") } }
        let created = schema.filter { ($0["type"] as String) == "table" && !isShadow($0["name"]) }
        let tables: [String] = created.map { $0["name"] }
        try dst.write { db in
            for row in created { try db.execute(sql: row["sql"]) }
            for table in tables {
                // Generated columns (table_xinfo hidden 2/3) are computed, never inserted.
                let stored: [String] = try src.read { db in
                    try Row.fetchAll(db, sql: "PRAGMA table_xinfo(\"\(table)\")").filter { ($0["hidden"] as Int) == 0 }.map { $0["name"] }
                }
                let list = (virtual.contains(table) ? ["rowid"] : []) + stored
                let select = "SELECT " + list.map { "\"\($0)\"" }.joined(separator: ", ") + " FROM \"\(table)\""
                let rows = try src.read { try Row.fetchAll($0, sql: select) }
                for row in rows {
                    let columns = Array(row.columnNames)
                    let names = columns.map { "\"\($0)\"" }.joined(separator: ", ")
                    let marks = Array(repeating: "?", count: columns.count).joined(separator: ", ")
                    try db.execute(sql: "INSERT INTO \"\(table)\" (\(names)) VALUES (\(marks))",
                                   arguments: StatementArguments(columns.map { row[$0] as DatabaseValue }))
                }
            }
            for row in schema where (row["type"] as String) != "table" { try db.execute(sql: row["sql"]) }
            try db.execute(sql: "PRAGMA user_version = \(userVersion)")
        }
        let encoding = try dst.read { try String.fetchOne($0, sql: "PRAGMA encoding") }
        guard encoding == "UTF-16le" else { throw FixtureFailure(words: "the clone is \(encoding ?? "?")") }
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
