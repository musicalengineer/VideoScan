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
