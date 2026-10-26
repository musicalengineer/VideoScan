// RemovalReservationRound3Tests.swift
// Codex closing pass 2026-10-26, F4/F5 barrier recipes: the reservation
// must know a file by its PHYSICAL identity (an alias spelling of a leaving
// copy is no survivor), and a removal must PIN the copy it relies on so no
// other door (here: Delete Confirmed Junk) removes that copy meanwhile.
// Every move goes to a sandbox folder, never the real Trash.

import CryptoKit
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@Suite(.serialized) @MainActor
struct RemovalReservationRound3Tests {

    @MainActor
    struct Rig {
        let root: URL, folder: URL, trashDir: URL
        let model: VideoScanModel
        let bytes = Data((0..<4_096).map { UInt8(truncatingIfNeeded: $0 &* 29 &+ 3) })

        init() throws {
            let fm = FileManager.default
            root = fm.temporaryDirectory.appendingPathComponent("test_reserve3_\(UUID().uuidString.prefix(8))", isDirectory: true)
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

        /// A row for the file at `url` (written with the shared bytes unless
        /// `write` is false), SHA-256 fixity stamped through that spelling.
        func row(_ url: URL, write: Bool = true) throws -> VideoRecord {
            if write { try bytes.write(to: url) }
            let r = VideoRecord()
            r.fullPath = url.path; r.filename = url.lastPathComponent
            r.directory = url.deletingLastPathComponent().path; r.ext = url.pathExtension
            r.partialMD5 = "reserve3-md5"; r.sizeBytes = Int64(bytes.count)
            r.streamTypeRaw = StreamType.videoAndAudio.rawValue
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            r.contentFixity = ContentFixity.captured(path: url.path, digest: digest, byteCount: Int64(bytes.count))
            return r
        }
    }

    /// Recipe 4: a third row names A through a symlinked directory. With A
    /// parked mid-move, B's batch must not prove itself against A's alias.
    @Test func anAliasOfALeavingCopyIsNoSurvivor() async throws {
        let rig = try Rig(); defer { rig.cleanup() }
        let recA = try rig.row(rig.folder.appendingPathComponent("test_clip_a.mov"))
        let recB = try rig.row(rig.folder.appendingPathComponent("test_clip_b.mov"))
        let link = rig.root.appendingPathComponent("Linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: rig.folder)
        let alias = try rig.row(link.appendingPathComponent("test_clip_a.mov"), write: false)
        rig.model.records = [recA, recB, alias]
        let planA = rig.model.catalogTrashPlan(for: [recA])
        let planB = rig.model.catalogTrashPlan(for: [recB])
        try #require(planA.onlyCopy.isEmpty && planB.onlyCopy.isEmpty)

        let parking = ParkingTrash(dir: rig.trashDir)
        let model = rig.model
        let first = Task { @MainActor in
            await model.trashSelectedRecords([recA], confirmed: planA, fileOperation: parking.operation).succeeded
        }
        await Task.detached { ParkingTrash.block(parking.entered) }.value
        _ = await model.trashSelectedRecords([recB], confirmed: planB, fileOperation: parking.operation)
        parking.proceed.signal()
        _ = await first.value

        let aLeft = !FileManager.default.fileExists(atPath: recA.fullPath)
        let bLeft = !FileManager.default.fileExists(atPath: recB.fullPath)
        #expect(!(aLeft && bLeft), "both physical copies moved — the alias vouched for a leaving file")
    }

    /// Recipe 5: ⌘⌫ A relies on B; B is Confirmed Junk. With A parked
    /// mid-move, Delete Confirmed Junk must not remove B.
    @Test func aCopyReliedOnByAMoveIsNotRemovedByAnotherDoor() async throws {
        let rig = try Rig(); defer { rig.cleanup() }
        let recA = try rig.row(rig.folder.appendingPathComponent("test_clip_a.mov"))
        let recB = try rig.row(rig.folder.appendingPathComponent("test_clip_b.mov"))
        recB.mediaDisposition = .confirmedJunk
        rig.model.records = [recA, recB]
        let planA = rig.model.catalogTrashPlan(for: [recA])
        try #require(planA.onlyCopy.isEmpty)
        let junk = await rig.model.freezeJunkSnapshot([recB], isOffline: { _ in false })
        try #require(junk.moveCount == 1, "B is frozen as junk to move")

        let parking = ParkingTrash(dir: rig.trashDir)
        let model = rig.model
        let first = Task { @MainActor in
            await model.trashSelectedRecords([recA], confirmed: planA, fileOperation: parking.operation).succeeded
        }
        await Task.detached { ParkingTrash.block(parking.entered) }.value
        let junkResult = await model.trashFrozenJunk(junk, fileOperation: parking.operation)
        parking.proceed.signal()
        _ = await first.value

        let aLeft = !FileManager.default.fileExists(atPath: recA.fullPath)
        let bLeft = !FileManager.default.fileExists(atPath: recB.fullPath)
        #expect(!(aLeft && bLeft), "A moved relying on B while Delete Junk removed B")
        #expect(junkResult.succeeded == 0, "B is relied on by A's move")
    }
}
