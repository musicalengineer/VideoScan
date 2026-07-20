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
        // macOS 26 exposes a styled SwiftUI Text's string via `value`, not
        // `label`, when it carries only an .accessibilityIdentifier — `label`
        // is empty. Read label, falling back to value (same fix as Gauntlet05).
        let savedStatus = status.label.isEmpty ? (status.value as? String ?? "") : status.label
        XCTAssertTrue(savedStatus.contains("1992") && savedStatus.contains("best guess"),
                      "Expected 'Saved: 1992 — best guess', got: \(savedStatus)")
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
        var lastStatus = ""
        while Date() < sureDeadline {
            lastStatus = status.label.isEmpty ? (status.value as? String ?? "") : status.label
            if status.exists,
               lastStatus.contains("1992-06-14"),
               lastStatus.contains("sure") { sure = true; break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(sure,
                      "Status never became 'Saved: 1992-06-14 — you're sure'; last: \(status.exists ? lastStatus : "<gone>")")
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
        let rejectionText = rejection.label.isEmpty ? (rejection.value as? String ?? "") : rejection.label
        XCTAssertTrue(rejectionText.contains("couldn't read that"),
                      "Rejection wording changed: \(rejectionText)")
        XCTAssertTrue(app.staticTexts["1992-06-14"].exists,
                      "A rejected entry must not clobber the previously saved date.")
    }
}
