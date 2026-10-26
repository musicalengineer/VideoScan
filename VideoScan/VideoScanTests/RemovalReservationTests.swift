// RemovalReservationTests.swift
// Codex #150 F4: two removal jobs must never each prove "the other copy
// survives" against the other's file and both move. The one Trash engine
// reserves each file from the door's proof through the move
// (RemovalReservations); a door needing a surviving copy accepts only one
// that is not reserved. Barrier in the disk seam per Codex's recipe.
//
// Every move goes to a sandbox "Trash" folder, never the real one.

import CryptoKit
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

/// A disk seam that parks the FIRST file handed to it until released, so a
/// second job can run while the first is between its proof and its move.
/// (`@unchecked Sendable` + semaphores ≈ a C++ class of std::binary_semaphore.)
final class ParkingTrash: @unchecked Sendable {
    let dir: URL
    let entered = DispatchSemaphore(value: 0)
    let proceed = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var parked = false

    init(dir: URL) { self.dir = dir }

    /// Block the calling (non-async) thread until `s` is signalled.
    nonisolated static func block(_ s: DispatchSemaphore) { s.wait() }

    var operation: @Sendable (URL) throws -> Void {
        { [self] url in
            let first: Bool = lock.withLock { defer { parked = true }; return !parked }
            if first {
                entered.signal()
                proceed.wait()
            }
            try FileManager.default.moveItem(at: url, to: dir.appendingPathComponent("\(UUID().uuidString.prefix(8))_\(url.lastPathComponent)"))
        }
    }
}

@Suite(.serialized) @MainActor
struct RemovalReservationTests {

    @MainActor
    struct Rig {
        let root: URL, folder: URL, trashDir: URL
        let model: VideoScanModel
        let bytes = Data((0..<4_096).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 5) })

        init() throws {
            let fm = FileManager.default
            root = fm.temporaryDirectory.appendingPathComponent("test_reserve_\(UUID().uuidString.prefix(8))", isDirectory: true)
            folder = root.appendingPathComponent("Sources", isDirectory: true)
            trashDir = root.appendingPathComponent("trash", isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try fm.createDirectory(at: trashDir, withIntermediateDirectories: true)
            model = VideoScanModel()
            model.catalogStore = CatalogStore(directory: root.appendingPathComponent("catalog", isDirectory: true))
            model.mediaLedger = MediaLedger(directory: root.appendingPathComponent("ledger", isDirectory: true))
            model.ignoredContentStore = IgnoredContentStore(directory: root.appendingPathComponent("ignored", isDirectory: true))
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }

        /// A file with the shared bytes and its row, SHA-256 fixity stamped.
        func copy(_ name: String) throws -> VideoRecord {
            let url = folder.appendingPathComponent(name)
            try bytes.write(to: url)
            let r = VideoRecord()
            r.fullPath = url.path; r.filename = name
            r.directory = folder.path; r.ext = url.pathExtension
            r.partialMD5 = "reserve-md5"; r.sizeBytes = Int64(bytes.count)
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            r.contentFixity = ContentFixity.captured(path: url.path, digest: digest, byteCount: Int64(bytes.count))
            return r
        }
    }

    @Test func aReservedPathCannotBeReservedTwiceAndIsFreedOnRelease() {
        let path = "/tmp/reserve-unit-\(UUID().uuidString)/Clip.MOV"
        let r = RemovalReservations.shared
        guard case .reserved(let key) = r.reserve(path) else { Issue.record("first reserve held"); return }
        if case .reserved = r.reserve(path.lowercased()) { Issue.record("case-folded spelling reserved twice") }
        #expect(r.isReserved(path))
        r.release(key)
        #expect(!r.isReserved(path))
    }

    /// Codex's recipe: two ⌘⌫ batches for identical A and B, both
    /// confirmed (each saw the other as the surviving copy). A's move is
    /// parked between its proof and its Trash; B's batch runs to the end;
    /// then A resumes. At least one copy must remain on disk.
    @Test func twoBatchesForTwoCopiesNeverMoveBoth() async throws {
        let rig = try Rig(); defer { rig.cleanup() }
        let recA = try rig.copy("test_clip_a.mov")
        let recB = try rig.copy("test_clip_b.mov")
        try #require(recA.contentFixity != nil && recB.contentFixity != nil)
        rig.model.records = [recA, recB]
        let planA = rig.model.catalogTrashPlan(for: [recA])
        let planB = rig.model.catalogTrashPlan(for: [recB])
        try #require(planA.onlyCopy.isEmpty && planB.onlyCopy.isEmpty, "each was confirmed with no warning")

        let parking = ParkingTrash(dir: rig.trashDir)
        let model = rig.model
        let first = Task { @MainActor in
            await model.trashSelectedRecords([recA], confirmed: planA, fileOperation: parking.operation).succeeded
        }
        // Wait (off the main actor) until A is inside its move.
        await Task.detached { ParkingTrash.block(parking.entered) }.value

        let second = await model.trashSelectedRecords([recB], confirmed: planB, fileOperation: parking.operation)
        parking.proceed.signal()
        let firstMoved = await first.value

        let aLeft = !FileManager.default.fileExists(atPath: recA.fullPath)
        let bLeft = !FileManager.default.fileExists(atPath: recB.fullPath)
        #expect(!(aLeft && bLeft), "both copies moved to the Trash — the last copy is gone")
        #expect(aLeft && !bLeft, "A was proven first and moves; B is held while A relies on it")
        #expect(second.refused.map(\.reason) == [RemovalReservations.reliedOnNote], "\(second.refused.map(\.reason))")
        #expect(firstMoved == 1)
    }

    /// The engine's own rule: a file another turn is removing right now is
    /// held, never handed to the disk a second time.
    @Test func aFileAlreadyBeingRemovedIsHeld() async throws {
        let rig = try Rig(); defer { rig.cleanup() }
        let recA = try rig.copy("test_clip_a.mov")
        rig.model.records = [recA]
        let plan = rig.model.catalogTrashPlan(for: [recA])
        guard case .reserved(let key) = RemovalReservations.shared.reserve(recA.fullPath) else {
            Issue.record("could not reserve the fixture"); return
        }
        defer { RemovalReservations.shared.release(key) }
        let trash = SandboxTrash(dir: rig.trashDir)
        let result = await rig.model.trashSelectedRecords([recA], confirmed: plan, fileOperation: trash.operation)
        #expect(FileManager.default.fileExists(atPath: recA.fullPath))
        #expect(trash.attempts.isEmpty)
        #expect(result.refused.map(\.reason) == [RemovalReservations.busyNote], "\(result.refused.map(\.reason))")
    }

    /// Sensor: every door that removes a media file because another copy
    /// stays asks the reservation list about that copy, and the one Trash
    /// engine and Delete Duplicates' own disk worker reserve the file.
    @Test func everyRemovalDoorTakesTheReservation() throws {
        let engine = try SourceTree.appCode(named: "VideoScanModel+JunkDelete.swift")
        #expect(engine.contains("RemovalReservations.shared.reserve(path)"), "the one Trash engine reserves each file")
        let dups = try SourceTree.appCode(named: "DeleteDuplicatesJob.swift")
        // Phase one (proof → quarantine) and phase two (quarantine → Trash),
        // each reserving the duplicate against its keeper.
        #expect(dups.contains("item.path, survivor: item.keeperPath,"), "Delete Duplicates phase one")
        #expect(dups.contains("ticket.originalPath, survivor: ticket.proof.keeperPath,"), "Delete Duplicates phase two")
        #expect(dups.components(separatedBy: "RemovalReservations.shared.whileReserved(").count - 1 == 2)
        let cleanup = try SourceTree.appCode(named: "CleanupTrashJob.swift")
        // Closing pass F4/F5: each door PINS the copy it relies on.
        #expect(cleanup.contains("RemovalReservations.shared.pin([copy.keeper.path], for: path)"), "Cleanup's copy lane")
        let prune = try SourceTree.appCode(named: "VideoScanModel+PruneApply.swift")
        #expect(prune.contains("RemovalReservations.shared.pin([proof.archivePath], for: path)"), "Prune")
        let trash = try SourceTree.appCode(named: "VideoScanModel+TrashSelection.swift")
        #expect(trash.contains("RemovalReservations.shared.pin(copies.map(\\.path), for: path)"), "⌘⌫")
        let publish = try SourceTree.appCode(named: "DerivativeOutputPublish.swift")
        #expect(publish.contains("RemovalReservations.shared.whileReserved("), "Transcode/Reformat replacing its original")
    }
}
