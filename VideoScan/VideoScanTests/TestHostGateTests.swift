// TestHostGateTests.swift
//
// Pins the main.swift test-host gate. If `isTestHost` is false while the
// test runner is executing, VideoScanApp.main() booted the FULL app inside
// the test host — scenes, CatalogSync viewer rsync, volume observers,
// keepalive timers — contaminating every unit-test run with live app
// behavior. That regressed silently when Xcode stopped setting
// XCTESTCONFIGURATION_TEMP_DIR (observed under Xcode 26, 2026-06-09:
// CatalogSync rsync from RicksM4.local fired during a CICanaryTests-only
// run, and TEST_HOST_STARTED never appeared in xcodebuild stdout).

import Foundation
import Testing
@testable import VideoScan

@Suite("Test host gate")
struct TestHostGateTests {

    @Test("isTestHost is true under the test runner — the real app must not boot")
    func gateDetectsTestHost() {
        #expect(isTestHost,
                "main.swift's gate failed to detect the test host; VideoScanApp.main() ran and the full app booted under the tests")
    }

    @Test("diagnostic: test-related environment visible to the host process")
    func dumpTestEnvironmentSignals() {
        let env = ProcessInfo.processInfo.environment
        let interesting = env.keys.filter {
            $0.uppercased().contains("TEST") || $0.uppercased().contains("XCT")
        }.sorted()
        for key in interesting {
            print("TESTENV \(key)=\(env[key] ?? "")")
        }
        print("TESTENV_BUNDLES \(Bundle.allBundles.map(\.bundlePath).filter { $0.hasSuffix(".xctest") })")
        print("TESTENV_XCTESTCASE_CLASS \(NSClassFromString("XCTestCase") != nil)")
        #expect(!interesting.isEmpty, "no test-related env vars visible at all — detection has nothing to key on")
    }
}
