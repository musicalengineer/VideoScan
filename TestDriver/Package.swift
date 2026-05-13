// swift-tools-version:5.9
//
// TestDriver — a SwiftUI front-end for hammering on a target macOS app.
// Initial target: VideoScan. The architecture (TestRegistry + UI) is
// intentionally generic so the same harness can be pointed at other apps
// later.
//
// Standalone macOS executable, not coupled to VideoScan.xcodeproj.
// Drives the target app from outside (subprocess invocation, defaults
// inspection, sample tool, log scanning, xcodebuild test invocation),
// which keeps TestDriver decoupled from any single project's internals.

import PackageDescription

let package = Package(
    name: "TestDriver",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "TestDriver", targets: ["TestDriver"])
    ],
    targets: [
        .executableTarget(
            name: "TestDriver",
            path: "Sources/TestDriver"
        )
    ]
)
