import Testing
import Foundation
@testable import VideoScan

// MARK: - ProcessRunner consolidation tests (codex finding #3)
//
// The subprocess-consolidation refactor migrated three hand-rolled Process
// call sites (CombineEngine.runFFMpeg, IdentifyFamilyModel.launch,
// PersonFinderCompilation's ffprobe/ffmpeg helpers) onto ProcessRunner.
// These tests pin the runner behaviors those sites now rely on:
//   • stdout line callbacks deliver complete lines, in order
//   • both pipes are fully drained even when data lands at exit time
//   • cancellation escalates SIGTERM → SIGKILL after a grace period
//
// Like ProcessRunnerStressTests, these use real /bin/sh children — fast
// (<1s each except the escalation test, ~1s) and no user data touched.

/// Thread-safe line accumulator for @Sendable callbacks.
private final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func append(_ line: String) { lock.lock(); stored.append(line); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return stored }
}

struct ProcessRunnerConsolidationTests {

    private let shellPath = "/bin/sh"

    // MARK: stdout line callbacks

    @Test func stdoutLinesDeliveredInOrder() async throws {
        let box = LineBox()
        let result = await ProcessRunner.runProcess(
            executable: shellPath,
            arguments: ["-c", "printf 'one\\ntwo\\nthree\\n'"],
            stdoutLine: { box.append($0) }
        )
        #expect(result.exitCode == 0)
        #expect(box.lines == ["one", "two", "three"])
    }

    // A trailing partial line (no final newline) must still be flushed when
    // the process exits — CombineEngine's progress parser depends on the
    // final out_time_us update.
    @Test func stdoutTailWithoutNewlineIsFlushed() async throws {
        let box = LineBox()
        let result = await ProcessRunner.runProcess(
            executable: shellPath,
            arguments: ["-c", "printf 'head\\ntail-no-newline'"],
            stdoutLine: { box.append($0) }
        )
        #expect(result.exitCode == 0)
        #expect(box.lines == ["head", "tail-no-newline"])
    }

    // stdout and stderr callbacks operate independently on the same run.
    @Test func bothStreamsDeliverToTheirOwnCallbacks() async throws {
        let outBox = LineBox()
        let errBox = LineBox()
        let result = await ProcessRunner.runProcess(
            executable: shellPath,
            arguments: ["-c", "echo out1; echo err1 >&2; echo out2; echo err2 >&2"],
            stdoutLine: { outBox.append($0) },
            stderrLine: { errBox.append($0) }
        )
        #expect(result.exitCode == 0)
        #expect(outBox.lines == ["out1", "out2"])
        #expect(errBox.lines == ["err1", "err2"])
    }

    // MARK: drain-at-exit

    // Data written immediately before exit (after a quiet period, so the
    // readabilityHandler has gone idle) must still reach both the collected
    // Result and the line callbacks. This is the "drains both pipes after
    // termination" guarantee the migrated call sites depend on.
    @Test func lateWritesToBothPipesAreDrained() async throws {
        let outBox = LineBox()
        let errBox = LineBox()
        let result = await ProcessRunner.runProcess(
            executable: shellPath,
            arguments: ["-c", "echo early; sleep 0.3; echo late-out; echo late-err >&2"],
            stdoutLine: { outBox.append($0) },
            stderrLine: { errBox.append($0) }
        )
        #expect(result.exitCode == 0)
        #expect(outBox.lines == ["early", "late-out"])
        #expect(errBox.lines == ["late-err"])
        #expect(result.stdout?.contains("late-out") == true)
        #expect(result.stderr.contains("late-err"))
    }

    // MARK: terminate → kill escalation

    // Child traps SIGTERM and would sleep 30s; cancellation must escalate
    // to SIGKILL after the grace period instead of waiting the child out.
    //
    // The sleeper's fds are redirected away from our pipes: because the trap
    // keeps sh resident, `sleep` is a forked grandchild that would otherwise
    // survive the SIGKILL holding the pipe write-ends open, and the runner's
    // post-termination drain (readDataToEndOfFile) would block until the
    // orphan exits. That orphaned-grandchild drain behavior is pre-existing
    // and out of scope here — this test pins the TERM→KILL escalation only.
    @Test func cancellationEscalatesToSIGKILLAfterGrace() async throws {
        let box = LineBox()
        let started = ContinuousClock.now
        let task = Task {
            await ProcessRunner.runProcess(
                executable: shellPath,
                arguments: ["-c", "trap '' TERM; echo ready; sleep 30 </dev/null >/dev/null 2>&1"],
                stdoutLine: { box.append($0) },
                killGraceSeconds: 0.5
            )
        }
        // Wait until the child confirms it's alive with TERM trapped.
        for _ in 0..<200 where !box.lines.contains("ready") {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(box.lines.contains("ready"), "child never reported ready")
        task.cancel()
        let result = await task.value
        let elapsed = ContinuousClock.now - started
        // SIGKILL == 9; Process.terminationStatus reports the signal number
        // for uncaught-signal exits.
        #expect(result.exitCode == SIGKILL)
        #expect(elapsed < .seconds(10), "escalation took too long: \(elapsed)")
    }

    // Control case: a child that honours SIGTERM exits during the grace
    // period and is never SIGKILLed.
    @Test func cancellationUsesSIGTERMWhenChildCooperates() async throws {
        let box = LineBox()
        let task = Task {
            await ProcessRunner.runProcess(
                executable: shellPath,
                arguments: ["-c", "echo ready; sleep 30"],
                stdoutLine: { box.append($0) },
                killGraceSeconds: 5.0
            )
        }
        for _ in 0..<200 where !box.lines.contains("ready") {
            try await Task.sleep(for: .milliseconds(25))
        }
        task.cancel()
        let result = await task.value
        #expect(result.exitCode == SIGTERM)
    }

    // MARK: collected-copy caps

    // stdoutLimitBytes caps the collected Result copy without disturbing
    // the exit path (mirrors the existing stderr cap behavior).
    @Test func stdoutLimitTruncatesCollectedCopy() async throws {
        let result = await ProcessRunner.runProcess(
            executable: shellPath,
            arguments: ["-c", "/bin/dd if=/dev/zero bs=1024 count=1024 2>/dev/null"],
            stdoutLimitBytes: 64 * 1024
        )
        #expect(result.exitCode == 0)
        #expect((result.stdout?.count ?? 0) <= 64 * 1024 + 256)
    }
}
