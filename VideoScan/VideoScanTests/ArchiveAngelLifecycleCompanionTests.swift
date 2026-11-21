// ArchiveAngelLifecycleCompanionTests.swift
// codex review 2026-09-20 #4 and #11, through the REAL lifecycle entry
// points — ArchiveAngelJob.skip / cancel, ArchiveAngelPlanStore's settle —
// on real (tiny, synthetic) media, so removing the production wiring
// cannot leave these green.
//
//   #4  A companion record is retired, with its `copyDeleted` line, ONLY
//       when its file is confirmed gone. Removal failures are injected the
//       way they happen in life: a read-only entry folder. The surviving
//       record keeps its place in the catalog and earns no history line.
//   #11 A row waiting for buffer space stays skippable after the job has
//       finished — the skip goes to the plan on disk, saves, and leaves
//       its ledger line; ready rows and cleared batches are refused.
//
// Dimensions: LOGIC · MEDIA (real mp4 through the production job) ·
// ISOLATION (sandbox model, ledger, buffer) · SENSOR (a survivor is never
// tombstoned; a skip after finish never touches a batch that was cleared).

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

// Parallel: the slow ffmpeg is a ScriptedExecutor bound to each test's task
// tree (it was a fake behind the process-global VS_FFMPEG_PATH, serialized).
@Suite("Archive Angel — companions go only with files confirmed gone; skip after finish")
@MainActor
struct ArchiveAngelLifecycleCompanionTests {
    static let ffmpeg = ToolLocator.ffmpegPath

    struct Bench {
        let sb: MasterArchiveTestSupport.Sandbox
        let model: VideoScanModel
        let center: MediaFileOperationsCenter
        let buffer: URL
    }

    private func bench(_ label: String) throws -> Bench {
        let sb = try MasterArchiveTestSupport.makeSandbox(label)
        try FileManager.default.createDirectory(at: sb.archiveVolume, withIntermediateDirectories: true)
        let model = MasterArchiveTestSupport.makeModel(sb)
        model.mediaLedger = MediaLedger(directory: sb.root.appendingPathComponent("ledger", isDirectory: true))
        model.scanTargets = []
        model.previewSweep.stop()
        model.archiveAngel.sweep.stop()
        model.masterArchive = MasterArchiveDesignation(targetPath: sb.archiveVolume.path,
                                                       rootPath: sb.archiveRoot.path, volumeUUID: nil)
        let buffer = sb.root.appendingPathComponent("Buffer", isDirectory: true)
        try FileManager.default.createDirectory(at: buffer, withIntermediateDirectories: true)
        return Bench(sb: sb, model: model, center: MediaFileOperationsCenter(), buffer: buffer)
    }

    private func clip(_ name: String, in dir: URL) async throws -> URL {
        let url = dir.appendingPathComponent(name)
        let r = await ProcessRunner.runProcess(
            executable: Self.ffmpeg,
            arguments: ["-hide_banner", "-loglevel", "error", "-y",
                        "-f", "lavfi", "-i", "testsrc=size=320x240:rate=30:duration=4",
                        "-f", "lavfi", "-i", "sine=frequency=440:duration=4",
                        "-c:v", "libx264", "-pix_fmt", "yuv420p",
                        // Sound on the left only, so Prepare makes a balanced
                        // copy as well as an access copy (2026-11-16: a mono
                        // clip is no longer balanced).
                        "-af", "pan=stereo|c0=c0|c1=0*c0", "-c:a", "aac", "-ac", "2", "-shortest", url.path],
            deadlineSeconds: 120)
        try #require(r.exitCode == 0, "fixture \(name): \(r.stderr)")
        return url
    }

    private func record(_ url: URL, sizeBytes: Int64? = nil) -> VideoRecord {
        let r = MasterArchiveTestSupport.makeRecord(path: url.path, userDate: "1995", starRating: 2)
        r.durationSeconds = 600
        r.videoCodec = "h264"
        r.audioCodec = "aac"
        r.isPlayable = "Yes"
        if let sizeBytes { r.sizeBytes = sizeBytes }
        return r
    }

    /// An ffmpeg that waits before working on any file whose name has
    /// `slowMarker` in it — a long transcode, so a skip or cancel can land
    /// while a later row is being prepared and earlier rows are ready.
    /// Every command is the real tool; only the delay is scripted.
    private func slowFFmpeg(in sb: MasterArchiveTestSupport.Sandbox, slowMarker: String, seconds: Int) -> ScriptedExecutor {
        ScriptedExecutor(claiming: [sb.root.path])
            .on("ffmpeg", containing: [slowMarker], .after(.seconds(seconds), then: .passThrough))
            .on("*", .passThrough)
    }

    private func entryDir(_ job: ArchiveAngelJob, _ id: UUID) -> URL {
        URL(fileURLWithPath: job.plan.batchDir).appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// Poll (yielding to the job, which runs on this actor) until `cond`.
    private func waitUntil(_ what: String, seconds: Double = 40, _ cond: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !cond() {
            try #require(Date() < deadline, "timed out waiting for \(what)")
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func copyDeletedLines(_ model: VideoScanModel) async -> [MediaLedgerEvent] {
        await model.mediaLedger.waitForPendingWrites()
        return model.mediaLedger.allEvents().filter { $0.event == .copyDeleted }
    }

    private func setPerms(_ mode: Int, _ path: String) {
        try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
    }

    // MARK: - #4 Skip (the non-live path) while the job runs

    @Test("Skip of a READY row while the batch runs: a removal that fails keeps the catalogued access copy and writes no copyDeleted; one that succeeds retires it")
    func skipReadyRowReconcilesAgainstTheDisk() async throws {
        let b = try bench("lifecycle_skip"); defer { b.sb.cleanup() }
        let fm = FileManager.default
        let a = try await clip("test_lc_a.mp4", in: b.sb.sources)
        let c = try await clip("test_lc_b.mp4", in: b.sb.sources)
        let slow = try await clip("test_lc_slow.mp4", in: b.sb.sources)
        try await slowFFmpeg(in: b.sb, slowMarker: "test_lc_slow", seconds: 4).scoped {
            let recA = record(a), recB = record(c), recSlow = record(slow)
            b.model.records = [recA, recB, recSlow]
            let job = ArchiveAngelJob(model: b.model, center: b.center, count: 3, makeLossless: false,
                                      bufferRoot: b.buffer, explicitRecordIDs: [recA.id, recB.id, recSlow.id])
            job.start()
            defer { job.cancel() }

            // The two small files are ready and the slow one is being prepared.
            try await waitUntil("A and B ready, slow preparing") {
                job.preparingEntryID == recSlow.id
                    && job.plan.entries.first { $0.id == recA.id }?.status == .ready
                    && job.plan.entries.first { $0.id == recB.id }?.status == .ready
            }
            let dirA = entryDir(job, recA.id), dirB = entryDir(job, recB.id)
            // The Balance and Transcode jobs catalogued each row's companions
            // (the left-only test clip gets a balanced copy AND an access copy; the
            // access copy is derived from the balanced one, so match by folder).
            let compsA = b.model.records.filter { $0.fullPath.hasPrefix(dirA.path + "/") }
            let compsB = b.model.records.filter { $0.fullPath.hasPrefix(dirB.path + "/") }
            #expect(compsA.count == 2 && compsB.count == 2, "\((compsA + compsB).map(\.filename))")
            try #require(!compsA.isEmpty && !compsB.isEmpty, "the jobs catalogued the companions: \(b.model.records.map(\.filename))")
            #expect((compsA + compsB).allSatisfy { fm.fileExists(atPath: $0.fullPath) })

            // Injected removal failure: A's folder is read-only.
            setPerms(0o555, dirA.path)
            defer { setPerms(0o755, dirA.path) }
            #expect(job.skip(entryID: recA.id))
            await job.cleanupTask?.value
            #expect(compsA.allSatisfy { fm.fileExists(atPath: $0.fullPath) }, "the files survived the failed removal")
            #expect(compsA.allSatisfy { !$0.isPurged }, "SENSOR: a record is never tombstoned while its file is still there")
            #expect(await copyDeletedLines(b.model).isEmpty, "no history line for a deletion that did not happen")
            #expect(job.plan.entries.first { $0.id == recA.id }?.status == .skipped, "the decision itself stands")
            try await Task.sleep(nanoseconds: 300_000_000)
            #expect(b.model.dashboard.consoleLines.contains {
                $0.contains("kept \(compsA.count) companion record(s)") && $0.contains("skipped by you") },
                    "\(b.model.dashboard.consoleLines.suffix(8))")

            // The success path: B's folder is writable.
            #expect(job.skip(entryID: recB.id))
            await job.cleanupTask?.value
            #expect(!fm.fileExists(atPath: dirB.path))
            #expect(compsB.filter { !$0.isPurged }.isEmpty, "every companion of B is retired")
            let lines = await copyDeletedLines(b.model)
            #expect(Set(lines.map(\.recordID)) == Set(compsB.map(\.id)), "exactly the confirmed deletions: \(lines.map(\.filename))")
            #expect(lines.allSatisfy { $0.by == .angel && $0.batchID == job.plan.batchID })

            setPerms(0o755, dirA.path)
            await job.task?.value
            guard case .finished = job.state else { Issue.record("\(job.state)"); return }
            #expect(try ArchiveAngelPlanStore.load(batchDir: job.plan.batchDir).skippedCount == 2)
        }
    }

    // MARK: - #4 Cancel (the reclaim of unfinished rows)

    @Test("Cancel with a completed companion in the unfinished row's folder: a read-only folder keeps the record; a writable one retires it")
    func cancelReconcilesReclaimedCompanions() async throws {
        let b = try bench("lifecycle_cancel"); defer { b.sb.cleanup() }
        let fm = FileManager.default
        let a = try await clip("test_lc_ca.mp4", in: b.sb.sources)
        let slow = try await clip("test_lc_slowc.mp4", in: b.sb.sources)
        try await slowFFmpeg(in: b.sb, slowMarker: "test_lc_slowc", seconds: 4).scoped {

            for removalFails in [true, false] {
                let recA = record(a), recSlow = record(slow)
                b.model.records = [recA, recSlow]
                let job = ArchiveAngelJob(model: b.model, center: b.center, count: 2, makeLossless: false,
                                          bufferRoot: b.buffer, explicitRecordIDs: [recA.id, recSlow.id])
                job.start()
                try await waitUntil("A ready, slow preparing") {
                    job.preparingEntryID == recSlow.id && job.plan.entries.first { $0.id == recA.id }?.status == .ready
                }
                // A "completed" companion of the unfinished row: BalanceAudio
                // catalogues its output the moment it finishes, before the
                // access copy runs. Planted here with a real file.
                let dirSlow = entryDir(job, recSlow.id)
                try fm.createDirectory(at: dirSlow, withIntermediateDirectories: true)
                let balanced = dirSlow.appendingPathComponent("test_lc_slowc_balanced.mov")
                try Data(count: 4_096).write(to: balanced)
                let planted = VideoRecord()
                planted.filename = balanced.lastPathComponent
                planted.fullPath = balanced.path
                planted.sizeBytes = 4_096
                planted.derivedFrom = recSlow.id
                planted.workspaceActive = true
                b.model.records.append(planted)
                if removalFails { setPerms(0o555, dirSlow.path) }

                job.cancel()
                await job.task?.value
                await job.cleanupTask?.value
                #expect(job.state == .cancelled)
                let onDisk = try ArchiveAngelPlanStore.load(batchDir: job.plan.batchDir)
                #expect(onDisk.status == .ready && onDisk.entries.first { $0.id == recSlow.id }?.status == .failed, "settled: A stays reviewable")

                if removalFails {
                    #expect(fm.fileExists(atPath: balanced.path), "the reclaim could not remove the read-only folder")
                    #expect(!planted.isPurged, "SENSOR: the surviving companion keeps its record")
                    #expect(await copyDeletedLines(b.model).isEmpty)
                    setPerms(0o755, dirSlow.path)
                } else {
                    #expect(!fm.fileExists(atPath: dirSlow.path))
                    #expect(planted.isPurged)
                    let lines = await copyDeletedLines(b.model)
                    #expect(lines.map(\.recordID) == [planted.id] && lines.first?.batchID == job.plan.batchID, "\(lines.map(\.filename))")
                }
            }
        }
    }

    // MARK: - #4 The settle (Archive tab refresh) on disk

    @Test("Settle of an interrupted batch: a companion whose folder could not be reclaimed keeps its record; a discarded batch whose folder would not go keeps its records")
    func settleReconcilesOnDisk() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("lifecycle_settle"); defer { sb.cleanup() }
        let fm = FileManager.default
        let model = MasterArchiveTestSupport.makeModel(sb)
        model.mediaLedger = MediaLedger(directory: sb.root.appendingPathComponent("ledger", isDirectory: true))
        let root = sb.root.appendingPathComponent("buffer", isDirectory: true)
        func entry(_ id: UUID, _ status: ArchiveAngelPlan.EntryStatus) -> ArchiveAngelPlan.Entry {
            .init(id: id, sourcePath: "/v/\(id).mov", filename: "\(id).mov", sizeBytes: 1, durationSeconds: 3600,
                  score: 40, evidence: [], proposedName: "x.mov", proposedDate: nil, status: status)
        }
        func companion(_ dir: URL, _ name: String) throws -> VideoRecord {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(name)
            try Data(count: 2_048).write(to: url)
            let r = VideoRecord()
            r.filename = name; r.fullPath = url.path; r.sizeBytes = 2_048; r.workspaceActive = true
            return r
        }
        // Kept batch: one ready row, one row interrupted mid-preparation whose folder is read-only.
        let ready = UUID(), stuck = UUID()
        var kept = ArchiveAngelPlan(batchDir: root.appendingPathComponent("batch-kept").path, requestedCount: 2,
                                    makeLossless: false, entries: [entry(ready, .ready), entry(stuck, .preparing)])
        try ArchiveAngelPlanStore.save(kept)
        let stuckDir = URL(fileURLWithPath: kept.batchDir).appendingPathComponent(stuck.uuidString)
        let stuckComp = try companion(stuckDir, "stuck_balanced.mov")
        setPerms(0o555, stuckDir.path)
        defer { setPerms(0o755, stuckDir.path) }
        // Discarded batch: nothing prepared; its whole folder is read-only.
        let lone = UUID()
        let gone = ArchiveAngelPlan(batchDir: root.appendingPathComponent("batch-gone").path, requestedCount: 1,
                                    makeLossless: false, entries: [entry(lone, .preparing)])
        try ArchiveAngelPlanStore.save(gone)
        let loneDir = URL(fileURLWithPath: gone.batchDir).appendingPathComponent(lone.uuidString)
        let loneComp = try companion(loneDir, "lone_balanced.mov")
        setPerms(0o555, loneDir.path)
        defer { setPerms(0o755, loneDir.path) }
        // A writable sibling: the same shape, reclaimed for real.
        let stuck2 = UUID()
        let kept2 = ArchiveAngelPlan(batchDir: root.appendingPathComponent("batch-kept2").path, requestedCount: 2,
                                     makeLossless: false, entries: [entry(UUID(), .ready), entry(stuck2, .preparing)])
        try ArchiveAngelPlanStore.save(kept2)
        let stuck2Comp = try companion(URL(fileURLWithPath: kept2.batchDir).appendingPathComponent(stuck2.uuidString), "s2_balanced.mov")
        for p in [kept, gone, kept2] {
            try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-7_200)], ofItemAtPath: p.planURL.path)
        }
        model.records = [stuckComp, loneComp, stuck2Comp]

        // What ArchiveView.refreshAngelBatches does: settle off-main, then reconcile on main.
        let settled = await Task.detached { ArchiveAngelPlanStore.settleInterruptedBatches(bufferRoot: root) }.value
        #expect(settled.count == 3)
        let n = model.forgetArchiveAngelCompanions(settled: settled)
        #expect(n == 1, "only the companion whose file really went")
        #expect(fm.fileExists(atPath: stuckComp.fullPath) && !stuckComp.isPurged, "read-only entry folder: kept")
        #expect(fm.fileExists(atPath: loneComp.fullPath) && !loneComp.isPurged, "read-only discarded batch: kept")
        #expect(!fm.fileExists(atPath: stuck2Comp.fullPath) && stuck2Comp.isPurged)
        let lines = await copyDeletedLines(model)
        #expect(lines.map(\.recordID) == [stuck2Comp.id], "\(lines.map(\.filename))")
        kept = try ArchiveAngelPlanStore.load(batchDir: kept.batchDir)
        #expect(kept.status == .ready && kept.entries.first { $0.id == stuck }?.status == .failed)
        #expect(fm.fileExists(atPath: gone.batchDir), "the discarded batch's folder could not go — it is still here, not forgotten")
    }

    // MARK: - #11 Skip after the job finished

    @Test("A row waiting for buffer space is skippable after the job finished: plan on disk transitions and saves, ledger line written; ready rows and cleared batches are refused")
    func waitingRowSkipsAfterTheJobFinished() async throws {
        let b = try bench("lifecycle_waiting"); defer { b.sb.cleanup() }
        let fm = FileManager.default
        let a = try await clip("test_lc_w_a.mp4", in: b.sb.sources)
        // Two impossibly large "tapes": the free-space precheck parks them
        // before any media work; one small file is prepared for real.
        let big1 = record(b.sb.sources.appendingPathComponent("test_lc_big1.mkv"), sizeBytes: 1_000_000_000_000_000)
        let big2 = record(b.sb.sources.appendingPathComponent("test_lc_big2.mkv"), sizeBytes: 1_000_000_000_000_000)
        let small = record(a)
        b.model.records = [big1, big2, small]
        let job = ArchiveAngelJob(model: b.model, center: b.center, count: 3, makeLossless: false,
                                  bufferRoot: b.buffer, explicitRecordIDs: [big1.id, big2.id, small.id])
        job.start()
        await job.task?.value
        guard case .finished = job.state else { Issue.record("\(job.state) — \(job.plan.log.suffix(4))"); return }
        let byID = { (id: UUID) in job.plan.entries.first { $0.id == id } }
        let parked = try #require(byID(big1.id)), prepared = try #require(byID(small.id))
        #expect(parked.isBufferShort && byID(big2.id)?.isBufferShort == true, "fixture: parked for space")
        #expect(prepared.status == .ready)
        #expect(ArchiveAngelDetailView.offersSkip(isActive: false, entry: parked), "the button stays")
        #expect(!ArchiveAngelDetailView.offersSkip(isActive: false, entry: prepared), "a ready row is decided in the review")
        #expect(ArchiveAngelDetailView.offersSkip(isActive: true, entry: prepared))

        // The skip, through the job, after it finished.
        #expect(job.skip(entryID: big1.id))
        await job.cleanupTask?.value
        #expect(byID(big1.id)?.status == .skipped && byID(big1.id)?.failure == nil)
        #expect(byID(big1.id)?.skipNote?.contains("waiting for buffer space") == true, "\(byID(big1.id)?.skipNote ?? "")")
        let onDisk = try ArchiveAngelPlanStore.load(batchDir: job.plan.batchDir)
        #expect(onDisk.entries.first { $0.id == big1.id }?.status == .skipped, "saved")
        #expect(onDisk.status == .ready && onDisk.readyCount == 1)
        await b.model.mediaLedger.waitForPendingWrites()
        let skips = b.model.mediaLedger.allEvents().filter { $0.event == .angelSkipped }
        #expect(skips.map(\.recordID) == [big1.id] && skips.first?.batchID == job.plan.batchID, "\(skips.map(\.filename))")
        #expect(!ArchiveAngelPlanStore.inFlightRecordIDs(bufferRoot: b.buffer).contains(big1.id), "free for the next batch")

        // Refused: already skipped; a ready row; a cleared batch.
        #expect(!job.skip(entryID: big1.id))
        #expect(!job.skip(entryID: small.id), "the job is over — decide it in the review")
        #expect(try ArchiveAngelPlanStore.load(batchDir: job.plan.batchDir).entries.first { $0.id == small.id }?.status == .ready)
        let cleared = await b.model.clearArchiveAngelBatch(onDisk, reason: "test")
        #expect(cleared.cleared)
        _ = await cleared.removal?.value
        #expect(!fm.fileExists(atPath: job.plan.batchDir))
        #expect(!job.skip(entryID: big2.id), "SENSOR: nothing is written for a batch that was cleared")
        #expect(!fm.fileExists(atPath: job.plan.batchDir), "…and nothing resurrected it")
        #expect(byID(big2.id)?.isBufferShort == true)
    }

    // MARK: - The plan writer's test fault reaches both Skip saves (Codex #347 P2)
    //
    // Each Skip saves the plan in a DETACHED task, which inherits no
    // task-locals: the job reads `ArchiveAngelPlanWriter.injectedFailure` on
    // the tree and hands the value in. A source pin cannot tell a capture
    // made before the detach from one made inside it (where it reads nil
    // and the save silently succeeds), so each path is driven for real: a
    // fault bound around the Skip must fail THAT save and be said in the log.

    @Test("Skip of a waiting row while the batch runs: a bound plan-writer fault fails the Skip's detached save, and the log says so")
    func skipWhileRunningHandsTheFaultToItsDetachedSave() async throws {
        let b = try bench("lifecycle_skip_fault"); defer { b.sb.cleanup() }
        let slow = try await clip("test_lc_sf_slow.mp4", in: b.sb.sources)
        try await slowFFmpeg(in: b.sb, slowMarker: "test_lc_sf_slow", seconds: 4).scoped {
            let recSlow = record(slow)
            let other = record(b.sb.sources.appendingPathComponent("test_lc_sf_big.mkv"), sizeBytes: 1_000_000_000_000_000)
            b.model.records = [recSlow, other]
            let job = ArchiveAngelJob(model: b.model, center: b.center, count: 2, makeLossless: false,
                                      bufferRoot: b.buffer, explicitRecordIDs: [recSlow.id, other.id])
            job.start()   // started UNBOUND: the loop's own saves are not faulted
            defer { job.cancel() }
            try await waitUntil("the slow row is being prepared") { job.preparingEntryID == recSlow.id }

            // Nobody is holding `other`: the non-live path, a detached save.
            let sink = InMemoryLogSink(name: "skip-fault-running")
            let fault = ArchiveAngelPlanWriter.InjectedFailure(batchNameContains: b.buffer.path, afterWrites: 0)
            let accepted = withAppLog(sink) {
                ArchiveAngelPlanWriter.$injectedFailure.withValue(fault) { job.skip(entryID: other.id) }
            }
            #expect(accepted, "fixture: the row was skippable")
            await job.cleanupTask?.value
            #expect(sink.contains("could not save the skip of test_lc_sf_big.mkv"),
                    "the Skip's detached save did not see the fault: \(sink.lines.suffix(6))")

            job.cancel()
            await job.task?.value
            await job.cleanupTask?.value
        }
    }

    @Test("Skip of a waiting row after the job finished: a bound plan-writer fault fails the Skip's detached save; the plan on disk is unchanged and the log says so")
    func skipAfterFinishHandsTheFaultToItsDetachedSave() async throws {
        let b = try bench("lifecycle_skip_fault_done"); defer { b.sb.cleanup() }
        let a = try await clip("test_lc_sfd_a.mp4", in: b.sb.sources)
        let big = record(b.sb.sources.appendingPathComponent("test_lc_sfd_big.mkv"), sizeBytes: 1_000_000_000_000_000)
        let small = record(a)
        b.model.records = [big, small]
        let job = ArchiveAngelJob(model: b.model, center: b.center, count: 2, makeLossless: false,
                                  bufferRoot: b.buffer, explicitRecordIDs: [big.id, small.id])
        job.start()
        await job.task?.value
        guard case .finished = job.state else { Issue.record("\(job.state) — \(job.plan.log.suffix(4))"); return }
        try #require(job.plan.entries.first { $0.id == big.id }?.isBufferShort == true, "fixture: parked for space")

        let sink = InMemoryLogSink(name: "skip-fault-finished")
        let fault = ArchiveAngelPlanWriter.InjectedFailure(batchNameContains: b.buffer.path, afterWrites: 0)
        let accepted = withAppLog(sink) {
            ArchiveAngelPlanWriter.$injectedFailure.withValue(fault) { job.skip(entryID: big.id) }
        }
        #expect(accepted, "fixture: the waiting row was skippable")
        await job.cleanupTask?.value
        #expect(sink.contains("could not save the skip of test_lc_sfd_big.mkv"),
                "the Skip's detached save did not see the fault: \(sink.lines.suffix(6))")
        let onDisk = try ArchiveAngelPlanStore.load(batchDir: job.plan.batchDir)
        #expect(onDisk.entries.first { $0.id == big.id }?.status != .skipped, "the faulted save wrote plan.json")
    }
}
