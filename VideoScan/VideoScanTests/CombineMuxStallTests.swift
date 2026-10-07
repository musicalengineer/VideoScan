import Testing
import Foundation
import os
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

    // MARK: - Silent but writing (QA FIX-FIRST, 2026-10-07)
    //
    // `-movflags +faststart` ends with a pass that rewrites the whole output
    // in place and prints nothing. On a 75 MB/s drive a ~22 GB output is
    // silent past the 5-minute threshold, so a healthy pair was killed as
    // "stalled" on every retry. The heartbeat is ANY ffmpeg line OR a change
    // in the output's size/mtime. (A truly wedged ffmpeg — no lines, no file
    // change — is still caught: silentMuxFailsAsStalled above.)

    /// Silent for ~3 s but appending to its output every 0.1 s — the shape
    /// of faststart's rewrite, without gigabytes of fixture.
    static func silentWriterFFmpeg(in dir: URL, real: String) throws -> URL {
        try script("""
        case "$*" in *-movflags*test_silentwrite_*) ;; *) exec "\(real)" "$@" ;; esac
        for out; do :; done
        i=0
        while [ $i -lt 30 ]; do head -c 65536 /dev/zero >> "$out"; sleep 0.1; i=$((i+1)); done
        exit 0
        """, named: "ffmpeg", in: dir)
    }

    @Test("an ffmpeg that prints nothing but keeps writing its output is not a stall")
    func silentButWritingIsNotAStall() async throws {
        let real = ToolLocator.ffmpegPath
        try #require(FileManager.default.isExecutableFile(atPath: real), "ffmpeg not found")
        let root = try H.makeDir("silent_write")
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = try Self.silentWriterFFmpeg(in: root, real: real)
        let out = root.appendingPathComponent("test_silentwrite_combined.vs-test.mov")
        FileManager.default.createFile(atPath: out.path, contents: nil)   // the 0-byte reservation

        setenv(ToolLocator.ffmpegEnvVar, fake.path, 1)
        defer { unsetenv(ToolLocator.ffmpegEnvVar) }
        let started = Date()
        let result = await CombineEngine.runFFMpeg(
            videoPath: root.appendingPathComponent("test_silentwrite_v.mov").path,
            audioPath: root.appendingPathComponent("test_silentwrite_a.wav").path,
            outputPath: out.path, stallThresholdSeconds: 1.0, log: { _ in })
        let elapsed = Date().timeIntervalSince(started)

        #expect(elapsed > 2.0, "the fake must stay silent well past the 1 s threshold (ran \(elapsed) s)")
        #expect(result.stallReason == nil, "a silent-but-writing ffmpeg was killed: \(result.stallReason ?? "")")
        #expect(result.success)
    }

    /// QA's real-media pin. Writes ~8 GB (a 3.9 GB rawvideo source and its
    /// mux), so it is off on GitHub runners and when the temp volume is short
    /// of space; on Rick's fleet it runs.
    nonisolated static var heavyFaststartAllowed: Bool {
        guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] != "true" else { return false }
        let tmp = FileManager.default.temporaryDirectory
        let free = (try? tmp.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        return free > 20_000_000_000
    }

    @Test("faststart's silent second pass is not a stall",
          .enabled(if: CombineMuxStallTests.heavyFaststartAllowed,
                   "writes ~8 GB: skipped on GitHub runners and below 20 GB free"))
    func faststartPassIsNotAStall() async throws {
        try #require(H.toolsPresent, "ffmpeg/ffprobe not found")
        let root = try H.makeDir("faststart")
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("test_faststart_v.mov")
        let audio = root.appendingPathComponent("test_faststart_a.wav")
        try H.ffmpeg(["-f", "lavfi", "-i", "testsrc=duration=50:size=1920x1080:rate=25",
                      "-c:v", "rawvideo", "-pix_fmt", "yuv420p", video.path])
        try H.ffmpeg(["-f", "lavfi", "-i", "sine=duration=50:sample_rate=48000", "-c:a", "pcm_s16le", audio.path])
        let out = root.appendingPathComponent("test_faststart_combined.vs-test.mov")
        FileManager.default.createFile(atPath: out.path, contents: nil)

        // Every line ffmpeg prints, timestamped as it is read (the progress
        // lines arrive on the reader thread; stderr is hopped to main).
        let stamps = OSAllocatedUnfairLock(initialState: [Date()])
        let stamp: @Sendable () -> Void = { stamps.withLock { $0.append(Date()) } }
        let result = await CombineEngine.runFFMpeg(
            videoPath: video.path, audioPath: audio.path, outputPath: out.path,
            durationSeconds: 50, onProgress: { _ in stamp() },
            stallThresholdSeconds: 1.0, log: { _ in stamp() })
        let times = stamps.withLock { $0 }.sorted() + [Date()]
        let longestSilence = zip(times, times.dropFirst()).map { $1.timeIntervalSince($0) }.max() ?? 0

        #expect(result.stallReason == nil, "faststart's rewrite was killed as a stall: \(result.stallReason ?? "")")
        #expect(result.success, "\(result.stderr.suffix(300))")
        // Only a slow disk makes this silence outlast StallMonitor's 1 s
        // minimum threshold: an internal M-series SSD rewrites 3.9 GB faster
        // than that. The gap is reported so a run on a slow drive shows that
        // the file heartbeat (not a line) carried the mux through. The
        // always-on pin is silentButWritingIsNotAStall.
        print("faststartPassIsNotAStall: longest silence between ffmpeg lines \(String(format: "%.2f", longestSilence)) s (threshold 1.0 s)")
    }

    @Test("the output heartbeat sees size and mtime changes, and nothing for an untouched file")
    func heartbeatSignatureTracksWrites() throws {
        let root = try H.makeDir("heartbeat_sig")
        defer { try? FileManager.default.removeItem(at: root) }
        let f = root.appendingPathComponent("test_sig.bin")
        #expect(OutputFileHeartbeat.signature(f.path) == nil, "absent file has no signature")
        try Data([1, 2, 3]).write(to: f)
        let a = OutputFileHeartbeat.signature(f.path)
        #expect(a == OutputFileHeartbeat.signature(f.path), "untouched file: same signature")
        let h = try FileHandle(forWritingTo: f)
        try h.seek(toOffset: 0); try h.write(contentsOf: Data([9]))    // in-place rewrite: same size
        try h.close()
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: f.path)
        #expect(OutputFileHeartbeat.signature(f.path) != a, "an in-place rewrite changes mtime")
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
