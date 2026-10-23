// ProductionShapeRescanSensorTests.swift
// P0 2026-10-22, at PRODUCTION SHAPE: Rick's real catalog, the app's real
// rescan merge, the app's real committer — on a .backup copy in a temp
// folder. The live catalog is only READ (one SQLite online backup through a
// read-only URI connection); no media file is opened, no disk is walked, no
// ffprobe runs.
//
// The incident: a rescan of /Volumes/FamilyArchive committed one generation
// with `written 456 · held 502 · refused 95 · removed 641`. Every re-seen
// file became a fresh record (new id); the store applied the 641 purges
// first and on their own, then refused 95 replacement archive-copy rows
// (`an archive copy names its source`, trigger archive_copies_need_source):
// the live writer inserted the fresh copy as 'promote' with no source while
// the old row was an import-era copy ('import', NULL source). 95 archived
// Masters were left with no live row. Separately, the Archive tab hid every
// archive copy whose source row was trashed (9 of 144 Masters shown).
//
// One test per fix, each with its own red/green:
//   (a) rescanKeepsEveryArchivedMastersRow — f59f6d841 / 3197ef431 /
//       868c8d2ae: a purge stands only when its replacement ends stored or
//       held. Every live path keeps exactly one live row; every archived
//       Master stays an archived Master; the live Master count is unchanged.
//   (b) importEraArchiveCopyReplacementLands — 8ddfa80d6: the replacement's
//       archive copy inherits 'import' + NULL source, so the trigger never
//       refuses it, the old row is purged and nothing is NOT REMOVED.
//   (c) archiveTabCountsEveryLiveArchiveCopyOnce — f59f6d841's Archive view
//       half (`sourceRepresents`): the categorization counts every live
//       archive copy exactly once, including copies whose source row is
//       trashed — on the copy as loaded and again after the rescan.
//
// The incident shape in the copy: until the live recovery runs, the live
// catalog still holds the 95 purged rows. Setup then puts the copy back in
// its PRE-incident state — it clears the purge marker (a tombstone + the
// cleared marker, every trigger armed) on each purged archive copy under
// /Volumes/FamilyArchive whose path has no live row, which is exactly what
// the rehearsed recovery does. After the recovery that step finds nothing.
// Either way the test then requires ≥ 1 live import-era archive copy
// ('import', NULL source); with none it FAILS ("lost its teeth").
//
// ISOLATION / real global state: this reads the live catalog, so it is NOT
// a sensor-lane test (scripts/sensor_lane.py: "ISOLATION" in the suite name,
// and nothing here reads the repo's source). It runs in the nightly's
// all-tests pass on the M4; anywhere without the live catalog + latch it is
// SKIPPED with the reason below (Swift Testing's `.enabled(if:)` reports a
// skip, never a pass). The gauntlet holds it as a real-data test.
//
// PRIVACY: assertion messages and the summary print counts and record ids,
// never paths or filenames.
//
// (For Rick: `.enabled(if:_:)` ≈ gtest's GTEST_SKIP() decided before the
// body runs; `#expect` ≈ EXPECT_* (records and continues), `#require` ≈
// ASSERT_* (stops the test).)
//
// Suites (filter by SUITE): ProductionShapeRescanSensorTests

import Foundation
import SQLite3
import Testing
@testable import VideoScan
import VideoScanCore

// MARK: - The live catalog (read only)

enum LiveCatalogCopy {
    static let archiveVolumeRoot = "/Volumes/FamilyArchive"

    static var liveFolder: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("VideoScan", isDirectory: true)
    }

    /// The live catalog.sqlite and its latch are both there.
    static var present: Bool {
        guard let folder = liveFolder else { return false }
        let fm = FileManager.default
        return fm.fileExists(atPath: folder.appendingPathComponent(CatalogAuthority.databaseFileName).path)
            && fm.fileExists(atPath: folder.appendingPathComponent(CatalogAuthority.latchFileName).path)
    }

    static let skipWords: Comment = "skipped: no live catalog (catalog.sqlite + catalog.cutover in ~/Library/Application Support/VideoScan) — production-shape P0 test runs only on Rick's Mac"

    /// The live file's read-only URI: `file:/…/catalog.sqlite?mode=ro`.
    static func readOnlyURI() throws -> String {
        guard let folder = liveFolder else { throw CutoverFailure(words: "no Application Support folder") }
        var components = URLComponents()
        components.scheme = "file"
        components.path = folder.appendingPathComponent(CatalogAuthority.databaseFileName).path
        components.queryItems = [URLQueryItem(name: "mode", value: "ro")]
        return try #require(components.string)
    }

    /// `sqlite3 "file:…?mode=ro" ".backup dest"` — SQLite's online backup
    /// through a READ-ONLY connection on the live file; consistent even
    /// while the app writes. If the command-line tool cannot do it, the
    /// same backup in-process; if both fail, both reasons.
    static func backup(to dest: URL) throws {
        let uri = try readOnlyURI()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [uri, ".backup '\(dest.path)'"]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let stderrText = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        if process.terminationStatus == 0, FileManager.default.fileExists(atPath: dest.path) { return }
        try? FileManager.default.removeItem(at: dest)
        do {
            try backupInProcess(uri: uri, to: dest)
        } catch {
            throw CutoverFailure(words: "sqlite3 .backup exited \(process.terminationStatus) (\(stderrText.trimmingCharacters(in: .whitespacesAndNewlines))); in-process: \(error)")
        }
    }

    private static func backupInProcess(uri: String, to dest: URL) throws {
        var src: OpaquePointer?
        var dst: OpaquePointer?
        defer { sqlite3_close(src); sqlite3_close(dst) }
        guard sqlite3_open_v2(uri, &src, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            throw CutoverFailure(words: "the live catalog would not open read-only")
        }
        sqlite3_busy_timeout(src, 10_000)
        guard sqlite3_open_v2(dest.path, &dst, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw CutoverFailure(words: "the backup destination would not open")
        }
        guard let backup = sqlite3_backup_init(dst, "main", src, "main") else {
            throw CutoverFailure(words: "sqlite3_backup_init: \(String(cString: sqlite3_errmsg(dst)))")
        }
        var rc: Int32
        repeat {
            rc = sqlite3_backup_step(backup, -1)
            if rc == SQLITE_BUSY || rc == SQLITE_LOCKED { sqlite3_sleep(50) }
        } while rc == SQLITE_OK || rc == SQLITE_BUSY || rc == SQLITE_LOCKED
        let words = "\(String(cString: sqlite3_errmsg(src))) / \(String(cString: sqlite3_errmsg(dst))), errno \(sqlite3_system_errno(src))/\(sqlite3_system_errno(dst))"
        sqlite3_backup_finish(backup)
        guard rc == SQLITE_DONE else { throw CutoverFailure(words: "sqlite3_backup_step returned \(rc): \(words)") }
    }
}

/// Every row `sql` returns, each column as text ("NULL" for NULL), through
/// its own connection on the TEMP COPY (read-write: the copy is in WAL
/// mode and a read-only connection cannot create its -shm; only SELECTs
/// are passed here). No size limit (the pipe-based helper is for a
/// handful of rows).
func sqliteTable(_ url: URL, _ sql: String) throws -> [[String]] {
    var db: OpaquePointer?
    defer { sqlite3_close(db) }
    guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
        throw CutoverFailure(words: "the copy would not open")
    }
    sqlite3_busy_timeout(db, 10_000)
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
        throw CutoverFailure(words: "prepare: \(String(cString: sqlite3_errmsg(db)))")
    }
    defer { sqlite3_finalize(statement) }
    var rows: [[String]] = []
    while sqlite3_step(statement) == SQLITE_ROW {
        let n = sqlite3_column_count(statement)
        rows.append((0..<n).map { i in
            sqlite3_column_text(statement, i).map { String(cString: $0) } ?? "NULL"
        })
    }
    return rows
}

// MARK: - The scene: a temp folder holding the copy, the app model on it

@MainActor
struct ProductionShapeScene {
    let scene: CutoverScene
    /// Purged archive copies the setup put back (0 once the live recovery ran).
    let revived: Int
    let root = LiveCatalogCopy.archiveVolumeRoot

    var model: VideoScanModel { scene.model }
    var db: URL { scene.databaseURL }

    /// Copy the live catalog (+ latch + high-water witnesses at its
    /// generation) into a sandbox, re-create the pre-incident state there
    /// when needed, and launch the app's model on it.
    static func make(_ label: String) async throws -> ProductionShapeScene {
        let scene = CutoverScene(sandbox: try ShowAgainSandbox.make("prodshape_\(label)"))
        let folder = scene.folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try LiveCatalogCopy.backup(to: scene.databaseURL)
        let liveLatch = try #require(LiveCatalogCopy.liveFolder).appendingPathComponent(CatalogAuthority.latchFileName)
        try FileManager.default.copyItem(at: liveLatch, to: scene.latchURL)

        let revived = try Self.restorePreIncidentRows(scene)
        let generation = try #require(Int(try sqliteTable(scene.databaseURL,
                                                         "SELECT generation FROM generations WHERE id = 1").first?.first ?? ""))
        try Data("\(generation)\n".utf8).write(to: folder.appendingPathComponent(CatalogHighWater.fileName))
        try Data("\(generation) 2026-10-23T00:00:00Z prodshape-test\n".utf8)
            .write(to: folder.appendingPathComponent(CatalogHighWaterLedger.fileName))

        // The launch, as `restoreCatalogAtLaunch` runs it: the records, then
        // the Master Archive designation catalog_state carried (without it
        // every commit is refused — GH #167's guard — and nothing is tested).
        scene.model.records = scene.model.loadCatalogAtLaunch()
        scene.model.masterArchive = scene.model.catalogStore.masterArchive
        try #require(scene.model.catalogCutover.isSQLiteAuthority,
                     "the copy launched on SQLite with a writable committer")
        try #require(scene.model.masterArchive != nil, "the copy carries the Master Archive designation")
        return ProductionShapeScene(scene: scene, revived: revived)
    }

    func cleanup() { scene.cleanup() }

    /// Close the committer's store before the folder goes (as at quit).
    func close() async { await Self.close(model) }

    static func close(_ model: VideoScanModel) async {
        if let committer = model.catalogCutover.committer { await committer.repository.close() }
    }

    /// Quit and launch again: the session's store closed, then a NEW model
    /// on the same folder runs the launch (records + designation) — no
    /// in-memory index or record object survives from the first session.
    func relaunchedModel() async throws -> VideoScanModel {
        await close()
        let sandbox = scene.sandbox
        let fresh = VideoScanModel(logDirectory: sandbox.logs)
        fresh.catalogStore = CatalogStore(directory: sandbox.catalogDir)
        fresh.mediaLedger = MediaLedger(directory: sandbox.root.appendingPathComponent("ledger", isDirectory: true))
        fresh.records = fresh.loadCatalogAtLaunch()
        fresh.masterArchive = fresh.catalogStore.masterArchive
        try #require(fresh.catalogCutover.isSQLiteAuthority, "the relaunch opened the copy on SQLite")
        return fresh
    }

    /// The incident's 95 rows, if the copy still has them purged: a purged
    /// ('removedFromCatalog' / 'purged') archive copy under the archive
    /// volume whose path holds no live row gets its marker cleared — its
    /// tombstone first, then the files row, one transaction, every trigger
    /// armed. One row per path. Returns how many.
    private static func restorePreIncidentRows(_ scene: CutoverScene) throws -> Int {
        let prefix = LiveCatalogCopy.archiveVolumeRoot + "/"
        let select = """
            SELECT min(f.id) FROM files f JOIN archive_copies a ON a.file_id = f.id
            WHERE f.removal_state = 'removedFromCatalog' AND f.removal_reason = 'purged'
              AND substr(f.full_path, 1, \(prefix.count)) = '\(prefix)'
              AND NOT EXISTS (SELECT 1 FROM files g WHERE g.removal_state IS NULL AND g.volume_uuid = f.volume_uuid
                              AND (g.full_path = f.full_path OR (g.volume_case_sensitive = 0 AND g.path_fold = f.path_fold)))
            GROUP BY f.volume_uuid, f.path_fold
            """
        let count = try sqliteTable(scene.databaseURL, select).count
        guard count > 0 else { return 0 }
        try scene.execSQL("""
            BEGIN IMMEDIATE;
            CREATE TEMP TABLE revive AS \(select);
            INSERT INTO tombstones (file_id, revision, state, since, reason, trash_path, trash_emptied_at,
                                    last_seen, written_at, door, generation)
              SELECT f.id, f.removal_revision + 1, NULL, NULL, NULL, NULL, NULL, NULL,
                     CAST(strftime('%s','now') AS INTEGER), 'prodshape-test-pre-incident',
                     (SELECT generation FROM generations WHERE id = 1)
              FROM files f WHERE f.id IN (SELECT * FROM revive);
            UPDATE files SET removal_state = NULL, removal_since = NULL, removal_reason = NULL,
                             removal_trash_path = NULL, removal_trash_emptied_at = NULL,
                             removal_last_seen = NULL, removal_revision = removal_revision + 1
              WHERE id IN (SELECT * FROM revive);
            COMMIT;
            """)
        return count
    }

    // MARK: Facts

    struct ArchivedMaster: Equatable {
        let id: String
        let promotedBy: String
        let sourceIsNull: Bool
    }

    /// Path → live archived Master (files row live, stage Master, an
    /// archive_copies row) under the archive volume.
    func archivedMastersByPath() throws -> [String: ArchivedMaster] {
        let prefix = root + "/"
        var out: [String: ArchivedMaster] = [:]
        for row in try sqliteTable(db, """
            SELECT f.full_path, f.id, a.promoted_by, a.source_file_id IS NULL
            FROM files f JOIN archive_copies a ON a.file_id = f.id
            WHERE f.removal_state IS NULL AND f.archive_stage = 'Master'
              AND substr(f.full_path, 1, \(prefix.count)) = '\(prefix)'
            """) {
            out[row[0]] = ArchivedMaster(id: row[1], promotedBy: row[2], sourceIsNull: row[3] == "1")
        }
        return out
    }

    /// Path → ids of every live record under the archive volume.
    static func livePaths(_ records: [VideoRecord], root: String) -> [String: [UUID]] {
        var out: [String: [UUID]] = [:]
        for rec in records where rec.removal == nil && PathScope.contains(rec.fullPath, within: root) {
            out[rec.fullPath, default: []].append(rec.id)
        }
        return out
    }

    static func liveMasterCount(_ records: [VideoRecord]) -> Int {
        records.count { $0.removal == nil && $0.archiveStage == .masterAssigned }
    }

    // MARK: The rescan, as a completed scan of the archive volume drives it

    struct RescanResult {
        let outcome: ScanMergeOutcome
        let fed: Int
        let log: String
        let reloaded: [VideoRecord]
    }

    /// What `finalizeSingleTargetScan` does for a completed rescan of the
    /// archive volume, minus the walk and ffprobe: the preservation
    /// snapshot (startTarget), one fresh probe per live path under the root
    /// (new id, no whole-file hash, no curated values — the re-probe of the
    /// same bytes: same path, size, stamps, partial hash), the preservation
    /// apply, `commitScanResults(scanWasComplete: true)`, the save funnel,
    /// and the committer drained. Then the copy is reloaded with the app's
    /// loader.
    func rescan() async throws -> RescanResult {
        let target = CatalogScanTarget(searchPath: root)
        model.snapshotPreservedFieldsForRescan(of: target)
        var seen = Set<String>()
        var fresh: [VideoRecord] = []
        for rec in model.records where rec.removal == nil && PathScope.contains(rec.fullPath, within: root) {
            guard seen.insert(rec.fullPath).inserted else { continue }
            fresh.append(try scene.probe(of: rec))
        }
        model.applyPreservedFieldsAfterRescan(of: target, onto: fresh)
        let generationBefore = try await CutoverScene.load(db).generation
        let outcome = await model.commitScanResults(root: root, volName: "FamilyArchive",
                                                    targetRecords: fresh, scanWasComplete: true)
        _ = model.saveCatalogNow()
        let committer = try scene.committer()
        for _ in 0..<2 {
            committer.scheduleCommit(after: .zero)
            try await scene.settle(60)
        }
        let load = try await CutoverScene.load(db)
        let log = scene.sandbox.catalogLogText()
        // The rescan must have COMMITTED, or every invariant below holds
        // vacuously (a refused save leaves the copy untouched).
        // Whole-save refusal words only ("NOT SAVED — …", "REFUSED via …");
        // a per-row "NOT SAVED <id> — …" is a finding the tests judge.
        try #require(!log.contains("NOT SAVED — ") && !log.contains("REFUSED via"),
                     "the rescan's save was refused as a whole — nothing was committed, the test proves nothing")
        try #require(load.generation > generationBefore,
                     "the rescan committed no generation (\(generationBefore) → \(load.generation))")
        return RescanResult(outcome: outcome, fed: fresh.count, log: log, reloaded: load.records)
    }

    /// "refused N" summed over every OUTCOME commit line of the log.
    static func refusedTotal(_ log: String) -> Int {
        log.split(separator: "\n").filter { $0.contains("OUTCOME commit") }.reduce(0) { sum, line in
            guard let r = line.range(of: "refused ") else { return sum }
            return sum + (Int(line[r.upperBound...].prefix { $0.isNumber }) ?? 0)
        }
    }

    static func occurrences(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    // MARK: The Archive tab's categorization

    struct ArchiveCount {
        var liveCopies = 0
        var shownOnce = 0
        var missing: [UUID] = []
        var doubled: [UUID] = []
        /// Live copies whose source row is in the catalog but not active
        /// (trashed, removed, set aside, superseded) — the case the fix is about.
        var inactiveSource = 0
    }

    /// The Archive tab's own snapshot (`ArchiveCategorySnapshot.compute`
    /// over `pfActiveRecords`, as `cached(in:)` builds it), then: is every
    /// ACTIVE archive copy represented exactly once in `archived` — by
    /// itself, or by its active source whose master copy it is?
    static func archiveCount(_ model: VideoScanModel) -> ArchiveCount {
        let active = pfActiveRecords(model.records)
        let snap = ArchiveCategorySnapshot.compute(active: active, allRecords: model.records, model: model,
                                                   volumeSearchPaths: [], needsDate: .pending)
        let shown = Set(snap.archived.map(\.id))
        let activeIDs = Set(active.map(\.id))
        var c = ArchiveCount()
        for copy in active where model.isArchiveCopy(copy) {
            c.liveCopies += 1
            let source = model.promotionSource(of: copy)
            if let source, !activeIDs.contains(source.id) { c.inactiveSource += 1 }
            let bySelf = shown.contains(copy.id)
            let bySource = source.map { activeIDs.contains($0.id) && shown.contains($0.id)
                && model.masterArchiveCopy(of: $0) === copy } ?? false
            switch (bySelf, bySource) {
            case (true, true): c.doubled.append(copy.id)
            case (false, false): c.missing.append(copy.id)
            default: c.shownOnce += 1
            }
        }
        return c
    }
}

// MARK: - The tests

@Suite("Production-shape rescan of the live catalog's archive volume (P0 2026-10-22) — ISOLATION: reads the real catalog",
       .serialized, .enabled(if: LiveCatalogCopy.present, LiveCatalogCopy.skipWords))
@MainActor
struct ProductionShapeRescanSensorTests {

    /// The copy must hold the incident's shape, or the tests prove nothing.
    private func requireTeeth(_ before: [String: ProductionShapeScene.ArchivedMaster]) throws -> Int {
        let importEra = before.values.count { $0.promotedBy == "import" && $0.sourceIsNull }
        try #require(importEra >= 1, "the copy has no import-era archive copies — the test lost its teeth")
        try #require(before.count >= 24, "only \(before.count) live archived Masters under the archive volume — expected dozens")
        return importEra
    }

    @Test("(a) f59f6d841/3197ef431/868c8d2ae: a rescan of the archive volume keeps one live row per path, every archived Master, and the live Master count")
    func rescanKeepsEveryArchivedMastersRow() async throws {
        let s = try await ProductionShapeScene.make("a"); defer { s.cleanup() }
        let before = try s.archivedMastersByPath()
        let importEra = try requireTeeth(before)
        let livePathsBefore = ProductionShapeScene.livePaths(s.model.records, root: s.root)
        let mastersBefore = ProductionShapeScene.liveMasterCount(s.model.records)

        let r = try await s.rescan()
        let livePathsAfter = ProductionShapeScene.livePaths(r.reloaded, root: s.root)
        let after = try s.archivedMastersByPath()
        let lostPaths = livePathsBefore.keys.filter { (livePathsAfter[$0]?.count ?? 0) == 0 }
        let doubledPaths = livePathsBefore.keys.filter { (livePathsAfter[$0]?.count ?? 0) > 1 }
        let lostMasters = before.keys.filter { after[$0] == nil }
        let mastersAfter = ProductionShapeScene.liveMasterCount(r.reloaded)
        let lostIDs = lostPaths.compactMap { livePathsBefore[$0]?.first?.uuidString }.sorted().prefix(5)

        print("ProductionShape (a): revived \(s.revived) · fed \(r.fed) · live paths \(livePathsBefore.count) → lost \(lostPaths.count), doubled \(doubledPaths.count)"
              + " · archived Masters \(before.count) (import-era \(importEra)) → \(after.count), lost \(lostMasters.count)"
              + " · live Masters \(mastersBefore) → \(mastersAfter) · refused \(ProductionShapeScene.refusedTotal(r.log))")
        #expect(lostPaths.isEmpty, "\(lostPaths.count) of \(livePathsBefore.count) live paths have NO live row after the rescan (old ids, first 5: \(lostIDs.joined(separator: ", ")))")
        #expect(doubledPaths.isEmpty, "\(doubledPaths.count) live paths have more than one live row after the rescan")
        #expect(lostMasters.isEmpty, "\(lostMasters.count) of \(before.count) archived Masters are no longer an archived Master with an archive_copies row")
        #expect(mastersAfter == mastersBefore, "live Masters \(mastersBefore) before, \(mastersAfter) after")
        await s.close()
    }

    @Test("(b) 8ddfa80d6: every import-era archive copy's replacement lands as 'import' — no trigger refusal, old row purged, nothing NOT REMOVED")
    func importEraArchiveCopyReplacementLands() async throws {
        let s = try await ProductionShapeScene.make("b"); defer { s.cleanup() }
        let before = try s.archivedMastersByPath()
        let importEra = try requireTeeth(before)
        let importBefore = before.filter { $0.value.promotedBy == "import" }

        let r = try await s.rescan()
        let after = try s.archivedMastersByPath()
        let triggerRefusals = ProductionShapeScene.occurrences("an archive copy names its source", in: r.log)
        let notRemoved = ProductionShapeScene.occurrences("NOT REMOVED", in: r.log)
        var notReplaced: [String] = []      // old ids whose path has no fresh archived Master
        var lostProvenance: [String] = []   // new ids not stored as 'import' with the old source shape
        var oldStillLive: [String] = []
        for (path, old) in importBefore {
            guard let new = after[path], new.id != old.id else { notReplaced.append(old.id); continue }
            if new.promotedBy != "import" || new.sourceIsNull != old.sourceIsNull { lostProvenance.append(new.id) }
        }
        let oldIDs = importBefore.values.map { "'\($0.id)'" }.joined(separator: ",")
        if !oldIDs.isEmpty {
            oldStillLive = try sqliteTable(s.db, "SELECT id FROM files WHERE removal_state IS NULL AND id IN (\(oldIDs))").map { $0[0] }
        }

        print("ProductionShape (b): revived \(s.revived) · fed \(r.fed) · import-era archived Masters \(importBefore.count) (NULL source \(importEra))"
              + " · replaced as 'import' \(importBefore.count - notReplaced.count - lostProvenance.count)"
              + " · not replaced \(notReplaced.count) · provenance lost \(lostProvenance.count) · old still live \(oldStillLive.count)"
              + " · trigger refusals \(triggerRefusals) · NOT REMOVED \(notRemoved) · refused \(ProductionShapeScene.refusedTotal(r.log))")
        #expect(triggerRefusals == 0, "\(triggerRefusals) catalog.log line(s) say \"an archive copy names its source\"")
        #expect(notRemoved == 0, "\(notRemoved) purge(s) were kept back (NOT REMOVED) because a replacement did not land")
        #expect(notReplaced.isEmpty, "\(notReplaced.count) of \(importBefore.count) import-era archived Masters were not replaced by a fresh stored archive copy (old ids, first 5: \(notReplaced.sorted().prefix(5).joined(separator: ", ")))")
        #expect(lostProvenance.isEmpty, "\(lostProvenance.count) replacement archive copies did not keep promoted_by 'import' and the old source shape")
        #expect(oldStillLive.isEmpty, "\(oldStillLive.count) replaced import-era rows are still live (not purged)")
        await s.close()
    }

    @Test("(c) Archive view fix: the Archive tab counts every live archive copy exactly once — as loaded and after the rescan, trashed sources included")
    func archiveTabCountsEveryLiveArchiveCopyOnce() async throws {
        let s = try await ProductionShapeScene.make("c"); defer { s.cleanup() }
        _ = try requireTeeth(try s.archivedMastersByPath())

        let asLoaded = ProductionShapeScene.archiveCount(s.model)
        try #require(asLoaded.inactiveSource >= 1,
                     "no live archive copy has an inactive source row — the Archive-count check lost its teeth")
        Self.expectEachCopyOnce(asLoaded, when: "as loaded")   // judged BEFORE the rescan can throw

        _ = try await s.rescan()
        let relaunched = try await s.relaunchedModel()
        Self.expectEachCopyOnce(ProductionShapeScene.archiveCount(relaunched), when: "after the rescan")
        await ProductionShapeScene.close(relaunched)
    }

    private static func expectEachCopyOnce(_ c: ProductionShapeScene.ArchiveCount, when: String) {
        print("ProductionShape (c) \(when): live archive copies \(c.liveCopies) · shown once \(c.shownOnce)"
              + " · missing \(c.missing.count) · doubled \(c.doubled.count) · inactive source \(c.inactiveSource)")
        #expect(c.missing.isEmpty, "\(when): \(c.missing.count) of \(c.liveCopies) live archive copies are not in the Archive tab (first 5: \(c.missing.map(\.uuidString).sorted().prefix(5).joined(separator: ", ")))")
        #expect(c.doubled.isEmpty, "\(when): \(c.doubled.count) live archive copies are counted twice")
    }
}
