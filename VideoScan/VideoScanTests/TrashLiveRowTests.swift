// TrashLiveRowTests.swift
// Codex #206 F1 (P1): Workbench Discard's guard authorized every row, so the
// shared Trash routine moved the file of an object the catalog no longer
// held — B replaced in `model.records` (same id, another file) during A's
// move, before B's turn, and B's ORIGINAL file still went to the Trash.
// The live-row rule now lives INSIDE the routine: at every file's turn (and
// every unit member's phase 1), the target must be the catalog's own row for
// its id, else it is held with the changed-in-catalog words. No door can
// bypass it; the doors' own checks stay as the earlier, friendlier refusal.
//
// Dimensions: logic + isolation (sandbox catalog, sandbox "Trash") + sensor.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

/// A main-actor action run from the routine's off-main disk stretch (≈ a
/// callback that marshals to the UI thread and waits).
private final class OnMain: @unchecked Sendable {
    let action: @MainActor () -> Void
    init(_ action: @escaping @MainActor () -> Void) { self.action = action }
    nonisolated func runAndWait() { DispatchQueue.main.sync { MainActor.assumeIsolated { action() } } }
}

@Suite("The Trash routine acts only on the catalog's own row (Codex #206)", .serialized)
@MainActor
struct TrashLiveRowTests {

    private func scratch(_ tag: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vs_liverow_\(tag)_\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("trash"), withIntermediateDirectories: true)
        return dir
    }

    private func model(_ dir: URL) -> VideoScanModel {
        let m = VideoScanModel()
        m.catalogStore = CatalogStore(directory: dir.appendingPathComponent("catalog", isDirectory: true))
        m.mediaLedger = MediaLedger(directory: dir.appendingPathComponent("ledger", isDirectory: true))
        return m
    }

    private func item(_ dir: URL, _ name: String) -> VideoRecord {
        let url = dir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data([1, 2, 3, 4]))
        let r = VideoRecord()
        r.filename = name; r.fullPath = url.path; r.directory = dir.path
        r.sizeBytes = 4; r.lifecycleStage = .workbench
        return r
    }

    @Test("codex #206 F1: Workbench — B replaced in the catalog during A's move is held at its turn; both B files stay")
    func workbenchReplacedRowBeforeTurnIsHeld() async throws {
        let dir = try scratch("wb"); defer { try? FileManager.default.removeItem(at: dir) }
        let m = model(dir)
        let a = item(dir, "test_a.mov"), b = item(dir, "test_b.mov")
        m.records = [a, b]
        let otherURL = dir.appendingPathComponent("test_b_elsewhere.mov")
        FileManager.default.createFile(atPath: otherURL.path, contents: Data([9, 9, 9, 9]))
        let replace = OnMain {
            let clone = b.snapshotClone()
            clone.fullPath = otherURL.path
            if let i = m.records.firstIndex(where: { $0.id == b.id }) { m.records[i] = clone }
        }
        let trashDir = dir.appendingPathComponent("trash")
        let aPath = a.fullPath
        let result = try #require(await m.discardWorkbenchResult([a, b]) { url in
            if url.path == aPath { replace.runAndWait() }
            try FileManager.default.moveItem(at: url, to: trashDir.appendingPathComponent(url.lastPathComponent))
        })
        #expect(!FileManager.default.fileExists(atPath: a.fullPath), "A moved")
        #expect(FileManager.default.fileExists(atPath: b.fullPath), "B's original file was moved for a row the catalog no longer holds")
        #expect(FileManager.default.fileExists(atPath: otherURL.path), "the catalog's B file is untouched")
        let bOutcome = try #require(result.items.first { $0.record.id == b.id }?.outcome)
        guard case .held(let why) = bOutcome else { Issue.record("B: \(bOutcome)"); return }
        #expect(why == VideoScanModel.changedInCatalogHeldNote, "\(why)")
    }

    @Test("codex #206 F1: the bare routine holds a row the catalog does not have — no door can bypass the rule")
    func bareRoutineHoldsARowTheCatalogLacks() async throws {
        let dir = try scratch("bare"); defer { try? FileManager.default.removeItem(at: dir) }
        let m = model(dir)
        let inCatalog = item(dir, "test_in.mov"), detached = item(dir, "test_out.mov")
        m.records = [inCatalog]
        let trashDir = dir.appendingPathComponent("trash")
        let fileGuard = VideoScanModel.JunkDeletionGuard(
            authorize: { _ in nil }, beforeRemoval: { _ in nil },
            remove: { url in try FileManager.default.moveItem(at: url, to: trashDir.appendingPathComponent(url.lastPathComponent)) })
        let result = await m.deleteConfirmedJunk([inCatalog, detached], mode: .toTrash, reason: .junk, guard: fileGuard)
        #expect(!FileManager.default.fileExists(atPath: inCatalog.fullPath), "the catalog's row moves")
        #expect(FileManager.default.fileExists(atPath: detached.fullPath), "a row the catalog lacks never moves")
        #expect(result.items.map(\.outcome.isMoved) == [true, false])
        #expect(detached.removal == nil)
    }

    @Test("sensor: the routine's single-file turn and every unit member's phase 1 ask the live-row rule first")
    func routineAsksTheLiveRowRule() throws {
        let engine = try SourceTree.appCode(named: "VideoScanModel+JunkDelete.swift")
        #expect(engine.contains("func junkTurnLiveRowRefusal(_ rec: VideoRecord) -> JunkFileOutcome?"))
        #expect(engine.contains("record(forID: rec.id) === rec"), "the rule is identity with the catalog's row by id")
        let calls = engine.components(separatedBy: "junkTurnLiveRowRefusal(rec").count - 1
        #expect(calls == 2, "junkTurn and junkUnitTurn each ask it (found \(calls))")
    }
}
