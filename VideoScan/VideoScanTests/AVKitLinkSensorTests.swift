import Testing
import Foundation
import MachO
@testable import VideoScan

// MARK: - AVKitLinkSensorTests
//
// Sensor for the 2026-09-28 crash after the macOS 27 upgrade: the SDK's
// `import AVKit` linked only the _AVKit_SwiftUI overlay, AVKit.framework
// never loaded, and the Catalog preview's VideoPlayer aborted the app on
// first play ("failed to demangle superclass of VideoPlayerView from
// mangled name 'So12AVPlayerViewC'"). The fix names AVPlayerView next to
// the VideoPlayer call so the app links AVKit for real.
//
// The test bundle is hosted in the app, so this checks the APP's link.
// Do not `import AVKit` in this file — that would load it from here and
// make the sensor pass on its own.

struct AVKitLinkSensorTests {

    @Test func theAppLoadsAVKitSoVideoPlayerCanFindAVPlayerView() {
        let loaded = (0..<_dyld_image_count()).contains { i in
            guard let name = _dyld_get_image_name(i) else { return false }
            return String(cString: name).hasSuffix("/AVKit.framework/Versions/A/AVKit")
        }
        #expect(loaded, "AVKit.framework is not loaded — VideoPlayer will abort on first play")
        #expect(NSClassFromString("AVPlayerView") != nil)
    }
}
