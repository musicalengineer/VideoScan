// CatalogDatabaseInfoTests.swift — Catalog ▸ Catalog Database Info…, the app
// half (rule 8; the Core half — the SQLite read at 100k rows, the 13 → 14
// migration, the layout diff — is CatalogDatabaseInfoReaderTests):
//   LOGIC     — the row builder on fixture values: order, words, and the
//               "unknown — <why>" wording for every missing source;
//   ISOLATION — poisoned folders through the real gather: no database, a
//               garbage integrity-latest.json, a missing -wal, a catalog_state
//               with no row, a journal folder that is not there → "unknown"
//               rows, no crash, no catalog.sqlite created;
//   TRUTH     — the Schema row equals PRAGMA user_version and
//               catalog_state.schema_version of a real store (read here with
//               the C API, not through the code under test); Generation and
//               Last commit are the store's own.
// The sensor (no model extension, no write door) is CatalogDatabaseInfoSensorTests.

import Foundation
import SQLite3
import Testing
import VideoScanCore
@testable import VideoScan

@Suite("CatalogDatabaseInfo")
struct CatalogDatabaseInfoTests {

    // MARK: Fixtures

    private final class Folder {
        let url: URL
        init() throws {
            url = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-db-info-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: url) }
        var database: URL { url.appendingPathComponent("catalog.sqlite") }
        var catalogFile: URL { url.appendingPathComponent("catalog.json") }
        var journal: URL { url.appendingPathComponent("background/journal", isDirectory: true) }
    }

    private static func sources(_ f: Folder, role: CatalogSyncMode? = .master, suite: String? = nil) -> CatalogDatabaseInfoSources {
        CatalogDatabaseInfoSources(databaseURL: f.database, databaseOpenThisSession: true, catalogFile: f.catalogFile,
                                   journalFolder: f.journal, lastSyncFile: f.url.appendingPathComponent("last_sync.txt"),
                                   sessionRole: role, localHostname: "RicksUltra", masterHostname: "RicksM4.local",
                                   defaultsSuite: suite ?? "catalog-db-info-empty-\(UUID().uuidString)")
    }

    private static let fixedDate: @Sendable (Date) -> String = { "D\(Int($0.timeIntervalSince1970))" }

    private static func snapshot(_ database: CatalogDatabaseFacts, role: CatalogSyncMode? = .master,
                                 integrity: CatalogIntegrityVerdict = CatalogIntegrityVerdict(facts: IntegrityReportFacts(), missing: true),
                                 backup: CatalogBackupFacts = CatalogBackupFacts(),
                                 lastSync: CatalogDatabaseReading<Date> = .unknown("no last_sync.txt"),
                                 journal: CatalogDatabaseReading<JournalApplier.Counts> = .known(JournalApplier.Counts(waiting: 3, refused: 1)),
                                 sizes: CatalogDatabaseReading<CatalogFileSizes> = .known(CatalogFileSizes(database: 1_000_000, wal: 4_096, shm: 32_768)))
        -> CatalogDatabaseInfoSnapshot {
        var s = CatalogDatabaseInfoSources(databaseURL: URL(fileURLWithPath: "/x/catalog.sqlite"), databaseOpenThisSession: true,
                                           catalogFile: URL(fileURLWithPath: "/x/catalog.json"), journalFolder: URL(fileURLWithPath: "/x/background/journal"),
                                           lastSyncFile: URL(fileURLWithPath: "/x/last_sync.txt"), sessionRole: role,
                                           localHostname: "RicksUltra", masterHostname: "RicksM4.local", defaultsSuite: nil)
        s.sessionRole = role
        return CatalogDatabaseInfoSnapshot(sources: s, readAt: Date(timeIntervalSince1970: 0), database: database, sizes: sizes,
                                           backup: backup, lastSync: lastSync, journal: journal, integrity: integrity)
    }

    private static let known = CatalogDatabaseFacts(
        userVersion: .known(CatalogDatabaseInfoReader.expectedSchemaVersion),
        schemaVersion: .known(CatalogDatabaseInfoReader.expectedSchemaVersion),
        schemaLayout: .known(CatalogSchemaLayout(tableCount: 40, extra: [], missing: [])),
        generation: .known(1_234), contents: .known(4_600), liveFiles: .known(16_000), records: .known(16_156),
        lastCommit: .known(CatalogLastCommit(generation: 1_234, committedAt: Date(timeIntervalSince1970: 100), host: "RicksUltra", writer: "save", kind: "commit")))

    private static func value(_ rows: [CatalogDatabaseInfoLine], _ label: String) -> String? {
        rows.first { $0.label == label }?.value
    }

    // MARK: Logic

    @Test func everyRowInOrderWithTheSchemaFirst() {
        let rows = CatalogDatabaseInfoLines.build(Self.snapshot(Self.known), date: Self.fixedDate)
        #expect(rows.map(\.label) == ["Schema", "Schema layout", "Database", "Size", "Generation", "Contents", "Live files", "Records",
                                      "Last commit", "Last backup the app made", "This Mac's role", "Last sync", "Background journal",
                                      "Last Validate Catalog"])
        let v = CatalogDatabaseInfoReader.expectedSchemaVersion
        #expect(rows[0].value == "Schema \(v)")
        #expect(Self.value(rows, "Schema layout") == "40 tables · matches this build")
        #expect(Self.value(rows, "Database") == "/x/catalog.sqlite")
        #expect(Self.value(rows, "Generation") == 1_234.formatted())
        #expect(Self.value(rows, "Contents") == 4_600.formatted())
        #expect(Self.value(rows, "Live files") == 16_000.formatted())
        #expect(Self.value(rows, "Records") == "\(16_156.formatted()) (live and removed; rows are never deleted)")
        #expect(Self.value(rows, "Last commit") == "D100 · generation \(1_234.formatted()) · via save · RicksUltra")
        #expect(Self.value(rows, "This Mac's role") == "Master — RicksUltra writes the catalog")
        #expect(Self.value(rows, "Last sync") == "not applicable — the master publishes; viewers pull")
        #expect(Self.value(rows, "Background journal") == "3 lines waiting · 1 refused")
        #expect(Self.value(rows, "Size")?.contains("-wal ") == true)
        #expect(rows.allSatisfy { !$0.source.isEmpty }, "every row says where it came from")
        #expect(rows.allSatisfy { !$0.value.isEmpty }, "never a blank")
    }

    @Test func theSchemaRowSaysWhenTheTwoVersionsDisagreeOrTheBuildExpectsAnother() {
        var f = Self.known
        f.userVersion = .known(13)
        f.schemaVersion = .known(13)
        let v = CatalogDatabaseInfoReader.expectedSchemaVersion
        #expect(CatalogDatabaseInfoLines.schema(f) == .known("Schema 13 — this build expects \(v)"))
        f.schemaVersion = .known(v)
        #expect(CatalogDatabaseInfoLines.schema(f) == .known("Schema \(v) — PRAGMA user_version says 13; the two disagree"))
        f.schemaVersion = .unknown("catalog_state has no row (singleton 1) — no schema_version was ever stored")
        #expect(CatalogDatabaseInfoLines.schema(f) == .unknown("catalog_state has no row (singleton 1) — no schema_version was ever stored; PRAGMA user_version says 13"))
    }

    @Test func theLayoutRowNamesExtraAndMissingTables() {
        let r = CatalogDatabaseInfoLines.layout(.known(CatalogSchemaLayout(tableCount: 40, extra: ["stray"], missing: ["footage_likeness", "provenance_assertions"])))
        #expect(r == .known("40 tables · differs from this build — not in this build: stray · missing: footage_likeness, provenance_assertions"))
    }

    @Test func everyMissingSourceIsUnknownWithItsReason() {
        let why = "no file at /x/catalog.sqlite"
        let rows = CatalogDatabaseInfoLines.build(Self.snapshot(.allUnknown(why), role: nil,
                                                                journal: .unknown("no background/journal folder"),
                                                                sizes: .unknown(why)), date: Self.fixedDate)
        for label in ["Schema", "Schema layout", "Size", "Generation", "Contents", "Live files", "Records", "Last commit"] {
            #expect(Self.value(rows, label) == "unknown — " + why, "\(label)")
        }
        #expect(Self.value(rows, "Last backup the app made") == "unknown — no backup recorded on this Mac (VideoScan.lastBackupAt is not set)")
        #expect(Self.value(rows, "This Mac's role") == "unknown — the sync engine has not started this session")
        #expect(Self.value(rows, "Last sync") == "unknown — no last_sync.txt")
        #expect(Self.value(rows, "Background journal") == "unknown — no background/journal folder")
        #expect(Self.value(rows, "Last Validate Catalog") == "unknown — no integrity-latest.json beside the catalog — Validate Catalog has not run here")
        #expect(rows.filter { !$0.known }.count == rows.count - 1, "only the path is known")
    }

    @Test func aViewerSaysItsMasterAndItsLastSync() {
        let rows = CatalogDatabaseInfoLines.build(Self.snapshot(Self.known, role: .viewer, lastSync: .known(Date(timeIntervalSince1970: 7))),
                                                  date: Self.fixedDate)
        #expect(Self.value(rows, "This Mac's role") == "Viewer — read-only; the master is RicksM4.local (this Mac is RicksUltra)")
        #expect(Self.value(rows, "Last sync") == "D7")
    }

    @Test func theBackupRowChecksThePathNow() {
        let at = Date(timeIntervalSince1970: 50)
        #expect(CatalogDatabaseInfoLines.backup(CatalogBackupFacts(at: at, path: "/b/x.vsbundle", pathExists: true), date: Self.fixedDate) == .known("D50 → /b/x.vsbundle"))
        #expect(CatalogDatabaseInfoLines.backup(CatalogBackupFacts(at: at, path: "/b/x.vsbundle", pathExists: false), date: Self.fixedDate)
                == .known("D50 → /b/x.vsbundle (nothing is at that path now)"))
        #expect(CatalogDatabaseInfoLines.backup(CatalogBackupFacts(at: at), date: Self.fixedDate) == .known("D50 — destination not recorded"))
    }

    @Test func theValidateRowFollowsTheReport() {
        let d = Self.fixedDate
        var facts = IntegrityReportFacts(needsDecision: 3)
        facts.unverified = 2
        let completed = CatalogIntegrityVerdict(facts: facts, startedAt: Date(timeIntervalSince1970: 10), verifiedAt: Date(timeIntervalSince1970: 20),
                                                outcome: .completed, missing: false)
        #expect(CatalogDatabaseInfoLines.validate(completed, date: d) == .known("completed D20 · 3 need a decision · 2 unverified"))
        let clean = CatalogIntegrityVerdict(facts: IntegrityReportFacts(), startedAt: Date(timeIntervalSince1970: 10),
                                            verifiedAt: Date(timeIntervalSince1970: 20), outcome: .completed, missing: false)
        #expect(CatalogDatabaseInfoLines.validate(clean, date: d) == .known("completed D20 · nothing to decide"))
        let stopped = CatalogIntegrityVerdict(facts: IntegrityReportFacts(), startedAt: Date(timeIntervalSince1970: 10), outcome: .stopped, missing: false)
        #expect(CatalogDatabaseInfoLines.validate(stopped, date: d) == .known("stopped — started D10; not a full check"))
        let bad = CatalogIntegrityVerdict(facts: IntegrityReportFacts(problem: "integrity-latest.json can't be read: damaged"), missing: false)
        #expect(CatalogDatabaseInfoLines.validate(bad, date: d) == .unknown("integrity-latest.json can't be read: damaged"))
        let old = CatalogIntegrityVerdict(facts: IntegrityReportFacts(predatesSwitch: true), outcome: .completed, missing: false)
        #expect(CatalogDatabaseInfoLines.validate(old, date: d) == .unknown("the last report was made from catalog.json, before the switch to SQLite"))
    }

    @Test func plainTextCarriesEveryRow() {
        let rows = CatalogDatabaseInfoLines.build(Self.snapshot(Self.known), date: Self.fixedDate)
        let text = CatalogDatabaseInfoLines.plainText(rows, readAt: nil)
        #expect(text.hasPrefix("Catalog Database\n"))
        for row in rows { #expect(text.contains("\(row.label): \(row.value)")) }
    }

    // MARK: Isolation (poisoned state, through the real gather)

    @Test func anEmptyFolderIsUnknownEverywhereAndCreatesNothing() throws {
        let f = try Folder()
        let rows = CatalogDatabaseInfoLines.build(CatalogDatabaseInfoGather.readNow(Self.sources(f)))
        for label in ["Schema", "Size", "Generation", "Records", "Last commit", "Background journal", "Last Validate Catalog"] {
            #expect(Self.value(rows, label)?.hasPrefix("unknown — ") == true, "\(label): \(Self.value(rows, label) ?? "nil")")
        }
        #expect(!FileManager.default.fileExists(atPath: f.database.path), "the read never creates the database")
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.url.path).isEmpty, "nothing written in the folder")
    }

    @Test func anUnreadableIntegrityFileIsUnknownInItsWords() throws {
        let f = try Folder()
        try Data("not json at all".utf8).write(to: f.url.appendingPathComponent(IntegrityReportStore.latestFileName))
        let rows = CatalogDatabaseInfoLines.build(CatalogDatabaseInfoGather.readNow(Self.sources(f)))
        #expect(Self.value(rows, "Last Validate Catalog") == "unknown — integrity-latest.json can't be read: not readable as an integrity report")
    }

    @Test func aMissingWalShowsAbsentAndTheFactsStillRead() async throws {
        let f = try Folder()
        _ = try await Self.makeStore(at: f.database, commits: 2)
        try? FileManager.default.removeItem(atPath: f.database.path + "-wal")
        try? FileManager.default.removeItem(atPath: f.database.path + "-shm")
        let rows = CatalogDatabaseInfoLines.build(CatalogDatabaseInfoGather.readNow(Self.sources(f)))
        #expect(Self.value(rows, "Size")?.contains("-wal absent") == true, "\(Self.value(rows, "Size") ?? "nil")")
        #expect(Self.value(rows, "Generation") == "2")
    }

    @Test func aCatalogStateWithNoRowIsUnknownNotZero() throws {
        let f = try Folder()
        try Self.sqlite(f.database, "CREATE TABLE catalog_state (singleton INTEGER PRIMARY KEY, schema_version INTEGER NOT NULL)")
        let rows = CatalogDatabaseInfoLines.build(CatalogDatabaseInfoGather.readNow(Self.sources(f)))
        #expect(Self.value(rows, "Schema") == "unknown — catalog_state has no row (singleton 1) — no schema_version was ever stored; PRAGMA user_version says 0")
        #expect(Self.value(rows, "Generation") == "unknown — the file has no generations table")
    }

    @Test func theJournalIsCountedFromTheFolderNow() throws {
        let f = try Folder()
        try FileManager.default.createDirectory(at: f.journal, withIntermediateDirectories: true)
        try Data("{\"a\":1}\n{\"a\":2}\n".utf8).write(to: f.journal.appendingPathComponent("2026-11-01.jsonl"))
        let snapshot = CatalogDatabaseInfoGather.readNow(Self.sources(f))
        #expect(snapshot.journal == .known(JournalApplier.count(ObservationJournal(directory: f.journal))))
        #expect(snapshot.journal.value?.waiting == 2)
    }

    @Test func theBackupDefaultsAreReadNow() throws {
        let f = try Folder()
        let suite = "catalog-db-info-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(1_700_000_000.0, forKey: "VideoScan.lastBackupAt")
        defaults.set(f.url.path, forKey: "VideoScan.lastBackupPath")
        let backup = CatalogDatabaseInfoGather.readNow(Self.sources(f, suite: suite)).backup
        #expect(backup == CatalogBackupFacts(at: Date(timeIntervalSince1970: 1_700_000_000), path: f.url.path, pathExists: true))
    }

    // MARK: Truth

    @Test func theSchemaRowIsThePragmaAndTheCatalogStateOfARealStore() async throws {
        let f = try Folder()
        _ = try await Self.makeStore(at: f.database, commits: 3)
        let pragma = try #require(try Self.int(f.database, "PRAGMA user_version"))
        let state = try #require(try Self.int(f.database, "SELECT schema_version FROM catalog_state WHERE singleton = 1"))
        let generation = try #require(try Self.int(f.database, "SELECT generation FROM generations WHERE id = 1"))
        #expect(pragma == state)
        let rows = CatalogDatabaseInfoLines.build(await CatalogDatabaseInfoGather.read(Self.sources(f)), date: Self.fixedDate)
        #expect(rows[0].label == "Schema")
        #expect(rows[0].value == "Schema \(state)")
        #expect(Self.value(rows, "Generation") == generation.formatted())
        #expect(Self.value(rows, "Last commit")?.contains("generation \(generation) · via ui") == true)
        #expect(Self.value(rows, "Schema layout")?.hasSuffix("· matches this build") == true)
        #expect(Self.value(rows, "Records") == "0 (live and removed; rows are never deleted)")
    }

    @MainActor
    @Test func theModelPublishesFreshRowsOnEveryRefresh() async throws {
        let f = try Folder()
        _ = try await Self.makeStore(at: f.database, commits: 1)
        let sources = Self.sources(f)
        let model = CatalogDatabaseInfoModel(sources: { sources })
        await model.refresh()
        #expect(model.lines.first { $0.label == "Generation" }?.value == "1")
        _ = try await Self.commit(at: f.database, times: 2)
        await model.refresh()
        #expect(model.lines.first { $0.label == "Generation" }?.value == "3", "re-read from the file, not kept")
        #expect(model.readAt != nil)
        #expect(model.plainText.contains("Generation: 3"))
    }

    // MARK: Helpers

    private static func makeStore(at url: URL, commits: Int) async throws -> Int {
        try await commit(at: url, times: commits)
    }

    /// Open (creating when absent), commit `times` empty `.ui` writes, close.
    @discardableResult
    private static func commit(at url: URL, times: Int) async throws -> Int {
        let repository = GRDBCatalogRepository(host: "test-host", durability: .volatileForTests)
        let opened = await repository.open(at: url)
        try #require(opened == .readWrite, "\(opened)")
        var last = 0
        for _ in 0..<times {
            guard case .committed(let g) = await repository.write(as: .ui, { _ in }) else {
                Issue.record("commit refused")
                break
            }
            last = g
        }
        await repository.close()
        return last
    }

    private static func sqlite(_ url: URL, _ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func int(_ url: URL, _ sql: String) throws -> Int? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : nil
    }
}
