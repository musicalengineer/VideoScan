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
// runFFProbe is a thin convenience that any extension may want — kept
// nearby because both generateThumbnail and ffprobe live in the "preview /
// quick peek at one file" mental bucket.

extension VideoScanModel {

    nonisolated func runFFProbe(url: URL) async -> (output: FFProbeOutput?, stderr: String) {
        await CombineVerifier.runFFProbe(url: url, ffprobePath: ffprobePath)
    }

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
}
