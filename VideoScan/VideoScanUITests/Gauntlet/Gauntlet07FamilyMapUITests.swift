//
//  Gauntlet07FamilyMapUITests.swift
//  VideoScanUITests — Gauntlet, flow 7
//
//  Rick 2026-10-29: "on the FT tab, launch the map … it is important."
//  The isolated app has no Master Archive, so no tree would load; the
//  runner writes a SYNTHETIC eleven-person tree (GauntletFamilyTreeFixture,
//  invented names, well-known cities) into the per-run sandbox and hands
//  the folder over with `-gauntletFamilyTreeDir` (GauntletSeams). Then it
//  clicks what Rick clicks: Family Tree tab → Walk Tree… → Walk → Skip to
//  end → Show on map, and asserts the Family Map rendered and the app is
//  still running.
//

import XCTest
import VideoScanCore

final class Gauntlet07FamilyMapUITests: GauntletTestCase {

    /// Writes the synthetic tree into the sandbox; returns its folder.
    private func writeFixtureTree() throws -> URL {
        let dir = sandboxRoot.appendingPathComponent("family-tree", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(GauntletFamilyTreeFixture.gedcom.utf8)
            .write(to: dir.appendingPathComponent(GauntletFamilyTreeFixture.fileName))
        return dir
    }

    /// Wait for `element` to exist AND be enabled (SwiftUI disables "Walk"
    /// until the tree is known and "Show on map" until the replay ends).
    private func waitEnabled(_ element: XCUIElement, timeout: TimeInterval,
                             _ message: String) {
        // A free-standing expectation (not `self.expectation(for:)`), so a
        // timeout is reported once, here, with the message.
        let enabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND isEnabled == true"), object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: timeout), .completed, message)
    }

    @MainActor
    func testWalkTreeOpensTheFamilyMap() throws {
        let tree = try writeFixtureTree()
        let app = launchGauntletApp(seams: ["gauntletFamilyTreeDir": tree.path])
        openTab(app, "Family Tree")

        // "Walk Tree…" is shown only for a LIVE tree: its appearance is the
        // proof the seam loaded the fixture.
        let walkTree = app.buttons["ft.walkTree"]
        XCTAssertTrue(walkTree.waitForExistence(timeout: 60),
                      "Walk Tree… never appeared — the fixture tree did not load (seam -gauntletFamilyTreeDir).")
        walkTree.click()

        let walk = app.buttons["ft.walk.start"]
        waitEnabled(walk, timeout: 30, "The walk sheet's Walk button never became enabled (no start person).")
        walk.click()

        // The fan replays the walk; Skip to end finishes it at once. The
        // replay of eleven people is short anyway, so a missing button
        // (already finished) is fine.
        let skip = app.buttons["ft.walk.skipToEnd"]
        if skip.waitForExistence(timeout: 60), skip.isEnabled { skip.click() }

        let showOnMap = app.buttons["ft.walk.showOnMap"]
        waitEnabled(showOnMap, timeout: 120, "Show on map never became enabled — the fan replay did not finish.")
        showOnMap.click()

        // The map view's Roll Call control exists only on the map stage.
        let rollCall = app.descendants(matching: .any)["ft.map.rollCall"]
        XCTAssertTrue(rollCall.waitForExistence(timeout: 120),
                      "The Family Map never rendered (ft.map.rollCall missing) after Show on map.")
        XCTAssertEqual(app.state, .runningForeground,
                       "App is not running after opening the Family Map.")

        // Close the sheet the way Rick does; the app must survive it.
        let done = app.buttons["ft.walk.done"]
        if done.waitForExistence(timeout: 10) { done.click() }
        XCTAssertEqual(app.state, .runningForeground,
                       "App is not running after closing the Family Map.")
    }
}
