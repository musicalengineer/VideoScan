// SQLiteWALSidecarTests.swift
// GH #386, Rick 2026-10-26 (docs/DECISIONS.md): a read-only door that finds
// a WAL-mode SQLite file with no `-wal` beside it creates the empty sidecar
// when the folder is writable (create-only, never truncating or replacing an
// existing one), and otherwise refuses in words that say why. The red/green
// table is in the commit; the read-write door's half is
// CatalogCornerCases2026_10_25Tests.theReadOnlyDoorNeedsTheWALSidecarOnAppleSQLite.
//
// Five dimensions: LOGIC (every test) · SCALE N/A (one header read, one
// open(2)) · MEDIA N/A · ISOLATION (one temp folder per test; a read-only
// folder, a crash image and a dangling symlink are the poisoned states) ·
// SENSOR (byte and inode pins wherever "untouched" is claimed).
//
// Suite (filter by SUITE): SQLiteWALSidecarTests

import Foundation
import GRDB
import Testing
@testable import VideoScanCore

@Suite("SQLiteWALSidecar — read-only doors restore a missing -wal, or say why they cannot", .serialized)
struct SQLiteWALSidecarTests {

    private static func wal(_ url: URL) -> String { url.path + "-wal" }

    /// A current catalog in WAL mode whose last closer was a read-write
    /// program that removed both sidecars (a `sqlite3` shell, a `cp`).
    private static func walCatalogWithoutSidecars() async throws -> StoreFixture {
        let fixture = try await StoreFixture.make(.grdb, generation: 3)
        try CatalogOpenCornerTests.removeSidecars(fixture.url)
        try #require(SQLiteWALSidecar.isWALMode(fixture.url))
        try #require(!FileManager.default.fileExists(atPath: wal(fixture.url)))
        return fixture
    }

    private static func directorySnapshot(_ directory: URL) throws -> [String: Data] {
        var snapshot: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            snapshot[name] = try Data(contentsOf: directory.appendingPathComponent(name))
        }
        return snapshot
    }

    private static func inode(_ path: String) -> UInt64? {
        var info = stat()
        return lstat(path, &info) == 0 ? UInt64(info.st_ino) : nil
    }

    // MARK: - Writable folder: the door restores the sidecar and opens

    @Test func theViewerDoorRestoresTheSidecarAndOpens() async throws {
        let fixture = try await Self.walCatalogWithoutSidecars()
        defer { fixture.remove() }
        let main = try Data(contentsOf: fixture.url)
        let repository = GRDBCatalogRepository(host: "viewer", durability: .volatileForTests)
        let opened = await repository.openReadOnly(at: fixture.url, reason: "a viewer Mac")
        #expect(opened == .readOnly(reason: "a viewer Mac"), "\(opened)")
        #expect(try await repository.read { $0.generation } == 3)
        await repository.close()
        let size = (try? FileManager.default.attributesOfItem(atPath: Self.wal(fixture.url))[.size] as? NSNumber)?.intValue
        #expect(size == 0, "the restored -wal must be empty (got \(size.map(String.init) ?? "none"))")
        #expect(try Data(contentsOf: fixture.url) == main, "a read-only door changed the main file")
    }

    @Test func thePreflightReaderReadsACatalogWithoutItsSidecar() async throws {
        let fixture = try await Self.walCatalogWithoutSidecars()
        defer { fixture.remove() }
        #expect(try CatalogPreflightReader.schemaVersion(at: fixture.url) == GRDBCatalogRepository.currentSchemaVersion)
        #expect(FileManager.default.fileExists(atPath: Self.wal(fixture.url)))
    }

    /// Codex #151-4: through `alias.sqlite → catalog.sqlite` SQLite uses the
    /// TARGET's sidecar names; the restored -wal must be `catalog.sqlite-wal`.
    @Test func aViewerOpeningThroughAnAliasGetsTheTargetsSidecar() async throws {
        let fixture = try await Self.walCatalogWithoutSidecars()
        defer { fixture.remove() }
        let alias = fixture.directory.appendingPathComponent("alias.sqlite")
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: fixture.url.lastPathComponent)
        let repository = GRDBCatalogRepository(host: "viewer", durability: .volatileForTests)
        let opened = await repository.openForReading(at: alias)
        await repository.close()
        #expect(opened == .readOnly(reason: GRDBCatalogRepository.readerOnlyWords), "\(opened)")
        #expect(FileManager.default.fileExists(atPath: Self.wal(fixture.url)), "the target's -wal was not restored")
        #expect(!FileManager.default.fileExists(atPath: alias.path + "-wal"), "a -wal SQLite never reads was made beside the alias")
    }

    /// Codex #151-5: the restored -wal gets the database's mode whatever the
    /// process umask. umask(2) is PROCESS-wide and swift test runs suites in
    /// parallel, so it is changed for the one helper call only and restored
    /// at once (this suite is .serialized; other suites' files created in
    /// that microsecond window would only be created more private).
    @Test func theRestoredSidecarHasTheDatabasesModeWhateverTheUmask() async throws {
        let fixture = try await Self.walCatalogWithoutSidecars()
        defer { fixture.remove() }
        try FileManager.default.setAttributes([.posixPermissions: 0o660], ofItemAtPath: fixture.url.path)
        let previous = umask(0o077)
        let readiness = SQLiteWALSidecar.prepareForReadOnlyOpen(fixture.url)
        umask(previous)
        #expect(readiness == .created)
        let mode = (try FileManager.default.attributesOfItem(atPath: Self.wal(fixture.url))[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o660, "the -wal's mode is \(String(mode ?? -1, radix: 8)), not the database's 660")
    }

    // MARK: - Read-only folder: refused, in words that say why

    @Test func aReadOnlyFolderIsRefusedWithWordsThatSayWhy() async throws {
        let fixture = try await Self.walCatalogWithoutSidecars()
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fixture.directory.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.directory.path)
            fixture.remove()
        }
        let before = try Self.directorySnapshot(fixture.directory)
        let repository = GRDBCatalogRepository(host: "viewer", durability: .volatileForTests)
        let opened = await repository.openForReading(at: fixture.url)
        await repository.close()
        guard case .refused(let words) = opened else {
            Issue.record("expected .refused in a read-only folder, got \(opened)")
            return
        }
        #expect(words.contains("was last closed by another program"), Comment(rawValue: words))
        #expect(words.contains("Opening it once in VideoScan"), Comment(rawValue: words))
        #expect(!words.contains("unable to open database file"), "the engine's bare words leaked through: \(words)")
        var preflightWords = ""
        do {
            _ = try CatalogPreflightReader.schemaVersion(at: fixture.url)
            Issue.record("the preflight read a catalog it could not open read-only")
        } catch {
            preflightWords = String(describing: error)
        }
        #expect(preflightWords.contains("was last closed by another program"), Comment(rawValue: preflightWords))
        #expect(try Self.directorySnapshot(fixture.directory) == before, "a refused read-only open changed the folder")
    }

    // MARK: - Never touched: an existing -wal, a symlink, a rollback-mode file

    @Test func anExistingSidecarIsNeverTouched() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 1)
        defer { fixture.remove() }
        // A -wal holding committed frames another writer has not checkpointed.
        let writer = try DatabaseQueue(path: fixture.url.path)
        try writer.inDatabase { db in
            try db.execute(sql: "PRAGMA wal_autocheckpoint = 0")
            try db.execute(sql: "CREATE TABLE sidecar_probe (x INTEGER); INSERT INTO sidecar_probe VALUES (1)")
        }
        let path = Self.wal(fixture.url)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        try #require(!bytes.isEmpty)
        let inode = Self.inode(path)
        #expect(SQLiteWALSidecar.prepareForReadOnlyOpen(fixture.url) == .alreadyThere)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == bytes, "an existing -wal was truncated or rewritten")
        #expect(Self.inode(path) == inode, "an existing -wal was replaced")
        try writer.close()
    }

    @Test func aDanglingSymlinkIsNeitherFollowedNorReplaced() async throws {
        let fixture = try await Self.walCatalogWithoutSidecars()
        defer { fixture.remove() }
        let target = fixture.directory.appendingPathComponent("elsewhere-wal").path
        try FileManager.default.createSymbolicLink(atPath: Self.wal(fixture.url), withDestinationPath: target)
        #expect(SQLiteWALSidecar.prepareForReadOnlyOpen(fixture.url) == .alreadyThere)
        #expect(!FileManager.default.fileExists(atPath: target), "the symlink was followed and its target created")
        let link = try? FileManager.default.destinationOfSymbolicLink(atPath: Self.wal(fixture.url))
        #expect(link == target, "the symlink was replaced")
    }

    @Test func aRollbackJournalFileGetsNoSidecar() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 1)
        defer { fixture.remove() }
        let queue = try DatabaseQueue(path: fixture.url.path)
        try queue.inDatabase { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
            _ = try String.fetchOne(db, sql: "PRAGMA journal_mode = DELETE")
        }
        try queue.close()
        try CatalogOpenCornerTests.removeSidecars(fixture.url)
        #expect(SQLiteWALSidecar.prepareForReadOnlyOpen(fixture.url) == .notNeeded)
        #expect(!FileManager.default.fileExists(atPath: Self.wal(fixture.url)), "a -wal was made beside a rollback-journal file")
    }
}
