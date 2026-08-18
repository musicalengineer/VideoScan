import Foundation
import SwiftUI
import Combine
import Darwin
import AVFoundation
import SQLite3

// MARK: - Model

@MainActor
final class VideoScanModel: ObservableObject {
    @Published var records: [VideoRecord] = [] {
        // Keeps the O(1) chrome counters honest — see `dossierCounts`.
        // Covers every array-level mutation (scan commit, import, delete,
        // purge, live-reload append). In-place field writes that don't
        // touch the array (dossier writeback, provenance stamping) call
        // noteCatalogChangedForDossierCounts() at their own sites.
        didSet {
            noteCatalogChangedForDossierCounts()
            noteVolumeStatusesStale()
            noteVolumeRenameCandidatesStale()
            // Path-index staleness (ride-along 2026-07-14): fullPaths
            // PERSIST across rescans, so a same-count array swap would
            // stale-HIT the path map and hand back an orphaned record
            // — a dossier writeback to it would be silently lost. O(1)
            // un-latch; cheap enough for per-file live-reload appends.
            recordIndex.invalidate()
            recordPathIndex.invalidate()
            // Background preview sweep (2026-07-27): re-diff against the
            // disk cache once records settle. Debounced inside the
            // service; no-op while the checkbox is off.
            previewSweep.noteCatalogChanged()
        }
    }
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
    /// Handle to the currently-running relocate runner Task, retained so
    /// the user can cancel an in-flight job. Cancellation is cooperative:
    /// `runRelocate`'s copy loop checks `Task.isCancelled` between files
    /// (see `cancelActiveRelocate()`). Not `@Published` — it's an internal
    /// control handle, not view state.
    var relocateRunnerTask: Task<Void, Never>?
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
    /// Live (done, total) of the reconcile classify loop — nil when no
    /// reconcile is running. One channel serves both the Jobs panel and
    /// the progress sheet because the relocate queue is strictly serial.
    /// (2026-07-06: the reconcile used to run minutes with an
    /// indeterminate bar and a silent log — "2 weeks or 20 minutes".)
    @Published var reconcileProgress: (done: Int, total: Int)?
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
    /// True when preview generation FAILED (or negative-cache hit) for the
    /// CURRENT selection. CatalogContent renders a "NO PREVIEW" placeholder
    /// instead of an eternal spinner (preview routing, 2026-07-26). Reset
    /// by clearPreview and on every new selection request.
    @Published var previewUnavailable: Bool = false

    /// Filmstrip mode for AVPlayer-unplayable formats (filmstrip preview,
    /// 2026-07-27): what the preview pane's filmstrip branch renders.
    /// Carries its record's fullPath so a stale publish can never show
    /// another row's frames. Driven by requestFilmstrip / stopFilmstrip /
    /// resetFilmstrip in VideoScanModel+Filmstrip.swift.
    @Published var filmstripState: PreviewFilmstripState = .idle

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
        // Role/trust/retire edits change the safe-witness resolution, so
        // the cached retire statuses are stale too.
        noteVolumeStatusesStale()
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
        // In-place fullPath/archiveStage rewrites (Bucket-D adoption,
        // Relocate disposal) shift records between volumes without an
        // array-level mutation — the retire-status cache must follow.
        noteVolumeStatusesStale()
    }

    // MARK: - Cached chrome counts (2026-07-02 feedback-storm fix)
    //
    // Always-visible toolbar chrome (DossierToolbarChip) used to reduce
    // over the whole `records` array INSIDE view body per invalidation.
    // At 90k records × per-file dashboard invalidations during a scan,
    // that recount was one leg of the three-leg feedback storm that
    // stretched the RicksBackups sweep to 14.5h. Rule: NO O(records)
    // work in view bodies — chrome reads this cached value; the model
    // recomputes it (debounced, 250 ms) on catalog mutation. Pinned by
    // DossierCountsCacheTests.

    struct DossierCounts: Equatable {
        var dossiered: Int = 0
        var total: Int = 0
    }

    /// O(1) dossier progress for chrome views. Never compute this from
    /// `records` inside a view body.
    @Published private(set) var dossierCounts = DossierCounts()
    /// Test hook: proves reads never recompute (N reads between
    /// mutations = 1 computation).
    private(set) var dossierCountsRecomputeCount = 0
    private var dossierCountsRefreshScheduled = false

    /// Debounced invalidation — cheap enough to call from per-record
    /// loops. Coalesces any burst of catalog mutations into ONE
    /// recompute 250 ms later.
    func noteCatalogChangedForDossierCounts() {
        guard !dossierCountsRefreshScheduled else { return }
        dossierCountsRefreshScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            self?.dossierCountsRefreshScheduled = false
            self?.refreshDossierCountsNow()
        }
    }

    /// O(1) "any A/V pairs exist" flag for toolbar chrome (Show Pairs
    /// Only toggle). Body evals used to build the FULL correlatedPairs
    /// array just to ask isEmpty (2026-07-05 beachball arc).
    @Published private(set) var hasAnyPairs = false

    /// Cached "Delete duplicates on volume X" menu payload. Was computed
    /// in ContentView's body — two full-catalog passes with per-record
    /// volumeRoot() string work, per body evaluation (2026-07-05 arc).
    @Published private(set) var deletableDupVolumes: [(path: String, count: Int)] = []

    /// Immediate recompute — the ONLY place the O(records) count runs.
    /// Piggybacked (2026-07-05): the pair flag and the deletable-dups
    /// menu payload ride the same debounced catalog-change pass, so
    /// chrome reads stay O(1) with no extra invalidation machinery.
    func refreshDossierCountsNow() {
        dossierCountsRecomputeCount += 1
        var dossiered = 0
        var anyPairs = false
        for record in records {
            if record.dossierProcessedAt != nil { dossiered += 1 }
            if record.pairedWith != nil { anyPairs = true }
        }
        let fresh = DossierCounts(dossiered: dossiered, total: records.count)
        if fresh != dossierCounts {
            dossierCounts = fresh
        }
        if anyPairs != hasAnyPairs {
            hasAnyPairs = anyPairs
        }
        // QA P2-2: diff before publishing — tuples aren't Equatable, so
        // compare element-wise rather than invalidating dependents on
        // every debounced tick.
        let freshDeletable = volumesWithDeletableDuplicates()
        let changed = freshDeletable.count != deletableDupVolumes.count
            || !zip(freshDeletable, deletableDupVolumes).allSatisfy {
                $0.path == $1.path && $0.count == $1.count
            }
        if changed {
            deletableDupVolumes = freshDeletable
        }
    }

    // MARK: - Cached per-volume retire statuses (2026-07-05 beachball fix)
    //
    // VolumesWindow used to compute retire readiness INSIDE its body: four
    // full-catalog sweeps per volume row per body evaluation (~8M
    // PathScope comparisons per keystroke in the notes field — 91% of a
    // 20 s main-thread sample). Same rule as dossierCounts above: NO
    // O(records) work in view bodies. Rows read this cache; the model
    // rebuilds it off the main thread (debounced 300 ms) whenever the
    // catalog or the scan targets change. Pinned by VolumeStatusCacheTests.

    /// O(1) per-volume retire readiness for the Volumes window, keyed by
    /// the target's `searchPath`. Never compute retire status from
    /// `records` inside a view body — read this.
    @Published private(set) var volumeStatusCache: [String: VolumeRetireStatus] = [:]
    /// Test hook: proves reads never recompute (mirrors
    /// `dossierCountsRecomputeCount`).
    private(set) var volumeStatusRecomputeCount = 0
    /// Debounce flag for `noteVolumeStatusesStale()`.
    var volumeStatusRefreshScheduled = false
    /// Generation stamp: a rebuild that finishes after a NEWER
    /// invalidation must not publish its stale result.
    var volumeStatusGeneration: UInt64 = 0

    /// Cache lookup for a volume row. Missing entry (cache still warming
    /// up) returns `.empty` — fail-safe: `canRetire` is false, so a cold
    /// cache can never enable a destructive action it shouldn't.
    func volumeStatus(for searchPath: String) -> VolumeRetireStatus {
        volumeStatusCache[PathScope.normalize(searchPath)] ?? .empty
    }

    /// Bookkeeping for the test hook — called by the rebuild in
    /// VideoScanModel+VolumeStatusCache.swift when it actually recomputes.
    func countVolumeStatusRecompute() {
        volumeStatusRecomputeCount += 1
    }

    /// Publish a freshly-computed status dictionary. Same-file setter for
    /// the `private(set)` cache — ONLY the rebuild in
    /// VideoScanModel+VolumeStatusCache.swift may call this.
    func publishVolumeStatuses(_ fresh: [String: VolumeRetireStatus]) {
        if fresh != volumeStatusCache {
            volumeStatusCache = fresh
        }
    }

    // MARK: - Cached volume-rename candidates (feature/volume-rename-migration)
    //
    // "Crucial2TB was renamed to CrucialX9" detection — an offline scan
    // target whose records' consensus volumeUUID matches a currently
    // mounted volume at a different path. Same shape as volumeStatusCache
    // above: NO O(records) work in view bodies; rows read the dictionary
    // (O(1)), the model rebuilds it off-main (debounced 500 ms) when the
    // catalog changes or volumes mount/unmount. Detection, migration, and
    // the value types live in VideoScanModel+VolumeRenameMigration.swift;
    // the stored properties are here because extensions can't add them.

    /// O(1) per-target rename candidates for the scan-targets table badge,
    /// keyed by the target's NORMALIZED searchPath. Never compute rename
    /// detection from `records` inside a view body — read this.
    @Published private(set) var volumeRenameCache: [String: VolumeRenameCandidate] = [:]
    /// Test hook: proves reads never recompute (mirrors
    /// `volumeStatusRecomputeCount`).
    private(set) var volumeRenameRecomputeCount = 0
    /// Debounce flag for `noteVolumeRenameCandidatesStale()`.
    var volumeRenameRefreshScheduled = false
    /// Generation stamp: a rebuild that finishes after a NEWER invalidation
    /// must not publish its stale result.
    var volumeRenameGeneration: UInt64 = 0
    /// Normalized old searchPath of the migration currently running, or
    /// nil. Serializes migrations (one at a time — they rewrite `records`
    /// in place).
    @Published var volumeRenameMigrationInFlight: String?
    /// Scan-target id of the migration currently running — drives the
    /// row-level SpinningRing (the row's path flips old→new mid-flight,
    /// so the path-keyed cache can't anchor the indicator; the id can).
    @Published var volumeRenameMigrationInFlightTargetID: UUID?
    /// Auto/ask dialog payload (informational after an auto-migration,
    /// question for the ask tier, refusal for a failed manual check).
    /// The UI binds an alert to this; the model's accept/dismiss/undo
    /// handlers clear it.
    @Published var pendingVolumeRenameNotice: VolumeRenameNotice?
    /// Normalized old paths the AUTO pass must leave alone this session:
    /// set after Undo and after "Not Now" so the dialog never nags. The
    /// row badge stays as the manual affordance.
    var volumeRenameAutoSuppressed: Set<String> = []
    /// Kill switch for the auto-migrate/ask pass that runs after each
    /// detection rebuild. Always true in production; detection-only tests
    /// flip it off to observe candidates without side effects.
    var volumeRenameAutoPassEnabled = true
    /// Test seam (VolumeRenameMigrationTests): replaces the real
    /// mounted-volume UUID probe so detection/migration can be exercised
    /// against synthetic volumes. Always nil in production.
    var mountedVolumeInfoProviderForTesting: (@Sendable () -> [MountedVolumeInfo])?
    /// Test seam: replaces the on-disk file-size stat used by the Signal-B
    /// spot-check (returns size in bytes, nil = missing). Always nil in
    /// production.
    var volumeRenameStatProviderForTesting: (@Sendable (String) -> Int64?)?

    /// Cache lookup for a scan-target row. Missing entry (no rename
    /// detected, or cache still warming) returns nil — fail-safe: no
    /// badge, no migration offered.
    func volumeRenameCandidate(for searchPath: String) -> VolumeRenameCandidate? {
        volumeRenameCache[PathScope.normalize(searchPath)]
    }

    /// Bookkeeping for the test hook — called by the rebuild in
    /// VideoScanModel+VolumeRenameMigration.swift when it actually recomputes.
    func countVolumeRenameRecompute() {
        volumeRenameRecomputeCount += 1
    }

    /// Publish a freshly-computed candidate dictionary. Same-file setter
    /// for the `private(set)` cache — ONLY the rebuild/migrate code in
    /// VideoScanModel+VolumeRenameMigration.swift may call this.
    func publishVolumeRenameCandidates(_ fresh: [String: VolumeRenameCandidate]) {
        if fresh != volumeRenameCache {
            volumeRenameCache = fresh
        }
    }

    // MARK: - Backup status (Back Up Catalog tracking)
    //
    // "Back Up Catalog…" (File menu ⌘E and the catalog-header badge —
    // one code path, exportBundleViaPanel) writes a .videoscanbundle
    // that's the canonical disaster-recovery snapshot — catalog records,
    // scan-target metadata, POI profiles + photos, manifest with
    // SHA-256s. Persisting when/where the user last backed up makes the
    // badge in the catalog header honest about recency, so Rick can see
    // at a glance whether today's Migrate work is safely captured off
    // the Mac Studio.
    //
    // Persisted via UserDefaults so the badge survives app restarts.

    /// Date of the most recent successful catalog backup, or nil if
    /// the catalog has never been bundle-exported on this machine.
    @Published var lastBackupAt: Date? = {
        let t = UserDefaults.standard.double(forKey: "VideoScan.lastBackupAt")
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }()

    /// Filesystem path of the most recent successful backup destination.
    /// Used to render "→ iCloud Drive" or similar in the badge, to power
    /// the badge's reveal-in-Finder context menu, and to pre-aim the
    /// save panel at the same folder next time.
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

    /// Negative cache for preview generation (preview routing, 2026-07-26):
    /// files that failed to yield a frame, keyed by fullPath with their
    /// (mtime, size) at failure time — consulted by generateThumbnail and
    /// the precacher BEFORE attempting, so a known-bad file costs one stat
    /// instead of a deadline-bounded decode failure every selection. A
    /// repaired/replaced file (signature mismatch) retries automatically.
    /// Capped at 10k entries (~2–3 MB worst case) — see ThumbnailFailureStore.
    let thumbnailFailureStore = ThumbnailFailureStore()

    /// Persistent on-disk preview cache — L2 behind `thumbnailCache`
    /// (Phase B piece 1, 2026-07-26). Keyed on (path, mtime, size) so a
    /// changed file misses automatically; 2 GB cap pruned at background
    /// QoS on launch. Lookup order everywhere: L1 NSCache → this →
    /// generate, write-through to both. See PreviewDiskCache.swift.
    /// (The production root self-redirects to a temp sandbox under a
    /// unit-test host — same gate as MetadataCache.defaultPath.)
    let previewDiskCache = PreviewDiskCache(rootURL: PreviewDiskCache.productionRootURL)

    /// Pending debounced thumbnail generation (see requestThumbnailDebounced
    /// in VideoScanModel+Thumbnail). Cancelled and replaced on every
    /// selection step; only the row the user rests on pays for generation.
    var thumbnailDebounceTask: Task<Void, Never>?

    /// fullPath of the most recent preview request. Guards against a slow,
    /// stale generation completing AFTER a newer selection and clobbering
    /// its preview. Set by requestThumbnailDebounced/generateThumbnail.
    var previewRequestPath: String?

    // MARK: Filmstrip bookkeeping (filmstrip preview, 2026-07-27)
    // Stored here because extensions can't add stored properties; all
    // logic lives in VideoScanModel+Filmstrip.swift. Main-actor only
    // (the model is @MainActor) — no locks needed. For Rick: these five
    // are the members a C++ class would guard with "only touch on the
    // UI thread" comments; @MainActor makes the compiler enforce it.

    /// The single in-flight filmstrip generation (interactive OR
    /// prewarm) — at most ONE per model instance by design, so an
    /// interactive play click and a background prewarm can never rip
    /// the same 20 GB master twice concurrently.
    var filmstripTask: Task<Void, Never>?
    /// fullPath the in-flight task is generating for (coalescing key).
    var filmstripTaskPath: String?
    /// True when the in-flight task's result should publish to the UI.
    /// A prewarm flips to true ("promoted") if the user clicks play on
    /// the same row mid-generation.
    var filmstripTaskIsInteractive = false
    /// Latest (done, total) the in-flight task reported — lets a
    /// promoted prewarm publish honest progress immediately.
    var filmstripLatestProgress: (done: Int, total: Int) = (0, 0)
    /// Identifies the latest filmstrip task so a superseded run's
    /// completion can't clear a newer run's bookkeeping (same pattern
    /// as ThumbnailPrecacher.currentRunID).
    var filmstripRunID = UUID()
    /// Paths whose filmstrip generation genuinely failed this session —
    /// keeps the prewarm from re-ripping hopeless files on every
    /// selection. Deliberately NOT ThumbnailFailureStore: the fast
    /// thumbnail SUCCEEDED for these files, and poisoning the shared
    /// negative cache would blank their previews entirely. Capped at
    /// 10k inserts (~2 MB worst case) per the memory discipline rule.
    var filmstripFailedPaths: Set<String> = []

    /// Volume-click thumbnail prewarmer (Part 3 of the 2026-06-10 perf
    /// batch). Owned here so the catalog view and scan lifecycle share one
    /// instance — a new volume selection or a scan start cancels the run.
    let thumbnailPrecacher = ThumbnailPrecacher()

    /// O(1) id → record lookup over `records`. Lazily rebuilt when the
    /// array changes; see RecordIDIndex (CatalogPerfMemo.swift) for the
    /// staleness contract. Private — go through record(forID:).
    private let recordIndex = RecordIDIndex()

    /// Fast selected-record resolution for views. Replaces the
    /// `records.first(where: { $0.id == id })` linear scans that ran
    /// several times per arrow-key step.
    func record(forID id: UUID) -> VideoRecord? {
        recordIndex.record(forID: id, in: records)
    }

    /// O(1) fullPath → record lookup (perf ride-along 2026-07-14); see
    /// RecordPathIndex (CatalogPerfMemo.swift) for the staleness
    /// contract — invalidated by records.didSet AND keyed on
    /// volumeAggregatesRevision for in-place fullPath rewrites.
    /// Private index — go through record(forPath:).
    private let recordPathIndex = RecordPathIndex()

    /// Fast per-file record resolution for the dossier writeback path
    /// and single-file Analyze batches. Replaces per-file
    /// `records.first(where: { $0.fullPath == path })` scans — on a
    /// ~103k-record catalog an N-file multi-select Analyze paid N full
    /// passes on the MainActor.
    func record(forPath path: String) -> VideoRecord? {
        recordPathIndex.record(forPath: path, in: records,
                               revision: volumeAggregatesRevision)
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

    /// Standalone audio-file extensions. NOT scanned by default — only when the
    /// "Scan for Audio Files" option is on — because archives hold thousands of
    /// scratch/temp audio files (FCP/iMovie render audio, etc.). Audio-only
    /// files inside video containers (.mxf, .mov) are already covered by
    /// videoExtensions; this set is for files that carry an audio extension.
    let audioExtensions: Set<String> = [
        "wav", "aif", "aiff", "mp3", "mp2", "m4a", "aac", "flac", "caf",
        "wma", "ac3", "oga", "opus", "alac", "amr", "au", "snd"
    ]

    /// User-toggleable scan policy. Bound to the Scan Options menu. Walkers
    /// snapshot this at scan start via `skipDirsSnapshot()` /
    /// `skipBundleExtensionsSnapshot()` so toggling a category takes effect
    /// on the next scan (not mid-flight). Kept @Published so the menu
    /// checkmarks update live.
    @Published var scanOptions: ScanOptions = .restored()

    /// Catalog scope: video and linked audio only (DEFAULT ON — Rick's
    /// 2026-07-15 directive). Drives the walker's pre-ffprobe extension
    /// skip and the post-scan linked-audio evidence gate. Test hosts get
    /// the pristine default and never read/write the real plist
    /// (settings-pollution class).
    @Published var catalogScopeSettings: CatalogScopeSettings =
        TestEnvironment.isTestHost
            ? CatalogScopeSettings()
            : CatalogScopeSettings.restored(from: .standard)

    /// Explicit save — @Published kills didSet, so every UI mutation of
    /// `catalogScopeSettings` must call this (AnalysisScope pattern).
    func saveCatalogScopeSettings() {
        guard !TestEnvironment.isTestHost else { return }
        catalogScopeSettings.save(to: .standard)
    }

    /// Duplicate keeper election preferences (2026-08-18): the
    /// user-ordered volume precedence list that decides which copy of a
    /// duplicate group is "Keep" (DuplicateKeeperPolicy — 8/14
    /// offline-strand and 8/17 volume-provenance findings). Test hosts get
    /// the seed default and never read/write the real plist.
    @Published var duplicateKeeperSettings: DuplicateKeeperSettings =
        TestEnvironment.isTestHost
            ? DuplicateKeeperSettings()
            : DuplicateKeeperSettings.restored(from: .standard)

    /// Explicit save — same contract as `saveCatalogScopeSettings`.
    func saveDuplicateKeeperSettings() {
        guard !TestEnvironment.isTestHost else { return }
        duplicateKeeperSettings.save(to: .standard)
    }

    /// Catalog media-kind facet (GH #124 layer 1): the persisted "which
    /// stream shapes does the catalog table show" preference. DEFAULT
    /// `.videoBearing` — the table opens on video-bearing records so 80k
    /// music rows never bury the videos again. Audio-only stays one click
    /// away via the toolbar facet chip and is NEVER hidden from
    /// correlate/combine (those source candidates from `records`
    /// directly). Same explicit-save + test-host-pristine discipline as
    /// `catalogScopeSettings` above.
    @Published var kindFacetSetting: CatalogKindFacetSetting =
        TestEnvironment.isTestHost
            ? CatalogKindFacetSetting()
            : CatalogKindFacetSetting.restored(from: .standard)

    /// Explicit save for the media-kind facet — @Published kills didSet,
    /// so every UI mutation of `kindFacetSetting` must call this.
    func saveKindFacetSetting() {
        guard !TestEnvironment.isTestHost else { return }
        kindFacetSetting.save(to: .standard)
    }

    /// Background preview sweep opt-in ("Keep previews fresh in the
    /// background", 2026-07-27). DEFAULT OFF — sensor-pinned. Same
    /// explicit-save + test-host-pristine discipline as the settings
    /// above. Wiring lives in VideoScanModel+PreviewSweep.swift.
    @Published var previewSweepSettings: PreviewSweepSettings =
        TestEnvironment.isTestHost
            ? PreviewSweepSettings()
            : PreviewSweepSettings.restored(from: .standard)

    /// Explicit save for the sweep setting — @Published kills didSet,
    /// so every UI mutation of `previewSweepSettings` must call this.
    func savePreviewSweepSettings() {
        guard !TestEnvironment.isTestHost else { return }
        previewSweepSettings.save(to: .standard)
    }

    /// The background preview sweep service (2026-07-27). Stored here
    /// because extensions can't add stored properties; configured at the
    /// end of init (configurePreviewSweep), catalog-change signal comes
    /// from records.didSet, interaction pings from the thumbnail /
    /// filmstrip request sites.
    let previewSweep = PreviewSweepService()

    /// Stage 2 (2026-07-29): manages the DETACHED out-of-process helper
    /// (videoscan-preview-sweep) so preview prewarming survives app quit.
    /// Built in configurePreviewSweep with the real posix_spawn launcher +
    /// bundle/dev binary locator. nil under a test host (never spawns a real
    /// process). See PreviewHelperSupervisor.swift for the pure lifecycle.
    var previewHelperCoordinator: PreviewHelperCoordinator?

    // MARK: Detached Find and Tag daemon (2026-08-06)

    /// Background Find and Tag opt-in ("survives app quit"). DEFAULT
    /// OFF. Same explicit-save + test-host-pristine discipline as the
    /// preview sweep above. Wiring: VideoScanModel+FindTagHelper.swift.
    @Published var findTagBackgroundSetting: FindTagBackgroundSetting =
        TestEnvironment.isTestHost
            ? FindTagBackgroundSetting()
            : FindTagBackgroundSetting.restored(from: .standard)

    /// Lifecycle manager for the detached --find-tag daemon (the app
    /// binary respawned headless via posix_spawn+SETSID). Reuses the
    /// preview helper's generic coordinator with find-tag paths/args.
    /// nil under a test host.
    var findTagHelperCoordinator: PreviewHelperCoordinator?

    /// Journal-ingest poll while the background scan is enabled — the
    /// daemon writes verdicts, this timer applies them (30 s cadence;
    /// each tick is one directory listing + at most a few appends'
    /// worth of parsing).
    var findTagIngestTimer: Timer?

    /// Per-file ingest parse state (FindTagIngestEngine): committed
    /// byte offsets + sticky rejections, so the 30 s MainActor tick
    /// reads only appended journal bytes and never re-evaluates
    /// rejected files (codex QA #277/#279 perf). In-memory only; a
    /// relaunch re-parses once.
    var findTagIngestFileStates: [String: FindTagIngestFileState] = [:]

    /// Launch-cached gallery digest for ingest provenance logging
    /// (computing it reads every gallery photo — once is enough).
    /// Double-optional: nil = not yet computed; .some(nil) = computed,
    /// gallery unreadable.
    var findTagGalleryDigestCache: String??

    /// Cross-window search routing for the Family Archivist chat
    /// window (2026-08-07): the archivist publishes a composed query
    /// here; the catalog view observes it, applies it to its own
    /// search field, and clears it. One-way, last-writer.
    @Published var archivistSearchRequest: String?

    /// Exactly one selected Catalog row, published for Hallie's
    /// `currentSelection` temporal reference. Zero or multiple selections
    /// intentionally publish nil so factual chat cannot guess a referent.
    @Published var hallieCurrentSelectionID: UUID?

    /// Snapshot the current skip-directory set from scanOptions.
    /// Must be called on the main actor (returns a Sendable Set<String>
    /// that nonisolated walkers can then capture safely). The derivation
    /// itself is `ScanOptions.skipDirs()` — pure, unit-tested without a
    /// model (GH #124 layer 3 refactor; behavior unchanged for the
    /// pre-existing categories, music-library trees added).
    func skipDirsSnapshot() -> Set<String> {
        scanOptions.skipDirs()
    }

    /// Snapshot the current skip-bundle-extensions set from scanOptions.
    /// App bundles fold into "system files"; media bundles are a separate
    /// toggle (since media libraries are where user content often lives).
    /// "Look Inside Video Project Bundles" then carves the PRO-VIDEO subset
    /// (.fcpbundle, .imovielibrary, .rcproject, …) back OUT of whatever the
    /// skips added — photo/music libraries (.photoslibrary, .lrdata, …) are
    /// never unlocked by it. Derivation lives in
    /// `ScanOptions.skipBundleExtensions()` (pure, unit-tested).
    func skipBundleExtensionsSnapshot() -> Set<String> {
        scanOptions.skipBundleExtensions()
    }

    /// Discovery audit of the most recently FINALIZED scan (one entry per
    /// finished target; the sidecar JSON under ~/Library/Logs/VideoScan/
    /// keeps the full history). Read by tests and available to future UI.
    var lastDiscoveryAudit: DiscoveryAudit?

    /// Test seam: where finalize writes the scan-audit sidecar. nil (the
    /// default) → ~/Library/Logs/VideoScan in production, and NOWHERE in a
    /// test host (same narrow gate as CatalogStore.saveNow) — tests that
    /// want to see the JSON point this at a temp directory.
    var discoveryAuditDirectoryOverride: URL?

    var combineTask: Task<Void, Never>?
    var backfillTask: Task<Void, Never>?
    var ramDisk = RAMDisk()
    // Internal so VideoScanModel+ProbeEngine.probeFile can read/write the
    // SQLite cache; spine helpers (clearCache, cacheCount) also use it.
    nonisolated let metadataCache = MetadataCache()
    /// True while a file-signature pass is running. Guards against two
    /// overlapping fleets (each would honour the lane cap alone and
    /// together exceed it) and drives the UI's disabled state.
    @Published var isComputingSignatures = false

    /// True while a "Refresh Embedded Dates" pass is running (2026-08-16).
    /// Same one-fleet-at-a-time guard as the signature pass.
    @Published var isRefreshingEmbeddedDates = false

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

    /// Sibling of `pendingPreservedFields` (deep-test finding 2, GH
    /// #132): fullPath → the record's PRE-RESCAN id for EVERY record
    /// under the target (not just worth-restoring ones — the target of
    /// a lifecycle pointer may itself carry no curated fields). The
    /// scan merge mints fresh ids, so restored `supersededByID` /
    /// `derivedFrom` values go stale; the apply pass joins this map
    /// with the fresh instances (by fullPath) to build old-id → new-id
    /// and re-link both pointers. Transient — cleared on apply/discard.
    /// Memory: ~path + 16 bytes per record; ~12 MB worst case at 100k,
    /// held only for the duration of one rescan.
    var pendingRescanOldIDs: [String: [String: UUID]] = [:]

    /// Test seam (ScanMergeScopeTests): invoked by the scan-merge existence
    /// sweep right after its initial root-reachability check passes, so the
    /// millisecond-unmount-window recheck can be exercised deterministically
    /// (the test removes the root here, simulating a volume that unmounts
    /// between the root check and the per-record existence loop). Since the
    /// sweep moved off the main actor (2026-07-02, beachball fix) the hook
    /// runs on the detached checker task — hence `@Sendable`. Always nil
    /// in production; `var` for the same test-seam reason as ffprobePath.
    var scanMergeAfterRootCheckForTesting: (@Sendable () -> Void)?

    /// Test seam (ScanMergeScopeTests): awaited ON THE MAIN ACTOR by
    /// `commitScanResults` while the detached existence sweep runs, i.e.
    /// inside the merge's one suspension window. Lets the atomicity test
    /// mutate `records` deterministically "during the await" and assert the
    /// post-suspension re-derivation still merges correctly. Always nil in
    /// production.
    var scanMergeDuringExistenceChecksForTesting: (@MainActor () async -> Void)?

    // Internal so VideoScanModel+ScanTargetPersistence can gate persistence
    // during XCTest runs.
    static var isRunningTests: Bool {
        if NSClassFromString("XCTestCase") != nil { return true }
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil { return true }
        if env["XCTestBundlePath"] != nil { return true }
        if env["SWIFT_TESTING_ENABLED"] != nil { return true }
        if env["VS_UI_TEST"] == "1" { return true } // UI-test target — see TestEnvironment.detect
        if Bundle.allBundles.contains(where: { $0.bundlePath.hasSuffix(".xctest") }) {
            return true
        }
        return false
    }

    init() {
        installLifecycleObservers()
        restoreScanTargets()
        // Restore previously-scanned records so the user can browse the
        // catalog even when source volumes are offline.
        let restored = catalogStore.load()
        // Master Archive designation rides the same snapshot (additive
        // key) — adopt it before anything else reads `masterArchive`.
        // Test hosts: the shared store never loads, and its `masterArchive`
        // slot is a process-wide mirror that an earlier test's model may
        // have written — a fresh model must not inherit it (same narrow
        // gate as CatalogStore.load()).
        if !(Self.isRunningTests && catalogStore === CatalogStore.shared) {
            masterArchive = catalogStore.masterArchive
        }
        reresolveMasterArchiveMount()   // volume-UUID-first re-resolution
        if !restored.isEmpty {
            records = restored
            log("Restored \(restored.count) records from previous session.")
            // One UUID = one record. Repairs the 8/17 duplicate-id incident
            // and any future re-append; see +RecordIdentityRepair.
            repairDuplicateRecordIDs()
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
            //
            // First, one-shot cleanup of the pre-2026-06-30 smear
            // corruption: unreadable/ffprobe-failed records that earlier
            // builds smeared hallucinated dossier content onto (no
            // dossierProcessedAt stamp). Gated so it runs exactly once;
            // prior content is quarantined to a JSON sidecar for undo.
            cleanupSmearedDossiersOnUnreadableRecords()
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
        // One-time notes → userNotes split (2026-07-23): move legacy
        // human text out of the machine `notes` field. Runs over the
        // FULL assembled set (restored + backfilled) and BEFORE the
        // search-index load/rebuild below so haystacks see the
        // post-migration values. Idempotent — see migrateLegacyUserNotes.
        let notesMigrated = migrateLegacyUserNotes()
        if notesMigrated > 0 {
            log("Moved your notes on \(notesMigrated) record(s) into the new Notes field (probe details stay separate).")
            catalogStore.scheduleSave(records: records)
        }
        enforcePhaseConsistency()
        repairCorruptedPhases()
        // Volume-role taxonomy migration (2026-08-16): boot volume → System,
        // ~/… folders → Working, legacy non-master "Archive" → ask once.
        // Idempotent; runs after the Master Archive designation is known.
        migrateVolumeRoles()
        detectResumableTargets()
        installVolumeMountObservers()
        refreshTargetReachability()
        // Warm the per-volume retire-status cache so the Volumes window
        // has real numbers on first open (until then rows read .empty —
        // fail-safe but blank).
        noteVolumeStatusesStale()
        // Warm the volume-rename detection too — an offline target whose
        // volume was renamed while the app was closed should show its
        // "Update catalog" badge shortly after launch.
        noteVolumeRenameCandidatesStale()
        // Build the per-record haystack cache once the catalog is fully
        // assembled (restored + backfilled). All subsequent search
        // operations route through this index — see searchIndex above.
        // Rick 2026-06-16: try to load the persisted index first
        // (~70% launch-time savings on a warm cache). Stale-check
        // against catalog.json's mtime — any catalog change since save
        // forces a fresh rebuild for correctness.
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first?.appendingPathComponent("VideoScan", isDirectory: true)
        let catalogJSONPath = appSupport?.appendingPathComponent("catalog.json").path
        let catalogMTime: Date? = catalogJSONPath.flatMap {
            try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date
        }
        // GH #123 (2026-07-19): two poisoning defenses live in the index
        // itself — defaultPersistenceURL() diverts test hosts to a temp
        // dir (so this load/rebuild/save block can never touch the real
        // plist under a test run), and expectedRecordCount rejects a
        // persisted index grossly inconsistent with the catalog (the
        // 0-record poison a guardless test run used to write here cost
        // 5.4 s of inline haystack builds per settled keystroke).
        // Rejection falls through to the rebuild branch — recovery is
        // automatic on the next launch.
        let idxStart = Date()
        let loaded = searchIndex.loadFromDisk(catalogModifiedAt: catalogMTime,
                                              expectedRecordCount: records.count)
        if loaded {
            let ms = Int((Date().timeIntervalSince(idxStart)) * 1000)
            log("Search index loaded from disk in \(ms) ms (\(searchIndex.recordCount()) indexed / \(records.count) records)")
        } else {
            searchIndex.rebuild(records: records)
            let rebuildMs = Int((Date().timeIntervalSince(idxStart)) * 1000)
            // Persist the freshly-built index so the NEXT launch hits
            // the fast path. Best-effort — a failure here just means
            // we'll rebuild again next time.
            let saveStart = Date()
            try? searchIndex.saveToDisk()
            let saveMs = Int((Date().timeIntervalSince(saveStart)) * 1000)
            log("Search index rebuilt in \(rebuildMs) ms, saved in \(saveMs) ms (\(records.count) records)")
        }
        // Seed the memoized probe-cache count so the toolbar's first
        // render doesn't show 0 for 10 seconds.
        refreshCacheCountSoon()
        // Background preview sweep (2026-07-27): wire the service and —
        // when the persisted checkbox is ON — hand it the restored
        // catalog as its first change signal (records.didSet doesn't
        // fire inside init). Test hosts get the pristine OFF default,
        // so the ~200 model-constructing tests never start a sweep.
        configurePreviewSweep()

        // Detached Find and Tag daemon (2026-08-06): BUILD only — the
        // launch-resume respawn and catch-up ingest wait for
        // activateFindTagBackground(), called by VideoScanApp after
        // CatalogSync decides master-vs-viewer (a read-only viewer must
        // never spawn or ingest; codex QA #277 blocker B). No-op under
        // a test host.
        configureFindTagHelper()
    }

    /// The two NotificationCenter observers installed at init. Extracted
    /// from `init` verbatim (2026-07-07, concurrency-warning pass). Both
    /// observers use `queue: .main`, so the blocks are GUARANTEED to run
    /// on the main thread — `MainActor.assumeIsolated` makes that
    /// guarantee visible to the compiler (and enforces it with a runtime
    /// check) instead of calling MainActor-isolated methods from a
    /// nominally nonisolated closure. Same pattern as the app-delegate
    /// callbacks in VideoScanApp. NO async hop: everything below still
    /// executes synchronously inside the notification delivery, exactly
    /// as before.
    private func installLifecycleObservers() {
        // Listen for catalog-mutation pings from InspectorFamilyTagsView
        // (and any other downstream view that mutates a VideoRecord's
        // class-typed fields, which can't fire @Published didSet on
        // the records array). Triggers the debounced save path.
        NotificationCenter.default.addObserver(
            forName: .videoScanCatalogMutated,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self else { return }
                // When the poster names the mutated record (Inspector
                // family-tag edits), refresh its search-index entry so
                // people:/tag: searches see the change immediately —
                // the same single-record contract as dossier writeback.
                if let rec = note.object as? VideoRecord {
                    self.searchIndex.update(rec)
                }
                self.saveCatalogDebounced()
                self.noteVolumeStatusesStale()
                // QA P0-1 (2026-07-05): the correlate/duplicate ledger paths
                // publish through THIS notification instead of republishing the
                // records array — the debounced chrome caches (dossierCounts,
                // hasAnyPairs, deletableDupVolumes) must refresh here too, or
                // "Show Pairs Only" / the delete-dups menu go stale.
                self.noteCatalogChangedForDossierCounts()
                self.objectWillChange.send()
            }
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
            MainActor.assumeIsolated {
                guard let self else { return }
                self.thumbnailCache.removeAllObjects()
                self.thumbnailPrecacher.cancel(reason: "memory pressure")
            }
        }
    }

    // Internal (not private) so VideoScanModel+VolumeLifecycle can mutate it.
    // mountObservers stays in the main class because extensions can't add
    // stored properties.
    var mountObservers: [any NSObjectProtocol] = []




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
    /// snapshot is on disk before the process exits. Returns whether the
    /// snapshot durably reached disk (see CatalogStore.saveNow).
    @discardableResult
    func saveCatalogNow() -> Bool {
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

    // MARK: - Tidy Catalog undo state (logic in VideoScanModel+TidyCatalog.swift)

    /// The Tidy undo banner observes this. nil = no banner shown. Same
    /// session-scope one-target-at-a-time semantics as lastPurgedBatch.
    @Published var lastTidyBatch: LastTidyBatch?

    // MARK: - Repair-lifecycle undo state (logic in VideoScanModel+RepairLifecycle.swift)

    /// The confirm-repair undo banner observes this (GH #132). nil = no
    /// banner shown. Same session-scope one-target-at-a-time semantics
    /// as lastPurgedBatch.
    @Published var lastConfirmBatch: LastConfirmBatch?

    // MARK: - Cover-Art Music Purge (logic in VideoScanModel+CoverArtMusicPurge.swift)

    /// Drives the "Purge Cover-Art Music Records…" confirmation sheet.
    /// Flipped true by the Catalog-menu command (VideoScanApp); the sheet
    /// is bound in ContentView. Model-level (not a view @State) precisely
    /// so the app-level menu can open it. The sheet recomputes the live
    /// candidate count on appear — never a hard-coded number.
    @Published var showCoverArtMusicPurgeSheet: Bool = false

    // MARK: - Unrelated Audio Purge (logic in VideoScanModel+UnrelatedAudioPurge.swift)

    /// Drives the "Purge Non-Video Audio Junk…" confirmation sheet. Flipped
    /// true by the Catalog-menu command (VideoScanApp); the sheet is bound
    /// in ContentView. Model-level (not a view @State) precisely so the
    /// app-level menu can open it. The sheet recomputes the live candidate
    /// count + top-trees breakdown on appear — never a hard-coded number.
    @Published var showUnrelatedAudioPurgeSheet: Bool = false

    // MARK: - Non-Video Media Purge (logic in VideoScanModel+NonVideoMediaPurge.swift)

    /// Drives the unified "Purge Non-Video Media…" dialog opened from the
    /// Catalog menu. Flipped true by the Catalog-menu command (VideoScanApp);
    /// the sheet is bound in ContentView. Model-level (not a view @State)
    /// precisely so the app-level menu can open it. The volume right-click
    /// entry point (VolumesWindow) drives its OWN local sheet item so it can
    /// pre-select that one volume. Replaces showCoverArtMusicPurgeSheet /
    /// showUnrelatedAudioPurgeSheet as the live purge surface.
    @Published var showNonVideoMediaPurgeSheet: Bool = false

    // MARK: - Update Catalog (VideoScanModel+UpdateCatalog.swift)
    //
    // Stored here because extensions cannot add stored properties. The
    // ONE door for "humans moved things outside the app": rename badge +
    // deferred rescan-with-preview + relink + the "looks moved" banner.
    /// Sheet visibility — bound in ContentView, set by the Catalog menu,
    /// the rename badge, and the "looks moved" banner.
    @Published var showUpdateCatalogSheet: Bool = false
    /// One row per eligible scan target; a pure value the sheet renders.
    @Published var updateCatalogRows: [UpdateCatalogRow] = []
    /// "Looks moved" banner payload (nil = hidden).
    @Published var looksMovedNotice: LooksMovedNotice?
    /// Normalized roots whose finishing scan must PARK its results for the
    /// sheet instead of committing.
    var updateCatalogDeferredRoots: Set<String> = []
    /// Parked probe results per normalized root — live records, main actor
    /// only. Cleared on Apply and on close.
    var updateCatalogPendingMerges: [String: UpdateCatalogPendingMerge] = [:]
    /// Volumes already prompted with the "looks moved" banner this session
    /// (once per volume unless the user asks again).
    var looksMovedPromptedVolumes: Set<String> = []
    /// Generation guard for the off-main missing-file default check.
    var updateCatalogCheckGeneration: Int = 0

    // MARK: - Master Archive (docs/archive_promotion_workflow.md)
    //
    // Stored here (not in VideoScanModel+MasterArchive.swift) because
    // Swift extensions cannot add stored properties. All the LOGIC —
    // initialize / clear / promote plan / linked-copy index — lives in
    // the extension file.

    /// The one designated Master Archive, or nil when none. Mirrored into
    /// `catalogStore.masterArchive` on every change so the next catalog
    /// save persists it (additive snapshot key). Loaded from the store
    /// in `init` right after `load()`.
    @Published var masterArchive: MasterArchiveDesignation? {
        didSet { catalogStore.masterArchive = masterArchive }
    }

    /// Reverse index source-id → promoted-copy record (and copy-id →
    /// source-id), memoized on `RecordsVersion` like the CatalogHelpers
    /// memos. Reads are O(1); the O(records) rebuild runs once per
    /// catalog mutation, never in a view body.
    let archivePromotionIndex = ArchivePromotionIndex()

    /// Live catalog-table selection, mirrored from CatalogView so the
    /// menu-bar command "Promote Selected to Archive" knows what is
    /// selected. Plain `var` (not @Published) — the menu reads it at
    /// click time; nothing renders from it.
    var catalogSelectedIDs: Set<UUID> = []

    /// Sheet driver for "Initialize as Master Archive…" — set by the
    /// Volumes window right-click, the File ▸ Archive menu (after the
    /// open panel), and the no-master alert's fix-it button. Bound in
    /// ContentView. Model-level so every entry point shares ONE sheet.
    @Published var pendingMasterArchiveInitOffer: MasterArchiveInitOffer?

    /// Sheet driver for the Promote confirmation (N files, GB, folders,
    /// warnings). Set by the catalog right-click and the File menu.
    @Published var pendingPromoteRequest: ArchivePromoteRequest?

    /// Alert driver: "You need to designate a volume as the master
    /// archive." Carries the ids the user tried to promote so the fix-it
    /// button can re-offer the promotion after Initialize.
    @Published var pendingPromoteWithoutMaster: ArchivePromoteWithoutMaster?

    /// Non-nil when the volume mounted at the designation's path is NOT
    /// the archive volume (UUID mismatch — codex R3 blocker 1). Set by
    /// `reresolveMasterArchiveMount`; every write path refuses while set;
    /// the UI surfaces it. Cleared by a successful re-resolution or a
    /// fresh Initialize.
    @Published var masterArchiveIdentityMismatch: String?

    /// Volume-role taxonomy migration (2026-08-16): targets whose persisted
    /// role was "Archive" but which are NOT the designated Master Archive.
    /// `.archive` now means THE Master Archive, so we do not silently
    /// rename these — the Volumes window surfaces a one-time sheet asking
    /// Workspace / Backup for each. Filled by
    /// `migrateVolumeRoles()`, drained by `resolveRoleReclassification`.
    @Published var pendingRoleReclassifications: [CatalogScanTarget] = []

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
        previewUnavailable = false
        resetFilmstrip(forNewPath: nil)
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
        // Drop in-memory records that came from this target so the table
        // reflects the reset — through the guarded helper (2026-07-03):
        // records still covered by another registered target's root are
        // KEPT, and any removal >50 records lands a
        // catalog.pre-target-removal snapshot first (or degrades to
        // no-removal). The bare removeAll that used to live here is the
        // hole QA flagged after the 2,720-record folder-target loss.
        removeCatalogRecords(underTargetRoot: target.searchPath, action: "reset")
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
