// UITestStorageOverride.swift
// Single switch that redirects all per-user persistence (POI photos,
// scan-job descriptors, catalog.json) to a per-process tmp dir when the
// app is launched under XCUITest with the `--ui-test-fresh-storage`
// argument.
//
// Why this isn't the existing `isRunningTests` plumbing:
//   The existing checks (CatalogStore.isRunningTests, ScanJobsStorage.
//   isRunningTests, PersonFinderModel.isRunningTests) all fire when
//   XCTest classes are loaded into the *current* process. Under XCTest /
//   Swift Testing that's true: the test bundle and the host both live
//   in the same process and the .xctest bundle is loaded at launch.
//
//   Under XCUITest, the situation is different. The TEST runs in the
//   `VideoScanUITests-Runner.app` process; the APP that's being driven
//   is the real `VideoScan.app` binary, with no XCTest bundle attached.
//   None of the `isRunningTests` checks fire there. Without this hook,
//   a UI test would touch Rick's real ~/Library/Application Support
//   data.
//
// The launch flag is the explicit bridge. UI tests opt in via
//   app.launchArguments = ["--ui-test-fresh-storage"]
// in their XCUIApplication setup.
//
// Worst-case memory footprint: a single Foundation-backed POIProfile
// JSON (~1 KB) + the path Strings cached as statics. The tmp dir grows
// only with what the test writes into it (descriptors are ~600 bytes
// each); orphaned dirs from crashed test runs accumulate in
// /tmp/VideoScan-UITest-* and are cleaned on host reboot per
// macOS /tmp policy.

import Foundation

enum UITestStorageOverride {

    /// Launch flag the test runner injects via
    /// `XCUIApplication.launchArguments`. Anywhere in argv works.
    static let launchFlag = "--ui-test-fresh-storage"

    /// True when the launch flag was on argv at process start. Cached so
    /// every accessor doesn't re-walk argv.
    static let isActive: Bool = {
        ProcessInfo.processInfo.arguments.contains(launchFlag)
    }()

    /// Per-process root directory for all redirected stores. Stable across
    /// one app lifetime, fresh per process so re-launches from the same
    /// test can opt to share it via an env var (see `relaunchableRoot`).
    ///
    /// `nonisolated(unsafe)` because this is set exactly once in
    /// `activate()` before any other code reads it, and stays immutable
    /// afterwards.
    nonisolated(unsafe) static var rootDirectory: URL?

    /// When the test wants paths to survive a relaunch (same test invocation,
    /// app quit + relaunch sequence), it sets the env var
    /// `VS_UITEST_STORAGE_ROOT=/some/path` BEFORE launching the app. If
    /// present, we use that path verbatim instead of creating a fresh
    /// per-pid one. Lets the pause→quit→relaunch canary point both launches
    /// at the same `scan_jobs/` so the descriptor is visible on restore.
    private static let envOverrideKey = "VS_UITEST_STORAGE_ROOT"

    /// Idempotent — calling more than once is safe; first call wins on
    /// path resolution. Subsequent calls re-create the directory if missing
    /// (defends against a manual `rm -rf` between launches in tests).
    static func activate() {
        guard rootDirectory == nil else { return }

        let env = ProcessInfo.processInfo.environment
        let root: URL
        if let override = env[envOverrideKey], !override.isEmpty {
            root = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            // pid lets a single test's app launch get its own dir, while
            // the env-var path lets the test reuse it across relaunch.
            let pid = ProcessInfo.processInfo.processIdentifier
            let shortID = UUID().uuidString.prefix(8)
            root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("VideoScan-UITest-\(pid)-\(shortID)", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        rootDirectory = root

        // Seed substructure so first-access of each store finds clean dirs,
        // not stale leftovers (the env-shared case).
        let appSupport = root.appendingPathComponent("Application Support/VideoScan", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(
            at: appSupport.appendingPathComponent("scan_jobs", isDirectory: true),
            withIntermediateDirectories: true
        )
        try? FileManager.default.createDirectory(
            at: appSupport.appendingPathComponent("POI", isDirectory: true),
            withIntermediateDirectories: true
        )

        // Synthetic POI so the Family gallery shows one card and the user
        // (test) can create a search job without driving the photo picker.
        seedSyntheticPOI(in: appSupport)
    }

    /// Where redirected stores should root their `VideoScan/` folder.
    /// Returns nil when override is inactive — callers fall back to the
    /// production `applicationSupportDirectory` path.
    static var applicationSupportRoot: URL? {
        rootDirectory?.appendingPathComponent("Application Support", isDirectory: true)
    }

    // MARK: - Synthetic POI

    /// Pre-set POI name for the canary test. Stable so the test can find the
    /// card by `personFinder.familyCard.testperson`.
    static let syntheticPOIName = "TestPerson"

    /// Pre-set search path on the synthetic seed job. Intentionally a path
    /// that may or may not exist — the pause→restart canary doesn't care
    /// about scan results, only state transitions. Using `/tmp/...` keeps it
    /// in-pid-cleanable.
    static var syntheticSearchPath: URL {
        rootDirectory?.appendingPathComponent("fake-test-volume", isDirectory: true)
            ?? URL(fileURLWithPath: "/tmp/vs-uitest-fake-volume", isDirectory: true)
    }

    private static func seedSyntheticPOI(in appSupport: URL) {
        let folderName = "testperson"   // POIStorage.sanitize("TestPerson")
        let poiFolder = appSupport
            .appendingPathComponent("POI", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: poiFolder, withIntermediateDirectories: true)

        // Minimum-viable profile.json. Empty referencePath means the POI shows
        // in the gallery with no faces — fine for our purposes since the
        // canary never actually starts a real scan that needs reference faces.
        let profileURL = poiFolder.appendingPathComponent("profile.json")
        guard !FileManager.default.fileExists(atPath: profileURL.path) else { return }

        let profileJSON = """
        {
          "name": "\(syntheticPOIName)",
          "referencePath": "\(poiFolder.path)",
          "rejectedFiles": [],
          "largestFaceOnly": false,
          "engine": "vision"
        }
        """
        try? profileJSON.data(using: .utf8)?.write(to: profileURL, options: .atomic)

        // Pre-create the fake-test-volume dir so VolumeReachability returns
        // true on first-launch (Pause-then-quit path). On the relaunch path
        // we delete it from the test before clicking Resume so the resume
        // route hits the .failed branch deterministically.
        try? FileManager.default.createDirectory(
            at: syntheticSearchPath, withIntermediateDirectories: true
        )
    }
}
