import Foundation
import Testing
@testable import VideoScan

// MARK: - Quit-time VLM drain tests
//
// Regression coverage for the MLX exit-crash fix (crash reports
// VideoScan-2026-06-11-232946.ips / VideoScan-2026-06-12-143757.ips):
// the app segfaulted on quit because MLX's static C++ Scheduler
// destructor synchronized Metal during exit(), and a second variant
// crashed with VLM inference still dispatching GPU work mid-teardown.
//
// These tests exercise the orchestrator side of the fix with fake
// engines — no MLX, no GPU:
//   - drainForShutdown settles a cooperatively-cancellable batch well
//     within its deadline,
//   - drainForShutdown gives up at the deadline when the engine
//     ignores cancellation (the caller then relies on the _exit
//     backstop),
//   - the isShuttingDown latch refuses new batches, so the
//     catalog-wide sweep can't start the NEXT volume's inference
//     while the app is terminating.
// The _exit / static-destructor mechanism itself is not unit-testable
// in-process by construction (it ends the process); it's verified
// manually in-app.

// MARK: - Fake engines

/// Engine that blocks "forever" but honors cancellation — `Task.sleep`
/// throws `CancellationError` as soon as the surrounding task is
/// cancelled. Models a well-behaved MLX generation loop.
private actor CooperativeSlowRunner: CaptionRunner {
    nonisolated let modelID = "fake-coop-slow"
    private(set) var entered = false
    func hasEntered() -> Bool { entered }

    func caption(
        videoPath: String,
        atTimestamps timestamps: [Double]
    ) async throws -> [SceneCaption] {
        entered = true
        try await Task.sleep(nanoseconds: 60_000_000_000) // cancelled long before
        return []
    }
}

/// Engine that IGNORES cancellation for `holdSeconds` — models a worst
/// case where inference can't be interrupted mid-dispatch. `try?` on
/// the sleep swallows the CancellationError so the loop keeps going.
private actor StubbornSlowRunner: CaptionRunner {
    nonisolated let modelID = "fake-stubborn-slow"
    private let holdSeconds: Double
    private(set) var entered = false
    func hasEntered() -> Bool { entered }

    init(holdSeconds: Double) {
        self.holdSeconds = holdSeconds
    }

    func caption(
        videoPath: String,
        atTimestamps timestamps: [Double]
    ) async throws -> [SceneCaption] {
        entered = true
        let end = CFAbsoluteTimeGetCurrent() + holdSeconds
        while CFAbsoluteTimeGetCurrent() < end {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return []
    }
}

/// Trivial fast engine used to assert the shutdown latch refuses work.
private actor CountingRunner: CaptionRunner {
    nonisolated let modelID = "fake-counting"
    private(set) var calls = 0
    func callCount() -> Int { calls }

    func caption(
        videoPath: String,
        atTimestamps timestamps: [Double]
    ) async throws -> [SceneCaption] {
        calls += 1
        return timestamps.map { SceneCaption(timestamp: $0, text: "x") }
    }
}

// MARK: - Helpers

@MainActor
private func makeRecord(fullPath: String) -> VideoRecord {
    let r = VideoRecord()
    r.filename = (fullPath as NSString).lastPathComponent
    r.fullPath = fullPath
    r.streamTypeRaw = StreamType.videoAndAudio.rawValue
    r.durationSeconds = 3.0
    return r
}

/// Create a real (empty) tmp file so the orchestrator's existence
/// check passes through to the runner. Returns the path; caller cleans
/// up via the returned closure.
private func makeTmpVideo(_ name: String) -> (path: String, cleanup: () -> Void) {
    let path = NSTemporaryDirectory() + name
    FileManager.default.createFile(atPath: path, contents: Data("x".utf8))
    return (path, { try? FileManager.default.removeItem(atPath: path) })
}

/// Poll until `condition` is true or `timeout` elapses. Returns the
/// final condition value.
private func waitUntil(
    timeout: TimeInterval = 5.0,
    _ condition: () async -> Bool
) async -> Bool {
    let end = CFAbsoluteTimeGetCurrent() + timeout
    while CFAbsoluteTimeGetCurrent() < end {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return await condition()
}

// MARK: - Suite

@MainActor
@Suite("Caption Orchestrator — quit-time drain")
struct CaptionOrchestratorShutdownTests {

    @Test("drain on idle orchestrator returns true immediately")
    func drainOnIdleIsImmediate() async {
        let orch = CaptionOrchestrator()
        let t0 = CFAbsoluteTimeGetCurrent()
        let drained = await orch.drainForShutdown(deadline: 5.0)
        let elapsed = CFAbsoluteTimeGetCurrent() - t0
        #expect(drained)
        #expect(elapsed < 1.0, "Idle drain should not wait, took \(elapsed)s")
        #expect(orch.isShuttingDown)
        #expect(orch.currentStatus == .idle)
    }

    @Test("drain cancels a cooperative batch well within the deadline")
    func drainCancelsCooperativeBatch() async {
        let (path, cleanup) = makeTmpVideo("vs-drain-coop.mp4")
        defer { cleanup() }

        let model = VideoScanModel()
        model.records = [makeRecord(fullPath: path)]
        let target = CatalogScanTarget(searchPath: NSTemporaryDirectory())

        let runner = CooperativeSlowRunner()
        let orch = CaptionOrchestrator(runnerFactory: { runner })

        let batch = Task { await orch.startCaptioning(target: target, model: model) }

        // Wait until inference is actually in flight before draining.
        let started = await waitUntil { await runner.hasEntered() }
        #expect(started, "Runner never entered caption() — test setup broken")

        let t0 = CFAbsoluteTimeGetCurrent()
        let drained = await orch.drainForShutdown(deadline: 5.0)
        let elapsed = CFAbsoluteTimeGetCurrent() - t0

        #expect(drained, "Cooperative batch should drain on cancel")
        #expect(elapsed < 2.0, "Drain of a cooperative batch took \(elapsed)s")
        // The batch settled to a terminal status — nothing in flight.
        guard case .finished = orch.currentStatus else {
            Issue.record("Expected .finished after drain, got \(orch.currentStatus)")
            return
        }
        await batch.value
    }

    @Test("drain returns false at the deadline when the engine ignores cancellation")
    func drainDeadlineExpiresOnStubbornEngine() async {
        let (path, cleanup) = makeTmpVideo("vs-drain-stubborn.mp4")
        defer { cleanup() }

        let model = VideoScanModel()
        model.records = [makeRecord(fullPath: path)]
        let target = CatalogScanTarget(searchPath: NSTemporaryDirectory())

        let runner = StubbornSlowRunner(holdSeconds: 2.0)
        let orch = CaptionOrchestrator(runnerFactory: { runner })

        let batch = Task { await orch.startCaptioning(target: target, model: model) }
        let started = await waitUntil { await runner.hasEntered() }
        #expect(started, "Runner never entered caption() — test setup broken")

        let t0 = CFAbsoluteTimeGetCurrent()
        let drained = await orch.drainForShutdown(deadline: 0.5)
        let elapsed = CFAbsoluteTimeGetCurrent() - t0

        #expect(drained == false, "Stubborn engine should exhaust the deadline")
        #expect(elapsed < 1.5, "Drain must give up near the 0.5s deadline, took \(elapsed)s")

        // Let the stubborn batch run out so the test leaves no work behind.
        await batch.value
    }

    @Test("shutdown latch refuses new single-target and catalog-wide batches")
    func shutdownLatchRefusesNewBatches() async {
        let (path, cleanup) = makeTmpVideo("vs-drain-latch.mp4")
        defer { cleanup() }

        let model = VideoScanModel()
        model.records = [makeRecord(fullPath: path)]
        let target = CatalogScanTarget(searchPath: NSTemporaryDirectory())

        let runner = CountingRunner()
        let orch = CaptionOrchestrator(runnerFactory: { runner })

        // Latch shutdown (idle drain), then try to start work.
        await orch.drainForShutdown(deadline: 1.0)
        #expect(orch.isShuttingDown)

        await orch.startCaptioning(target: target, model: model)
        await orch.startCatalogWideCaptioning(model: model)
        await orch.startCatalogWideDossier(model: model)

        let calls = await runner.callCount()
        #expect(calls == 0, "No engine work may start after shutdown latch, got \(calls) call(s)")
        #expect(orch.currentStatus == .idle, "Refused starts must not flip status, got \(orch.currentStatus)")
    }

    @Test("fast quit during the auto-resume delay: beginShutdown latch blocks the deferred dossier start")
    func beginShutdownBlocksDeferredAutoResume() async {
        // Launch sequence under test: VideoScanApp's DossierAutoResume
        // path schedules startCatalogWideDossier ~3s after launch. If
        // the user quits during that delay, NO batch is active, so
        // applicationShouldTerminate skips the drain — it latches via
        // the synchronous beginShutdown() instead. The auto-resume
        // task firing afterward must be refused; fresh VLM inference
        // starting mid-teardown is the original exit crash
        // (VideoScan-2026-06-11-232946.ips).
        let (path, cleanup) = makeTmpVideo("vs-drain-autoresume.mp4")
        defer { cleanup() }

        let model = VideoScanModel()
        model.records = [makeRecord(fullPath: path)]

        let runner = CountingRunner()
        let orch = CaptionOrchestrator(runnerFactory: { runner })

        // Fast quit-after-launch: latch with nothing active.
        orch.beginShutdown()
        #expect(orch.isShuttingDown)

        // The deferred auto-resume fires after termination began.
        await orch.startCatalogWideDossier(model: model)

        let calls = await runner.callCount()
        #expect(calls == 0, "Auto-resume must not start inference after shutdown began, got \(calls) call(s)")
        #expect(orch.currentStatus == .idle, "Refused auto-resume must not flip status, got \(orch.currentStatus)")
    }

    @Test("MLX usage flag round-trips and is reset-able")
    func mlxUsageFlagRoundTrip() {
        resetMLXInferenceUsedForTesting()
        #expect(mlxInferenceWasUsed() == false)
        noteMLXInferenceUsed()
        #expect(mlxInferenceWasUsed())
        resetMLXInferenceUsedForTesting()
        #expect(mlxInferenceWasUsed() == false)
        // synchronizeMLXForShutdown with the flag clear must be a no-op
        // (and must not touch the GPU in a test host).
        synchronizeMLXForShutdown()
    }
}
