// ProcessRunner+Blocking.swift (VideoScanCore)
// The synchronous door onto ProcessRunner, for the few callers that cannot
// suspend. Everything else awaits `ProcessRunner.runProcess`.

import Foundation
import os

extension ProcessRunner {
    /// `runProcess` for a caller that CANNOT suspend: the app's quit path
    /// (`applicationWillTerminate` must not return before the RAM disk is
    /// gone) and synchronous self-tests (EraCanary, called from a
    /// synchronous throwing init). It goes through the same executor seam,
    /// so a ScriptedExecutor bound for the calling task tree answers it.
    ///
    /// The deadline is NOT optional: a blocking wait with no bound is the
    /// 2026-09-13 quit wedge. The caller's thread is held for at most
    /// `deadlineSeconds + 2 × killGraceSeconds` (SIGTERM, SIGKILL, abandon).
    /// Never call it from a hot path or from many tasks at once — it parks
    /// the calling thread, and on the cooperative pool that is a thread the
    /// pool does not get back until the child ends.
    ///
    /// No cancellation: a synchronous caller has no task to cancel; the
    /// deadline is the only stop.
    /// (C++: `std::async(...).get()` — start the work elsewhere, block here
    /// for the result; the scope snapshot is the thread_local handed over.)
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
        _ = TaskTreeScope.detached(priority: .userInitiated) {
            let result = await runProcess(
                executable: executable, arguments: arguments, environment: environment,
                stdoutLimitBytes: stdoutLimitBytes, stderrLimitBytes: stderrLimitBytes,
                deadlineSeconds: deadlineSeconds, killGraceSeconds: killGraceSeconds)
            box.withLock { $0 = result }
            done.signal()
        }
        done.wait()
        return box.withLock { $0 }
            ?? Result(stdout: nil, stderr: "runProcessBlocking: no result", exitCode: -1)
    }
}
