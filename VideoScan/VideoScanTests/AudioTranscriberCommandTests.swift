// AudioTranscriberCommandTests.swift — PythonSubprocessAudioTranscriber's
// one-shot python command goes through ProcessRunner (2026-11-21; it was a
// hand-rolled Process() with its own deadline poll and kill escalation), so
// a ScriptedExecutor answers it — no python, no model, no real media.
//
//   COMMAND   executable, argv and environment, exactly
//   FAILURE   nonzero exit (with the END of stderr) · cannot start · hang
//             to the deadline · hang + cancel (Skip) · exit 0 with no
//             transcript — each its own named error, none a transcript
//   BOUND     the kept stderr is the last 64 KB, not the first
// The interpreter and the script are placeholder files (never run); the
// "tape" is bytes AVFoundation cannot open, so the audio preflight asks
// ffprobe — which the mock answers.
// Parallel by design: each test has its own scratch directory and mock.

import Foundation
import Testing
@testable import VideoScan
@_spi(Testing) import VideoScanCore

@Suite("Python transcriber — the command through the executor seam", .timeLimit(.minutes(1)))
struct AudioTranscriberCommandTests {

    struct Bench {
        let dir: URL
        let python: String
        let script: String
        let video: String
        var runner: PythonSubprocessAudioTranscriber { PythonSubprocessAudioTranscriber(pythonPath: python, scriptPath: script) }

        /// A strict mock whose ffprobe says "one audio stream".
        func mock() -> ScriptedExecutor {
            ScriptedExecutor(claiming: [dir.path]).on("ffprobe", .output(stdout: "1\n"))
        }
        func cleanup() { try? FileManager.default.removeItem(at: dir) }
    }

    /// nil when ffprobe is not installed (the preflight then cannot admit a
    /// file AVFoundation cannot open, and no python command is issued).
    func bench() throws -> Bench? {
        guard FileManager.default.isExecutableFile(atPath: ToolLocator.ffprobePath) else {
            Issue.record("ffprobe not found — the audio preflight cannot reach the python command")
            return nil
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcriber-cmd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let b = Bench(dir: dir, python: dir.appendingPathComponent("python3").path,
                      script: dir.appendingPathComponent("whisper_transcribe.py").path,
                      video: dir.appendingPathComponent("tape.mkv").path)
        try Data("#!/bin/sh\nexit 97\n".utf8).write(to: URL(fileURLWithPath: b.python))
        try Data("raise SystemExit(97)\n".utf8).write(to: URL(fileURLWithPath: b.script))
        try Data(repeating: 0x5A, count: 4096).write(to: URL(fileURLWithPath: b.video))   // not a container
        return b
    }

    @Test("COMMAND: python is issued once with exactly the argv and environment the hand-rolled spawn used; the transcript is trimmed")
    func theCommandLine() async throws {
        guard let b = try bench() else { return }
        defer { b.cleanup() }
        let mock = b.mock().on("python3", .writeOutputFile(Data("  hello from the tape \n".utf8)))
        let text = try await mock.scoped { try await b.runner.transcribe(videoPath: b.video, deadlineSeconds: 120) }
        #expect(text == "hello from the tape")

        let calls = mock.calls(to: "python3")
        #expect(calls.count == 1)
        guard let call = calls.first else { return }
        #expect(call.executable == b.python)
        #expect(call.arguments.count == 7)
        #expect(Array(call.arguments.prefix(6)) == ["-u", b.script, b.video, "--model", "mlx-community/whisper-medium-mlx-q4", "--out"])
        #expect(call.arguments.last?.hasSuffix("/transcript.txt") == true)
        #expect(call.arguments.last?.contains("/vs-transcribe-") == true)

        // The app's environment, plus exactly two changes.
        var expected = ProcessInfo.processInfo.environment
        expected["PYTHONUNBUFFERED"] = "1"
        expected["PATH"] = augmentedPathWithHomebrew(inheriting: ProcessInfo.processInfo.environment["PATH"])
        #expect(call.environment == expected)
        #expect(call.environment?["PATH"]?.hasPrefix("/opt/homebrew/bin:") == true)

        // The scratch directory the transcript was written to is gone.
        if let out = call.arguments.last {
            #expect(!FileManager.default.fileExists(atPath: (out as NSString).deletingLastPathComponent))
        }
    }

    @Test("FAILURE: a nonzero exit is subprocessFailed with the exit code and python's last words")
    func nonzeroExit() async throws {
        guard let b = try bench() else { return }
        defer { b.cleanup() }
        let mock = b.mock().on("python3", .output(stdout: "loading model\n",
                                                  stderr: "Traceback (most recent call last):\n  File \"x.py\"\nValueError: boom\n", exit: 6))
        await mock.scoped {
            do {
                _ = try await b.runner.transcribe(videoPath: b.video, deadlineSeconds: 120)
                Issue.record("a failed python returned a transcript")
            } catch AudioTranscriberError.subprocessFailed(let code, let tail) {
                #expect(code == 6)
                #expect(tail.hasSuffix("ValueError: boom"), "\(tail)")
                #expect(tail.contains("Traceback"))
            } catch {
                Issue.record("wrong error: \(error)")
            }
        }
    }

    @Test("FAILURE: an interpreter that cannot be started is subprocessLaunchFailed, not a model failure")
    func launchFailure() async throws {
        guard let b = try bench() else { return }
        defer { b.cleanup() }
        let mock = b.mock().on("python3", .launchFailure)
        await mock.scoped {
            do {
                _ = try await b.runner.transcribe(videoPath: b.video, deadlineSeconds: 120)
                Issue.record("an unlaunchable python returned a transcript")
            } catch AudioTranscriberError.subprocessLaunchFailed(let reason) {
                #expect(!reason.isEmpty)
            } catch {
                Issue.record("wrong error: \(error)")
            }
        }
    }

    @Test("FAILURE: a python that hangs is stopped at the deadline and reported deadlineExceeded — not subprocessFailed")
    func hangToTheDeadline() async throws {
        guard let b = try bench() else { return }
        defer { b.cleanup() }
        let mock = b.mock().on("python3", .hang(stderr: "loading weights…"))
        let started = ContinuousClock.now
        await mock.scoped {
            do {
                _ = try await b.runner.transcribe(videoPath: b.video, deadlineSeconds: 0.6)
                Issue.record("a hung python returned a transcript")
            } catch AudioTranscriberError.deadlineExceeded(let seconds) {
                #expect(seconds == 0.6)
            } catch {
                Issue.record("wrong error: \(error)")
            }
        }
        #expect(ContinuousClock.now - started < .seconds(20))
    }

    @Test("FAILURE: Skip (task cancellation) stops a running python and surfaces CancellationError")
    func cancelStopsIt() async throws {
        guard let b = try bench() else { return }
        defer { b.cleanup() }
        let mock = b.mock().on("python3", .hang())
        let runner = b.runner
        let video = b.video
        let task = Task { try await mock.scoped { try await runner.transcribe(videoPath: video, deadlineSeconds: 600) } }
        for _ in 0..<1000 where mock.calls(to: "python3").isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(mock.calls(to: "python3").count == 1, "python was never started")
        let started = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("a cancelled transcription returned a transcript")
        } catch is CancellationError {
            // expected
        } catch {
            Issue.record("wrong error: \(error)")
        }
        #expect(ContinuousClock.now - started < .seconds(15), "the 600 s deadline was not what ended it")
    }

    @Test("FAILURE: exit 0 with no transcript file is an error, never an empty transcript")
    func exitZeroWithoutATranscript() async throws {
        guard let b = try bench() else { return }
        defer { b.cleanup() }
        let mock = b.mock().on("python3", .output(stdout: "done\n"))
        await mock.scoped {
            do {
                let text = try await b.runner.transcribe(videoPath: b.video, deadlineSeconds: 120)
                Issue.record("no transcript file, yet a transcript was returned: \(text.debugDescription)")
            } catch AudioTranscriberError.underlying {
                // expected: the file the script should have written is not there
            } catch {
                Issue.record("wrong error: \(error)")
            }
        }
    }

    @Test("BOUND: the kept stderr is the LAST 64 KB (where the cause is), however much python printed")
    func stderrTailIsBounded() async throws {
        guard let b = try bench() else { return }
        defer { b.cleanup() }
        let noise = (0..<6000).map { "tqdm progress line number \($0) of a chatty model load ........" }.joined(separator: "\n")
        #expect(noise.utf8.count > 300_000)
        let mock = b.mock().on("python3", .output(stderr: noise + "\nRuntimeError: the real cause\n", exit: 1))
        await mock.scoped {
            do {
                _ = try await b.runner.transcribe(videoPath: b.video, deadlineSeconds: 120)
                Issue.record("expected a failure")
            } catch AudioTranscriberError.subprocessFailed(_, let tail) {
                #expect(tail.utf8.count <= 64 * 1024, "\(tail.utf8.count) bytes kept")
                #expect(tail.utf8.count > 60 * 1024)
                #expect(tail.hasSuffix("RuntimeError: the real cause"))
                #expect(!tail.contains("line number 0 of"))
            } catch {
                Issue.record("wrong error: \(error)")
            }
        }
    }

    @Test("python's stdout lines reach the app log, tagged with the file's name")
    func stdoutGoesToTheLog() async throws {
        guard let b = try bench() else { return }
        defer { b.cleanup() }
        let sink = InMemoryLogSink()
        let mock = b.mock().on("python3", .custom { request in
            request.stdoutLine?("decoding audio")
            request.stdoutLine?("window 3/9")
            if let out = request.arguments.last { try? Data("words".utf8).write(to: URL(fileURLWithPath: out)) }
            return ProcessRunner.Result(stdout: "", stderr: "", exitCode: 0, launched: true)
        })
        let text = try await withAppLog(sink) {
            try await mock.scoped { try await b.runner.transcribe(videoPath: b.video, deadlineSeconds: 120) }
        }
        #expect(text == "words")
        #expect(sink.contains("whisper[tape.mkv]: decoding audio"))
        #expect(sink.contains("whisper[tape.mkv]: window 3/9"))
        #expect(sink.contains("AudioTranscriber(Python) transcribed tape.mkv — 5 chars"))
    }
}
