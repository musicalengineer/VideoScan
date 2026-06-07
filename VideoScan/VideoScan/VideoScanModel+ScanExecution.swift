import Foundation

// MARK: - Scan Execution (orchestration around the probe engine)
//
// The "what runs when a target is scanning" verbs — runScanForTarget,
// resumeTarget, detectResumableTargets — plus the per-file orchestration
// helpers (probeAndRecord, processTargetProbeResult, finalizeSingleTargetScan,
// mountScanRAMDiskIfNeeded, logTargetScanSummary).
//
// The lowest level — the actual streaming walker, the probe group task
// machinery, the per-file probeFile/probeFileWithTimeout, and the RAM
// prefetch — lives one floor down in VideoScanModel+ProbeEngine.swift.
//
// This file is "the recipe"; ProbeEngine is "the kitchen tools".

extension VideoScanModel {

    /// Probe a single URL and update the dashboard counters for one volume.
    /// Extracted from `runScanForTarget` / `runParallelScan` so the big scan
    /// methods stay below the SwiftLint function-body ceiling. Returns the
    /// resulting VideoRecord — a `StreamType.ffprobeFailed` placeholder when
    /// the task is cancelled.
    ///
    /// - Parameter useTimeout: true → `probeFileWithTimeout` (per-target scan),
    ///   false → `probeFile` (parallel multi-root scan).
    /// - Parameter echoFilename: true → log `[vol] filename` before probing
    ///   (matches the old parallel-scan UX).
    func probeAndRecord(
        url: URL,
        volName: String,
        root: String,
        rootIsNetwork: Bool,
        ramMountPoint: String?,
        skipHashing: Bool,
        useTimeout: Bool,
        echoFilename: Bool
    ) async -> VideoRecord {
        if Task.isCancelled {
            return await MainActor.run {
                let skip = VideoRecord()
                skip.filename = url.lastPathComponent
                skip.streamTypeRaw = StreamType.ffprobeFailed.rawValue
                return skip
            }
        }
        await MainActor.run {
            if echoFilename {
                self.log("  [\(volName)] \(url.lastPathComponent)")
            }
            self.dashboard.recordScanFile(volume: volName, filename: url.lastPathComponent)
        }
        let rec: VideoRecord
        if useTimeout {
            rec = await self.probeFileWithTimeout(
                url: url,
                prefetchToRAM: rootIsNetwork,
                ramPath: ramMountPoint,
                skipHashing: skipHashing,
                scanRootPath: root
            )
        } else {
            rec = await self.probeFile(
                url: url,
                prefetchToRAM: rootIsNetwork,
                ramPath: ramMountPoint,
                skipHashing: skipHashing,
                scanRootPath: root
            )
        }
        await MainActor.run {
            let ds = self.dashboard
            ds.scanCompleted += 1
            if let idx = ds.volumeProgress.firstIndex(where: { $0.rootPath == root }) {
                ds.volumeProgress[idx].completedFiles += 1
                if rec.wasCacheHit {
                    ds.volumeProgress[idx].cacheHits += 1
                }
                if rec.streamTypeRaw == StreamType.ffprobeFailed.rawValue {
                    ds.volumeProgress[idx].errors += 1
                }
            }
            if rec.wasCacheHit {
                ds.scanCacheHits += 1
            } else {
                ds.scanCacheMisses += 1
            }
            if rec.streamTypeRaw == StreamType.ffprobeFailed.rawValue {
                ds.scanErrors += 1
            }
            ds.liveStreamCounts[rec.streamTypeRaw, default: 0] += 1
        }
        return rec
    }

    /// Process one probe result inside the per-target scan loop.
    /// Returns true if the caller should break (abort threshold tripped).
    func processTargetProbeResult(
        rec: VideoRecord,
        volName: String,
        completedCount: Int,
        totalFiles: Int,
        target: CatalogScanTarget,
        consecutiveNotAccessible: inout Int,
        loggedMilestones: inout Set<Int>,
        milestones: Set<Int>,
        abortAfter: Int
    ) -> Bool {
        if rec.streamTypeRaw == StreamType.ffprobeFailed.rawValue {
            let detail = rec.notes.isEmpty ? "no detail available" : rec.notes
            log("  ⚠ FAILED: \(rec.filename) — \(detail)")
            if rec.isPlayable == "File not found" {
                consecutiveNotAccessible += 1
                if consecutiveNotAccessible >= abortAfter {
                    log("  ⛔ \(abortAfter) consecutive files inaccessible on \(volName) — volume likely unmounted. Aborting remaining probes.")
                    return true
                }
            } else {
                consecutiveNotAccessible = 0
            }
        } else {
            consecutiveNotAccessible = 0
        }
        let pct = totalFiles > 0 ? (completedCount * 100 / totalFiles) : 100
        let shouldUpdate = completedCount % 20 == 0 || completedCount == totalFiles
            || (milestones.contains(pct) && !loggedMilestones.contains(pct))
        if shouldUpdate {
            if milestones.contains(pct) { loggedMilestones.insert(pct) }
            target.filesScanned = completedCount
            log("  [\(volName)] \(completedCount)/\(totalFiles) (\(pct)%)")
        }
        return false
    }

    /// Post-scan bookkeeping for a single-target scan: unmount, persist,
    /// update target + dashboard state. Extracted from `runScanForTarget`.
    fileprivate func finalizeSingleTargetScan(
        target: CatalogScanTarget,
        volName: String,
        targetRecords: [VideoRecord],
        completedCount: Int,
        discoveredCount: Int,
        rootIsNetwork: Bool
    ) async {
        target.filesScanned = completedCount
        if discoveredCount == 0 {
            log("  No video files found on \(volName).")
            appLog.write("Completed catalog scan of volume \(volName): no video files found")
            if rootIsNetwork { await ramDisk.unmount() }
            target.status = .complete
            target.lastScannedDate = Date()
            target.stopElapsedTimer()
            updateGlobalScanState()
            return
        }
        if rootIsNetwork { await ramDisk.unmount() }
        if Task.isCancelled {
            target.status = .stopped
            target.stopElapsedTimer()
            // Drop the rescan snapshot so the map doesn't grow unbounded.
            // Today this means a cancelled rescan loses the volume's
            // records until next scan (pre-existing behavior — startTarget
            // already removed them). A future improvement could re-insert
            // originals from a full-record snapshot. For now: discard.
            discardPreservedFieldsSnapshot(of: target)
            appLog.write("Cancelled catalog scan of volume \(volName) at \(completedCount)/\(discoveredCount) file(s)")
            updateGlobalScanState()
            return
        }
        // Restore dossier + user-edit fields snapshotted in startTarget
        // before the rescan's removeAll. Without this, every rescan
        // would silently destroy hours of Qwen + Whisper work and any
        // manual people tags. Returns the count restored for logging.
        let restored = applyPreservedFieldsAfterRescan(of: target, onto: targetRecords)
        if restored > 0 {
            appLog.write("Rescan preservation: restored dossier+user fields onto \(restored) of \(targetRecords.count) freshly-scanned records on \(volName)")
        }
        records.append(contentsOf: targetRecords)
        saveCatalogDebounced()
        ScanCheckpointStorage.delete(for: target.searchPath)
        logTargetScanSummary(volName: volName, records: targetRecords)
        appLog.write("Completed catalog scan of volume \(volName): \(completedCount) file(s) scanned, \(targetRecords.count) catalogued")
        target.status = .complete
        target.lastScannedDate = Date()
        if target.phase == .noCatalog { target.phase = .cataloged }
        target.stopElapsedTimer()
        persistScanDates()
        notifyTargetsChanged()
        updateGlobalScanState()
        if !hasActiveTargets {
            dashboard.stopThroughputTimer()
            dashboard.scanPhase = .complete
        }
    }

    /// Mount the RAM disk for network scans if any root needs it.
    /// Returns the mount point string (or nil if not network / not mounted).
    fileprivate func mountScanRAMDiskIfNeeded(hasNetwork: Bool) async -> String? {
        guard hasNetwork else { return nil }
        let ramDiskMB = perfSettings.ramDiskGB * 1024
        let mounted = await ramDisk.mount(sizeMB: ramDiskMB)
        let mp = await ramDisk.mountPoint
        if mounted, let mp {
            log("  RAM disk mounted at \(mp) (\(perfSettings.ramDiskGB) GB) for network prefetch")
            return mp
        }
        log("  WARN: RAM disk unavailable, probing network files directly")
        return nil
    }

    /// Log the final success summary for a volume scan. Extracted purely to
    /// keep `runScanForTarget` focused on orchestration.
    fileprivate func logTargetScanSummary(volName: String, records: [VideoRecord]) {
        let va = records.filter { $0.streamTypeRaw == StreamType.videoAndAudio.rawValue }.count
        let vo = records.filter { $0.streamTypeRaw == StreamType.videoOnly.rawValue }.count
        let ao = records.filter { $0.streamTypeRaw == StreamType.audioOnly.rawValue }.count

        log("""

        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
          Scan Complete: \(volName)
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
          Total:          \(records.count)
          Video+Audio:    \(va)
          Video only:     \(vo)
          Audio only:     \(ao)
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        """)
    }

    /// Scan a single target's path, appending results to the shared records array
    func runScanForTarget(_ target: CatalogScanTarget) async {
        let root = target.searchPath
        let volName = URL(fileURLWithPath: root).lastPathComponent

        // High-level narration to videoscan.log — per-target per-file detail
        // continues to go to the catalog log.
        appLog.write("Starting catalog scan of volume \(volName) (path: \(root))")

        guard FileManager.default.fileExists(atPath: ffprobePath) else {
            log("ERROR: ffprobe not found at \(ffprobePath)\nInstall with: brew install ffmpeg")
            target.status = .error
            target.stopElapsedTimer()
            updateGlobalScanState()
            return
        }

        let rootIsNetwork = CombineVerifier.isNetworkPath(root)
        target.status = .discovering
        // Register this volume in the dashboard so the Realtime Catalog Scan
        // window can show per-volume progress for per-target scans.
        dashboard.volumeProgress.append(
            VolumeProgress(rootPath: root, volumeName: volName)
        )
        if rootIsNetwork {
            log("Discovering files on \(volName) (network volume — this may take a moment)…")
        } else {
            log("Discovering files on \(volName)…")
        }

        // Mount RAM disk up-front for network scans so ffprobe prefetch works
        // from the first probed file AND the user can see /Volumes/VideoScan_Temp
        // appear right away instead of waiting for a long walk to finish.
        let ramMountPoint = await mountScanRAMDiskIfNeeded(hasNetwork: rootIsNetwork)

        // Start keepalive for network volumes to prevent disk sleep and
        // auto-pause/resume on transient network outages.
        var keepalive: VolumeKeepalive?
        if rootIsNetwork {
            let ka = VolumeKeepalive(volumePath: root) { [weak self] msg in
                Task { @MainActor in self?.log(msg) }
            }
            await ka.start(pauseGate: target.pauseGate)
            keepalive = ka
            log("  Volume keepalive started for \(volName) (stat every 30s)")
        }

        // Streaming walk + interleaved probe — see runTargetProbeGroup.
        dashboard.scanPhase = .probing
        target.status = .scanning

        let result = await runTargetProbeGroup(
            target: target,
            root: root,
            volName: volName,
            rootIsNetwork: rootIsNetwork,
            ramMountPoint: ramMountPoint,
            keepalive: keepalive
        )

        if let ka = keepalive { await ka.stop() }

        await finalizeSingleTargetScan(
            target: target,
            volName: volName,
            targetRecords: result.records,
            completedCount: result.completed,
            discoveredCount: result.discovered,
            rootIsNetwork: rootIsNetwork
        )
    }

    /// Resume a previously interrupted scan from its checkpoint.
    func resumeTarget(_ target: CatalogScanTarget) {
        guard !target.searchPath.isEmpty else { return }
        // §1B: same retire guard as startTarget. Resume eventually
        // converges on the same record-write path, so the same audit
        // trail destruction would apply.
        guard !target.isRetired else {
            log("--- Resume refused: \(URL(fileURLWithPath: target.searchPath).lastPathComponent) is retired. Reinstate via Volumes window to enable scanning. ---")
            return
        }
        guard let checkpoint = ScanCheckpointStorage.load(for: target.searchPath) else {
            log("No checkpoint found for \(target.searchPath) — starting fresh scan")
            startTarget(target)
            return
        }
        if let missing = DependencyChecker.checkScan() {
            missingDependency = missing
            return
        }

        let staleHours = Int(Date().timeIntervalSince(checkpoint.startedAt) / 3600)
        if staleHours > 24 {
            log("  ⚠ Checkpoint is \(staleHours)h old — file list may be stale")
        }

        target.status = .scanning
        target.filesFound = checkpoint.totalDiscovered
        target.filesScanned = 0
        target.startElapsedTimer()

        let isFirstActive = !scanTargets.contains { $0.id != target.id && $0.status.isActive }
        if isFirstActive {
            dashboard.resetForScan()
            dashboard.scanPhase = .probing
            dashboard.startThroughputTimer()
        }
        isScanning = true

        let root = target.searchPath
        let volName = URL(fileURLWithPath: root).lastPathComponent
        let existingPaths = Set(records.filter { $0.fullPath.hasPrefix(root) }.map(\.fullPath))
        let remainingPaths = checkpoint.discoveredPaths.filter { !existingPaths.contains($0) }
        log("Resuming scan of \(volName): \(remainingPaths.count) of \(checkpoint.totalDiscovered) files remaining")
        appLog.write("Resuming catalog scan of volume \(volName) from checkpoint (\(remainingPaths.count) remaining)")

        target.scanTask = Task {
            let rootIsNetwork = CombineVerifier.isNetworkPath(root)
            let ramMountPoint = await mountScanRAMDiskIfNeeded(hasNetwork: rootIsNetwork)

            var keepalive: VolumeKeepalive?
            if rootIsNetwork {
                let ka = VolumeKeepalive(volumePath: root) { [weak self] msg in
                    Task { @MainActor in self?.log(msg) }
                }
                await ka.start(pauseGate: target.pauseGate)
                keepalive = ka
            }

            let result = await runResumedProbeGroup(
                target: target,
                filePaths: remainingPaths,
                root: root,
                volName: volName,
                rootIsNetwork: rootIsNetwork,
                ramMountPoint: ramMountPoint,
                keepalive: keepalive,
                skipChecksums: checkpoint.skipChecksums
            )

            if let ka = keepalive { await ka.stop() }

            ScanCheckpointStorage.delete(for: root)

            await finalizeSingleTargetScan(
                target: target,
                volName: volName,
                targetRecords: result.records,
                completedCount: result.completed,
                discoveredCount: result.discovered,
                rootIsNetwork: rootIsNetwork
            )
        }
    }

    /// Check for resumable scan checkpoints and mark matching targets.
    func detectResumableTargets() {
        let checkpoints = ScanCheckpointStorage.listAll()
        for cp in checkpoints {
            if let target = scanTargets.first(where: { $0.searchPath == cp.volumePath }),
               target.status == .idle || target.status == .stopped {
                let remaining = cp.discoveredPaths.count
                    - records.filter({ $0.fullPath.hasPrefix(cp.volumePath) }).count
                if remaining > 0 {
                    target.status = .resumable
                    log("  💾 Checkpoint found for \(URL(fileURLWithPath: cp.volumePath).lastPathComponent): \(remaining) files remaining")
                } else {
                    ScanCheckpointStorage.delete(for: cp.volumePath)
                }
            }
        }
    }
}
