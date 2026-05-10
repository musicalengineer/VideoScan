import SwiftUI

let isTestHost = ProcessInfo.processInfo.environment["XCTESTCONFIGURATION_TEMP_DIR"] != nil
    || NSClassFromString("XCTestCase") != nil

if isTestHost {
    class TestHostDelegate: NSObject, NSApplicationDelegate {
        func applicationDidFinishLaunching(_ notification: Notification) {
            fputs("[TestHost] applicationDidFinishLaunching fired\n", stderr)
        }
    }
    fputs("[TestHost] detected test mode, launching minimal NSApplication\n", stderr)
    let app = NSApplication.shared
    let delegate = TestHostDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    fputs("[TestHost] calling app.run()\n", stderr)
    app.run()
    fputs("[TestHost] app.run() returned\n", stderr)
} else {
    VideoScanApp.main()
}
