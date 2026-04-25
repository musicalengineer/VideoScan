import Foundation
import CryptoKit
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
    private static let defaults = UserDefaults.standard
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

    private static let defaults = UserDefaults.standard
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
    @Published var outputCSVPath: String = ""
    @Published var previewImage: NSImage?
    @Published var previewFilename: String = ""
    /// Set by Archive tab to navigate the Catalog tab to a specific record.
    @Published var pendingCatalogSelection: UUID?
    /// When true, Show Pair mode: filter catalog to show the selected file
    /// and its correlated pair instead of just the one file.
    @Published var pendingCatalogPairMode: Bool = false
    /// Set when the user selects a record whose source volume isn't currently
    /// mounted. CatalogContent renders an "Volume Offline" placeholder
    /// instead of trying to load a thumbnail.
    @Published var previewOfflineVolumeName: String?

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

    let ffprobePath = "/opt/homebrew/bin/ffprobe"
    let ffmpegPath  = "/opt/homebrew/bin/ffmpeg"

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

    private var scanTask: Task<Void, Never>?
    private var combineTask: Task<Void, Never>?
    private var ramDisk = RAMDisk()
    nonisolated private let metadataCache = MetadataCache()

    /// Cooperative pause gate for scan tasks
    let pauseGate = PauseGate()
    @Published var isPaused: Bool = false

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
        // Consistency check: if a target claims "Cataloged" but has zero
        // records, the catalog was deleted or lost — reset to NO CATALOG.
        for t in scanTargets where t.phase == .cataloged {
            let hasRecords = records.contains { $0.fullPath.hasPrefix(t.searchPath) }
            if !hasRecords {
                t.phase = .noCatalog
                t.lastScannedDate = nil
            }
        }
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
            Task { @MainActor in
                guard let self else { return }
                self.refreshTargetReachability()
                // Auto-add newly mounted volume as a scan target (skip RAM disk)
                if let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
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
                await NSWorkspace.shared.open(url)
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
                try await NSWorkspace.shared.unmountAndEjectDevice(at: url)
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
        clearCacheForTarget(target)
        persistScanDates()
        saveCatalogNow()
        notifyTargetsChanged()
        log("Deleted \(removed) catalog record(s) for \(volName).")
    }

    /// Export volume info as CSV via a save panel.
    func exportVolumeInfo() {
        // Gather per-volume stats
        var volumePaths = Set<String>()
        for rec in records {
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
            let volRecords = records.filter { $0.fullPath.hasPrefix(vol) }
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
            log("Exported volume info to \(url.lastPathComponent)")
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
    func exportCatalog(to url: URL) throws {
        let snapshot = CatalogSnapshot(
            version: CatalogSnapshot.currentVersion,
            savedAt: Date(),
            records: records,
            savedFromHost: CatalogHost.currentName
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        try data.write(to: url, options: .atomic)
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

    private func restoreScanTargets() {
        let paths = UserDefaults.standard.stringArray(forKey: Self.savedTargetsKey) ?? []
        let dates = UserDefaults.standard.dictionary(forKey: Self.savedDatesKey) as? [String: Date] ?? [:]
        let phases = UserDefaults.standard.dictionary(forKey: Self.savedPhasesKey) as? [String: String] ?? [:]
        for p in paths where !p.isEmpty {
            if !scanTargets.contains(where: { $0.searchPath == p }) {
                let t = CatalogScanTarget(searchPath: p)
                t.lastScannedDate = dates[p]
                if let raw = phases[p] {
                    if let phase = VolumePhase(rawValue: raw) {
                        t.phase = phase
                    } else if raw == "New" {
                        t.phase = .noCatalog
                    }
                }
                scanTargets.append(t)
            }
        }
    }

    private func persistScanTargets() {
        let paths = scanTargets.map { $0.searchPath }
        UserDefaults.standard.set(paths, forKey: Self.savedTargetsKey)
    }

    /// Save scan-completion dates and phases so they survive relaunch.
    private func persistScanDates() {
        var dates: [String: Date] = [:]
        var phases: [String: String] = [:]
        for t in scanTargets {
            if let d = t.lastScannedDate {
                dates[t.searchPath] = d
            }
            phases[t.searchPath] = t.phase.rawValue
        }
        UserDefaults.standard.set(dates, forKey: Self.savedDatesKey)
        UserDefaults.standard.set(phases, forKey: Self.savedPhasesKey)
    }

    /// Update a volume's lifecycle phase and persist.
    func setPhase(_ phase: VolumePhase, for target: CatalogScanTarget) {
        target.phase = phase
        persistScanDates()
        notifyTargetsChanged()
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
            guard fm.isReadableFile(atPath: path) else { return nil }

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
            updateGlobalScanState()
            return
        }
        records.append(contentsOf: targetRecords)
        saveCatalogDebounced()
        logTargetScanSummary(volName: volName, records: targetRecords)
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

        // Mount RAM disk up-front for network scans so ffprobe prefetch works
        // from the first probed file AND the user can see /Volumes/VideoScan_Temp
        // appear right away instead of waiting for a long walk to finish.
        let ramMountPoint = await mountScanRAMDiskIfNeeded(hasNetwork: rootIsNetwork)

        // Streaming walk + interleaved probe — see runTargetProbeGroup.
        dashboard.scanPhase = .probing
        target.status = .scanning

        let result = await runTargetProbeGroup(
            target: target,
            root: root,
            volName: volName,
            rootIsNetwork: rootIsNetwork,
            ramMountPoint: ramMountPoint
        )

        await finalizeSingleTargetScan(
            target: target,
            volName: volName,
            targetRecords: result.records,
            completedCount: result.completed,
            discoveredCount: result.discovered,
            rootIsNetwork: rootIsNetwork
        )
    }

    /// Streams `target.searchPath` and drains a probe group against it.
    /// Returns the collected records, total discovered, and total completed.
    private func runTargetProbeGroup(
        target: CatalogScanTarget,
        root: String,
        volName: String,
        rootIsNetwork: Bool,
        ramMountPoint: String?
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
        let abortAfter = 50

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
                    return await sem.withPermit {
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

            for await rec in probeGroup {
                targetRecords.append(rec)
                completedCount += 1
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
        let ramMountPoint = await mountScanRAMDiskIfNeeded(hasNetwork: hasNetworkRoot)

        // Per-root streaming walk + interleaved probe (producer-consumer).
        //
        // Each root gets its own walker Task and its own prober pool. Probes
        // begin as soon as the walker yields the first URL, so SMB content
        // reads start within seconds and keep the remote session warm while
        // the rest of the tree is enumerated. This replaces the old two-phase
        // "walk everything, then probe everything" scheme that let long
        // network walks idle out the session before probing could begin.
        dashboard.scanPhase = .probing
        dashboard.volumeProgress = roots.map { root in
            VolumeProgress(rootPath: root, volumeName: URL(fileURLWithPath: root).lastPathComponent)
        }
        dashboard.startThroughputTimer()

        var allRecords: [VideoRecord] = []

        // Capture settings on main actor before entering task group
        let probesLimit = perfSettings.probesPerVolume
        let abortAfter = 50
        let skipHashingCaptured = scanOptions.skipChecksums
        let skipDirsCaptured = skipDirsSnapshot()
        let skipBundleExtsCaptured = skipBundleExtensionsSnapshot()
        let skipSmallFilesCaptured = scanOptions.skipSmallFiles

        await withTaskGroup(of: [VideoRecord].self) { rootGroup in
            for root in roots {
                rootGroup.addTask { [self] in
                    await scanOneRootParallel(
                        root: root,
                        ramMountPoint: ramMountPoint,
                        probesLimit: probesLimit,
                        abortAfter: abortAfter,
                        skipHashing: skipHashingCaptured,
                        skipDirs: skipDirsCaptured,
                        skipBundleExts: skipBundleExtsCaptured,
                        skipSmallFiles: skipSmallFilesCaptured
                    )
                }
            }
            for await rootRecords in rootGroup {
                allRecords.append(contentsOf: rootRecords)
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

        logParallelScanSummary(roots: roots, records: allRecords)
        dashboard.scanPhase = .complete
        isScanning = false
    }

    /// Per-root body invoked from `runParallelScan`'s outer task group.
    /// Streams directory entries and drains a probe group, aborting if too
    /// many consecutive files become inaccessible.
    private func scanOneRootParallel(
        root: String,
        ramMountPoint: String?,
        probesLimit: Int,
        abortAfter: Int,
        skipHashing: Bool,
        skipDirs: Set<String>,
        skipBundleExts: Set<String>,
        skipSmallFiles: Bool
    ) async -> [VideoRecord] {
        let volName = URL(fileURLWithPath: root).lastPathComponent
        let rootIsNetwork = isNetworkPath(root)
        let sem = AsyncSemaphore(limit: probesLimit)
        var rootRecords: [VideoRecord] = []
        var discoveredCount = 0
        var consecutiveNotAccessible = 0

        let stream = walkDirectoryStream(
            root: root,
            skipDirs: skipDirs,
            skipBundleExtensions: skipBundleExts,
            skipSmallFiles: skipSmallFiles
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
                let currentDiscovered = discoveredCount
                await MainActor.run {
                    let ds = self.dashboard
                    ds.scanTotal += 1
                    if let idx = ds.volumeProgress.firstIndex(where: { $0.rootPath == root }) {
                        ds.volumeProgress[idx].totalFiles = currentDiscovered
                    }
                }
                probeGroup.addTask {
                    await self.pauseGate.waitIfPaused()
                    return await sem.withPermit {
                        await self.probeAndRecord(
                            url: url,
                            volName: volName,
                            root: root,
                            rootIsNetwork: rootIsNetwork,
                            ramMountPoint: ramMountPoint,
                            skipHashing: skipHashing,
                            useTimeout: false,
                            echoFilename: true
                        )
                    }
                }
            }

            // Walker finished for this root.
            let totalFiles = discoveredCount
            await MainActor.run {
                self.log("  Found \(totalFiles) video files on \(volName)")
                if let idx = self.dashboard.volumeProgress.firstIndex(where: { $0.rootPath == root }) {
                    self.dashboard.volumeProgress[idx].isWalking = false
                }
            }

            for await rec in probeGroup {
                rootRecords.append(rec)
                let shouldAbort = Self.updateInaccessibleCounter(
                    rec: rec,
                    consecutive: &consecutiveNotAccessible,
                    abortAfter: abortAfter
                )
                if shouldAbort {
                    await MainActor.run {
                        self.log("  ⛔ \(abortAfter) consecutive files inaccessible on \(volName) — volume likely unmounted. Aborting remaining probes.")
                    }
                    probeGroup.cancelAll()
                    break
                }
            }
        }
        return rootRecords
    }

    /// Reset or increment the consecutive-not-accessible counter based on a
    /// probe result. Returns true if the caller should abort.
    nonisolated private static func updateInaccessibleCounter(
        rec: VideoRecord,
        consecutive: inout Int,
        abortAfter: Int
    ) -> Bool {
        if rec.streamTypeRaw == StreamType.ffprobeFailed.rawValue,
           rec.isPlayable == "File not found" {
            consecutive += 1
            return consecutive >= abortAfter
        }
        consecutive = 0
        return false
    }

    /// Final banner for `runParallelScan`.
    private func logParallelScanSummary(roots: [String], records: [VideoRecord]) {
        let va = records.filter { $0.streamTypeRaw == StreamType.videoAndAudio.rawValue }.count
        let vo = records.filter { $0.streamTypeRaw == StreamType.videoOnly.rawValue }.count
        let ao = records.filter { $0.streamTypeRaw == StreamType.audioOnly.rawValue }.count
        let ff = records.filter { $0.isPlayable.contains("ffprobe") }.count
        log("""

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Scan Complete
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Locations:      \(roots.count)
  Total:          \(records.count)
  Video+Audio:    \(va)
  Video only:     \(vo)
  Audio only:     \(ao)
  ffprobe failed: \(ff)
  Cache hits:     \(dashboard.scanCacheHits)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
""")
    }

    /// Walk a single directory tree and return all video file URLs. Caller
    /// (on main actor) passes pre-snapshotted skip sets so this method can
    /// stay nonisolated.
    nonisolated func walkDirectory(
        root: String,
        skipDirs: Set<String>,
        skipBundleExtensions: Set<String>,
        skipSmallFiles: Bool,
        onProgress: (@Sendable (_ currentDir: URL, _ filesFoundSoFar: Int, _ lastFile: URL?) -> Void)? = nil
    ) async -> [URL] {
        // Run on a detached task to avoid blocking the cooperative thread pool.
        // FileManager calls are synchronous and can stall on network volumes.
        let videoExtensions = self.videoExtensions
        let minFileBytes: Int = skipSmallFiles ? 1_048_576 : 0
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
                        includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isReadableKey, .fileSizeKey],
                        options: [.skipsHiddenFiles]
                    )
                } catch {
                    continue
                }

                for url in contents {
                    if Task.isCancelled { break }
                    guard let rv = try? url.resourceValues(
                        forKeys: [.isDirectoryKey, .isRegularFileKey, .isReadableKey, .fileSizeKey]
                    ) else { continue }

                    if rv.isDirectory == true {
                        let dirName = url.lastPathComponent.lowercased()
                        let dirExt = url.pathExtension.lowercased()
                        if !skipDirs.contains(dirName)
                            && !skipBundleExtensions.contains(dirExt) {
                            dirStack.append(url)
                        }
                    } else if rv.isRegularFile == true && rv.isReadable == true {
                        let ext = url.pathExtension.lowercased()
                        if videoExtensions.contains(ext) {
                            // .ts can collide with TypeScript — verify MPEG-TS sync byte.
                            // .mts is AVCHD-only (never TypeScript), so skip the check.
                            if ext == "ts" && !Self.isMpegTS(url) {
                                continue
                            }
                            if minFileBytes > 0, let sz = rv.fileSize, sz < minFileBytes {
                                continue
                            }
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
        let videoExtensions = self.videoExtensions
        // Capture at walk start so mid-scan toggles don't corrupt the walk.
        // 1 MB threshold — matches the skipSmallFiles heuristic.
        let minFileBytes: Int = skipSmallFiles ? 1_048_576 : 0
        return AsyncStream(URL.self, bufferingPolicy: .unbounded) { continuation in
            let walker = Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                var dirStack: [URL] = [URL(fileURLWithPath: root)]
                while !dirStack.isEmpty {
                    if Task.isCancelled { break }
                    let currentDir = dirStack.removeLast()
                    onDirectoryEntered?(currentDir)

                    let contents: [URL]
                    do {
                        contents = try fm.contentsOfDirectory(
                            at: currentDir,
                            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isReadableKey, .fileSizeKey],
                            options: [.skipsHiddenFiles]
                        )
                    } catch {
                        continue
                    }

                    for url in contents {
                        if Task.isCancelled { break }
                        guard let rv = try? url.resourceValues(
                            forKeys: [.isDirectoryKey, .isRegularFileKey, .isReadableKey, .fileSizeKey]
                        ) else { continue }

                        if rv.isDirectory == true {
                            let dirName = url.lastPathComponent.lowercased()
                            let dirExt = url.pathExtension.lowercased()
                            if !skipDirs.contains(dirName)
                                && !skipBundleExtensions.contains(dirExt) {
                                dirStack.append(url)
                            }
                        } else if rv.isRegularFile == true && rv.isReadable == true {
                            let ext = url.pathExtension.lowercased()
                            if videoExtensions.contains(ext) {
                                if ext == "ts" && !Self.isMpegTS(url) {
                                    continue
                                }
                                // skipSmallFiles filter — cheap reject of stubs/thumbnails.
                                // `.fileSizeKey` may be nil on SMB quirks; when missing, yield
                                // (err on the side of cataloging) rather than silently drop.
                                if minFileBytes > 0, let sz = rv.fileSize, sz < minFileBytes {
                                    continue
                                }
                                continuation.yield(url)
                            }
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                walker.cancel()
            }
        }
    }

    /// Check if a .ts file is actually an MPEG transport stream (not TypeScript).
    /// Standard MPEG-TS: sync byte 0x47 at offset 0 (188-byte packets).
    /// BDAV/AVCHD:        sync byte 0x47 at offset 4 (192-byte packets with timecode prefix).
    nonisolated private static func isMpegTS(_ url: URL) -> Bool {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var buf = [UInt8](repeating: 0, count: 5)
        let n = read(fd, &buf, 5)
        guard n >= 1 else { return false }
        return buf[0] == 0x47 || (n >= 5 && buf[4] == 0x47)
    }

    /// Per-file probe timeout (seconds). Prevents the scan from stalling on
    /// network files that block indefinitely on read/open. 300s to accommodate
    /// SMB mounts on sleepy external drives — a too-short timeout was flagging
    /// healthy network volumes as "stalled" when they just needed to spin up.
    private let probeTimeoutSeconds: UInt64 = 300

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
        guard fm.isReadableFile(atPath: path) else {
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
            r.size            = humanSize(fileSize)
            r.dateModifiedRaw = attrs?[.modificationDate] as? Date
            r.dateCreatedRaw  = attrs?[.creationDate] as? Date
            r.dateModified    = r.dateModifiedRaw.map { df.string(from: $0) } ?? ""
            r.dateCreated     = r.dateCreatedRaw.map { df.string(from: $0) } ?? ""

            // partialMD5 is the strong identity key for duplicate detection.
            // Skip reads ~64 KB per file, which is free on local SSD but costs
            // real seconds over SMB on thousands of files. skipHashing trades
            // dup detection for a faster pass — user can run "Analyze
            // Duplicates" later if they change their mind.
            r.partialMD5 = skipHashing ? "" : partialMD5(path: path)
            return r
        }

        // Prefetch file header to RAM disk for fast ffprobe
        let (probeURL, tempFile) = await prefetchIfNeeded(
            url: url,
            fileSize: fileSize,
            prefetchToRAM: prefetchToRAM,
            ramPath: ramPath
        )

        let probeResult = await runFFProbe(url: probeURL)
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
        guard prefetchHeader(from: url, to: tmpURL, bytes: prefetchBytes) else {
            return (url, nil)
        }
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

    // MARK: - Correlate helpers

    private struct CorrelateCandidate {
        let video: VideoRecord
        let audio: VideoRecord
        let score: Int
        let confidence: PairConfidence
        let reasons: [String]
    }

    /// Select records to re-correlate (all or the selected subset) and clear
    /// their prior pairing so they can be re-paired from scratch.
    private func resolveCorrelateScope(selectedIDs: Set<UUID>?) -> [VideoRecord] {
        let scope: [VideoRecord]
        if let ids = selectedIDs, !ids.isEmpty {
            scope = records.filter { ids.contains($0.id) }
        } else {
            scope = records
        }
        for r in scope {
            r.pairedWith = nil
            r.pairGroupID = nil
            r.pairConfidence = nil
        }
        return scope
    }

    /// Index audio records by filename-correlation key and directory for O(1) lookup.
    private func buildAudioPools(
        from audios: [VideoRecord]
    ) -> (byKey: [String: [VideoRecord]], byDir: [String: [VideoRecord]]) {
        var byKey: [String: [VideoRecord]] = [:]
        var byDir: [String: [VideoRecord]] = [:]
        for a in audios {
            byKey[filenameCorrelationKey(a.filename), default: []].append(a)
            byDir[a.directory, default: []].append(a)
        }
        return (byKey, byDir)
    }

    /// Build the candidate audio pool for a video: indexed lookups first, fall back
    /// to duration/timestamp scan across ALL audios only when the pool is thin.
    private func gatherCandidateAudios(
        for video: VideoRecord,
        vKey: String,
        allAudios: [VideoRecord],
        byKey: [String: [VideoRecord]],
        byDir: [String: [VideoRecord]]
    ) -> [VideoRecord] {
        var seen = Set<UUID>()
        var pool: [VideoRecord] = []
        for a in byKey[vKey] ?? [] where seen.insert(a.id).inserted { pool.append(a) }
        for a in byDir[video.directory] ?? [] where seen.insert(a.id).inserted { pool.append(a) }
        if pool.count >= 5 { return pool }
        for a in allAudios where !seen.contains(a.id) {
            let durationHit = video.durationSeconds > 0 && a.durationSeconds > 0 &&
                abs(video.durationSeconds - a.durationSeconds) <= durationTolerance
            let timestampHit: Bool
            if let vDate = video.dateCreatedRaw, let aDate = a.dateCreatedRaw {
                timestampHit = abs(vDate.timeIntervalSince(aDate)) <= timestampTolerance
            } else {
                timestampHit = false
            }
            if (durationHit || timestampHit) && seen.insert(a.id).inserted {
                pool.append(a)
            }
        }
        return pool
    }

    /// Score a single video/audio pair and return a Candidate if the minimum
    /// threshold is met. Same weighting as Correlator.swift (filename 4 / duration 3 /
    /// timestamp 3 / timecode 2 / directory 1 / tape 1).
    private func scoreCorrelatePair(
        video: VideoRecord,
        audio: VideoRecord,
        vKey: String
    ) -> CorrelateCandidate? {
        var score = 0
        var reasons: [String] = []

        if vKey == filenameCorrelationKey(audio.filename) { score += 4; reasons.append("filename") }
        if video.durationSeconds > 0 && audio.durationSeconds > 0 &&
           abs(video.durationSeconds - audio.durationSeconds) <= durationTolerance {
            score += 3; reasons.append("duration")
        }
        if let vDate = video.dateCreatedRaw, let aDate = audio.dateCreatedRaw,
           abs(vDate.timeIntervalSince(aDate)) <= timestampTolerance {
            score += 3; reasons.append("timestamp")
        }
        if !video.timecode.isEmpty && video.timecode == audio.timecode {
            score += 2; reasons.append("timecode")
        }
        if video.directory == audio.directory { score += 1; reasons.append("directory") }
        if !video.tapeName.isEmpty && video.tapeName == audio.tapeName {
            score += 1; reasons.append("tape")
        }
        guard score >= 3 else { return nil }

        let confidence: PairConfidence
        if score >= 7 { confidence = .high } else if score >= 4 { confidence = .medium } else { confidence = .low }
        return CorrelateCandidate(
            video: video, audio: audio,
            score: score, confidence: confidence, reasons: reasons
        )
    }

    /// Greedy max-score assignment: sort by score descending, claim each pair
    /// unless either side was already matched. Mutates records in place.
    private func assignCorrelateCandidates(
        _ candidates: [CorrelateCandidate],
        matched: inout Set<UUID>
    ) {
        for c in candidates.sorted(by: { $0.score > $1.score }) {
            guard !matched.contains(c.video.id), !matched.contains(c.audio.id) else { continue }
            let gid = UUID()
            c.video.pairedWith = c.audio
            c.video.pairGroupID = gid
            c.video.pairConfidence = c.confidence
            c.audio.pairedWith = c.video
            c.audio.pairGroupID = gid
            c.audio.pairConfidence = c.confidence
            matched.insert(c.video.id)
            matched.insert(c.audio.id)
            log("  Paired [\(c.confidence.rawValue)] (\(c.reasons.joined(separator: "+"))): \(c.video.filename)  ↔  \(c.audio.filename)")
        }
    }

    /// Emit the end-of-correlation summary (both status line and console log).
    private func logCorrelateSummary(needsPairing: [VideoRecord], matched: Set<UUID>) {
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
    }

    /// Correlate all records, or only those whose IDs are in `selectedIDs` (if non-nil/non-empty).
    func correlate(selectedIDs: Set<UUID>? = nil) {
        isCorrelating = true
        correlateStatus = ""
        defer { isCorrelating = false }

        let scope = resolveCorrelateScope(selectedIDs: selectedIDs)
        let needsPairing = scope.filter { $0.streamType.needsCorrelation }
        let allVideos = needsPairing.filter { $0.streamType == .videoOnly }
        let allAudios = needsPairing.filter { $0.streamType == .audioOnly }

        correlateStatus = "\(allVideos.count) video + \(allAudios.count) audio candidates"
        log("  Correlating \(allVideos.count) video-only + \(allAudios.count) audio-only files...")

        let pools = buildAudioPools(from: allAudios)
        var candidates: [CorrelateCandidate] = []
        for v in allVideos {
            let vKey = filenameCorrelationKey(v.filename)
            let audioPool = gatherCandidateAudios(
                for: v, vKey: vKey, allAudios: allAudios,
                byKey: pools.byKey, byDir: pools.byDir
            )
            for a in audioPool {
                if let candidate = scoreCorrelatePair(video: v, audio: a, vKey: vKey) {
                    candidates.append(candidate)
                }
            }
        }

        var matched = Set<UUID>()
        assignCorrelateCandidates(candidates, matched: &matched)
        logCorrelateSummary(needsPairing: needsPairing, matched: matched)

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

    /// Normalize filename by stripping V/A prefix (Avid MXF convention).
    /// Only strips when followed by hex digits (e.g., V01A23BC.mxf → _01A23BC.mxf)
    func filenameCorrelationKey(_ filename: String) -> String {
        var parts = filename.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        for i in parts.indices {
            let p = parts[i]
            if p.count > 1,
               let first = p.first,
               first == "V" || first == "A" || first == "v" || first == "a",
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

    func combineSelectedPairs(_ pairs: [(video: VideoRecord, audio: VideoRecord)], outputFolder: URL, maxConcurrency: Int? = nil) {
        guard !pairs.isEmpty else {
            log("No pairs selected to combine.")
            return
        }
        combineAllPairsInternal(pairs: pairs, outputFolder: outputFolder, maxConcurrency: maxConcurrency)
    }

    func combineAllPairs(outputFolder: URL, maxConcurrency: Int? = nil) {
        let pairs = correlatedPairs
        guard !pairs.isEmpty else {
            log("No correlated pairs to combine.")
            return
        }
        combineAllPairsInternal(pairs: pairs, outputFolder: outputFolder, maxConcurrency: maxConcurrency)
    }

    // MARK: - Combine helpers

    /// Mount the RAM disk for combine temp buffering. Returns the base URL to
    /// use (RAM disk if mounted, otherwise the system temp dir) and a flag.
    private func mountCombineRAMDisk() async -> (tempBase: URL, hasRAMDisk: Bool) {
        let combineDiskMB = perfSettings.ramDiskGB * 1024
        let hasRAMDisk = await ramDisk.mount(sizeMB: combineDiskMB)
        let ramMountPoint = await ramDisk.mountPoint
        if hasRAMDisk, let mp = ramMountPoint {
            log("  RAM disk mounted at \(mp) (\(perfSettings.ramDiskGB) GB)")
            return (URL(fileURLWithPath: mp), true)
        }
        return (FileManager.default.temporaryDirectory, false)
    }

    /// Buffer a single network-side file to the combine temp dir.
    /// Returns the local URL to pass to ffmpeg.
    private func bufferCombineSource(
        kind: String,
        from remotePath: String,
        to destination: URL,
        hasRAMDisk: Bool
    ) async throws -> URL {
        await MainActor.run {
            self.log("    Buffering \(kind) to \(hasRAMDisk ? "RAM disk" : "temp")...")
        }
        try await bufferedCopy(from: URL(fileURLWithPath: remotePath), to: destination)
        return destination
    }

    /// Copy network-backed inputs to `tempBase` and return the local paths to use.
    /// Creates (and marks for cleanup) a dedicated temp dir only when needed.
    private func stageCombineInputs(
        videoPath: String,
        videoFilename: String,
        audioPath: String,
        audioFilename: String,
        tempBase: URL,
        hasRAMDisk: Bool
    ) async throws -> (video: URL, audio: URL, tempDir: URL?) {
        let videoIsNetwork = isNetworkPath(videoPath)
        let audioIsNetwork = isNetworkPath(audioPath)
        guard videoIsNetwork || audioIsNetwork else {
            return (URL(fileURLWithPath: videoPath), URL(fileURLWithPath: audioPath), nil)
        }
        let tempDir = tempBase.appendingPathComponent("VS_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        var localVideo = URL(fileURLWithPath: videoPath)
        var localAudio = URL(fileURLWithPath: audioPath)
        if videoIsNetwork {
            localVideo = try await bufferCombineSource(
                kind: "video", from: videoPath,
                to: tempDir.appendingPathComponent(videoFilename),
                hasRAMDisk: hasRAMDisk
            )
        }
        if audioIsNetwork {
            localAudio = try await bufferCombineSource(
                kind: "audio", from: audioPath,
                to: tempDir.appendingPathComponent(audioFilename),
                hasRAMDisk: hasRAMDisk
            )
        }
        return (localVideo, localAudio, tempDir)
    }

    /// Process one video/audio pair end-to-end: skip-if-exists, pause-gate,
    /// stage inputs, mux, clean up. Returns true on success.
    private func processCombinePair(
        video: VideoRecord,
        audio: VideoRecord,
        outputFolder: URL,
        tempBase: URL,
        hasRAMDisk: Bool
    ) async -> Bool {
        if Task.isCancelled { return false }
        await combinePauseGate.waitIfPaused()
        if Task.isCancelled { return false }

        let videoPath = video.fullPath
        let audioPath = audio.fullPath
        let videoFilename = video.filename
        let audioFilename = audio.filename
        let baseName = URL(fileURLWithPath: videoPath).deletingPathExtension().lastPathComponent
        let outName = "\(baseName)_combined.mov"
        let outURL = outputFolder.appendingPathComponent(outName)

        // Skip if already completed (resume after pause)
        if FileManager.default.fileExists(atPath: outURL.path) {
            await MainActor.run {
                self.dashboard.combineCompleted += 1
                self.log("  [\(self.dashboard.combineCompleted)/\(self.dashboard.combineTotal)] \(outName) — already exists, skipping")
            }
            return true
        }

        await MainActor.run {
            self.dashboard.combineCurrentFile = outName
            self.log("  [\(self.dashboard.combineCompleted + 1)/\(self.dashboard.combineTotal)] \(outName)")
            self.log("    Video: \(videoPath)")
            self.log("    Audio: \(audioPath)")
        }

        let staged: (video: URL, audio: URL, tempDir: URL?)
        do {
            staged = try await stageCombineInputs(
                videoPath: videoPath, videoFilename: videoFilename,
                audioPath: audioPath, audioFilename: audioFilename,
                tempBase: tempBase, hasRAMDisk: hasRAMDisk
            )
        } catch {
            await MainActor.run {
                self.log("    ERROR buffering: \(error.localizedDescription)")
                self.dashboard.combineCompleted += 1
            }
            return false
        }

        let success = await runFFMpeg(
            videoPath: staged.video.path,
            audioPath: staged.audio.path,
            outputPath: outURL.path
        )

        if let tempDir = staged.tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        if !success {
            try? FileManager.default.removeItem(at: outURL)
        }

        await MainActor.run {
            self.dashboard.combineCompleted += 1
            if success {
                self.log("    ✓ Done: \(outURL.path)")
            } else {
                self.log("    ✗ FAILED: \(outName)")
            }
        }
        return success
    }

    /// Emit the Combine Complete banner and clear the combine UI state.
    @MainActor
    private func logCombineSummary() {
        self.log("""

        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
          Combine Complete
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
          Succeeded: \(dashboard.combineSucceeded)
          Failed:    \(dashboard.combineFailed)
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        """)
        isCombining = false
        dashboard.combineCurrentFile = ""
    }

    private func combineAllPairsInternal(pairs: [(video: VideoRecord, audio: VideoRecord)], outputFolder: URL, maxConcurrency: Int? = nil) {
        isCombining = true
        dashboard.resetForCombine(total: pairs.count)

        log("""

        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
          Combining \(pairs.count) pair\(pairs.count == 1 ? "" : "s") → \(outputFolder.path)
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        """)

        combineTask = Task {
            let (tempBase, hasRAMDisk) = await mountCombineRAMDisk()
            let semaphore = AsyncSemaphore(limit: maxConcurrency ?? self.perfSettings.combineConcurrency)

            await withTaskGroup(of: Bool.self) { group in
                for (video, audio) in pairs {
                    if Task.isCancelled { break }
                    group.addTask { [self] in
                        await semaphore.withPermit {
                            await self.processCombinePair(
                                video: video, audio: audio,
                                outputFolder: outputFolder,
                                tempBase: tempBase, hasRAMDisk: hasRAMDisk
                            )
                        }
                    }
                }

                for await ok in group {
                    await MainActor.run {
                        if ok { self.dashboard.combineSucceeded += 1 } else { self.dashboard.combineFailed += 1 }
                    }
                }

                await self.ramDisk.unmount()
                await self.logCombineSummary()
            }
        }
    }

    func pauseCombine() {
        isCombinePaused = true
        Task { await combinePauseGate.pause() }
        log("--- Combine paused ---")
    }

    func resumeCombine() {
        isCombinePaused = false
        Task { await combinePauseGate.resume() }
        log("--- Combine resumed ---")
    }

    func stopCombine() {
        combineTask?.cancel()
        combineTask = nil
        Task {
            await combinePauseGate.resume()  // release any waiters before cancel
            await ramDisk.unmount()
        }
        log("--- Combine stopped by user ---")
        isCombining = false
        isCombinePaused = false
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
        let logFn: @Sendable (String) -> Void = { [weak self] msg in
            DispatchQueue.main.async { self?.log(msg) }
        }
        let result = await CombineEngine.runFFMpeg(
            videoPath: videoPath,
            audioPath: audioPath,
            outputPath: outputPath,
            log: logFn
        )
        if !result.success {
            log("ffmpeg exit code \(result.exitCode)")
        }
        return result.success
    }

    // MARK: - ffprobe

    nonisolated func runFFProbe(url: URL) async -> (output: FFProbeOutput?, stderr: String) {
        let args = ["-v", "warning", "-probesize", "50M", "-analyzeduration", "10M",
                    "-print_format", "json", "-show_format", "-show_streams", url.path]
        let result = await ProcessRunner.runCapturingStderr(executable: ffprobePath, arguments: args)
        guard let json = result.stdout, let data = json.data(using: .utf8) else {
            return (nil, result.stderr)
        }
        let output = try? JSONDecoder().decode(FFProbeOutput.self, from: data)
        return (output, result.stderr)
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
                do { try proc.run() } catch { continuation.resume(returning: nil) }
            }
        } onCancel: {
            if proc.isRunning { proc.terminate() }
        }
    }

    // MARK: - Partial MD5

    nonisolated func partialMD5(path: String, chunkSize: Int = 65536) -> String {
        // Use read() instead of mmap() — mmap on network files can SIGBUS
        // (KERN_MEMORY_ERROR) if the remote volume becomes unreachable mid-read.
        // read() returns -1 on I/O errors instead of crashing.
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return "" }
        defer { close(fd) }

        var sb = stat()
        guard fstat(fd, &sb) == 0 else { return "" }
        let fileSize = Int(sb.st_size)
        guard fileSize > 0 else { return "" }

        var md5 = Insecure.MD5()
        let buf = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 16)
        defer { buf.deallocate() }

        // Hash first chunk
        let headLen = min(chunkSize, fileSize)
        let headRead = read(fd, buf, headLen)
        guard headRead > 0 else { return "" }
        md5.update(bufferPointer: UnsafeRawBufferPointer(start: buf, count: headRead))

        // Hash last chunk if file is large enough
        if fileSize > chunkSize * 2 {
            let tailOffset = off_t(fileSize - chunkSize)
            guard lseek(fd, tailOffset, SEEK_SET) == tailOffset else { return "" }
            let tailRead = read(fd, buf, chunkSize)
            guard tailRead > 0 else { return "" }
            md5.update(bufferPointer: UnsafeRawBufferPointer(start: buf, count: tailRead))
        }

        return md5.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - CSV

    func writeCSV(records: [VideoRecord], root: String) -> String? {
        let headers = [
            "Filename", "Extension", "Stream Type", "Size", "Size (Bytes)", "Duration",
            "Date Created", "Date Modified", "Container", "Video Codec", "Resolution",
            "Frame Rate", "Video Bitrate", "Total Bitrate", "Color Space", "Bit Depth",
            "Scan Type", "Audio Codec", "Audio Channels", "Audio Sample Rate", "Timecode",
            "Tape Name", "Is Playable", "Partial MD5", "Duplicate Group", "Duplicate Confidence",
            "Duplicate Disposition", "Duplicate Match", "Duplicate Reasons", "Full Path", "Directory", "Notes"
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
                        if let image { cont.resume(returning: image) } else { cont.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
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
        let units = ["B", "KB", "MB", "GB", "TB"]
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
