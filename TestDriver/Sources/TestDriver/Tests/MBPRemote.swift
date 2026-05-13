// MBPRemote.swift
//
// Runs `xcodebuild test` on the M1 MBP over SSH. Wrapped in
// `launchctl submit` so the test host gets an Aqua bootstrap context
// — direct `ssh host xcodebuild test ...` aborts at childPID > 0
// because xctest can't acquire a Mach port without Aqua. Pattern
// established in earlier sessions; documented in
// memory/feedback_mbp_fast_user_switching.md.
//
// Output is captured to /tmp/<label>.{out,err} on the MBP, polled
// via `launchctl list`, then printed back over the SSH pipe and
// cleaned up.

import Foundation

enum MBPRemote {
    /// Hostname used for SSH. Matches reference_mbp_test_runner memory.
    static let host = "ricksmacbookpro.local"

    /// Project path on the MBP — different from the Mac Studio (~/dev vs.
    /// ~/developer). Caller doesn't need to know this; we resolve it here.
    static let projectDir = "/Users/rickb/developer/VideoScan"

    /// Run `xcodebuild test` on the MBP and return the same SubprocessResult
    /// shape Subprocess.run uses for local invocations. The caller in
    /// runXcodebuildTest treats the result identically to a local run.
    static func runXcodebuildTest(
        configuration: String,
        onlyTesting: String,
        coverage: Bool,
        log: @escaping @Sendable (String) -> Void,
        timeoutSeconds: TimeInterval
    ) async -> SubprocessResult {
        log("MBP: SSH + launchctl submit (\(configuration), \(onlyTesting))")

        // Build the xcodebuild command that runs INSIDE the launchctl job.
        // Single-line, single-quoted on the bash -c side. Uses CODE_SIGNING_ALLOWED=NO
        // and ENABLE_TESTABILITY=YES to mirror the local invocation.
        var xcArgs = [
            "xcodebuild test",
            "-project '\(projectDir)/VideoScan/VideoScan.xcodeproj'",
            "-scheme VideoScan",
            "-configuration \(configuration)",
            "-destination platform=macOS",
            "-derivedDataPath /tmp/td-mbp-dd",
            "-only-testing:\(onlyTesting)",
            "CODE_SIGNING_ALLOWED=NO"
        ]
        if configuration == "Release" {
            xcArgs.append("ENABLE_TESTABILITY=YES")
        }
        if coverage {
            xcArgs.append("-enableCodeCoverage YES")
            xcArgs.append("-resultBundlePath /tmp/td-mbp-coverage.xcresult")
        }
        let xcCmd = xcArgs.joined(separator: " ")

        // The wrapper script that runs on the MBP. Submits the job, polls
        // until it exits, prints captured output, returns the job's exit code.
        // Script is single-quoted on the SSH side so the local shell doesn't
        // interpret $LBL etc.
        let remoteScript = """
        set -u
        LBL="td.$(date +%s).$$"
        OUT="/tmp/$LBL.out"
        ERR="/tmp/$LBL.err"
        echo "MBP-SUBMIT label=$LBL" >&2
        launchctl submit -l "$LBL" -o "$OUT" -e "$ERR" -- /bin/bash -c '\(xcCmd)'
        # Wait for the launchctl job to leave the running state. While running,
        # `launchctl list <label>` includes a "PID" line; once exited it does not.
        while launchctl list "$LBL" 2>/dev/null | grep -q '"PID"'; do
          sleep 1
        done
        EXIT=$(launchctl list "$LBL" 2>/dev/null | grep '"LastExitStatus"' | awk '{print $3}' | tr -d ';')
        launchctl remove "$LBL" 2>/dev/null || true
        cat "$OUT"
        cat "$ERR" >&2
        rm -f "$OUT" "$ERR"
        echo "MBP-EXIT $EXIT" >&2
        exit "${EXIT:-1}"
        """

        let result = await Subprocess.run(
            "/usr/bin/ssh",
            [
                "-o", "ConnectTimeout=10",
                "-o", "BatchMode=yes",
                host,
                remoteScript
            ],
            timeoutSeconds: timeoutSeconds,
            stdoutLine: { line in
                if line.contains("Test Case") ||
                   line.contains("Test Suite") ||
                   line.contains("TEST SUCCEEDED") ||
                   line.contains("TEST FAILED") ||
                   line.contains("MBP-") ||
                   line.contains("error:") {
                    log("[mbp] " + line)
                }
            },
            stderrLine: { line in
                if line.contains("MBP-") {
                    log("[mbp/stderr] " + line)
                }
            }
        )
        return result
    }
}
