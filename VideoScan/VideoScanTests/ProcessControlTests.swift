import Testing
import Foundation
@testable import VideoScan

// MARK: - ProcessControl tests (GH #150 — MFO pause)
//
// These drive REAL child processes (/bin/sh beat loops) through
// ProcessRunner with a ProcessControl attached, because the properties
// that matter — SIGSTOP freezes output, a pending suspend applies at
// launch, SIGTERM still lands on a stopped child — live in the kernel,
// not in our bookkeeping. Timing windows are generous (hundreds of ms
// against a 50 ms beat cadence) to stay honest on a loaded CI machine.
//
// Per the safety-critical policy: positive (pause freezes, resume
// completes) AND negative (cancel-while-paused must not hang) coverage.

/// Lock-guarded beat counter fed from ProcessRunner's stderr callback.
private final class BeatCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

@Suite("ProcessControl suspend/resume")
struct ProcessControlTests {

    /// Bookkeeping-only semantics: idempotent flips of the suspend wish.
    @Test func suspendResumeFlagIsIdempotent() {
        let control = ProcessControl()
        #expect(!control.isSuspended)
        #expect(control.suspend())
        #expect(control.isSuspended)
        #expect(!control.suspend())       // second suspend is a no-op
        #expect(control.resume())
        #expect(!control.isSuspended)
        #expect(!control.resume())        // second resume is a no-op
    }

    /// Pause freezes a live child's output; resume lets it finish.
    @Test func suspendFreezesChildOutputAndResumeCompletes() async throws {
        let control = ProcessControl()
        let beats = BeatCounter()
        let total = 40

        let run = Task {
            await ProcessRunner.runProcess(
                executable: "/bin/sh",
                arguments: ["-c", "i=0; while [ $i -lt \(total) ]; do echo beat >&2; i=$((i+1)); sleep 0.05; done"],
                stderrLine: { _ in beats.increment() },
                control: control
            )
        }

        // Let it demonstrably run first.
        for _ in 0..<100 where beats.count < 3 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(beats.count >= 3, "child never started emitting")

        control.suspend()
        // First window drains anything already buffered in the pipe…
        try await Task.sleep(nanoseconds: 600_000_000)
        let frozenAt = beats.count
        // …second window is the actual assertion: a stopped child is silent.
        try await Task.sleep(nanoseconds: 600_000_000)
        #expect(beats.count == frozenAt,
                "child kept emitting while suspended (\(beats.count) vs \(frozenAt))")
        #expect(frozenAt < total, "child finished before the pause landed — beat cadence too fast for this box?")

        control.resume()
        let result = await run.value
        #expect(result.exitCode == 0)
        #expect(beats.count == total, "expected all \(total) beats after resume, saw \(beats.count)")
    }

    /// Pause-between-phases: a suspend wish recorded while NO child is
    /// live must apply to the next launch (the child is born stopped).
    @Test func pendingSuspendAppliesAtLaunch() async throws {
        let control = ProcessControl()
        let beats = BeatCounter()
        control.suspend()   // wish first, launch second

        let run = Task {
            await ProcessRunner.runProcess(
                executable: "/bin/sh",
                arguments: ["-c", "i=0; while [ $i -lt 5 ]; do echo beat >&2; i=$((i+1)); sleep 0.05; done"],
                stderrLine: { _ in beats.increment() },
                control: control
            )
        }

        try await Task.sleep(nanoseconds: 800_000_000)
        // BeatCounter.count is an Int, not a collection — empty_count misfires here.
        // swiftlint:disable:next empty_count
        #expect(beats.count == 0, "child born suspended must not emit (saw \(beats.count) beats)")

        control.resume()
        let result = await run.value
        #expect(result.exitCode == 0)
        #expect(beats.count == 5)
    }

    /// Negative / the trap this seam exists for: SIGTERM is NOT delivered
    /// to a stopped process, so cancelling a paused job would hang in
    /// "Stopping…" forever unless the kill path resumes the child first
    /// (resumeForKill). Pins that cancel-while-paused returns promptly.
    @Test func cancelWhilePausedStillKillsTheChild() async throws {
        let control = ProcessControl()
        let beats = BeatCounter()

        let run = Task {
            await ProcessRunner.runProcess(
                executable: "/bin/sh",
                // Traps SIGTERM like ffmpeg: an untrapped sh dies on SIGTERM even
                // while stopped, so only a trap shows SIGCONT was sent (review
                // 2026-11-28). Grace 30 s: a stopped child would hold Stop for 30 s.
                arguments: ["-c", "trap 'exit 1' TERM; while true; do echo beat >&2; sleep 0.05; done"],
                stderrLine: { _ in beats.increment() },
                killGraceSeconds: 30,
                control: control
            )
        }

        for _ in 0..<100 where beats.count < 3 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(beats.count >= 3, "child never started emitting")

        control.suspend()
        try await Task.sleep(nanoseconds: 300_000_000)

        let cancelledAt = ContinuousClock.now
        run.cancel()
        let result = await run.value
        let waited = ContinuousClock.now - cancelledAt

        // SIGTERM lands because the kill path SIGCONTs first; well under
        // the 5 s SIGKILL escalation, but allow headroom for a slow box.
        #expect(waited < .seconds(10), "cancel-while-paused took \(waited) — SIGTERM likely pending on a stopped child")
        #expect(result.exitCode != 0, "an infinite loop cannot exit cleanly")
        // The UI wish survives the kill: a paused-then-cancelled job must
        // not flip its badge back to running.
        #expect(control.isSuspended)
    }

    // MARK: Several live children under one control (A/V sync reads sound and
    // picture side by side, and both files of a pair at once — up to four).

    private static func beatLoop(_ beats: BeatCounter, count: Int?, control: ProcessControl,
                                 killGraceSeconds: Double = ProcessRunner.defaultKillGraceSeconds) -> Task<ProcessRunner.Result, Never> {
        let loop = count.map { "i=0; while [ $i -lt \($0) ]; do echo beat >&2; i=$((i+1)); sleep 0.05; done" }
            ?? "trap 'exit 1' TERM; while true; do echo beat >&2; sleep 0.05; done"
        return Task {
            await ProcessRunner.runProcess(executable: "/bin/sh", arguments: ["-c", loop],
                                           stderrLine: { _ in beats.increment() },
                                           killGraceSeconds: killGraceSeconds, control: control)
        }
    }

    /// Pause freezes EVERY live child, not only the last one launched.
    @Test func suspendFreezesEveryLiveChild() async throws {
        let control = ProcessControl()
        let first = BeatCounter(), second = BeatCounter()
        let total = 60
        let runA = Self.beatLoop(first, count: total, control: control)
        let runB = Self.beatLoop(second, count: total, control: control)
        for _ in 0..<100 where first.count < 3 || second.count < 3 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(first.count >= 3 && second.count >= 3, "children never started emitting")

        control.suspend()
        try await Task.sleep(nanoseconds: 600_000_000)
        let frozen = (first.count, second.count)
        try await Task.sleep(nanoseconds: 600_000_000)
        #expect(first.count == frozen.0, "the first child kept emitting while paused")
        #expect(second.count == frozen.1, "the second child kept emitting while paused")

        control.resume()
        _ = await (runA.value, runB.value)
        #expect(first.count == total && second.count == total)
    }

    /// Born paused, then Stop: every child must get SIGCONT before SIGTERM.
    /// The kill grace is set long (30 s), so a child left stopped would hold
    /// the cancel for 30 s before SIGKILL; the expectation is well under that.
    @Test func cancelWhileBornPausedKillsEveryChildPromptly() async throws {
        let control = ProcessControl()
        control.suspend()
        let runA = Self.beatLoop(BeatCounter(), count: nil, control: control, killGraceSeconds: 30)
        let runB = Self.beatLoop(BeatCounter(), count: nil, control: control, killGraceSeconds: 30)
        try await Task.sleep(nanoseconds: 500_000_000)

        let cancelledAt = ContinuousClock.now
        runA.cancel()
        runB.cancel()
        _ = await (runA.value, runB.value)
        let waited = ContinuousClock.now - cancelledAt
        #expect(waited < .seconds(10), "cancel took \(waited) — a stopped child never got SIGCONT before SIGTERM")
    }
}
