import Testing
import Foundation
@testable import VideoScan

// MARK: - Pipe-deadlock regression tests (Issue #56)
//
// The "harden subprocess runner" issue calls for a stress test where a
// child process writes more than the OS pipe buffer (~64KB on macOS)
// before exiting. If the runner only reads after termination, the
// child blocks on its write and we deadlock.
//
// These tests use real subprocess (`/bin/sh` + `/bin/dd`) — they're
// integration tests, not pure-logic. They run quickly (well under a
// second) but exercise the real Pipe machinery.

struct ProcessRunnerPipeDeadlockTests {

    private let shellPath = "/bin/sh"

    // regression: #56 — Child writing > 1MB to stdout doesn't deadlock the runner
    @Test func largeStdoutDrainedWithoutDeadlock() async throws {
        // dd if=/dev/zero bs=1024 count=1024 → 1 MiB of zeros to stdout
        let result = await ProcessRunner.runProcess(
            executable: shellPath,
            arguments: ["-c", "/bin/dd if=/dev/zero bs=1024 count=1024 2>/dev/null"]
        )
        #expect(result.exitCode == 0)
        #expect(result.stdout?.count == 1024 * 1024,
                "Expected 1MiB stdout, got \(result.stdout?.count ?? 0)")
    }

    // regression: #56 — Child writing > 1MB to STDERR doesn't deadlock the runner
    @Test func largeStderrDrainedWithoutDeadlock() async throws {
        // `tee /dev/stderr` duplicates the 1MB stream to fd 2 (the rest goes
        // to /dev/null via the final pipe). Reliably routes data to the
        // parent's stderr capture pipe.
        let result = await ProcessRunner.runProcess(
            executable: shellPath,
            arguments: ["-c", "/bin/dd if=/dev/zero bs=1024 count=1024 2>/dev/null | /usr/bin/tee /dev/stderr >/dev/null"],
            stderrLimitBytes: 2 * 1024 * 1024  // raise cap above the 1MB payload
        )
        #expect(result.exitCode == 0)
        #expect(result.stderr.count >= 1024 * 1024,
                "Expected at least 1MiB stderr, got \(result.stderr.count)")
    }

    // regression: #56 — Both pipes filling concurrently doesn't deadlock either
    @Test func bothPipesLargeNoDeadlock() async throws {
        let result = await ProcessRunner.runProcess(
            executable: shellPath,
            arguments: [
                "-c",
                "/bin/dd if=/dev/zero bs=1024 count=512 2>/dev/null; " +
                "/bin/dd if=/dev/zero bs=1024 count=512 2>/dev/null | /usr/bin/tee /dev/stderr >/dev/null"
            ],
            stderrLimitBytes: 2 * 1024 * 1024
        )
        #expect(result.exitCode == 0)
        #expect(result.stdout?.count == 512 * 1024)
        #expect(result.stderr.count >= 512 * 1024)
    }

    // regression: #56 — Stderr limit honoured even under flood (bounded memory)
    @Test func stderrLimitTruncatesOversizeOutput() async throws {
        let result = await ProcessRunner.runProcess(
            executable: shellPath,
            arguments: ["-c", "/bin/dd if=/dev/zero bs=1024 count=1024 2>/dev/null | /usr/bin/tee /dev/stderr >/dev/null"],
            stderrLimitBytes: 64 * 1024   // 64KB cap
        )
        #expect(result.exitCode == 0)
        // Truncation lets the process complete — the child shouldn't block
        // even though we capped the in-memory tail.
        #expect(result.stderr.count <= 64 * 1024 + 256)   // small slack
    }

    // regression: #56 — Non-zero exit propagates to caller cleanly
    @Test func nonZeroExitCodePropagates() async throws {
        let result = await ProcessRunner.runProcess(
            executable: shellPath,
            arguments: ["-c", "exit 42"]
        )
        #expect(result.exitCode == 42)
    }

    // regression: #56 — runProcess's stdout type round-trips correctly
    @Test func smallOutputRoundTrips() async throws {
        let result = await ProcessRunner.runProcess(
            executable: shellPath,
            arguments: ["-c", "printf 'hello\\nworld'"]
        )
        #expect(result.exitCode == 0)
        #expect(result.stdout == "hello\nworld")
    }
}

// MARK: - parseMeanVolumeDB tests

struct ParseMeanVolumeTests {

    // regression: #56 — extracted parseMeanVolumeDB still recognises the value
    @Test func extractsMeanVolumeFromFFmpegOutput() {
        let sample = """
        [Parsed_volumedetect_0 @ 0x600003c89180] n_samples: 882000
        [Parsed_volumedetect_0 @ 0x600003c89180] mean_volume: -23.4 dB
        [Parsed_volumedetect_0 @ 0x600003c89180] max_volume: -5.0 dB
        """
        #expect(CombineVerifier.parseMeanVolumeDB(from: sample) == -23.4)
    }

    // regression: #56 — parser returns nil when no mean_volume line present
    @Test func returnsNilWhenAbsent() {
        let sample = "[ffmpeg] no audio stream found"
        #expect(CombineVerifier.parseMeanVolumeDB(from: sample) == nil)
    }

    // regression: #56 — parser handles positive dB values (loud audio)
    @Test func handlesPositiveDB() {
        let sample = "[volumedetect] mean_volume: 3.2 dB"
        #expect(CombineVerifier.parseMeanVolumeDB(from: sample) == 3.2)
    }
}
