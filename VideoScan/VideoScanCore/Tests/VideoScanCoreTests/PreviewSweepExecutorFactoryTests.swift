// PreviewSweepExecutorFactoryTests.swift
// Proves the FilmstripRipper seam: the Core executor (makePreviewSweepExecutor)
// classifies failures correctly when driven by a FAKE PreviewMediaRenderer
// and a FAKE PreviewCache — NO real ffmpeg, no app types. This is the
// negative-cache poison contract the app and the Stage-1 CLI both rely on:
//   - success        → stillReady + bytes accumulated
//   - ffmpeg missing → environmentFailure (never a file verdict)
//   - genuine decode → stillFailedGenuinely (the ONLY poisoning class)
//   - unreachable    → skippedUnreachable
//   - strip-only     → stripFailed (still is fine; never poisons)

import XCTest
import CoreGraphics
@testable import VideoScanCore

final class PreviewSweepExecutorFactoryTests: XCTestCase {

    // MARK: - Fakes

    private enum FakeStill { case image, ffmpegMissing, genuineFailure }
    private enum FakeStrip { case frames, ffmpegMissing, genericFailure }

    private struct FakeRenderer: PreviewMediaRenderer {
        let still: FakeStill
        let strip: FakeStrip
        func renderBestStill(_ candidate: PreviewSweepCandidate) async throws -> CGImage {
            switch still {
            case .image: return Self.pixel()
            case .ffmpegMissing: throw PreviewRenderError.ffmpegUnavailable
            case .genuineFailure: throw NSError(domain: "decode", code: 1)
            }
        }
        func renderFilmstrip(_ candidate: PreviewSweepCandidate) async throws -> [PreviewFilmstripFrame] {
            switch strip {
            case .frames: return [PreviewFilmstripFrame(offsetSeconds: 1, image: Self.pixel())]
            case .ffmpegMissing: throw PreviewRenderError.ffmpegUnavailable
            case .genericFailure: throw NSError(domain: "strip", code: 2)
            }
        }
        static func pixel() -> CGImage {
            let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            return ctx.makeImage()!
        }
    }

    private final class FakeCache: PreviewCache, @unchecked Sendable {
        func currentListing() -> [(name: String, size: Int64)] { [] }
        func store(_ image: CGImage, path: String, mtime: TimeInterval, size: Int64,
                   tier: PreviewCacheTier) -> Int64 { 100 }
        func storeFilmstrip(_ frames: [(offsetSeconds: Double, image: CGImage)],
                            path: String, mtime: TimeInterval, size: Int64) -> Int64 { 200 }
    }

    private func workItem(needsBestStill: Bool, needsFilmstrip: Bool) -> PreviewSweepWorkItem {
        // A real temp file so previewFileSignature succeeds.
        let path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("exec-\(UUID().uuidString).bin").path
        try? Data("x".utf8).write(to: URL(fileURLWithPath: path))
        let c = PreviewSweepCandidate(path: path, container: "Matroska / WebM",
                                      videoCodec: "ffv1", likelyUnanalyzable: false,
                                      durationSeconds: 30)
        return PreviewSweepWorkItem(candidate: c, key: previewCacheKey(path: path, mtime: 0, size: 1),
                                    needsBestStill: needsBestStill, needsFilmstrip: needsFilmstrip)
    }

    // MARK: - Tests

    func testStillSuccessAndFilmstripSuccess() async throws {
        let exec = makePreviewSweepExecutor(cache: FakeCache(),
                                            renderer: FakeRenderer(still: .image, strip: .frames),
                                            isReachable: { _ in true })
        let outcome = try await exec(workItem(needsBestStill: true, needsFilmstrip: true))
        XCTAssertTrue(outcome.stillReady)
        XCTAssertEqual(outcome.bytesWritten, 300)      // 100 still + 200 strip
        XCTAssertFalse(outcome.stillFailedGenuinely)
        XCTAssertFalse(outcome.stripFailed)
    }

    func testGenuineStillFailurePoisons() async throws {
        let exec = makePreviewSweepExecutor(cache: FakeCache(),
                                            renderer: FakeRenderer(still: .genuineFailure, strip: .frames),
                                            isReachable: { _ in true })
        let outcome = try await exec(workItem(needsBestStill: true, needsFilmstrip: true))
        XCTAssertTrue(outcome.stillFailedGenuinely)
        XCTAssertFalse(outcome.stillReady)
        XCTAssertFalse(outcome.environmentFailure)
    }

    func testFfmpegMissingIsEnvironmentNotVerdict() async throws {
        let exec = makePreviewSweepExecutor(cache: FakeCache(),
                                            renderer: FakeRenderer(still: .ffmpegMissing, strip: .frames),
                                            isReachable: { _ in true })
        let outcome = try await exec(workItem(needsBestStill: true, needsFilmstrip: true))
        XCTAssertTrue(outcome.environmentFailure)
        XCTAssertFalse(outcome.stillFailedGenuinely)
    }

    func testUnreachableVolumeNoVerdict() async throws {
        let exec = makePreviewSweepExecutor(cache: FakeCache(),
                                            renderer: FakeRenderer(still: .image, strip: .frames),
                                            isReachable: { _ in false })
        let outcome = try await exec(workItem(needsBestStill: true, needsFilmstrip: true))
        XCTAssertTrue(outcome.skippedUnreachable)
        XCTAssertFalse(outcome.stillFailedGenuinely)
    }

    func testStripOnlyFailureNeverPoisons() async throws {
        // Still lands; only the strip fails with a generic (non-ffmpeg)
        // error — the still is good, so this must NOT poison.
        let exec = makePreviewSweepExecutor(cache: FakeCache(),
                                            renderer: FakeRenderer(still: .image, strip: .genericFailure),
                                            isReachable: { _ in true })
        let outcome = try await exec(workItem(needsBestStill: true, needsFilmstrip: true))
        XCTAssertTrue(outcome.stillReady)
        XCTAssertTrue(outcome.stripFailed)
        XCTAssertFalse(outcome.stillFailedGenuinely)
        XCTAssertEqual(outcome.bytesWritten, 100)      // still only; strip wrote nothing
    }
}
