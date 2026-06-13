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

    @Test("serial path records entries with nil whisperSeconds and the no-transcript note")
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
            #expect(entry.note == "no transcript")
        }
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
