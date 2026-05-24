import Foundation
import SwiftUI
import Combine
import Darwin
import AVFoundation
import SQLite3

// MARK: - Scan Options

/// User-toggleable scan policy. Every toggle reads "Skip X" — consistent
/// polarity, no double negatives. Defaults match the fast-path
/// recommendation (three out of four "Skip" toggles ON).
struct ScanOptions: Equatable {
    /// Skip macOS/Windows/BSD system trees, app bundles, dev caches,
    /// Windows recycle bins. ON by default — family videos don't live in
    /// /System, node_modules, or $RECYCLE.BIN.
    var skipSystemFiles: Bool = true
    /// Skip `.photoslibrary`, `.fcpbundle`, `.imovielibrary`, etc. OFF by
    /// default — these *are* where user-created family media lives. Flip
    /// ON for a faster filesystem-only pass that ignores library bundles.
    var skipMediaBundles: Bool = false
    /// Skip files < 1 MB (stubs, thumbnails, .DS_Store-ish junk). ON by
    /// default — 1 MB is well under any real family video.
    var skipSmallFiles: Bool = true
    /// Skip partial-MD5 checksum. OFF by default — hashing lets Analyze
    /// Duplicates find copies later. Flip ON for a faster SMB scan when
    /// you don't care about dup detection this pass.
    var skipChecksums: Bool = false

    // MARK: Persistence
    // UserDefaults.standard is documented thread-safe (CFPreferences-backed
    // with internal locking). nonisolated(unsafe) tells strict concurrency
    // we know what we're doing.
    nonisolated(unsafe) private static let defaults = UserDefaults.standard
    private static let prefix = "scanopts_"

    static func restored() -> ScanOptions {
        let d = defaults; let p = prefix
        var s = ScanOptions()
        if d.object(forKey: "\(p)skipSystemFiles") != nil { s.skipSystemFiles  = d.bool(forKey: "\(p)skipSystemFiles") }
        if d.object(forKey: "\(p)skipMediaBundles") != nil { s.skipMediaBundles = d.bool(forKey: "\(p)skipMediaBundles") }
        if d.object(forKey: "\(p)skipSmallFiles") != nil { s.skipSmallFiles   = d.bool(forKey: "\(p)skipSmallFiles") }
        if d.object(forKey: "\(p)skipChecksums") != nil { s.skipChecksums    = d.bool(forKey: "\(p)skipChecksums") }
        return s
    }

    func save() {
        let d = Self.defaults; let p = Self.prefix
        d.set(skipSystemFiles, forKey: "\(p)skipSystemFiles")
        d.set(skipMediaBundles, forKey: "\(p)skipMediaBundles")
        d.set(skipSmallFiles, forKey: "\(p)skipSmallFiles")
        d.set(skipChecksums, forKey: "\(p)skipChecksums")
    }

    /// True when the user has deviated from the recommended fast-path
    /// defaults. Used to badge the menu icon so a non-default policy is
    /// visible at a glance.
    var isCustomized: Bool { self != ScanOptions() }

    /// The recommended fast-path preset — all three safe skips ON,
    /// checksums OFF. Same as default initializer.
    static let fastDefaults = ScanOptions()

    /// Scan everything, hash everything. Use when you suspect a rare find
    /// lives somewhere weird. Slower — walks system trees and hashes all.
    static let thorough = ScanOptions(
        skipSystemFiles: false,
        skipMediaBundles: false,
        skipSmallFiles: false,
        skipChecksums: false
    )
}

// MARK: - Skip List Categories (static — walkers consult ScanOptions to decide)

enum SkipCategories {
    /// Always-skipped: Finder metadata that never contains media and cannot
    /// be toggled on. These are filesystem plumbing, not content.
    static let finderMetaDirs: Set<String> = [
        ".spotlight-v100", ".fseventsd", ".trashes", ".temporaryitems",
        ".documentrevisions-v100", ".vol", "automount"
    ]
    /// macOS + BSD system trees. `library` is here because ~/Library holds
    /// app containers, never home videos. Togglable via includeSystemTrees.
    static let systemDirs: Set<String> = [
        "system", "library", "applications", "usr", "bin", "sbin",
        "private", "network", "cores", "dev", "opt", "var", "tmp",
        "etc", "volumes",
        "home", "net", "lost+found"
    ]
    /// Windows-formatted-volume leftovers (seen on osx10.8). Togglable.
    static let windowsTrashDirs: Set<String> = [
        "$recycle.bin", "recycler", "system volume information"
    ]
    /// Dev / build caches. Togglable.
    static let devCacheDirs: Set<String> = [
        "node_modules", ".git", ".svn", ".hg", "__pycache__",
        ".venv", "venv", ".cache", ".npm", ".cocoapods"
    ]
    /// Opaque OS/app bundles. Togglable via includeAppBundles.
    static let appBundleExtensions: Set<String> = [
        "app", "bundle", "framework", "kext", "plugin", "component",
        "mdimporter", "osax", "xpc", "lproj", "pkg", "mpkg", "docset",
        "pluginkit", "systemextension", "appex"
    ]
    /// User-media libraries. IN by default (opt-out via skipMediaLibraries).
    static let mediaLibraryExtensions: Set<String> = [
        "photoslibrary", "imovielibrary", "fcpbundle", "musiclibrary",
        "tvlibrary", "aplibrary", "finalcutprojectlibrary"
    ]
}

// MARK: - Performance Settings

struct ScanPerformanceSettings {
    var probesPerVolume: Int = 8          // concurrent ffprobe processes per volume
    var ramDiskGB: Int = 16               // RAM disk size for network prefetch (GB)
    var prefetchMB: Int = 50              // bytes to prefetch from network files (MB)
    var combineConcurrency: Int = 4       // concurrent ffmpeg combine processes
    var memoryFloorGB: Int = 4            // auto-pause when available RAM drops below this (GB)

    // MARK: Persistence

    // See ScanOptions.defaults — UserDefaults is thread-safe.
    nonisolated(unsafe) private static let defaults = UserDefaults.standard
    private static let prefix = "perf_"

    static func restored() -> ScanPerformanceSettings {
        let d = defaults; let p = prefix
        var s = ScanPerformanceSettings()
        if d.object(forKey: "\(p)probesPerVolume") != nil { s.probesPerVolume = d.integer(forKey: "\(p)probesPerVolume") }
        if d.object(forKey: "\(p)ramDiskGB") != nil { s.ramDiskGB = d.integer(forKey: "\(p)ramDiskGB") }
        if d.object(forKey: "\(p)prefetchMB") != nil { s.prefetchMB = d.integer(forKey: "\(p)prefetchMB") }
        if d.object(forKey: "\(p)combineConcurrency") != nil { s.combineConcurrency = d.integer(forKey: "\(p)combineConcurrency") }
        if d.object(forKey: "\(p)memoryFloorGB") != nil { s.memoryFloorGB = d.integer(forKey: "\(p)memoryFloorGB") }
        return s
    }

    func save() {
        let d = Self.defaults; let p = Self.prefix
        d.set(probesPerVolume, forKey: "\(p)probesPerVolume")
        d.set(ramDiskGB, forKey: "\(p)ramDiskGB")
        d.set(prefetchMB, forKey: "\(p)prefetchMB")
        d.set(combineConcurrency, forKey: "\(p)combineConcurrency")
        d.set(memoryFloorGB, forKey: "\(p)memoryFloorGB")
    }
}

// MARK: - Model

@MainActor
final class VideoScanModel: ObservableObject {
    @Published var records: [VideoRecord] = []
    @Published var isScanning: Bool = false
    @Published var isCombining: Bool = false
    @Published var isCorrelating: Bool = false
    @Published var isAnalyzingDuplicates: Bool = false
    @Published var isDeletingDuplicates: Bool = false
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

    private static let savedTargetsKey = "VideoScan.scanTargetPaths"
    private static let savedDatesKey = "VideoScan.scanTargetDates"
    private static let savedPhasesKey = "VideoScan.scanTargetPhases"
    private static let savedRolesKey = "VideoScan.scanTargetRoles"
    private static let savedTrustKey = "VideoScan.scanTargetTrust"
    private static let savedFilesystemKey = "VideoScan.scanTargetFilesystems"
    private static let savedMediaTechKey = "VideoScan.scanTargetMediaTechs"
    private static let savedPurchaseYearKey = "VideoScan.scanTargetPurchaseYears"
    private static let savedCapacityKey = "VideoScan.scanTargetCapacities"
    private static let savedNotesKey = "VideoScan.scanTargetNotes"

    private let catalogStore = CatalogStore.shared

    private static var isRunningTests: Bool {
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

    private var mountObservers: [NSObjectProtocol] = []

    /// Listen for drive mount/unmount events so the Scan Target list can
    /// flip its offline indicator without polling, and auto-add newly mounted volumes.
    private func installVolumeMountObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        let mount = nc.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            // Notification is non-Sendable; pull the userInfo URL out before
            // hopping to the main actor so we don't capture `note` itself.
            let volumeURL = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            Task { @MainActor in
                guard let self else { return }
                // Mount changes invalidate the per-volume reachability cache
                // — without this, the catalog table would keep returning
                // stale "offline" for the new mount until the 5s TTL expires.
                VolumeReachability.invalidateCache()
                self.refreshTargetReachability()
                // Auto-add newly mounted volume as a scan target (skip RAM disk)
                if let url = volumeURL {
                    let path = url.path
                    let volumeRoot = url.path
                    for t in self.scanTargets where t.searchPath.hasPrefix(volumeRoot) {
                        t.isReachable = VolumeReachability.isReachable(path: t.searchPath)
                    }
                    if !path.isEmpty,
                       !url.lastPathComponent.hasPrefix("VideoScan_Temp"),
                       self.scanTargets.contains(where: { $0.searchPath == path }) == false {
                        let target = CatalogScanTarget(searchPath: path)
                        target.isReachable = true
                        self.scanTargets.append(target)
                        self.persistScanTargets()
                        self.log("Auto-added mounted volume: \(url.lastPathComponent)")
                    }
                }
                self.notifyTargetsChanged()
            }
        }
        let unmount = nc.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // Same cache invalidation as the mount handler — a yanked
                // drive needs to flip to offline immediately, not after TTL.
                VolumeReachability.invalidateCache()
                self?.refreshTargetReachability()
                self?.notifyTargetsChanged()
            }
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

    /// Attempt to wake/access an offline volume. For network shares this may trigger
    /// automount; for sleeping USB drives it can spin them up. After a brief delay,
    /// re-check reachability and update the target's status.
    func wakeVolume(_ target: CatalogScanTarget) {
        let path = target.searchPath
        let volName = URL(fileURLWithPath: path).lastPathComponent
        log("Attempting to wake \(volName)…")
        Task.detached(priority: .userInitiated) {
            // Strategy 1: open() the volume root — this is what actually triggers
            // macOS disk arbitration to spin up sleeping USB/TB drives and triggers
            // automountd for network shares. fileExists alone only checks the cache.
            let fd = open(path, O_RDONLY | O_NONBLOCK)
            if fd >= 0 { close(fd) }

            // Strategy 2: For network volumes under /Volumes, ask Finder to open
            // the path via NSWorkspace. Finder knows saved credentials and can
            // remount SMB/AFP shares that automountd won't.
            let url = URL(fileURLWithPath: path)
            if path.hasPrefix("/Volumes/") {
                NSWorkspace.shared.open(url)
                // Give Finder a moment to mount the share
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            } else {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }

            await MainActor.run { [weak self] in
                let reachable = VolumeReachability.isReachable(path: path)
                target.isReachable = reachable
                if reachable {
                    self?.log("  \(volName) is now online.")
                } else {
                    self?.log("  \(volName) did not respond — try opening it in Finder.")
                }
                self?.refreshTargetReachability()
                self?.notifyTargetsChanged()
            }
        }
    }

    /// Eject a mounted volume. Uses NSWorkspace to safely unmount and eject.
    func ejectVolume(_ target: CatalogScanTarget) {
        let path = target.searchPath
        // Extract the volume root (e.g. /Volumes/MyDrive)
        let components = path.split(separator: "/", maxSplits: 3)
        guard components.count >= 2, components[0] == "Volumes" else {
            log("Cannot eject — not a /Volumes/ path: \(path)")
            return
        }
        let volumeRoot = "/\(components[0])/\(components[1])"
        let volumeName = String(components[1])
        log("Ejecting \(volumeName)…")
        let url = URL(fileURLWithPath: volumeRoot)
        Task.detached(priority: .userInitiated) {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                await MainActor.run { [weak self] in
                    self?.log("  \(volumeName) ejected.")
                    target.isReachable = false
                    self?.refreshTargetReachability()
                    self?.notifyTargetsChanged()
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.log("  Failed to eject \(volumeName): \(error.localizedDescription)")
                }
            }
        }
    }

    /// Delete all catalog records for a specific scan target's volume.
    func deleteCatalogForTarget(_ target: CatalogScanTarget) {
        let path = target.searchPath
        let volName = VolumeReachability.volumeName(forPath: path)
        // Reset target state BEFORE touching records so the UI picks up
        // the phase change on the same objectWillChange cycle.
        target.phase = .noCatalog
        target.lastScannedDate = nil
        target.filesFound = 0
        target.filesScanned = 0
        if target.status == .complete || target.status == .stopped || target.status == .error {
            target.status = .idle
        }
        let before = records.count
        records.removeAll { $0.fullPath.hasPrefix(path) }
        let removed = before - records.count
        // If any of the banner-tracked rows lived on this volume, the
        // banner's Undo would now skip them — drop the banner to avoid the
        // partial-restore confusion.
        clearPurgeUndoState()
        clearCacheForTarget(target)
        persistScanDates()
        saveCatalogNow()
        notifyTargetsChanged()
        log("Deleted \(removed) catalog record(s) for \(volName).")
    }

    /// Export volume info as CSV via a save panel.
    ///
    /// Purge policy: removed-from-catalog records are LOCAL-ONLY and never
    /// surface in the exported per-volume stats. Volume counts reflect what
    /// the user actually keeps in the catalog, not the trash bin.
    func exportVolumeInfo() {
        let activeRecords = pfActiveRecords(records)
        let excluded = records.count - activeRecords.count
        // Gather per-volume stats
        var volumePaths = Set<String>()
        for rec in activeRecords {
            let path = rec.fullPath
            if path.hasPrefix("/Volumes/") {
                let parts = path.split(separator: "/", maxSplits: 3)
                if parts.count >= 2 { volumePaths.insert("/Volumes/" + String(parts[1])) }
            }
        }
        // Also include scan targets that may have no records yet
        for t in scanTargets where !t.searchPath.isEmpty {
            volumePaths.insert(t.searchPath)
        }

        var csv = "Volume,Status,Files,Video+Audio,Video Only,Audio Only,Errors,Media Size,Codecs,Containers,Last Scanned\n"

        for vol in volumePaths.sorted() {
            let volRecords = activeRecords.filter { $0.fullPath.hasPrefix(vol) }
            let name = VolumeReachability.volumeName(forPath: vol)
            let target = scanTargets.first { $0.searchPath == vol }
            let status = target?.isReachable == true ? "Connected" : "Offline"
            let total = volRecords.count
            let va = volRecords.filter { $0.streamType == .videoAndAudio }.count
            let vo = volRecords.filter { $0.streamType == .videoOnly }.count
            let ao = volRecords.filter { $0.streamType == .audioOnly }.count
            let failed = volRecords.filter { $0.streamType == .ffprobeFailed }.count
            let bytes = volRecords.reduce(into: Int64(0)) { $0 += $1.sizeBytes }
            let mediaSize = bytes < 1_073_741_824
                ? String(format: "%.1f MB", Double(bytes) / 1_048_576)
                : String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
            let codecs = Set(volRecords.compactMap { $0.videoCodec.isEmpty ? nil : $0.videoCodec }).sorted().joined(separator: "; ")
            let containers = Set(volRecords.compactMap { $0.container.isEmpty ? nil : $0.container }).sorted().joined(separator: "; ")
            let lastScan: String
            if let date = target?.lastScannedDate {
                let fmt = DateFormatter()
                fmt.dateStyle = .medium
                fmt.timeStyle = .short
                lastScan = fmt.string(from: date)
            } else {
                lastScan = ""
            }
            csv += "\"\(name)\",\(status),\(total),\(va),\(vo),\(ao),\(failed),\"\(mediaSize)\",\"\(codecs)\",\"\(containers)\",\"\(lastScan)\"\n"
        }

        let panel = NSSavePanel()
        panel.title = "Export Volume Info"
        panel.nameFieldStringValue = "VideoScan_Volumes.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            if excluded > 0 {
                log("Exported volume info to \(url.lastPathComponent) (\(excluded) removed records excluded)")
            } else {
                log("Exported volume info to \(url.lastPathComponent)")
            }
        } catch {
            log("Export failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Catalog Import / Export
    //
    // Purpose: let the same user keep one catalog across multiple Macs. Rick
    // scans on the Mac Studio, exports the catalog JSON, AirDrops it to the
    // MBP on the couch, and imports it there — now he can browse and search
    // the full library from the laptop, and walk back upstairs only when he
    // needs the actual media file.
    //
    // Merge policy: content-identity dedup. `partialMD5 + sizeBytes` is the
    // strong key; when the import has no MD5 (e.g. an ffprobe-failed row) we
    // fall back to `filename + sizeBytes + floor(durationSeconds)`. Records
    // with neither identity are always added — better a rare duplicate than
    // a silently dropped row.

    struct CatalogImportResult {
        var added: Int
        var skipped: Int
        var sourceHost: String
    }

    /// Write the current `records` array to `url` as a v2 snapshot tagged
    /// with the current machine's name. Throws on write failure.
    ///
    /// Purge policy: removed-from-catalog records are LOCAL-ONLY. They are
    /// stripped from every export path so a catalog moved to another Mac
    /// looks like the user's curated view, not their personal trash bin.
    /// Restoring is a per-machine action — exports never carry purge state.
    func exportCatalog(to url: URL) throws {
        let activeRecords = pfActiveRecords(records)
        let excluded = records.count - activeRecords.count
        let snapshot = CatalogSnapshot(
            version: CatalogSnapshot.currentVersion,
            savedAt: Date(),
            records: activeRecords,
            savedFromHost: CatalogHost.currentName
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        try data.write(to: url, options: .atomic)
        if excluded > 0 {
            log("Exported \(activeRecords.count) records (\(excluded) removed records excluded)")
        } else {
            log("Exported \(activeRecords.count) records")
        }
    }

    /// Decode a catalog snapshot at `url` and merge its records into the
    /// current catalog, deduping by content identity. Each newly added
    /// record gets `sourceHost` stamped so the origin is traceable.
    /// Throws on decode failure.
    @discardableResult
    func importCatalog(from url: URL) throws -> CatalogImportResult {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(CatalogSnapshot.self, from: data)

        // Rewire pairedWith back-references within the imported array so
        // imported pairs keep pointing at each other, not at nothing.
        let importedByID = Dictionary(uniqueKeysWithValues: snapshot.records.map { ($0.id, $0) })
        for rec in snapshot.records {
            if let pid = rec.pendingPairedWithID {
                rec.pairedWith = importedByID[pid]
                rec.pendingPairedWithID = nil
            }
        }

        // Seed identity set from existing records so an import can't create
        // a duplicate of something we already have locally.
        var seen = Set<String>()
        for rec in records {
            if let key = Self.identityKey(for: rec) { seen.insert(key) }
        }

        // Fall back to filename-without-extension if the file forgot to stamp
        // savedFromHost (v1 snapshot or manual JSON).
        let effectiveHost: String = {
            if !snapshot.savedFromHost.isEmpty { return snapshot.savedFromHost }
            return url.deletingPathExtension().lastPathComponent
        }()

        var added = 0
        var skipped = 0
        for rec in snapshot.records {
            if let key = Self.identityKey(for: rec), seen.contains(key) {
                skipped += 1
                continue
            }
            if rec.sourceHost.isEmpty {
                rec.sourceHost = effectiveHost
            }
            records.append(rec)
            if let key = Self.identityKey(for: rec) { seen.insert(key) }
            added += 1
        }

        saveCatalogNow()
        return CatalogImportResult(added: added, skipped: skipped, sourceHost: effectiveHost)
    }

    private static func showErrorAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Stable content identity for a record.
    /// Primary: partial-MD5 + size. Fallback: filename + size + duration.
    /// Returns nil if the record has no identifying info at all — such
    /// records are always added rather than silently dropped.
    static func identityKey(for rec: VideoRecord) -> String? {
        if !rec.partialMD5.isEmpty && rec.sizeBytes > 0 {
            return "md5:\(rec.partialMD5):\(rec.sizeBytes)"
        }
        if rec.sizeBytes > 0 && !rec.filename.isEmpty {
            return "fn:\(rec.filename):\(rec.sizeBytes):\(Int(rec.durationSeconds))"
        }
        return nil
    }

    /// Show a save panel, then export. UI entry point.
    func exportCatalogViaPanel() {
        let panel = NSSavePanel()
        panel.title = "Export Catalog"
        panel.message = "Save the full catalog so you can import it on another Mac."
        let host = CatalogHost.currentName.replacingOccurrences(of: " ", with: "_")
        let dateStr = ISO8601DateFormatter().string(from: Date()).prefix(10)
        panel.nameFieldStringValue = "VideoScan_catalog_\(host)_\(dateStr).json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try exportCatalog(to: url)
            log("Exported \(records.count) record(s) to \(url.lastPathComponent)")
        } catch {
            log("Export failed: \(error.localizedDescription)")
            Self.showErrorAlert(title: "Export Failed", message: error.localizedDescription)
        }
    }

    /// Show an open panel, then import. UI entry point.
    func importCatalogViaPanel() {
        let panel = NSOpenPanel()
        panel.title = "Import Catalog"
        panel.message = "Import a catalog exported from another Mac. Records already present here are skipped."
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let result = try importCatalog(from: url)
            log("Imported \(result.added) new record(s) from \(result.sourceHost); skipped \(result.skipped) duplicate(s).")
            let alert = NSAlert()
            alert.messageText = "Catalog Imported"
            alert.informativeText = "Added \(result.added) new record(s) from \(result.sourceHost).\nSkipped \(result.skipped) record(s) already in this catalog."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        } catch {
            log("Import failed: \(error.localizedDescription)")
            Self.showErrorAlert(title: "Import Failed", message: error.localizedDescription)
        }
    }

    // MARK: - Catalog Navigation Helpers

    /// Find the set of record IDs that should be shown when navigating from
    /// Archive to Catalog for a given record. In pair mode, includes both the
    /// record and its partner (via `pairedWith` or `pairGroupID` fallback).
    nonisolated static func catalogFilterIDs(for recordID: UUID, pairMode: Bool, in records: [VideoRecord]) -> Set<UUID> {
        guard let rec = records.first(where: { $0.id == recordID }) else {
            return [recordID]
        }
        if !pairMode {
            return [recordID]
        }
        var ids: Set<UUID> = [recordID]
        if let partner = rec.pairedWith {
            ids.insert(partner.id)
        } else if let gid = rec.pairGroupID {
            for r in records where r.pairGroupID == gid && r.id != recordID {
                ids.insert(r.id)
            }
        }
        return ids
    }

    /// Expand a single record into a focus set: the record itself plus all
    /// duplicate-group members.
    func focusSet(for recordID: UUID) -> Set<UUID> {
        var ids: Set<UUID> = [recordID]
        if let rec = records.first(where: { $0.id == recordID }),
           let gid = rec.duplicateGroupID {
            for r in records where r.duplicateGroupID == gid {
                ids.insert(r.id)
            }
        }
        return ids
    }

    // MARK: - Online Substitute Finder

    struct OnlineSubstitute {
        let original: VideoRecord
        let substitute: VideoRecord
        let volumeName: String
    }

    /// Find online content-identical copies of an offline record.
    /// Matches on partialMD5 + sizeBytes (byte-identical) only — no fuzzy matching.
    nonisolated static func findOnlineSubstitutes(
        for record: VideoRecord,
        in allRecords: [VideoRecord]
    ) -> [OnlineSubstitute] {
        guard !record.partialMD5.isEmpty, record.sizeBytes > 0 else { return [] }

        return allRecords.compactMap { candidate in
            guard candidate.id != record.id,
                  candidate.partialMD5 == record.partialMD5,
                  candidate.sizeBytes == record.sizeBytes,
                  VolumeReachability.isReachable(path: candidate.fullPath)
            else { return nil }
            let vol = VolumeReachability.volumeName(forPath: candidate.fullPath)
            return OnlineSubstitute(original: record, substitute: candidate, volumeName: vol)
        }
    }

    // MARK: - Whole-shebang Bundle Import / Export
    //
    // The bundle format (see BundleExportImport.swift) wraps catalog +
    // per-volume metadata + machine-portable PersonFinderSettings + the
    // entire POI tree (profiles + reference photos) in a single
    // `<name>.videoscanbundle/` directory. Goal: after pulling the latest
    // code on the MBP and importing a bundle from the Mac Studio, the two
    // machines look identical to the user.

    /// UI entry point: show a save panel, write the bundle, summarize.
    func exportBundleViaPanel() {
        let panel = NSSavePanel()
        panel.title = "Export Everything"
        panel.message = "Save a VideoScan bundle containing the catalog, volume metadata, settings, and reference photos for every person."
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.directory]
        let host = CatalogHost.currentName.replacingOccurrences(of: " ", with: "_")
        let dateStr = ISO8601DateFormatter().string(from: Date()).prefix(10)
        panel.nameFieldStringValue = "VideoScan_\(host)_\(dateStr).videoscanbundle"
        guard panel.runModal() == .OK, var url = panel.url else { return }
        // NSSavePanel can drop our extension if the user retypes the name.
        if url.pathExtension != "videoscanbundle" {
            url = url.appendingPathExtension("videoscanbundle")
        }
        do {
            let summary = try BundleExporter.writeBundle(records: records,
                                                         scanTargets: scanTargets,
                                                         to: url)
            let m = summary.manifest
            // BundleExporter.writeBundle strips purged records before encoding.
            // Surface the excluded count so the local-only purge state is
            // discoverable in the log (matches CSV export logging).
            let excluded = records.count - m.counts.records
            if excluded > 0 {
                log("Exported bundle to \(url.lastPathComponent) — " +
                    "\(m.counts.records) records (\(excluded) removed records excluded), " +
                    "\(m.counts.volumes) volumes, " +
                    "\(m.counts.people) people, \(m.counts.referencePhotos) photos, " +
                    "\(BundleSize.human(m.sizes.totalBytes)).")
            } else {
                log("Exported bundle to \(url.lastPathComponent) — " +
                    "\(m.counts.records) records, \(m.counts.volumes) volumes, " +
                    "\(m.counts.people) people, \(m.counts.referencePhotos) photos, " +
                    "\(BundleSize.human(m.sizes.totalBytes)).")
            }
            // Surface export warnings (typically dangling symlinks) so Rick
            // knows the bundle is missing a few photos. Logged individually
            // for the audit trail; summarized in the alert.
            for w in summary.exportWarnings {
                log("Export warning: \(w.path) — \(w.reason)")
            }
            let warningsBlurb: String
            if summary.exportWarnings.isEmpty {
                warningsBlurb = ""
            } else {
                let preview = summary.exportWarnings.prefix(5)
                    .map { "  – \($0.path): \($0.reason)" }
                    .joined(separator: "\n")
                let more = summary.exportWarnings.count > 5
                    ? "\n  – …and \(summary.exportWarnings.count - 5) more (see log)"
                    : ""
                warningsBlurb = """


                Warnings (\(summary.exportWarnings.count)):
                \(preview)\(more)
                """
            }
            // Loud banner when ANY POI shipped without a valid profile.json —
            // that means the bundle is not safely importable on another Mac
            // (which is the bug that motivated this validator). Surfaced
            // ABOVE the normal counts so Rick can't miss it.
            let missingProfileBanner: String
            let missing = summary.missingProfileJSONCount
            if missing > 0 {
                let plural = missing == 1 ? "" : "s"
                missingProfileBanner =
                    "\u{26A0}\u{FE0F} \(missing) POI\(plural) shipped without profile.json — re-export recommended\n\n"
            } else {
                missingProfileBanner = ""
            }
            let alert = NSAlert()
            alert.messageText = "Exported Everything"
            alert.informativeText = """
            \(missingProfileBanner)Saved \(url.lastPathComponent)

            • \(m.counts.records) catalog record(s)
            • \(m.counts.volumes) volume(s)
            • \(m.counts.people) person profile(s) with \(m.counts.referencePhotos) reference photo(s)
            • Total size: \(BundleSize.human(m.sizes.totalBytes)) (photos: \(BundleSize.human(m.sizes.referencePhotoBytes)))\(warningsBlurb)
            """
            alert.addButton(withTitle: "OK")
            alert.runModal()
        } catch {
            log("Bundle export failed: \(error.localizedDescription)")
            Self.showErrorAlert(title: "Export Failed", message: error.localizedDescription)
        }
    }

    /// UI entry point: show an open panel, parse the bundle, ask for
    /// confirmation, then merge into live state.
    ///
    /// POI install is `async` (iCloud materialization polls in the
    /// background). The open/confirm panels and the final alert run on the
    /// main actor; the polling loop is `await`ed off the main thread.
    func importBundleViaPanel() {
        let panel = NSOpenPanel()
        panel.title = "Import Everything"
        panel.message = "Choose a .videoscanbundle directory from another Mac."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let payload: BundleImporter.Payload
        do {
            payload = try BundleImporter.read(from: url)
        } catch {
            log("Bundle import failed: \(error.localizedDescription)")
            Self.showErrorAlert(title: "Import Failed", message: error.localizedDescription)
            return
        }

        // Confirmation dialog — bundles can be sizeable and this overwrites
        // POI folders, so make the user opt in deliberately.
        let confirm = NSAlert()
        confirm.messageText = "Import Everything from this Bundle?"
        confirm.informativeText = """
        From: \(payload.manifest.exportedFromHost) on \(Self.shortDate(payload.manifest.exportedAt))
        App: v\(payload.manifest.appVersion) build \(payload.manifest.appBuild)

        • \(payload.manifest.counts.records) catalog record(s)
        • \(payload.manifest.counts.volumes) volume(s) of metadata
        • \(payload.manifest.counts.people) person profile(s) (\(payload.manifest.counts.referencePhotos) photo(s))

        Catalog records merge by content identity (no duplicates). \
        Volume metadata for matching paths is overwritten. \
        For each person, the version with MORE reference photos wins \
        (ties broken by newest first). Replaced POI folders are moved \
        to ~/dev/VideoScan/.trash/ for recovery.
        """
        confirm.addButton(withTitle: "Import")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else {
            log("Bundle import canceled.")
            return
        }

        // Hand off to async — POI install does iCloud polling that must not
        // block the main actor. The Task is @MainActor-isolated so we can
        // mutate model state safely; awaits inside hop to background work.
        // Swift's `Task { @MainActor in … }` ≈ "post this to the UI thread".
        Task { @MainActor in
            let result = await applyBundlePayload(payload, bundleURL: url)
            self.log("Imported bundle from \(payload.manifest.exportedFromHost): " +
                "\(result.recordsAdded) new records, \(result.recordsSkipped) duplicates skipped, " +
                "\(result.volumesUpdated) volume(s) updated, \(result.volumesAdded) added, " +
                "\(result.peopleInstalled.count) person profile(s) installed, " +
                "\(result.peopleSkipped.count) skipped, \(result.peopleFailed.count) failed.")

            // Build the user-visible alert body with all three POI buckets,
            // plus the audit log path.
            let installedLine = Self.formatPOIBucket(label: "Installed",
                                                     count: result.peopleInstalled.count,
                                                     names: result.peopleInstalled)
            let skippedLine = Self.formatPOIBucket(label: "Skipped (local copy preferred)",
                                                   count: result.peopleSkipped.count,
                                                   names: result.peopleSkipped.map { $0.name })
            let failedLine = Self.formatPOIFailures(result.peopleFailed)
            var body = """
            Imported from \(url.lastPathComponent).

            • \(result.recordsAdded) new catalog record(s) (skipped \(result.recordsSkipped) already here)
            • \(result.volumesUpdated) volume(s) updated, \(result.volumesAdded) new volume(s) added
            • \(installedLine)
            • \(skippedLine)
            """
            if !failedLine.isEmpty {
                body += "\n• \(failedLine)"
            }
            if let auditURL = result.auditLogURL {
                body += "\n\nAudit log: \(auditURL.path)"
            }
            body += "\n\nPerson Finder settings will take effect after relaunching VideoScan."

            let done = NSAlert()
            done.messageText = "Bundle Imported"
            done.informativeText = body
            done.addButton(withTitle: "OK")
            done.runModal()
        }
    }

    struct BundleImportResult {
        var recordsAdded: Int
        var recordsSkipped: Int
        var volumesUpdated: Int
        var volumesAdded: Int
        /// POI folder names that won and were installed.
        var peopleInstalled: [String]
        /// POI folder names where the local copy was preferred (reason).
        var peopleSkipped: [(name: String, reason: String)]
        /// POI folder names that errored during materialize/copy/validate.
        var peopleFailed: [(name: String, reason: String)]
        /// Path to the per-import audit log under ~/Library/Logs/VideoScan/.
        /// nil only if writing the log itself failed.
        var auditLogURL: URL?

        /// Back-compat shim: callers / tests that asked for `peopleInstalled`
        /// as an Int can use this. The new structured form is preferred.
        var peopleInstalledCount: Int { peopleInstalled.count }
    }

    /// Merge a parsed bundle payload into live model state. Async because
    /// POI install does iCloud-aware polling. Separated from
    /// `importBundleViaPanel` so tests can call it directly.
    @discardableResult
    func applyBundlePayload(_ payload: BundleImporter.Payload,
                            bundleURL: URL) async -> BundleImportResult {
        // Catalog — seed identity set from existing records, dedup on insert.
        var seen = Set<String>()
        for rec in records {
            if let key = Self.identityKey(for: rec) { seen.insert(key) }
        }
        let effectiveHost = payload.catalog.savedFromHost.isEmpty
            ? payload.manifest.exportedFromHost
            : payload.catalog.savedFromHost
        var added = 0
        var skipped = 0
        for rec in payload.catalog.records {
            if let key = Self.identityKey(for: rec), seen.contains(key) {
                skipped += 1
                continue
            }
            if rec.sourceHost.isEmpty {
                rec.sourceHost = effectiveHost
            }
            records.append(rec)
            if let key = Self.identityKey(for: rec) { seen.insert(key) }
            added += 1
        }

        // Volumes — overwrite metadata on path match; add as offline target
        // when the path isn't present locally so the volume shows up in the
        // sidebar (grayed out until the drive is connected on this Mac).
        var updated = 0
        var addedVolumes = 0
        for snap in payload.volumes.volumes {
            if let existing = scanTargets.first(where: { $0.searchPath == snap.searchPath }) {
                applyVolumeSnapshot(snap, to: existing)
                updated += 1
            } else {
                let t = CatalogScanTarget(searchPath: snap.searchPath)
                applyVolumeSnapshot(snap, to: t)
                scanTargets.append(t)
                addedVolumes += 1
            }
        }
        if updated > 0 || addedVolumes > 0 {
            persistScanTargets()
            persistScanDates()
            notifyTargetsChanged()
        }

        // Settings — merge portable fields onto current settings, save back.
        var current = PersonFinderSettings.restored()
        payload.settings.apply(to: &current)
        current.save()

        // POIs — safe install with iCloud materialization, validation, and
        // conflict resolution. Failures here are logged but don't roll back
        // the catalog/volumes/settings work above. See
        // `BundleImporter.installPOIs` for the gory details.
        let poiResult = await BundleImporter.installPOIs(
            from: payload.poiFoldersInBundle,
            bundleExportedAt: payload.bundleExportedAt
        )

        // Write per-import audit log so Rick can review every POI decision.
        let auditURL = Self.writeImportAuditLog(bundleURL: bundleURL,
                                                 payload: payload,
                                                 poiResult: poiResult)
        // Mirror the audit summary into the dashboard log too.
        for line in poiResult.auditLines {
            log(line)
        }

        saveCatalogNow()
        return BundleImportResult(
            recordsAdded: added,
            recordsSkipped: skipped,
            volumesUpdated: updated,
            volumesAdded: addedVolumes,
            peopleInstalled: poiResult.installed,
            peopleSkipped: poiResult.skipped,
            peopleFailed: poiResult.failed,
            auditLogURL: auditURL
        )
    }

    // MARK: - Bundle import: formatting helpers

    /// Render an "Installed: 8 (donna, timmy, ...)" style bucket. Truncates
    /// long lists with an ellipsis so the alert stays readable.
    private static func formatPOIBucket(label: String,
                                        count: Int,
                                        names: [String]) -> String {
        if count == 0 { return "\(label): 0" }
        let shown = names.prefix(8).joined(separator: ", ")
        if names.count > 8 {
            return "\(label): \(count) (\(shown), …)"
        }
        return "\(label): \(count) (\(shown))"
    }

    /// Render the failed bucket with reasons inline — Rick needs the "why"
    /// to know whether to retry or investigate.
    private static func formatPOIFailures(_ failures: [(name: String, reason: String)]) -> String {
        guard !failures.isEmpty else { return "" }
        let shown = failures.prefix(5)
            .map { "\($0.name): \($0.reason)" }
            .joined(separator: "; ")
        if failures.count > 5 {
            return "Failed: \(failures.count) (\(shown); …see audit log)"
        }
        return "Failed: \(failures.count) (\(shown))"
    }

    /// Write a one-shot per-import audit log under
    /// `~/Library/Logs/VideoScan/import-<ISO8601-date>.log`. Returns the URL
    /// (or nil if writing failed — never throws to the caller).
    ///
    /// The audit log captures every POI decision verbatim plus a summary
    /// header — Rick wants to be able to answer "why didn't 'matt' come
    /// across?" weeks later. Format matches `PersistentLog` loosely but is
    /// written all-at-once (the import is short enough that crash-resilient
    /// streaming isn't worth the complexity).
    private static func writeImportAuditLog(bundleURL: URL,
                                            payload: BundleImporter.Payload,
                                            poiResult: BundleImporter.POIInstallResult) -> URL? {
        let stampFmt = DateFormatter()
        stampFmt.dateFormat = "yyyyMMdd-HHmmss"
        stampFmt.timeZone = TimeZone(secondsFromGMT: 0)
        let stamp = stampFmt.string(from: Date())
        let url = PersistentLog.logDir.appendingPathComponent("import-\(stamp).log")

        var body = """
        VideoScan import audit log
        ─────────────────────────────────────────────
        Started:        \(ISO8601DateFormatter().string(from: Date()))
        Bundle path:    \(bundleURL.path)
        Bundle host:    \(payload.manifest.exportedFromHost)
        Bundle date:    \(ISO8601DateFormatter().string(from: payload.manifest.exportedAt))
        Bundle app:     v\(payload.manifest.appVersion) build \(payload.manifest.appBuild)
        Counts:         \(payload.manifest.counts.records) records, \
        \(payload.manifest.counts.volumes) volumes, \
        \(payload.manifest.counts.people) people, \
        \(payload.manifest.counts.referencePhotos) photos
        ─────────────────────────────────────────────
        POI decisions:

        """
        for line in poiResult.auditLines {
            body += line + "\n"
        }
        body += """

        ─────────────────────────────────────────────
        Summary:
          installed: \(poiResult.installed.count) — \(poiResult.installed.joined(separator: ", "))
          skipped:   \(poiResult.skipped.count) — \(poiResult.skipped.map { "\($0.name) (\($0.reason))" }.joined(separator: "; "))
          failed:    \(poiResult.failed.count) — \(poiResult.failed.map { "\($0.name): \($0.reason)" }.joined(separator: "; "))
        ─────────────────────────────────────────────
        """

        do {
            try FileManager.default.createDirectory(at: PersistentLog.logDir,
                                                    withIntermediateDirectories: true)
            try body.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            // Best-effort: log to dashboard via NSLog so we don't lose this
            // failure. Returning nil tells the alert to omit the audit line.
            NSLog("VideoScan: failed to write import audit log at \(url.path): \(error)")
            return nil
        }
    }

    private func applyVolumeSnapshot(_ s: VolumeMetadataSnapshot, to t: CatalogScanTarget) {
        ScanTargetPersistence.applyVolumeSnapshot(s, to: t)
    }

    private static func shortDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: d)
    }

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

    // MARK: - Soft-delete (Remove from Catalog)
    //
    // Mirrors the POI delete pattern (see PersonFinderModel.deletePOI +
    // POIStorage.trashPOIFolder). Differences from POI:
    //  - The "trash" is the catalog itself: setting purgedAt=Date() hides
    //    the row from the default view; files on disk are untouched.
    //  - Undo restores the *batch* (right-click on a multi-select), not
    //    just a single record — Rick wants one Cmd-Z to walk back the
    //    whole "Remove from Catalog" action.
    //  - There is no on-disk .trash/ folder to clean up — recovery is
    //    free, the purged rows live in catalog.json forever until the
    //    user explicitly restores them.
    //
    // Session-scope undo: app relaunch drops the banner state, exactly
    // like the POI banner. Only ONE undo target at a time — a second
    // purge supersedes the first (the first batch stays purged but is no
    // longer one-tap recoverable; the user can still flip "Show removed"
    // and right-click → Restore).

    /// Snapshot of the most recent purge. Holds the affected record IDs so
    /// undo can flip them back. Includes the timestamp written into each
    /// record's purgedAt for diagnostics.
    struct LastPurgedBatch: Equatable {
        let ids: [UUID]         // records whose purgedAt we set
        let timestamp: Date     // value we wrote into purgedAt
    }

    /// The banner observes this. nil = no banner shown.
    @Published var lastPurgedBatch: LastPurgedBatch?

    /// Surface for undo errors (e.g. all target records have been deleted
    /// from the catalog between purge and undo). Banner shows this in
    /// place of the default "Removed N items." message.
    @Published var lastPurgeUndoError: String?

    /// Mark the given record IDs as purged. Sets `purgedAt = now` on every
    /// match, persists, and arms the undo banner with the affected IDs.
    /// Returns the count actually mutated (records already purged are not
    /// double-stamped, and bogus IDs are silently ignored).
    @discardableResult
    func purgeRecords(ids: Set<UUID>) -> Int {
        guard !ids.isEmpty else { return 0 }
        let now = Date()
        var changed: [UUID] = []
        for rec in records where ids.contains(rec.id) && rec.purgedAt == nil {
            rec.purgedAt = now
            changed.append(rec.id)
        }
        guard !changed.isEmpty else { return 0 }
        saveCatalogDebounced()
        // Arm the undo banner. Supersedes any previous batch (matches POI
        // single-target undo semantics). The previous batch stays purged
        // and can still be recovered via Show Removed → right-click → Restore.
        lastPurgedBatch = LastPurgedBatch(ids: changed, timestamp: now)
        lastPurgeUndoError = nil
        return changed.count
    }

    /// Clear `purgedAt` on a single record. Used by the right-click menu
    /// on a purged row when "Show removed" is on. Returns true on success.
    @discardableResult
    func restoreRecord(id: UUID) -> Bool {
        guard let rec = records.first(where: { $0.id == id }),
              rec.purgedAt != nil else { return false }
        rec.purgedAt = nil
        saveCatalogDebounced()
        // If the user manually restores a record from the most recent
        // purge batch, drop it from the undo set so the banner's "Undo"
        // doesn't no-op or surface a confusing partial restore later.
        if var snap = lastPurgedBatch {
            snap = LastPurgedBatch(
                ids: snap.ids.filter { $0 != id },
                timestamp: snap.timestamp
            )
            if snap.ids.isEmpty {
                lastPurgedBatch = nil
                lastPurgeUndoError = nil
            } else {
                lastPurgedBatch = snap
            }
        }
        return true
    }

    /// Restore the most recently purged batch. Returns true if at least
    /// one record was un-purged. Drops the banner on success or when the
    /// batch has nothing left to restore (all records already deleted /
    /// already restored manually).
    @discardableResult
    func undoLastPurge() -> Bool {
        guard let snap = lastPurgedBatch else { return false }
        var restored = 0
        for id in snap.ids {
            if let rec = records.first(where: { $0.id == id }),
               rec.purgedAt != nil {
                rec.purgedAt = nil
                restored += 1
            }
        }
        if restored == 0 {
            // Everything in the batch is gone (e.g. user deleted the
            // catalog or restored records manually). Drop the banner —
            // nothing to undo.
            lastPurgedBatch = nil
            lastPurgeUndoError = nil
            return false
        }
        saveCatalogDebounced()
        lastPurgedBatch = nil
        lastPurgeUndoError = nil
        return true
    }

    /// Dismiss the undo banner without restoring. The purged records
    /// stay hidden in the default view — only the one-tap undo affordance
    /// goes away. They remain recoverable via "Show removed" → right-click
    /// → Restore.
    func dismissPurgeUndoBanner() {
        lastPurgedBatch = nil
        lastPurgeUndoError = nil
    }

    /// Drop the undo banner state. Called by catalog-wide mutations that
    /// reseed `records` wholesale (deleteAllCatalog, deleteCatalogForTarget,
    /// clearResults) — once the target rows are gone, the banner's "Undo"
    /// would no-op anyway, and leaving the banner armed would mislead the
    /// user into thinking their delete is reversible. Cheap idempotent reset.
    private func clearPurgeUndoState() {
        lastPurgedBatch = nil
        lastPurgeUndoError = nil
    }

    private func restoreScanTargets() {
        let restored = ScanTargetPersistence.restore(
            existing: scanTargets,
            savedTargetsKey: Self.savedTargetsKey,
            savedDatesKey: Self.savedDatesKey,
            savedPhasesKey: Self.savedPhasesKey,
            savedRolesKey: Self.savedRolesKey,
            savedTrustKey: Self.savedTrustKey,
            savedFilesystemKey: Self.savedFilesystemKey,
            savedMediaTechKey: Self.savedMediaTechKey,
            savedPurchaseYearKey: Self.savedPurchaseYearKey,
            savedCapacityKey: Self.savedCapacityKey,
            savedNotesKey: Self.savedNotesKey
        )
        scanTargets.append(contentsOf: restored)
    }

    private func persistScanTargets() {
        if Self.isRunningTests { return }
        ScanTargetPersistence.persistPaths(scanTargets, key: Self.savedTargetsKey)
    }

    private func persistScanDates() {
        if Self.isRunningTests { return }
        ScanTargetPersistence.persistMetadata(
            scanTargets,
            savedDatesKey: Self.savedDatesKey,
            savedPhasesKey: Self.savedPhasesKey,
            savedRolesKey: Self.savedRolesKey,
            savedTrustKey: Self.savedTrustKey,
            savedFilesystemKey: Self.savedFilesystemKey,
            savedMediaTechKey: Self.savedMediaTechKey,
            savedPurchaseYearKey: Self.savedPurchaseYearKey,
            savedCapacityKey: Self.savedCapacityKey,
            savedNotesKey: Self.savedNotesKey
        )
    }

    // MARK: - Phase Consistency

    /// If a target claims "Cataloged" but has zero records, the catalog was
    /// deleted or lost — reset to NO CATALOG so the UI doesn't lie.
    func enforcePhaseConsistency() {
        for t in scanTargets where t.phase == .cataloged {
            let hasRecords = records.contains { $0.fullPath.hasPrefix(t.searchPath) }
            if !hasRecords {
                t.phase = .noCatalog
                t.lastScannedDate = nil
            }
        }
    }

    /// If a target shows noCatalog but we have records for it, a previous
    /// test run (or crash) corrupted the persisted phase. Re-derive the
    /// phase from actual catalog data. Returns number of targets repaired.
    @discardableResult
    func repairCorruptedPhases() -> Int {
        guard !records.isEmpty else { return 0 }
        var repaired = 0
        for t in scanTargets where t.phase == .noCatalog && !t.searchPath.isEmpty {
            if records.contains(where: { $0.fullPath.hasPrefix(t.searchPath) }) {
                t.phase = .cataloged
                repaired += 1
            }
        }
        if repaired > 0 {
            log("Repaired \(repaired) volume phase(s) — catalog data exists but phases were reset.")
            persistScanDates()
        }
        return repaired
    }

    /// Update a volume's lifecycle phase and persist.
    func setPhase(_ phase: VolumePhase, for target: CatalogScanTarget) {
        target.phase = phase
        persistScanDates()
        notifyTargetsChanged()
    }

    func setRole(_ role: VolumeRole, for target: CatalogScanTarget) {
        target.role = role
        persistScanDates()
        notifyTargetsChanged()
    }

    func setTrust(_ trust: VolumeTrust, for target: CatalogScanTarget) {
        target.trust = trust
        persistScanDates()
        notifyTargetsChanged()
    }

    func setFilesystem(_ value: String, for target: CatalogScanTarget) {
        target.filesystem = value
        persistScanDates()
        notifyTargetsChanged()
    }

    func setMediaTech(_ value: VolumeMediaTech, for target: CatalogScanTarget) {
        target.mediaTech = value
        persistScanDates()
        notifyTargetsChanged()
    }

    func setPurchaseYear(_ value: Int?, for target: CatalogScanTarget) {
        target.purchaseYear = value
        persistScanDates()
        notifyTargetsChanged()
    }

    func setCapacityTB(_ value: Double?, for target: CatalogScanTarget) {
        target.capacityTB = value
        persistScanDates()
        notifyTargetsChanged()
    }

    func setNotes(_ value: String, for target: CatalogScanTarget) {
        target.notes = value
        persistScanDates()
        notifyTargetsChanged()
    }

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
                skipHashing: skipHashing
            )
        } else {
            rec = await self.probeFile(
                url: url,
                prefetchToRAM: rootIsNetwork,
                ramPath: ramMountPoint,
                skipHashing: skipHashing
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

        backfillTask = Task {
            struct BackfillResult {
                let recIndex: Int
                let reachable: Bool
                var capturedContext: ScanContext?
            }

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
    nonisolated func probeFileWithTimeout(url: URL, prefetchToRAM: Bool = false, ramPath: String? = nil, skipHashing: Bool = false) async -> VideoRecord {
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
                    await self.probeFile(url: url, prefetchToRAM: prefetchToRAM, ramPath: ramPath, skipHashing: skipHashing)
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
    nonisolated func probeFile(url: URL, prefetchToRAM: Bool = false, ramPath: String? = nil, skipHashing: Bool = false) async -> VideoRecord {
        let fm = FileManager.default
        let path = url.path

        // Quick existence check — on network volumes, files discovered during
        // the walk phase can vanish by the time we probe (symlinks, aliases,
        // unmounted subdirs). Skip immediately rather than wasting time on
        // ffprobe which will also fail.
        guard VolumeReachability.isReachable(path: path) else {
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
            cached.scanContext = ScanContext.capture(for: url)
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
        rec.scanContext = ScanContext.capture(for: url)
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
