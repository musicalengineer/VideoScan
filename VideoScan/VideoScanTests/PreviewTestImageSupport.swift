// PreviewTestImageSupport.swift
// Synthetic CGImage fixtures shared by the preview disk-cache and
// frame-scorer test suites (perf/preview-disk-cache, 2026-07-26).
// Pure CoreGraphics — no files, no media, deterministic (seeded LCG for
// the noise generators, so a "static" image is bit-identical run to run).

import Foundation
import CoreGraphics

enum PreviewTestImages {

    /// Solid single-color frame — the "blue VHS leader" stand-in.
    static func solid(red: CGFloat, green: CGFloat, blue: CGFloat,
                      width: Int = 480, height: Int = 270) -> CGImage {
        let ctx = rgbaContext(width: width, height: height)
        ctx.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    /// Per-pixel independent grayscale noise — analog "snow" static.
    /// Seeded LCG (same recurrence as C++'s std::minstd-style generators
    /// scaled up to 64-bit) so results are deterministic.
    static func grayNoise(seed: UInt64, width: Int = 480, height: Int = 270) -> CGImage {
        var state = seed
        var data = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let v = UInt8(truncatingIfNeeded: state >> 33)
            data[i * 4] = v; data[i * 4 + 1] = v; data[i * 4 + 2] = v
        }
        return image(fromRGBA: data, width: width, height: height)
    }

    /// Per-pixel independent RGB noise — "colored static".
    static func rgbNoise(seed: UInt64, width: Int = 480, height: Int = 270) -> CGImage {
        var state = seed
        func next() -> UInt8 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return UInt8(truncatingIfNeeded: state >> 33)
        }
        var data = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            data[i * 4] = next(); data[i * 4 + 1] = next(); data[i * 4 + 2] = next()
        }
        return image(fromRGBA: data, width: width, height: height)
    }

    /// Two-tone split frame — the simplest thing that reads as "a scene":
    /// real luma structure AND two distinct colors.
    static func twoTone(width: Int = 480, height: Int = 270) -> CGImage {
        let ctx = rgbaContext(width: width, height: height)
        ctx.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.6, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: 0.9, green: 0.8, blue: 0.3, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        return ctx.makeImage()!
    }

    /// Smooth two-axis color gradient — structure without hard edges.
    static func gradient(width: Int = 480, height: Int = 270) -> CGImage {
        var data = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                data[i] = UInt8(x * 255 / max(1, width - 1))
                data[i + 1] = UInt8(y * 255 / max(1, height - 1))
                data[i + 2] = 128
            }
        }
        return image(fromRGBA: data, width: width, height: height)
    }

    /// Average RGB over the whole image (0–255 per channel) — used to
    /// verify "the payload that came back is (still) the blue one"
    /// through a JPEG round trip without pixel-exact comparison.
    static func meanRGB(_ image: CGImage) -> (r: Double, g: Double, b: Double) {
        let w = image.width, h = image.height
        let ctx = rgbaContext(width: w, height: h)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var r = 0.0, g = 0.0, b = 0.0
        for i in 0..<(w * h) {
            r += Double(px[i * 4]); g += Double(px[i * 4 + 1]); b += Double(px[i * 4 + 2])
        }
        let n = Double(w * h)
        return (r / n, g / n, b / n)
    }

    // MARK: - Internals

    private static func rgbaContext(width: Int, height: Int) -> CGContext {
        CGContext(data: nil, width: width, height: height,
                  bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    private static func image(fromRGBA data: [UInt8], width: Int, height: Int) -> CGImage {
        let provider = CGDataProvider(data: Data(data) as CFData)!
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)!
    }
}
