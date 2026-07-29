// FFmpegPreviewRendererE2ETests.swift
// Media-matrix / e2e dimension for Stage 1: at least one REAL ffmpeg rip
// through the SAME renderer + engine + cache the CLI uses, producing a valid
// cached filmstrip that reads back. Skipped (not failed) when ffmpeg isn't
// installed, so CI on a bare box stays green; on Rick's Homebrew box it runs.
//
// Uses a synthetic mkv/ffv1 fixture (the ffmpegDirect route — the exact class
// the filmstrip feature exists for) built with ffmpeg at test time.

import XCTest
import CoreGraphics
@testable import VideoScanCore

final class FFmpegPreviewRendererE2ETests: XCTestCase {

    private func makeFFV1Fixture(at url: URL) async throws {
        let result = await ProcessRunner.runProcess(
            executable: FFmpegLocator.ffmpegPath,
            arguments: ["-v", "error", "-f", "lavfi",
                        "-i", "testsrc=duration=2:size=240x160:rate=10",
                        "-c:v", "ffv1", "-y", url.path],
            deadlineSeconds: 60)
        XCTAssertEqual(result.exitCode, 0, "ffmpeg fixture build failed: \(result.stderr)")
    }

    func testRealFFmpegRipThroughRunnerIsAppReadable() async throws {
        try XCTSkipUnless(FFmpegLocator.ffmpegIsAvailable(),
                          "ffmpeg not installed — skipping real-rip e2e")

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ffmpeg-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let media = dir.appendingPathComponent("clip_ffv1.mkv")
        try await makeFFV1Fixture(at: media)

        let catalog = dir.appendingPathComponent("catalog.json")
        try PreviewCLITestSupport.writeCatalog([
            PreviewCLITestSupport.makeRecord(path: media.path, stream: .videoOnly,
                                             container: "Matroska / WebM",
                                             codec: "ffv1", duration: 2),
        ], to: catalog)

        let cache = dir.appendingPathComponent("cache", isDirectory: true)
        let runner = PreviewSweepCLIRunner(
            options: PreviewSweepCLIOptions(catalogURL: catalog, mode: .once),
            cacheRootURL: cache,
            renderer: FFmpegPreviewRenderer(),   // REAL ffmpeg
            isReachable: { _ in true },
            out: { _ in })
        let diskCache = PreviewDiskCache(rootURL: cache)
        let source = FileBackedCatalogSource(catalogURL: catalog, isReachable: { _ in true })

        _ = await runner.runPass(cache: diskCache, catalogSource: source)

        let sig = try XCTUnwrap(PreviewDiskCache.fileSignature(atPath: media.path))
        XCTAssertNotNil(diskCache.lookup(path: media.path, mtime: sig.mtime, size: sig.size),
                        "real ffmpeg best still must be app-readable")
        let strip = try XCTUnwrap(
            diskCache.lookupFilmstrip(path: media.path, mtime: sig.mtime, size: sig.size),
            "real ffmpeg filmstrip must read back as a complete set")
        XCTAssertGreaterThan(strip.count, 1, "a 2s clip should yield a multi-frame strip")
        // Frames actually decoded to images.
        for frame in strip {
            XCTAssertGreaterThan(frame.image.width, 0)
        }
    }
}
