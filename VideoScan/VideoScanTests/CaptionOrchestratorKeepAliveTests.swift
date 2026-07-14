import Foundation
import Testing
@testable import VideoScan

// MARK: - VLM runner keep-alive tests (perf item 3, 2026-07-14)
//
// Pins the cached-runner lifecycle that replaced the batch-scoped VLM
// container: N sequential batches (multi-select single-file Analyze
// jobs, queued-volume hand-offs) must pay for exactly ONE runner
// instantiation (in production: one ~30s / ~3 GB model load), an idle
// window releases the cached runner when no batch follows, and the
// shutdown path drops it IMMEDIATELY even mid-idle-window — the
// mid-inference quit crash (VideoScan-2026-06-11-232946.ips) must not
// come back through the cache.
//
// Dimensions per the feature-test checklist:
//   Logic  — reuse across sequential batches + queue hand-off
//   Sensor — "5 batches → exactly 1 instantiation" is the regression
//            sensor for the N×30s model-reload waste
//   Negative/safety — shutdown drop, no-resurrection, timer-fires-
//            after-shutdown no-op, cancel-preserves-runner semantics
// Scale: N/A (no O(records) pass added here — the ride-along path
// index has its own scale sensor). Media matrix: N/A (stub runner,
// no media opened). Isolation: orchestrator persistence is already
// disabled in test hosts (persistenceEnabled gate, pinned elsewhere).

// MARK: - Counting factory probe
//
// Counts every `runnerFactory()` invocation and remembers the last
// runner WEAKLY — so the shutdown test can prove the orchestrator
// actually released its reference (in production that reference is
// what keeps the ~3 GB ModelContainer alive). NSLock + @unchecked
// Sendable mirrors StubAudioTranscriber's pattern.
final class KeepAliveFactoryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    private weak var _last: AnyObject?
    private let builder: @Sendable (Int) -> CaptionRunner

    init(builder: @escaping @Sendable (Int) -> CaptionRunner = { n in
        StubDossierRunner(modelID: "stub-keepalive-\(n)")
    }) {
        self.builder = builder
    }

    var instantiations: Int { lock.withLock { _count } }
    var lastRunner: AnyObject? { lock.withLock { _last } }

    func make() -> CaptionRunner {
        lock.withLock {
            _count += 1
            let r = builder(_count)
            _last = r as AnyObject
            return r
        }
    }
}

// MARK: - Slow-then-fast runner
//
// First dossier() call blocks "forever" but honors cancellation
// (models a well-behaved in-flight MLX generation); every later call
// returns instantly. Lets the cancel-semantics test cancel mid-batch
// and then prove the SAME runner instance completes the next batch.
private actor SlowThenFastRunner: CaptionRunner {
    nonisolated let modelID = "stub-slow-then-fast"
    private var calls = 0
    private var entered = false
    func hasEntered() -> Bool { entered }

    func caption(
        videoPath: String,
        atTimestamps timestamps: [Double]
    ) async throws -> [SceneCaption] {
        timestamps.map { SceneCaption(timestamp: $0, text: "x") }
    }

    func dossier(
        videoPath: String,
        atTimestamps timestamps: [Double]
    ) async throws -> DossierExtraction {
        calls += 1
        if calls == 1 {
            entered = true
            try await Task.sleep(nanoseconds: 60_000_000_000) // cancelled long before
        }
        return DossierExtraction(
            scenes: timestamps.map { SceneCaption(timestamp: $0, text: "s") },
            dates: [], texts: []
        )
    }
}

// MARK: - Fixtures

@MainActor
private func keepAliveRecord(fullPath: String) -> VideoRecord {
    let r = VideoRecord()
    r.filename = (fullPath as NSString).lastPathComponent
    r.fullPath = fullPath
    r.streamTypeRaw = StreamType.videoAndAudio.rawValue
    r.durationSeconds = 3.0
    r.lifecycleStage = .cataloged
    return r
}

/// Tmp dir with `count` stand-in media files + matching records.
@MainActor
private func makeFiles(tag: String, count: Int) throws -> (root: String, paths: [String], records: [VideoRecord]) {
    let root = NSTemporaryDirectory() + "vs-keepalive-\(tag)-\(UUID().uuidString)/"
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    var paths: [String] = []
    var recs: [VideoRecord] = []
    for i in 0..<count {
        let p = root + "clip\(i).mp4"
        FileManager.default.createFile(atPath: p, contents: Data("x".utf8))
        paths.append(p)
        recs.append(keepAliveRecord(fullPath: p))
    }
    return (root, paths, recs)
}

/// Poll until `condition` is true or timeout. Yields the MainActor.
@MainActor
private func pollUntil(
    timeoutSeconds: Double = 5.0,
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

// MARK: - Suite

@MainActor
@Suite("VLM runner keep-alive")
struct CaptionOrchestratorKeepAliveTests {

    // MARK: Positive

    @Test("sensor: 5 sequential single-file batches instantiate the runner exactly once")
    func fiveSingleFileBatchesOneInstantiation() async throws {
        let (root, paths, recs) = try makeFiles(tag: "five", count: 5)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let model = VideoScanModel()
        model.records = recs

        let probe = KeepAliveFactoryProbe()
        let orch = CaptionOrchestrator(runnerFactory: { probe.make() })

        // The exact multi-select shape: N AnalyzeJobs, each a
        // single-file batch keyed by the record's fullPath, run
        // back-to-back. Pre-keep-alive this paid N model loads.
        for p in paths {
            let ran = await orch.startAnalyzing(volumePrefix: p, model: model,
                                                ignoringScope: true)
            #expect(ran, "single-file batch for \(p) must run")
        }

        #expect(probe.instantiations == 1,
                "5 sequential batches must reuse ONE runner (≈ one 30s model load), got \(probe.instantiations)")
        for rec in recs {
            #expect(rec.dossierProcessedAt != nil, "\(rec.filename) must be dossiered")
        }
        #expect(orch.cachedRunner != nil, "runner must stay cached after settle (idle window not expired)")
    }

    @Test("queued-volume hand-off reuses the cached runner across the hop")
    func queueHandOffReusesRunner() async throws {
        let (root, _, recs) = try makeFiles(tag: "handoff", count: 2)
        defer { try? FileManager.default.removeItem(atPath: root) }
        // Two "volumes": split the files into two subdirs.
        let volA = root + "volA/", volB = root + "volB/"
        try FileManager.default.createDirectory(atPath: volA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: volB, withIntermediateDirectories: true)
        let pA = volA + "a.mp4", pB = volB + "b.mp4"
        FileManager.default.createFile(atPath: pA, contents: Data("x".utf8))
        FileManager.default.createFile(atPath: pB, contents: Data("x".utf8))
        recs[0].fullPath = pA; recs[0].filename = "a.mp4"
        recs[1].fullPath = pB; recs[1].filename = "b.mp4"
        let model = VideoScanModel()
        model.records = recs

        let probe = KeepAliveFactoryProbe()
        let orch = CaptionOrchestrator(runnerFactory: { probe.make() })

        // Express intent on both volumes at once — the queue runs A,
        // then hands off to B on settle. Pre-keep-alive the hand-off
        // paid a fresh ~30s model load.
        orch.enqueueAnalyze(volumePrefix: volA, model: model)
        orch.enqueueAnalyze(volumePrefix: volB, model: model)

        let drained = await pollUntil(timeoutSeconds: 15) {
            orch.queuedVolumePrefixes.isEmpty
                && !orch.queueDispatchInFlight
                && !orch.currentStatus.isActive
        }
        #expect(drained, "queue never drained")
        #expect(probe.instantiations == 1,
                "queue hand-off must reuse the cached runner, got \(probe.instantiations) instantiation(s)")
        #expect(recs[0].dossierProcessedAt != nil)
        #expect(recs[1].dossierProcessedAt != nil)
    }

    @Test("idle window expiry releases the runner; the next batch re-instantiates")
    func idleTimeoutDropsRunner() async throws {
        let (root, paths, recs) = try makeFiles(tag: "idle", count: 2)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let model = VideoScanModel()
        model.records = recs

        let probe = KeepAliveFactoryProbe()
        let orch = CaptionOrchestrator(runnerFactory: { probe.make() })
        orch.runnerIdleTimeout = 0.15   // test seam — production default is 10 min

        _ = await orch.startAnalyzing(volumePrefix: paths[0], model: model,
                                      ignoringScope: true)
        #expect(orch.cachedRunner != nil, "runner cached right after settle")

        let dropped = await pollUntil(timeoutSeconds: 3) { orch.cachedRunner == nil }
        #expect(dropped, "idle window expiry must release the cached runner (and its container)")

        _ = await orch.startAnalyzing(volumePrefix: paths[1], model: model,
                                      ignoringScope: true)
        #expect(probe.instantiations == 2,
                "post-idle batch must re-instantiate (fresh model load), got \(probe.instantiations)")
    }

    // MARK: Negative / safety

    @Test("beginShutdown mid-idle-window drops the runner immediately and releases the reference")
    func beginShutdownDropsCachedRunner() async throws {
        let (root, paths, recs) = try makeFiles(tag: "shutdown", count: 2)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let model = VideoScanModel()
        model.records = recs

        let probe = KeepAliveFactoryProbe()
        let orch = CaptionOrchestrator(runnerFactory: { probe.make() })
        // Default 10-min idle window — we are guaranteed mid-window.

        _ = await orch.startAnalyzing(volumePrefix: paths[0], model: model,
                                      ignoringScope: true)
        #expect(orch.cachedRunner != nil)
        #expect(probe.lastRunner != nil)

        // Quit begins. The cached runner must be dropped NOW — not in
        // 10 minutes. In production this releases the ModelContainer
        // while the AppDelegate MLXShutdown path (GPU-stream
        // synchronize + _exit backstop, MLXShutdown.swift) quiesces
        // Metal; a runner surviving here is how mid-teardown GPU
        // dispatch (the 2026-06-11 crash) could come back.
        orch.beginShutdown()
        #expect(orch.cachedRunner == nil, "beginShutdown must drop the cached runner immediately")
        #expect(orch.runnerIdleTimer == nil, "idle timer must be cancelled at shutdown")

        // The orchestrator's reference is gone — the runner actor
        // itself must deallocate (weak probe ref zeroes). This is the
        // container-release proof.
        let released = await pollUntil(timeoutSeconds: 3) { probe.lastRunner == nil }
        #expect(released, "runner must actually deallocate once the orchestrator lets go")

        // Batch start during teardown must NOT resurrect a runner.
        let ran = await orch.startAnalyzing(volumePrefix: paths[1], model: model,
                                            ignoringScope: true)
        #expect(ran == false, "starts are refused after shutdown began")
        #expect(orch.cachedRunner == nil, "refused start must not resurrect the dead runner")
        #expect(probe.instantiations == 1, "no new instantiation after shutdown, got \(probe.instantiations)")
    }

    @Test("drainForShutdown (idle) also drops the cached runner")
    func drainForShutdownDropsCachedRunner() async throws {
        let (root, paths, recs) = try makeFiles(tag: "drain", count: 1)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let model = VideoScanModel()
        model.records = recs

        let probe = KeepAliveFactoryProbe()
        let orch = CaptionOrchestrator(runnerFactory: { probe.make() })

        _ = await orch.startAnalyzing(volumePrefix: paths[0], model: model,
                                      ignoringScope: true)
        #expect(orch.cachedRunner != nil)

        let drained = await orch.drainForShutdown(deadline: 2.0)
        #expect(drained, "idle drain returns true")
        #expect(orch.cachedRunner == nil, "drainForShutdown must drop the cached runner")
        #expect(orch.isShuttingDown)
    }

    @Test("idle timer firing after shutdown is a clean no-op (no crash, no resurrection)")
    func idleTimerAfterShutdownIsNoOp() async throws {
        let (root, paths, recs) = try makeFiles(tag: "latetimer", count: 1)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let model = VideoScanModel()
        model.records = recs

        let probe = KeepAliveFactoryProbe()
        let orch = CaptionOrchestrator(runnerFactory: { probe.make() })
        orch.runnerIdleTimeout = 0.1

        _ = await orch.startAnalyzing(volumePrefix: paths[0], model: model,
                                      ignoringScope: true)
        // Shutdown lands inside the 0.1s idle window; the timer's
        // wakeup (if the cancel raced) must find nothing to do.
        orch.beginShutdown()
        #expect(orch.cachedRunner == nil)
        try? await Task.sleep(for: .milliseconds(300))   // ride out the window
        #expect(orch.cachedRunner == nil, "late timer must not touch a shut-down orchestrator")
        #expect(probe.instantiations == 1)
    }

    @Test("cancel() preserves the cached runner for the next batch — cancel never tore down MLX state (pre-existing semantics: the batch-scoped runner was simply released, no explicit GPU teardown), so reuse is safe")
    func cancelPreservesCachedRunner() async throws {
        let (root, _, recs) = try makeFiles(tag: "cancel", count: 2)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let model = VideoScanModel()
        model.records = recs

        let probe = KeepAliveFactoryProbe(builder: { _ in SlowThenFastRunner() })
        let orch = CaptionOrchestrator(runnerFactory: { probe.make() })

        // Batch over the whole tmp "volume": first dossier() call
        // blocks (cancellable) so we can cancel mid-batch.
        let batch = Task { await orch.startAnalyzing(volumePrefix: root, model: model) }
        let entered = await pollUntil {
            if let slow = orch.cachedRunner as? SlowThenFastRunner {
                return await slow.hasEntered()
            }
            return false
        }
        #expect(entered, "runner never entered dossier() — setup broken")

        orch.cancel()
        _ = await batch.value

        // cancel ≠ shutdown: the runner survives for the next batch.
        #expect(orch.cachedRunner != nil,
                "a cancelled batch must leave the cached runner in place")
        #expect(probe.instantiations == 1)

        // Next batch (same runner, now fast) completes on the reused
        // instance — zero new instantiations.
        let ran = await orch.startAnalyzing(volumePrefix: root, model: model)
        #expect(ran)
        #expect(probe.instantiations == 1,
                "post-cancel batch must reuse the cached runner, got \(probe.instantiations)")
        for rec in recs {
            #expect(rec.dossierProcessedAt != nil)
        }
    }
}
