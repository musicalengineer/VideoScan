import SwiftUI

let isTestHost = ProcessInfo.processInfo.environment["XCTESTCONFIGURATION_TEMP_DIR"] != nil
    || NSClassFromString("XCTestCase") != nil

if isTestHost {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.run()
} else {
    VideoScanApp.main()
}
