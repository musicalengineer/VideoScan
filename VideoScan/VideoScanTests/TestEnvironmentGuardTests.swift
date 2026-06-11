import Foundation
import Testing
@testable import VideoScan

// MARK: - Test-host isolation guard (Rick 2026-06-10)
//
// The app target is the unit-test host, so `xcodebuild test` runs real
// app startup. CatalogStore has guarded its shared singleton for a
// while; CatalogSync did not — a test run on the master Mac ran real
// sync, and on a viewer machine syncFromMaster() would pull the master
// catalog over local data. These tests pin (1) the shared detection
// predicate, (2) that production() is inert under a test host, and
// (3) that inert instances refuse to write.

@Suite("TestEnvironment detection")
struct TestEnvironmentDetectTests {

    @Test func xctestConfigEnvDetected() {
        #expect(TestEnvironment.detect(
            environment: ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"],
            loadedBundlePaths: [], hasXCTestCaseClass: false))
    }

    @Test func xctestBundlePathEnvDetected() {
        #expect(TestEnvironment.detect(
            environment: ["XCTestBundlePath": "/tmp/T.xctest"],
            loadedBundlePaths: [], hasXCTestCaseClass: false))
    }

    @Test func swiftTestingEnvDetected() {
        #expect(TestEnvironment.detect(
            environment: ["SWIFT_TESTING_ENABLED": "1"],
            loadedBundlePaths: [], hasXCTestCaseClass: false))
    }

    @Test func xctestCaseClassDetected() {
        #expect(TestEnvironment.detect(
            environment: [:], loadedBundlePaths: [], hasXCTestCaseClass: true))
    }

    @Test func loadedXctestBundleDetected() {
        #expect(TestEnvironment.detect(
            environment: [:],
            loadedBundlePaths: ["/Applications/X.app", "/tmp/VideoScanTests.xctest"],
            hasXCTestCaseClass: false))
    }

    @Test func cleanProcessNotDetected() {
        #expect(!TestEnvironment.detect(
            environment: ["PATH": "/usr/bin", "HOME": "/Users/x"],
            loadedBundlePaths: ["/Applications/VideoScan.app"],
            hasXCTestCaseClass: false))
    }

    // We ARE a test host right now — the live predicate must say so.
    // If this fails, every downstream guard is silently disarmed.
    @Test func livePredicateTrueUnderTests() {
        #expect(TestEnvironment.isTestHost)
    }
}

@Suite("CatalogSync inert mode")
struct CatalogSyncInertTests {

    private struct FixedHostname: HostnameSource {
        let name: String
        func currentHostname() -> String { name }
    }

    private final class RefusingRsync: RsyncRunner, @unchecked Sendable {
        var invoked = false
        func run(args: [String], destDir: URL) async -> RsyncOutcome {
            invoked = true
            return RsyncOutcome(succeeded: true, exitCode: 0, stderr: "")
        }
    }

    private func tempPaths() throws -> CatalogSyncPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vs-inert-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return CatalogSyncPaths(
            liveDir: root.appendingPathComponent("live"),
            stagingDir: root.appendingPathComponent("staging"),
            previousDir: root.appendingPathComponent("previous"),
            lastSyncFile: root.appendingPathComponent("last-sync.txt"))
    }

    @MainActor
    @Test func productionIsInertUnderTestHost() {
        // Constructing is safe: init only detects mode. The point of the
        // guard is that its mutating methods never run for real in tests.
        #expect(CatalogSync.production().isInert)
    }

    @MainActor
    @Test func inertMasterWritesNoManifest() throws {
        let paths = try tempPaths()
        try FileManager.default.createDirectory(at: paths.liveDir, withIntermediateDirectories: true)
        let sync = CatalogSync(paths: paths,
                               hostnameSource: FixedHostname(name: "master-host"),
                               rsyncRunner: RefusingRsync(),
                               masterHostname: "master-host",
                               remoteUser: "tester",
                               isInert: true,
                               log: { _ in })
        sync.writeManifestIfMaster()
        let manifest = paths.liveDir.appendingPathComponent("manifest.sha256")
        #expect(!FileManager.default.fileExists(atPath: manifest.path))
    }

    @MainActor
    @Test func inertViewerNeverRunsRsync() async throws {
        let paths = try tempPaths()
        let rsync = RefusingRsync()
        let sync = CatalogSync(paths: paths,
                               hostnameSource: FixedHostname(name: "viewer-host"),
                               rsyncRunner: rsync,
                               masterHostname: "master-host",
                               remoteUser: "tester",
                               isInert: true,
                               log: { _ in })
        await sync.syncFromMaster()
        sync.startViewerAutoRefresh(intervalSeconds: 0.01)
        #expect(!rsync.invoked)
    }

    @MainActor
    @Test func nonInertMasterStillWritesManifest() throws {
        // Negative control: the guard must not break real sync. A direct
        // (mock-injected, non-inert) master writes its manifest.
        let paths = try tempPaths()
        try FileManager.default.createDirectory(at: paths.liveDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: paths.liveDir.appendingPathComponent("catalog.json"))
        let sync = CatalogSync(paths: paths,
                               hostnameSource: FixedHostname(name: "master-host"),
                               rsyncRunner: RefusingRsync(),
                               masterHostname: "master-host",
                               remoteUser: "tester",
                               log: { _ in })
        sync.writeManifestIfMaster()
        let manifest = paths.liveDir.appendingPathComponent("manifest.sha256")
        #expect(FileManager.default.fileExists(atPath: manifest.path))
    }
}
