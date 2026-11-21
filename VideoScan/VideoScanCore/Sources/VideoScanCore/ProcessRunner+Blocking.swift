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

    /// Test seam: called on the expiry path right after the work is
    /// cancelled, before the bridge returns — a test holds the caller there
    /// until the woken work has published, the ordering Codex r2 P2 is
    /// about. Nil in production, always (task-local; nothing binds it).
    @TaskLocal static var blockingExpiryProbe: (@Sendable () -> Void)?

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
    /// evidence either way; read `timedOut` first). A result the work had
    /// ALREADY published when the wait expired is returned as it is; one
    /// published after that is dropped.
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
        // One slot, three states, one lock: whichever of "the work
        // published" and "the wait gave up" takes the lock first decides,
        // and the other sees it. (C++: a mutex-guarded std::variant.)
        enum Slot { case pending, published(Result), abandoned }
        let slot = OSAllocatedUnfairLock<Slot>(initialState: .pending)
        let done = DispatchSemaphore(value: 0)
        // Detached (the caller may not be in a task at all) but carrying the
        // caller's scope, so a mocked test's command stays on its mock.
        let work = TaskTreeScope.detached(priority: .userInitiated) {
            let result = await runProcess(
                executable: executable, arguments: arguments, environment: environment,
                stdoutLimitBytes: stdoutLimitBytes, stderrLimitBytes: stderrLimitBytes,
                deadlineSeconds: deadlineSeconds, killGraceSeconds: killGraceSeconds)
            // After the wait gave up, a result is nobody's: dropped.
            slot.withLock { if case .pending = $0 { $0 = .published(result) } }
            done.signal()
        }
        let bound = max(0, deadlineSeconds) + 2 * max(0, killGraceSeconds) + blockingWaitMarginSeconds
        let expired = done.wait(timeout: .now() + bound) == .timedOut
        // Decide BEFORE cancelling (Codex r2 P2): a result already published
        // — in time, or in the instant the wait expired — is returned as it
        // is. Otherwise the slot is closed first and only THEN is the work
        // cancelled, so the cancellation result the woken work publishes
        // next (exit -1 or SIGTERM, timedOut == false) can never be mistaken
        // for the answer: the caller gets this bridge's own timeout.
        let landed: Result? = slot.withLock { state in
            if case .published(let result) = state { return result }
            state = .abandoned
            return nil
        }
        if let landed { return landed }
        work.cancel()
        Self.blockingExpiryProbe?()
        return Result(stdout: nil,
                      stderr: "no answer within \(String(format: "%.1f", bound)) s (deadline \(deadlineSeconds) s)\(expired ? "" : " [no result]") — stopped waiting; the command was cancelled",
                      exitCode: -1, timedOut: true, launched: false)
    }
}
