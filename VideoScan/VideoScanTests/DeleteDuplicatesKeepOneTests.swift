// DeleteDuplicatesKeepOneTests.swift
// R5 (design triage_delete_streamline_2026_10_09 §9 R5, codex F5) — RULED
// by Rick 2026-10-09: KEEP ONE verified copy. "When we have 5 copies, it
// should be easy to move them to Trash."
//
//   • one independently verified keeper is enough for the Trash (was: two
//     copies had to REMAIN — `minimumForTrash = 2` — so with exactly two
//     identical files nothing ever moved);
//   • REVISED by Rick 2026-10-09 evening: no per-file ticks — the bulk run
//     moves every proven extra, pairs included; a reviewed plan acts on
//     exactly the rows Rick ticked;
//   • the keeper is still proven at the moment of the move (digest +
//     identity, unchanged): a keeper that fails there → HOLD.
//
// The survival policy is changed in every place codex F5 named, together:
// the worker's early eligibility, the final decision, the boundary
// re-check, the forecast and the sibling-read goal.

import CryptoKit
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

private func tempDir(_ label: String) -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("test_dupkeepone_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func write(_ url: URL, _ bytes: [UInt8]) { FileManager.default.createFile(atPath: url.path, contents: Data(bytes)) }

private func plainSHA256(_ url: URL) -> String {
    SHA256.hash(data: (try? Data(contentsOf: url)) ?? Data()).map { String(format: "%02x", $0) }.joined()
}

private let fileSize = FileHasher.segmentSize * 2

/// keeper + `extras` identical extra copies in one temp folder (= the
/// volume), the keeper's fixity stored (single-read path).
@MainActor
private struct Family {
    let dir: URL
    let root: URL
    let model: VideoScanModel
    let keeper: VideoRecord
    let extras: [VideoRecord]
    let bytes: [UInt8]

    init(_ label: String, extras n: Int) {
        let folder = tempDir(label)
        let content = (0..<fileSize).map { UInt8($0 % 223) }
        let catalog = VideoScanModel()
        catalog.catalogStore = CatalogStore(directory: folder.appendingPathComponent("catalog", isDirectory: true))
        catalog.mediaLedger = MediaLedger(directory: folder.appendingPathComponent("ledger", isDirectory: true))
        let group = UUID()
        func rec(_ name: String, _ d: DuplicateDisposition) -> VideoRecord {
            let url = folder.appendingPathComponent(name); write(url, content)
            let r = VideoRecord()
            r.fullPath = url.path; r.filename = name; r.directory = folder.path
            r.sizeBytes = Int64(fileSize); r.partialMD5 = "same"; r.durationSeconds = 61
            r.duplicateGroupID = group; r.duplicateDisposition = d; r.duplicateConfidence = .high
            return r
        }
        let k = rec("keeper.mov", .keep)
        k.contentFixity = ContentFixity.captured(path: k.fullPath, digest: plainSHA256(URL(fileURLWithPath: k.fullPath)),
                                                 byteCount: Int64(fileSize))
        let copies = (0..<n).map { rec("copy\($0 + 1).mov", .extraCopy) }
        catalog.records = [k] + copies
        dir = folder
        root = folder.appendingPathComponent("plans", isDirectory: true)
        bytes = content
        model = catalog
        keeper = k
        extras = copies
    }

    var hooks: SignatureVerification.Hooks { SignatureVerification.Hooks.live.withScratchTrash(in: dir) }
    var trash: URL { dir.appendingPathComponent("Trash", isDirectory: true) }
    func inTrash(_ r: VideoRecord) -> Bool {
        FileManager.default.fileExists(atPath: trash.appendingPathComponent(r.filename).path)
    }
    func atHome(_ r: VideoRecord) -> Bool { FileManager.default.fileExists(atPath: r.fullPath) }

    /// The plan Rick reviewed: exactly these rows, with the current keeper.
    func plan(_ rows: [VideoRecord]) -> DeleteDuplicatesPlan {
        DeleteDuplicatesPlan(volumePath: dir.path, catalogLocation: model.catalogStore.fileLocation,
                             crossVolumeMode: false, skippedBeforePlan: 0, summaryLine: "",
                             entries: rows.map { r in
                                 DeleteDuplicatesPlan.Entry(id: r.id, path: r.fullPath, filename: r.filename,
                                                            sizeBytes: r.sizeBytes, keeperID: keeper.id,
                                                            keeperPath: keeper.fullPath, keeperFilename: keeper.filename,
                                                            keeperStamp: FileIdentityStamp.capture(path: keeper.fullPath))
                             })
    }

    func cleanup() { try? FileManager.default.removeItem(at: dir) }
}

@Suite("Delete Duplicates — keep one verified copy (R5)", .serialized)
@MainActor
struct DeleteDuplicatesKeepOneTests {

    // MARK: The rule

    @Test func oneVerifiedKeeperIsEnoughForTheTrash() {
        #expect(DeletionTierDecision.minimumForTrash == 1)
        var keeperOnly = DeletionTierFacts()
        keeperOnly.remainingVerifiedCopies = 1
        keeperOnly.counted = ["keeper on LaCie"]
        let d = DeletionTierDecision.decide(facts: keeperOnly)
        #expect(d.tier == .trash, Comment(rawValue: d.reason))
        var none = DeletionTierFacts()
        none.remainingVerifiedCopies = 0
        #expect(DeletionTierDecision.decide(facts: none).tier == nil, "no verified copy → left alone")
        #expect(DeletionTierDecision.ruleSentence.contains("one verified copy"), Comment(rawValue: DeletionTierDecision.ruleSentence))
    }

    // MARK: The bulk run (Storage card): pre-selected rows only

    /// keeper + 2 extras = 3 copies: both extras pre-selected, both go to
    /// the Trash — the keeper alone remains. Was: each extra was "left
    /// alone" (the other was still to be decided, so only one remained).
    @Test func threeCopiesKeepOneAndTrashTheTwoExtras() async throws {
        let f = Family("three", extras: 2); defer { f.cleanup() }
        let job = DeleteDuplicatesJob(model: f.model, volumePath: f.dir.path, hooks: f.hooks, planRoot: f.root)
        job.start(); await job.task?.value

        let plan = try #require(job.plan)
        #expect(plan.entries.map(\.status) == [.trashed, .trashed], "\(plan.entries.map(\.note))")
        #expect(f.inTrash(f.extras[0]) && f.inTrash(f.extras[1]))
        #expect(f.atHome(f.keeper), "the keeper stays")
    }

    /// keeper + 1 extra = 2 copies (R5 revised by Rick 2026-10-09 evening:
    /// no ticks, pairs included): the bulk run proves the keeper at the
    /// move and the extra goes to the Trash; the keeper stays.
    @Test func aPairsExtraMovesInTheBulkRunWhenTheKeeperIsProven() async throws {
        let f = Family("two-bulk", extras: 1); defer { f.cleanup() }
        let job = DeleteDuplicatesJob(model: f.model, volumePath: f.dir.path, hooks: f.hooks, planRoot: f.root)
        job.start(); await job.task?.value

        let plan = try #require(job.plan)
        let row = try #require(plan.entries.first)
        #expect(row.status == .trashed && row.remainingVerifiedCopies == 1, "\(row.status): \(row.note)")
        #expect(f.inTrash(f.extras[0]) && f.atHome(f.keeper))
    }

    // MARK: A plan with the row ticked

    /// 2 identical copies (keeper + 1), the extra TICKED: it goes to the
    /// Trash. Was: left alone ("only 1 verified copy would remain").
    @Test func twoCopiesWithTheExtraTickedMovesItToTheTrash() async throws {
        let f = Family("two-ticked", extras: 1); defer { f.cleanup() }
        let job = DeleteDuplicatesJob(model: f.model, resuming: f.plan(f.extras), hooks: f.hooks, planRoot: f.root)
        job.start(); await job.task?.value

        let plan = try #require(job.plan)
        #expect(plan.entries[0].status == .trashed, Comment(rawValue: plan.entries[0].note))
        #expect(plan.entries[0].remainingVerifiedCopies == 1)
        #expect(f.inTrash(f.extras[0]) && f.atHome(f.keeper))
    }

    /// The keeper fails its proof at the removal boundary (rewritten after
    /// the copy was verified): the copy is put back — a HOLD — and the
    /// keeper is untouched.
    @Test func aKeeperThatFailsAtTheBoundaryHoldsTheCopy() async throws {
        let f = Family("keeper-changed", extras: 1); defer { f.cleanup() }
        let job = DeleteDuplicatesJob(model: f.model, resuming: f.plan(f.extras), hooks: f.hooks, planRoot: f.root)
        let keeperPath = f.keeper.fullPath
        job.testHookAfterQuarantineSaved = { _ in
            // Same size, new bytes: the keeper's stamp no longer reproduces.
            var changed = (try? Data(contentsOf: URL(fileURLWithPath: keeperPath))) ?? Data()
            changed[0] ^= 0xFF
            try? changed.write(to: URL(fileURLWithPath: keeperPath))
        }
        job.start(); await job.task?.value

        let row = try #require(job.plan?.entries.first)
        // Refused AT THE BOUNDARY (not left alone earlier): the verifier's
        // keeper re-stat failed after the copy had been verified and moved.
        #expect(row.status == .refused, "\(row.status): \(row.note)")
        #expect(row.note.contains("changed during verification"), Comment(rawValue: row.note))
        #expect(row.tier == .trash, "the copy was decided for the Trash before the keeper changed")
        #expect(f.atHome(f.extras[0]) && !f.inTrash(f.extras[0]), "put back at its path")
        #expect((try? Data(contentsOf: URL(fileURLWithPath: f.extras[0].fullPath))) == Data(f.bytes), "untouched")
        #expect(row.quarantineDirectory == nil, "nothing left in quarantine")
    }

    /// One copy (the keeper alone): nothing to do, nothing moves.
    @Test func aLoneKeeperIsNeverATarget() async throws {
        let f = Family("one", extras: 0); defer { f.cleanup() }
        let job = DeleteDuplicatesJob(model: f.model, volumePath: f.dir.path, hooks: f.hooks, planRoot: f.root)
        job.start(); await job.task?.value
        #expect(job.plan?.entries.isEmpty ?? true)
        #expect(f.atHome(f.keeper) && !FileManager.default.fileExists(atPath: f.trash.path))
    }
}
