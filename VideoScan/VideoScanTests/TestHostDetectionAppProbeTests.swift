// TestHostDetectionAppProbeTests.swift
//
// codex #1713 (2026-09-23): app-host half of the test-isolation fix. Every
// app-side detector now forwards to VideoScanCore.TestHostDetection via
// TestEnvironment. These pin (1) that the app wrapper classifies the
// `swift test` shape Core's old copy missed, (2) that main.swift's boot
// gate and TestEnvironment agree with Core's live answer in the Xcode test
// host, and (3) that both production compiled-store factories (.production
// and the app's .app) are sandboxed here.
//
// The probe suite is also driven from OUTSIDE by
// tests/test_test_host_detection_subprocess.py through xcodebuild, with
// TEST_RUNNER_VS_TEST_HOST_PROBE_REPORT (xcodebuild strips the
// TEST_RUNNER_ prefix and hands VS_TEST_HOST_PROBE_REPORT to the host).

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@Suite("TestEnvironment forwards to the shared detector (codex #1713)")
struct TestEnvironmentSharedDetectorTests {

    @Test func swiftPMTestingHelperShapeDetected() {
        // Exactly what codex captured under `swift test`: no env keys, no
        // XCTestCase class, no .xctest in Bundle.allBundles.
        #expect(TestEnvironment.detect(
            environment: [:], loadedBundlePaths: [], hasXCTestCaseClass: false,
            arguments: ["/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper"]))
        #expect(TestEnvironment.detect(
            environment: [:], loadedBundlePaths: [], hasXCTestCaseClass: false,
            loadedImagePaths: ["/tmp/b/Debug/VideoScanCoreTests.xctest/Contents/MacOS/VideoScanCoreTests"]))
    }

    @Test @MainActor func liveFlavoursAgreeWithCore() {
        #expect(TestEnvironment.isTestHost == TestHostDetection.isTestHost)
        #expect(TestEnvironment.isUnitTestProcess == TestHostDetection.isUnitTestProcess)
        #expect(isTestHost, "main.swift's boot gate must see the Xcode test host")
        #expect(TestEnvironment.isUnitTestProcess)
    }
}

@Suite("AppTestHostDetectionProbe")
struct AppTestHostDetectionProbe {

    @Test @MainActor func reportDetection() throws {
        let appSupport = try #require(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
            .appendingPathComponent("VideoScan", isDirectory: true).standardizedFileURL.path
        let productionRoot = FamilyGraphCompiledStore.production.root.standardizedFileURL.path
        let appRoot = FamilyGraphCompiledStore.app.root.standardizedFileURL.path
        let underRealStore = productionRoot.hasPrefix(appSupport) || appRoot.hasPrefix(appSupport)

        if let reportPath = ProcessInfo.processInfo.environment["VS_TEST_HOST_PROBE_REPORT"],
           !reportPath.isEmpty {
            let report: [String: String] = [
                "runner": "app-host",
                "argv0": CommandLine.arguments.first ?? "",
                "detected": TestEnvironment.isUnitTestProcess ? "true" : "false",
                "mainGate": isTestHost ? "true" : "false",
                "signal": TestHostDetection.currentSignal(includeUITestTarget: false)?.rawValue ?? "none",
                "compiledRoot": productionRoot,
                "appCompiledRoot": appRoot,
                "compiledRootUnderApplicationSupport": underRealStore ? "true" : "false",
            ]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            try data.write(to: URL(fileURLWithPath: reportPath), options: .atomic)
        }
        #expect(TestEnvironment.isUnitTestProcess)
        #expect(isTestHost)
        #expect(!underRealStore, "compiled store resolved to production=\(productionRoot) app=\(appRoot)")
    }
}
