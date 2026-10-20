// EventsCatalogBackingTests.swift
// Catalog folders live in catalog.sqlite (2026-10-19). Through the REAL
// committer and a sandbox GRDB catalog (never Application Support):
//   IMPORT      — a copy-shaped events-decisions.json (with a damaged folder,
//                 a damaged decision, an unknown kind and a "pair:" key) is
//                 imported whole: every folder, every decision, the damaged
//                 elements kept verbatim as `unreadable`, the counts verified;
//                 the JSON file is left byte for byte;
//   IDEMPOTENCE — a second attach imports nothing; a changed file is said,
//                 not imported;
//   PERSISTENCE — make / add / move / remove / rename / kind / delete land in
//                 catalog.sqlite (a fresh read sees them) and NEVER in the
//                 JSON file; one content in two folders is two members;
//   READ-ONLY   — a read-only (viewer) session refuses folder edits with
//                 words and imports nothing;
//   BACKUP      — Back Up Catalog's sealed copy carries the folders.
// Scale lives in FolderLabelsScaleTests; media matrix: N/A (no media).
// Synthetic names only.
//
// Suites (filter by SUITE): EventsCatalogBackingTests

import Foundation
import SQLite3
import Testing
@testable import VideoScan
import VideoScanCore

private final class ReadOnlyBox {
    var words: String?
}

@MainActor
private struct FolderScene {
    let directory: URL
    let databaseURL: URL
    let repository: GRDBCatalogRepository
    let committer: CatalogCommitter
    let readOnly = ReadOnlyBox()
    var sink: [String] { lines.lines }
    private let lines = LineBox()

    final class LineBox { var lines: [String] = [] }

    static let shaA = String(repeating: "a", count: 64)
    static let shaB = String(repeating: "b", count: 64)
    static let shaC = String(repeating: "c", count: 64)
    static let shaNotStored = String(repeating: "d", count: 64)

    /// A fresh sandbox catalog.sqlite with three stored contents (a, b, c).
    static func make(_ tag: String) async throws -> FolderScene {
        let dir = try EventsFixture.scratchDirectory("folders-\(tag)")
        let url = dir.appendingPathComponent("catalog.sqlite")
        let first = GRDBCatalogRepository(host: "folders-test", durability: .volatileForTests)
        #expect(await first.open(at: url) == .readWrite)
        await first.close()
        try Self.exec(url, """
            INSERT INTO content (digest, byte_count, first_seen_at, first_seen_how) VALUES ('\(shaA)', 1, 1700000000, 'rescan');
            INSERT INTO content (digest, byte_count, first_seen_at, first_seen_how) VALUES ('\(shaB)', 1, 1700000000, 'rescan');
            INSERT INTO content (digest, byte_count, first_seen_at, first_seen_how) VALUES ('\(shaC)', 1, 1700000000, 'rescan');
            """)
        let repository = GRDBCatalogRepository(host: "folders-test", durability: .volatileForTests)
        #expect(await repository.open(at: url) == .readWrite)
        return FolderScene(directory: dir, databaseURL: url, repository: repository)
    }

    init(directory: URL, databaseURL: URL, repository: GRDBCatalogRepository) {
        self.directory = directory
        self.databaseURL = databaseURL
        self.repository = repository
        let box = readOnly
        let lines = self.lines
        committer = CatalogCommitter(repository: repository, storedDesignationJSON: nil, input: {
            CatalogCommitter.Input(records: [], designation: nil, clearAuthorized: false, holdReason: nil, holdOwner: nil,
                                   readOnlyReason: box.words)
        }, sink: { lines.lines.append($0) })
    }

    var jsonURL: URL { directory.appendingPathComponent(EventsDecisionStore.filename) }

    /// A store on this scene's folder, attached to the catalog, loaded.
    func attachedStore() async -> (EventsDecisionStore, EventsDecisionLoad) {
        let store = EventsDecisionStore(directory: directory)
        store.attachCatalog(EventsCatalogBacking(committer: committer))
        let loaded = await store.load()
        return (store, loaded)
    }

    func read() async -> EventsCatalogBacking.Read? {
        guard case .success(let read) = await EventsCatalogBacking(committer: committer).read() else { return nil }
        return read
    }

    func close() async {
        await repository.close()
        try? FileManager.default.removeItem(at: directory)
    }

    static func exec(_ url: URL, _ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw FolderSceneFailure(words: "sqlite3_open_v2 failed")
        }
        defer { sqlite3_close(db) }
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            let words = message.map { String(cString: $0) } ?? "?"
            sqlite3_free(message)
            throw FolderSceneFailure(words: "sqlite3_exec: \(words)")
        }
    }

    /// The real file's shape (storeVersion 1, savedAt, events, member
    /// decisions keyed by SHA-256), synthetic names, plus the hard cases.
    static let eventOne = "11111111-0000-0000-0000-000000000001"
    static let eventTwo = "11111111-0000-0000-0000-000000000002"
    static let eventThree = "11111111-0000-0000-0000-000000000003"
    static var copyShapedJSON: String {
        """
        {
          "decisions" : [
            { "eventID" : "\(eventOne)", "kind" : "member", "range" : { "contentKey" : "\(shaA)" }, "verdict" : "accepted" },
            { "eventID" : "\(eventOne)", "kind" : "member", "range" : { "contentKey" : "\(shaB)" }, "verdict" : "accepted" },
            { "eventID" : "\(eventTwo)", "kind" : "member", "range" : { "contentKey" : "\(shaA)" }, "verdict" : "accepted" },
            { "eventID" : "\(eventTwo)", "kind" : "member", "range" : { "contentKey" : "pair:22222222-0000-0000-0000-000000000009" }, "verdict" : "accepted" },
            { "eventID" : "\(eventThree)", "kind" : "member", "range" : { "contentKey" : "\(shaNotStored)" }, "verdict" : "accepted" },
            { "kind" : "fromANewerBuild", "anything" : [1, 2, 3] },
            42
          ],
          "events" : [
            { "categories" : [ "Thanksgiving" ], "createdAt" : "2026-10-19T16:43:30Z", "id" : "\(eventOne)", "name" : "Synthetic Thanksgiving 1990", "state" : "confirmed", "updatedAt" : "2026-10-19T16:43:30Z" },
            { "categories" : [ ], "createdAt" : "2026-10-19T17:00:00Z", "id" : "\(eventTwo)", "name" : "Synthetic Person", "state" : "confirmed", "updatedAt" : "2026-10-19T17:00:00Z" },
            { "categories" : [ "Christmas" ], "createdAt" : "2026-10-19T18:00:00Z", "id" : "\(eventThree)", "name" : "Synthetic Christmas", "state" : "confirmed", "updatedAt" : "2026-10-19T18:00:00Z" },
            { "id" : "not-a-uuid", "name" : 7 }
          ],
          "savedAt" : "2026-10-19T21:42:52Z",
          "storeVersion" : 1
        }
        """
    }
}

private struct FolderSceneFailure: Error, CustomStringConvertible {
    let words: String
    var description: String { words }
}

@MainActor
@Suite("Catalog folders in catalog.sqlite", .serialized)
struct EventsCatalogBackingTests {

    private typealias S = FolderScene

    // MARK: - Import

    @Test("IMPORT: a copy-shaped file lands whole — folders, decisions, damaged elements kept, counts verified, file untouched")
    func importCarriesEverythingAndVerifies() async throws {
        let scene = try await S.make("import")
        let bytes = Data(S.copyShapedJSON.utf8)
        try bytes.write(to: scene.jsonURL)
        let backing = EventsCatalogBacking(committer: scene.committer)
        var said: [String] = []
        let outcome = await backing.importJSONOnce(from: scene.jsonURL) { said.append($0) }
        // 5 members + the unknown kind + 2 unreadable (the damaged folder, the bare 42) + the marker.
        #expect(outcome == .imported(events: 3, newEvents: 3, decisions: 9, unreadable: 2, members: 3, verified: true))
        #expect(said.count == 1)
        #expect(said.first?.contains("verified (counts in = counts out)") == true)
        let read = try #require(await scene.read())
        #expect(read.counts.events == 3)
        #expect(read.counts.decisions == 9)
        // Stored digests only: a in One, b in One, a in Two — not the pair key, not the unstored digest.
        #expect(read.counts.members == 3)
        let unreadable = read.decisions.filter { $0.kind == EventDecision.unreadableKind }
        #expect(unreadable.count == 2)
        #expect(read.decisions.contains { $0.kind == "fromANewerBuild" }, "an unknown kind is kept verbatim")
        #expect(read.decisions.contains { if case .jsonImported = $0 { return true } else { return false } })
        #expect(try Data(contentsOf: scene.jsonURL) == bytes, "the JSON file is left byte for byte")
        await scene.close()
    }

    @Test("IDEMPOTENCE: a second attach imports nothing; a changed file is reconciled again, appending only its new marker when nothing else is new")
    func importIsIdempotent() async throws {
        let scene = try await S.make("idempotent")
        try Data(S.copyShapedJSON.utf8).write(to: scene.jsonURL)
        let backing = EventsCatalogBacking(committer: scene.committer)
        _ = await backing.importJSONOnce(from: scene.jsonURL) { _ in }
        let before = try #require(await scene.read()).counts
        let again = await backing.importJSONOnce(from: scene.jsonURL) { _ in }
        #expect(again == .alreadyImported(changedSince: false))
        #expect(try #require(await scene.read()).counts == before, "nothing new")
        try Data((S.copyShapedJSON + "\n").utf8).write(to: scene.jsonURL)
        let changed = await backing.importJSONOnce(from: scene.jsonURL) { _ in }
        #expect(changed == .imported(events: 3, newEvents: 0, decisions: 1, unreadable: 2, members: 3, verified: true))
        let after = try #require(await scene.read()).counts
        #expect(after.events == before.events && after.members == before.members)
        #expect(after.decisions == before.decisions + 1, "only the new marker: no decision, no unreadable element twice")
        let third = await backing.importJSONOnce(from: scene.jsonURL) { _ in }
        #expect(third == .alreadyImported(changedSince: false), "the newest marker names the file now")
        await scene.close()
    }

    @Test("RECONCILE (codex #113 P1-1): an older build's later rename in the JSON is written; a same-time difference is kept as catalog.sqlite has it and said as a FINDING — never silent")
    func changedFileIsReconciled() async throws {
        let scene = try await S.make("reconcile")
        try Data(S.copyShapedJSON.utf8).write(to: scene.jsonURL)
        let backing = EventsCatalogBacking(committer: scene.committer)
        _ = await backing.importJSONOnce(from: scene.jsonURL) { _ in }
        // The older build renames One an hour later and edits Three's name
        // without moving its updatedAt (a tie).
        let edited = S.copyShapedJSON
            .replacingOccurrences(of: "\"name\" : \"Synthetic Thanksgiving 1990\", \"state\" : \"confirmed\", \"updatedAt\" : \"2026-10-19T16:43:30Z\"",
                                  with: "\"name\" : \"Synthetic Thanksgiving 1991\", \"state\" : \"dismissed\", \"updatedAt\" : \"2026-10-19T19:00:00Z\"")
            .replacingOccurrences(of: "\"name\" : \"Synthetic Christmas\"", with: "\"name\" : \"Synthetic Xmas\"")
        #expect(edited != S.copyShapedJSON)
        try Data(edited.utf8).write(to: scene.jsonURL)
        var said: [String] = []
        let outcome = await backing.importJSONOnce(from: scene.jsonURL) { said.append($0) }
        #expect(outcome == .imported(events: 3, newEvents: 0, decisions: 1, unreadable: 2, members: 3, verified: true,
                                     updated: 1, conflicts: 1))
        let read = try #require(await scene.read())
        let one = try #require(read.events.first { $0.id.uuidString == S.eventOne })
        #expect(one.name == "Synthetic Thanksgiving 1991" && one.state == .dismissed, "the newer file row is written")
        let three = try #require(read.events.first { $0.id.uuidString == S.eventThree })
        #expect(three.name == "Synthetic Christmas", "a tie keeps catalog.sqlite's row")
        #expect(said.contains { $0.contains("reconciled “Synthetic Thanksgiving 1990”") && $0.contains("state confirmed → dismissed") })
        #expect(said.contains { $0.contains("FINDING — “Synthetic Christmas”") && $0.contains("catalog.sqlite's is kept") })
        await scene.close()
    }

    @Test("IMPORT: no file → nothing imported; the store loads empty and writable")
    func noFileImportsNothing() async throws {
        let scene = try await S.make("nofile")
        let (store, loaded) = await scene.attachedStore()
        #expect(loaded == .loaded)
        #expect(store.isWritable)
        #expect(store.eventCount == 0)
        await scene.close()
    }

    // MARK: - Persistence

    @Test("PERSISTENCE: every folder edit lands in catalog.sqlite and never in the JSON file")
    func editsPersistToTheCatalogOnly() async throws {
        let scene = try await S.make("edits")
        try Data(S.copyShapedJSON.utf8).write(to: scene.jsonURL)
        let bytes = try Data(contentsOf: scene.jsonURL)
        let (store, loaded) = await scene.attachedStore()
        #expect(loaded == .loaded)
        #expect(store.eventCount == 3, "the import's folders are loaded")
        let one = try #require(UUID(uuidString: S.eventOne)), two = try #require(UUID(uuidString: S.eventTwo))
        let made = try #require(store.confirm(name: "Synthetic Dad", categories: [], members: [ContentRange(contentKey: S.shaC)],
                                              kind: .person))
        #expect(store.addMembers([ContentRange(contentKey: S.shaC)], to: one))
        #expect(store.addMembers([ContentRange(contentKey: S.shaB)], to: two, movingFrom: [one: [ContentRange(contentKey: S.shaB)]]))
        #expect(store.removeMembers([ContentRange(contentKey: S.shaA)], from: two))
        #expect(store.renameEvent(made.id, to: "Synthetic Father"))
        #expect(store.setKind(one, .other))
        #expect(store.deleteFolder(two))

        // A fresh store on the same catalog sees exactly what memory holds.
        let (fresh, _) = await scene.attachedStore()
        #expect(fresh.snapshot().members(of: one).map(\.contentKey).sorted() == [S.shaA, S.shaC])
        #expect(fresh.snapshot().members(of: made.id).map(\.contentKey) == [S.shaC])
        #expect(fresh.event(id: made.id)?.name == "Synthetic Father")
        #expect(fresh.event(id: made.id)?.kind == .person)
        #expect(fresh.event(id: one)?.kind == .other)
        #expect(fresh.event(id: two)?.state == .dismissed, "Delete Folder dismisses the label")
        #expect(Set(fresh.snapshot().folders(containing: S.shaC)) == [one, made.id], "one content, two folders")
        let read = try #require(await scene.read())
        let edits = read.decisions.compactMap { d -> FolderEdit.Change? in if case .folderEdited(let e) = d { return e.change } else { return nil } }
        #expect(edits == [.renamed, .kindChanged, .deleted], "the stream keeps the label's history")
        #expect(try Data(contentsOf: scene.jsonURL) == bytes, "the JSON file is frozen")
        #expect(!FileManager.default.fileExists(atPath: scene.jsonURL.path + ".prev"), "and never rewritten")
        await scene.close()
    }

    // MARK: - Read-only

    @Test("READ-ONLY: a viewer / read-only session refuses folder edits with words and imports nothing")
    func readOnlySessionRefuses() async throws {
        let scene = try await S.make("readonly")
        try Data(S.copyShapedJSON.utf8).write(to: scene.jsonURL)
        scene.readOnly.words = CatalogReadOnlyFacts(viewerRole: true).readOnlyWords
        let (store, _) = await scene.attachedStore()
        #expect(store.eventCount == 0, "nothing imported")
        let refusal = try #require(store.writeRefusal)
        #expect(refusal.contains("read-only"))
        #expect(refusal.contains("viewer"))
        #expect(store.confirm(name: "Nope", categories: [], members: [ContentRange(contentKey: S.shaA)]) == nil)
        #expect(try #require(await scene.read()).counts.events == 0, "nothing was written")
        await scene.close()
    }

    // MARK: - Backup

    @Test("BACKUP: Back Up Catalog's sealed catalog.sqlite carries the folders")
    func aSealedBackupContainsTheFolders() async throws {
        let scene = try await S.make("backup")
        let (store, _) = await scene.attachedStore()
        let dad = try #require(store.confirm(name: "Synthetic Dad", categories: [], members: [ContentRange(contentKey: S.shaA)], kind: .person))
        _ = try #require(store.confirm(name: "Synthetic Beach 1988", categories: [],
                                       members: [ContentRange(contentKey: S.shaA), ContentRange(contentKey: S.shaB)]))
        let latch = scene.directory.appendingPathComponent(CatalogAuthority.latchFileName)
        try Data("switched".utf8).write(to: latch)
        let bundle = scene.directory.appendingPathComponent("Backup.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        _ = try await CatalogBackupSeal.seal(.init(repository: scene.repository, databaseURL: scene.databaseURL, latchURL: latch),
                                             into: bundle)
        let sealed = GRDBCatalogRepository(host: "folders-test", durability: .volatileForTests)
        let opened = await sealed.openReadOnly(at: bundle.appendingPathComponent("catalog.sqlite"), reason: "test: the bundle")
        if case .refused(let why) = opened { Issue.record("the sealed copy would not open: \(why)") }
        let read = try await sealed.read { reader -> (CatalogRow.FolderCounts, [CatalogRow.Folder]) in
            var rows: [CatalogRow.Folder] = []
            try reader.folderRows { rows.append($0) }
            return (try reader.folderCounts(), rows)
        }
        #expect(read.0.events == 2)
        #expect(read.0.members == 3)
        #expect(read.1.first { $0.eventID == dad.id.uuidString }?.kind == "person")
        await sealed.close()
        await scene.close()
    }
}
