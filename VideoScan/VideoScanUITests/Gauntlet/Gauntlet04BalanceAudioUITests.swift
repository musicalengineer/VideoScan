//
//  Gauntlet04BalanceAudioUITests.swift
//  VideoScanUITests — Gauntlet v1, flow 4 of 5
//
//  Rick's spot test: "Balance Audio on DV material" (GH #116).
//
//  Two fixtures:
//    * a two-pair DV file (DVCPRO50 shape — dvvideo + two PCM stereo
//      pairs, program on the right channel of pair 1, pair 2 silent):
//      the FIXABLE case. Right-click → Balance Audio… → Balance; the
//      MFO window's job reaches done and <stem>_balanced.mov appears
//      (raw DV publishes as QuickTime — the container fix).
//    * a true-stereo mov: the sheet must EXPLAIN and offer no Balance
//      button — the refusal wording assertion.
//

import XCTest
import VideoScanCore

final class Gauntlet04BalanceAudioUITests: GauntletTestCase {

    @MainActor
    func testBalanceAudioOnTwoPairDVAndTrueStereoRefusal() throws {
        try XCTSkipUnless(GauntletFixtures.toolsAvailable,
                          "ffmpeg not installed — Gauntlet fixtures are synthesized per run.")

        // 1. Fixtures.
        let catalogDir = sandboxRoot.appendingPathComponent("catalog", isDirectory: true)
        try FileManager.default.createDirectory(at: catalogDir, withIntermediateDirectories: true)
        try GauntletFixtures.render(
            GauntletFixturePlan.twoPairDV(
                label: "fixable",
                pair1: GauntletFixturePlan.rightOnlyPair,
                pair2: GauntletFixturePlan.silentPair),
            into: catalogDir)
        try GauntletFixtures.render(
            GauntletFixturePlan.trueStereoMov(label: "refusal"), into: catalogDir)

        let app = launchGauntletApp(seams: ["gauntletScanTarget": catalogDir.path])
        scanFixturesIntoCatalog(app, waitForFilename: "test_gauntlet_2pair_fixable.dv")

        // 2. Fixable case: right-click → Balance Audio… → sheet analyzes
        //    → Balance.
        app.staticTexts["test_gauntlet_2pair_fixable.dv"].firstMatch.rightClick()
        clickMenuItem(app, titled: "Balance Audio\u{2026}")

        XCTAssertTrue(app.staticTexts["balanceSheet.title"].waitForExistence(timeout: 15),
                      "Balance Audio sheet never appeared.")
        let balanceButton = app.buttons["balanceSheet.balanceButton"]
        XCTAssertTrue(balanceButton.waitForExistence(timeout: 60),
                      "Balance button never appeared — analysis failed or the two-pair DV was refused (it must be fixable: one live pair + one silent).")
        balanceButton.click()

        // 3. MFO window opens itself; the job reaches done…
        let mfoWindow = app.windows["Media File Operations"]
        XCTAssertTrue(mfoWindow.waitForExistence(timeout: 30),
                      "Media File Operations window did not open after Balance.")
        XCTAssertTrue(
            mfoWindow.staticTexts["mfo.row.finishedChip"].waitForExistence(timeout: 180),
            "Balance job never showed the finished chip in the MFO window.")

        // …and the balanced copy exists on disk, as QuickTime (.mov):
        // raw DV can't hold the balanced sound (the very bug the fix
        // works around), so the publish is <stem>_balanced.mov.
        let published = try waitForFile(
            named: "test_gauntlet_2pair_fixable_balanced.mov",
            in: catalogDir, timeout: 60)
        let size = (try? published.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        XCTAssertGreaterThan(size, 100_000,
                             "_balanced.mov exists but is only \(size) bytes.")

        // 4. Refusal case: true stereo explains, offers no button.
        //    Bring the main window forward first.
        app.windows.firstMatch.click()
        openTab(app, "Catalog")
        app.staticTexts["test_gauntlet_stereo_refusal.mov"].firstMatch.rightClick()
        clickMenuItem(app, titled: "Balance Audio\u{2026}")

        let classification = app.staticTexts["balanceSheet.classification"]
        XCTAssertTrue(classification.waitForExistence(timeout: 60),
                      "Analysis verdict never appeared for the true-stereo fixture.")
        XCTAssertTrue(classification.label.contains("True stereo"),
                      "Expected the true-stereo refusal wording, got: \(classification.label)")
        XCTAssertTrue(classification.label.contains("Nothing to fix"),
                      "Refusal wording lost its 'Nothing to fix' reassurance: \(classification.label)")
        XCTAssertFalse(app.buttons["balanceSheet.balanceButton"].exists,
                       "Balance button offered for TRUE STEREO — the safety gate regressed.")
    }
}
