// BackgroundRegistrationGateTests.swift — who may register VideoScan
// Background (Rick 2026-11-03: "yes on helper rel build"). Only the Release
// build on the catalog master registers it. macOS registers the helper from
// whichever app copy turns it on, and the checkbox's defaults key is shared by
// the Debug and Release apps, so a Debug launch used to swap the registered
// helper for its own Debug copy. Also closes the codex-1102 leftover: the
// launch-time register ran on a viewer Mac (VideoScanApp.swift:161) while the
// toggle refused there.
//
// Dimensions: LOGIC (the refusal table, the launch call, the toggle),
// SENSOR (the launch passes the gate; the checkbox reads it).

import Foundation
import ServiceManagement
import Testing
@testable import VideoScan

@Suite("Background registration gate — Release build on the master only")
@MainActor
struct BackgroundRegistrationGateTests {
    typealias R = BackgroundServiceRegistrar

    @Test("the refusal table: viewer first, then a Debug build; Release on the master may register")
    func refusalTable() {
        #expect(R.registrationRefusal(isViewer: false, isReleaseBuild: true) == nil)
        #expect(R.registrationRefusal(isViewer: true, isReleaseBuild: true) == R.viewerRefusal)
        #expect(R.registrationRefusal(isViewer: false, isReleaseBuild: false) == R.debugBuildRefusal)
        #expect(R.registrationRefusal(isViewer: true, isReleaseBuild: false) == R.viewerRefusal)
        #expect(R.debugBuildRefusal.contains("Release"))
        #expect(R.viewerRefusal.contains("viewer"))
    }

    @Test("launch: a refused register never touches ServiceManagement and says why in one line")
    func launchRefusalRegistersNothing() {
        let fake = BackgroundServiceStoreTests.FakeAgent(.enabled)
        var made = 0
        var lines: [String] = []
        R.registerIfEnabled(enabled: true, refusal: R.debugBuildRefusal, service: { made += 1; return fake }, log: { lines.append($0) })
        #expect(made == 0 && fake.registerCalls == 0 && fake.unregisterCalls == 0,
                "a refused launch leaves the Release app's registration alone")
        #expect(lines == ["background service: not registered — \(R.debugBuildRefusal)"], "\(lines)")
    }

    @Test("toggle in a Debug build: refused — nothing registered, nothing persisted, the reason shown")
    func debugBuildToggleRefuses() {
        let agent = BackgroundServiceStoreTests.FakeAgent(.notRegistered)
        let (store, r) = BackgroundServiceStoreTests.make(enabled: false, agent: agent)
        store.isReleaseBuild = { false }
        #expect(store.registrationRefusal == R.debugBuildRefusal)
        store.setEnabled(true)
        #expect(!store.enabled)
        #expect(agent.registerCalls == 0)
        #expect(r.persisted.isEmpty)
        #expect(store.lastNote == R.debugBuildRefusal)
    }

    @Test("SENSOR: the launch passes the gate, and the checkbox is disabled by it")
    func sensor() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VideoScan/App")
        let launch = try String(contentsOf: app.appendingPathComponent("VideoScanApp.swift"), encoding: .utf8)
        #expect(launch.contains("BackgroundServiceRegistrar.registerIfEnabled(refusal: BackgroundServiceRegistrar.launchRefusal())"))
        let rows = try String(contentsOf: app.appendingPathComponent("ContentAnalysisSettingsRows.swift"), encoding: .utf8)
        #expect(rows.contains(".disabled(store.registrationRefusal != nil)"))
        #expect(rows.contains("store.registrationRefusal ?? Self.footnote"))
    }
}
