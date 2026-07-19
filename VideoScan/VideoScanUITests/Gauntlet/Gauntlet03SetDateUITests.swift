//
//  Gauntlet03SetDateUITests.swift
//  VideoScanUITests — Gauntlet v1, flow 3 of 5
//
//  Rick's spot test: "set a date" (Estimated Date, GH #117).
//
//  Select a scanned fixture, open the inspector's WHEN WAS THIS?
//  section, and walk the three user paths in order:
//    1. "1992" saved as Best guess  → Date column shows "1992 (est.)"
//    2. "6/14/1992" + I'm sure      → canonical "1992-06-14", no (est.)
//    3. garbage ("potato")          → the friendly rejection line
//

import XCTest
import VideoScanCore

final class Gauntlet03SetDateUITests: GauntletTestCase {

    @MainActor
    func testSetDateThroughInspector() throws {
        try XCTSkipUnless(GauntletFixtures.toolsAvailable,
                          "ffmpeg not installed — Gauntlet fixtures are synthesized per run.")

        // 1. One fixture is enough; scan it in.
        let catalogDir = sandboxRoot.appendingPathComponent("catalog", isDirectory: true)
        try FileManager.default.createDirectory(at: catalogDir, withIntermediateDirectories: true)
        try GauntletFixtures.render(
            GauntletFixturePlan.catalogClip(label: "dated_clip"), into: catalogDir)

        let app = launchGauntletApp(seams: ["gauntletScanTarget": catalogDir.path])
        scanFixturesIntoCatalog(app, waitForFilename: "test_gauntlet_dated_clip.mp4")

        // 2. Select the row (click its filename cell) — the inspector
        //    (visible by default) shows the record's sections.
        app.staticTexts["test_gauntlet_dated_clip.mp4"].firstMatch.click()

        let dateField = app.textFields["inspector.date.field"]
        XCTAssertTrue(dateField.waitForExistence(timeout: 30),
                      "WHEN WAS THIS? date field never appeared — is the inspector open and the row selected?")

        // 3. "1992" as Best guess (the default confidence).
        replaceText(in: dateField, with: "1992")
        app.buttons["inspector.date.save"].click()

        let status = app.staticTexts["inspector.date.status"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 15),
                      "Saved-date status line never appeared after Save.")
        XCTAssertTrue(status.label.contains("1992") && status.label.contains("best guess"),
                      "Expected 'Saved: 1992 — best guess', got: \(status.label)")
        XCTAssertTrue(app.staticTexts["1992 (est.)"].waitForExistence(timeout: 15),
                      "Date column never showed '1992 (est.)' after a best-guess year.")

        // 4. Full date, I'm sure. The segmented control's segments render
        //    as buttons titled with their text.
        replaceText(in: dateField, with: "6/14/1992")
        app.buttons["inspector.date.save"].click()
        let sureSegment = app.radioButtons["I'm sure"].firstMatch.exists
            ? app.radioButtons["I'm sure"].firstMatch
            : app.buttons["I'm sure"].firstMatch
        XCTAssertTrue(sureSegment.waitForExistence(timeout: 15),
                      "\"I'm sure\" confidence segment not found.")
        sureSegment.click()

        let sureDeadline = Date().addingTimeInterval(15)
        var sure = false
        while Date() < sureDeadline {
            if status.exists,
               status.label.contains("1992-06-14"),
               status.label.contains("sure") { sure = true; break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(sure,
                      "Status never became 'Saved: 1992-06-14 — you're sure'; last: \(status.exists ? status.label : "<gone>")")
        XCTAssertTrue(app.staticTexts["1992-06-14"].waitForExistence(timeout: 15),
                      "Date column never updated to the canonical certain date.")
        XCTAssertFalse(app.staticTexts["1992-06-14 (est.)"].exists,
                       "Date column still carries (est.) after I'm sure.")

        // 5. Garbage in → friendly rejection, saved date untouched.
        replaceText(in: dateField, with: "potato")
        app.buttons["inspector.date.save"].click()
        let rejection = app.staticTexts["inspector.date.rejected"]
        XCTAssertTrue(rejection.waitForExistence(timeout: 15),
                      "The friendly rejection line never appeared for garbage input.")
        XCTAssertTrue(rejection.label.contains("couldn't read that"),
                      "Rejection wording changed: \(rejection.label)")
        XCTAssertTrue(app.staticTexts["1992-06-14"].exists,
                      "A rejected entry must not clobber the previously saved date.")
    }
}
