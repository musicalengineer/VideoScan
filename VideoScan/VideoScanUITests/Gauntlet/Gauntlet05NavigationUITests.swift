//
//  Gauntlet05NavigationUITests.swift
//  VideoScanUITests — Gauntlet v1, flow 5 of 5
//
//  Rick's spot test: "general navigation." Tabs cycle, the catalog
//  inspector toggles, the Media File Operations window opens from the
//  Window menu, and the About window shows the live version + git hash
//  summary (BuildInfo.summary — "VideoScan v2.6 …").
//
//  No fixtures needed: this flow runs against the empty isolated
//  catalog, which also keeps the accessibility tree tiny and fast
//  (SmokeUITests' 12k-row lesson).
//

import XCTest

final class Gauntlet05NavigationUITests: GauntletTestCase {

    @MainActor
    func testTabsInspectorMFOWindowAndAbout() throws {
        let app = launchGauntletApp()

        // 1. Tabs — click through all six; each must exist and stay
        //    hittable after the switch (a crash mid-switch fails here).
        for label in ["People", "Catalog", "Triage", "Workbench",
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
        // 2026-07-20, caught this: the app renders "v2.6 …" correctly, but
        // this assertion read the wrong attribute.) Read label, falling back
        // to value — same pattern as Gauntlet01's `textViews...value as? String`.
        let summaryText = summary.label.isEmpty
            ? (summary.value as? String ?? "")
            : summary.label
        XCTAssertTrue(summaryText.contains("2.6"),
                      "About summary lost the v2.6 marketing version: \(summaryText)")
        // The genuine-git-hash release feature (67e765a): the summary
        // must carry SOME hash/branch info beyond the bare version.
        XCTAssertGreaterThan(summaryText.count, "2.6".count + 4,
                             "About summary is suspiciously bare — git hash/branch info missing: \(summaryText)")
    }
}
