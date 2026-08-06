import AppKit
import Foundation
import SwiftUI

// Multi-signal test-host detection. XCTESTCONFIGURATION_TEMP_DIR stopped
// being set somewhere around Xcode 26, which silently broke this gate:
// the full app (scenes, CatalogSync viewer rsync, volume observers,
// keepalive timers) booted inside every unit-test run. Xcode 26 sets
// XCTestBundlePath / XCTestSessionIdentifier / XCTestConfigurationFilePath
// (the last one present-but-empty, hence `!= nil`) on the host process at
// launch. Pinned by TestHostGateTests.
let isTestHost: Bool = {
    let env = ProcessInfo.processInfo.environment
    return env["XCTESTCONFIGURATION_TEMP_DIR"] != nil
        || env["XCTestConfigurationFilePath"] != nil
        || env["XCTestBundlePath"] != nil
        || env["XCTestSessionIdentifier"] != nil
}()

let isPersonEvaluation = CommandLine.arguments.contains("--person-eval")
let isRecipeCalibration = CommandLine.arguments.contains("--recipe-calibrate")
let isFindTagDaemon = CommandLine.arguments.contains("--find-tag")

if isFindTagDaemon {
    // Detached find-and-tag daemon (FindTagCLI). Same headless-Aqua
    // arrangement as --person-eval / --recipe-calibrate: Vision/CoreML
    // need an application context; `.prohibited` keeps us out of the
    // Dock. Spawned detached by the app (survives quit) or run by hand.
    let daemonApp = NSApplication.shared
    daemonApp.setActivationPolicy(.prohibited)
    Task {
        let code = await FindTagCLI.run(arguments: Array(CommandLine.arguments.dropFirst()))
        fflush(stdout)
        fflush(stderr)
        exit(code)
    }
    RunLoop.main.run()
} else if isPersonEvaluation {
    // Vision/CoreML require an Aqua application context even though the
    // evaluator has no windows. `.prohibited` keeps the process out of the
    // Dock and avoids activating the normal VideoScan scenes.
    let evaluationApp = NSApplication.shared
    evaluationApp.setActivationPolicy(.prohibited)
    Task {
        let code = await PersonEvaluationCLI.run(arguments: Array(CommandLine.arguments.dropFirst()))
        fflush(stdout)
        fflush(stderr)
        exit(code)
    }
    RunLoop.main.run()
} else if isRecipeCalibration {
    // Native recipe threshold calibration (RecipeCalibrationCLI). Same
    // headless-Aqua arrangement as --person-eval: Vision/CoreML need an
    // application context; `.prohibited` keeps us out of the Dock.
    let calibrationApp = NSApplication.shared
    calibrationApp.setActivationPolicy(.prohibited)
    Task {
        let code = await RecipeCalibrationCLI.run(arguments: Array(CommandLine.arguments.dropFirst()))
        fflush(stdout)
        fflush(stderr)
        exit(code)
    }
    RunLoop.main.run()
} else if isTestHost {
    // Forensic logging for CI test runs — every line is captured by
    // xcodebuild's StandardOutputAndStandardError.txt and uploaded as an
    // artifact, giving us an audit trail independent of xcresulttool's
    // possibly-broken summary parsing.
    let startEpoch = Date().timeIntervalSince1970
    print("TEST_HOST_STARTED epoch=\(String(format: "%.3f", startEpoch)) pid=\(getpid())")
    fflush(stdout)

    // Heartbeat every 10s. If the log stops getting these, we know exactly
    // when the host became unresponsive vs. when the workflow killed it.
    let heartbeat = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { _ in
        let now = Date().timeIntervalSince1970
        let elapsed = now - startEpoch
        print("TEST_HOST_HEARTBEAT epoch=\(String(format: "%.3f", now)) elapsed=\(String(format: "%.1f", elapsed))s")
        fflush(stdout)
    }
    RunLoop.main.add(heartbeat, forMode: .common)

    // Catch SIGTERM (sent by GitHub Actions when the workflow timeout fires).
    // Lets us record the exact moment the runner started killing us.
    signal(SIGTERM) { _ in
        let line = "TEST_HOST_SIGTERM_RECEIVED epoch=\(Date().timeIntervalSince1970)"
        // signal handler context: use write() not print() to avoid stdio locks
        line.withCString { ptr in
            let len = strlen(ptr)
            _ = write(STDOUT_FILENO, ptr, len)
            _ = write(STDOUT_FILENO, "\n", 1)
        }
        // Don't call exit() — let xcodebuild's normal teardown finish.
        // We just want the timestamp logged.
    }

    // Drive the run loop with a minimal NSApplication. Under Xcode 26 a bare
    // RunLoop.main.run() host hangs the XCTest IPC handshake ("the test
    // runner hung before establishing connection" after ~6 min) — XCTest
    // needs an Aqua application context to acquire its Mach port, the same
    // constraint behind the launchctl-submit wrapper for SSH test runs.
    // `.prohibited` activation policy keeps the host out of the Dock and
    // prevents it stealing focus; crucially we never call VideoScanApp.main(),
    // so no scenes, StateObjects, CatalogSync rsync, or volume observers run.
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    app.run()
} else {
    VideoScanApp.main()
}
