import Testing
import Foundation
@testable import VideoScan

// MARK: - MapKitLinkSensorTests
//
// Sensor for the Family Map (GH #227), modelled on AVKitLinkSensorTests:
// on the macOS 27 SDK `import AVKit` linked only the _AVKit_SwiftUI
// overlay, AVKit.framework never loaded, and VideoPlayer aborted the app
// on first use (52abfaaa). SwiftUI's `Map` lives in the _MapKit_SwiftUI
// overlay the same way, so MapKit.framework is linked explicitly in the
// project and `mapKitLinkAnchor()` names MKMapView next to the Map.
//
// The test bundle is hosted in the app, so this checks the APP's link.
// Do not `import MapKit` in this file — or in any test file — that would
// load it from here and make the sensor pass on its own.

struct MapKitLinkSensorTests {

    /// dlopen(RTLD_NOLOAD) answers "already loaded?" without loading it;
    /// dlsym finds the class symbol without touching the class.
    /// NEVER hand a class object to #expect: on CI (Xcode 26.3) the macro's
    /// capture of a class crashed the test runner (c489acdc / 6d6e5288),
    /// and the restart limit then ran ZERO tests. #expect sees Bools only.
    @Test func theAppLoadsMapKitSoTheFamilyMapCanFindMKMapView() {
        let handle = dlopen("/System/Library/Frameworks/MapKit.framework/Versions/A/MapKit", RTLD_NOLOAD)
        defer { if let handle { dlclose(handle) } }
        let loaded = handle != nil
        let hasMapView = handle.map { dlsym($0, "OBJC_CLASS_$_MKMapView") != nil } ?? false
        #expect(loaded, "MapKit.framework is not loaded — the Family Map will abort on first show")
        #expect(hasMapView, "MKMapView is not reachable in the loaded MapKit")
    }
}
