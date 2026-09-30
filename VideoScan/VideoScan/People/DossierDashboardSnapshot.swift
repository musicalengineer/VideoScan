// DossierDashboardSnapshot.swift
// The dashboard's ONE observed object — the render-loop fix
// (perf/dashboard-render, 2026-07-14).
//
// Problem this solves: DossierDashboardView used to observe BOTH
// CaptionOrchestrator and VideoScanModel wholesale via
// @EnvironmentObject. Every @Published write on either object — a
// per-record `liveSkipped += 1` during a skip storm, 4–6 lane
// mutations per file, any catalog churn — invalidated the entire
// dashboard body. Over a 9.8 h batch that cost 6.2 CPU-hours on the
// MainActor and starved the orchestrator's inter-file hops (median
// 3.4 s gap between files).
//
// Fix: the VolumeStatusCache pattern (see
// VideoScanModel+VolumeStatusCache.swift — the 2026-07-05 Volumes-
// window beachball fix), applied to observation instead of
// computation. The orchestrator copies its dashboard-visible state
// into ONE Equatable value struct at ≤2 Hz; the dashboard observes
// ONLY this snapshot. Hot counters (liveCurrentIndex, liveSkipped, …)
// stay @Published for the progress sheet but no longer touch the
// dashboard's view graph at all.
//
// Truthfulness contract (batch-ux queue UI): every dashboard-visible
// state — running / Queued (#n) / parked / paused / settled — is
// carried in the snapshot, converges to the orchestrator's direct
// state within ≤500 ms of quiesce, and the FINAL state of any burst
// is always published (the coalescer is trailing-edge, never lossy).
// DossierDashboardSnapshotTests pins both directions.
//
// Worst-case memory footprint: two copies (current + in-flight
// publish) of ≤2 PipelineLane + ≤8 CompletedActivity structs plus the
// queue string arrays — well under 64 KB. No per-record state.

import Foundation
import Combine

// MARK: - Snapshot state (Equatable value struct)

/// Everything the Dossier Dashboard renders from the orchestrator,
/// as plain values. Equatable so the snapshot object can drop no-op
/// publishes — an update tick that changed nothing sends nothing.
/// (Value struct + Equatable gate ≈ C++ "copy out under the lock,
/// compare, notify only on diff".)
struct DossierDashboardState: Equatable {

    /// `currentStatus.isActive` — a batch is running or cancelling.
    var statusIsActive: Bool = false
    /// The per-volume Pause button's state (in-flight work drains).
    var paused: Bool = false
    /// True when a persisted queue was restored with Resume on Launch
    /// OFF — drives the "waiting from last session" banner.
    var queuePaused: Bool = false
    /// Volume the active batch is processing (nil when idle).
    var currentVolumePrefix: String?
    /// Volume in the dequeue→batch-start hand-off window (QA F6) —
    /// must read as "analyzing", never "Queued".
    var queueDispatchInFlightPrefix: String?
    /// FIFO of volumes waiting their turn ("Queued (#n)" rows).
    var queuedVolumePrefixes: [String] = []
    /// Queued volumes whose drive is offline — the parked banner.
    var parkedVolumePrefixes: Set<String> = []
    /// What kinds of files Analyze spends GPU time on (scope toggle).
    var analysisScope: AnalysisScope = AnalysisScope()
    /// "Now Analyzing" lanes (≤2 by pipeline design).
    var activeLanes: [PipelineLane] = []
    /// "Recently Completed" history (≤ recentActivityCap).
    var recentActivity: [CompletedActivity] = []

    // MARK: Derived row state
    //
    // These mirror CaptionOrchestrator.isVolumeAnalyzing /
    // queuePosition(of:) EXACTLY — same definitions, computed from the
    // snapshotted values — so a row rendered from the snapshot can
    // never disagree with the orchestrator once the snapshot has
    // converged. DossierDashboardSnapshotTests asserts the parity.

    /// Mirror of `CaptionOrchestrator.isVolumeAnalyzing(_:)`.
    func isVolumeAnalyzing(_ volumePrefix: String) -> Bool {
        if queueDispatchInFlightPrefix == volumePrefix { return true }
        return statusIsActive && currentVolumePrefix == volumePrefix
    }

    /// Mirror of `CaptionOrchestrator.queuePosition(of:)` (1-based).
    func queuePosition(of volumePrefix: String) -> Int? {
        queuedVolumePrefixes.firstIndex(of: volumePrefix).map { $0 + 1 }
    }

    /// Paused state is per-volume in the UI (the yellow dot on the row
    /// whose batch is paused).
    func isVolumePaused(_ volumePrefix: String) -> Bool {
        paused && currentVolumePrefix == volumePrefix
    }
}

// MARK: - Snapshot object (the dashboard's ONLY observed dependency)

/// Tiny ObservableObject wrapper: one @Published value, equality-gated.
/// The orchestrator owns the instance and is the only writer.
@MainActor
final class DossierDashboardSnapshot: ObservableObject {

    @Published private(set) var state = DossierDashboardState()

    /// Equality gate: publishing an unchanged state is a no-op — zero
    /// objectWillChange, zero view invalidation. This is what makes
    /// the ≤2 Hz refresh free when nothing moved.
    func publish(_ new: DossierDashboardState) {
        guard new != state else { return }
        state = new
    }
}

// MARK: - Orchestrator → snapshot publication (≤2 Hz, trailing-edge)

extension CaptionOrchestrator {

    /// Snapshot refresh floor — 500 ms → ≤2 publishes/s reach the
    /// dashboard no matter how fast the orchestrator's own @Published
    /// state churns. The publish-rate sensor test pins this.
    static let dashboardSnapshotMinInterval: CFAbsoluteTime = 0.5

    /// Wire the coalesced forwarder. Called ONCE at the end of init.
    /// objectWillChange fires synchronously BEFORE each mutation; the
    /// scheduled refresh Task runs on a LATER MainActor turn, so it
    /// always reads post-mutation state. Also publishes the initial
    /// state so a queue restored paused at launch is visible
    /// immediately, not after the first mutation.
    func wireDashboardSnapshot() {
        dashboardSnapshotForwarder = objectWillChange.sink { [weak self] _ in
            self?.noteDashboardSnapshotDirty()
        }
        publishDashboardSnapshotNow()
    }

    /// Copy the dashboard-visible state into a value struct. Cheap:
    /// two small array copies + a set copy, no records work.
    func currentDashboardState() -> DossierDashboardState {
        var s = DossierDashboardState()
        s.statusIsActive = currentStatus.isActive
        s.paused = paused
        s.queuePaused = queuePaused
        s.currentVolumePrefix = currentVolumePrefix
        s.queueDispatchInFlightPrefix = queueDispatchInFlightPrefix
        s.queuedVolumePrefixes = queuedVolumePrefixes
        s.parkedVolumePrefixes = parkedVolumePrefixes
        s.analysisScope = analysisScope
        s.activeLanes = activeLanes
        s.recentActivity = recentActivity
        return s
    }

    /// Immediate publish — used at init, and by the dashboard's action
    /// closures so direct user intent (Analyze / Remove from Line /
    /// scope toggle) echoes without waiting out the coalescing floor.
    /// Resets the interval clock so burst publishes stay bounded.
    func publishDashboardSnapshotNow() {
        lastDashboardSnapshotPublishAt = CFAbsoluteTimeGetCurrent()
        dashboardSnapshot.publish(currentDashboardState())
    }

    /// Coalesced refresh: any orchestrator publish marks the snapshot
    /// dirty; ONE trailing Task delivers the latest state no earlier
    /// than `dashboardSnapshotMinInterval` after the previous publish.
    /// Guarantees: ≤2 Hz to observers, AND the last event of any burst
    /// always lands (trailing-edge — a transition can be delayed up to
    /// 500 ms but never lost). When the orchestrator has been quiet
    /// the delay collapses to ~1 ms, so isolated transitions publish
    /// effectively immediately.
    func noteDashboardSnapshotDirty() {
        guard !dashboardSnapshotRefreshScheduled else { return }
        dashboardSnapshotRefreshScheduled = true
        let elapsed = CFAbsoluteTimeGetCurrent() - lastDashboardSnapshotPublishAt
        let delay = max(0.001, Self.dashboardSnapshotMinInterval - elapsed)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self else { return }
            self.dashboardSnapshotRefreshScheduled = false
            self.publishDashboardSnapshotNow()
        }
    }
}
