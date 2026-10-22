// PruneApplyJobTests.swift
// "Move N copies to the Trash" as a Media File Operation (PruneApplyJob) —
// the one job both "Archived — what next?" and Triage's Excess copies pane
// start. Ported from the pre-2026-10-21 suite to the simple plan: the same
// pipeline, Pause / Stop between files, the queue (Rick 2026-09-22: queue,
// don't refuse; stop is stop; an error drops the line), the log lines, the
// progress subtitle. Fixtures: PruneApplyTests.fixture (a sandbox promote
// with the source and one byte-identical copy offered); the file operation
// is the sandbox "Trash" seam — the real Trash is never touched.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Prune — the job and its queue", .serialized)
@MainActor
struct PruneApplyJobTests {

    typealias F = PruneApplyTests.Fixture

    private func fixture(_ label: String) async throws -> F { try await PruneApplyTests.fixture("job_\(label)") }

    private func shown(_ f: F) async -> PrunePlan { await f.model.prunePlan(batch: f.batch).shown() }

    private func hooks(_ f: F, beforeMutation: (@MainActor (String) -> Void)? = nil) -> VideoScanModel.PruneVerifyHooks {
        PruneApplyTests.hooks(PruneApplyTests.Mover(trash: f.trashDir), beforeMutation: beforeMutation)
    }

    private func job(_ f: F, _ plan: PrunePlan, selected: Set<UUID>, hooks h: VideoScanModel.PruneVerifyHooks? = nil,
                     batchID: String = "test-job") -> PruneApplyJob {
        PruneApplyJob(model: f.model, shown: plan, selected: selected, batch: f.batch, batchID: batchID,
                      hooks: h ?? hooks(f))
    }

    private func start(_ center: MediaFileOperationsCenter, _ f: F, _ plan: PrunePlan, selected: Set<UUID>,
                       batchID: String, hooks h: VideoScanModel.PruneVerifyHooks? = nil) -> PruneApplyJob {
        center.startPruneApply(shown: plan, selected: selected, batch: f.batch, batchID: batchID, model: f.model,
                               hooks: h ?? hooks(f))
    }

    private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    /// Poll (bounded) until `condition` holds on the main actor.
    private func eventually(_ what: String, timeoutMs: Int = 4_000, _ condition: () -> Bool) async throws {
        var waited = 0
        while !condition() {
            try #require(waited < timeoutMs, "timed out waiting for: \(what)")
            try await Task.sleep(for: .milliseconds(20))
            waited += 20
        }
    }

    final class JobBox: @unchecked Sendable { var job: PruneApplyJob? }

    // MARK: The job

    @Test("JOB: every checked copy read then moved, one row per copy, the approval written ONCE with the actual count")
    func theJobRunsThePipeline() async throws {
        let f = try await fixture("pipeline"); defer { f.sb.cleanup() }
        let plan = await shown(f)
        let j = job(f, plan, selected: plan.offeredIDs)
        j.start()
        await j.task?.value
        #expect(j.state == .finished(summary: j.outcome.summary), "\(j.state)")
        #expect(j.title == "Move 2 copies to the Trash")
        #expect(j.outcome.trashed == 2 && j.outcome.verified == 2 && j.outcome.archiveReads == 1, "\(j.outcome)")
        #expect(j.rows.count == 2 && j.rows.allSatisfy { $0.status == .trashed && $0.note == "byte-identical to the archive copy" })
        #expect(j.progress.settled == 2 && j.fraction == 1)
        await f.model.mediaLedger.waitForPendingWrites()
        let approvals = f.model.mediaLedger.allEvents().filter { $0.event == .approval }
        #expect(approvals.count == 1 && approvals.first?.detail[MediaLedgerEvent.Detail.count] == "2" && approvals.first?.batchID == "test-job")
        #expect(f.model.mediaLedger.allEvents().filter { $0.event == .copyTrashed }.count == 2)
    }

    @Test("JOB: held copies are named in the rows and the log; no approval when nothing moved; a hold is a normal finish")
    func theJobNamesHeldCopies() async throws {
        let f = try await fixture("held"); defer { f.sb.cleanup() }
        let plan = await shown(f)
        let size = Int((try FileManager.default.attributesOfItem(atPath: f.archive.fullPath))[.size] as? Int64 ?? 0)
        try MasterArchiveTestSupport.writeBlob(at: URL(fileURLWithPath: f.archive.fullPath), bytes: size, seed: 505)
        let j = job(f, plan, selected: plan.offeredIDs)
        j.start()
        await j.task?.value
        #expect(j.state == .finished(summary: j.outcome.summary), "\(j.state)")
        #expect(j.outcome.trashed == 0 && j.rows.allSatisfy { $0.status == .held && $0.note.contains("archive copy changed") }, "\(j.rows)")
        await f.model.mediaLedger.waitForPendingWrites()
        #expect(!f.model.mediaLedger.allEvents().contains { $0.event == .approval })
    }

    @Test("JOB: Pause takes effect between files; Resume carries on")
    func theJobPausesBetweenFiles() async throws {
        let f = try await fixture("pause"); defer { f.sb.cleanup() }
        let plan = await shown(f)
        let first = f.source, second = f.copy
        let box = JobBox()
        let firstPath = first.fullPath
        let j = job(f, plan, selected: plan.offeredIDs, hooks: hooks(f, beforeMutation: { path in
            if path == firstPath { box.job?.pause() }
        }))
        box.job = j
        j.start()
        try await eventually("the first file moved and the job paused") {
            j.isPaused && j.rows.first { $0.id == first.id }?.status == .trashed
                && j.rows.first { $0.id == second.id }?.status == .pending
        }
        #expect(j.subtitle.contains("paused") && j.subtitle.hasPrefix("verified 1 of 2"), "\(j.subtitle)")
        #expect(exists(second.fullPath))
        j.resume()
        await j.task?.value
        #expect(j.outcome.trashed == 2 && !exists(second.fullPath), "\(j.outcome)")
    }

    @Test("JOB: Stop between a read and its move leaves that file and the rest; done stays done")
    func theJobStopsBetweenFiles() async throws {
        let f = try await fixture("stop"); defer { f.sb.cleanup() }
        let plan = await shown(f)
        let box = JobBox()
        let sourcePath = f.source.fullPath
        let j = job(f, plan, selected: plan.offeredIDs, hooks: hooks(f, beforeMutation: { path in
            if path == sourcePath { box.job?.stopForQuit() }
        }))
        box.job = j
        j.start()
        await j.task?.value
        #expect(j.state == .cancelled && j.subtitle.hasPrefix("Stopped — 0 moved to Trash"), "\(j.state)")
        #expect(j.rows.first { $0.id == f.source.id }?.note == "stopped before it was moved", "\(j.rows)")
        #expect(j.rows.first { $0.id == f.copy.id }?.status == .stopped)
        #expect(exists(f.source.fullPath) && exists(f.copy.fullPath))
        await f.model.mediaLedger.waitForPendingWrites()
        #expect(!f.model.mediaLedger.allEvents().contains { $0.event == .approval || $0.event == .copyTrashed })
        // Done stays done.
        let g = try await fixture("stop2"); defer { g.sb.cleanup() }
        let gp = await shown(g)
        let box2 = JobBox()
        let gCopy = g.copy.fullPath
        let j2 = job(g, gp, selected: gp.offeredIDs, hooks: hooks(g, beforeMutation: { path in
            if path == gCopy { box2.job?.cancel() }
        }))
        box2.job = j2
        j2.start()
        await j2.task?.value
        #expect(j2.state == .cancelled && j2.outcome.trashed == 1, "\(j2.outcome)")
        await g.model.mediaLedger.waitForPendingWrites()
        #expect(g.model.mediaLedger.allEvents().first { $0.event == .approval }?.detail[MediaLedgerEvent.Detail.count] == "1")
    }

    // MARK: The queue

    @Test("QUEUE: a second batch while one runs is queued, waits untouched, then runs after the first settles")
    func aSecondBatchQueues() async throws {
        let f = try await fixture("q1"); defer { f.sb.cleanup() }
        let g = try await fixture("q2"); defer { g.sb.cleanup() }
        let fp = await shown(f), gp = await shown(g)
        let center = MediaFileOperationsCenter()
        let first = start(center, f, fp, selected: [f.copy.id], batchID: "q1")
        let second = start(center, g, gp, selected: [g.copy.id], batchID: "q2")
        #expect(!second.wasRefused && second.isQueued && second.task == nil, "\(second.state)")
        #expect(second.subtitle == PruneApplyJob.waitingSubtitle(behind: first.title, ahead: 0), "\(second.subtitle)")
        #expect(center.runningPruneApply === first && center.queuedPruneApplies.map(\.id) == [second.id])
        await first.task?.value
        try await eventually("the second starts") { second.task != nil }
        await second.task?.value
        #expect(first.outcome.trashed == 1 && second.outcome.trashed == 1)
        #expect(!center.hasActivePruneApply)
        #expect(MediaFileOperationKind.pruneCopies.badgeText == "TRASH" && MediaFileOperationKind.pruneCopies.hasDetailView)
    }

    @Test("QUEUE OVERLAP: a copy checked in both batches is moved ONCE — the second skips it, never reads it")
    func anOverlappingCopyIsMovedOnce() async throws {
        let f = try await fixture("overlap"); defer { f.sb.cleanup() }
        let plan = await shown(f)
        let center = MediaFileOperationsCenter()
        let opens = PruneApplyTests.OpenCounter()
        let h2 = PruneApplyTests.hooks(PruneApplyTests.Mover(trash: f.trashDir), opens: opens)
        let first = start(center, f, plan, selected: [f.copy.id], batchID: "ov1")
        let second = start(center, f, plan, selected: plan.offeredIDs, batchID: "ov2", hooks: h2)
        await first.task?.value
        try await eventually("the second starts") { second.task != nil }
        await second.task?.value
        #expect(second.movedEarlier == [f.copy.id])
        #expect(second.outcome.trashed == 1 && second.outcome.movedByEarlierBatch == 1, "\(second.outcome)")
        let row = try #require(second.rows.first { $0.id == f.copy.id })
        #expect(row.status == .movedEarlier && PruneApplyDetailView.chip(row).label == "Already moved by the batch before")
        #expect(opens.opens(of: f.copy.fullPath) == 0)
    }

    @Test("QUEUE STOP: Stop on a waiting batch takes it out of the line; Quit drops waiting batches too")
    func stoppingAWaitingBatch() async throws {
        let f = try await fixture("qs1"); defer { f.sb.cleanup() }
        let g = try await fixture("qs2"); defer { g.sb.cleanup() }
        let fp = await shown(f), gp = await shown(g)
        let center = MediaFileOperationsCenter()
        let first = start(center, f, fp, selected: [f.copy.id], batchID: "st1")
        let second = start(center, g, gp, selected: [g.copy.id], batchID: "st2")
        let third = start(center, g, gp, selected: [g.source.id], batchID: "st3")
        #expect(center.queuedPruneApplies.map(\.id) == [second.id, third.id])
        second.cancel()
        #expect(second.state == .cancelled && second.droppedWhileQueued && second.task == nil)
        await first.task?.value
        try await eventually("the third starts") { third.task != nil }
        await third.task?.value
        #expect(exists(g.copy.fullPath), "the dropped batch's copy is untouched")
        #expect(third.outcome.trashed == 1 && !exists(g.source.fullPath), "\(third.outcome)")

        let h = try await fixture("qs3"); defer { h.sb.cleanup() }
        let hp = await shown(h)
        let running = start(center, h, hp, selected: [h.copy.id], batchID: "qt1")
        let waiting = start(center, h, hp, selected: [h.source.id], batchID: "qt2")
        center.stopAllForQuit()
        #expect(waiting.state == .cancelled && waiting.task == nil)
        let settled = await center.waitForPruneApplyToSettle(deadline: 10)
        #expect(settled && !running.state.isActive && exists(h.source.fullPath))
    }

    @Test("QUEUE STOP-RUNNING: Stop on the running batch takes the waiting one out of the line (stop is stop)")
    func stoppingTheRunningBatchDropsTheLine() async throws {
        let f = try await fixture("sr1"); defer { f.sb.cleanup() }
        let g = try await fixture("sr2"); defer { g.sb.cleanup() }
        let fp = await shown(f), gp = await shown(g)
        let center = MediaFileOperationsCenter()
        let box = JobBox()
        let first = start(center, f, fp, selected: [f.copy.id], batchID: "sr1", hooks: hooks(f, beforeMutation: { _ in
            box.job?.cancel()
        }))
        box.job = first
        let second = start(center, g, gp, selected: [g.copy.id], batchID: "sr2")
        await first.task?.value
        try await Task.sleep(for: .milliseconds(300))
        #expect(first.state == .cancelled && second.task == nil && second.droppedWhileQueued, "\(second.state)")
        #expect(exists(f.copy.fullPath) && exists(g.copy.fullPath))
    }

    @Test("QUEUE ERROR: a running batch that fails (read-only viewer) hands nothing on — the waiting batch leaves the line, logged")
    func anErrorDropsTheLine() async throws {
        let f = try await fixture("err1"); defer { f.sb.cleanup() }
        let g = try await fixture("err2"); defer { g.sb.cleanup() }
        let fp = await shown(f), gp = await shown(g)
        let sink = InMemoryLogSink()
        let previous = appLog
        appLog = sink
        defer { appLog = previous }
        let center = MediaFileOperationsCenter()
        f.model.isReadOnly = true
        let first = start(center, f, fp, selected: [f.copy.id], batchID: "er1")
        let second = start(center, g, gp, selected: [g.copy.id], batchID: "er2")
        await first.task?.value
        try await Task.sleep(for: .milliseconds(300))
        guard case .failed(let why) = first.state else { Issue.record("\(first.state)"); return }
        #expect(second.task == nil && second.droppedWhileQueued && exists(g.copy.fullPath))
        let line = PruneApplyJob.droppedLine(title: second.title, count: 1, bytes: g.copy.sizeBytes, reason: .batchBeforeFailed(why))
        #expect(sink.lines.contains { $0.contains(line) }, "\(sink.lines)")
    }

    /// A Trash seam that throws on the Nth call and moves every other file aside.
    final class FailingRemover: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        private let failOn: Int
        let trash: URL
        init(failOn: Int, trash: URL) { self.failOn = failOn; self.trash = trash }
        func remove(_ url: URL) throws {
            lock.lock(); calls += 1; let n = calls; lock.unlock()
            if n == failOn { throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path]) }
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(UUID().uuidString))
        }
    }

    @Test("codex #1642 P2-a: a Trash failure on the 2nd copy ends the batch FAILED (results kept) and the line is dropped")
    func aTrashFailureFailsTheBatch() async throws {
        let f = try await fixture("iofail1"); defer { f.sb.cleanup() }
        let g = try await fixture("iofail2"); defer { g.sb.cleanup() }
        let fp = await shown(f), gp = await shown(g)
        let remover = FailingRemover(failOn: 2, trash: f.trashDir)
        var h1 = hooks(f)
        h1.removeFile = { try remover.remove($0) }
        let center = MediaFileOperationsCenter()
        let first = start(center, f, fp, selected: fp.offeredIDs, batchID: "io1", hooks: h1)
        let second = start(center, g, gp, selected: [g.copy.id], batchID: "io2")
        await first.task?.value
        try await Task.sleep(for: .milliseconds(300))
        guard case .failed(let why) = first.state else { Issue.record("\(first.state)"); return }
        #expect(why.contains("could not be moved") && first.outcome.trashed == 1 && first.outcome.failed.count == 1, "\(first.outcome)")
        #expect(second.task == nil && second.droppedWhileQueued && exists(g.copy.fullPath))
    }

    @Test("a batch that only HOLDS is a normal finish — it hands on and the next batch runs")
    func aBatchThatOnlyHoldsHandsOn() async throws {
        let f = try await fixture("ho1"); defer { f.sb.cleanup() }
        let g = try await fixture("ho2"); defer { g.sb.cleanup() }
        let fp = await shown(f), gp = await shown(g)
        f.copy.fullPath += ".moved"   // held at prepare: changed since the list was shown
        let center = MediaFileOperationsCenter()
        let first = start(center, f, fp, selected: [f.copy.id], batchID: "ho1")
        let second = start(center, g, gp, selected: [g.copy.id], batchID: "ho2")
        await first.task?.value
        #expect(first.state == .finished(summary: first.outcome.summary) && first.outcome.held.count == 1, "\(first.state)")
        try await eventually("the second starts") { second.task != nil }
        await second.task?.value
        #expect(second.outcome.trashed == 1)
    }

    // MARK: Pure words

    @Test("QUEUE LOG LINES: queued / started / taken out of the line each carry the file count and bytes")
    func theQueueLogLines() {
        let q = PruneApplyJob.queuedLine(title: "Move 1 copy to the Trash", count: 1, bytes: 6_000_000_000,
                                         behind: "Move 2 copies to the Trash")
        #expect(q.hasPrefix("trash copies queued: Move 1 copy to the Trash — 1 copy, ") && q.contains("waits for Move 2 copies to the Trash"))
        let s0 = PruneApplyJob.startPlan(count: 2, bytes: 83_000_000_000, waitedSeconds: nil)
        #expect(s0.hasPrefix("2 copies, \(MediaBytes.display(83_000_000_000)) — read each copy and its archive copy in full") && !s0.contains("waited"), "\(s0)")
        let s1 = PruneApplyJob.startPlan(count: 1, bytes: 1_000, waitedSeconds: 125.4)
        #expect(s1.contains("(waited 125 s in line; every copy is checked now, at its turn)"))
        let d = PruneApplyJob.droppedLine(title: "Move 3 copies to the Trash", count: 3, bytes: 3_000, forQuit: true)
        #expect(d.hasPrefix("trash copies taken out of the line (quit): Move 3 copies to the Trash — 3 copies, "))
        #expect(PruneApplyJob.waitingSubtitle(behind: "X", ahead: 1, aheadIsPaused: true) == "Waiting — starts after X (paused) and 1 more waiting batch")
    }

    @Test("the job's subtitle: bytes-based progress, counts that exist, the time left")
    func theProgressSubtitle() {
        var p = PruneApplyProgress()
        p.total = 12; p.totalBytes = 12_000_000_000
        #expect(p.subtitle() == "verified 0 of 12" && p.fraction == 0)
        p.settle(bytes: 1_000_000_000, seconds: 30, result: .trashed(bytes: 1_000_000_000))
        p.settle(bytes: 1_000_000_000, seconds: 30, result: .trashed(bytes: 1_000_000_000))
        p.settle(bytes: 1_000_000_000, seconds: 20, result: .held("changed"))
        #expect(p.subtitle() == "verified 3 of 12 · 2 moved to Trash · 1 held · about 4 min left", "\(p.subtitle())")
        #expect(p.subtitle(paused: true) == "verified 3 of 12 · 2 moved to Trash · 1 held · paused")
    }

    @Test("the Trash routine's guard: a refusal from either callback leaves the file and the row untouched")
    func theJunkDeletionGuardRefuses() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("prune_guard"); defer { sb.cleanup() }
        let model = MasterArchiveTestSupport.makeModel(sb)
        model.mediaLedger = MediaLedger(directory: sb.root.appendingPathComponent("ledger", isDirectory: true))
        let file = try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent("test_guard.mov"), bytes: 1024, seed: 5)
        let rec = MasterArchiveTestSupport.makeRecord(path: file.path)
        model.records = [rec]
        let offDisk = await model.deleteConfirmedJunk([rec], mode: .permanent,
                                                      guard: .init(authorize: { _ in nil }, beforeRemoval: { _ in "the proof no longer holds" }))
        #expect(offDisk.succeeded == 0 && offDisk.refused.first?.reason == "the proof no longer holds")
        let inCatalog = await model.deleteConfirmedJunk([rec], mode: .permanent,
                                                        guard: .init(authorize: { _ in "not what was read" }, beforeRemoval: { _ in nil }))
        #expect(inCatalog.refused.first?.reason == "not what was read" && inCatalog.succeeded == 0)
        #expect(exists(file.path) && rec.purgedAt == nil)
    }
}
