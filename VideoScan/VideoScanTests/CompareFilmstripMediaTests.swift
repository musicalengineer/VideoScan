// CompareFilmstripMediaTests.swift
// Compare Media's frames over the sound (2026-10-22), on real media:
//   MEDIA     — the loader end to end on mp4/h264, mov/prores, mkv/ffv1+pcm,
//               mxf/mpeg2video, avi/dv (pictures, never a throw or a hang,
//               time budget), audio-only OP-Atom mxf (no picture, no
//               decode), and the renderer's fixed-positions mode keeping a
//               blue leader.
//   ISOLATION — the shared thumbnail NSCache poisoned under the file's
//               plain path key and under a stale signature: never served;
//               the right key IS served, with no decode (bogus ffmpeg).
//   OFFLINE   — drive offline, file missing, cancel.

import AppKit
import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Compare filmstrip — loader on real media",
       .serialized,
       .timeLimit(.minutes(5)),
       .enabled(if: TestMediaGenerator.isAvailable))
@MainActor
struct CompareFilmstripMediaTests {

    private static let ffmpeg: String = {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "ffmpeg"
    }()
    private static let noFFmpeg = "/dev/null/definitely-not-ffmpeg"
    /// Per format: generous for a loaded host; a hang or a serialized rip
    /// of a few-second fixture blows through it.
    private static let budget = Duration.seconds(30)

    private func runFFmpeg(_ args: [String]) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: Self.ffmpeg)
        proc.arguments = ["-y", "-hide_banner", "-loglevel", "error"] + args
        proc.standardError = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw TestMediaGenerator.GeneratorError.ffmpegFailed(status: proc.terminationStatus, message: "fixture")
        }
    }

    private func temp(_ ext: String) -> String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("test_gen_cmpstrip_\(UUID().uuidString.prefix(8)).\(ext)")
    }

    private func request(_ path: String, container: String, codec: String, duration: Double,
                         unanalyzable: Bool = false, hasPicture: Bool = true,
                         ffmpegPath: String = ToolLocator.ffmpegPath) -> CompareFilmstripRequest {
        CompareFilmstripRequest(
            item: .init(path: path, container: container, videoCodec: codec,
                        likelyUnanalyzable: unanalyzable, durationSeconds: duration),
            hasPicture: hasPicture, ffmpegPath: ffmpegPath)
    }

    private func pictures(_ loader: CompareFilmstripLoader) -> Int {
        loader.cells.filter { $0.image != nil }.count
    }

    private func waiting(_ loader: CompareFilmstripLoader) -> Int {
        loader.cells.filter { if case .waiting = $0 { return true } else { return false } }.count
    }

    /// Load, time it, and assert the outcome every format must meet.
    private func expectPictures(_ req: CompareFilmstripRequest, label: String, atLeast: Int = 6) async {
        let loader = CompareFilmstripLoader()
        let elapsed = await ContinuousClock().measure {
            await loader.load(req, cache: NSCache<NSString, NSImage>())
        }
        #expect(loader.blank == nil, "[\(label)] strip blank: \(String(describing: loader.blank))")
        #expect(pictures(loader) >= atLeast, "[\(label)] only \(pictures(loader))/8 pictures")
        #expect(waiting(loader) == 0, "[\(label)] cells left waiting after the load finished")
        #expect(elapsed < Self.budget, "[\(label)] took \(elapsed)")
    }

    @Test("mp4/h264: eight pictures (AVF batch arm)")
    func h264() async throws {
        let path = try TestMediaGenerator.generate(container: "mp4", streams: .videoOnly, videoCodec: "libx264",
                                                   duration: 6, prefix: "test_gen_cmpstrip_h264")
        defer { TestMediaGenerator.cleanup(path) }
        await expectPictures(request(path, container: "QuickTime / MOV", codec: "h264", duration: 6), label: "h264")
    }

    @Test("mov/prores: eight pictures")
    func prores() async throws {
        let path = try TestMediaGenerator.generate(container: "mov", streams: .videoOnly, videoCodec: "prores",
                                                   duration: 6, prefix: "test_gen_cmpstrip_prores")
        defer { TestMediaGenerator.cleanup(path) }
        await expectPictures(request(path, container: "QuickTime / MOV", codec: "prores", duration: 6), label: "prores")
    }

    @Test("mkv/ffv1+pcm: all eight pictures through the ffmpegDirect arm")
    func ffv1() async throws {
        let path = try TestMediaGenerator.generate(container: "mkv", streams: .videoAndAudio, videoCodec: "ffv1",
                                                   audioCodec: "pcm_s16le", duration: 6, prefix: "test_gen_cmpstrip_ffv1")
        defer { TestMediaGenerator.cleanup(path) }
        await expectPictures(request(path, container: "Matroska / WebM", codec: "ffv1", duration: 6), label: "ffv1", atLeast: 8)
    }

    @Test("mxf/mpeg2video video-only: pictures on the routed arm and the likelyUnanalyzable ffmpeg arm")
    func mxfVideoOnly() async throws {
        let path = try TestMediaGenerator.generate(container: "mxf", streams: .videoOnly, videoCodec: "mpeg2video",
                                                   duration: 6, prefix: "test_gen_cmpstrip_mxf")
        defer { TestMediaGenerator.cleanup(path) }
        let mxf = "MXF (Material eXchange Format)"
        await expectPictures(request(path, container: mxf, codec: "mpeg2video", duration: 6), label: "mxf-routed")
        await expectPictures(request(path, container: mxf, codec: "mpeg2video", duration: 6, unanalyzable: true), label: "mxf-ffmpeg")
    }

    @Test("audio-only mxf: 'no picture', and nothing is decoded (bogus ffmpeg never reached)")
    func mxfAudioOnly() async throws {
        // Avid OP-Atom audio essence — the orphaned-MXF half this app
        // recovers (ffmpeg's generic mxf muxer insists on a video stream).
        let path = temp("mxf")
        try runFFmpeg(["-f", "lavfi", "-i", "sine=frequency=440:duration=4:sample_rate=48000",
                       "-c:a", "pcm_s16le", "-ac", "1", "-f", "mxf_opatom", path])
        defer { TestMediaGenerator.cleanup(path) }
        let loader = CompareFilmstripLoader()
        await loader.load(request(path, container: "MXF (Material eXchange Format)", codec: "", duration: 4,
                                  hasPicture: false, ffmpegPath: Self.noFFmpeg),
                          cache: NSCache<NSString, NSImage>())
        #expect(loader.blank == .noPicture && pictures(loader) == 0 && waiting(loader) == 0)
    }

    @Test("avi/dv: pictures (AVF batch, or its ffmpeg fallback)")
    func aviDV() async throws {
        let path = temp("avi")
        try runFFmpeg(["-f", "lavfi", "-i", "testsrc=duration=6:size=720x576:rate=25",
                       "-c:v", "dvvideo", "-pix_fmt", "yuv420p", "-an", path])
        defer { TestMediaGenerator.cleanup(path) }
        await expectPictures(request(path, container: "AVI (Audio Video Interleaved)", codec: "dvvideo", duration: 6), label: "avi-dv")
    }

    @Test("an undecodable file: 'pictures could not be read', no throw, no hang")
    func garbage() async throws {
        let path = temp("mkv")
        try Data((0..<8192).map { UInt8(truncatingIfNeeded: $0 &* 37) }).write(to: URL(fileURLWithPath: path))
        defer { TestMediaGenerator.cleanup(path) }
        let loader = CompareFilmstripLoader()
        let elapsed = await ContinuousClock().measure {
            await loader.load(request(path, container: "Matroska / WebM", codec: "ffv1", duration: 6), cache: NSCache<NSString, NSImage>())
        }
        #expect(loader.blank == .unreadable && waiting(loader) == 0)
        #expect(elapsed < Self.budget)
    }

    @Test("fixed-positions mode keeps near-solid frames: a blue leader still holds its slots (8 of 8)")
    func fixedPositionsKeepLeader() async throws {
        let path = temp("mkv")
        try runFFmpeg(["-f", "lavfi", "-i", "color=c=blue:s=320x240:r=25:d=3",
                       "-f", "lavfi", "-i", "testsrc=duration=5:size=320x240:rate=25",
                       "-filter_complex", "[0:v][1:v]concat=n=2:v=1:a=0[v]", "-map", "[v]", "-c:v", "ffv1", path])
        defer { TestMediaGenerator.cleanup(path) }
        let offsets = CompareFilmstripPlan.offsets(durationSeconds: 8)
        let frames = try await PreviewFrameRenderer.renderFramesAtOffsets(
            path: path, container: "Matroska / WebM", videoCodec: "ffv1", likelyUnanalyzable: false, offsets: offsets)
        #expect(frames.map(\.offsetSeconds) == offsets, "every planned slot, in order — none dropped")
    }

    // MARK: Isolation — the shared cache

    @Test("poisoned shared cache: a thumbnail under the plain path and a frame under a stale signature are never served")
    func poisonedCacheNotServed() async throws {
        let path = try TestMediaGenerator.generate(container: "mkv", streams: .videoOnly, videoCodec: "ffv1",
                                                   duration: 4, prefix: "test_gen_cmpstrip_iso")
        defer { TestMediaGenerator.cleanup(path) }
        let sig = try #require(PreviewDiskCache.fileSignature(atPath: path))
        let offsets = CompareFilmstripPlan.offsets(durationSeconds: 4)
        let poison = NSImage(cgImage: PreviewTestImages.solid(red: 1, green: 0, blue: 0), size: .zero)
        let cache = NSCache<NSString, NSImage>()
        cache.setObject(poison, forKey: path as NSString)
        let stale = PreviewDiskCache.cacheKey(path: path, mtime: sig.mtime - 60, size: sig.size)
        for o in offsets { cache.setObject(poison, forKey: CompareFilmstripPlan.cacheKey(signatureKey: stale, offsetSeconds: o) as NSString) }

        // ffmpegDirect route + no ffmpeg: anything not served from the
        // right key must fail to decode, so a poisoned hit would show.
        let loader = CompareFilmstripLoader()
        await loader.load(request(path, container: "Matroska / WebM", codec: "ffv1", duration: 4, ffmpegPath: Self.noFFmpeg), cache: cache)
        #expect(loader.blank == .noFFmpeg, "\(String(describing: loader.blank))")
        #expect(!loader.cells.contains { $0.image === poison }, "a poisoned entry was served")
        #expect(cache.object(forKey: path as NSString) === poison, "the thumbnail entry was not the loader's to touch")
    }

    @Test("the right key is served from the shared cache, with no decode at all")
    func rightKeyServed() async throws {
        let path = try TestMediaGenerator.generate(container: "mkv", streams: .videoOnly, videoCodec: "ffv1",
                                                   duration: 4, prefix: "test_gen_cmpstrip_hit")
        defer { TestMediaGenerator.cleanup(path) }
        let sig = try #require(PreviewDiskCache.fileSignature(atPath: path))
        let key = PreviewDiskCache.cacheKey(path: path, mtime: sig.mtime, size: sig.size)
        let marker = NSImage(cgImage: PreviewTestImages.solid(red: 0, green: 1, blue: 0), size: .zero)
        let cache = NSCache<NSString, NSImage>()
        for o in CompareFilmstripPlan.offsets(durationSeconds: 4) {
            cache.setObject(marker, forKey: CompareFilmstripPlan.cacheKey(signatureKey: key, offsetSeconds: o) as NSString)
        }
        let loader = CompareFilmstripLoader()
        await loader.load(request(path, container: "Matroska / WebM", codec: "ffv1", duration: 4, ffmpegPath: Self.noFFmpeg), cache: cache)
        #expect(loader.blank == nil && loader.cells.allSatisfy { $0.image === marker })
    }

    @Test("decoded frames are written back to the shared cache under the compare keys")
    func framesCached() async throws {
        let path = try TestMediaGenerator.generate(container: "mkv", streams: .videoOnly, videoCodec: "ffv1",
                                                   duration: 4, prefix: "test_gen_cmpstrip_store")
        defer { TestMediaGenerator.cleanup(path) }
        let cache = NSCache<NSString, NSImage>()
        let loader = CompareFilmstripLoader()
        await loader.load(request(path, container: "Matroska / WebM", codec: "ffv1", duration: 4), cache: cache)
        let sig = try #require(PreviewDiskCache.fileSignature(atPath: path))
        let key = PreviewDiskCache.cacheKey(path: path, mtime: sig.mtime, size: sig.size)
        let cached = CompareFilmstripPlan.offsets(durationSeconds: 4).filter {
            cache.object(forKey: CompareFilmstripPlan.cacheKey(signatureKey: key, offsetSeconds: $0) as NSString) != nil
        }
        #expect(cached.count == 8)
        #expect(cache.object(forKey: path as NSString) == nil, "never written under the thumbnail's own key")
    }

    // MARK: Offline, missing, cancel

    @Test("drive offline: grey cells, 'drive offline', no stat")
    func offline() async {
        let loader = CompareFilmstripLoader()
        await loader.load(request("/Volumes/NotMounted/a.mov", container: "QuickTime / MOV", codec: "h264", duration: 60),
                          cache: NSCache<NSString, NSImage>(), isVolumeMounted: { _ in false })
        #expect(loader.blank == .driveOffline && pictures(loader) == 0 && waiting(loader) == 0)
    }

    @Test("file missing on a mounted drive: 'file missing'")
    func missing() async {
        let loader = CompareFilmstripLoader()
        await loader.load(request(temp("mov"), container: "QuickTime / MOV", codec: "h264", duration: 60),
                          cache: NSCache<NSString, NSImage>(), isVolumeMounted: { _ in true })
        #expect(loader.blank == .fileMissing && waiting(loader) == 0)
    }

    @Test("cancelled mid-decode: returns promptly and says nothing")
    func cancelled() async throws {
        let path = try TestMediaGenerator.generate(container: "mkv", streams: .videoOnly, videoCodec: "ffv1",
                                                   duration: 6, prefix: "test_gen_cmpstrip_cancel")
        defer { TestMediaGenerator.cleanup(path) }
        let loader = CompareFilmstripLoader()
        let req = request(path, container: "Matroska / WebM", codec: "ffv1", duration: 6)
        let task = Task { @MainActor in await loader.load(req, cache: NSCache<NSString, NSImage>()) }
        task.cancel()
        let elapsed = await ContinuousClock().measure { await task.value }
        #expect(loader.blank == nil, "a cancel is not a failure: \(String(describing: loader.blank))")
        #expect(elapsed < Self.budget)
    }
}
