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
    /// §3 Relocate Job Queue — backing store for the per-volume queue.
    /// Each user "Run/Add to Queue" click appends one job; the queue is
    /// strictly serial (a parallel-to-the-user illusion). See
    /// `VideoScanModel+RelocateQueue.swift` and
    /// docs/relocate_volume_plan.md §3.
    @Published var relocateQueue: [RelocateQueuedJob] = []
    /// True while any queued job is in flight. Replaces the prior stored
    /// `isRelocating: Bool` — kept as a computed property so existing UI
    /// gating (`disabled(model.isRelocating)`, the in-flight progress
    /// sheet binding, RelocateSheet's `canRelocate`) keeps working
    /// unchanged. Drives `.reconciling`, `.copying`, and `.awaitingDone`
    /// — the user-facing definition of "something's happening."
    var isRelocating: Bool {
        relocateQueue.contains { $0.isInFlight }
    }

    /// Distinct from `isRelocating`: this is true ONLY while a job is in
    /// .reconciling or .copying — NOT during .awaitingDone. The progress
    /// sheet binds to this so it dismisses the moment the work finishes,
    /// freeing SwiftUI's single-sheet stack to render the post-flight
    /// summary sheet (which is bound to `pendingRelocateSummary`). Without
    /// this distinction the progress sheet stayed up while .awaitingDone
    /// held isRelocating true, blocking the summary from ever appearing —
    /// the "stuck at preparing" bug observed 2026-05-31.
    var isRelocateActivelyWorking: Bool {
        relocateQueue.contains { job in
            switch job.status {
            case .reconciling, .copying: return true
            default: return false
            }
        }
    }
    /// §1B Retire Volume — set by `runRelocate` when the just-completed
    /// run leaves 100% of the source volume's catalogued records marked
    /// `.manuallyDeleted`. The UI binds a sheet to this; selecting Retire
    /// or Skip clears it. nil ⇒ no pending offer. Carries the source
    /// volume root path so the sheet doesn't have to recompute.
    @Published var pendingRetireOffer: PendingRetireOffer?
    /// Post-Apply summary sheet payload. Set unconditionally at the end of
    /// `runRelocate` (both real runs AND dry runs). The UI binds a
    /// `.sheet(item:)` to this. The sheet's Done button is the ONLY trigger
    /// that fires `maybeOfferRetire` — Rick has to see the verification
    /// summary before the Retire prompt can appear. See
    /// docs/relocate_volume_plan.md (§1A summary-sheet note).
    @Published var pendingRelocateSummary: RelocateSummary?
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

    /// Revision counter for in-place mutations of `records` that don't
    /// change the array count — currently the Bucket-D adoption path
    /// rewrites `fullPath` on existing records without adding/removing
    /// entries. Bumping this flips the published value and lets
    /// ContentView's per-volume aggregate cache invalidate. Pure count
    /// triggers aren't enough because a Bucket-D move shifts records
    /// from one volume's bucket to another without changing total
    /// count.
    @Published var volumeAggregatesRevision: Int = 0

    /// Bump the per-volume aggregate cache so ContentView rebuilds its
    /// `[UUID: VolumeAggregate]` map. Call after any bulk in-place
    /// mutation of `records` that doesn't change overall count.
    func notifyVolumeAggregatesStale() {
        volumeAggregatesRevision &+= 1
    }

    // MARK: - Backup status (Export Everything tracking)
    //
    // The "Export Everything…" menu writes a .videoscanbundle that's the
    // canonical disaster-recovery snapshot — catalog records, scan-target
    // metadata, POI profiles + photos, manifest with SHA-256s. Persisting
    // when/where the user last exported makes the badge in the catalog
    // header honest about recency, so Rick can see at a glance whether
    // today's Migrate work is safely captured off the Mac Studio.
    //
    // Persisted via UserDefaults so the badge survives app restarts.

    /// Date of the most recent successful Export Everything, or nil if
    /// the catalog has never been bundle-exported on this machine.
    @Published var lastBackupAt: Date? = {
        let t = UserDefaults.standard.double(forKey: "VideoScan.lastBackupAt")
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }()

    /// Filesystem path of the most recent successful Export Everything
    /// destination. Used to render "→ iCloud Drive" or similar in the
    /// badge and to power click-to-reveal in Finder.
    @Published var lastBackupPath: String? = UserDefaults.standard.string(forKey: "VideoScan.lastBackupPath")

    /// Call from `exportBundleViaPanel` after a successful bundle write.
    /// Updates both the published values (drives the badge) and the
    /// UserDefaults entries (survives restart).
    func recordBackupSuccess(at url: URL) {
        let now = Date()
        UserDefaults.standard.set(now.timeIntervalSince1970,
                                  forKey: "VideoScan.lastBackupAt")
        UserDefaults.standard.set(url.path,
                                  forKey: "VideoScan.lastBackupPath")
        lastBackupAt = now
        lastBackupPath = url.path
    }

    /// High-frequency dashboard + console state — separate ObservableObject
    /// so updates don't trigger re-render of the main Table view.
    let dashboard = DashboardState()

    /// In-memory search accelerator. Built after catalog load, updated
    /// on dossier live-reload merges, cleared on full reset. Toolbar
    /// hit-count badge and the catalog table both filter through it
    /// instead of running raw `pfRecordsMatchingQuery` over `records`.
    /// See CatalogSearchIndex.swift for the design + invariants.
    /// Rick 2026-06-09: per-keystroke lowercase + concat of 50 MB of
    /// dossier text was the bottleneck behind sluggish typing.
    let searchIndex = CatalogSearchIndex()

    /// Thumbnail cache — keyed by fullPath, avoids regenerating from video file on re-click.
    /// Internal so VideoScanModel+Thumbnail.generateThumbnail can read/write it.
    /// Byte-cost-limited (8 GB — see ThumbnailCachePolicy) so the volume-click
    /// prewarm can fill it aggressively without unbounded growth; NSCache also
    /// evicts under system memory pressure, and the .memoryPressureAutoPause
    /// observer in init clears it outright when scans hit the RAM floor.
    let thumbnailCache: NSCache<NSString, NSImage> = VideoScanModel.makeThumbnailCache()

    /// Pending debounced thumbnail generation (see requestThumbnailDebounced
    /// in VideoScanModel+Thumbnail). Cancelled and replaced on every
    /// selection step; only the row the user rests on pays for generation.
    var thumbnailDebounceTask: Task<Void, Never>?

    /// fullPath of the most recent preview request. Guards against a slow,
    /// stale generation completing AFTER a newer selection and clobbering
    /// its preview. Set by requestThumbnailDebounced/generateThumbnail.
    var previewRequestPath: String?

    /// Volume-click thumbnail prewarmer (Part 3 of the 2026-06-10 perf
    /// batch). Owned here so the catalog view and scan lifecycle share one
    /// instance — a new volume selection or a scan start cancels the run.
    let thumbnailPrecacher = ThumbnailPrecacher()

    /// O(1) id → record lookup over `records`. Lazily rebuilt when the
    /// array's count changes; see RecordIDIndex (CatalogPerfMemo.swift)
    /// for the staleness contract. Private — go through record(forID:).
    private let recordIndex = RecordIDIndex()

    /// Fast selected-record resolution for views. Replaces the
    /// `records.first(where: { $0.id == id })` linear scans that ran
    /// several times per arrow-key step.
    func record(forID id: UUID) -> VideoRecord? {
        recordIndex.record(forID: id, in: records)
    }

    /// Drop any cached thumbnail under `path`. Called from the rename path
    /// (VideoScanModel+Rename) so a renamed record doesn't leak a stale
    /// entry under its old `fullPath` key. Internal to the model so the
    /// NSCache itself stays private.
    func invalidateThumbnailCacheEntry(forPath path: String) {
        thumbnailCache.removeObject(forKey: path as NSString)
    }

    /// Resolved ffprobe path. `var` (not `let`) purely as a test seam so the
    /// probe-timeout regression tests can inject a fake stuck ffprobe;
    /// production code never reassigns it. nonisolated(unsafe) because
    /// nonisolated probe code reads it and writes only happen before probing
    /// starts (tests).
    nonisolated(unsafe) var ffprobePath = ToolLocator.ffprobePath

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
    /// `var` as a test seam (regression tests inject a short timeout so the
    /// stuck-ffprobe repro runs in seconds, not 300s); production never
    /// reassigns it. nonisolated(unsafe) for the same reason as ffprobePath.
    nonisolated(unsafe) var probeTimeoutSeconds: UInt64 = 300

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
    // §1B Retire Volume — three parallel dictionaries keyed by searchPath.
    // Presence of an entry in savedRetiredAtKey is the retired-or-not signal;
    // reason + witnesses are aggregate data captured at retire time.
    static let savedRetiredAtKey = "VideoScan.scanTargetRetiredAt"
    static let savedRetiredReasonKey = "VideoScan.scanTargetRetiredReason"
    static let savedRetiredWitnessesKey = "VideoScan.scanTargetRetiredWitnesses"

    // `internal var` (not `private let`) so tests can swap in a per-test
    // CatalogStore(directory:) instance — necessary because the shared
    // CatalogStore short-circuits saves under XCTest to avoid polluting
    // Application Support. Production code never reassigns this.
    var catalogStore: CatalogStore = .shared

    /// Live-reload polling task — set by `startLiveDossierReload()` in
    /// VideoScanModel+LiveReload.swift, cancelled by
    /// `stopLiveDossierReload()`. nil when the live reload is not
    /// active (e.g. tests, viewer mode).
    var liveReloadTask: Task<Void, Never>?

    /// Mtime watermark for the live-reload polling loop. Set to the
    /// catalog file's mtime at launch (so the first tick doesn't
    /// re-merge what we just loaded) and on every successful merge.
    var lastLiveReloadMtime: Date?

    /// Per-volume snapshot of dossier + user-edit fields, captured by
    /// `snapshotPreservedFieldsForRescan` before the scan's removeAll
    /// destroys them, applied by `applyPreservedFieldsAfterRescan`
    /// when the new scan results are about to land. Keyed by the
    /// target's searchPath so concurrent rescans don't collide.
    /// See VideoScanModel+RescanPreservation.swift for the contract.
    var pendingPreservedFields: [String: [String: RescanPreservedFields]] = [:]

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
        // Listen for catalog-mutation pings from InspectorFamilyTagsView
        // (and any other downstream view that mutates a VideoRecord's
        // class-typed fields, which can't fire @Published didSet on
        // the records array). Triggers the debounced save path.
        NotificationCenter.default.addObserver(
            forName: .videoScanCatalogMutated,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.saveCatalogDebounced()
            self?.objectWillChange.send()
        }
        // When scans hit the RAM floor (MemoryPressureMonitor auto-pause),
        // drop the thumbnail cache wholesale — it's pure derived data and
        // the cheapest several GB we can hand back. NSCache would shed
        // entries on its own eventually; this makes it immediate. Also
        // stop any in-flight prewarm so it doesn't refill what we just
        // freed.
        NotificationCenter.default.addObserver(
            forName: .memoryPressureAutoPause,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.thumbnailCache.removeAllObjects()
            self?.thumbnailPrecacher.cancel(reason: "memory pressure")
        }
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
            // Phase 0 (Rick 2026-06-15): backfill dossier propagation
            // across MD5-identical duplicate records. Different scans of
            // the same physical file (Whisper non-determinism) produce
            // divergent transcripts; this harmonizes them by picking the
            // longest/best result per MD5 group and applying to all
            // members. Idempotent — re-running on an already-harmonized
            // catalog is a no-op (0 records mutated, no save).
            backfillDossierAcrossDuplicates()
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
        // Build the per-record haystack cache once the catalog is fully
        // assembled (restored + backfilled). All subsequent search
        // operations route through this index — see searchIndex above.
        searchIndex.rebuild(records: records)
        // Seed the memoized probe-cache count so the toolbar's first
        // render doesn't show 0 for 10 seconds.
        refreshCacheCountSoon()
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
        searchIndex.clear()
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
        // We just paid for the authoritative COUNT(*) — seed the memo
        // directly instead of scheduling a refresh.
        cacheCountMemo = (value: after, fetchedAt: Date())
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
            // Memoized count is now wrong — adjust in place (exact: we
            // know how many rows were dropped) and let the TTL refresh
            // reconcile any drift.
            if let memo = cacheCountMemo {
                cacheCountMemo = (value: max(0, memo.value - dropped), fetchedAt: memo.fetchedAt)
            }
        }
    }

    func resetTarget(_ target: CatalogScanTarget) {
        target.reset()
        clearCacheForTarget(target)
        // Also drop in-memory records that came from this target so the table reflects the reset
        records.removeAll { $0.fullPath.hasPrefix(target.searchPath) }
    }

    // MARK: - Probe-cache count (memoized)
    //
    // `metadataCache.count` is a synchronous SQLite COUNT(*) under the
    // cache's shared NSLock. The toolbar read it PER RENDER — every
    // arrow-key step paid a lock acquisition that probe writers also
    // contend on (audit 2026-06-10). Now the value is memoized with a
    // coarse TTL; the refresh runs off the main thread and only nudges
    // the UI when the number actually changed.

    /// (value, fetchedAt) memo. Internal-by-fileprivate contract: only
    /// cacheCount / refreshCacheCountSoon / clearCache paths touch it.
    var cacheCountMemo: (value: Int, fetchedAt: Date)?
    private var cacheCountRefreshInFlight = false
    private let cacheCountTTL: TimeInterval = 10

    /// Memoized probe-cache row count. Reading a stale value schedules a
    /// background refresh (stale-while-revalidate, same idea as
    /// SWRProbeCache) — the getter itself never touches SQLite.
    var cacheCount: Int {
        if let memo = cacheCountMemo,
           Date().timeIntervalSince(memo.fetchedAt) < cacheCountTTL {
            return memo.value
        }
        refreshCacheCountSoon()
        return cacheCountMemo?.value ?? 0
    }

    /// Schedule an off-main-thread COUNT(*) refresh; coalesced so render
    /// storms can't stack queries. Safe to call from a view body — it only
    /// mutates non-@Published bookkeeping synchronously.
    func refreshCacheCountSoon() {
        guard !cacheCountRefreshInFlight else { return }
        cacheCountRefreshInFlight = true
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let fresh = self.metadataCache.count   // nonisolated, lock inside
            await MainActor.run {
                let changed = self.cacheCountMemo?.value != fresh
                self.cacheCountMemo = (value: fresh, fetchedAt: Date())
                self.cacheCountRefreshInFlight = false
                // Only poke SwiftUI when the displayed number moved.
                if changed { self.objectWillChange.send() }
            }
        }
    }
}
