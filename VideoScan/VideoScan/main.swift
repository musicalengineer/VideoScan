import Foundation
import SwiftUI

let isTestHost = ProcessInfo.processInfo.environment["XCTESTCONFIGURATION_TEMP_DIR"] != nil

if isTestHost {
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

    // Drive the main CFRunLoop so XCTest's XCTWaiter (which polls
    // CFRunLoopGetMain()) can deliver test plan / configuration events.
    // dispatchMain() drains the dispatch main queue but leaves the CFRunLoop
    // empty. NSApplication.run() drives the CFRunLoop but hangs on headless
    // runners (no window server). RunLoop.main.run() gives us the run loop
    // without the AppKit dependency.
    RunLoop.main.run()
} else {
    VideoScanApp.main()
}
