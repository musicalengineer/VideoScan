// EraCanaryCommandTests.swift — EraCanary's two ffmpeg commands go through
// ProcessRunner (2026-11-21; it was a hand-rolled Process()), so a
// ScriptedExecutor answers them: the exact command lines are pinned
// (EXPECT_CALL style on `mock.calls`) and every way the tool can fail is
// named in words, without a real ffmpeg.
//
//   COMMAND   the clip and the still: executable, argv and environment, exactly
//   FAILURE   nonzero exit (the last stderr line) · launch failure · ran past
//             the cap · exit 0 with no still
//   BRIDGE    ProcessRunner.runProcessBlocking keeps the caller's mock (a
//             synchronous caller's command must not escape to the real tool)
// Parallel by design: each test has its own scratch directory and mock.

import Foundation
import Testing
@_spi(Testing) @testable import VideoScanCore

@Suite("EraCanary — the ffmpeg commands through the executor seam", .timeLimit(.minutes(1)))
struct EraCanaryCommandTests {

    struct Bench {
        let root: URL
        let ffmpeg: String
        let environment: [String: String]
        var clip: String { root.appendingPathComponent("canary/canary.mp4").path }
        var still: String { root.appendingPathComponent("canary/still.png").path }
    }

    /// A state root and a PATH whose only `ffmpeg` is an executable
    /// placeholder that is never run (every command is answered by the mock;
    /// the escape guard would refuse it).
    func bench() throws -> Bench {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eracanary-cmd-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let ffmpeg = bin.appendingPathComponent("ffmpeg").path
        try Data("#!/bin/sh\nexit 97\n".utf8).write(to: URL(fileURLWithPath: ffmpeg))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ffmpeg)
        return Bench(root: root, ffmpeg: ffmpeg, environment: ["PATH": bin.path, "ERA_TEST_MARK": "kept"])
    }

    static let stillFilter = "scale=448:448:force_original_aspect_ratio=decrease,pad=448:448:(ow-iw)/2:(oh-ih)/2:color=black"

    @Test("COMMAND: the clip and the still are issued with exactly the argv and environment the hand-rolled spawn used")
    func theTwoCommandLines() async throws {
        let b = try bench()
        defer { try? FileManager.default.removeItem(at: b.root) }
        let mock = ScriptedExecutor(claiming: [b.root.path])
            .on("ffmpeg", .writeOutputFile(Data([0x89, 0x50])))
        try await mock.scoped {
            let canary = try EraCanary(environment: b.environment, stateRoot: b.root)
            #expect(canary.ffmpeg == b.ffmpeg)
        }
        #expect(mock.calls.count == 2)
        guard mock.calls.count == 2 else { return }
        #expect(mock.calls[0].executable == b.ffmpeg)
        #expect(mock.calls[0].arguments == ["-nostdin", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
                                            "testsrc=size=320x240:rate=25:duration=2",
                                            "-c:v", "mpeg4", "-q:v", "5", b.clip])
        #expect(mock.calls[0].environment == b.environment)
        #expect(mock.calls[1].executable == b.ffmpeg)
        #expect(mock.calls[1].arguments == ["-nostdin", "-loglevel", "error", "-y", "-ss", "1.000", "-i", b.clip,
                                            "-frames:v", "1", "-vf", Self.stillFilter, b.still])
        #expect(mock.calls[1].environment == b.environment)
    }

    @Test("FAILURE: a nonzero exit refuses at START with ffmpeg's last stderr line, and no still is attempted")
    func nonzeroExitIsNamed() async throws {
        let b = try bench()
        defer { try? FileManager.default.removeItem(at: b.root) }
        let mock = ScriptedExecutor(claiming: [b.root.path])
            .on("ffmpeg", .output(stderr: "dyld: warning\n  Library not loaded: libx264.165.dylib  \n\n", exit: 134))
        await mock.scoped {
            do {
                _ = try EraCanary(environment: b.environment, stateRoot: b.root)
                Issue.record("a broken ffmpeg was accepted")
            } catch let refusal as Refusal {
                #expect(refusal.words.contains("cannot make a 2 s synthetic clip"))
                #expect(refusal.words.hasSuffix("Library not loaded: libx264.165.dylib"), "\(refusal.words)")
            } catch {
                Issue.record("not a Refusal: \(error)")
            }
        }
        #expect(mock.calls.count == 1, "the still is not ripped from a clip that was never made")
    }

    @Test("FAILURE: a nonzero exit with nothing on stderr is named by its exit status")
    func silentNonzeroExitIsNamed() async throws {
        let b = try bench()
        defer { try? FileManager.default.removeItem(at: b.root) }
        let mock = ScriptedExecutor(claiming: [b.root.path]).on("ffmpeg", .crash(signal: 11))
        await mock.scoped {
            #expect(EraCanary.run(b.ffmpeg, ["-version"], environment: b.environment) == "exit 11")
        }
    }

    @Test("FAILURE: an ffmpeg that cannot be started says so, and is not reported as the file's fault")
    func launchFailureIsNamed() async throws {
        let b = try bench()
        defer { try? FileManager.default.removeItem(at: b.root) }
        let mock = ScriptedExecutor(claiming: [b.root.path]).on("ffmpeg", .launchFailure)
        await mock.scoped {
            let why = EraCanary.run(b.ffmpeg, ["-version"], environment: b.environment)
            #expect(why?.hasPrefix("could not start \(b.ffmpeg): ") == true, "\(why ?? "nil")")
        }
    }

    @Test("FAILURE: an ffmpeg that hangs is stopped at the cap and named \"ran past\" — through the runner's real deadline")
    func hangIsStoppedAtTheCap() async throws {
        let b = try bench()
        defer { try? FileManager.default.removeItem(at: b.root) }
        let mock = ScriptedExecutor(claiming: [b.root.path]).on("ffmpeg", .hang())
        await mock.scoped {
            let why = EraCanary.$capSeconds.withValue(0.4) {
                EraCanary.run(b.ffmpeg, ["-version"], environment: b.environment)
            }
            #expect(why == "\(b.ffmpeg) ran past 0 s", "the bound 0.4 s cap ended it (the suite time limit would catch the 60 s default)")
        }
    }

    @Test("FAILURE: exit 0 with no still written is not a pass")
    func exitZeroWithoutAStill() async throws {
        let b = try bench()
        defer { try? FileManager.default.removeItem(at: b.root) }
        let mock = ScriptedExecutor(claiming: [b.root.path])
            .on("ffmpeg", containing: ["lavfi"], .writeOutputFile(Data([1])))
            .on("ffmpeg", .output())
        await mock.scoped {
            do {
                _ = try EraCanary(environment: b.environment, stateRoot: b.root)
                Issue.record("exit 0 with no still was accepted")
            } catch {
                #expect("\(error)".contains("ffmpeg exited 0 and wrote no still"), "\(error)")
            }
        }
        #expect(mock.calls.count == 2)
    }

    @Test("BRIDGE: outside any mock the blocking form really runs, bounded by its deadline")
    func blockingFormRunsForReal() {
        let ok = ProcessRunner.runProcessBlocking(executable: "/bin/echo", arguments: ["blocking-real"], deadlineSeconds: 20)
        #expect(ok.launched && ok.exitCode == 0 && ok.stdout == "blocking-real\n")
        let slow = ProcessRunner.runProcessBlocking(executable: "/bin/sleep", arguments: ["30"],
                                                    deadlineSeconds: 0.3, killGraceSeconds: 1)
        #expect(slow.timedOut && slow.exitCode != 0)
        let missing = ProcessRunner.runProcessBlocking(executable: "/nonexistent/tool-\(UUID().uuidString)",
                                                       arguments: [], deadlineSeconds: 5)
        #expect(!missing.launched && missing.exitCode == -1)
    }
}
