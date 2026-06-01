import Foundation

// MARK: - Scan Lifecycle (start / stop / pause / resume)
//
// Per-target lifecycle controls plus their bulk "all targets" siblings.
// These are the small orchestration verbs the UI calls — the heavy
// runScanForTarget probe loop and its helpers live in
// VideoScanModel+ScanExecution.swift. The split keeps the lifecycle file
// small enough to read at a glance while the execution file holds the
// scary stuff (async groups, semaphores, RAM disks).

extension VideoScanModel {

    func startTarget(_ target: CatalogScanTarget) {
        guard !target.searchPath.isEmpty else { return }
        // §1B: retired volumes are off-limits for rescan. The destructive
        // bit is the `records.removeAll` line below — it would wipe the
        // Bucket-E `.manuallyDeleted` witness records that ARE the
        // retire audit trail. The user has to Reinstate first via the
        // Volumes window if they really want to re-scan.
        guard !target.isRetired else {
            log("--- Scan refused: \(URL(fileURLWithPath: target.searchPath).lastPathComponent) is retired. Reinstate via Volumes window to enable scanning. ---")
            return
        }
        if let missing = DependencyChecker.checkScan() {
            missingDependency = missing
            log("--- Scan blocked: \(missing.displayName) not installed (\(missing.installHint)) ---")
            return
        }
        // Clear any stale checkpoint — this is a fresh scan.
        ScanCheckpointStorage.delete(for: target.searchPath)
        // Clear any existing catalog records for this volume so a rescan
        // doesn't create duplicates. The cache is kept (probes are reused).
        records.removeAll { $0.fullPath.hasPrefix(target.searchPath) }
        target.status = .scanning
        target.filesFound = 0
        target.filesScanned = 0
        target.startElapsedTimer()

        // Track global scanning state. Only reset the dashboard + start the
        // throughput timer when this is the *first* active target — otherwise
        // we'd wipe progress from a sibling target that's already running.
        let isFirstActive = !scanTargets.contains { $0.id != target.id && $0.status.isActive }
        if isFirstActive {
            dashboard.resetForScan()
            dashboard.scanPhase = .discovering
            dashboard.startThroughputTimer()
        }
        isScanning = true

        target.scanTask = Task {
            await runScanForTarget(target)
        }
    }

    func stopTarget(_ target: CatalogScanTarget) {
        target.scanTask?.cancel()
        target.scanTask = nil
        Task { await target.pauseGate.resume() }
        target.stopElapsedTimer()
        target.status = .stopped
        log("--- Scan stopped for \(URL(fileURLWithPath: target.searchPath).lastPathComponent) ---")
        updateGlobalScanState()
    }

    func togglePauseTarget(_ target: CatalogScanTarget) {
        if target.status == .paused {
            Task { await target.pauseGate.resume() }
            target.status = .scanning
            log("--- Resumed \(URL(fileURLWithPath: target.searchPath).lastPathComponent) ---")
        } else if target.status == .scanning {
            Task { await target.pauseGate.pause() }
            target.status = .paused
            log("--- Paused \(URL(fileURLWithPath: target.searchPath).lastPathComponent) ---")
        }
        updateDashboardPauseState()
    }

    /// Update dashboard.scanPhase to reflect paused state when all active
    /// targets are paused, and restore to .probing when any target resumes.
    fileprivate func updateDashboardPauseState() {
        let active = scanTargets.filter { $0.status.isActive }
        guard !active.isEmpty else { return }
        let allPaused = active.allSatisfy { $0.status == .paused }
        if allPaused && dashboard.scanPhase == .probing {
            dashboard.scanPhase = .paused
        } else if !allPaused && dashboard.scanPhase == .paused {
            dashboard.scanPhase = .probing
        }
    }

    func startAllTargets() {
        // Check deps once up-front rather than repeating per-target —
        // otherwise startTarget would set missingDependency for each
        // volume, which is the same dialog over and over.
        if let missing = DependencyChecker.checkScan() {
            missingDependency = missing
            log("--- Scan blocked: \(missing.displayName) not installed (\(missing.installHint)) ---")
            return
        }
        for target in scanTargets where target.status.isIdle || target.status == .stopped {
            guard !target.searchPath.contains("VideoScan_Temp") else { continue }
            guard target.isReachable else { continue }
            // §1B: skip retired volumes. They're not coming back; the
            // catalog already has whatever they held. Reinstate (via the
            // Volumes window context menu) re-includes them.
            guard !target.isRetired else { continue }
            startTarget(target)
        }
    }

    func stopAllTargets() {
        for target in scanTargets where target.status.isActive {
            stopTarget(target)
        }
    }

    func pauseAllTargets() {
        for target in scanTargets where target.status == .scanning {
            togglePauseTarget(target)
        }
    }

    func resumeAllTargets() {
        for target in scanTargets where target.status == .paused {
            togglePauseTarget(target)
        }
    }

    var hasActiveTargets: Bool { scanTargets.contains { $0.status.isActive } }
    var hasPausedTargets: Bool { scanTargets.contains { $0.status == .paused } }

    // Internal — also called by ScanExecution.finalizeSingleTargetScan and
    // ScanExecution's verify path after they update target.status.
    func updateGlobalScanState() {
        isScanning = scanTargets.contains { $0.status.isActive }
    }
}
