// ProcessControlKillRaceTests.swift — ProcessControl's stop/continue books
// (ProcessRunner.swift) against real children that trap SIGTERM the way ffmpeg
// does: an untrapped child dies on SIGTERM even while stopped, so only a
// trapping child shows whether SIGCONT was actually sent (review 2026-11-28).

import Darwin
import Foundation
import Testing
@testable import VideoScanCore

@Suite struct ProcessControlKillRaceTests {

    /// Traps SIGTERM like ffmpeg: exits only once it can run its trap.
    static func trappingChild() throws -> Process {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "trap 'exit 0' TERM; while true; do sleep 0.05; done"]
        try child.run()
        return child
    }

    static func exits(_ child: Process, withinSeconds seconds: Double) async throws -> Bool {
        for _ in 0..<Int(seconds / 0.05) where child.isRunning { try await Task.sleep(nanoseconds: 50_000_000) }
        return !child.isRunning
    }

    /// The runner's own order when Stop's onCancel beats attach:
    /// resumeForKill → attach → resumeForKill → terminate.
    @Test func killRacingAttachWhilePausedStillContinuesTheChild() async throws {
        let control = ProcessControl()
        control.suspend()
        let child = try Self.trappingChild()
        defer { if child.isRunning { kill(child.processIdentifier, SIGKILL) } }
        try await Task.sleep(nanoseconds: 300_000_000)      // let sh install its trap
        control.resumeForKill(child)
        control.attach(child)
        control.resumeForKill(child)
        child.terminate()
        #expect(try await Self.exits(child, withinSeconds: 3),
                "still stopped 3 s after SIGTERM: the second resumeForKill sent no SIGCONT")
    }

    @Test func killingOneChildLeavesItsPausedSiblingPaused() async throws {
        let control = ProcessControl()
        let doomed = try Self.trappingChild(), sibling = try Self.trappingChild()
        defer { for c in [doomed, sibling] where c.isRunning { kill(c.processIdentifier, SIGKILL) } }
        try await Task.sleep(nanoseconds: 300_000_000)
        control.attach(doomed)
        control.attach(sibling)
        control.suspend()
        control.resumeForKill(doomed)
        doomed.terminate()
        #expect(try await Self.exits(doomed, withinSeconds: 3))
        sibling.terminate()                                 // pending while stopped
        #expect(try await Self.exits(sibling, withinSeconds: 1) == false, "the sibling was continued too")
        control.resume()
        #expect(try await Self.exits(sibling, withinSeconds: 3))
    }

    /// Pause, resume, pause again: each stop is matched by one continue.
    @Test func repeatedPauseResumeStaysBalanced() async throws {
        let control = ProcessControl()
        let child = try Self.trappingChild()
        defer { if child.isRunning { kill(child.processIdentifier, SIGKILL) } }
        try await Task.sleep(nanoseconds: 300_000_000)
        control.attach(child)
        for _ in 0..<3 { control.suspend(); control.resume() }
        control.resumeForKill(child)                         // not stopped: a no-op
        control.suspend()
        control.resumeForKill(child)
        child.terminate()
        #expect(try await Self.exits(child, withinSeconds: 3))
    }
}
