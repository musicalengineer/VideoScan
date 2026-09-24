// TestHostStoreIsolationTests.swift
//
// codex #1713 (2026-09-23): FamilyGraphCompiledStore's test-host detector
// read four environment keys that XCTest sets but SwiftPM's Swift Testing
// runner (`swift test` → swiftpm-testing-helper) does NOT. Under `swift
// test`, a test that forgot to inject a store got `.production` pointed at
// Rick's real compiled family tree in Application Support.
//
// These run under whichever runner launched the Core package — `swift
// test`, Xcode's package scheme, or the app-host — and pin that the
// production factory never resolves to Application Support in any of them.
// Evaluating `.production` is a pure struct init: no disk is touched, so
// the red run cannot harm the real store.
//
// The out-of-process half (the actual `swift test` and `xcodebuild`
// invocation paths, checked from outside) is
// tests/test_test_host_detection_subprocess.py, which drives the probe
// suite at the bottom of this file.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("Test-host store isolation (codex #1713)")
struct TestHostStoreIsolationTests {

    private static var realApplicationSupportVideoScan: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("VideoScan", isDirectory: true).standardizedFileURL.path
    }

    /// No env mutation here: a concurrently running override test may set
    /// VIDEOSCAN_FAMILY_TREE_COMPILED_ROOT to a /private/tmp scratch path,
    /// which is also not Application Support — the assertion holds either way.
    @Test("production compiled store is never the real Application Support root under a test runner")
    func productionStoreIsSandboxed() {
        let root = FamilyGraphCompiledStore.production.root.standardizedFileURL.path
        #expect(!root.hasPrefix(Self.realApplicationSupportVideoScan),
                "FamilyGraphCompiledStore.production resolved to the REAL store (\(root)) inside a test process")
    }
}

// MARK: - Subprocess probe
//
// Driven by tests/test_test_host_detection_subprocess.py via
// `swift test --filter TestHostDetectionProbe` and via xcodebuild. When
// VS_TEST_HOST_PROBE_REPORT names a file, the probe writes what THIS
// process concluded, so the harness can assert from outside the runner.
// Without the variable it is an ordinary in-process check.

@Suite("TestHostDetectionProbe")
struct TestHostDetectionProbe {

    @Test func reportDetection() throws {
        let root = FamilyGraphCompiledStore.production.root.standardizedFileURL.path
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("VideoScan", isDirectory: true).standardizedFileURL.path
        let underRealStore = root.hasPrefix(appSupport)

        if let reportPath = ProcessInfo.processInfo.environment["VS_TEST_HOST_PROBE_REPORT"],
           !reportPath.isEmpty {
            let report: [String: String] = [
                "runner": "core",
                "argv0": CommandLine.arguments.first ?? "",
                "detected": TestHostDetection.isUnitTestProcess ? "true" : "false",
                "signal": TestHostDetection.currentSignal(includeUITestTarget: false)?.rawValue ?? "none",
                "compiledRoot": root,
                "compiledRootUnderApplicationSupport": underRealStore ? "true" : "false",
            ]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            try data.write(to: URL(fileURLWithPath: reportPath), options: .atomic)
        }
        #expect(TestHostDetection.isUnitTestProcess)
        #expect(!underRealStore, "production compiled store resolved to \(root)")
    }
}

// MARK: - Pure classifier, both directions

@Suite("TestHostDetection classifier (codex #1713)")
struct TestHostDetectionClassifierTests {

    private typealias D = TestHostDetection

    /// The exact shape codex captured under `swift test` (Xcode 26.3):
    /// no test env keys at all. Only argv/images give it away.
    private static let swiftPMHelper =
        "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper"
    private static let testBundleImage =
        "/tmp/pkg/.build/out/Products/Debug/ProbeTests.xctest/Contents/MacOS/ProbeTests"
    private static let testingFramework =
        "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks/Testing.framework/Versions/A/Testing"
    /// Loaded into ordinary macOS processes — must NOT count.
    private static let recapFramework =
        "/System/Library/PrivateFrameworks/RecapPerformanceTesting.framework/Versions/A/RecapPerformanceTesting"

    @Test func swiftPMTestingHelperArgv0Detected() {
        #expect(D.signal(in: .init(arguments: [Self.swiftPMHelper, "--test-bundle-path", "x"]),
                         includeUITestTarget: false) == .testRunnerExecutable)
    }

    @Test func xctestRunnerArgv0Detected() {
        #expect(D.signal(in: .init(arguments: ["/Applications/Xcode.app/Contents/Developer/usr/bin/xctest", "b.xctest"]),
                         includeUITestTarget: false) == .testRunnerExecutable)
    }

    @Test func testingLibraryArgumentDetected() {
        #expect(D.signal(in: .init(arguments: ["/some/renamed-helper", "--testing-library", "swift-testing"]),
                         includeUITestTarget: false) == .testingLibraryArgument)
    }

    @Test func imageInsideXctestBundleDetected() {
        #expect(D.signal(in: .init(loadedImagePaths: ["/usr/lib/libSystem.B.dylib", Self.testBundleImage]),
                         includeUITestTarget: false) == .testBundleImage)
    }

    @Test func swiftTestingFrameworkImageDetected() {
        #expect(D.signal(in: .init(loadedImagePaths: [Self.testingFramework]),
                         includeUITestTarget: false) == .testingLibraryImage)
        #expect(D.signal(in: .init(loadedImagePaths: ["/x/usr/lib/lib_TestingInterop.dylib"]),
                         includeUITestTarget: false) == .testingLibraryImage)
    }

    @Test func xctestEnvironmentKeysDetected() {
        for key in D.xctestEnvironmentKeys {
            #expect(D.signal(in: .init(environment: [key: ""]), includeUITestTarget: false) == .xctestEnvironment,
                    "\(key) (present-but-empty) must count")
        }
        #expect(D.signal(in: .init(environment: ["SWIFT_TESTING_ENABLED": "1"]),
                         includeUITestTarget: false) == .swiftTestingEnvironment)
    }

    @Test func uiTestTargetOnlyWhenRequestedAndOnlyForOne() {
        let ui = D.Inputs(environment: ["VS_UI_TEST": "1"])
        #expect(D.signal(in: ui, includeUITestTarget: true) == .uiTestTarget)
        #expect(D.signal(in: ui, includeUITestTarget: false) == nil, "main.swift's boot gate must ignore VS_UI_TEST")
        #expect(D.signal(in: .init(environment: ["VS_UI_TEST": "0"]), includeUITestTarget: true) == nil)
    }

    /// Negative control: a production-shaped VideoScan process, with the
    /// system framework whose name merely CONTAINS "Testing".
    @Test func productionProcessNotDetected() {
        let production = D.Inputs(
            environment: ["PATH": "/usr/bin", "HOME": "/Users/x", "__CFBundleIdentifier": "Rick-Breen.VideoScan"],
            arguments: ["/Applications/VideoScan.app/Contents/MacOS/VideoScan", "--hallie"],
            loadedBundlePaths: ["/Applications/VideoScan.app", "/System/Library/Frameworks/AppKit.framework"],
            loadedImagePaths: ["/Applications/VideoScan.app/Contents/MacOS/VideoScan",
                               "/Applications/VideoScan.app/Contents/Frameworks/VideoScanCore.framework/VideoScanCore",
                               Self.recapFramework,
                               "/usr/lib/libSystem.B.dylib"],
            hasXCTestCaseClass: false)
        #expect(D.signal(in: production, includeUITestTarget: true) == nil)
    }

    /// The signal that does NOT depend on a runner's env exports or on
    /// the toolchain linking XCTest into a Swift Testing bundle: this
    /// process has the tests loaded. Must fire on its own, under every
    /// runner (swift test, Xcode package scheme, app host).
    @Test func loadedImageSignalFiresOnItsOwnInThisProcess() {
        #expect(TestHostDetection.loadedImageSignal() != nil)
    }

    /// Scale/cost sensor: the live getter runs at dozens of call sites and
    /// a production (negative) answer always reaches the dyld walk; with
    /// the walk memoised on image count, 10k calls must stay cheap.
    @Test func imageWalkAndLiveGetterAreCheapWhenRepeated() {
        let start = Date()
        for _ in 0..<10_000 {
            _ = TestHostDetection.loadedImageSignal()
            _ = TestHostDetection.isTestHost
        }
        #expect(Date().timeIntervalSince(start) < 2.0)
    }
}
