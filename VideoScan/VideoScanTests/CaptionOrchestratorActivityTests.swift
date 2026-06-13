import Foundation
import Testing
@testable import VideoScan

// MARK: - Caption Orchestrator — live pipeline activity tests
//
// Sibling to CaptionOrchestratorDossierTests.swift (and reuses its
// StubDossierRunner / StubAudioTranscriber, which are internal to the
// test target). Where that file verifies the dossier *writeback*,
// this one verifies the dashboard's activity feed:
//
//   - after a pipelined batch over N files, `recentActivity` holds
//     min(N, cap) entries, newest first, with both stage timings
//     populated, and `activeLanes` is empty (batch settled)
//   - the history cap holds at `recentActivityCap` for N > cap
//   - the serial (no-transcriber) path produces entries with
//     whisperSeconds == nil and the "no transcript" note
//   - stage display names derive from engine modelIDs, with a
//     pass-through fallback for future stages

// MARK: - Test helpers (private — only this file)

@MainActor
private func makeActivityRecord(fullPath: String) -> VideoRecord {
    let r = VideoRecord()
    r.filename = (fullPath as NSString).lastPathComponent
    r.fullPath = fullPath
    r.streamTypeRaw = StreamType.videoAndAudio.rawValue
    r.durationSeconds = 3.0
    r.lifecycleStage = .cataloged
    return r
}

@MainActor
private func makeReachableTarget(at path: String) -> CatalogScanTarget {
    let t = CatalogScanTarget(searchPath: path)
    t.isReachable = true
    return t
}

/// Create `count` zero-byte stand-in media files in tmp with a unique
/// `tag` so parallel test cases never collide. Returns (paths, records).
@MainActor
private func makeActivityFixtures(count: Int, tag: String) -> ([String], [VideoRecord]) {
    let tmp = NSTemporaryDirectory()
    var paths: [String] = []
    var recs: [VideoRecord] = []
    for i in 0..<count {
        let p = tmp + "vs-activity-\(tag)-\(i).mp4"
        FileManager.default.createFile(atPath: p, contents: Data("x".utf8))
        paths.append(p)
        recs.append(makeActivityRecord(fullPath: p))
    }
    return (paths, recs)
}

private func removeAll(_ paths: [String]) {
    for p in paths { try? FileManager.default.removeItem(atPath: p) }
}

// MARK: - Suite

@MainActor
@Suite("Caption Orchestrator — live pipeline activity")
struct CaptionOrchestratorActivityTests {

    // MARK: - Pipelined batch populates history, newest first

    @Test("pipelined batch fills recentActivity newest-first with both timings, lanes end empty")
    func pipelinedBatchPopulatesActivity() async {
        let model = VideoScanModel()
        let (paths, recs) = makeActivityFixtures(count: 3, tag: "pipe")
        defer { removeAll(paths) }

        model.records = recs
        model.scanTargets = [makeReachableTarget(at: NSTemporaryDirectory())]

        let stub = StubDossierRunner(modelID: "stub-d-act")
        let orch = CaptionOrchestrator(runnerFactory: { stub })
        // A small Whisper delay so the pipeline genuinely overlaps and
        // the recorded whisperSeconds are visibly non-zero.
        let transcriber = StubAudioTranscriber(
            modelID: "stub-w-act",
            transcriptText: "hello",
            delay: .milliseconds(10)
        )

        await orch.startCatalogWideDossier(model: model, transcriber: transcriber)

        guard case .finished(let captioned, _, let failed) = orch.currentStatus else {
            Issue.record("Expected .finished, got \(orch.currentStatus)")
            return
        }
        #expect(captioned == 3)
        #expect(failed == 0)

        // Batch settled: no lane may linger.
        #expect(orch.activeLanes.isEmpty)

        // History: one entry per file, newest first. Processing order
        // is whatever the candidate filter produced — derive expected
        // order from the stub's actual call sequence, reversed.
        let processedOrder = await stub.pathsCalled()
            .map { ($0 as NSString).lastPathComponent }
        #expect(orch.recentActivity.count == 3)
        #expect(orch.recentActivity.map(\.filename) == Array(processedOrder.reversed()))

        for entry in orch.recentActivity {
            #expect(entry.vlmSeconds != nil, "\(entry.filename) missing VLM timing")
            #expect(entry.whisperSeconds != nil, "\(entry.filename) missing Whisper timing")
            #expect(entry.note == nil, "\(entry.filename) unexpectedly noted: \(entry.note ?? "")")
        }
        // Newest-first also means non-increasing sync timestamps.
        for pair in zip(orch.recentActivity, orch.recentActivity.dropFirst()) {
            #expect(pair.0.syncedAt >= pair.1.syncedAt)
        }
    }

    // MARK: - History cap

    @Test("recentActivity caps at recentActivityCap for batches larger than the cap")
    func historyCapHolds() async {
        let model = VideoScanModel()
        let n = CaptionOrchestrator.recentActivityCap + 4   // 12 with cap 8
        let (paths, recs) = makeActivityFixtures(count: n, tag: "cap")
        defer { removeAll(paths) }

        model.records = recs
        model.scanTargets = [makeReachableTarget(at: NSTemporaryDirectory())]

        let stub = StubDossierRunner(modelID: "stub-d-cap")
        let orch = CaptionOrchestrator(runnerFactory: { stub })
        let transcriber = StubAudioTranscriber(modelID: "stub-w-cap")

        await orch.startCatalogWideDossier(model: model, transcriber: transcriber)

        guard case .finished(let captioned, _, _) = orch.currentStatus else {
            Issue.record("Expected .finished, got \(orch.currentStatus)")
            return
        }
        #expect(captioned == n)
        #expect(orch.activeLanes.isEmpty)
        #expect(orch.recentActivity.count == CaptionOrchestrator.recentActivityCap)

        // The surviving entries must be the LAST cap files processed,
        // newest first — the oldest completions fell off the end.
        let processedOrder = await stub.pathsCalled()
            .map { ($0 as NSString).lastPathComponent }
        let expected = Array(processedOrder.suffix(CaptionOrchestrator.recentActivityCap).reversed())
        #expect(orch.recentActivity.map(\.filename) == expected)
    }

    // MARK: - Serial path (no transcriber)

    @Test("serial path records entries with nil whisperSeconds and the no-transcriber note")
    func serialPathNoTranscript() async {
        let model = VideoScanModel()
        let (paths, recs) = makeActivityFixtures(count: 2, tag: "serial")
        defer { removeAll(paths) }

        model.records = recs
        model.scanTargets = [makeReachableTarget(at: NSTemporaryDirectory())]

        let stub = StubDossierRunner(modelID: "stub-d-serial")
        let orch = CaptionOrchestrator(runnerFactory: { stub })

        // Drive the serial batch directly (see the visibility note on
        // runDossierBatchSerial) — the public entry's nil-transcriber
        // fallback is environment-dependent.
        await orch.runDossierBatchSerial(
            runner: stub,
            transcriber: nil,
            candidates: recs,
            framesPerFile: 3,
            force: false,
            model: model,
            stackID: "stub-d-serial",
            started: CFAbsoluteTimeGetCurrent()
        )

        guard case .finished(let captioned, _, let failed) = orch.currentStatus else {
            Issue.record("Expected .finished, got \(orch.currentStatus)")
            return
        }
        #expect(captioned == 2)
        #expect(failed == 0)
        #expect(orch.activeLanes.isEmpty)
        #expect(orch.recentActivity.count == 2)
        for entry in orch.recentActivity {
            #expect(entry.vlmSeconds != nil)
            #expect(entry.whisperSeconds == nil)
            #expect(entry.note == "no transcriber",
                    "Serial path with no transcriber must tag as 'no transcriber' so we can distinguish that case from 'no audio' (file has no audio stream) and 'transcript failed' (whisper threw).")
        }
    }

    // MARK: - User-initiated skip cancels in-flight Whisper

    @Test("skipLane during a slow Whisper banks VLM-only with the 'user skipped' note")
    func skipLaneCancelsInFlightWhisper() async {
        let model = VideoScanModel()
        let (paths, recs) = makeActivityFixtures(count: 1, tag: "skip")
        defer { removeAll(paths) }

        model.records = recs
        model.scanTargets = [makeReachableTarget(at: NSTemporaryDirectory())]

        // modelIDs MUST contain the family hint so stageDisplayName
        // maps them to "MLXVLM" / "Whisper" — that's what the dashboard
        // (and this test's polling loop) looks for. Pre-existing
        // activity tests don't read stageName so they got away with
        // arbitrary stub names; we can't.
        let stub = StubDossierRunner(modelID: "stub-vlm-skip")
        let orch = CaptionOrchestrator(runnerFactory: { stub })
        // 30s synthetic Whisper. We never let it complete — the test
        // calls skipLane and asserts the CancellationError path bails
        // immediately. A short stub delay (e.g. 200ms) would be racy:
        // the test's polling loop could miss the Whisper window.
        let transcriber = StubAudioTranscriber(
            modelID: "stub-whisper-skip",
            delay: .seconds(30)
        )

        // Run the batch off-test-task so we can observe activeLanes
        // and call skipLane while it's mid-flight.
        let batch = Task { await orch.startCatalogWideDossier(model: model, transcriber: transcriber) }

        // Spin until the Whisper lane shows up. Bounded retry: 5s at
        // 25ms intervals = 200 attempts. If we never see Whisper the
        // pipeline is broken; failing the test with a clear message is
        // better than hanging indefinitely.
        var whisperLaneID: UUID?
        for _ in 0..<200 {
            try? await Task.sleep(for: .milliseconds(25))
            if let lane = orch.activeLanes.first(where: { $0.stageName == "Whisper" }) {
                whisperLaneID = lane.id
                break
            }
        }
        guard let laneID = whisperLaneID else {
            Issue.record("Whisper lane never appeared — pipeline never reached transcription stage")
            batch.cancel()
            return
        }

        orch.skipLane(laneID)
        await batch.value

        guard case .finished(let captioned, _, _) = orch.currentStatus else {
            Issue.record("Expected .finished, got \(orch.currentStatus)")
            return
        }
        // The file IS captioned (VLM result banked); we just dropped
        // the transcript. liveCaptioned counts every file that landed
        // a dossier — VLM-only is still a dossier.
        #expect(captioned == 1)
        #expect(orch.activeLanes.isEmpty, "lane must end after skip")
        #expect(orch.recentActivity.count == 1)
        let entry = orch.recentActivity[0]
        #expect(entry.vlmSeconds != nil, "VLM should have completed and recorded its timing")
        #expect(entry.whisperSeconds == nil, "Whisper was skipped, so it produced no timing")
        #expect(entry.note == "user skipped",
                "skip must tag the completion 'user skipped' so the dashboard distinguishes it from a Whisper failure")
    }

    // MARK: - Whisper deadline auto-kills stuck transcription

    /// Stub-level test: confirms StubAudioTranscriber throws
    /// `.deadlineExceeded` when `delay > deadlineSeconds`. The
    /// orchestrator's catch arm against the same typed error is
    /// verified at compile time; running a 60s+ end-to-end deadline
    /// here would dwarf the rest of the suite.
    @Test("Whisper deadline: delay > deadline → .deadlineExceeded")
    func whisperDeadlineTrips() async {
        let (paths, _) = makeActivityFixtures(count: 1, tag: "deadline")
        defer { removeAll(paths) }

        let transcriber = StubAudioTranscriber(
            modelID: "stub-whisper-deadline",
            delay: .seconds(5)
        )
        do {
            _ = try await transcriber.transcribe(videoPath: paths[0], deadlineSeconds: 0.1)
            Issue.record("Expected deadlineExceeded, got success")
        } catch AudioTranscriberError.deadlineExceeded(let secs) {
            #expect(secs == 0.1, "Stub must echo the deadline it tripped on")
        } catch {
            Issue.record("Expected deadlineExceeded, got \(error)")
        }
    }

    // MARK: - Cancellation actually kills a real subprocess
    //
    // The fix for "right-click Skip didn't kill Python whisper" was to
    // wrap AudioTranscriber's subprocess in withTaskCancellationHandler.
    // The prior implementation used `Task { ... }` with a Task.isCancelled
    // poll, which silently never trips because Task.init creates a
    // sibling task that does NOT inherit cancellation (Apple docs).
    //
    // This test exercises the EXACT primitive that fix relies on — a
    // real Process, the withTaskCancellationHandler pattern, the
    // onCancel kill(pid, SIGTERM) — against /bin/sleep so it has zero
    // dependency on Python or Whisper. If this test passes, the same
    // pattern wired into PythonSubprocessAudioTranscriber will also
    // kill the real whisper subprocess on skipLane.
    //
    // Rick 2026-06-13: prior "skip works" tests only exercised
    // StubAudioTranscriber (whose Task.sleep cooperates with
    // cancellation natively, so they couldn't have caught the bug).

    @Test("Real Process: cancelling parent task SIGTERMs child within a few seconds")
    func realSubprocessKilledOnCancellation() async {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sleep")
        proc.arguments = ["60"]  // long enough that natural exit can't mask a fix failure
        do {
            try proc.run()
        } catch {
            Issue.record("Failed to launch /bin/sleep: \(error)")
            return
        }
        let pid = proc.processIdentifier
        let started = Date()

        // Inner task mirrors AudioTranscriber.transcribe's structure:
        // operation awaits the subprocess; onCancel kills the PID.
        // proc is non-Sendable so we use Task.detached for the wait
        // (the detached task is allowed to capture proc by reference;
        // onCancel only captures pid, which is Int32-Sendable).
        let task: Task<Void, Never> = Task {
            await withTaskCancellationHandler {
                await Task.detached {
                    proc.waitUntilExit()
                }.value
            } onCancel: {
                kill(pid, SIGTERM)
                Task.detached {
                    try? await Task.sleep(for: .seconds(2))
                    kill(pid, SIGKILL)  // escalate; no-op if already reaped
                }
            }
        }

        // Give /bin/sleep time to actually be running.
        try? await Task.sleep(for: .milliseconds(200))
        #expect(proc.isRunning, "Sanity: /bin/sleep should be running before we cancel")

        task.cancel()
        await task.value

        let elapsed = Date().timeIntervalSince(started)
        #expect(!proc.isRunning,
                "Subprocess must be dead after parent task cancellation; pid=\(pid)")
        // Generous wall-clock budget: 200ms warmup + ~immediate SIGTERM
        // delivery + Python-style cleanup. /bin/sleep itself exits on
        // SIGTERM in milliseconds. If we ever blow past 5s, the
        // cancellation handler is no longer working.
        #expect(elapsed < 5.0,
                "Cancellation→kill should complete within 5s; took \(elapsed)s")
    }

    // MARK: - DRM → suspectedJunk flagging
    //
    // When the orchestrator probes a file via AVAsset.hasProtectedContent
    // and it returns true, it routes through flagDRMSuspectJunk which:
    //   - sets drmProtected = true (so the candidate filter excludes
    //     on the NEXT run without paying the probe cost)
    //   - bumps mediaDisposition to .suspectedJunk IF currently
    //     .unreviewed (so Rick sees it in his triage flow)
    //   - records "DRM-protected (no decryption key)" in junkReasons
    //
    // Preserves any stronger pre-existing disposition — the user's
    // judgment wins. These are pure-function tests; the AVAsset probe
    // itself can't be unit-tested without a real DRM fixture file.

    @Test("flagDRMSuspectJunk: unreviewed → suspectedJunk")
    func flagDRMOnUnreviewed() {
        let r = VideoRecord()
        r.fullPath = "/Volumes/Lacie/protected.m4v"
        r.mediaDisposition = .unreviewed
        CaptionOrchestrator.flagDRMSuspectJunk(r)
        #expect(r.drmProtected == true)
        #expect(r.mediaDisposition == .suspectedJunk)
        #expect(r.junkReasons == [CaptionOrchestrator.drmSuspectJunkReason])
    }

    @Test("flagDRMSuspectJunk: confirmedJunk stays confirmedJunk (don't downgrade)")
    func flagDRMOnConfirmedJunk() {
        let r = VideoRecord()
        r.mediaDisposition = .confirmedJunk
        CaptionOrchestrator.flagDRMSuspectJunk(r)
        #expect(r.drmProtected == true)
        #expect(r.mediaDisposition == .confirmedJunk,
                "User already confirmed junk — don't downgrade to suspected")
        #expect(r.junkReasons.contains(CaptionOrchestrator.drmSuspectJunkReason))
    }

    @Test("flagDRMSuspectJunk: important stays important (don't override user)")
    func flagDRMOnImportant() {
        let r = VideoRecord()
        r.mediaDisposition = .important
        CaptionOrchestrator.flagDRMSuspectJunk(r)
        #expect(r.drmProtected == true)
        #expect(r.mediaDisposition == .important,
                "User flagged this important — DRM detection must not override")
        #expect(r.junkReasons.contains(CaptionOrchestrator.drmSuspectJunkReason),
                "Reason still logs even when disposition isn't bumped — diagnostic trail")
    }

    @Test("flagDRMSuspectJunk: idempotent — re-flagging doesn't multiply junkReasons")
    func flagDRMIdempotent() {
        let r = VideoRecord()
        r.mediaDisposition = .unreviewed
        CaptionOrchestrator.flagDRMSuspectJunk(r)
        CaptionOrchestrator.flagDRMSuspectJunk(r)
        CaptionOrchestrator.flagDRMSuspectJunk(r)
        #expect(r.junkReasons.count == 1,
                "junkReasons must dedupe — repeated runs shouldn't multiply the entry")
        #expect(r.mediaDisposition == .suspectedJunk)
    }

    // MARK: - Missing-on-disk auto-purge

    @Test("flagMissingOnDisk: sets purgedAt + records reason; idempotent")
    func flagMissingOnDiskMarks() {
        let r = VideoRecord()
        r.fullPath = "/Volumes/Lacie/m29_combine/missing.mov"
        CaptionOrchestrator.flagMissingOnDisk(r)
        #expect(r.purgedAt != nil, "purgedAt must be set so the candidate filter and coverage exclude it")
        #expect(r.junkReasons == [CaptionOrchestrator.missingOnDiskReason])

        // Re-flagging the same record doesn't duplicate the reason or
        // overwrite the original purge timestamp.
        let originalDate = r.purgedAt!
        CaptionOrchestrator.flagMissingOnDisk(r)
        #expect(r.junkReasons.count == 1)
        #expect(r.purgedAt == originalDate, "re-flag must preserve the original purge timestamp")
    }

    // MARK: - Per-volume start + pause/resume (Phase 1)

    @Test("startAnalyzing(volumePrefix:) processes only files under that prefix")
    func startAnalyzingFiltersByPrefix() async {
        let model = VideoScanModel()
        // Two volumes worth of fixtures. The orchestrator should only
        // process the records whose fullPath has the target prefix.
        let tmp = NSTemporaryDirectory()
        let pathA = tmp + "vs-vol-a-clip.mp4"
        let pathB = tmp + "vs-vol-b-clip.mp4"
        FileManager.default.createFile(atPath: pathA, contents: Data("x".utf8))
        FileManager.default.createFile(atPath: pathB, contents: Data("x".utf8))
        defer {
            try? FileManager.default.removeItem(atPath: pathA)
            try? FileManager.default.removeItem(atPath: pathB)
        }

        let recA = makeActivityRecord(fullPath: pathA)
        let recB = makeActivityRecord(fullPath: pathB)
        model.records = [recA, recB]
        // Both volumes reachable — the prefix filter alone must keep
        // recB out of the candidate list.
        model.scanTargets = [
            makeReachableTarget(at: tmp + "vs-vol-a-"),
            makeReachableTarget(at: tmp + "vs-vol-b-")
        ]

        let stub = StubDossierRunner(modelID: "stub-vlm-volA")
        let orch = CaptionOrchestrator(runnerFactory: { stub })
        let transcriber = StubAudioTranscriber(modelID: "stub-whisper-volA")

        await orch.startAnalyzing(
            volumePrefix: tmp + "vs-vol-a-",
            model: model,
            transcriber: transcriber
        )

        let processed = await stub.pathsCalled()
        #expect(processed == [pathA],
                "startAnalyzing must process only paths under the given prefix")
        #expect(orch.currentVolumePrefix == nil,
                "currentVolumePrefix should clear after the batch finishes")
    }

    @Test("pause halts new file dispatch; resume continues the batch")
    func pauseResumeHoldsLoop() async {
        let model = VideoScanModel()
        let (paths, recs) = makeActivityFixtures(count: 3, tag: "pause")
        defer { removeAll(paths) }

        model.records = recs
        model.scanTargets = [makeReachableTarget(at: NSTemporaryDirectory())]

        let stub = StubDossierRunner(modelID: "stub-vlm-pause")
        let orch = CaptionOrchestrator(runnerFactory: { stub })
        // Small Whisper delay so the loop has visible per-file work.
        let transcriber = StubAudioTranscriber(
            modelID: "stub-whisper-pause",
            delay: .milliseconds(50)
        )

        // Pause BEFORE starting — the loop's pause-gate will trip on
        // the very first iteration. Then after 200ms we resume; the
        // loop should drain all three files.
        orch.pause()
        let batch = Task { await orch.startCatalogWideDossier(model: model, transcriber: transcriber) }

        // Confirm pause held: after 250ms no files should have been
        // processed (stub's calledPaths still empty).
        try? await Task.sleep(for: .milliseconds(250))
        let stalledCount = await stub.pathsCalled().count
        #expect(stalledCount == 0,
                "pause must prevent any file dispatch; saw \(stalledCount) calls instead")

        orch.resume()
        await batch.value
        let finalCount = await stub.pathsCalled().count
        #expect(finalCount == 3, "after resume, all 3 files should have processed")
        #expect(orch.paused == false, "paused state should remain cleared after batch end")
    }

    // MARK: - Stage names are data-driven

    @Test("stage display names derive from modelIDs and pass unknown stages through")
    func stageNamesDataDriven() {
        #expect(CaptionOrchestrator.stageDisplayName(forModelID: "qwen2.5-vl-3b-4bit") == "MLXVLM")
        #expect(CaptionOrchestrator.stageDisplayName(forModelID: "python-vlm-qwen25vl-3b-4bit") == "MLXVLM")
        #expect(CaptionOrchestrator.stageDisplayName(forModelID: "whisper-medium-mlx-q4") == "Whisper")
        #expect(CaptionOrchestrator.stageDisplayName(forModelID: "python-whisper-medium-mlx-q4") == "Whisper")
        // Future stage with no special-case: renders its own ID rather
        // than being hidden — the dashboard shows whatever reports in.
        #expect(CaptionOrchestrator.stageDisplayName(forModelID: "FancyAlg2-v1") == "FancyAlg2-v1")
    }
}
