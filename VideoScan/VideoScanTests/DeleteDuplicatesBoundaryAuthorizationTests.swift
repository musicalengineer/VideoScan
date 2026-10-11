// DeleteDuplicatesBoundaryAuthorizationTests.swift
// Codex delete-engines review 2026-10-09, F5 (P1): "Duplicate authorization
// can be revoked during verification without stopping disposal." The row's
// authorization (`authorizeDuplicateDeletion`: still an extra copy, same
// group, keeper still its keeper) was asked at the row's turn; the post-read
// check covered only the hold rule and the removal boundary only protections
// and pairing. Change the target to Keep while its file is being read → it
// was still trashed.
//
// Now the removal boundary repeats that authorization, after the read and
// immediately before the Trash: any revocation → put back, held, named.

import CryptoKit
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@Suite("Delete Duplicates — the authorization is asked again at the removal (codex F5)", .serialized)
@MainActor
struct DeleteDuplicatesBoundaryAuthorizationTests {

    private struct Rig {
        let dir: URL
        let model: VideoScanModel
        let keeper: VideoRecord
        let copy: VideoRecord
        var root: URL { dir.appendingPathComponent("plans", isDirectory: true) }
        var trashed: Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent("Trash/\(copy.filename)").path) }
        func cleanup() { try? FileManager.default.removeItem(at: dir) }
    }

    private func rig(_ label: String) -> Rig {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test_dupauth_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: dir.appendingPathComponent("catalog", isDirectory: true))
        model.mediaLedger = MediaLedger(directory: dir.appendingPathComponent("ledger", isDirectory: true))
        let size = FileHasher.segmentSize * 2
        let bytes = Data((0..<size).map { UInt8($0 % 193) })
        let group = UUID()
        func rec(_ name: String, _ d: DuplicateDisposition) -> VideoRecord {
            let url = dir.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: bytes)
            let r = VideoRecord()
            r.fullPath = url.path; r.filename = name; r.directory = dir.path
            r.sizeBytes = Int64(size); r.partialMD5 = "same"; r.durationSeconds = 61
            r.duplicateGroupID = group; r.duplicateDisposition = d; r.duplicateConfidence = .high
            return r
        }
        let keeper = rec("keeper.mov", .keep)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        keeper.contentFixity = ContentFixity.captured(path: keeper.fullPath, digest: digest, byteCount: Int64(size))
        let copy = rec("copy.mov", .extraCopy)
        model.records = [keeper, copy]
        return Rig(dir: dir, model: model, keeper: keeper, copy: copy)
    }

    private func reviewedJob(_ r: Rig, hooks: SignatureVerification.Hooks) async throws -> DeleteDuplicatesJob {
        let batch = await r.model.reviewedDuplicateBatch([ReviewedDuplicatePick(recordID: r.copy.id, path: r.copy.fullPath,
                                                                                keeperID: r.keeper.id)])
        return DeleteDuplicatesJob(model: r.model, reviewed: try #require(batch.plans.first), hooks: hooks, planRoot: r.root)
    }

    /// The target is re-marked Keep after its turn's authorization, once it
    /// is read and in quarantine, before the removal.
    @Test func theTargetMarkedKeepAfterItsTurnIsHeld() async throws {
        let r = rig("keep"); defer { r.cleanup() }
        let job = try await reviewedJob(r, hooks: SignatureVerification.Hooks.live.withScratchTrash(in: r.dir))
        let copy = r.copy
        job.testHookAfterQuarantineSaved = { _ in copy.duplicateDisposition = .keep }
        job.start(); await job.task?.value

        let row = try #require(job.plan?.entries.first)
        #expect(row.status != .trashed && row.outcome == .held, "\(row.status): \(row.note)")
        #expect(!r.trashed && FileManager.default.fileExists(atPath: r.copy.fullPath), "put back at its path")
        #expect(row.quarantineDirectory == nil, "nothing left in quarantine")
    }

    /// The keeper is re-elected (no longer Keep) WHILE the copy is being
    /// read (the read is held on the disk thread while the catalog changes).
    @Test func theKeeperReElectedDuringTheReadHoldsTheCopy() async throws {
        let r = rig("reelect"); defer { r.cleanup() }
        nonisolated(unsafe) let keeper = r.keeper
        let flipped = NSLock()
        nonisolated(unsafe) var done = false
        var hooks = SignatureVerification.Hooks.live.withScratchTrash(in: r.dir)
        hooks.didReadBlock = { _ in
            guard flipped.withLock({ () -> Bool in defer { done = true }; return !done }) else { return }
            DispatchQueue.main.sync { MainActor.assumeIsolated { keeper.duplicateDisposition = .extraCopy } }
        }
        let job = try await reviewedJob(r, hooks: hooks)
        job.start(); await job.task?.value

        #expect(flipped.withLock { done }, "fixture: the catalog changed during the read")
        let row = try #require(job.plan?.entries.first)
        #expect(row.status != .trashed && row.outcome == .held, "\(row.status): \(row.note)")
        #expect(!r.trashed && FileManager.default.fileExists(atPath: r.copy.fullPath))
    }

    /// Control: nothing changes → the copy goes to the (sandbox) Trash.
    @Test func anUnchangedAuthorizationStillMoves() async throws {
        let r = rig("control"); defer { r.cleanup() }
        let job = try await reviewedJob(r, hooks: SignatureVerification.Hooks.live.withScratchTrash(in: r.dir))
        job.start(); await job.task?.value
        #expect(job.plan?.entries.first?.status == .trashed, "\(job.plan?.entries.first?.note ?? "-")")
        #expect(r.trashed)
    }
}
