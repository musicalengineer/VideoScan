// CatalogOpenCornerTests.swift
// Corner-case matrix (Rick, 2026-10-21), the OPEN half: how OUR repository
// reacts when catalog.sqlite is not a file it may write. Each failure is
// injected at our seam (the file on disk, a lock held by another connection,
// a catalog_state row) and the assertions are only about our reaction: the
// outcome, its words, and that NOTHING was written (the file's SHA-256 and
// the high-water witnesses unchanged). No SQLite internals are asserted.
//
//   Case 9   read-only file (0444), a Finder-"Locked" file (uchg), a write
//            lock held by another connection — refused or read-only, with
//            words; no write attempted; a held lock is answered within the
//            busy timeout, not waited on forever.
//   Case 10  corrupt catalog.sqlite (page headers overwritten in a copy) —
//            open refuses with words; the app never writes over it; the
//            repository stays closed (every write refused).
//   Case 11  schema version newer than this build — refused with words that
//            say so; not one byte written; the read-only door refuses too.
//   Fail-fast  (#359) the database file REPLACED or MOVED underneath an
//            open session, or the latch beside it removed or replaced —
//            the store compares device + inode before every commit and
//            refuses before writing, in words, for the rest of the session.
//
// Five dimensions: LOGIC (above) · SCALE N/A (each case is one open) · MEDIA
// N/A · ISOLATION (temp folders only; flags and modes restored before the
// folder is removed) · SENSOR (the SHA-before == SHA-after pins).
//
// For Rick: `sqlite3_*` below is the C API, used ONLY to stand in for another
// process holding the write lock — the same calls you would make from C.

import CryptoKit
import Foundation
import GRDB
import SQLite3
import Testing
@testable import VideoScanCore

@Suite("Catalog open corners — read-only, locked, corrupt, newer schema, replaced underneath", .serialized)
struct CatalogOpenCornerTests {

    // MARK: - Case 9

    enum Lock: String, CaseIterable, Sendable, CustomStringConvertible {
        /// chmod 0444 on catalog.sqlite (the folder stays writable).
        case readOnlyMode
        /// Finder ▸ Get Info ▸ Locked (the uchg flag).
        case finderLocked
        var description: String { rawValue }
    }

    @Test("case 9: a read-only or Finder-locked catalog.sqlite is not opened read-write; the words say so; nothing is written",
          arguments: Lock.allCases)
    func readOnlyFileIsNotWritten(_ lock: Lock) async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 3)
        defer {
            try? FileManager.default.setAttributes([.immutable: false, .posixPermissions: 0o644], ofItemAtPath: fixture.url.path)
            fixture.remove()
        }
        let before = try Self.fingerprint(fixture)
        switch lock {
        case .readOnlyMode: try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: fixture.url.path)
        case .finderLocked: try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: fixture.url.path)
        }
        let repository = GRDBCatalogRepository(host: "corner-test", durability: .volatileForTests)
        let opened = await repository.open(at: fixture.url)
        print("[corner-open] \(lock): \(opened)")
        switch opened {
        case .readWrite:
            Issue.record("\(lock): a read-only catalog.sqlite opened read-write")
        case .readOnly(let words), .refused(let words):
            #expect(!words.isEmpty)
            #expect(words.lowercased().contains("read") || words.lowercased().contains("writ"),
                    "\(lock): the words do not say it cannot be written: \(words)")
            // The folder IS writable here; the words must name the file.
            withKnownIssue("pending (draft issue): a read-only / locked catalog.sqlite is reported as 'the folder … is not writable'") {
                #expect(!words.contains("the folder"), "\(lock): blames the folder: \(words)")
                #expect(words.contains("catalog.sqlite"), "\(lock): does not name the file: \(words)")
            }
        }
        let wrote = await repository.write(as: .ui) { _ in }
        #expect(!wrote.isCommitted, "\(lock): a write landed: \(wrote)")
        await repository.close()
        try FileManager.default.setAttributes([.immutable: false, .posixPermissions: 0o644], ofItemAtPath: fixture.url.path)
        #expect(try Self.fingerprint(fixture) == before, "\(lock): catalog.sqlite or a witness changed")
    }

    @Test("case 9: another connection holds the write lock — open is refused or read-only within the busy timeout, with words; nothing written; it opens once the lock is gone",
          .timeLimit(.minutes(1)))
    func writeLockHeldElsewhere() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 2)
        defer { fixture.remove() }
        let before = try Self.fingerprint(fixture)
        let other = try OtherWriter(fixture.url)
        let repository = GRDBCatalogRepository(host: "corner-test", durability: .volatileForTests)
        let clock = ContinuousClock()
        let start = clock.now
        let opened = await repository.open(at: fixture.url)
        let waited = clock.now - start
        print("[corner-open] write lock held elsewhere: \(opened) after \(waited)")
        #expect(waited < .seconds(GRDBCatalogRepository.busyTimeoutSeconds * 3), "fail fast: waited \(waited)")
        var wrote: CatalogWriteOutcome = .refused(reason: "not tried")
        switch opened {
        case .readWrite:
            // Allowed only if the first write is then refused in words.
            wrote = await repository.write(as: .ui) { _ in }
            #expect(!wrote.isCommitted, "a write landed while another connection held the lock")
        case .readOnly(let words), .refused(let words):
            #expect(words.lowercased().contains("lock") || words.lowercased().contains("busy"), Comment(rawValue: words))
        }
        await repository.close()
        other.release()
        #expect(try Self.fingerprint(fixture) == before, "nothing was written while the lock was held")

        let again = GRDBCatalogRepository(host: "corner-test", durability: .volatileForTests)
        #expect(await again.open(at: fixture.url) == .readWrite, "the lock is gone; the catalog opens normally")
        await again.close()
    }

    // MARK: - Case 10

    @Test("case 10: a corrupt catalog.sqlite — open refuses with words, the repository stays shut, the file and witnesses are byte-identical after")
    func corruptCatalogIsRefusedAndNeverWritten() async throws {
        let scene = try ImporterScene.make(healthyRows: 60)
        defer { scene.remove() }
        _ = try #require(await scene.run().outcome.reconciliation)
        let database = scene.databaseURL
        try Self.removeSidecars(database)
        try Self.corruptPageHeaders(database)
        let fixture = StoreFixture(kind: .grdb, directory: scene.databaseFolder)
        let before = try Self.fingerprint(fixture)

        let repository = GRDBCatalogRepository(host: "corner-test", durability: .volatileForTests)
        let opened = await repository.open(at: database)
        guard case .refused(let words) = opened else {
            Issue.record("a corrupt catalog.sqlite was not refused: \(opened)")
            await repository.close()
            return
        }
        print("[corner-open] corrupt: \(words)")
        #expect(!words.isEmpty)
        let wrote = await repository.write(as: .ui) { _ in }
        #expect(wrote == .refused(reason: "not open"), "fail-fast: a refused open must leave nothing writable: \(wrote)")
        await repository.close()

        let reader = GRDBCatalogRepository(host: "corner-test", durability: .volatileForTests)
        guard case .refused = await reader.openReadOnly(at: database, reason: "viewer") else {
            Issue.record("the read-only door opened a corrupt catalog.sqlite"); await reader.close(); return
        }
        await reader.close()
        #expect(try Self.fingerprint(fixture) == before, "the app wrote over a corrupt catalog.sqlite or its witnesses")
    }

    // MARK: - Case 11

    @Test("case 11: a schema version newer than this build — refused by both doors with words naming it; not one byte written")
    func newerSchemaIsRefused() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 2)
        defer { fixture.remove() }
        let newer = GRDBCatalogRepository.currentSchemaVersion + 1
        try Self.stampSchemaVersion(newer, at: fixture.url)
        try Self.removeSidecars(fixture.url)
        let before = try Self.fingerprint(fixture)

        let repository = GRDBCatalogRepository(host: "corner-test", durability: .volatileForTests)
        guard case .refused(let words) = await repository.open(at: fixture.url) else {
            Issue.record("a newer schema was not refused"); await repository.close(); return
        }
        #expect(words.contains("newer than this build"), Comment(rawValue: words))
        #expect(words.contains("\(newer)"), Comment(rawValue: words))
        await repository.close()

        let reader = GRDBCatalogRepository(host: "corner-test", durability: .volatileForTests)
        guard case .refused(let readerWords) = await reader.openReadOnly(at: fixture.url, reason: "viewer") else {
            Issue.record("the read-only door opened a newer schema"); await reader.close(); return
        }
        #expect(readerWords.contains("newer than this build"), Comment(rawValue: readerWords))
        await reader.close()
        #expect(try Self.fingerprint(fixture) == before, "a refused newer schema was migrated or written")
    }

    // MARK: - Fail fast: the file replaced underneath

    /// The ruled words (#359, Rick 10/21) a refused commit carries.
    static let replacedWords = "catalog.sqlite was replaced or moved while VideoScan was open; nothing more will be saved — quit and reopen"

    @Test("fail-fast (#359): catalog.sqlite replaced underneath an open session — both write doors refuse BEFORE writing, in the ruled words; not one byte lands in the moved-aside file, its -wal, the replacement or the witnesses")
    func databaseReplacedUnderneath() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 2, durability: .archival)
        defer { fixture.remove() }
        let repository = GRDBCatalogRepository(host: "corner-test", durability: .volatileForTests)
        try #require(await repository.open(at: fixture.url) == .readWrite)
        let generation = await repository.generation
        // A same-generation copy put in its place (a restore, a sync tool, Finder).
        let copy = fixture.directory.appendingPathComponent("copy.sqlite")
        #expect(repository.sealedCopyBlocking(to: copy) == nil)
        let aside = fixture.directory.appendingPathComponent("moved-aside.sqlite")
        let wal = URL(fileURLWithPath: fixture.url.path + "-wal")
        let originalBefore = try Self.sha256(fixture.url)
        let replacementBefore = try Self.sha256(copy)
        let walBefore = try Self.sha256(wal)
        let witnessesBefore = Array(try Self.fingerprint(fixture).dropFirst())
        try FileManager.default.moveItem(at: fixture.url, to: aside)
        try FileManager.default.moveItem(at: copy, to: fixture.url)

        // Both doors: the actor's `write` and the committer's `writeBlocking`.
        let first = await repository.write(as: .ui) { _ in }
        let second = repository.writeBlocking(as: .ui) { _ in }
        let generationAfter = await repository.generation
        // Before close: close's checkpoint is not a commit (see the report on #359).
        let walAfter = try Self.sha256(wal)
        let witnessesAfter = Array(try Self.fingerprint(fixture).dropFirst())
        await repository.close()
        print("[corner-open] replaced underneath: \(first) / \(second)")
        // Until #359 this was refused only by Apple SQLite's SQLITE_IOERR_VNODE
        // (6922), a file-system notice that arrives ASYNCHRONOUSLY: under load
        // both writes committed into the moved-aside file (generation 2 → 3 → 4).
        // Now the store compares device + inode before every commit: a hard
        // expectation, never a known issue.
        #expect(first == .refused(reason: Self.replacedWords), "first write: \(first)")
        #expect(second == .refused(reason: Self.replacedWords), "second write: \(second)")
        #expect(generationAfter == generation)
        #expect(walAfter == walBefore, "a frame landed in catalog.sqlite-wal after the file was replaced")
        #expect(witnessesAfter == witnessesBefore, "a high-water witness moved after the file was replaced")
        #expect(try Self.sha256(aside) == originalBefore, "the moved-aside catalog.sqlite changed")
        #expect(try Self.sha256(fixture.url) == replacementBefore, "the replacement catalog.sqlite changed")
    }

    @Test("fail-fast (#359): catalog.sqlite moved away with nothing in its place — refused in the ruled words; moving it back does not resume writing (no silent retry)")
    func databaseMovedAwayStaysStopped() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 2)
        defer { fixture.remove() }
        let repository = GRDBCatalogRepository(host: "corner-test", durability: .volatileForTests)
        try #require(await repository.open(at: fixture.url) == .readWrite)
        let aside = fixture.directory.appendingPathComponent("moved-aside.sqlite")
        try FileManager.default.moveItem(at: fixture.url, to: aside)
        let gone = await repository.write(as: .ui) { _ in }
        try FileManager.default.moveItem(at: aside, to: fixture.url)
        let back = await repository.write(as: .ui) { _ in }
        let generation = await repository.generation
        await repository.close()
        #expect(gone == .refused(reason: Self.replacedWords), "\(gone)")
        #expect(back == .refused(reason: Self.replacedWords), "the session resumed writing once the file came back: \(back)")
        #expect(generation == 2)
    }

    /// Every file a swap could touch (QA r1 E): the database at the path, its
    /// -wal and -shm, both witnesses, and any extra file (the replacement,
    /// the moved-aside file). SHA-256 each; missing = "-". No `dropFirst`.
    static func everyFile(_ fixture: StoreFixture, plus extra: [URL] = []) throws -> [String: String] {
        var files = [fixture.url, URL(fileURLWithPath: fixture.url.path + "-wal"), URL(fileURLWithPath: fixture.url.path + "-shm"),
                     fixture.highWaterURL, fixture.highWaterLogURL]
        files += extra
        var hashes: [String: String] = [:]
        for url in files { hashes[url.lastPathComponent] = try sha256(url) }
        return hashes
    }

    @Test("fail-fast (#359): the latch beside catalog.sqlite removed or replaced mid-session — the next write is refused in words naming catalog.cutover; not one byte changes in any catalog file",
          arguments: [false, true])
    func latchGoneOrReplacedMidSession(_ replaced: Bool) async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 2)
        defer { fixture.remove() }
        let latch = fixture.directory.appendingPathComponent(SQLiteCatalogReader.latchFileName)
        try Data("switched\n".utf8).write(to: latch)
        let repository = GRDBCatalogRepository(host: "corner-test", durability: .volatileForTests)
        try #require(await repository.open(at: fixture.url) == .readWrite)
        #expect(await repository.write(as: .ui) { _ in }.isCommitted, "an armed latch that has not moved lets the write through")
        let before = try Self.everyFile(fixture)
        try FileManager.default.removeItem(at: latch)
        if replaced { try Data("switched\n".utf8).write(to: latch) }      // same name, a new file
        let refused = await repository.write(as: .ui) { _ in }
        let generation = await repository.generation
        let after = try Self.everyFile(fixture)
        await repository.close()
        #expect(refused == .refused(reason: "\(SQLiteCatalogReader.latchFileName) was replaced or removed while VideoScan was open; nothing more will be saved — quit and reopen"),
                "\(refused)")
        #expect(generation == 3)
        #expect(after == before, "a catalog file changed after the latch went: \(before) → \(after)")
    }

    @Test("fail-fast (#359): Adopt after catalog.sqlite was moved aside — refused in the ruled words before any witness is raised; not one byte changes in any catalog file")
    func adoptAfterTheFileMovedIsRefused() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 5)
        defer { fixture.remove() }
        try fixture.writeHighWater("10")
        let repository = GRDBCatalogRepository(host: "corner-test", durability: .volatileForTests)
        guard case .readOnly = await repository.open(at: fixture.url) else {
            Issue.record("expected a read-only open below the high-water"); await repository.close(); return
        }
        let aside = fixture.directory.appendingPathComponent("moved-aside.sqlite")
        let originalBefore = try Self.sha256(fixture.url)
        try FileManager.default.moveItem(at: fixture.url, to: aside)
        let before = try Self.everyFile(fixture, plus: [aside])
        let adopted = await repository.adopt(toHighWater: 10)
        let generation = await repository.generation
        let after = try Self.everyFile(fixture, plus: [aside])
        await repository.close()
        #expect(adopted == .refused(reason: Self.replacedWords), "\(adopted)")
        #expect(generation == 5)
        #expect(after == before, "a catalog file changed: \(before) → \(after)")
        #expect(try Self.sha256(aside) == originalBefore)
    }

    /// QA r1 F3 — commits BEFORE the swap (the case the first round missed).
    /// close() after a stop does NOT checkpoint (Apple SQLite refuses or
    /// skips it once it noticed the rename) and RENAMES this session's own
    /// -wal / -shm into `catalog-wal-quarantine-<stamp>/`: the replacement
    /// never inherits them, and the quarantined -wal put beside the
    /// moved-aside file completes it (generation 4). Nothing deleted.
    @Test("fail-fast (#359, QA r1 F3): commits before the swap, then close — the session's -wal is quarantined (renamed, never deleted); the replacement opens at its own generation; moved-aside + quarantined -wal = every commit")
    func closeAfterSwapQuarantinesTheSessionsWAL() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 2)
        defer { fixture.remove() }
        let repository = GRDBCatalogRepository(host: "corner-test", durability: .volatileForTests)
        try #require(await repository.open(at: fixture.url) == .readWrite)
        let copy = fixture.directory.appendingPathComponent("copy.sqlite")
        #expect(repository.sealedCopyBlocking(to: copy) == nil)          // the replacement, at generation 2
        #expect(await repository.write(as: .ui) { _ in } == .committed(generation: 3))
        #expect(await repository.write(as: .ui) { _ in } == .committed(generation: 4))
        let wal = URL(fileURLWithPath: fixture.url.path + "-wal")
        let walAtSwap = try Self.sha256(wal)
        #expect(Self.size(wal) > 0, "the two commits sit in the -wal before the swap")
        let aside = fixture.directory.appendingPathComponent("moved-aside.sqlite")
        try FileManager.default.moveItem(at: fixture.url, to: aside)
        try FileManager.default.moveItem(at: copy, to: fixture.url)
        let replacementBefore = try Self.sha256(fixture.url)
        await repository.close()                                          // no write after the swap: close's own check finds it

        let quarantine = try Self.quarantineFolders(fixture.directory)
        #expect(quarantine.count == 1, "one quarantine folder: \(quarantine.map(\.lastPathComponent))")
        #expect(!FileManager.default.fileExists(atPath: wal.path), "the session's -wal is still beside the replacement")
        #expect(!FileManager.default.fileExists(atPath: fixture.url.path + "-shm"), "the session's -shm is still beside the replacement")
        #expect(try Self.sha256(fixture.url) == replacementBefore, "the replacement changed at close")
        if let folder = quarantine.first {
            let moved = folder.appendingPathComponent("catalog.sqlite-wal")
            #expect(try Self.sha256(moved) == walAtSwap, "the quarantined -wal is not the session's, byte for byte")
            #expect(try Self.generationOfACopy(aside, wal: moved, in: fixture.directory) == 4,
                    "moved-aside + quarantined -wal do not hold every commit")
        }
        #expect(try Self.generationOfACopy(aside, in: fixture.directory) == 2, "precondition: the commits lived only in the -wal")
        let reopened = GRDBCatalogRepository(host: "corner-test", durability: .volatileForTests)
        _ = await reopened.open(at: fixture.url)
        let generation = await reopened.generation
        await reopened.close()
        #expect(generation == 2, "the replacement inherited the session's frames: generation \(generation)")
    }

    @Test("fail-fast (#359, QA r1 F3): a -wal at the path that is NOT this session's (it came with the replacement) is left alone — no quarantine, not one byte changed")
    func closeLeavesSomeoneElsesWALAlone() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 2)
        defer { fixture.remove() }
        let repository = GRDBCatalogRepository(host: "corner-test", durability: .volatileForTests)
        try #require(await repository.open(at: fixture.url) == .readWrite)
        #expect(await repository.write(as: .ui) { _ in } == .committed(generation: 3))
        let wal = URL(fileURLWithPath: fixture.url.path + "-wal")
        let shm = URL(fileURLWithPath: fixture.url.path + "-shm")
        let asideFolder = fixture.directory.appendingPathComponent("aside", isDirectory: true)
        try FileManager.default.createDirectory(at: asideFolder, withIntermediateDirectories: false)
        for url in [fixture.url, wal, shm] {                              // a tool moves all three away …
            try FileManager.default.moveItem(at: url, to: asideFolder.appendingPathComponent(url.lastPathComponent))
        }
        try Data("someone else's catalog".utf8).write(to: fixture.url)    // … and puts its own in their place
        try Data("someone else's wal".utf8).write(to: wal)
        let theirs = try Self.sha256(wal)
        await repository.close()
        #expect(try Self.quarantineFolders(fixture.directory).isEmpty, "a quarantine ran on files that are not this session's")
        #expect(try Self.sha256(wal) == theirs, "someone else's -wal was touched")
    }

    @Test("fail-fast (#359, QA r1 D): an open that requires the latch refuses without it, in GH #354's words, and writes nothing")
    func openRequiringTheLatchRefusesWithoutIt() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 2)
        defer { fixture.remove() }
        try Self.removeSidecars(fixture.url)
        let before = try Self.everyFile(fixture)
        let repository = GRDBCatalogRepository(host: "corner-test", durability: .volatileForTests)
        let opened = await repository.open(at: fixture.url, requiringLatch: true)
        let wrote = await repository.write(as: .ui) { _ in }
        await repository.close()
        #expect(opened == .refused(reason: GRDBCatalogRepository.noLatchWords(folder: fixture.directory)), "\(opened)")
        #expect(wrote == .refused(reason: "not open"))
        #expect(try Self.everyFile(fixture) == before, "a refused open wrote")
        try Data("switched\n".utf8).write(to: fixture.directory.appendingPathComponent(SQLiteCatalogReader.latchFileName))
        let again = GRDBCatalogRepository(host: "corner-test", durability: .volatileForTests)
        #expect(await again.open(at: fixture.url, requiringLatch: true) == .readWrite, "with the latch it opens")
        await again.close()
    }

    static func size(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.intValue ?? 0
    }

    static func quarantineFolders(_ folder: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("catalog-wal-quarantine-") }
    }

    /// The generation `url` holds ON ITS OWN (or with `wal` beside it): byte
    /// copies opened in a private folder, so the probe never touches the
    /// files under test.
    static func generationOfACopy(_ url: URL, wal: URL? = nil, in folder: URL) throws -> Int {
        let probeFolder = folder.appendingPathComponent("probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: probeFolder, withIntermediateDirectories: true)
        let probe = probeFolder.appendingPathComponent("probe.sqlite")
        try FileManager.default.copyItem(at: url, to: probe)
        if let wal { try FileManager.default.copyItem(at: wal, to: URL(fileURLWithPath: probe.path + "-wal")) }
        let queue = try DatabaseQueue(path: probe.path)
        defer { try? queue.close() }
        return try queue.read { try Int.fetchOne($0, sql: "SELECT generation FROM generations WHERE id = 1") ?? -1 }
    }

    @Test("fail-fast (#359): no latch at open (a bare store, the importer) — the latch is not watched and writes go on")
    func noLatchAtOpenIsNotWatched() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 2)
        defer { fixture.remove() }
        let repository = GRDBCatalogRepository(host: "corner-test", durability: .volatileForTests)
        try #require(await repository.open(at: fixture.url) == .readWrite)
        let wrote = await repository.write(as: .ui) { _ in }
        await repository.close()
        #expect(wrote == .committed(generation: 3))
    }

    // MARK: - Helpers

    /// The injected newer schema: one UPDATE of catalog_state, folded back into the file.
    static func stampSchemaVersion(_ version: Int, at url: URL) throws {
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: "UPDATE catalog_state SET schema_version = ? WHERE singleton = 1", arguments: [version])
        }
        try queue.writeWithoutTransaction { try $0.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
        try queue.close()
    }

    /// SHA-256 of catalog.sqlite and both witnesses (missing = "-").
    static func fingerprint(_ fixture: StoreFixture) throws -> [String] {
        try [fixture.url, fixture.highWaterURL, fixture.highWaterLogURL].map(sha256)
    }

    /// SHA-256 of one file (missing = "-").
    static func sha256(_ url: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { return "-" }
        return SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    static func removeSidecars(_ database: URL) throws {
        for suffix in ["-wal", "-shm"] {
            let url = URL(fileURLWithPath: database.path + suffix)
            if FileManager.default.fileExists(atPath: url.path) {
                let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
                guard suffix == "-shm" || size == 0 else { throw FixtureFailure(words: "\(url.lastPathComponent) holds \(size) bytes — not closed cleanly") }
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Overwrite the first 8 bytes of every page after the first with 0xFF —
    /// the injected damage. Page size from the header (offset 16, big-endian).
    static func corruptPageHeaders(_ database: URL) throws {
        let handle = try FileHandle(forUpdating: database)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 100) ?? Data()
        guard header.count == 100 else { throw FixtureFailure(words: "short header") }
        var pageSize = Int(header[16]) << 8 | Int(header[17])
        if pageSize == 1 { pageSize = 65_536 }
        let length = Int(try handle.seekToEnd())
        let pages = length / pageSize
        guard pages > 2 else { throw FixtureFailure(words: "only \(pages) pages") }
        for page in 1..<pages {
            try handle.seek(toOffset: UInt64(page * pageSize))
            try handle.write(contentsOf: Data(repeating: 0xFF, count: 8))
        }
        try handle.synchronize()
    }
}

/// A second connection holding SQLite's write lock (BEGIN IMMEDIATE) until
/// `release` — the stand-in for another process writing the catalog.
final class OtherWriter: @unchecked Sendable {
    private var handle: OpaquePointer?

    init(_ url: URL) throws {
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              sqlite3_exec(handle, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            let words = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close_v2(handle)
            throw FixtureFailure(words: "the other writer could not take the lock: \(words)")
        }
    }

    func release() {
        guard let handle else { return }
        sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
        sqlite3_close_v2(handle)
        self.handle = nil
    }

    deinit { release() }
}

extension CatalogWriteOutcome {
    /// True only for `.committed` (tests).
    var isCommitted: Bool {
        if case .committed = self { return true }
        return false
    }
}
