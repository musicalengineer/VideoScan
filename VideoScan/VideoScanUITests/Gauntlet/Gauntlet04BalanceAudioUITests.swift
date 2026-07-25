//
//  Gauntlet04BalanceAudioUITests.swift
//  VideoScanUITests — Gauntlet v1, flow 4 of 5
//
//  Rick's spot test: "Balance Audio on DV material" (GH #116), amended
//  for the GH #137 consolidation — Verify Audio is now the SINGLE audio
//  examination entry point, and Balance is offered as a treatment on
//  the Verification Results sheet. The standalone "Balance Audio…"
//  context-menu verb is RETIRED (asserted below).
//
//  Two fixtures:
//    * a two-pair DV file (DVCPRO50 shape — dvvideo + two PCM stereo
//      pairs, program on the right channel of pair 1, pair 2 silent):
//      the FIXABLE case. Right-click → Verify Audio (MFO job) →
//      Verification Results… → Balance Audio; the MFO window's render
//      job runs and <stem>_balanced.mov appears (raw DV publishes as
//      QuickTime — the container fix).
//    * a true-stereo mov: verification reports "All is well" and the
//      results sheet must offer NO Balance button — the safety-gate
//      assertion (true stereo is never "fixed").
//

import XCTest
import VideoScanCore

final class Gauntlet04BalanceAudioUITests: GauntletTestCase {

    @MainActor
    func testBalanceViaVerifyResultsAndTrueStereoOffersNoBalance() throws {
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

        // 2. GH #137 retirement pin: the row context menu must NOT offer
        //    the old standalone "Balance Audio…" verb any more.
        app.staticTexts["test_gauntlet_2pair_fixable.dv"].firstMatch.rightClick()
        XCTAssertTrue(app.menuItems.matching(
            NSPredicate(format: "title == %@", "Verify Audio")).firstMatch
                .waitForExistence(timeout: 10),
            "Context menu never opened (Verify Audio absent).")
        XCTAssertFalse(app.menuItems.matching(
            NSPredicate(format: "title == %@", "Balance Audio\u{2026}")).firstMatch.exists,
            "The retired standalone 'Balance Audio…' verb is back in the context menu — GH #137 consolidation regressed.")

        // 3. Fixable case: Verify Audio runs as an MFO job (never a
        //    blocking sheet — GH #135).
        clickMenuItem(app, titled: "Verify Audio")
        let mfoWindow = app.windows["Media File Operations"]
        XCTAssertTrue(mfoWindow.waitForExistence(timeout: 30),
                      "Media File Operations window did not open after Verify Audio.")

        // 4. "Verification Results…" appears in the context menu once
        //    the diagnosis is cached — poll by reopening the menu (the
        //    item's presence IS the completion signal, immune to
        //    finished-chip ambiguity when several jobs share the list).
        app.windows.firstMatch.click()
        openTab(app, "Catalog")
        try clickContextMenuItemWhenAvailable(
            app, row: "test_gauntlet_2pair_fixable.dv",
            titled: "Verification Results\u{2026}", timeout: 180)

        // 5. The results sheet presents instantly and offers Balance —
        //    with the two-pair DV story: wrapper note + planned name.
        XCTAssertTrue(app.staticTexts["verifySheet.title"].waitForExistence(timeout: 15),
                      "Verification Results sheet never appeared.")
        let balanceButton = app.buttons["verifySheet.balanceButton"]
        XCTAssertTrue(balanceButton.waitForExistence(timeout: 15),
                      "Balance button never appeared on the results sheet — the two-pair DV must be fixable (one live pair + one silent).")
        XCTAssertTrue(app.staticTexts["verifySheet.dvContainerNote"].exists,
                      "Raw-DV wrapper note missing — the sheet must be honest about publishing as .mov.")
        balanceButton.click()

        // 6. The render job runs in the MFO window and the balanced copy
        //    exists on disk, as QuickTime (.mov): raw DV can't hold the
        //    balanced sound (the very bug the fix works around).
        XCTAssertTrue(mfoWindow.waitForExistence(timeout: 30),
                      "Media File Operations window did not open after Balance.")
        let published = try waitForFile(
            named: "test_gauntlet_2pair_fixable_balanced.mov",
            in: catalogDir, timeout: 180)
        let size = (try? published.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        XCTAssertGreaterThan(size, 100_000,
                             "_balanced.mov exists but is only \(size) bytes.")

        // 7. Safety-gate case: true stereo verifies healthy, and the
        //    results sheet offers NO Balance button.
        app.windows.firstMatch.click()
        openTab(app, "Catalog")
        app.staticTexts["test_gauntlet_stereo_refusal.mov"].firstMatch.rightClick()
        clickMenuItem(app, titled: "Verify Audio")
        app.windows.firstMatch.click()
        openTab(app, "Catalog")
        try clickContextMenuItemWhenAvailable(
            app, row: "test_gauntlet_stereo_refusal.mov",
            titled: "Verification Results\u{2026}", timeout: 180)

        XCTAssertTrue(app.staticTexts["verifySheet.allIsWell"].waitForExistence(timeout: 15),
                      "True-stereo fixture should verify healthy (All is well).")
        XCTAssertFalse(app.buttons["verifySheet.balanceButton"].exists,
                       "Balance button offered for TRUE STEREO — the safety gate regressed.")
    }

    /// Reopen `row`'s context menu until an item titled `titled` exists,
    /// then click it. Context menus are transient — the only way to
    /// poll a conditional item (like "Verification Results…", which
    /// appears once the diagnosis is cached) is to open, look, and
    /// dismiss with Escape when it isn't there yet.
    @MainActor
    private func clickContextMenuItemWhenAvailable(_ app: XCUIApplication,
                                                   row: String,
                                                   titled title: String,
                                                   timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            app.staticTexts[row].firstMatch.rightClick()
            let item = app.menuItems.matching(
                NSPredicate(format: "title == %@", title)).firstMatch
            if item.waitForExistence(timeout: 3) {
                item.click()
                return
            }
            app.typeKey(.escape, modifierFlags: [])
            Thread.sleep(forTimeInterval: 2.0)
        }
        XCTFail("Context menu item '\(title)' never appeared for \(row) within \(Int(timeout))s.")
        throw NSError(domain: "GauntletTestCase", code: 2)
    }
}
