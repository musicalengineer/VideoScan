import Testing
import Foundation
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

    /// dlopen(RTLD_NOLOAD) answers "already loaded?" without loading it.
    /// NOT a walk of _dyld_image_count/_dyld_get_image_name: that list is
    /// not thread-safe, and with Swift Testing loading images on other
    /// threads the walk segfaulted the test host on CI (b8ef883f, 319ba883).
    @Test func theAppLoadsAVKitSoVideoPlayerCanFindAVPlayerView() {
        let handle = dlopen("/System/Library/Frameworks/AVKit.framework/Versions/A/AVKit", RTLD_NOLOAD)
        defer { if let handle { dlclose(handle) } }
        #expect(handle != nil, "AVKit.framework is not loaded — VideoPlayer will abort on first play")
        #expect(NSClassFromString("AVPlayerView") != nil)
    }
}
