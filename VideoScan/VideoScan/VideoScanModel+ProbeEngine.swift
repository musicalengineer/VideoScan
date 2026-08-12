import Foundation
import Darwin

// MARK: - Probe Engine (the kitchen tools)
//
// The lowest level of the scan stack:
//   - walkDirectoryStream — async streaming filesystem walker
//   - probeFile / probeFileWithTimeout — per-file ffprobe invocation
//   - runTargetProbeGroup / runResumedProbeGroup — concurrent probe pools
//   - prefetchIfNeeded / prefetchHeader — network header staging to RAM disk
//   - cancelledProbeRecord — sentinel for cancelled-before-permit cases
//
// All of this is nonisolated so probe tasks can run off the main actor
// without bouncing back — and the two per-file workhorses
// (probeFileOutcome, probeFileWithTimeoutOutcome) are additionally
// `@concurrent`: under Approachable Concurrency
// (NonisolatedNonsendingByDefault) a plain `nonisolated async` runs on
// its CALLER's actor, and the scan pipeline calls them from main-actor
// probeAndRecord. Without `@concurrent` the pre-race stat, existence
// check, cache lookup, sniff, and 64 KB hash all ran ON THE MAIN ACTOR
// per scanned file (2026-07-02 feedback storm — 207/222 main-thread
// samples in lstat during the 14.5h RicksBackups crawl). The recipe
// layer that orchestrates these tools lives in
// VideoScanModel+ScanExecution.swift.
//
// The two probe-engine stored constants (prefetchBytes, probeTimeoutSeconds)
// stay in the main class because extensions can't add stored properties.
//
// Discovery-completeness (2026-07-02): extensionless and unknown-extension
// candidates now pass a magic-byte content sniff (MediaSignatures) BEFORE
// ffprobe — sniff-fails skip the subprocess, surface as the same
// gated-out ffprobeFailed shape the junk gate already handles, and are
// counted in the per-scan DiscoveryAudit. Known media extensions never
// sniff: zero behavior change for normal scans.

extension VideoScanModel {

    /// Streams `target.searchPath` and drains a probe group against it.
    /// Returns the collected records, total discovered, and total completed.
    func runTargetProbeGroup(
        target: CatalogScanTarget,
        root: String,
        volName: String,
        rootIsNetwork: Bool,
        ramMountPoint: String?,
        keepalive: VolumeKeepalive? = nil,
        audit: DiscoveryAuditCollector? = nil
    ) async -> (records: [VideoRecord], discovered: Int, completed: Int) {
        let probesLimit = perfSettings.probesPerVolume
        let sem = AsyncSemaphore(limit: probesLimit)
        let skipHashingCaptured = scanOptions.skipChecksums
        var targetRecords: [VideoRecord] = []
        let milestones = Set([10, 25, 50, 75, 90, 100])
        var loggedMilestones: Set<Int> = []
        var completedCount = 0
        var discoveredCount = 0
        var consecutiveNotAccessible = 0
        let abortAfter = rootIsNetwork ? 100 : 50
        var allDiscoveredPaths: [String] = []
        let knownMediaExtensions = videoExtensions.union(audioExtensions)
        // Counter-integrity stamp (2026-07-03): captured ONCE, on the main
        // actor, before any probe is enqueued. Every discovery increment and
        // every completion from this scan carries it; if the user stops this
        // scan and starts another (resetForScan → new generation), our
        // in-flight stragglers are dropped at the DashboardState seam
        // instead of corrupting the new scan's counters.
        let scanGen = dashboard.scanGeneration
        // Sniff-gate exemption (QA 2026-07-02): paths that ALREADY have a
        // catalog record reach ffprobe even if their first bytes match no
        // signature — ffprobe once vouched for them, and a 264-byte sniff
        // must never overrule that verdict (it would feed the prune chain).
        // Built ONCE per target on the main actor, then carried into the
        // off-actor probe tasks as an immutable Set — zero actor traffic.
        let catalogedPaths = Set(records.lazy
            .map(\.fullPath)
            .filter { PathScope.contains($0, within: root) })

        let stream = walkDirectoryStream(
            root: root,
            skipDirs: skipDirsSnapshot(),
            skipBundleExtensions: skipBundleExtensionsSnapshot(),
            skipSmallFiles: scanOptions.skipSmallFiles,
            probeExtensionless: scanOptions.probeExtensionless,
            scanAudioFiles: scanOptions.scanAudioFiles,
            scanUnknownExtensions: scanOptions.scanUnknownExtensions,
            videoOnlyCatalogScope: catalogScopeSettings.videoAndLinkedAudioOnly,
            audit: audit
        ) { [weak self] currentDir in
            Task { @MainActor in
                guard let self else { return }
                self.dashboard.scanCurrentVolume = volName
                self.dashboard.scanCurrentFile = "📂 " + currentDir.lastPathComponent
            }
        }

        await withTaskGroup(of: ProbeOutcome.self) { probeGroup in
            for await url in stream {
                if Task.isCancelled { break }
                discoveredCount += 1
                allDiscoveredPaths.append(url.path)
                // Discovery increment SYNCHRONOUSLY before the enqueue —
                // this loop is @MainActor-isolated, so there is no actor
                // hop (the old `await MainActor.run` here suspended between
                // the increment and the enqueue) and no probe can possibly
                // complete before its discovery is visible. The invariant
                // completed ≤ discovered is structural from here on.
                dashboard.recordFileDiscovered(volumeRoot: root, generation: scanGen)
                probeGroup.addTask { [self] in
                    await target.pauseGate.waitIfPaused()
                    do {
                        return try await sem.withPermit {
                            await self.probeAndRecord(
                                url: url,
                                volName: volName,
                                root: root,
                                rootIsNetwork: rootIsNetwork,
                                ramMountPoint: ramMountPoint,
                                skipHashing: skipHashingCaptured,
                                useTimeout: true,
                                echoFilename: false,
                                catalogedPaths: catalogedPaths,
                                scanGeneration: scanGen
                            )
                        }
                    } catch {
                        return self.cancelledProbeOutcome(url: url)
                    }
                }
            }

            let totalFiles = discoveredCount
            target.filesFound = totalFiles
            // Denominator is now FINAL — flips the row out of isWalking so
            // the UI may switch from "N probed — finding files…" to a true
            // N/M percentage (scanDiscoveryFinal).
            dashboard.markVolumeWalkComplete(volumeRoot: root, totalFiles: totalFiles, generation: scanGen)
            log("  Found \(totalFiles) video files on \(volName)")

            // Save checkpoint after walk completes so a crash during probing
            // can resume without re-walking the entire directory tree.
            if rootIsNetwork {
                // Checkpoint honesty (QA 2026-07-02): if the walk hit
                // enumeration errors, the checkpoint must say so — a resume
                // completes only the ADMITTED paths, and without the flag it
                // would finalize as "complete" and prune records under the
                // directories this walk never read.
                let checkpoint = ScanCheckpoint(
                    volumePath: root,
                    startedAt: Date(),
                    discoveredPaths: allDiscoveredPaths,
                    totalDiscovered: totalFiles,
                    skipChecksums: skipHashingCaptured,
                    walkHadEnumerationErrors: (audit?.directoryEnumerationErrors ?? 0) > 0
                )
                ScanCheckpointStorage.save(checkpoint)
                log("  💾 Checkpoint saved (\(totalFiles) files) — scan is resumable if interrupted")
            }

            for await outcome in probeGroup {
                completedCount += 1

                // Scan-health accounting runs for EVERY outcome — BEFORE the
                // catalog-admission gate below. The gate decides what enters
                // the catalog, never whether the volume-unmount abort counter
                // or filesScanned tick. (Regression: gated-out extensionless
                // + ffprobeFailed outcomes used to `continue` past this, so a
                // mid-scan unmount in an Avid extensionless tree never
                // tripped the consecutive-failures abort and the scan ground
                // through the whole dead volume.)
                await resetAbortStreakIfVolumeRecovered(
                    keepalive: keepalive, outcome: outcome,
                    consecutiveNotAccessible: &consecutiveNotAccessible)

                // Catalog-admission gate — the SAME junk gate as the
                // network-resume path (runResumedProbeGroup). Computed ONCE
                // here: the accounting call below needs it too (gated-out
                // failures on a healthy volume keep the quieter appLog-only
                // treatment instead of a console FAILED line per junk blob).
                let shouldCatalog = Self.shouldCatalogProbeResult(
                    ext: outcome.ext, streamTypeRaw: outcome.probe.streamTypeRaw,
                    knownMediaExtensions: knownMediaExtensions)

                let shouldAbort = processTargetProbeResult(
                    outcome: outcome,
                    volName: volName,
                    completedCount: completedCount,
                    totalFiles: totalFiles,
                    target: target,
                    catalogGated: !shouldCatalog,
                    consecutiveNotAccessible: &consecutiveNotAccessible,
                    loggedMilestones: &loggedMilestones,
                    milestones: milestones,
                    abortAfter: abortAfter
                )

                // Drop pre-construction so we never build a VideoRecord for a
                // file we're about to discard (extensionless + ffprobe-
                // unidentified). The two paths must gate identically.
                if shouldCatalog {
                    // MainActor drain point: this loop is @MainActor-isolated,
                    // so the VideoRecord is constructed HERE — the off-actor
                    // probe pipeline only ever produced the Sendable
                    // ProbeOutcome carrier.
                    let rec = VideoRecord()
                    rec.apply(outcome)
                    targetRecords.append(rec)
                } else {
                    recordGatedOutcome(outcome, audit: audit)
                }

                if shouldAbort {
                    probeGroup.cancelAll()
                    break
                }
            }
        }
        // Deterministic final flush: the batched counters must be fully
        // published the moment the probe group returns (finalize and tests
        // read them synchronously; the trailing-timer flush alone would
        // leave up to one throttle window of lag).
        dashboard.flushScanProgress()
        return (targetRecords, discoveredCount, completedCount)
    }

    /// If keepalive reports the volume healthy again, clear the consecutive
    /// not-accessible streak so transient outages don't accumulate toward
    /// the abort threshold. Shared by both probe-group drain loops.
    func resetAbortStreakIfVolumeRecovered(
        keepalive: VolumeKeepalive?,
        outcome: ProbeOutcome,
        consecutiveNotAccessible: inout Int
    ) async {
        guard let keepalive, consecutiveNotAccessible > 0 else { return }
        let volDown = await keepalive.volumeIsDown
        if !volDown && outcome.probe.streamTypeRaw != StreamType.ffprobeFailed.rawValue {
            consecutiveNotAccessible = 0
        }
    }

    /// Whether a probed file should get a catalog record. Drops files that
    /// ffprobe (or the pre-ffprobe content sniff) could not identify as media
    /// AND whose extension can't vouch for them — the data-blob noise the
    /// "Scan Files With No Extension" / "Scan Unrecognized File Types" passes
    /// admit (e.g. ~4.9k junk rows on a backup-drive sweep). Extensioned
    /// damaged media (a real but unreadable Avid .mxf, say) is STILL cataloged
    /// so it stays visible. Each drop is logged at the call site, so "why
    /// isn't this file cataloged?" always has an answer (and, since
    /// 2026-07-02, an audit entry).
    ///
    /// - Parameter knownMediaExtensions: lowercased extensions that vouch for
    ///   a file even when ffprobe fails (the video+audio allowlists). Pass
    ///   nil (the default, and the pre-2026-07-02 behavior) to gate ONLY
    ///   extensionless failures — kept so the original contract stays pinned
    ///   by ProbeResultCatalogingTests. The scan drain loops pass the real
    ///   sets so unknown-extension junk admitted by the new toggle can't
    ///   flood the catalog as "damaged media".
    nonisolated static func shouldCatalogProbeResult(
        ext: String,
        streamTypeRaw: String,
        knownMediaExtensions: Set<String>? = nil
    ) -> Bool {
        let unidentified = streamTypeRaw == StreamType.ffprobeFailed.rawValue
        guard unidentified else { return true }
        let trimmed = ext.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        if let known = knownMediaExtensions, !known.contains(trimmed.lowercased()) {
            return false
        }
        return true
    }

    /// Shared drain-point bookkeeping for a gated-out (never-cataloged)
    /// outcome: the quiet appLog line (fa24921 etiquette — file log, not
    /// console) plus the discovery-audit entry, classified by whether the
    /// content sniff or ffprobe did the rejecting.
    func recordGatedOutcome(_ outcome: ProbeOutcome, audit: DiscoveryAuditCollector?) {
        if outcome.sniffRejected {
            appLog.write("NOT CATALOGED — no media signature in file header (ffprobe skipped): \(outcome.fullPath)")
            audit?.sniffRejected(path: outcome.fullPath)
        } else {
            appLog.write("NOT CATALOGED — extension can't vouch for it and ffprobe could not identify as media: \(outcome.fullPath)")
            audit?.probeRejected(path: outcome.fullPath)
        }
    }

    /// Probe a pre-discovered file list (from a checkpoint). Skips the walk
    /// phase entirely — MetadataCache handles skipping already-probed files.
    func runResumedProbeGroup(
        target: CatalogScanTarget,
        filePaths: [String],
        root: String,
        volName: String,
        rootIsNetwork: Bool,
        ramMountPoint: String?,
        keepalive: VolumeKeepalive?,
        skipChecksums: Bool,
        audit: DiscoveryAuditCollector? = nil
    ) async -> (records: [VideoRecord], discovered: Int, completed: Int) {
        let probesLimit = perfSettings.probesPerVolume
        let sem = AsyncSemaphore(limit: probesLimit)
        var targetRecords: [VideoRecord] = []
        let milestones = Set([10, 25, 50, 75, 90, 100])
        var loggedMilestones: Set<Int> = []
        var completedCount = 0
        var consecutiveNotAccessible = 0
        let abortAfter = rootIsNetwork ? 100 : 50
        let totalFiles = filePaths.count
        let knownMediaExtensions = videoExtensions.union(audioExtensions)
        // Sniff-gate exemption — same per-target context as
        // runTargetProbeGroup (see the comment there).
        let catalogedPaths = Set(records.lazy
            .map(\.fullPath)
            .filter { PathScope.contains($0, within: root) })
        // Counter-integrity stamp — same contract as runTargetProbeGroup.
        let scanGen = dashboard.scanGeneration

        target.filesFound = totalFiles
        // Resumed scans have no walk: the checkpoint list IS the final
        // denominator, so the row starts with isWalking=false and a known
        // total (the pre-fix row stayed isWalking=true forever and showed
        // the walking treatment for the whole resume).
        dashboard.beginVolumeWalk(volumeRoot: root, volumeName: volName,
                                  generation: scanGen, knownTotal: totalFiles)

        await withTaskGroup(of: ProbeOutcome.self) { probeGroup in
            for path in filePaths {
                if Task.isCancelled { break }
                let url = URL(fileURLWithPath: path)
                // Strictly before the enqueue — same invariant as the
                // streaming walk path.
                dashboard.recordFileDiscovered(volumeRoot: root, generation: scanGen)

                probeGroup.addTask { [self] in
                    await target.pauseGate.waitIfPaused()
                    do {
                        return try await sem.withPermit {
                            await self.probeAndRecord(
                                url: url,
                                volName: volName,
                                root: root,
                                rootIsNetwork: rootIsNetwork,
                                ramMountPoint: ramMountPoint,
                                skipHashing: skipChecksums,
                                useTimeout: true,
                                echoFilename: false,
                                catalogedPaths: catalogedPaths,
                                scanGeneration: scanGen
                            )
                        }
                    } catch {
                        return self.cancelledProbeOutcome(url: url)
                    }
                }
            }
            // Publish the final discovered total for this root right away.
            dashboard.markVolumeWalkComplete(volumeRoot: root, totalFiles: totalFiles, generation: scanGen)

            for await outcome in probeGroup {
                completedCount += 1

                // Scan-health accounting BEFORE the catalog gate — see the
                // matching comment in runTargetProbeGroup. The gate controls
                // catalog admission only; the not-accessible abort counter
                // and filesScanned must tick for gated-out outcomes too.
                await resetAbortStreakIfVolumeRecovered(
                    keepalive: keepalive, outcome: outcome,
                    consecutiveNotAccessible: &consecutiveNotAccessible)

                // Catalog-admission gate — computed ONCE (see the matching
                // comment in runTargetProbeGroup); also feeds the accounting
                // call so healthy-volume gated-out junk stays off the console.
                let shouldCatalog = Self.shouldCatalogProbeResult(
                    ext: outcome.ext, streamTypeRaw: outcome.probe.streamTypeRaw,
                    knownMediaExtensions: knownMediaExtensions)

                let shouldAbort = processTargetProbeResult(
                    outcome: outcome,
                    volName: volName,
                    completedCount: completedCount,
                    totalFiles: totalFiles,
                    target: target,
                    catalogGated: !shouldCatalog,
                    consecutiveNotAccessible: &consecutiveNotAccessible,
                    loggedMilestones: &loggedMilestones,
                    milestones: milestones,
                    abortAfter: abortAfter
                )

                // Drop pre-construction so we never build a VideoRecord for a
                // file we're about to discard (extensionless + unidentified).
                if shouldCatalog {
                    // MainActor drain point — construct the VideoRecord here.
                    let rec = VideoRecord()
                    rec.apply(outcome)
                    targetRecords.append(rec)
                } else {
                    recordGatedOutcome(outcome, audit: audit)
                }

                if shouldAbort {
                    probeGroup.cancelAll()
                    break
                }
            }
        }
        // Deterministic final flush — same contract as runTargetProbeGroup.
        dashboard.flushScanProgress()
        return (targetRecords, totalFiles, completedCount)
    }

    /// Walk a directory tree and yield video file URLs as they are discovered
    /// via an `AsyncStream<URL>`. The walker runs on a detached task so FileManager
    /// I/O doesn't block the cooperative pool. Consumers receive URLs one at a
    /// time and can begin probing long before the full walk completes.
    ///
    /// This is the network-friendly variant: a pure metadata walk over SMB can
    /// take 30-90 minutes on old HDDs, long enough for the remote to let the
    /// SMB session idle out. Interleaving content reads (probe) with directory
    /// enumeration keeps the session warm end-to-end.
    nonisolated func walkDirectoryStream(
        root: String,
        skipDirs: Set<String>,
        skipBundleExtensions: Set<String>,
        skipSmallFiles: Bool,
        probeExtensionless: Bool = false,
        scanAudioFiles: Bool = false,
        scanUnknownExtensions: Bool = false,
        videoOnlyCatalogScope: Bool = false,
        audit: DiscoveryAuditCollector? = nil,
        onDirectoryEntered: (@Sendable (_ currentDir: URL) -> Void)? = nil
    ) -> AsyncStream<URL> {
        FilesystemWalker.walkDirectoryStream(
            root: root,
            videoExtensions: videoExtensions,
            skipDirs: skipDirs,
            skipBundleExtensions: skipBundleExtensions,
            skipSmallFiles: skipSmallFiles,
            probeExtensionless: probeExtensionless,
            audioExtensions: audioExtensions,
            scanAudioFiles: scanAudioFiles,
            scanUnknownExtensions: scanUnknownExtensions,
            videoOnlyCatalogScope: videoOnlyCatalogScope,
            audit: audit,
            onDirectoryEntered: onDirectoryEntered
        )
    }

    /// Sentinel outcome for a probe cancelled before it acquired a permit.
    /// Pure off-actor producer — returns the Sendable carrier, never a
    /// VideoRecord. The task group consumes this; the VideoRecord is built at
    /// the main-actor drain point.
    nonisolated func cancelledProbeOutcome(url: URL) -> ProbeOutcome {
        var o = ProbeOutcome()
        o.filename            = url.lastPathComponent
        o.ext                 = url.pathExtension.uppercased()
        o.fullPath            = url.path
        o.directory           = url.deletingLastPathComponent().path
        o.probe.isPlayable    = "Cancelled"
        o.notes               = "Probe cancelled before acquiring a concurrency permit"
        o.probe.streamTypeRaw = StreamType.ffprobeFailed.rawValue
        return o
    }

    /// `@MainActor` VideoRecord shim over `cancelledProbeOutcome`. Retained for
    /// the probe-engine error-path tests and any single-record caller that
    /// wants a materialized record. The VideoRecord is constructed on the main
    /// actor (this method is actor-isolated), so the no-off-actor-construction
    /// invariant holds.
    func cancelledProbeRecord(url: URL) -> VideoRecord {
        let rec = VideoRecord()
        rec.apply(cancelledProbeOutcome(url: url))
        return rec
    }

    /// Wrapper that races probeFile against a timeout. If probeFile takes
    /// longer than probeTimeoutSeconds, returns a timed-out record so the
    /// scan can move past stuck network files.
    ///
    /// Even on timeout, the record carries filename + size so the
    /// VolumeComparer `(filename, size)` fallback can still match it against
    /// other volumes — without that, every timed-out file would be flagged as
    /// "unique to this volume" in Compare & Rescue.
    /// LOAD-BEARING SEAM — `@concurrent` keeps the per-file probe work off
    /// the main actor. Under Approachable Concurrency, `nonisolated async`
    /// alone runs on the caller's actor (main-actor `probeAndRecord`), which
    /// put the pre-race stat below on the main thread once per scanned file
    /// and starved the scan (2026-07-02, 14.5h RicksBackups crawl). Do not
    /// remove the attribute; the main-actor slice per file must stay
    /// lightweight bookkeeping only.
    // #if guard: the nightly CI's Xcode 16.4 (Swift 6.1) knows
    // `@concurrent` only as a deprecated alias of `@Sendable` and warns;
    // pre-6.2 a nonisolated async already runs off-actor.
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated func probeFileWithTimeoutOutcome(url: URL, prefetchToRAM: Bool = false, ramPath: String? = nil, skipHashing: Bool = false, scanRootPath: String? = nil, catalogedPaths: Set<String> = []) async -> ProbeOutcome {
        // Best-effort stat before the race. stat() is metadata-only and
        // usually fast even on SMB when content reads stall. We use this only
        // to populate the timeout record; probeFileOutcome re-fetches on its
        // own path for the success case.
        let preSize: Int64 = {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            return (attrs?[.size] as? Int64) ?? 0
        }()

        do {
            return try await withThrowingTaskGroup(of: ProbeOutcome.self) { group in
                group.addTask {
                    await self.probeFileOutcome(url: url, prefetchToRAM: prefetchToRAM, ramPath: ramPath, skipHashing: skipHashing, scanRootPath: scanRootPath, catalogedPaths: catalogedPaths)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: self.probeTimeoutSeconds * 1_000_000_000)
                    throw CancellationError()
                }
                // First to finish wins — cancel the other
                guard let result = try await group.next() else {
                    throw CancellationError()
                }
                group.cancelAll()
                return result
            }
        } catch {
            // Timeout fired before the probe completed. Pure value carrier —
            // the VideoRecord is built later at the main-actor drain point.
            var o = ProbeOutcome()
            o.filename            = url.lastPathComponent
            o.ext                 = url.pathExtension.uppercased()
            o.fullPath            = url.path
            o.directory           = url.deletingLastPathComponent().path
            o.sizeBytes           = preSize
            o.probe.isPlayable    = "Timed out"
            o.notes               = "File probe exceeded \(probeTimeoutSeconds)s — network I/O may be stalled"
            o.probe.streamTypeRaw = StreamType.ffprobeFailed.rawValue
            return o
        }
    }

    /// `@MainActor` VideoRecord shim over `probeFileWithTimeoutOutcome`.
    /// Retained for the probe-engine timeout-regression tests; the scan
    /// pipeline calls the `…Outcome` core directly via `probeAndRecord`.
    func probeFileWithTimeout(url: URL, prefetchToRAM: Bool = false, ramPath: String? = nil, skipHashing: Bool = false, scanRootPath: String? = nil) async -> VideoRecord {
        let outcome = await probeFileWithTimeoutOutcome(url: url, prefetchToRAM: prefetchToRAM, ramPath: ramPath, skipHashing: skipHashing, scanRootPath: scanRootPath)
        let rec = VideoRecord()
        rec.apply(outcome)
        return rec
    }

    /// Probe a single file and return a populated `VideoRecord`.
    ///
    /// `@MainActor` shim over the nonisolated `probeFileOutcome` core: the
    /// heavy work (existence check, hashing, ffprobe subprocess, MXF fallback,
    /// caching) runs off-actor inside the core and yields a Sendable
    /// `ProbeOutcome`; the `VideoRecord` is materialized HERE, on the main
    /// actor. This is the single-file reprobe entry point used by TranscodeJob,
    /// ReformatJob, and TriageView (all `@MainActor`) — and by the probe-engine
    /// tests. The scan pipeline does NOT call this; it consumes the carrier
    /// from the core directly (see `probeAndRecord`).
    func probeFile(url: URL, prefetchToRAM: Bool = false, ramPath: String? = nil, skipHashing: Bool = false, scanRootPath: String? = nil) async -> VideoRecord {
        let outcome = await probeFileOutcome(url: url, prefetchToRAM: prefetchToRAM, ramPath: ramPath, skipHashing: skipHashing, scanRootPath: scanRootPath)
        let rec = VideoRecord()
        rec.apply(outcome)
        return rec
    }

    /// Probe a single file and return a Sendable `ProbeOutcome`.
    /// If prefetchToRAM is true and ramPath is available, copies the first 10MB
    /// to the RAM disk so ffprobe reads at memory speed instead of network speed.
    ///
    /// Pure off-actor producer: EVERY return path yields a `ProbeOutcome` value
    /// (the not-found sentinel, the cache-hit carrier from `MetadataCache.lookup`,
    /// and the probe-success/fallback carrier). No `VideoRecord` is constructed
    /// here — that now happens only at the main-actor drain points and the
    /// `@MainActor` shims. This is what closes the off-actor reference-mutation
    /// hole: the whole probe stage trafficks in Sendable values.
    /// LOAD-BEARING SEAM — `@concurrent` for the same reason as
    /// `probeFileWithTimeoutOutcome`: the parallel-scan path
    /// (`probeAndRecord` with useTimeout=false) and the @MainActor shims
    /// call this directly from the main actor, and without the attribute
    /// the existence check, attributes fetch, cache lookup, sniff, and
    /// partial-MD5 hash all ran on the main thread per file.
    // #if guard: see probeFileWithTimeoutOutcome above.
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated func probeFileOutcome(url: URL, prefetchToRAM: Bool = false, ramPath: String? = nil, skipHashing: Bool = false, scanRootPath: String? = nil, catalogedPaths: Set<String> = []) async -> ProbeOutcome {
        let fm = FileManager.default
        let path = url.path

        // Quick existence check — on network volumes, files discovered during
        // the walk phase can vanish by the time we probe (symlinks, aliases,
        // unmounted subdirs). Skip immediately rather than wasting time on
        // ffprobe which will also fail.
        //
        // This is a true per-file existence question, so we use
        // `FileManager.fileExists` directly rather than VolumeReachability.
        // VolumeReachability answers "is the VOLUME mounted?" — a single bit
        // shared by every file on the mount — which is the wrong granularity
        // here. Using it caused per-file existence misses to overwrite the
        // cached mount bit and flicker the catalog UI (italics flicker bug).
        guard fm.fileExists(atPath: path) else {
            var o = ProbeOutcome()
            o.filename            = url.lastPathComponent
            o.ext                 = url.pathExtension.uppercased()
            o.fullPath            = path
            o.directory           = url.deletingLastPathComponent().path
            o.probe.isPlayable    = "File not found"
            o.notes               = "File was discovered during scan but is no longer accessible"
            o.probe.streamTypeRaw = StreamType.ffprobeFailed.rawValue
            return o
        }

        // Get file attributes for cache key and record population
        let attrs = try? fm.attributesOfItem(atPath: path)
        let fileSize = (attrs?[.size] as? Int64) ?? 0
        let modDate = (attrs?[.modificationDate] as? Date) ?? Date.distantPast

        // Check SQLite cache first — skip ffprobe if file unchanged.
        // Always refresh scanContext on cache hits so provenance (scan host,
        // mount type, volume UUID, remote server) reflects the current scan
        // and legacy records backfill naturally on rescan. The capture is two
        // syscalls — cheap even when multiplied across thousands of hits.
        if var cached = metadataCache.lookup(path: path, fileSize: fileSize, modDate: modDate) {
            cached.wasCacheHit = true
            cached.scanContext = ScanContext.capture(for: url, scanRootPath: scanRootPath)
            return cached
        }

        // Magic-byte sniff gate (discovery-completeness, 2026-07-02): a file
        // whose extension can't vouch for it (none, or unrecognized) must
        // show a media signature in its first bytes before we pay for an
        // ffprobe subprocess. Placement matters:
        //   * AFTER the existence check + cache lookup — vanished files keep
        //     producing the "File not found" trail the unmount-abort
        //     accounting depends on, and previously-identified media skips
        //     both sniff and ffprobe via the cache;
        //   * BEFORE hashing/prefetch/ffprobe — junk costs a 264-byte read,
        //     not a 64 KB hash + subprocess.
        // `.unreadable` deliberately falls THROUGH to ffprobe: the sniff only
        // ever rejects on evidence, never on an I/O hiccup.
        // Cataloged-path exemption (QA 2026-07-02): a path that already has
        // a catalog record skips the gate entirely — ffprobe once vouched
        // for it, and a 264-byte sniff must never overrule that verdict and
        // feed the prune chain. ffprobe re-judges it below.
        let extLower = url.pathExtension.lowercased()
        if MediaSignatures.needsSniff(pathExtension: extLower,
                                      videoExtensions: videoExtensions,
                                      audioExtensions: audioExtensions),
           !catalogedPaths.contains(path),
           case .noMediaSignature = MediaSignatures.sniff(path: path) {
            var o = ProbeOutcome()
            o.filename            = url.lastPathComponent
            o.ext                 = url.pathExtension.uppercased()
            o.fullPath            = path
            o.directory           = url.deletingLastPathComponent().path
            o.sizeBytes           = fileSize
            o.size                = Formatting.humanSize(fileSize)
            o.probe.isPlayable    = "No media signature"
            o.notes               = "Content sniff found no media container signature in the file header — ffprobe skipped"
            o.probe.streamTypeRaw = StreamType.ffprobeFailed.rawValue
            o.sniffRejected       = true
            return o
        }

        // autoreleasepool drains Obj-C bridged objects (DateFormatter, NSString,
        // FileManager internals) created during record population
        var outcome: ProbeOutcome = autoreleasepool {
            var o = ProbeOutcome()
            o.filename  = url.lastPathComponent
            o.ext       = url.pathExtension.uppercased()
            o.fullPath  = path
            o.directory = url.deletingLastPathComponent().path

            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd HH:mm:ss"
            o.sizeBytes       = fileSize
            o.size            = Formatting.humanSize(fileSize)
            // Reject impossible dates (future, before 1900, or the
            // known 2040-02-06 06:28:16 UTC sentinel from Rick's old
            // MacPro PRAM-dead scan) so they never enter the catalog.
            // See DateValidation.swift for the predicates + tests.
            o.dateModifiedRaw = pfDateOrNilIfImpossible(attrs?[.modificationDate] as? Date)
            o.dateCreatedRaw  = pfDateOrNilIfImpossible(attrs?[.creationDate] as? Date)
            o.dateModified    = o.dateModifiedRaw.map { df.string(from: $0) } ?? ""
            o.dateCreated     = o.dateCreatedRaw.map { df.string(from: $0) } ?? ""

            // partialMD5 is the strong identity key for duplicate detection.
            // Skip reads ~64 KB per file, which is free on local SSD but costs
            // real seconds over SMB on thousands of files. skipHashing trades
            // dup detection for a faster pass — user can run "Analyze
            // Duplicates" later if they change their mind.
            o.partialMD5 = skipHashing ? "" : FileHasher.partialMD5(path: path)
            // Segmented content hash — the identity strong enough to
            // authorize deletion (see FileHasher). Rides the SAME
            // skipHashing gate: it is three 1 MiB reads, negligible on
            // local SSD and deliberately skippable over SMB.
            o.contentHash = skipHashing ? "" : FileHasher.segmentedHash(path: path)
            return o
        }

        // Prefetch file header to RAM disk for fast ffprobe
        let (probeURL, tempFile) = await prefetchIfNeeded(
            url: url,
            fileSize: fileSize,
            prefetchToRAM: prefetchToRAM,
            ramPath: ramPath
        )

        // The subprocess gets its own deadline equal to the probe timeout.
        // The task-group race in probeFileWithTimeout alone cannot bound a
        // stuck ffprobe: throwing out of a task group still AWAITS child
        // cleanup, and cancellation only SIGTERMs the child — a process
        // wedged in uninterruptible I/O on a dead volume never exits, so the
        // group (and the whole scan) used to hang forever. The deadline
        // escalates SIGTERM → SIGKILL → abandon inside ProcessRunner, making
        // the blocking work itself bounded.
        let probeResult = await CombineVerifier.runFFProbe(
            url: probeURL,
            ffprobePath: ffprobePath,
            timeoutSeconds: Double(probeTimeoutSeconds)
        )
        let stderrTrimmed = probeResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)

        ScanEngine.applyProbeOrFallback(outcome: &outcome, url: url, path: path,
                                        probe: probeResult.output, stderrTrimmed: stderrTrimmed)

        // Clean up temp file
        if let tmp = tempFile {
            try? fm.removeItem(at: tmp)
        }

        // Cache the result — but don't cache ffprobe failures, so future runs
        // with improved fallback parsers can retry them.
        if outcome.probe.streamTypeRaw != StreamType.ffprobeFailed.rawValue {
            metadataCache.store(outcome: outcome, fileSize: fileSize, modDate: modDate)
        }

        // Stamp scan-time provenance. Done after caching so the SQLite cache
        // schema stays stable — scanContext lives in catalog.json only and is
        // recaptured fresh on every scan.
        outcome.scanContext = ScanContext.capture(for: url, scanRootPath: scanRootPath)
        return outcome
    }

    /// If prefetchToRAM is enabled and a RAM path is available, copy the
    /// file's header to the RAM disk and return the staged URL (plus a temp
    /// file for later cleanup). Falls back to the original URL on failure.
    /// Retries up to 3 times with exponential backoff on network volumes.
    nonisolated func prefetchIfNeeded(
        url: URL,
        fileSize: Int64,
        prefetchToRAM: Bool,
        ramPath: String?
    ) async -> (probeURL: URL, tempFile: URL?) {
        guard prefetchToRAM, let rp = ramPath else { return (url, nil) }
        let prefetchStart = CFAbsoluteTimeGetCurrent()
        let tmpName = "\(UUID().uuidString)_\(url.lastPathComponent)"
        let tmpURL = URL(fileURLWithPath: rp).appendingPathComponent(tmpName)

        let backoffSeconds: [UInt64] = [1, 3, 9]
        var succeeded = false

        for attempt in 0...backoffSeconds.count {
            if prefetchHeader(from: url, to: tmpURL, bytes: prefetchBytes) {
                succeeded = true
                break
            }
            if attempt < backoffSeconds.count {
                if !VolumeReachability.isReachable(path: url.deletingLastPathComponent().path) {
                    break
                }
                try? await Task.sleep(nanoseconds: backoffSeconds[attempt] * 1_000_000_000)
            }
        }

        guard succeeded else { return (url, nil) }

        let elapsed = CFAbsoluteTimeGetCurrent() - prefetchStart
        let mbCopied = Double(min(prefetchBytes, Int(fileSize))) / (1024.0 * 1024.0)
        await MainActor.run { [elapsed, mbCopied] in
            self.dashboard.recordNetworkPrefetch(megabytesCopied: mbCopied, seconds: elapsed)
        }
        return (tmpURL, tmpURL)
    }

    /// Copy the first N bytes of a file to a destination. Used to prefetch
    /// network file headers to RAM disk for fast ffprobe access.
    nonisolated func prefetchHeader(from src: URL, to dst: URL, bytes: Int) -> Bool {
        // Use read() instead of mmap() — mmap on network files can SIGBUS
        // if the remote volume becomes unreachable mid-read.
        let fd = open(src.path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var sb = stat()
        guard fstat(fd, &sb) == 0 else { return false }
        let readLen = min(bytes, Int(sb.st_size))
        guard readLen > 0 else { return false }

        // Read into buffer then write to RAM disk
        let buf = UnsafeMutableRawPointer.allocate(byteCount: readLen, alignment: 16)
        defer { buf.deallocate() }

        var totalRead = 0
        while totalRead < readLen {
            let n = read(fd, buf.advanced(by: totalRead), readLen - totalRead)
            if n <= 0 { break }
            totalRead += n
        }
        guard totalRead > 0 else { return false }

        let data = Data(bytesNoCopy: buf, count: totalRead, deallocator: .none)
        do {
            try data.write(to: dst)
            return true
        } catch {
            return false
        }
    }
}
