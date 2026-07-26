import Foundation
import AVFoundation
import AppKit
import CoreMedia
import ImageIO
import os

// MARK: - Thumbnail Preview + ffprobe convenience
//
// generateThumbnail caches an NSImage per fullPath in the model's
// thumbnailCache. The cache stays in the main class because extensions
// can't add stored properties. The cache invalidation entry-point also
// stays in main (invalidateThumbnailCacheEntry) since it's called from
// the rename extension on a per-record basis.
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
//   - renderThumbnailCGImage is the shared single-frame generator core,
//     also used by ThumbnailPrecacher (Part 3 prewarm).
//
// Preview routing (2026-07-26):
//   - renderThumbnailCGImage is now ROUTED: the pure
//     PreviewFrameRouter.previewRoute decision (cataloged container /
//     videoCodec / isLikelyUnanalyzable) picks AVFoundation or ffmpeg
//     BEFORE any media object exists. FFV1/Matroska masters used to stall the
//     pane 30 s–1 min+ while AVFoundation ground through container
//     sniffing it could never finish — they now go straight to a
//     single-frame ffmpeg rip (same two-tier design the caption
//     pipeline's extractFramesForCaptioning already proved out).
//   - The AVFoundation path carries a hard deadline (a watchdog task
//     calls cancelAllCGImageGeneration) and falls back to ONE ffmpeg
//     attempt before giving up, so surprise-hostile files can't hang.
//   - Failures land in the model's ThumbnailFailureStore (negative
//     cache) and publish previewUnavailable so the pane shows "NO
//     PREVIEW" instead of an eternal spinner.
//
// Preview disk cache (Phase B piece 1, 2026-07-26):
//   - Lookup order is now L1 NSCache → L2 PreviewDiskCache → generate,
//     with write-through to BOTH on generation. Disk hits populate L1.
//     The L2 probe (one stat + JPEG decode) happens inside the detached
//     generation task — never on the main actor.
//   - The interactive path stores its single 0.5 s frame at tier "fast";
//     the background/prewarm pass owns tier "best" (see PreviewDiskCache
//     for the tier contract — best never downgrades to fast).
//   - Negative-cache (ThumbnailFailureStore) semantics are UNCHANGED:
//     it is consulted before L2, and only genuine generation failures
//     are recorded (cancellation/ffmpegUnavailable excluded, as before).
//
// Content-aware best frame (Phase B piece 1 commit 2, 2026-07-26):
//   - renderBestPreviewCGImage — BACKGROUND path only (prewarm); the
//     interactive path stays the fast single 0.5 s frame. Rips ≤4
//     candidate frames at offsets planned from the CATALOG duration
//     (PreviewBestFramePlan — no ffprobe at preview time), scores them
//     (PreviewFrameScorer), returns the winner; all-near-solid keeps
//     the 25% frame so a decodable file never loses its preview to a
//     blue VHS lead-in. AVF-routed files rip all candidates from ONE
//     asset via generateCGImagesAsynchronously(forTimes:); ffmpeg-routed
//     files reuse the single-frame rip per offset with cancellation
//     checks between candidates.
//
// runFFProbe is a thin convenience that any extension may want — kept
// nearby because both generateThumbnail and ffprobe live in the "preview /
// quick peek at one file" mental bucket.

/// File-scope (not a static on the @MainActor model) so the detached
/// generation tasks can log without touching main-actor-isolated state —
/// same fix class as precacheLog in ThumbnailPrecache.swift.
private let previewLog = Logger(subsystem: "Rick-Breen.VideoScan",
                                category: "preview")

/// Single-frame preview generation failures (the I/O side of the
/// routing; the pure decision lives in PreviewFrameRoute.swift).
enum PreviewFrameError: Error {
    /// ToolLocator found no executable ffmpeg — the fallback tier is
    /// unavailable, not just this file.
    case ffmpegUnavailable
    /// ffmpeg ran (both seek attempts) but produced no decodable frame.
    case noFrameProduced
}

/// Shares the AVAssetImageGenerator between the generation await and its
/// deadline watchdog task, plus a latch recording that the deadline
/// fired (so the failure log says "timed out" and not just AVF's opaque
/// "operation cancelled"). `@unchecked Sendable` tiny-box per the repo
/// convention (see ProcessRunner.DeadlineFlag): the Bool is
/// lock-guarded, and cancelAllCGImageGeneration is documented safe to
/// call from any thread. For Rick: a mutex-guarded bool riding along
/// with a shared object pointer.
private final class AVFDeadlineBox: @unchecked Sendable {
    let generator: AVAssetImageGenerator
    private let lock = NSLock()
    private var fired = false

    init(_ generator: AVAssetImageGenerator) { self.generator = generator }

    func fireDeadline() {
        lock.lock()
        fired = true
        lock.unlock()
        // Pending generation callbacks complete with
        // AVError.operationCancelled — that resumes the awaiting
        // continuation, which is exactly the unblock we need.
        generator.cancelAllCGImageGeneration()
    }

    var deadlineFired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fired
    }
}

/// Accumulates the AVF batch candidate rips (best-frame pass) across
/// the generator's per-time callbacks, and reports when the LAST
/// callback has landed so the awaiting continuation resumes exactly
/// once. `@unchecked Sendable` tiny-box per the repo convention: every
/// member access is inside the lock. AVF delivers exactly one callback
/// per requested time — including for cancelled/failed times — which is
/// what makes the countdown sound. For Rick: a mutex-guarded results
/// vector + countdown, standing in for a condition variable.
private final class AVFCandidateCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [(offset: Double, image: CGImage)] = []
    private var remaining: Int

    init(expecting count: Int) { self.remaining = count }

    /// Record one callback; true when this was the final one.
    func record(offset: Double, image: CGImage?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let image { frames.append((offset, image)) }
        remaining -= 1
        return remaining == 0
    }

    var collected: [(offset: Double, image: CGImage)] {
        lock.lock()
        defer { lock.unlock() }
        return frames
    }
}

extension VideoScanModel {

    nonisolated func runFFProbe(url: URL) async -> (output: FFProbeOutput?, stderr: String) {
        await CombineVerifier.runFFProbe(url: url, ffprobePath: ffprobePath)
    }

    /// Factory for the model's thumbnail cache — split out so the cost
    /// limit is set in exactly one place and unit tests can assert it
    /// without instantiating the whole model.
    nonisolated static func makeThumbnailCache() -> NSCache<NSString, NSImage> {
        let cache = NSCache<NSString, NSImage>()
        cache.name = "Rick-Breen.VideoScan.thumbnailCache"
        // Byte-cost ceiling (8 GB). Every setObject below passes an
        // estimated bitmap cost, so NSCache can actually enforce this.
        // NSCache also evicts on its own under system memory pressure.
        cache.totalCostLimit = ThumbnailCachePolicy.costLimitBytes
        return cache
    }

    // MARK: - Routed single-frame core

    /// Hard deadline on the AVFoundation tier: asset open + single-frame
    /// generation together. Generous for anything AVF can actually
    /// decode (typ. well under 1 s even on HDD); the ceiling exists for
    /// surprise-hostile files the router didn't catch.
    nonisolated static let avfPreviewDeadlineSeconds: Double = 8

    /// Deadline on one ffmpeg single-frame rip. ffmpeg opens hostile
    /// containers in milliseconds; the ceiling guards dead-volume reads
    /// (ProcessRunner escalates SIGTERM → SIGKILL → abandon past it).
    nonisolated static let ffmpegPreviewDeadlineSeconds: Double = 15

    /// Shared single-frame thumbnail core: one CGImage at t=0.5s, capped
    /// at 480x270. Used by the interactive path (generateThumbnail) and
    /// the volume-click prewarm (ThumbnailPrecacher). Never loads more
    /// than one frame per call.
    ///
    /// ROUTED (2026-07-26): the pure route decision runs FIRST, before
    /// any AVFoundation object is created — an mkv/FFV1 record never
    /// instantiates an AVURLAsset. Routing fields come from the catalog
    /// record (ffprobe-stamped at scan time), so callers must pass them
    /// through rather than re-probing. `likelyUnanalyzable` is the
    /// record's `isLikelyUnanalyzable` derived flag — stored
    /// needsReformat OR the canonical UnplayableLegacyCodecs list — so
    /// this core shares one source of truth with the catalog's red `!`
    /// badge instead of growing its own drifting codec list.
    ///
    /// `@concurrent`: under Approachable Concurrency a plain `nonisolated
    /// async` runs on its CALLER's actor — today's callers are both
    /// detached tasks (safe), but a future main-actor caller would
    /// silently pull AVAsset open/decode onto the UI thread. Pin it to
    /// the global pool. (Same trap QA caught in MediaPairComparator.)
    // #if guard: the nightly CI's Xcode 16.4 (Swift 6.1) knows
    // `@concurrent` only as a deprecated alias of `@Sendable` and warns;
    // pre-6.2 a nonisolated async already runs off-actor.
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func renderThumbnailCGImage(path: String,
                                                   container: String,
                                                   videoCodec: String,
                                                   likelyUnanalyzable: Bool) async throws -> CGImage {
        let route = PreviewFrameRouter.previewRoute(container: container,
                                                    videoCodec: videoCodec,
                                                    likelyUnanalyzable: likelyUnanalyzable)
        let filename = (path as NSString).lastPathComponent
        switch route {
        case .ffmpegDirect:
            previewLog.debug("route ffmpegDirect (\(container, privacy: .public) / \(videoCodec, privacy: .public)) — \(filename, privacy: .public)")
            return try await renderPreviewFrameViaFFmpeg(path: path)

        case .avFoundation:
            previewLog.debug("route avFoundation — \(filename, privacy: .public)")
            do {
                return try await renderPreviewFrameViaAVFoundation(path: path)
            } catch {
                // AVF failed or timed out on a file the router thought
                // was friendly — ffmpeg is the arbiter before we call it
                // unpreviewable (same tier order as the caption
                // pipeline's extractFramesForCaptioning).
                previewLog.notice("AVFoundation preview failed for \(filename, privacy: .public) (\(error.localizedDescription, privacy: .public)) — one ffmpeg attempt")
                return try await renderPreviewFrameViaFFmpeg(path: path)
            }
        }
    }

    /// AVFoundation tier: the original generator path, now under a hard
    /// deadline covering asset open + generation. A detached watchdog
    /// task calls cancelAllCGImageGeneration at the deadline, which
    /// completes the pending callback with operationCancelled and
    /// unblocks the await — without it, AVF container sniffing on a
    /// hostile 20 GB file can grind for minutes with no way to bail.
    ///
    /// Plain `nonisolated` (no `@concurrent`): only called from the
    /// routed core above, which is already pinned to the global pool —
    /// the callee inherits that executor.
    private nonisolated static func renderPreviewFrameViaAVFoundation(path: String) async throws -> CGImage {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 270)

        let box = AVFDeadlineBox(generator)
        let deadline = avfPreviewDeadlineSeconds
        // Watchdog ≈ an armed one-shot timer; cancelling the Task on the
        // success path disarms it (Task.sleep throws CancellationError
        // and the fire never happens).
        let watchdog = Task {
            try await Task.sleep(for: .seconds(deadline))
            box.fireDeadline()
        }
        defer { watchdog.cancel() }

        let time = CMTime(seconds: 0.5, preferredTimescale: 600)
        do {
            return try await withCheckedThrowingContinuation { cont in
                box.generator.generateCGImageAsynchronously(for: time) { image, _, error in
                    if let image {
                        cont.resume(returning: image)
                    } else {
                        cont.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                    }
                }
            }
        } catch {
            if box.deadlineFired {
                previewLog.notice("AVFoundation preview timed out (\(Int(deadline))s) — \((path as NSString).lastPathComponent, privacy: .public)")
            }
            throw error
        }
    }

    /// ffmpeg tier: rip exactly one frame to a temp PNG (scaled to ≤480
    /// wide, height even for the encoder), load it via ImageIO. `seeks`
    /// is a try-in-order ladder; the default rips at t=0.5s and — if
    /// that yields no frame, e.g. a sub-half-second clip — retries once
    /// from t=0. The best-frame pass passes a single candidate offset
    /// instead. Same ProcessRunner + ToolLocator + input-seek (-ss
    /// before -i) shape as CaptionRunner's extractFramesViaFFmpeg.
    ///
    /// Memory: one ≤480-wide PNG in RAM per call (~0.5 MB decoded),
    /// deleted from disk on exit — nothing accumulates.
    private nonisolated static func renderPreviewFrameViaFFmpeg(path: String,
                                                                seeks: [String] = ["0.5", "0"]) async throws -> CGImage {
        let ffmpeg = ToolLocator.ffmpegPath
        guard FileManager.default.isExecutableFile(atPath: ffmpeg) else {
            previewLog.notice("ffmpeg preview tier unavailable (no executable at \(ffmpeg, privacy: .public))")
            throw PreviewFrameError.ffmpegUnavailable
        }
        let tmpPNG = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vs_preview_\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmpPNG) }

        for seek in seeks {
            try Task.checkCancellation()
            let rip = await ProcessRunner.runProcess(
                executable: ffmpeg,
                arguments: ["-v", "error",
                            // Input seeking (-ss BEFORE -i): keyframe
                            // seek then decode forward — fast, and
                            // frame-exactness doesn't matter for a
                            // preview thumbnail.
                            "-ss", seek,
                            "-i", path,
                            "-frames:v", "1",
                            // The quotes are ffmpeg filtergraph quoting
                            // (the comma in min() would otherwise split
                            // the graph) — no shell involved here.
                            "-vf", "scale='min(480,iw)':-2",
                            "-y", tmpPNG.path],
                deadlineSeconds: ffmpegPreviewDeadlineSeconds)
            // CANCELLATION, not failure (QA 🔴, 2026-07-26): when the
            // awaiting task is cancelled mid-rip, ProcessRunner's
            // cancellation handler SIGTERMs the child and returns
            // exitCode -1 — indistinguishable from a genuine decode
            // failure by exit code alone. Surface it as CancellationError
            // HERE so a cancelled prewarm can never fall through to
            // noFrameProduced and poison the negative cache against a
            // perfectly good file.
            try Task.checkCancellation()
            // ffmpeg can exit 0 with no frame written (seek past EOF on
            // a very short clip) — the PNG actually decoding is the real
            // success test, hence the load inside the condition.
            if rip.exitCode == 0,
               let data = try? Data(contentsOf: tmpPNG),
               let source = CGImageSourceCreateWithData(data as CFData, nil),
               let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                return cg
            }
            if rip.exitCode != 0 {
                previewLog.notice("ffmpeg preview rip failed (-ss \(seek, privacy: .public)) for \((path as NSString).lastPathComponent, privacy: .public): \(rip.stderr, privacy: .public)")
            }
        }
        throw PreviewFrameError.noFrameProduced
    }

    // MARK: - Best-frame core (background path only)

    /// Content-aware best-frame generation — used by the PREWARM /
    /// background pass only; the interactive path keeps the fast single
    /// 0.5 s frame (renderThumbnailCGImage) for immediate display.
    ///
    /// Rips candidate frames at PreviewBestFramePlan.candidateOffsets
    /// (≤4, planned from the CATALOG duration — never ffprobe here),
    /// scores each with PreviewFrameScorer, returns the winner. When
    /// every candidate is near-solid (wall-to-wall blue leader) it
    /// keeps the 25% frame — a decodable file never downgrades to "no
    /// preview" just because its content is boring. Short/unknown
    /// durations degenerate to the plain single-frame core.
    ///
    /// Cancellation discipline matches the single-frame path: checks
    /// between candidates, CancellationError propagates out untouched so
    /// a cancelled pass can never be recorded as a file failure by the
    /// caller. ffmpegUnavailable also propagates (environment problem —
    /// no point attempting further candidates).
    ///
    /// Memory: at most 4 candidate CGImages at ≤480 wide (~2 MB total)
    /// + one 64×64 scoring buffer, all released on return.
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func renderBestPreviewCGImage(path: String,
                                                     container: String,
                                                     videoCodec: String,
                                                     likelyUnanalyzable: Bool,
                                                     durationSeconds: Double) async throws -> CGImage {
        let offsets = PreviewBestFramePlan.candidateOffsets(durationSeconds: durationSeconds)
        guard offsets.count > 1 else {
            // Short or unknown duration — nothing to choose between.
            return try await renderThumbnailCGImage(path: path,
                                                    container: container,
                                                    videoCodec: videoCodec,
                                                    likelyUnanalyzable: likelyUnanalyzable)
        }

        let route = PreviewFrameRouter.previewRoute(container: container,
                                                    videoCodec: videoCodec,
                                                    likelyUnanalyzable: likelyUnanalyzable)
        var candidates: [(offset: Double, image: CGImage)] = []

        if route == .avFoundation {
            // One asset open, all candidate times in one batch request.
            // Batch errors are swallowed (not thrown): the ffmpeg loop
            // below is the arbiter, mirroring the single-frame tier
            // order (AVF → one ffmpeg attempt).
            candidates = (try? await renderCandidateFramesViaAVFoundation(path: path,
                                                                          offsets: offsets)) ?? []
            // The batch is deadline-bounded, not cancellation-
            // interruptible — surface a cancel that arrived mid-batch
            // NOW, before any caching happens.
            try Task.checkCancellation()
        }

        if candidates.isEmpty {
            // ffmpeg-routed files, or the AVF batch produced nothing.
            // One single-frame rip per candidate offset; a dry offset
            // (seek past EOF) just drops out of the lineup.
            for offset in offsets {
                try Task.checkCancellation()
                do {
                    let image = try await renderPreviewFrameViaFFmpeg(
                        path: path,
                        seeks: [String(format: "%.2f", offset)])
                    candidates.append((offset, image))
                } catch {
                    if error is CancellationError
                        || (error as? PreviewFrameError) == .ffmpegUnavailable {
                        throw error
                    }
                    continue
                }
            }
        }

        guard !candidates.isEmpty else {
            // No candidate decoded at all — hand the file to the plain
            // single-frame core, whose 0.5 s + t=0 retry ladder is the
            // final word before the caller records a failure.
            return try await renderThumbnailCGImage(path: path,
                                                    container: container,
                                                    videoCodec: videoCodec,
                                                    likelyUnanalyzable: likelyUnanalyzable)
        }

        let scores = candidates.map { PreviewFrameScorer.score($0.image)?.combined ?? 0 }
        let chosen = PreviewBestFramePlan.chooseIndex(
            scores: scores,
            offsets: candidates.map(\.offset),
            fallbackOffset: PreviewBestFramePlan.fallbackOffset(durationSeconds: durationSeconds),
            threshold: PreviewFrameScorer.nearSolidThreshold) ?? 0
        previewLog.debug("best-frame pick t=\(String(format: "%.1f", candidates[chosen].offset), privacy: .public)s (score \(String(format: "%.3f", scores[chosen]), privacy: .public), \(candidates.count) candidates) — \((path as NSString).lastPathComponent, privacy: .public)")
        return candidates[chosen].image
    }

    /// AVF candidate rips for the best-frame pass: all offsets from ONE
    /// AVURLAsset via generateCGImagesAsynchronously(forTimes:) — the
    /// asset open (the expensive part) is paid once, and per-time
    /// keyframe rips are cheap. Shares the single-frame tier's deadline
    /// watchdog: at the deadline, cancelAllCGImageGeneration completes
    /// every outstanding time's callback as cancelled, the collector's
    /// countdown hits zero, and the await resumes with whatever frames
    /// landed in time (possibly none — caller falls through to ffmpeg).
    private nonisolated static func renderCandidateFramesViaAVFoundation(
        path: String,
        offsets: [Double]) async throws -> [(offset: Double, image: CGImage)] {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 270)

        let box = AVFDeadlineBox(generator)
        let deadline = avfPreviewDeadlineSeconds
        let watchdog = Task {
            try await Task.sleep(for: .seconds(deadline))
            box.fireDeadline()
        }
        defer { watchdog.cancel() }

        let times = offsets.map { NSValue(time: CMTime(seconds: $0, preferredTimescale: 600)) }
        let collector = AVFCandidateCollector(expecting: times.count)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            box.generator.generateCGImagesAsynchronously(forTimes: times) { requestedTime, image, _, _, _ in
                // requestedTime round-trips through CMTime ticks, so it
                // is only ≈ the planned offset — downstream matching
                // (fallback pick) uses a tolerance for exactly this.
                if collector.record(offset: requestedTime.seconds, image: image) {
                    cont.resume()
                }
            }
        }
        if box.deadlineFired {
            previewLog.notice("AVFoundation candidate batch timed out (\(Int(deadline))s) — \((path as NSString).lastPathComponent, privacy: .public): \(collector.collected.count)/\(times.count) frames kept")
        }
        return collector.collected
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

        previewFilename = record.filename

        // Cache hit → immediate, no debounce, no file I/O.
        let cacheKey = record.fullPath as NSString
        if let cached = thumbnailCache.object(forKey: cacheKey) {
            previewRequestPath = record.fullPath
            previewImage = cached
            previewOfflineVolumeName = nil
            previewUnavailable = false
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

        previewFilename = record.filename
        previewRequestPath = record.fullPath

        // Check cache first — works even when the source volume is offline.
        let cacheKey = record.fullPath as NSString
        if let cached = thumbnailCache.object(forKey: cacheKey) {
            previewImage = cached
            previewOfflineVolumeName = nil
            previewUnavailable = false
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
                }
                return
            }
            do {
                let cgImage = try await VideoScanModel.renderThumbnailCGImage(
                    path: cacheKeyString,
                    container: container,
                    videoCodec: videoCodec,
                    likelyUnanalyzable: likelyUnanalyzable)
                // Write-through L2 first (already off-main here). Tier
                // "fast": this is the interactive single 0.5 s frame —
                // the background pass may later upgrade it to "best".
                // Signature from BEFORE generation is correct: the key
                // must describe the file we just decoded.
                if let signature {
                    diskCache.store(cgImage,
                                    path: cacheKeyString,
                                    mtime: signature.mtime,
                                    size: signature.size,
                                    tier: .fast)
                }
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
