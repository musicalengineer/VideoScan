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

    /// dlopen(RTLD_NOLOAD) answers "already loaded?" without loading it;
    /// dlsym finds the class symbol without touching the class.
    /// NEVER hand a class object to #expect: on CI (Xcode 26.3) the macro's
    /// capture of `NSClassFromString("AVPlayerView")` crashed the test runner
    /// ("crashed … freestanding macro expansion #2 of expect", 6d6e5288),
    /// and the restart limit then ran ZERO tests. #expect sees Bools only.
    @Test func theAppLoadsAVKitSoVideoPlayerCanFindAVPlayerView() {
        let handle = dlopen("/System/Library/Frameworks/AVKit.framework/Versions/A/AVKit", RTLD_NOLOAD)
        defer { if let handle { dlclose(handle) } }
        let loaded = handle != nil
        let hasPlayerView = handle.map { dlsym($0, "OBJC_CLASS_$_AVPlayerView") != nil } ?? false
        #expect(loaded, "AVKit.framework is not loaded — VideoPlayer will abort on first play")
        #expect(hasPlayerView, "AVPlayerView is not reachable in the loaded AVKit")
    }
}
