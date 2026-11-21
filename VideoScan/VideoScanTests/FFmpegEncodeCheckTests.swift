// FFmpegEncodeCheckTests.swift
// Archive Angel robustness pass (2026-09-19). A failed or truncated ffmpeg
// encode used to be published as "done": TranscodeJob threw away the exit
// status and only checked "≥ 10 KB". Logic tests for FFmpegEncodeCheck,
// then real-media tests whose encode is answered by a ScriptedExecutor bound
// to the test's own task tree (ffprobe and fixtures run for real), so the
// suite runs in parallel — it used to be serialized around a process-global
// VS_FFMPEG_PATH fake.

import Foundation
import Testing
@testable import VideoScan

@Suite("ffmpeg encode verdict — logic")
struct FFmpegEncodeCheckLogicTests {
    @Test func zeroExitIsNotAFailure() {
        #expect(FFmpegEncodeCheck.exitFailure(exitCode: 0, stderr: "Conversion failed!") == nil)
    }

    @Test func nonZeroExitNamesFfmpegsLastWordsNotItsProgress() {
        let stderr = """
        Input #0, mov, from 'tape.mov':
        frame=  120 fps= 60 q=28.0 size=    1024kB time=00:00:04.00
        [out#0/mov @ 0x1] Error writing trailer: No space left on device
        size=    2048kB time=00:00:05.00

        """
        let reason = FFmpegEncodeCheck.exitFailure(exitCode: 228, stderr: stderr)
        #expect(reason == "ffmpeg stopped with exit code 228 — [out#0/mov @ 0x1] Error writing trailer: No space left on device")
        #expect(FFmpegEncodeCheck.exitFailure(exitCode: 1, stderr: "") == "ffmpeg stopped with exit code 1")
    }

    @Test func shortOutputFailsLongEnoughPasses() {
        typealias C = FFmpegEncodeCheck
        #expect(C.durationShortfall(sourceSeconds: 3600, outputSeconds: 1800)
                == "the output runs 30:00 but the source runs 1:00:00 — the encode stopped early")
        // Within tolerance: max(3 s, 3 %).
        #expect(C.durationShortfall(sourceSeconds: 3600, outputSeconds: 3600 - 100) == nil)
        #expect(C.durationShortfall(sourceSeconds: 10, outputSeconds: 7.5) == nil)
        #expect(C.durationShortfall(sourceSeconds: 10, outputSeconds: 6.9) != nil)
        // Longer output (audio tail) is fine.
        #expect(C.durationShortfall(sourceSeconds: 60, outputSeconds: 61) == nil)
    }

    @Test func anUnmeasurableLengthIsNeverAVerdict() {
        typealias C = FFmpegEncodeCheck
        #expect(C.durationShortfall(sourceSeconds: nil, outputSeconds: 5) == nil)
        #expect(C.durationShortfall(sourceSeconds: 60, outputSeconds: nil) == nil)
        #expect(C.durationShortfall(sourceSeconds: 0, outputSeconds: 1) == nil)
    }
}

/// Real ffmpeg for fixtures; a scripted encode for the failures.
@Suite("ffmpeg encode verdict — a failed encode is never published")
struct FFmpegEncodeFailureTests {
    static let realFFmpeg = ToolLocator.ffmpegPath

    /// A 12-second synthetic tape (test pattern + tone), mov/h264 + aac.
    private func makeSource(in dir: URL) async throws -> URL {
        let src = dir.appendingPathComponent("test_tape.mov")
        let r = await ProcessRunner.runProcess(
            executable: Self.realFFmpeg,
            arguments: ["-hide_banner", "-loglevel", "error", "-y",
                        "-f", "lavfi", "-i", "testsrc=size=320x240:rate=30:duration=12",
                        "-f", "lavfi", "-i", "sine=frequency=440:duration=12",
                        "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", src.path],
            deadlineSeconds: 120)
        try #require(r.exitCode == 0, "fixture: \(r.stderr)")
        return src
    }

    /// The encode of this test's tape answers with `encode`; every other
    /// command (ffprobe's length checks) runs the real tool.
    private func mock(_ encode: ScriptedExecutor.Behaviour, sandbox: MasterArchiveTestSupport.Sandbox) -> ScriptedExecutor {
        ScriptedExecutor(claiming: [sandbox.root.path])
            .on("ffmpeg", containing: ["test_tape.mov"], encode)
            .on("*", .passThrough)
    }

    @MainActor
    private func run(source: URL, mock: ScriptedExecutor?, sandbox: MasterArchiveTestSupport.Sandbox) async -> (TranscodeJob, URL) {
        let model = MasterArchiveTestSupport.makeModel(sandbox)
        let rec = MasterArchiveTestSupport.makeRecord(path: source.path)
        rec.durationSeconds = 12
        let out = sandbox.root.appendingPathComponent("test_tape.vs.archive.mov")
        let job = TranscodeJob(record: rec, preset: .archival, outputURL: out, model: model)
        guard let mock else {
            job.start()
            await job.task?.value
            return (job, out)
        }
        await mock.scoped {
            job.start()   // the job's Task {} inherits the mock
            await job.task?.value
        }
        #expect(mock.calls(to: "ffmpeg", containing: ["test_tape.mov"]).count == 1, "\(mock.calls)")
        return (job, out)
    }

    /// A real, playable clip of `seconds` (mov/h264), made outside any mock.
    private func clip(seconds: Int, in dir: URL) async throws -> URL {
        let url = dir.appendingPathComponent("test_clip_\(seconds)s.mov")
        let r = await ProcessRunner.runProcess(
            executable: Self.realFFmpeg,
            arguments: ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi",
                        "-i", "testsrc=size=320x240:rate=30:duration=\(seconds)",
                        "-c:v", "libx264", "-pix_fmt", "yuv420p", "-f", "mov", url.path],
            deadlineSeconds: 120)
        try #require(r.exitCode == 0, "fixture: \(r.stderr)")
        return url
    }

    @Test @MainActor func aNonZeroExitWithAPlausibleFileIsAFailure() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("encode_exit"); defer { sb.cleanup() }
        let src = try await makeSource(in: sb.sources)
        // 20 KB of junk (passes the old ≥10 KB gate), then "disk full".
        let encode = mock(.writeOutputFile(Data(count: 20_000),
                                           stderr: "[out#0/mov @ 0x1] Error writing trailer: No space left on device\n",
                                           exit: 228), sandbox: sb)
        let (job, out) = await run(source: src, mock: encode, sandbox: sb)
        guard case .failed(let reason) = job.state else {
            Issue.record("a failed encode was published: \(job.state)"); return
        }
        #expect(reason.contains("exit code 228") && reason.contains("No space left on device"), Comment(rawValue: reason))
        #expect(!FileManager.default.fileExists(atPath: out.path), "nothing published")
        #expect(!FileManager.default.fileExists(atPath: ReformatJob.partialURL(for: out).path), "partial removed")
    }

    @Test @MainActor func aCleanExitWithATruncatedFileIsAFailure() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("encode_short"); defer { sb.cleanup() }
        let src = try await makeSource(in: sb.sources)
        // A real, playable file — but 2 s of a 12 s tape — and exit 0.
        let short = try await clip(seconds: 2, in: sb.root)
        let (job, out) = await run(source: src, mock: mock(.copyToOutputFile(short), sandbox: sb), sandbox: sb)
        guard case .failed(let reason) = job.state else {
            Issue.record("a truncated encode was published: \(job.state)"); return
        }
        #expect(reason.contains("stopped early") && reason.contains("0:02") && reason.contains("0:12"), Comment(rawValue: reason))
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    /// Control: the real encoder on the same tape still publishes — the
    /// check does not invent failures.
    @Test @MainActor func aRealEncodeStillPublishes() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("encode_ok"); defer { sb.cleanup() }
        let src = try await makeSource(in: sb.sources)
        let (job, out) = await run(source: src, mock: nil, sandbox: sb)
        guard case .finished = job.state else { Issue.record("a good encode was rejected: \(job.state)"); return }
        #expect(FileManager.default.fileExists(atPath: out.path))
    }
}
