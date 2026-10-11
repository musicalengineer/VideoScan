// DeleteDuplicatesReviewedStampTests.swift
// Codex delete-engines review 2026-10-09, F4 (P1): "Reviewed duplicates are
// not bound to the reviewed disk contents." Only the keeper's stamp was kept
// at the freeze, and a fresh run never compared it: rewrite BOTH files with
// identical new content at unchanged paths → the job verified today's pair
// and trashed the target.
//
// Now the freeze keeps the TARGET's stamp too, and execution requires both
// the target's and the keeper's identity (device, inode, size, mtime) to
// equal what was reviewed — before anything is read, and again on the very
// bytes that were proven (the quarantine baseline, the proof's keeper) —
// else the copy is held: "changed since you reviewed it".

import CryptoKit
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@Suite("Delete Duplicates — a reviewed pick is bound to the files reviewed (codex F4)", .serialized)
@MainActor
struct DeleteDuplicatesReviewedStampTests {

    private struct Rig {
        let dir: URL
        let model: VideoScanModel
        let keeper: VideoRecord
        let copy: VideoRecord
        var hooks: SignatureVerification.Hooks { SignatureVerification.Hooks.live.withScratchTrash(in: dir) }
        var root: URL { dir.appendingPathComponent("plans", isDirectory: true) }
        var trashed: Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent("Trash/\(copy.filename)").path) }
        func cleanup() { try? FileManager.default.removeItem(at: dir) }
    }

    private static let size = FileHasher.segmentSize * 2

    private func rig(_ label: String) -> Rig {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test_dupstamp_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: dir.appendingPathComponent("catalog", isDirectory: true))
        model.mediaLedger = MediaLedger(directory: dir.appendingPathComponent("ledger", isDirectory: true))
        let bytes = Data((0..<Self.size).map { UInt8($0 % 211) })
        let group = UUID()
        func rec(_ name: String, _ d: DuplicateDisposition) -> VideoRecord {
            let url = dir.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: bytes)
            let r = VideoRecord()
            r.fullPath = url.path; r.filename = name; r.directory = dir.path
            r.sizeBytes = Int64(Self.size); r.partialMD5 = "same"; r.durationSeconds = 61
            r.duplicateGroupID = group; r.duplicateDisposition = d; r.duplicateConfidence = .high
            return r
        }
        let keeper = rec("keeper.mov", .keep)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        keeper.contentFixity = ContentFixity.captured(path: keeper.fullPath, digest: digest, byteCount: Int64(Self.size))
        let copy = rec("copy.mov", .extraCopy)
        model.records = [keeper, copy]
        return Rig(dir: dir, model: model, keeper: keeper, copy: copy)
    }

    /// New bytes (the same in both files), and a later mtime, at the same path.
    private func rewrite(_ paths: [String], seed: UInt8) throws {
        let fresh = Data((0..<Self.size).map { UInt8(($0 &+ Int(seed)) % 199) })
        let later = Date().addingTimeInterval(120)
        for path in paths {
            try fresh.write(to: URL(fileURLWithPath: path))
            try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: path)
        }
    }

    private func run(_ batch: DeleteDuplicatesBatch, _ r: Rig) async throws -> DeleteDuplicatesPlan.Entry {
        let job = DeleteDuplicatesJob(model: r.model, reviewed: try #require(batch.plans.first), hooks: r.hooks, planRoot: r.root)
        job.start(); await job.task?.value
        return try #require(job.plan?.entries.first)
    }

    @Test func rewritingBothFilesWithIdenticalNewContentHoldsThePick() async throws {
        let r = rig("both"); defer { r.cleanup() }
        let batch = await r.model.reviewedDuplicateBatch([ReviewedDuplicatePick(recordID: r.copy.id, path: r.copy.fullPath,
                                                                                keeperID: r.keeper.id)])
        try rewrite([r.copy.fullPath, r.keeper.fullPath], seed: 7)

        let row = try await run(batch, r)
        #expect(row.status != .trashed && row.status != .deleted, "\(row.status): \(row.note)")
        #expect(row.outcome == .held, "\(row.outcome): \(row.note)")
        #expect(row.note.contains("changed since you reviewed it"), Comment(rawValue: row.note))
        #expect(!r.trashed && FileManager.default.fileExists(atPath: r.copy.fullPath), "nothing moved")
    }

    @Test func rewritingOnlyTheTargetHoldsThePick() async throws {
        let r = rig("target"); defer { r.cleanup() }
        let batch = await r.model.reviewedDuplicateBatch([ReviewedDuplicatePick(recordID: r.copy.id, path: r.copy.fullPath,
                                                                                keeperID: r.keeper.id)])
        // Same bytes as before (still identical to the keeper), new mtime:
        // not the file that was reviewed.
        let later = Date().addingTimeInterval(120)
        try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: r.copy.fullPath)

        let row = try await run(batch, r)
        #expect(row.outcome == .held && row.note.contains("changed since you reviewed it"), "\(row.status): \(row.note)")
        #expect(!r.trashed)
    }

    @Test func anUntouchedReviewedPairStillMoves() async throws {
        let r = rig("control"); defer { r.cleanup() }
        let batch = await r.model.reviewedDuplicateBatch([ReviewedDuplicatePick(recordID: r.copy.id, path: r.copy.fullPath,
                                                                                keeperID: r.keeper.id)])
        let row = try await run(batch, r)
        #expect(row.status == .trashed, Comment(rawValue: row.note))
        #expect(r.trashed)
    }

    /// Pure: what counts as "the file reviewed" — device, inode, size and
    /// mtime; ctime ignored (the quarantine rename changes it); an absent
    /// file is left to the run's own gates; an unstamped review never passes.
    @Test func theReviewedIdentityRule() {
        let t = FileIdentityStamp(device: 1, inode: 10, size: 100, mtimeNs: 5, ctimeNs: 7)
        let k = FileIdentityStamp(device: 1, inode: 20, size: 100, mtimeNs: 6, ctimeNs: 8)
        let reviewed = ReviewedIdentity(target: t, keeper: k)
        #expect(reviewed.problem(targetNow: t, keeperNow: k) == nil)
        let renamed = FileIdentityStamp(device: 1, inode: 10, size: 100, mtimeNs: 5, ctimeNs: 99)
        #expect(reviewed.problem(targetNow: renamed, keeperNow: k) == nil, "a rename's ctime is not a change")
        let rewritten = FileIdentityStamp(device: 1, inode: 10, size: 100, mtimeNs: 6, ctimeNs: 7)
        #expect(reviewed.problem(targetNow: rewritten, keeperNow: k)?.hasPrefix("this copy changed since you reviewed it") == true)
        let replaced = FileIdentityStamp(device: 1, inode: 21, size: 100, mtimeNs: 6, ctimeNs: 8)
        #expect(reviewed.problem(targetNow: t, keeperNow: replaced)?.hasPrefix("its keeper changed since you reviewed it") == true)
        let otherDrive = FileIdentityStamp(device: 2, inode: 10, size: 100, mtimeNs: 5, ctimeNs: 7)
        #expect(reviewed.problem(targetNow: otherDrive, keeperNow: k) != nil, "device is part of the identity")
        #expect(reviewed.problem(targetNow: nil, keeperNow: nil) == nil, "absence is the run's to name")
        #expect(ReviewedIdentity(target: nil, keeper: k).problem(targetNow: t, keeperNow: k) != nil,
                "a copy not stamped at the review is never taken on trust")
    }

    /// Codex delete-engines r2 F4: both files rewritten IN PLACE with identical
    /// same-length bytes and their mtimes restored — device, inode, size and
    /// mtime all match; only ctime moved. The job-start check (before the
    /// quarantine rename) must catch it; the post-proof check may not, since
    /// the job's own rename changes ctime.
    @Test func anInPlaceRewriteWithRestoredMtimeIsHeldAtJobStart() {
        let t = FileIdentityStamp(device: 1, inode: 10, size: 100, mtimeNs: 5, ctimeNs: 7)
        let k = FileIdentityStamp(device: 1, inode: 20, size: 100, mtimeNs: 6, ctimeNs: 8)
        let reviewed = ReviewedIdentity(target: t, keeper: k)
        let tRewritten = FileIdentityStamp(device: 1, inode: 10, size: 100, mtimeNs: 5, ctimeNs: 70)
        let kRewritten = FileIdentityStamp(device: 1, inode: 20, size: 100, mtimeNs: 6, ctimeNs: 80)
        #expect(reviewed.problem(targetNow: tRewritten, keeperNow: kRewritten, changeTime: .mustMatch)?
            .hasPrefix("this copy changed since you reviewed it") == true)
        #expect(reviewed.problem(targetNow: t, keeperNow: kRewritten, changeTime: .mustMatch)?
            .hasPrefix("its keeper changed since you reviewed it") == true)
        #expect(reviewed.problem(targetNow: t, keeperNow: k, changeTime: .mustMatch) == nil)
    }

    @Test func theJobStartCheckRequiresAnUnchangedCtime() throws {
        let job = try SourceTree.appSource(named: "DeleteDuplicatesJob.swift")
        #expect(job.contains("keeperNow: stamps[e.keeperPath],\n                                                                 changeTime: .mustMatch)"),
                "the pre-quarantine reviewed check must use changeTime: .mustMatch")
    }
}
