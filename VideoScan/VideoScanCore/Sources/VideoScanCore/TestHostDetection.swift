// TestHostDetection.swift
//
// THE one "is this process a test?" predicate for Core AND the app
// (codex #1713, 2026-09-23). Every other detector in the codebase now
// forwards here; do not grow another copy.
//
// Why a new one: the old detectors keyed on environment variables that
// XCTest sets (XCTestConfigurationFilePath, XCTestBundlePath,
// XCTestSessionIdentifier) plus SWIFT_TESTING_ENABLED. SwiftPM's Swift
// Testing runner — `swift test` launching `swiftpm-testing-helper` — sets
// NONE of them (verified on Xcode 26.3,
// ~/Library/Logs/VideoScan/review_store_detection_20260923/output.txt), so
// FamilyGraphCompiledStore.production fell through to Rick's real compiled
// family tree for any Core test that forgot to inject a store. The app-side
// copies survived only because that toolchain happens to link XCTest into
// Swift Testing bundles — an accident, not a contract.
//
// So detection is multi-signal and deliberately includes signals that do
// not depend on what a runner chooses to export:
//   * environment  — XCTest/Xcode markers (unchanged; covers the app host)
//   * argv[0]      — swiftpm-testing-helper / xctest are test runners
//   * loaded code  — any dyld image inside an `*.xctest/` bundle, or the
//                    Swift Testing library itself (Testing.framework,
//                    lib_TestingInterop). A process that is running tests
//                    has loaded the tests; that is the one fact no runner
//                    can omit.
// Matching is by exact path component: macOS also loads
// RecapPerformanceTesting.framework into ordinary processes, so a
// substring match on "Testing" would be a false positive.
//
// Two flavours:
//   isUnitTestProcess — runner signals only. main.swift's boot gate uses
//                       this: the app under XCUITest must still launch its
//                       full UI.
//   isTestHost        — the above OR VS_UI_TEST=1 (SmokeUITests injects it
//                       into the app under XCUITest). Every settings/store
//                       pollution gate uses this.

import Foundation
import MachO
import os

public enum TestHostDetection {

    /// Why a process was classified as a test. Reported in the loud
    /// fail-safe log lines so a future miss is diagnosable from the log.
    public enum Signal: String, Sendable, CaseIterable {
        case xctestEnvironment
        case swiftTestingEnvironment
        case uiTestTarget
        case xctestCaseClass
        case xctestBundle
        case testRunnerExecutable
        case testingLibraryArgument
        case testBundleImage
        case testingLibraryImage
    }

    /// Process facts the predicate looks at. Injected so the pure
    /// classifier is testable in both directions without faking real
    /// process state (C++ analogy: a POD of inputs passed by value to a
    /// free function, instead of the function reaching for globals).
    public struct Inputs: Sendable {
        public var environment: [String: String]
        public var arguments: [String]
        public var loadedBundlePaths: [String]
        public var loadedImagePaths: [String]
        public var hasXCTestCaseClass: Bool

        public init(environment: [String: String] = [:],
                    arguments: [String] = [],
                    loadedBundlePaths: [String] = [],
                    loadedImagePaths: [String] = [],
                    hasXCTestCaseClass: Bool = false) {
            self.environment = environment
            self.arguments = arguments
            self.loadedBundlePaths = loadedBundlePaths
            self.loadedImagePaths = loadedImagePaths
            self.hasXCTestCaseClass = hasXCTestCaseClass
        }
    }

    static let xctestEnvironmentKeys = [
        "XCTestConfigurationFilePath",   // present-but-empty under Xcode 26 → `!= nil`
        "XCTestBundlePath",
        "XCTestSessionIdentifier",
        "XCTESTCONFIGURATION_TEMP_DIR",  // pre-Xcode-26 host marker
    ]

    static let testRunnerExecutableNames: Set<String> = [
        "swiftpm-testing-helper",  // `swift test`, Swift Testing (Xcode 26.x toolchains)
        "xctest",                  // `swift test`, XCTest; Xcode package tests
    ]

    /// Pure classifier. Returns the FIRST signal found (cheap checks
    /// first), or nil for an ordinary process.
    public static func signal(in inputs: Inputs, includeUITestTarget: Bool) -> Signal? {
        let env = inputs.environment
        if xctestEnvironmentKeys.contains(where: { env[$0] != nil }) { return .xctestEnvironment }
        if env["SWIFT_TESTING_ENABLED"] != nil { return .swiftTestingEnvironment }
        if includeUITestTarget, env["VS_UI_TEST"] == "1" { return .uiTestTarget }
        if inputs.hasXCTestCaseClass { return .xctestCaseClass }
        if let argv0 = inputs.arguments.first,
           testRunnerExecutableNames.contains((argv0 as NSString).lastPathComponent) {
            return .testRunnerExecutable
        }
        if inputs.arguments.contains("--testing-library") { return .testingLibraryArgument }
        if inputs.loadedBundlePaths.contains(where: { $0.hasSuffix(".xctest") }) { return .xctestBundle }
        if inputs.loadedImagePaths.contains(where: isTestBundleImage) { return .testBundleImage }
        if inputs.loadedImagePaths.contains(where: isTestingLibraryImage) { return .testingLibraryImage }
        return nil
    }

    /// An executable image living inside an `.xctest` bundle
    /// (`Foo.xctest/Contents/MacOS/Foo`) — the tests themselves.
    static func isTestBundleImage(_ path: String) -> Bool {
        path.split(separator: "/").dropLast().contains { $0.hasSuffix(".xctest") }
    }

    /// The Swift Testing library, by exact component (see file header re
    /// RecapPerformanceTesting.framework).
    static func isTestingLibraryImage(_ path: String) -> Bool {
        let components = path.split(separator: "/")
        if components.contains("Testing.framework") { return true }
        guard let last = components.last else { return false }
        return last == "lib_TestingInterop.dylib" || last == "libTesting.dylib"
    }

    // MARK: Live process

    /// Runner signals only (no VS_UI_TEST). main.swift's boot gate.
    public static var isUnitTestProcess: Bool { currentSignal(includeUITestTarget: false) != nil }

    /// Runner signals OR the UI-test target flag. Every store/settings
    /// pollution gate.
    public static var isTestHost: Bool { currentSignal(includeUITestTarget: true) != nil }

    /// Computed on every call — NOT cached — because an `.xctest` bundle
    /// can be injected after process start, so an early `false` must not
    /// stick. The only expensive input (the dyld image walk) is memoised
    /// on the image count: images are only ever added in practice, so an
    /// unchanged count means an unchanged answer.
    public static func currentSignal(includeUITestTarget: Bool) -> Signal? {
        var inputs = Inputs(environment: ProcessInfo.processInfo.environment,
                            arguments: CommandLine.arguments,
                            loadedBundlePaths: [],
                            loadedImagePaths: [],
                            hasXCTestCaseClass: NSClassFromString("XCTestCase") != nil)
        if let fast = signal(in: inputs, includeUITestTarget: includeUITestTarget) { return fast }
        inputs.loadedBundlePaths = Bundle.allBundles.map(\.bundlePath)
        if let bundle = signal(in: inputs, includeUITestTarget: includeUITestTarget) { return bundle }
        return loadedImageSignal()
    }

    private struct ImageScan {
        var imageCount: UInt32 = 0
        var signal: Signal?
    }
    private static let imageScan = OSAllocatedUnfairLock(initialState: ImageScan())

    /// Internal for tests: the toolchain-independent signal on its own.
    static func loadedImageSignal() -> Signal? {
        let count = _dyld_image_count()
        if let cached = imageScan.withLock({ $0.imageCount == count && count > 0 ? Optional($0.signal) : nil }) {
            return cached
        }
        var paths: [String] = []
        paths.reserveCapacity(Int(count))
        for index in 0..<count {
            if let name = _dyld_get_image_name(index) { paths.append(String(cString: name)) }
        }
        let found = signal(in: Inputs(loadedImagePaths: paths), includeUITestTarget: false)
        imageScan.withLock { $0 = ImageScan(imageCount: count, signal: found) }
        return found
    }

    // MARK: Test-host Application Support

    /// THE one stand-in for ~/Library/Application Support inside a test
    /// host (QA follow-up 2026-09-24): a private per-process temp directory
    /// shaped like the real one, so `<root>/VideoScan/cyberbrain`,
    /// `<root>/VideoScan/Hallie/…` and the family-asset roots keep their
    /// relative layout. nil outside a test host — the caller then uses the
    /// real directory. Every app default that would otherwise name the
    /// real Application Support routes through here; do not grow a copy.
    /// `store` names the caller in the once-per-store fail-safe log line.
    public static func sandboxedApplicationSupportRoot(for store: String) -> URL? {
        guard isTestHost else { return nil }
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "VideoScan-test-appsupport-\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: true)
        reportSandboxedProductionStore(store, sandbox: sandbox, overrideKey: nil)
        return sandbox
    }

    // MARK: Fail-safe logging

    private static let announced = OSAllocatedUnfairLock(initialState: Set<String>())

    /// A production-store factory was asked for its REAL root inside a
    /// test and redirected to a sandbox. Loud (stderr + unified log), once
    /// per store per process: the redirect is the fail-safe, the line is
    /// how the test that forgot to inject gets found.
    public static func reportSandboxedProductionStore(_ store: String, sandbox: URL, overrideKey: String?) {
        let first = announced.withLock { $0.insert(store).inserted }
        guard first else { return }
        let why = currentSignal(includeUITestTarget: true)?.rawValue ?? "unknown"
        var line = "[test-isolation] \(store): production root requested inside a test process "
            + "(signal \(why)) with no injected store — using sandbox \(sandbox.path)"
        if let overrideKey { line += "; set \(overrideKey) to point it somewhere deliberate" }
        FileHandle.standardError.write(Data((line + "\n").utf8))
        Logger(subsystem: "Rick-Breen.VideoScan", category: "test-isolation").notice("\(line, privacy: .public)")
    }
}
