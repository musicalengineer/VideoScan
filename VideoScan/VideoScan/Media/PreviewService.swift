// PreviewService.swift
// GH #337 slice 1 (2026-10-19): the catalog preview pane's state and
// logic — thumbnail (L1/L2 caches, debounce, negative cache), filmstrip
// and the background preview sweep — moved off VideoScanModel into one
// store the model owns (`model.previewService`).
//
// Behaviour-preserving move (docs/design/vsm_split_plan_2026_10_19.md §2):
//   - VideoScanModel keeps every old name as a computed forwarder, so all
//     call sites (views, extensions, ~40 tests) compile unchanged. In C++
//     terms: a pimpl with inline forwarding accessors.
//   - Threading unchanged: @MainActor, exactly as the model was.
//   - The six formerly-@Published properties fire `host.willChange()` in
//     willSet — the model wires that to its own `objectWillChange.send()`,
//     so everything that observed the model still refreshes exactly as it
//     did under @Published. SwiftUI ALSO tracks these reads directly
//     (@Observable); ObservableForwarderPatternTests proves both paths.
//     Dropping the bridge is a later, separate per-view PR.
//   - The formerly plain `var`s are @ObservationIgnored (a non-@Published
//     var notified nobody before; it notifies nobody now).
//   - Settings keep their explicit save() (savePreviewSweepSettings).
//
// File map:
//   PreviewService.swift          state + thumbnail entry points
//   PreviewService+Filmstrip.swift filmstrip orchestration
//   PreviewService+Sweep.swift     background sweep + detached helper glue
//   PreviewFrameRenderer.swift     the nonisolated frame-rip cores
//
// Perf batch 2026-06-10:
//   - requestThumbnailDebounced is the selection-driven entry point.
//     Holding an arrow key used to spawn one AVAssetImageGenerator per
//     traversed row; now only the row the user RESTS on (200 ms) pays
//     for a generation. Cache hits still swap instantly.
//   - The preview is no longer nil'd while a replacement generates — the
//     old frame stays up until the new one is ready, so arrow-keying
//     doesn't flash an empty preview.
//   - The cache has a byte-cost limit (ThumbnailCachePolicy, 8 GB) and
//     each setObject carries an estimated bitmap cost.
//
// Preview disk cache (Phase B piece 1, 2026-07-26):
//   - Lookup order is L1 NSCache → L2 PreviewDiskCache → generate,
//     with write-through to BOTH on generation. Disk hits populate L1.
//     The L2 probe (one stat + JPEG decode) happens inside the detached
//     generation task — never on the main actor.
//   - The interactive path stores its single 0.5 s frame at tier "fast";
//     the background/prewarm pass owns tier "best" (see PreviewDiskCache
//     for the tier contract — best never downgrades to fast).
//   - Negative-cache (ThumbnailFailureStore) semantics: it is consulted
//     before L2, and only genuine generation failures are recorded
//     (cancellation/ffmpegUnavailable excluded).

import Foundation
import AppKit
import Observation

@Observable @MainActor
final class PreviewService {

    // MARK: - Owner hooks

    /// What the service needs from its owner (VideoScanModel). Closures,
    /// not a back-pointer, so the store depends on three facts rather than
    /// the whole model. Wired once at the top of the model's init; the
    /// defaults are inert so a service built alone (tests) is safe.
    struct Host {
        /// Called in willSet of every formerly-@Published property — the
        /// model's `objectWillChange.send()`.
        var willChange: @MainActor () -> Void = {}
        /// The catalog, for the background sweep's candidate list.
        var records: @MainActor () -> [VideoRecord] = { [] }
        /// Raise the app-wide MissingDependency alert (model.missingDependency).
        var reportMissingDependency: @MainActor (MissingDependency) -> Void = { _ in }
    }

    @ObservationIgnored var host = Host()

    // MARK: - Observed state (formerly @Published on VideoScanModel)

    var previewImage: NSImage? { willSet { host.willChange() } }
    var previewFilename: String = "" { willSet { host.willChange() } }
    /// Set when the user selects a record whose source volume isn't currently
    /// mounted. CatalogContent renders an "Volume Offline" placeholder
    /// instead of trying to load a thumbnail.
    var previewOfflineVolumeName: String? { willSet { host.willChange() } }
    /// True when preview generation FAILED (or negative-cache hit) for the
    /// CURRENT selection. CatalogContent renders a "NO PREVIEW" placeholder
    /// instead of an eternal spinner (preview routing, 2026-07-26). Reset
    /// by clearPreview and on every new selection request.
    var previewUnavailable: Bool = false { willSet { host.willChange() } }

    /// Filmstrip mode for AVPlayer-unplayable formats (filmstrip preview,
    /// 2026-07-27): what the preview pane's filmstrip branch renders.
    /// Carries its record's fullPath so a stale publish can never show
    /// another row's frames. Driven by requestFilmstrip / stopFilmstrip /
    /// resetFilmstrip in PreviewService+Filmstrip.swift.
    var filmstripState: PreviewFilmstripState = .idle { willSet { host.willChange() } }

    /// Background preview sweep opt-in ("Keep previews fresh in the
    /// background", 2026-07-27). DEFAULT OFF — sensor-pinned. Same
    /// explicit-save + test-host-pristine discipline as the model's other
    /// settings. Wiring lives in PreviewService+Sweep.swift.
    var previewSweepSettings: PreviewSweepSettings =
        TestEnvironment.isTestHost
            ? PreviewSweepSettings()
            : PreviewSweepSettings.restored(from: .standard) {
        willSet { host.willChange() }
    }

    /// Explicit save for the sweep setting — @Published killed didSet,
    /// so every UI mutation of `previewSweepSettings` must call this.
    func savePreviewSweepSettings() {
        guard !TestEnvironment.isTestHost else { return }
        previewSweepSettings.save(to: .standard)
    }

    // MARK: - Caches

    /// Thumbnail cache — keyed by fullPath, avoids regenerating from video file on re-click.
    /// Byte-cost-limited (8 GB — see ThumbnailCachePolicy) so the volume-click
    /// prewarm can fill it aggressively without unbounded growth; NSCache also
    /// evicts under system memory pressure, and the .memoryPressureAutoPause
    /// observer in the model's init clears it outright when scans hit the RAM floor.
    @ObservationIgnored let thumbnailCache: NSCache<NSString, NSImage> = PreviewService.makeThumbnailCache()

    /// Negative cache for preview generation (preview routing, 2026-07-26):
    /// files that failed to yield a frame, keyed by fullPath with their
    /// (mtime, size) at failure time — consulted by generateThumbnail and
    /// the precacher BEFORE attempting, so a known-bad file costs one stat
    /// instead of a deadline-bounded decode failure every selection. A
    /// repaired/replaced file (signature mismatch) retries automatically.
    /// Capped at 10k entries (~2–3 MB worst case) — see ThumbnailFailureStore.
    @ObservationIgnored let thumbnailFailureStore = ThumbnailFailureStore()

    /// Persistent on-disk preview cache — L2 behind `thumbnailCache`
    /// (Phase B piece 1, 2026-07-26). Keyed on (path, mtime, size) so a
    /// changed file misses automatically; 2 GB cap pruned at background
    /// QoS on launch. Lookup order everywhere: L1 NSCache → this →
    /// generate, write-through to both. See PreviewDiskCache.swift.
    /// (The production root self-redirects to a temp sandbox under a
    /// unit-test host — same gate as MetadataCache.defaultPath.)
    @ObservationIgnored let previewDiskCache = PreviewDiskCache(rootURL: PreviewDiskCache.productionRootURL)

    /// Volume-click thumbnail prewarmer (Part 3 of the 2026-06-10 perf
    /// batch). One instance shared by the catalog view and the scan
    /// lifecycle — a new volume selection or a scan start cancels the run.
    @ObservationIgnored let thumbnailPrecacher = ThumbnailPrecacher()

    // MARK: - Selection bookkeeping

    /// Pending debounced thumbnail generation (see requestThumbnailDebounced).
    /// Cancelled and replaced on every selection step; only the row the user
    /// rests on pays for generation.
    @ObservationIgnored var thumbnailDebounceTask: Task<Void, Never>?

    /// fullPath of the most recent preview request. Guards against a slow,
    /// stale generation completing AFTER a newer selection and clobbering
    /// its preview. Set by requestThumbnailDebounced/generateThumbnail.
    @ObservationIgnored var previewRequestPath: String?

    // MARK: Filmstrip bookkeeping (filmstrip preview, 2026-07-27)
    // Logic lives in PreviewService+Filmstrip.swift. Main-actor only
    // (the service is @MainActor) — no locks needed. For Rick: these are
    // the members a C++ class would guard with "only touch on the UI
    // thread" comments; @MainActor makes the compiler enforce it.

    /// The single in-flight filmstrip generation (interactive OR
    /// prewarm) — at most ONE per model instance by design, so an
    /// interactive play click and a background prewarm can never rip
    /// the same 20 GB master twice concurrently.
    @ObservationIgnored var filmstripTask: Task<Void, Never>?
    /// fullPath the in-flight task is generating for (coalescing key).
    @ObservationIgnored var filmstripTaskPath: String?
    /// True when the in-flight task's result should publish to the UI.
    /// A prewarm flips to true ("promoted") if the user clicks play on
    /// the same row mid-generation.
    @ObservationIgnored var filmstripTaskIsInteractive = false
    /// Latest (done, total) the in-flight task reported — lets a
    /// promoted prewarm publish honest progress immediately.
    @ObservationIgnored var filmstripLatestProgress: (done: Int, total: Int) = (0, 0)
    /// Identifies the latest filmstrip task so a superseded run's
    /// completion can't clear a newer run's bookkeeping (same pattern
    /// as ThumbnailPrecacher.currentRunID).
    @ObservationIgnored var filmstripRunID = UUID()
    /// Paths whose filmstrip generation genuinely failed this session —
    /// keeps the prewarm from re-ripping hopeless files on every
    /// selection. Deliberately NOT ThumbnailFailureStore: the fast
    /// thumbnail SUCCEEDED for these files, and poisoning the shared
    /// negative cache would blank their previews entirely. Capped at
    /// 10k inserts (~2 MB worst case) per the memory discipline rule.
    @ObservationIgnored var filmstripFailedPaths: Set<String> = []

    // MARK: Background sweep (2026-07-27)

    /// The background preview sweep service. Configured at the end of the
    /// model's init (configurePreviewSweep), catalog-change signal comes
    /// from the model's records.didSet, interaction pings from the
    /// thumbnail / filmstrip request sites.
    @ObservationIgnored let previewSweep = PreviewSweepService()

    /// Stage 2 (2026-07-29): manages the DETACHED out-of-process helper
    /// (videoscan-preview-sweep) so preview prewarming survives app quit.
    /// Built in configurePreviewSweep with the real posix_spawn launcher +
    /// bundle/dev binary locator. nil under a test host (never spawns a real
    /// process). See PreviewHelperSupervisor.swift for the pure lifecycle.
    @ObservationIgnored var previewHelperCoordinator: PreviewHelperCoordinator?

    init() {}

    // MARK: - Thumbnail cache

    /// Factory for the thumbnail cache — split out so the cost limit is set
    /// in exactly one place and unit tests can assert it without
    /// instantiating the whole model.
    nonisolated static func makeThumbnailCache() -> NSCache<NSString, NSImage> {
        let cache = NSCache<NSString, NSImage>()
        cache.name = "Rick-Breen.VideoScan.thumbnailCache"
        // Byte-cost ceiling (8 GB). Every setObject below passes an
        // estimated bitmap cost, so NSCache can actually enforce this.
        // NSCache also evicts on its own under system memory pressure.
        cache.totalCostLimit = ThumbnailCachePolicy.costLimitBytes
        return cache
    }

    /// Drop any cached thumbnail under `path`. Called from the rename path
    /// (VideoScanModel+Rename) so a renamed record doesn't leak a stale
    /// entry under its old `fullPath` key.
    func invalidateThumbnailCacheEntry(forPath path: String) {
        thumbnailCache.removeObject(forKey: path as NSString)
    }

    /// Store a prewarmed/generated CGImage into the cache with its byte
    /// cost. Main-actor because the NSCache + NSImage types live there in
    /// this codebase's threading model (matches the pre-existing
    /// generateThumbnail completion hop).
    func storePrecachedThumbnail(_ cgImage: CGImage, forPath path: String) {
        // autoreleasepool around the bitmap-handling sync work — standing
        // rule for media loops (feedback_memory_pressure): don't let
        // NSImage/CG temporaries pile up across a long prewarm run.
        autoreleasepool {
            let nsImage = NSImage(cgImage: cgImage,
                                  size: NSSize(width: cgImage.width, height: cgImage.height))
            thumbnailCache.setObject(
                nsImage,
                forKey: path as NSString,
                cost: ThumbnailCachePolicy.estimatedCost(pixelsWide: cgImage.width,
                                                         pixelsHigh: cgImage.height)
            )
        }
    }

    /// Selection-driven entry point — debounces thumbnail generation by
    /// 200 ms so holding an arrow key doesn't open one media file per
    /// traversed row. Cache hits bypass the debounce (instant swap, no
    /// I/O). While waiting, the PREVIOUS preview image stays visible; it
    /// is only replaced when the new frame is ready.
    func requestThumbnailDebounced(for record: VideoRecord) {
        thumbnailDebounceTask?.cancel()
        thumbnailDebounceTask = nil

        // Background sweep yields to the user: one timestamp write —
        // the sweep pauses dispatch until ~10 s of interactive quiet
        // (PreviewSweepService, 2026-07-27).
        previewSweep.noteUserInteraction()

        previewFilename = record.filename

        // Selection moved: filmstrip state for another row is stale
        // (frames must never outlive their row); a same-row prewarm
        // survives inside resetFilmstrip (filmstrip preview, 2026-07-27).
        resetFilmstrip(forNewPath: record.fullPath)

        // Cache hit → immediate, no debounce, no file I/O.
        let cacheKey = record.fullPath as NSString
        if let cached = thumbnailCache.object(forKey: cacheKey) {
            previewRequestPath = record.fullPath
            previewImage = cached
            previewOfflineVolumeName = nil
            previewUnavailable = false
            // Fast thumbnail is up — background-prewarm the strip for
            // ffmpegDirect rows (all guards inside; no-op otherwise).
            prewarmFilmstripIfNeeded(item: FilmstripWorkItem(record: record))
            return
        }

        // Mark this as the current request so a slower, earlier generation
        // that lands later can't overwrite the newer selection's preview.
        previewRequestPath = record.fullPath

        // New selection: drop a previous row's "NO PREVIEW" verdict — if
        // THIS row is a known failure too, generateThumbnail republishes
        // it (instantly, via the negative cache) after the debounce.
        previewUnavailable = false

        // `Task` + cancel-on-next-keystroke ≈ a debounce timer; Swift's
        // cooperative cancellation replaces invalidating an NSTimer.
        thumbnailDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            self.generateThumbnail(for: record)
        }
    }

    /// Clear the preview pane AND any pending debounced generation.
    /// Without the cancel, a debounce scheduled for the previous (video)
    /// row fires up to 200 ms after the selection moved to a row with no
    /// thumbnail and repopulates the pane with the wrong file. (QA 🟠,
    /// 2026-06-10 perf batch.)
    func clearPreview() {
        thumbnailDebounceTask?.cancel()
        thumbnailDebounceTask = nil
        previewRequestPath = nil
        previewImage = nil
        previewFilename = ""
        previewOfflineVolumeName = nil
        previewUnavailable = false
        resetFilmstrip(forNewPath: nil)
    }

    /// Immediate (non-debounced) generation — used by deliberate one-shot
    /// navigation (Archive → Catalog deep links) and as the debounce
    /// landing point. Does NOT clear the existing preview while working;
    /// the swap happens only when the replacement frame is ready.
    func generateThumbnail(for record: VideoRecord) {
        // A deliberate immediate request supersedes any pending debounce —
        // otherwise selectAndReveal's instant path can race a stale
        // debounce that fires 200 ms later for a different row.
        thumbnailDebounceTask?.cancel()
        thumbnailDebounceTask = nil

        // Interactive request — pause the background sweep (also pinged
        // by the debounced entry point; double pings are harmless).
        previewSweep.noteUserInteraction()

        previewFilename = record.filename
        previewRequestPath = record.fullPath

        // Same selection-change reset as requestThumbnailDebounced
        // (this is also a direct entry point for deep links).
        resetFilmstrip(forNewPath: record.fullPath)

        // Check cache first — works even when the source volume is offline.
        let cacheKey = record.fullPath as NSString
        if let cached = thumbnailCache.object(forKey: cacheKey) {
            previewImage = cached
            previewOfflineVolumeName = nil
            previewUnavailable = false
            // Prewarm the strip for ffmpegDirect rows (guards inside —
            // including reachability, since an L1 hit works offline).
            prewarmFilmstripIfNeeded(item: FilmstripWorkItem(record: record))
            return
        }

        // If the source volume isn't mounted, don't try to read the file —
        // surface a clean "Volume Offline" placeholder instead of stalling.
        // (This selection has no thumbnail at all, so clearing is correct.)
        if !VolumeReachability.isReachable(path: record.fullPath) {
            previewImage = nil
            previewUnavailable = false
            previewOfflineVolumeName = VolumeReachability.volumeName(forPath: record.fullPath)
            return
        }
        previewOfflineVolumeName = nil

        // Negative cache: this file already failed and is unchanged on
        // disk (mtime + size) — publish "NO PREVIEW" immediately. No
        // spinner, no media I/O (one stat, already gated behind the
        // reachability check above). A repaired/replaced file falls
        // through and retries normally.
        if thumbnailFailureStore.isKnownFailure(atPath: record.fullPath) {
            previewImage = nil
            previewUnavailable = true
            return
        }
        previewUnavailable = false

        // Capture the cache key as Sendable String, not NSString. Re-bridge
        // inside the MainActor block where the NSCache lives. Routing
        // fields ride along the same way (all Sendable value types).
        // isLikelyUnanalyzable (not raw needsReformat) so routing shares
        // the canonical legacy-codec list with the red `!` badge.
        let cacheKeyString = record.fullPath
        let container = record.container
        let videoCodec = record.videoCodec
        let likelyUnanalyzable = record.isLikelyUnanalyzable
        // Rides along for the filmstrip prewarm kick below — the strip
        // plan is built from the CATALOG duration, never ffprobe.
        let durationSeconds = record.durationSeconds
        let failureStore = thumbnailFailureStore
        let diskCache = previewDiskCache
        Task.detached { [weak self] in
            // L2 disk cache probe (Phase B piece 1) — one stat + JPEG
            // decode, deliberately OFF the main actor. Signature nil
            // (file vanished between reachability check and here) just
            // skips L2 both ways; generation below reports the truth.
            let signature = PreviewDiskCache.fileSignature(atPath: cacheKeyString)
            if let signature,
               let diskHit = diskCache.lookup(path: cacheKeyString,
                                              mtime: signature.mtime,
                                              size: signature.size) {
                // Disk hits populate L1, then publish through it — same
                // single storage path as a fresh generation.
                await MainActor.run {
                    guard let self else { return }
                    self.storePrecachedThumbnail(diskHit, forPath: cacheKeyString)
                    if self.previewRequestPath == cacheKeyString {
                        self.previewImage = self.thumbnailCache.object(forKey: cacheKeyString as NSString)
                        self.previewUnavailable = false
                    }
                    // Fast thumbnail is up — kick the filmstrip prewarm
                    // for ffmpegDirect rows (all guards inside).
                    self.prewarmFilmstripIfNeeded(item: FilmstripWorkItem(
                        path: cacheKeyString, container: container,
                        videoCodec: videoCodec,
                        likelyUnanalyzable: likelyUnanalyzable,
                        durationSeconds: durationSeconds))
                }
                return
            }
            do {
                let cgImage = try await PreviewFrameRenderer.renderThumbnailCGImage(
                    path: cacheKeyString,
                    container: container,
                    videoCodec: videoCodec,
                    likelyUnanalyzable: likelyUnanalyzable)
                // Publish to L1/UI FIRST, L2 after (QA 🟡, 2026-07-26):
                // diskCache.store blocks on the cache lock (and JPEG-
                // encodes under it), and the init-scheduled background
                // prune can hold that lock mid-reap right at launch —
                // the user's first preview must not wait behind a reap
                // loop. (The prewarm path keeps store-then-L1: it's
                // background work whose per-file order gates nothing
                // visible.)
                // CGImage is Sendable; NSImage and NSString aren't. Build
                // both on the main actor so we never cross actor boundaries
                // with them.
                await MainActor.run {
                    guard let self else { return }
                    self.storePrecachedThumbnail(cgImage, forPath: cacheKeyString)
                    // Publish only if this is still the current selection's
                    // request — a stale completion must not clobber a newer
                    // preview (the cache write above is still worthwhile).
                    if self.previewRequestPath == cacheKeyString {
                        self.previewImage = self.thumbnailCache.object(forKey: cacheKeyString as NSString)
                        self.previewUnavailable = false
                    }
                    // Fast thumbnail landed — kick the filmstrip prewarm
                    // for ffmpegDirect rows (all guards inside).
                    self.prewarmFilmstripIfNeeded(item: FilmstripWorkItem(
                        path: cacheKeyString, container: container,
                        videoCodec: videoCodec,
                        likelyUnanalyzable: likelyUnanalyzable,
                        durationSeconds: durationSeconds))
                }
                // Write-through L2 (still off-main here). Tier "fast":
                // this is the interactive single 0.5 s frame — the
                // background pass may later upgrade it to "best".
                // Signature from BEFORE generation is correct: the key
                // must describe the file we just decoded.
                if let signature {
                    diskCache.store(cgImage,
                                    path: cacheKeyString,
                                    mtime: signature.mtime,
                                    size: signature.size,
                                    tier: .fast)
                }
            } catch {
                // Remember the failure (stat happens here, off-main) so
                // the next selection of this row skips straight to the
                // "NO PREVIEW" state. Two exclusions (QA 2026-07-26):
                //   - CancellationError says nothing about the file —
                //     recording it would stamp a good file "bad" for the
                //     rest of the session (defensive here; the precacher
                //     path is where cancellation actually happens today).
                //   - ffmpegUnavailable is an ENVIRONMENT failure (no
                //     ffmpeg binary), also not a fact about this file.
                if !(error is CancellationError),
                   !Task.isCancelled,
                   (error as? PreviewFrameError) != .ffmpegUnavailable {
                    failureStore.recordFailure(forPath: cacheKeyString)
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    // Generation failed for the CURRENT selection → showing
                    // the previous file's frame would be wrong; clear it and
                    // publish the failure so the pane doesn't spin forever
                    // (respects the stale-completion guard — an old failure
                    // must not stamp "NO PREVIEW" on a newer selection).
                    if self.previewRequestPath == cacheKeyString {
                        self.previewImage = nil
                        self.previewUnavailable = true
                    }
                }
            }
        }
    }
}
