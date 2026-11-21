
// CommandExecutorSeamReviewTests.swift — review of feat/command-executor-seam
// (84a8e30e0). Each test is RED on that commit and names the line it pins.

import Darwin
import Foundation
import Testing
@testable import VideoScanCore

@Suite("CommandExecutor seam — review findings (red on 84a8e30e0)")
struct CommandExecutorSeamReviewTests {

    // Pins CommandExecutor.swift:150 — `tokens.filter { !$0.isEmpty }` is the
    // only check on a claim. A claim of "/" (or "/tmp", or "mov") is
    // contained in almost every command line, so while that mock is
    // installed the process-wide guard refuses REAL commands of tests that
    // have nothing to do with it (the detached task stands in for a parallel
    // test outside the mocked tree) and files the "escape" against the
    // wrong test.
    @Test("a claim too short to be unique to one test is rejected, not allowed to refuse a bystander's real command",
          arguments: ["/", "/tmp", "mov"])
    func aVagueClaimCannotRefuseABystander(claim: String) async {
        let mock = ScriptedExecutor(claiming: [claim]).on("*", .output())
        let bystander = await mock.withInstalled {
            await Task.detached {
                await ProcessRunner.runProcess(executable: "/bin/echo", arguments: ["/tmp/bystander.mov"])
            }.value
        }
        #expect(bystander.launched && bystander.stdout == "/tmp/bystander.mov\n",
                "claim \(claim.debugDescription) refused an unrelated real command: \(bystander.stderr)")
        #expect(mock.failures.contains { $0.contains("claim") },
                "the vague claim itself should be the reported failure: \(mock.failures)")
    }

    // Pins ScriptedExecutor.swift:74-80 and :237 — `.hang()` promises
    // "exactly the Result a wedged tool produces", but its child is
    // /bin/sleep, which dies OF SIGTERM (exit 15). ffmpeg installs a SIGTERM
    // handler and EXITS (255), so 15 is a shape the real tool never returns.
    static let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }

    @Test(".hang() + deadline returns the exit code a real, still-running ffmpeg returns when the runner's deadline SIGTERMs it",
          .enabled(if: ffmpeg != nil))
    func hangMatchesARealFFmpegKilledAtTheDeadline() async throws {
        let ffmpeg = try #require(Self.ffmpeg)
        let real = await ProcessRunner.runProcess(
            executable: ffmpeg,
            arguments: ["-hide_banner", "-nostdin", "-re", "-f", "lavfi", "-i", "testsrc=rate=1", "-f", "null", "-"],
            deadlineSeconds: 1.0, killGraceSeconds: 5)
        let mock = await ScriptedExecutor().on("ffmpeg", .hang()).withInstalled {
            await ProcessRunner.runProcess(executable: ffmpeg, arguments: ["-i", "x"], deadlineSeconds: 1.0, killGraceSeconds: 5)
        }
        #expect(real.timedOut && real.launched && mock.timedOut && mock.launched)
        #expect(mock.exitCode == real.exitCode, "mock .hang exit \(mock.exitCode), real ffmpeg exit \(real.exitCode)")
    }

    // Pins CommandExecutor.swift:109, :131, :138-157 — the binding and the
    // claim registry are `public`, so any app/helper/CLI source can bind an
    // executor or register a claim that makes the REAL executor refuse
    // production commands. Only ScriptedExecutor (same module) needs them.
    @Test("sensor: the executor binding and the escape-guard registry are not public API")
    func theBindingAndTheRegistryAreNotPublic() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VideoScanCore/CommandExecutor.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        for forbidden in ["@TaskLocal public static var executor", "public static func claim(",
                          "public static func release(", "public enum CommandExecutorEscapeGuard",
                          "public protocol CommandEscapeSink"] {
            #expect(!text.contains(forbidden), "\(forbidden) — reachable from the app target")
        }
    }
}
