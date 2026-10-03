// VideoScanModel+AnalyzeCoverage.swift
// The model-owned coverage cache behind the Analyze panel and the Catalog
// toolbar's Analyze menu (Phase A trial, 2026-10-02).
//
// Pattern = VolumeDashboard / UserPlaceRoster: ONE main-actor projection
// pass over `records` (Sendable rows), the arithmetic in a detached task,
// the result published through a tiny equality-gated ObservableObject
// that the two views observe INSTEAD of the model (the 2026-07-14
// render-loop lesson — see DossierDashboardSnapshot.swift). It rides the
// debounced catalog-change pass `refreshDossierCountsNow()` already runs,
// so a scan's stream of appends is one recompute.
//
// NO O(records) work in any view body: the menu and the panel read
// `analyzeCoverageSnapshot.report` and nothing else.

import Foundation
import Combine

/// The views' ONLY observed dependency for coverage. Publishing an
/// unchanged report is a no-op (zero invalidation).
@MainActor
final class AnalyzeCoverageSnapshot: ObservableObject {
    @Published private(set) var report = AnalyzeCoverageReport()
    /// Test hook: how many computes actually landed.
    private(set) var publishCount = 0

    func publish(_ new: AnalyzeCoverageReport) {
        guard new != report else { return }
        publishCount += 1
        report = new
    }
}

extension VideoScanModel {

    /// Project on the main actor, compute off it, publish once. A newer
    /// call cancels the in-flight one. (`Task.detached` ≈ a worker thread
    /// that does NOT inherit the caller's actor; only Sendable values cross.)
    func scheduleAnalyzeCoverageRefresh() {
        analyzeCoverageTask?.cancel()
        let inputs = AnalyzeCoverageCalculator.project(records)
        let volumes = AnalyzeCoverageCalculator.volumeFacts(scanTargets)
        let scope = analyzeCoverageScope
        analyzeCoverageTask = Task { [weak self] in
            let report = await Task.detached(priority: .utility) {
                AnalyzeCoverageCalculator.compute(inputs: inputs,
                                                  volumes: volumes,
                                                  mountedRoots: VolumeReachability.currentMountedRoots(),
                                                  scope: scope)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.analyzeCoverageSnapshot.publish(report)
        }
    }
}
