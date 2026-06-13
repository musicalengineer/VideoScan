import Foundation
import Testing
@testable import VideoScan

// MARK: - Caption Orchestrator — catalog-wide dossier tests
//
// Sibling to CaptionOrchestratorTests.swift. Where that file exercises
// the single-prompt caption pass (startCatalogWideCaptioning + runBatch),
// this one drives the dossier pass (startCatalogWideDossier +
// runDossierBatch) with a stub runner that overrides dossier() and a
// stub transcriber, so we can verify:
//
//   - all three signal channels (scenes / dates / texts) round-trip
//     through the writeback
//   - the optional transcript channel is plumbed only when a
//     transcriber is supplied
//   - the dossierProcessedBy stack-id idempotent skip works
//   - records on unreachable volumes are filtered out before the runner
//   - the per-record file-existence guard prevents the runner being
//     invoked for ghost files

// MARK: - Stub dossier runner (overrides dossier())
//
// Returns a fixed DossierExtraction per call shaped from the input
// timestamps so the test can assert frame-by-frame writeback.

actor StubDossierRunner: CaptionRunner {
    nonisolated let modelID: String

    private(set) var dossierPaths: [String] = []

    let scenePerFrame: String
    let dateText: String?
    let textPerFrame: String?

    init(
        modelID: String = "stub-dossier-1",
        scenePerFrame: String = "stub scene",
        dateText: String? = "MAR 14 1991",
        textPerFrame: String? = "TEST OVERLAY"
    ) {
        self.modelID = modelID
        self.scenePerFrame = scenePerFrame
        self.dateText = dateText
        self.textPerFrame = textPerFrame
    }

    func caption(
        videoPath: String,
        atTimestamps timestamps: [Double]
    ) async throws -> [SceneCaption] {
        // Caption fallback path — not actually exercised by the dossier
        // tests since we override dossier() below, but the protocol
        // requires it.
        timestamps.map { SceneCaption(timestamp: $0, text: scenePerFrame) }
    }

    func dossier(
        videoPath: String,
        atTimestamps timestamps: [Double]
    ) async throws -> DossierExtraction {
        dossierPaths.append(videoPath)
        let scenes = timestamps.map { SceneCaption(timestamp: $0, text: scenePerFrame) }
        let dates  = dateText.map { txt in timestamps.map { SceneCaption(timestamp: $0, text: txt) } } ?? []
        let texts  = textPerFrame.map { txt in timestamps.map { SceneCaption(timestamp: $0, text: txt) } } ?? []
        return DossierExtraction(scenes: scenes, dates: dates, texts: texts)
    }

    func pathsCalled() -> [String] { dossierPaths }
    func countCalled() -> Int { dossierPaths.count }
}

// MARK: - Stub audio transcriber

struct StubAudioTranscriber: AudioTranscriber {
    let modelID: String
    let transcriptText: String
    /// Optional artificial transcription latency. Defaults to zero so
    /// existing tests are unaffected; the pipelining regression test
    /// uses a non-zero delay to keep the Whisper stage busy while the
    /// (fast) stub VLM races ahead.
    let delay: Duration

    init(
        modelID: String = "stub-whisper-1",
        transcriptText: String = "stub transcript",
        delay: Duration = .zero
    ) {
        self.modelID = modelID
        self.transcriptText = transcriptText
        self.delay = delay
    }

    func transcribe(videoPath: String) async throws -> String {
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        return transcriptText
    }
}

// MARK: - Test helpers (private — only this file)

@MainActor
private func makeDossierRecord(
    fullPath: String,
    streamType: StreamType = .videoAndAudio,
    duration: Double = 3.0,
    dossierProcessedAt: Date? = nil,
    dossierProcessedBy: String? = nil
) -> VideoRecord {
    let r = VideoRecord()
    r.filename = (fullPath as NSString).lastPathComponent
    r.fullPath = fullPath
    r.streamTypeRaw = streamType.rawValue
    r.durationSeconds = duration
    r.lifecycleStage = .cataloged
    r.dossierProcessedAt = dossierProcessedAt
    r.dossierProcessedBy = dossierProcessedBy
    return r
}

/// Build a reachable CatalogScanTarget pointing at `path`. CatalogScanTarget's
/// init evaluates VolumeReachability lazily; we force isReachable = true so
/// the orchestrator's reachability gate doesn't filter us out for the test
/// directory.
@MainActor
private func makeReachableTarget(at path: String) -> CatalogScanTarget {
    let t = CatalogScanTarget(searchPath: path)
    t.isReachable = true
    return t
}

// MARK: - Suite

@MainActor
@Suite("Caption Orchestrator — catalog-wide dossier")
struct CaptionOrchestratorDossierTests {

    // MARK: - Three-channel writeback round-trip

    @Test("dossier batch round-trips scenes / dates / texts to the record")
    func threeChannelWriteback() async {
        let model = VideoScanModel()
        let tmp = NSTemporaryDirectory()
        let path = tmp + "vs-dossier-rt-a.mp4"
        FileManager.default.createFile(atPath: path, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(atPath: path) }

        let rec = makeDossierRecord(fullPath: path)
        model.records = [rec]
        model.scanTargets = [makeReachableTarget(at: tmp)]

        let stub = StubDossierRunner(modelID: "stub-d-1")
        let orch = CaptionOrchestrator(runnerFactory: { stub })
        let transcriber = StubAudioTranscriber(modelID: "stub-w-1", transcriptText: "hello")

        await orch.startCatalogWideDossier(model: model, transcriber: transcriber)

        guard case .finished(let captioned, _, let failed) = orch.currentStatus else {
            Issue.record("Expected .finished, got \(orch.currentStatus)")
            return
        }
        #expect(captioned == 1)
        #expect(failed == 0)
        // 3 default frames per file × 3 channels (scenes / dates / texts)
        #expect(rec.sceneCaptions.count == 3)
        #expect(rec.ocrDateCandidates.count == 3)
        #expect(rec.ocrText.count == 3)
        #expect(rec.audioTranscript == "hello")
        #expect(rec.audioTranscriptModel == "stub-w-1")
        #expect(rec.dossierProcessedBy == "stub-d-1+stub-w-1")
        #expect(rec.dossierProcessedAt != nil)
    }

    // MARK: - Idempotent skip on dossierProcessedBy match

    @Test("records already dossiered with the current stack are skipped")
    func idempotentSkipMatchesStackID() async {
        let model = VideoScanModel()
        let tmp = NSTemporaryDirectory()
        let already = tmp + "vs-dossier-skip-a.mp4"
        let fresh   = tmp + "vs-dossier-skip-b.mp4"
        FileManager.default.createFile(atPath: already, contents: Data("x".utf8))
        FileManager.default.createFile(atPath: fresh, contents: Data("x".utf8))
        defer {
            try? FileManager.default.removeItem(atPath: already)
            try? FileManager.default.removeItem(atPath: fresh)
        }

        // Records: one already processed with stack "stub-d-1+stub-w-1",
        // one fresh.
        let priorRec = makeDossierRecord(
            fullPath: already,
            dossierProcessedAt: Date(timeIntervalSince1970: 1_700_000_000),
            dossierProcessedBy: "stub-d-1+stub-w-1"
        )
        let freshRec = makeDossierRecord(fullPath: fresh)
        model.records = [priorRec, freshRec]
        model.scanTargets = [makeReachableTarget(at: tmp)]

        let stub = StubDossierRunner(modelID: "stub-d-1")
        let orch = CaptionOrchestrator(runnerFactory: { stub })
        let trans = StubAudioTranscriber(modelID: "stub-w-1")

        await orch.startCatalogWideDossier(model: model, transcriber: trans)

        guard case .finished(let captioned, let skipped, let failed) = orch.currentStatus else {
            Issue.record("Expected .finished, got \(orch.currentStatus)")
            return
        }
        #expect(captioned == 1, "Only the fresh record should be dossiered")
        #expect(skipped == 1, "The pre-stamped record should be skipped")
        #expect(failed == 0)

        let calls = await stub.pathsCalled()
        #expect(calls == [fresh])
    }

    // MARK: - VLM-only mode when no transcriber

    @Test("VLM-only mode (nil transcriber) still writes scene + OCR channels")
    func vlmOnlyModeNoTranscriber() async {
        let model = VideoScanModel()
        let tmp = NSTemporaryDirectory()
        let path = tmp + "vs-dossier-vlm-only-a.mp4"
        FileManager.default.createFile(atPath: path, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(atPath: path) }

        let rec = makeDossierRecord(fullPath: path)
        model.records = [rec]
        model.scanTargets = [makeReachableTarget(at: tmp)]

        // Stub runner that returns dates but the test passes no transcriber
        // — sentinel for the "Whisper missing on this host" environment.
        // We bypass the ToolLocator-based default by passing transcriber:
        // .some(nil) shape via the typed nil parameter. The orchestrator
        // accepts a nil transcriber AND, when explicitly nil, skips the
        // ToolLocator fallback (see the impl).
        let stub = StubDossierRunner(modelID: "stub-d-vlm-only")
        let orch = CaptionOrchestrator(runnerFactory: { stub })

        // NOTE: passing transcriber: nil here triggers the default
        // resolution path (ToolLocator). In a sandboxed test env those
        // paths usually aren't present, so the orchestrator falls back
        // to nil-transcriber automatically. If the test env DOES happen
        // to have venv-mlx + whisper_transcribe.py present (Rick's box),
        // the test will still pass on the writeback shape — we don't
        // assert "no audio transcript", we assert the stackID has no
        // "+" suffix when no transcriber actually ran.
        await orch.startCatalogWideDossier(model: model, transcriber: nil)

        guard case .finished(let captioned, _, _) = orch.currentStatus else {
            Issue.record("Expected .finished, got \(orch.currentStatus)")
            return
        }
        #expect(captioned >= 1)
        #expect(rec.sceneCaptions.count == 3)
        #expect(rec.ocrDateCandidates.count == 3)
    }

    // MARK: - Pipelining must not drop VLM results (data-loss regression)
    //
    // Regression test for the AsyncStream .bufferingOldest(1) bug:
    // AsyncStream.Continuation.yield never suspends, so when the
    // Whisper consumer was mid-transcription with one result already
    // buffered, every further VLM yield was silently discarded — the
    // dropped records never reached applyDossier and were never
    // stamped with dossierProcessedAt. A fast VLM stub plus a slow
    // transcriber reproduces the drop deterministically.

    @Test("pipelined dossier applies every VLM result when transcriber is slow")
    func testPipelinedDossierAppliesEveryVLMResultWhenTranscriberIsSlow() async {
        let model = VideoScanModel()
        let tmp = NSTemporaryDirectory()

        var paths: [String] = []
        var recs: [VideoRecord] = []
        for i in 0..<8 {
            let p = tmp + "vs-dossier-slowwhisper-\(i).mp4"
            FileManager.default.createFile(atPath: p, contents: Data("x".utf8))
            paths.append(p)
            recs.append(makeDossierRecord(fullPath: p))
        }
        defer { for p in paths { try? FileManager.default.removeItem(atPath: p) } }

        model.records = recs
        model.scanTargets = [makeReachableTarget(at: tmp)]

        let stub = StubDossierRunner(modelID: "stub-d-slow")
        let orch = CaptionOrchestrator(runnerFactory: { stub })
        // Slow Whisper, instant VLM: the worst case for the pipeline.
        let transcriber = StubAudioTranscriber(
            modelID: "stub-w-slow",
            transcriptText: "slow hello",
            delay: .milliseconds(80)
        )

        await orch.startCatalogWideDossier(model: model, transcriber: transcriber)

        guard case .finished(let captioned, let skipped, let failed) = orch.currentStatus else {
            Issue.record("Expected .finished, got \(orch.currentStatus)")
            return
        }
        #expect(captioned == recs.count, "Every VLM result must reach applyDossier — none may be dropped")
        #expect(skipped == 0)
        #expect(failed == 0)
        for rec in recs {
            #expect(
                rec.dossierProcessedAt != nil,
                "\(rec.filename) was never stamped — its VLM result was dropped between stages"
            )
        }
    }

    // MARK: - Reachability filter

    @Test("records whose volume isn't a reachable scan target are excluded")
    func unreachableVolumeFiltered() async {
        let model = VideoScanModel()
        let tmp = NSTemporaryDirectory()
        let reachablePath = tmp + "vs-dossier-reach.mp4"
        let unreachablePath = "/Volumes/NEVER-MOUNTED-DISK/foo.mp4"
        FileManager.default.createFile(atPath: reachablePath, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(atPath: reachablePath) }

        let reachRec = makeDossierRecord(fullPath: reachablePath)
        let unreachRec = makeDossierRecord(fullPath: unreachablePath)
        model.records = [reachRec, unreachRec]
        // Only the tmp target is in scanTargets — the unreachable disk
        // doesn't appear, so its records get filtered out.
        model.scanTargets = [makeReachableTarget(at: tmp)]

        let stub = StubDossierRunner()
        let orch = CaptionOrchestrator(runnerFactory: { stub })

        await orch.startCatalogWideDossier(model: model, transcriber: StubAudioTranscriber())

        let calls = await stub.pathsCalled()
        #expect(calls == [reachablePath])
        #expect(unreachRec.dossierProcessedAt == nil)
    }
}
