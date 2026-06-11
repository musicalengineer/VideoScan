import Testing
import Foundation
@testable import VideoScan

// MARK: - PerceptualFingerprinter tests (2026-06-11)
//
// buildArgs is PURE (no filesystem, no Process), so the exact ffmpeg
// argv is pinned here the same way CombineEngineArgsTests pins the mux
// command — any drift in flags is a deliberate, reviewed change, not
// an accident. The Process-running half is exercised by the env-gated
// integration test at the bottom (VS_RUN_PERCEPTUAL=1), mirroring the
// VS_RUN_WHISPER pattern: real ffmpeg, real re-encode, real match.

@Suite("PerceptualFingerprinter.buildArgs")
struct PerceptualFingerprinterArgsTests {

    // The canonical case: a 100-second file. Trim 5% each end →
    // start 5 s, span 90 s, fps = 32/90 = 0.355556.
    @Test func exactArgvForHundredSecondFile() {
        let args = PerceptualFingerprinter.buildArgs(
            inputPath: "/Volumes/Tape/clip.mxf",
            durationSeconds: 100,
            frameCount: 32,
            outputPath: "/tmp/out.gray")
        #expect(args == [
            "-nostdin", "-nostats",
            "-v", "error",
            "-progress", "pipe:2",
            "-ss", "5.000",
            "-t", "90.000",
            "-i", "/Volumes/Tape/clip.mxf",
            "-an", "-sn", "-dn",
            "-vf", "fps=0.355556,scale=9:8:flags=area,format=gray",
            "-frames:v", "32",
            "-f", "rawvideo",
            "-y", "/tmp/out.gray"
        ])
    }

    // Short file: trim math still holds and fps scales up — a half-
    // second clip samples at 32/0.45 ≈ 71 fps.
    @Test func shortFileGetsHighSampleRate() {
        let args = PerceptualFingerprinter.buildArgs(
            inputPath: "/a.mov",
            durationSeconds: 0.5,
            frameCount: 32,
            outputPath: "/tmp/o.gray")
        #expect(args.contains("0.025"))                  // -ss 5% of 0.5s
        #expect(args.contains("0.450"))                  // -t  90% of 0.5s
        #expect(args.contains("fps=71.111111,scale=9:8:flags=area,format=gray"))
    }

    // Degenerate duration must not divide by zero — span floors at 1 ms.
    @Test func tinyDurationDoesNotDivideByZero() {
        let args = PerceptualFingerprinter.buildArgs(
            inputPath: "/a.mov",
            durationSeconds: 0.0001,
            frameCount: 32,
            outputPath: "/tmp/o.gray")
        let vfIndex = args.firstIndex(of: "-vf").map { args.index(after: $0) }
        let vf = vfIndex.map { args[$0] } ?? ""
        #expect(vf.hasPrefix("fps="))
        #expect(!vf.contains("inf") && !vf.contains("nan"))
    }

    // Structural invariants that the runner depends on, for any input:
    // -ss/-t precede -i (input-side trim), and the output path is last.
    @Test(arguments: [3.0, 47.5, 7200.0])
    func argOrderInvariants(_ duration: Double) {
        let args = PerceptualFingerprinter.buildArgs(
            inputPath: "/in.dv",
            durationSeconds: duration,
            frameCount: 32,
            outputPath: "/tmp/fp.gray")
        let ssIndex = args.firstIndex(of: "-ss")
        let inputIndex = args.firstIndex(of: "-i")
        #expect(ssIndex != nil && inputIndex != nil)
        if let ssIndex, let inputIndex {
            #expect(ssIndex < inputIndex, "-ss must be input seeking (before -i)")
        }
        #expect(args.last == "/tmp/fp.gray")
        #expect(args.contains("rawvideo"))
        #expect(args.contains("-nostdin"))   // never let ffmpeg grab the tty
    }

    // The sampled span used for progress math must equal the -t value.
    @Test func sampledSpanMatchesTrimMath() {
        #expect(PerceptualFingerprinter.sampledSpan(durationSeconds: 100) == 90)
        #expect(PerceptualFingerprinter.sampledSpan(durationSeconds: 0) == 0.001)
    }

    // Pin the production constants: the statistical comments and the
    // verdict gates are written for n = 32, and minimumFrames must
    // track the verdict gate so the fingerprinter never hands compare()
    // a sequence it would refuse to judge.
    @Test func productionConstantsPinned() {
        #expect(PerceptualFingerprinter.frameCount == 32)
        #expect(PerceptualFingerprinter.minimumFrames == PerceptualHash.minFramesForVerdict)
        #expect(PerceptualFingerprinter.trimFraction == 0.05)
    }
}

// MARK: - Env-gated integration (real ffmpeg)
//
// Opt-in with VS_RUN_PERCEPTUAL=1, same pattern as VS_RUN_WHISPER:
// re-encode a repo fixture to H.264 in a temp dir, fingerprint both,
// and require the perceptual model to call them the same content.
// This is the DV-vs-H.264 scenario the whole feature exists for.

@Suite("PerceptualFingerprinter integration",
       .enabled(if: ProcessInfo.processInfo.environment["VS_RUN_PERCEPTUAL"] == "1"))
struct PerceptualFingerprinterIntegrationTests {

    /// First usable fixture clip in tests/fixtures/videos (repo-relative
    /// from the test bundle's source root is unreliable; walk up from cwd
    /// candidates the way other fixture-using tests do).
    private func fixtureClip() -> URL? {
        let candidates = [
            URL(fileURLWithPath: #filePath)              // …/VideoScan/VideoScanTests/x.swift
                .deletingLastPathComponent()             // VideoScanTests
                .deletingLastPathComponent()             // VideoScan (xcodeproj dir)
                .deletingLastPathComponent()             // repo root
                .appendingPathComponent("tests/fixtures/videos")
        ]
        for dir in candidates {
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil)) ?? []
            if let clip = contents.first(where: {
                ["mov", "mp4", "mts", "avi", "dv", "mxf"].contains($0.pathExtension.lowercased())
            }) {
                return clip
            }
        }
        return nil
    }

    @Test func reencodedCopyIsRecognizedAsSameContent() async throws {
        let ffmpeg = ToolLocator.ffmpegPath
        let original = try #require(fixtureClip(), "no fixture video found")

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vs-perceptual-itest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Re-encode: different codec, half resolution, new container.
        let reencoded = dir.appendingPathComponent("reencoded.mp4")
        let enc = await ProcessRunner.runProcess(
            executable: ffmpeg,
            arguments: ["-nostdin", "-v", "error",
                        "-i", original.path,
                        "-an",
                        "-c:v", "libx264", "-crf", "30",
                        "-vf", "scale=iw/2:-2",
                        "-y", reencoded.path])
        try #require(enc.exitCode == 0, "fixture re-encode failed: \(enc.stderr)")

        // Probe the duration the way the comparator gets it (catalog).
        let probe = await ProcessRunner.runProcess(
            executable: ToolLocator.ffprobePath,
            arguments: ["-v", "error", "-show_entries", "format=duration",
                        "-of", "default=nw=1:nk=1", original.path])
        let duration = Double(
            (probe.stdout ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        try #require(duration > 0, "could not probe fixture duration")

        let fpA = try await PerceptualFingerprinter.fingerprint(
            ffmpegPath: ffmpeg, path: original.path,
            durationSeconds: duration, onFraction: { _ in })
        let fpB = try await PerceptualFingerprinter.fingerprint(
            ffmpegPath: ffmpeg, path: reencoded.path,
            durationSeconds: duration, onFraction: { _ in })

        let stats = PerceptualHash.compare(fpA, fpB)
        #expect(stats.isMatch,
                "re-encode should match: \(stats.summary)")
    }
}
