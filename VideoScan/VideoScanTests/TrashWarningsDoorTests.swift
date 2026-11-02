// TrashWarningsDoorTests.swift
// Codex #205 (P1): a kept concurrent marker reached ⌘⌫'s alert (#204) but
// vanished in every door that read only `result.items` — Cleanup reported
// clean success, Prune reduced the result to `.trashed(bytes:)`, Workbench
// Discard returned a count, Delete Junk's OUTCOME line said nothing. Each
// test here moves a real file while another action re-marks its row
// (`.removedFromCatalog`, stamped on the main actor from inside the disk
// stretch), then asks the door's OWN result surface — subtitle, summary,
// OUTCOME line — to name the conflict and where the file went.
// The Delete Duplicates sibling: its own settlement (not the routine) must
// follow the same rule — detect, keep, say — never overwrite.
//
// Dimensions: logic + truth (the shown result is the routine's warning);
// isolation (sandbox catalog, ledger, scratch Trash).

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

/// A `VideoRecord` handed into a `@Sendable` closure that only touches it
/// on the main actor (≈ passing a raw pointer to a callback that marshals
/// to the UI thread before dereferencing).
private final class RowRef: @unchecked Sendable {
    let value: VideoRecord
    init(_ v: VideoRecord) { value = v }
}

/// Another action marks the row gone, on the main actor, while the caller
/// waits off it — the race the doors must report.
nonisolated private func remarkOnMain(_ ref: RowRef) {
    DispatchQueue.main.sync {
        MainActor.assumeIsolated {
            _ = VideoScanModel.stampRemoval(ref.value, .removedFromCatalog(at: Date(), reason: .junk))
        }
    }
}

/// A main-actor action run from Prune's off-main file operation.
private final class StopOnMain: @unchecked Sendable {
    let action: @MainActor () -> Void
    init(_ action: @escaping @MainActor () -> Void) { self.action = action }
    nonisolated func runAndWait() { DispatchQueue.main.sync { MainActor.assumeIsolated { action() } } }
}

@MainActor
private final class PruneJobBox { var job: PruneApplyJob? }

@Suite("Trash warnings reach every door (Codex #205)", .serialized)
@MainActor
struct TrashWarningsDoorTests {

    private func console(_ m: VideoScanModel, containing s: String) async -> String? {
        for _ in 0..<200 {
            if let line = m.dashboard.consoleLines.first(where: { $0.contains(s) }) { return line }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    @Test("codex #205: Cleanup — a kept concurrent marker is in the subtitle, the result and the OUTCOME, with the Trash path")
    func cleanupKeptMarkerRequiresAttention() async throws {
        let sb = try CleanupTrashSandbox("keptmarker")
        defer { sb.cleanup() }
        let (model, extras) = try cleanupThreeCopies(sb)
        let plan = await model.buildCleanupPlan()
        let selection = CleanupSelection(plan: plan, unticked: [extras[1].id, extras[2].id], includeArchiveJunk: false)
        let first = try #require(selection.copies.first)
        let target = try #require(extras.first { $0.id == first.target.id })
        let ref = RowRef(target)
        let job = await runCleanupTrash(model, selection) { job in
            job.proofPassedForTesting = { path in
                guard path == first.target.path else { return }
                remarkOnMain(ref)
            }
        }
        // The file really moved (the test host's scratch Trash).
        let moved = try #require(job.items.first { $0.id == target.id })
        #expect(moved.outcome == .moved, "\(job.items.map { "\($0.outcome): \($0.reason)" })")
        #expect(!FileManager.default.fileExists(atPath: first.target.path))
        #expect(target.removal?.state == .removedFromCatalog, "the concurrent marker is kept, not overwritten")
        await model.mediaLedger.waitForPendingWrites()
        let event = try #require(model.mediaLedger.allEvents().first { $0.event == .copyTrashed && $0.recordID == target.id })
        let trashPath = try #require(event.detail[MediaLedgerEvent.Detail.trashPath])
        defer { try? FileManager.default.removeItem(atPath: trashPath) }
        // What the person sees: the job's subtitle / finished summary.
        #expect(job.subtitle.contains("catalog changed during the move"), "subtitle: \(job.subtitle)")
        if case .finished(let summary) = job.state {
            #expect(summary.contains("catalog changed during the move"), "summary: \(summary)")
        } else {
            Issue.record("expected Finished, got \(job.state)")
        }
        // The OUTCOME line names the conflict and where the file is.
        let outcome = await console(model, containing: "[cleanup] OUTCOME")
        #expect(outcome?.contains("kept another action's marker 1") == true, "\(outcome ?? "no OUTCOME")")
        #expect(outcome?.contains(trashPath) == true, "\(outcome ?? "no OUTCOME")")
    }

    @Test("codex #205: Workbench Discard — a kept concurrent marker is on the OUTCOME line")
    func workbenchKeptMarkerOnOutcome() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vs_wb_kept_\(UUID().uuidString.prefix(8))", isDirectory: true)
        let trashDir = dir.appendingPathComponent("trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: dir.appendingPathComponent("catalog", isDirectory: true))
        model.mediaLedger = MediaLedger(directory: dir.appendingPathComponent("ledger", isDirectory: true))
        let url = dir.appendingPathComponent("test_wb_kept.mov")
        FileManager.default.createFile(atPath: url.path, contents: Data([1, 2, 3, 4]))
        let rec = VideoRecord()
        rec.filename = url.lastPathComponent; rec.fullPath = url.path; rec.directory = dir.path
        rec.sizeBytes = 4; rec.lifecycleStage = .workbench
        model.records = [rec]
        let ref = RowRef(rec)
        _ = await model.discardWorkbench([rec]) { moving in
            remarkOnMain(ref)
            try FileManager.default.moveItem(at: moving, to: trashDir.appendingPathComponent(moving.lastPathComponent))
        }
        #expect(rec.removal?.state == .removedFromCatalog, "the concurrent marker is kept")
        let outcome = await console(model, containing: "[workbench] OUTCOME")
        #expect(outcome?.contains("kept another action's marker 1") == true, "\(outcome ?? "no OUTCOME")")
        #expect(outcome?.contains("test_wb_kept.mov") == true, "\(outcome ?? "no OUTCOME")")
    }

    @Test("codex #205: Delete Junk — a kept concurrent marker is on the OUTCOME line and in the result sheet")
    func deleteJunkKeptMarkerOnOutcome() async throws {
        let sb = try JunkTrashSandbox("keptmarker"); defer { sb.cleanup() }
        let model = sb.model()
        let a = sb.junk(try sb.write("test_junk_kept.mov"))
        model.records = [a]
        let snapshot = await model.freezeJunkSnapshot([a], isOffline: { _ in false })
        let ref = RowRef(a)
        let trashDir = sb.root.appendingPathComponent("trash", isDirectory: true)
        let result = await model.trashFrozenJunk(snapshot) { moving in
            remarkOnMain(ref)
            try FileManager.default.moveItem(at: moving, to: trashDir.appendingPathComponent(moving.lastPathComponent))
        }
        #expect(result.succeeded == 1)
        #expect(a.removal?.state == .removedFromCatalog, "the concurrent marker is kept")
        #expect(JunkDeletionReport(result).hasNotes, "the result sheet shows it")
        let outcome = await console(model, containing: "[junk] OUTCOME")
        #expect(outcome?.contains("kept another action's marker 1") == true, "\(outcome ?? "no OUTCOME")")
    }

    @Test("codex #205: Prune — a kept concurrent marker is in the batch's summary, never a clean 'moved'")
    func pruneKeptMarkerInSummary() async throws {
        let f = try await PruneApplyTests.fixture("keptmarker")
        defer { f.sb.cleanup() }
        let mover = PruneApplyTests.Mover(trash: f.trashDir)
        let ref = RowRef(f.copy)
        var hooks = PruneApplyTests.hooks(mover)
        hooks.removeFile = { url in
            remarkOnMain(ref)
            try mover.move(url)
        }
        let shown = await f.model.prunePlan(batch: f.batch).shown()
        let outcome = await f.model.applyPrune(shown: shown, selected: [f.copy.id], batch: f.batch,
                                               batchID: "test-kept", hooks: hooks)
        #expect(mover.paths == [f.copy.fullPath], "the copy really moved: \(outcome.summary)")
        #expect(f.copy.removal?.state == .removedFromCatalog, "the concurrent marker is kept")
        #expect(outcome.summary.contains("catalog changed during the move"), "\(outcome.summary)")
        #expect(outcome.warnings.contains { $0.contains(f.copy.filename) && $0.contains("kept another action's marker") },
                "\(outcome.warnings)")
    }

    @Test("codex #207: Prune stopped (or quit) after a kept marker — the stopped result still names it",
          arguments: [false, true])
    func pruneStoppedResultCarriesKeptMarker(quit: Bool) async throws {
        let f = try await PruneApplyTests.fixture(quit ? "keptquit" : "keptstop")
        defer { f.sb.cleanup() }
        let mover = PruneApplyTests.Mover(trash: f.trashDir)
        let box = PruneJobBox()
        let stop = StopOnMain {
            _ = VideoScanModel.stampRemoval(f.copy, .removedFromCatalog(at: Date(), reason: .junk))
            if quit { box.job?.stopForQuit() } else { box.job?.cancel() }
        }
        var hooks = PruneApplyTests.hooks(mover)
        hooks.removeFile = { url in
            stop.runAndWait()
            try mover.move(url)
        }
        let shown = await f.model.prunePlan(batch: f.batch).shown()
        let job = PruneApplyJob(model: f.model, shown: shown, selected: [f.copy.id], batch: f.batch,
                                batchID: "test-keptstop", hooks: hooks)
        box.job = job
        job.start()
        await job.task?.value
        #expect(mover.paths == [f.copy.fullPath], "the copy really moved")
        #expect(f.copy.removal?.state == .removedFromCatalog, "the concurrent marker is kept")
        #expect(job.state == .cancelled, "\(job.state)")
        #expect(job.subtitle.contains("catalog changed during the move"), "subtitle: \(job.subtitle)")
        #expect(job.subtitle.contains(f.copy.filename), "subtitle: \(job.subtitle)")
    }

    // MARK: Delete Duplicates — the sibling engine, the same rule

    @Test("codex #205 sibling: Delete Duplicates' settlement keeps a marker another action wrote during the move, and says so")
    func deleteDuplicatesKeepsAConcurrentMarker() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test_dup_kept_\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let m = VideoScanModel(logDirectory: root.appendingPathComponent("logs"))
        m.catalogStore = CatalogStore(directory: root.appendingPathComponent("catalog"))
        m.mediaLedger = MediaLedger(directory: root.appendingPathComponent("ledger", isDirectory: true))
        func record(_ name: String) -> VideoRecord {
            let r = VideoRecord(); r.fullPath = root.appendingPathComponent(name).path; r.filename = name
            r.sizeBytes = 100; r.partialMD5 = "h-\(UUID().uuidString)"; return r
        }
        let keeper = record("test_keeper.mov"), extra = record("test_extra.mov")
        m.records = [keeper, extra]
        // The pair's turn freezes the row; another action re-marks it while
        // the file is moving; then the settlement runs.
        let preAwait = extra.snapshotClone()
        VideoScanModel.stampRemoval(extra, .removedFromCatalog(at: Date(), reason: .junk))
        let trashPath = root.appendingPathComponent(".Trash/test_extra.mov").path
        var said: [String] = []
        m.settleDeletedDuplicate(expectedID: extra.id, expectedPath: extra.fullPath, preAwait: preAwait,
                                 keeperID: keeper.id, keeperPath: keeper.fullPath, keeperFilename: keeper.filename,
                                 isWorkingCopy: false, batchID: "test", keeperMatchedByStoredFixity: true,
                                 tier: .trash, trashVolume: "Test", trashPath: trashPath,
                                 keptMarker: { said.append($0) })
        #expect(extra.removal?.state == .removedFromCatalog, "the concurrent marker was overwritten")
        #expect(said.count == 1 && said[0].contains("test_extra.mov") && said[0].contains(trashPath), "\(said)")
        await m.mediaLedger.waitForPendingWrites()
        let event = try #require(m.mediaLedger.allEvents().first { $0.event == .copyTrashed && $0.recordID == extra.id })
        #expect(event.detail[MediaLedgerEvent.Detail.trashPath] == trashPath, "the ledger says where the file went: \(event.detail)")
    }

    @Test("Delete Duplicates: the job's summary carries every kept-marker sentence")
    func deleteDuplicatesSummaryCarriesKeptMarkers() {
        let line = DeleteDuplicatesJob.summaryLine(["moved 2"], keptMarkerNotes: ["a.mov kept another action's marker (removedFromCatalog) — it is in the Trash at /T/a.mov"])
        #expect(line.contains("catalog changed during the move for 1 file"), "\(line)")
        #expect(line.contains("/T/a.mov"), "\(line)")
        #expect(DeleteDuplicatesJob.summaryLine(["moved 2"], keptMarkerNotes: []) == "moved 2")
    }
}
