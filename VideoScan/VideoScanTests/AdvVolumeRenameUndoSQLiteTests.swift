// AdvVolumeRenameUndoSQLiteTests.swift
//
// Adversarial review 2026-10-18, item 2 (P2, invariant VOL-5): after the
// flip to catalog.sqlite a volume rename could not be undone.
//
// Mechanism (pre-fix): since cutover B2.3 `snapshotCatalog` returns a
// sealed `catalog.pre-volume-rename.<stamp>.sqlite`, so the migration now
// runs (before B2.3 it refused for want of a snapshot). The dialog's Undo
// read that path with `CatalogStore.loadRecords(fromSnapshotAtPath:)` — the
// catalog.json decoder — got nil, said "Couldn't read the pre-update
// snapshot", and left every record on the new volume path.
//
// Fix hazard codex named (pinned here too): Undo used to swap the whole
// records array for the snapshot and purge the ids the snapshot lacked.
// Taught only to read the .sqlite copy, that would have purged every record
// added since the migration (and written the SQLite load losses back over
// live values). Undo now reverts exactly what the migration wrote, record by
// record, and removes nothing.
//
// Dimensions (CLAUDE.md feature-test checklist):
//   LOGIC     Undo reads the .sqlite copy and puts paths, directories and
//             the volume name back; a record added since stays; an edit made
//             since stays; a record changed since is left alone; a .json
//             safety copy is refused in words and never read (slice 2b)
//   SCALE     100k records through the revert, explicit time budget
//   ISOLATION every case in a CutoverScene sandbox, never Application Support
//   SENSOR    relaunch from catalog.sqlite after Undo: old paths stored, the
//             added record NOT purged
//   MEDIA     N/A — no media is opened.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Adv — volume rename Undo under catalog.sqlite", .serialized)
@MainActor
struct AdvVolumeRenameUndoSQLiteTests {

    static let oldRoot = "/Volumes/Fixture"
    static let newRoot = "/Volumes/FixtureRenamed"

    /// What `migrateRenamedVolume`'s apply step writes, on every record
    /// under the old root (the UUID gate is the migration's business).
    static func migrate(_ model: VideoScanModel) -> Int {
        var n = 0
        for rec in model.records {
            guard let newPath = VideoScanModel.rewritePathPrefix(rec.fullPath, from: oldRoot, to: newRoot) else { continue }
            rec.fullPath = newPath
            rec.directory = VideoScanModel.rewritePathPrefix(rec.directory, from: oldRoot, to: newRoot)
                ?? (newPath as NSString).deletingLastPathComponent
            rec.scanContext.volumeName = "FixtureRenamed"
            n += 1
        }
        return n
    }

    static func notice(_ snapshot: String) -> VolumeRenameNotice {
        VolumeRenameNotice(kind: .migrated(undoSnapshotPath: snapshot), targetID: UUID(),
                           oldVolumeName: "Fixture", newVolumeName: "FixtureRenamed",
                           oldTargetPath: oldRoot, newTargetPath: newRoot,
                           migratedCount: 1, mismatchedCount: 0, driftDetected: false)
    }

    struct Before: Equatable {
        let fullPath: String
        let directory: String
        let volumeName: String
    }

    static func before(_ model: VideoScanModel) -> [UUID: Before] {
        Dictionary(uniqueKeysWithValues: model.records.map {
            ($0.id, Before(fullPath: $0.fullPath, directory: $0.directory, volumeName: $0.scanContext.volumeName))
        })
    }

    static func addedRecord() -> VideoRecord {
        let r = VideoRecord()
        r.filename = "added-after.mov"
        r.fullPath = newRoot + "/Clips/added-after.mov"
        r.directory = newRoot + "/Clips"
        r.sizeBytes = 4_242
        return r
    }

    @Test("Undo reads the .sqlite safety copy it was given and puts every rewritten record back")
    func undoReadsTheSafetyCopyItWasGiven() async throws {
        let scene = try CutoverScene.make("adv_vr_undo"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let was = Self.before(scene.model)
        let snapshot = try #require(scene.model.snapshotCatalog(prefix: "pre-volume-rename"))
        #expect(snapshot.hasSuffix(".sqlite"))
        #expect(Self.migrate(scene.model) > 0)
        #expect(scene.model.saveCatalogNow())

        #expect(await scene.model.undoVolumeRenameMigration(Self.notice(snapshot)),
                "Undo could not read the safety copy the migration wrote")
        for rec in scene.model.records {
            let b = try #require(was[rec.id])
            #expect(Before(fullPath: rec.fullPath, directory: rec.directory, volumeName: rec.scanContext.volumeName) == b,
                    Comment(rawValue: rec.filename))
        }
        // Carried over from VolumeRenameMigrationTests' JSON round trip (its
        // .json copy is refused since slice 2b): Undo suppresses the auto
        // pass for the old volume so the next rebuild does not redo it.
        #expect(scene.model.volumeRenameAutoSuppressed.contains(PathScope.normalize(Self.oldRoot)))
        #expect(scene.model.pendingVolumeRenameNotice == nil)
    }

    @Test("SENSOR: a record added and an edit made after the migration survive Undo — and the relaunch from catalog.sqlite")
    func undoKeepsWhatChangedSince() async throws {
        let scene = try CutoverScene.make("adv_vr_undo_keep"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let healthy = try scene.record(.healthy)
        let healthyPath = healthy.fullPath
        let snapshot = try #require(scene.model.snapshotCatalog(prefix: "pre-volume-rename"))
        _ = Self.migrate(scene.model)
        #expect(scene.model.saveCatalogNow())
        // After the migration, before Undo: a new record, and a note.
        let added = Self.addedRecord()
        scene.model.records.append(added)
        healthy.userNotes = "typed after the rename"
        #expect(scene.model.saveCatalogNow())

        #expect(await scene.model.undoVolumeRenameMigration(Self.notice(snapshot)))
        #expect(healthy.fullPath == healthyPath)
        #expect(healthy.userNotes == "typed after the rename", "Undo reverts the rename, not later edits")
        #expect(scene.model.records.contains { $0.id == added.id }, "a record added since the migration must not leave with Undo")
        #expect(!scene.sandbox.catalogLogText().contains("START purge"), "Undo removes nothing, so it purges nothing")

        let reloaded = try await scene.sqliteLoad()
        #expect(reloaded.records.first { $0.id == healthy.id }?.fullPath == healthyPath)
        #expect(reloaded.records.first { $0.id == healthy.id }?.userNotes == "typed after the rename")
        #expect(reloaded.records.contains { $0.id == added.id }, "the added record was purged from catalog.sqlite")
    }

    @Test("a record moved since the migration is left alone and counted")
    func undoLeavesARecordChangedSinceAlone() async throws {
        let scene = try CutoverScene.make("adv_vr_undo_moved"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let healthy = try scene.record(.healthy)
        let snapshot = try #require(scene.model.snapshotCatalog(prefix: "pre-volume-rename"))
        _ = Self.migrate(scene.model)
        let moved = Self.newRoot + "/Elsewhere/" + healthy.filename
        healthy.fullPath = moved
        let copy = try #require(await scene.model.loadSafetyCopy(atPath: snapshot))
        let revert = scene.model.revertVolumeRenameRewrites(from: copy, notice: Self.notice(snapshot))
        #expect(revert.leftAlone == 1)
        #expect(revert.reverted > 0)
        #expect(healthy.fullPath == moved)
    }

    /// JSON gone, slice 2b (2026-10-21): a pre-cutover
    /// `catalog.pre-volume-rename.*.json` safety copy is never read. Undo
    /// refuses in words, the records keep the new volume path, and the copy
    /// is left exactly as it was.
    @Test("a .json safety copy (from before the switch) is refused in words — Undo changes nothing and the copy is untouched")
    func jsonSafetyCopyIsRefused() async throws {
        let scene = try CutoverScene.make("adv_vr_undo_json"); defer { scene.cleanup() }
        scene.model.records = scene.model.catalogStore.load()
        #expect(!scene.model.catalogCutover.isSQLiteAuthority)
        let snapshot = try #require(scene.model.snapshotCatalog(prefix: "pre-volume-rename"))
        #expect(snapshot.hasSuffix(".json"))
        let copyBefore = try Data(contentsOf: URL(fileURLWithPath: snapshot))
        #expect(Self.migrate(scene.model) > 0)
        let migrated = Self.before(scene.model)

        #expect(await scene.model.undoVolumeRenameMigration(Self.notice(snapshot)) == false)
        #expect(Self.before(scene.model) == migrated, "a refused Undo changes no record")
        #expect(scene.model.pendingVolumeRenameNotice == nil)
        #expect(try Data(contentsOf: URL(fileURLWithPath: snapshot)) == copyBefore)
        let log = scene.sandbox.catalogLogText()
        #expect(log.contains("REFUSED reading the safety copy \(snapshot) — \(VideoScanModel.jsonSafetyCopyWords)"), Comment(rawValue: log))
        #expect(await scene.model.loadSafetyCopy(atPath: snapshot) == nil)
    }

    @Test("SCALE: reverting 100k rewritten records stays inside the budget")
    func revertScale() async throws {
        let scene = try CutoverScene.make("adv_vr_undo_scale"); defer { scene.cleanup() }
        let n = 100_000
        var live: [VideoRecord] = []
        var copy: [VideoRecord] = []
        live.reserveCapacity(n)
        copy.reserveCapacity(n)
        for i in 0..<n {
            let old = VideoRecord()
            old.filename = "row-\(i).mov"
            old.directory = Self.oldRoot + "/Bulk/\(i / 1_000)"
            old.fullPath = old.directory + "/" + old.filename
            old.scanContext.volumeName = "Fixture"
            copy.append(old)
            let rec = VideoRecord(id: old.id)
            rec.filename = old.filename
            rec.directory = Self.newRoot + "/Bulk/\(i / 1_000)"
            rec.fullPath = rec.directory + "/" + rec.filename
            rec.scanContext.volumeName = "FixtureRenamed"
            live.append(rec)
        }
        scene.model.records = live
        let clock = ContinuousClock()
        let start = clock.now
        let revert = scene.model.revertVolumeRenameRewrites(from: copy, notice: Self.notice("/unused.sqlite"))
        let elapsed = clock.now - start
        #expect(revert.reverted == n)
        #expect(scene.model.records[n - 1].fullPath == copy[n - 1].fullPath)
        #expect(elapsed < .seconds(5), "revert of \(n) records took \(elapsed)")
    }
}
