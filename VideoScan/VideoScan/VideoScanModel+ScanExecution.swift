import Foundation
import os

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
//
// Discovery-completeness (2026-07-02): every scan carries a
// DiscoveryAuditCollector from walk through finalize. Finalize emits ONE
// audit summary block (console + os.log discoveryAudit category), writes the
// machine-readable scan-audit-<stamp>.json sidecar, and — the honesty hook —
// refuses to call a scan COMPLETE if any directory could not be enumerated,
// which routes the catalog merge onto the upsert-never-prune path.

extension VideoScanModel {

    /// Probe a single URL and update the dashboard counters for one volume.
    /// Extracted from `runScanForTarget` / `runParallelScan` so the big scan
    /// methods stay below the SwiftLint function-body ceiling. Returns the
    /// resulting Sendable `ProbeOutcome` — a `StreamType.ffprobeFailed`
    /// placeholder when the task is cancelled. The VideoRecord is materialized
    /// later, at the main-actor drain points in the probe task groups.
    ///
    /// - Parameter useTimeout: true → `probeFileWithTimeoutOutcome` (per-target
    ///   scan), false → `probeFileOutcome` (parallel multi-root scan).
    /// - Parameter echoFilename: true → log `[vol] filename` before probing
    ///   (matches the old parallel-scan UX).
    /// - Parameter scanGeneration: the dashboard scan generation captured at
    ///   ENQUEUE time (the same actor turn as this file's discovery
    ///   increment). Completion counting passes it to the DashboardState
    ///   seam, which drops stale-generation events — a straggler probe from
    ///   a stopped scan must never tick the NEXT scan's counters (the
    ///   "PROBING 18,456/18,450" invariant breach, 2026-07-03).
    func probeAndRecord(
        url: URL,
        volName: String,
        root: String,
        rootIsNetwork: Bool,
        ramMountPoint: String?,
        skipHashing: Bool,
        useTimeout: Bool,
        echoFilename: Bool,
        catalogedPaths: Set<String> = [],
        scanGeneration: UInt64
    ) async -> ProbeOutcome {
        if Task.isCancelled {
            var skip = ProbeOutcome()
            skip.filename = url.lastPathComponent
            skip.probe.streamTypeRaw = StreamType.ffprobeFailed.rawValue
            return skip
        }
        await MainActor.run {
            if echoFilename {
                self.log("  [\(volName)] \(url.lastPathComponent)")
            }
            self.dashboard.recordScanFile(volume: volName,
                                          filename: url.lastPathComponent,
                                          generation: scanGeneration)
        }
        let outcome: ProbeOutcome
        if useTimeout {
            outcome = await self.probeFileWithTimeoutOutcome(
                url: url,
                prefetchToRAM: rootIsNetwork,
                ramPath: ramMountPoint,
                skipHashing: skipHashing,
                scanRootPath: root,
                catalogedPaths: catalogedPaths
            )
        } else {
            outcome = await self.probeFileOutcome(
                url: url,
                prefetchToRAM: rootIsNetwork,
                ramPath: ramMountPoint,
                skipHashing: skipHashing,
                scanRootPath: root,
                catalogedPaths: catalogedPaths
            )
        }
        await MainActor.run {
            // Sniff-rejected outcomes are junk CLASSIFICATION, not probe
            // errors (QA 2026-07-02): ffprobe never ran, nothing failed —
            // the file simply isn't media. They carry the ffprobeFailed
            // streamType for the junk gate, but must not inflate the
            // dashboard's error counts (a .dat-blob volume would otherwise
            // report thousands of "errors" on a perfectly healthy scan).
            // ffprobe-failed outcomes that PASSED the sniff still count.
            let isProbeError = outcome.probe.streamTypeRaw == StreamType.ffprobeFailed.rawValue
                && !outcome.sniffRejected
            // Single batched seam (item-4 leg-2): scanCompleted, cache
            // hit/miss, error, stream-type, and per-volume row updates all
            // ride DashboardState's ≤4 Hz / 50-event flush machinery —
            // the direct @Published writes that used to live here were the
            // remaining per-file publish storm.
            self.dashboard.recordProbeCompletion(
                volumeRoot: root,
                wasCacheHit: outcome.wasCacheHit,
                isProbeError: isProbeError,
                streamTypeRaw: outcome.probe.streamTypeRaw,
                generation: scanGeneration
            )
        }
        return outcome
    }

    /// Process one probe result inside the per-target scan loop.
    /// Returns true if the caller should break (abort threshold tripped).
    ///
    /// Takes the Sendable `ProbeOutcome`, NOT a `VideoRecord`, so it can run
    /// for EVERY outcome — including files the catalog-admission gate
    /// (`shouldCatalogProbeResult`) rejects, for which no record is ever
    /// constructed. Scan-health accounting (the consecutiveNotAccessible
    /// abort counter, filesScanned, progress logging) must never depend on
    /// catalog admission: if a volume unmounts mid-scan in an
    /// extensionless-heavy tree (Avid media dirs), every outcome is
    /// extensionless + ffprobeFailed and gated out — and the abort would
    /// never fire. Pinned by ProbeGroupAbortAccountingTests.
    ///
    /// - Parameter catalogGated: true when the caller's catalog-admission
    ///   gate rejects this outcome (extensionless + ffprobe-unidentified).
    ///   The caller computes `shouldCatalogProbeResult` ONCE and passes its
    ///   negation, so gate logic is never evaluated twice per file. Gated-out
    ///   failures on a HEALTHY volume (file exists, ffprobe just couldn't
    ///   identify it) skip the visible "⚠ FAILED" console line — thousands of
    ///   junk blobs in an Avid tree would otherwise flood the console; the
    ///   quieter appLog "NOT CATALOGED" line at the drain point still records
    ///   each one. "File not found" failures ALWAYS log and count: they are
    ///   the volume-unmount trail the abort diagnostic depends on.
    func processTargetProbeResult(
        outcome: ProbeOutcome,
        volName: String,
        completedCount: Int,
        totalFiles: Int,
        target: CatalogScanTarget,
        catalogGated: Bool,
        consecutiveNotAccessible: inout Int,
        loggedMilestones: inout Set<Int>,
        milestones: Set<Int>,
        abortAfter: Int
    ) -> Bool {
        if outcome.probe.streamTypeRaw == StreamType.ffprobeFailed.rawValue {
            let notFound = outcome.probe.isPlayable == "File not found"
            if notFound || !catalogGated {
                let detail = outcome.notes.isEmpty ? "no detail available" : outcome.notes
                log("  ⚠ FAILED: \(outcome.filename) — \(detail)")
            }
            if notFound {
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
        rootIsNetwork: Bool,
        audit: DiscoveryAuditCollector?
    ) async {
        target.filesScanned = completedCount
        if discoveredCount == 0 {
            log("  No video files found on \(volName).")
            // Discovery audit still runs for empty discovery — an unreadable
            // ROOT looks exactly like "no files found", and the audit block
            // is what says so out loud. (This branch never prunes, so the
            // catalog is safe either way.)
            finishDiscoveryAudit(audit, volName: volName, cataloged: 0)
            // Empty discovery NEVER prunes: an empty walk over a tree the
            // catalog knows is populated is the LaCieWorkspace incident
            // shape (2026-07-01) — keep the existing records and say so.
            let retained = records.filter {
                PathScope.contains($0.fullPath, within: target.searchPath)
            }.count
            if retained > 0 {
                log("  Keeping \(retained) existing catalog record(s) under \(volName) — a scan that discovers nothing never prunes.")
                appLog.write("Completed catalog scan of volume \(volName): no video files found; retained \(retained) existing records (empty discovery never prunes)")
            } else {
                appLog.write("Completed catalog scan of volume \(volName): no video files found")
            }
            discardPreservedFieldsSnapshot(of: target)
            // Update Catalog: a deferred rescan that found nothing has
            // nothing to park — tell the sheet so its row doesn't spin.
            noteUpdateCatalogScanEnded(target: target, emptyDiscovery: true, cancelled: false)
            // The walk ran to completion (it just found nothing), so any
            // checkpoint is consumed — e.g. a network scan's post-walk
            // checkpoint, or a resumed checkpoint with zero paths.
            ScanCheckpointStorage.delete(for: target.searchPath)
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
            // Since the 2026-07-02 merge restructure, a cancelled scan
            // loses NOTHING: existing records were never removed (the old
            // wipe-at-start is gone) and the partial targetRecords buffer
            // is simply discarded here. The checkpoint (if any) is
            // deliberately KEPT: this branch commits nothing, so
            // resumability must survive a user cancel (QA 2026-07-02;
            // pinned by userCancelMidProbeLeavesCatalogAndCheckpointIntact).
            discardPreservedFieldsSnapshot(of: target)
            noteUpdateCatalogScanEnded(target: target, emptyDiscovery: false, cancelled: true)
            appLog.write("Cancelled catalog scan of volume \(volName) at \(completedCount)/\(discoveredCount) file(s) — catalog unchanged")
            updateGlobalScanState()
            return
        }
        // Catalog scope gate (video-only catalog, 2026-07-15): ambiguous
        // audio is admitted only with video-linked evidence; stray stills/
        // music are dropped. Runs BEFORE preservation + merge so excluded
        // files never enter the catalog — and re-drop identically on every
        // rescan (nothing creeps back). Pair-protected records pass
        // untouched (hard invariant; see VideoScanModel+CatalogScope).
        let scopeOutcome = await applyCatalogScopeGate(
            targetRecords: targetRecords, volName: volName, audit: audit)
        let scopedRecords = scopeOutcome.admitted

        // Restore dossier + user-edit fields snapshotted in startTarget.
        // Without this, every rescan would silently destroy hours of
        // Qwen + Whisper work and any manual people tags. Must run BEFORE
        // commitScanResults so the merged-in records carry the fields.
        let restored = applyPreservedFieldsAfterRescan(of: target, onto: scopedRecords)
        if restored > 0 {
            appLog.write("Rescan preservation: restored dossier+user fields onto \(restored) of \(scopedRecords.count) freshly-scanned records on \(volName)")
        }
        // Discovery honesty (2026-07-02): a scan whose enumerator could not
        // read one or more directories has NOT seen the whole tree — even if
        // every admitted file was probed. Treat it exactly like a mid-probe
        // abort: the merge below upserts and never prunes. This is the flag
        // that would have made the June-30 incident shape visible AND
        // harmless.
        let enumerationErrors = audit?.directoryEnumerationErrors ?? 0
        // walkWasIncomplete also covers the RESUMED case (QA 2026-07-02):
        // a checkpoint whose ORIGINAL walk hit enumeration errors carries
        // walkHadEnumerationErrors, resume marks the audit, and this scan —
        // which never re-walked — must not claim completeness either.
        let walkIncomplete = audit?.walkWasIncomplete ?? false
        if enumerationErrors > 0 {
            log("  ⚠ \(enumerationErrors) director\(enumerationErrors == 1 ? "y" : "ies") could not be read on \(volName) — treating this scan as INCOMPLETE (no records will be pruned).")
        } else if walkIncomplete {
            log("  ⚠ Resumed from a checkpoint whose original walk could not read every directory on \(volName) — treating this scan as INCOMPLETE (no records will be pruned).")
        }
        // Atomic root-scoped replace + mass-deletion tripwire — see
        // VideoScanModel+ScanMerge.swift. An aborted scan (completed <
        // discovered: volume died mid-probe) upserts without pruning.
        let scanWasComplete = completedCount >= discoveredCount && !walkIncomplete
        // UPDATE CATALOG (2026-08-17): when this root's rescan was started
        // from the Update Catalog sheet, the merge is DEFERRED — results are
        // parked and dry-run for the preview; the sheet's Apply commits them
        // (VideoScanModel+UpdateCatalog). The scan itself, the scope gate,
        // and the preservation pass above ran exactly as for a normal scan.
        // Status stays .idle (the catalog has NOT been updated yet);
        // lastScannedDate is stamped on Apply.
        if isUpdateCatalogDeferred(root: target.searchPath) {
            await parkScanResultsForUpdateCatalog(
                target: target, volName: volName,
                targetRecords: scopedRecords, scanWasComplete: scanWasComplete)
            if scanWasComplete { ScanCheckpointStorage.delete(for: target.searchPath) }
            logTargetScanSummary(volName: volName, records: scopedRecords)
            finishDiscoveryAudit(audit, volName: volName, cataloged: scopedRecords.count)
            appLog.write("Completed catalog scan of volume \(volName) for Update Catalog preview: \(completedCount) file(s) scanned, \(scopedRecords.count) catalogued — merge parked until Apply")
            target.status = .idle
            target.stopElapsedTimer()
            notifyTargetsChanged()
            updateGlobalScanState()
            if !hasActiveTargets {
                dashboard.stopThroughputTimer()
                dashboard.scanPhase = .complete
            }
            return
        }
        await commitScanResults(
            root: target.searchPath,
            volName: volName,
            targetRecords: scopedRecords,
            scanWasComplete: scanWasComplete
        )
        saveCatalogDebounced()
        // Checkpoint lifecycle (QA 2026-07-02): consumed only when the scan
        // ran to COMPLETION. A partial merge (unmount-abort) keeps it so
        // the target stays resumable — the merge above pruned nothing, and
        // the checkpoint is the only record of what was left to re-verify.
        var keptCheckpoint = false
        if scanWasComplete {
            ScanCheckpointStorage.delete(for: target.searchPath)
        } else if ScanCheckpointStorage.load(for: target.searchPath) != nil {
            keptCheckpoint = true
            log("  💾 Scan checkpoint kept for \(volName) — the scan aborted before completing, so it stays resumable.")
        }
        logTargetScanSummary(volName: volName, records: scopedRecords)
        finishDiscoveryAudit(audit, volName: volName, cataloged: scopedRecords.count)
        appLog.write("Completed catalog scan of volume \(volName): \(completedCount) file(s) scanned, \(scopedRecords.count) catalogued")
        // Post-merge status (QA on 3628e07): a PARTIAL merge must not claim
        // .complete — that both misstates what happened and hides the
        // resume affordance until relaunch, because detectResumableTargets
        // only promotes .idle/.stopped targets. `.stopped` is the existing
        // "ended without completing" state (stopTarget, the cancel branch
        // above), and promotion to `.resumable` stays
        // detectResumableTargets' job — it remains the SINGLE writer of
        // that status and it validates the checkpoint is non-empty.
        target.status = scanWasComplete ? .complete : .stopped
        target.lastScannedDate = Date()
        if target.phase == .noCatalog { target.phase = .cataloged }
        target.stopElapsedTimer()
        persistScanDates()
        notifyTargetsChanged()
        updateGlobalScanState()
        if keptCheckpoint {
            // Surface the kept checkpoint as a resume affordance NOW, not
            // only at next app launch.
            detectResumableTargets()
        }
        if !hasActiveTargets {
            dashboard.stopThroughputTimer()
            dashboard.scanPhase = .complete
        }
    }

    /// Snapshot the audit, publish it (`lastDiscoveryAudit`), write the
    /// sidecar JSON, and emit the ONE summary block per scan (fa24921
    /// console etiquette — never per-file lines).
    fileprivate func finishDiscoveryAudit(
        _ collector: DiscoveryAuditCollector?,
        volName: String,
        cataloged: Int
    ) {
        guard let collector else { return }
        let audit = collector.finish(cataloged: cataloged)
        lastDiscoveryAudit = audit

        // Sidecar destination: ~/Library/Logs/VideoScan in production;
        // NOWHERE in a test host unless a test injects an override directory
        // (settings-pollution class — tests must not write to real logs).
        var sidecarPath: String?
        if let dir = discoveryAuditDirectoryOverride {
            sidecarPath = DiscoveryAuditSidecar.write(audit, to: dir)
        } else if !TestEnvironment.isTestHost {
            sidecarPath = DiscoveryAuditSidecar.write(audit, to: PersistentLog.logDir)
        }

        var lines: [String] = []
        lines.append("  ── Discovery audit — \(volName) ──")
        lines.append("  Enumerated \(audit.filesEnumerated) file(s) · admitted \(audit.filesAdmitted) · cataloged \(audit.filesCataloged)")
        lines.append("  Skipped: \(audit.skippedNonMediaExtension) non-media ext · \(audit.skippedExtensionlessOff) extensionless (option off) · \(audit.skippedAudioExtensionOff) audio (option off) · \(audit.skippedSmallFile) small · \(audit.skippedSystemTreeDirs) system dir(s) · \(audit.skippedBundleDirs) bundle dir(s)")
        if audit.skippedCatalogScope > 0 || audit.scopeUnlinkedAudioExcluded > 0 || audit.scopeLinkedAudioKept > 0 {
            lines.append("  Catalog scope: \(audit.skippedCatalogScope) photo/music file(s) skipped before probing · \(audit.scopeLinkedAudioKept) audio kept (belongs to a video) · \(audit.scopeUnlinkedAudioExcluded) audio left out (no matching video)")
        }
        if audit.sniffRejected > 0 || audit.probeRejected > 0 {
            lines.append("  Not cataloged: \(audit.sniffRejected) no media signature (sniff) · \(audit.probeRejected) unidentified by ffprobe")
        }
        if audit.unreadableFiles > 0 {
            lines.append("  ⚠ \(audit.unreadableFiles) file(s) could not be read (permissions) — recorded in the audit, never probed")
        }
        if audit.skippedNonRegularEntries > 0 {
            lines.append("  \(audit.skippedNonRegularEntries) non-regular entr\(audit.skippedNonRegularEntries == 1 ? "y" : "ies") (symlink/fifo/socket) skipped — recorded in the audit")
        }
        if audit.directoryEnumerationErrors > 0 {
            lines.append("  ⚠ \(audit.directoryEnumerationErrors) directories could not be read — discovery was INCOMPLETE")
        }
        if audit.resumedFromIncompleteWalk {
            lines.append("  ⚠ Resumed from a checkpoint whose original walk was incomplete — discovery was INCOMPLETE")
        }
        if let sidecarPath {
            lines.append("  Audit JSON: \(sidecarPath)")
        }
        log(lines.joined(separator: "\n"))

        discoveryAuditLog.info("Discovery audit \(volName, privacy: .public): enumerated=\(audit.filesEnumerated) admitted=\(audit.filesAdmitted) cataloged=\(audit.filesCataloged) sniffRejected=\(audit.sniffRejected) probeRejected=\(audit.probeRejected) enumErrors=\(audit.directoryEnumerationErrors)")
        if audit.directoryEnumerationErrors > 0 {
            discoveryAuditLog.warning("Discovery INCOMPLETE for \(volName, privacy: .public): \(audit.directoryEnumerationErrors) unreadable directories — scan finalized as not-complete (upsert, no prune)")
        }
        appLog.write("Discovery audit (\(volName)): enumerated \(audit.filesEnumerated), admitted \(audit.filesAdmitted), cataloged \(audit.filesCataloged), sniff-rejected \(audit.sniffRejected), probe-rejected \(audit.probeRejected), unreadable dirs \(audit.directoryEnumerationErrors), unreadable files \(audit.unreadableFiles)\(sidecarPath.map { "; sidecar: \($0)" } ?? "")")
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
            // The preserved-fields snapshot startTarget just took has no
            // consumer on this path — discard it, or the map grows by one
            // stale entry per failed start (QA 2026-07-02).
            discardPreservedFieldsSnapshot(of: target)
            noteUpdateCatalogScanEnded(target: target, emptyDiscovery: false, cancelled: false)
            target.status = .error
            target.stopElapsedTimer()
            updateGlobalScanState()
            return
        }

        let rootIsNetwork = CombineVerifier.isNetworkPath(root)
        target.status = .discovering
        // Register this volume in the dashboard so the Realtime Catalog Scan
        // window can show per-volume progress for per-target scans. Replaces
        // any stale row for the same root (rescan of A while B is active
        // used to append a duplicate row the per-file updates never found).
        dashboard.beginVolumeWalk(volumeRoot: root, volumeName: volName,
                                  generation: dashboard.scanGeneration)
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

        // Discovery audit rides the whole scan: walker skip/error hooks,
        // probe-engine gate hooks, finalize summary + sidecar.
        let audit = DiscoveryAuditCollector(scanRoot: root, volumeName: volName)

        let result = await runTargetProbeGroup(
            target: target,
            root: root,
            volName: volName,
            rootIsNetwork: rootIsNetwork,
            ramMountPoint: ramMountPoint,
            keepalive: keepalive,
            audit: audit
        )

        if let ka = keepalive { await ka.stop() }

        await finalizeSingleTargetScan(
            target: target,
            volName: volName,
            targetRecords: result.records,
            completedCount: result.completed,
            discoveredCount: result.discovered,
            rootIsNetwork: rootIsNetwork,
            audit: audit
        )
    }

    /// Resume a previously interrupted scan from its checkpoint.
    func resumeTarget(_ target: CatalogScanTarget) {
        guard !target.searchPath.isEmpty else { return }
        // Same double-start guard as startTarget (QA 2026-07-02): a resume
        // of an already-active target would re-snapshot the preserved-fields
        // map, clobber filesFound from the checkpoint, and spawn a second
        // scanTask. No side effects past this point on refusal.
        guard !target.status.isActive else {
            log("--- Scan already \(target.status.rawValue.lowercased()) for \(URL(fileURLWithPath: target.searchPath).lastPathComponent) — resume ignored ---")
            return
        }
        // §1B: same retire guard as startTarget. Resume eventually
        // converges on the same record-write path, so the same audit
        // trail destruction would apply.
        guard !target.isRetired else {
            log("--- Resume refused: \(URL(fileURLWithPath: target.searchPath).lastPathComponent) is retired. Reinstate via Volumes window to enable scanning. ---")
            return
        }
        // Same scratch guard as startTarget (QA 2026-07-08): when a
        // checkpoint exists, resume never reaches startTarget's gate, so
        // without this a stale checkpoint could resurrect the RAM-disk
        // scratch volume as a scannable target.
        guard !target.isScratchVolume else {
            log("--- Resume refused: \(target.searchPath) is VideoScan's own RAM-disk scratch volume. ---")
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

        // Snapshot dossier + user-edit fields BEFORE the resumed probes run —
        // mirror of startTarget. Since the 2026-07-02 merge restructure,
        // resume re-verifies the FULL checkpoint list and finalize performs a
        // complete-scan replace, so without this snapshot a resumed-to-
        // completion scan replaced every re-seen record with a fresh probe
        // carrying no dossier/user fields (pendingPreservedFields is
        // in-memory only; after a crash/relaunch → resume, the map was
        // empty). Found by the testing agent 2026-07-02; pinned by
        // ScanMergeScopeTests.dossierAndUserFieldsSurviveResumedScan.
        snapshotPreservedFieldsForRescan(of: target)

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
        // Probe the FULL checkpoint list, not "checkpoint minus records
        // already in the catalog". Since the 2026-07-02 merge restructure,
        // existing records survive until scan COMPLETION — filtering them
        // out here would shrink targetRecords to the un-cataloged remainder
        // and commitScanResults would then prune everything else under the
        // root. MetadataCache makes the re-probes cheap (cache hits skip
        // ffprobe), so re-covering the whole list costs little.
        let remainingPaths = checkpoint.discoveredPaths
        log("Resuming scan of \(volName): re-verifying \(remainingPaths.count) checkpointed file(s) (cache hits skip ffprobe)")
        appLog.write("Resuming catalog scan of volume \(volName) from checkpoint (\(remainingPaths.count) file(s), full-list re-verify)")

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

            // Resumed scans skip the walk phase, so the audit carries no
            // enumeration stats — but the probe-gate hooks (sniff-rejected /
            // probe-rejected) and the finalize summary still apply.
            let audit = DiscoveryAuditCollector(scanRoot: root, volumeName: volName)
            // Checkpoint honesty (QA 2026-07-02): the ORIGINAL walk behind
            // this checkpoint could not read every directory. The resume
            // never re-walks, so the incompleteness carries over — finalize
            // must refuse to call the scan complete (upsert, never prune),
            // or it would prune records under directories that walk never
            // saw despite completing every checkpointed path.
            if checkpoint.walkHadEnumerationErrors {
                audit.markResumedFromIncompleteWalk()
            }

            let result = await runResumedProbeGroup(
                target: target,
                filePaths: remainingPaths,
                root: root,
                volName: volName,
                rootIsNetwork: rootIsNetwork,
                ramMountPoint: ramMountPoint,
                keepalive: keepalive,
                skipChecksums: checkpoint.skipChecksums,
                audit: audit
            )

            if let ka = keepalive { await ka.stop() }

            // Checkpoint lifecycle belongs to finalizeSingleTargetScan:
            // deleted only when the scan ran to COMPLETION. The
            // unconditional delete that used to sit here destroyed the
            // checkpoint on a CANCELLED or unmount-aborted resume — whose
            // finalize branches commit nothing, so resumability must
            // survive them (QA 2026-07-02).
            await finalizeSingleTargetScan(
                target: target,
                volName: volName,
                targetRecords: result.records,
                completedCount: result.completed,
                discoveredCount: result.discovered,
                rootIsNetwork: rootIsNetwork,
                audit: audit
            )
        }
    }

    /// Check for resumable scan checkpoints and mark matching targets.
    func detectResumableTargets() {
        let checkpoints = ScanCheckpointStorage.listAll()
        for cp in checkpoints {
            if let target = scanTargets.first(where: { $0.searchPath == cp.volumePath }),
               target.status == .idle || target.status == .stopped {
                // A lingering checkpoint means the scan never finalized
                // (finalize deletes it), so any non-empty checkpoint is
                // resumable. The old "checkpoint count minus cataloged
                // records under the path" arithmetic is meaningless now
                // that existing records survive until scan completion —
                // it would go ≤ 0 on every interrupted RESCAN and delete
                // the checkpoint the user needs.
                let remaining = cp.discoveredPaths.count
                if remaining > 0 {
                    target.status = .resumable
                    log("  💾 Checkpoint found for \(URL(fileURLWithPath: cp.volumePath).lastPathComponent): \(remaining) file(s) to re-verify")
                } else {
                    ScanCheckpointStorage.delete(for: cp.volumePath)
                }
            }
        }
    }
}
