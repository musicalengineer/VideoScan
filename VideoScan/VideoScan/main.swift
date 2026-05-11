import Foundation
import SwiftUI

let isTestHost = ProcessInfo.processInfo.environment["XCTESTCONFIGURATION_TEMP_DIR"] != nil

if isTestHost {
    // Swift Testing's runner injects @Test functions into this process; we
    // just need the host alive. Do NOT call NSApplication.run() — it blocks
    // forever on headless CI (no window server, no Aqua bootstrap), which
    // was the real cause of the 30-min CI timeouts. dispatchMain() is what
    // Apple's own `xctest` binary uses for command-line test hosting:
    // drains the main queue, never returns, doesn't touch AppKit.
    dispatchMain()
} else {
    VideoScanApp.main()
}
