import Foundation
import XCTest
@testable import TeamChannelMonitor

final class CodexWakeTests: XCTestCase {
    func testCommandKeepsThreadAndMessageAsSeparateArguments() throws {
        let executable = URL(fileURLWithPath: "/tmp/codex")
        let target = "session name; echo unsafe"
        let message = "read #1373 $(touch /tmp/unsafe)"

        let command = try XCTUnwrap(CodexWake.command(
            threadTarget: target,
            message: message,
            executableURL: executable
        ))

        XCTAssertEqual(command.executableURL, executable)
        XCTAssertEqual(command.arguments, ["queue", "--thread", target, "--message", message])
    }

    func testCommandTrimsTargetAndRejectsBlankTarget() {
        let executable = URL(fileURLWithPath: "/tmp/codex")
        XCTAssertEqual(
            CodexWake.command(threadTarget: "  my session  ", executableURL: executable)?.arguments,
            ["queue", "--thread", "my session", "--message", CodexWake.defaultMessage]
        )
        XCTAssertNil(CodexWake.command(threadTarget: " \n ", executableURL: executable))
    }

    func testExecutableOverrideWins() {
        let selected = CodexWake.findExecutable(
            environment: [CodexWake.binaryOverrideEnvironmentKey: "/custom/codex"],
            homeDirectory: "/Users/test",
            isExecutable: { $0 == "/custom/codex" }
        )
        XCTAssertEqual(selected?.path, "/custom/codex")
    }

    func testExecutableFallsBackInSupportedOrder() {
        var probes: [String] = []
        let selected = CodexWake.findExecutable(
            environment: [:],
            homeDirectory: "/Users/test",
            isExecutable: {
                probes.append($0)
                return $0.hasSuffix("standalone/current/bin/codex")
            }
        )
        XCTAssertEqual(probes, [
            "/Users/test/.local/bin/codex",
            "/Users/test/.codex/packages/standalone/current/bin/codex"
        ])
        XCTAssertEqual(selected?.path, "/Users/test/.codex/packages/standalone/current/bin/codex")
    }

    func testExecutableSkipsInvalidOverrideAndReturnsNilWhenNoCandidateWorks() {
        var probes: [String] = []
        let selected = CodexWake.findExecutable(
            environment: [CodexWake.binaryOverrideEnvironmentKey: "/not/executable/codex"],
            homeDirectory: "/Users/test",
            isExecutable: {
                probes.append($0)
                return false
            }
        )

        XCTAssertEqual(probes, [
            "/not/executable/codex",
            "/Users/test/.local/bin/codex",
            "/Users/test/.codex/packages/standalone/current/bin/codex"
        ])
        XCTAssertNil(selected)
    }

    func testExecutableExpandsTildeInOverride() {
        let selected = CodexWake.findExecutable(
            environment: [CodexWake.binaryOverrideEnvironmentKey: "~/bin/codex"],
            homeDirectory: "/unused",
            isExecutable: { $0 == NSHomeDirectory() + "/bin/codex" }
        )

        XCTAssertEqual(selected?.path, NSHomeDirectory() + "/bin/codex")
    }

    func testWakeLaunchesOverrideWithoutShellInterpretation() async throws {
        let executable = try makeExecutable(
            named: "argument-recorder",
            contents: """
            #!/bin/sh
            printf '<%s>\\n' "$@"
            """
        )
        let target = "session name; echo unsafe"
        let message = "read #1373 $(touch /tmp/unsafe)"

        let result = await CodexWake.wake(
            threadTarget: target,
            message: message,
            environment: [CodexWake.binaryOverrideEnvironmentKey: executable.path]
        )

        XCTAssertTrue(result.ok)
        XCTAssertEqual(
            result.output,
            "<queue>\n<--thread>\n<session name; echo unsafe>\n<--message>\n<read #1373 $(touch /tmp/unsafe)>"
        )
    }

    func testWakeReturnsToolFailureOutput() async throws {
        let executable = try makeExecutable(
            named: "failing-codex",
            contents: """
            #!/bin/sh
            printf 'synthetic queue failure\\n' >&2
            exit 23
            """
        )

        let result = await CodexWake.wake(
            threadTarget: "test-session",
            environment: [CodexWake.binaryOverrideEnvironmentKey: executable.path]
        )

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.output, "synthetic queue failure")
    }

    func testWakeUsesDefaultSuccessMessageWhenToolIsSilent() async throws {
        let executable = try makeExecutable(
            named: "silent-successful-codex",
            contents: """
            #!/bin/sh
            exit 0
            """
        )

        let result = await CodexWake.wake(
            threadTarget: "test-session",
            environment: [CodexWake.binaryOverrideEnvironmentKey: executable.path]
        )

        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.output, "Wake request queued.")
    }

    func testWakeReportsProcessLaunchFailure() async throws {
        let executable = try makeExecutable(
            named: "invalid-executable",
            contents: "this is not an executable image"
        )

        let result = await CodexWake.wake(
            threadTarget: "test-session",
            environment: [CodexWake.binaryOverrideEnvironmentKey: executable.path]
        )

        XCTAssertFalse(result.ok)
        XCTAssertTrue(
            result.output.hasPrefix("Could not start Codex:"),
            "Unexpected launch-failure message: \(result.output)"
        )
    }

    func testWakeReportsStatusWhenToolFailsSilently() async throws {
        let executable = try makeExecutable(
            named: "silent-failing-codex",
            contents: """
            #!/bin/sh
            exit 17
            """
        )

        let result = await CodexWake.wake(
            threadTarget: "test-session",
            environment: [CodexWake.binaryOverrideEnvironmentKey: executable.path]
        )

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.output, "Codex exited with status 17.")
    }

    func testWakeDrainsOutputLargerThanPipeCapacity() async throws {
        let executable = try makeExecutable(
            named: "verbose-codex",
            contents: """
            #!/bin/sh
            yes x | head -c 524288
            """
        )

        let result = await CodexWake.wake(
            threadTarget: "test-session",
            environment: [CodexWake.binaryOverrideEnvironmentKey: executable.path]
        )

        XCTAssertTrue(result.ok)
        XCTAssertTrue(result.output.hasSuffix("[output truncated]"))
    }

    func testWakeTimesOutAndTerminatesChild() async throws {
        let executable = try makeExecutable(
            named: "hung-codex",
            contents: """
            #!/bin/sh
            trap '' TERM
            while :; do :; done
            """
        )
        let started = Date()

        let result = await CodexWake.wake(
            threadTarget: "test-session",
            timeout: 0.2,
            environment: [CodexWake.binaryOverrideEnvironmentKey: executable.path]
        )

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.output, "Codex wake timed out after 0.2 seconds and was terminated.")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    private func makeExecutable(named name: String, contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TeamChannelMonitorTests-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: url.path
        )
        return url
    }

}
