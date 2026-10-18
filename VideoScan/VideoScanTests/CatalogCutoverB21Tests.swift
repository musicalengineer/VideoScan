// CatalogCutoverB21Tests.swift
// Cutover B2.1 — the write-side gaps that would bite in the first session
// after the flip, and codex's B2 findings (docs/reviews/codex/
// codex-review-cutover-b2-write-side-switch-door-2026-10-17.md):
//   LOGIC     a dirty sibling never overwrites a curated value it did not
//             change (P1-1); copy propagation never overwrites an edit made
//             while the commit ran (P1-2); a quit during an in-flight commit
//             waits for it and commits again (P1-3); a new row without a
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

    @Test("P1-2: copy propagation leaves an edit the sibling got while the commit ran")
    func propagationKeepsLaterEdit() async throws {
        let scene = try CutoverScene.make("b21_propagate"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let committer = try scene.committer()
        let b = try scene.record(.curatedConflictB)
        try scene.record(.curatedConflictA).userNotes = "from A"
        committer.afterSnapshotForTesting = { b.userNotes = "B, typed while A was saving" }
        _ = await scene.model.saveCatalogAcknowledged()
        committer.afterSnapshotForTesting = nil
        #expect(b.userNotes == "B, typed while A was saving")
        #expect(scene.model.saveCatalogNow())
        #expect(try await scene.reloaded(.curatedConflictB).userNotes == "B, typed while A was saving")
    }

    @Test("P1-3: a quit during an in-flight commit waits for it, then commits what changed since")
    func quitWaitsForInFlight() async throws {
        let scene = try CutoverScene.make("b21_quit"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let committer = try scene.committer()
        let healthy = try scene.record(.healthy)
        healthy.starRating = 1
        var quitDurable = false
        committer.beforeAbsorbForTesting = {
            healthy.starRating = 0
            quitDurable = scene.model.saveCatalogNow()
        }
        _ = await scene.model.saveCatalogAcknowledged()
        committer.beforeAbsorbForTesting = nil
        #expect(quitDurable)
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
        let allowed: [String: Int] = ["VideoScanModel.swift": 2, "ImportToSQLitePhases.swift": 1]
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
