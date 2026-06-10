import Testing
import Foundation
import AppKit
import CoreImage
import CoreGraphics
@testable import VideoScan

// MARK: - FrameRipper tests (Rick 2026-06-09)
//
// FrameRipper has two pure-static surfaces we can hammer with unit tests:
//
//   - makeFilename(rank:timestamp:score:) — the saved filename format.
//   - writePNG(image:to:) — the lossless export.
//
// scoreFace(in:) requires a real CGImage with a face; we test it via a
// synthetic image (a face would need a fixture pipeline that's overkill
// for what's effectively wrapping a Vision API call). The scoring
// MATH is testable separately by passing through known shape signals.
//
// The rip pipeline itself (sample → score → save) is an integration
// test territory that would need a fixture video. We deliberately skip
// that — it's gated by AVAsset I/O and the cost of bundling a fixture
// outweighs the bug-catching value for what's mostly orchestration.

@Suite("FrameRipper")
struct FrameRipperTests {

    // MARK: - Filename format

    @Test func filenameSortsByRank() {
        // The leading rank field must zero-pad to 2 digits so Finder's
        // alphabetic sort matches the score ranking.
        let f1 = FrameRipper.makeFilename(rank: 1, timestamp: 0, score: 0.5)
        let f9 = FrameRipper.makeFilename(rank: 9, timestamp: 0, score: 0.5)
        let f10 = FrameRipper.makeFilename(rank: 10, timestamp: 0, score: 0.5)
        // Alphabetic sort should give 01, 09, 10 — not 1, 10, 9.
        #expect(f1 < f9)
        #expect(f9 < f10)
    }

    @Test func filenameEmbedsTimestamp() {
        let f = FrameRipper.makeFilename(rank: 1, timestamp: 102, score: 0.5)
        // 102 seconds = 1 min 42 sec
        #expect(f.contains("t01m42s"),
                "Expected timestamp embedded as 't01m42s', got \(f)")
    }

    @Test func filenameEmbedsQuality() {
        let f50 = FrameRipper.makeFilename(rank: 1, timestamp: 0, score: 0.5)
        let f87 = FrameRipper.makeFilename(rank: 1, timestamp: 0, score: 0.87)
        #expect(f50.contains("q50"))
        #expect(f87.contains("q87"))
    }

    @Test func filenameQualityClampsToBounds() {
        // Defensive: score outside 0…1 shouldn't break the format.
        let fNeg = FrameRipper.makeFilename(rank: 1, timestamp: 0, score: -0.3)
        let fOver = FrameRipper.makeFilename(rank: 1, timestamp: 0, score: 1.5)
        #expect(fNeg.contains("q00"))
        #expect(fOver.contains("q99"))
    }

    @Test func filenameHasPngExtension() {
        let f = FrameRipper.makeFilename(rank: 1, timestamp: 0, score: 0.5)
        #expect(f.hasSuffix(".png"))
    }

    @Test func filenameZeroTimestamp() {
        let f = FrameRipper.makeFilename(rank: 1, timestamp: 0, score: 0)
        #expect(f.contains("t00m00s"))
    }

    @Test func filenameLargeTimestamp() {
        // A 60-min video clip — timestamp at the end.
        let f = FrameRipper.makeFilename(rank: 1, timestamp: 3599, score: 0.5)
        #expect(f.contains("t59m59s"))
    }

    // MARK: - PNG writer

    @Test func writePNGSucceedsOnValidImage() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("frameripper-test-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let cgImage = try makeSolidRedCGImage(width: 64, height: 64)
        let target = dir.appendingPathComponent("test.png")
        let ok = FrameRipper.writePNG(image: cgImage, to: target)
        #expect(ok)
        #expect(FileManager.default.fileExists(atPath: target.path))

        // Verify the file actually decodes back as a 64×64 PNG.
        let img = NSImage(contentsOf: target)
        #expect(img != nil)
        #expect(img?.size.width == 64)
        #expect(img?.size.height == 64)
    }

    @Test func writePNGProducesNonZeroFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("frameripper-test-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cgImage = try makeSolidRedCGImage(width: 128, height: 128)
        let target = dir.appendingPathComponent("nonzero.png")
        _ = FrameRipper.writePNG(image: cgImage, to: target)
        let attrs = try FileManager.default.attributesOfItem(atPath: target.path)
        let size = (attrs[.size] as? Int64) ?? 0
        #expect(size > 100,
                "PNG file should be more than 100 bytes; got \(size)")
    }

    // MARK: - Face scoring on a no-face image

    @Test func scoreFaceReturnsZeroForBlankImage() async throws {
        // A solid-color CGImage has no face — Vision should report no
        // observations and our scorer should return 0.
        let cgImage = try makeSolidRedCGImage(width: 256, height: 256)
        let score = await FrameRipper.scoreFace(in: cgImage)
        #expect(score == 0)
    }

    // MARK: - Helpers

    /// Create a small solid-color CGImage for tests that need an image
    /// but not a real face. Uses standard sRGB color space + 32-bit BGRA.
    private func makeSolidRedCGImage(width: Int, height: Int) throws -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = width * 4
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue
              | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: nil,
                                  width: width, height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow,
                                  space: cs,
                                  bitmapInfo: info) else {
            struct CtxError: Error {}
            throw CtxError()
        }
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let img = ctx.makeImage() else {
            struct ImgError: Error {}
            throw ImgError()
        }
        return img
    }
}
