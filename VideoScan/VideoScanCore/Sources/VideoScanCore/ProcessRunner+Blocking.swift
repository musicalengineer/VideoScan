// ProcessRunner+Blocking.swift (VideoScanCore)
// The synchronous door onto ProcessRunner, for the few callers that cannot
// suspend. Everything else awaits `ProcessRunner.runProcess`.
//
// WHO MAY CALL IT (audited 2026-11-21; a sensor pins the list —
// CommandExecutorSensorTests.onlyTheAuditedSynchronousCallersBlock):
//   • RAMDisk.cleanupStaleMounts — the app's launch and quit path, on the
//     main thread, never inside a task (`applicationWillTerminate` must not
//     return before the RAM disk is gone);
//   • EraCanary.init — a synchronous throwing init, once per job at START.
// An `async` function must NOT call it: it awaits `runProcess` (EraCanary's
// job-time check does). Parking a cooperative-pool thread on a semaphore
// while the work it waits for needs a pool thread is the classic deadlock
// (WWDC22 "Visualize and optimize Swift concurrency").

import Foundation
import os

extension ProcessRunner {
    /// Slack the blocking wait allows past the runner's own worst case.
    static let blockingWaitMarginSeconds: Double = 0.5

    /// `runProcess` for a caller that CANNOT suspend (see the file header
    /// for who that is). It goes through the same executor seam, so a
    /// ScriptedExecutor bound for the calling task tree answers it.
    ///
    /// BOUNDED TWICE. The deadline is not optional, and the runner
    /// enforces it on the child (SIGTERM → SIGKILL → abandon). The wait
    /// here has its OWN clock as well — `deadlineSeconds + 2 ×
    /// killGraceSeconds + blockingWaitMarginSeconds` — because the
    /// runner's bound is on the CHILD, not on this thread getting an
    /// answer (Codex r1 P2, 2026-11-21):
    ///   • a child that exits at once but leaves a descendant holding its
    ///     pipes keeps the runner draining to EOF long after the deadline
    ///     callbacks found nothing left to kill;
    ///   • on an exhausted cooperative pool the detached work may not have
    ///     started at all.
    /// When this clock expires the work is CANCELLED — a command that has
    /// not launched never will; one that has is terminated by the runner's
    /// cancellation handler — and a timed-out Result is returned:
    /// `timedOut == true`, exit -1, `launched == false` (this side has no
    /// evidence either way; read `timedOut` first).
    ///
    /// No cancellation from the caller: a synchronous caller has no task
    /// to cancel; the two clocks are the only stop.
    /// (C++: `std::async(...)` + `future.wait_for(bound)`; on timeout
    /// request_stop() and walk away.)
    public static func runProcessBlocking(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        stdoutLimitBytes: Int? = nil,
        stderrLimitBytes: Int? = 256 * 1024,
        deadlineSeconds: Double,
        killGraceSeconds: Double = ProcessRunner.defaultKillGraceSeconds
    ) -> Result {
        let box = OSAllocatedUnfairLock<Result?>(initialState: nil)
        let done = DispatchSemaphore(value: 0)
        // Detached (the caller may not be in a task at all) but carrying the
        // caller's scope, so a mocked test's command stays on its mock.
        let work = TaskTreeScope.detached(priority: .userInitiated) {
            let result = await runProcess(
                executable: executable, arguments: arguments, environment: environment,
                stdoutLimitBytes: stdoutLimitBytes, stderrLimitBytes: stderrLimitBytes,
                deadlineSeconds: deadlineSeconds, killGraceSeconds: killGraceSeconds)
            box.withLock { $0 = result }
            done.signal()
        }
        let bound = max(0, deadlineSeconds) + 2 * max(0, killGraceSeconds) + blockingWaitMarginSeconds
        if done.wait(timeout: .now() + bound) == .timedOut {
            work.cancel()
            // The work may have finished in the instant the wait expired.
            if let late = box.withLock({ $0 }) { return late }
            return Result(stdout: nil,
                          stderr: "no answer within \(String(format: "%.1f", bound)) s (deadline \(deadlineSeconds) s) — stopped waiting; the command was cancelled",
                          exitCode: -1, timedOut: true, launched: false)
        }
        return box.withLock { $0 }
            ?? Result(stdout: nil, stderr: "runProcessBlocking: no result", exitCode: -1)
    }
}
