// CatalogFolderDoorsTests.swift
// Catalog folders in catalog.sqlite (schema v1.10, migration
// `v6_folder_kind`; CatalogFolderRows.swift, GRDBCatalogRepository+Folders
// .swift):
//   LOGIC     — a folder round-trips with its kind; an upsert keeps
//               created_at and changes name / kind / state; the stream is
//               read back in order; only stored digests become members.
//   MIGRATION — a v1.9 database's existing events read kind 'event' after
//               the open (additive: no row rewritten); a kind outside the
//               three is refused by the CHECK.
//   BACKUP    — a sealed copy (VACUUM INTO, what Back Up Catalog bundles)
//               carries the folders, the stream and the members.
// One condition per #expect. Synthetic names only.

import Foundation
import GRDB
import Testing
@testable import VideoScanCore

@Suite("CatalogFolderDoors")
struct CatalogFolderDoorsTests {

    private static let eventID = "AAAAAAAA-0000-0000-0000-000000000001"
    private static let otherID = "AAAAAAAA-0000-0000-0000-000000000002"

    private func open(_ fixture: StoreFixture) async throws -> GRDBCatalogRepository {
        let repository = GRDBCatalogRepository(host: "test-host", durability: .volatileForTests)
        let opened = await repository.open(at: fixture.url)
        try #require(opened == .readWrite)
        return repository
    }

    private func seedContent(_ fixture: StoreFixture) throws {
        try DatabaseQueue(path: fixture.url.path).inDatabase { db in try db.execute(sql: SchemaSeed.contentAInsert) }
    }

    private static func folder(_ id: String = eventID, name: String = "Synthetic Picnic", kind: String = "event",
                               state: String = "confirmed", at: Int64 = 1_700_000_000) -> CatalogRow.Folder {
        CatalogRow.Folder(eventID: id, name: name, state: state, kind: kind, categories: ["Picnic"], note: nil,
                          createdAt: at, updatedAt: at)
    }

    private struct Read: Sendable {
        var folders: [CatalogRow.Folder] = []
        var decisions: [CatalogRow.FolderDecision] = []
        var counts = CatalogRow.FolderCounts(events: 0, decisions: 0, members: 0)
    }

    private func readAll(_ repository: GRDBCatalogRepository) async throws -> Read {
        try await repository.read { reader in
            var out = Read()
            try reader.folderRows { out.folders.append($0) }
            try reader.folderDecisions { out.decisions.append($0) }
            out.counts = try reader.folderCounts()
            return out
        }
    }

    // MARK: - Logic

    @Test func aFolderRoundTripsWithItsKindTheStreamAndItsMembers() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        try seedContent(fixture)
        let repository = try await open(fixture)
        let outcome = await repository.write(as: .ui) { tx in
            try tx.upsertFolder(Self.folder(kind: "person"))
            try tx.appendFolderDecision(kind: "member", payloadJSON: #"{"kind":"member","n":1}"#)
            try tx.appendFolderDecision(kind: "member", payloadJSON: #"{"kind":"member","n":2}"#)
            _ = try tx.replaceFolderMembers(eventID: Self.eventID, [
                CatalogRow.FolderMember(key: SchemaSeed.digestA),
                CatalogRow.FolderMember(key: "pair:" + Self.otherID),          // not a digest: stream only
                CatalogRow.FolderMember(key: SchemaSeed.digestB),               // not stored: stream only
                CatalogRow.FolderMember(key: SchemaSeed.digestA.uppercased()),  // the same content twice
            ])
        }
        #expect(outcome == .committed(generation: 1))
        let read = try await readAll(repository)
        #expect(read.folders == [Self.folder(kind: "person")])
        #expect(read.decisions.map(\.payloadJSON) == [#"{"kind":"member","n":1}"#, #"{"kind":"member","n":2}"#])
        #expect(read.counts == CatalogRow.FolderCounts(events: 1, decisions: 2, members: 1))
        await repository.close()
    }

    @Test func replaceFolderMembersSaysHowManyLanded() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        try seedContent(fixture)
        let repository = try await open(fixture)
        let box = LandedBox()
        _ = await repository.write(as: .ui) { tx in
            try tx.upsertFolder(Self.folder())
            box.set(try tx.replaceFolderMembers(eventID: Self.eventID, [CatalogRow.FolderMember(key: SchemaSeed.digestA),
                                                                       CatalogRow.FolderMember(key: "pair:x")]))
        }
        #expect(box.value == 1)
        // Replacing with nothing empties the folder's fold.
        _ = await repository.write(as: .ui) { tx in _ = try tx.replaceFolderMembers(eventID: Self.eventID, []) }
        #expect(try await readAll(repository).counts.members == 0)
        await repository.close()
    }

    @Test func anUpsertKeepsCreatedAtAndChangesNameKindAndState() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        let repository = try await open(fixture)
        _ = await repository.write(as: .ui) { tx in try tx.upsertFolder(Self.folder(at: 1_700_000_000)) }
        var later = Self.folder(name: "Synthetic Picnic 1990", kind: "other", state: "dismissed", at: 1_800_000_000)
        _ = await repository.write(as: .ui) { tx in try tx.upsertFolder(later) }
        let read = try await readAll(repository)
        later.createdAt = 1_700_000_000
        #expect(read.folders == [later])
        await repository.close()
    }

    @Test func aKindOutsideTheThreeIsRefusedAndNothingLands() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        let repository = try await open(fixture)
        let outcome = await repository.write(as: .ui) { tx in try tx.upsertFolder(Self.folder(kind: "album")) }
        guard case .refused(let words) = outcome else {
            Issue.record("expected .refused, got \(outcome)")
            return
        }
        #expect(words.contains("CHECK"))
        #expect(try await readAll(repository).counts.events == 0)
        await repository.close()
    }

    // MARK: - Migration (additive)

    @Test func aV19DatabasesEventsReadKindEventAfterTheOpen() async throws {
        let fixture = StoreFixture(kind: .grdb, directory: try StoreFixture.temporaryDirectory())
        defer { fixture.remove() }
        // A file exactly as a v1.9 build left it: five migrations, one event.
        var v19 = DatabaseMigrator()
        v19.registerMigration(CatalogBookkeepingSchema.migrationID, foreignKeyChecks: .immediate) { db in
            for statement in CatalogBookkeepingSchema.statements { try db.execute(sql: statement) }
            try db.execute(sql: "PRAGMA user_version = 7")
            try db.execute(sql: "INSERT INTO catalog_state (singleton, schema_version) VALUES (1, 7)")
            try db.execute(sql: "INSERT INTO generations (id, generation, saved_at, saved_from_host) VALUES (1, 0, 1, 'v19')")
            try db.execute(sql: "INSERT INTO generation_history (generation, committed_at, host, writer, files_live, files_total) VALUES (0, 1, 'v19', 'create', 0, 0)")
        }
        v19.registerMigration(CatalogDataSchema.migrationID, foreignKeyChecks: .immediate) { db in
            for statement in CatalogDataSchema.statements { try db.execute(sql: statement) }
        }
        v19.registerMigration(CatalogLiveWritesSchema.migrationID, foreignKeyChecks: .immediate) { db in
            for statement in CatalogLiveWritesSchema.statements + CatalogLiveWritesSchema.versionBump { try db.execute(sql: statement) }
        }
        v19.registerMigration(CatalogPendingRowsSchema.migrationID, foreignKeyChecks: .immediate) { db in
            for statement in CatalogPendingRowsSchema.statements + CatalogPendingRowsSchema.versionBump { try db.execute(sql: statement) }
        }
        v19.registerMigration(CatalogCommitB22Schema.migrationID, foreignKeyChecks: .immediate) { db in
            for statement in CatalogCommitB22Schema.statements + CatalogCommitB22Schema.versionBump { try db.execute(sql: statement) }
        }
        let queue = try DatabaseQueue(path: fixture.url.path)
        try v19.migrate(queue)
        try queue.inDatabase { db in
            try db.execute(sql: """
                INSERT INTO events (event_id, name, state, categories, note, created_at, updated_at)
                VALUES ('\(Self.eventID)', 'Synthetic Picnic', 'confirmed', '[]', NULL, 1, 1)
                """)
        }
        try queue.close()
        try fixture.writeHighWater("0")

        let repository = try await open(fixture)
        let read = try await readAll(repository)
        #expect(read.folders.map(\.kind) == ["event"])
        let version = try await repository.read { reader in try reader.folderCounts().events }
        #expect(version == 1)
        await repository.close()
        let schema = try DatabaseQueue(path: fixture.url.path).inDatabase { db in
            try Int.fetchOne(db, sql: "SELECT schema_version FROM catalog_state")
        }
        #expect(schema == CatalogFolderKindSchema.schemaVersion)
    }

    // MARK: - Backup: the sealed copy carries the folders

    @Test func aSealedCopyCarriesTheFoldersTheStreamAndTheMembers() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        try seedContent(fixture)
        let repository = try await open(fixture)
        _ = await repository.write(as: .ui) { tx in
            try tx.upsertFolder(Self.folder(kind: "person"))
            try tx.upsertFolder(Self.folder(Self.otherID, name: "Synthetic Beach", kind: "event"))
            try tx.appendFolderDecision(kind: "member", payloadJSON: #"{"kind":"member"}"#)
            _ = try tx.replaceFolderMembers(eventID: Self.eventID, [CatalogRow.FolderMember(key: SchemaSeed.digestA)])
            _ = try tx.replaceFolderMembers(eventID: Self.otherID, [CatalogRow.FolderMember(key: SchemaSeed.digestA)])
        }
        let copy = fixture.directory.appendingPathComponent("sealed.sqlite")
        #expect(repository.sealedCopyBlocking(to: copy) == nil)
        await repository.close()

        let sealed = GRDBCatalogRepository(host: "test-host", durability: .volatileForTests)
        let opened = await sealed.openReadOnly(at: copy, reason: "test: a backup bundle")
        if case .refused(let why) = opened { Issue.record("the sealed copy would not open: \(why)") }
        let read = try await readAll(sealed)
        #expect(read.counts == CatalogRow.FolderCounts(events: 2, decisions: 1, members: 2))
        #expect(read.folders.map(\.kind) == ["person", "event"])
        await sealed.close()
    }
}

/// The landed count out of a `@Sendable` write body.
private final class LandedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = -1
    var value: Int { lock.withLock { stored } }
    func set(_ v: Int) { lock.withLock { stored = v } }
}
