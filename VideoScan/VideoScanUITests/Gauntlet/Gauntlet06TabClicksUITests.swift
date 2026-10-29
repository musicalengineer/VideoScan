//
//  Gauntlet06TabClicksUITests.swift
//  VideoScanUITests — Gauntlet, flow 6
//
//  Rick 2026-10-29: "a couple more tests, small ones, which click on FT
//  tab and Hallie tab, just to click … I'd like to incrementally add more
//  UI automated tests over time." One click each, one window or tab
//  assertion, and the app must still be running afterwards (a crash on
//  the click fails here). Empty isolated catalog, no fixtures.
//
//  Opening the Family Map from the Family Tree tab is flow 7
//  (Gauntlet07FamilyMapUITests: a synthetic tree behind the
//  -gauntletFamilyTreeDir test-host seam).
//

import XCTest

final class Gauntlet06TabClicksUITests: GauntletTestCase {

    @MainActor
    func testFamilyTreeTabOpens() throws {
        let app = launchGauntletApp()
        openTab(app, "Family Tree")
        XCTAssertTrue(app.buttons["tab.Family Tree"].isHittable,
                      "Family Tree tab unusable after clicking it.")
        XCTAssertEqual(app.state, .runningForeground,
                       "App is not running after opening the Family Tree tab.")
    }

    /// The "Ask Hallie Mae" button in the tab strip is not a content tab:
    /// it opens the Family Archivist window (ContentView, openWindow(id:
    /// "archivist")).
    @MainActor
    func testHallieButtonOpensArchivistWindow() throws {
        let app = launchGauntletApp()
        let hallie = app.buttons["tab.Archivist"]
        XCTAssertTrue(hallie.waitForExistence(timeout: 90),
                      "Hallie button (tab.Archivist) never rendered in the tab strip.")
        hallie.click()

        let window = app.windows.matching(
            NSPredicate(format: "title == %@", "Family Archivist")).firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 30),
                      "Family Archivist window never opened from the Hallie button.")
        XCTAssertEqual(app.state, .runningForeground,
                       "App is not running after opening Hallie's window.")
    }
}
