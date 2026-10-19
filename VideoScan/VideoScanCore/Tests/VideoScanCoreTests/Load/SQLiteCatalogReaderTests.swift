// SQLiteCatalogReaderTests.swift
// The non-writer processes' catalog door (2026-10-19, cutover audit gap 3):
// the preview helper and the Hallie shell read catalog.sqlite READ-ONLY.
//   * no `catalog.cutover` beside the file ⇒ refused with words, and the
//     frozen catalog.json beside it is never read as a fallback;
//   * a catalog.json path ⇒ refused;
//   * with the latch: the same records the app's load builds, and the read
//     leaves the database, its WAL and the high-water sidecar untouched
//     (ISOLATION: a reader must never be a writer);
//   * `openForReading` refuses every write;
//   * the preview source plans from it exactly as the shared rule says.
//
// Suite (filter by SUITE): SQLiteCatalogReaderTests

import Foundation
import Testing
@testable import VideoScanCore

@Suite("SQLiteCatalogReader — catalog.sqlite read-only for the helper and the shell", .serialized)
struct SQLiteCatalogReaderTests {

    /// An imported fixture, loaded once by the app's path (display pass done).
    private static func scene() async throws -> (ImporterScene, LoadedCatalog) {
        let scene = try ImporterScene.make()
        let run = await scene.run()
        _ = try #require(run.outcome.reconciliation, Comment(rawValue: "\(run.outcome)"))
        return (scene, try await LoadedCatalog.load(scene))
    }

    private static func writeLatch(_ scene: ImporterScene) throws {
        let latch = scene.databaseFolder.appendingPathComponent(SQLiteCatalogReader.latchFileName)
        try Data("{}".utf8).write(to: latch)
    }

    /// Bytes + mtime of every file in the database folder except the WAL
    /// index (`-shm`): that is SQLite's shared memory, where every reader —
    /// read-only ones too — takes a read-lock slot. It holds no catalog data.
    private static func folderState(_ folder: URL) throws -> [String: Data] {
        var state: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where !name.hasSuffix("-shm") {
            let url = folder.appendingPathComponent(name)
            let mtime = (try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)?
                .timeIntervalSince1970 ?? 0
            state[name] = try Data(contentsOf: url) + Data("\(mtime)".utf8)
        }
        return state
    }

    @Test("no catalog.cutover: refused with words that name it, and catalog.json is not read")
    func refusedWithoutLatch() async throws {
        let (scene, _) = try await Self.scene(); defer { scene.remove() }
        // A catalog.json beside the database must not rescue the read.
        try Data("{\"records\":[]}".utf8).write(to: scene.databaseFolder.appendingPathComponent("catalog.json"))
        let result = await SQLiteCatalogReader.load(databaseURL: scene.databaseURL)
        guard case .failure(let failure) = result else {
            Issue.record("a catalog without catalog.cutover was read")
            return
        }
        #expect(failure.words.contains(SQLiteCatalogReader.latchFileName))
        #expect(failure.words.contains("not read as a fallback"))
    }

    @Test("a catalog.json path is refused, even with the latch beside it")
    func jsonPathRefused() async throws {
        let (scene, _) = try await Self.scene(); defer { scene.remove() }
        try Self.writeLatch(scene)
        let json = scene.databaseFolder.appendingPathComponent("catalog.json")
        try Data("{\"records\":[]}".utf8).write(to: json)
        #expect(SQLiteCatalogReader.preflight(databaseURL: json)?.words.contains("frozen") == true)
    }

    @Test("latch present but no catalog.sqlite: refused")
    func missingDatabaseRefused() throws {
        let folder = try StoreFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("{}".utf8).write(to: folder.appendingPathComponent(SQLiteCatalogReader.latchFileName))
        let words = SQLiteCatalogReader.preflight(databaseURL: folder.appendingPathComponent("catalog.sqlite"))?.words
        #expect(words?.contains("there is no catalog.sqlite") == true)
    }

    @Test("with the latch: the app's records, and the folder is byte-for-byte untouched")
    func readsTheAppsRecordsReadOnly() async throws {
        let (scene, app) = try await Self.scene(); defer { scene.remove() }
        try Self.writeLatch(scene)
        let before = try Self.folderState(scene.databaseFolder)

        let loaded = try await SQLiteCatalogReader.load(databaseURL: scene.databaseURL).get()

        let after = try Self.folderState(scene.databaseFolder)
        let changed = Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }.sorted()
        #expect(changed.isEmpty, "a reader wrote into the catalog folder: \(changed) before=\(before.keys.sorted())")
        #expect(Set(loaded.records.map(\.id.uuidString)) == Set(app.records.keys))
        #expect(loaded.generation == app.snapshot.generation)
        #expect(loaded.unreadable == 0)
        for record in loaded.records {
            let theirs = try #require(app.records[record.id.uuidString])
            #expect(record.fullPath == theirs.fullPath)
            #expect(record.streamTypeRaw == theirs.streamTypeRaw)
            #expect(record.starRating == theirs.starRating)
            #expect(record.durationSeconds == theirs.durationSeconds)
        }
    }

    @Test("openForReading: the outcome is read-only and a write is refused")
    func openForReadingRefusesWrites() async throws {
        let (scene, _) = try await Self.scene(); defer { scene.remove() }
        let repository = GRDBCatalogRepository(host: "reader-test", durability: .volatileForTests)
        let opened = await repository.openForReading(at: scene.databaseURL)
        #expect(opened == .readOnly(reason: GRDBCatalogRepository.readerOnlyWords))
        let outcome = await repository.write(as: .ui) { _ in }
        if case .committed = outcome { Issue.record("a reading-only open committed a write") }
        await repository.close()
    }

    @Test("openForReading: a missing file is refused, and nothing is created")
    func openForReadingMissingFile() async throws {
        let folder = try StoreFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("catalog.sqlite")
        let opened = await GRDBCatalogRepository().openForReading(at: url)
        guard case .refused = opened else {
            Issue.record("opened a missing file: \(opened)")
            return
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test("the preview source plans from catalog.sqlite with the shared rule")
    func previewSourcePlansFromSQLite() async throws {
        let (scene, app) = try await Self.scene(); defer { scene.remove() }
        try Self.writeLatch(scene)
        let source = SQLiteCatalogSource(databaseURL: scene.databaseURL, isReachable: { _ in true })
        let planned = await source.eligibleCandidates().map(\.path).sorted()
        let expected = previewSweepCandidates(from: Array(app.records.values), isReachable: { _ in true })
            .map(\.path).sorted()
        #expect(planned == expected)
    }

    @Test("the preview source without the latch plans nothing and says why")
    func previewSourceWithoutLatch() async throws {
        let (scene, _) = try await Self.scene(); defer { scene.remove() }
        let said = SinkLines()
        let source = SQLiteCatalogSource(databaseURL: scene.databaseURL, isReachable: { _ in true },
                                         report: { said.append($0) })
        #expect(await source.eligibleCandidates().isEmpty)
        #expect(said.lines.contains { $0.contains(SQLiteCatalogReader.latchFileName) })
    }

    @Test("the watcher's freshness file is the high-water sidecar beside the database")
    func freshnessIsTheHighWater() {
        let db = URL(fileURLWithPath: "/x/VideoScan/catalog.sqlite")
        #expect(SQLiteCatalogReader.freshnessURL(databaseURL: db).path == "/x/VideoScan/catalog.highwater")
        #expect(PreviewSweepCLIOptions.defaultCatalogURL().lastPathComponent == "catalog.sqlite")
    }
}
