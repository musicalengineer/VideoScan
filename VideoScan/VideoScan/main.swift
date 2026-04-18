import SwiftUI

// When launched as a test host, skip the full SwiftUI app to avoid
// crashes on headless CI runners that have no display server.
if NSClassFromString("XCTestCase") != nil {
    // Minimal run loop for the test host — keep the process alive
    // so XCTest can bootstrap and run tests inside this host app.
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.run()
} else {
    VideoScanApp.main()
}
