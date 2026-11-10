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

    @Test("RED 11/03 F4 SENSOR: the launch passes the gate; the checkbox is disabled only when OFF and refused — never while ON")
    func sensor() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VideoScan/App")
        let launch = try String(contentsOf: app.appendingPathComponent("VideoScanApp.swift"), encoding: .utf8)
        #expect(launch.contains("BackgroundServiceRegistrar.registerIfEnabled(refusal: BackgroundServiceRegistrar.launchRefusal())"))
        let rows = try String(contentsOf: app.appendingPathComponent("ContentAnalysisSettingsRows.swift"), encoding: .utf8)
        #expect(!rows.contains(".disabled(store.registrationRefusal != nil)"), "Codex 11/03 F4: OFF was unreachable")
        #expect(rows.contains(".disabled(control.actionDisabled || store.busy)"), "only Start is ever disabled by the gate")
        #expect(rows.contains("Self.footnoteWords(refusal: store.registrationRefusal)"), "the refusal adds to the how-to")
        #expect(rows.contains("refusal: store.registrationRefusal)"), "the helper line's Fix knows the gate")
    }

    @Test("F4 LOGIC: disabled only for OFF + refused")
    func checkboxRule() {
        func disabled(_ enabled: Bool, _ refusal: String?) -> Bool {
            BackgroundServicePresentation.control(enabled: enabled, launchd: enabled ? .enabled : .notRegistered, service: nil,
                                                  serviceProblem: nil, refusal: refusal, bundledBuild: nil).actionDisabled
        }
        #expect(disabled(false, R.debugBuildRefusal))
        #expect(disabled(false, R.viewerRefusal))
        #expect(!disabled(true, R.debugBuildRefusal), "ON in Debug: Stop must work")
        #expect(!disabled(true, R.viewerRefusal), "ON on a viewer: Stop must work")
        #expect(!disabled(false, nil))
        #expect(!disabled(true, nil))
    }

    @Test("RED 11/03 F4: enabled from Release, then a Debug build or a viewer — the control allows OFF and unregister is called")
    func offIsReachableWhenRefused() {
        for (debug, viewer) in [(true, false), (false, true), (true, true)] {
            let agent = BackgroundServiceStoreTests.FakeAgent(.enabled)
            let (store, r) = BackgroundServiceStoreTests.make(enabled: true, agent: agent, readOnly: viewer)
            store.isReleaseBuild = { !debug }
            #expect(store.registrationRefusal != nil, "turning ON is refused here")
            #expect(store.control.action == .stop && !store.control.actionDisabled, "debug \(debug) viewer \(viewer): Stop is offered")
            store.setEnabled(false)
            #expect(agent.unregisterCalls == 1)
            #expect(!store.enabled && r.persisted == [false])
            store.setEnabled(true)
            #expect(agent.registerCalls == 0, "and it cannot be turned back on here")
            #expect(store.control.action == .start && store.control.actionDisabled)
        }
    }

    @Test("the footnote: the refusal first, then the how-to — never the refusal alone")
    func footnoteAdds() {
        #expect(ContentAnalysisSettingsRows.footnoteWords(refusal: nil) == ContentAnalysisSettingsRows.footnote)
        let refused = ContentAnalysisSettingsRows.footnoteWords(refusal: R.debugBuildRefusal)
        #expect(refused.hasPrefix(R.debugBuildRefusal) && refused.hasSuffix(ContentAnalysisSettingsRows.footnote))
    }
}

// MARK: - Reviewer reds (fresh-eyes review of 50b7fe05, 2026-11-03), lifted
// from the review-1103 worktree. `fixNamesADisabledVerb` builds the lines the
// way the rows do (with `refusal:`, added by this fix) and reads the store's
// own `checkboxDisabled`.

@Suite("Background registration gate — reviewer reds (2026-11-03)")
@MainActor
struct BackgroundRegistrationGateReviewTests {
    typealias R = BackgroundServiceRegistrar

    @Test("WORKFLOW: a Debug app with the flag ON and launchd saying notRegistered must not tell Rick to 'turn the checkbox off and on'")
    func fixNamesADisabledVerb() async {
        let agent = BackgroundServiceStoreTests.FakeAgent(.notRegistered)
        let (store, _) = BackgroundServiceStoreTests.make(enabled: true, agent: agent)
        store.isReleaseBuild = { false }
        await store.refresh()
        let lines = BackgroundServicePresentation.lines(enabled: store.enabled, launchd: store.launchdStatus, service: store.service,
                                                        serviceProblem: store.serviceProblem, lastNote: store.lastNote,
                                                        refusal: store.registrationRefusal)
        // Turning it back ON is what re-registers, and ON is refused in Debug.
        #expect(!lines.helper.contains("Fix: press Start"), "\(lines.helper)")
        #expect(lines.helper.contains("in the Release build"), "\(lines.helper)")
    }

    @Test("LOGGING: the toggle's refusal is shown (lastNote) and logged")
    func toggleRefusalIsLogged() {
        let agent = BackgroundServiceStoreTests.FakeAgent(.notRegistered)
        let (store, r) = BackgroundServiceStoreTests.make(enabled: false, agent: agent)
        store.isReleaseBuild = { false }
        store.setEnabled(true)
        #expect(store.lastNote == R.debugBuildRefusal)
        #expect(r.lines.contains { $0.contains(R.debugBuildRefusal) }, "\(r.lines)")
    }
}
