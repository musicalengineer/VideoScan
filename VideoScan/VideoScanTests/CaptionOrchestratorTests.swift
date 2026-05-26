import Foundation
import Testing
@testable import VideoScan

// MARK: - CaptionOrchestrator stage-6b tests
//
// Exercise the orchestrator's plumbing — state transitions, skip logic,
// per-file writeback, cancellation flag — without invoking the real MLX
// VLM. The runner is stubbed via `CaptionOrchestrator.runnerFactory`,
// which lets us return deterministic captions on demand and verify the
// orchestrator wires them into the catalog correctly.
//
// One gated test (`captionsTargetEndToEnd`, behind VS_RUN_VLM=1) drives
// the real engine with the test fixture so we can verify the
// orchestrator + real engine round-trip in CI mode. The default sweep
// skips it for the same reasons CaptionRunnerTests skips its VLM test
// (3 GB download + slow inference; see that file's header).

// MARK: - Stub runner
//
// Returns a fixed set of captions per call. Records every invocation so
// the test can assert which paths were captioned (and which were
// skipped). `actor` for thread-safety since the orchestrator may invoke
// it from a detached task; `CaptionRunner` requires `Sendable`.

/// `actor` ≈ a class with implicit mutex around all members — gives us
/// safe shared mutable state for invocation counting without a Lock.
actor StubCaptionRunner: CaptionRunner {
    nonisolated let modelID: String

    /// Paths the runner was asked to caption, in invocation order.
    /// Tests read this to verify orchestrator skip logic.
    private(set) var captionedPaths: [String] = []

    /// Caption text the stub returns for every frame. One per
    /// timestamp the orchestrator passes.
    let captionText: String

    init(modelID: String = "stub-vlm-1", captionText: String = "A stub caption.") {
        self.modelID = modelID
        self.captionText = captionText
    }

    func caption(
        videoPath: String,
        atTimestamps timestamps: [Double]
    ) async throws -> [SceneCaption] {
        captionedPaths.append(videoPath)
        return timestamps.map { SceneCaption(timestamp: $0, text: captionText) }
    }

    /// Test introspection. Returns a snapshot of paths the stub has
    /// been called with so far.
    func pathsCalled() -> [String] { captionedPaths }
    func countCalled() -> Int { captionedPaths.count }
}

// MARK: - Test helpers

/// Build a minimal cataloged VideoRecord for a video file. Tests don't
/// need a real file on disk for the orchestrator's plumbing checks
/// because we hand-construct the candidate set via VideoScanModel.records
/// — but where the orchestrator's file-existence guard fires (the
/// "missing on disk" path), tests do need a real fixture.
@MainActor
private func makeCatalogRecord(
    fullPath: String,
    streamType: StreamType = .videoAndAudio,
    durationSeconds: Double = 3.0,
    existingCaptions: [SceneCaption] = [],
    existingModel: String? = nil
) -> VideoRecord {
    let r = VideoRecord()
    r.filename = (fullPath as NSString).lastPathComponent
    r.fullPath = fullPath
    r.streamTypeRaw = streamType.rawValue
    r.durationSeconds = durationSeconds
    r.sceneCaptions = existingCaptions
    r.sceneCaptionModel = existingModel
    if existingModel != nil { r.sceneCaptionDate = Date() }
    return r
}

/// Build a CatalogScanTarget pointing at /tmp so the orchestrator's
/// prefix filter picks up records under that path. We do NOT call
/// model.startTarget on it — pure data structure.
@MainActor
private func makeTarget(at path: String) -> CatalogScanTarget {
    let t = CatalogScanTarget(searchPath: path)
    return t
}

// MARK: - Suite

@MainActor
@Suite("Caption Orchestrator — stage 6b plumbing")
struct CaptionOrchestratorTests {

    // MARK: - Always-on: init + idle state

    @Test("orchestrator starts in idle status")
    func initIsIdle() async {
        let orch = CaptionOrchestrator()
        #expect(orch.currentStatus == .idle)
        #expect(orch.currentStatus.isActive == false)
        #expect(orch.liveCaptioned == 0)
        #expect(orch.liveSkipped == 0)
        #expect(orch.liveFailed == 0)
    }

    // MARK: - Always-on: cancel before-start is a no-op

    @Test("cancel on idle orchestrator does nothing")
    func cancelOnIdleIsNoOp() async {
        let orch = CaptionOrchestrator()
        orch.cancel()
        // Status should remain .idle — cancel only flips state when
        // there's an active batch.
        #expect(orch.currentStatus == .idle)
    }

    // MARK: - Always-on: empty target finishes cleanly

    @Test("empty target produces finished status with zero counts")
    func emptyTargetFinishesCleanly() async {
        let model = VideoScanModel()
        model.records = []   // no records at all
        let target = makeTarget(at: "/tmp/vs-empty-test")

        let stub = StubCaptionRunner()
        let orch = CaptionOrchestrator(runnerFactory: { stub })

        await orch.startCaptioning(target: target, model: model)

        guard case .finished(let captioned, let skipped, let failed) = orch.currentStatus else {
            Issue.record("Expected .finished status, got \(orch.currentStatus)")
            return
        }
        #expect(captioned == 0)
        #expect(skipped == 0)
        #expect(failed == 0)

        let calls = await stub.countCalled()
        #expect(calls == 0, "Stub runner should not have been called for empty target")
    }

    // MARK: - Always-on: idempotent skip

    @Test("records already captioned with the current model are skipped")
    func idempotentSkipForAlreadyCaptioned() async {
        let model = VideoScanModel()
        let target = makeTarget(at: "/tmp/vs-skip-test")

        // Two records: one already captioned with "stub-vlm-1", one
        // never captioned. Both backed by a real (empty) tmp file so
        // the orchestrator's file-existence check passes through to
        // the runner path — that's where the skip vs caption decision
        // actually happens.
        let tmp = NSTemporaryDirectory()
        let fake1 = tmp + "vs-orch-test-existing.mp4"
        let fake2 = tmp + "vs-orch-test-fresh.mp4"
        FileManager.default.createFile(atPath: fake1, contents: Data("x".utf8))
        FileManager.default.createFile(atPath: fake2, contents: Data("x".utf8))
        defer {
            try? FileManager.default.removeItem(atPath: fake1)
            try? FileManager.default.removeItem(atPath: fake2)
        }

        let already = makeCatalogRecord(
            fullPath: fake1,
            existingCaptions: [SceneCaption(timestamp: 0.5, text: "old")],
            existingModel: "stub-vlm-1"
        )
        let fresh = makeCatalogRecord(fullPath: fake2)
        model.records = [already, fresh]

        // Stub runner with the matching modelID so the skip path triggers.
        let stub = StubCaptionRunner(modelID: "stub-vlm-1")
        let orch = CaptionOrchestrator(runnerFactory: { stub })

        // Override the prefix so both records sort under the target.
        let prefixTarget = makeTarget(at: tmp)
        await orch.startCaptioning(target: prefixTarget, model: model)

        guard case .finished(let captioned, let skipped, let failed) = orch.currentStatus else {
            Issue.record("Expected .finished, got \(orch.currentStatus)")
            return
        }
        #expect(captioned == 1)
        #expect(skipped == 1)
        #expect(failed == 0)

        // The stub should have been called exactly once — for the
        // fresh record only.
        let calls = await stub.pathsCalled()
        #expect(calls == [fake2], "Stub should only be called for fake2 (fresh), got \(calls)")
    }

    // MARK: - Always-on: writeback at file boundary

    @Test("each captioned file gets applyCaptions immediately")
    func writebackHappensPerFile() async {
        let model = VideoScanModel()
        let tmp = NSTemporaryDirectory()

        let path1 = tmp + "vs-orch-wb-a.mp4"
        let path2 = tmp + "vs-orch-wb-b.mp4"
        FileManager.default.createFile(atPath: path1, contents: Data("x".utf8))
        FileManager.default.createFile(atPath: path2, contents: Data("x".utf8))
        defer {
            try? FileManager.default.removeItem(atPath: path1)
            try? FileManager.default.removeItem(atPath: path2)
        }

        let r1 = makeCatalogRecord(fullPath: path1)
        let r2 = makeCatalogRecord(fullPath: path2)
        model.records = [r1, r2]

        let stub = StubCaptionRunner(modelID: "stub-vlm-2", captionText: "a person standing in a kitchen")
        let orch = CaptionOrchestrator(runnerFactory: { stub })

        let target = makeTarget(at: tmp)
        await orch.startCaptioning(target: target, model: model)

        guard case .finished(let captioned, _, _) = orch.currentStatus else {
            Issue.record("Expected .finished, got \(orch.currentStatus)")
            return
        }
        #expect(captioned == 2)

        // Both records should have captions written through. With a
        // 3-frame default and a 3-second clip, we expect 3 SceneCaption
        // entries per record, all with the stub's text.
        #expect(r1.sceneCaptions.count == 3, "r1 should have 3 captions, got \(r1.sceneCaptions.count)")
        #expect(r2.sceneCaptions.count == 3, "r2 should have 3 captions, got \(r2.sceneCaptions.count)")
        #expect(r1.sceneCaptionModel == "stub-vlm-2")
        #expect(r2.sceneCaptionModel == "stub-vlm-2")
        #expect(r1.sceneCaptions.first?.text == "a person standing in a kitchen")
    }

    // MARK: - Always-on: missing-on-disk file is counted as failed, not crashed

    @Test("records whose file is missing on disk are counted as failed")
    func missingFileCountsAsFailed() async {
        let model = VideoScanModel()
        let tmp = NSTemporaryDirectory()

        // Real file (will succeed) + nonexistent path (will fail with
        // file-not-found short-circuit).
        let realPath = tmp + "vs-orch-mf-real.mp4"
        let ghostPath = tmp + "vs-orch-mf-ghost-DOES-NOT-EXIST.mp4"
        FileManager.default.createFile(atPath: realPath, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(atPath: realPath) }

        let realRec = makeCatalogRecord(fullPath: realPath)
        let ghostRec = makeCatalogRecord(fullPath: ghostPath)
        model.records = [realRec, ghostRec]

        let stub = StubCaptionRunner()
        let orch = CaptionOrchestrator(runnerFactory: { stub })

        let target = makeTarget(at: tmp)
        await orch.startCaptioning(target: target, model: model)

        guard case .finished(let captioned, let skipped, let failed) = orch.currentStatus else {
            Issue.record("Expected .finished, got \(orch.currentStatus)")
            return
        }
        #expect(captioned == 1, "Only realPath should caption")
        #expect(skipped == 0)
        #expect(failed == 1, "ghostPath should count as failed")

        let calls = await stub.pathsCalled()
        #expect(calls == [realPath], "Stub should only see realPath, got \(calls)")
    }

    // MARK: - Always-on: audio-only records are filtered out (not seen by runner)

    @Test("audio-only records are filtered out before the runner")
    func audioOnlyFilteredOut() async {
        let model = VideoScanModel()
        let tmp = NSTemporaryDirectory()

        let aoPath = tmp + "vs-orch-ao.wav"
        let videoPath = tmp + "vs-orch-ao-vid.mp4"
        FileManager.default.createFile(atPath: aoPath, contents: Data("x".utf8))
        FileManager.default.createFile(atPath: videoPath, contents: Data("x".utf8))
        defer {
            try? FileManager.default.removeItem(atPath: aoPath)
            try? FileManager.default.removeItem(atPath: videoPath)
        }

        let aoRec = makeCatalogRecord(fullPath: aoPath, streamType: .audioOnly)
        let vRec = makeCatalogRecord(fullPath: videoPath, streamType: .videoAndAudio)
        model.records = [aoRec, vRec]

        let stub = StubCaptionRunner()
        let orch = CaptionOrchestrator(runnerFactory: { stub })

        let target = makeTarget(at: tmp)
        await orch.startCaptioning(target: target, model: model)

        let calls = await stub.pathsCalled()
        #expect(calls == [videoPath], "Audio-only record should be filtered out before runner")
    }

    // MARK: - Always-on: framesEvenlySpaced math

    @Test("framesEvenlySpaced returns N entries skipping clip edges")
    func framesEvenlySpacedShape() {
        let three = framesEvenlySpaced(framesPerFile: 3, durationSec: 10.0)
        #expect(three.count == 3)
        // Should land inside the clip with 5% guards on either side.
        #expect(three.first! >= 0.5 && three.first! < 1.0,
                "First frame should be near 5% mark, got \(three.first!)")
        #expect(three.last! > 9.0 && three.last! <= 9.5,
                "Last frame should be near 95% mark, got \(three.last!)")
        // Monotonically increasing.
        #expect(three[0] < three[1])
        #expect(three[1] < three[2])

        // Edge cases.
        #expect(framesEvenlySpaced(framesPerFile: 0, durationSec: 10).isEmpty)
        #expect(framesEvenlySpaced(framesPerFile: 3, durationSec: 0).isEmpty)
        let one = framesEvenlySpaced(framesPerFile: 1, durationSec: 10.0)
        #expect(one.count == 1)
        #expect(one[0] > 4.5 && one[0] < 5.5, "Single-frame should land near midpoint")
    }

    // MARK: - VLM-gated: full end-to-end

    @Test(
        "MLXVLM orchestrator end-to-end on a single fixture (VS_RUN_VLM=1)",
        .disabled(
            if: ProcessInfo.processInfo.environment["VS_RUN_VLM"] != "1",
            "VLM end-to-end — set VS_RUN_VLM=1 to enable."
        ),
        .timeLimit(.minutes(10))
    )
    func captionsTargetEndToEnd() async throws {
        let fixturesDir = testFixturesDir()
        let videoPath = fixturesDir + "/test_face_3s.mp4"
        #expect(FileManager.default.fileExists(atPath: videoPath))

        let model = VideoScanModel()
        let rec = makeCatalogRecord(fullPath: videoPath, durationSeconds: 3.0)
        model.records = [rec]

        let target = makeTarget(at: fixturesDir)
        let orch = CaptionOrchestrator()

        await orch.startCaptioning(target: target, model: model)

        guard case .finished(let captioned, _, _) = orch.currentStatus else {
            Issue.record("Expected .finished, got \(orch.currentStatus)")
            return
        }
        #expect(captioned >= 1, "Expected at least 1 captioned file, got \(captioned)")
        #expect(!rec.sceneCaptions.isEmpty, "Catalog record should have captions")
        #expect(rec.sceneCaptionModel == "qwen2.5-vl-3b-4bit")
    }
}
