import Foundation
import SwiftUI

let isTestHost = ProcessInfo.processInfo.environment["XCTESTCONFIGURATION_TEMP_DIR"] != nil

if isTestHost {
    // Drive the main CFRunLoop so XCTest's XCTWaiter (which polls
    // CFRunLoopGetMain() with RunLoop.main.run(until:)) can deliver
    // test plan / configuration events. dispatchMain() is NOT sufficient:
    // it drains the dispatch main queue but leaves CFRunLoopGetMain()
    // empty, so XCTWaiter sleeps in 100ms increments. CI logs showed
    // "Current run loop empty; sleeping the thread for 0.100s" ~20 times
    // per test (~2s per test, 1300 tests, 30-min timeout).
    //
    // NSApplication.run() also drives the CFRunLoop but additionally
    // blocks on a window-server handshake that hangs forever on headless
    // runners (no Aqua bootstrap, no display server). RunLoop.main.run()
    // gives us the run loop without the AppKit dependency.
    RunLoop.main.run()
} else {
    VideoScanApp.main()
}
