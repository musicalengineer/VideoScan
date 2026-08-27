// CropRendererMemoryTests.swift
// SENSOR for codex #707 item 6 (2026-08-26): "Adjust Photo…" used to build a
// full NSImage, then an unbounded `tiffRepresentation`, on the main actor
// before bounding to 2048 px. An 8000×6000 scan is ≈ 190 MB as a bitmap and
// more as a TIFF. The decode now goes straight from the source (URL or
// Data) through ImageIO's thumbnail path, so the largest bitmap that ever
// exists is the ≤ 2048 px one.
//
// Dimensions per the feature-test checklist:
//   Scale     — a generated 8000×6000 fixture (test_ prefix, CoreGraphics)
//   Sensor    — RSS delta across the decode < 150 MB, output ≤ 2048 px
//   Grep      — the view/sheet sources contain no NSImage/TIFF decode path

import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import VideoScan

@Suite("Crop renderer — bounded decode of a huge scan", .serialized)
struct CropRendererMemoryTests {

    /// Writes an 8000×6000 JPEG. The 192 MB context used to paint it is
    /// released before the test measures anything.
    private func makeHugeFixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_crop_renderer_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("test_scan_8000x6000.jpg")
        let width = 8000, height = 6000
        let data = try autoreleasepool { () throws -> Data in
            let context = try #require(CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            // Two flat regions so the crop test below can tell top from bottom.
            context.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
            context.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1))
            context.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))
            let image = try #require(context.makeImage())
            return try #require(CropRenderer.jpegData(image, quality: 0.6))
        }
        try data.write(to: url)
        return url
    }

    @Test func anEightThousandPixelScanDecodesBoundedWithoutAMemorySpike() throws {
        let url = try makeHugeFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let before = processResidentMemoryMB()
        let image = try #require(CropRenderer.boundedImage(at: url))
        // Touch the pixels so a lazily-backed image is really materialised
        // before the after-measurement.
        var geometry = CropGeometry(
            viewport: CGSize(width: 300, height: 300),
            imageSize: CGSize(width: image.width, height: image.height))
        geometry.setZoom(1)
        let cropped = try #require(geometry.cropped(image, maxPixels: 1024))
        let after = processResidentMemoryMB()

        #expect(max(image.width, image.height) == 2048,
                "bounded decode, got \(image.width)×\(image.height)")
        #expect(image.width == 2048 && image.height == 1536)
        #expect(cropped.width == 1024 && cropped.height == 1024)
        let delta = after - before
        #expect(delta < 150, "RSS grew \(delta) MB decoding an 8000×6000 scan")
    }

    @Test func dataPathIsBoundedToo() throws {
        // Apple Photos hands us Data, not a URL.
        let url = try makeHugeFixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let data = try Data(contentsOf: url)
        let before = processResidentMemoryMB()
        let image = try #require(CropRenderer.boundedImage(data: data))
        let after = processResidentMemoryMB()
        #expect(max(image.width, image.height) == 2048)
        #expect(after - before < 150, "RSS grew \(after - before) MB")
    }

    /// Grep sensor: the presenting view and the sheet must not reintroduce
    /// the NSImage → TIFF → decode path.
    @Test func adjustPhotoSourcesContainNoUnboundedDecode() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()            // VideoScanTests
            .deletingLastPathComponent()            // VideoScan (project dir)
            .appendingPathComponent("VideoScan", isDirectory: true)
        for name in ["FamilyTreeDemoView.swift", "FamilyPhotoAdjustSheet.swift", "CropGeometry.swift"] {
            let text = try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
            for forbidden in ["tiffRepresentation", "NSImage(contentsOf", "NSImage(data", "NSBitmapImageRep(data"] {
                #expect(!text.contains(forbidden), "\(name) uses \(forbidden) — decode must go through CropRenderer.boundedImage")
            }
        }
        // And the sheet saves through the injected store, not the shared center.
        let sheet = try String(contentsOf: sources.appendingPathComponent("FamilyPhotoAdjustSheet.swift"), encoding: .utf8)
        #expect(!sheet.contains("FamilyAssetConfigurationCenter.shared"),
                "FamilyPhotoAdjustSheet must save through source.store (codex #707 / 11)")
    }
}
