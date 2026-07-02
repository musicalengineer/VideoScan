import Testing
import Foundation
@testable import VideoScan

// MARK: - File-descriptor lifecycle regression (walker-subtree-loss incident)
//
// Root cause of the 2026-07-02 InternalRaid discovery collapse (and, with
// high confidence, the 2026-06-30 LaCieWorkspace incident): every
// `ProcessRunner.runProcess(deadlineSeconds:)` call scheduled its deadline
// via a plain `DispatchQueue.asyncAfter` CLOSURE capturing the Process and
// both pipe FileHandles. The closure cannot be cancelled, so even a probe
// whose child exited in 50 ms kept its parent-side pipe fds alive for the
// FULL deadline (probeTimeoutSeconds = 300 s). A cache-heavy rescan bursts
// hundreds of ffprobe launches in under two minutes; with the GUI-app
// default RLIMIT_NOFILE soft limit of 256, the fd table filled, after which
//   * FilesystemWalker's contentsOfDirectory failed with Cocoa error 256
//     (whole sibling subtrees unreadable → 33,848 files undiscovered), and
//   * new probes failed with EBADF ("Bad file descriptor") because Pipe()
//     hands out dead descriptors when the table is full.
//
// The fix: the deadline/escalation chain uses cancellable DispatchWorkItems
// owned by a per-run lifecycle box; normal termination cancels them and
// CLOSES the parent-side read handles immediately. These tests count real
// fds via /dev/fd, so they are per-process integration sensors.

struct ProcessRunnerFdLifecycleTests {

    /// Open-descriptor count for THIS process. /dev/fd enumerates the live
    /// fd table (the enumeration itself briefly costs one fd — tolerances
    /// below absorb that noise plus any concurrent test activity).
    private func openFdCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd"))?.count ?? -1
    }

    // regression: walker-subtree-loss 2026-07-02 — a completed subprocess
    // with a pending deadline must NOT retain its pipe fds for the deadline
    // duration. Pre-fix this leaks 2 fds per run for 300 s: 40 runs ⇒ ≈ +80.
    @Test func deadlineRunReleasesPipeFdsAtTermination() async throws {
        let before = openFdCount()
        #expect(before > 0, "could not read /dev/fd")

        for _ in 0..<40 {
            let result = await ProcessRunner.runProcess(
                executable: "/bin/echo",
                arguments: ["fd-lifecycle"],
                deadlineSeconds: 300   // probeTimeoutSeconds in production
            )
            #expect(result.exitCode == 0)
        }

        // Let terminationHandler cleanup finish for the last run.
        try await Task.sleep(nanoseconds: 300_000_000)

        let after = openFdCount()
        #expect(after - before <= 10,
                "pipe fds retained after subprocess exit: fd count grew from \(before) to \(after) across 40 deadline-bounded runs — deadline blocks are pinning FileHandles")
    }

    // Companion pin: runs WITHOUT a deadline never had the retention bug
    // (ARC frees the pipes when runProcess returns). Keep it pinned so a
    // future refactor can't regress the plain path while fixing the other.
    @Test func plainRunReleasesPipeFdsAtTermination() async throws {
        let before = openFdCount()
        #expect(before > 0, "could not read /dev/fd")

        for _ in 0..<20 {
            let result = await ProcessRunner.runProcess(
                executable: "/bin/echo",
                arguments: ["fd-lifecycle-plain"]
            )
            #expect(result.exitCode == 0)
        }

        try await Task.sleep(nanoseconds: 300_000_000)

        let after = openFdCount()
        #expect(after - before <= 10,
                "fd count grew from \(before) to \(after) across 20 plain runs")
    }

    // The launch-failure path builds both pipes before proc.run() throws —
    // those four descriptors are parent-owned and must be closed on the
    // error path, or a misconfigured tool path leaks 4 fds per attempt.
    @Test func launchFailureReleasesPipeFds() async throws {
        let before = openFdCount()
        #expect(before > 0, "could not read /dev/fd")

        for _ in 0..<20 {
            let result = await ProcessRunner.runProcess(
                executable: "/nonexistent/vs-test-binary",
                arguments: [],
                deadlineSeconds: 300
            )
            #expect(result.exitCode == -1)
        }

        try await Task.sleep(nanoseconds: 200_000_000)

        let after = openFdCount()
        #expect(after - before <= 10,
                "fd count grew from \(before) to \(after) across 20 failed launches")
    }
}
