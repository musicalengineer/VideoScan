// DeleteDuplicatesRunEndCharacterizationTests.swift
// Characterization of how a Delete Duplicates run ENDS (DeleteDuplicatesJob's
// run-end step, `finishRun`), written against the code before its 2026-11-07
// decomposition and green on it. Every way a run can end is pinned here by
// what a person or the next launch can see: the plan on disk (where it is
// filed, its outcome word, its last log line), the console lines, the
// `[dupjob]` summary word, the row's terminal state and subtitle, the result
// tuple, `duplicateStatus`, and that no file is lost on the way out.
//
// Ways a run ends (each has a test):
//   completed · completed with copies left alone · completed in
//   working-copy (cross-volume) mode · Stop that keeps the plan (suspend) ·
//   quit (suspend) · Stop and discard the rest · a mid-run plan save failure ·
//   a Stop that lands during the final save.
// Already pinned elsewhere and re-run with this suite: the final save failing
// (DeleteDuplicatesCodex1593Tests), a stranded quarantine keeping the plan out
// of done/ (DeleteDuplicatesTierAndSpeedTests), kept markers on every
// terminal line (DeleteDuplicatesCodex1593Tests).
//
// Isolation: catalog, ledger, plans and the Trash all live under a fresh temp
// folder per test; nothing touches App Support or the real Trash.

import Foundation
import os
import Testing
import VideoScanCore
@testable import VideoScan

private func runEndTempDir(_ label: String) -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("test_dupend_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@MainActor
private func runEndRecord(path: String, size: Int64, group: UUID, disposition: DuplicateDisposition) -> VideoRecord {
    let r = VideoRecord()
    r.fullPath = path
    r.filename = (path as NSString).lastPathComponent
    r.directory = (path as NSString).deletingLastPathComponent
    r.sizeBytes = size
    r.partialMD5 = "same"
    r.durationSeconds = 61
    r.duplicateGroupID = group
    r.duplicateDisposition = disposition
    r.duplicateConfidence = .high
    return r
}

/// Blocks the first duplicate block read until released (disk thread), and
/// can run a hook at the Nth quarantine move.
private final class RunEndGate: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var started = false
    private var quarantines = 0
    var blockFirstDuplicate = false
    var onQuarantine: ((Int) -> Void)?
    var hasStarted: Bool { lock.withLock { started } }

    func hooks(trashIn dir: URL) -> SignatureVerification.Hooks {
        SignatureVerification.Hooks(
            shouldCancel: { Task.isCancelled },
            didReadBlock: { [self] label in
                let first: Bool = lock.withLock {
                    guard label == "duplicate", !started else { return false }
                    started = true
                    return true
                }
                if first && blockFirstDuplicate { release.wait() }
            },
            didQuarantine: { [self] _ in
                let n: Int = lock.withLock { quarantines += 1; return quarantines }
                onQuarantine?(n)
            }).withScratchTrash(in: dir)
    }
}

private let runEndBlock = FileHasher.segmentSize
private let runEndFileSize = runEndBlock * 3

@Suite("Delete Duplicates — how a run ends (characterization)", .serialized)
@MainActor
struct DeleteDuplicatesRunEndCharacterizationTests {

    private struct Rig {
        let dir: URL
        let root: URL
        let model: VideoScanModel
        let keeper: VideoRecord
        let copies: [VideoRecord]
        let different: VideoRecord
        let bytes: [UInt8]
        func cleanup() {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            if let dirs = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                for d in dirs { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: d.path) }
            }
            try? FileManager.default.removeItem(at: dir)
        }
        var trashFolder: URL { dir.appendingPathComponent("Trash", isDirectory: true) }
        func filesInTrash() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: trashFolder.path)) ?? []).sorted()
        }
    }

    /// keeper + two identical copies + one look-alike; with the verified
    /// archive family (the tier's three verified copies) unless `archive` is
    /// false — then no copy can be proven to leave enough behind.
    private func makeRig(_ label: String, archive: Bool = true) -> Rig {
        let dir = runEndTempDir(label)
        let root = dir.appendingPathComponent("plans", isDirectory: true)
        let bytes = (0..<runEndFileSize).map { UInt8($0 % 199) }
        var other = bytes; other[runEndBlock + 500] ^= 0x5A
        func file(_ name: String, _ b: [UInt8]) -> URL {
            let u = dir.appendingPathComponent(name)
            FileManager.default.createFile(atPath: u.path, contents: Data(b))
            return u
        }
        let group = UUID()
        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: dir.appendingPathComponent("catalog", isDirectory: true))
        model.mediaLedger = MediaLedger(directory: dir.appendingPathComponent("ledger", isDirectory: true))
        let keeper = runEndRecord(path: file("keeper.mov", bytes).path, size: Int64(runEndFileSize), group: group, disposition: .keep)
        let copies = ["copy1.mov", "copy2.mov"].map {
            runEndRecord(path: file($0, bytes).path, size: Int64(runEndFileSize), group: group, disposition: .extraCopy)
        }
        let different = runEndRecord(path: file("lookalike.mov", other).path, size: Int64(runEndFileSize), group: group,
                                     disposition: .extraCopy)
        model.records = [keeper] + copies + [different]
        if archive { addVerifiedArchiveFamily(to: model, keeper: keeper) }
        return Rig(dir: dir, root: root, model: model, keeper: keeper, copies: copies, different: different, bytes: bytes)
    }

    private func makeJob(_ rig: Rig, gate: RunEndGate, sink: InMemoryLogSink) -> DeleteDuplicatesJob {
        let job = DeleteDuplicatesJob(model: rig.model, volumePath: rig.dir.path, hooks: gate.hooks(trashIn: rig.dir),
                                      planRoot: rig.root)
        job.appLogSink = sink
        return job
    }

    private func console(_ model: VideoScanModel) async -> String {
        try? await Task.sleep(nanoseconds: 400_000_000)   // console flush debounce (150 ms)
        return model.dashboard.consoleLines.joined(separator: "\n")
    }

    private func waitForFirstDuplicateRead(_ gate: RunEndGate) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline, !gate.hasStarted { await Task.yield() }
    }

    private func donePlanExists(_ id: UUID, _ rig: Rig) -> Bool {
        FileManager.default.fileExists(
            atPath: DeleteDuplicatesPlanStore.doneURL(for: id, root: rig.root).appendingPathComponent("plan.json").path)
    }

    /// The `[dupjob]` run summary line (`delete duplicates <how>: …`).
    private func summaryLines(_ sink: InMemoryLogSink) -> [String] {
        sink.lines.filter { $0.contains("delete duplicates ") && $0.contains(" — deleted ") }
    }

    // MARK: completed

    @Test func completedRunLogsItsOutcomeFilesThePlanAndEndsFinished() async throws {
        let rig = makeRig("completed"); defer { rig.cleanup() }
        let sink = InMemoryLogSink()
        let gate = RunEndGate()
        let mutated = OSAllocatedUnfairLock(initialState: 0)
        let token = NotificationCenter.default.addObserver(forName: .videoScanCatalogMutated, object: nil, queue: nil) { _ in
            mutated.withLock { $0 += 1 }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        let job = makeJob(rig, gate: gate, sink: sink)
        job.start()
        await job.task?.value

        let plan = try #require(job.plan)
        let report = plan.outcomeReport
        let completion = report.line + " (\(plan.summaryLine))"
        let moved = ByteCountFormatter.string(fromByteCount: Int64(runEndFileSize * 2), countStyle: .file)
        #expect(job.state == .finished(summary: "Moved 2 (\(moved)) to the Trash · 1 held (content differs from keeper keeper.mov — NOT a duplicate)"),
                "\(job.state)")
        #expect(job.subtitle == "Moved 2 (\(moved)) to the Trash · 1 held (content differs from keeper keeper.mov — NOT a duplicate)")
        #expect(job.result.deleted == 2 && job.result.failed == 0 && job.result.skipped == 0 && job.result.bytesFreed == 0)
        #expect(rig.model.duplicateStatus == report.line)
        #expect(plan.outcome == "completed" && plan.finishedAt != nil)
        #expect(plan.log.last == completion, "the plan's last log line is the completion line: \(plan.log.last ?? "nil")")
        #expect(donePlanExists(plan.id, rig), "a finished plan is filed under done/")
        #expect(!FileManager.default.fileExists(atPath: DeleteDuplicatesPlanStore.planURL(for: plan.id, root: rig.root).path))
        let text = await console(rig.model)
        #expect(text.contains("Delete Duplicates complete: \(completion)"), "\(text)")
        #expect(text.contains("1 file(s) were NOT identical to their keeper despite matching on hash/name/duration — they are marked Review and left on disk."))
        #expect(!text.contains("were left alone because no verified copy would remain"))
        #expect(!text.contains("Working-copy cleanup on"))
        #expect(summaryLines(sink).count == 1 && summaryLines(sink)[0].contains("delete duplicates done: "), "\(sink.lines)")
        #expect(mutated.withLock { $0 } >= 1, "a run that changed rows tells the catalog")
        // Never lose media: keeper + look-alike in place, both copies in the (scratch) Trash.
        #expect(FileManager.default.fileExists(atPath: rig.keeper.fullPath))
        #expect(FileManager.default.fileExists(atPath: rig.different.fullPath))
        #expect(rig.filesInTrash().count == 2, "\(rig.filesInTrash())")
    }

    /// Every copy is on a network share (R4's gate, injected): each is left
    /// alone at its turn — nothing moves — and the end says why.
    @Test func completedRunWithCopiesLeftAloneSaysWhy() async throws {
        let rig = makeRig("leftalone"); defer { rig.cleanup() }
        let sink = InMemoryLogSink()
        let job = makeJob(rig, gate: RunEndGate(), sink: sink)
        job.isNetworkMountForPath = { _ in true }
        job.start()
        await job.task?.value

        let plan = try #require(job.plan)
        let report = plan.outcomeReport
        #expect(plan.outcome == "completed")
        #expect(rig.model.duplicateStatus == report.line)
        let text = await console(rig.model)
        #expect(text.contains("3 file(s) were left alone because no verified copy would remain — their keeper could not be proven; check it, then run again."),
                "\(text)")
        // Nothing left the drive: every file is where it was.
        for r in [rig.keeper] + rig.copies + [rig.different] {
            #expect(FileManager.default.fileExists(atPath: r.fullPath), "\(r.filename)")
        }
        #expect(rig.filesInTrash().isEmpty)
        #expect(job.result.deleted == 0 && job.result.failed == 0)
        #expect(job.result.skipped == 3, "skipped = left alone (3) + skipped before the plan (0)")
        #expect(donePlanExists(plan.id, rig))
        #expect(summaryLines(sink).first?.contains("delete duplicates done: ") == true)
    }

    @Test func completedWorkingCopyRunLogsTheWorkingCopyLine() async throws {
        let rig = makeRig("crossvol"); defer { rig.cleanup() }
        let entry = DeleteDuplicatesPlan.Entry(id: rig.copies[0].id, path: rig.copies[0].fullPath, filename: rig.copies[0].filename,
                                               sizeBytes: rig.copies[0].sizeBytes, keeperID: rig.keeper.id,
                                               keeperPath: rig.keeper.fullPath, keeperFilename: rig.keeper.filename,
                                               keeperStamp: FileIdentityStamp.capture(path: rig.keeper.fullPath))
        var plan = DeleteDuplicatesPlan(volumePath: rig.dir.path, catalogLocation: rig.model.catalogStore.fileLocation,
                                        crossVolumeMode: true, skippedBeforePlan: 0, summaryLine: "1 working copy",
                                        entries: [entry])
        plan.startedAt = Date().addingTimeInterval(-60)
        try DeleteDuplicatesPlanStore.save(plan, root: rig.root)
        let job = DeleteDuplicatesJob(model: rig.model, resuming: plan, hooks: RunEndGate().hooks(trashIn: rig.dir),
                                      planRoot: rig.root)
        job.appLogSink = InMemoryLogSink()
        job.start()
        await job.task?.value

        let after = try #require(job.plan)
        let completion = after.outcomeReport.line + " (1 working copy)"
        let text = await console(rig.model)
        #expect(text.contains(WorkingCopyCleanupText.logSummary(volume: rig.dir.lastPathComponent, detail: "complete — " + completion)),
                "\(text)")
        #expect(!text.contains("Delete Duplicates complete:"))
        #expect(after.outcome == "completed" && after.log.last == completion)
    }

    // MARK: suspend (Stop that keeps the plan, quit)

    @Test func stopThatKeepsThePlanSuspendsWithEveryLine() async throws {
        let rig = makeRig("stopkeep"); defer { rig.cleanup() }
        let sink = InMemoryLogSink()
        let gate = RunEndGate(); gate.blockFirstDuplicate = true
        let job = makeJob(rig, gate: gate, sink: sink)
        job.start()
        await waitForFirstDuplicateRead(gate)
        job.cancel()
        gate.release.signal()
        await job.task?.value

        #expect(job.state == .cancelled)
        #expect(job.subtitle == "Stopped — 0 moved to the Trash; 3 remaining kept for later (Resume in Media File Operations)",
                Comment(rawValue: job.subtitle))
        #expect(job.result.deleted == 0 && job.result.failed == 0 && job.result.skipped == 0 && job.result.bytesFreed == 0)
        #expect(rig.model.duplicateStatus == "0 moved to the Trash — 3 remaining, resume offered")
        let plan = try #require(job.plan)
        #expect(plan.outcome == nil && plan.finishedAt == nil)
        #expect(plan.log.last == "Suspended by Stop with 3 remaining — offered to resume now, or at the next launch",
                "\(plan.log.last ?? "nil")")
        let onDisk = try DeleteDuplicatesPlanStore.load(url: DeleteDuplicatesPlanStore.planURL(for: plan.id, root: rig.root))
        #expect(onDisk.log.last == plan.log.last, "the suspended plan is saved in place")
        #expect(!donePlanExists(plan.id, rig))
        let text = await console(rig.model)
        #expect(text.contains("Delete Duplicates on \(rig.dir.lastPathComponent) suspended for Stop: 0 moved to the Trash, 3 remaining — kept; Resume in Media File Operations, or at the next launch."),
                "\(text)")
        #expect(!text.contains("Delete Duplicates complete:"))
        #expect(summaryLines(sink).count == 1 && summaryLines(sink)[0].contains("delete duplicates stopped: "), "\(sink.lines)")
        for r in rig.copies + [rig.different] { #expect(FileManager.default.fileExists(atPath: r.fullPath)) }
    }

    @Test func quitSuspendsWithEveryLine() async throws {
        let rig = makeRig("quit"); defer { rig.cleanup() }
        let sink = InMemoryLogSink()
        let gate = RunEndGate(); gate.blockFirstDuplicate = true
        let job = makeJob(rig, gate: gate, sink: sink)
        job.start()
        await waitForFirstDuplicateRead(gate)
        job.stopForQuit()
        gate.release.signal()
        await job.task?.value

        #expect(job.state == .cancelled)
        #expect(job.subtitle == "Suspended for quit — 0 moved to the Trash; 3 remaining will be offered to resume at the next launch",
                Comment(rawValue: job.subtitle))
        #expect(rig.model.duplicateStatus == "0 moved to the Trash — 3 remaining, resume offered")
        let plan = try #require(job.plan)
        #expect(plan.outcome == nil && plan.finishedAt == nil)
        #expect(plan.log.last == "Suspended by quit with 3 remaining — offered to resume at the next launch", "\(plan.log.last ?? "nil")")
        #expect(!donePlanExists(plan.id, rig))
        let text = await console(rig.model)
        #expect(text.contains("suspended for quit: 0 moved to the Trash, 3 remaining — the run will be offered to resume at the next launch."),
                "\(text)")
        #expect(summaryLines(sink).count == 1 && summaryLines(sink)[0].contains("delete duplicates suspended for quit: "), "\(sink.lines)")
        for r in rig.copies + [rig.different] { #expect(FileManager.default.fileExists(atPath: r.fullPath)) }
    }

    // MARK: Stop and discard the rest

    @Test func discardCountsTheRestAsNotDoneAndSaysCancelled() async throws {
        let rig = makeRig("discard"); defer { rig.cleanup() }
        let sink = InMemoryLogSink()
        let gate = RunEndGate(); gate.blockFirstDuplicate = true
        let job = makeJob(rig, gate: gate, sink: sink)
        job.start()
        await waitForFirstDuplicateRead(gate)
        job.cancel(discardingRemaining: true)
        gate.release.signal()
        await job.task?.value

        #expect(job.state == .cancelled)
        #expect(job.subtitle == "Stopped — 0 moved to the Trash, the rest left alone", Comment(rawValue: job.subtitle))
        #expect(job.result.deleted == 0 && job.result.failed == 3)
        let plan = try #require(job.plan)
        let completion = plan.outcomeReport.line + " (\(plan.summaryLine))"
        #expect(plan.outcome == "cancelled" && plan.finishedAt != nil)
        #expect(plan.log.last == completion)
        // The row in flight was put back by the Stop; the rows never reached
        // are skipped as cancelled.
        #expect(plan.entries[0].status == .skipped && plan.entries[0].note == "cancelled during verification — left alone"
                && plan.entries[0].outcomeKind == .cancelled, "\(plan.entries[0].status) \(plan.entries[0].note)")
        #expect(plan.entries.dropFirst().allSatisfy { $0.status == .skipped && $0.note == "cancelled before verification" },
                "\(plan.entries.map(\.note))")
        #expect(rig.model.duplicateStatus == plan.outcomeReport.line)
        #expect(donePlanExists(plan.id, rig), "a discarded run is filed under done/")
        let text = await console(rig.model)
        #expect(text.contains("Duplicate deletion cancelled before verification completed"))
        #expect(text.contains("Delete Duplicates complete: \(completion)"))
        let line = try #require(summaryLines(sink).first, "\(sink.lines)")
        #expect(line.contains("delete duplicates cancelled: "))
        let notDone = ByteCountFormatter.string(fromByteCount: Int64(runEndFileSize * 3), countStyle: .file)
        #expect(line.contains("not done 3 (\(notDone))"), "\(line)")
        for r in rig.copies + [rig.different] { #expect(FileManager.default.fileExists(atPath: r.fullPath)) }
    }

    // MARK: a plan save failure mid-run

    @Test func aMidRunPlanSaveFailureStopsTheRunAndSaysSo() async throws {
        let rig = makeRig("savefail"); defer { rig.cleanup() }
        let sink = InMemoryLogSink()
        let gate = RunEndGate()
        let root = rig.root
        // The second file's move into quarantine: from here on the plan
        // folder is read-only, so the next plan save fails.
        gate.onQuarantine = { n in
            guard n == 2, let dirs = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            else { return }
            for d in dirs where d.lastPathComponent != "done" {
                try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: d.path)
            }
        }
        let job = makeJob(rig, gate: gate, sink: sink)
        job.start()
        await job.task?.value

        let plan = try #require(job.plan)
        guard case .failed(let message) = job.state else {
            Issue.record("expected .failed, got \(job.state)"); return
        }
        #expect(message.hasPrefix("Stopped after 1 moved to the Trash — the plan could not be saved ("), "\(message)")
        #expect(plan.outcome == "stopped (plan not saved)" && plan.finishedAt != nil)
        #expect(plan.entries.last?.status == .skipped
                && plan.entries.last?.note.contains("stopped — the plan could not be saved, so the rest was left alone") == true,
                "\(plan.entries.map(\.status)) \(plan.entries.map(\.note))")
        #expect(!donePlanExists(plan.id, rig), "the final save fails too: never filed as done")
        let text = await console(rig.model)
        #expect(!text.contains("Duplicate deletion cancelled before verification completed"),
                "a save failure is not a cancel")
        #expect(text.contains("the finished plan could not be saved"), "\(text)")
        let line = try #require(summaryLines(sink).first, "\(sink.lines)")
        #expect(line.contains("delete duplicates stopped (plan not saved): "), "\(line)")
        // Never lose media: the keeper stays; every copy is at its path or in the Trash.
        #expect(FileManager.default.fileExists(atPath: rig.keeper.fullPath))
        let atPath = (rig.copies + [rig.different]).filter { FileManager.default.fileExists(atPath: $0.fullPath) }.count
        #expect(atPath + rig.filesInTrash().count == 3, "at path \(atPath), in Trash \(rig.filesInTrash())")
    }

    // MARK: a Stop that lands during the final save

    @Test func aStopDuringTheFinalSaveEndsCancelledWhileThePlanSaysCompleted() async throws {
        let rig = makeRig("latestop"); defer { rig.cleanup() }
        let sink = InMemoryLogSink()
        let job = makeJob(rig, gate: RunEndGate(), sink: sink)
        job.testHookBeforeFinalSave = { [weak job] in job?.cancel() }
        job.start()
        await job.task?.value

        // The plan's outcome is decided before the final save (every row
        // settled: "completed"); the row's end and the summary word are
        // read after it, so they say Stop.
        let plan = try #require(job.plan)
        #expect(plan.outcome == "completed")
        #expect(donePlanExists(plan.id, rig))
        #expect(job.state == .cancelled)
        #expect(job.subtitle == "Stopped — 2 moved to the Trash, the rest left alone", Comment(rawValue: job.subtitle))
        let line = try #require(summaryLines(sink).first, "\(sink.lines)")
        #expect(line.contains("delete duplicates cancelled: "), "\(line)")
        let text = await console(rig.model)
        #expect(!text.contains("Duplicate deletion cancelled before verification completed"),
                "the Stop came after every row settled")
    }
}
