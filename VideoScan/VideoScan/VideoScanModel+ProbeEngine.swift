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
// without bouncing back. The recipe layer that orchestrates these tools
// lives in VideoScanModel+ScanExecution.swift.
//
// The two probe-engine stored constants (prefetchBytes, probeTimeoutSeconds)
// stay in the main class because extensions can't add stored properties.

extension VideoScanModel {

    /// Streams `target.searchPath` and drains a probe group against it.
    /// Returns the collected records, total discovered, and total completed.
    func runTargetProbeGroup(
        target: CatalogScanTarget,
        root: String,
        volName: String,
        rootIsNetwork: Bool,
        ramMountPoint: String?,
        keepalive: VolumeKeepalive? = nil
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

        let stream = walkDirectoryStream(
            root: root,
            skipDirs: skipDirsSnapshot(),
            skipBundleExtensions: skipBundleExtensionsSnapshot(),
            skipSmallFiles: scanOptions.skipSmallFiles
        ) { [weak self] currentDir in
            Task { @MainActor in
                guard let self else { return }
                self.dashboard.scanCurrentVolume = volName
                self.dashboard.scanCurrentFile = "📂 " + currentDir.lastPathComponent
            }
        }

        await withTaskGroup(of: VideoRecord.self) { probeGroup in
            for await url in stream {
                if Task.isCancelled { break }
                discoveredCount += 1
                allDiscoveredPaths.append(url.path)
                let currentDiscovered = discoveredCount
                await MainActor.run {
                    let ds = self.dashboard
                    ds.scanTotal += 1
                    if let idx = ds.volumeProgress.firstIndex(where: { $0.rootPath == root }) {
                        ds.volumeProgress[idx].totalFiles = currentDiscovered
                    }
                }
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
                                echoFilename: false
                            )
                        }
                    } catch {
                        return self.cancelledProbeRecord(url: url)
                    }
                }
            }

            let totalFiles = discoveredCount
            target.filesFound = totalFiles
            await MainActor.run {
                if let idx = self.dashboard.volumeProgress.firstIndex(where: { $0.rootPath == root }) {
                    self.dashboard.volumeProgress[idx].isWalking = false
                }
            }
            log("  Found \(totalFiles) video files on \(volName)")

            // Save checkpoint after walk completes so a crash during probing
            // can resume without re-walking the entire directory tree.
            if rootIsNetwork {
                let checkpoint = ScanCheckpoint(
                    volumePath: root,
                    startedAt: Date(),
                    discoveredPaths: allDiscoveredPaths,
                    totalDiscovered: totalFiles,
                    skipChecksums: skipHashingCaptured
                )
                ScanCheckpointStorage.save(checkpoint)
                log("  💾 Checkpoint saved (\(totalFiles) files) — scan is resumable if interrupted")
            }

            for await rec in probeGroup {
                targetRecords.append(rec)
                completedCount += 1

                // If keepalive detected volume recovery, reset the consecutive
                // failure counter so transient outages don't accumulate toward
                // the abort threshold.
                if let ka = keepalive {
                    let volDown = await ka.volumeIsDown
                    if !volDown && consecutiveNotAccessible > 0 && rec.streamTypeRaw != StreamType.ffprobeFailed.rawValue {
                        consecutiveNotAccessible = 0
                    }
                }

                let shouldAbort = processTargetProbeResult(
                    rec: rec,
                    volName: volName,
                    completedCount: completedCount,
                    totalFiles: totalFiles,
                    target: target,
                    consecutiveNotAccessible: &consecutiveNotAccessible,
                    loggedMilestones: &loggedMilestones,
                    milestones: milestones,
                    abortAfter: abortAfter
                )
                if shouldAbort {
                    probeGroup.cancelAll()
                    break
                }
            }
        }
        return (targetRecords, discoveredCount, completedCount)
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
        skipChecksums: Bool
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

        target.filesFound = totalFiles
        dashboard.volumeProgress.append(
            VolumeProgress(rootPath: root, volumeName: volName)
        )

        await withTaskGroup(of: VideoRecord.self) { probeGroup in
            for path in filePaths {
                if Task.isCancelled { break }
                let url = URL(fileURLWithPath: path)
                dashboard.scanTotal += 1

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
                                echoFilename: false
                            )
                        }
                    } catch {
                        return self.cancelledProbeRecord(url: url)
                    }
                }
            }

            for await rec in probeGroup {
                targetRecords.append(rec)
                completedCount += 1

                if let ka = keepalive {
                    let volDown = await ka.volumeIsDown
                    if !volDown && consecutiveNotAccessible > 0 && rec.streamTypeRaw != StreamType.ffprobeFailed.rawValue {
                        consecutiveNotAccessible = 0
                    }
                }

                let shouldAbort = processTargetProbeResult(
                    rec: rec,
                    volName: volName,
                    completedCount: completedCount,
                    totalFiles: totalFiles,
                    target: target,
                    consecutiveNotAccessible: &consecutiveNotAccessible,
                    loggedMilestones: &loggedMilestones,
                    milestones: milestones,
                    abortAfter: abortAfter
                )
                if shouldAbort {
                    probeGroup.cancelAll()
                    break
                }
            }
        }
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
        onDirectoryEntered: (@Sendable (_ currentDir: URL) -> Void)? = nil
    ) -> AsyncStream<URL> {
        FilesystemWalker.walkDirectoryStream(
            root: root,
            videoExtensions: videoExtensions,
            skipDirs: skipDirs,
            skipBundleExtensions: skipBundleExtensions,
            skipSmallFiles: skipSmallFiles,
            onDirectoryEntered: onDirectoryEntered
        )
    }

    nonisolated func cancelledProbeRecord(url: URL) -> VideoRecord {
        let rec = VideoRecord()
        rec.filename      = url.lastPathComponent
        rec.ext           = url.pathExtension.uppercased()
        rec.fullPath      = url.path
        rec.directory     = url.deletingLastPathComponent().path
        rec.isPlayable    = "Cancelled"
        rec.notes         = "Probe cancelled before acquiring a concurrency permit"
        rec.streamTypeRaw = StreamType.ffprobeFailed.rawValue
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
    nonisolated func probeFileWithTimeout(url: URL, prefetchToRAM: Bool = false, ramPath: String? = nil, skipHashing: Bool = false, scanRootPath: String? = nil) async -> VideoRecord {
        // Best-effort stat before the race. stat() is metadata-only and
        // usually fast even on SMB when content reads stall. We use this only
        // to populate the timeout record; probeFile re-fetches on its own
        // path for the success case.
        let preSize: Int64 = {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            return (attrs?[.size] as? Int64) ?? 0
        }()

        do {
            return try await withThrowingTaskGroup(of: VideoRecord.self) { group in
                group.addTask {
                    await self.probeFile(url: url, prefetchToRAM: prefetchToRAM, ramPath: ramPath, skipHashing: skipHashing, scanRootPath: scanRootPath)
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
            // Timeout fired before probeFile completed
            let rec = VideoRecord()
            rec.filename      = url.lastPathComponent
            rec.ext           = url.pathExtension.uppercased()
            rec.fullPath      = url.path
            rec.directory     = url.deletingLastPathComponent().path
            rec.sizeBytes     = preSize
            rec.isPlayable    = "Timed out"
            rec.notes         = "File probe exceeded \(probeTimeoutSeconds)s — network I/O may be stalled"
            rec.streamTypeRaw = StreamType.ffprobeFailed.rawValue
            return rec
        }
    }

    /// Probe a single file and return a populated VideoRecord.
    /// If prefetchToRAM is true and ramPath is available, copies the first 10MB
    /// to the RAM disk so ffprobe reads at memory speed instead of network speed.
    nonisolated func probeFile(url: URL, prefetchToRAM: Bool = false, ramPath: String? = nil, skipHashing: Bool = false, scanRootPath: String? = nil) async -> VideoRecord {
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
            let rec = VideoRecord()
            rec.filename      = url.lastPathComponent
            rec.ext           = url.pathExtension.uppercased()
            rec.fullPath      = path
            rec.directory     = url.deletingLastPathComponent().path
            rec.isPlayable    = "File not found"
            rec.notes         = "File was discovered during scan but is no longer accessible"
            rec.streamTypeRaw = StreamType.ffprobeFailed.rawValue
            return rec
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
        if let cached = metadataCache.lookup(path: path, fileSize: fileSize, modDate: modDate) {
            cached.wasCacheHit = true
            cached.scanContext = ScanContext.capture(for: url, scanRootPath: scanRootPath)
            return cached
        }

        // autoreleasepool drains Obj-C bridged objects (DateFormatter, NSString,
        // FileManager internals) created during record population
        let rec: VideoRecord = autoreleasepool {
            let r = VideoRecord()
            r.filename  = url.lastPathComponent
            r.ext       = url.pathExtension.uppercased()
            r.fullPath  = path
            r.directory = url.deletingLastPathComponent().path

            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd HH:mm:ss"
            r.sizeBytes       = fileSize
            r.size            = Formatting.humanSize(fileSize)
            // Reject impossible dates (future, before 1900, or the
            // known 2040-02-06 06:28:16 UTC sentinel from Rick's old
            // MacPro PRAM-dead scan) so they never enter the catalog.
            // See DateValidation.swift for the predicates + tests.
            r.dateModifiedRaw = pfDateOrNilIfImpossible(attrs?[.modificationDate] as? Date)
            r.dateCreatedRaw  = pfDateOrNilIfImpossible(attrs?[.creationDate] as? Date)
            r.dateModified    = r.dateModifiedRaw.map { df.string(from: $0) } ?? ""
            r.dateCreated     = r.dateCreatedRaw.map { df.string(from: $0) } ?? ""

            // partialMD5 is the strong identity key for duplicate detection.
            // Skip reads ~64 KB per file, which is free on local SSD but costs
            // real seconds over SMB on thousands of files. skipHashing trades
            // dup detection for a faster pass — user can run "Analyze
            // Duplicates" later if they change their mind.
            r.partialMD5 = skipHashing ? "" : FileHasher.partialMD5(path: path)
            return r
        }

        // Prefetch file header to RAM disk for fast ffprobe
        let (probeURL, tempFile) = await prefetchIfNeeded(
            url: url,
            fileSize: fileSize,
            prefetchToRAM: prefetchToRAM,
            ramPath: ramPath
        )

        let probeResult = await CombineVerifier.runFFProbe(url: probeURL, ffprobePath: ffprobePath)
        let stderrTrimmed = probeResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)

        ScanEngine.applyProbeOrFallback(rec: rec, url: url, path: path,
                                        probe: probeResult.output, stderrTrimmed: stderrTrimmed)

        // Clean up temp file
        if let tmp = tempFile {
            try? fm.removeItem(at: tmp)
        }

        // Cache the result — but don't cache ffprobe failures, so future runs
        // with improved fallback parsers can retry them.
        if rec.streamTypeRaw != StreamType.ffprobeFailed.rawValue {
            metadataCache.store(record: rec, fileSize: fileSize, modDate: modDate)
        }

        // Stamp scan-time provenance. Done after caching so the SQLite cache
        // schema stays stable — scanContext lives in catalog.json only and is
        // recaptured fresh on every scan.
        rec.scanContext = ScanContext.capture(for: url, scanRootPath: scanRootPath)
        return rec
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
