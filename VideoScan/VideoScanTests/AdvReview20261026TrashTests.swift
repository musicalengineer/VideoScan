// AdvReview20261026TrashTests.swift
// Regression pins for the 2026-10-26 nightly adversarial review
// (docs/reviews/adversarial/2026-10-26.md), P2 F2 (MOPS-1): ⌘⌫ asked "is
// this the only copy we know of?" before the alert, but at the move the
// answer was only logged and the file moved anyway. Now the move never
// exceeds the confirmation: at each file's turn a row the person did not
// confirm is held, and so is a row that became the only known copy after
// the alert said another copy survives. A row the alert DID warn about
// still moves (Rick decides).
//
// Every move goes to a sandbox "Trash" (SandboxTrash), never the real one.

import Foundation
import Testing
@testable import VideoScan

@Suite(.serialized)
@MainActor
struct CatalogTrashOnlyCopyAtTheMoveTests {

    /// A temp folder, a sandbox Trash and an isolated model.
    @MainActor
    struct Rig {
        let root: URL
        let folder: URL
        let trash: SandboxTrash
        let model: VideoScanModel
        let bytes = Data((0..<2_048).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) })

        init() throws {
            let fm = FileManager.default
            root = fm.temporaryDirectory
                .appendingPathComponent("test_onlycopy_atmove_\(UUID().uuidString.prefix(8))", isDirectory: true)
            folder = root.appendingPathComponent("Sources", isDirectory: true)
            let trashDir = root.appendingPathComponent("trash", isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try fm.createDirectory(at: trashDir, withIntermediateDirectories: true)
            trash = SandboxTrash(dir: trashDir)
            model = VideoScanModel()
            model.catalogStore = CatalogStore(directory: root.appendingPathComponent("catalog", isDirectory: true))
            model.mediaLedger = MediaLedger(directory: root.appendingPathComponent("ledger", isDirectory: true))
            model.ignoredContentStore = IgnoredContentStore(directory: root.appendingPathComponent("ignored", isDirectory: true))
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }

        /// A file on disk and its row; same `md5` = same bytes (a copy).
        func file(_ name: String, md5: String = "synthetic-md5-0001") throws -> VideoRecord {
            let url = folder.appendingPathComponent(name)
            try bytes.write(to: url)
            let r = VideoRecord()
            r.fullPath = url.path
            r.filename = url.lastPathComponent
            r.directory = url.deletingLastPathComponent().path
            r.ext = url.pathExtension
            r.partialMD5 = md5
            r.sizeBytes = Int64(bytes.count)
            return r
        }
    }

    private func onDisk(_ r: VideoRecord) -> Bool { FileManager.default.fileExists(atPath: r.fullPath) }

    /// The reviewer's red test, with the confirmation handed in.
    @Test func aCopyThatBecameTheOnlyOneAfterTheConfirmationIsHeld() async throws {
        let rig = try Rig(); defer { rig.cleanup() }
        let recA = try rig.file("test_clip_a.mov")
        let recB = try rig.file("test_clip_b.mov")
        rig.model.records = [recA, recB]

        // confirmThenTrash: the plan behind the alert — B survives, so A is
        // NOT the only copy: no warning, Return moves.
        let confirmed = rig.model.catalogTrashPlan(for: [recA])
        try #require(confirmed.toTrash == [recA.id])
        try #require(confirmed.onlyCopy.isEmpty)

        // While the alert is up another door takes B to the Trash.
        recB.purgedAt = Date()

        // Return pressed: the confirmed rows go to the one Trash routine.
        let result = await rig.model.trashSelectedRecords([recA], confirmed: confirmed,
                                                          fileOperation: rig.trash.operation)

        #expect(onDisk(recA),
                "the last known copy moved to the Trash on a confirmation that said another copy survives")
        #expect(rig.trash.attempts.isEmpty, "nothing was handed to the Trash")
        #expect(recA.purgedAt == nil)
        #expect(result.succeeded == 0)
        #expect(result.refused.map(\.reason) == [VideoScanModel.becameOnlyCopyHeldNote], "\(result.refused.map(\.reason))")
    }

    /// Control: the alert warned that A is the only copy and the person
    /// clicked Move to Trash anyway — it moves (still Rick's call).
    @Test func aWarnedOnlyCopyStillMoves() async throws {
        let rig = try Rig(); defer { rig.cleanup() }
        let recA = try rig.file("test_clip_a.mov")
        rig.model.records = [recA]
        let confirmed = rig.model.catalogTrashPlan(for: [recA])
        try #require(confirmed.onlyCopy == [recA.id])

        let result = await rig.model.trashSelectedRecords([recA], confirmed: confirmed,
                                                          fileOperation: rig.trash.operation)
        #expect(!onDisk(recA) && rig.trash.attempts == [recA.fullPath])
        #expect(result.succeeded == 1 && result.refused.isEmpty)
    }

    /// The held-back set: a row the confirmation held back (here: its drive
    /// looked offline) that is movable by the time Return is pressed is
    /// held — the count shown is the set handed on.
    @Test func aRowTheConfirmationHeldBackNeverMoves() async throws {
        let rig = try Rig(); defer { rig.cleanup() }
        let recA = try rig.file("test_clip_a.mov")
        let recB = try rig.file("test_clip_b.mov", md5: "synthetic-md5-0002")
        rig.model.records = [recA, recB]
        // The alert: A held as "drive not connected", B to move.
        let confirmed = rig.model.catalogTrashPlan(for: [recA, recB], isOffline: { $0.id == recA.id })
        try #require(confirmed.toTrash == [recB.id])
        try #require(confirmed.refused.map(\.id) == [recA.id])

        let result = await rig.model.trashSelectedRecords([recA, recB], confirmed: confirmed,
                                                          fileOperation: rig.trash.operation)
        #expect(onDisk(recA) && recA.purgedAt == nil, "A was never confirmed")
        #expect(!onDisk(recB), "B was confirmed and moves")
        #expect(rig.trash.attempts == [recB.fullPath])
        #expect(result.refused.map(\.reason) == [VideoScanModel.notConfirmedHeldNote], "\(result.refused.map(\.reason))")
    }

    /// Two selected copies of a clip whose third copy (unselected) went away
    /// after the alert: the first moves (the second still holds the bytes),
    /// the second is held — one copy always stays on disk.
    @Test func twoSelectedCopiesWhoseThirdWentAwayLeaveOne() async throws {
        let rig = try Rig(); defer { rig.cleanup() }
        let recA = try rig.file("test_clip_a.mov")
        let recB = try rig.file("test_clip_b.mov")
        let recC = try rig.file("test_clip_c.mov")
        rig.model.records = [recA, recB, recC]
        let confirmed = rig.model.catalogTrashPlan(for: [recA, recB])
        try #require(confirmed.toTrash == [recA.id, recB.id])
        try #require(confirmed.onlyCopy.isEmpty, "C survives: no warning")

        recC.purgedAt = Date()   // another door, while the alert is up

        let result = await rig.model.trashSelectedRecords([recA, recB], confirmed: confirmed,
                                                          fileOperation: rig.trash.operation)
        #expect(!onDisk(recA) && onDisk(recB), "A moved while B still held the bytes; B is now the last copy")
        #expect(recB.purgedAt == nil)
        #expect(result.succeeded == 1)
        #expect(result.refused.map(\.reason) == [VideoScanModel.becameOnlyCopyHeldNote])
    }

    /// Isolation: a surviving "copy" that cannot really survive (on a
    /// RETIRED drive) does not let the last
    /// live copy move unwarned.
    @Test func aCopyOnARetiredDriveDoesNotCount() async throws {
        let rig = try Rig(); defer { rig.cleanup() }
        let recA = try rig.file("test_clip_a.mov")
        let recB = try rig.file("test_clip_b.mov")
        rig.model.records = [recA, recB]
        let confirmed = rig.model.catalogTrashPlan(for: [recA])
        try #require(confirmed.onlyCopy.isEmpty)

        // After the alert, B's folder becomes a retired drive.
        let retired = CatalogScanTarget(searchPath: rig.folder.path)
        retired.retiredAt = Date()
        // (A shares the folder, so only B's survival is in question: the
        // retired-root rule makes B no witness; A itself is still checked.)
        rig.model.scanTargets = [retired]

        let result = await rig.model.trashSelectedRecords([recA], confirmed: confirmed,
                                                          fileOperation: rig.trash.operation)
        #expect(onDisk(recA), "a copy on a retired drive is not a surviving copy")
        #expect(result.refused.map(\.reason) == [VideoScanModel.becameOnlyCopyHeldNote], "\(result.refused.map(\.reason))")
    }

    /// SCALE: 100k rows, 500 selected rows each with a live copy, none
    /// warned — the per-turn only-copy question for all 500 stays in budget.
    @Test func scale_perTurnCheckAt100kWithinBudget() {
        let model = VideoScanModel()
        var all: [VideoRecord] = []
        all.reserveCapacity(100_000)
        for i in 0..<100_000 {
            let r = VideoRecord()
            r.fullPath = "/tmp/onlycopy-scale/\(i / 1000)/clip_\(i).mov"
            r.filename = "clip_\(i).mov"
            r.partialMD5 = "m\(i % 99_500)"     // rows 0..<500 have a copy at 99_500..<100_000
            r.sizeBytes = 10_000
            all.append(r)
        }
        model.records = all
        let selection = Array(all[0..<500])
        let confirmed = Set(selection.map(\.id))
        let copies = CatalogTrashTurnCopies(batch: selection)
        let t0 = Date()
        var held = 0
        for rec in selection {
            if model.catalogTrashTurnProblem(rec, confirmed: confirmed, warnedOnlyCopy: [], copies: copies) != nil {
                held += 1
            } else {
                copies.handedOn(rec.id)
            }
        }
        let took = -t0.timeIntervalSinceNow
        #expect(held == 0, "each has a live copy outside the selection")
        // Budget: 1 s for 500 turns over 100k rows in Debug. The first,
        // whole-catalog pass per turn took 19.5 s (39 ms a turn); the pool
        // makes it one catalog pass per batch.
        #expect(took < 1.0, "500 per-turn only-copy checks over 100k rows took \(took) s")
        print("[scale] 500 per-turn only-copy checks over 100k rows: \(String(format: "%.3f", took)) s")
    }
}
