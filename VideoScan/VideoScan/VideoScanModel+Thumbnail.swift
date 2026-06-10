import Foundation
import AVFoundation
import AppKit
import CoreMedia

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
// runFFProbe is a thin convenience that any extension may want — kept
// nearby because both generateThumbnail and ffprobe live in the "preview /
// quick peek at one file" mental bucket.

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

    /// Shared single-frame thumbnail core: one CGImage at t=0.5s, capped
    /// at 480x270. Used by the interactive path (generateThumbnail) and
    /// the volume-click prewarm (ThumbnailPrecacher). Never loads more
    /// than one frame per call.
    ///
    /// `@concurrent`: under Approachable Concurrency a plain `nonisolated
    /// async` runs on its CALLER's actor — today's callers are both
    /// detached tasks (safe), but a future main-actor caller would
    /// silently pull AVAsset open/decode onto the UI thread. Pin it to
    /// the global pool. (Same trap QA caught in MediaPairComparator.)
    @concurrent
    nonisolated static func renderThumbnailCGImage(path: String) async throws -> CGImage {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 270)

        let time = CMTime(seconds: 0.5, preferredTimescale: 600)
        return try await withCheckedThrowingContinuation { cont in
            generator.generateCGImageAsynchronously(for: time) { image, _, error in
                if let image {
                    cont.resume(returning: image)
                } else {
                    cont.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                }
            }
        }
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
            return
        }

        // Mark this as the current request so a slower, earlier generation
        // that lands later can't overwrite the newer selection's preview.
        previewRequestPath = record.fullPath

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
            return
        }

        // If the source volume isn't mounted, don't try to read the file —
        // surface a clean "Volume Offline" placeholder instead of stalling.
        // (This selection has no thumbnail at all, so clearing is correct.)
        if !VolumeReachability.isReachable(path: record.fullPath) {
            previewImage = nil
            previewOfflineVolumeName = VolumeReachability.volumeName(forPath: record.fullPath)
            return
        }
        previewOfflineVolumeName = nil

        // Capture the cache key as Sendable String, not NSString. Re-bridge
        // inside the MainActor block where the NSCache lives.
        let cacheKeyString = record.fullPath
        Task.detached { [weak self] in
            do {
                let cgImage = try await VideoScanModel.renderThumbnailCGImage(path: cacheKeyString)
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
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    // Generation failed for the CURRENT selection → showing
                    // the previous file's frame would be wrong; clear it.
                    if self.previewRequestPath == cacheKeyString {
                        self.previewImage = nil
                    }
                }
            }
        }
    }
}
