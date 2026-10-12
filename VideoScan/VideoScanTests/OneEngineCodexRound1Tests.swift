// OneEngineCodexRound1Tests.swift
// Codex round 1 on GH #143 (docs/reviews/codex/codex-review-2026-10-12-one-engine.md,
// range 1f1f39e74..b71331f32): one red test per finding, red on b71331f32,
// green after its fix.
//
//   F1 (P1) the verifier can still unlink: `.permanent` or a final verdict
//      of `.proceed(.permanent)` reaches removeItem.
//   F2 (P1) Restore of an In-the-Trash row clears the marker before it
//      checks the file is back; "Restore again" after Put Back then fails.
//   F3 (P1) batch settlement stamps a row that was repointed mid-batch.
//   F4 (P1) a restored legacy row (purge + "Manually Deleted" label) comes
//      back hidden after save → reload.
//   F5 (P2) a stale "Trash emptied" probe marks a NEWER Trash marker.
//
// Dimensions: logic; isolation (sandbox catalog, ledger and Trash).

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("One engine — codex round 1 (GH #143)", .serialized)
@MainActor
struct OneEngineCodexRound1Tests {

    private func scratch(_ label: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test_codex1_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: F1 — the verifier never unlinks

    private func quarantinedPair(_ dir: URL) throws -> (QuarantineTicket,
                                                         SignatureVerification.Hooks, URL, Int) {
        let size = FileHasher.segmentSize + 333
        let bytes = Data((0..<size).map { UInt8($0 % 251) })
        let keeper = dir.appendingPathComponent("keeper.mov"); try bytes.write(to: keeper)
        let copy = dir.appendingPathComponent("copy.mov"); try bytes.write(to: copy)
        var hooks = SignatureVerification.Hooks(shouldCancel: { false }, didReadBlock: { _ in })
        let fakeTrash = dir.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
        hooks.trashItem = { url in
            let dest = fakeTrash.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: dest); return dest
        }
        let proof = try SignatureVerification.verify(keeperPath: keeper.path, duplicatePath: copy.path, hooks: hooks).get()
        guard case .quarantined(let ticket) = SignatureVerification.quarantine(proof, hooks: hooks) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return (ticket, hooks, fakeTrash, size)
    }

    @Test func f1APermanentDisposalStillGoesToTheTrash() throws {
        let dir = try scratch("f1a"); defer { try? FileManager.default.removeItem(at: dir) }
        let (ticket, hooks, trash, size) = try quarantinedPair(dir)
        let result = SignatureVerification.deleteQuarantined(ticket, disposal: .permanent, hooks: hooks)
        #expect(result != .deleted(bytes: Int64(size)), "unlinked outright — Trash only")
        #expect(FileManager.default.fileExists(atPath: trash.appendingPathComponent("copy.mov").path))
    }

    @Test func f1AFinalVerdictOfPermanentStillGoesToTheTrash() throws {
        let dir = try scratch("f1b"); defer { try? FileManager.default.removeItem(at: dir) }
        let (ticket, hooks, trash, size) = try quarantinedPair(dir)
        let result = SignatureVerification.deleteQuarantined(ticket, disposal: .trash, hooks: hooks) { .proceed(.permanent) }
        #expect(result != .deleted(bytes: Int64(size)), "the final verdict raised it to an unlink")
        #expect(FileManager.default.fileExists(atPath: trash.appendingPathComponent("copy.mov").path))
    }

    // MARK: F2 — Restore waits for the file to be back

    @Test func f2RestoreRefusesWhileTheFileIsInTheTrashAndWorksAfterPutBack() async throws {
        let sb = try JunkTrashSandbox("f2"); defer { sb.cleanup() }
        let model = sb.model()
        let url = try sb.write("test_f2.mov")
        let rec = sb.junk(url)
        model.records = [rec]
        _ = await model.trashSelectedRecords([rec], fileOperation: sb.trash.operation)
        let marker = try #require(rec.removal)
        #expect(marker.state == .inTrash)

        #expect(!model.restoreRecord(id: rec.id), "restored while the file is still in the Trash")
        #expect(rec.removal == marker && rec.isPurged, "the marker was cleared before the file came back")

        // Rick puts it back in Finder, then Restores again.
        let inTrash = try #require(try FileManager.default.contentsOfDirectory(atPath: sb.trash.dir.path).first)
        try FileManager.default.moveItem(at: sb.trash.dir.appendingPathComponent(inTrash), to: url)
        #expect(model.restoreRecord(id: rec.id), "Restore again after Put Back")
        #expect(rec.removal == nil && rec.lifecycleStage == .cataloged)
    }

    // MARK: F3 — settlement stamps only the row the file left from

    @Test func f3ARowRepointedMidBatchIsNotStamped() async throws {
        let sb = try JunkTrashSandbox("f3"); defer { sb.cleanup() }
        let model = sb.model()
        let a = try sb.write("test_A.mov")
        let b = try sb.write("test_B.mov", fill: 0x33)
        let rec = sb.junk(a)
        model.records = [rec]
        let repointTo = b.path
        let fileGuard = VideoScanModel.JunkDeletionGuard(
            authorize: { _ in nil }, beforeRemoval: { _ in nil }, remove: sb.trash.operation,
            settled: { r, _ in r.fullPath = repointTo; r.filename = "test_B.mov" })   // a relink lands mid-batch

        let result = await model.deleteConfirmedJunk([rec], mode: .toTrash, reason: .catalogTrash, guard: fileGuard)

        #expect(result.items.map(\.outcome.kind) == [.moved], "fixture: A left")
        #expect(FileManager.default.fileExists(atPath: b.path), "fixture: B is still on disk")
        #expect(rec.removal == nil && !rec.isPurged && rec.lifecycleStage != .trashed,
                "the row now describing B was stamped removed: \(String(describing: rec.removal))")
    }
}
