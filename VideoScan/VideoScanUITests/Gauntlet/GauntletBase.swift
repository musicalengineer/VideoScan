//
//  GauntletBase.swift
//  VideoScanUITests — Gauntlet v1
//
//  Shared plumbing for the Gauntlet: the five UI flows that mimic Rick's
//  real spot-test ritual (docs/gauntlet.md). Each flow is an independent
//  XCTestCase subclass of GauntletTestCase, which provides:
//
//    * the VS_GAUNTLET=1 positive gate (mirrors SmokeUITests' VS_UI_SMOKE
//      gate — the Gauntlet never runs from a plain `xcodebuild test`)
//    * isolated app launch: VS_UI_TEST=1 flips every in-app test-host
//      gate (no real catalog, no real prefs writes, POI/cache/log
//      redirects), PLUS a throwaway HOME/CFFIXED_USER_HOME so anything
//      that still reads or writes CFPreferences/App Support lands in a
//      per-run sandbox, never in Rick's account
//    * transient launch-argument seams (GauntletSeams.swift in the app)
//      for fixture folders — the NSOpenPanel replacement
//    * a screenshot attached automatically on every failure
//
//  Machine policy (docs/gauntlet.md): EXECUTE on the M1 first; the M4
//  only inside declared windows (midnight–10:00) — its testmanagerd
//  bootstrap is flaky for UI-test runners, which is an environment
//  problem, not a code signal.
//

import XCTest

class GauntletTestCase: XCTestCase {

    /// The app under test, kept for the failure screenshot.
    private(set) var app: XCUIApplication?

    /// Per-test sandbox root (fixtures + fake home). Cleaned in tearDown.
    private(set) var sandboxRoot: URL!

    /// Fake home the app under test runs with — prefs (CFFIXED_USER_HOME)
    /// and Application Support resolve here, so the app cannot touch the
    /// real account even where an in-app gate is missing.
    private(set) var fakeHome: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["VS_GAUNTLET"] == "1",
            "Gauntlet flows run only via the VideoScan-Gauntlet test plan / scripts/run_gauntlet.sh (VS_GAUNTLET=1)."
        )
        sandboxRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("gauntlet_\(UUID().uuidString.prefix(8))",
                                    isDirectory: true)
        fakeHome = sandboxRoot.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(
            at: fakeHome.appendingPathComponent("Library/Preferences"),
            withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        app?.terminate()
        // Fixture teardown. Project policy forbids deleting USER files —
        // this sandbox is entirely test-created, same lifecycle as
        // BalanceAudioTestMedia's scratch dirs.
        if let root = sandboxRoot {
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// Screenshot on failure — every Gauntlet flow fails with pixels
    /// attached so a remote M1 run can be diagnosed from the .xcresult.
    override func record(_ issue: XCTIssue) {
        if let app {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "gauntlet-failure-\(name)"
            attachment.lifetime = .keepAlways
            var annotated = issue
            annotated.add(attachment)
            super.record(annotated)
            return
        }
        super.record(issue)
    }

    // MARK: - Launch

    /// Launch the app fully isolated. `seams` become transient
    /// `-key value` argument-domain defaults (see GauntletSeams.swift) —
    /// read-only overrides that never persist anywhere.
    @discardableResult
    func launchGauntletApp(seams: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        var args = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        for (key, value) in seams.sorted(by: { $0.key < $1.key }) {
            args += ["-\(key)", value]
        }
        app.launchArguments = args
        app.launchEnvironment = [
            "VS_UI_TEST": "1",
            // Belt-and-suspenders prefs/App-Support isolation. VS_UI_TEST
            // already gates every known persistence path in-app; the fake
            // home catches anything that gate misses (e.g. @AppStorage
            // writes like selectedTab).
            "HOME": fakeHome.path,
            "CFFIXED_USER_HOME": fakeHome.path
        ]
        app.launch()
        self.app = app
        return app
    }

    // MARK: - Shared steps

    /// Wait for the main window + tab strip, then click a tab by label
    /// ("People", "Catalog", …) via the existing tab.<label> identifiers.
    func openTab(_ app: XCUIApplication, _ label: String,
                 timeout: TimeInterval = 90) {
        let tab = app.buttons["tab.\(label)"]
        XCTAssertTrue(tab.waitForExistence(timeout: timeout),
                      "Tab strip never rendered (tab.\(label) missing) — app may have crashed on launch.")
        tab.click()
    }

    /// Flows 2/3/4: the fixture folder arrives via -gauntletScanTarget;
    /// this clicks Scan All and waits for a known fixture filename to
    /// appear in the catalog table. ffprobe on a handful of tiny files
    /// takes seconds; the timeout is generous for a cold M1.
    func scanFixturesIntoCatalog(_ app: XCUIApplication,
                                 waitForFilename filename: String,
                                 timeout: TimeInterval = 120) {
        openTab(app, "Catalog")
        // Scan All moved off the toolbar into Catalog Options on
        // 2026-08-12: run controls now live in the Scan Monitor window
        // and scanning is driven by selection (per-volume ▶ or
        // right-click "Scan Selected"), with this as the deliberate
        // whole-fleet verb. Menu items do not carry
        // accessibilityIdentifier, so it is title-matched like every
        // other menu action here.
        let options = app.buttons["Catalog Options"]
        XCTAssertTrue(options.waitForExistence(timeout: 30),
                      "Catalog Options menu never appeared on the Catalog tab.")
        options.click()
        clickMenuItem(app, titled: "Scan All Volumes")
        let row = app.staticTexts[filename]
        XCTAssertTrue(row.waitForExistence(timeout: timeout),
                      "Fixture \(filename) never appeared in the catalog table after Scan All — check ffprobe availability and the seam path.")
    }

    /// Click a menu item by its visible title. SwiftUI Buttons inside
    /// Menus / context menus render as NSMenuItems, and
    /// accessibilityIdentifier does NOT propagate to them (documented in
    /// CombineWorkflowUITests) — title matching is the only reliable hook.
    func clickMenuItem(_ app: XCUIApplication, titled title: String,
                       timeout: TimeInterval = 10) {
        let item = app.menuItems.matching(
            NSPredicate(format: "title == %@", title)).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: timeout),
                      "Menu item '\(title)' never appeared.")
        item.click()
    }

    /// Type into a SwiftUI TextField: click to focus, select-all, then
    /// type. macOS 26.5 note (CombineWorkflowUITests): typeText into
    /// SwiftUI fields is the least reliable XCUITest primitive — the
    /// select-all + retype shape has been the most robust variant.
    func replaceText(in field: XCUIElement, with text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 15),
                      "Text field \(field) never appeared.")
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text)
    }

    /// Poll for a file to appear (and stop growing) under `dir`.
    /// Same stable-size heuristic as CombineWorkflowUITests.
    func waitForFile(named name: String, in dir: URL,
                     timeout: TimeInterval) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               size > 10_000 {
                Thread.sleep(forTimeInterval: 2.0)
                let size2 = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size2 == size { return url }
            }
            Thread.sleep(forTimeInterval: 1.0)
        }
        XCTFail("\(name) never appeared (stable) in \(dir.path) within \(Int(timeout))s.")
        throw NSError(domain: "GauntletTestCase", code: 1)
    }
}
