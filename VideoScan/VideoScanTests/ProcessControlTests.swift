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
                arguments: ["-c", "while true; do echo beat >&2; sleep 0.05; done"],
                stderrLine: { _ in beats.increment() },
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
}
