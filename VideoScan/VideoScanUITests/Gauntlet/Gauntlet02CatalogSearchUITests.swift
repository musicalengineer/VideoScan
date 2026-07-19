//
//  Gauntlet02CatalogSearchUITests.swift
//  VideoScanUITests — Gauntlet v1, flow 2 of 5
//
//  Rick's spot test: "search in the catalog window."
//
//  Three distinctly-named tiny clips get scanned in via the seam +
//  Scan All, then the search field filters them: "beach" must keep the
//  beach row and hide the others; clearing must bring everything back.
//
//  Known risk (documented in CombineWorkflowUITests): typeText into a
//  SwiftUI TextField is the flakiest XCUITest primitive on macOS 26.5.
//  If this flow flakes on the M1, the search step — not the assertion —
//  is the suspect; see docs/gauntlet.md § Known limitations.
//

import XCTest
import VideoScanCore

final class Gauntlet02CatalogSearchUITests: GauntletTestCase {

    @MainActor
    func testCatalogSearchFiltersScannedFixtures() throws {
        try XCTSkipUnless(GauntletFixtures.toolsAvailable,
                          "ffmpeg not installed — Gauntlet fixtures are synthesized per run.")

        // 1. Fixtures: three clips whose names share no substring.
        let catalogDir = sandboxRoot.appendingPathComponent("catalog", isDirectory: true)
        try FileManager.default.createDirectory(at: catalogDir, withIntermediateDirectories: true)
        for label in ["beach_1992", "birthday_bash", "zoo_trip"] {
            try GauntletFixtures.render(
                GauntletFixturePlan.catalogClip(label: label), into: catalogDir)
        }

        // 2. Launch, scan the folder in through the real UI.
        let app = launchGauntletApp(seams: ["gauntletScanTarget": catalogDir.path])
        scanFixturesIntoCatalog(app, waitForFilename: "test_gauntlet_beach_1992.mp4")

        // All three rows present pre-filter.
        XCTAssertTrue(app.staticTexts["test_gauntlet_birthday_bash.mp4"]
            .waitForExistence(timeout: 30),
            "Second fixture missing after scan — scan may have only partially completed.")
        XCTAssertTrue(app.staticTexts["test_gauntlet_zoo_trip.mp4"]
            .waitForExistence(timeout: 30),
            "Third fixture missing after scan.")

        // 3. Filter on "beach".
        let search = app.searchFields["catalog.searchField"].firstMatch.exists
            ? app.searchFields["catalog.searchField"].firstMatch
            : app.textFields["catalog.searchField"].firstMatch
        replaceText(in: search, with: "beach")

        // 4. Assert filtering: beach stays, the others go.
        let beach = app.staticTexts["test_gauntlet_beach_1992.mp4"]
        let birthday = app.staticTexts["test_gauntlet_birthday_bash.mp4"]
        XCTAssertTrue(beach.waitForExistence(timeout: 15),
                      "Matching row vanished while filtering on 'beach'.")
        let birthdayGone = expectation(
            for: NSPredicate(format: "exists == false"), evaluatedWith: birthday)
        wait(for: [birthdayGone], timeout: 20)
        XCTAssertFalse(app.staticTexts["test_gauntlet_zoo_trip.mp4"].exists,
                       "Non-matching zoo_trip row survived the 'beach' filter.")

        // 5. Clear the filter — everything comes back.
        replaceText(in: search, with: "")
        search.typeKey(.delete, modifierFlags: [])   // flush the emptied field
        XCTAssertTrue(birthday.waitForExistence(timeout: 20),
                      "Rows did not return after clearing the search field.")
    }
}
