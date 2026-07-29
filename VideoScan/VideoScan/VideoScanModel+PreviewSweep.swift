// VideoScanModel+PreviewSweep.swift
// Background preview sweep, Phase 1 (2026-07-27) — the model glue.
//
// Owns nothing itself (stored properties live in VideoScanModel.swift:
// `previewSweep` + `previewSweepSettings`); this file wires the service's
// injected closures to the model and hosts the settings toggle handler.
// The sweep machinery proper is PreviewSweepService/PreviewSweepPlan.

import Foundation
import VideoScanCore

extension VideoScanModel {

    /// Wire the sweep service to this model. Called once at the end of
    /// init; also the launch-resume path — when the persisted setting is
    /// ON, the catalog signal below starts the sweep (debounced) without
    /// any re-checking. All model captures are weak: the model owns the
    /// service, so a strong closure capture would be a retain cycle
    /// (for Rick: shared_ptr cycle through the callback).
    func configurePreviewSweep() {
        // Stage 2: build the detached-helper coordinator (unless under a
        // test host — it must never spawn a real process). Do this BEFORE
        // configuring the in-process service so the coexistence gate below
        // can consult it.
        buildPreviewHelperCoordinator()

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
                guard let self else { return false }
                // COEXISTENCE RULE (Stage 2): the DETACHED external helper
                // is the primary prewarmer whenever it's alive — the app's
                // in-process sweep stands down (parks + re-polls) so the two
                // never fight for the same caches or the same spindle. When
                // the helper self-exits (cache warm), this clears and the
                // in-process sweep resumes as the fallback.
                if self.isPreviewHelperRunning { return true }
                // The volume-click precacher is filling the very same
                // caches at .utility priority (it runs BECAUSE the user
                // clicked a volume). Defer the whole sweep while it runs;
                // when it stops, the next pacing poll proceeds and covers
                // ALL remaining records.
                return self.thumbnailPrecacher.isRunning
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

        // Stage 2 launch hook: if the flag is ON and no live helper already
        // owns the pidfile, spawn a detached one now (survives quit;
        // respawned on the next launch after a reboot).
        previewHelperCoordinator?.handle(
            event: .launch, enabled: previewSweepSettings.enabled)
    }

    /// Settings checkbox handler: persist + start/stop BOTH the detached
    /// helper (primary) and the in-process service (fallback). The helper
    /// is the one that survives quit; the in-process service parks while it
    /// runs (see the coexistence rule above).
    /// (@Published kills didSet — explicit save, CatalogScopeSettings
    /// pattern.)
    func setPreviewSweepEnabled(_ on: Bool) {
        previewSweepSettings.enabled = on
        savePreviewSweepSettings()
        // Detached helper first (spawn on / SIGTERM off).
        previewHelperCoordinator?.handle(event: on ? .toggleOn : .toggleOff,
                                         enabled: on)
        // In-process service tracks the flag too; while the helper is
        // running its sweep parks via isExternallyBusy, so this is the
        // fallback path for when the helper can't run or has self-exited.
        previewSweep.setEnabled(on)
    }

    // MARK: - Detached helper (Stage 2)

    /// Is a LIVE external helper currently holding the pidfile? Reads the
    /// tiny pidfile + one kill(pid,0) — cheap enough for the coexistence
    /// gate's per-poll sampling. False under a test host (no coordinator).
    var isPreviewHelperRunning: Bool {
        previewHelperCoordinator?.isHelperRunning ?? false
    }

    /// Construct the coordinator with production dependencies: the
    /// posix_spawn launcher, the bundle/dev binary locator, the pidfile
    /// running-probe, and the helper's watch/idle-exit arguments. Skipped
    /// under a test host so the ~200 model-constructing unit tests never
    /// spawn a process or touch the real pidfile.
    private func buildPreviewHelperCoordinator() {
        guard !TestEnvironment.isTestHost else {
            previewHelperCoordinator = nil
            return
        }
        let launcher = PosixSpawnHelperLauncher()
        let pidfileURL = PreviewHelperPaths.pidfileURL()
        let logURL = PreviewHelperPaths.logURL()
        let catalogPath = PreviewSweepCLIOptions.defaultCatalogURL().path
        previewHelperCoordinator = PreviewHelperCoordinator(
            spawner: launcher,
            stopper: launcher,
            runningPID: { PreviewHelperInstance.runningPID(pidfileURL: pidfileURL) },
            executableProvider: { try PreviewHelperLocator.resolve() },
            arguments: {
                // --watch with a per-file re-check interval; --idle-exit
                // lets the detached helper retire once the cache is warm
                // and the catalog is quiet (see HelperIdleExitPolicy).
                ["--watch",
                 "--catalog", catalogPath,
                 "--interval", "30",
                 "--idle-exit", "300"]
            },
            logFileURL: logURL,
            log: { appLog.write($0) })
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
