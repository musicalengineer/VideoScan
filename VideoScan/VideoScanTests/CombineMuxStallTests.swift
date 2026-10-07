import Testing
import Foundation
@testable import VideoScan

// MARK: - CombineMuxStallTests (N1014-F3, 2026-10-07)
//
// Combine's ffmpeg mux ran with no stall watchdog, and its verify probes
// (ffprobe, the one-frame decode tests, volumedetect) with no deadline. A
// USB drive that stops answering mid-mux leaves ffmpeg blocked in read(2),
// printing nothing: the row said "muxing" forever and the rest of an
// overnight batch never ran — the 14-hour hang class StallMonitor exists for.
//
// Contract pinned here:
//   • the mux runs under a StallMonitor fed by ffmpeg's progress output;
//     silence past the threshold kills ffmpeg, the pair fails as STALLED,
//     only its own partial is removed, nothing is published;
//   • every verify subprocess has a deadline, and a timed-out probe fails
//     verification (never passes it).
//
// Fixtures: CombineNeverOverwritesTests' synthetic `test_` pairs, and fake
// tools (shell scripts in the test's temp dir) that sleep silently. The
// ffmpeg fake is pass-through for everything but this suite's mux;
// VS_FFMPEG_PATH is process-global, so the suite is serialized. Thresholds
// come from CombineTestSeams (production uses StallMonitor's default).

@Suite(.serialized, .timeLimit(.minutes(2))) @MainActor
struct CombineMuxStallTests {

    typealias H = CombineNeverOverwritesTests

    static func script(_ body: String, named name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// Silent sleeper for this suite's mux only (`-movflags` is in the mux
    /// arguments, never in a probe or a fixture call).
    static func stallingFFmpeg(in dir: URL, real: String) throws -> URL {
        try script("""
        case "$*" in *-movflags*test_stallmux_*) ;; *) exec "\(real)" "$@" ;; esac
        exec sleep 60
        """, named: "ffmpeg", in: dir)
    }

    @Test("a mux that goes silent fails the pair as stalled, removes only its partial, publishes nothing")
    func silentMuxFailsAsStalled() async throws {
        try #require(H.toolsPresent, "ffmpeg/ffprobe not found")
        let real = ToolLocator.ffmpegPath
        let root = try H.makeDir("mux_stall")
        defer { try? FileManager.default.removeItem(at: root) }
        let out = root.appendingPathComponent("out")
        let tools = root.appendingPathComponent("tools")
        for d in [out, tools] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let pair = try H.makePair(.movProRes, in: root, stem: "test_stallmux_clip", seconds: 2)
        let fake = try Self.stallingFFmpeg(in: tools, real: real)

        let model = await H.makeModel()
        setenv(ToolLocator.ffmpegEnvVar, fake.path, 1)
        defer { unsetenv(ToolLocator.ffmpegEnvVar) }
        let started = Date()
        let ok = await CombineTestSeams.$muxStallThresholdSeconds.withValue(2) {
            await H.run(model, pair, into: out)
        }
        let elapsed = Date().timeIntervalSince(started)

        #expect(!ok)
        #expect(elapsed < 30, "the stalled mux ran \(Int(elapsed)) s — the watchdog never fired")
        #expect(model.dashboard.combineFailed == 1)
        #expect(H.names(in: out).isEmpty, "a stalled mux leaves nothing behind: \(H.names(in: out))")
        try await Task.sleep(nanoseconds: 400_000_000)   // console flushes every 0.15 s
        #expect(model.dashboard.consoleLines.contains { $0.contains("STALLED") && $0.contains("test_stallmux_clip_combined.mov") },
                "the console must say the pair stalled")
    }

    @Test("a healthy mux under a short threshold is not mistaken for a stall")
    func healthyMuxIsNotAStall() async throws {
        try #require(H.toolsPresent, "ffmpeg/ffprobe not found")
        let root = try H.makeDir("mux_healthy")
        defer { try? FileManager.default.removeItem(at: root) }
        let out = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let pair = try H.makePair(.movProRes, in: root, stem: "test_healthymux_clip", seconds: 2)

        let model = await H.makeModel()
        let ok = await CombineTestSeams.$muxStallThresholdSeconds.withValue(2) {
            await H.run(model, pair, into: out)
        }
        #expect(ok)
        #expect(H.names(in: out) == ["test_healthymux_clip_combined.mov"])
    }

    /// A finished 2 s mov with video + audio for the verifier tests.
    static func combinedClip(in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("test_verify_clip.mov")
        try H.ffmpeg(["-f", "lavfi", "-i", "testsrc=duration=2:size=320x240:rate=25",
                      "-f", "lavfi", "-i", "sine=duration=2:sample_rate=48000",
                      "-c:v", "mpeg4", "-c:a", "pcm_s16le", "-shortest", url.path])
        return url
    }

    @Test("a wedged ffprobe in verify times out and fails verification")
    func wedgedProbeFailsVerify() async throws {
        try #require(H.toolsPresent, "ffmpeg/ffprobe not found")
        let root = try H.makeDir("verify_probe_wedge")
        defer { try? FileManager.default.removeItem(at: root) }
        let clip = try Self.combinedClip(in: root)
        let probe = try Self.script("exec sleep 60", named: "ffprobe", in: root)

        let started = Date()
        let result = await CombineTestSeams.$verifyToolTimeoutSeconds.withValue(1) {
            await CombineVerifier.verifyCombineOutput(url: clip, expectedDuration: 2,
                                                      ffprobePath: probe.path,
                                                      ffmpegPath: ToolLocator.ffmpegPath)
        }
        let elapsed = Date().timeIntervalSince(started)
        #expect(!result.ok)
        #expect(result.reason.contains("timed out"), Comment(rawValue: result.reason))
        #expect(elapsed < 20, "verify waited \(Int(elapsed)) s on a wedged ffprobe")
    }

    @Test("a wedged decode test in verify times out and fails verification")
    func wedgedDecodeFailsVerify() async throws {
        try #require(H.toolsPresent, "ffmpeg/ffprobe not found")
        let root = try H.makeDir("verify_decode_wedge")
        defer { try? FileManager.default.removeItem(at: root) }
        let clip = try Self.combinedClip(in: root)
        let ffmpeg = try Self.script("exec sleep 60", named: "ffmpeg", in: root)

        let started = Date()
        let result = await CombineTestSeams.$verifyToolTimeoutSeconds.withValue(1) {
            await CombineVerifier.verifyCombineOutput(url: clip, expectedDuration: 2,
                                                      ffprobePath: ToolLocator.ffprobePath,
                                                      ffmpegPath: ffmpeg.path)
        }
        let elapsed = Date().timeIntervalSince(started)
        #expect(!result.ok)
        #expect(result.reason.contains("timed out"), Comment(rawValue: result.reason))
        #expect(elapsed < 20, "verify waited \(Int(elapsed)) s on a wedged decode")
    }
}
