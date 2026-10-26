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
        _ = await model.trashSelectedRecords([rec], confirmed: model.catalogTrashPlan(for: [rec]), fileOperation: sb.trash.operation)
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

    // MARK: round 2 P2 — the REPORTED item is about the file that left, too

    /// Trash A; its row is repointed to B inside its turn (after the turn's
    /// identity was frozen, before settlement). F3 keeps the live row (now
    /// B) unstamped; this pins that the `settled` callback and the result
    /// item name A — the audit and receipt must never associate B with A's
    /// "moved" outcome (codex round 2 P2).
    @Test func r2ARowRepointedMidTurnIsReportedUnderTheFrozenPath() async throws {
        let sb = try JunkTrashSandbox("r2"); defer { sb.cleanup() }
        let model = sb.model()
        let a = try sb.write("test_A.mov")
        let b = try sb.write("test_B.mov", fill: 0x33)
        let rec = sb.junk(a)
        model.records = [rec]
        let repointTo = b.path
        final class Seen: @unchecked Sendable { var path: String?; var isLive: Bool? }
        let seen = Seen()
        let fileGuard = VideoScanModel.JunkDeletionGuard(
            authorize: { r in r.fullPath = repointTo; r.filename = "test_B.mov"; return nil },   // relinked mid-turn
            beforeRemoval: { _ in nil }, remove: sb.trash.operation,
            settled: { r, _ in seen.path = r.fullPath; seen.isLive = (r === rec) })

        let result = await model.deleteConfirmedJunk([rec], mode: .toTrash, reason: .catalogTrash, guard: fileGuard)

        #expect(result.items.map(\.outcome.kind) == [.moved], "fixture: A left")
        #expect(!FileManager.default.fileExists(atPath: a.path) && FileManager.default.fileExists(atPath: b.path))
        #expect(seen.path == a.path, "settled was told about \(seen.path ?? "nil"), not A")
        #expect(seen.isLive == false, "the live row (now B) is not the reported record")
        #expect(result.items.first?.record.fullPath == a.path, "the result item names A")
        #expect(result.items.first?.record.removal?.state == .inTrash, "…and carries the stamp")
        #expect(rec.removal == nil && rec.fullPath == b.path, "F3: the live row describing B is untouched")
    }

    // MARK: F4 — a restored legacy row stays restored

    private func decodeLegacy(_ fields: String, path: String) throws -> VideoRecord {
        let json = "{\"id\":\"\(UUID().uuidString)\",\"filename\":\"\((path as NSString).lastPathComponent)\",\"fullPath\":\"\(path)\"\(fields)}"
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(VideoRecord.self, from: Data(json.utf8))
    }

    private func restoreSaveReload(_ rec: VideoRecord, in dir: URL) throws -> VideoRecord? {
        let store = CatalogStore(directory: dir.appendingPathComponent("catalog", isDirectory: true))
        let m = VideoScanModel()
        m.catalogStore = store
        m.mediaLedger = MediaLedger(directory: dir.appendingPathComponent("ledger", isDirectory: true))
        m.records = [rec]
        #expect(m.restoreRecord(id: rec.id))
        #expect(store.saveNow(records: m.records))
        return CatalogStore(directory: dir.appendingPathComponent("catalog", isDirectory: true)).load().first
    }

    @Test func f4APurgedRowWithTheOldLabelStaysRestoredAfterReload() throws {
        let dir = try scratch("f4a"); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("test_f4a.mov"); try Data([1]).write(to: file)
        let rec = try decodeLegacy(",\"purgedAt\":\"2023-11-14T22:13:20Z\",\"archiveStage\":\"Manually Deleted\"", path: file.path)
        #expect(rec.removal?.reason == .legacyPurged, "fixture: the purge won migration")
        let back = try #require(try restoreSaveReload(rec, in: dir))
        #expect(!back.isPurged && back.archiveStage != .manuallyDeleted, "hidden again after reload")
    }

    @Test func f4ATrashedRowWithTheOldLabelStaysRestoredAfterPutBack() throws {
        let dir = try scratch("f4b"); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("test_f4b.mov"); try Data([1]).write(to: file)   // already put back
        let rec = try decodeLegacy(",\"purgedAt\":\"2023-11-14T22:13:20Z\",\"lifecycleStage\":\"Trashed\",\"archiveStage\":\"Manually Deleted\"",
                                   path: file.path)
        #expect(rec.removal?.state == .inTrash, "fixture")
        let back = try #require(try restoreSaveReload(rec, in: dir))
        #expect(!back.isPurged && back.archiveStage != .manuallyDeleted && back.lifecycleStage == .cataloged)
    }

    // MARK: F5 — a stale probe never marks a newer Trash marker

    @Test func f5AStaleEmptiedProbeLeavesANewerMarkerAlone() throws {
        let dir = try scratch("f5"); defer { try? FileManager.default.removeItem(at: dir) }
        let m = VideoScanModel()
        m.catalogStore = CatalogStore(directory: dir.appendingPathComponent("catalog", isDirectory: true))
        let rec = VideoRecord(); rec.fullPath = dir.appendingPathComponent("a.mov").path; rec.filename = "a.mov"
        rec.removal = .inTrash(movedAt: Date(timeIntervalSince1970: 1_000), trashPath: dir.appendingPathComponent("gone-A").path,
                               reason: .junk)
        m.records = [rec]
        let probes = m.trashCopyProbes(in: m.records)
        let gone = VideoScanModel.emptiedTrashCopies(probes)
        // Meanwhile: restored, trashed again — a new marker, Trash copy B exists.
        let b = dir.appendingPathComponent("present-B"); try Data([1]).write(to: b)
        rec.removal = .inTrash(movedAt: Date(timeIntervalSince1970: 2_000), trashPath: b.path, reason: .junk)

        _ = m.applyTrashEmptied(gone, now: Date())

        #expect(rec.removal?.isTrashEmptied == false, "the old probe marked the new Trash copy emptied")
    }
}
