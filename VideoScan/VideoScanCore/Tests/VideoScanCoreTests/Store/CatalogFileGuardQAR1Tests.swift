// CatalogFileGuardQAR1Tests.swift — QA round 1 on GH #359 (commit 1e30b5382).
// RED tests authored by the reviewer; the fix agent lands them red -> green.
//
// F1: adopt(toHighWater:) checks the file identity before it raises the
// witnesses (GRDBCatalogRepository.swift:800) but NOT before or inside the
// adoption transaction it then runs (runAdoption, :807/:851). Adopt suspends
// at `await pool.writeWithoutTransaction` and BEGIN IMMEDIATE can wait up to
// busyTimeoutSeconds (5 s) for another connection's write lock; a file
// replaced in that window takes the adopt row and the generation jump into
// the moved-aside file, and adopt reports `.adopted`.

import Foundation
import SQLite3
import Testing
@testable import VideoScanCore

@Suite("QA r1 #359 — file guard gaps", .serialized)
struct CatalogFileGuardQAR1Tests {

    /// Holds SQLite's write lock on `url` from a second connection, the way
    /// another process (an importer CLI, a sync tool, a second app) would.
    final class ExternalWriter: @unchecked Sendable {
        private var handle: OpaquePointer?
        init(_ url: URL) throws {
            guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
                throw FixtureFailure(words: "external open failed")
            }
            guard sqlite3_exec(handle, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
                throw FixtureFailure(words: "external BEGIN IMMEDIATE failed")
            }
        }
        func release() {
            sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
            sqlite3_close_v2(handle)
            handle = nil
        }
    }

    /// Opens a fixture below its high-water (read-only, adoptable), holds the
    /// writer lock from a second connection, starts Adopt, waits until Adopt
    /// has passed its file check (it has appended `10` to the ledger), runs
    /// `swap`, then releases the lock.
    private func adoptAcrossASwap(withLatch: Bool, _ swap: (StoreFixture) throws -> Void) async throws
        -> (adopted: CatalogAdoptOutcome, generation: Int, walChanged: Bool, later: CatalogWriteOutcome) {
        let fixture = try await StoreFixture.make(.grdb, generation: 5)
        defer { fixture.remove() }
        if withLatch {
            try Data("switched\n".utf8).write(to: fixture.directory.appendingPathComponent(SQLiteCatalogReader.latchFileName))
        }
        try fixture.writeHighWater("10")
        let repository = GRDBCatalogRepository(host: "qa-r1", durability: .volatileForTests)
        guard case .readOnly = await repository.open(at: fixture.url) else {
            await repository.close()
            throw FixtureFailure(words: "expected a read-only open below the high-water")
        }
        let wal = URL(fileURLWithPath: fixture.url.path + "-wal")
        let ledgerBefore = CatalogOpenCornerTests.sha256OrDash(fixture.highWaterLogURL)
        let external = try ExternalWriter(fixture.url)
        let adoptTask = Task { await repository.adopt(toHighWater: 10) }
        let deadline = Date().addingTimeInterval(3)
        while CatalogOpenCornerTests.sha256OrDash(fixture.highWaterLogURL) == ledgerBefore, Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        guard CatalogOpenCornerTests.sha256OrDash(fixture.highWaterLogURL) != ledgerBefore else {
            external.release(); _ = await adoptTask.value; await repository.close()
            throw FixtureFailure(words: "adopt never reached the witness raise")
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        try swap(fixture)
        let walBefore = CatalogOpenCornerTests.sha256OrDash(wal)
        external.release()
        let adopted = await adoptTask.value
        let walAfter = CatalogOpenCornerTests.sha256OrDash(wal)
        let generation = await repository.generation
        let later = await repository.write(as: .ui) { _ in }
        await repository.close()
        return (adopted, generation, walAfter != walBefore, later)
    }

    @Test("QA r1 F1 (#359): catalog.cutover removed while Adopt waits for the writer — the adoption must be refused in the latch words and not one frame may land in catalog.sqlite-wal")
    func adoptTransactionRechecksTheLatch() async throws {
        let latchName = SQLiteCatalogReader.latchFileName
        let run = try await adoptAcrossASwap(withLatch: true) { fixture in
            try FileManager.default.removeItem(at: fixture.directory.appendingPathComponent(latchName))
        }
        print("[qa-r1 #359] adopt after latch removed: \(run.adopted); later write: \(run.later)")
        #expect(run.adopted == .refused(reason: "\(latchName) was replaced or removed while VideoScan was open; nothing more will be saved — quit and reopen"),
                "adopt committed after the latch was removed: \(run.adopted)")
        #expect(run.generation == 5)
        #expect(!run.walChanged, "the adoption's frames landed in catalog.sqlite-wal after the latch was removed")
    }

    @Test("QA r1 F1b (#359): catalog.sqlite replaced while Adopt waits for the writer — refused in OUR words (today only Apple SQLite's asynchronous SQLITE_IOERR_VNODE stops it, when it arrives in time)")
    func adoptTransactionRechecksTheDatabase() async throws {
        let run = try await adoptAcrossASwap(withLatch: false) { fixture in
            let replacement = fixture.directory.appendingPathComponent("replacement.sqlite")
            try FileManager.default.copyItem(at: fixture.url, to: replacement)   // identical bytes, new inode
            try FileManager.default.moveItem(at: fixture.url, to: fixture.directory.appendingPathComponent("moved-aside.sqlite"))
            try FileManager.default.moveItem(at: replacement, to: fixture.url)
        }
        print("[qa-r1 #359] adopt after db swap: \(run.adopted); later write: \(run.later)")
        #expect(run.adopted == .refused(reason: CatalogOpenCornerTests.replacedWords), "\(run.adopted)")
        #expect(run.generation == 5)
        #expect(!run.walChanged, "the adoption's frames landed in the moved-aside file's -wal")
    }

    // F2: sealedCopyBlocking (GRDBCatalogRepository.swift:559) runs VACUUM INTO
    // with no file check. After catalog.sqlite was replaced, the backup seal
    // and the viewer snapshot publisher seal the MOVED-ASIDE file and label it
    // "catalog.sqlite generation N"; with nothing pending, the commit-first
    // door never writes, so the stop is never raised first.
    @Test("QA r1 F2 (#359): a sealed copy after catalog.sqlite was replaced is refused in the ruled words — never a copy of the moved-aside file")
    func sealedCopyRefusedAfterReplace() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 2)
        defer { fixture.remove() }
        let repository = GRDBCatalogRepository(host: "qa-r1", durability: .volatileForTests)
        try #require(await repository.open(at: fixture.url) == .readWrite)
        let replacement = fixture.directory.appendingPathComponent("replacement.sqlite")
        #expect(repository.sealedCopyBlocking(to: replacement) == nil)
        try FileManager.default.moveItem(at: fixture.url, to: fixture.directory.appendingPathComponent("moved-aside.sqlite"))
        try FileManager.default.moveItem(at: replacement, to: fixture.url)
        let target = fixture.directory.appendingPathComponent("backup.sqlite")
        let sealed = repository.sealedCopyBlocking(to: target)
        await repository.close()
        print("[qa-r1 #359] sealed copy after replace: \(sealed ?? "written")")
        #expect(sealed == CatalogOpenCornerTests.replacedWords, "\(sealed ?? "a copy of the moved-aside file was sealed")")
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    // H1 (sensor, GREEN today): every #359 test swaps the file BEFORE the
    // write, so only check 1 is exercised; checks 2 and 3 can be deleted with
    // the suite still green. These pin them.
    @Test("QA r1 H1 sensor (#359 check 2): the latch removed DURING the transaction body — refused in the latch words before phase 1; no witness moves, no frame lands")
    func latchRemovedDuringBodyStopsBeforePhaseOne() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 2)
        defer { fixture.remove() }
        let latch = fixture.directory.appendingPathComponent(SQLiteCatalogReader.latchFileName)
        try Data("switched\n".utf8).write(to: latch)
        let repository = GRDBCatalogRepository(host: "qa-r1", durability: .volatileForTests)
        try #require(await repository.open(at: fixture.url) == .readWrite)
        let wal = URL(fileURLWithPath: fixture.url.path + "-wal")
        let witnessesBefore = Array(try CatalogOpenCornerTests.fingerprint(fixture).dropFirst())
        let walBefore = CatalogOpenCornerTests.sha256OrDash(wal)
        let outcome = await repository.write(as: .ui) { _ in try FileManager.default.removeItem(at: latch) }
        let witnessesAfter = Array(try CatalogOpenCornerTests.fingerprint(fixture).dropFirst())
        let walAfter = CatalogOpenCornerTests.sha256OrDash(wal)
        let generation = await repository.generation
        await repository.close()
        #expect(outcome == .refused(reason: "\(SQLiteCatalogReader.latchFileName) was replaced or removed while VideoScan was open; nothing more will be saved — quit and reopen"),
                "\(outcome)")
        #expect(generation == 2)
        #expect(witnessesAfter == witnessesBefore, "phase 1 raised a witness after the latch was removed")
        #expect(walAfter == walBefore, "a frame landed after the latch was removed")
    }

    @Test("QA r1 H1 sensor (#359 check 3): the latch removed between phase 1 and COMMIT — refused in the latch words; the commit rolls back and no frame lands")
    func latchRemovedAfterPhaseOneStopsBeforeCommit() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 2)
        defer { fixture.remove() }
        let latch = fixture.directory.appendingPathComponent(SQLiteCatalogReader.latchFileName)
        try Data("switched\n".utf8).write(to: latch)
        let repository = GRDBCatalogRepository(host: "qa-r1", durability: .volatileForTests)
        try #require(await repository.open(at: fixture.url) == .readWrite)
        let wal = URL(fileURLWithPath: fixture.url.path + "-wal")
        let walBefore = CatalogOpenCornerTests.sha256OrDash(wal)
        await repository.injectCrashBeforeCommit { try FileManager.default.removeItem(at: latch) }
        let outcome = await repository.write(as: .ui) { _ in }
        let walAfter = CatalogOpenCornerTests.sha256OrDash(wal)
        let generation = await repository.generation
        await repository.injectCrashBeforeCommit(nil)
        await repository.close()
        #expect(outcome == .refused(reason: "\(SQLiteCatalogReader.latchFileName) was replaced or removed while VideoScan was open; nothing more will be saved — quit and reopen"),
                "\(outcome)")
        #expect(generation == 2)
        #expect(walAfter == walBefore, "the commit landed after the latch was removed")
    }

    // F3: close() keeps the TRUNCATE checkpoint after a swap so "the
    // replacement never inherits" this session's -wal (:868-874). But once
    // Apple SQLite has noticed the rename, the checkpoint itself fails with
    // SQLITE_IOERR_VNODE ("disk I/O error"), the -wal at the path keeps the
    // moved-aside file's committed frames, and the replacement's next open
    // replays them INTO the replacement.
    @Test("QA r1 F3 (#359): catalog.sqlite replaced after a commit, then close — the replacement must not inherit the moved-aside file's -wal (its generation stays what it was)")
    func replacementDoesNotInheritTheSessionsWAL() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 2)
        defer { fixture.remove() }
        let replacement = fixture.directory.appendingPathComponent("replacement.sqlite")
        try FileManager.default.copyItem(at: fixture.url, to: replacement)   // generation 2, WAL-format header
        let repository = GRDBCatalogRepository(host: "qa-r1", durability: .volatileForTests)
        try #require(await repository.open(at: fixture.url) == .readWrite)
        try #require(await repository.write(as: .ui) { _ in } == .committed(generation: 3))
        let wal = URL(fileURLWithPath: fixture.url.path + "-wal")
        let walBytesAtSwap = (try? FileManager.default.attributesOfItem(atPath: wal.path)[.size] as? Int) ?? 0
        try FileManager.default.moveItem(at: fixture.url, to: fixture.directory.appendingPathComponent("moved-aside.sqlite"))
        try FileManager.default.moveItem(at: replacement, to: fixture.url)
        try await Task.sleep(nanoseconds: 500_000_000)   // let the engine's rename notice arrive (a person quits later than this)
        await repository.close()
        let walBytesAfterClose = (try? FileManager.default.attributesOfItem(atPath: wal.path)[.size] as? Int) ?? 0

        let reopened = GRDBCatalogRepository(host: "qa-r1", durability: .volatileForTests)
        let outcome = await reopened.open(at: fixture.url)
        let generation = await reopened.generation
        await reopened.close()
        print("[qa-r1 #359] -wal \(walBytesAtSwap) bytes at swap, \(walBytesAfterClose) after close; replacement reopened: \(outcome), generation \(generation)")
        #expect(walBytesAtSwap > 0, "precondition: the commit's frames were in the -wal")
        #expect(walBytesAfterClose == 0, "close left the moved-aside file's frames in catalog.sqlite-wal beside the replacement")
        #expect(generation == 2, "the replacement inherited the moved-aside file's -wal: generation \(generation)")
    }

    @Test("QA r1 F3b (#359): the replacement is a DIFFERENT catalog (another lineage) — after close and reopen it must still be that catalog, intact")
    func differentReplacementIsNotOverwrittenByTheSessionsWAL() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 2)
        defer { fixture.remove() }
        let other = try await StoreFixture.make(.grdb, generation: 7)
        defer { other.remove() }
        let repository = GRDBCatalogRepository(host: "qa-r1", durability: .volatileForTests)
        try #require(await repository.open(at: fixture.url) == .readWrite)
        for _ in 0..<3 { _ = await repository.write(as: .ui) { _ in } }       // generation 5, frames in the -wal
        try FileManager.default.moveItem(at: fixture.url, to: fixture.directory.appendingPathComponent("moved-aside.sqlite"))
        try FileManager.default.copyItem(at: other.url, to: fixture.url)        // someone else's catalog, generation 7
        try await Task.sleep(nanoseconds: 500_000_000)
        await repository.close()
        try FileManager.default.removeItem(at: fixture.highWaterURL)            // witnesses are not the point here
        try? FileManager.default.removeItem(at: fixture.highWaterLogURL)
        let reopened = GRDBCatalogRepository(host: "qa-r1", durability: .volatileForTests)
        let outcome = await reopened.open(at: fixture.url)
        let generation = await reopened.generation
        await reopened.close()
        print("[qa-r1 #359] different replacement reopened: \(outcome), generation \(generation)")
        #expect(generation == 7, "the replacement is no longer the catalog that was put there: \(outcome), generation \(generation)")
    }
}

extension CatalogOpenCornerTests {
    /// SHA-256 of one file, "-" when missing (non-throwing for polling).
    static func sha256OrDash(_ url: URL) -> String {
        (try? sha256(url)) ?? "?"
    }
}
