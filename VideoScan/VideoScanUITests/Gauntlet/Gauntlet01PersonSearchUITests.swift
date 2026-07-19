//
//  Gauntlet01PersonSearchUITests.swift
//  VideoScanUITests — Gauntlet v1, flow 1 of 5
//
//  Rick's spot test: "search for a person on a volume."
//
//  Fixtures (synthesized per run, GauntletFixturePlan-verified):
//    * refs/            one known face photo (the reference)
//    * videos/found     the same photo on screen for the full 10 s
//                       → hits ≈ 50 ≥ floor(7) → FOUND
//    * videos/below     the photo for 1 s of 20 s
//                       → hits ≈ 5 < floor(7), sampled ≈ 100 ≥ 7
//                       → REFUSED by the match-confidence floor
//
//  Asserts, in Rick's order: the scan completes, the results table
//  populates with the found video, and the refused-below-floor console
//  line appears (the exact wording pinned by
//  PersonFinderModel.belowFloorSummaryLine) — under the DEFAULT
//  Match Confidence Floor, which isolation guarantees is 7.
//

import XCTest
import VideoScanCore

final class Gauntlet01PersonSearchUITests: GauntletTestCase {

    @MainActor
    func testPersonSearchOnFixtureVolume() throws {
        try XCTSkipUnless(GauntletFixtures.toolsAvailable,
                          "ffmpeg not installed — Gauntlet fixtures are synthesized per run.")
        let photo = try XCTUnwrap(GauntletFixtures.referencePhoto(),
                                  "No reference face photo (repo fixture missing and VS_GAUNTLET_PHOTO unset).")

        // 1. Fixtures. The plan's arithmetic (unit-tested in VideoScanCore)
        //    proves the durations straddle the floor BEFORE we launch.
        let refDir = sandboxRoot.appendingPathComponent("refs", isDirectory: true)
        let scanDir = sandboxRoot.appendingPathComponent("videos", isDirectory: true)
        try FileManager.default.createDirectory(at: refDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scanDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: photo, to: refDir.appendingPathComponent(photo.lastPathComponent))

        XCTAssertTrue(GauntletFixturePlan.shouldBeRefusedByFloor(
            faceSeconds: 1, totalSeconds: 20, fps: 25, frameStep: 5, floor: 7),
            "Fixture plan no longer straddles the floor — update durations.")
        try GauntletFixtures.render(
            GauntletFixturePlan.faceTimelineVideo(
                photoPath: photo.path, label: "found",
                faceSeconds: 10, totalSeconds: 10),
            into: scanDir)
        try GauntletFixtures.render(
            GauntletFixturePlan.faceTimelineVideo(
                photoPath: photo.path, label: "belowfloor",
                faceSeconds: 1, totalSeconds: 20),
            into: scanDir)

        // 2. Launch with the POI + recent-path seams; open the People tab.
        let app = launchGauntletApp(seams: [
            "gauntletPOIName": "Gauntlet",
            "gauntletPOIRefPath": refDir.path,
            "gauntletRecentPath": scanDir.path
        ])
        openTab(app, "People")

        // 3. Right-click the person card → "Search for Gauntlet…".
        let card = app.otherElements["pf.person.Gauntlet"].firstMatch
        let cardFallback = app.staticTexts["Gauntlet"].firstMatch
        if card.waitForExistence(timeout: 30) {
            card.rightClick()
        } else {
            // Identifier placement on a composite SwiftUI card can land on
            // a different AX role — fall back to the visible name text.
            XCTAssertTrue(cardFallback.waitForExistence(timeout: 15),
                          "The seam-installed 'Gauntlet' POI never appeared in the People pane.")
            cardFallback.rightClick()
        }
        clickMenuItem(app, titled: "Search for Gauntlet\u{2026}")

        // 4. Pick the fixture folder from the volume menu's Recent section
        //    (fed by the gauntletRecentPath seam), then Start.
        let volumeMenu = app.menuButtons["pf.job.volumeMenu"].firstMatch
        XCTAssertTrue(volumeMenu.waitForExistence(timeout: 30),
                      "New search row's volume picker never appeared after 'Search for Gauntlet…'.")
        volumeMenu.click()
        clickMenuItem(app, titled: scanDir.lastPathComponent)

        let start = app.buttons["pf.job.startButton"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 15),
                      "Start button not visible on the search row.")
        start.click()

        // 5. Scan completes and the results table shows the FOUND video.
        //    ~150 sampled Vision frames across two clips — minutes at the
        //    outside on the M1.
        let foundRow = app.staticTexts["test_gauntlet_face_found.mp4"]
        XCTAssertTrue(foundRow.waitForExistence(timeout: 600),
                      "Scan never produced the found-video row — job may have failed; open the Face Detection Console output in the attached screenshot.")

        // The refused video must NOT be presented as found. Scope to
        // tables so a transient "current file" label can't false-positive.
        XCTAssertFalse(
            app.tables.staticTexts["test_gauntlet_face_belowfloor.mp4"].exists,
            "The below-floor video appeared in the results table — the confidence floor did not refuse it.")

        // 6. The honest console line. Wording pinned by
        //    belowFloorSummaryLine(count: 1, floor: 7).
        let consoleButton = app.buttons["pf.console.open"]
        XCTAssertTrue(consoleButton.waitForExistence(timeout: 15),
                      "Console button missing from the jobs toolbar.")
        consoleButton.click()

        let consoleWindow = app.windows["Face Detection Console"]
        XCTAssertTrue(consoleWindow.waitForExistence(timeout: 15),
                      "Face Detection Console window never opened.")
        let expectedLine = "1 video had brief possible matches below the confidence floor (7)"
        let deadline = Date().addingTimeInterval(30)
        var consoleText = ""
        var lineSeen = false
        while Date() < deadline {
            consoleText = (consoleWindow.textViews.firstMatch.value as? String) ?? ""
            if consoleText.contains(expectedLine) { lineSeen = true; break }
            Thread.sleep(forTimeInterval: 1.0)
        }
        XCTAssertTrue(lineSeen, """
            Refused-below-floor console line never appeared.
            Expected substring: \(expectedLine)
            Console tail: …\(consoleText.suffix(400))
            """)
    }
}
