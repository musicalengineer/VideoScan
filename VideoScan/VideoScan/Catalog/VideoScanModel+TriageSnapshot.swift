// VideoScanModel+TriageSnapshot.swift
// The model-owned cache behind the Triage tab (2026-10-03). See
// TriageSnapshot.swift for why and for the pure builder.
//
// When it runs:
//   * only while a Triage tab is on screen (`triageViewAppeared` /
//     `triageViewDisappeared` — a launch that never opens Triage pays
//     nothing, and leaving the tab drops the rows);
//   * 250 ms after the first of a burst of catalog changes (the funnels
//     every mutation already passes through: `noteCatalogMutated` and
//     `noteCatalogChangedForDossierCounts`) — a Delete Duplicates run's
//     stream of per-file changes is at most four rebuilds a second, each
//     one projection pass on the main actor and the rest off it;
//   * at once (still off-main) when the person changes the filter, the
//     search, the sort or "Online volumes only", and after an edit made in
//     the tab itself.
//
// A newer build cancels the one in flight; a build that finishes late
// never publishes (generation stamp).
//
// (For Rick: `Task.detached` ≈ a worker thread that does NOT inherit the
// caller's actor; only Sendable values cross.)

import Foundation
import VideoScanCore

extension VideoScanModel {

    var triageWanted: Bool { triageViewers > 0 }

    // MARK: On screen / off screen

    /// A Triage tab is on screen: start keeping its snapshot current.
    /// Counted, not a flag — switching between the two tab slots that show
    /// Triage can deliver the new view's appear before the old one's
    /// disappear.
    func triageViewAppeared(query: TriageQuery) {
        triageViewers += 1
        triageQuery = query
        refreshTriageSnapshotNow()
    }

    /// It left the screen: stop, and let the rows go.
    func triageViewDisappeared() {
        triageViewers = max(0, triageViewers - 1)
        guard !triageWanted else { return }
        triageTask?.cancel()
        triageTask = nil
        triageGeneration &+= 1
        triageProjection = nil
        triageCatalogDirty = false
        triageSnapshot.reset()
    }

    // MARK: Triggers

    /// The filter / search / sort / online-only / steward narrowing changed.
    /// The projection is reused — only the build runs again.
    func setTriageQuery(_ query: TriageQuery) {
        guard query != triageQuery else { return }
        triageQuery = query
        guard triageWanted else { return }
        startTriageBuild(priority: .userInitiated)
    }

    /// Debounced invalidation — cheap enough to call from per-record
    /// loops (one Bool test while Triage is off screen). Coalesces a burst
    /// into ONE rebuild 250 ms later.
    func noteTriageCatalogChanged() {
        guard triageWanted else { return }
        triageCatalogDirty = true
        guard !triageRefreshScheduled else { return }
        triageRefreshScheduled = true
        let delay = Self.triageDebounceNanos(lastProjectionNanos: triageLastProjectionNanos)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self else { return }
            self.triageRefreshScheduled = false
            // An immediate refresh in the meantime already covered it.
            guard self.triageWanted, self.triageCatalogDirty else { return }
            self.refreshTriageSnapshotNow(priority: .utility)
        }
    }

    /// How long a burst of catalog changes is gathered before ONE rebuild:
    /// 250 ms, stretched to ten times the last projection pass when that
    /// is longer — so during a long run the main-actor step stays under
    /// about a tenth of the main thread however large the catalog is
    /// (measured, Debug: ~2 µs a record → 100k records = one rebuild per
    /// ~2 s instead of four a second). Capped at 5 s. Pure.
    nonisolated static func triageDebounceNanos(lastProjectionNanos: UInt64) -> UInt64 {
        let floor: UInt64 = 250_000_000
        let ceiling: UInt64 = 5_000_000_000
        let (stretched, overflow) = lastProjectionNanos.multipliedReportingOverflow(by: 10)
        return overflow ? ceiling : min(ceiling, max(floor, stretched))
    }

    /// Re-project and rebuild now (the build itself is still off-main).
    /// Called after an edit made in the Triage tab, so its own change shows
    /// without waiting out the debounce.
    func refreshTriageSnapshotNow(priority: TaskPriority = .userInitiated) {
        guard triageWanted else { return }
        triageProjection = nil
        triageCatalogDirty = false
        startTriageBuild(priority: priority)
    }

    /// A drive came or went (or a background probe corrected an answer):
    /// repaint the offline italics, and re-filter if "Online volumes only"
    /// is on.
    func noteTriageReachabilityChanged() {
        guard triageWanted else { return }
        triageSnapshot.noteReachabilityChanged()
        if triageQuery.onlineOnly { startTriageBuild(priority: .userInitiated) }
    }

    // MARK: The build

    private func startTriageBuild(priority: TaskPriority) {
        triageTask?.cancel()
        triageGeneration &+= 1
        let generation = triageGeneration
        let projection: TriageProjection
        if let cached = triageProjection {
            projection = cached
        } else {
            let started = DispatchTime.now().uptimeNanoseconds
            projection = TriageSnapshotBuilder.project(records)
            triageLastProjectionNanos = DispatchTime.now().uptimeNanoseconds &- started
            triageProjection = projection
            triageProjectionCount += 1
        }
        let query = triageQuery
        let previous = triageSnapshot.value
        let reachable = triageReachability
        triageTask = Task.detached(priority: priority) { [weak self] in
            guard let value = TriageSnapshotBuilder.build(projection, query: query, reachable: reachable,
                                                          isCancelled: { Task.isCancelled }) else { return }
            // Compared here, off the main thread.
            let changed = value != previous
            guard changed, !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.triageGeneration == generation, self.triageWanted else { return }
                self.triageSnapshot.publish(value, knownDifferent: true)
            }
        }
    }

    // MARK: Click-time record lookups (event handlers only — never a view body)

    /// Every record in Triage's scope, in catalog order ("Analyze All").
    func triageScopeRecords() -> [VideoRecord] {
        TriageSnapshotBuilder.triageScope(records)
    }

    /// The Delete Junk button's target: Confirmed Junk within Triage's scope.
    func triageConfirmedJunkRecords() -> [VideoRecord] {
        triageScopeRecords().filter { $0.mediaDisposition == .confirmedJunk }
    }

    /// The selection, resolved through the id index — O(selection).
    func triageRecords(withIDs ids: Set<UUID>) -> [VideoRecord] {
        ids.compactMap { record(forID: $0) }
    }
}
