// PreviewSweepCLIRunnerTests.swift
// The out-of-process helper end-to-end at the Core level (Stage 1), with a
// FAKE renderer (no ffmpeg — fast + hermetic):
//   - dry-run computes the same work-item counts the engine would plan;
//   - a real pass drives the SHARED PreviewSweepEngine + PreviewDiskCache and
//     the entries it writes are found under the EXACT keys the app looks up
//     (the anti-drift out-of-process sensor — the whole point of Stage 1).
//
// Isolation: every path is a per-test temp dir; the cache dir is injected, so
// nothing touches the real Application Support cache.

import XCTest
import CoreGraphics
@testable import VideoScanCore

final class PreviewSweepCLIRunnerTests: XCTestCase {

    private func makeSandbox() throws -> (dir: URL, catalog: URL, cache: URL,
                                          mkv: String, mp4: String) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cli-runner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let media = dir.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)

        let mkv = media.appendingPathComponent("clip_ffv1.mkv").path
        let mp4 = media.appendingPathComponent("clip_h264.mp4").path
        PreviewCLITestSupport.touchDummyMedia(at: mkv)
        PreviewCLITestSupport.touchDummyMedia(at: mp4)

        let catalog = dir.appendingPathComponent("catalog.json")
        try PreviewCLITestSupport.writeCatalog([
            PreviewCLITestSupport.makeRecord(path: mkv, stream: .videoOnly,
                                             container: "Matroska / WebM",
                                             codec: "ffv1", duration: 4),
            PreviewCLITestSupport.makeRecord(path: mp4, stream: .videoAndAudio,
                                             container: "QuickTime / MOV",
                                             codec: "h264", duration: 4),
        ], to: catalog)

        let cache = dir.appendingPathComponent("cache", isDirectory: true)
        return (dir, catalog, cache, mkv, mp4)
    }

    func testDryRunPlanCountsMatchTheEngineDiff() async throws {
        let box = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.dir) }

        let runner = PreviewSweepCLIRunner(
            options: PreviewSweepCLIOptions(catalogURL: box.catalog, mode: .once, dryRun: true),
            cacheRootURL: box.cache,
            renderer: FakePreviewRenderer(),
            isReachable: { _ in true },
            out: { _ in })
        let cache = PreviewDiskCache(rootURL: box.cache)
        let source = FileBackedCatalogSource(catalogURL: box.catalog, isReachable: { _ in true })

        let plan = await runner.computePlan(cache: cache, catalogSource: source)
        XCTAssertEqual(plan.eligible, 2)
        XCTAssertEqual(plan.keyed, 2)
        XCTAssertEqual(plan.needBestStill, 2, "both need a best still on an empty cache")
        XCTAssertEqual(plan.needFilmstrip, 1, "only the ffmpegDirect mkv needs a strip")
        XCTAssertEqual(plan.totalWorkItems, 2)
        XCTAssertEqual(plan.cacheFileCount, 0)
    }

    /// THE anti-drift sensor: an entry the CLI writes out-of-process is found
    /// under the exact (path|mtime|size) key an app-side lookup uses.
    func testRunPassWritesAppReadableCache() async throws {
        let box = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.dir) }

        let runner = PreviewSweepCLIRunner(
            options: PreviewSweepCLIOptions(catalogURL: box.catalog, mode: .once),
            cacheRootURL: box.cache,
            renderer: FakePreviewRenderer(frameCount: 6),
            isReachable: { _ in true },
            out: { _ in })
        let cache = PreviewDiskCache(rootURL: box.cache)
        let source = FileBackedCatalogSource(catalogURL: box.catalog, isReachable: { _ in true })

        let status = await runner.runPass(cache: cache, catalogSource: source)

        // Reconstruct the signature exactly as the app would (fresh stat).
        for path in [box.mkv, box.mp4] {
            let sig = try XCTUnwrap(PreviewDiskCache.fileSignature(atPath: path))
            XCTAssertNotNil(cache.lookup(path: path, mtime: sig.mtime, size: sig.size),
                            "best still must be app-readable for \(path)")
        }
        // Filmstrip only for the ffmpegDirect mkv; the h264 has none.
        let mkvSig = try XCTUnwrap(PreviewDiskCache.fileSignature(atPath: box.mkv))
        let strip = cache.lookupFilmstrip(path: box.mkv, mtime: mkvSig.mtime, size: mkvSig.size)
        XCTAssertNotNil(strip, "complete filmstrip must be app-readable")
        XCTAssertEqual(strip?.count, 6)

        let mp4Sig = try XCTUnwrap(PreviewDiskCache.fileSignature(atPath: box.mp4))
        XCTAssertNil(cache.lookupFilmstrip(path: box.mp4, mtime: mp4Sig.mtime, size: mp4Sig.size),
                     "avFoundation-routed record gets no strip from the sweep")

        // Honest terminal status.
        if case .done(let ready, _, _) = status {
            XCTAssertEqual(ready, 2)
        } else {
            XCTFail("expected .done, got \(status)")
        }
    }

    func testSecondPassIsIdempotent() async throws {
        let box = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: box.dir) }

        let runner = PreviewSweepCLIRunner(
            options: PreviewSweepCLIOptions(catalogURL: box.catalog, mode: .once),
            cacheRootURL: box.cache,
            renderer: FakePreviewRenderer(frameCount: 6),
            isReachable: { _ in true },
            out: { _ in })
        let cache = PreviewDiskCache(rootURL: box.cache)
        let source = FileBackedCatalogSource(catalogURL: box.catalog, isReachable: { _ in true })

        _ = await runner.runPass(cache: cache, catalogSource: source)
        // Warm cache — the plan should now be empty.
        let plan = await runner.computePlan(cache: cache, catalogSource: source)
        XCTAssertEqual(plan.totalWorkItems, 0, "warm cache needs no further work")
    }
}
