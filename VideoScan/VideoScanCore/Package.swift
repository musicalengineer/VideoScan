// swift-tools-version: 6.0
import PackageDescription

// VideoScanCore — the pure, Foundation-only domain model layer for VideoScan
// (VideoRecord + the persisted Codable enums, tagging, ffprobe, scan context).
// Extracted from the app target so the data layer compiles independently,
// enforces a UI-free boundary, and can be unit-tested in isolation.
//
// Swift 6 language mode (Rick 2026-10-25, docs/design/swift6_migration_2026_10_25.md,
// stage 1): strict concurrency is implicit and its findings are ERRORS, so a
// data race on tracked state cannot compile. The app target follows once its
// own diagnostics are at zero (stage 8). Platform floor is intentionally low
// (the domain uses only long-stable Foundation API); the app declares the
// real, higher deployment target.
//
// History: strict concurrency was turned on as warnings on 2026-09-22
// (`.enableUpcomingFeature("StrictConcurrency")`, Swift 5 mode); the v6 mode
// below replaces that setting.

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
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .executableTarget(
            name: "videoscan-preview-sweep",
            dependencies: ["VideoScanCore"]
        ),
        .executableTarget(
            name: "videoscan-tree-ingest",
            dependencies: ["VideoScanCore"]
        ),
        .executableTarget(
            name: "videoscan-audio-match",
            dependencies: ["VideoScanCore"]
        ),
        // TEST-ONLY (2026-10-18): the child process CatalogHardKillTests
        // SIGKILLs mid-commit. No product entry: the app links only the
        // library; `swift build` / `swift test` build it beside the tests.
        .executableTarget(
            name: "catalog-crash-helper",
            dependencies: ["VideoScanCore"]
        ),
        .testTarget(
            name: "VideoScanCoreTests",
            dependencies: ["VideoScanCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
