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
    // Internal so VideoScanModel+ProbeEngine.probeFile can read/write the
    // SQLite cache; spine helpers (clearCache, cacheCount) also use it.
    nonisolated let metadataCache = MetadataCache()

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

    /// How many bytes to prefetch from network files to RAM disk for ffprobe.
    /// Set from perfSettings at scan start so nonisolated code can read it.
    /// Internal (not private) so VideoScanModel+ProbeEngine can reference it
    /// — extensions can't add stored properties so it has to live here.
    nonisolated(unsafe) var prefetchBytes: Int = 50 * 1024 * 1024

    /// Per-file probe timeout (seconds). Prevents the scan from stalling on
    /// network files that block indefinitely on read/open. 300s to accommodate
    /// SMB mounts on sleepy external drives — a too-short timeout was flagging
    /// healthy network volumes as "stalled" when they just needed to spin up.
    /// Internal so VideoScanModel+ProbeEngine can race against it.
    let probeTimeoutSeconds: UInt64 = 300

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
