// CatalogCutoverReadSideTests.swift
// Cutover B1 — the READ SIDE and the flip (docs/design/
// catalog_cutover_f_prime_2026_10_17.md §2, §7, §8), five dimensions + TRUTH:
//   LOGIC + TRUTH  the app loads the SAME records from catalog.sqlite that it
//                  loads from catalog.json: the poisoned fixture is loaded
//                  both ways (CatalogStore.load and, after CatalogImporter,
//                  SQLiteCatalogLoader.load) and every SQLite record's DTO
//                  equals the JSON record's, class for class, except the two
//                  documented losses (pair confidence; copies in conflict
//                  show the field EMPTY); quarantined rows are not records;
//                  display strings are the scan's formatters.
//   ISOLATION      the flip is inert without the latch (an imported
//                  catalog.sqlite beside the catalog is not even opened);
//                  latch + a store that is missing / will not open / holds no
//                  comparator-ok import → refused words and catalog.json
//                  READ-ONLY; latch + a good store → SQLite. Every case runs
//                  on a sandbox folder, never Application Support.
//   P0 TRUTH       the P0 suite's fixture catalog through import → load: the
//                  rows that land keep every fact the P0 surfaces read, and
//                  the File Journey's first event says the same words; the
//                  rows the P0 tests are about that cannot prove their bytes
//                  are quarantined, never records. (The P0 suite itself is
//                  bound to its sandbox model's in-memory rows, so it cannot
//                  be re-run against a second store unchanged — this is the
//                  focused equivalent.)
//   SCALE          covered in Core (CatalogLoadScaleTests: 100k rows);
//                  nothing here iterates more than the fixture.
//   MEDIA          N/A — no media is opened.
//
// Suites (filter by SUITE): SQLiteCatalogLoaderTests · CatalogAuthorityFlipTests ·
// P0TruthThroughSQLiteTests

import CryptoKit
import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

// MARK: - The scene: a sandbox catalog folder holding the poisoned fixture

@MainActor
struct CutoverScene {
    let sandbox: ShowAgainSandbox
    let fixture = PoisonedCatalogFixture()

    var model: VideoScanModel { sandbox.model }
    var catalogURL: URL { URL(fileURLWithPath: sandbox.model.catalogStore.fileLocation) }
    var folder: URL { catalogURL.deletingLastPathComponent() }
    var databaseURL: URL { folder.appendingPathComponent(CatalogAuthority.databaseFileName) }
    var latchURL: URL { folder.appendingPathComponent(CatalogAuthority.latchFileName) }

    static func make(_ label: String) throws -> CutoverScene {
        let scene = CutoverScene(sandbox: try ShowAgainSandbox.make("cutover_\(label)"))
        try FileManager.default.createDirectory(at: scene.folder, withIntermediateDirectories: true)
        for (name, data) in scene.fixture.files {
            try data.write(to: scene.folder.appendingPathComponent(name), options: .atomic)
        }
        return scene
    }

    func cleanup() { sandbox.cleanup() }

    /// A real import (commit) into catalog.sqlite beside the catalog.
    func importCatalog() async throws {
        let inputs = CatalogImporter.Inputs.beside(catalogURL: catalogURL, databaseFolder: folder)
        let importer = CatalogImporter(repository: GRDBCatalogRepository(host: "cutover-test")) { _ in }
        let outcome = await importer.run(inputs, mode: .commit)
        guard case .imported = outcome else { throw CutoverFailure(words: "import: \(outcome)") }
    }

    func writeLatch() throws { try Data("switched\n".utf8).write(to: latchURL) }

    func sqliteLoad() async throws -> SQLiteCatalogLoader.LoadResult {
        try await Self.load(databaseURL)
    }

    /// Open, load, close — the close awaited on every path.
    static func load(_ url: URL) async throws -> SQLiteCatalogLoader.LoadResult {
        let repository = GRDBCatalogRepository(host: "cutover-test")
        _ = await repository.open(at: url)
        do {
            let result = try await SQLiteCatalogLoader.load(repository: repository)
            await repository.close()
            return result
        } catch {
            await repository.close()
            throw error
        }
    }

    func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
}

struct CutoverFailure: Error, CustomStringConvertible {
    let words: String
    var description: String { words }
}

/// The DTO with what the contract does not keep set aside (raw evidence,
/// probe-extra members at their default, the import's migration flag) and
/// set-like arrays as sets — the Core round-trip sensor's rule (LoadTestSupport).
enum CutoverKept {
    static func normalized(_ d: CatalogRecordDTO) -> CatalogRecordDTO {
        var k = d
        k.raw = [:]
        k.undecodable = []
        k.file.probeExtra = k.file.probeExtra.filter { !isDefault($0.value) }
        k.removal?.migrated = false
        k.legacyPairIDs = nil
        k.curated.tags.sort()
        k.curated.people.sort { ($0.kind.rawValue, $0.name) < ($1.kind.rawValue, $1.name) }
        return k
    }

    /// The same, with the two fields in conflict (stars, user date) and
    /// their evidence lists set aside (rows whose copies disagree).
    static func withoutConflict(_ d: CatalogRecordDTO) -> CatalogRecordDTO {
        var k = normalized(d)
        k.curated.starRating = nil
        k.curated.userDate = nil
        k.curatedFields = []
        k.knowledgeSources = []
        return k
    }

    private static func isDefault(_ v: CatalogJSONValue) -> Bool {
        switch v {
        case .string(let s): return s.isEmpty
        case .int(let i): return i == 0
        case .double(let x): return x == 0
        case .bool(let b): return !b
        case .null: return true
        default: return false
        }
    }
}

// MARK: - LOGIC + TRUTH: JSON load vs SQLite load

@Suite("SQLite catalog loader — the same records catalog.json gives", .serialized)
@MainActor
struct SQLiteCatalogLoaderTests {

    typealias Shape = PoisonedCatalogFixture.Shape

    @Test("TRUTH: every record loaded from catalog.sqlite has the DTO of the same row loaded from catalog.json")
    func sqliteRecordsEqualJSONRecords() async throws {
        let scene = try CutoverScene.make("equal"); defer { scene.cleanup() }
        let json = CatalogStore(directory: scene.folder).load()
        try await scene.importCatalog()
        let sqlite = try await scene.sqliteLoad()
        let byID = Dictionary(uniqueKeysWithValues: json.map { ($0.id, $0) })
        let compared = sqlite.records.filter { ![Shape.curatedConflictA, .curatedConflictB].map(PoisonedCatalogFixture.id).contains($0.id.uuidString) }
        #expect(compared.count == 3)
        for record in compared {
            let twin = try #require(byID[record.id])
            let a = CutoverKept.normalized(try CatalogRecordDTO(record: twin, migrationLoadedAt: 0))
            let b = CutoverKept.normalized(try CatalogRecordDTO(record: record, migrationLoadedAt: 0))
            #expect(a == b, Comment(rawValue: record.filename))
        }
    }

    @Test("quarantined rows are not records; the counts say how many wait, and how many values are from before the port")
    func quarantineAndCounts() async throws {
        let scene = try CutoverScene.make("counts"); defer { scene.cleanup() }
        try await scene.importCatalog()
        let result = try await scene.sqliteLoad()
        #expect(result.records.count == 5)
        #expect(result.quarantineCount == 12)
        #expect(result.conflictCount == 2)
        #expect(result.unverifiedCount == 0, "the fixture's main rows carry no derived values")
        #expect(result.summary.hasPrefix("5 records from catalog.sqlite"), Comment(rawValue: result.summary))
    }

    @Test("two copies that disagree load with stars and date EMPTY; everything else matches the JSON load")
    func conflictCopiesLoadEmpty() async throws {
        let scene = try CutoverScene.make("conflict"); defer { scene.cleanup() }
        let json = CatalogStore(directory: scene.folder).load()
        try await scene.importCatalog()
        let sqlite = try await scene.sqliteLoad()
        for shape in [Shape.curatedConflictA, .curatedConflictB] {
            let id = PoisonedCatalogFixture.id(shape)
            let record = try #require(sqlite.records.first { $0.id.uuidString == id })
            let twin = try #require(json.first { $0.id.uuidString == id })
            #expect(twin.starRating > 0, "catalog.json shows a star on each copy")
            #expect(record.starRating == 0)
            #expect(record.userDate == nil)
            let a = CutoverKept.withoutConflict(try CatalogRecordDTO(record: twin, migrationLoadedAt: 0))
            let b = CutoverKept.withoutConflict(try CatalogRecordDTO(record: record, migrationLoadedAt: 0))
            #expect(a == b, Comment(rawValue: shape.rawValue))
        }
    }

    @Test("the display copies are the scan's formatters; the pair state matches the JSON load's")
    func displayStringsAndPairs() async throws {
        let scene = try CutoverScene.make("display"); defer { scene.cleanup() }
        let json = CatalogStore(directory: scene.folder).load()
        try await scene.importCatalog()
        let sqlite = try await scene.sqliteLoad()
        let healthy = try #require(sqlite.records.first { $0.id.uuidString == PoisonedCatalogFixture.id(.healthy) })
        #expect(healthy.size == Formatting.humanSize(PoisonedCatalogFixture.sizeBytes))
        #expect(healthy.duration.isEmpty, "no duration in the row → no duration text")
        let stale = try #require(sqlite.records.first { $0.id.uuidString == PoisonedCatalogFixture.id(.stalePrint) })
        let staleJSON = try #require(json.first { $0.id == stale.id })
        #expect(stale.pairedWith?.id == staleJSON.pairedWith?.id)
        #expect(stale.pairGroupID == staleJSON.pairGroupID)
    }
}

// MARK: - ISOLATION: the flip

@Suite("Catalog authority flip — inert without the latch; refused words make catalog.json read-only", .serialized)
@MainActor
struct CatalogAuthorityFlipTests {

    @Test("no latch, no database → JSON")
    func nothingIsJSON() async throws {
        let scene = try CutoverScene.make("flip_none"); defer { scene.cleanup() }
        #expect(await CatalogAuthority.decide(folder: scene.folder) == .json)
    }

    @Test("ISOLATION: an imported catalog.sqlite WITHOUT the latch → JSON, and the database is not even opened (bytes unchanged)")
    func databaseWithoutLatchIsInert() async throws {
        let scene = try CutoverScene.make("flip_inert"); defer { scene.cleanup() }
        try await scene.importCatalog()
        let before = try scene.sha256(scene.databaseURL)
        // Unreadable: any attempt to open it would answer `.refused`, not `.json`.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: scene.databaseURL.path)
        let authority = await CatalogAuthority.decide(folder: scene.folder)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: scene.databaseURL.path)
        #expect(authority == .json)
        #expect(try scene.sha256(scene.databaseURL) == before)
    }

    @Test("latch without the database → refused, in words")
    func latchWithoutDatabaseRefuses() async throws {
        let scene = try CutoverScene.make("flip_nodb"); defer { scene.cleanup() }
        try scene.writeLatch()
        guard case .refused(let words) = await CatalogAuthority.decide(folder: scene.folder) else { Issue.record("expected refused"); return }
        #expect(words.contains("catalog.sqlite is not beside it"), Comment(rawValue: words))
    }

    @Test("latch + a database with no finished, comparator-ok import → refused, in words")
    func latchWithUnfinishedImportRefuses() async throws {
        let scene = try CutoverScene.make("flip_empty"); defer { scene.cleanup() }
        let repository = GRDBCatalogRepository(host: "cutover-test")
        _ = await repository.open(at: scene.databaseURL)        // a store with no import at all
        await repository.close()
        try scene.writeLatch()
        guard case .refused(let words) = await CatalogAuthority.decide(folder: scene.folder) else { Issue.record("expected refused"); return }
        #expect(words.contains("no finished import checked by the comparator"), Comment(rawValue: words))
    }

    @Test("latch + a database that will not open → refused with the store's words")
    func latchWithDamagedDatabaseRefuses() async throws {
        let scene = try CutoverScene.make("flip_damaged"); defer { scene.cleanup() }
        try Data("not a database".utf8).write(to: scene.databaseURL)
        try scene.writeLatch()
        guard case .refused(let words) = await CatalogAuthority.decide(folder: scene.folder) else { Issue.record("expected refused"); return }
        #expect(words.contains("would not open"), Comment(rawValue: words))
    }

    @Test("latch + a comparator-ok import → SQLite")
    func latchWithGoodImportIsSQLite() async throws {
        let scene = try CutoverScene.make("flip_good"); defer { scene.cleanup() }
        try await scene.importCatalog()
        try scene.writeLatch()
        #expect(await CatalogAuthority.decide(folder: scene.folder) == .sqlite(scene.databaseURL))
    }

    @Test("model: no latch → the JSON records, nothing read-only")
    func modelLoadsJSONWithoutLatch() async throws {
        let scene = try CutoverScene.make("model_json"); defer { scene.cleanup() }
        try await scene.importCatalog()
        let expected = CatalogStore(directory: scene.folder).load().count
        let records = scene.model.loadCatalogAtLaunch()
        #expect(records.count == expected)
        #expect(scene.model.catalogStore.isReadOnly == false)
        #expect(scene.model.isReadOnly == false)
    }

    @Test("model: latch but the import is not comparator-ok → the JSON records, READ-ONLY, the words in catalog.log; catalog.json untouched")
    func modelRefusedIsJSONReadOnly() async throws {
        let scene = try CutoverScene.make("model_refused"); defer { scene.cleanup() }
        let repository = GRDBCatalogRepository(host: "cutover-test")
        _ = await repository.open(at: scene.databaseURL)
        await repository.close()
        try scene.writeLatch()
        let expected = CatalogStore(directory: scene.folder).load().count
        let before = try scene.sha256(scene.catalogURL)
        let records = scene.model.loadCatalogAtLaunch()
        #expect(records.count == expected)
        #expect(scene.model.catalogStore.isReadOnly)
        #expect(scene.model.isReadOnly)
        #expect(scene.sandbox.catalogLogText().contains("SQLite catalog refused — catalog.sqlite holds no finished import"))
        #expect(scene.sandbox.catalogLogText().contains("catalog.json is open READ-ONLY"))
        #expect(try scene.sha256(scene.catalogURL) == before)
    }

    @Test("model: latch + a good import → the SQLite records; catalog.json frozen; the OUTCOME line names the counts")
    func modelLoadsSQLiteWithLatch() async throws {
        let scene = try CutoverScene.make("model_sqlite"); defer { scene.cleanup() }
        try await scene.importCatalog()
        try scene.writeLatch()
        let records = scene.model.loadCatalogAtLaunch()
        #expect(records.count == 5)
        #expect(scene.model.catalogStore.isReadOnly)
        #expect(scene.sandbox.catalogLogText().contains("OUTCOME loaded 5 records from catalog.sqlite"))
    }

    @Test("source sensor: the init's one seam; no GRDB import in the app")
    func theSeamIsOneLine() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let model = try String(contentsOf: root.appendingPathComponent("VideoScan/Model/VideoScanModel.swift"), encoding: .utf8)
        #expect(model.contains("let restored = loadCatalogAtLaunch()"))
        #expect(!model.contains("let restored = catalogStore.load()"))
        let flip = try String(contentsOf: root.appendingPathComponent("VideoScan/Catalog/CatalogAuthorityFlip.swift"), encoding: .utf8)
        #expect(!flip.contains("import " + "GRDB"))
        #expect(!flip.contains("write(as:"), "the flip never writes the store")
    }
}

// MARK: - P0 TRUTH through SQLite (the focused equivalent)

@Suite("P0 truth through SQLite — the P0 fixture imported and loaded keeps what the surfaces read", .serialized)
@MainActor
struct P0TruthThroughSQLiteTests {

    /// The P0 fixture catalog as catalog.json + the gate files, in the
    /// sandbox's catalog folder: rows whose bytes are on disk get a
    /// whole-file fixity and an audit stamp (what Fill In Full Hashes and
    /// Audit Catalog give them); the dead link, the missing pair and the
    /// sampled-only pair get neither — the shapes the P0 tests are about.
    private static func writeImportable(_ catalog: P0TruthFixtureCatalog) throws -> URL {
        let folder = URL(fileURLWithPath: catalog.model.catalogStore.fileLocation).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fixture = PoisonedCatalogFixture()
        let seen = Date(timeIntervalSince1970: TimeInterval(PoisonedCatalogFixture.seenAt))
        var auditRows: [AuditMarkerJSON.Row] = []
        for record in catalog.model.records {
            record.scanContext.volumeUUID = PoisonedCatalogFixture.volumeUUID
            guard record.contentHash.isEmpty, FileManager.default.fileExists(atPath: record.fullPath),
                  let digest = P0TruthFixtureCatalog.sha256(ofFile: record.fullPath) else { continue }
            var st = stat()
            guard stat(record.fullPath, &st) == 0 else { continue }
            let stamp = FileIdentityStamp(device: UInt64(st.st_dev), inode: UInt64(st.st_ino), size: Int64(st.st_size),
                                          mtimeNs: Int64(st.st_mtimespec.tv_sec) * 1_000_000_000, ctimeNs: Int64(st.st_ctimespec.tv_sec) * 1_000_000_000)
            record.contentFixity = ContentFixity(digest: digest, byteCount: record.sizeBytes, stamp: stamp, computedAt: seen.addingTimeInterval(-86_400))
            record.auditSeenOn = AuditSeenOn(volumeUUID: PoisonedCatalogFixture.volumeUUID, mountFrom: "/dev/disk9s1", seenAt: seen)
            auditRows.append(.init(id: record.id.uuidString, result: "present"))
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let rows = try catalog.model.records.map { try JSONDecoder().decode(CatalogJSONValue.self, from: encoder.encode(VideoRecordDTO($0))) }
        let catalogBytes = try CatalogJSONValue.makeEncoder().encode(CatalogJSONValue.object([
            "version": .int(6), "generation": .int(Int64(PoisonedCatalogFixture.generation)), "savedFromHost": .string("FixtureHost"),
            "records": .array(rows),
        ]))
        try catalogBytes.write(to: folder.appendingPathComponent("catalog.json"))
        var marker = try AuditMarkerJSON.decode(fixture.auditData)
        marker.rows = auditRows
        marker.counts = ["present": auditRows.count]
        try CatalogJSONValue.makeEncoder().encode(marker).write(to: folder.appendingPathComponent(PoisonedCatalogFixture.auditFileName))
        var report = try IntegrityReportJSON.decode(fixture.integrityData)
        report.catalogSHA256 = SHA256.hash(data: catalogBytes).map { String(format: "%02x", $0) }.joined()
        report.catalogByteCount = Int64(catalogBytes.count)
        report.rowsTotal = rows.count
        report.rowsLive = rows.count
        report.findings = []
        report.findingsTotal = 0
        report.tiers = report.tiers.map { var t = $0; t.result = .init(kind: "ok"); t.needsDecision = 0; return t }
        try CatalogJSONValue.makeEncoder().encode(report).write(to: folder.appendingPathComponent(PoisonedCatalogFixture.integrityFileName))
        return folder
    }

    private static func importAndLoad(_ catalog: P0TruthFixtureCatalog) async throws -> SQLiteCatalogLoader.LoadResult {
        let folder = try writeImportable(catalog)
        let catalogURL = folder.appendingPathComponent("catalog.json")
        let inputs = CatalogImporter.Inputs(catalogURL: catalogURL,
                                            integrityURL: folder.appendingPathComponent(PoisonedCatalogFixture.integrityFileName),
                                            auditURL: folder.appendingPathComponent(PoisonedCatalogFixture.auditFileName),
                                            databaseURL: folder.appendingPathComponent(CatalogAuthority.databaseFileName))
        let importer = CatalogImporter(repository: GRDBCatalogRepository(host: "p0")) { _ in }
        let outcome = await importer.run(inputs, mode: .commit)
        guard case .imported = outcome else { throw CutoverFailure(words: "import: \(outcome)") }
        return try await CutoverScene.load(inputs.databaseURL)
    }

    /// The facts the seven P0 surfaces read off a row.
    private static func facts(_ r: VideoRecord) -> [String] {
        [r.fullPath, r.filename, r.streamTypeRaw, r.videoCodec, r.audioCodec, "\(r.durationSeconds)", "\(r.sizeBytes)",
         r.contentHash, r.archiveStage.rawValue, r.notes, "\(String(describing: r.dateModifiedRaw))",
         "\(String(describing: r.scanContext.scannedAt))", "\(String(describing: r.derivedFrom))", r.derivationKind ?? "",
         r.archiveFixity?.digest ?? "", r.contentFixity?.digest ?? ""]
    }

    @Test("P0 TRUTH: every P0 row that lands keeps every fact the P0 surfaces read")
    func landedRowsKeepTheirFacts() async throws {
        let catalog = try P0TruthFixtureCatalog.build("sqlite_facts")
        defer { catalog.cleanup() }
        let loaded = try await Self.importAndLoad(catalog)
        let before = Dictionary(uniqueKeysWithValues: catalog.model.records.map { ($0.id, Self.facts($0)) })
        #expect(loaded.records.count == 7, "the 12 rows less the dead link, the sampled pair and the missing pair")
        for record in loaded.records {
            #expect(Self.facts(record) == before[record.id], Comment(rawValue: record.filename))
        }
    }

    @Test("P0 TRUTH: the rows that cannot prove their bytes (dead link, sampled-only pair, missing pair) are quarantined — never records")
    func unprovenRowsAreNotRecords() async throws {
        let catalog = try P0TruthFixtureCatalog.build("sqlite_quarantine")
        defer { catalog.cleanup() }
        let loaded = try await Self.importAndLoad(catalog)
        let ids = Set(loaded.records.map(\.id))
        for kind in [P0TruthRowKind.deadLinkSource, .sampledOnlyA, .sampledOnlyB, .sourceWithoutCopy, .sourceWithoutCopyArchivedCopy] {
            #expect(!ids.contains(try catalog.require(kind).id), Comment(rawValue: kind.rawValue))
        }
        #expect(loaded.quarantineCount == 5)
    }

    @Test("P0 TRUTH (File Journey): the mtime row's first event says the same words loaded from SQLite — the file's own date, never 'Scanned on'")
    func journeyWordsAreUnchanged() async throws {
        let catalog = try P0TruthFixtureCatalog.build("sqlite_journey")
        defer { catalog.cleanup() }
        let row = try catalog.require(.mtimeYearsBeforeCatalogue)
        let jsonFirst = VideoScanModel.buildFileJourney(for: row, allRecords: catalog.model.records,
                                                        resolveVolumeSafety: { _ in VolumeSafety.unknown }).events.first?.sentence
        let loaded = try await Self.importAndLoad(catalog)
        let back = try #require(loaded.records.first { $0.id == row.id })
        let sqliteFirst = VideoScanModel.buildFileJourney(for: back, allRecords: loaded.records,
                                                          resolveVolumeSafety: { _ in VolumeSafety.unknown }).events.first?.sentence
        #expect(sqliteFirst == jsonFirst)
        #expect(sqliteFirst?.hasPrefix("File dated") == true, Comment(rawValue: sqliteFirst ?? "nil"))
    }

    @Test("P0 (Sound): a v1:-keyed sound stamp does not survive the import (contract §b: the next Fingerprint Sound run redoes it) — pinned")
    func aSampledSoundStampIsNotImported() async throws {
        let catalog = try P0TruthFixtureCatalog.build("sqlite_sound")
        defer { catalog.cleanup() }
        let silent = try catalog.require(.silentHeader)
        #expect(silent.audioFingerprint != nil, "catalog.json carries the v1: stamp")
        let loaded = try await Self.importAndLoad(catalog)
        let back = try #require(loaded.records.first { $0.id == silent.id })
        #expect(back.audioFingerprint == nil, "no stamp, not a 'has sound' stamp: the surface asks for a run")
    }
}
