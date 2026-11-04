// BackgroundCountCatalogURLTests.swift — regression (Rick 2026-11-03,
// Settings ▸ Background: "Content analysis: could not count — catalog read
// failed: file is not a database"). The store's count was handed
// `catalogStore.fileLocation`, which is catalog.json — the frozen pre-SQLite
// file — so the era planner opened JSON as SQLite, every recount failed, and
// the app never queued the era job itself (since 2026-11-02).
//
// One rule for "the catalog database this role shows"
// (CatalogAuthority.databaseURL(role:opened:catalogFile:)), used by the count
// and by Catalog Database Info:
//   master  the database the cutover opened, else catalog.sqlite beside
//           catalog.json;
//   viewer  viewer-catalog/catalog.sqlite — the master's synced snapshot —
//           and a viewer counts NO local era work (Codex 11/03 F1: the count
//           followed a stale top-level catalog.sqlite).
//
// Codex 11/03 F7: the old TRUTH test never created a catalog.sqlite, and its
// "fixed" branch passed on ANY failure but "not a database" — including "no
// file". These tests build a REAL schema-current catalog (the repository's
// own open, then rows), with a known eligible count, and require `.success`
// with exactly that count through `productionCountWork` — the closure the
// launch installs.
//
// Dimensions: LOGIC (the rule, three sources), TRUTH (a real database, a
// known count, through the production closure), ISOLATION (two databases
// with different counts side by side: the role picks one), SENSOR (both
// callers use the one rule; the launch hands the store the role).

import Foundation
import ServiceManagement
import SQLite3
import Testing
import VideoScanCore
@testable import VideoScan

/// A catalog.sqlite at the current schema holding `video` readable video
/// files, plus one audio-only and one removed row (never era work).
enum BackgroundCountFixture {
    static func hex(_ n: Int) -> String { String(format: "%064x", n) }

    static func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bg-count-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @MainActor
    static func catalog(at url: URL, video: Int, mediaIn media: URL, seed: Int = 0) async throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let repository = GRDBCatalogRepository(host: "bg-count-test", durability: .volatileForTests)
        let opened = await repository.open(at: url)
        try #require(opened == .readWrite, "\(opened)")
        await repository.close()
        var rows: [(n: Int, stream: String, removed: Bool)] = (1...max(video, 1)).prefix(video).map { ($0 + seed, "Video+Audio", false) }
        rows.append((seed + 900, "Audio only", false))
        rows.append((seed + 901, "Video only", true))
        var sql = "INSERT OR IGNORE INTO volumes (volume_uuid) VALUES ('');"
        for r in rows {
            let path = media.appendingPathComponent("clip-\(r.n).mov").path
            try Data("x".utf8).write(to: URL(fileURLWithPath: path))
            sql += """
                INSERT OR IGNORE INTO content (digest, byte_count, first_seen_at, first_seen_how) VALUES ('\(hex(r.n))', 100, 1700000000, 'rescan');
                INSERT INTO files (id, content_digest, volume_uuid, full_path, path_fold, filename, ext, directory, size_bytes,
                                   digest_computed_at, digest_source, stream_type, duration_s, lifecycle, archive_stage,
                                   volume_case_sensitive, removal_state, removal_since, removal_reason)
                VALUES ('\(String(format: "00000000-0000-0000-0000-%012X", r.n))', '\(hex(r.n))', '', '\(path)', '\(path.lowercased())',
                        'clip-\(r.n).mov', 'mov', '\(media.path)', 100, 1, 'archiveFixity', '\(r.stream)', 120, 'Cataloged', 'None', 0,
                        \(r.removed ? "'removedFromCatalog', 1, 'test'" : "NULL, NULL, NULL"));
                """
        }
        var db: OpaquePointer?
        try #require(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        try #require(rc == SQLITE_OK, Comment(rawValue: err.map { String(cString: $0) } ?? "rc \(rc)"))
    }
}

@Suite("Background count reads the catalog this role shows, never catalog.json")
@MainActor
struct BackgroundCountCatalogURLTests {

    @Test("the one rule: master = the opened database, else catalog.sqlite beside catalog.json; viewer = the synced snapshot")
    func rule() {
        let json = URL(fileURLWithPath: "/tmp/VS/catalog.json")
        #expect(CatalogAuthority.databaseURL(role: .master, opened: nil, catalogFile: json).path == "/tmp/VS/catalog.sqlite")
        let opened = URL(fileURLWithPath: "/tmp/elsewhere/catalog.sqlite")
        #expect(CatalogAuthority.databaseURL(role: .master, opened: opened, catalogFile: json) == opened)
        #expect(CatalogAuthority.databaseURL(role: .viewer, opened: nil, catalogFile: json).path == "/tmp/VS/viewer-catalog/catalog.sqlite")
        #expect(CatalogAuthority.databaseURL(role: .viewer, opened: opened, catalogFile: json)
                == CatalogViewerSnapshot.databaseURL(in: URL(fileURLWithPath: "/tmp/VS")), "a viewer shows the snapshot, whatever was opened")
    }

    @Test("RED 11/03 F7 TRUTH: master, cutover not open — a real catalog.sqlite beside catalog.json counts exactly its 3 video files")
    func countOpensSQLite() async throws {
        let dir = try BackgroundCountFixture.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = dir.appendingPathComponent("catalog.json")
        try Data(#"{"version": 9, "records": []}"#.utf8).write(to: json)
        let db = CatalogAuthority.databaseURL(role: .master, opened: nil, catalogFile: json)
        try await BackgroundCountFixture.catalog(at: db, video: 3, mediaIn: dir.appendingPathComponent("media"))

        // The JSON file is never a catalog (the 11/03 bug, kept as the contrast).
        guard case .failure(let r) = BackgroundServiceStore.count(catalogURL: json, stateRoot: dir.appendingPathComponent("background"),
                                                                  knownJobs: [], now: Date()) else {
            Issue.record("JSON must not count as a catalog"); return
        }
        #expect(r.words.contains("not a database"), "\(r.words)")

        let count = BackgroundServiceStore.productionCountWork(catalogURL: { db })
        guard case .success(let c) = await count([]) else { Issue.record("the real catalog must count"); return }
        #expect(c.filesLeft == 3, "3 live readable videos; the audio-only and the removed row are not era work")
        #expect(c.catalogPath == db.path)
    }

    @Test("TRUTH: master with the cutover open elsewhere — the opened database is counted, not the one beside catalog.json")
    func countFollowsTheOpenedDatabase() async throws {
        let dir = try BackgroundCountFixture.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = dir.appendingPathComponent("catalog.json")
        try await BackgroundCountFixture.catalog(at: dir.appendingPathComponent("catalog.sqlite"), video: 2, mediaIn: dir.appendingPathComponent("m1"))
        let opened = dir.appendingPathComponent("restored/catalog.sqlite")
        try await BackgroundCountFixture.catalog(at: opened, video: 5, mediaIn: dir.appendingPathComponent("m2"), seed: 100)
        let count = BackgroundServiceStore.productionCountWork(catalogURL: {
            CatalogAuthority.databaseURL(role: .master, opened: opened, catalogFile: json)
        })
        guard case .success(let c) = await count([]) else { Issue.record("the opened catalog must count"); return }
        #expect(c.filesLeft == 5)
    }

    @Test("RED 11/03 F1 ISOLATION: a viewer with a stale top-level catalog.sqlite counts nothing and says the master analyzes")
    func viewerCountsNothing() async throws {
        let agent = BackgroundServiceStoreTests.FakeAgent(.enabled)
        let (store, r) = BackgroundServiceStoreTests.make(enabled: true, agent: agent, readOnly: true)
        await store.refresh(recount: true)
        #expect(r.counts == 0, "no count is attempted on a viewer")
        #expect(store.work == nil && store.workProblem == nil)
        #expect(r.enqueued.isEmpty)
        let lines = BackgroundServicePresentation.lines(enabled: store.enabled, launchd: store.launchdStatus, service: store.service,
                                                        serviceProblem: store.serviceProblem, work: store.work,
                                                        workProblem: store.workProblem, lastNote: store.lastNote, viewer: true)
        #expect(lines.job == BackgroundServicePresentation.viewerJob)
        #expect(lines.job.contains("the master runs content analysis"))
        // Codex closing #3: a helper left registered from the master days still
        // lists an era job — the viewer words still win.
        let leftover = BackgroundServicePresentation.lines(enabled: true, launchd: .enabled,
                                                           service: BackgroundServiceStoreTests.serviceStatus(jobs: [BackgroundServiceStoreTests.eraJob(.running)]),
                                                           serviceProblem: nil, work: nil, workProblem: nil, lastNote: nil, viewer: true)
        #expect(leftover.job == BackgroundServicePresentation.viewerJob, "\(leftover.job)")
    }

    @Test("TRUTH F1: Catalog Database Info on a viewer reads the synced snapshot, not a top-level catalog.sqlite with other rows")
    func databaseInfoOnAViewerReadsTheSnapshot() async throws {
        let dir = try BackgroundCountFixture.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = dir.appendingPathComponent("catalog.json")
        try await BackgroundCountFixture.catalog(at: dir.appendingPathComponent("catalog.sqlite"), video: 2, mediaIn: dir.appendingPathComponent("m1"))
        try await BackgroundCountFixture.catalog(at: CatalogViewerSnapshot.databaseURL(in: dir), video: 4,
                                                 mediaIn: dir.appendingPathComponent("m2"), seed: 100)
        func liveFiles(_ role: CatalogSyncMode) -> String? {
            let sources = CatalogDatabaseInfoSources(
                databaseURL: CatalogAuthority.databaseURL(role: role, opened: nil, catalogFile: json),
                databaseOpenThisSession: role == .viewer, catalogFile: json,
                journalFolder: dir.appendingPathComponent("background/journal"), lastSyncFile: dir.appendingPathComponent("last_sync.txt"),
                sessionRole: role, localHostname: "here", masterHostname: "there", defaultsSuite: nil)
            return CatalogDatabaseInfoLines.build(CatalogDatabaseInfoGather.readNow(sources)).first { $0.label == "Live files" }?.value
        }
        // Each fixture adds one audio-only live row beside its videos.
        #expect(liveFiles(.viewer) == "5", "4 videos + 1 audio in the snapshot")
        #expect(liveFiles(.master) == "3", "2 videos + 1 audio beside catalog.json")
    }

    @Test("SENSOR: both callers use the one role-aware rule; the launch hands the store the sync role, not catalogStore.fileLocation")
    func wiring() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("VideoScan")
        let text = try String(contentsOf: src.appendingPathComponent("App/VideoScanApp.swift"), encoding: .utf8)
        let start = try #require(text.range(of: "private func wireBackgroundService()")).upperBound
        let body = String(text[start...].prefix(2_000))
        #expect(body.contains("CatalogAuthority.databaseURL(role: role()"), "the store counts against the role's catalog")
        #expect(body.contains("backgroundService.isViewer = { role() == .viewer }"), "viewer = the sync role, one source")
        #expect(!body.contains("isReadOnly"), "read-only for other reasons is not a viewer")
        #expect(!body.contains("catalogModel.map { URL(fileURLWithPath: $0.catalogStore.fileLocation) }"), "catalog.json is not a database")
        let info = try String(contentsOf: src.appendingPathComponent("Catalog/CatalogDatabaseInfo.swift"), encoding: .utf8)
        #expect(info.contains("CatalogAuthority.databaseURL(role: role, opened: opened, catalogFile: catalogFile)"))
        let flip = try String(contentsOf: src.appendingPathComponent("Catalog/CatalogAuthorityFlip.swift"), encoding: .utf8)
        #expect(flip.components(separatedBy: "static func databaseURL(").count == 2, "one rule, no second overload")
    }
}
