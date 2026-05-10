import SwiftUI

// When launched as a test host, skip the full SwiftUI app to avoid
// crashes on headless CI runners that have no display server.
// XCTESTCONFIGURATION_TEMP_DIR is set by Xcode's test runner for
// both XCTest and Swift Testing frameworks.
let isTestHost = ProcessInfo.processInfo.environment["XCTESTCONFIGURATION_TEMP_DIR"] != nil
    || NSClassFromString("XCTestCase") != nil

if isTestHost {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.run()
} else {
    VideoScanApp.main()
}
