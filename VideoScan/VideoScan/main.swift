import SwiftUI

let isTestHost = ProcessInfo.processInfo.environment["XCTESTCONFIGURATION_TEMP_DIR"] != nil
    || NSClassFromString("XCTestCase") != nil

if isTestHost {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    // On headless CI runners, app.run() can block waiting for the window server.
    // Posting an event ensures the run loop starts processing immediately.
    if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                                       modifierFlags: [], timestamp: 0, windowNumber: 0,
                                       context: nil, subtype: 0, data1: 0, data2: 0) {
        app.postEvent(event, atStart: true)
    }
    app.run()
} else {
    VideoScanApp.main()
}
