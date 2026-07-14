import Foundation
import Combine
import Testing
@testable import VideoScan

// MARK: - Dossier dashboard snapshot + progress-throttle tests
// (perf/dashboard-render, 2026-07-14)
//
// THE sensor for the dashboard render-loop item: the orchestrator's
// per-record churn must reach dashboard observers at ≤2 Hz through
// DossierDashboardSnapshot, publishProgress must coalesce skip storms
// at the source, and NO terminal/transition state may ever be lost to
// coalescing. Positive AND negative directions per the safety-critical
// testing rule.
//
// Dimensions (feature-test checklist):
//   Logic    — throttle rules, snapshot equality gate, derived helpers
//   Scale    — 5,000-record synchronous skip storm (production shape:
//              a nightly batch skipping an already-analyzed volume)
//   Isolation— orchestrators built on real standard defaults in a test
//              host don't persist (existing CaptionOrchestratorQueueTests
//              pin this; snapshot machinery reads no defaults at all)
//   Sensor   — publishRateSensor / skipStormSensor are the regression
//              sensors pinning ≤2 Hz + bounded-source behavior

// MARK: Helpers

/// Count emissions of the snapshot's published state (dropFirst skips
/// the current-value replay Combine sends on subscribe).
@MainActor
private final class SnapshotProbe {
    private(set) var publishes = 0
    private var sub: AnyCancellable?
    init(_ snapshot: DossierDashboardSnapshot) {
        sub = snapshot.$state.dropFirst().sink { [weak self] _ in
            self?.publishes += 1
        }
    }
}

/// Count raw objectWillChange fires on the orchestrator itself —
/// the "source rate" the publishProgress throttle bounds.
@MainActor
private final class WillChangeProbe {
    private(set) var fires = 0
    private var sub: AnyCancellable?
    init(_ orch: CaptionOrchestrator) {
        sub = orch.objectWillChange.sink { [weak self] _ in
            self?.fires += 1
        }
    }
}

// MARK: - Publish-rate + storm sensors

@MainActor
@Suite("Dossier dashboard snapshot — publish rate")
struct DossierDashboardPublishRateTests {

    @Test("SENSOR (positive): ~200 progress events/s reach snapshot observers at ≤2 publishes/s")
    func publishRateSensor() async throws {
        let orch = CaptionOrchestrator()
        orch.currentStatus = .running(progress: 0, currentFile: "warm", etaSec: nil)
        let probe = SnapshotProbe(orch.dashboardSnapshot)

        let started = CFAbsoluteTimeGetCurrent()
        let startedArg = started
        var idx = 0
        // 10 bursts × 20 events with ~100 ms gaps ≈ 200 events/s for
        // ~1 s — twice the plan's 100/s bar.
        for _ in 0..<10 {
            for _ in 0..<20 {
                idx += 1
                orch.publishProgress(idx: idx, total: 10_000,
                                     currentFile: "f\(idx)", started: startedArg)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        // Let the trailing coalescers (250 ms progress + 500 ms
        // snapshot) drain before measuring.
        try await Task.sleep(for: .milliseconds(700))
        let elapsed = CFAbsoluteTimeGetCurrent() - started

        let allowed = Int((elapsed * 2.0).rounded(.up)) + 2   // 2 Hz + edge slack
        #expect(probe.publishes <= allowed,
                "snapshot published \(probe.publishes)× in \(String(format: "%.2f", elapsed))s — exceeds the ≤2 Hz contract (allowed \(allowed))")
        #expect(probe.publishes >= 1,
                "coalescing must not swallow the batch's progress entirely")
        orch.currentStatus = .idle
    }

    @Test("SENSOR (positive): 5,000-record skip storm is coalesced at the source")
    func skipStormSensor() async throws {
        let orch = CaptionOrchestrator()
        orch.currentStatus = .running(progress: 0, currentFile: "start", etaSec: nil)
        let source = WillChangeProbe(orch)

        let started = CFAbsoluteTimeGetCurrent()
        // Synchronous storm — exactly the shape of a dossier batch
        // skipping thousands of already-analyzed records back-to-back.
        for i in 1...5_000 {
            orch.publishProgress(idx: i, total: 5_000,
                                 currentFile: "skip\(i)", started: started)
        }
        // Pre-fix this was ≥10,000 fires (two @Published writes per
        // event). Post-fix: only 250 ms-boundary publishes + the
        // terminal one — single digits on any machine; 40 is generous
        // slack for a slow CI box stretching the loop past boundaries.
        #expect(source.fires <= 40,
                "skip storm fired objectWillChange \(source.fires)× — source throttle regressed")
        orch.currentStatus = .idle
    }

    @Test("NEGATIVE: the terminal idx == total event is never coalesced away")
    func terminalEventAlwaysDelivered() {
        let orch = CaptionOrchestrator()
        orch.currentStatus = .running(progress: 0, currentFile: "start", etaSec: nil)
        let started = CFAbsoluteTimeGetCurrent()
        for i in 1...3_000 {
            orch.publishProgress(idx: i, total: 3_000,
                                 currentFile: "skip\(i)", started: started)
        }
        // Immediately after the synchronous storm — no waiting — the
        // terminal state must already be published (rule 2: terminal
        // events bypass the throttle).
        #expect(orch.liveCurrentIndex == 3_000)
        if case .running(let progress, let file, _) = orch.currentStatus {
            #expect(progress == 1.0)
            #expect(file == "skip3000")
        } else {
            Issue.record("expected .running at full progress, got \(orch.currentStatus)")
        }
        orch.currentStatus = .idle
    }

    @Test("NEGATIVE: a suppressed NON-terminal event is delivered by the trailing flush, not dropped")
    func trailingFlushDeliversLastEvent() async throws {
        let orch = CaptionOrchestrator()
        orch.currentStatus = .running(progress: 0, currentFile: "start", etaSec: nil)
        let started = CFAbsoluteTimeGetCurrent()

        orch.publishProgress(idx: 1, total: 100, currentFile: "a", started: started)
        #expect(orch.liveCurrentIndex == 1, "first event publishes immediately (interval clock idle)")
        orch.publishProgress(idx: 2, total: 100, currentFile: "b", started: started)
        #expect(orch.liveCurrentIndex == 1, "second event within 250 ms must be coalesced…")

        try await Task.sleep(for: .milliseconds(450))
        #expect(orch.liveCurrentIndex == 2, "…but the trailing flush must deliver it — never frozen stale")
        if case .running(_, let file, _) = orch.currentStatus {
            #expect(file == "b")
        }
        orch.currentStatus = .idle
    }

    @Test("NEGATIVE: a pending flush never resurrects .running over a settled batch")
    func flushNeverResurrectsSettledStatus() async throws {
        let orch = CaptionOrchestrator()
        orch.currentStatus = .running(progress: 0, currentFile: "start", etaSec: nil)
        let started = CFAbsoluteTimeGetCurrent()

        orch.publishProgress(idx: 1, total: 100, currentFile: "a", started: started)
        orch.publishProgress(idx: 2, total: 100, currentFile: "b", started: started)  // pending
        orch.currentStatus = .finished(captioned: 1, skipped: 0, failed: 0)

        try await Task.sleep(for: .milliseconds(450))
        #expect(orch.currentStatus == .finished(captioned: 1, skipped: 0, failed: 0),
                "trailing flush overwrote a terminal status with stale .running")
    }

    @Test("NEGATIVE: a stale pending event from batch A cannot leak into batch B (resetLiveCounts clears it)")
    func pendingClearedAcrossBatches() async throws {
        let orch = CaptionOrchestrator()
        orch.currentStatus = .running(progress: 0, currentFile: "A0", etaSec: nil)
        let startedA = CFAbsoluteTimeGetCurrent()
        orch.publishProgress(idx: 1, total: 100, currentFile: "A1", started: startedA)
        orch.publishProgress(idx: 2, total: 100, currentFile: "A2-stale", started: startedA)  // pending
        orch.currentStatus = .finished(captioned: 2, skipped: 0, failed: 0)

        // Batch B starts before A's flush timer fires.
        orch.resetLiveCounts()
        orch.currentStatus = .running(progress: 0, currentFile: "B0", etaSec: nil)

        try await Task.sleep(for: .milliseconds(450))
        if case .running(_, let file, _) = orch.currentStatus {
            #expect(file == "B0", "batch A's coalesced event leaked into batch B: '\(file)'")
        } else {
            Issue.record("expected batch B still .running, got \(orch.currentStatus)")
        }
        orch.currentStatus = .idle
    }

    @Test("equality gate: dirty ticks with unchanged state publish nothing")
    func unchangedStatePublishesNothing() async throws {
        let orch = CaptionOrchestrator()
        // Let any init-time publication settle first.
        try await Task.sleep(for: .milliseconds(600))
        let probe = SnapshotProbe(orch.dashboardSnapshot)
        for _ in 0..<10 {
            orch.noteDashboardSnapshotDirty()
        }
        try await Task.sleep(for: .milliseconds(700))
        #expect(probe.publishes == 0,
                "no state changed — observers must not be invalidated (got \(probe.publishes) publishes)")
    }
}

// MARK: - Snapshot truthfulness (queue UI states through the snapshot)

@MainActor
@Suite("Dossier dashboard snapshot — truthfulness")
struct DossierDashboardSnapshotTruthfulnessTests {

    /// Wait out the coalescing floor (500 ms) plus slack so the
    /// snapshot has provably converged before asserting parity.
    private func quiesce() async throws {
        try await Task.sleep(for: .milliseconds(800))
    }

    /// Assert the snapshot mirrors the orchestrator field-for-field,
    /// including the derived row-state helpers for every prefix the
    /// dashboard could render.
    private func assertParity(_ orch: CaptionOrchestrator,
                              probePrefixes: [String]) {
        let s = orch.dashboardSnapshot.state
        #expect(s.statusIsActive == orch.currentStatus.isActive)
        #expect(s.paused == orch.paused)
        #expect(s.queuePaused == orch.queuePaused)
        #expect(s.currentVolumePrefix == orch.currentVolumePrefix)
        #expect(s.queueDispatchInFlightPrefix == orch.queueDispatchInFlightPrefix)
        #expect(s.queuedVolumePrefixes == orch.queuedVolumePrefixes)
        #expect(s.parkedVolumePrefixes == orch.parkedVolumePrefixes)
        #expect(s.analysisScope == orch.analysisScope)
        #expect(s.activeLanes == orch.activeLanes)
        #expect(s.recentActivity == orch.recentActivity)
        for p in probePrefixes {
            #expect(s.isVolumeAnalyzing(p) == orch.isVolumeAnalyzing(p),
                    "isVolumeAnalyzing(\(p)) diverged")
            #expect(s.queuePosition(of: p) == orch.queuePosition(of: p),
                    "queuePosition(\(p)) diverged")
        }
    }

    @Test("running + queued (#n) + parked + lanes: snapshot equals orchestrator state after quiesce")
    func runningQueuedParkedParity() async throws {
        let model = VideoScanModel()
        let orch = CaptionOrchestrator()
        let a = "/Volumes/SnapA/", b = "/Volumes/SnapB/", c = "/Volumes/SnapC/"

        // Simulate a running batch on A with two volumes lined up and
        // one parked (drive offline), plus an in-flight lane.
        orch.currentStatus = .running(progress: 0.4, currentFile: "x", etaSec: 12)
        orch.currentVolumePrefix = a
        orch.enqueueAnalyze(volumePrefix: b, model: model)
        orch.enqueueAnalyze(volumePrefix: c, model: model)
        orch.parkedVolumePrefixes = [c]
        orch.beginLane(path: a + "clip.mov", filename: "clip.mov",
                       isVideoOnly: false, stage: "MLXVLM", verb: "extracting scenes…")

        try await quiesce()
        assertParity(orch, probePrefixes: [a, b, c, "/Volumes/Nope/"])
        #expect(orch.dashboardSnapshot.state.queuePosition(of: b) == 1)
        #expect(orch.dashboardSnapshot.state.queuePosition(of: c) == 2)
        #expect(orch.dashboardSnapshot.state.isVolumeAnalyzing(a))
        orch.currentStatus = .idle
    }

    @Test("paused and settled states: snapshot follows both flips")
    func pausedAndSettledParity() async throws {
        let orch = CaptionOrchestrator()
        let a = "/Volumes/SnapPause/"
        orch.currentStatus = .running(progress: 0.2, currentFile: "y", etaSec: nil)
        orch.currentVolumePrefix = a
        orch.paused = true
        try await quiesce()
        #expect(orch.dashboardSnapshot.state.isVolumePaused(a))
        assertParity(orch, probePrefixes: [a])

        // Settle: finished batch, pause cleared.
        orch.paused = false
        orch.currentStatus = .finished(captioned: 3, skipped: 1, failed: 0)
        orch.currentVolumePrefix = nil
        try await quiesce()
        #expect(!orch.dashboardSnapshot.state.statusIsActive)
        #expect(!orch.dashboardSnapshot.state.isVolumePaused(a))
        assertParity(orch, probePrefixes: [a])
    }

    @Test("dispatch window (QA F6) reads as analyzing through the snapshot, never 'Queued'")
    func dispatchWindowReadsAnalyzing() async throws {
        let orch = CaptionOrchestrator()
        let a = "/Volumes/SnapWindow/"
        orch.queueDispatchInFlightPrefix = a
        try await quiesce()
        let s = orch.dashboardSnapshot.state
        #expect(s.isVolumeAnalyzing(a))
        #expect(s.queuePosition(of: a) == nil)
        orch.queueDispatchInFlightPrefix = nil
    }

    @Test("NEGATIVE: rapid enqueue→dequeue→enqueue burst converges — the final transition is never lost")
    func transitionBurstConverges() async throws {
        let model = VideoScanModel()
        let orch = CaptionOrchestrator()
        let b = "/Volumes/SnapBurst/"
        orch.currentStatus = .running(progress: 0.1, currentFile: "x", etaSec: nil)

        // All three mutations inside one MainActor turn — faster than
        // any coalescing interval could sample.
        orch.enqueueAnalyze(volumePrefix: b, model: model)
        orch.dequeueAnalyze(volumePrefix: b)
        orch.enqueueAnalyze(volumePrefix: b, model: model)

        try await quiesce()
        #expect(orch.dashboardSnapshot.state.queuePosition(of: b) == 1,
                "final state of the burst (queued #1) must be published")

        // And the inverse: end on EMPTY — the removal must not be
        // swallowed either.
        orch.dequeueAnalyze(volumePrefix: b)
        try await quiesce()
        #expect(orch.dashboardSnapshot.state.queuePosition(of: b) == nil,
                "final state of the burst (dequeued) must be published")
        orch.currentStatus = .idle
    }

    @Test("initial snapshot reflects a queue restored PAUSED at launch — no first-mutation wait")
    func initialSnapshotReflectsRestoredQueue() throws {
        let suiteName = "vs-test-snapshot-restore-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(["/Volumes/R1/", "/Volumes/R2/"],
                     forKey: CaptionOrchestrator.queuedVolumesPrefsKey)

        let orch = CaptionOrchestrator(defaults: defaults)
        // Synchronous: init publishes the restored state itself.
        #expect(orch.dashboardSnapshot.state.queuedVolumePrefixes ==
                ["/Volumes/R1/", "/Volumes/R2/"])
        #expect(orch.dashboardSnapshot.state.queuePaused == true,
                "restored-paused banner state must be visible without waiting for a mutation")
    }

    @Test("publishDashboardSnapshotNow gives direct user intent an immediate echo")
    func immediateEchoForUserIntent() {
        let model = VideoScanModel()
        let orch = CaptionOrchestrator()
        let b = "/Volumes/SnapIntent/"
        orch.currentStatus = .running(progress: 0.1, currentFile: "x", etaSec: nil)

        // The dashboard's intent(_:) wrapper: action + immediate publish.
        orch.enqueueAnalyze(volumePrefix: b, model: model)
        orch.publishDashboardSnapshotNow()
        #expect(orch.dashboardSnapshot.state.queuePosition(of: b) == 1,
                "user click must render this frame, not after the coalescing floor")
        orch.currentStatus = .idle
    }
}
