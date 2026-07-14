// CaptionOrchestrator+Queue.swift
// FIFO volume-analyze queue + analysis-scope mutation.
//
// Rick's design principle (2026-07-13): never make the user WAIT to
// EXPRESS intent. Clicking Analyze on volume B while A is running
// must not be a disabled button — it enqueues B, and when A's batch
// settles (finished OR stopped), B starts automatically. "Analyze
// All" at bedtime, progress by morning.
//
// One verb, one meaning: the row button always says "Analyze". The
// queue is FIFO; a queued row shows "Queued (#n)" with a cancel
// affordance that dequeues without touching anything else.
//
// Persistence: the pending queue survives relaunch via UserDefaults
// (explicit-save pattern — every mutation calls persistQueue()).
// With DossierAutoResume ON the queue resumes on launch (after the
// in-flight volumes recorded in DossierActiveVolumes); with it OFF
// the queue is shown PAUSED — visible, never auto-started, never
// silently dropped.
//
// Stored state (queuedVolumePrefixes / queuePaused / analysisScope /
// queueDispatchInFlight) lives in CaptionOrchestrator.swift — a
// cross-file extension can't add stored properties.

import Foundation
import os

extension CaptionOrchestrator {

    // MARK: - Enqueue / dequeue

    /// The ONE entry point behind the dashboard's per-volume Analyze
    /// button. Idle → starts immediately (via the queue, so ordering
    /// logic has a single path). Busy → appends to the FIFO. Already
    /// queued or currently analyzing this volume → no-op.
    func enqueueAnalyze(volumePrefix: String, model: VideoScanModel) {
        guard !isShuttingDown, !volumePrefix.isEmpty else { return }
        if currentStatus.isActive && currentVolumePrefix == volumePrefix { return }
        guard !queuedVolumePrefixes.contains(volumePrefix) else { return }
        queuedVolumePrefixes.append(volumePrefix)
        persistQueue()
        captionOrchLog.info("Analyze queue: enqueued \(volumePrefix, privacy: .public) (depth \(self.queuedVolumePrefixes.count))")
        appLog.write("Analyze queue: \(VolumeReachability.displayLabel(forPath: volumePrefix)) queued (#\(queuedVolumePrefixes.count))")
        // Clicking Analyze IS explicit intent — a restored-paused
        // queue un-pauses rather than swallowing the click.
        queuePaused = false
        scheduleQueueAdvance(model: model)
    }

    /// Remove a pending volume from the queue (the row's cancel
    /// affordance). Does not touch a running batch — that's Stop.
    func dequeueAnalyze(volumePrefix: String) {
        let before = queuedVolumePrefixes.count
        queuedVolumePrefixes.removeAll { $0 == volumePrefix }
        guard queuedVolumePrefixes.count != before else { return }
        persistQueue()
        captionOrchLog.info("Analyze queue: dequeued \(volumePrefix, privacy: .public)")
        appLog.write("Analyze queue: \(VolumeReachability.displayLabel(forPath: volumePrefix)) removed from queue")
    }

    /// "Analyze All" — enqueue every prefix the dashboard computed as
    /// having remaining eligible work. Skips already-queued/analyzing
    /// prefixes via enqueueAnalyze's own guards.
    func enqueueAnalyzeAll(volumePrefixes: [String], model: VideoScanModel) {
        for prefix in volumePrefixes {
            enqueueAnalyze(volumePrefix: prefix, model: model)
        }
    }

    /// 1-based position of a pending volume ("Queued (#2)"), nil when
    /// not queued.
    func queuePosition(of volumePrefix: String) -> Int? {
        queuedVolumePrefixes.firstIndex(of: volumePrefix).map { $0 + 1 }
    }

    /// Explicit user resume of a paused (restored with AutoResume off)
    /// queue.
    func resumeQueue(model: VideoScanModel) {
        queuePaused = false
        scheduleQueueAdvance(model: model)
    }

    /// Launch-time resume (called from VideoScanApp when
    /// DossierAutoResume is ON). Unifies the two persisted work lists
    /// through the ONE queue path:
    ///   - `activeVolumePrefixes` — volumes that were mid-batch at the
    ///     last quit/crash. They were running, so they resume FIRST
    ///     (prepended, original order preserved).
    ///   - `queuedVolumePrefixes` — volumes the user had queued but
    ///     that never started. They keep their FIFO order after the
    ///     interrupted ones.
    /// The old wiring looped startAnalyzing over the actives directly,
    /// which would have raced the queue's own settle hand-off — two
    /// dispatchers, one busy-guard, silently dropped volumes.
    func resumePersistedWork(model: VideoScanModel) {
        let interrupted = activeVolumePrefixes.sorted()
        for prefix in interrupted.reversed() where !queuedVolumePrefixes.contains(prefix) {
            queuedVolumePrefixes.insert(prefix, at: 0)
        }
        if !interrupted.isEmpty { persistQueue() }
        guard !queuedVolumePrefixes.isEmpty else { return }
        captionOrchLog.info("Analyze queue: resuming persisted work — \(self.queuedVolumePrefixes.count) volume(s) (\(interrupted.count) interrupted)")
        appLog.write("Analyze queue: resuming \(queuedVolumePrefixes.count) volume(s) from last session")
        queuePaused = false
        scheduleQueueAdvance(model: model)
    }

    // MARK: - Advance

    /// Start the queue head if nothing is running. Called from
    /// enqueue/resume AND from startAnalyzing's settle path (so a
    /// batch started by ANY caller — queue, AnalyzeJob, auto-resume —
    /// hands off to the next queued volume when it ends or is
    /// stopped). All checks are synchronous on the MainActor, so the
    /// dequeue is atomic with the dispatch decision.
    func scheduleQueueAdvance(model: VideoScanModel) {
        guard !isShuttingDown, !queuePaused else { return }
        guard !currentStatus.isActive, !queueDispatchInFlight else { return }
        guard !queuedVolumePrefixes.isEmpty else { return }
        let next = queuedVolumePrefixes.removeFirst()
        persistQueue()
        queueDispatchInFlight = true
        captionOrchLog.info("Analyze queue: starting \(next, privacy: .public) (\(self.queuedVolumePrefixes.count) still queued)")
        Task { [weak self, weak model] in
            guard let self else { return }
            guard let model else {
                self.queueDispatchInFlight = false
                return
            }
            await self.startAnalyzing(volumePrefix: next, model: model)
            self.queueDispatchInFlight = false
            // Chain to the next queued volume. startAnalyzing's own
            // settle hook is a no-op while queueDispatchInFlight was
            // still latched, so this is the ONE advance for this hop.
            self.scheduleQueueAdvance(model: model)
        }
    }

    /// Explicit-save persistence — mirrors ScanPerformanceSettings.
    /// No-op in a test host on real defaults (persistenceEnabled).
    func persistQueue() {
        guard persistenceEnabled else { return }
        persistenceDefaults.set(queuedVolumePrefixes, forKey: Self.queuedVolumesPrefsKey)
    }

    // MARK: - Analysis scope

    /// The ONE mutation point for the scope — updates the published
    /// value and does the explicit save (@Observable/@Published kill
    /// didSet-based persistence; see project_settings_persistence).
    func updateAnalysisScope(_ scope: AnalysisScope) {
        guard scope != analysisScope else { return }
        analysisScope = scope
        guard persistenceEnabled else { return }
        scope.save(to: persistenceDefaults)
    }
}

// MARK: - Analyze All candidate selection (pure)

/// Which volume prefixes should "Analyze All" enqueue? Only those
/// with remaining eligible work, minus already-queued and the one
/// currently analyzing. Free function so the dashboard's button stays
/// O(volumes) over CACHED coverage — no records pass, and testable
/// without a view. `activePrefix` is nil when the orchestrator is idle.
nonisolated func pfAnalyzeAllPrefixes(
    remainingByVolume: [(prefix: String, remaining: Int)],
    queued: [String],
    activePrefix: String?
) -> [String] {
    remainingByVolume
        .filter { $0.remaining > 0 }
        .map(\.prefix)
        .filter { $0 != activePrefix && !queued.contains($0) }
}
