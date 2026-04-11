import Foundation
import CryptoKit
import SwiftUI
import Combine
import Darwin
import AVFoundation
import SQLite3

// MARK: - Performance Settings

struct ScanPerformanceSettings {
    var probesPerVolume: Int = 8          // concurrent ffprobe processes per volume
    var ramDiskGB: Int = 16               // RAM disk size for network prefetch (GB)
    var prefetchMB: Int = 50              // bytes to prefetch from network files (MB)
    var combineConcurrency: Int = 4       // concurrent ffmpeg combine processes
    var memoryFloorGB: Int = 4            // auto-pause when available RAM drops below this (GB)

    // MARK: Persistence

    private static let defaults = UserDefaults.standard
    private static let prefix = "perf_"

    static func restored() -> ScanPerformanceSettings {
        let d = defaults; let p = prefix
        var s = ScanPerformanceSettings()
        if d.object(forKey: "\(p)probesPerVolume") != nil    { s.probesPerVolume = d.integer(forKey: "\(p)probesPerVolume") }
        if d.object(forKey: "\(p)ramDiskGB") != nil          { s.ramDiskGB = d.integer(forKey: "\(p)ramDiskGB") }
        if d.object(forKey: "\(p)prefetchMB") != nil         { s.prefetchMB = d.integer(forKey: "\(p)prefetchMB") }
        if d.object(forKey: "\(p)combineConcurrency") != nil { s.combineConcurrency = d.integer(forKey: "\(p)combineConcurrency") }
        if d.object(forKey: "\(p)memoryFloorGB") != nil      { s.memoryFloorGB = d.integer(forKey: "\(p)memoryFloorGB") }
        return s
    }

    func save() {
        let d = Self.defaults; let p = Self.prefix
        d.set(probesPerVolume,    forKey: "\(p)probesPerVolume")
        d.set(ramDiskGB,          forKey: "\(p)ramDiskGB")
        d.set(prefetchMB,        forKey: "\(p)prefetchMB")
        d.set(combineConcurrency, forKey: "\(p)combineConcurrency")
        d.set(memoryFloorGB,     forKey: "\(p)memoryFloorGB")
    }
}

// MARK: - Model

@MainActor
final class VideoScanModel: ObservableObject {
    @Published var records: [VideoRecord] = []
    @Published var isScanning: Bool = false
    @Published var isCombining: Bool = false
    @Published var avidBinResults: [AvbBinResult] = []
    @Published var scanTargets: [CatalogScanTarget] = []
    @Published var outputCSVPath: String = ""
    @Published var previewImage: NSImage? = nil
    @Published var previewFilename: String = ""
    /// Set when the user selects a record whose source volume isn't currently
    /// mounted. CatalogContent renders an "Volume Offline" placeholder
    /// instead of trying to load a thumbnail.
    @Published var previewOfflineVolumeName: String? = nil

    /// High-frequency dashboard + console state — separate ObservableObject
    /// so updates don't trigger re-render of the main Table view.
    let dashboard = DashboardState()

    /// Thumbnail cache — keyed by fullPath, avoids regenerating from video file on re-click
    private let thumbnailCache = NSCache<NSString, NSImage>()

    let ffprobePath = "/opt/homebrew/bin/ffprobe"
    let ffmpegPath  = "/opt/homebrew/bin/ffmpeg"

    let videoExtensions: Set<String> = [
        "mov","mp4","m4v","avi","mkv","mxf","mts","m2ts","ts","mpg","mpeg",
        "m2v","vob","wmv","asf","webm","ogv","ogg","rm","rmvb","divx","flv",
        "f4v","3gp","3g2","dv","dif","braw","r3d","vro","mod","tod"
    ]

    let skipDirs: Set<String> = [
        ".spotlight-v100",".fseventsd",".trashes",".temporaryitems",
        ".documentrevisions-v100",".vol","automount"
    ]

    private var scanTask: Task<Void, Never>?
    private var combineTask: Task<Void, Never>?
    private var ramDisk = RAMDisk()
    nonisolated private let metadataCache = MetadataCache()

    /// Cooperative pause gate for scan tasks
    let pauseGate = PauseGate()
    @Published var isPaused: Bool = false

    /// Tuneable performance settings — persisted via UserDefaults
    @Published var perfSettings = ScanPerformanceSettings.restored() {
        didSet {
            perfSettings.save()
            Task { await MemoryPressureMonitor.shared.setFloorGB(perfSettings.memoryFloorGB) }
        }
    }

    private static let savedTargetsKey = "VideoScan.scanTargetPaths"

    private let catalogStore = CatalogStore.shared

    init() {
        restoreScanTargets()
        // Restore previously-scanned records so the user can browse the
        // catalog even when source volumes are offline.
        let restored = catalogStore.load()
        if !restored.isEmpty {
            records = restored
            log("Restored \(restored.count) records from previous session.")
        }
        // Backfill: for any scan target that has zero records in the restored
        // snapshot, pull whatever the SQLite metadata cache has under that
        // path. This covers volumes scanned by builds older than catalog.json
        // persistence — without this, View Catalog shows (0) for offline
        // volumes even though the ffprobe cache is full of their files.
        var backfilled = 0
        for t in scanTargets where !t.searchPath.isEmpty {
            let already = records.contains { $0.fullPath.hasPrefix(t.searchPath) }
            if already { continue }
            let cached = metadataCache.allRecordsWithPrefix(t.searchPath)
            if !cached.isEmpty {
                records.append(contentsOf: cached)
                backfilled += cached.count
                log("Backfilled \(cached.count) records for \(URL(fileURLWithPath: t.searchPath).lastPathComponent) from metadata cache.")
            }
        }
        if backfilled > 0 {
            // Persist the merged set so subsequent launches skip the backfill.
            catalogStore.scheduleSave(records: records)
        }
        installVolumeMountObservers()
        refreshTargetReachability()
    }

    private var mountObservers: [NSObjectProtocol] = []

    /// Listen for drive mount/unmount events so the Scan Target list can
    /// flip its offline indicator without polling.
    private func installVolumeMountObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        let mount = nc.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshTargetReachability() }
        }
        let unmount = nc.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshTargetReachability() }
        }
        mountObservers = [mount, unmount]
    }

    /// Re-check whether each scan target's path is currently mounted.
    func refreshTargetReachability() {
        for t in scanTargets {
            let r = VolumeReachability.isReachable(path: t.searchPath)
            if t.isReachable != r { t.isReachable = r }
        }
    }

    /// Persist the current records array. Debounced; bursts of mutations
    /// (e.g. mid-scan) collapse into one disk write.
    func saveCatalogDebounced() {
        catalogStore.scheduleSave(records: records)
    }

    /// Synchronous save — call from `applicationWillTerminate` so the
    /// snapshot is on disk before the process exits.
    func saveCatalogNow() {
        catalogStore.saveNow(records: records)
    }

    private func restoreScanTargets() {
        let paths = UserDefaults.standard.stringArray(forKey: Self.savedTargetsKey) ?? []
        for p in paths where !p.isEmpty {
            if !scanTargets.contains(where: { $0.searchPath == p }) {
                scanTargets.append(CatalogScanTarget(searchPath: p))
            }
        }
    }

    private func persistScanTargets() {
        let paths = scanTargets.map { $0.searchPath }
        UserDefaults.standard.set(paths, forKey: Self.savedTargetsKey)
    }

    // MARK: - Logging (delegates to DashboardState)

    func log(_ msg: String) { dashboard.log(msg) }
    func clearConsole() { dashboard.clearConsole() }

    func clearResults() {
        records = []
        outputCSVPath = ""
        previewImage = nil
        previewFilename = ""
        previewOfflineVolumeName = nil
        saveCatalogNow()
    }

    func clearCache() -> Int {
        let before = metadataCache.count
        metadataCache.clearAll()
        let after = metadataCache.count
        log("━━ Metadata cache cleared: \(before) → \(after) entries (DB VACUUM done) ━━")
        return before
    }

    /// Drop cached probe results whose path lives under `target.searchPath`.
    /// Called from per-target Reset and per-target Trash so a re-scan of the same
    /// volume actually re-runs ffprobe instead of returning instantly from cache.
    func clearCacheForTarget(_ target: CatalogScanTarget) {
        let path = target.searchPath
        guard !path.isEmpty else { return }
        let dropped = metadataCache.clearForPathPrefix(path)
        if dropped > 0 {
            log("  Dropped \(dropped) cached probe entries under \(path)")
        }
    }

    func resetTarget(_ target: CatalogScanTarget) {
        target.reset()
        clearCacheForTarget(target)
        // Also drop in-memory records that came from this target so the table reflects the reset
        records.removeAll { $0.fullPath.hasPrefix(target.searchPath) }
    }

    var cacheCount: Int { metadataCache.count }

    // MARK: - Avid Bin Scanning

    /// Scan all scan target paths for .avb files and parse them.
    func scanAvidBins() {
        let paths = scanTargets.map { $0.searchPath }.filter { !$0.isEmpty }
        guard !paths.isEmpty else {
            log("No scan targets configured — add a volume first.")
            return
        }

        log("━━ Scanning for Avid bin files (.avb) ━━")
        avidBinResults = []

        Task {
            var allResults: [AvbBinResult] = []
            for path in paths {
                await MainActor.run {
                    log("  Searching \(path) for .avb files…")
                }
                let results = await Task.detached(priority: .userInitiated) {
                    AvbParser.scanDirectory(path)
                }.value
                allResults.append(contentsOf: results)
            }

            await MainActor.run {
                self.avidBinResults = allResults
                let totalClips = allResults.reduce(0) { $0 + $1.clips.count }
                let totalBins = allResults.count
                let errorCount = allResults.reduce(0) { $0 + $1.errors.count }

                log("  Found \(totalBins) .avb files containing \(totalClips) clips")
                if errorCount > 0 {
                    log("  ⚠ \(errorCount) parse errors — some bins may use newer format features")
                }

                for result in allResults {
                    if !result.errors.isEmpty {
                        log("  \(result.binName).avb: \(result.errors.joined(separator: ", "))")
                    }
                    for clip in result.clips where clip.mobType == "MasterMob" {
                        let trackDesc = clip.tracks.map { t in
                            let kind = t.mediaKind == "picture" ? "V" : (t.mediaKind == "sound" ? "A" : String(t.mediaKind.prefix(2)).uppercased())
                            return "\(kind)\(t.index)"
                        }.joined(separator: ", ")
                        let tapeStr = clip.tapeName.isEmpty ? "" : " tape:\(clip.tapeName)"
                        let pathStr = clip.mediaPath.isEmpty ? "" : " \(clip.mediaPath)"
                        log("    \(clip.clipName)  [\(trackDesc)]\(tapeStr)\(pathStr)")
                    }
                }

                // Auto cross-reference with existing records
                crossReferenceAvidBins()
            }
        }
    }

    /// Cross-reference parsed Avid bin clips with scanned MXF records.
    /// Matching is done by filename stem and media path patterns since
    /// MXF UMID extraction via ffprobe requires specific format flags.
    func crossReferenceAvidBins() {
        guard !avidBinResults.isEmpty, !records.isEmpty else { return }

        // Build lookup tables from Avid clips
        // Key: lowercased filename stem from mediaPath → clip
        var clipsByMediaFilename: [String: AvbClip] = [:]
        // Key: material UUID → clip
        var clipsByMaterialUUID: [String: AvbClip] = [:]

        for result in avidBinResults {
            for clip in result.clips {
                // Index by media path filename
                if !clip.mediaPath.isEmpty {
                    let mediaFilename = URL(fileURLWithPath: clip.mediaPath).lastPathComponent.lowercased()
                    clipsByMediaFilename[mediaFilename] = clip
                }
                if !clip.mediaPathPosix.isEmpty {
                    let mediaFilename = URL(fileURLWithPath: clip.mediaPathPosix).lastPathComponent.lowercased()
                    clipsByMediaFilename[mediaFilename] = clip
                }
                // Index by material UUID
                if !clip.materialUUID.isEmpty {
                    clipsByMaterialUUID[clip.materialUUID.lowercased()] = clip
                }
            }
        }

        var matchCount = 0
        for record in records {
            // Try matching by filename (most reliable for MXF files)
            let recFilename = record.filename.lowercased()
            if let clip = clipsByMediaFilename[recFilename] {
                applyAvidMetadata(clip: clip, to: record)
                matchCount += 1
                continue
            }

            // Try matching by partial path — the MXF filename might be under
            // Avid MediaFiles/MXF/n/ and the media path in the bin points there
            for (mediaFilename, clip) in clipsByMediaFilename {
                if recFilename == mediaFilename ||
                   record.fullPath.lowercased().hasSuffix(mediaFilename) {
                    applyAvidMetadata(clip: clip, to: record)
                    matchCount += 1
                    break
                }
            }
        }

        if matchCount > 0 {
            log("━━ Cross-referenced \(matchCount) media files with Avid bin metadata ━━")
        } else {
            log("  No matches found between Avid bins and scanned media (bins may reference different volumes)")
        }
    }

    private func applyAvidMetadata(clip: AvbClip, to record: VideoRecord) {
        record.avidClipName = clip.clipName
        record.avidMobID = clip.mobID
        record.avidMaterialUUID = clip.materialUUID
        record.avidBinFile = clip.binFileName
        record.avidMobType = clip.mobType
        record.avidMediaPath = clip.mediaPath.isEmpty ? clip.mediaPathPosix : clip.mediaPath
        record.avidTapeName = clip.tapeName
        record.avidEditRate = clip.editRate

        let trackDesc = clip.tracks.map { t in
            let kind = t.mediaKind == "picture" ? "V" : (t.mediaKind == "sound" ? "A" : t.mediaKind.prefix(2).uppercased())
            return "\(kind)\(t.index)"
        }.joined(separator: ", ")
        record.avidTracks = trackDesc

        // Fill in tape name if record doesn't already have one
        if record.tapeName.isEmpty && !clip.tapeName.isEmpty {
            record.tapeName = clip.tapeName
        }
    }

    func startScan(roots: [String]) {
        records = []
        outputCSVPath = ""
        isScanning = true
        dashboard.resetForScan()

        scanTask = Task {
            await runParallelScan(roots: roots)
        }
    }

    func stopScan() {
        scanTask?.cancel()
        scanTask = nil
        Task {
            await pauseGate.resume()  // release any waiters before cancel
            await ramDisk.unmount()
        }
        log("--- Scan stopped by user ---")
        isScanning = false
        isPaused = false
        dashboard.scanPhase = .idle
    }

    func pauseScan() {
        guard isScanning, !isPaused else { return }
        Task { await pauseGate.pause() }
        isPaused = true
        log("--- Scan paused ---")
    }

    func resumeScan() {
        guard isScanning, isPaused else { return }
        Task { await pauseGate.resume() }
        isPaused = false
        log("--- Scan resumed ---")
    }

    func togglePause() {
        if isPaused { resumeScan() } else { pauseScan() }
    }

    // MARK: - Scan Target Management

    func addScanTarget() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "Select volumes or folders to scan (⌘-click for multiple)"
        panel.prompt = "Add"
        if panel.runModal() == .OK {
            for url in panel.urls {
                let path = url.path
                if !scanTargets.contains(where: { $0.searchPath == path }) {
                    scanTargets.append(CatalogScanTarget(searchPath: path))
                }
            }
            persistScanTargets()
        }
    }

    func removeScanTarget(_ target: CatalogScanTarget) {
        target.scanTask?.cancel()
        target.stopElapsedTimer()
        clearCacheForTarget(target)
        records.removeAll { $0.fullPath.hasPrefix(target.searchPath) }
        scanTargets.removeAll { $0.id == target.id }
        persistScanTargets()
        saveCatalogNow()
    }

    func startTarget(_ target: CatalogScanTarget) {
        guard !target.searchPath.isEmpty else { return }
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
    private func updateDashboardPauseState() {
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
        for target in scanTargets where target.status.isIdle || target.status == .stopped {
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

    private func updateGlobalScanState() {
        isScanning = scanTargets.contains { $0.status.isActive }
    }

    /// Scan a single target's path, appending results to the shared records array
    private func runScanForTarget(_ target: CatalogScanTarget) async {
        let root = target.searchPath
        let volName = URL(fileURLWithPath: root).lastPathComponent

        guard FileManager.default.fileExists(atPath: ffprobePath) else {
            log("ERROR: ffprobe not found at \(ffprobePath)\nInstall with: brew install ffmpeg")
            target.status = .error
            target.stopElapsedTimer()
            updateGlobalScanState()
            return
        }

        let rootIsNetwork = isNetworkPath(root)
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

        // Phase 1: Discover files
        let files = await walkDirectory(root: root)
        if Task.isCancelled { target.status = .stopped; target.stopElapsedTimer(); updateGlobalScanState(); return }

        target.filesFound = files.count
        target.status = .scanning
        log("  Found \(files.count) video files on \(volName)")
        // Update dashboard with discovered count and flip into probing phase.
        if let idx = dashboard.volumeProgress.firstIndex(where: { $0.rootPath == root }) {
            dashboard.volumeProgress[idx].totalFiles = files.count
            dashboard.volumeProgress[idx].isWalking = false
        }
        dashboard.scanTotal += files.count
        dashboard.scanPhase = .probing

        if files.isEmpty {
            log("  No video files found on \(volName).")
            target.status = .complete
            target.stopElapsedTimer()
            updateGlobalScanState()
            return
        }

        // Phase 2: Probe files
        let probesLimit = perfSettings.probesPerVolume

        var ramMountPoint: String? = nil
        if rootIsNetwork {
            let ramDiskMB = perfSettings.ramDiskGB * 1024
            let mounted = await ramDisk.mount(sizeMB: ramDiskMB)
            ramMountPoint = await ramDisk.mountPoint
            if mounted, let mp = ramMountPoint {
                log("  RAM disk mounted at \(mp) (\(perfSettings.ramDiskGB) GB) for network prefetch")
            } else {
                log("  WARN: RAM disk unavailable, probing network files directly")
            }
        }

        var targetRecords: [VideoRecord] = []
        let sem = AsyncSemaphore(limit: probesLimit)
        let totalFiles = files.count
        // Track milestones to avoid per-file UI updates (beachball prevention)
        let milestones = Set([10, 25, 50, 75, 90, 100])
        var loggedMilestones: Set<Int> = []
        var completedCount = 0

        await withTaskGroup(of: VideoRecord.self) { probeGroup in
            for (_, url) in files.enumerated() {
                if Task.isCancelled { break }
                probeGroup.addTask { [self] in
                    await target.pauseGate.waitIfPaused()
                    return await sem.withPermit {
                        if Task.isCancelled {
                            return await MainActor.run {
                                let skip = VideoRecord()
                                skip.filename = url.lastPathComponent
                                skip.streamTypeRaw = StreamType.ffprobeFailed.rawValue
                                return skip
                            }
                        }
                        await MainActor.run {
                            self.dashboard.recordScanFile(
                                volume: volName,
                                filename: url.lastPathComponent
                            )
                        }
                        let rec = await self.probeFile(
                            url: url,
                            prefetchToRAM: rootIsNetwork,
                            ramPath: ramMountPoint
                        )
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
                }
            }
            for await rec in probeGroup {
                targetRecords.append(rec)
                completedCount += 1
                // Log ffprobe failures with detail
                if rec.streamTypeRaw == StreamType.ffprobeFailed.rawValue {
                    let detail = rec.notes.isEmpty ? "no detail available" : rec.notes
                    log("  ⚠ FAILED: \(rec.filename) — \(detail)")
                }
                // Batch UI updates: only at milestones or every 20 files
                let pct = totalFiles > 0 ? (completedCount * 100 / totalFiles) : 100
                let shouldUpdate = completedCount % 20 == 0 || completedCount == totalFiles
                    || milestones.contains(pct) && !loggedMilestones.contains(pct)
                if shouldUpdate {
                    if milestones.contains(pct) { loggedMilestones.insert(pct) }
                    target.filesScanned = completedCount
                    log("  [\(volName)] \(completedCount)/\(totalFiles) (\(pct)%)")
                }
            }
        }
        // Final count sync
        target.filesScanned = completedCount

        // Unmount RAM disk if we mounted one
        if rootIsNetwork { await ramDisk.unmount() }

        if Task.isCancelled {
            target.status = .stopped
            target.stopElapsedTimer()
            updateGlobalScanState()
            return
        }

        // Append results to shared records and persist the snapshot.
        records.append(contentsOf: targetRecords)
        saveCatalogDebounced()

        let va = targetRecords.filter { $0.streamTypeRaw == StreamType.videoAndAudio.rawValue }.count
        let vo = targetRecords.filter { $0.streamTypeRaw == StreamType.videoOnly.rawValue }.count
        let ao = targetRecords.filter { $0.streamTypeRaw == StreamType.audioOnly.rawValue }.count

        log("""

        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
          Scan Complete: \(volName)
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
          Total:          \(targetRecords.count)
          Video+Audio:    \(va)
          Video only:     \(vo)
          Audio only:     \(ao)
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        """)

        target.status = .complete
        target.stopElapsedTimer()
        updateGlobalScanState()
        // If this was the last active target, stop the throughput timer and
        // mark the dashboard's overall phase complete so the Realtime window
        // shows a finished scan instead of staying stuck in "probing".
        if !hasActiveTargets {
            dashboard.stopThroughputTimer()
            dashboard.scanPhase = .complete
        }
    }

    /// How many bytes to prefetch from network files to RAM disk for ffprobe.
    /// Set from perfSettings at scan start so nonisolated code can read it.
    nonisolated(unsafe) private var prefetchBytes: Int = 50 * 1024 * 1024

    /// Scan multiple volumes/folders in parallel, merge all results
    func runParallelScan(roots: [String]) async {
        // Sync performance settings for nonisolated code
        prefetchBytes = perfSettings.prefetchMB * 1024 * 1024

        guard FileManager.default.fileExists(atPath: ffprobePath) else {
            log("ERROR: ffprobe not found at \(ffprobePath)\nInstall with: brew install ffmpeg")
            isScanning = false
            return
        }

        let cacheCount = metadataCache.count
        log("Scanning \(roots.count) location\(roots.count == 1 ? "" : "s") in parallel...")
        log("  Metadata cache: \(cacheCount) entries (unchanged files skip ffprobe)\n")
        for r in roots { log("  • \(r)") }
        log("")

        // Mount RAM disk for network file prefetching — size adapts to available memory
        let hasNetworkRoot = roots.contains { isNetworkPath($0) }
        var ramMountPoint: String? = nil
        if hasNetworkRoot {
            let ramDiskMB = perfSettings.ramDiskGB * 1024
            let mounted = await ramDisk.mount(sizeMB: ramDiskMB)
            ramMountPoint = await ramDisk.mountPoint
            if mounted, let mp = ramMountPoint {
                log("  RAM disk mounted at \(mp) (\(perfSettings.ramDiskGB) GB) for network prefetch\n")
            } else {
                log("  WARN: RAM disk unavailable, probing network files directly\n")
            }
        }

        // ── Phase 1: Walk all directories in parallel to discover files ──
        dashboard.scanPhase = .discovering
        dashboard.volumeProgress = roots.map { root in
            VolumeProgress(rootPath: root, volumeName: URL(fileURLWithPath: root).lastPathComponent)
        }

        var allVideoFiles: [(root: String, url: URL)] = []

        await withTaskGroup(of: (String, [URL]).self) { group in
            for root in roots {
                let volName = URL(fileURLWithPath: root).lastPathComponent
                group.addTask { [self] in
                    let files = await self.walkDirectory(root: root) { currentDir, count, lastFile in
                        // Heartbeat: stream walk progress to the dashboard so the
                        // Realtime Catalog Scan window comes alive immediately
                        // instead of looking frozen during long network walks.
                        Task { @MainActor in
                            let ds = self.dashboard
                            ds.scanCurrentVolume = volName
                            if let f = lastFile {
                                ds.recordScanFile(volume: volName, filename: f.lastPathComponent)
                            } else {
                                ds.scanCurrentFile = "📂 " + currentDir.lastPathComponent
                            }
                            if let idx = ds.volumeProgress.firstIndex(where: { $0.rootPath == root }) {
                                ds.volumeProgress[idx].totalFiles = count
                            }
                        }
                    }
                    return (root, files)
                }
            }
            for await (root, files) in group {
                let volName = URL(fileURLWithPath: root).lastPathComponent
                log("  Found \(files.count) video files on \(volName)")
                // Update volume progress
                if let idx = dashboard.volumeProgress.firstIndex(where: { $0.rootPath == root }) {
                    dashboard.volumeProgress[idx].totalFiles = files.count
                    dashboard.volumeProgress[idx].isWalking = false
                }
                for f in files {
                    allVideoFiles.append((root, f))
                }
            }
        }

        if Task.isCancelled {
            await ramDisk.unmount()
            dashboard.scanPhase = .idle
            isScanning = false
            return
        }

        dashboard.scanTotal = allVideoFiles.count
        log("\nTotal: \(allVideoFiles.count) files across \(roots.count) location(s). Probing...\n")

        if allVideoFiles.isEmpty {
            log("No video files found.")
            await ramDisk.unmount()
            dashboard.scanPhase = .complete
            isScanning = false
            return
        }

        // ── Phase 2: Probe files ──
        dashboard.scanPhase = .probing
        dashboard.startThroughputTimer()

        var filesByRoot: [String: [URL]] = [:]
        for (root, url) in allVideoFiles {
            filesByRoot[root, default: []].append(url)
        }

        var allRecords: [VideoRecord] = []

        // Capture settings on main actor before entering task group
        let probesLimit = perfSettings.probesPerVolume

        await withTaskGroup(of: Void.self) { group in
            for (root, files) in filesByRoot {
                let rootIsNetwork = self.isNetworkPath(root)
                group.addTask { [self] in
                    let volName = URL(fileURLWithPath: root).lastPathComponent
                    let sem = AsyncSemaphore(limit: probesLimit)

                    await withTaskGroup(of: VideoRecord.self) { probeGroup in
                        for (i, url) in files.enumerated() {
                            if Task.isCancelled { break }
                            probeGroup.addTask {
                                // Pause gate: wait here if user (or memory pressure) paused
                                await self.pauseGate.waitIfPaused()
                                return await sem.withPermit {
                                    if Task.isCancelled {
                                        return await MainActor.run {
                                            let skip = VideoRecord()
                                            skip.filename = url.lastPathComponent
                                            skip.streamTypeRaw = StreamType.ffprobeFailed.rawValue
                                            return skip
                                        }
                                    }
                                    await MainActor.run {
                                        self.log("  [\(volName)] [\(i+1)/\(files.count)] \(url.lastPathComponent)")
                                        self.dashboard.recordScanFile(
                                            volume: volName,
                                            filename: url.lastPathComponent
                                        )
                                    }
                                    let rec = await self.probeFile(
                                        url: url,
                                        prefetchToRAM: rootIsNetwork,
                                        ramPath: ramMountPoint
                                    )
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
                            }
                        }
                        for await rec in probeGroup {
                            allRecords.append(rec)
                        }
                    }
                }
            }
        }

        dashboard.stopThroughputTimer()

        // Unmount RAM disk
        await ramDisk.unmount()

        if Task.isCancelled { dashboard.scanPhase = .idle; isScanning = false; return }

        // ── Phase 3: Write CSV ──
        dashboard.scanPhase = .writingCSV

        let rootLabel = roots.count == 1 ? roots[0] : "MultiVolume"
        let csvPath = writeCSV(records: allRecords, root: rootLabel)
        records = allRecords
        saveCatalogDebounced()
        outputCSVPath = csvPath ?? ""
        if let p = csvPath { log("CSV saved to:\n\(p)") }

        let va = allRecords.filter { $0.streamTypeRaw == StreamType.videoAndAudio.rawValue }.count
        let vo = allRecords.filter { $0.streamTypeRaw == StreamType.videoOnly.rawValue }.count
        let ao = allRecords.filter { $0.streamTypeRaw == StreamType.audioOnly.rawValue }.count
        let ff = allRecords.filter { $0.isPlayable.contains("ffprobe") }.count

        log("""

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Scan Complete
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Locations:      \(roots.count)
  Total:          \(allRecords.count)
  Video+Audio:    \(va)
  Video only:     \(vo)
  Audio only:     \(ao)
  ffprobe failed: \(ff)
  Cache hits:     \(dashboard.scanCacheHits)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
""")
        dashboard.scanPhase = .complete
        isScanning = false
    }

    /// Walk a single directory tree and return all video file URLs
    nonisolated func walkDirectory(
        root: String,
        onProgress: (@Sendable (_ currentDir: URL, _ filesFoundSoFar: Int, _ lastFile: URL?) -> Void)? = nil
    ) async -> [URL] {
        // Run on a detached task to avoid blocking the cooperative thread pool.
        // FileManager calls are synchronous and can stall on network volumes.
        let skipDirs = self.skipDirs
        let videoExtensions = self.videoExtensions
        let result = await Task.detached(priority: .userInitiated) {
            var videoFiles: [URL] = []
            let fm = FileManager.default
            var dirStack: [URL] = [URL(fileURLWithPath: root)]

            while !dirStack.isEmpty {
                if Task.isCancelled { break }
                let currentDir = dirStack.removeLast()
                // Heartbeat: tell the dashboard which directory we're entering.
                // This is the only signal a network walk produces — without it
                // the RT scan window looks frozen during discovery.
                onProgress?(currentDir, videoFiles.count, nil)

                let contents: [URL]
                do {
                    contents = try fm.contentsOfDirectory(
                        at: currentDir,
                        includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isReadableKey],
                        options: [.skipsHiddenFiles]
                    )
                } catch {
                    continue
                }

                for url in contents {
                    if Task.isCancelled { break }
                    guard let rv = try? url.resourceValues(
                        forKeys: [.isDirectoryKey, .isRegularFileKey, .isReadableKey]
                    ) else { continue }

                    if rv.isDirectory == true {
                        if !skipDirs.contains(url.lastPathComponent.lowercased()) {
                            dirStack.append(url)
                        }
                    } else if rv.isRegularFile == true && rv.isReadable == true {
                        if videoExtensions.contains(url.pathExtension.lowercased()) {
                            videoFiles.append(url)
                            onProgress?(currentDir, videoFiles.count, url)
                        }
                    }
                }
            }
            return videoFiles
        }.value
        return result
    }

    /// Probe a single file and return a populated VideoRecord.
    /// If prefetchToRAM is true and ramPath is available, copies the first 10MB
    /// to the RAM disk so ffprobe reads at memory speed instead of network speed.
    nonisolated func probeFile(url: URL, prefetchToRAM: Bool = false, ramPath: String? = nil) async -> VideoRecord {
        let fm = FileManager.default
        let path = url.path

        // Get file attributes for cache key and record population
        let attrs = try? fm.attributesOfItem(atPath: path)
        let fileSize = (attrs?[.size] as? Int64) ?? 0
        let modDate = (attrs?[.modificationDate] as? Date) ?? Date.distantPast

        // Check SQLite cache first — skip ffprobe if file unchanged
        if let cached = metadataCache.lookup(path: path, fileSize: fileSize, modDate: modDate) {
            cached.wasCacheHit = true
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
            r.size            = humanSize(fileSize)
            r.dateModifiedRaw = attrs?[.modificationDate] as? Date
            r.dateCreatedRaw  = attrs?[.creationDate] as? Date
            r.dateModified    = r.dateModifiedRaw.map { df.string(from: $0) } ?? ""
            r.dateCreated     = r.dateCreatedRaw.map { df.string(from: $0) } ?? ""

            r.partialMD5 = partialMD5(path: path)
            return r
        }

        // Prefetch file header to RAM disk for fast ffprobe
        var probeURL = url
        var tempFile: URL? = nil

        if prefetchToRAM, let rp = ramPath {
            let prefetchStart = CFAbsoluteTimeGetCurrent()
            let tmpName = "\(UUID().uuidString)_\(url.lastPathComponent)"
            let tmpURL = URL(fileURLWithPath: rp).appendingPathComponent(tmpName)
            if prefetchHeader(from: url, to: tmpURL, bytes: prefetchBytes) {
                probeURL = tmpURL
                tempFile = tmpURL
                let elapsed = CFAbsoluteTimeGetCurrent() - prefetchStart
                let mbCopied = Double(min(prefetchBytes, Int(fileSize))) / (1024.0 * 1024.0)
                await MainActor.run { [elapsed, mbCopied] in
                    self.dashboard.recordNetworkPrefetch(megabytesCopied: mbCopied, seconds: elapsed)
                }
            }
        }

        let probeResult = await runFFProbe(url: probeURL)
        let stderrTrimmed = probeResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)

        if let probe = probeResult.output,
           probe.format != nil || !(probe.streams ?? []).isEmpty {
            // Genuine success — ffprobe found format/stream data
            autoreleasepool {
                extractMetadata(probe: probe, into: rec)
            }
            if !stderrTrimmed.isEmpty {
                rec.notes = stderrTrimmed
            }
        } else if url.pathExtension.lowercased() == "mxf" {
            // ffprobe failed on MXF — try native header parser
            if let mxf = MxfHeaderParser.parse(fileAt: path) {
                ScanEngine.applyMxfMetadata(mxf, into: rec)
                let reason = stderrTrimmed.isEmpty ? "ffprobe could not decode" : stderrTrimmed
                rec.notes = "MXF header parsed (ffprobe failed: \(reason))"
            } else {
                rec.isPlayable    = "ffprobe failed"
                rec.notes         = stderrTrimmed.isEmpty ? "MXF header parse also failed" : "MXF fallback failed; \(stderrTrimmed)"
                rec.streamTypeRaw = StreamType.ffprobeFailed.rawValue
            }
        } else {
            rec.isPlayable    = "ffprobe failed"
            rec.notes         = stderrTrimmed.isEmpty ? "ffprobe could not read file" : stderrTrimmed
            rec.streamTypeRaw = StreamType.ffprobeFailed.rawValue
        }

        // Clean up temp file
        if let tmp = tempFile {
            try? fm.removeItem(at: tmp)
        }

        // Cache the result — but don't cache ffprobe failures, so future runs
        // with improved fallback parsers can retry them.
        if rec.streamTypeRaw != StreamType.ffprobeFailed.rawValue {
            metadataCache.store(record: rec, fileSize: fileSize, modDate: modDate)
        }

        return rec
    }

    /// Copy the first N bytes of a file to a destination. Used to prefetch
    /// network file headers to RAM disk for fast ffprobe access.
    nonisolated func prefetchHeader(from src: URL, to dst: URL, bytes: Int) -> Bool {
        let fd = open(src.path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        // Get actual file size — prefetch the smaller of requested bytes or full file
        var sb = stat()
        guard fstat(fd, &sb) == 0 else { return false }
        let readLen = min(bytes, Int(sb.st_size))

        // mmap source for fast read
        guard let ptr = mmap(nil, readLen, PROT_READ, MAP_PRIVATE, fd, 0),
              ptr != MAP_FAILED else { return false }
        defer { munmap(ptr, readLen) }

        // Write to RAM disk
        let data = Data(bytesNoCopy: ptr, count: readLen, deallocator: .none)
        do {
            try data.write(to: dst)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Correlate

    /// Tolerance for duration matching (seconds)
    private let durationTolerance: Double = 1.0
    /// Tolerance for timestamp matching (seconds)
    private let timestampTolerance: TimeInterval = 5.0

    /// Correlate all records, or only those whose IDs are in `selectedIDs` (if non-nil/non-empty).
    func correlate(selectedIDs: Set<UUID>? = nil) {
        let scope: [VideoRecord]
        if let ids = selectedIDs, !ids.isEmpty {
            scope = records.filter { ids.contains($0.id) }
            // Only clear pairing on selected records
            for r in scope {
                r.pairedWith = nil
                r.pairGroupID = nil
                r.pairConfidence = nil
            }
        } else {
            scope = records
            for r in records {
                r.pairedWith = nil
                r.pairGroupID = nil
                r.pairConfidence = nil
            }
        }

        let needsPairing = scope.filter { $0.streamType.needsCorrelation }
        let allVideos = needsPairing.filter { $0.streamType == .videoOnly }
        let allAudios = needsPairing.filter { $0.streamType == .audioOnly }
        var matched: Set<UUID> = []

        log("  Correlating \(allVideos.count) video-only + \(allAudios.count) audio-only files...")

        // Two-phase approach to avoid O(N*M) memory:
        // Phase 1: Build index of audio files by correlation key for fast lookup.
        // Phase 2: For each video, score only plausible audio candidates (same key,
        //          same directory, or similar timestamp) rather than all audios.

        struct Candidate {
            let video: VideoRecord
            let audio: VideoRecord
            let score: Int
            let confidence: PairConfidence
            let reasons: [String]
        }

        // Index audio files by correlation key and directory for fast lookup
        var audioByKey: [String: [VideoRecord]] = [:]
        var audioByDir: [String: [VideoRecord]] = [:]
        for a in allAudios {
            let key = filenameCorrelationKey(a.filename)
            audioByKey[key, default: []].append(a)
            audioByDir[a.directory, default: []].append(a)
        }

        var candidates: [Candidate] = []

        for v in allVideos {
            let vKey = filenameCorrelationKey(v.filename)

            // Gather plausible audio candidates: same key OR same directory
            var candidateAudios = Set<UUID>()
            var audioPool: [VideoRecord] = []
            for a in audioByKey[vKey] ?? [] {
                if candidateAudios.insert(a.id).inserted { audioPool.append(a) }
            }
            for a in audioByDir[v.directory] ?? [] {
                if candidateAudios.insert(a.id).inserted { audioPool.append(a) }
            }
            // If pool is small, also check duration/timestamp matches against all audios
            // (only when the indexed lookups haven't found enough candidates)
            if audioPool.count < 5 {
                for a in allAudios where !candidateAudios.contains(a.id) {
                    var hasStrongSignal = false
                    if v.durationSeconds > 0 && a.durationSeconds > 0 &&
                       abs(v.durationSeconds - a.durationSeconds) <= durationTolerance {
                        hasStrongSignal = true
                    }
                    if let vDate = v.dateCreatedRaw, let aDate = a.dateCreatedRaw,
                       abs(vDate.timeIntervalSince(aDate)) <= timestampTolerance {
                        hasStrongSignal = true
                    }
                    if hasStrongSignal {
                        if candidateAudios.insert(a.id).inserted { audioPool.append(a) }
                    }
                }
            }

            for a in audioPool {
                var score = 0
                var reasons: [String] = []

                let aKey = filenameCorrelationKey(a.filename)
                if vKey == aKey { score += 4; reasons.append("filename") }

                if v.durationSeconds > 0 && a.durationSeconds > 0 &&
                   abs(v.durationSeconds - a.durationSeconds) <= durationTolerance {
                    score += 3; reasons.append("duration")
                }

                if let vDate = v.dateCreatedRaw, let aDate = a.dateCreatedRaw,
                   abs(vDate.timeIntervalSince(aDate)) <= timestampTolerance {
                    score += 3; reasons.append("timestamp")
                }

                if !v.timecode.isEmpty && v.timecode == a.timecode {
                    score += 2; reasons.append("timecode")
                }

                if v.directory == a.directory {
                    score += 1; reasons.append("directory")
                }

                if !v.tapeName.isEmpty && v.tapeName == a.tapeName {
                    score += 1; reasons.append("tape")
                }

                guard score >= 3 else { continue }

                let confidence: PairConfidence
                if score >= 7 { confidence = .high }
                else if score >= 4 { confidence = .medium }
                else { confidence = .low }

                candidates.append(Candidate(
                    video: v, audio: a, score: score,
                    confidence: confidence, reasons: reasons
                ))
            }
        }

        // Sort by score descending, then greedily pair
        candidates.sort { $0.score > $1.score }

        for c in candidates {
            guard !matched.contains(c.video.id) && !matched.contains(c.audio.id) else { continue }

            let gid = UUID()
            c.video.pairedWith = c.audio; c.video.pairGroupID = gid; c.video.pairConfidence = c.confidence
            c.audio.pairedWith = c.video; c.audio.pairGroupID = gid; c.audio.pairConfidence = c.confidence
            matched.insert(c.video.id); matched.insert(c.audio.id)
            log("  Paired [\(c.confidence.rawValue)] (\(c.reasons.joined(separator: "+"))): \(c.video.filename)  ↔  \(c.audio.filename)")
        }

        let totalPairs     = matched.count / 2
        let highCount      = records.filter { $0.pairConfidence == .high }.count / 2
        let medCount       = records.filter { $0.pairConfidence == .medium }.count / 2
        let lowCount       = records.filter { $0.pairConfidence == .low }.count / 2
        let stillUnmatched = needsPairing.filter { !matched.contains($0.id) }.count

        log("""

        Correlation complete:
          \(totalPairs) pairs — \(highCount) high, \(medCount) medium, \(lowCount) low confidence
          \(stillUnmatched) unmatched
        """)

        // Force table refresh
        let tmp = records
        records = []
        records = tmp
    }

    func analyzeDuplicates(selectedIDs: Set<UUID>? = nil) {
        let scope: [VideoRecord]
        if let ids = selectedIDs, !ids.isEmpty {
            scope = records.filter { ids.contains($0.id) }
            DuplicateDetector.clear(records: scope)
        } else {
            scope = records
        }

        let summary = DuplicateDetector.analyze(records: scope)

        log("""

        Duplicate analysis complete:
          \(summary.groups) groups
          \(summary.highConfidenceGroups) high, \(summary.mediumConfidenceGroups) medium, \(summary.lowConfidenceGroups) low confidence
          \(summary.extraCopies) extra copy candidates, \(summary.reviewItems) review items
        """)

        let tmp = records
        records = []
        records = tmp
    }

    /// Normalize filename by stripping V/A prefix (Avid MXF convention).
    /// Only strips when followed by hex digits (e.g., V01A23BC.mxf → _01A23BC.mxf)
    func filenameCorrelationKey(_ filename: String) -> String {
        var parts = filename.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        for i in parts.indices {
            let p = parts[i]
            if p.count > 1,
               let first = p.first,
               (first == "V" || first == "A" || first == "v" || first == "a"),
               p.dropFirst().allSatisfy({ $0.isHexDigit }) {
                parts[i] = "_" + p.dropFirst()
                break
            }
        }
        return parts.joined(separator: ".")
    }

    // MARK: - Combine

    /// All correlated pairs (video record is always first in tuple)
    var correlatedPairs: [(video: VideoRecord, audio: VideoRecord)] {
        var seen = Set<UUID>()
        var pairs: [(VideoRecord, VideoRecord)] = []
        for rec in records {
            guard let partner = rec.pairedWith, !seen.contains(rec.id) else { continue }
            seen.insert(rec.id)
            seen.insert(partner.id)
            let v = rec.streamType == .videoOnly ? rec : partner
            let a = rec.streamType == .audioOnly ? rec : partner
            pairs.append((v, a))
        }
        return pairs
    }

    func combineAllPairs(outputFolder: URL, maxConcurrency: Int? = nil) {
        let pairs = correlatedPairs
        guard !pairs.isEmpty else {
            log("No correlated pairs to combine.")
            return
        }

        isCombining = true
        dashboard.resetForCombine(total: pairs.count)

        log("""

        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
          Combining \(pairs.count) pair\(pairs.count == 1 ? "" : "s") → \(outputFolder.path)
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        """)

        combineTask = Task {
            // Mount RAM disk for temp buffering
            let combineDiskMB = self.perfSettings.ramDiskGB * 1024
            let hasRAMDisk = await ramDisk.mount(sizeMB: combineDiskMB)
            let ramMountPoint = await ramDisk.mountPoint
            if hasRAMDisk, let mp = ramMountPoint {
                log("  RAM disk mounted at \(mp) (\(self.perfSettings.ramDiskGB) GB)")
            }
            let tempBase = (hasRAMDisk && ramMountPoint != nil)
                ? URL(fileURLWithPath: ramMountPoint!)
                : FileManager.default.temporaryDirectory

            let semaphore = AsyncSemaphore(limit: maxConcurrency ?? self.perfSettings.combineConcurrency)

            await withTaskGroup(of: (String, Bool).self) { group in
                for (video, audio) in pairs {
                    if Task.isCancelled { break }

                    let videoFilename = video.filename
                    let videoPath = video.fullPath
                    let audioFilename = audio.filename
                    let audioPath = audio.fullPath

                    group.addTask { [self] in
                        return await semaphore.withPermit {
                            if Task.isCancelled { return (videoFilename, false) }

                            let baseName = URL(fileURLWithPath: videoPath)
                                .deletingPathExtension().lastPathComponent
                            let outName = "\(baseName)_combined.mov"
                            let outURL = outputFolder.appendingPathComponent(outName)

                            await MainActor.run {
                                self.dashboard.combineCurrentFile = outName
                                self.log("  [\(self.dashboard.combineCompleted + 1)/\(self.dashboard.combineTotal)] \(outName)")
                                self.log("    Video: \(videoPath)")
                                self.log("    Audio: \(audioPath)")
                            }

                            // Buffer network sources to RAM disk (or /tmp fallback)
                            let tempDir = tempBase
                                .appendingPathComponent("VS_\(UUID().uuidString)")
                            var localVideo = URL(fileURLWithPath: videoPath)
                            var localAudio = URL(fileURLWithPath: audioPath)
                            var usedTempDir = false

                            let videoIsNetwork = self.isNetworkPath(videoPath)
                            let audioIsNetwork = self.isNetworkPath(audioPath)

                            if videoIsNetwork || audioIsNetwork {
                                do {
                                    try FileManager.default.createDirectory(
                                        at: tempDir, withIntermediateDirectories: true)
                                    usedTempDir = true

                                    if videoIsNetwork {
                                        let dest = tempDir.appendingPathComponent(videoFilename)
                                        await MainActor.run {
                                            self.log("    Buffering video to \(hasRAMDisk ? "RAM disk" : "temp")...")
                                        }
                                        try await self.bufferedCopy(
                                            from: URL(fileURLWithPath: videoPath), to: dest)
                                        localVideo = dest
                                    }
                                    if audioIsNetwork {
                                        let dest = tempDir.appendingPathComponent(audioFilename)
                                        await MainActor.run {
                                            self.log("    Buffering audio to \(hasRAMDisk ? "RAM disk" : "temp")...")
                                        }
                                        try await self.bufferedCopy(
                                            from: URL(fileURLWithPath: audioPath), to: dest)
                                        localAudio = dest
                                    }
                                } catch {
                                    await MainActor.run {
                                        self.log("    ERROR buffering: \(error.localizedDescription)")
                                        self.dashboard.combineCompleted += 1
                                    }
                                    if usedTempDir {
                                        try? FileManager.default.removeItem(at: tempDir)
                                    }
                                    return (videoFilename, false)
                                }
                            }

                            // Run ffmpeg: remux into MOV, no re-encode
                            let success = await self.runFFMpeg(
                                videoPath: localVideo.path,
                                audioPath: localAudio.path,
                                outputPath: outURL.path
                            )

                            // Clean up temp files
                            if usedTempDir {
                                try? FileManager.default.removeItem(at: tempDir)
                            }

                            await MainActor.run {
                                self.dashboard.combineCompleted += 1
                                if success {
                                    self.log("    ✓ Done: \(outURL.path)")
                                } else {
                                    self.log("    ✗ FAILED: \(outName)")
                                }
                            }
                            return (videoFilename, success)
                        }
                    }
                }

                for await (_, ok) in group {
                    await MainActor.run {
                        if ok { self.dashboard.combineSucceeded += 1 }
                        else  { self.dashboard.combineFailed += 1 }
                    }
                }

                // Unmount RAM disk
                await self.ramDisk.unmount()

                await MainActor.run {
                    self.log("""

                    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                      Combine Complete
                    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                      Succeeded: \(self.dashboard.combineSucceeded)
                      Failed:    \(self.dashboard.combineFailed)
                    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                    """)
                    self.isCombining = false
                    self.dashboard.combineCurrentFile = ""
                }
            }
        }
    }

    func stopCombine() {
        combineTask?.cancel()
        combineTask = nil
        Task { await ramDisk.unmount() }
        log("--- Combine stopped by user ---")
        isCombining = false
        dashboard.combineCurrentFile = ""
    }

    /// Detect network/remote mount paths
    nonisolated func isNetworkPath(_ path: String) -> Bool {
        let networkPrefixes = ["/Volumes/", "/private/var/automount/", "/net/"]
        guard networkPrefixes.contains(where: { path.hasPrefix($0) }) else { return false }
        // Check if it's actually a network mount via statfs
        var stat = statfs()
        guard statfs(path, &stat) == 0 else { return false }
        let fsType = withUnsafePointer(to: &stat.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) {
                String(cString: $0)
            }
        }
        let networkFS = ["smbfs", "nfs", "afpfs", "webdav", "cifs"]
        return networkFS.contains(fsType)
    }

    /// Large-buffer async file copy (4 MB chunks) for network reliability
    nonisolated func bufferedCopy(from src: URL, to dst: URL, bufferSize: Int = 4 * 1024 * 1024) async throws {
        try await Task.detached {
            let reader = try FileHandle(forReadingFrom: URL(fileURLWithPath: src.path))
            defer { try? reader.close() }

            FileManager.default.createFile(atPath: dst.path, contents: nil)
            guard let writer = try? FileHandle(forWritingTo: URL(fileURLWithPath: dst.path)) else {
                throw NSError(domain: "VideoScan", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Cannot write \(dst.lastPathComponent)"])
            }
            defer { try? writer.close() }

            while true {
                try Task.checkCancellation()
                let chunk = reader.readData(ofLength: bufferSize)
                if chunk.isEmpty { break }
                try writer.write(contentsOf: chunk)
            }
        }.value
    }

    /// Run ffmpeg to remux video+audio into MOV. Returns true on success.
    /// Cancellation-aware: terminates ffmpeg immediately when task is cancelled.
    func runFFMpeg(videoPath: String, audioPath: String, outputPath: String) async -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpegPath)
        proc.arguments = [
            "-y",
            "-probesize", "50M",        // larger probe for MXF
            "-analyzeduration", "10M",
            "-i", videoPath,
            "-i", audioPath,
            "-map", "0:v",
            "-map", "1:a",
            "-c:v", "copy",
            "-c:a", "copy",
            "-movflags", "+faststart",
            "-f", "mov",
            outputPath
        ]

        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = Pipe()

        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            if let text = String(data: handle.availableData, encoding: .utf8), !text.isEmpty {
                DispatchQueue.main.async { self?.log(text.trimmingCharacters(in: .newlines)) }
            }
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                proc.terminationHandler = { p in
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    let remaining = errPipe.fileHandleForReading.readDataToEndOfFile()
                    if let text = String(data: remaining, encoding: .utf8), !text.isEmpty {
                        DispatchQueue.main.async { self.log(text.trimmingCharacters(in: .newlines)) }
                    }
                    continuation.resume(returning: p.terminationStatus == 0)
                }
                do    { try proc.run() }
                catch { continuation.resume(returning: false) }
            }
        } onCancel: {
            if proc.isRunning { proc.terminate() }
        }
    }

    // MARK: - ffprobe

    nonisolated func runFFProbe(url: URL) async -> (output: FFProbeOutput?, stderr: String) {
        let args = ["-v","warning","-probesize","50M","-analyzeduration","10M",
                    "-print_format","json","-show_format","-show_streams", url.path]
        let result = await ProcessRunner.runCapturingStderr(executable: ffprobePath, arguments: args)
        guard let json = result.stdout, let data = json.data(using: .utf8) else {
            return (nil, result.stderr)
        }
        let output = try? JSONDecoder().decode(FFProbeOutput.self, from: data)
        return (output, result.stderr)
    }

    nonisolated func extractMetadata(probe: FFProbeOutput, into rec: VideoRecord) {
        let fmt     = probe.format
        let streams = probe.streams ?? []
        let fmtTags = fmt?.tags ?? [:]

        rec.container = fmt?.format_long_name ?? fmt?.format_name ?? ""
        if let d = Double(fmt?.duration ?? "") {
            rec.durationSeconds = d
            rec.duration = formatDuration(d)
        }
        if let br = fmt?.bit_rate, let bri = Int(br) { rec.totalBitrate = "\(bri/1000) kbps" }

        rec.timecode = fmtTags["timecode"] ?? fmtTags["Timecode"] ?? ""
        rec.tapeName = fmtTags["tape_name"] ?? fmtTags["reel_name"] ??
                       fmtTags["com.apple.quicktime.reelname"] ?? ""

        var hasVideo = false
        var hasAudio = false

        for s in streams {
            let stags = s.tags ?? [:]
            if rec.timecode.isEmpty { rec.timecode = stags["timecode"] ?? "" }

            if s.codec_type == "video" && !hasVideo {
                hasVideo       = true
                rec.videoCodec = s.codec_name ?? ""
                let w = s.width ?? 0; let h = s.height ?? 0
                if w > 0 && h > 0 { rec.resolution = "\(w)x\(h)" }
                rec.frameRate  = parseFraction(s.r_frame_rate ?? s.avg_frame_rate ?? "")
                if let vbr = s.bit_rate, let vbri = Int(vbr) { rec.videoBitrate = "\(vbri/1000) kbps" }
                rec.colorSpace = s.color_space ?? ""
                rec.bitDepth   = s.bits_per_raw_sample ?? ""
                rec.scanType   = s.field_order ?? ""
            }

            if s.codec_type == "audio" && !hasAudio {
                hasAudio          = true
                rec.audioCodec    = s.codec_name ?? ""
                rec.audioChannels = s.channels.map { String($0) } ?? ""
                if let sr = s.sample_rate { rec.audioSampleRate = "\(sr) Hz" }
            }
        }

        if hasVideo && hasAudio { rec.streamTypeRaw = StreamType.videoAndAudio.rawValue }
        else if hasVideo        { rec.streamTypeRaw = StreamType.videoOnly.rawValue }
        else if hasAudio        { rec.streamTypeRaw = StreamType.audioOnly.rawValue }
        else                    { rec.streamTypeRaw = StreamType.noStreams.rawValue }

        rec.isPlayable = (rec.streamTypeRaw == StreamType.noStreams.rawValue) ? "No streams" : "Yes"
    }

    // MARK: - Process runner (cancellation-aware)

    nonisolated func runProcess(executable: String, arguments: [String]) async -> String? {
        let proc = Process()
        proc.executableURL  = URL(fileURLWithPath: executable)
        proc.arguments      = arguments
        let pipe            = Pipe()
        proc.standardOutput = pipe
        proc.standardError  = Pipe()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                proc.terminationHandler = { _ in
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    continuation.resume(returning: String(data: data, encoding: .utf8))
                }
                do    { try proc.run() }
                catch { continuation.resume(returning: nil) }
            }
        } onCancel: {
            if proc.isRunning { proc.terminate() }
        }
    }

    // MARK: - Partial MD5 (mmap-based for speed)

    nonisolated func partialMD5(path: String, chunkSize: Int = 65536) -> String {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return "" }
        defer { close(fd) }

        var sb = stat()
        guard fstat(fd, &sb) == 0 else { return "" }
        let fileSize = Int(sb.st_size)
        guard fileSize > 0 else { return "" }

        var md5 = Insecure.MD5()

        // Hash first chunk via mmap
        let headLen = min(chunkSize, fileSize)
        if let ptr = mmap(nil, headLen, PROT_READ, MAP_PRIVATE, fd, 0) {
            if ptr != MAP_FAILED {
                md5.update(bufferPointer: UnsafeRawBufferPointer(start: ptr, count: headLen))
                munmap(ptr, headLen)
            }
        }

        // Hash last chunk if file is large enough
        if fileSize > chunkSize * 2 {
            let tailOffset = fileSize - chunkSize
            // mmap offset must be page-aligned
            let pageSize = Int(getpagesize())
            let alignedOffset = (tailOffset / pageSize) * pageSize
            let mapLen = fileSize - alignedOffset
            let offsetInMap = tailOffset - alignedOffset

            if let ptr = mmap(nil, mapLen, PROT_READ, MAP_PRIVATE, fd, off_t(alignedOffset)) {
                if ptr != MAP_FAILED {
                    md5.update(bufferPointer: UnsafeRawBufferPointer(
                        start: ptr.advanced(by: offsetInMap), count: chunkSize))
                    munmap(ptr, mapLen)
                }
            }
        }

        return md5.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - CSV

    func writeCSV(records: [VideoRecord], root: String) -> String? {
        let headers = [
            "Filename","Extension","Stream Type","Size","Size (Bytes)","Duration",
            "Date Created","Date Modified","Container","Video Codec","Resolution",
            "Frame Rate","Video Bitrate","Total Bitrate","Color Space","Bit Depth",
            "Scan Type","Audio Codec","Audio Channels","Audio Sample Rate","Timecode",
            "Tape Name","Is Playable","Partial MD5","Duplicate Group","Duplicate Confidence",
            "Duplicate Disposition","Duplicate Match","Duplicate Reasons","Full Path","Directory","Notes"
        ]
        var lines = [headers.joined(separator: ",")]
        for r in records {
            let row = [
                r.filename, r.ext, r.streamTypeRaw, r.size, String(r.sizeBytes),
                r.duration, r.dateCreated, r.dateModified, r.container,
                r.videoCodec, r.resolution, r.frameRate, r.videoBitrate,
                r.totalBitrate, r.colorSpace, r.bitDepth, r.scanType,
                r.audioCodec, r.audioChannels, r.audioSampleRate, r.timecode,
                r.tapeName, r.isPlayable, r.partialMD5, r.duplicateGroupID?.uuidString ?? "",
                r.duplicateConfidence?.rawValue ?? "", r.duplicateDisposition.rawValue,
                r.duplicateBestMatchFilename, r.duplicateReasons, r.fullPath, r.directory, r.notes
            ].map { csvEscape($0) }.joined(separator: ",")
            lines.append(row)
        }

        let folderName = URL(fileURLWithPath: root).lastPathComponent
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd_HHmmss"
        let outURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")
            .appendingPathComponent("VideoScan_\(folderName)_\(df.string(from: Date())).csv")
        do {
            try lines.joined(separator: "\n").write(to: outURL, atomically: true, encoding: .utf8)
            return outURL.path
        } catch { return nil }
    }

    // MARK: - Thumbnail Preview

    func generateThumbnail(for record: VideoRecord) {
        previewFilename = record.filename

        // Check cache first — works even when the source volume is offline.
        let cacheKey = record.fullPath as NSString
        if let cached = thumbnailCache.object(forKey: cacheKey) {
            previewImage = cached
            previewOfflineVolumeName = nil
            return
        }

        // If the source volume isn't mounted, don't try to read the file —
        // surface a clean "Volume Offline" placeholder instead of stalling.
        if !VolumeReachability.isReachable(path: record.fullPath) {
            previewImage = nil
            previewOfflineVolumeName = VolumeReachability.volumeName(forPath: record.fullPath)
            return
        }
        previewOfflineVolumeName = nil

        previewImage = nil
        let url = URL(fileURLWithPath: record.fullPath)
        Task.detached {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 480, height: 270)

            let time = CMTime(seconds: 0.5, preferredTimescale: 600)
            do {
                let cgImage = try await withCheckedThrowingContinuation { cont in
                    generator.generateCGImageAsynchronously(for: time) { image, _, error in
                        if let image { cont.resume(returning: image) }
                        else { cont.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
                    }
                }
                let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                await MainActor.run {
                    self.thumbnailCache.setObject(nsImage, forKey: cacheKey)
                    self.previewImage = nsImage
                }
            } catch {
                await MainActor.run {
                    self.previewImage = nil
                }
            }
        }
    }

    // MARK: - Helpers

    nonisolated func formatDuration(_ secs: Double) -> String {
        let s = Int(secs)
        return String(format: "%02d:%02d:%02d", s/3600, (s%3600)/60, s%60)
    }

    nonisolated func parseFraction(_ fr: String) -> String {
        let parts = fr.split(separator: "/").compactMap { Double($0) }
        guard parts.count == 2, parts[1] != 0 else { return fr }
        var s = String(format: "%.3f", parts[0]/parts[1])
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    nonisolated func humanSize(_ bytes: Int64) -> String {
        let units = ["B","KB","MB","GB","TB"]
        var val = Double(bytes)
        for unit in units {
            if abs(val) < 1024 { return String(format: "%.1f \(unit)", val) }
            val /= 1024
        }
        return String(format: "%.1f PB", val)
    }

    func csvEscape(_ v: String) -> String {
        if v.contains(",") || v.contains("\"") || v.contains("\n") {
            return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return v
    }
}
