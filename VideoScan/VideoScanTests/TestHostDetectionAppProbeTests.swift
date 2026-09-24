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

/// QA follow-up 2026-09-24: the CyberBrain default root and the family
/// asset configuration's default Application Support root are the
/// DEFAULTS for FamilyTreeLiveModel, the pronunciation lexicon and the
/// live pronunciation writer. Under a test host neither may resolve into
/// the real ~/Library/Application Support/VideoScan — that is Rick's
/// family knowledge and GEDCOM.
@Suite("Production CyberBrain and family-asset defaults are sandboxed in a test host")
struct CyberBrainDefaultRootSandboxTests {

    private func realAppSupportVideoScan() throws -> String {
        try #require(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
            .appendingPathComponent("VideoScan", isDirectory: true).standardizedFileURL.path
    }

    @Test func cyberBrainProductionRootIsNotTheRealBrain() throws {
        let real = try realAppSupportVideoScan()
        let root = try #require(FamilyTreeNotesStorage.productionRootURL).standardizedFileURL.path
        #expect(!root.hasPrefix(real), "CyberBrain default resolved to the real brain: \(root)")
        #expect(root.contains("\(ProcessInfo.processInfo.processIdentifier)"),
                "sandbox must be per-process: \(root)")
        let lexiconDefault = try #require(HalliePronunciationLexicon.defaultCyberBrainRootURL)
            .standardizedFileURL.path
        #expect(!lexiconDefault.hasPrefix(real), "lexicon brain default is real: \(lexiconDefault)")
    }

    @Test func familyAssetConfigurationDefaultSupportRootIsSandboxed() throws {
        let real = try realAppSupportVideoScan()
        let config = FamilyAssetConfigurationCenter.configuration(
            masterArchiveRoot: nil, masterIsSafelyAvailable: true, readOnly: true)
        let paths = [config.roots.assets.path,
                     config.roots.thumbnailCache.path,
                     config.gedcomDirectory().path,
                     config.legacyGEDCOMDirectory?.path ?? ""]
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        for path in paths where !path.isEmpty {
            #expect(!path.hasPrefix(real), "default family-asset path is real App Support: \(path)")
        }
        // An explicit support root is still honoured exactly.
        let explicit = URL(fileURLWithPath: "/tmp/ExplicitSupport", isDirectory: true)
        let pinned = FamilyAssetConfigurationCenter.configuration(
            masterArchiveRoot: nil, masterIsSafelyAvailable: true, readOnly: true,
            applicationSupportRoot: explicit)
        #expect(pinned.roots.assets.path.hasPrefix("/tmp/ExplicitSupport/"))
    }

    /// QA follow-up 2026-09-24 (second pass): Hallie's live wiring built its
    /// CyberBrain, pronunciation and drill paths from the REAL Application
    /// Support, and the lexicon's default file sat there too.
    @Test func hallieLiveRootsAndPronunciationDefaultsAreSandboxed() throws {
        let real = try realAppSupportVideoScan()
        let support = HallieAppTurnCoordinator.Dependencies.productionApplicationSupportRoot
        let roots = HallieLiveDependencyRoots(applicationSupportRoot: support)
        let paths = [roots.cyberBrain, roots.pronunciationFile, roots.drillFile,
                     HalliePronunciationLexicon.defaultFileURL,
                     PronunciationDrillStore.defaultFileURL]
        for url in paths {
            let path = try #require(url, "a Hallie live root resolved to nil").standardizedFileURL.path
            #expect(!path.hasPrefix(real), "Hallie default is real App Support: \(path)")
            #expect(path.contains("\(ProcessInfo.processInfo.processIdentifier)"), "not per-process: \(path)")
        }
        // One sandbox, not a copy per store: the brain the live wiring
        // uses is the same one FamilyTreeNotesStorage hands out.
        #expect(roots.cyberBrain?.standardizedFileURL == FamilyTreeNotesStorage.productionRootURL?.standardizedFileURL)
    }
}
