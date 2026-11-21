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

import Darwin
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
            #expect(EraCanary.runBlocking(b.ffmpeg, ["-version"], environment: b.environment) == "exit 11")
        }
    }

    @Test("FAILURE: an ffmpeg that cannot be started says so, and is not reported as the file's fault")
    func launchFailureIsNamed() async throws {
        let b = try bench()
        defer { try? FileManager.default.removeItem(at: b.root) }
        let mock = ScriptedExecutor(claiming: [b.root.path]).on("ffmpeg", .launchFailure)
        await mock.scoped {
            let why = EraCanary.runBlocking(b.ffmpeg, ["-version"], environment: b.environment)
            #expect(why?.hasPrefix("could not start \(b.ffmpeg): ") == true, "\(why ?? "nil")")
        }
    }

    @Test("FAILURE: an ffmpeg that hangs is stopped at the cap and named \"ran past\" — through the runner's real deadline")
    func hangIsStoppedAtTheCap() async throws {
        let b = try bench()
        defer { try? FileManager.default.removeItem(at: b.root) }
        let mock = ScriptedExecutor(claiming: [b.root.path]).on("ffmpeg", .hang(maxSeconds: 20))
        await mock.scoped {
            let why = EraCanary.$capSeconds.withValue(0.4) {
                EraCanary.runBlocking(b.ffmpeg, ["-version"], environment: b.environment)
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

    @Test("the job-time check AWAITS the runner (no blocking bridge from async code): same still command, and a hang is named")
    func jobTimeCheckIsAsync() async throws {
        let b = try bench()
        defer { try? FileManager.default.removeItem(at: b.root) }
        let mock = ScriptedExecutor(claiming: [b.root.path])
            .on("ffmpeg", .sequence([.writeOutputFile(Data([1])), .writeOutputFile(Data([1])),      // init: clip, still
                                     .writeOutputFile(Data([2])),                                    // job-time: a still
                                     .hang(maxSeconds: 20)]))                                        // job-time: wedged
        try await mock.scoped {
            let canary = try EraCanary(environment: b.environment, stateRoot: b.root)
            #expect(await canary.toolWorks(environment: b.environment) == nil)
            #expect(!FileManager.default.fileExists(atPath: b.still), "the still is removed after the check")
            let why = await EraCanary.$capSeconds.withValue(0.4) { await canary.toolWorks(environment: b.environment) }
            #expect(why == "\(b.ffmpeg) ran past 0 s")
        }
        #expect(mock.calls.count == 4)
        #expect(mock.calls.dropFirst().allSatisfy { $0.arguments == ["-nostdin", "-loglevel", "error", "-y", "-ss", "1.000", "-i", b.clip,
                                                                    "-frames:v", "1", "-vf", Self.stillFilter, b.still]
                                                     && $0.environment == b.environment })
    }

    @Test("BRIDGE (Codex r1 P2): the blocking wait has its own bound — a child whose descendant holds the pipes open cannot hold the caller",
          .tags(.quietMachine))   // it judges elapsed time (0.8 s bound vs 4 s of held pipes): serial phase
    func blockingWaitIsBoundedIndependently() {
        // The shell exits at once; its background sleep keeps the pipes open
        // for 4 s, so the runner drains for 4 s and its deadline callbacks
        // find no child to kill. Bound: 0.1 + 2 x 0.1 + 0.5 margin = 0.8 s.
        let clock = ContinuousClock()
        let started = clock.now
        let result = ProcessRunner.runProcessBlocking(executable: "/bin/sh", arguments: ["-c", "/bin/sleep 4 & exit 0"],
                                                      deadlineSeconds: 0.1, killGraceSeconds: 0.1)
        let waited = clock.now - started
        // 0.8 s bound vs the 4 s the pipes stay open; 3 s leaves 3.7x slack.
        expectBudget(waited, under: .seconds(3), "the caller was held \(waited) — until the descendant closed the pipes")
        #expect(result.timedOut && result.exitCode == -1 && !result.launched)
        #expect(result.stderr.contains("stopped waiting"), "\(result.stderr)")
    }

    @Test("BRIDGE (Codex r1 P2): work that has not started when the wait expires is cancelled — it never launches later")
    func expiredWaitCancelsPendingWork() async {
        // The mock holds the command for 1.5 s before "launching"; the
        // bridge's bound is 0.1 + 0.2 + 0.5 = 0.8 s. After the wait expires
        // the work is cancelled, so the delayed launch never happens.
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("bridge-late-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let mock = ScriptedExecutor(claiming: [marker.path])
            .on("touch", .after(.milliseconds(1500), then: .passThrough))
        await mock.scoped {
            let result = ProcessRunner.runProcessBlocking(executable: "/usr/bin/touch", arguments: [marker.path],
                                                          deadlineSeconds: 0.1, killGraceSeconds: 0.1)
            #expect(result.timedOut && !result.launched && result.exitCode == -1,
                    "the bridge's own timeout, whatever the cancelled work goes on to publish")
            try? await Task.sleep(for: .milliseconds(2200))
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path), "the command launched after the caller had stopped waiting")
    }

    /// Set once; read from another thread. (C++: std::atomic<bool>.)
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var on = false
        func set() { lock.lock(); on = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return on }
    }

    @Test("BRIDGE (Codex r2 P2): the result the cancelled work publishes after the wait expired is never the bridge's answer — it is its own timeout")
    func aCancellationResultPublishedAfterExpiryIsNotTheAnswer() async {
        // Gated, so the ordering is forced, not hoped for: the command waits
        // until it is CANCELLED (which only the bridge's expiry does), then
        // answers at once with the runner's cancellation shape (exit 15,
        // launched, timedOut == false) and raises `answered`. The probe
        // holds the bridge on its expiry path until `answered` is up and the
        // work has had time to publish — so "cancel, THEN look in the box"
        // is certain to find that result.
        let answered = Flag()
        let mock = ScriptedExecutor().on("gated-tool", .custom { _ in
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            answered.set()
            return ProcessRunner.Result(stdout: "", stderr: "", exitCode: SIGTERM, timedOut: false, launched: true)
        })
        let probe: @Sendable () -> Void = {
            for _ in 0..<2000 where !answered.isSet { usleep(1_000) }
            usleep(200_000)                                   // …and published
        }
        await mock.scoped {
            let result = ProcessRunner.$blockingExpiryProbe.withValue(probe) {
                ProcessRunner.runProcessBlocking(executable: "/nonexistent/gated-tool", arguments: [],
                                                 deadlineSeconds: 0.1, killGraceSeconds: 0.1)
            }
            #expect(answered.isSet, "the gate never opened: the bridge did not cancel the work")
            #expect(result.timedOut, "the bridge returned the cancelled work's result (exit \(result.exitCode), launched \(result.launched)) instead of its own timeout")
            #expect(result.exitCode == -1 && !result.launched)
            #expect(result.stderr.contains("stopped waiting"))
        }
        #expect(mock.calls.count == 1)
    }

    @Test("BRIDGE: a result that lands in time is returned as it is — never turned into a timeout")
    func aResultInTimeIsReturnedAsIs() async {
        let mock = ScriptedExecutor().on("quick-tool", .after(.milliseconds(300), then: .output(stdout: "done\n", exit: 3)))
        await mock.scoped {
            let result = ProcessRunner.runProcessBlocking(executable: "/nonexistent/quick-tool", arguments: [],
                                                          deadlineSeconds: 0.1, killGraceSeconds: 0.1)   // bound 0.8 s
            #expect(!result.timedOut && result.launched && result.exitCode == 3 && result.stdout == "done\n")
        }
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
