import Foundation

// MARK: - TestEnvironment
//
// Single source of truth for "is this process a unit-test host?".
//
// The app target IS the test host: running `xcodebuild test` launches the
// real app, whose startup would otherwise load/save the user's live
// catalog.json and run CatalogSync against the real fleet. CatalogStore
// has guarded itself since the importCatalog incident; CatalogSync did
// not — on 2026-06-10 a test run on the master Mac ran real sync, and on
// a viewer-mode machine syncFromMaster() would pull the master catalog
// over local data. Every subsystem that touches user state at startup
// must check this ONE flag rather than growing its own detection.

enum TestEnvironment {

    /// Pure detection over injected inputs — unit-testable without faking
    /// real process state. Checks both XCTest (legacy) and Swift Testing
    /// signals: Swift Testing tests don't necessarily link XCTest.
    static func detect(environment: [String: String],
                       loadedBundlePaths: [String],
                       hasXCTestCaseClass: Bool) -> Bool {
        if hasXCTestCaseClass { return true }
        if environment["XCTestConfigurationFilePath"] != nil { return true }
        if environment["XCTestBundlePath"] != nil { return true }
        if environment["SWIFT_TESTING_ENABLED"] != nil { return true }
        return loadedBundlePaths.contains { $0.hasSuffix(".xctest") }
    }

    /// Computed (not cached): the .xctest bundle may be injected after
    /// process start, so an early cached `false` could stick wrongly.
    static var isTestHost: Bool {
        detect(environment: ProcessInfo.processInfo.environment,
               loadedBundlePaths: Bundle.allBundles.map(\.bundlePath),
               hasXCTestCaseClass: NSClassFromString("XCTestCase") != nil)
    }
}
