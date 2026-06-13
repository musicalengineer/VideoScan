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
//
// Reference type so call-tracking and per-path failure injection
// survive across the orchestrator's await boundaries. The transcriber
// is passed into the pipeline as `AudioTranscriber` (protocol-existential),
// so each caller sees the same underlying calledPaths bucket.

final class StubAudioTranscriber: AudioTranscriber, @unchecked Sendable {
    let modelID: String
    let transcriptText: String
    /// Optional artificial transcription latency. Defaults to zero so
    /// existing tests are unaffected; the pipelining regression test
    /// uses a non-zero delay to keep the Whisper stage busy while the
    /// (fast) stub VLM races ahead.
    let delay: Duration
    /// Paths the orchestrator asked us to transcribe. Used by the
    /// video-only bypass regression test to assert that no Whisper
    /// call was ever dispatched for a video-only record.
    private let lock = NSLock()
    private var _calledPaths: [String] = []
    /// If non-nil, throw the given error from `transcribe` whenever
    /// the requested videoPath matches this string. Lets the
    /// "whisper-failed records as transcript failed" regression test
    /// inject a failure on a single record while keeping others happy.
    let failOnPath: String?
    let failError: Error

    init(
        modelID: String = "stub-whisper-1",
        transcriptText: String = "stub transcript",
        delay: Duration = .zero,
        failOnPath: String? = nil,
        failError: Error = NSError(domain: "stub", code: 1)
    ) {
        self.modelID = modelID
        self.transcriptText = transcriptText
        self.delay = delay
        self.failOnPath = failOnPath
        self.failError = failError
    }

    var calledPaths: [String] {
        lock.withLock { _calledPaths }
    }

    func transcribe(videoPath: String, deadlineSeconds: Double?) async throws -> String {
        lock.withLock { _calledPaths.append(videoPath) }
        // Honor the deadline so tests can exercise the timeout path
        // without a real subprocess: if `delay` would exceed the
        // deadline, we throw `.deadlineExceeded` after sleeping for
        // the deadline window. Production semantics are identical
        // (subprocess gets SIGTERMed at the deadline); the stub
        // skips the actual signal mechanics.
        if let dl = deadlineSeconds, delay > .seconds(dl) {
            try? await Task.sleep(for: .seconds(dl))
            throw AudioTranscriberError.deadlineExceeded(seconds: dl)
        }
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        if let failOn = failOnPath, failOn == videoPath {
            throw failError
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

    // MARK: - Skip on dossierProcessedAt alone (Bug 1 regression)
    //
    // The previous skip predicate also matched on dossierProcessedBy ==
    // currentStackID. That bit Rick hard: the external worker fleet and
    // the in-app PythonSubprocessAudioTranscriber stamp different
    // stackIDs ("...whisper-medium-mlx-q4" vs "...python-whisper-..."),
    // so thousands of fleet-dossiered records re-ran every launch —
    // and the dashboard "Analyzed" count never moved because the
    // re-runs simply re-stamped what was already there. New contract:
    // a non-nil dossierProcessedAt is enough to skip unless force.

    @Test("records pre-stamped with a DIFFERENT stackID are still skipped")
    func testPrestampedDifferentStackIDIsSkipped() async {
        let model = VideoScanModel()
        let tmp = NSTemporaryDirectory()

        var paths: [String] = []
        var recs: [VideoRecord] = []
        let n = 4
        for i in 0..<n {
            let p = tmp + "vs-dossier-diffstack-\(i).mp4"
            FileManager.default.createFile(atPath: p, contents: Data("x".utf8))
            paths.append(p)
            recs.append(makeDossierRecord(
                fullPath: p,
                dossierProcessedAt: Date(timeIntervalSince1970: 1_700_000_000),
                dossierProcessedBy: "different-stack-id"
            ))
        }
        defer { for p in paths { try? FileManager.default.removeItem(atPath: p) } }

        model.records = recs
        model.scanTargets = [makeReachableTarget(at: tmp)]

        let stub = StubDossierRunner(modelID: "stub-d-skip")
        let orch = CaptionOrchestrator(runnerFactory: { stub })
        let transcriber = StubAudioTranscriber(modelID: "stub-w-skip")

        await orch.startCatalogWideDossier(model: model, transcriber: transcriber)

        guard case .finished(let captioned, let skipped, let failed) = orch.currentStatus else {
            Issue.record("Expected .finished, got \(orch.currentStatus)")
            return
        }
        #expect(captioned == 0, "Pre-stamped records must not re-run regardless of stackID")
        #expect(skipped == n)
        #expect(failed == 0)

        let dossierCalls = await stub.pathsCalled()
        #expect(dossierCalls.isEmpty, "Dossier runner must not be called for any pre-stamped record")
        #expect(transcriber.calledPaths.isEmpty, "Whisper must not be called for any pre-stamped record")
    }

    @Test("force=true re-runs even on pre-stamped records")
    func testForceRedossiersEvenWhenStamped() async {
        let model = VideoScanModel()
        let tmp = NSTemporaryDirectory()

        var paths: [String] = []
        var recs: [VideoRecord] = []
        let n = 3
        for i in 0..<n {
            let p = tmp + "vs-dossier-force-\(i).mp4"
            FileManager.default.createFile(atPath: p, contents: Data("x".utf8))
            paths.append(p)
            recs.append(makeDossierRecord(
                fullPath: p,
                dossierProcessedAt: Date(timeIntervalSince1970: 1_700_000_000),
                dossierProcessedBy: "some-old-stack"
            ))
        }
        defer { for p in paths { try? FileManager.default.removeItem(atPath: p) } }

        model.records = recs
        model.scanTargets = [makeReachableTarget(at: tmp)]

        let stub = StubDossierRunner(modelID: "stub-d-force")
        let orch = CaptionOrchestrator(runnerFactory: { stub })
        let transcriber = StubAudioTranscriber(modelID: "stub-w-force")

        await orch.startCatalogWideDossier(model: model, transcriber: transcriber, force: true)

        let calls = await stub.countCalled()
        #expect(calls == n, "force=true must redo every pre-stamped record")
    }

    // MARK: - Whisper bypass for video-only files (Bug 2 regression)
    //
    // Rick observed "Whisper transcribing audio…" lanes on files he
    // knows have no audio. VideoRecord.streamType already tells us
    // whether the file has audio (.videoOnly == no audio). After VLM
    // completes the pipeline must apply the dossier inline VLM-only
    // for a video-only file and NOT dispatch Whisper. The completion
    // note must distinguish "no audio" (by design) from "no
    // transcriber" / "transcript failed".

    @Test("video-only file bypasses Whisper but still gets a VLM-only dossier")
    func testVideoOnlyFileBypassesWhisper() async {
        let model = VideoScanModel()
        let tmp = NSTemporaryDirectory()

        let videoOnlyPath = tmp + "vs-dossier-videoonly.mxf"
        let bothPath = tmp + "vs-dossier-both.mp4"
        FileManager.default.createFile(atPath: videoOnlyPath, contents: Data("x".utf8))
        FileManager.default.createFile(atPath: bothPath, contents: Data("x".utf8))
        defer {
            try? FileManager.default.removeItem(atPath: videoOnlyPath)
            try? FileManager.default.removeItem(atPath: bothPath)
        }

        let videoOnly = makeDossierRecord(fullPath: videoOnlyPath, streamType: .videoOnly)
        let both = makeDossierRecord(fullPath: bothPath, streamType: .videoAndAudio)
        model.records = [videoOnly, both]
        model.scanTargets = [makeReachableTarget(at: tmp)]

        let stub = StubDossierRunner(modelID: "stub-d-novoa")
        let orch = CaptionOrchestrator(runnerFactory: { stub })
        let transcriber = StubAudioTranscriber(
            modelID: "stub-w-novoa",
            transcriptText: "hello"
        )

        await orch.startCatalogWideDossier(model: model, transcriber: transcriber)

        guard case .finished(let captioned, _, let failed) = orch.currentStatus else {
            Issue.record("Expected .finished, got \(orch.currentStatus)")
            return
        }
        #expect(captioned == 2)
        #expect(failed == 0)

        // Whisper must NOT have been called for the videoOnly path.
        #expect(!transcriber.calledPaths.contains(videoOnlyPath),
                "Whisper was called for the video-only file: \(transcriber.calledPaths)")
        #expect(transcriber.calledPaths.contains(bothPath),
                "Whisper must still run for the videoAndAudio file")

        // The video-only record must be dossiered (VLM-only) with no
        // whisper model stamp.
        #expect(videoOnly.dossierProcessedAt != nil)
        #expect(videoOnly.audioTranscriptModel == nil || videoOnly.audioTranscriptModel == "")

        // Completion entry: note == "no audio", whisperSeconds == nil.
        let videoOnlyEntry = orch.recentActivity.first { $0.filename == (videoOnlyPath as NSString).lastPathComponent }
        #expect(videoOnlyEntry != nil, "Video-only file must appear in recentActivity")
        #expect(videoOnlyEntry?.note == "no audio")
        #expect(videoOnlyEntry?.whisperSeconds == nil)
    }

    // MARK: - Whisper failure mode (Bug 2 follow-up)
    //
    // A whisper subprocess crash leaves us with a valid VLM-only
    // dossier — the file IS captioned, not failed. We must not
    // double-count it as failed; instead bump a separate counter and
    // tag the activity entry as "transcript failed".

    @Test("whisper failure records 'transcript failed' but file is still captioned")
    func testWhisperFailureRecordsTranscriptFailed() async {
        let model = VideoScanModel()
        let tmp = NSTemporaryDirectory()

        let goodPath = tmp + "vs-dossier-wf-good.mp4"
        let badPath = tmp + "vs-dossier-wf-bad.mp4"
        FileManager.default.createFile(atPath: goodPath, contents: Data("x".utf8))
        FileManager.default.createFile(atPath: badPath, contents: Data("x".utf8))
        defer {
            try? FileManager.default.removeItem(atPath: goodPath)
            try? FileManager.default.removeItem(atPath: badPath)
        }

        let goodRec = makeDossierRecord(fullPath: goodPath)
        let badRec = makeDossierRecord(fullPath: badPath)
        model.records = [goodRec, badRec]
        model.scanTargets = [makeReachableTarget(at: tmp)]

        let stub = StubDossierRunner(modelID: "stub-d-wf")
        let orch = CaptionOrchestrator(runnerFactory: { stub })
        let transcriber = StubAudioTranscriber(
            modelID: "stub-w-wf",
            transcriptText: "hello",
            failOnPath: badPath
        )

        await orch.startCatalogWideDossier(model: model, transcriber: transcriber)

        guard case .finished(let captioned, _, let failed) = orch.currentStatus else {
            Issue.record("Expected .finished, got \(orch.currentStatus)")
            return
        }
        // Both files captioned (whisper failure does NOT fail the file).
        #expect(captioned == 2)
        #expect(failed == 0, "Whisper failure must NOT increment liveFailed")
        #expect(orch.transcriptFailures == 1, "transcriptFailures should be exactly 1")

        // The bad-whisper file appears in history with the right note.
        let badEntry = orch.recentActivity.first { $0.filename == (badPath as NSString).lastPathComponent }
        #expect(badEntry != nil, "Whisper-failed file must still appear in recentActivity (it was captioned)")
        #expect(badEntry?.note == "transcript failed")
        #expect(badEntry?.whisperSeconds == nil)
        #expect(badEntry?.vlmSeconds != nil)

        // The bad record is captioned (VLM ran) but has no audio transcript stamped.
        #expect(badRec.dossierProcessedAt != nil)
        #expect((badRec.audioTranscript ?? "").isEmpty)
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
