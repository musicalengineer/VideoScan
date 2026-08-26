// CropGeometry.swift
// Pure crop math for "Adjust Photo…" on the Family Tree card (Rick
// 2026-08-26: centre + crop the portrait without touching the original).
//
// Model: the image is scaled so it FILLS the viewport (`zoom == 1` ≈
// SwiftUI's `.scaledToFill()`), may be zoomed in further, and panned by
// `offset` (viewport points). Pan is clamped so the viewport never shows
// past the image edge, zoom is clamped to [1, 6]. `sourceRect` is the
// viewport expressed in image pixels — what `CGImage.cropping(to:)` needs.
//
// Value type, no SwiftUI, no I/O: the sheet mutates a copy per gesture and
// the save path calls `cropped(_:maxPixels:)` once. Nothing here runs in
// a view body except reading `displayedSize` / `clampedOffset`.
//
// Memory: the source CGImage is bounded to 2048 px on the long side before
// it reaches this type (≈ 16 MB decoded); the output is ≤ 1024 px (≈ 4 MB).

import CoreGraphics
import Foundation
import ImageIO

struct CropGeometry: Equatable {
    static let minZoom: CGFloat = 1
    static let maxZoom: CGFloat = 6

    /// The crop window, in points. Square for the card's circular portrait.
    var viewport: CGSize
    /// Source image size in pixels.
    var imageSize: CGSize
    /// 1 = fill the viewport exactly; larger = zoomed in. Always clamped.
    private(set) var zoom: CGFloat = 1
    /// Pan of the image centre from the viewport centre, in viewport
    /// points. Positive x moves the image right (reveals its left side).
    private(set) var offset: CGSize = .zero

    init(viewport: CGSize, imageSize: CGSize, zoom: CGFloat = 1, offset: CGSize = .zero) {
        self.viewport = viewport
        self.imageSize = imageSize
        setZoom(zoom)
        setOffset(offset)
    }

    var isValid: Bool {
        viewport.width > 0 && viewport.height > 0
            && imageSize.width > 0 && imageSize.height > 0
    }

    /// Scale at which the image just covers the viewport (points / pixel).
    var fillScale: CGFloat {
        guard isValid else { return 1 }
        return max(viewport.width / imageSize.width, viewport.height / imageSize.height)
    }

    /// Points per image pixel at the current zoom.
    var displayScale: CGFloat { fillScale * zoom }

    /// On-screen size of the whole image at the current zoom.
    var displayedSize: CGSize {
        CGSize(width: imageSize.width * displayScale, height: imageSize.height * displayScale)
    }

    /// How far the image may be panned in each direction before an edge
    /// would show. Zero on an axis where the image exactly fits.
    var maxOffset: CGSize {
        let displayed = displayedSize
        return CGSize(width: max(0, (displayed.width - viewport.width) / 2),
                      height: max(0, (displayed.height - viewport.height) / 2))
    }

    /// `offset` is always kept inside ±`maxOffset`; exposed by this name
    /// so call sites read naturally.
    var clampedOffset: CGSize { offset }

    // MARK: Mutation

    mutating func setZoom(_ value: CGFloat) {
        let clean = value.isFinite ? value : 1
        zoom = min(max(clean, Self.minZoom), Self.maxZoom)
        setOffset(offset)   // a zoom-out can leave the old pan out of range
    }

    mutating func setOffset(_ value: CGSize) {
        let limit = maxOffset
        let x = value.width.isFinite ? value.width : 0
        let y = value.height.isFinite ? value.height : 0
        offset = CGSize(width: min(max(x, -limit.width), limit.width),
                        height: min(max(y, -limit.height), limit.height))
    }

    /// Pan relative to a starting offset (drag gesture: start + translation).
    mutating func pan(from start: CGSize, by translation: CGSize) {
        setOffset(CGSize(width: start.width + translation.width,
                         height: start.height + translation.height))
    }

    /// "Center" button: fill the viewport, image centred.
    mutating func center() {
        zoom = 1
        offset = .zero
    }

    // MARK: Output

    /// The viewport in image-pixel coordinates (origin top-left, like
    /// `CGImage.cropping(to:)`), rounded to whole pixels and clamped to
    /// the image bounds. Empty when the geometry is invalid.
    var sourceRect: CGRect {
        guard isValid else { return .zero }
        let scale = displayScale
        let displayed = displayedSize
        // Viewport's top-left corner relative to the image's top-left, in
        // points: the image is centred then shifted by `offset`.
        let originX = (displayed.width - viewport.width) / 2 - offset.width
        let originY = (displayed.height - viewport.height) / 2 - offset.height
        // Round origin and size separately: `.integral` would grow a rect
        // whose origin lands on a half pixel (187.5 → 187…313 = 126 wide).
        let rect = CGRect(x: (originX / scale).rounded(), y: (originY / scale).rounded(),
                          width: (viewport.width / scale).rounded(),
                          height: (viewport.height / scale).rounded())
            .intersection(CGRect(origin: .zero, size: imageSize))
        return rect.isNull ? .zero : rect
    }

    /// Pixel size of the saved crop: the source rect, scaled down (never
    /// up) so the long side is at most `maxPixels`.
    func outputSize(maxPixels: Int) -> CGSize {
        let rect = sourceRect
        guard rect.width > 0, rect.height > 0, maxPixels > 0 else { return .zero }
        let longSide = max(rect.width, rect.height)
        let factor = min(1, CGFloat(maxPixels) / longSide)
        return CGSize(width: max(1, (rect.width * factor).rounded()),
                      height: max(1, (rect.height * factor).rounded()))
    }

    /// Crop `image` (which must be the image `imageSize` describes) to the
    /// viewport and downscale to ≤ `maxPixels`. Pure CoreGraphics; call it
    /// once on Save, never per frame.
    func cropped(_ image: CGImage, maxPixels: Int = 1024) -> CGImage? {
        guard CGFloat(image.width) == imageSize.width,
              CGFloat(image.height) == imageSize.height else { return nil }
        let rect = sourceRect
        guard rect.width >= 1, rect.height >= 1,
              let slice = image.cropping(to: rect) else { return nil }
        let target = outputSize(maxPixels: maxPixels)
        guard target.width > 0, target.height > 0 else { return nil }
        if Int(target.width) == slice.width, Int(target.height) == slice.height {
            return slice
        }
        // `CGContext` ≈ an offscreen bitmap; drawing the slice into it at a
        // smaller size is the resample.
        guard let context = CGContext(
            data: nil, width: Int(target.width), height: Int(target.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(slice, in: CGRect(origin: .zero, size: target))
        return context.makeImage()
    }
}

/// Encoding + bounded decoding helpers around the geometry (ImageIO only).
enum CropRenderer {
    /// Decoded, orientation-applied, at most `maxPixels` on the long side —
    /// the bound that keeps a phone HEIC from becoming a 100 MB bitmap.
    static func boundedImage(at url: URL, maxPixels: Int = 2048) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return boundedImage(from: source, maxPixels: maxPixels)
    }

    static func boundedImage(data: Data, maxPixels: Int = 2048) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return boundedImage(from: source, maxPixels: maxPixels)
    }

    private static func boundedImage(from source: CGImageSource, maxPixels: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// JPEG bytes at the given quality (0.9 for card photos).
    static func jpegData(_ image: CGImage, quality: Double = 0.9) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(
            destination, image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
