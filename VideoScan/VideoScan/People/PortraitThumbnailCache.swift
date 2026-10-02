import AppKit
import ImageIO

/// Small, cached portrait thumbnails for card grids.
///
/// 2026-10-02 (Rick: "the app is responding in a glacial manner"): a sample
/// of the People tab showed ~60% of the main thread inside SwiftUI resolving
/// full-size portraits — `NSImage(contentsOf:)` in `PersonCard.body`, so every
/// card re-decoded an iPhone HEIC on every render, and HDR (gain-map / PQ)
/// photos were tone-mapped through ColorSync each time. Cards draw at ~100 pt;
/// a bounded ImageIO thumbnail (SDR, orientation applied) decoded once and
/// kept in an NSCache is all they need. Crop scale/offset are in view points,
/// so a smaller bitmap keeps the same framing.
enum PortraitThumbnailCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 600
        return c
    }()

    /// A thumbnail at most `maxPixels` on the long side, or nil if the file
    /// can't be read. Keyed by path + modification date + size, so an edited
    /// photo refreshes.
    static func thumbnail(at url: URL, maxPixels: Int = 512) -> NSImage? {
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(mtime)|\(maxPixels)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let cg = CropRenderer.boundedImage(at: url, maxPixels: maxPixels) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(image, forKey: key)
        return image
    }
}
