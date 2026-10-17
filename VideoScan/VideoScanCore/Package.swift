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
//
// Strict concurrency = COMPLETE for every target (stage 1 of the
// strict-concurrency rollout, Rick 2026-09-22). Still Swift 5 language mode,
// so findings are warnings, not errors. With swift-tools-version 6.0 the
// setting is the upcoming feature "StrictConcurrency" (SE-0337), which is
// what `-strict-concurrency=complete` maps to; it keeps the manifest free of
// `unsafeFlags`. Swift 6 mode would turn it on implicitly.
let strictConcurrency: [SwiftSetting] = [.enableUpcomingFeature("StrictConcurrency")]

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
        // One-time family-tree ingest: parse N GEDCOM pulls → merge by FSID →
        // compile → verify → promote (2026-08-28, Rick: "pay a one-time price").
        .executable(name: "videoscan-tree-ingest", targets: ["videoscan-tree-ingest"]),
        // Audio-fingerprint demo (2026-10-14): `fingerprint <file>` and
        // `match <query> <master>`, read-only, for "same event?" questions.
        .executable(name: "videoscan-audio-match", targets: ["videoscan-audio-match"]),
    ],
    dependencies: [
        // GRDB — the SQLite toolkit behind the catalog store (Rick, 2026-10-17:
        // "the database is a plugin behind a protocol"). Pinned EXACTLY so a
        // `swift package update` can never move the engine under the catalog;
        // bumping it is a deliberate commit. 7.11.1 was released 2026-06-18
        // (the latest stable, four months old on 2026-10-17); it needs
        // Swift 6.1+ / Xcode 16.3+ and macOS 10.15+, so it builds on CI's
        // Xcode 26.3 and on the fleet's 27. Only files under
        // Sources/VideoScanCore/Store/ may `import GRDB`
        // (CatalogStoreSensorTests pins that).
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
    ],
    targets: [
        .target(
            name: "VideoScanCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: strictConcurrency
        ),
        .executableTarget(
            name: "videoscan-preview-sweep",
            dependencies: ["VideoScanCore"],
            swiftSettings: strictConcurrency
        ),
        .executableTarget(
            name: "videoscan-tree-ingest",
            dependencies: ["VideoScanCore"],
            swiftSettings: strictConcurrency
        ),
        .executableTarget(
            name: "videoscan-audio-match",
            dependencies: ["VideoScanCore"],
            swiftSettings: strictConcurrency
        ),
        .testTarget(
            name: "VideoScanCoreTests",
            dependencies: ["VideoScanCore"],
            swiftSettings: strictConcurrency
        ),
    ],
    swiftLanguageModes: [.v5]
)
