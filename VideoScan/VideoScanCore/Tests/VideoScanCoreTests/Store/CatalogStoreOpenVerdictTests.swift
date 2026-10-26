// CatalogStoreOpenVerdictTests.swift
// GH #387, Rick 2026-10-26 (docs/DECISIONS.md): a refused catalog open never
// deletes a journal file, and the open checks (version, integrity, foreign
// keys) run inside the writer's first BEGIN IMMEDIATE with the normal busy
// timeout — so the lock that admits the file is the lock that writes it.
// One test per Codex #144 finding (docs/reviews/codex/codex-review-store-
// durability-third-2026-10-25.md); the red/green table is in the commit.
//
// Lives under Tests/…/Store/ because it opens the same file with plain GRDB
// queues (the sensor allows `import GRDB` only here and in Sources/…/Store/).
// One condition per #expect.
//
// Suite (filter by SUITE): CatalogStoreOpenVerdictTests

import Foundation
import GRDB
import Testing
@testable import VideoScanCore

@Suite("CatalogStoreOpenVerdict — the open's checks hold the writer's lock; a refusal deletes nothing")
struct CatalogStoreOpenVerdictTests {

    /// Another program's connection, kept open across the open under test
    /// (for Rick: a mutex-guarded pointer to a second sqlite3* handle).
    private final class OtherConnection: @unchecked Sendable {
        private let lock = NSLock()
        private var queue: DatabaseQueue?
        private var sidecars: [String: UInt64] = [:]
        func keep(_ q: DatabaseQueue, sidecars found: [String: UInt64]) { lock.withLock { queue = q; sidecars = found } }
        var kept: DatabaseQueue? { lock.withLock { queue } }
        var sidecarsWhenOpened: [String: UInt64] { lock.withLock { sidecars } }
        func close() throws { try lock.withLock { try queue?.close(); queue = nil } }
    }

    /// `-wal` / `-shm` beside `url` by suffix → inode (absent ones omitted).
    private static func sidecarInodes(_ url: URL) -> [String: UInt64] {
        var found: [String: UInt64] = [:]
        for suffix in ["-wal", "-shm"] {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path + suffix)
            if let inode = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value { found[suffix] = inode }
        }
        return found
    }

    /// A current catalog in WAL mode whose last closer left nothing beside
    /// it (a `sqlite3` shell, a `cp` of the file alone) — optionally stamped
    /// `version`. The -wal must be empty before it is taken away.
    private static func walFixtureWithoutSidecars(version: Int? = nil) async throws -> StoreFixture {
        let fixture = try await StoreFixture.make(.grdb, generation: 1)
        let queue = try DatabaseQueue(path: fixture.url.path)
        try queue.inDatabase { db in
            if let version {
                try db.execute(sql: "UPDATE catalog_state SET schema_version = \(version) WHERE singleton = 1")
                try db.execute(sql: "PRAGMA user_version = \(version)")
            }
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
        try queue.close()
        let fm = FileManager.default
        for suffix in ["-wal", "-shm"] where fm.fileExists(atPath: fixture.url.path + suffix) {
            let size = (try fm.attributesOfItem(atPath: fixture.url.path + suffix)[.size] as? NSNumber)?.intValue ?? -1
            try #require(suffix == "-shm" || size == 0, "the -wal holds \(size) bytes — the checkpoint did not empty it")
            try fm.removeItem(atPath: fixture.url.path + suffix)   // the fixture's own temp dir
        }
        return fixture
    }

    // MARK: - #144-1 (P1): a refusal never removes a sidecar another connection is using

    /// Codex's recipe: the file had no sidecars when the open began; another
    /// connection opens it during the open, commits without checkpointing and
    /// stays connected; the open then refuses. Its `-wal` and `-shm` are that
    /// connection's live state — a refusal that removes either separates the
    /// WAL from its index under a live writer (sqlite.org/wal.html).
    @Test func foreignSidecarsSurviveARefusal() async throws {
        let fixture = try await Self.walFixtureWithoutSidecars()
        defer { fixture.remove() }
        let url = fixture.url
        let newer = GRDBCatalogRepository.currentSchemaVersion + 1
        let other = OtherConnection()
        let repository = GRDBCatalogRepository(host: "foreign-sidecars", durability: .volatileForTests)
        await repository.injectAdmittedHook {
            let queue = try DatabaseQueue(path: url.path)
            try queue.write { db in
                try db.execute(sql: "UPDATE catalog_state SET schema_version = \(newer) WHERE singleton = 1")
                try db.execute(sql: "PRAGMA user_version = \(newer)")
            }
            other.keep(queue, sidecars: Self.sidecarInodes(url))
        }
        let outcome = await repository.open(at: url)
        guard case .refused(let words) = outcome else {
            Issue.record("expected .refused for a schema another connection raised mid-open, got \(outcome)")
            await repository.close()
            try other.close()
            return
        }
        #expect(words.contains("schema version \(newer) is newer"), Comment(rawValue: words))
        let opened = other.sidecarsWhenOpened
        try #require(opened.keys.contains("-wal") && opened.keys.contains("-shm"), "the other connection made no sidecars: \(opened)")
        let now = Self.sidecarInodes(url)
        #expect(now["-shm"] == opened["-shm"], "the live -shm was removed or replaced under the other connection: \(opened) → \(now)")
        #expect(now["-wal"] == opened["-wal"], "the live -wal was removed or replaced under the other connection: \(opened) → \(now)")
        let seen = try await other.kept?.read { try Int.fetchOne($0, sql: "SELECT schema_version FROM catalog_state WHERE singleton = 1") }
        #expect(seen == newer, "the other connection lost its own commit")
        try other.close()
        await repository.close()
    }

    // MARK: - #144-2 (P1): a foreign-key violation landing after the checks never reaches a writer

    /// Codex's recipe: a current catalog; between the checks and the first
    /// write, another connection (foreign keys OFF) adds a row whose
    /// reference dangles. Version unchanged. The open must refuse in the
    /// foreign_key_check's words, never publish a writer.
    @Test func aForeignKeyViolationAfterTheChecksIsRefused() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 1)
        defer { fixture.remove() }
        let url = fixture.url
        let repository = GRDBCatalogRepository(host: "fk-after-checks", durability: .volatileForTests)
        await repository.injectAdmittedHook {
            var configuration = Configuration()
            configuration.foreignKeysEnabled = false
            let other = try DatabaseQueue(path: url.path, configuration: configuration)
            try other.write { db in
                try db.execute(sql: "CREATE TABLE admission_fk_probe (generation INTEGER REFERENCES generations(id))")
                try db.execute(sql: "INSERT INTO admission_fk_probe VALUES (999)")
            }
            try other.close()
        }
        let outcome = await repository.open(at: url)
        guard case .refused(let words) = outcome else {
            Issue.record("expected .refused for a foreign-key violation added after the checks, got \(outcome)")
            await repository.close()
            return
        }
        #expect(words.contains("foreign_key_check"), Comment(rawValue: words))
        let wrote = await repository.write(as: .ui) { _ in }
        #expect(wrote == .refused(reason: "not open"), "a refused open left something writable: \(wrote)")
        await repository.close()
    }

    // MARK: - #144-3 (P2): a refused open never checkpoints committed frames into the main file

    /// A crash image: a newer-schema catalog whose last transaction is
    /// committed in its `-wal` and not yet checkpointed (the writer died, or
    /// the file was copied with its WAL). No other connection is open, so the
    /// refusing connection would be the LAST to close — and SQLite's close
    /// checkpoints the WAL into the main file and then deletes the WAL.
    private static func newerSchemaCrashImage() async throws -> (StoreFixture, Int) {
        let source = try await StoreFixture.make(.grdb, generation: 1)
        defer { source.remove() }
        let newer = GRDBCatalogRepository.currentSchemaVersion + 1
        let image = StoreFixture(kind: .grdb, directory: try StoreFixture.temporaryDirectory())
        let writer = try DatabaseQueue(path: source.url.path)
        try writer.inDatabase { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
            try db.execute(sql: "PRAGMA wal_autocheckpoint = 0")
            try db.execute(sql: "UPDATE catalog_state SET schema_version = \(newer) WHERE singleton = 1")
            try db.execute(sql: "PRAGMA user_version = \(newer)")
        }
        // Copied while the writer is still open: the main file without the
        // commit, the -wal with it — what a crash leaves.
        try FileManager.default.copyItem(at: source.url, to: image.url)
        try FileManager.default.copyItem(atPath: source.url.path + "-wal", toPath: image.url.path + "-wal")
        try writer.close()
        let walSize = (try FileManager.default.attributesOfItem(atPath: image.url.path + "-wal")[.size] as? NSNumber)?.intValue ?? 0
        try #require(walSize > 0, "the crash image's -wal is empty")
        return (image, newer)
    }

    @Test func aRefusedOpenLeavesCommittedFramesInTheirWAL() async throws {
        let (fixture, newer) = try await Self.newerSchemaCrashImage()
        defer { fixture.remove() }
        let mainBefore = try Data(contentsOf: fixture.url)
        let walBefore = try Data(contentsOf: URL(fileURLWithPath: fixture.url.path + "-wal"))
        let repository = GRDBCatalogRepository(host: "crash-image", durability: .volatileForTests)
        let outcome = await repository.open(at: fixture.url)
        guard case .refused(let words) = outcome else {
            Issue.record("expected .refused for a newer schema committed in the -wal, got \(outcome)")
            await repository.close()
            return
        }
        #expect(words.contains("schema version \(newer) is newer"), Comment(rawValue: words))
        await repository.close()
        let mainAfter = try Data(contentsOf: fixture.url)
        #expect(mainAfter == mainBefore, "the refused open checkpointed the -wal into the main file (\(mainBefore.count) → \(mainAfter.count) bytes, or same size with pages rewritten)")
        let walAfter = try? Data(contentsOf: URL(fileURLWithPath: fixture.url.path + "-wal"))
        #expect(walAfter == walBefore, "the -wal holding the committed transaction was removed or rewritten (\(walBefore.count) → \(walAfter?.count ?? -1) bytes)")
    }

    // MARK: - #144-4 (P2): a briefly locked healthy catalog is waited for, not refused

    /// A healthy current catalog in rollback-journal mode, held under
    /// `BEGIN EXCLUSIVE` by another connection for a second. The open must
    /// wait (the store's 5 s busy timeout) and open read-write.
    @Test func aBrieflyLockedCatalogIsWaitedFor() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 1)
        defer { fixture.remove() }
        let setup = try DatabaseQueue(path: fixture.url.path)
        try setup.inDatabase { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
            _ = try String.fetchOne(db, sql: "PRAGMA journal_mode = DELETE")
        }
        try setup.close()
        var configuration = Configuration()
        configuration.allowsUnsafeTransactions = true
        let blocker = try DatabaseQueue(path: fixture.url.path, configuration: configuration)
        try blocker.inDatabase { db in try db.execute(sql: "BEGIN EXCLUSIVE") }
        let hold: Duration = .seconds(1)
        let release = Task.detached {
            try await Task.sleep(for: hold)
            try blocker.inDatabase { db in try db.execute(sql: "COMMIT") }
        }
        let clock = ContinuousClock()
        let started = clock.now
        let repository = GRDBCatalogRepository(host: "briefly-locked", durability: .volatileForTests)
        let outcome = await repository.open(at: fixture.url)
        let waited = clock.now - started
        try await release.value
        try blocker.close()
        #expect(outcome == .readWrite, "a catalog locked for \(hold) was not waited for: \(outcome)")
        #expect(waited >= .milliseconds(500), "the open did not wait for the lock (\(waited))")
        await repository.close()
    }
}
