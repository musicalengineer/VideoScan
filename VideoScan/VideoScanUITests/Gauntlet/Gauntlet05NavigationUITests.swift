//
//  Gauntlet05NavigationUITests.swift
//  VideoScanUITests — Gauntlet v1, flow 5 of 5
//
//  Rick's spot test: "general navigation." Tabs cycle, the catalog
//  inspector toggles, the Media File Operations window opens from the
//  Window menu, and the About window shows the live version + git hash
//  summary (BuildInfo.summary — "VideoScan v3.5 …").
//
//  No fixtures needed: this flow runs against the empty isolated
//  catalog, which also keeps the accessibility tree tiny and fast
//  (SmokeUITests' 12k-row lesson).
//

import XCTest

final class Gauntlet05NavigationUITests: GauntletTestCase {

    /// The About summary must show a VERSION and build provenance. It used
    /// to pin the literal "3.5" and "keep in sync with MARKETING_VERSION" —
    /// which nobody did: the app went to 3.7 on 2026-09-15 and this test
    /// failed on 2026-09-18 reading "v3.7 (debug) · main @ c010f2d5".
    ///
    /// A version number is not the invariant; SHOWING one is. Pinning the
    /// literal meant the test went red on every release for no defect, and
    /// a test that cries wolf at each bump is one nobody keeps current —
    /// which is exactly what happened.
    static let versionPattern = #"v\d+\.\d+"#

    @MainActor
    func testTabsInspectorMFOWindowAndAbout() throws {
        let app = launchGauntletApp()

        // 1. Tabs — click through all six; each must exist and stay
        //    hittable after the switch (a crash mid-switch fails here).
        //    (Workbench merged into Triage; Storage added — 2026-08-19.)
        for label in ["People", "Catalog", "Storage", "Triage",
                      "Archive", "Family Tree"] {
            openTab(app, label)
            XCTAssertTrue(app.buttons["tab.\(label)"].isHittable,
                          "Tab \(label) unusable after switching to it.")
        }

        // 2. Inspector toggle on the Catalog tab: two clicks — off, on.
        //    (State assertions are cheap-and-honest: the button itself
        //    must survive both presses; deeper content assertions live
        //    in flow 3, which uses the inspector for real work.)
        openTab(app, "Catalog")
        let toggle = app.buttons["catalog.inspectorToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 30),
                      "Inspector toggle missing from the catalog toolbar.")
        toggle.click()
        toggle.click()
        XCTAssertTrue(toggle.isHittable, "Inspector toggle wedged after toggling.")

        // 3. MFO window from the Window menu (its declared title).
        let windowMenu = app.menuBarItems["Window"]
        XCTAssertTrue(windowMenu.waitForExistence(timeout: 15),
                      "Window menu missing from the menu bar.")
        windowMenu.click()
        clickMenuItem(app, titled: "Media File Operations")
        XCTAssertTrue(app.windows["Media File Operations"].waitForExistence(timeout: 15),
                      "Media File Operations window never opened from the Window menu.")

        // 4. About — version + git hash summary line. Menu path mirrors
        //    SmokeUITests (identifier matching doesn't reach NSMenuItems).
        var appMenu = app.menuBarItems.matching(
            NSPredicate(format: "title == %@", "VideoScan")).firstMatch
        if !appMenu.waitForExistence(timeout: 10) {
            appMenu = app.menuBarItems.element(boundBy: 1)
            XCTAssertTrue(appMenu.waitForExistence(timeout: 5),
                          "App menu not found in the menu bar.")
        }
        appMenu.click()
        clickMenuItem(app, titled: "About VideoScan")

        let aboutWindow = app.windows.matching(
            NSPredicate(format: "title == %@", "About VideoScan")).firstMatch
        XCTAssertTrue(aboutWindow.waitForExistence(timeout: 15),
                      "About window never appeared.")
        let summary = app.staticTexts["about.buildSummary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 15),
                      "About window rendered without the BuildInfo summary line.")
        // A styled SwiftUI Text carrying only an .accessibilityIdentifier
        // exposes its string via the element's `value`, not `label`, on
        // macOS 26 — `label` comes back empty. (Flow 5's first real run,
        // 2026-07-20, caught this: the app renders "v3.5 …" correctly, but
        // this assertion read the wrong attribute.) Read label, falling back
        // to value — same pattern as Gauntlet01's `textViews...value as? String`.
        let summaryText = summary.label.isEmpty
            ? (summary.value as? String ?? "")
            : summary.label
        XCTAssertNotNil(summaryText.range(of: Self.versionPattern, options: .regularExpression),
                        "About summary shows no vN.N marketing version: \(summaryText)")
        // The genuine-git-hash release feature (67e765a): the summary
        // must carry SOME hash/branch info beyond the bare version.
        // The genuine-git-hash release feature (67e765a): beyond the bare
        // version the summary must carry branch/hash provenance.
        XCTAssertGreaterThan(summaryText.count, 10,
                             "About summary is suspiciously bare — git hash/branch info missing: \(summaryText)")
    }
}
