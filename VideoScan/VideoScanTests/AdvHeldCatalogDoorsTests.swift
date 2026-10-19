// AdvHeldCatalogDoorsTests.swift
//
// Adversarial review 2026-10-18, items 8, 9 and 10 (P3, invariants MOPS-7 /
// MOPS-9): three doors that cutover B2.3 taught to ask catalog.sqlite before
// changing a removal marker, and what each one does when the catalog says
// no (held by a job, or blocked read-only).
//
//   #10 AdvUndoPurgeWhileHeldTests — Undo of Remove from Catalog while the
//       catalog is held: `clearRemoval` refuses; `undoLastPurge` used to
//       treat "nothing restored" as "nothing left to restore", drop the
//       banner and say nothing. Now the banner stays on the rows still
//       removed, with the refusal's words, and a later Undo finishes.
//   #9  AdvRelocateBucketBHeldTests — Migrate's Bucket B (source not found)
//       under a held catalog: `markSourceNotFound` wrote nothing, but the
//       caller still counted every row as "marked", and each refused row
//       wrote its own console line. Now only marked rows are counted and the
//       refusal is ONE line (console + relocate.log) with the count.
//   #8  AdvJunkDeleteHeldTests — tests only (the finding was "no test"):
//       Delete Junk under a held or read-only catalog refuses the file
//       BEFORE any disk work (file stays, outcome held, row untouched), and
//       a disk fact the catalog cannot record says "NOT RECORDED".
//
// Dimensions (CLAUDE.md feature-test checklist):
//   LOGIC     each door held / blocked, then released
//   SCALE     #10 the Undo's id loop is the existing O(batch) index walk
//             (GH #143 scale test unchanged); #9 one summary line however
//             many rows are refused — pinned at 2,000 refused rows
//   ISOLATION every case in a CutoverScene sandbox (temp folder); the junk
//             file is a temp file removed through the test seam, never the
//             real Trash
//   SENSOR    the words on screen (banner error, one console line)
//   MEDIA     N/A — no media is opened (a byte file stands in).

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

/// The console as the person sees it (the dashboard flushes on a debounce).
@MainActor
private func consoleText(_ model: VideoScanModel) async -> String {
    try? await Task.sleep(nanoseconds: 400_000_000)
    return model.dashboard.consoleLines.joined(separator: "\n")
}

// MARK: - #10 Undo of Remove from Catalog while held

@Suite("Adv — Undo of Remove from Catalog while the catalog is held keeps the banner and says why", .serialized)
@MainActor
struct AdvUndoPurgeWhileHeldTests {

    @Test("held: nothing restored, the banner stays on the row with the refusal's words; released: Undo finishes")
    func undoWhileHeldKeepsTheBanner() async throws {
        let scene = try CutoverScene.make("adv_undo_purge_held"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let healthy = try scene.record(.healthy)
        #expect(scene.model.purgeRecords(ids: [healthy.id]) == 1)
        #expect(scene.model.saveCatalogNow())
        await scene.hold()

        #expect(scene.model.undoLastPurge() == false)
        #expect(healthy.purgedAt != nil, "the held catalog refused the restore")
        let batch = try #require(scene.model.lastPurgedBatch, "the banner vanished with nothing restored")
        #expect(batch.ids == [healthy.id])
        let words = try #require(scene.model.lastPurgeUndoError, "no words on screen")
        #expect(words.contains("can't restore \(healthy.filename) right now"), Comment(rawValue: words))

        scene.release()
        #expect(scene.model.undoLastPurge())
        #expect(healthy.purgedAt == nil)
        #expect(scene.model.lastPurgedBatch == nil)
        #expect(scene.model.lastPurgeUndoError == nil)
    }

    @Test("not held: Undo restores and drops the banner, as before")
    func undoNotHeldUnchanged() async throws {
        let scene = try CutoverScene.make("adv_undo_purge_free"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let healthy = try scene.record(.healthy)
        #expect(scene.model.purgeRecords(ids: [healthy.id]) == 1)
        #expect(scene.model.undoLastPurge())
        #expect(healthy.purgedAt == nil)
        #expect(scene.model.lastPurgedBatch == nil)
        #expect(scene.model.lastPurgeUndoError == nil)
    }
}

// MARK: - #9 Relocate Bucket B while held

@Suite("Adv — Migrate's Bucket B counts only rows it marked, and says a refusal once", .serialized)
@MainActor
struct AdvRelocateBucketBHeldTests {

    @Test("held: no row counted as marked, progress still completes, ONE console line with the count")
    func heldBucketBIsNotCountedAsMarked() async throws {
        let scene = try CutoverScene.make("adv_relocate_b_held"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let rows = [try scene.record(.healthy), try scene.record(.curatedConflictA)]
        #expect(scene.model.saveCatalogNow())
        await scene.hold()
        defer { scene.release() }

        scene.model.markBucketBSourcesNotFound(rows, presence: { _ in .missing })   // the source IS gone (2026-10-19: the disk is asked)
        #expect(scene.model.dashboard.relocateManuallyDeleted == 0, "the sheet says rows were marked when none were")
        #expect(scene.model.dashboard.relocateCompleted == 2, "the progress bar still reaches the end")
        for r in rows {
            #expect(r.removal == nil)
            #expect(r.archiveStage != .manuallyDeleted)
        }
        let console = await consoleText(scene.model)
        #expect(console.components(separatedBy: "NOT marked Missing").count - 1 == 1, Comment(rawValue: console))
        #expect(console.contains("2 row(s) whose source was not found were NOT marked Missing"))
        #expect(!console.contains("Reconcile: can't mark"), "one line per refused row is back")
    }

    @Test("not held: every row is marked Missing and counted")
    func freeBucketBMarks() async throws {
        let scene = try CutoverScene.make("adv_relocate_b_free"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let rows = [try scene.record(.healthy), try scene.record(.curatedConflictA)]
        scene.model.markBucketBSourcesNotFound(rows, presence: { _ in .missing })   // the source IS gone (2026-10-19: the disk is asked)
        #expect(scene.model.dashboard.relocateManuallyDeleted == 2)
        #expect(scene.model.dashboard.relocateCompleted == 2)
        for r in rows { #expect(r.removal?.state == .missing) }
    }

    @Test("SCALE: 2,000 refused rows → one line, inside the budget")
    func manyRefusedRowsOneLine() async throws {
        let scene = try CutoverScene.make("adv_relocate_b_scale"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let n = 2_000
        var extra: [VideoRecord] = []
        extra.reserveCapacity(n)
        for i in 0..<n {
            let r = VideoRecord()
            r.filename = "gone-\(i).mov"
            r.fullPath = "/Volumes/Fixture/Gone/gone-\(i).mov"
            r.directory = "/Volumes/Fixture/Gone"
            extra.append(r)
        }
        scene.model.records.append(contentsOf: extra)
        #expect(scene.model.saveCatalogNow())
        await scene.hold()
        defer { scene.release() }
        let clock = ContinuousClock()
        let start = clock.now
        scene.model.markBucketBSourcesNotFound(extra, presence: { _ in .missing })
        let elapsed = clock.now - start
        #expect(scene.model.dashboard.relocateManuallyDeleted == 0)
        #expect(scene.model.dashboard.relocateCompleted == n)
        let console = await consoleText(scene.model)
        #expect(console.components(separatedBy: "NOT marked Missing").count - 1 == 1)
        #expect(elapsed < .seconds(10), "Bucket B of \(n) refused rows took \(elapsed)")
    }
}

// MARK: - #8 Delete Junk under a held / read-only catalog

@Suite("Adv — Delete Junk asks the catalog before it moves a file", .serialized)
@MainActor
struct AdvJunkDeleteHeldTests {

    /// A real byte file in the sandbox, and the healthy row pointed at it.
    static func stage(_ scene: CutoverScene) throws -> (VideoRecord, URL) {
        let healthy = try scene.record(.healthy)
        let dir = scene.folder.deletingLastPathComponent().appendingPathComponent("junkfiles", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(healthy.filename)
        try Data(repeating: 7, count: 1_024).write(to: file)
        healthy.fullPath = file.path
        healthy.directory = dir.path
        #expect(scene.model.saveCatalogNow())
        return (healthy, file)
    }

    static let seam: VideoScanModel.JunkDeletionMode = .removeThroughTestSeam { try FileManager.default.removeItem(at: $0) }

    @Test("held: the file stays where it is, the outcome is held with words, the row is untouched")
    func heldRefusesBeforeDiskWork() async throws {
        let scene = try CutoverScene.make("adv_junk_held"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let (healthy, file) = try Self.stage(scene)
        await scene.hold()
        defer { scene.release() }
        let result = await scene.model.deleteConfirmedJunk([healthy], mode: Self.seam)
        #expect(FileManager.default.fileExists(atPath: file.path), "a held catalog let the file leave")
        #expect(result.refused.count == 1)
        #expect(result.refused.first?.reason.contains("the catalog can't save") == true,
                Comment(rawValue: result.refused.first?.reason ?? "no reason"))
        #expect(result.refused.first?.reason.hasSuffix("nothing moved") == true)
        #expect(healthy.removal == nil)
        #expect(healthy.lifecycleStage != .trashed && healthy.lifecycleStage != .deletedPermanently)
    }

    @Test("read-only (blocked) catalog: the same refusal, the file stays")
    func blockedRefusesBeforeDiskWork() async throws {
        let scene = try CutoverScene.make("adv_junk_blocked"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let (healthy, file) = try Self.stage(scene)
        try #require(scene.model.catalogCutover.committer).block("read-only: adv test")
        let result = await scene.model.deleteConfirmedJunk([healthy], mode: Self.seam)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(result.refused.count == 1)
        #expect(healthy.removal == nil)
    }

    @Test("free: the file leaves through the seam and the row is marked (control)")
    func freeMovesAndMarks() async throws {
        let scene = try CutoverScene.make("adv_junk_free"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let (healthy, file) = try Self.stage(scene)
        let result = await scene.model.deleteConfirmedJunk([healthy], mode: Self.seam)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(result.refused.isEmpty)
        #expect(healthy.removal != nil)
    }

    @Test("NOT RECORDED: a file that already left, on a row whose previous marker change cannot be stored, is said — and the row is left as it was")
    func diskFactNotRecordedIsSaid() async throws {
        let scene = try CutoverScene.make("adv_junk_not_recorded"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let healthy = try scene.record(.healthy)
        #expect(scene.model.saveCatalogNow())
        scene.trash(healthy)                     // revision 1, its commit asked for at once…
        await scene.hold()                       // …but the hold lands first
        defer { scene.release() }
        let marker = RemovalMarker.missing(noticedAt: Date(), lastSeen: nil, reason: .missingAtMigrate)
        scene.model.recordFileLeft(healthy, marker, stage: .trashed, whereNow: "was already gone")
        #expect(healthy.removal?.state == .inTrash, "the row keeps its stored-pending marker")
        #expect(healthy.removalRevision == 1)
        let console = await consoleText(scene.model)
        #expect(console.contains("NOT RECORDED: \(healthy.filename) was already gone"), Comment(rawValue: console))
    }
}
