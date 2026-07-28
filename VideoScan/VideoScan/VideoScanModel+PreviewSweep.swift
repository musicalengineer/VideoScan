// VideoScanModel+PreviewSweep.swift
// Background preview sweep, Phase 1 (2026-07-27) — the model glue.
//
// Owns nothing itself (stored properties live in VideoScanModel.swift:
// `previewSweep` + `previewSweepSettings`); this file wires the service's
// injected closures to the model and hosts the settings toggle handler.
// The sweep machinery proper is PreviewSweepService/PreviewSweepPlan.

import Foundation

extension VideoScanModel {

    /// Wire the sweep service to this model. Called once at the end of
    /// init; also the launch-resume path — when the persisted setting is
    /// ON, the catalog signal below starts the sweep (debounced) without
    /// any re-checking. All model captures are weak: the model owns the
    /// service, so a strong closure capture would be a retain cycle
    /// (for Rick: shared_ptr cycle through the callback).
    func configurePreviewSweep() {
        previewSweep.configure(PreviewSweepService.Configuration(
            diskCache: previewDiskCache,
            failureStore: thumbnailFailureStore,
            candidates: { [weak self] in self?.previewSweepCandidates() ?? [] },
            shouldSkipPathNow: { [weak self] path in
                // NARROW per-path skip ONLY: leave a path alone while the
                // model's single filmstrip task is actively ripping it
                // (never rip the same master twice). Deferred, not lost.
                // The precacher-running stand-down is `isExternallyBusy`
                // below — a PARK, not a per-path skip — because a
                // predicate true for every path would make the sweep
                // consume its whole plan as skips and report done with
                // the catalog uncovered (QA MAJOR-1, 2026-07-27).
                self?.filmstripTaskPath == path
            },
            isExternallyBusy: { [weak self] in
                // The volume-click precacher is filling the very same
                // caches at .utility priority (it runs BECAUSE the user
                // clicked a volume). Defer the whole sweep while it runs;
                // when it stops, the next pacing poll proceeds and covers
                // ALL remaining records.
                self?.thumbnailPrecacher.isRunning ?? false
            },
            isReachable: { VolumeReachability.isReachable(path: $0) },
            thermalState: { ProcessInfo.processInfo.thermalState },
            executeItem: PreviewSweepService.defaultExecutor(
                diskCache: previewDiskCache,
                isReachable: { VolumeReachability.isReachable(path: $0) })
        ), enabled: previewSweepSettings.enabled)

        // Launch resume: records were restored before this call (didSet
        // doesn't fire inside init), so hand the service its first
        // catalog signal explicitly. No-op while disabled.
        previewSweep.noteCatalogChanged()
    }

    /// Settings checkbox handler: persist + start/stop the service.
    /// (@Published kills didSet — explicit save, CatalogScopeSettings
    /// pattern.)
    func setPreviewSweepEnabled(_ on: Bool) {
        previewSweepSettings.enabled = on
        savePreviewSweepSettings()
        previewSweep.setEnabled(on)
    }

    /// Sendable snapshot of the records the sweep should cover:
    /// video-bearing (same streamType rule as ThumbnailPrecachePlanner —
    /// only shapes that can yield a frame), reachable volumes only.
    /// One O(records) pass per (debounced) plan build on the main actor
    /// — a few ms at 17k, never in a view body. Failure-store filtering
    /// happens off-main in the service (it stats per check).
    func previewSweepCandidates() -> [PreviewSweepCandidate] {
        records.compactMap { rec in
            guard rec.streamType == .videoOnly || rec.streamType == .videoAndAudio,
                  VolumeReachability.isReachable(path: rec.fullPath) else {
                return nil
            }
            return PreviewSweepCandidate(path: rec.fullPath,
                                         container: rec.container,
                                         videoCodec: rec.videoCodec,
                                         likelyUnanalyzable: rec.isLikelyUnanalyzable,
                                         durationSeconds: rec.durationSeconds)
        }
    }
}
