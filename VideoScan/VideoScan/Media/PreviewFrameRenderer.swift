import Foundation
import AVFoundation
import AppKit
import CoreMedia
import ImageIO
import os

// MARK: - Preview frame rendering (was VideoScanModel+Thumbnail.swift)
//
// GH #337 slice 1 (2026-10-19): the static frame-rip cores moved here
// verbatim; the preview pane's state and entry points (generateThumbnail,
// the caches, the debounce) moved to PreviewService. VideoScanModel keeps
// static forwarders (VideoScanModel.renderThumbnailCGImage etc.) so every
// caller compiles unchanged.
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
//     also used by ThumbnailPrecacher (Part 3 prewarm). (The debounce,
//     cache-cost and no-flash notes now head PreviewService.swift.)
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
//   - Failures land in PreviewService's ThumbnailFailureStore (negative
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
// Filmstrip preview (2026-07-27):
//   - renderPreviewFilmstrip — multi-frame strip for the preview pane's
//     filmstrip mode (AVPlayer-unplayable formats: MKV/FFV1 etc.).
//     Offsets planned by PreviewFilmstripPlan from the catalog duration,
//     ripped via the same routed tiers as above (bounded-concurrency
//     ffmpeg for ffmpegDirect, one-asset batch for avFoundation),
//     near-solid frames dropped by PreviewFrameScorer. Orchestration
//     lives in PreviewService+Filmstrip.swift; persistent strips in
//     PreviewDiskCache's -strip- payloads.
//
// runFFProbe (the ffprobe convenience that used to sit here) moved into
// VideoScanModel.swift beside `ffprobePath`, the state it reads.

/// File-scope (a holdover from when these were statics on the @MainActor model) so the detached
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

/// Result of a filmstrip render (filmstrip preview, 2026-07-27): the
/// POST-selection frames — near-solid leaders already dropped by
/// PreviewFilmstripPlan.selectFrames — ordered by offset. CGImage is
/// Sendable (immutable), so whole strips can cross out of the
/// `@concurrent` renderer.
struct PreviewFilmstrip: Sendable {
    struct Frame: Sendable {
        let offsetSeconds: Double
        let image: CGImage
    }
    let frames: [Frame]
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

/// The nonisolated frame-rip cores behind the preview pane, the
/// volume-click precacher and the background sweep (GH #337 slice 1:
/// moved verbatim off VideoScanModel, which keeps static forwarders).
/// A caseless enum ≈ a C++ namespace: statics only, never instantiated.
enum PreviewFrameRenderer {

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
                                                                seeks: [String] = ["0.5", "0"],
                                                                ffmpegPath: String = ToolLocator.ffmpegPath) async throws -> CGImage {
        // The ffmpeg-subprocess-to-CGImage core now lives in VideoScanCore
        // (`ffmpegRipPreviewFrame`, 2026-07-28 Stage 1) so the app and the
        // out-of-process CLI helper share ONE ffmpeg invocation. This
        // forwarder maps the Core error type back onto the app's
        // PreviewFrameError so every existing caller and media-matrix test
        // sees the identical contract. `ffmpegPath` stays injectable so the
        // filmstrip tests can prove the AVFoundation arm produced the frames
        // (a bogus path here throws ffmpegUnavailable rather than quietly
        // passing, codex 2026-07-27).
        do {
            return try await ffmpegRipPreviewFrame(
                path: path,
                seeks: seeks,
                ffmpegPath: ffmpegPath,
                maxDimension: PreviewDiskCache.maxPayloadDimension,
                deadlineSeconds: ffmpegPreviewDeadlineSeconds)
        } catch let error as FFmpegPreviewError {
            switch error {
            case .ffmpegUnavailable: throw PreviewFrameError.ffmpegUnavailable
            case .noFrameProduced: throw PreviewFrameError.noFrameProduced
            }
        }
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

    /// Candidate offsets → unique CMTime batch requests (timescale
    /// 600), order preserved. Two planned offsets that quantize to the
    /// same tick value collapse to ONE request — see the callsite
    /// comment for why the collector's liveness depends on this.
    /// Internal (not private) so tests can pin the dedupe.
    nonisolated static func dedupedCandidateTimes(offsets: [Double]) -> [NSValue] {
        var seen = Set<CMTimeValue>()
        var times: [NSValue] = []
        for offset in offsets {
            let time = CMTime(seconds: offset, preferredTimescale: 600)
            if seen.insert(time.value).inserted {
                times.append(NSValue(time: time))
            }
        }
        return times
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

        // Dedupe on the CMTimeValue actually requested (QA 🟡,
        // 2026-07-26): the collector's countdown assumes one callback
        // per requested time. Today's planner can't emit offsets that
        // collide at timescale-600 resolution, but if a future tweak
        // did and AVF coalesced the duplicate request, `remaining`
        // would never reach zero and the checked continuation would
        // hang the prewarm worker forever. Sizing the collector from
        // the DEDUPED times makes that impossible structurally.
        let times = Self.dedupedCandidateTimes(offsets: offsets)
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

    // MARK: - Filmstrip core (filmstrip preview, 2026-07-27)

    /// Bounded ffmpeg concurrency for filmstrip rips: 4 single-frame
    /// children in flight at once (matches the caption ripper's and the
    /// planner's SSD default — an FFV1 master decode is CPU-bound, and
    /// 4 keeps the strip fast without starving an active scan).
    nonisolated static let filmstripFFmpegConcurrency = 4

    /// Multi-frame filmstrip render for the catalog preview pane's
    /// filmstrip mode (the play-button path for AVPlayer-unplayable
    /// formats). Rips ≤`frameCount` frames at
    /// PreviewFilmstripPlan.offsets (planned from the CATALOG duration —
    /// never ffprobe at preview time), scores each
    /// (PreviewFrameScorer), and drops near-solid leaders via
    /// PreviewFilmstripPlan.selectFrames.
    ///
    /// Route-agnostic by design even though today's only caller is
    /// ffmpegDirect-routed: `.avFoundation` records reuse the
    /// best-frame pass's one-asset batch generator, `.ffmpegDirect`
    /// records rip per-offset with bounded concurrency
    /// (`filmstripFFmpegConcurrency`). Per-frame failures are tolerated
    /// (a dry offset just drops out of the strip); the call throws only
    /// when ALL frames fail (noFrameProduced), ffmpeg is missing
    /// entirely (ffmpegUnavailable), or the task is cancelled.
    ///
    /// Cancellation discipline matches the single-frame path:
    /// CancellationError propagates untouched so callers can never
    /// record a cancelled run as a file failure (the cache-poison class
    /// PreviewCachePoisonSensorTests pins).
    ///
    /// `onFrameProgress(done, total)` fires after each rip attempt
    /// lands (kept or dropped) — honest progress for the pane's
    /// "Extracting frame N of M…". Called from the rendering executor;
    /// callers hop to the main actor themselves.
    ///
    /// Memory: worst case `frameCount` (16) candidate CGImages at ≤480
    /// wide (~8 MB) + one 64×64 scoring buffer per frame
    /// (autoreleasepool'd) + `filmstripFFmpegConcurrency` transient
    /// ffmpeg children, all released on return.
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func renderPreviewFilmstrip(path: String,
                                                   container: String,
                                                   videoCodec: String,
                                                   likelyUnanalyzable: Bool,
                                                   durationSeconds: Double,
                                                   frameCount: Int = PreviewFilmstripPlan.defaultFrameCount,
                                                   ffmpegPath: String = ToolLocator.ffmpegPath,
                                                   onFrameProgress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> PreviewFilmstrip {
        let offsets = PreviewFilmstripPlan.offsets(durationSeconds: durationSeconds,
                                                   frameCount: frameCount)
        guard !offsets.isEmpty else {
            // Unknown/garbage duration — a one-frame "strip" from the
            // plain single-frame ladder beats nothing (same degeneration
            // rule as renderBestPreviewCGImage's short-file path).
            // 0.5 s is the ladder's primary seek, so that's the honest
            // timestamp label.
            let image = try await renderThumbnailCGImage(path: path,
                                                         container: container,
                                                         videoCodec: videoCodec,
                                                         likelyUnanalyzable: likelyUnanalyzable)
            onFrameProgress?(1, 1)
            return PreviewFilmstrip(frames: [.init(offsetSeconds: 0.5, image: image)])
        }

        let route = PreviewFrameRouter.previewRoute(container: container,
                                                    videoCodec: videoCodec,
                                                    likelyUnanalyzable: likelyUnanalyzable)
        var candidates: [(offset: Double, image: CGImage)] = []

        if route == .avFoundation {
            // One asset open, all offsets in one batch — same swallow-
            // then-arbitrate shape as renderBestPreviewCGImage: an AVF
            // batch failure falls through to the ffmpeg loop below.
            candidates = (try? await renderCandidateFramesViaAVFoundation(path: path,
                                                                          offsets: offsets)) ?? []
            try Task.checkCancellation()
            if !candidates.isEmpty {
                onFrameProgress?(offsets.count, offsets.count)
            }
        }

        if candidates.isEmpty {
            candidates = try await ripFilmstripFramesViaFFmpeg(path: path,
                                                               offsets: offsets,
                                                               ffmpegPath: ffmpegPath,
                                                               onFrameProgress: onFrameProgress)
        }

        guard !candidates.isEmpty else {
            previewLog.notice("filmstrip: no frame decoded at any offset — \((path as NSString).lastPathComponent, privacy: .public)")
            throw PreviewFrameError.noFrameProduced
        }

        // TaskGroup children land out of order — restore timeline order
        // before scoring so selectFrames' index math and the UI's
        // scrubber both see a monotonic strip.
        candidates.sort { $0.offset < $1.offset }
        try Task.checkCancellation()

        var scores: [PreviewFrameScorer.FrameScore?] = []
        scores.reserveCapacity(candidates.count)
        for candidate in candidates {
            // autoreleasepool per scored frame — media-loop memory rule.
            autoreleasepool {
                scores.append(PreviewFrameScorer.score(candidate.image))
            }
        }
        let kept = PreviewFilmstripPlan.selectFrames(scores: scores)
        let frames = kept.map {
            PreviewFilmstrip.Frame(offsetSeconds: candidates[$0].offset,
                                   image: candidates[$0].image)
        }
        previewLog.debug("filmstrip: \(frames.count)/\(candidates.count) frames kept (\(offsets.count) planned) — \((path as NSString).lastPathComponent, privacy: .public)")
        return PreviewFilmstrip(frames: frames)
    }

    /// ffmpeg filmstrip rips: one single-frame child per offset, at
    /// most `filmstripFFmpegConcurrency` in flight (sliding-window task
    /// group — same shape as ThumbnailPrecacher's window; no 16
    /// suspended children up front, and cancellation drains within one
    /// window). Per-frame decode failures return nil and drop out;
    /// CancellationError and ffmpegUnavailable abort the group (the
    /// throwing group cancels the remaining children for us).
    private nonisolated static func ripFilmstripFramesViaFFmpeg(
        path: String,
        offsets: [Double],
        ffmpegPath: String = ToolLocator.ffmpegPath,
        onFrameProgress: (@Sendable (Int, Int) -> Void)?) async throws -> [(offset: Double, image: CGImage)] {
        let total = offsets.count
        var collected: [(offset: Double, image: CGImage)] = []
        collected.reserveCapacity(total)
        var attempted = 0

        @Sendable func ripOne(_ offset: Double) async throws -> (Double, CGImage)? {
            do {
                let image = try await renderPreviewFrameViaFFmpeg(
                    path: path,
                    seeks: [String(format: "%.3f", offset)],
                    ffmpegPath: ffmpegPath)
                return (offset, image)
            } catch {
                // Tolerated per-frame failure (seek past EOF, decoder
                // hiccup) — the frame just drops out of the lineup.
                // Cancellation and a missing ffmpeg binary are about
                // the RUN, not the frame: rethrow.
                if error is CancellationError
                    || (error as? PreviewFrameError) == .ffmpegUnavailable {
                    throw error
                }
                return nil
            }
        }

        try await withThrowingTaskGroup(of: (Double, CGImage)?.self) { group in
            var iterator = offsets.makeIterator()
            // Prime the window; after that, one-in-one-out in the drain
            // loop keeps at most `filmstripFFmpegConcurrency` children
            // in flight — no counter needed (QA nit 2026-07-27: the
            // post-fill inFlight bookkeeping was dead).
            for _ in 0..<filmstripFFmpegConcurrency {
                guard let next = iterator.next() else { break }
                group.addTask { try await ripOne(next) }
            }
            while let landed = try await group.next() {
                attempted += 1
                if let landed { collected.append((landed.0, landed.1)) }
                onFrameProgress?(attempted, total)
                try Task.checkCancellation()
                if let next = iterator.next() {
                    group.addTask { try await ripOne(next) }
                }
            }
        }
        return collected
    }
}
