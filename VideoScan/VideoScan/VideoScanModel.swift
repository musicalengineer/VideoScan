import Foundation
import SwiftUI
import Combine
import Darwin
import AVFoundation
import SQLite3

// MARK: - Model

@MainActor
final class VideoScanModel: ObservableObject {
    @Published var records: [VideoRecord] = []
    /// True when the app is running on a non-master Mac (viewer mode).
    /// Set by the sync engine at launch via `applyReadOnlyMode(_:)` so
    /// views can disable Combine / Archive / Delete affordances. The
    /// CatalogStore layer also refuses writes — this flag is the UI
    /// half of the belt-and-suspenders. See CatalogSync.swift.
    @Published var isReadOnly: Bool = false
    @Published var isScanning: Bool = false
    @Published var isCombining: Bool = false
    @Published var isCorrelating: Bool = false
    @Published var isAnalyzingDuplicates: Bool = false
    @Published var isDeletingDuplicates: Bool = false
    /// Scan-target IDs currently undergoing a Verify pass. Verify uses
    /// `target.status = .scanning` for its lifecycle plumbing, so this set
    /// is the only way to distinguish a verify from a fresh scan in the UI.
    /// Read by VolumeUIStatus.compute().
    @Published var verifyingTargetIDs: Set<UUID> = []
    /// True while `backfillAllProvenance` is running. Drives the
    /// "Backfilling" badge in VolumeStatusView.
    @Published var isBackfillingProvenance: Bool = false
    /// Progress text shown in toolbar during correlate/duplicate operations
    @Published var correlateStatus: String = ""
    @Published var duplicateStatus: String = ""
    @Published var avidBinResults: [AvbBinResult] = []
    @Published var scanTargets: [CatalogScanTarget] = []
    /// Set by other views to ask the Volumes window to open with a specific
    /// volume pre-selected. The window consumes and clears this on appear /
    /// change. Lets the Archive sidebar (and future badges elsewhere) deep-
    /// link into the editor without a separate routing layer.
    @Published var pendingVolumesSelectionID: UUID?
    @Published var outputCSVPath: String = ""
    @Published var previewImage: NSImage?
    @Published var previewFilename: String = ""
    /// Set by Archive tab to navigate the Catalog tab to a specific record.
    @Published var pendingCatalogSelection: UUID?
    /// When true, Show Pair mode: filter catalog to show the selected file
    /// and its correlated pair instead of just the one file.
    @Published var pendingCatalogPairMode: Bool = false
    /// Set by Catalog tab to navigate the Archive tab to a specific record.
    @Published var pendingArchiveSelection: UUID?
    /// The file(s) currently "under the microscope" — persists across tab
    /// switches so both Catalog and Archive highlight the same set. Includes
    /// the primary record plus any duplicate-group members.
    @Published var focusedMediaIDs: Set<UUID> = []
    /// Set when the user selects a record whose source volume isn't currently
    /// mounted. CatalogContent renders an "Volume Offline" placeholder
    /// instead of trying to load a thumbnail.
    @Published var previewOfflineVolumeName: String?

    /// Set by an operation that can't proceed because an external tool
    /// is missing (e.g. ffmpeg not installed). The view binds an alert to
    /// this; clearing it dismisses the dialog. Prevents the silent-no-op
    /// failure mode where Scan just sits there because every probe fails.
    @Published var missingDependency: MissingDependency?

    /// Force SwiftUI to recompute volumeTableRows when target properties
    /// (phase, reachability, etc.) change. Reassigning the array triggers
    /// @Published even though the contents are the same references —
    /// this is the nuclear option that works through NSSplitView hosting.
    func notifyTargetsChanged() {
        scanTargets = scanTargets
    }

    /// High-frequency dashboard + console state — separate ObservableObject
    /// so updates don't trigger re-render of the main Table view.
    let dashboard = DashboardState()

    /// Thumbnail cache — keyed by fullPath, avoids regenerating from video file on re-click
    private let thumbnailCache = NSCache<NSString, NSImage>()

    /// Drop any cached thumbnail under `path`. Called from the rename path
    /// (VideoScanModel+Rename) so a renamed record doesn't leak a stale
    /// entry under its old `fullPath` key. Internal to the model so the
    /// NSCache itself stays private.
    func invalidateThumbnailCacheEntry(forPath path: String) {
        thumbnailCache.removeObject(forKey: path as NSString)
    }

    let ffprobePath = ToolLocator.ffprobePath

    let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "avi", "mkv", "mxf", "mts", "m2ts", "ts", "mpg", "mpeg",
        "m2v", "vob", "wmv", "asf", "webm", "ogv", "ogg", "rm", "rmvb", "divx", "flv",
        "f4v", "3gp", "3g2", "dv", "dif", "braw", "r3d", "vro", "mod", "tod"
    ]

    /// User-toggleable scan policy. Bound to the Scan Options menu. Walkers
    /// snapshot this at scan start via `skipDirsSnapshot()` /
    /// `skipBundleExtensionsSnapshot()` so toggling a category takes effect
    /// on the next scan (not mid-flight). Kept @Published so the menu
    /// checkmarks update live.
    @Published var scanOptions: ScanOptions = .restored()

    /// Snapshot the current skip-directory set from scanOptions.
    /// Must be called on the main actor (returns a Sendable Set<String>
    /// that nonisolated walkers can then capture safely).
    func skipDirsSnapshot() -> Set<String> {
        var s = SkipCategories.finderMetaDirs  // always skipped
        if scanOptions.skipSystemFiles {
            s.formUnion(SkipCategories.systemDirs)
            s.formUnion(SkipCategories.windowsTrashDirs)
            s.formUnion(SkipCategories.devCacheDirs)
        }
        return s
    }

    /// Snapshot the current skip-bundle-extensions set from scanOptions.
    /// App bundles fold into "system files"; media bundles are a separate
    /// toggle (since media libraries are where user content often lives).
    func skipBundleExtensionsSnapshot() -> Set<String> {
        var s = Set<String>()
        if scanOptions.skipSystemFiles { s.formUnion(SkipCategories.appBundleExtensions) }
        if scanOptions.skipMediaBundles { s.formUnion(SkipCategories.mediaLibraryExtensions) }
        return s
    }

    var combineTask: Task<Void, Never>?
    var backfillTask: Task<Void, Never>?
    var ramDisk = RAMDisk()
    nonisolated private let metadataCache = MetadataCache()

    /// Cooperative pause gate for combine tasks
    let combinePauseGate = PauseGate()
    @Published var isCombinePaused: Bool = false

    /// Tuneable performance settings — persisted via UserDefaults
    @Published var perfSettings = ScanPerformanceSettings.restored() {
        didSet {
            perfSettings.save()
            Task { await MemoryPressureMonitor.shared.setFloorGB(perfSettings.memoryFloorGB) }
        }
    }

    // Internal so VideoScanModel+ScanTargetPersistence can reference them.
    static let savedTargetsKey = "VideoScan.scanTargetPaths"
    static let savedDatesKey = "VideoScan.scanTargetDates"
    static let savedPhasesKey = "VideoScan.scanTargetPhases"
    static let savedRolesKey = "VideoScan.scanTargetRoles"
    static let savedTrustKey = "VideoScan.scanTargetTrust"
    static let savedFilesystemKey = "VideoScan.scanTargetFilesystems"
    static let savedMediaTechKey = "VideoScan.scanTargetMediaTechs"
    static let savedPurchaseYearKey = "VideoScan.scanTargetPurchaseYears"
    static let savedCapacityKey = "VideoScan.scanTargetCapacities"
    static let savedNotesKey = "VideoScan.scanTargetNotes"

    // `internal var` (not `private let`) so tests can swap in a per-test
    // CatalogStore(directory:) instance — necessary because the shared
    // CatalogStore short-circuits saves under XCTest to avoid polluting
    // Application Support. Production code never reassigns this.
    var catalogStore: CatalogStore = .shared

    // Internal so VideoScanModel+ScanTargetPersistence can gate persistence
    // during XCTest runs.
    static var isRunningTests: Bool {
        if NSClassFromString("XCTestCase") != nil { return true }
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil { return true }
        if env["XCTestBundlePath"] != nil { return true }
        if env["SWIFT_TESTING_ENABLED"] != nil { return true }
        if Bundle.allBundles.contains(where: { $0.bundlePath.hasSuffix(".xctest") }) {
            return true
        }
        return false
    }

    init() {
        restoreScanTargets()
        // Restore previously-scanned records so the user can browse the
        // catalog even when source volumes are offline.
        let restored = catalogStore.load()
        if !restored.isEmpty {
            records = restored
            log("Restored \(restored.count) records from previous session.")
            // Migrate: backfill lifecycleStage for records that predate the field.
            var migrated = 0
            for rec in records where rec.lifecycleStage == .cataloged {
                if rec.archiveStage >= .masterAssigned {
                    rec.lifecycleStage = .archived
                    migrated += 1
                } else if rec.mediaDisposition != .unreviewed {
                    rec.lifecycleStage = .reviewing
                    migrated += 1
                }
            }
            if migrated > 0 {
                log("Migrated \(migrated) records to lifecycleStage.")
                catalogStore.scheduleSave(records: records)
            }
        }
        // Backfill: for any scan target that has zero records in the restored
        // snapshot, pull whatever the SQLite metadata cache has under that
        // path. This covers volumes scanned by builds older than catalog.json
        // persistence — without this, View Catalog shows (0) for offline
        // volumes even though the ffprobe cache is full of their files.
        var backfilled = 0
        for t in scanTargets where !t.searchPath.isEmpty {
            // Don't backfill volumes whose catalog was explicitly deleted
            if t.phase == .noCatalog { continue }
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
        enforcePhaseConsistency()
        repairCorruptedPhases()
        detectResumableTargets()
        installVolumeMountObservers()
        refreshTargetReachability()
    }

    // Internal (not private) so VideoScanModel+VolumeLifecycle can mutate it.
    // mountObservers stays in the main class because extensions can't add
    // stored properties.
    var mountObservers: [NSObjectProtocol] = []




    /// Delete all catalog records across all volumes.
    func deleteAllCatalog() {
        // Reset all target state BEFORE touching records
        for target in scanTargets {
            target.phase = .noCatalog
            target.lastScannedDate = nil
            target.filesFound = 0
            target.filesScanned = 0
            if target.status == .complete || target.status == .stopped || target.status == .error {
                target.status = .idle
            }
            clearCacheForTarget(target)
        }
        let count = records.count
        records.removeAll()
        // Records the banner was tracking are gone — drop it so the user
        // doesn't see a now-meaningless "Undo" affordance after a wipe.
        clearPurgeUndoState()
        persistScanDates()
        saveCatalogNow()
        notifyTargetsChanged()
        log("Deleted all \(count) catalog record(s).")
    }

    /// Apply viewer-mode semantics: flip the UI flag and tell the
    /// underlying CatalogStore to refuse writes. Idempotent.
    /// Called by VideoScanApp once CatalogSync has decided the mode.
    func applyReadOnlyMode(_ readOnly: Bool) {
        isReadOnly = readOnly
        catalogStore.isReadOnly = readOnly
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

    // MARK: - Soft-delete state (logic in VideoScanModel+SoftDelete.swift)
    //
    // @Published storage stays in the main class because extensions cannot
    // add stored properties. All purge/restore/undo behavior lives in
    // VideoScanModel+SoftDelete.swift.

    /// The banner observes this. nil = no banner shown.
    @Published var lastPurgedBatch: LastPurgedBatch?

    /// Surface for undo errors (e.g. all target records have been deleted
    /// from the catalog between purge and undo). Banner shows this in
    /// place of the default "Removed N items." message.
    @Published var lastPurgeUndoError: String?

    // MARK: - Logging (delegates to DashboardState)

    func log(_ msg: String) { dashboard.log(msg) }

    func clearResults() {
        records = []
        // Wholesale reseed of records — same reasoning as deleteAllCatalog:
        // the banner has nothing left to undo, so drop it.
        clearPurgeUndoState()
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

    /// Number of scan targets that pass the "unscanned & idle" sweep.
    /// Used by the UI to decide whether to surface the cleanup affordance.
    var unscannedTargetCount: Int {
        scanTargets.lazy.filter { Self.isUnscannedRemovable($0) }.count
    }

    /// Belt-and-suspenders predicate used by `cleanupUnscannedTargets` and the
    /// UI count. Kept `static` so tests can exercise it directly and so it
    /// stays in lock-step between the count badge and the actual removal.
    static func isUnscannedRemovable(_ t: CatalogScanTarget) -> Bool {
        if t.lastScannedDate != nil { return false }
        if !t.status.isIdle { return false }
        // Defensive against double-cleanup races and against the obvious noise
        // case where XcodeRAM was somehow injected into scanTargets.
        if t.searchPath.hasPrefix("/Volumes/XcodeRAM") { return false }
        return true
    }

    /// Remove scan targets that have never been scanned successfully and
    /// aren't currently doing anything. This is the manual escape hatch for
    /// users whose target list got polluted by the old auto-add-on-mount
    /// behavior. Returns the number of targets removed.
    @discardableResult
    func cleanupUnscannedTargets() -> Int {
        // Swift's `filter` returns a new Array — equivalent to a C++
        // std::copy_if into a fresh vector. No mutation of `scanTargets` yet.
        let toRemove = scanTargets.filter { Self.isUnscannedRemovable($0) }
        let removeIDs = Set(toRemove.map { $0.id })
        scanTargets.removeAll { removeIDs.contains($0.id) }
        persistScanTargets()
        log("Cleaned up \(toRemove.count) unscanned scan target(s)")
        notifyTargetsChanged()
        return toRemove.count
    }

    /// Discover all mounted volumes (local + network) and return them grouped by type.
    /// Excludes system volumes (Data, Preboot, Recovery, VM, etc.) and already-added targets.
    func discoverVolumes() -> [DiscoveredVolume] {
        let fm = FileManager.default
        let systemExclusions: Set<String> = [
            "Macintosh HD", "Macintosh HD - Data",
            "Data", "Preboot", "Recovery", "VM", "Update",
            "com.apple.TimeMachine.localsnapshots"
        ]

        guard let contents = try? fm.contentsOfDirectory(atPath: "/Volumes") else { return [] }

        let existingPaths = Set(scanTargets.map { $0.searchPath })

        return contents.compactMap { name in
            guard !systemExclusions.contains(name) else { return nil }
            let path = "/Volumes/\(name)"

            // Resolve symlinks — /Volumes/Macintosh HD is a symlink to /
            let resolved = (path as NSString).resolvingSymlinksInPath
            guard resolved != "/" else { return nil }
            guard VolumeReachability.isReachable(path: path) else { return nil }

            let alreadyAdded = existingPaths.contains(path)
            let isNetwork = isNetworkVolume(path: path)

            // Get volume size info
            let attrs = try? fm.attributesOfFileSystem(forPath: path)
            let totalBytes = attrs?[.systemSize] as? Int64 ?? 0
            let freeBytes = attrs?[.systemFreeSize] as? Int64 ?? 0

            return DiscoveredVolume(
                name: name,
                path: path,
                isNetwork: isNetwork,
                totalBytes: totalBytes,
                freeBytes: freeBytes,
                alreadyAdded: alreadyAdded
            )
        }
        .sorted { a, b in
            if a.isNetwork != b.isNetwork { return !a.isNetwork }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// Add discovered volumes as scan targets
    func addDiscoveredVolumes(_ volumes: [DiscoveredVolume]) {
        for vol in volumes {
            if !scanTargets.contains(where: { $0.searchPath == vol.path }) {
                scanTargets.append(CatalogScanTarget(searchPath: vol.path))
            }
        }
        persistScanTargets()
    }

    /// Scan catalog records for volume roots that aren't in the current scan target
    /// list and re-add them. This recovers targets lost due to UserDefaults resets or
    /// key name changes. Returns the number of targets restored.
    @discardableResult
    func restoreTargetsFromCatalog() -> Int {
        let existingPaths = Set(scanTargets.map { $0.searchPath })
        var volumeRoots = Set<String>()

        for rec in records {
            let path = rec.fullPath
            guard !path.isEmpty else { continue }
            // Extract volume root: /Volumes/VolumeName
            if path.hasPrefix("/Volumes/") {
                let parts = path.split(separator: "/", maxSplits: 3)
                if parts.count >= 2 {
                    let root = "/Volumes/" + String(parts[1])
                    volumeRoots.insert(root)
                }
            }
        }

        var restored = 0
        for root in volumeRoots.sorted() where !existingPaths.contains(root) {
            let target = CatalogScanTarget(searchPath: root)
            scanTargets.append(target)
            restored += 1
        }

        if restored > 0 {
            persistScanTargets()
            refreshTargetReachability()
            log("Restored \(restored) scan target(s) from catalog history.")
        }
        return restored
    }

    private func isNetworkVolume(path: String) -> Bool {
        var statBuf = statfs()
        guard statfs(path, &statBuf) == 0 else { return false }
        let fsType = withUnsafePointer(to: &statBuf.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) {
                String(cString: $0)
            }
        }
        return ["smbfs", "nfs", "afpfs", "webdav"].contains(fsType)
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
    private func probeAndRecord(
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
    private func processTargetProbeResult(
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
    private func finalizeSingleTargetScan(
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
            appLog.write("Cancelled catalog scan of volume \(volName) at \(completedCount)/\(discoveredCount) file(s)")
            updateGlobalScanState()
            return
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
    private func mountScanRAMDiskIfNeeded(hasNetwork: Bool) async -> String? {
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
    private func logTargetScanSummary(volName: String, records: [VideoRecord]) {
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
    private func runScanForTarget(_ target: CatalogScanTarget) async {
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

    // MARK: - Catalog Verification

    /// Verify catalog records for a volume without running ffprobe.
    /// Checks provenance, file existence, and size. Backfills missing
    /// scanContext fields (volume name, host, mount type) when the volume
    /// is online — no rescan needed for that.
    func verifyCatalog(for target: CatalogScanTarget) {
        let root = target.searchPath
        let volName = URL(fileURLWithPath: root).lastPathComponent
        let volumeRecords = records.filter { $0.fullPath.hasPrefix(root) }

        guard !volumeRecords.isEmpty else {
            log("No catalog records for \(volName) — nothing to verify")
            return
        }

        guard VolumeReachability.isReachable(path: root) else {
            var report = CatalogHealthReport(
                volumePath: root, volumeName: volName,
                totalRecords: volumeRecords.count
            )
            report.volumeOffline = true
            report.missingVolumeName = volumeRecords.filter { $0.scanContext.volumeName.isEmpty }.count
            report.missingProvenance = volumeRecords.filter { !$0.scanContext.isPopulated }.count
            log(report.summary)
            return
        }

        log("""

        ─────────────────────────────────────────────
        Verifying catalog for \(volName)…
        ─────────────────────────────────────────────
          \(volumeRecords.count) records to check
        """)
        target.status = .scanning
        target.filesFound = volumeRecords.count
        target.filesScanned = 0
        target.startElapsedTimer()
        // Mark this target as verifying so VolumeUIStatus surfaces the
        // "Verifying" badge instead of "Scanning". Target ID set is cleared
        // in the task's final block. (Verify reuses .scanning status because
        // the existing lifecycle plumbing — pause, stop, elapsed timer —
        // assumes it; the badge difference lives only at the view layer.)
        verifyingTargetIDs.insert(target.id)

        // Snapshot the record paths + sizes so the background task can
        // do all the filesystem I/O without touching MainActor state.
        struct RecordSnapshot {
            let index: Int
            let path: String
            let url: URL
            let sizeBytes: Int64
            let needsBackfill: Bool
        }
        let snapshots = volumeRecords.enumerated().map { (i, rec) in
            RecordSnapshot(
                index: i,
                path: rec.fullPath,
                url: URL(fileURLWithPath: rec.fullPath),
                sizeBytes: rec.sizeBytes,
                needsBackfill: rec.scanContext.volumeName.isEmpty || !rec.scanContext.isPopulated
            )
        }
        let totalCount = volumeRecords.count

        target.scanTask = Task {
            struct FileResult {
                let index: Int
                let exists: Bool
                let sizeChanged: Bool
                let needsBackfill: Bool
                var capturedContext: ScanContext?
            }

            // Run all filesystem checks off the main thread.
            let results: [FileResult] = await Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                return snapshots.map { snap in
                    guard fm.fileExists(atPath: snap.path) else {
                        return FileResult(index: snap.index, exists: false,
                                          sizeChanged: false, needsBackfill: false)
                    }
                    let attrs = try? fm.attributesOfItem(atPath: snap.path)
                    let diskSize = (attrs?[.size] as? Int64) ?? 0
                    let changed = snap.sizeBytes > 0 && diskSize > 0 && diskSize != snap.sizeBytes
                    var ctx: ScanContext?
                    if !changed && snap.needsBackfill {
                        ctx = ScanContext.capture(for: snap.url)
                    }
                    return FileResult(index: snap.index, exists: true,
                                      sizeChanged: changed,
                                      needsBackfill: snap.needsBackfill,
                                      capturedContext: ctx)
                }
            }.value

            // Apply results back on MainActor.
            var report = CatalogHealthReport(
                volumePath: root, volumeName: volName, totalRecords: totalCount
            )
            var backfillCount = 0
            let milestones = Set([10, 25, 50, 75, 90])
            var loggedMilestones: Set<Int> = []

            for (i, result) in results.enumerated() {
                if !result.exists {
                    report.filesDeleted += 1
                } else if result.sizeChanged {
                    report.sizeChanged += 1
                } else {
                    if let ctx = result.capturedContext {
                        volumeRecords[result.index].scanContext = ctx
                        backfillCount += 1
                    }
                    report.healthy += 1
                }

                let done = i + 1
                target.filesScanned = done
                let pct = done * 100 / totalCount
                if milestones.contains(pct) && !loggedMilestones.contains(pct) {
                    loggedMilestones.insert(pct)
                    self.log("  [\(volName)] \(done)/\(totalCount) (\(pct)%) — \(report.filesDeleted) deleted, \(backfillCount) backfilled")
                }
            }

            let elapsed = target.elapsedSecs

            report.provenanceBackfilled = backfillCount
            report.missingVolumeName = volumeRecords.filter { $0.scanContext.volumeName.isEmpty }.count
            report.missingProvenance = volumeRecords.filter { !$0.scanContext.isPopulated }.count

            if backfillCount > 0 { self.saveCatalogDebounced() }

            target.stopElapsedTimer()
            target.status = .complete
            self.verifyingTargetIDs.remove(target.id)
            self.updateGlobalScanState()

            self.log(report.summary)
            self.log("  Completed in \(String(format: "%.1f", elapsed))s")

            if report.isHealthy || (report.issues == 0 && backfillCount > 0) {
                appLog.write("Verified \(volName): \(totalCount) records healthy, \(backfillCount) backfilled (\(String(format: "%.1f", elapsed))s)")
            } else {
                appLog.write("Verified \(volName): \(report.issues) issue(s) found — \(report.recommendation)")
            }
        }
    }

    /// Backfill scanContext for all catalog records across all volumes.
    /// Quick pass — no ffprobe, just stat + URL resource values per file.
    func backfillAllProvenance() {
        let needsBackfill = records.filter { $0.scanContext.volumeName.isEmpty }
        guard !needsBackfill.isEmpty else {
            log("All records already have volume names — nothing to backfill")
            return
        }

        var byVolume: [String: [(index: Int, rec: VideoRecord)] ] = [:]
        for (i, rec) in needsBackfill.enumerated() {
            let vol = VolumeReachability.volumeName(forPath: rec.fullPath)
            byVolume[vol, default: []].append((i, rec))
        }

        log("""

        ─────────────────────────────────────────────
        Backfilling volume names for \(needsBackfill.count) records
        ─────────────────────────────────────────────
          \(byVolume.count) volume(s) to process
        """)

        struct BackfillSnap {
            let recIndex: Int
            let path: String
            let url: URL
            let vol: String
        }
        var allSnaps: [BackfillSnap] = []
        var volOrder: [(name: String, range: Range<Int>)] = []
        for (vol, entries) in byVolume.sorted(by: { $0.value.count > $1.value.count }) {
            let start = allSnaps.count
            for (_, rec) in entries {
                allSnaps.append(BackfillSnap(
                    recIndex: records.firstIndex(where: { $0 === rec }) ?? 0,
                    path: rec.fullPath,
                    url: URL(fileURLWithPath: rec.fullPath),
                    vol: vol
                ))
            }
            volOrder.append((vol, start..<allSnaps.count))
        }
        let snapshots = allSnaps
        let volumes = volOrder

        isBackfillingProvenance = true
        backfillTask = Task {
            struct BackfillResult {
                let recIndex: Int
                let reachable: Bool
                var capturedContext: ScanContext?
            }

            // Defer-style cleanup: clear the global flag on every exit path
            // — completion, cancellation, exception. `defer` ≈ C++ RAII guard.
            // The outer class is @MainActor so this closure inherits it and
            // the flag write is main-thread-safe.
            defer { self.isBackfillingProvenance = false }

            let startTime = CFAbsoluteTimeGetCurrent()

            let results: [BackfillResult] = await Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                return snapshots.map { snap in
                    guard fm.fileExists(atPath: snap.path) else {
                        return BackfillResult(recIndex: snap.recIndex, reachable: false)
                    }
                    let ctx = ScanContext.capture(for: snap.url)
                    return BackfillResult(recIndex: snap.recIndex, reachable: true, capturedContext: ctx)
                }
            }.value

            var backfilled = 0
            var unreachable = 0

            for vol in volumes {
                var volBackfilled = 0
                var volUnreachable = 0
                for i in vol.range {
                    let r = results[i]
                    if r.reachable, let ctx = r.capturedContext {
                        self.records[r.recIndex].scanContext = ctx
                        volBackfilled += 1
                        backfilled += 1
                    } else if !r.reachable {
                        volUnreachable += 1
                        unreachable += 1
                    }
                }
                if volUnreachable == vol.range.count {
                    self.log("  [\(vol.name)] \(vol.range.count) records — offline/unreachable")
                } else {
                    self.log("  [\(vol.name)] \(volBackfilled)/\(vol.range.count) backfilled\(volUnreachable > 0 ? ", \(volUnreachable) unreachable" : "")")
                }
            }

            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            if backfilled > 0 { self.saveCatalogDebounced() }

            self.log("""

            ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
              Backfill Complete
            ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
              Updated:     \(backfilled)
              Unreachable: \(unreachable)
              Elapsed:     \(String(format: "%.1f", elapsed))s
            ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            """)
            appLog.write("Provenance backfill: \(backfilled) updated, \(unreachable) unreachable (\(String(format: "%.1f", elapsed))s)")
        }
    }

    /// Streams `target.searchPath` and drains a probe group against it.
    /// Returns the collected records, total discovered, and total completed.
    private func runTargetProbeGroup(
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
    private func runResumedProbeGroup(
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

    /// How many bytes to prefetch from network files to RAM disk for ffprobe.
    /// Set from perfSettings at scan start so nonisolated code can read it.
    nonisolated(unsafe) private var prefetchBytes: Int = 50 * 1024 * 1024


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

    /// Per-file probe timeout (seconds). Prevents the scan from stalling on
    /// network files that block indefinitely on read/open. 300s to accommodate
    /// SMB mounts on sleepy external drives — a too-short timeout was flagging
    /// healthy network volumes as "stalled" when they just needed to spin up.
    private let probeTimeoutSeconds: UInt64 = 300

    nonisolated private func cancelledProbeRecord(url: URL) -> VideoRecord {
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
            r.dateModifiedRaw = attrs?[.modificationDate] as? Date
            r.dateCreatedRaw  = attrs?[.creationDate] as? Date
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
    nonisolated private func prefetchIfNeeded(
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

    // MARK: - Correlate

    /// Tolerance for duration matching (seconds)
    private let durationTolerance: Double = 1.0
    /// Tolerance for timestamp matching (seconds)
    private let timestampTolerance: TimeInterval = 5.0

    // MARK: - Cross-Volume Avid Correlator

    /// Correlate Avid MXF A/V pairs across all volumes using clip ID matching.
    func correlateAcrossVolumes() {
        isCorrelating = true
        correlateStatus = ""
        defer { isCorrelating = false }

        // Clear existing pairs
        for r in records {
            r.pairedWith = nil
            r.pairGroupID = nil
            r.pairConfidence = nil
        }

        // Group by Avid clip ID
        var videosByClip: [String: [VideoRecord]] = [:]
        var audiosByClip: [String: [VideoRecord]] = [:]

        for r in records {
            guard let (clipID, isVideo) = CorrelationScorer.avidClipID(from: r.filename) else { continue }
            if isVideo {
                videosByClip[clipID, default: []].append(r)
            } else {
                audiosByClip[clipID, default: []].append(r)
            }
        }

        let allClipIDs = Set(videosByClip.keys).union(audiosByClip.keys)
        var paired = 0
        var videoOnlyOrphans = 0
        var audioOnlyOrphans = 0

        for clipID in allClipIDs {
            let videos = videosByClip[clipID] ?? []
            let audios = audiosByClip[clipID] ?? []

            guard !videos.isEmpty, !audios.isEmpty else {
                if videos.isEmpty { audioOnlyOrphans += audios.count }
                if audios.isEmpty { videoOnlyOrphans += videos.count }
                continue
            }

            guard let bestVideo = CorrelationScorer.bestCopy(from: videos),
                  let bestAudio = CorrelationScorer.bestCopy(from: audios) else { continue }

            let gid = UUID()
            bestVideo.pairedWith = bestAudio
            bestVideo.pairGroupID = gid
            bestVideo.pairConfidence = .high
            bestAudio.pairedWith = bestVideo
            bestAudio.pairGroupID = gid
            bestAudio.pairConfidence = .high
            paired += 1
            log("  Paired [high] (clipID): \(bestVideo.filename) ↔ \(bestAudio.filename)")
        }

        // Enrich with Avid bin metadata if bins have been scanned
        if !avidBinResults.isEmpty {
            crossReferenceAvidBins()
        }

        correlateStatus = "\(paired) pairs · \(videoOnlyOrphans)V + \(audioOnlyOrphans)A orphans"
        log("""

        Cross-volume Avid correlation complete:
          \(allClipIDs.count) unique clip IDs
          \(paired) pairs matched
          \(videoOnlyOrphans) video-only orphans (no audio found)
          \(audioOnlyOrphans) audio-only orphans (no video found)
        """)

        // Force table refresh
        let tmp = records
        records = []
        records = tmp
    }

    /// Correlate all records, or only those whose IDs are in `selectedIDs` (if non-nil/non-empty).
    func correlate(selectedIDs: Set<UUID>? = nil) {
        isCorrelating = true
        correlateStatus = ""
        defer { isCorrelating = false }

        let scope = CorrelationScorer.resolveCorrelateScope(records: records, selectedIDs: selectedIDs)
        let needsPairing = scope.filter { $0.streamType.needsCorrelation }
        let allVideos = needsPairing.filter { $0.streamType == .videoOnly }
        let allAudios = needsPairing.filter { $0.streamType == .audioOnly }

        correlateStatus = "\(allVideos.count) video + \(allAudios.count) audio candidates"
        log("  Correlating \(allVideos.count) video-only + \(allAudios.count) audio-only files...")

        let pools = CorrelationScorer.buildAudioPools(from: allAudios)
        var candidates: [CorrelationScorer.Candidate] = []
        for v in allVideos {
            let vKey = CorrelationScorer.filenameCorrelationKey(v.filename)
            let audioPool = CorrelationScorer.gatherCandidateAudios(
                for: v, vKey: vKey, allAudios: allAudios,
                byKey: pools.byKey, byDir: pools.byDir,
                durationTolerance: durationTolerance,
                timestampTolerance: timestampTolerance
            )
            for a in audioPool {
                if let candidate = CorrelationScorer.scoreCorrelatePair(
                    video: v, audio: a, vKey: vKey,
                    durationTolerance: durationTolerance,
                    timestampTolerance: timestampTolerance
                ) {
                    candidates.append(candidate)
                }
            }
        }

        var matched = Set<UUID>()
        let logLines = CorrelationScorer.assignCandidates(candidates, matched: &matched)
        for line in logLines { log(line) }

        let totalPairs     = matched.count / 2
        let highCount      = records.filter { $0.pairConfidence == .high }.count / 2
        let medCount       = records.filter { $0.pairConfidence == .medium }.count / 2
        let lowCount       = records.filter { $0.pairConfidence == .low }.count / 2
        let stillUnmatched = needsPairing.filter { !matched.contains($0.id) }.count
        correlateStatus = "\(totalPairs) pairs · \(stillUnmatched) unmatched"
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
        isAnalyzingDuplicates = true
        duplicateStatus = ""
        defer {
            isAnalyzingDuplicates = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                if self?.isAnalyzingDuplicates == false { self?.duplicateStatus = "" }
            }
        }
        let scope: [VideoRecord]
        if let ids = selectedIDs, !ids.isEmpty {
            scope = records.filter { ids.contains($0.id) }
            DuplicateDetector.clear(records: scope)
        } else {
            scope = records
        }

        duplicateStatus = "Analyzing \(scope.count) files…"

        let summary = DuplicateDetector.analyze(records: scope)

        duplicateStatus = "\(summary.extraCopies) duplicates in \(summary.groups) groups"

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

    /// Delete high-confidence duplicate files on a given volume, but ONLY when
    /// the keeper (the `.keep` file in the same duplicate group) is also on the
    /// same volume.  This prevents deleting a file whose only surviving copy
    /// lives on a different (e.g. backup) volume.
    @discardableResult
    func deleteDuplicates(onVolume volumePath: String) -> (deleted: Int, failed: Int, skipped: Int, bytesFreed: Int64) {
        isDeletingDuplicates = true
        defer { isDeletingDuplicates = false }

        let prefix = volumePath.hasSuffix("/") ? volumePath : volumePath + "/"

        // Build keeper lookup: groupID → keeper record
        let keepers = keepersByGroupID()

        // Only target extra copies whose keeper is on the same volume
        let targets = records.filter { rec in
            guard rec.duplicateDisposition == .extraCopy,
                  rec.fullPath.hasPrefix(prefix),
                  let groupID = rec.duplicateGroupID,
                  let keeper = keepers[groupID] else { return false }
            return keeper.fullPath.hasPrefix(prefix)
        }

        let skippedCount = records.filter { rec in
            rec.duplicateDisposition == .extraCopy &&
            rec.fullPath.hasPrefix(prefix) &&
            !targets.contains(where: { $0.id == rec.id })
        }.count

        guard !targets.isEmpty else {
            if skippedCount > 0 {
                log("\nNo same-volume duplicates to delete on \(volumePath). Skipped \(skippedCount) file(s) whose keeper is on a different volume.")
            } else {
                log("\nNo high-confidence duplicates to delete on \(volumePath)")
            }
            return (0, 0, skippedCount, 0)
        }

        log("\nDeleting \(targets.count) same-volume duplicate(s) on \(volumePath)…")
        if skippedCount > 0 {
            log("  (Skipping \(skippedCount) file(s) whose keeper is on a different volume)")
        }

        var deleted = 0
        var failed = 0
        var bytesFreed: Int64 = 0
        let fm = FileManager.default

        for record in targets {
            let path = record.fullPath
            do {
                let attrs = try fm.attributesOfItem(atPath: path)
                let size = (attrs[.size] as? Int64) ?? 0
                try fm.removeItem(atPath: path)
                bytesFreed += size
                deleted += 1
                log("  Deleted: \(record.filename)")
            } catch {
                failed += 1
                log("  FAILED to delete \(record.filename): \(error.localizedDescription)")
            }
        }

        // Remove deleted records from the catalog
        let deletedPaths = Set(targets.filter { !FileManager.default.fileExists(atPath: $0.fullPath) }.map { $0.fullPath })
        records.removeAll { deletedPaths.contains($0.fullPath) }

        let freed = ByteCountFormatter.string(fromByteCount: bytesFreed, countStyle: .file)
        log("\nDuplicate deletion complete: \(deleted) deleted, \(failed) failed, \(skippedCount) skipped (cross-volume), \(freed) freed")
        duplicateStatus = "\(deleted) deleted, \(freed) freed"

        return (deleted, failed, skippedCount, bytesFreed)
    }

    /// Returns the distinct volume root paths that have high-confidence duplicate
    /// extra copies deletable on that volume (keeper also on same volume).
    func volumesWithDeletableDuplicates() -> [(path: String, count: Int)] {
        let keepers = keepersByGroupID()
        let extras = records.filter { rec in
            guard rec.duplicateDisposition == .extraCopy,
                  let groupID = rec.duplicateGroupID,
                  let keeper = keepers[groupID] else { return false }
            let volume = volumeRoot(for: rec.fullPath)
            let keeperVolume = volumeRoot(for: keeper.fullPath)
            return volume == keeperVolume
        }
        var volumeCounts: [String: Int] = [:]
        for record in extras {
            let volume = volumeRoot(for: record.fullPath)
            volumeCounts[volume, default: 0] += 1
        }
        return volumeCounts.sorted { $0.key < $1.key }.map { (path: $0.key, count: $0.value) }
    }

    /// Build a lookup from duplicate group ID to the keeper record in that group.
    func keepersByGroupID() -> [UUID: VideoRecord] {
        var result: [UUID: VideoRecord] = [:]
        for record in records {
            if record.duplicateDisposition == .keep, let groupID = record.duplicateGroupID {
                result[groupID] = record
            }
        }
        return result
    }

    func volumeRoot(for path: String) -> String {
        if path.hasPrefix("/Volumes/") {
            let parts = path.split(separator: "/", maxSplits: 3)
            if parts.count >= 2 {
                return "/\(parts[0])/\(parts[1])"
            }
        }
        // For non-/Volumes paths, use the scan target root that contains it
        for target in scanTargets {
            let prefix = target.searchPath.hasSuffix("/") ? target.searchPath : target.searchPath + "/"
            if path.hasPrefix(prefix) || path == target.searchPath {
                return target.searchPath
            }
        }
        return (path as NSString).deletingLastPathComponent
    }

    // MARK: - ffprobe

    nonisolated func runFFProbe(url: URL) async -> (output: FFProbeOutput?, stderr: String) {
        await CombineVerifier.runFFProbe(url: url, ffprobePath: ffprobePath)
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
        // Capture the cache key as Sendable String, not NSString. Re-bridge
        // inside the MainActor block where the NSCache lives.
        let cacheKeyString = record.fullPath
        Task.detached { [weak self] in
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 480, height: 270)

            let time = CMTime(seconds: 0.5, preferredTimescale: 600)
            do {
                let cgImage = try await withCheckedThrowingContinuation { cont in
                    generator.generateCGImageAsynchronously(for: time) { image, _, error in
                        if let image { cont.resume(returning: image) } else { cont.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
                    }
                }
                // CGImage is Sendable; NSImage and NSString aren't. Build
                // both on the main actor so we never cross actor boundaries
                // with them.
                await MainActor.run {
                    guard let self else { return }
                    let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                    self.thumbnailCache.setObject(nsImage, forKey: cacheKeyString as NSString)
                    self.previewImage = nsImage
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.previewImage = nil
                }
            }
        }
    }

    // MARK: - Helpers

}
