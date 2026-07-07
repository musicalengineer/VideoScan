//
//  SmokeUITests.swift
//  VideoScanUITests
//
//  The first UI test intended to actually RUN (the four older classes have
//  been skip-listed since 2026-05-29 and never executed successfully).
//  Smallest possible proof of life: launch the app, see the main window,
//  open the About box from the app menu, see it, close it, terminate.
//  No volumes, no search, no catalog interaction.
//
//  Isolation: the app under test is launched with VS_UI_TEST=1 in its
//  environment, which flips TestEnvironment.isTestHost (and its mirrored
//  detectors) inside the target process. Effects:
//    * CatalogStore.shared neither loads nor saves the real catalog.json
//    * scan targets are neither restored from nor persisted to UserDefaults
//    * MetadataCache / ScanJobsStorage / PersonFinder storage redirect to
//      per-process temp sandboxes
//    * CatalogSync is inert (no rsync, no manifest writes)
//    * appLog is a NullLogSink; Dossier auto-resume is skipped
//    * the RAM-disk reap (force-detach of /Volumes/VideoScan_Temp*) is
//      skipped, so a concurrently running production instance is safe
//  Net: the app launches with an EMPTY catalog — which also keeps the
//  accessibility tree tiny (see the 12k-row query-cost note in
//  CombineWorkflowUITests) and the whole test fast.
//
//  Run via:  scripts/run_ui_smoke.sh   (or the VideoScan-UI test plan)
//

import XCTest

final class SmokeUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false

        // Positive gate: this class is deliberately NOT in
        // VideoScan-CI.xctestplan's skippedTests list (that plan stays
        // untouched — units stay unit-only), so it self-skips unless
        // explicitly requested. The VideoScan-UI test plan sets
        // VS_UI_SMOKE=1 on the runner; scripts/run_ui_smoke.sh also
        // forwards TEST_RUNNER_VS_UI_SMOKE=1 as belt-and-suspenders.
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["VS_UI_SMOKE"] == "1",
            "UI smoke test runs only via the VideoScan-UI test plan / run_ui_smoke.sh (VS_UI_SMOKE=1)."
        )
    }

    @MainActor
    func testLaunchAboutBoxAndQuit() throws {
        let app = XCUIApplication()
        // Isolation switch — see file header. Without this the real app
        // would load Rick's 100k-record catalog and touch real prefs.
        app.launchEnvironment["VS_UI_TEST"] = "1"
        app.launch()

        // 1. Main window appears. First any window at all, then the tab
        //    strip — proving actual SwiftUI content rendered, not just an
        //    empty NSWindow. "tab.Catalog" is the existing identifier from
        //    ContentView's tab strip.
        XCTAssertTrue(
            app.windows.firstMatch.waitForExistence(timeout: 60),
            "No window appeared within 60s of launch — check ~/Library/Logs/VideoScan/ if the app crashed."
        )
        let catalogTab = app.buttons["tab.Catalog"]
        XCTAssertTrue(
            catalogTab.waitForExistence(timeout: 30),
            "Main window exists but the tab strip never rendered."
        )

        // 2. Open About via the app menu. accessibilityIdentifier does NOT
        //    propagate from SwiftUI Buttons to rendered NSMenuItems (see
        //    CombineWorkflowUITests), so match menu elements by title.
        //    The app menu bar item is titled with the bundle name; fall
        //    back to index 1 (0 = Apple menu) if the title lookup misses.
        var appMenu = app.menuBarItems.matching(
            NSPredicate(format: "title == %@", "VideoScan")
        ).firstMatch
        if !appMenu.waitForExistence(timeout: 10) {
            appMenu = app.menuBarItems.element(boundBy: 1)
            XCTAssertTrue(appMenu.waitForExistence(timeout: 5),
                          "App menu not found in the menu bar.")
        }
        appMenu.click()

        let aboutItem = app.menuItems.matching(
            NSPredicate(format: "title == %@", "About VideoScan")
        ).firstMatch
        XCTAssertTrue(aboutItem.waitForExistence(timeout: 10),
                      "'About VideoScan' menu item never appeared.")
        aboutItem.click()

        // 3. About window appears — matched by window title (set by the
        //    SwiftUI `Window("About VideoScan", id: "about")` scene) AND by
        //    the about.title identifier on its headline, proving content
        //    rendered.
        let aboutWindow = app.windows.matching(
            NSPredicate(format: "title == %@", "About VideoScan")
        ).firstMatch
        XCTAssertTrue(aboutWindow.waitForExistence(timeout: 15),
                      "About window never appeared after clicking the menu item.")
        XCTAssertTrue(app.staticTexts["about.title"].waitForExistence(timeout: 10),
                      "About window exists but its content (about.title) never rendered.")

        // 4. Close the About window via its close button; Cmd-W fallback
        //    (About is the key window right after opening).
        let closeButton = aboutWindow.buttons[XCUIIdentifierCloseWindow]
        if closeButton.exists && closeButton.isHittable {
            closeButton.click()
        } else {
            app.typeKey("w", modifierFlags: .command)
        }
        let aboutGone = expectation(
            for: NSPredicate(format: "exists == false"),
            evaluatedWith: aboutWindow
        )
        wait(for: [aboutGone], timeout: 15)

        // 5. Terminate. XCUIApplication.terminate() is a hard kill, so no
        //    quit-guard alert can hang us; the isTestHost gates mean there
        //    is nothing to flush anyway.
        app.terminate()
        XCTAssertEqual(app.state, .notRunning,
                       "App still running after terminate().")
    }
}
