// swift-tools-version: 6.0
import PackageDescription

// VideoScanCore — the pure, Foundation-only domain model layer for VideoScan
// (VideoRecord + the persisted Codable enums, tagging, ffprobe, scan context).
// Extracted from the app target so the data layer compiles independently,
// enforces a UI-free boundary, and can be unit-tested in isolation.
//
// Swift 5 language mode to match the app target (SWIFT_VERSION = 5.0) — keeps
// VideoRecord's existing (non-Sendable) concurrency behavior identical to the
// pre-extraction app build. Platform floor is intentionally low (the domain
// uses only long-stable Foundation API); the app declares the real, higher
// deployment target.
let package = Package(
    name: "VideoScanCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "VideoScanCore", targets: ["VideoScanCore"]),
        // Out-of-process preview (filmstrip/still) prewarmer (Stage 1,
        // 2026-07-28). Depends on VideoScanCore so it drives the SAME
        // PreviewSweepEngine + PreviewDiskCache the app uses in-process.
        // Kept in THIS package (not a separate one) because it links the
        // shared engine directly with no app-only entanglement — the app
        // simply doesn't build this product.
        .executable(name: "videoscan-preview-sweep", targets: ["videoscan-preview-sweep"]),
    ],
    targets: [
        .target(name: "VideoScanCore"),
        .executableTarget(
            name: "videoscan-preview-sweep",
            dependencies: ["VideoScanCore"]
        ),
        .testTarget(
            name: "VideoScanCoreTests",
            dependencies: ["VideoScanCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
