import Foundation
import VideoScanCore

// MARK: - TestEnvironment
//
// The app's face of the ONE "is this process a test?" predicate, which
// lives in VideoScanCore (TestHostDetection.swift) so Core stores and app
// stores cannot drift apart again (codex #1713, 2026-09-23: Core's copy
// missed `swift test` + Swift Testing entirely, and seven app-side copies
// had each grown their own slightly different signal list).
//
// The app target IS the test host: running `xcodebuild test` launches the
// real app, whose startup would otherwise load/save the user's live
// catalog.json and run CatalogSync against the real fleet. CatalogStore
// has guarded itself since the importCatalog incident; CatalogSync did
// not — on 2026-06-10 a test run on the master Mac ran real sync, and on
// a viewer-mode machine syncFromMaster() would pull the master catalog
// over local data. Every subsystem that touches user state must check
// THIS type rather than growing its own detection.

enum TestEnvironment {

    /// Pure detection over injected inputs — unit-testable without faking
    /// real process state. Forwards to Core's classifier.
    ///
    /// VS_UI_TEST=1 is the UI-test-target signal: under XCUITest the app
    /// under test is the REAL app in a separate process, so NONE of the
    /// runner markers are present in it (they live in the runner process).
    /// SmokeUITests injects VS_UI_TEST=1 via launchEnvironment so all the
    /// settings-pollution gates keyed off this predicate (catalog
    /// load/save, scan-target restore/persist, sync, caches) apply to the
    /// app under UI test exactly as they do to a unit-test host. Note:
    /// main.swift's test-HOST gate deliberately does NOT honour VS_UI_TEST
    /// (it uses `isUnitTestProcess`) — the UI must still launch fully.
    static func detect(environment: [String: String],
                       loadedBundlePaths: [String],
                       hasXCTestCaseClass: Bool,
                       arguments: [String] = [],
                       loadedImagePaths: [String] = []) -> Bool {
        TestHostDetection.signal(
            in: .init(environment: environment,
                      arguments: arguments,
                      loadedBundlePaths: loadedBundlePaths,
                      loadedImagePaths: loadedImagePaths,
                      hasXCTestCaseClass: hasXCTestCaseClass),
            includeUITestTarget: true) != nil
    }

    /// Unit-test host, `swift test`, Xcode host, OR the app under XCUITest.
    /// Computed (not cached): the .xctest bundle may be injected after
    /// process start, so an early cached `false` could stick wrongly.
    static var isTestHost: Bool { TestHostDetection.isTestHost }

    /// Runner signals only — ignores VS_UI_TEST. For the few gates that
    /// must still let the app under XCUITest behave like the real app
    /// (main.swift's boot gate, launch-time metrics polling).
    static var isUnitTestProcess: Bool { TestHostDetection.isUnitTestProcess }
}
