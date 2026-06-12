import Testing
import Foundation
@testable import VideoScan

// MARK: - IdentifyFamilyModel subprocess characterization tests
//
// Written BEFORE migrating IdentifyFamilyModel.launch onto ProcessRunner
// (codex finding #3) to pin the observable subprocess behavior:
//   • stdout protocol lines drive the published progress state
//   • non-zero exit while scanning → .failed("Process exited with status N")
//   • cancel() goes straight to .idle and the late termination callback
//     leaves the idle phase alone
//
// They use the test-internal python/script override seam with /bin/sh and
// a temp-dir script — the real cluster_faces.py pipeline is never run and
// no user data is touched (exit-1 paths never create the output run dir).

@MainActor
struct IdentifyFamilyLaunchTests {

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("idfam_launch_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeScript(_ body: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("fake_cluster_faces.sh")
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Poll until `condition` is true or the timeout elapses.
    private func waitUntil(
        timeoutSecs: Double = 10,
        _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(timeoutSecs)
        while !condition() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    // characterization: stdout progress protocol updates published state,
    // and a non-zero exit during scanning surfaces as .failed with the
    // exact historical message.
    @Test func stdoutProtocolDrivesProgressAndFailureSurfaces() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = try writeScript(
            """
            echo "[scan] 3 videos under $1"
            echo "[1/3] tape_a.mov: 2 faces (total 2)"
            echo "[2/3] tape_b.mov: 1 faces (total 3)"
            echo "console noise on stderr" >&2
            exit 7
            """,
            in: dir
        )

        let model = IdentifyFamilyModel()
        model.testPythonOverride = URL(fileURLWithPath: "/bin/sh")
        model.testScriptOverride = script
        model.selectedFolder = dir
        model.runName = "idfam_test_\(UUID().uuidString)"
        model.startScan()

        try await waitUntil { model.phase == .failed("Process exited with status 7") }

        #expect(model.phase == .failed("Process exited with status 7"))
        #expect(model.totalVideos == 3)
        #expect(model.processedVideos == 2)
        #expect(model.totalFaces == 3)
        #expect(model.currentFile == "tape_b.mov")
        #expect(model.consoleLines.contains("console noise on stderr"))
        #expect(model.consoleLines.contains(where: { $0.contains("tape_a.mov") }))
    }

    // characterization: cancel() during a run goes straight to .idle, and
    // the (later) child termination does not disturb the idle phase.
    @Test func cancelReturnsToIdleAndStaysIdle() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Sleeper redirects its fds so an orphaned child can't hold the
        // runner's pipes open after the shell is signalled.
        let script = try writeScript(
            """
            echo "[scan] 5 videos under $1"
            sleep 30 </dev/null >/dev/null 2>&1
            """,
            in: dir
        )

        let model = IdentifyFamilyModel()
        model.testPythonOverride = URL(fileURLWithPath: "/bin/sh")
        model.testScriptOverride = script
        model.selectedFolder = dir
        model.runName = "idfam_cancel_\(UUID().uuidString)"
        model.startScan()

        try await waitUntil { model.totalVideos == 5 }
        #expect(model.totalVideos == 5, "child never reported scan progress")

        model.cancel()
        #expect(model.phase == .idle)

        // Give the terminated child's exit callback time to land; phase
        // must remain .idle (handleTermination leaves cancelled runs alone).
        try await Task.sleep(for: .seconds(1))
        #expect(model.phase == .idle)
    }

    // characterization: a missing script fails fast without spawning.
    @Test func missingScriptFailsFast() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let model = IdentifyFamilyModel()
        model.testPythonOverride = URL(fileURLWithPath: "/bin/sh")
        model.testScriptOverride = dir.appendingPathComponent("does_not_exist.py")
        model.selectedFolder = dir
        model.runName = "idfam_missing_\(UUID().uuidString)"
        model.startScan()

        guard case .failed(let message) = model.phase else {
            Issue.record("expected .failed, got \(model.phase)")
            return
        }
        #expect(message.hasPrefix("Script missing:"))
    }
}
