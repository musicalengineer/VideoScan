import Testing
import Foundation
@testable import VideoScan

// regression: verify-audio pause 2026-08-03 — a deadline-guarded child
// that is SUSPENDED (MFO Pause All → ProcessControl SIGSTOP) must NOT be
// killed when its deadline fires; the runner restarts the clock and
// checks again. Pre-fix, pausing any deadline-guarded job longer than
// its budget SIGTERMed the paused child and surfaced a bogus timed-out
// failure (verify audio was the first job to combine pause + deadlines).
struct ProcessRunnerPauseDeadlineTests {

    @Test func deadlineDoesNotFireWhileSuspended() async throws {
        let control = ProcessControl()
        // Pause BEFORE launch: the wish is remembered and the child is
        // born suspended (ProcessControl.attach), so there is no window
        // where the deadline could race an unsuspended child.
        control.suspend()

        // Resume well after the 1.5 s deadline has come due while
        // suspended. Post-resume the child needs ~1 s (a stopped
        // nanosleep restarts with its remaining time on SIGCONT),
        // which must fit inside ONE fresh deadline period — the
        // budget the runner grants from resume time.
        let resumer = Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            control.resume()
        }

        let result = await ProcessRunner.runProcess(
            executable: "/bin/sleep",
            arguments: ["1"],
            deadlineSeconds: 1.5,
            control: control
        )
        resumer.cancel()

        #expect(result.timedOut == false,
                "deadline fired while the child was suspended — pause must restart the clock")
        #expect(result.exitCode == 0,
                "suspended child was killed (exit \(result.exitCode)) instead of surviving the pause")
    }

    // Companion pin: an UNPAUSED overrunning child still hits the
    // deadline — the suspend check must not soften the real guard.
    @Test func deadlineStillFiresWhenNotSuspended() async throws {
        let control = ProcessControl()
        let result = await ProcessRunner.runProcess(
            executable: "/bin/sleep",
            arguments: ["30"],
            deadlineSeconds: 0.3,
            control: control
        )
        #expect(result.timedOut == true)
        #expect(result.exitCode != 0)
    }
}
