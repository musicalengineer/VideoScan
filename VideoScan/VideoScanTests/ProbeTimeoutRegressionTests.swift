import Testing
import Foundation
@testable import VideoScan

// MARK: - Probe timeout regression tests
//
// Codex finding (triaged real, 2026-06): probeFileWithTimeout races probeFile
// against Task.sleep in a throwing task group, but throwing out of a task
// group still AWAITS child cleanup. Task cancellation only sends SIGTERM to
// the ffprobe subprocess (ProcessRunner's onCancel → proc.terminate()). An
// ffprobe that doesn't die on SIGTERM — the real-world case is a process
// blocked in uninterruptible I/O on a dead SMB volume — never fires its
// terminationHandler, so the child task never completes and the "timed out"
// record is never returned. One bad file hangs the whole scan, defeating the
// 300s timeout entirely.
//
// The fix gives the subprocess its own deadline inside ProcessRunner:
// SIGTERM at the deadline, SIGKILL after a grace period, then (if even
// SIGKILL can't reap it) abandon the process and resume with a timed-out
// result. These tests inject a fake ffprobe that ignores SIGTERM to
// deterministically reproduce the "terminate() doesn't unblock the child"
// failure mode in seconds instead of minutes.
//
// All fixtures live in a per-test temp dir; no real volumes, no real
// Application Support (MetadataCache self-sandboxes under test hosts).

/// Shared helper: writes an executable perl script that ignores SIGTERM and
/// sleeps, simulating ffprobe stuck on dead-volume I/O. Perl (always present
/// on macOS) is a single process with no children, so SIGKILL closes its
/// pipe ends immediately — keeps the test deterministic.
private func makeStuckTool(sleepSeconds: Int, in dir: URL) throws -> URL {
    let script = dir.appendingPathComponent("fake-ffprobe-stuck")
    let body = """
    #!/usr/bin/perl
    $SIG{TERM} = 'IGNORE';
    sleep \(sleepSeconds);
    exit 1;
    """
    try body.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
}

private func makeTempDir() throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ProbeTimeoutTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@MainActor
struct ProbeTimeoutRegressionTests {

    /// THE regression test for the hang: a probe whose ffprobe is stuck and
    /// ignores SIGTERM must still return within the injected timeout bound
    /// (plus the kill-escalation grace), not block until the subprocess
    /// deigns to exit.
    ///
    /// Against the pre-fix code this takes the full 30s of the fake tool's
    /// sleep (timeout fires at 2s but the group then awaits the stuck child),
    /// failing the elapsed bound. With the subprocess deadline it returns in
    /// roughly timeout + SIGKILL grace.
    @Test func stuckFFProbeIsBoundedByProbeTimeout() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fakeFFProbe = try makeStuckTool(sleepSeconds: 30, in: dir)
        let media = dir.appendingPathComponent("stuck.mov")
        try Data(repeating: 0x42, count: 4096).write(to: media)

        let model = VideoScanModel()
        model.ffprobePath = fakeFFProbe.path
        model.probeTimeoutSeconds = 2

        // SuspendingClock, not ContinuousClock: elapsed-bound assertions must
        // stop ticking while the machine sleeps. On 2026-07-09 the M5 nightly
        // slept ~7 min mid-test and ContinuousClock reported 419 s for a run
        // whose suspending duration was 7.9 s — a false failure.
        let start = SuspendingClock.now
        let rec = await model.probeFileWithTimeout(url: media, skipHashing: true)
        let elapsed = start.duration(to: .now)

        // 2s timeout + 5s default SIGTERM→SIGKILL grace + scheduling slack.
        // The pre-fix behavior blocks for the full 30s sleep.
        #expect(elapsed < .seconds(15),
                "probe must be bounded by the injected timeout; took \(elapsed)")
        #expect(rec.streamTypeRaw == StreamType.ffprobeFailed.rawValue,
                "stuck probe must surface as a failed/timed-out record")
        #expect(rec.fullPath == media.path)
    }
}

/// Direct unit tests of ProcessRunner's subprocess deadline (the mechanism
/// behind the fix), exercising the SIGTERM → SIGKILL escalation without the
/// probe stack on top.
struct ProcessRunnerDeadlineTests {

    /// A child that ignores SIGTERM must be SIGKILLed at deadline + grace
    /// and the caller resumed with a failed Result.
    @Test func sigtermIgnoringChildIsKilledAtDeadline() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tool = try makeStuckTool(sleepSeconds: 30, in: dir)

        // SuspendingClock — sleep-immune elapsed bound (see note above).
        let start = SuspendingClock.now
        let result = await ProcessRunner.runProcess(
            executable: tool.path, arguments: [],
            deadlineSeconds: 1, killGraceSeconds: 1)
        let elapsed = start.duration(to: .now)

        // 1s deadline + 1s grace + scheduling slack; the tool sleeps 30s.
        #expect(elapsed < .seconds(10),
                "SIGKILL escalation must bound the subprocess; took \(elapsed)")
        #expect(result.exitCode != 0, "killed child must not report success")
    }

    /// A well-behaved child that finishes before the deadline is unaffected:
    /// normal exit code and captured stdout.
    @Test func fastChildIsUntouchedByDeadline() async throws {
        let result = await ProcessRunner.runProcess(
            executable: "/bin/echo", arguments: ["ok"],
            deadlineSeconds: 30, killGraceSeconds: 1)
        #expect(result.exitCode == 0)
        #expect(result.stdout?.trimmingCharacters(in: .whitespacesAndNewlines) == "ok")
    }
}
