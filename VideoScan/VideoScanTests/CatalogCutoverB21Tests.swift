// CatalogCutoverB21Tests.swift
// Cutover B2.1 — the write-side gaps that would bite in the first session
// after the flip, and codex's B2 findings (docs/reviews/codex/
// codex-review-cutover-b2-write-side-switch-door-2026-10-17.md):
//   LOGIC     a dirty sibling never overwrites a curated value it did not
//             change (P1-1); copy propagation never overwrites a later edit
//             (P1-2); a quit after a commit commits what changed since (P1-3 —
//             "during" is impossible since B2.2's synchronous commit); a new row without a
//             whole-file hash survives a relaunch and gets its hash job
//             (gap 1); Trash then Undo stores both revisions (gap 2); a row
//             removed from the records is purged in the store and stays gone
//             at relaunch (gap 3); Adopt This SQLite Catalog… (gap 5);
//   ISOLATION another job's hold is not passed by an unrelated owner
//             (codex gap 4);
//   SENSOR    no app file outside the funnels calls the JSON store's save
//             directly (gap 4);
//   SCALE     covered in Core (CatalogCommitScaleTests);
//   MEDIA     N/A — no media is opened.
// Every case runs in a sandbox folder (CutoverScene), never Application Support.
//
// Suites (filter by SUITE): CatalogCommitterSerialTests · CatalogPendingRowsTests ·
// CatalogMarkerRevisionTests · CatalogPurgeMarkerTests · CatalogDirectSaveSensorTests ·
// CatalogAdoptTests

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@MainActor
extension CutoverScene {

    /// The open committer (the scene launched on SQLite).
    func committer() throws -> CatalogCommitter {
        try #require(model.catalogCutover.committer)
    }

    /// Quit and launch again on the same folder: the committer's store is
    /// closed (as at quit), then the launch rule runs once more.
    func relaunch() async throws {
        if let committer = model.catalogCutover.committer { await committer.repository.close() }
        model.records = model.loadCatalogAtLaunch()
    }

    /// A NEW record at `path`: the fixture row `shape`'s fields under a new
    /// id, its whole-file hashes removed (what a scan, a Combine output or
    /// a Transcode output looks like before Fill In Full Hashes).
    func freshCopy(of shape: PoisonedCatalogFixture.Shape, path: String) throws -> VideoRecord {
        let source = try record(shape)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try #require(try JSONSerialization.jsonObject(with: encoder.encode(VideoRecordDTO(source))) as? [String: Any])
        object["id"] = UUID().uuidString
        object["fullPath"] = path
        object["filename"] = (path as NSString).lastPathComponent
        object["contentFixity"] = nil
        object["archiveFixity"] = nil
        object["pairedWithID"] = nil
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(VideoRecord.self, from: JSONSerialization.data(withJSONObject: object))
    }

    /// The revisions of a fixture row's tombstones, read through the seam.
    func tombstoneRevisions(_ shape: PoisonedCatalogFixture.Shape) async throws -> [Int] {
        let repository = GRDBCatalogRepository(host: "cutover-test")
        _ = await repository.open(at: databaseURL)
        let id = PoisonedCatalogFixture.id(shape)
        do {
            let revisions = try await repository.read { try $0.tombstoneRevisions(fileID: id) }
            await repository.close()
            return revisions
        } catch {
            await repository.close()
            throw error
        }
    }

    /// Put a Master Archive designation into catalog.json through the JSON
    /// store's own save (as the app does before the switch).
    @discardableResult
    func writeDesignation(rootPath: String) throws -> MasterArchiveDesignation {
        let store = CatalogStore(directory: folder)
        let records = store.load()
        let designation = MasterArchiveDesignation(targetPath: "/Volumes/Archive", rootPath: rootPath,
                                                   designatedAt: Date(timeIntervalSince1970: 1_790_000_000))
        store.masterArchive = designation
        guard store.saveNow(records: records) else { throw CutoverFailure(words: "catalog.json was not saved") }
        try recertify()
        return designation
    }

    /// catalog.json changed on purpose (a save): Verify Catalog and Audit
    /// Catalog "ran again" — the fixture's report and marker name the new
    /// bytes and generation, as the real import job's own passes would.
    func recertify() throws {
        let bytes = try Data(contentsOf: catalogURL)
        let top = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let generation = top["generation"] as? Int ?? 0
        let sha = try sha256(catalogURL)
        try patch(PoisonedCatalogFixture.integrityFileName) {
            $0["catalogSHA256"] = sha
            $0["catalogByteCount"] = bytes.count
            $0["snapshotGeneration"] = generation
        }
        try patch(PoisonedCatalogFixture.auditFileName) {
            if $0["catalogGeneration"] != nil { $0["catalogGeneration"] = generation }
        }
    }

    private func patch(_ name: String, _ change: (inout [String: Any]) -> Void) throws {
        let url = folder.appendingPathComponent(name)
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        change(&object)
        try JSONSerialization.data(withJSONObject: object).write(to: url, options: .atomic)
    }

    /// Wait (bounded) for the committer's queued work to finish.
    func settle(_ seconds: Double = 10) async throws {
        let committer = try committer()
        let deadline = Date().addingTimeInterval(seconds)
        while committer.isBusy, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

// MARK: - Codex P1-1 / P1-2 / P1-3 / P2-7 and the hold owner

@Suite("Catalog committer B2.1 — siblings, propagation, one serial path, the hold owner", .serialized)
@MainActor
struct CatalogCommitterSerialTests {

    @Test("P1-1: a sibling dirty for another field does not write its stale copy of a curated value over the edit")
    func dirtySiblingKeepsEdit() async throws {
        let scene = try CutoverScene.make("b21_sibling"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        try scene.record(.curatedConflictA).userNotes = "A wrote this"
        try scene.record(.curatedConflictB).setAsideReason = "damaged"
        #expect(scene.model.saveCatalogNow())
        #expect(try await scene.reloaded(.curatedConflictA).userNotes == "A wrote this")
    }

    // P1-2 ("an edit the sibling got while the commit ran") and P1-3 ("a quit
    // during an in-flight commit") are impossible since B2.2: a commit is one
    // synchronous main-actor turn. CatalogCommitterSyncSensorTests pins that;
    // the cases below keep the user-visible half of each.

    @Test("P1-2: copy propagation leaves an edit the sibling got after A's commit")
    func propagationKeepsLaterEdit() async throws {
        let scene = try CutoverScene.make("b21_propagate"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let b = try scene.record(.curatedConflictB)
        try scene.record(.curatedConflictA).userNotes = "from A"
        #expect(await scene.model.saveCatalogAcknowledged())
        #expect(b.userNotes == "from A", "the copy follows A's committed note")
        b.userNotes = "B, typed after A was saved"
        #expect(scene.model.saveCatalogNow())
        #expect(try await scene.reloaded(.curatedConflictB).userNotes == "B, typed after A was saved")
    }

    @Test("P1-3: a quit right after an acknowledged commit commits what changed since")
    func quitAfterAcknowledged() async throws {
        let scene = try CutoverScene.make("b21_quit"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let healthy = try scene.record(.healthy)
        healthy.starRating = 1
        #expect(await scene.model.saveCatalogAcknowledged())
        healthy.starRating = 0
        #expect(scene.model.saveCatalogNow())
        #expect(try await scene.reloaded(.healthy).starRating == 0)
    }

    @Test("codex gap 4: another job's hold is not passed by an unrelated owner")
    func holdOwnerCompared() async throws {
        let scene = try CutoverScene.make("b21_owner"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        await scene.model.catalogStore.holdWrites(reason: "a test job is reading the catalog", owner: CatalogWriteHoldOwner())
        try scene.record(.healthy).starRating = 2
        #expect(await scene.model.saveCatalogAcknowledged(asHoldOwner: CatalogWriteHoldOwner()) == false)
        #expect(try await scene.reloaded(.healthy).starRating == 0)
        scene.model.catalogStore.releaseWriteHold()
    }
}

// MARK: - Gap 1: new rows without a whole-file hash

@Suite("Catalog pending rows — a new row without a whole-file hash survives a relaunch and gets its hash job", .serialized)
@MainActor
struct CatalogPendingRowsTests {

    @Test("new row → commit → relaunch: the record is back and its hash job is queued")
    func newRowSurvivesRelaunch() async throws {
        let scene = try CutoverScene.make("b21_pending"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let fresh = try scene.freshCopy(of: .healthy, path: "/Volumes/Fixture/New/scan-result.mov")
        scene.model.records.append(fresh)
        _ = scene.model.saveCatalogNow()
        try await scene.relaunch()
        #expect(scene.model.records.contains { $0.id == fresh.id })
        #expect(scene.model.catalogCutover.awaitingDigest.contains(fresh.id))
    }

    @Test("the hash lands → the next save stores the row; the held row is gone and nothing waits for a hash")
    func hashLandsThenStored() async throws {
        let scene = try CutoverScene.make("b21_pending_lands"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let fresh = try scene.freshCopy(of: .healthy, path: "/Volumes/Fixture/New/combined.mov")
        scene.model.records.append(fresh)
        #expect(scene.model.saveCatalogNow(), "a held row is durable")
        #expect(try scene.committer().heldIDs == [fresh.id])
        fresh.contentFixity = ContentFixity(digest: String(repeating: "d", count: 64), byteCount: fresh.sizeBytes,
                                            stamp: FileIdentityStamp(device: 1, inode: 2, size: fresh.sizeBytes, mtimeNs: 3,
                                                                     ctimeNs: 4, volumeUUID: nil))
        #expect(scene.model.saveCatalogNow())
        #expect(try scene.committer().heldIDs.isEmpty)
        let reloaded = try await scene.sqliteLoad()
        #expect(reloaded.records.contains { $0.id == fresh.id })
        #expect(reloaded.heldIDs.isEmpty)
        #expect(scene.model.catalogCutover.awaitingDigest.isEmpty)
    }

    @Test("a held row is offered to the scoped hash job once one is attached")
    func heldRowsOfferedToTheJob() async throws {
        let scene = try CutoverScene.make("b21_pending_job"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        var offered: [Set<UUID>] = []
        scene.model.catalogCutover.attachDigestJobs { offered.append($0) }
        let fresh = try scene.freshCopy(of: .healthy, path: "/Volumes/Fixture/New/transcoded.mov")
        scene.model.records.append(fresh)
        _ = scene.model.saveCatalogNow()
        #expect(offered.last == [fresh.id])
    }
}

// MARK: - Gap 2: two marker changes inside one save window

@Suite("Catalog marker revisions — every removal-marker change gets its own tombstone", .serialized)
@MainActor
struct CatalogMarkerRevisionTests {

    @Test("Trash then Undo within one second: both revisions stored, the row live")
    func trashThenUndo() async throws {
        let scene = try CutoverScene.make("b21_marker"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let healthy = try scene.record(.healthy)
        let before = RemovalMirrors.of(healthy)
        VideoScanModel.stampRemoval(healthy, .removedFromCatalog(at: Date(), reason: .userRemoved))
        let wrote = healthy.removal
        VideoScanModel.revertRemoval(healthy, wrote: wrote, previous: nil, revision: healthy.removalRevision,
                                     mirrorsBefore: before, mirrorsAfter: RemovalMirrors.of(healthy))
        #expect(scene.model.saveCatalogNow())
        #expect(try scene.committer().changedRecordCount() == 0)
        #expect(try await scene.reloaded(.healthy).removal == nil)
        #expect(try await scene.tombstoneRevisions(.healthy) == [1, 2])
    }

    @Test("Trash emptied is a marker change too: it gets its own revision and tombstone")
    func trashEmptiedBumps() async throws {
        let scene = try CutoverScene.make("b21_emptied"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let healthy = try scene.record(.healthy)
        let gone = scene.sandbox.root.appendingPathComponent("not-there.mov").path
        healthy.lifecycleStage = .trashed
        VideoScanModel.stampRemoval(healthy, .inTrash(movedAt: Date(timeIntervalSince1970: 1_790_400_000), trashPath: gone, reason: .catalogTrash))
        #expect(scene.model.saveCatalogNow())
        #expect(scene.model.noteEmptiedTrash(in: [healthy], now: Date(timeIntervalSince1970: 1_790_400_100)) == 1)
        #expect(scene.model.saveCatalogNow())
        #expect(try await scene.tombstoneRevisions(.healthy) == [1, 2])
    }
}

// MARK: - Gap 3: records removed from the array

@Suite("Catalog purge — a record removed from the catalog stays gone at relaunch; its row is tombstoned, never deleted", .serialized)
@MainActor
struct CatalogPurgeMarkerTests {

    @Test("purge a row → commit → relaunch: not in the records")
    func purgedStaysGone() async throws {
        let scene = try CutoverScene.make("b21_purge"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let id = try scene.record(.healthy).id
        scene.model.records.removeAll { $0.id == id }
        #expect(scene.model.saveCatalogNow())
        let reloaded = try await scene.sqliteLoad()
        #expect(reloaded.records.contains { $0.id == id } == false)
        #expect(reloaded.purgedCount == 1)
        #expect(try await scene.tombstoneRevisions(.healthy) == [1], "the row is tombstoned, never deleted")
    }

    @Test("Delete All: every row purged; the relaunch holds no record")
    func deleteAllStaysEmpty() async throws {
        let scene = try CutoverScene.make("b21_delete_all"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        scene.model.deleteAllCatalog()
        try await scene.relaunch()
        #expect(scene.model.records.isEmpty)
    }
}

// MARK: - Gap 4: the direct JSON-store callers

@Suite("Catalog direct-save sensor — every save goes through the model's funnels", .serialized)
@MainActor
struct CatalogDirectSaveSensorTests {

    @Test("SENSOR: no app file but the funnels calls catalogStore.scheduleSave / saveNow / saveAsync / saveAcknowledged")
    func noDirectStoreSaves() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VideoScan")
        // The three funnels, and the Switch's flush (the JSON path on purpose:
        // before the switch catalog.json IS the catalog).
        let allowed: [String: Int] = ["VideoScanModel.swift": 2, "ImportToSQLitePhases.swift": 1, "CatalogSwitchToSQLite.swift": 1]
        var offenders: [String] = []
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        let pattern = try Regex(#"catalogStore\.(scheduleSave|saveNow|saveAsync|saveAcknowledged)\("#)
        for file in files where file.lastPathComponent != "CatalogStore.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            let count = text.matches(of: pattern).count
            if count > (allowed[file.lastPathComponent] ?? 0) { offenders.append("\(file.lastPathComponent) ×\(count)") }
        }
        #expect(offenders.isEmpty, Comment(rawValue: offenders.joined(separator: ", ")))
    }
}

// MARK: - Gap 5: Adopt This SQLite Catalog…

@Suite("Catalog adopt — a catalog.sqlite restored below the high-water may be adopted by a person", .serialized)
@MainActor
struct CatalogAdoptTests {

    @Test("restored below the high-water: offered with both numbers; Adopt → writable, the edit made meanwhile is saved")
    func adoptRestoredCatalog() async throws {
        let scene = try CutoverScene.make("b21_adopt"); defer { scene.cleanup() }
        try await scene.importCatalog()
        _ = try await scene.sqliteLoad()                          // the display pass, once
        try Data("99\n".utf8).write(to: CatalogHighWater.url(besideDatabaseAt: scene.databaseURL))
        try scene.writeLatch()
        scene.model.records = scene.model.loadCatalogAtLaunch()
        let cutover = scene.model.catalogCutover
        #expect(cutover.canAdopt)
        try scene.record(.healthy).starRating = 3
        let request = try #require(await cutover.adoptRequestIfAdoptable())
        #expect(request.highWater == 99)
        #expect(request.databaseGeneration < 99)
        let outcome = await cutover.adopt(request)
        #expect(outcome == .adopted(from: request.databaseGeneration, to: 99))
        #expect(scene.model.isReadOnly == false)
        #expect(cutover.canAdopt == false)
        #expect(scene.model.saveCatalogNow())
        #expect(try await scene.reloaded(.healthy).starRating == 3)
    }

    @Test("a writable catalog.sqlite is not offered for adoption")
    func notOfferedWhenWritable() async throws {
        let scene = try CutoverScene.make("b21_adopt_no"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        #expect(scene.model.catalogCutover.canAdopt == false)
        #expect(await scene.model.catalogCutover.adoptRequestIfAdoptable() == nil)
    }
}

// MARK: - Codex P1-4 / P1-5: the Switch door

@Suite("Switch Catalog to SQLite B2.1 — every accepted edit is in the import; the designation comes from the imported bytes", .serialized)
@MainActor
struct CatalogSwitchB21Tests {

    private static func jsonEnvironment(_ scene: CutoverScene, store: CatalogStore, records: [VideoRecord],
                                        freezes: CatalogSwitchTests.Freezes,
                                        runImport: @escaping @MainActor () async -> CatalogSwitchImportResult) -> CatalogSwitchEnvironment {
        var env = CatalogSwitchTests.environment(scene, freezes: freezes, runImport: runImport)
        env.flushJSON = { store.saveNow(records: records) }
        env.hasUnsavedJSON = { store.hasUnsavedChanges }
        return env
    }

    @Test("P1-4: an edit waiting in the JSON store's debounce BEFORE the switch is flushed, so the import carries it")
    func pendingEditIsFlushedFirst() async throws {
        let scene = try CutoverScene.make("b21_switch_flush"); defer { scene.cleanup() }
        try await scene.importCatalog()
        let store = CatalogStore(directory: scene.folder)
        let records = store.load()
        let healthy = try #require(records.first { $0.id.uuidString == PoisonedCatalogFixture.id(.healthy) })
        healthy.userNotes = "typed just before Switch"
        store.scheduleSave(records: records)
        let phase = await CatalogSwitchRun.run(Self.jsonEnvironment(scene, store: store, records: records, freezes: .init()) {
            do { try scene.recertify(); try await scene.importCatalog(); return .imported } catch { return .notImported("\(error)") }
        })
        guard case .done = phase else { Issue.record("expected .done, got \(phase)"); return }
        #expect(try await scene.reloaded(.healthy).userNotes == "typed just before Switch")
    }

    @Test("P1-4: an edit accepted while the import ran stops the switch — saved to catalog.json, no latch, nothing frozen")
    func editDuringImportStops() async throws {
        let scene = try CutoverScene.make("b21_switch_during"); defer { scene.cleanup() }
        try await scene.importCatalog()
        let store = CatalogStore(directory: scene.folder)
        let records = store.load()
        let healthy = try #require(records.first { $0.id.uuidString == PoisonedCatalogFixture.id(.healthy) })
        let freezes = CatalogSwitchTests.Freezes()
        let phase = await CatalogSwitchRun.run(Self.jsonEnvironment(scene, store: store, records: records, freezes: freezes) {
            do {
                try scene.recertify(); try await scene.importCatalog()
                healthy.userNotes = "typed while the import ran"
                store.scheduleSave(records: records)
                return .imported
            } catch { return .notImported("\(error)") }
        })
        #expect(phase == .failed("an edit was made while the import ran (it is saved in catalog.json) — run Switch again; nothing was switched"))
        #expect(FileManager.default.fileExists(atPath: scene.latchURL.path) == false)
        #expect(freezes.calls.isEmpty)
        let json = CatalogStore(directory: scene.folder).load()
        #expect(json.first { $0.id == healthy.id }?.userNotes == "typed while the import ran")
    }

    @Test("P1-5: the designation moved into catalog_state is the one in the imported catalog.json, not one captured before")
    func designationFromImportedBytes() async throws {
        let scene = try CutoverScene.make("b21_switch_designation"); defer { scene.cleanup() }
        try scene.writeDesignation(rootPath: "/Volumes/Archive/OLD")
        try await scene.importCatalog()
        var latest: MasterArchiveDesignation?
        let phase = await CatalogSwitchRun.run(CatalogSwitchTests.environment(scene, freezes: .init()) {
            do {
                latest = try scene.writeDesignation(rootPath: "/Volumes/Archive/NEW")
                try await scene.importCatalog()
                return .imported
            } catch { return .notImported("\(error)") }
        })
        guard case .done = phase else { Issue.record("expected .done, got \(phase)"); return }
        let launch = try #require(try? await SQLiteLaunchRead.read(scene.databaseURL).get())
        await launch.repository.close()
        #expect(CatalogCommitter.designation(fromJSON: launch.designationJSON)?.rootPath == "/Volumes/Archive/NEW")
        #expect(CatalogCommitter.designation(fromJSON: launch.designationJSON) == latest)
    }
}
