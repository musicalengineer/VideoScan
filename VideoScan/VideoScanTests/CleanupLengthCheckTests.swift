import Testing
import Foundation
@testable import VideoScan

// MARK: - CleanupLengthCheckTests (N1014-F2, 2026-10-07)
//
// CleanupFFmpegEngine.render checked only ffmpeg's exit code and a 10 KB
// floor. ffmpeg can exit 0 on a source read error (bad sectors on an aging
// USB drive are treated as end-of-file), so a 20-minute render of a
// 60-minute tape was published beside the original as a good cleaned copy.
// The render now goes through FFmpegEncodeCheck's length rule, the one
// Transcode and Reformat use: output vs a FRESH probe of the source, within
// max(3 s, 3 %); skipped (never failed) when either length can't be read.
//
// Fixtures: a 60 s synthetic `test_` source (tiny mpeg4 + aac), and a fake
// ffmpeg (VS_FFMPEG_PATH, pass-through for everything except this suite's
// render) that writes a real, playable clip of a chosen length and exits 0.
// VS_FFMPEG_PATH is process-global, so the suite is serialized.
// Tested at the engine: a throw is what keeps CleanupJob from publishing
// (it publishes only a returned URL). A job-level run would mount a RAM
// disk, and avoiding that means writing the user's persisted perf settings.

@Suite(.serialized, .timeLimit(.minutes(2)))
struct CleanupLengthCheckTests {

    static let sourceName = "test_cleanup_len60.mp4"

    /// A real, playable clip of `seconds` written to the render target,
    /// exit 0 — ffmpeg's behaviour on a source that "ended" early.
    static func fakeFFmpeg(in dir: URL, real: String, writesSeconds seconds: Int) throws -> URL {
        let url = dir.appendingPathComponent("ffmpeg")
        let script = """
        #!/bin/sh
        case "$*" in *\(sourceName)*cleanup-render*) ;; *) exec "\(real)" "$@" ;; esac
        for out; do :; done
        "\(real)" -hide_banner -loglevel error -nostdin -y -f lavfi -i testsrc=duration=\(seconds):size=320x240:rate=25 \\
          -c:v mpeg4 -q:v 2 -f mov "$out" || exit 9
        exit 0
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    struct Bench {
        let dir: URL
        let scratch: URL
        let source: CleanupSource
        let real: String
    }

    static func makeBench(_ label: String) throws -> Bench {
        let real = ToolLocator.ffmpegPath
        let dir = try CleanupTestMedia.makeScratchDir(label)
        let src = try CleanupTestMedia.generate(
            into: dir, name: sourceName, duration: 60, size: "160x120", rate: "10",
            videoCodec: "mpeg4", audioCodec: "aac")
        let scratch = dir.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let source = CleanupSource(path: src, durationSeconds: 60, fieldOrder: "progressive",
                                   hasAudio: true, audioCodec: "aac")
        return Bench(dir: dir, scratch: scratch, source: source, real: real)
    }

    static func render(_ bench: Bench, fake: URL) async throws -> URL {
        setenv(ToolLocator.ffmpegEnvVar, fake.path, 1)
        defer { unsetenv(ToolLocator.ffmpegEnvVar) }
        return try await CleanupFFmpegEngine().render(
            recipe: CleanupRecipeRegistry.vhsQuickClean, source: bench.source,
            scratchDirectory: bench.scratch, progress: { _ in })
    }

    @Test("a render that exits 0 but runs 5 s of a 60 s source is renderFailed, never returned")
    func aShortRenderIsRefused() async throws {
        try #require(CleanupTestMedia.toolsAvailable, "ffmpeg/ffprobe are required project dependencies")
        let bench = try Self.makeBench("length_short")
        defer { try? FileManager.default.removeItem(at: bench.dir) }
        let fake = try Self.fakeFFmpeg(in: bench.dir, real: bench.real, writesSeconds: 5)

        do {
            let url = try await Self.render(bench, fake: fake)
            Issue.record("a 5 s render of a 60 s source was returned as good: \(url.lastPathComponent)")
        } catch CleanupEngineError.renderFailed(let detail) {
            #expect(detail.contains("stopped early") && detail.contains("0:05") && detail.contains("1:00"),
                    Comment(rawValue: detail))
        } catch {
            Issue.record("expected renderFailed, got \(error)")
        }
    }

    @Test("a render as long as the source still passes (the length rule does not over-fail)")
    func aFullLengthRenderPasses() async throws {
        try #require(CleanupTestMedia.toolsAvailable, "ffmpeg/ffprobe are required project dependencies")
        let bench = try Self.makeBench("length_full")
        defer { try? FileManager.default.removeItem(at: bench.dir) }
        let fake = try Self.fakeFFmpeg(in: bench.dir, real: bench.real, writesSeconds: 59)

        let url = try await Self.render(bench, fake: fake)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    /// Sensor: the engine's verdict is the shared length rule, after the size gate.
    @Test("sensor: CleanupFFmpegEngine checks length through FFmpegEncodeCheck")
    func engineUsesTheSharedLengthRule() throws {
        let text = try SourceTree.appSource(named: "CleanupFFmpegEngine.swift")
        #expect(text.contains("FFmpegEncodeCheck.durationShortfall("))
        #expect(text.contains("FFmpegEncodeCheck.probeDurationSeconds("))
    }
}
